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
 * Each write is numbered, and carried out in a transaction that also records its number in the
 * database (`WriteLedger`); the replay skips the writes recorded, so none is written twice.
 *
 * While the database is unavailable, the writer tries the same write again (so the order holds), waiting
 * longer each time (`retryDelayMs`); the queue grows meanwhile, up to `Writer.maxQueued`. `settle` (reads,
 * handovers) does not wait for it beyond `Writer.stalledWaitMs`, so the game and its cluster lease go on. A write the
 * database refuses outright is kept in a file beside the log (`failedPath`) and the writer goes on.
 *
 * Each queued write carries the time until which this node may write (its cluster lease, docs/CLUSTER.md);
 * the writer drops a write it reaches after that, and so does the replay. A standalone server
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
import dmangos.world.database : Replaces, WorldDatabase, WriteLedger;

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
    ulong seq;                /// its number in this writer's stream (from 1; 0: not numbered)
}

/// How the writer stands, for the metrics line.
struct WriterStats
{
    ulong queued;    /// writes queued since the start
    ulong written;   /// carried out
    ulong replaced;  /// skipped: replaced by a later one
    ulong refused;   /// dropped: after the time this node could write
    ulong failed;    /// the database refused them (each kept in the file of failed writes)
    ulong retried;   /// tried again because the database was away
    size_t waiting;  /// in the queue or being written now
    bool stalled;    /// the database is away: the writer waits to try again
}

/// What became of a write carried out.
private enum Outcome
{
    written,
    failed,  /// refused by the database: it would be again
    away,    /// the database is unavailable: try again later
}

/**
 * Carries out `w` on `db`, recording it in `ledger` (if any, and if `w` is numbered) in the same
 * transaction. Logs a failure.
 */
private Outcome carryOutLogged(WorldDatabase db, WriteLedger ledger, uint stream, const ref Write w)
{
    import dmangos.mysql : DatabaseException;

    const method = w.signature in bySignature;
    if (method is null)
    {
        error!"a queued write of an unknown method (signature %016x) was skipped"(w.signature);
        return Outcome.failed;
    }
    try
    {
        if (ledger !is null && w.seq)
            ledger.applying(stream, w.seq, { method.carryOut(db, w.args); });
        else
            method.carryOut(db, w.args);
        return Outcome.written;
    }
    catch (DatabaseException e)
    {
        if (e.transient)
            return Outcome.away;
        error!"a queued '%s' could not be written: %s"(method.name, e.msg);
        return Outcome.failed;
    }
    catch (Exception e)
    {
        error!"a queued '%s' could not be written: %s"(method.name, e.msg);
        return Outcome.failed;
    }
}

/// How long to wait before trying the database again, after `attempt` tries (from 1): 0.25 s doubling to 5 s.
long retryDelayMs(uint attempt) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : min;

    return attempt >= 6 ? 5_000 : min(5_000, 250L << (attempt - 1));
}

/// The writer thread and its queue; see the module documentation.
final class Writer
{
    /// Writes waiting beyond which `put` waits too (the database is away and the queue grows).
    enum size_t maxQueued = 200_000;
    /// While stopping, how long the writer goes on trying an unavailable database before it leaves the rest in the log.
    long giveUpAfterMs = 30_000;
    /// How long `settle` waits for a writer that cannot reach the database before it returns.
    long stalledWaitMs = 1_000;

    private
    {
        Mutex lock;
        Condition work;        // the writer waits for writes
        Condition pause;       // while the database is away, the writer waits for its next try (or the stop)
        Condition finished;    // the game loop waits for the queue to be written
        Condition room;        // `put` waits for room in the queue
        Write[] queue;         // not yet taken
        size_t[ulong][ulong] latest; // for a `@Replaces` method, by key: its newest write in `queue`
        size_t inFlight;       // taken, being written
        bool stopping;
        WriterStats stats;
        shared long leaseUntil; // the newest `writableUntil` given or renewed: the lease has held until at least then
        shared long lapsedAt;   // when the lease last lapsed: a write made before is never written
        WorldDatabase db;
        WriteLedger ledger;    // where written writes are recorded; null: not recorded
        uint stream;
        ulong lastSeq;         // the number given to the newest write
        string logPath;
        Thread thread;
    }

    /**
     * A writer that writes into `db` (its own connections: it is used from the writer's thread only),
     * logging into `logPath` first (none: no log). Not `started`: it queues until `start`.
     *
     * If `db` is a `WriteLedger` whose table can be used, each write is numbered in `stream` and recorded
     * there as it is written, so that writing the log again after a crash skips what the database has.
     */
    this(WorldDatabase db, string logPath, bool started = true, uint stream = 0)
    {
        this.db = db;
        this.logPath = logPath;
        this.stream = stream;
        lock = new Mutex;
        work = new Condition(lock);
        finished = new Condition(lock);
        room = new Condition(lock);
        pause = new Condition(lock);
        if (auto l = cast(WriteLedger) db)
        {
            try
            {
                l.prepareLedger();
                lastSeq = l.appliedUpTo(stream);
                ledger = l;
            }
            catch (Exception e)
                warning!"writes are not recorded in dmangos_write_applied (%s): a crash while writing may write some twice"(
                    e.msg);
        }
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
        if (queue.length >= maxQueued)
        {
            warning!"%s writes wait for the database: the game waits for room"(queue.length);
            while (queue.length >= maxQueued && !stopping)
                room.wait();
        }
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
        write.seq = ++lastSeq;
        queue ~= write;
        ++stats.queued;
        work.notify();
    }

    /**
     * Waits until everything queued so far is written or dropped. Returns false if the database refused
     * one of the writes meanwhile, or if it is unavailable: then `settle` returns after `stalledWaitMs`
     * (the game goes on; the writes wait, in order, and are written when it is back).
     */
    bool settle()
    {
        import core.time : msecs, MonoTime;

        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        const failedBefore = stats.failed;
        MonoTime stalledSince;
        while (queue.length || inFlight)
        {
            finished.wait(50.msecs);
            if (!stats.stalled)
                stalledSince = MonoTime.init;
            else if (stalledSince == MonoTime.init)
                stalledSince = MonoTime.currTime;
            else if (MonoTime.currTime - stalledSince >= stalledWaitMs.msecs)
                return false;
        }
        return stats.failed == failedBefore;
    }

    /**
     * The lease holds until `until` (`Clock.currStdTime`), as the cluster renewed it: a write waiting for the
     * database may be written until then, though no newer write said so.
     */
    void renewLease(long until)
    {
        if (until > atomicLoad(leaseUntil))
            atomicStore(leaseUntil, until);
    }

    /// The lease lapsed at `at`: no write made before it is written, even once the lease holds again.
    void leaseLapsed(long at)
    {
        atomicStore(lapsedAt, at);
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

    /// Whether the writes are recorded in the database's ledger (exactly once).
    @property bool recorded() const
    {
        return ledger !is null;
    }

    /**
     * Writes what is queued, then ends the thread. If the database is away, the writer goes on trying for
     * `giveUpAfterMs`, then leaves what it has not written in the log, for the next start.
     */
    void stop()
    {
        {
            lock.lock_nothrow();
            scope (exit)
                lock.unlock_nothrow();
            stopping = true;
            work.notify();
            pause.notify();
            room.notifyAll();
        }
        thread.join();
    }

private:
    void run()
    {
        import core.time : msecs, MonoTime;

        MonoTime stoppingSince;
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
                room.notifyAll();
            }
            if (logPath.length)
                appendToLog(logPath, batch);
            bool abandoned;
            foreach (ref w; batch)
            {
                if (w.replaced)
                    continue;
                for (uint attempt = 1;; ++attempt)
                {
                    if (w.writableUntil && (Clock.currStdTime >= atomicLoad(leaseUntil)
                            || w.writableUntil <= atomicLoad(lapsedAt)))
                    {
                        count((ref s) { ++s.refused; });
                        if (statistics.refused % 100 == 1)
                            warning!"fenced: this node's lease has lapsed, so a queued '%s' was not written"(
                                nameOf(w.signature));
                        break;
                    }
                    const outcome = carryOutLogged(db, ledger, stream, w);
                    if (outcome == Outcome.written)
                    {
                        count((ref s) { ++s.written; s.stalled = false; });
                        if (attempt > 1)
                            info!"the database is back: writing again"();
                        break;
                    }
                    if (outcome == Outcome.failed)
                    {
                        count((ref s) { ++s.failed; });
                        keepFailed(w);
                        break;
                    }
                    // The database is away: the same write again, after a while, so that the order holds.
                    bool giveUp;
                    {
                        lock.lock_nothrow();
                        scope (exit)
                            lock.unlock_nothrow();
                        ++stats.retried;
                        stats.stalled = true;
                        if (stopping && stoppingSince == MonoTime.init)
                            stoppingSince = MonoTime.currTime;
                        giveUp = stopping && MonoTime.currTime - stoppingSince >= giveUpAfterMs.msecs;
                        if (!giveUp)
                            pause.wait(retryDelayMs(attempt).msecs);
                    }
                    if (attempt == 1 || attempt % 20 == 0)
                        warning!"the database is unavailable: a queued '%s' waits to be written (try %s)"(
                            nameOf(w.signature), attempt);
                    if (giveUp)
                    {
                        abandoned = true;
                        break;
                    }
                }
                if (abandoned)
                    break;
            }
            if (abandoned)
            {
                error!"stopping with the database unavailable: the writes not yet written stay in %s, written at the next start"(
                    logPath.length ? logPath : "(no log: they are lost)");
                lock.lock_nothrow();
                scope (exit)
                    lock.unlock_nothrow();
                if (logPath.length)
                    appendToLog(logPath, queue); // queued meanwhile: after the batch, in order
                inFlight = 0;
                queue = null;
                finished.notifyAll();
                return;
            }
            if (logPath.length)
                emptyLog(logPath);
            {
                lock.lock_nothrow();
                scope (exit)
                    lock.unlock_nothrow();
                inFlight = 0;
                finished.notifyAll();
            }
        }
    }

    void count(scope void delegate(ref WriterStats) change)
    {
        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        change(stats);
    }

    // A write the database refused: kept in the file of failed writes; recorded as dealt with, so that the
    // log does not try it again after a crash.
    void keepFailed(const ref Write w)
    {
        if (logPath.length)
            keepFailedWrite(failedPath(logPath), w);
        if (ledger !is null && w.seq)
            try
                ledger.applying(stream, w.seq, {});
            catch (Exception e)
            {
            }
    }
}

/// The file of writes the database refused, beside the log at `logPath` (in the log's format).
string failedPath(string logPath)
{
    return logPath ~ ".failed";
}

private void keepFailedWrite(string path, const ref Write w)
{
    appendToLog(path, (&w)[0 .. 1]);
    error!"the refused write is kept in %s"(path);
}

/// The name of the method a signature stands for.
string nameOf(ulong signature)
{
    if (auto m = signature in bySignature)
        return m.name;
    return "?";
}

// ---------------------------------------------------------------------------------------------------
// The log
// ---------------------------------------------------------------------------------------------------

private enum ubyte[8] logMagic = ['d', 'm', 'w', 'a', 'l', '0', '0', '2'];
private enum ubyte[8] logMagicUnnumbered = ['d', 'm', 'w', 'a', 'l', '0', '0', '1']; // before writes were numbered

/*
 * The log: `logMagic`, then each write as its length (uint), the CRC-32 of the rest (uint), its
 * signature (ulong), its `writableUntil` (long), its number (ulong) and its arguments. A write cut short,
 * or whose CRC is wrong (the end of a write the system did not finish), ends the log. A log of the
 * earlier format (`logMagicUnnumbered`) has no numbers.
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
        encode(body_, w.seq);
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
    if (bytes.length < logMagic.length)
        return null;
    const numbered = bytes[0 .. logMagic.length] == logMagic[];
    if (!numbered && bytes[0 .. logMagic.length] != logMagicUnnumbered[])
        return null;
    bytes = bytes[logMagic.length .. $];
    Write[] writes;
    while (bytes.length >= 8)
    {
        uint length, check;
        decode(bytes, length);
        decode(bytes, check);
        if (length < (numbered ? 24 : 16) || length > bytes.length)
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
        if (numbered)
            decode(rest, w.seq);
        w.args = rest.idup;
        writes ~= w;
    }
    return writes;
}

/**
 * At start-up: writes what the log at `path` still holds (the server stopped after logging writes and
 * before MySQL had them all) into `db`, then empties it. A write the database's ledger (`WriteLedger`, of
 * `stream`) records as carried out is skipped; so is one made under a lease that has lapsed since (the
 * regions may be another node's now). While the database is unavailable it tries again, for up to
 * `patienceMs`; then it throws, and the log is kept. Returns how many were written.
 */
size_t replayLog(string path, WorldDatabase db, uint stream = 0, long patienceMs = 120_000)
{
    import core.thread : Thread;
    import core.time : msecs, MonoTime;
    import std.exception : enforce;
    import std.file : exists;

    auto writes = readLog(path);
    size_t written, expired, had, failed;
    if (writes.length)
    {
        auto ledger = cast(WriteLedger) db;
        ulong applied;
        if (ledger !is null)
            try
            {
                ledger.prepareLedger();
                applied = ledger.appliedUpTo(stream);
            }
            catch (Exception e)
            {
                warning!"cannot read dmangos_write_applied (%s): the log is written again whole"(e.msg);
                ledger = null;
            }
        const now = Clock.currStdTime;
        const since = MonoTime.currTime;
        foreach (ref w; writes)
        {
            if (w.writableUntil && now >= w.writableUntil)
            {
                ++expired;
                continue;
            }
            if (ledger !is null && w.seq && w.seq <= applied)
            {
                ++had;
                continue;
            }
            for (uint attempt = 1;; ++attempt)
            {
                const outcome = carryOutLogged(db, ledger, stream, w);
                if (outcome == Outcome.written)
                    ++written;
                else if (outcome == Outcome.failed)
                {
                    ++failed;
                    keepFailedWrite(failedPath(path), w);
                }
                else
                {
                    enforce(MonoTime.currTime - since < patienceMs.msecs,
                        "the database is unavailable: the log of queued writes " ~ path
                        ~ " is kept, to be written at the next start");
                    warning!"the database is unavailable: writing the log of queued writes again in a while"();
                    Thread.sleep(retryDelayMs(attempt).msecs);
                    continue;
                }
                break;
            }
        }
        info!"log of queued writes %s: %s write(s) the database did not have yet written again, %s it had skipped, %s dropped (made under a lease that has lapsed), %s refused"(
            path, written, had, expired, failed);
    }
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

    /// Waits until everything queued so far is written; false if the database refused one of the writes.
    bool settle()
    {
        return writer.settle();
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

version (unittest)
{
    import dmangos.mysql : DatabaseException;
    import dmangos.world.database : MemoryWorldDatabase;

    // A database in front of a `MemoryWorldDatabase` that is away (or refuses) for its next `failures` calls.
    abstract class FlakyBase : WorldDatabase, WriteLedger
    {
        MemoryWorldDatabase inner;
        shared int failures;
        uint code = 2013; // the connection lost

        this(MemoryWorldDatabase inner)
        {
            this.inner = inner;
        }

        void prepareLedger() {}
        ulong appliedUpTo(uint stream) { return inner.appliedUpTo(stream); }
        void applying(uint stream, ulong seq, scope void delegate() work) { inner.applying(stream, seq, work); }

        protected void maybeFail()
        {
            import core.atomic : atomicOp;

            if (atomicLoad(failures) > 0)
            {
                atomicOp!"-="(failures, 1);
                throw DatabaseException.withCode("away", code);
            }
        }
    }

    enum string flaky(C, alias fun) = "maybeFail(); return inner." ~ __traits(identifier, fun) ~ "(args);";
    alias Flaky = AutoImplement!(FlakyBase, flaky);

    string tempLog(string name)
    {
        import std.conv : to;
        import std.file : tempDir;
        import std.path : buildPath;
        import std.process : thisProcessID;

        return buildPath(tempDir, "dmangos-writebehind-" ~ name ~ "-" ~ thisProcessID.to!string ~ ".log");
    }
}

// While the database is away, a write waits and is tried again, in order; nothing is lost.
unittest
{
    auto inner = newDatabase();
    auto flaky = new Flaky(inner);
    const id = inner.findAccount("PLAYER").get.id;
    atomicStore(flaky.failures, 2);
    auto writer = new Writer(flaky, null);
    scope (exit)
        writer.stop();
    WorldDatabase db = new WriteBehind(inner, writer, null);
    db.setMuteTime(id, 21);
    db.setMuteTime(id, 22);
    assert(writer.settle());
    assert(inner.findAccount("PLAYER").get.muteTime == 22, "both written, the second last");
    const s = writer.statistics;
    assert(s.written == 2 && s.retried == 2 && s.failed == 0 && !s.stalled);
    assert(inner.appliedUpTo(0) == 2, "each recorded with its number");
}

// A write the database refuses goes to the file of failed writes, and settle says so.
unittest
{
    import std.file : exists, remove;

    const path = tempLog("refused");
    scope (exit)
        foreach (p; [path, failedPath(path)])
            if (exists(p))
                remove(p);
    auto inner = newDatabase();
    auto flaky = new Flaky(inner);
    flaky.code = 1062; // a duplicate key: it would be again
    atomicStore(flaky.failures, 1);
    auto writer = new Writer(flaky, path);
    scope (exit)
        writer.stop();
    WorldDatabase db = new WriteBehind(inner, writer, null);
    const id = inner.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 30);
    assert(!writer.settle(), "settle reports the refused write");
    db.setMuteTime(id, 31);
    assert(writer.settle());
    assert(inner.findAccount("PLAYER").get.muteTime == 31);
    const kept = readLog(failedPath(path));
    assert(kept.length == 1 && kept[0].seq == 1, "the refused write is kept, with its number");
    assert(inner.appliedUpTo(0) == 2, "and counted as dealt with");
}

// After a crash, the log is written again, skipping what the ledger says the database has: exactly once.
unittest
{
    import std.file : exists, remove;

    const path = tempLog("ledger");
    scope (exit)
        if (exists(path))
            remove(path);
    auto inner = newDatabase();
    const id = inner.findAccount("PLAYER").get.id;
    ubyte[] args;
    encode(args, id);
    long minutes = 50;
    encode(args, minutes);
    auto first = Write(signature!(WorldDatabase.setMuteTime), 0, cast(immutable) args, false, 7);
    ubyte[] args2;
    encode(args2, id);
    minutes = 60;
    encode(args2, minutes);
    auto second = Write(signature!(WorldDatabase.setMuteTime), 0, cast(immutable) args2, false, 8);
    appendToLog(path, [first, second]);
    inner.appliedWrites[3] = 8; // both committed before the crash
    inner.setMuteTime(id, 99); // and changed since
    assert(replayLog(path, inner, 3) == 0, "nothing written again");
    assert(inner.findAccount("PLAYER").get.muteTime == 99);

    appendToLog(path, [first, second]);
    inner.appliedWrites[3] = 7; // the crash came between them
    assert(replayLog(path, inner, 3) == 1);
    assert(inner.findAccount("PLAYER").get.muteTime == 60 && inner.appliedUpTo(3) == 8);

    // A new writer numbers on from the ledger.
    auto writer = new Writer(inner, null, true, 3);
    scope (exit)
        writer.stop();
    WorldDatabase db = new WriteBehind(inner, writer, null);
    db.setMuteTime(id, 61);
    writer.settle();
    assert(inner.appliedUpTo(3) == 9);
}

// Stopping while the database is away leaves the writes in the log, for the next start.
unittest
{
    import std.file : exists, remove;

    const path = tempLog("away");
    scope (exit)
        if (exists(path))
            remove(path);
    auto inner = newDatabase();
    auto flaky = new Flaky(inner);
    atomicStore(flaky.failures, int.max);
    auto writer = new Writer(flaky, path, false);
    WorldDatabase db = new WriteBehind(inner, writer, null);
    const id = inner.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 70);
    db.setMuteTime(id, 71);
    writer.giveUpAfterMs = 0;
    writer.start();
    writer.stop();
    assert(readLog(path).length == 2, "kept");
    assert(replayLog(path, inner) == 2);
    assert(inner.findAccount("PLAYER").get.muteTime == 71);
}

unittest
{
    assert(retryDelayMs(1) == 250 && retryDelayMs(2) == 500 && retryDelayMs(5) == 4_000 && retryDelayMs(6) == 5_000
        && retryDelayMs(100) == 5_000);
}

// While the database is away, settle returns after a while (the game goes on); a write kept writable by
// the renewed lease is written once the database is back.
unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    auto inner = newDatabase();
    auto flaky = new Flaky(inner);
    atomicStore(flaky.failures, 4); // 0.25 + 0.5 + 1 + 2 s away
    auto writer = new Writer(flaky, null);
    scope (exit)
        writer.stop();
    writer.stalledWaitMs = 100;
    long until = Clock.currStdTime + 5_000_000; // the lease, as the write is made: half a second more
    auto db = new WriteBehind(inner, writer, () => until);
    const id = inner.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 80);
    Thread.sleep(50.msecs);
    assert(!writer.settle(), "the database is away: settle does not wait for it");
    assert(writer.statistics.stalled);
    foreach (i; 0 .. 40) // the cluster renews the lease meanwhile
    {
        writer.renewLease(Clock.currStdTime + 5_000_000);
        if (inner.findAccount("PLAYER").get.muteTime == 80)
            break;
        Thread.sleep(100.msecs);
    }
    assert(inner.findAccount("PLAYER").get.muteTime == 80, "written once the database was back");
    assert(writer.statistics.refused == 0 && !writer.statistics.stalled);

    // A write made before the lease lapsed is never written, even when the lease holds again.
    atomicStore(flaky.failures, 1);
    db.setMuteTime(id, 81);
    writer.leaseLapsed(Clock.currStdTime + 10_000_000);
    writer.renewLease(Clock.currStdTime + 50_000_000);
    foreach (i; 0 .. 20)
    {
        if (writer.settled)
            break;
        Thread.sleep(50.msecs);
    }
    assert(inner.findAccount("PLAYER").get.muteTime == 80 && writer.statistics.refused == 1);
}
