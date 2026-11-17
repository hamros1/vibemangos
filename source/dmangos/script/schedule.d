/**
 * Time in a script is data: a `Schedule` is a small fixed table of steps (members of the script's
 * own enum) due after so many milliseconds of the entity's simulation time, once or repeating. The
 * script's tick advances it, and each step that falls due is handed to the script's `on` for that
 * enum. Being plain data, a schedule is saved with the rest of the script (`dmangos.script.state`):
 * it survives a move to another node and a dungeon's save. Nothing here allocates.
 */
module dmangos.script.schedule;

import core.time : Duration;

/// See the module documentation. At most `capacity` steps are pending at once.
struct Schedule(E, size_t capacity = 8) if (is(E == enum))
{
    private static struct Entry
    {
        E step;
        bool used;
        int due;    // milliseconds from now
        int repeat; // 0: once
    }

    private Entry[capacity] entries;

    /// `step` once, `delay` from now (replacing a pending one). False if the table is full.
    bool after(E step, Duration delay)
    {
        return set(step, ms(delay), 0);
    }

    /// `step` every `period`, the first `first` from now (by default one period).
    bool every(E step, Duration period)
    {
        return set(step, ms(period), ms(period));
    }

    /// ditto
    bool every(E step, Duration first, Duration period)
    {
        return set(step, ms(first), ms(period));
    }

    /// `step` is not pending any more.
    void cancel(E step)
    {
        foreach (ref e; entries)
            if (e.used && e.step == step)
                e.used = false;
    }

    /// Nothing is pending any more.
    void clear()
    {
        foreach (ref e; entries)
            e.used = false;
    }

    /// Whether `step` is pending.
    bool pending(E step) const
    {
        foreach (ref e; entries)
            if (e.used && e.step == step)
                return true;
        return false;
    }

    /// Whether anything is pending.
    @property bool busy() const
    {
        foreach (ref e; entries)
            if (e.used)
                return true;
        return false;
    }

    /// Milliseconds until `step` is due; -1 if it is not pending.
    int remaining(E step) const
    {
        foreach (ref e; entries)
            if (e.used && e.step == step)
                return e.due > 0 ? e.due : 0;
        return -1;
    }

    /**
     * `elapsed` milliseconds pass: each step due is given to `due`, earliest first (a repeating step
     * comes back after its period; one due several times over a long pause runs once). Steps that
     * `due` schedules are counted from now.
     */
    void advance(int elapsed, scope void delegate(E step) due)
    {
        foreach (ref e; entries)
            if (e.used)
                e.due -= elapsed;
        // At most a few rounds: a step that schedules itself with no delay must not loop forever.
        foreach (_; 0 .. capacity * 2)
        {
            size_t next = size_t.max;
            foreach (i, ref e; entries)
                if (e.used && e.due <= 0 && (next == size_t.max || e.due < entries[next].due))
                    next = i;
            if (next == size_t.max)
                return;
            auto e = &entries[next];
            const step = e.step;
            if (e.repeat > 0)
            {
                e.due += e.repeat; // its rhythm kept; missed beats are not made up
                if (e.due <= 0)
                    e.due = e.repeat;
            }
            else
                e.used = false;
            due(step);
        }
    }

    private bool set(E step, int due, int repeat)
    {
        foreach (ref e; entries)
            if (e.used && e.step == step)
            {
                e.due = due;
                e.repeat = repeat;
                return true;
            }
        foreach (ref e; entries)
            if (!e.used)
            {
                e = Entry(step, true, due, repeat);
                return true;
            }
        return false;
    }

    private static int ms(Duration d)
    {
        const total = d.total!"msecs";
        return total > int.max ? int.max : total < 0 ? 0 : cast(int) total;
    }
}

unittest
{
    import core.time : msecs, seconds;

    enum Step { slam, stomp, yell }
    Schedule!(Step, 2) s;
    Step[] fired;
    void run(int ms)
    {
        s.advance(ms, (Step step) { fired ~= step; });
    }

    assert(!s.busy);
    assert(s.every(Step.slam, 2.seconds) && s.after(Step.stomp, 3.seconds));
    assert(!s.after(Step.yell, 1.seconds), "full");
    run(1999);
    assert(fired.length == 0);
    run(1);
    assert(fired == [Step.slam]);
    run(1000);
    assert(fired == [Step.slam, Step.stomp] && !s.pending(Step.stomp) && s.remaining(Step.slam) == 1000);
    run(10_000);
    assert(fired == [Step.slam, Step.stomp, Step.slam], "a long pause: once");

    // A step scheduling another at once: run in the same advance, not forever.
    s.clear();
    s.after(Step.yell, 0.msecs);
    s.advance(0, (Step step) {
        fired ~= step;
        if (step == Step.yell)
            s.after(Step.yell, 0.msecs);
    });
    assert(fired.length <= 3 + 4 && s.busy);
}
