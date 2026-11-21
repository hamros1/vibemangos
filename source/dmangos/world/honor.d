/**
 * Honor: points for kills, ranks from rank points, and the fields the client shows them in.
 *
 * $(UL
 *   $(LI A kill of an enemy player who is not grey to the killer gives honor (`honorableKillPoints`):
 *        more for a higher-ranked victim and at a higher level, a tenth less for each kill of the same one
 *        that day (none from the eleventh), shared in a group. A civilian creature of the other side
 *        (flagged for PvP) costs rank points (`dishonorableKillPoints`); a racial leader gives 398 to each.
 *        The rules and their sources: docs/FORMULAS.md, "Honor".)
 *   $(LI Each gain is a `character_honor_cp` row of the day. Today's, yesterday's, this week's and last
 *        week's kills and honor are counted from the rows (`updateHonor`); the weekly maintenance
 *        (`dmangos.world.honorweek`) turns a week's honor into rank points, gives last week's standing,
 *        and folds old rows into the stored totals.)
 *   $(LI The rank (Private/Scout 1 to Grand Marshal/High Warlord 14) comes from the rank points.)
 * )
 *
 * A day is `(year - 1900) << 16 | day of the year` in the server's local time (the `date`
 * column). Arithmetic on days goes through the calendar, since arithmetic on the number itself
 * (`date - 7`) goes wrong across a new year.
 */
module dmangos.world.honor;

import std.datetime.date : Date, DayOfWeek;
import dmangos.world.movement : Position;

// ---------------------------------------------------------------------------------------------------
// Days
// ---------------------------------------------------------------------------------------------------

/// A day as the `date` column holds it.
uint honorDay(Date d) pure nothrow @safe
{
    return cast(uint)((d.year - 1900) << 16 | (d.dayOfYear - 1));
}

/// ditto, back.
Date dateOfHonorDay(uint day) pure @safe
{
    auto d = Date(cast(int)((day >> 16) + 1900), 1, 1);
    return d + (cast(int)(day & 0xFFFF)).days;
}

/// `day` moved by `n` days, across a new year too.
uint honorDayPlus(uint day, int n) pure @safe
{
    return honorDay(dateOfHonorDay(day) + n.days);
}

/// The last `maintenanceDay` (0 Sunday) on or before `today`.
uint lastMaintenanceDay(Date today, uint maintenanceDay) pure @safe
{
    const back = (cast(int) today.dayOfWeek - cast(int) maintenanceDay + 7) % 7;
    return honorDay(today - back.days);
}

/// Today, in the server's local time.
Date honorToday() @safe
{
    import std.datetime.systime : Clock;

    return cast(Date) Clock.currTime;
}

private auto days(int n) pure nothrow @nogc @safe
{
    import core.time : dur;

    return dur!"days"(n);
}

unittest
{
    const newYear = Date(2026, 1, 2);
    assert(dateOfHonorDay(honorDay(newYear)) == newYear);
    assert(honorDayPlus(honorDay(newYear), -7) == honorDay(Date(2025, 12, 26)), "across the new year");
    // 2026-11-18 is a Wednesday (3): the maintenance day of a Wednesday is that day, of a Thursday the week before.
    assert(lastMaintenanceDay(Date(2026, 11, 18), 3) == honorDay(Date(2026, 11, 18)));
    assert(lastMaintenanceDay(Date(2026, 11, 18), 4) == honorDay(Date(2026, 11, 12)));
}

// ---------------------------------------------------------------------------------------------------
// Ranks
// ---------------------------------------------------------------------------------------------------

/// An internal rank (0 none, 1 to 4 negative, 5 to 18 the titles) and what it spans.
struct HonorRank
{
    ubyte rank;
    byte visualRank;     /// -4 to 14: what the client and the titles count
    float maxRP = 2000;
    float minRP = 0;
    bool positive = true;
}

/// What the killer needs to award honor, including when the victim died on another node.
struct HonorVictim
{
    ulong guid;
    uint level;
    ubyte race, rank;
    byte visualRank;
    bool honorless;
    Position position;
}

/// What an internal rank spans. (Rank 1's bar runs from 0 to 2000, not backwards from a minimum
/// of 2000 to a maximum of 0.)
HonorRank rankInfo(ubyte rank, bool positive = true) pure nothrow @nogc @safe
{
    HonorRank r;
    if (rank == 0)
        return r;
    r.rank = rank;
    r.positive = positive;
    const steps = positive ? rank - 5 : rank - 4;
    r.maxRP = (steps < 0 ? -steps : steps) * 5000;
    r.minRP = r.maxRP > 5000 ? r.maxRP - 5000 : 2000;
    if (positive && rank == 5)
    {
        r.minRP = 0;
        r.maxRP = 2000;
    }
    r.visualRank = cast(byte)(rank > 4 ? rank - 4 : -cast(int) rank);
    return r;
}

/// The rank of `rankPoints`.
HonorRank rankOf(float rankPoints) pure nothrow @nogc @safe
{
    if (rankPoints == 0)
        return HonorRank.init;
    if (rankPoints > 0)
    {
        ubyte rank;
        if (rankPoints < 2000)
            rank = 5;
        else if (rankPoints > 60_000)
            rank = 18;
        else
            rank = cast(ubyte)(cast(int)(rankPoints / 5000) + 5 + 1);
        return rankInfo(rank, true);
    }
    const lost = -rankPoints;
    ubyte rank;
    if (lost < 2000)
        rank = 4;
    else if (lost > 15_000)
        rank = 1;
    else
        rank = cast(ubyte)(4 - (cast(int)(lost / 5000) + 1));
    return rankInfo(rank, false);
}

/// The rank bar: how far into its rank (0 to 255; negative ranks fill the other way).
byte rankBar(float rankPoints, const HonorRank rank) pure nothrow @nogc @safe
{
    const rp = rankPoints < 0 ? -rankPoints : rankPoints;
    if (rank.maxRP <= rank.minRP)
        return 0;
    const fraction = (rp - rank.minRP) / (rank.maxRP - rank.minRP);
    const bar = cast(int)(fraction * (rank.positive ? 255 : -255));
    return cast(byte) bar;
}

unittest
{
    assert(rankOf(0).rank == 0 && rankOf(1500).rank == 5 && rankOf(1500).visualRank == 1);
    assert(rankOf(2000).rank == 6 && rankOf(4999).rank == 6 && rankOf(5000).rank == 7);
    assert(rankOf(60_001).rank == 18 && rankOf(60_001).visualRank == 14);
    assert(rankOf(-1000).rank == 4 && rankOf(-1000).visualRank == -4 && rankOf(-16_000).rank == 1);
    const r = rankOf(3500);
    assert(r.minRP == 2000 && r.maxRP == 5000 && rankBar(3500, r) == 127);
}

// ---------------------------------------------------------------------------------------------------
// Points for kills
// ---------------------------------------------------------------------------------------------------

/// Whether a gain is honor, or rank points lost for a dishonorable kill.
enum HonorType : ubyte
{
    honorable = 1,
    dishonorable = 2,
}

/**
 * The honor of an honorable kill at level 60 by the victim's rank (1 Private/Scout to 14 Grand Marshal/High Warlord):
 * Wowpedia "Honor system (pre-2.0 formulas)", "CP for Kill (1.8+)". A victim of no rank counts as rank 1 (no
 * source gives one).
 */
private immutable float[14] killHonorByRank = [198, 210, 221, 233, 246, 260, 274, 289, 305, 321, 339, 357, 377, 398];

/**
 * The honor a rank-1 kill gives at the top of each battleground bracket (Wowpedia "Honor system (pre-2.0
 * formulas)": "The BHU is determined by the CP that would be awarded to the highest level in the range, if they made
 * an honorable kill on a Rank 1 target"): 24 at 19, 41 at 29, 68 at 39, 113 at 49, 189 at 59, 198 at 60.
 */
private immutable uint[2][6] rankOneHonor = [[19, 24], [29, 41], [39, 68], [49, 113], [59, 189], [60, 198]];

/**
 * The honor of a kill of a rank-1 player of one's own level, at `level`: the documented values at the brackets' tops,
 * between them by the same ratio a level (each ten levels are about 0.6 of the next, so between the points the
 * honor grows geometrically); below 19 by the ratio of 19 to 29.
 */
float rankOneHonorAt(uint level) pure nothrow @nogc @safe
{
    import std.math : pow;

    if (level >= 60)
        return 198;
    size_t i = 1;
    while (i + 1 < rankOneHonor.length && rankOneHonor[i][0] < level)
        ++i;
    const lo = rankOneHonor[i - 1], hi = rankOneHonor[i];
    const perLevel = pow(cast(float) hi[1] / lo[1], 1.0f / (hi[0] - lo[0]));
    return hi[1] * pow(perLevel, -cast(float)(hi[0] - cast(int) level));
}

/**
 * The honor of a kill of a player of `victimLevel` and visual rank `victimVisualRank` by one of `killerLevel`, who
 * has killed it `killsToday` times today before, shared among `groupSize`.
 *
 * The rank's honor at 60 (`killHonorByRank`), scaled to the killer's level as the battleground bonus shows it
 * (`rankOneHonorAt`), less a tenth for each kill of the same victim that day (Wowpedia: "Within a 24 hour period you
 * will only get credit for 10 HKs against a given player", 100% down to 10%), shared equally ("The CP per HK are
 * divided among all the groups that caused damage"; the group's members alike). Between levels, no source gives
 * the rule: the victim's level over the killer's is CMaNGOS's (docs/FORMULAS.md, "Honor").
 */
float honorableKillPoints(uint killerLevel, uint victimLevel, int victimVisualRank, uint killsToday,
    uint groupSize) pure nothrow @nogc @safe
{
    import std.math : round;

    if (killsToday >= 10 || killerLevel == 0)
        return 0;
    const rank = victimVisualRank < 1 ? 1 : victimVisualRank > 14 ? 14 : victimVisualRank;
    const full = round(killHonorByRank[rank - 1] * rankOneHonorAt(killerLevel) / 198
        * victimLevel / killerLevel);
    return full * (10 - killsToday) / 10 / (groupSize ? groupSize : 1);
}

/**
 * The rank points a dishonorable kill costs at `level`: Wowpedia "Honor system (pre-2.0 formulas)", "Dishonorable
 * Kills" (10 to 29, then by level to 100 at 60; "accurate to +/-1 RP").
 */
float dishonorableKillPoints(uint level) pure nothrow @nogc @safe
{
    static immutable float[31] from30 = [11.5, 13.0, 14.5, 16.0, 17.5, 19.0, 21.0, 23.0, 25.0, 27.0, 29.0, 31.0, 34.2,
        37.4, 40.7, 43.9, 47.1, 50.3, 53.6, 56.8, 60.0, 64.0, 68.0, 72.0, 76.0, 80.0, 84.0, 88.0, 92.0, 96.0, 100.0];
    if (level < 30)
        return 10;
    return level - 30 < from30.length ? from30[level - 30] : 100;
}

/// A racial leader's kill (`RacialLeader` creatures), to each who earns it.
enum float racialLeaderHonor = 398;

unittest
{
    // Level 60 on level 60: the rank's honor; rank 0 as rank 1.
    assert(honorableKillPoints(60, 60, 1, 0, 1) == 198 && honorableKillPoints(60, 60, 14, 0, 1) == 398);
    assert(honorableKillPoints(60, 60, 0, 0, 1) == 198);
    assert(honorableKillPoints(60, 60, 1, 0, 2) == 99, "shared");
    assert(honorableKillPoints(60, 60, 1, 9, 1) == 19.8f && honorableKillPoints(60, 60, 1, 10, 1) == 0,
        "the tenth kill of one victim in a day is worth a tenth, the eleventh nothing");
    // The brackets' tops (the battleground bonus unit), and between.
    foreach (p; rankOneHonor)
        assert(honorableKillPoints(p[0], p[0], 1, 0, 1) == p[1]);
    assert(rankOneHonorAt(54) > 113 && rankOneHonorAt(54) < 189 && rankOneHonorAt(10) < 24 && rankOneHonorAt(10) > 0);
    assert(dishonorableKillPoints(20) == 10 && dishonorableKillPoints(42) == 34.2f && dishonorableKillPoints(50) == 60
        && dishonorableKillPoints(55) == 80 && dishonorableKillPoints(60) == 100);
}

// ---------------------------------------------------------------------------------------------------
// The player's side
// ---------------------------------------------------------------------------------------------------

/// A gain of honor in memory (a `character_honor_cp` row), with whether it is in the database yet.
struct HonorPoint
{
    import dmangos.world.database : HonorPointRecord;

    HonorPointRecord record;
    bool saved;

    /// Whether the gain is a kill of a creature or a player (not honor from elsewhere).
    @property bool isKill() const pure nothrow @nogc @safe
    {
        return record.victimType == 3 || record.victimType == 4;
    }
}

/// C's `atol`: an optional sign and the digits after any spaces; 0 if none.
long arcEmuAtol(string text) pure nothrow @safe
{
    size_t i;
    while (i < text.length && (text[i] == ' ' || text[i] == '\t'))
        ++i;
    bool negative;
    if (i < text.length && (text[i] == '-' || text[i] == '+'))
        negative = text[i++] == '-';
    long value;
    while (i < text.length && text[i] >= '0' && text[i] <= '9')
        value = value * 10 + (text[i++] - '0');
    return negative ? -value : value;
}

unittest
{
    assert(arcEmuAtol("") == 0 && arcEmuAtol(" 42 more") == 42 && arcEmuAtol("-5") == -5 && arcEmuAtol("x1") == 0);
}

/// What `HonorHandlers.updateHonor` counts from the rows.
struct HonorTally
{
    uint todayKills, todayDishonorable, yesterdayKills, thisWeekKills, lastWeekKills;
    float yesterdayHonor = 0, thisWeekHonor = 0, lastWeekHonor = 0;
    uint lifetimeKills, lifetimeDishonorable;
}

/**
 * The honor counted from the rows: kills and honor of today, yesterday, this week (from the last
 * maintenance day) and last week, and the lifetime kills (the stored ones and the rows').
 */
HonorTally tallyHonor(const(HonorPoint)[] points, uint today, uint weekBegin, uint storedKills, uint storedDishonorable)
    pure @safe
{
    HonorTally t;
    t.lifetimeKills = storedKills;
    t.lifetimeDishonorable = storedDishonorable;
    const yesterday = honorDayPlus(today, -1);
    const weekEnd = honorDayPlus(weekBegin, 7), lastWeekBegin = honorDayPlus(weekBegin, -7);
    const d = (uint day) => dateOfHonorDay(day);
    foreach (ref p; points)
    {
        const r = p.record;
        if (r.type == HonorType.honorable)
        {
            if (p.isKill)
            {
                ++t.lifetimeKills;
                if (r.date == today)
                    ++t.todayKills;
            }
            if (r.date == yesterday)
            {
                t.yesterdayKills += p.isKill;
                t.yesterdayHonor += r.honor;
            }
            if (d(r.date) >= d(weekBegin) && d(r.date) < d(weekEnd))
            {
                t.thisWeekKills += p.isKill;
                t.thisWeekHonor += r.honor;
            }
            if (d(r.date) >= d(lastWeekBegin) && d(r.date) < d(weekBegin))
            {
                t.lastWeekKills += p.isKill;
                t.lastWeekHonor += r.honor;
            }
        }
        else if (r.type == HonorType.dishonorable && p.isKill)
        {
            ++t.lifetimeDishonorable;
            if (r.date == today)
                ++t.todayDishonorable;
        }
    }
    return t;
}

/// Honor on the player's side: `Character` mixes it in.
mixin template HonorHandlers()
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.database : HonorColumns, HonorPointRecord;
    import dmangos.world.experience : isGray;
    import dmangos.world.honor;
    import dmangos.world.pvp : spellHonorlessTarget;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.player : DeathState;
    import dmangos.world.creature : Creature;
    import dmangos.world.commands : nextWord, Rest;
    import dmangos.world.updatefields;

    private
    {
        HonorPoint[] honorPoints;  // `m_honorCP`
        HonorColumns honorStored;  // the `characters` columns: stored rating and kills, highest rank, standing
        HonorRank honorRank_;      // `m_honor_rank`
    }

    /// The rank points: the stored rating (the weekly maintenance adds each week's earning to it).
    @property float rankPoints()
    {
        return honorStored.storedRating;
    }

    /// The player's rank, as last worked out by `updateHonor`.
    @property HonorRank honorRank() const
    {
        return honorRank_;
    }

    /// Loads the honor rows and the honor columns, at login or arrival.
    package void loadHonor()
    {
        const loaded = context.database.loadHonor(player.data.guid);
        honorStored = loaded.columns;
        honorPoints = null;
        foreach (ref p; loaded.points)
            honorPoints ~= HonorPoint(p, true);
        updateHonor();
    }

    /// Saves the new honor rows and the honor columns, with the character.
    package void saveHonor()
    {
        HonorPointRecord[] added;
        foreach (ref p; honorPoints)
            if (!p.saved)
            {
                added ~= p.record;
                p.saved = true;
            }
        context.database.saveHonor(player.data.guid, honorStored, added);
    }

    /**
     * Honor gained (or, dishonorable, rank points lost at once), the client told
     * (`SMSG_PVP_CREDIT`), the fields counted again. `victimType` 0 is honor from no kill.
     */
    void addHonorPoints(float honor, HonorType type, ubyte victimType = 0, uint victim = 0, ulong victimGuid = 0,
        uint victimRank = 0)
    {
        if (honor == 0)
            return;
        HonorPointRecord r;
        r.victimType = victimType;
        r.victim = victimType ? victim : player.data.guid;
        r.honor = honor;
        r.date = honorDay(honorToday());
        r.type = type;
        if (type == HonorType.dishonorable)
        {
            const left = rankPoints - honor;
            honorStored.storedRating = left > 0 ? left : 0;
        }
        honorPoints ~= HonorPoint(r, false);
        ByteWriter w;
        w.put(type == HonorType.dishonorable ? cast(uint)(-cast(int) honor) : cast(uint) honor);
        w.put(victimGuid);
        w.put(victimRank);
        deliver(Opcode.SMSG_PVP_CREDIT, w.data);
        updateHonor();
    }

    /// Kills of the player `victim` today, before this one.
    private uint killsTodayOf(uint victim)
    {
        const today = honorDay(honorToday());
        uint count;
        foreach (ref p; honorPoints)
            if (p.record.victimType == 4 && p.record.victim == victim && p.record.date == today)
                ++count;
        return count;
    }

    /**
     * Honor for a player killed: unless it is an Honorless Target, of this side, or grey
     * to this player, honor by the formula, shared among `groupSize`.
     */
    package void rewardHonorForPlayer(typeof(this) victim, uint groupSize)
    {
        if (victim is null || victim is this || victim.player is null)
            return;
        rewardHonorForPlayer(victim.describeHonorVictim(), groupSize);
    }

    package HonorVictim describeHonorVictim()
    {
        const noCredit = player.auras.find(spellHonorlessTarget) !is null
            || player.auras.hasType(imported!"dmangos.world.spellids".AuraType.noPvpCredit);
        return HonorVictim(player.guid, player.data.level, player.data.race, honorRank.rank, honorRank.visualRank,
            noCredit, player.position);
    }

    private void rewardHonorForPlayer(const HonorVictim victim, uint groupSize)
    {
        if (victim.honorless || victim.guid == player.guid
            || context.client.teamForRace(victim.race) == context.client.teamForRace(player.data.race))
            return;
        if (isGray(player.data.level, victim.level))
            return;
        const points = honorableKillPoints(player.data.level, victim.level, victim.visualRank,
            killsTodayOf(cast(uint) victim.guid), groupSize);
        addHonorPoints(points, HonorType.honorable, 4, cast(uint) victim.guid, victim.guid, victim.rank);
    }

    /**
     * Honor for a creature killed: a racial leader gives 398, a civilian of the other side (flagged for PvP) costs
     * rank points, whatever its level (Wowpedia "Civilian": an NPC "that would garner a dishonorable kill if killed").
     */
    package void rewardHonorForCreature(Creature victim)
    {
        import dmangos.world.relations : isEnemy;

        if (victim.auras.find(spellHonorlessTarget) !is null)
            return;
        const flagged = (victim.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
        if (victim.template_.civilian && flagged && isEnemy(victim.ai.relatingOf(), relatingNow(), context.client))
            addHonorPoints(dishonorableKillPoints(player.data.level), HonorType.dishonorable, 3,
                victim.template_.entry, victim.guid, 0);
        else if (victim.template_.racialLeader)
            addHonorPoints(racialLeaderHonor, HonorType.honorable, 3, victim.template_.entry, victim.guid, 19);
    }

    /**
     * This player (or its pet) killed `victim`: honor to the living
     * members of its group near the kill, each a share; or all of it, alone.
     */
    package void playerKilledByMe(typeof(this) victim)
    {
        if (victim !is null && victim !is this && victim.player !is null)
            playerKilledByMe(victim.describeHonorVictim());
    }

    package void playerKilledByMe(const HonorVictim victim)
    {
        playerKilledByMe(victim, map.id, map.instanceId);
    }

    package void playerKilledByMe(const HonorVictim victim, uint mapId, uint instance)
    {
        import dmangos.world.experience : groupXpDistance;

        auto group = context.groups.of(player.guid);
        if (group is null)
            return rewardHonorForPlayer(victim, 1);
        typeof(this)[] near;
        const v = victim.position;
        foreach (ref slot; group.members)
            if (auto member = cast(typeof(this)) context.onlinePlayer(slot.guid))
                if (member.player !is null && member.map !is null && member.map.id == mapId
                    && member.map.instanceId == instance)
                {
                    const p = member.player.position;
                    if ((p.x - v.x) ^^ 2 + (p.y - v.y) ^^ 2 + (p.z - v.z) ^^ 2 <= groupXpDistance ^^ 2
                        && (member.player.deathState == DeathState.alive || member is this))
                        near ~= member;
                }
        foreach (member; near)
            if (member.player.deathState == DeathState.alive)
                member.rewardHonorForPlayer(victim, cast(uint) near.length);
    }

    /// The honor rank and every honor field, worked out again from the rows and the stored columns.
    void updateHonor()
    {
        const today = honorDay(honorToday());
        const weekBegin = lastMaintenanceDay(honorToday(), context.config.honorMaintenanceDay);
        const t = tallyHonor(honorPoints, today, weekBegin, cast(uint) honorStored.storedHonorableKills,
            cast(uint) honorStored.storedDishonorableKills);
        const rp = rankPoints;
        honorRank_ = rankOf(rp);
        if (honorRank_.visualRank > 0 && honorRank_.rank > honorStored.highestRank)
            honorStored.highestRank = honorRank_.rank;
        auto v = &player.values;
        v.setByte!PLAYER_BYTES_3(3, honorRank_.rank);
        v.setByte!PLAYER_FIELD_BYTES(3, cast(ubyte) honorStored.highestRank);
        v.setByte!PLAYER_FIELD_BYTES2(0, cast(ubyte) rankBar(rp, honorRank_));
        v.set!PLAYER_FIELD_SESSION_KILLS(t.todayKills | t.todayDishonorable << 16);
        v.set!PLAYER_FIELD_YESTERDAY_KILLS(t.yesterdayKills);
        v.set!PLAYER_FIELD_LAST_WEEK_KILLS(t.lastWeekKills);
        v.set!PLAYER_FIELD_THIS_WEEK_KILLS(t.thisWeekKills);
        v.set!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION(cast(uint)(t.thisWeekHonor > 0 ? t.thisWeekHonor : 0));
        v.set!PLAYER_FIELD_LIFETIME_HONORBALE_KILLS(t.lifetimeKills);
        v.set!PLAYER_FIELD_LIFETIME_DISHONORBALE_KILLS(t.lifetimeDishonorable);
        v.set!PLAYER_FIELD_YESTERDAY_CONTRIBUTION(cast(uint)(t.yesterdayHonor > 0 ? t.yesterdayHonor : 0));
        v.set!PLAYER_FIELD_LAST_WEEK_CONTRIBUTION(cast(uint)(t.lastWeekHonor > 0 ? t.lastWeekHonor : 0));
        v.set!PLAYER_FIELD_LAST_WEEK_RANK(honorStored.standing);
        flushPlayerChanges();
    }

    // -----------------------------------------------------------------------
    // The `.honor` GM commands
    // -----------------------------------------------------------------------

    /// `.honor addpoints`: honor added to the selected player (here this week's, with no victim).
    bool handleAddHonorCommand(Rest args = Rest(""))
    {
        import std.format : format;

        const amount = cast(uint) arcEmuAtol(args);
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        blueSystemMessage(format!"Adding %u honor to player %s."(amount, plr.player.data.name));
        plr.greenSystemMessage(format!"You have had %u honor points added to your character."(amount));
        plr.addHonorPoints(amount, HonorType.honorable);
        return true;
    }

    /// `.honor addkills`: only the messages; no kills are added.
    bool handleAddKillCommand(Rest args = Rest(""))
    {
        import std.format : format;

        const amount = cast(uint) arcEmuAtol(args);
        auto plr = getSelectedChar(true);
        if (plr is null)
            return true;
        blueSystemMessage(format!"Adding %u kills to player %s."(amount, plr.player.data.name));
        plr.greenSystemMessage(format!"You have had %u honor kills added to your character."(amount));
        return true;
    }

    /// `.honor pvpcredit`: `SMSG_PVP_CREDIT` to oneself, for the selection, the points times ten.
    bool handlePVPCreditCommand(Rest args = Rest(""))
    {
        import std.conv : to;
        import std.format : format;

        string rest = args;
        const rankWord = nextWord(rest), pointsWord = nextWord(rest);
        uint rank, points;
        try
        {
            rank = rankWord.to!uint;
            points = pointsWord.to!uint;
        }
        catch (Exception)
        {
            redSystemMessage("Command must be in format <rank> <points>.");
            return true;
        }
        points *= 10;
        const guid = player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            redSystemMessage("A selection of a unit or player is required.");
            return true;
        }
        blueSystemMessage(format!"Building packet with Rank %u, Points %u, GUID %016X."(rank, points, guid));
        ByteWriter w;
        w.put(points);
        w.put(guid);
        w.put(rank);
        deliver(Opcode.SMSG_PVP_CREDIT, w.data);
        return true;
    }

    /// `.honor globaldailyupdate`: not implemented; does nothing.
    bool handleGlobalHonorDailyMaintenanceCommand()
    {
        return false;
    }

    /// `.honor singledailyupdate`: ditto.
    bool handleNextDayCommand()
    {
        return false;
    }

    /**
     * The client inspects another player's honor: sent for one who is near
     * (28 yards) and may not attack it.
     */
    @Handles(Opcode.MSG_INSPECT_HONOR_STATS, WorldState.inWorld)
    void handleInspectHonorStats(ref ByteReader reader)
    {
        import dmangos.world.relations : canAttack;

        const guid = reader.read!ulong;
        auto other = guid == player.guid ? this : cast(typeof(this)) context.onlinePlayer(guid);
        if (other is null || other.player is null || other.map !is map)
            return;
        const p = player.position, q = other.player.position;
        if ((p.x - q.x) ^^ 2 + (p.y - q.y) ^^ 2 > 28.0f ^^ 2)
            return;
        if (other !is this && canAttack(relatingNow(), other.relatingNow(), context.client))
            return;
        const v = &other.player.values;
        ByteWriter w;
        w.put(guid);
        w.put(v.getByte!PLAYER_FIELD_BYTES2(0));
        w.put(v.get!PLAYER_FIELD_SESSION_KILLS);
        w.put(v.get!PLAYER_FIELD_YESTERDAY_KILLS);
        w.put(v.get!PLAYER_FIELD_LAST_WEEK_KILLS);
        w.put(v.get!PLAYER_FIELD_THIS_WEEK_KILLS);
        w.put(v.get!PLAYER_FIELD_LIFETIME_HONORBALE_KILLS);
        w.put(v.get!PLAYER_FIELD_LIFETIME_DISHONORBALE_KILLS);
        w.put(v.get!PLAYER_FIELD_YESTERDAY_CONTRIBUTION);
        w.put(v.get!PLAYER_FIELD_LAST_WEEK_CONTRIBUTION);
        w.put(v.get!PLAYER_FIELD_THIS_WEEK_CONTRIBUTION);
        w.put(v.get!PLAYER_FIELD_LAST_WEEK_RANK);
        w.put(cast(ubyte) rankInfo(cast(ubyte) other.honorStored.highestRank).visualRank);
        deliver(Opcode.MSG_INSPECT_HONOR_STATS, w.data);
    }
}
