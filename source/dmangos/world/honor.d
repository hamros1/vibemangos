/**
 * Honor (CMaNGOS-classic's `Player::RewardHonor`, `AddHonorCP`, `UpdateHonor` and `MaNGOS::Honor`):
 * points for kills, ranks from rank points, and the fields the client shows them in.
 *
 * $(UL
 *   $(LI A kill of an enemy player who is not grey to the killer gives honor (`honorableKillPoints`):
 *        more for a higher-ranked victim, less for each kill of the same one that day (none from the
 *        tenth), shared in a group. A grey civilian creature of the other side (flagged for PvP) costs
 *        rank points (`dishonorableKillPoints`); a racial leader gives 398 to each.)
 *   $(LI Each gain is a `character_honor_cp` row of the day. Today's, yesterday's, this week's and last
 *        week's kills and honor are counted from the rows (`updateHonor`); the weekly maintenance
 *        (`dmangos.world.honorweek`) turns a week's honor into rank points, gives last week's standing,
 *        and folds old rows into the stored totals.)
 *   $(LI The rank (Private/Scout 1 to Grand Marshal/High Warlord 14) comes from the rank points.)
 * )
 *
 * Days are CMaNGOS's: `(year - 1900) << 16 | day of the year` in the server's local time (the
 * `date` column). Arithmetic on them goes through the calendar here, where CMaNGOS's `date - 7`
 * goes wrong across a new year.
 */
module dmangos.world.honor;

import std.datetime.date : Date, DayOfWeek;

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

/// `World::GetDateLastMaintenanceDay`: the last `maintenanceDay` (0 Sunday) on or before `today`.
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

/// `HonorRankInfo`: an internal rank (0 none, 1 to 4 negative, 5 to 18 the titles) and what it spans.
struct HonorRank
{
    ubyte rank;
    byte visualRank;     /// -4 to 14: what the client and the titles count
    float maxRP = 2000;
    float minRP = 0;
    bool positive = true;
}

/// `CalculateRankInfo`: what an internal rank spans. (Rank 1's bar runs from 0 to 2000, where
/// CMaNGOS gives it maximum 0 and minimum 2000, a bar that runs backwards.)
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

/// `CalculateHonorRank`: the rank of `rankPoints`.
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

/// `TYPE_OF_HONOR`
enum HonorType : ubyte
{
    honorable = 1,
    dishonorable = 2,
}

/// `IsTrivialLevelDifference`: grey to a unit of `level` (the honor tables' steps).
bool greyForHonor(uint level, uint targetLevel) pure nothrow @nogc @safe
{
    if (level <= targetLevel)
        return false;
    static immutable uint[13] limit = [4, 4, 5, 5, 6, 6, 7, 7, 8, 9, 10, 11, 12];
    const step = level / 5;
    return level - targetLevel > limit[step < 12 ? step : 12];
}

/**
 * `MaNGOS::Honor::HonorableKillPoints`: a kill of a player of `victimLevel`, `victimRP` rank points
 * and visual rank `victimVisualRank` by one of `killerLevel` and `killerRP`, who has killed it
 * `killsToday` times today before, shared among `groupSize`.
 */
float honorableKillPoints(uint killerLevel, float killerRP, uint victimLevel, float victimRP, int victimVisualRank,
    uint killsToday, uint groupSize) pure nothrow @nogc @safe
{
    const rank = victimVisualRank > 0 ? victimVisualRank : 0; // CMaNGOS wraps a negative rank into a huge one
    const diffHonor = victimRP / (killerRP + 1) + 1;
    const diffLevel = victimLevel * (1.0 / (killerLevel ? killerLevel : 1));
    const f = killsToday < 10 ? 10 - killsToday : 0;
    const honor = cast(int)((f * 0.25) * (killerLevel + (rank * 5 + 1)) * (1 + 0.05 * diffHonor) * diffLevel);
    return (honor <= 400 ? honor : 400) / (groupSize ? groupSize : 1);
}

/// `MaNGOS::Honor::DishonorableKillPoints`: the rank points a dishonorable kill costs at `level`.
float dishonorableKillPoints(uint level) pure nothrow @nogc @safe
{
    float points = 10;
    if (level >= 30 && level <= 35)
        points += 1.5f * (level - 29);
    else if (level >= 36 && level <= 41)
        points += 9 + 2 * (level - 35);
    else if (level >= 42 && level <= 50)
        points += 21 + 3.2f * (level - 41);
    else if (level >= 51)
        points += 50 + 4 * (level - 50);
    return points > 100 ? 100 : points;
}

/// A racial leader's kill (`RacialLeader` creatures), to each who earns it.
enum float racialLeaderHonor = 398;

unittest
{
    // Level 60 on level 60, no ranks, the first kill today: (10 * 0.25) * (60 + 1) * 1.05 * 1 = 160.
    assert(honorableKillPoints(60, 0, 60, 0, 0, 0, 1) == 160);
    assert(honorableKillPoints(60, 0, 60, 0, 0, 0, 2) == 80, "shared");
    assert(honorableKillPoints(60, 0, 60, 0, 0, 9, 1) == 16 && honorableKillPoints(60, 0, 60, 0, 0, 10, 1) == 0,
        "the tenth kill of one victim in a day is worth nothing");
    assert(dishonorableKillPoints(20) == 10 && dishonorableKillPoints(55) == 80 && dishonorableKillPoints(60) == 100);
    assert(greyForHonor(60, 47) && !greyForHonor(60, 48) && greyForHonor(10, 4) && !greyForHonor(10, 5));
}

// ---------------------------------------------------------------------------------------------------
// The player's side
// ---------------------------------------------------------------------------------------------------

/// A gain of honor in memory (`HonorCP`), with whether it is in the database yet.
struct HonorPoint
{
    import dmangos.world.database : HonorPointRecord;

    HonorPointRecord record;
    bool saved;

    /// `HonorCP::isKill`: a kill of a creature or a player (not honor from elsewhere).
    @property bool isKill() const pure nothrow @nogc @safe
    {
        return record.victimType == 3 || record.victimType == 4;
    }
}

/// What `HonorHandlers.updateHonor` counts from the rows.
struct HonorTally
{
    uint todayKills, todayDishonorable, yesterdayKills, thisWeekKills, lastWeekKills;
    float yesterdayHonor = 0, thisWeekHonor = 0, lastWeekHonor = 0;
    uint lifetimeKills, lifetimeDishonorable;
}

/**
 * `Player::UpdateHonor`'s counting: kills and honor of today, yesterday, this week (from the last
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
    import dmangos.world.honor;
    import dmangos.world.pvp : spellHonorlessTarget;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.player : DeathState;
    import dmangos.world.creature : Creature;
    import dmangos.world.updatefields;

    private
    {
        HonorPoint[] honorPoints;  // `m_honorCP`
        HonorColumns honorStored;  // the `characters` columns: stored rating and kills, highest rank, standing
        HonorRank honorRank_;      // `m_honor_rank`
    }

    /// `Player::GetRankPoints`: the stored rating (the weekly maintenance adds each week's earning to it).
    @property float rankPoints()
    {
        return honorStored.storedRating;
    }

    /// `GetHonorRankInfo`
    @property HonorRank honorRank() const
    {
        return honorRank_;
    }

    /// `_LoadHonorCP` and the honor columns, at login or arrival.
    package void loadHonor()
    {
        const loaded = context.database.loadHonor(player.data.guid);
        honorStored = loaded.columns;
        honorPoints = null;
        foreach (ref p; loaded.points)
            honorPoints ~= HonorPoint(p, true);
        updateHonor();
    }

    /// `_SaveHonorCP` and the honor columns, with the character.
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
     * `Player::AddHonorCP`: honor gained (or, dishonorable, rank points lost at once), the client told
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

    /// `Player::CalculateTotalKills`: kills of the player `victim` today, before this one.
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
     * `Player::RewardHonor` for a player killed: unless it is an Honorless Target, of this side, or grey
     * to this player, honor by the formula, shared among `groupSize`.
     */
    package void rewardHonorForPlayer(typeof(this) victim, uint groupSize)
    {
        if (victim is null || victim is this || victim.player is null)
            return;
        if (victim.player.auras.find(spellHonorlessTarget) !is null)
            return;
        if (context.client.teamForRace(victim.player.data.race) == context.client.teamForRace(player.data.race))
            return;
        if (greyForHonor(player.data.level, victim.player.data.level))
            return;
        const points = honorableKillPoints(player.data.level, rankPoints, victim.player.data.level,
            victim.rankPoints, victim.honorRank.visualRank, killsTodayOf(victim.player.data.guid), groupSize);
        addHonorPoints(points, HonorType.honorable, 4, victim.player.data.guid, victim.player.guid,
            victim.honorRank.rank);
    }

    /**
     * `Player::RewardHonor` for a creature killed: a racial leader gives 398, a grey civilian of the
     * other side (flagged for PvP) costs rank points (`IsCivilianForTarget`).
     */
    package void rewardHonorForCreature(Creature victim)
    {
        import dmangos.world.relations : isEnemy;

        if (victim.auras.find(spellHonorlessTarget) !is null)
            return;
        const level = victim.values.get!UNIT_FIELD_LEVEL;
        const flagged = (victim.values.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
        if (victim.template_.civilian && flagged && greyForHonor(player.data.level, level)
            && isEnemy(victim.ai.relatingOf(), relatingNow(), context.client))
            addHonorPoints(dishonorableKillPoints(player.data.level), HonorType.dishonorable, 3,
                victim.template_.entry, victim.guid, 0);
        else if (victim.template_.racialLeader)
            addHonorPoints(racialLeaderHonor, HonorType.honorable, 3, victim.template_.entry, victim.guid, 19);
    }

    /**
     * `Unit::Kill` of a player by this one (or its pet): `RewardGroupAtKill`'s honor to the living
     * members of its group near the kill, each a share; or all of it, alone.
     */
    package void playerKilledByMe(typeof(this) victim)
    {
        import dmangos.world.experience : groupXpDistance;

        auto group = context.groups.of(player.guid);
        if (group is null)
            return rewardHonorForPlayer(victim, 1);
        typeof(this)[] near;
        const v = victim.player.position;
        foreach (ref slot; group.members)
            if (auto member = cast(typeof(this)) context.onlinePlayer(slot.guid))
                if (member.player !is null && member.map is map)
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

    /// `Player::UpdateHonor`: the rank and every honor field, from the rows and the stored columns.
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

    /**
     * `WorldSession::HandleInspectHonorStatsOpcode`: another player's honor, for one who is near
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
