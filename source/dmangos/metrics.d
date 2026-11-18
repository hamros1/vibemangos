/**
 * Measurements of the server's own performance: how long ticks take and what the garbage collector
 * does, so memory and scheduling work goes where the numbers point (docs/CLUSTER.md).
 *
 * Recording a tick never allocates: durations go into a fixed histogram of power-of-two buckets
 * (from 1 µs up), which is enough to read percentiles to within a factor of two.
 */
module dmangos.metrics;

import core.memory : GC;
import core.time : Duration, usecs;

/// Durations of a series of ticks.
struct TickStats
{
    enum bucketCount = 32; /// bucket i holds durations in [2^(i-1), 2^i) µs; bucket 0 is under 1 µs

    private
    {
        ulong count_;
        long totalUsecs;
        long maxUsecs;
        ulong[bucketCount] buckets;
    }

    /// Records one tick.
    void record(Duration took) pure nothrow @nogc @safe
    {
        const us = took.total!"usecs";
        ++count_;
        totalUsecs += us;
        if (us > maxUsecs)
            maxUsecs = us;
        ++buckets[bucketOf(us)];
    }

    /// Ticks recorded.
    @property ulong count() const pure nothrow @nogc @safe
    {
        return count_;
    }

    /// The mean tick; zero if none.
    @property Duration average() const pure nothrow @nogc @safe
    {
        return count_ ? usecs(totalUsecs / cast(long) count_) : Duration.zero;
    }

    /// The longest tick.
    @property Duration maximum() const pure nothrow @nogc @safe
    {
        return usecs(maxUsecs);
    }

    /**
     * An upper bound of the `fraction` percentile (0.99 for p99): the top of the bucket it falls
     * in, but no more than the maximum.
     */
    Duration percentile(double fraction) const pure nothrow @nogc @safe
    in (fraction > 0 && fraction <= 1)
    {
        if (count_ == 0)
            return Duration.zero;
        const wanted = cast(ulong)(fraction * count_ + 0.999_999);
        ulong seen;
        foreach (i, n; buckets)
        {
            seen += n;
            if (seen >= wanted)
            {
                const top = i == 0 ? 1 : 1L << i;
                return usecs(top < maxUsecs ? top : maxUsecs);
            }
        }
        return maximum;
    }

    /// Starts a new series.
    void reset() pure nothrow @nogc @safe
    {
        this = TickStats.init;
    }

    private static size_t bucketOf(long us) pure nothrow @nogc @safe
    {
        import core.bitop : bsr;

        if (us <= 0)
            return 0;
        const b = bsr(cast(ulong) us) + 1;
        return b < bucketCount ? b : bucketCount - 1;
    }
}

/// What the garbage collector has done so far (`GC.profileStats`, `GC.stats`).
struct GcSnapshot
{
    size_t collections;
    Duration totalPause;
    Duration maxPause;
    ulong allocated;    /// bytes allocated by this thread since start-up
    size_t usedHeap;
    size_t freeHeap;

    /// The collector's figures now.
    static GcSnapshot take() nothrow
    {
        const profile = GC.profileStats();
        const stats = GC.stats();
        return GcSnapshot(profile.numCollections, profile.totalPauseTime, profile.maxPauseTime,
            GC.allocatedInCurrentThread(), stats.usedSize, stats.freeSize);
    }
}

/// Tick and GC measurements over an interval, reported as one line.
struct ServerMetrics
{
    TickStats ticks;
    private GcSnapshot start;
    private bool started;

    /// Records a tick; the first one starts the interval (and reads the collector, which may lock).
    void recordTick(Duration took) nothrow
    {
        if (!started)
        {
            start = GcSnapshot.take();
            started = true;
        }
        ticks.record(took);
    }

    /**
     * The interval's summary, then a new interval. With `loop` (the event loop's busy time per
     * iteration, which includes packet handling the tick does not), that is reported too and reset.
     */
    string report(TickStats* loop = null)
    {
        import std.format : format;

        const now = GcSnapshot.take();
        const allocated = now.allocated - start.allocated;
        const perTick = ticks.count ? allocated / ticks.count : 0;
        const pauseInInterval = now.totalPause - start.totalPause;
        const text = format!("metrics: %s ticks, avg %.2f ms, p99 %.2f ms, max %.2f ms; gc: %s collections, "
            ~ "max pause %.2f ms (since start), pauses %.2f ms, %s KiB allocated (%s B/tick), heap %.1f MiB used")(
            ticks.count, ms(ticks.average), ms(ticks.percentile(0.99)), ms(ticks.maximum),
            now.collections - start.collections, ms(now.maxPause), ms(pauseInInterval), allocated / 1024, perTick,
            now.usedHeap / (1024.0 * 1024.0));
        ticks.reset();
        start = now;
        if (loop is null)
            return text;
        const loopText = format!"; loop: %s iterations, busy avg %.3f ms, p99 %.2f ms, max %.2f ms"(loop.count,
            ms(loop.average), ms(loop.percentile(0.99)), ms(loop.maximum));
        loop.reset();
        return text ~ loopText;
    }

    private static double ms(Duration d) pure nothrow @nogc @safe
    {
        return d.total!"usecs" / 1000.0;
    }
}

unittest
{
    import core.time : msecs;

    TickStats stats;
    assert(stats.average == Duration.zero && stats.percentile(0.99) == Duration.zero);
    foreach (_; 0 .. 98)
        stats.record(100.usecs);
    stats.record(3.msecs);
    stats.record(10.msecs);
    assert(stats.count == 100 && stats.maximum == 10.msecs);
    assert(stats.average == usecs((98 * 100 + 3000 + 10_000) / 100));
    assert(stats.percentile(0.5) == 128.usecs, "100 µs falls in [64, 128)");
    assert(stats.percentile(0.99) == 4096.usecs, "the 99th tick is the 3 ms one");
    assert(stats.percentile(1) == 10.msecs, "capped by the maximum");
    stats.reset();
    assert(stats.count == 0);

    // A report reads the collector and starts a new interval.
    ServerMetrics metrics;
    metrics.recordTick(1.msecs);
    auto line = metrics.report();
    assert(line.length > 0 && metrics.ticks.count == 0);
}
