/**
 * The honor week and its standing formulas: once a week, on the maintenance
 * day, each finished week's honor becomes rank points.
 *
 * For each faction, the players with at least `min_honor_kills` honorable kills that week stand in
 * order of their honor. Their places, through the week's breakpoints (`standingScores`), give each the
 * rank points the week earns (`rankPointEarning`), and their rating becomes the old one decayed by a
 * fifth plus that (`decayedRankPoints`). Last week's place is the `honor_standing` column.
 *
 * A week is reckoned once and its earning counted once, so a restart cannot reckon one twice: the
 * weeks reckoned are those since the last maintenance (`saved_variables.NextMaintenanceDate` minus a
 * week), not those worked out from what rows are left, and the stored rating is the decayed one plus
 * the earning, once. Rows of weeks before last week are then folded into the stored
 * kill totals and deleted; last week's stay, for its fields. Online players load their honor again
 * after, so their old values are not saved over the new ones.
 */
module dmangos.world.honorweek;

import dmangos.world.honor;

/// The standing's breakpoints, as fractions of the list (the top place first).
private immutable float[14] breakpoints = [1.000, 0.858, 0.715, 0.587, 0.477, 0.377, 0.287, 0.207, 0.137, 0.077,
    0.037, 0.017, 0.007, 0.002];

/// What `standingScores` works out of a week's standing.
struct StandingScores
{
    uint[14] places;    /// the place (from 1) at each breakpoint
    float[15] honor;    /// the honor at each breakpoint
    float[15] points;   /// the rank points it earns
}

/// The breakpoints of a faction's week, its honors in order (most first).
StandingScores standingScores(const(float)[] honors) pure nothrow @safe
{
    import std.math : floor;

    StandingScores s;
    const n = honors.length;
    foreach (i, b; breakpoints)
        s.places[i] = cast(uint) floor(b * n + 0.5f);
    s.points[0] = 0;
    s.points[1] = 400;
    foreach (i; 2 .. 15)
        s.points[i] = (i - 1) * 1000;
    s.honor[0] = 0;
    foreach (i; 1 .. 14)
    {
        // The honor halfway between the breakpoint's place and the next.
        const place = s.places[i];
        if (place == 0 || place > n)
        {
            s.honor[i] = 0;
            continue;
        }
        const here = honors[place - 1];
        const next = place < n ? honors[place] : 0;
        s.honor[i] = (here + next) / 2;
    }
    s.honor[14] = s.honor[13] ? honors[0] : 0;
    return s;
}

/// The rank points `honor` earns in the week of `s`.
float rankPointEarning(const ref StandingScores s, float honor) pure nothrow @nogc @safe
{
    size_t i = 0;
    while (i < 14 && s.places[i] > 0 && s.honor[i] <= honor)
        ++i;
    if (i == 0)
        return 0;
    const span = s.honor[i] - s.honor[i - 1];
    if (span <= 0) // breakpoints that fell together (a short list): the lower one's points
        return s.points[i - 1];
    return (s.points[i] - s.points[i - 1]) * (honor - s.honor[i - 1]) / span + s.points[i - 1];
}

/// Last week's rank points, a fifth gone, the week's earning added.
float decayedRankPoints(float earning, float rankPoints) pure nothrow @nogc @safe
{
    import std.math : floor;

    const decay = floor(0.2f * rankPoints + 0.5f);
    float delta = earning - decay;
    if (delta < 0)
        delta /= 2;
    if (delta < -2500)
        delta = -2500;
    return rankPoints + delta;
}

unittest
{
    // Twenty players with 1000 to 20,000 honor: the top earns 13,000, the bottom little.
    float[] honors;
    foreach_reverse (i; 1 .. 21)
        honors ~= i * 1000.0f;
    const s = standingScores(honors);
    assert(s.places[0] == 20 && s.places[13] == 0, "the bottom of the list, and nobody in the top 0.2%");
    assert(rankPointEarning(s, 20_000) > rankPointEarning(s, 10_000) && rankPointEarning(s, 10_000) > rankPointEarning(s, 1000));
    // Earning nothing, a fifth of the points go (half of the loss); earning more than the decay, they grow.
    assert(decayedRankPoints(0, 10_000) == 9000);
    assert(decayedRankPoints(5000, 10_000) == 13_000);
    assert(decayedRankPoints(0, 60_000) == 57_500, "at most 2500 lost a week");
}

/// One player's week: honor, kills, side and rating.
struct HonorWeekEntry
{
    uint guid;
    float honor = 0;
    uint kills;
    ubyte race;
    float storedRating = 0;
}

/**
 * Reckons the finished weeks since the last maintenance, if the maintenance
 * day has come: rank points, last week's standing, old rows folded. Returns whether it ran.
 */
bool runHonorMaintenance(WorldContext context)
{
    import std.algorithm.sorting : sort;
    import dmangos.log : info;
    import dmangos.world.clientdata : Team;

    auto db = context.database;
    const today = honorToday();
    const thisWeek = lastMaintenanceDay(today, context.config.honorMaintenanceDay);
    const next = db.nextHonorMaintenance();
    if (next != 0 && dateOfHonorDay(next) > today)
        return false;
    // The weeks to reckon: from the last maintenance's week (or the oldest row's), to this week's start.
    uint from;
    if (next != 0)
        from = honorDayPlus(next, -7);
    else
    {
        const oldest = db.oldestHonorDay();
        from = thisWeek;
        if (oldest != 0)
            while (dateOfHonorDay(from) > dateOfHonorDay(oldest))
                from = honorDayPlus(from, -7);
    }
    size_t weeks, ranked;
    db.clearHonorStandings(); // last week's places, given below
    for (uint week = from; dateOfHonorDay(week) < dateOfHonorDay(thisWeek); week = honorDayPlus(week, 7))
    {
        ++weeks;
        const lastWeek = honorDayPlus(week, 7) == thisWeek;
        auto entries = db.honorWeek(week, honorDayPlus(week, 7));
        foreach (team; [Team.alliance, Team.horde])
        {
            HonorWeekEntry[] list;
            foreach (ref e; entries)
                if (e.kills >= context.config.minHonorKills && context.client.teamForRace(e.race) == team)
                    list ~= e;
            list.sort!((a, b) => cast(uint) a.honor > cast(uint) b.honor || (cast(uint) a.honor == cast(uint) b.honor
                && a.guid < b.guid));
            float[] honors;
            foreach (ref e; list)
                honors ~= cast(uint) e.honor; // read as whole points
            const scores = standingScores(honors);
            foreach (i, ref e; list)
            {
                const earning = rankPointEarning(scores, honors[i]);
                db.setHonorRating(e.guid, decayedRankPoints(earning, e.storedRating), cast(uint)(i + 1), lastWeek);
                ++ranked;
            }
        }
    }
    db.foldHonorPoints(honorDayPlus(thisWeek, -7));
    db.setNextHonorMaintenance(honorDayPlus(thisWeek, 7));
    context.settleWrites();
    context.honorMaintained();
    info!"honor: %s week(s) reckoned, %s standing place(s); the next maintenance is on %s"(weeks, ranked,
        dateOfHonorDay(honorDayPlus(thisWeek, 7)).toISOExtString);
    return true;
}

import dmangos.world.context : WorldContext;

// A week reckoned: rank points by standing, last week's places, old rows folded, run once.
unittest
{
    import dmangos.world.database : CharacterRecord, HonorPointRecord, HonorRecord;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.config.minHonorKills = 1;
    const today = honorToday();
    const thisWeek = lastMaintenanceDay(today, context.config.honorMaintenanceDay);
    const lastWeekDay = honorDayPlus(thisWeek, -3), olderDay = honorDayPlus(thisWeek, -10);
    void player(uint guid, ubyte race, uint day, uint kills, float honorEach)
    {
        CharacterRecord c;
        c.guid = guid;
        c.race = race;
        db.characterLists[1000 + guid] = [c];
        HonorRecord r;
        foreach (_; 0 .. kills)
            r.points ~= HonorPointRecord(4, 1, honorEach, day, 1);
        db.honorRows[guid] = r;
    }
    player(101, 1, lastWeekDay, 3, 100);   // a human: 300 last week
    player(102, 1, lastWeekDay, 1, 100);   // a human: 100 last week
    player(103, 2, olderDay, 2, 25);       // an orc: 50 the week before

    assert(runHonorMaintenance(context));
    const a = db.honorRows[101].columns, b = db.honorRows[102].columns, c = db.honorRows[103].columns;
    assert(a.storedRating > b.storedRating && b.storedRating >= 0 && c.storedRating > 0, "rank points earned");
    assert(a.standing == 1 && b.standing == 2 && c.standing == 0, "last week's places");
    assert(db.honorRows[103].points.length == 0 && c.storedHonorableKills == 2, "the older week folded");
    assert(db.honorRows[101].points.length == 3, "last week's rows kept, for its fields");
    assert(db.nextHonorMaintenance() == honorDayPlus(thisWeek, 7));
    const rated = a.storedRating;
    assert(!runHonorMaintenance(context), "once a week");
    assert(db.honorRows[101].columns.storedRating == rated, "and a week's earning counted once");
}
