/**
 * Brute-force protection: an address that fails too many logins in a row is
 * blocked for a while.
 *
 * The time is passed in by the caller rather than read inside, so the unit
 * tests can control it.
 */
module dmangos.auth.throttle;

import core.time : Duration, MonoTime;

/// Failed-login bookkeeping, keyed by remote address.
struct LoginThrottle
{
    private struct Record
    {
        uint failures;
        MonoTime lastFailure;
        MonoTime blockedUntil;
    }

    private Record[string] records;
    private uint maxFailures;
    private Duration blockDuration;

    /// `maxFailures` = 0 disables the throttle.
    this(uint maxFailures, Duration blockDuration) pure nothrow @nogc @safe
    in (blockDuration >= Duration.zero, "block duration must not be negative")
    {
        this.maxFailures = maxFailures;
        this.blockDuration = blockDuration;
    }

    /// Whether failures are being counted at all.
    @property bool enabled() const pure nothrow @nogc @safe
    {
        return maxFailures > 0;
    }

    /// Number of addresses being tracked.
    @property size_t trackedAddresses() const pure nothrow @nogc @safe
    {
        return records.length;
    }

    /// Whether `address` is currently blocked.
    bool isBlocked(string address, MonoTime now) const
    {
        if (auto record = address in records)
            return record.blockedUntil > now;
        return false;
    }

    /// Counts a failed login. Reaching the limit blocks the address.
    void recordFailure(string address, MonoTime now)
    {
        if (!enabled)
            return;

        auto record = address in records;
        if (record is null)
        {
            records[address] = Record.init;
            record = address in records;
        }

        // Failures spread out over long periods do not add up.
        if (now - record.lastFailure > blockDuration)
            record.failures = 0;

        record.failures++;
        record.lastFailure = now;
        if (record.failures >= maxFailures)
        {
            record.blockedUntil = now + blockDuration;
            record.failures = 0;
        }
    }

    /// Forgets the address after a successful login.
    void recordSuccess(string address)
    {
        records.remove(address);
    }

    /// Drops records that no longer affect anything, so the table cannot grow without bound.
    void prune(MonoTime now)
    {
        string[] stale;
        foreach (address, ref record; records)
            if (record.blockedUntil <= now && now - record.lastFailure > blockDuration)
                stale ~= address;
        foreach (address; stale)
            records.remove(address);
    }
}

unittest
{
    import core.time : minutes, seconds;

    auto throttle = LoginThrottle(3, 10.minutes);
    const start = MonoTime.currTime;

    throttle.recordFailure("1.2.3.4", start);
    throttle.recordFailure("1.2.3.4", start + 1.seconds);
    assert(!throttle.isBlocked("1.2.3.4", start + 2.seconds));
    throttle.recordFailure("1.2.3.4", start + 2.seconds);
    assert(throttle.isBlocked("1.2.3.4", start + 3.seconds));
    assert(!throttle.isBlocked("5.6.7.8", start + 3.seconds));
    assert(!throttle.isBlocked("1.2.3.4", start + 2.seconds + 10.minutes + 1.seconds));

    // Failures far apart are forgiven.
    throttle.recordFailure("9.9.9.9", start);
    throttle.recordFailure("9.9.9.9", start + 11.minutes);
    throttle.recordFailure("9.9.9.9", start + 22.minutes);
    assert(!throttle.isBlocked("9.9.9.9", start + 22.minutes));

    // A success resets the count.
    throttle.recordFailure("8.8.8.8", start);
    throttle.recordFailure("8.8.8.8", start);
    throttle.recordSuccess("8.8.8.8");
    throttle.recordFailure("8.8.8.8", start);
    assert(!throttle.isBlocked("8.8.8.8", start));

    throttle.prune(start + 1.minutes);
    assert(throttle.trackedAddresses == 3); // 1.2.3.4 is blocked; 8.8.8.8 and 9.9.9.9 failed recently
    throttle.prune(start + 1000.minutes);
    assert(throttle.trackedAddresses == 0);
}

unittest
{
    import core.time : seconds;

    auto disabled = LoginThrottle(0, 1.seconds);
    const now = MonoTime.currTime;
    foreach (_; 0 .. 100)
        disabled.recordFailure("1.1.1.1", now);
    assert(!disabled.isBlocked("1.1.1.1", now));
}
