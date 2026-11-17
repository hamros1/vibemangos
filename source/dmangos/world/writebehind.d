/**
 * Writes behind the game loop (docs/DESIGN.md, step 6): a write to the database no longer stalls a tick.
 *
 * `WriteBehind` wraps the world server's `WorldDatabase`:
 * $(UL
 *   $(LI A write (a method that returns nothing, with arguments that are plain data) is copied into
 *        bytes and queued, and the call returns at once. A thread of its own, with its own database
 *        connections, carries the queue out in the order it was made.)
 *   $(LI Every other call (a read, or a write that hands over a delegate or an `out` argument) first
 *        waits for the queue to be written, so it sees everything written before it, as it did when
 *        writes were immediate.)
 *   $(LI A write marked `@Replaces` (a character's whole progress, its auras, its cooldowns) makes a
 *        queued one with the same key pointless: the writer skips the older one.)
 * )
 *
 * Before the writer carries out what it took from the queue, it appends it to a log file and flushes
 * the file to the disk; once MySQL has it, the log is emptied. At start-up, what the log still holds
 * (the server stopped between the two) is written first (`replayLog`). A crash so loses only what was
 * queued and not yet logged: what came while the writer was busy with the writes before.
 *
 * Each queued write carries the time until which this node may write (its cluster lease, docs/CLUSTER.md
 * phase 4); the writer drops a write it reaches after that, and so does the replay. A standalone server
 * writes always.
 *
 * Everything is generated from the interface (`std.typecons.AutoImplement`, as in `fencing.d`), so a
 * method added there is queued or waited for without anyone remembering to.
 */
module dmangos.world.writebehind;

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.datetime.systime : Clock;
import std.meta : AliasSeq, staticMap;
import std.traits : FunctionAttribute, functionAttributes, hasUDA, isArray, isDynamicArray, isFloatingPoint,
    isIntegral, isSomeChar, isStaticArray, OriginalType, Parameters, ParameterStorageClass,
    ParameterStorageClassTuple, ReturnType, Unqual;
import std.typecons : AutoImplement;

import dmangos.plaindata : decode, encode, isPlainData, layout;
import dmangos.log : error, info, warning;
import dmangos.world.database : Replaces, WorldDatabase;

// ---------------------------------------------------------------------------------------------------
// The arguments as bytes
// ---------------------------------------------------------------------------------------------------

// ---------------------------------------------------------------------------------------------------
// Which methods are queued
// ---------------------------------------------------------------------------------------------------

/// Whether a call of `fun` is queued: it returns nothing, and its arguments are plain data passed in.
template isQueued(alias fun)
{
    enum isQueued = () {
        static if (!is(ReturnType!fun == void))
            return false;
        else
        {
            bool queued = true;
            static foreach (i, P; Parameters!fun)
            {
                queued = queued && isPlainData!P;
                static if (ParameterStorageClassTuple!fun[i] & (ParameterStorageClass.out_
                        | ParameterStorageClass.lazy_))
                    queued = false;
                static if (ParameterStorageClassTuple!fun[i] & ParameterStorageClass.ref_)
                    queued = queued && is(P == const);
            }
            return queued;
        }
    }();
}

/// A queued method's identity in the log: its name and the layout of its arguments, hashed (FNV-1a).
template signature(alias fun)
{
    enum signature = () {
        string text = __traits(identifier, fun) ~ "(";
        static foreach (P; Parameters!fun)
            text ~= layout!P ~ ",";
        ulong hash = 0xcbf29ce484222325;
        foreach (c; text)
        {
            hash ^= c;
            hash *= 0x100000001b3;
        }
        return hash;
    }();
}

/// The interface's methods, each overload once.
private template methods()
{
    alias methods = AliasSeq!();
    static foreach (name; __traits(allMembers, WorldDatabase))
        static foreach (fun; __traits(getOverloads, WorldDatabase, name))
            methods = AliasSeq!(methods, fun);
}

/// Carries out one queued call: the arguments decoded, the method called on `db`.
private void carryOut(alias fun)(WorldDatabase db, const(ubyte)[] bytes)
{
    import std.exception : enforce;

    staticMap!(Unqual, Parameters!fun) values;
    static foreach (i; 0 .. values.length)
        decode(bytes, values[i]);
    enforce(bytes.length == 0, "a queued write is longer than its arguments");
    __traits(getMember, db, __traits(identifier, fun))(values);
}

/// What a queued call is, by its `signature`: its name, and how to carry it out.
private struct Method
{
    string name;
    void function(WorldDatabase, const(ubyte)[]) carryOut;
}

private immutable Method[ulong] bySignature;

shared static this()
{
    Method[ulong] table;
    static foreach (fun; methods!())
        static if (isQueued!fun)
        {
            assert(signature!fun !in table, "two queued methods with one signature: " ~ __traits(identifier, fun));
            table[signature!fun] = Method(__traits(identifier, fun), &carryOut!fun);
        }
    bySignature = cast(immutable) table;
}

/// The key of a `@Replaces` write: its first argument, or that argument's `guid`.
private ulong replaceKey(T)(const ref T first)
{
    static if (is(T == struct))
        return first.guid;
    else
        return first;
}

// ---------------------------------------------------------------------------------------------------
// The queue and its writer
// ---------------------------------------------------------------------------------------------------

/// One queued write.
struct Write
{
    ulong signature;          /// which method (`signature`)
    long writableUntil;       /// in hnsecs since 1 AD (`Clock.currStdTime`): not written after; 0: always
    immutable(ubyte)[] args;  /// the arguments, as `encode` wrote them
    bool replaced;            /// a later write made it pointless
}

/// How the writer stands, for the metrics line.
struct WriterStats
{
    ulong queued;    /// writes queued since the start
    ulong written;   /// carried out
    ulong replaced;  /// skipped: replaced by a later one
    ulong refused;   /// dropped: after the time this node could write
    ulong failed;    /// the database refused them
    size_t waiting;  /// in the queue or being written now
}

/// The writer thread and its queue; see the module documentation.
final class Writer
{
    private
    {
        Mutex lock;
        Condition work;        // the writer waits for writes
        Condition finished;    // the game loop waits for the queue to be written
        Write[] queue;         // not yet taken
        size_t[ulong][ulong] latest; // for a `@Replaces` method, by key: its newest write in `queue`
        size_t inFlight;       // taken, being written
        bool stopping;
        WriterStats stats;
        shared long leaseUntil; // the newest `writableUntil` given: the lease has held until at least then
        WorldDatabase db;
        string logPath;
        Thread thread;
    }

    /**
     * A writer that writes into `db` (its own connections: it is used from the writer's thread only),
     * logging into `logPath` first (none: no log). Not `started`: it queues until `start`.
     */
    this(WorldDatabase db, string logPath, bool started = true)
    {
        this.db = db;
        this.logPath = logPath;
        lock = new Mutex;
        work = new Condition(lock);
        finished = new Condition(lock);
        thread = new Thread(&run);
        thread.isDaemon = true;
        if (started)
            start();
    }

    /// Starts the writer's thread.
    void start()
    {
        thread.start();
    }

    /// Queues a write; with `replaces`, the queued one with that key (and signature) is skipped.
    void put(Write write, bool replaces, ulong key)
    {
        if (write.writableUntil > atomicLoad(leaseUntil))
            atomicStore(leaseUntil, write.writableUntil);
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        if (replaces)
        {
            auto bySig = write.signature in latest;
            if (bySig is null)
            {
                latest[write.signature] = null;
                bySig = write.signature in latest;
            }
            if (auto older = key in *bySig)
            {
                queue[*older].replaced = true;
                ++stats.replaced;
            }
            (*bySig)[key] = queue.length;
        }
        queue ~= write;
        ++stats.queued;
        work.notify();
    }

    /// Waits until everything queued so far is written (or dropped).
    void settle()
    {
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        while (queue.length || inFlight)
            finished.wait();
    }

    /// Whether nothing waits to be written.
    @property bool settled()
    {
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        return queue.length == 0 && inFlight == 0;
    }

    /// Counts so far.
    WriterStats statistics()
    {
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        auto s = stats;
        s.waiting = queue.length + inFlight;
        return s;
    }

    /// Writes what is queued, then ends the thread.
    void stop()
    {
        {
            lock.lock_nothrow();
            scope (exit)
                lock.unlock_nothrow();
            stopping = true;
            work.notify();
        }
        thread.join();
    }

private:
    void run()
    {
        for (;;)
        {
            Write[] batch;
            {
                lock.lock_nothrow();
                scope (exit)
                    lock.unlock_nothrow();
                while (queue.length == 0 && !stopping)
                    work.wait();
                if (queue.length == 0)
                    return;
                batch = queue;
                queue = null;
                latest = null;
                inFlight = batch.length;
            }
            if (logPath.length)
                appendToLog(logPath, batch);
            ulong written, refused, failed;
            foreach (ref w; batch)
            {
                if (w.replaced)
                    continue;
                if (w.writableUntil && Clock.currStdTime >= atomicLoad(leaseUntil))
                {
                    ++refused;
                    if ((stats.refused + refused) % 100 == 1)
                        warning!"fenced: this node's lease has lapsed, so a queued '%s' was not written"(
                            nameOf(w.signature));
                    continue;
                }
                if (carryOutLogged(db, w))
                    ++written;
                else
                    ++failed;
            }
            if (logPath.length)
                emptyLog(logPath);
            {
                lock.lock_nothrow();
                scope (exit)
                    lock.unlock_nothrow();
                inFlight = 0;
                stats.written += written;
                stats.refused += refused;
                stats.failed += failed;
                finished.notifyAll();
            }
        }
    }
}

/// The name of the method a signature stands for.
string nameOf(ulong signature)
{
    if (auto m = signature in bySignature)
        return m.name;
    return "?";
}

/// Carries out `w` on `db`; false (and logged) if the database refused it.
private bool carryOutLogged(WorldDatabase db, const ref Write w)
{
    const method = w.signature in bySignature;
    if (method is null)
    {
        error!"a queued write of an unknown method (signature %016x) was skipped"(w.signature);
        return false;
    }
    try
    {
        method.carryOut(db, w.args);
        return true;
    }
    catch (Exception e)
    {
        error!"a queued '%s' could not be written: %s"(method.name, e.msg);
        return false;
    }
}

// ---------------------------------------------------------------------------------------------------
// The log
// ---------------------------------------------------------------------------------------------------

private enum ubyte[8] logMagic = ['d', 'm', 'w', 'a', 'l', '0', '0', '1'];

/*
 * The log: `logMagic`, then each write as its length (uint), the CRC-32 of the rest (uint), its
 * signature (ulong), its `writableUntil` (long) and its arguments. A write cut short, or whose CRC is
 * wrong (the end of a write the system did not finish), ends the log.
 */
private void appendToLog(string path, const(Write)[] batch)
{
    import core.sys.posix.unistd : fdatasync;
    import std.digest.crc : crc32Of;
    import std.stdio : File;

    ubyte[] bytes;
    foreach (ref w; batch)
    {
        if (w.replaced)
            continue;
        ubyte[] body_;
        encode(body_, w.signature);
        encode(body_, w.writableUntil);
        body_ ~= w.args;
        const uint length = cast(uint) body_.length;
        const crc = crc32Of(body_);
        const uint check = crc[0] | crc[1] << 8 | crc[2] << 16 | uint(crc[3]) << 24;
        encode(bytes, length);
        encode(bytes, check);
        bytes ~= body_;
    }
    try
    {
        auto file = File(path, "ab");
        if (file.size == 0)
            file.rawWrite(logMagic[]);
        file.rawWrite(bytes);
        file.flush();
        fdatasync(file.fileno);
    }
    catch (Exception e)
        error!"cannot log queued writes in %s (they are written, but a crash before would lose them): %s"(path,
            e.msg);
}

private void emptyLog(string path)
{
    import std.stdio : File;

    try
        File(path, "wb").close();
    catch (Exception e)
        error!"cannot empty the log of queued writes %s: %s"(path, e.msg);
}

/// The writes in the log at `path`, up to the first that is incomplete.
Write[] readLog(string path)
{
    import std.digest.crc : crc32Of;
    import std.file : exists, read;

    if (!exists(path))
        return null;
    const(ubyte)[] bytes = cast(const(ubyte)[]) read(path);
    if (bytes.length < logMagic.length || bytes[0 .. logMagic.length] != logMagic[])
        return null;
    bytes = bytes[logMagic.length .. $];
    Write[] writes;
    while (bytes.length >= 8)
    {
        uint length, check;
        decode(bytes, length);
        decode(bytes, check);
        if (length < 16 || length > bytes.length)
            break;
        const body_ = bytes[0 .. length];
        const crc = crc32Of(body_);
        if (check != (crc[0] | crc[1] << 8 | crc[2] << 16 | uint(crc[3]) << 24))
            break;
        bytes = bytes[length .. $];
        const(ubyte)[] rest = body_;
        Write w;
        decode(rest, w.signature);
        decode(rest, w.writableUntil);
        w.args = rest.idup;
        writes ~= w;
    }
    return writes;
}

/**
 * At start-up: writes what the log at `path` still holds (the server stopped after logging writes and
 * before MySQL had them all) into `db`, then empties it. A write made under a lease that has lapsed
 * since is dropped: the regions may be another node's now. Returns how many were written.
 */
size_t replayLog(string path, WorldDatabase db)
{
    import std.file : exists;

    auto writes = readLog(path);
    size_t written, expired;
    const now = Clock.currStdTime;
    foreach (ref w; writes)
    {
        if (w.writableUntil && now >= w.writableUntil)
            ++expired;
        else if (carryOutLogged(db, w))
            ++written;
    }
    if (writes.length)
        info!"log of queued writes %s: %s write(s) the database did not have yet written again, %s dropped (made under a lease that has lapsed)"(
            path, written, expired);
    if (exists(path))
        emptyLog(path);
    return written;
}

// ---------------------------------------------------------------------------------------------------
// The database that writes behind
// ---------------------------------------------------------------------------------------------------

/// The part of `WriteBehind` that is not generated.
abstract class WriteBehindBase : WorldDatabase
{
    protected WorldDatabase reader;
    protected Writer writer;
    /// Until when this node may write (`Clock.currStdTime`), asked at each write; null: always.
    long delegate() writableUntil;

    /**
     * Reads (and the writes that cannot be queued) go to `reader`, in the game loop; queued writes go to
     * `writer`. `writableUntil` says until when this node may write (`Clock.currStdTime`); null: always.
     */
    this(WorldDatabase reader, Writer writer, long delegate() writableUntil = null)
    {
        this.reader = reader;
        this.writer = writer;
        this.writableUntil = writableUntil;
    }

    /// Waits until everything queued so far is written.
    void settle()
    {
        writer.settle();
    }

    /// The writer.
    @property Writer queue()
    {
        return writer;
    }

    protected void enqueue(alias fun, Args...)(auto ref Args args)
    {
        Write w;
        w.signature = signature!fun;
        w.writableUntil = writableUntil is null ? 0 : writableUntil();
        ubyte[] bytes;
        static foreach (i; 0 .. Args.length)
            encode(bytes, args[i]);
        w.args = cast(immutable) bytes;
        static if (hasUDA!(fun, Replaces))
            writer.put(w, true, replaceKey(args[0]));
        else
            writer.put(w, false, 0);
    }
}

// Every method: queued if it can be, otherwise after the queue is written.
private enum string behind(C, alias fun) = isQueued!fun
    ? "enqueue!parent(args);"
    : "writer.settle(); return reader." ~ __traits(identifier, fun) ~ "(args);";

/// See the module documentation.
alias WriteBehind = AutoImplement!(WriteBehindBase, behind);

// The writes that wait for the queue, because they cannot be queued: a test notices a new one.
unittest
{
    string[] waiting;
    static foreach (fun; methods!())
        static if (is(ReturnType!fun == void) && !isQueued!fun)
            waiting ~= __traits(identifier, fun);
    import std.conv : text;

    assert(waiting == ["deleteCharacter", "loadTalentReset"], "waited for: " ~ text(waiting));
}

version (unittest)
{
    import dmangos.world.testclient : newDatabase;
}

// Writes return at once and are written in order; a read waits for them.
unittest
{
    auto inner = newDatabase();
    auto writer = new Writer(inner, null);
    scope (exit)
        writer.stop();
    WorldDatabase db = new WriteBehind(inner, writer, null);
    const id = db.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 5);
    db.setMuteTime(id, 9);
    assert(db.findAccount("PLAYER").get.muteTime == 9, "the read saw both writes, the last one last");
    assert(writer.settled);
    assert(writer.statistics.written == 2);
}

// A newer whole save of a character replaces a queued older one.
unittest
{
    import dmangos.world.database : AuraRecord;

    auto inner = newDatabase();
    auto writer = new Writer(inner, null, false); // queues until started, as while busy
    scope (exit)
        writer.stop();
    auto db = new WriteBehind(inner, writer, null);
    db.queue.put(Write(signature!(WorldDatabase.setMuteTime), 0, null), false, 0); // malformed: fails
    AuraRecord a;
    a.spell = 1;
    db.saveAuras(7, [a]);
    a.spell = 2;
    db.saveAuras(7, [a]);
    db.saveAuras(8, [a]);
    writer.start();
    assert(db.loadAuras(7).length == 1 && db.loadAuras(7)[0].spell == 2);
    assert(db.loadAuras(8).length == 1);
    const s = writer.statistics;
    assert(s.replaced == 1 && s.failed == 1, "the older save of 7 was skipped");
}

// A write reached after the lease lapsed is dropped.
unittest
{
    auto inner = newDatabase();
    auto writer = new Writer(inner, null);
    scope (exit)
        writer.stop();
    long until = Clock.currStdTime - 1; // already lapsed
    WorldDatabase db = new WriteBehind(inner, writer, () => until);
    const id = db.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 42);
    assert(db.findAccount("PLAYER").get.muteTime != 42);
    assert(writer.statistics.refused == 1);
}

// The log: written before MySQL, emptied after; what it still holds at start-up is written then.
unittest
{
    import std.file : exists, getSize, remove, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : to;

    const path = buildPath(tempDir, "dmangos-writebehind-" ~ thisProcessID.to!string ~ ".log");
    scope (exit)
        if (exists(path))
            remove(path);

    auto inner = newDatabase();
    const id = inner.findAccount("PLAYER").get.id;
    {
        auto writer = new Writer(inner, path);
        WorldDatabase db = new WriteBehind(inner, writer, null);
        db.setMuteTime(id, 11);
        writer.settle();
        writer.stop();
        assert(inner.findAccount("PLAYER").get.muteTime == 11);
        assert(getSize(path) == 0, "emptied once written");
    }

    // A server that stopped between logging and writing: three writes logged, the last one cut short.
    ubyte[] args;
    encode(args, id);
    long until = 0;
    encode(args, until);
    auto w = Write(signature!(WorldDatabase.setMuteTime), 0, cast(immutable) args);
    auto expired = Write(signature!(WorldDatabase.setMuteTime), Clock.currStdTime - 1, cast(immutable) args);
    appendToLog(path, [w, expired]);
    ubyte[] wrong;
    encode(wrong, id);
    long other = 99;
    encode(wrong, other);
    appendToLog(path, [Write(signature!(WorldDatabase.setMuteTime), 0, cast(immutable) wrong)]);
    {
        import std.stdio : File;

        const size = getSize(path);
        import core.sys.posix.unistd : ftruncate;

        auto f = File(path, "r+b");
        ftruncate(f.fileno, size - 3);
    }
    inner.setMuteTime(id, 5);
    assert(readLog(path).length == 2);
    assert(replayLog(path, inner) == 1, "the expired one is dropped, the cut one never read");
    assert(inner.findAccount("PLAYER").get.muteTime == 0);
    assert(getSize(path) == 0);
}
