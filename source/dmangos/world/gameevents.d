/**
 * Game events: the world's scheduled happenings (holidays, the Darkmoon Faire, fishing contests,
 * Call to Arms weekends, day and night).
 *
 * An event (`game_event`) is active in a repeating window: from its start, every `occurence` minutes,
 * for `length` minutes, until its end. How its start and end are found depends on its schedule type:
 *
 * $(UL
 *   $(LI 0: never by itself (a script or a GM would start it);)
 *   $(LI 1: the dates in `game_event_time`, as they are;)
 *   $(LI 11: those dates moved to this year (a holiday on the same days every year);)
 *   $(LI 13: Easter week this year (Noblegarden).)
 * )
 * Lunar New Year (12) and the computed Darkmoon Faire weeks (2 to 9) are not scheduled yet: those
 * events stay inactive.
 *
 * An event linked to another (`linkedTo`: the Wickerman's embers to Hallow's End) is active only
 * while that one is too.
 *
 * While an event is active, the creatures and game objects of `game_event_creature` and
 * `game_event_gameobject` listed with its id are in the world, and those listed with its negated id
 * are not. Every node of a cluster works the schedule out from the clock alone, so they agree.
 */
module dmangos.world.gameevents;

import std.datetime : Date, DateTime, SysTime, UTC, LocalTime, dur;

/// `game_event.schedule_type`
enum ScheduleType : uint
{
    serverSide = 0,
    date = 1,
    yearly = 11,
    lunarNewYear = 12,
    easter = 13,
}

/// A row of `game_event`, with its window's start and end (Unix time; 0 end: never starts).
struct GameEvent
{
    ushort id;
    ScheduleType schedule;
    long start;          /// the first window's start
    long end;            /// no window after this
    uint occurence;      /// minutes from one window's start to the next
    uint length;         /// minutes a window lasts
    uint holiday;        /// the client's holiday id (`Holidays.dbc`), 0 for none
    string description;
    ushort linkedTo;     /// an event it belongs to: active only inside that one's windows

    /// Whether the event is active at `now` (Unix time).
    bool activeAt(long now) const pure nothrow @nogc @safe
    {
        if (occurence == 0 || length == 0 || occurence < length || !(start < now && now < end))
            return false;
        return (now - start) % (cast(long) occurence * 60) < cast(long) length * 60;
    }
}

unittest
{
    // Every day from noon for two hours, from 2020 to 2030.
    auto e = GameEvent(1, ScheduleType.date, 1_577_880_000, 1_924_948_800, 1440, 120);
    assert(e.activeAt(1_577_880_000 + 60) && !e.activeAt(1_577_880_000 + 3 * 3600));
    assert(e.activeAt(1_577_880_000 + 86_400 + 30 * 60), "the next day too");
    assert(!e.activeAt(1_924_948_800 + 60), "not after its end");
}

/// Easter Sunday of `year` (the anonymous Gregorian algorithm).
Date easterSunday(int year) pure @safe
{
    const a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3,
        h = (19 * a + b - d - g + 15) % 30, i = c / 4, k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7,
        m = (a + 11 * h + 22 * l) / 451;
    const month = (h + l - 7 * m + 114) / 31, day = (h + l - 7 * m + 114) % 31 + 1;
    return Date(year, month, day);
}

unittest
{
    assert(easterSunday(2026) == Date(2026, 4, 5) && easterSunday(2024) == Date(2024, 3, 31));
}

/**
 * The window of event `e` for the year `today` is in: a yearly event's dates moved to this year, Easter
 * week's this year's; others as they are.
 */
void scheduleFor(ref GameEvent e, long today)
{
    const now = SysTime.fromUnixTime(today, LocalTime());
    final switch (e.schedule)
    {
    case ScheduleType.yearly:
    {
        auto s = SysTime.fromUnixTime(e.start, LocalTime()), t = SysTime.fromUnixTime(e.end, LocalTime());
        s.year = now.year;
        t.year = now.year;
        e.start = s.toUnixTime;
        e.end = t.toUnixTime;
        break;
    }
    case ScheduleType.easter:
    {
        const sunday = easterSunday(now.year);
        e.start = SysTime(DateTime(sunday), LocalTime()).toUnixTime;
        e.end = (SysTime(DateTime(sunday), LocalTime()) + dur!"days"(7)).toUnixTime;
        break;
    }
    case ScheduleType.serverSide, ScheduleType.lunarNewYear:
        e.start = e.end = 0; // never by schedule
        break;
    case ScheduleType.date:
        break;
    }
}

/// The game events and which are active now.
final class GameEvents
{
    /// By id.
    GameEvent[ushort] events;
    private bool[ushort] active_;

    /// Whether event `id` is active (as of the last `update`).
    bool isActive(uint id) const
    {
        return id <= ushort.max && (cast(ushort) id in active_) !is null;
    }

    /// Whether an active event is of holiday `holiday`.
    bool holidayActive(uint holiday) const
    {
        foreach (id, _; active_)
            if (events[id].holiday == holiday)
                return true;
        return false;
    }

    /// The active events' ids.
    @property const(ushort)[] active() const
    {
        return active_.keys;
    }

    /// Works out which are active at `now`: returns those that started and those that stopped.
    void update(long now, out ushort[] started, out ushort[] stopped)
    {
        foreach (id, ref e; events)
        {
            bool on = e.activeAt(now);
            if (on && e.linkedTo)
                if (const parent = e.linkedTo in events)
                    on = parent.activeAt(now);
            const was = (id in active_) !is null;
            if (on && !was)
            {
                active_[id] = true;
                started ~= id;
            }
            else if (!on && was)
            {
                active_.remove(id);
                stopped ~= id;
            }
        }
    }

    /// Whether a spawn listed for event `event` (negative: listed to be away while it is on) is in the world.
    bool spawnIn(short event) const
    {
        if (event > 0)
            return isActive(event);
        if (event < 0)
            return !isActive(-cast(int) event);
        return true;
    }
}

unittest
{
    auto events = new GameEvents;
    events.events[7] = GameEvent(7, ScheduleType.date, 1000, 1_000_000, 10, 5, 335);
    ushort[] started, stopped;
    events.update(1000 + 60, started, stopped);
    assert(started == [7] && events.isActive(7) && events.holidayActive(335));
    assert(events.spawnIn(7) && !events.spawnIn(-7) && events.spawnIn(0));
    events.update(1000 + 6 * 60, started, stopped);
    assert(stopped == [7] && !events.isActive(7) && events.spawnIn(-7));

    // An event inside another: only while the other is on.
    events.events[8] = GameEvent(8, ScheduleType.date, 1000, 1_000_000, 1, 1, 0, "", 7);
    events.update(1000 + 6 * 60 + 30, started, stopped);
    assert(!events.isActive(8), "its parent is off");
    events.update(1000 + 10 * 60 + 30, started, stopped);
    assert(events.isActive(7) && events.isActive(8), "its parent is on");
}
