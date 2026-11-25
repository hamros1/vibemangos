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
 * handovers) gives up once the writer has gone `Writer.stalledWaitMs` without finishing a write (a write held by a
 * lock counts from when it began, before the database reports anything), and later calls do not wait again until
 * the queue has emptied: however many reads and settles one game action makes, the game loop, and with it the
 * cluster's heartbeats and lease, stops for that long at most once per stall. A write the
 * database refuses outright is kept in a file beside the log (`failedPath`) and the writer goes on.
 *
 * Each queued write carries the time until which this node may write (its cluster lease, docs/CLUSTER.md);
 * the writer drops a write it reaches after that, and so does the replay. A standalone server
 * writes always. That time is on the writer's clock (`bootClock`): monotonic, so a step of the wall clock
 * (NTP, an operator) can neither stretch the lease nor let a fenced node's queued writes through, and the
 * same for every process of one boot of the machine, so the replay after a restart reads it too.
 *
 * Everything is generated from the interface (`std.typecons.AutoImplement`, as in `fencing.d`), so a
 * method added there is queued or waited for without anyone remembering to.
 */
module dmangos.world.writebehind;

import core.atomic : atomicLoad, atomicStore;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime;
import std.meta : AliasSeq, staticMap;
import std.traits : FunctionAttribute, functionAttributes, hasUDA, isArray, isDynamicArray, isFloatingPoint,
    isIntegral, isSomeChar, isStaticArray, OriginalType, Parameters, ParameterStorageClass,
    ParameterStorageClassTuple, ReturnType, Unqual;
import std.typecons : AutoImplement;

import dmangos.plaindata : decode, encode, isPlainData, layout;
import dmangos.log : error, info, warning;
import dmangos.world.database : DatabaseRead, DatabaseWrite, Replaces, WorldDatabase, WriteLedger;

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
        static if (!is(ReturnType!fun == void) || hasUDA!(fun, DatabaseRead))
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

// A crash before upgrading can leave aura writes in the old on-disk format.
private struct LegacyAuraRecord
{
    ulong caster;
    uint spell, stacks;
    int[3] amount, periodTimer;
    int maxDuration, remaining;
    uint effectMask;
}

private interface LegacyAuraWrites
{
    void saveAuras(uint player, const(LegacyAuraRecord)[] auras);
    void savePetAuras(uint pet, const(LegacyAuraRecord)[] auras);
}

private void replayLegacyAuras(alias fun)(WorldDatabase db, const(ubyte)[] bytes)
{
    import std.exception : enforce;
    import dmangos.world.database : AuraRecord;

    uint owner;
    LegacyAuraRecord[] old;
    decode(bytes, owner);
    decode(bytes, old);
    enforce(bytes.length == 0, "unexpected data after legacy aura records");
    AuraRecord[] rows;
    foreach (ref row; old)
        rows ~= AuraRecord(row.tupleof);
    __traits(getMember, db, __traits(identifier, fun))(owner, rows);
}

unittest
{
    import dmangos.world.database : AuraRecord;
    import dmangos.world.testclient : newDatabase;

    auto db = newDatabase();
    LegacyAuraRecord row;
    row.spell = 324;
    row.remaining = 20_000;
    ubyte[] bytes;
    uint owner = 7;
    auto rows = [row];
    encode(bytes, owner);
    encode(bytes, rows);
    bySignature[signature!(LegacyAuraWrites.saveAuras)].carryOut(db, bytes);
    bySignature[signature!(LegacyAuraWrites.savePetAuras)].carryOut(db, bytes);
    assert(db.loadAuras(7) == [AuraRecord(row.tupleof)]);
    assert(db.loadPetAuras(7) == db.loadAuras(7));
}

shared static this()
{
    Method[ulong] table;
    static foreach (fun; methods!())
        static if (isQueued!fun)
        {
            assert(signature!fun !in table, "two queued methods with one signature: " ~ __traits(identifier, fun));
            table[signature!fun] = Method(__traits(identifier, fun), &carryOut!fun);
        }
    static foreach (fun; AliasSeq!(LegacyAuraWrites.saveAuras, LegacyAuraWrites.savePetAuras))
        table[signature!fun] = Method(__traits(identifier, fun), &replayLegacyAuras!fun);
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

/**
 * The writer's clock, in hnsecs: the time since the machine booted, suspend included (Linux
 * `CLOCK_BOOTTIME`; elsewhere `MonoTime`). Unlike the wall clock it is never stepped, and every process of
 * one boot reads the same, so a deadline logged by one start is still a deadline for the next (`bootKey`).
 */
long bootClock() nothrow @nogc @safe
{
    import core.time : ClockType, MonoTimeImpl;

    version (linux)
        alias Boot = MonoTimeImpl!(ClockType.bootTime);
    else
        alias Boot = MonoTimeImpl!(ClockType.normal);
    return (Boot.currTime - Boot.init).total!"hnsecs";
}

/// Which boot of the machine this is (a hash of Linux's `boot_id`); 0: not known. Set once at start-up.
__gshared ulong bootKey;

shared static this()
{
    import std.file : readText;
    import std.string : strip;

    try
    {
        const id = readText("/proc/sys/kernel/random/boot_id").strip;
        ulong hash = 0xcbf29ce484222325;
        foreach (c; id)
        {
            hash ^= c;
            hash *= 0x100000001b3;
        }
        bootKey = id.length ? hash | 1 : 0;
    }
    catch (Exception)
        bootKey = 0; // unknown: a deadline logged before a restart is taken to have passed
}

/// One queued write.
struct Write
{
    ulong signature;          /// which method (`signature`)
    long writableUntil;       /// on the writer's clock (`bootClock`, hnsecs): not written after; 0: always
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
    fenced,  /// the lease lapsed before the write was committed: rolled back, and never written
}

/// Thrown in a write's transaction, just before its commit, when the lease that allowed the write has lapsed.
private final class LeaseLapsedAtCommit : Exception
{
    this()
    {
        super("the lease lapsed before the write was committed");
    }
}

/**
 * Carries out `w` on `db`, recording it in `ledger` (if any, and if `w` is numbered) in the same
 * transaction. Logs a failure.
 *
 * `lapsed` is asked in that transaction, after the write and just before its commit: if the lease that
 * allowed the write has lapsed by then (a statement waited on a lock, say, while the regions and the
 * accounts went to another node), the transaction is rolled back and the write is `Outcome.fenced`. A
 * write without a ledger is not in a transaction and is only checked before it is begun.
 */
private Outcome carryOutLogged(WorldDatabase db, WriteLedger ledger, uint stream, const ref Write w,
    scope bool delegate() lapsed = null)
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
            ledger.applying(stream, w.seq, { method.carryOut(db, w.args); }, {
                if (lapsed !is null && lapsed())
                    throw new LeaseLapsedAtCommit;
            });
        else
            method.carryOut(db, w.args);
        return Outcome.written;
    }
    catch (LeaseLapsedAtCommit)
        return Outcome.fenced;
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
    /**
     * How long `settle` waits for a writer that finishes no write (the database is away, or a write waits on a
     * lock) before it returns. The game loop, which carries the cluster's heartbeats and lease renewals, waits
     * that long at most once until the queue empties again: well under the cluster's failure timeout.
     */
    long stalledWaitMs = 300;
    /// How long one `settle` waits at most for a writer that is slow but still finishing writes.
    long slowWaitMs = 1_000;

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
        MonoTime progressAt;   // when the writer last took a batch or finished a write
        bool gaveUp;           // a `settle` gave up: the next ones do not wait until the queue empties
        // Set by the game loop, read by the writer's thread; both on `clock`.
        shared long leaseUntil; // the newest `writableUntil` given or renewed: the lease has held until at least then
        shared long lapsedAt;   // when the lease last lapsed: a write made before is never written
        long delegate() clock;  // `bootClock`, unless a test fakes it; set before the thread starts, then only read
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
     *
     * `clock` is the writer's clock (`now`), which the lease's times are on; null: `bootClock`.
     */
    this(WorldDatabase db, string logPath, bool started = true, uint stream = 0, long delegate() clock = null)
    {
        this.db = db;
        this.clock = clock !is null ? clock : () => bootClock();
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
        if (queue.length == 0 && inFlight == 0)
            progressAt = MonoTime.currTime; // an idle writer starts on it now
        queue ~= write;
        ++stats.queued;
        work.notify();
    }

    /**
     * Waits until everything queued so far is written or dropped. Returns false if the database refused
     * one of the writes meanwhile, or if the writer does not get through the queue: once it has finished no
     * write for `stalledWaitMs` (the database is away, or a write waits on a lock), or after `slowWaitMs`.
     * The game goes on; the writes wait, in order, and are written when the database is back. Once a
     * `settle` gave up, the next ones return false at once until the queue has emptied.
     */
    bool settle()
    {
        import core.time : msecs;

        lock.lock_nothrow();
        scope (exit)
            lock.unlock_nothrow();
        const failedBefore = stats.failed;
        const start = MonoTime.currTime;
        while (queue.length || inFlight)
        {
            const now = MonoTime.currTime;
            if (gaveUp || now - progressAt >= stalledWaitMs.msecs || now - start >= slowWaitMs.msecs)
            {
                gaveUp = true;
                return false;
            }
            finished.wait(20.msecs);
        }
        return stats.failed == failedBefore;
    }

    /// The writer's clock (`bootClock`, hnsecs), which `Write.writableUntil`, `renewLease` and `leaseLapsed` are on.
    @property long now()
    {
        return clock();
    }

    /**
     * The lease holds until `until` (on `now`), as the cluster renewed it: a write waiting for the
     * database may be written until then, though no newer write said so.
     */
    void renewLease(long until)
    {
        if (until > atomicLoad(leaseUntil))
            atomicStore(leaseUntil, until);
    }

    /// The lease lapsed at `at` (on `now`): no write made before it is written, even once the lease holds again.
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
                progressAt = MonoTime.currTime;
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
                    // Asked before the write is begun, and again in its transaction just before the commit.
                    bool lapsed()
                    {
                        return w.writableUntil && (clock() >= atomicLoad(leaseUntil)
                            || w.writableUntil <= atomicLoad(lapsedAt));
                    }

                    const outcome = lapsed() ? Outcome.fenced : carryOutLogged(db, ledger, stream, w, &lapsed);
                    if (outcome == Outcome.fenced)
                    {
                        count((ref s) { ++s.refused; progressAt = MonoTime.currTime; });
                        if (statistics.refused % 100 == 1)
                            warning!"fenced: this node's lease has lapsed, so a queued '%s' was not written"(
                                nameOf(w.signature));
                        break;
                    }
                    if (outcome == Outcome.written)
                    {
                        count((ref s) { ++s.written; s.stalled = false; progressAt = MonoTime.currTime; });
                        if (attempt > 1)
                            info!"the database is back: writing again"();
                        break;
                    }
                    if (outcome == Outcome.failed)
                    {
                        count((ref s) { ++s.failed; progressAt = MonoTime.currTime; });
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
                gaveUp = false;
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
                progressAt = MonoTime.currTime;
                if (queue.length == 0)
                    gaveUp = false;
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
                ledger.applying(stream, w.seq, {}, {});
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

private enum ubyte[8] logMagic = ['d', 'm', 'w', 'a', 'l', '0', '0', '3'];
private enum ubyte[8] logMagicWallClock = ['d', 'm', 'w', 'a', 'l', '0', '0', '2']; // deadlines on the wall clock
private enum ubyte[8] logMagicUnnumbered = ['d', 'm', 'w', 'a', 'l', '0', '0', '1']; // before writes were numbered

/*
 * The log: `logMagic`, then each write as its length (uint), the CRC-32 of the rest (uint), its
 * signature (ulong), its `writableUntil` (long, on `bootClock`), its number (ulong), the boot it was
 * logged in (`bootKey`, ulong) and its arguments. A write cut short, or whose CRC is wrong (the end of a
 * write the system did not finish), ends the log. The earlier formats have no boot, their `writableUntil`
 * being on the wall clock (`logMagicWallClock`), and the earliest no numbers either (`logMagicUnnumbered`).
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
        encode(body_, bootKey);
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

/**
 * The writes in the log at `path`, up to the first that is incomplete, their `writableUntil` on this boot's
 * `bootClock`: one logged in another boot (or one not known) has passed it, as no lease outlives a restart of
 * the machine. A log of the wall-clock format, from before an upgrade, is read against the wall clock.
 */
Write[] readLog(string path)
{
    import std.datetime.systime : Clock;
    import std.digest.crc : crc32Of;
    import std.file : exists, read;

    if (!exists(path))
        return null;
    const(ubyte)[] bytes = cast(const(ubyte)[]) read(path);
    if (bytes.length < logMagic.length)
        return null;
    const magic = bytes[0 .. logMagic.length];
    const booted = magic == logMagic[];
    const numbered = booted || magic == logMagicWallClock[];
    if (!numbered && magic != logMagicUnnumbered[])
        return null;
    bytes = bytes[logMagic.length .. $];
    const bootNow = bootClock();
    Write[] writes;
    while (bytes.length >= 8)
    {
        uint length, check;
        decode(bytes, length);
        decode(bytes, check);
        if (length < (booted ? 32 : numbered ? 24 : 16) || length > bytes.length)
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
        if (booted)
        {
            ulong boot;
            decode(rest, boot);
            if (w.writableUntil && w.writableUntil != long.max && (boot == 0 || boot != bootKey))
                w.writableUntil = 1; // another boot's: passed
        }
        else if (w.writableUntil && w.writableUntil != long.max)
        {
            const left = w.writableUntil - Clock.currStdTime;
            w.writableUntil = left > 0 ? bootNow + left : 1;
        }
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
        const now = bootClock();
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
                const outcome = carryOutLogged(db, ledger, stream, w,
                    () => w.writableUntil && bootClock() >= w.writableUntil);
                if (outcome == Outcome.written)
                    ++written;
                else if (outcome == Outcome.fenced)
                    ++expired;
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
    /// Until when this node may write (on the writer's clock, `Writer.now`), asked at each write; null: always.
    long delegate() writableUntil;

    /**
     * Reads (and the writes that cannot be queued) go to `reader`, in the game loop; queued writes go to
     * `writer`. `writableUntil` says until when this node may write (on `Writer.now`); null: always.
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

    // Pool choices use synchronous writes and do not depend on the queued character or respawn writes.
    override imported!"dmangos.world.database".CreaturePoolState[uint] loadCreaturePoolStates(uint realm)
    {
        return reader.loadCreaturePoolStates(realm);
    }

    override uint[] pendingLootCoinPlayers()
    {
        return reader.pendingLootCoinPlayers();
    }

    protected bool leaseStillHolds()
    {
        return writableUntil is null || writer.now < writableUntil();
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
    : "writer.settle(); " ~ (hasUDA!(fun, DatabaseWrite)
        ? "if (!leaseStillHolds()) return typeof(return).init; "
        : "") ~ "return reader." ~ __traits(identifier, fun) ~ "(args);";

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
    import dmangos.world.creature : CreatureSpawn;

    auto inner = newDatabase();
    auto writer = new Writer(inner, null);
    scope (exit)
        writer.stop();
    long until = bootClock() - 1; // already lapsed
    WorldDatabase db = new WriteBehind(inner, writer, () => until);
    const id = db.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 42);
    assert(db.findAccount("PLAYER").get.muteTime != 42);
    assert(writer.statistics.refused == 1);
    const spawn = CreatureSpawn.init;
    assert(db.createCreatureSpawn(spawn) == 0 && inner.creatureSpawnRows.length == 0);
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
    auto expired = Write(signature!(WorldDatabase.setMuteTime), bootClock() - 1, cast(immutable) args);
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
        shared int holdMs; // each call first waits this long, as a write held by a lock does
        uint code = 2013; // the connection lost

        this(MemoryWorldDatabase inner)
        {
            this.inner = inner;
        }

        void prepareLedger() {}
        ulong appliedUpTo(uint stream) { return inner.appliedUpTo(stream); }
        shared int commitHoldMs; // each transaction waits this long before its commit, as one held by a lock does

        void applying(uint stream, ulong seq, scope void delegate() work, scope void delegate() beforeCommit)
        {
            import core.thread : Thread;
            import core.time : msecs;

            // As a transaction would: what `beforeCommit` refuses is rolled back, so it never reaches `inner`.
            if (const hold = atomicLoad(commitHoldMs))
                Thread.sleep(hold.msecs);
            beforeCommit();
            inner.applying(stream, seq, work, () {});
        }

        protected void maybeFail()
        {
            import core.atomic : atomicOp;
            import core.thread : Thread;
            import core.time : msecs;

            if (const hold = atomicLoad(holdMs))
                Thread.sleep(hold.msecs);

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
    writer.stalledWaitMs = writer.slowWaitMs = 5_000; // 0.25 + 0.5 s of retries: settle waits them out
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
    long until = bootClock() + 5_000_000; // the lease, as the write is made: half a second more
    auto db = new WriteBehind(inner, writer, () => until);
    const id = inner.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 80);
    Thread.sleep(50.msecs);
    assert(!writer.settle(), "the database is away: settle does not wait for it");
    assert(writer.statistics.stalled);
    foreach (i; 0 .. 40) // the cluster renews the lease meanwhile
    {
        writer.renewLease(bootClock() + 5_000_000);
        if (inner.findAccount("PLAYER").get.muteTime == 80)
            break;
        Thread.sleep(100.msecs);
    }
    assert(inner.findAccount("PLAYER").get.muteTime == 80, "written once the database was back");
    assert(writer.statistics.refused == 0 && !writer.statistics.stalled);

    // A write made before the lease lapsed is never written, even when the lease holds again.
    atomicStore(flaky.failures, 1);
    db.setMuteTime(id, 81);
    writer.leaseLapsed(bootClock() + 10_000_000);
    writer.renewLease(bootClock() + 50_000_000);
    foreach (i; 0 .. 20)
    {
        if (writer.settled)
            break;
        Thread.sleep(50.msecs);
    }
    assert(inner.findAccount("PLAYER").get.muteTime == 80 && writer.statistics.refused == 1);
}

// A write held by a lock stops the game loop once, for `stalledWaitMs` from when the writer began it, however
// many settles (reads, handovers) follow; once the queue is written, settle waits for it again.
unittest
{
    import core.thread : Thread;
    import core.time : msecs, MonoTime;

    auto inner = newDatabase();
    auto flaky = new Flaky(inner);
    atomicStore(flaky.holdMs, 600);
    auto writer = new Writer(flaky, null);
    scope (exit)
        writer.stop();
    writer.stalledWaitMs = 200;
    WorldDatabase db = new WriteBehind(inner, writer, null);
    const id = inner.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 40);
    Thread.sleep(100.msecs); // the writer is held, though nothing has failed yet
    auto start = MonoTime.currTime;
    assert(!writer.settle(), "a held write is not waited for");
    assert(MonoTime.currTime - start < 400.msecs, "counted from when the writer began the write");
    assert(!writer.statistics.stalled, "nothing reported the database away yet");
    start = MonoTime.currTime;
    foreach (i; 0 .. 5)
    {
        assert(!writer.settle());
        db.findAccount("PLAYER"); // a read waits for the queue: not again
    }
    assert(MonoTime.currTime - start < 50.msecs, "the later settles do not wait again");
    atomicStore(flaky.holdMs, 0);
    foreach (i; 0 .. 50)
    {
        if (writer.settled)
            break;
        Thread.sleep(20.msecs);
    }
    db.setMuteTime(id, 41);
    assert(writer.settle(), "the queue emptied: settle waits again");
    assert(inner.findAccount("PLAYER").get.muteTime == 41);

    // A writer that keeps finishing writes, slowly, is waited for no longer than `slowWaitMs`.
    atomicStore(flaky.holdMs, 100);
    writer.slowWaitMs = 250;
    foreach (minutes; 50 .. 60)
        db.setMuteTime(id, minutes);
    start = MonoTime.currTime;
    assert(!writer.settle());
    assert(MonoTime.currTime - start < 450.msecs);
    atomicStore(flaky.holdMs, 0);
}

// The fence is on the writer's monotonic clock, not the wall clock: a lease that ran out there has run out
// whatever the wall clock reads (NTP stepped it back, say), and the writes queued under it are dropped.
unittest
{
    import core.atomic : atomicOp;

    auto inner = newDatabase();
    // Far beyond the wall clock's hnsecs: read against the wall clock, every deadline here is still ahead.
    shared long fake = long.max / 2;
    auto writer = new Writer(inner, null, false, 0, () => atomicLoad(fake)); // queues until started
    scope (exit)
        writer.stop();
    long until = atomicLoad(fake) + 5_000_000; // the lease, as the write is made: half a second more
    auto db = new WriteBehind(inner, writer, () => until);
    const id = inner.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 90);
    atomicOp!"+="(fake, 5_000_000); // the lease runs out before the writer reaches the write
    writer.start();
    writer.settle();
    assert(inner.findAccount("PLAYER").get.muteTime != 90, "a write reached after the lease ran out is dropped");
    assert(writer.statistics.refused == 1);

    // Renewed on the same clock, the lease lets writes through again.
    until = writer.now + 5_000_000;
    writer.renewLease(until);
    db.setMuteTime(id, 91);
    writer.settle();
    assert(inner.findAccount("PLAYER").get.muteTime == 91 && writer.statistics.refused == 1);
}

// A write held in its transaction (by a lock, say) while the lease lapses is rolled back at its commit. Checked
// only before it began, it would be written after the node's regions and accounts had gone to another node.
unittest
{
    auto inner = newDatabase();
    auto flaky = new Flaky(inner);
    atomicStore(flaky.commitHoldMs, 300);
    auto writer = new Writer(flaky, null);
    scope (exit)
        writer.stop();
    writer.stalledWaitMs = writer.slowWaitMs = 5_000;
    long until = writer.now + 1_000_000; // a tenth of a second of lease left as the write is made
    auto db = new WriteBehind(inner, writer, () => until);
    const id = inner.findAccount("PLAYER").get.id;
    db.setMuteTime(id, 70);
    assert(writer.settle());
    assert(inner.findAccount("PLAYER").get.muteTime != 70, "the lease lapsed before the commit: rolled back");
    assert(writer.statistics.refused == 1 && writer.statistics.written == 0 && inner.appliedUpTo(0) == 0);

    // Under a lease that holds through the commit, the same write is written.
    atomicStore(flaky.commitHoldMs, 0);
    until = writer.now + 50_000_000;
    writer.renewLease(until);
    db.setMuteTime(id, 71);
    assert(writer.settle());
    assert(inner.findAccount("PLAYER").get.muteTime == 71 && writer.statistics.written == 1);
}

// The log's deadlines are on the boot clock: a restart in the same boot keeps the lease's time left; a log
// from another boot of the machine (whose clock started again) has passed every deadline but "always".
unittest
{
    import std.file : exists, remove;

    const path = tempLog("boot");
    scope (exit)
        if (exists(path))
            remove(path);
    auto inner = newDatabase();
    const id = inner.findAccount("PLAYER").get.id;
    Write muteFor(long minutes, long until)
    {
        ubyte[] args;
        encode(args, id);
        encode(args, minutes);
        return Write(signature!(WorldDatabase.setMuteTime), until, cast(immutable) args);
    }

    appendToLog(path, [muteFor(1, 0), muteFor(2, bootClock() + 600_000_000)]); // a minute of lease left
    assert(replayLog(path, inner) == 2 && inner.findAccount("PLAYER").get.muteTime == 2, "the same boot: written");

    appendToLog(path, [muteFor(3, 0), muteFor(4, bootClock() + 600_000_000)]);
    const thisBoot = bootKey;
    bootKey = thisBoot ^ 2; // read as after the machine restarted
    scope (exit)
        bootKey = thisBoot;
    assert(replayLog(path, inner) == 1 && inner.findAccount("PLAYER").get.muteTime == 3,
        "another boot: the leased write is dropped");
}
