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

import core.time : Duration, minutes, MonoTime, msecs, seconds;
import dmangos.world.creature : Creature, CreatureParts, CreatureSpawn, CreatureTemplate, Npc, NpcStandIn, TempSpawn, TempSpawnType, VirtualItem;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType, GoLootState;
import dmangos.world.worldpvp : WorldPvp, WorldPvpFollower, WorldPvpHost;
import dmangos.world.map : Inhabitant, Map, MapObject, MapSettings, VisibilityFacts;
import dmangos.world.worlddata : EventCreature, EventMail, PoolMember, Ship, SpawnGroupCondition, SpellListEntry, WorldData;
import dmangos.world.context : WorldContext;

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

/**
 * The game events as this node keeps them (`WorldContext.calendar`): which are on, checked once a minute and worked
 * out again each day; the spawns and objects that come and go with them; the letters an event sends; what was on
 * across a restart (`game_event_status`).
 */
final class EventCalendar
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// The game events, and which are active (`dmangos.world.gameevents`).
    GameEvents gameEvents;

    package MonoTime gameEventsChecked;

    package long scheduledDay; // the day the events' dates were last worked out for

    /// Whether creature spawn `guid` is in the world as its game event (if any) stands.
    bool creatureInEvents(uint guid)
    {
        if (world.invasionHere.invasionLayout !is null)
            if (const site = guid in world.invasionHere.invasionLayout.creatures)
                if (!site.present(world.invasionHere.invasion)) return false;
        if (const e = guid in world.data.creatureGameEvents)
            return gameEvents.spawnIn(*e);
        return true;
    }

    /// Whether game object spawn `guid` is in the world as its game event (if any) stands, or as the war
    /// effort does (its piles of supplies).
    bool gameObjectInEvents(uint guid)
    {
        import dmangos.world.wareffort : isSupplyPile;

        if (world.invasionHere.invasionLayout !is null)
            if (const site = guid in world.invasionHere.invasionLayout.objects)
                if (!site.present(world.invasionHere.invasion)) return false;
        if (isSupplyPile(guid))
            return world.warEffortHere.warEffort.pileUp(guid);
        if (WorldPvp.follows(guid))
            return world.worldPvp.state.spawnUp(guid);
        if (const e = guid in world.data.gameObjectGameEvents)
            return gameEvents.spawnIn(*e);
        return true;
    }

    package bool eventActivatesObject(uint guid)
    {
        return WorldPvp.follows(guid) || (world.invasionHere.invasionLayout !is null && guid in world.invasionHere.invasionLayout.objects
            && world.invasionHere.invasionLayout.objects[guid].present(world.invasionHere.invasion));
    }

    /// The events made active and inactive by the clock; their spawns come and go in the loaded cells.
    package void updateGameEvents(MonoTime now, bool force = false)
    {
        import core.time : seconds;
        import dmangos.log : info;

        if (!force && gameEventsChecked != MonoTime.init && now - gameEventsChecked < 10.seconds)
            return;
        gameEventsChecked = now;
        // Yearly and Easter dates move to the new year once it comes.
        const day = world.unixTime / 86_400;
        if (day != scheduledDay)
        {
            scheduledDay = day;
            foreach (e; world.data.gameEvents)
            {
                scheduleFor(e, world.unixTime);
                gameEvents.events[e.id] = e;
            }
        }
        ushort[] started, stopped;
        gameEvents.update(world.unixTime, started, stopped);
        foreach (id; started)
            info!"game event %s (%s) starts"(id, gameEvents.events[id].description);
        foreach (id; stopped)
            info!"game event %s (%s) ends"(id, gameEvents.events[id].description);

        if (started.length || stopped.length)
            gameEventSpawnsChanged();
    }

    package bool eventStatusRead;

    package bool[ushort] eventsOnBefore; /// `game_event_status`: what was on when last looked (across restarts)

    /**
     * A game event's letters (`game_event_mail`): as it starts, and (negative rows) as it ends, compared with
     * what `game_event_status` says was on, so a restart sends nothing for an event already on; one that
     * ended while the server was down sends its ending letters when it comes back up.
     */
    package void eventMails()
    {
        if (!eventStatusRead)
        {
            eventStatusRead = true;
            foreach (id; world.database.gameEventStatus())
                eventsOnBefore[id] = true;
        }
        foreach (id, ref e; gameEvents.events)
        {
            const on = gameEvents.isActive(id);
            const was = (id in eventsOnBefore) !is null;
            if (on == was)
                continue;
            if (on)
                eventsOnBefore[id] = true;
            else
                eventsOnBefore.remove(id);
            world.database.setGameEventStatus(id, on);
            foreach (ref m; world.data.gameEventMails.get(on ? cast(short) id : cast(short)(-cast(int) id), null))
                foreach (guid; world.database.charactersFor(m.raceMask, m.quest))
                    world.templateLetter(m.mailTemplate, m.sender, guid);
        }
    }

    /// After events changed: in every loaded map, spawns now away go, and spawns now in come (where their cells are loaded).
    package void gameEventSpawnsChanged()
    {
        import dmangos.world.grid : cellKeyAt;

        void refresh(Map m)
        {
            // Those to go; and those an event changes (or changed), alive and out of a fight, to be made again.
            ulong[] gone;
            const(CreatureSpawn)*[] remade;
            m.forEachObject((MapObject o) {
                if (auto c = cast(Creature) o)
                {
                    if (!creatureInEvents(c.spawnId) || (world.invasionHere.invasionLayout !is null && c.summon.type != TempSpawnType.none
                        && !world.invasionHere.invasionLayout.actorPresent(c.template_.entry, c.spawn, world.invasionHere.invasion)))
                        gone ~= c.guid;
                    else if (c.spawnId in world.data.eventCreatures && !c.petOwner && c.summon.type == TempSpawnType.none
                            && c.alive && (c.ai is null || !c.ai.inCombat) && world.eventShapeOf(c.spawnId) != c.eventShape)
                        if (const spawn = world.creatureSpawnOf(c.spawnId))
                        {
                            gone ~= c.guid;
                            remade ~= spawn;
                        }
                }
                else if (auto go = cast(GameObject) o)
                    if ((eventObject(go.spawn.guid) && !gameObjectInEvents(go.spawn.guid)) ||
                        (world.invasionHere.invasionLayout !is null && go.template_.entry == 181142 &&
                         !world.invasionHere.invasionLayout.actorPresent(16230, go.spawn, world.invasionHere.invasion)))
                        gone ~= go.guid;
            });
            foreach (guid; gone)
                m.removeObject(guid);
            foreach (spawn; remade)
                if (auto c = world.makeCreature(spawn))
                {
                    c.instanceId = m.instanceId;
                    m.addObject(c);
                }
            // Those to come, in loaded cells.
            bool[ulong] present;
            m.forEachObject((MapObject o) { present[o.guid] = true; });
            if (auto cells = m.id in world.data.creatureCells)
                foreach (key, indexes; *cells)
                    if (m.cellLoaded(key))
                        foreach (index; indexes)
                        {
                            const spawn = &world.data.creatureSpawns[index];
                            if (spawn.guid !in world.data.creatureGameEvents || !creatureInEvents(spawn.guid)
                                    || !world.dungeons.groupSpawnAllowed(m, 0, spawn.guid) || !world.upInPool(PoolMember.Kind.creature, spawn.guid))
                                continue;
                            if (world.awaitingRespawn(spawn.guid) || world.loans.creatureOnLoan(spawn.guid))
                                continue;
                            auto c = world.makeCreature(spawn);
                            if (c is null || c.guid in present)
                                continue;
                            c.instanceId = m.instanceId;
                            m.addObject(c);
                        }
            if (auto cells = m.id in world.data.gameObjectCells)
                foreach (key, indexes; *cells)
                    if (m.cellLoaded(key))
                        foreach (index; indexes)
                        {
                            const spawn = &world.data.gameObjectSpawns[index];
                            if (!eventObject(spawn.guid) || !gameObjectInEvents(spawn.guid)
                                || (spawn.respawnSeconds < 0 && !eventActivatesObject(spawn.guid))
                                || !world.upInPool(PoolMember.Kind.gameObject, spawn.guid))
                                continue;
                            auto go = world.makeGameObject(*spawn);
                            if (go.guid in present)
                                continue;
                            go.instanceId = m.instanceId;
                            m.addObject(go);
                        }
        }
        foreach (m; world.maps.values)
            refresh(m);
        foreach (m; world.dungeons.instanceMaps.values)
            refresh(m);
    }

    /// Whether game object spawn `guid` comes and goes as the events (or the war effort) say.
    package bool eventObject(uint guid)
    {
        import dmangos.world.wareffort : isSupplyPile;

        return (guid in world.data.gameObjectGameEvents) !is null || isSupplyPile(guid) || WorldPvp.follows(guid);
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
