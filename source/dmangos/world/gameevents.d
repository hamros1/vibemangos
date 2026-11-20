/**
 * Game events: the world's scheduled happenings (holidays, the Darkmoon Faire, fishing contests,
 * Call to Arms weekends, day and night).
 *
 * An event (`game_event`) is active in a repeating window: from its start, every `occurence` minutes,
 * for `length` minutes, until its end. How its start and end are found depends on its schedule type:
 *
 * $(UL
 *   $(LI 0: never by itself: the server's state starts it (`GameEvents.start`: the war effort's phases);)
 *   $(LI 1: the dates in `game_event_time`, as they are;)
 *   $(LI 2 and 3: a Darkmoon Faire week, Monday to Monday, the first whole week of every third month (2:
 *        January, April, July, October; 3: February, May, August, November);)
 *   $(LI 5 and 6, 8 and 9: the Faire being built: one day starting two (5, 6) or one (8, 9) days before
 *        the week of 2 or 3;)
 *   $(LI 11: those dates moved to this year (a holiday on the same days every year);)
 *   $(LI 12: Lunar New Year: three weeks from the day (in China, UTC+8) of the second new moon after
 *        21 December;)
 *   $(LI 13: Easter week this year (Noblegarden).)
 * )
 *
 * An event linked to another (`linkedTo`: the Wickerman's embers to Hallow's End) is active only
 * while that one is too.
 *
 * While an event is active, the creatures and game objects of `game_event_creature` and
 * `game_event_gameobject` listed with its id are in the world, and those listed with its negated id
 * are not; the creatures of `game_event_creature_data` listed with it take its entry, model, equipment
 * and auras. Every node of a cluster works the schedule out from the clock alone, so they agree; the
 * events the server's state starts, every node starts as it hears of that state (the war effort's, from
 * its service).
 */
module dmangos.world.gameevents;

import std.datetime : Date, DateTime, SysTime, UTC, LocalTime, dur;

/// `game_event.schedule_type`
enum ScheduleType : uint
{
    serverSide = 0,
    date = 1,
    faire1 = 2,
    faire2 = 3,
    faireBuilding1First = 5,
    faireBuilding1Second = 6,
    faireBuilding2First = 8,
    faireBuilding2Second = 9,
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

/// The time (Unix, UTC) of the `k`-th new moon from that of 6 January 2000: the mean lunation and its largest
/// periodic terms, to within minutes.
double newMoon(long k) pure nothrow @nogc @safe
{
    import std.math : PI, sin;

    const t = k / 1236.85;
    enum rad = PI / 180;
    const m = (2.5534 + 29.10535670 * k) * rad, mm = (201.5643 + 385.81693528 * k) * rad,
        f = (160.7108 + 390.67050284 * k) * rad, e = 1 - 0.002516 * t;
    double jd = 2_451_550.09766 + 29.530588861 * k + 0.00015437 * t * t;
    jd += -0.40720 * sin(mm) + 0.17241 * e * sin(m) + 0.01608 * sin(2 * mm) + 0.01039 * sin(2 * f)
        + 0.00739 * e * sin(mm - m) - 0.00514 * e * sin(mm + m) + 0.00208 * e * e * sin(2 * m)
        - 0.00111 * sin(mm - 2 * f) - 0.00057 * sin(mm + 2 * f) + 0.00056 * e * sin(2 * mm + m)
        - 0.00042 * sin(3 * mm);
    return (jd - 2_440_587.5) * 86_400;
}

/// The day of Lunar New Year in `year`: in China (UTC+8), the second new moon after 21 December before it.
Date lunarNewYear(int year) @safe
{
    const solstice = SysTime(DateTime(year - 1, 12, 21), UTC()).toUnixTime;
    long k = cast(long)((year - 1 - 2000) * 12.3685) - 2;
    while (newMoon(k) <= solstice)
        ++k;
    const china = cast(long) newMoon(k + 1) + 8 * 3600;
    return cast(Date) SysTime.fromUnixTime(china, UTC());
}

unittest
{
    assert(lunarNewYear(2024) == Date(2024, 2, 10) && lunarNewYear(2025) == Date(2025, 1, 29));
    assert(lunarNewYear(2026) == Date(2026, 2, 17) && lunarNewYear(2027) == Date(2027, 2, 6));
    assert(lunarNewYear(2023) == Date(2023, 1, 22));
}

/// The Monday of the first whole week of the Faire month for `schedule` from `today`'s month.
private Date faireMonday(ScheduleType schedule, Date today) pure @safe
{
    import core.time : days;
    import std.datetime : DayOfWeek, Month;

    const r = (today.month - 1) % 3;
    const ahead = schedule == ScheduleType.faire1 || schedule == ScheduleType.faireBuilding1First
        || schedule == ScheduleType.faireBuilding2First ? (3 - r) % 3 : (4 - r) % 3;
    auto first = Date(today.year, today.month, 1);
    first.add!"months"(ahead);
    while (first.dayOfWeek != DayOfWeek.mon)
        first += 1.days;
    return first;
}

unittest
{
    // November 2026: the second Faire's month; its first Monday is the 2nd. In December, the first Faire's
    // month is January 2027 (Monday the 4th).
    assert(faireMonday(ScheduleType.faire2, Date(2026, 11, 18)) == Date(2026, 11, 2));
    assert(faireMonday(ScheduleType.faire1, Date(2026, 12, 1)) == Date(2027, 1, 4));
    assert(faireMonday(ScheduleType.faire1, Date(2026, 11, 18)) == Date(2027, 1, 4));
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
    case ScheduleType.lunarNewYear:
    {
        const day = lunarNewYear(now.year);
        e.start = SysTime(DateTime(day), LocalTime()).toUnixTime;
        e.end = (SysTime(DateTime(day), LocalTime()) + dur!"days"(21)).toUnixTime;
        break;
    }
    case ScheduleType.faire1, ScheduleType.faire2, ScheduleType.faireBuilding1First,
            ScheduleType.faireBuilding1Second, ScheduleType.faireBuilding2First, ScheduleType.faireBuilding2Second:
    {
        const building = e.schedule != ScheduleType.faire1 && e.schedule != ScheduleType.faire2;
        auto monday = faireMonday(e.schedule, cast(Date) now);
        int before = e.schedule == ScheduleType.faireBuilding1First || e.schedule == ScheduleType.faireBuilding1Second
            ? 2 : building ? 1 : 0;
        const from = SysTime(DateTime(monday), LocalTime()) - dur!"days"(before);
        e.start = from.toUnixTime;
        e.end = (from + dur!"days"(building ? 1 : 7)).toUnixTime;
        break;
    }
    case ScheduleType.serverSide:
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
    private bool[ushort] started_; // started by the server's own state (the war effort): on whatever the clock says

    /**
     * Starts (or stops) event `id` by the server's state rather than the clock: a server-side event
     * (schedule type 0, the war effort's phases) is on only so. The next `update` starts or stops it.
     */
    void start(ushort id, bool on)
    {
        if (on)
            started_[id] = true;
        else
            started_.remove(id);
    }

    /// Whether event `id` is on because it was started (`start`), not by the clock.
    bool started(uint id) const
    {
        return id <= ushort.max && (cast(ushort) id in started_) !is null;
    }

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
            on = on || (id in started_) !is null;
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

// A server-side event: on only while started, whatever the clock.
unittest
{
    auto events = new GameEvents;
    auto e = GameEvent(120, ScheduleType.serverSide, 0, 0, 525_600, 1);
    events.events[120] = e;
    ushort[] started, stopped;
    events.update(5000, started, stopped);
    assert(!events.isActive(120));
    events.start(120, true);
    events.update(5000, started, stopped);
    assert(started == [120] && events.isActive(120) && events.started(120));
    events.start(120, false);
    events.update(5000, started, stopped);
    assert(stopped == [120] && !events.isActive(120));
}
