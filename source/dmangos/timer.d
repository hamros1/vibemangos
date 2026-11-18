/**
 * A timer that fires every `interval` of the time fed to it. The update loop hands each
 * object the time since the last tick, and the object asks its timers
 * whether their period has come round.
 */
module dmangos.timer;

import core.time : Duration;

/// See the module documentation.
struct IntervalTimer
{
    Duration interval;  /// the period
    Duration elapsed;   /// time fed since the period last came round

    invariant (interval >= Duration.zero);

    /// Adds `delta`; true if a period has passed.
    bool update(Duration delta) pure nothrow @nogc @safe
    in (delta >= Duration.zero)
    {
        elapsed += delta;
        return elapsed >= interval;
    }

    /// Takes one period off if one has passed: true once per period, so a late tick catches up.
    bool consume() pure nothrow @nogc @safe
    {
        if (elapsed < interval)
            return false;
        elapsed -= interval;
        return true;
    }

    /// Takes every whole period off at once and returns the time they cover (what has
    /// passed, rounded down to a multiple of the interval).
    Duration takeAll() pure nothrow @nogc @safe
    {
        if (interval == Duration.zero)
        {
            auto all = elapsed;
            elapsed = Duration.zero;
            return all;
        }
        const periods = elapsed / interval;
        elapsed -= interval * periods;
        return interval * periods;
    }

    /// Starts the period again.
    void reset() pure nothrow @nogc @safe
    {
        elapsed = Duration.zero;
    }
}

unittest
{
    import core.time : msecs, seconds;

    auto timer = IntervalTimer(2.seconds);
    assert(!timer.update(1500.msecs) && !timer.consume());
    assert(timer.update(1500.msecs) && timer.consume() && !timer.consume() && timer.elapsed == 1.seconds);
    timer.update(5.seconds);
    assert(timer.takeAll() == 6.seconds && timer.elapsed == Duration.zero);
}
