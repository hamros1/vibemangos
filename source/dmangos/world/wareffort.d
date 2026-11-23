/**
 * The Ahn'Qiraj war effort: the server-wide state that opens the gates of Ahn'Qiraj.
 *
 * Both sides hand in resources at their capitals' war effort officers (`npc_war_effort`, a quest each);
 * once every one of the thirty counters has reached its goal, the effort moves on through its phases:
 *
 * $(OL
 *   $(LI gathering: the counters fill; the capitals show them (world states) and the piles of supplies
 *        outside Ironforge and Orgrimmar grow a tier at each tenth, three tenths, half, seven and nine
 *        tenths of a group's goal;)
 *   $(LI transporting: five days, the capitals counting them down, the piles shrinking a tier a day;)
 *   $(LI the gong: until a player rings the Scarab Gong ("Bang a Gong!");)
 *   $(LI the ten-hour war in Silithus, the Colossi falling one by one;)
 *   $(LI done, for good.)
 * )
 *
 * Each phase is a game event (120 to 124; 125 to 127 for each fallen Colossus) that the effort starts
 * and stops, and with it the creatures and objects of that phase.
 *
 * The state lives in one place in a cluster: the war effort service (`WarEffortHost`, docs/SERVICES.md),
 * which counts, moves the phases on, saves to the characters database (`world_state`, row 1, in the text
 * CMaNGOS writes there) and announces every change to every node. Each node keeps what it heard
 * (`WarEffort`) and follows it: the game events, the piles, the capitals' world states. Everything that
 * follows from the state is worked out from it alone (`events`, `pilesUp`, `worldStates`), so a node that
 * hears the same state does the same.
 */
module dmangos.world.wareffort;

import core.time : Duration, seconds;

import dmangos.cluster.services : Call, Service, ServiceKind;

/// The thirty resources counted, in the order of the counters (and of the saved text).
enum AqResource : ubyte
{
    // Horde
    peacebloom,
    leanWolfSteak,
    tinBar,
    woolBandage,
    firebloom,
    heavyLeather,
    mithrilBar,
    mageweaveBandage,
    ruggedLeather,
    bakedSalmon,
    // Alliance
    lightLeather,
    linenBandage,
    mediumLeather,
    stranglekelp,
    rainbowFinAlbacore,
    ironBar,
    roastRaptor,
    silkBandage,
    thoriumBar,
    arthasTears,
    // Both sides gather these, each its own count
    copperBarAlliance,
    purpleLotusAlliance,
    thickLeatherAlliance,
    spottedYellowtailAlliance,
    runeclothBandageAlliance,
    copperBarHorde,
    purpleLotusHorde,
    thickLeatherHorde,
    spottedYellowtailHorde,
    runeclothBandageHorde,
}

/// How many resources there are.
enum resourceCount = AqResource.max + 1;

/// The war effort's phases.
enum AqPhase : ubyte
{
    disabled,
    gathering,
    transporting,
    gongTime,
    tenHourWar,
    done,
}

/// The kinds of supplies, each with its own piles.
enum SupplyGroup : ubyte
{
    skinning,
    bandages,
    bars,
    cooking,
    herbs,
}

/// Whose supplies.
enum Side : ubyte
{
    alliance,
    horde,
}

/// The Colossi of Silithus (`AQSilithusBoss`): a bit each in `WarEffort.killedBosses`.
enum Colossus : ubyte
{
    ashi,
    regal,
    zora,
}

/// A resource: its world states (how many now, the goal), its goal, and whose piles it fills.
struct ResourceInfo
{
    uint nowState;
    uint goalState;
    uint goal;
    SupplyGroup group;
    Side side;
}

/// Each resource's (by `AqResource`).
immutable ResourceInfo[resourceCount] resources = [
    ResourceInfo(2021, 2020, 96_000, SupplyGroup.herbs, Side.horde),        // Peacebloom
    ResourceInfo(2095, 2096, 10_000, SupplyGroup.cooking, Side.horde),      // Lean Wolf Steak
    ResourceInfo(2005, 2006, 22_000, SupplyGroup.bars, Side.horde),         // Tin Bar
    ResourceInfo(2079, 2080, 250_000, SupplyGroup.bandages, Side.horde),    // Wool Bandage
    ResourceInfo(2050, 2051, 19_000, SupplyGroup.herbs, Side.horde),        // Firebloom
    ResourceInfo(2066, 2067, 60_000, SupplyGroup.skinning, Side.horde),     // Heavy Leather
    ResourceInfo(2008, 2009, 18_000, SupplyGroup.bars, Side.horde),         // Mithril Bar
    ResourceInfo(2085, 2086, 250_000, SupplyGroup.bandages, Side.horde),    // Mageweave Bandage
    ResourceInfo(2073, 2074, 60_000, SupplyGroup.skinning, Side.horde),     // Rugged Leather
    ResourceInfo(2105, 2106, 10_000, SupplyGroup.cooking, Side.horde),      // Baked Salmon
    ResourceInfo(2060, 2061, 180_000, SupplyGroup.skinning, Side.alliance), // Light Leather
    ResourceInfo(2076, 2077, 800_000, SupplyGroup.bandages, Side.alliance), // Linen Bandage
    ResourceInfo(2063, 2064, 110_000, SupplyGroup.skinning, Side.alliance), // Medium Leather
    ResourceInfo(2047, 2048, 33_000, SupplyGroup.herbs, Side.alliance),     // Stranglekelp
    ResourceInfo(2092, 2093, 14_000, SupplyGroup.cooking, Side.alliance),   // Rainbow Fin Albacore
    ResourceInfo(2002, 2003, 28_000, SupplyGroup.bars, Side.alliance),      // Iron Bar
    ResourceInfo(2098, 2099, 20_000, SupplyGroup.cooking, Side.alliance),   // Roast Raptor
    ResourceInfo(2082, 2083, 600_000, SupplyGroup.bandages, Side.alliance), // Silk Bandage
    ResourceInfo(2011, 2012, 24_000, SupplyGroup.bars, Side.alliance),      // Thorium Bar
    ResourceInfo(2057, 2058, 20_000, SupplyGroup.herbs, Side.alliance),     // Arthas' Tears
    ResourceInfo(1997, 1998, 45_000, SupplyGroup.bars, Side.alliance),      // Copper Bar
    ResourceInfo(2053, 2055, 13_000, SupplyGroup.herbs, Side.alliance),     // Purple Lotus
    ResourceInfo(2069, 2071, 40_000, SupplyGroup.skinning, Side.alliance),  // Thick Leather
    ResourceInfo(2101, 2103, 8_500, SupplyGroup.cooking, Side.alliance),    // Spotted Yellowtail
    ResourceInfo(2088, 2090, 200_000, SupplyGroup.bandages, Side.alliance), // Runecloth Bandage
    ResourceInfo(2018, 1998, 45_000, SupplyGroup.bars, Side.horde),         // Copper Bar
    ResourceInfo(2054, 2055, 13_000, SupplyGroup.herbs, Side.horde),        // Purple Lotus
    ResourceInfo(2070, 2071, 40_000, SupplyGroup.skinning, Side.horde),     // Thick Leather
    ResourceInfo(2102, 2103, 8_500, SupplyGroup.cooking, Side.horde),       // Spotted Yellowtail
    ResourceInfo(2089, 2090, 200_000, SupplyGroup.bandages, Side.horde),    // Runecloth Bandage
];

/// The world state of the days left to the gong, while the supplies are carried (`WORLD_STATE_AQ_DAYS_LEFT`).
enum uint worldStateDaysLeft = 2113;

/// The game events of the phases (gathering .. done), and of each fallen Colossus (by `Colossus`).
enum ushort[5] phaseEvents = [120, 121, 122, 123, 124];
/// ditto
enum ushort[3] colossusEvents = [125, 126, 127];

/// The capitals, where the counters are shown (`ZONEID_*`): Stormwind, Darnassus, Ironforge, Orgrimmar,
/// Thunder Bluff, Undercity.
immutable uint[6] capitalZones = [1519, 1657, 1537, 1637, 1638, 1497];

/// Whether `zone` is a capital.
bool isCapital(uint zone) pure nothrow @nogc @safe
{
    foreach (z; capitalZones)
        if (z == zone)
            return true;
    return false;
}

/// How long the supplies are carried, and the war lasts.
enum long transportSeconds = 5 * 86_400, warSeconds = 10 * 3600;

/// The save row's id in `world_state` (`SAVE_ID_AHN_QIRAJ`).
enum uint saveId = 1;

/// A pile of supplies: its spawn (`gameobject.guid`), shown from its tier on (1 to 5).
struct SupplyPile
{
    SupplyGroup group;
    ubyte tier;
    uint guid;
    Side side;
}

/// The piles by tier (`warEffortSpawns`): the Alliance's outside Ironforge, the Horde's outside Orgrimmar.
immutable SupplyPile[] supplyPiles = () {
    SupplyPile[] piles;
    foreach (side; [Side.alliance, Side.horde])
        foreach (ubyte tier; 1 .. 6)
            foreach (g; 0 .. 5)
                piles ~= SupplyPile(cast(SupplyGroup) g, tier, 155_000 + (side == Side.horde ? 500 : 0) + tier * 10 + g,
                    side);
    return piles;
}();

/// Whether game object spawn `guid` is a pile of supplies: in the world only while the war effort says.
bool isSupplyPile(uint guid) pure nothrow @nogc @safe
{
    const rest = guid - 155_000;
    if (guid < 155_000 || rest >= 600)
        return false;
    const tier = rest % 500 / 10, group = rest % 10;
    return (rest < 100 || rest >= 500) && tier >= 1 && tier <= 5 && group < 5;
}

/// The tier of a group's piles at `count` of `goal` (`GetResourceTier`): above 10, 30, 50, 70, 90 percent.
ubyte pileTier(ulong count, ulong goal) pure nothrow @nogc @safe
{
    ubyte tier;
    foreach (ubyte i, percent; [10, 30, 50, 70, 90])
        if (goal * percent / 100 < count)
            tier = cast(ubyte)(i + 1);
    return tier;
}

/**
 * The war effort's state: plain data, what the service keeps, saves and announces, and what every node
 * follows (`AhnQirajData`).
 */
struct WarEffort
{
    AqPhase phase;
    long ends;                         /// Unix time the phase ends (transporting, the war); 0 for none
    uint[resourceCount] counters;      /// handed in, by `AqResource`
    uint phase2Tier;                   /// the piles' tier while the supplies are carried
    uint killedBosses;                 /// fallen Colossi: a bit each, by `Colossus`

    /// Days left to the end of the phase, as the capitals show it (`GetDaysRemaining`): a started day
    /// counts, and the last is 1.
    uint daysLeft(long now) const pure nothrow @nogc @safe
    {
        const left = ends > now ? ends - now : 0;
        const days = cast(uint)((left + 86_399) / 86_400);
        return days ? days : 1;
    }

    /// The count of `group`'s resources of `side`, and their goal (`GetResourceCounterAndMax`).
    ulong[2] groupCount(SupplyGroup group, Side side) const pure nothrow @nogc @safe
    {
        ulong[2] found;
        foreach (i, ref r; resources)
            if (r.group == group && r.side == side)
            {
                found[0] += counters[i];
                found[1] += r.goal;
            }
        return found;
    }

    /// Whether every counter has reached its goal.
    bool allGathered() const pure nothrow @nogc @safe
    {
        foreach (i, ref r; resources)
            if (counters[i] < r.goal)
                return false;
        return true;
    }

    /// The piles' tier for `group` of `side` now (0: none): by the counts while gathering, by the days while
    /// carrying, none before or after.
    ubyte tierOf(SupplyGroup group, Side side) const pure nothrow @nogc @safe
    {
        if (phase == AqPhase.transporting)
            return cast(ubyte)(phase2Tier > 5 ? 5 : phase2Tier);
        if (phase != AqPhase.gathering)
            return 0;
        const c = groupCount(group, side);
        return pileTier(c[0], c[1]);
    }

    /// Whether pile spawn `guid` is in the world now.
    bool pileUp(uint guid) const pure nothrow @nogc @safe
    {
        foreach (ref p; supplyPiles)
            if (p.guid == guid)
                return p.tier <= tierOf(p.group, p.side);
        return false;
    }

    /// The piles in the world now (their spawns).
    uint[] pilesUp() const pure @safe
    {
        uint[] up;
        foreach (ref p; supplyPiles)
            if (p.tier <= tierOf(p.group, p.side))
                up ~= p.guid;
        return up;
    }

    /// The game events the state has on (`StartWarEffortEvent`): its phase's; in the war, each fallen Colossus's.
    ushort[] events() const pure @safe
    {
        if (phase == AqPhase.disabled || phase > AqPhase.done)
            return null;
        ushort[] on = [phaseEvents[phase - 1]];
        if (phase == AqPhase.tenHourWar)
            foreach (i, e; colossusEvents)
                if (killedBosses & (1 << i))
                    on ~= e;
        return on;
    }

    /**
     * The world states a player in `zone` sees (`FillInitialWorldStates`): in a capital, while gathering,
     * every goal and every count; while carrying, the days left. Elsewhere none.
     */
    uint[2][] worldStates(uint zone, long now) const pure @safe
    {
        uint[2][] states;
        if (!isCapital(zone))
            return states;
        if (phase == AqPhase.gathering)
        {
            foreach (i, ref r; resources[0 .. AqResource.runeclothBandageAlliance + 1]) // a goal each, the shared once
                states ~= [r.goalState, r.goal];
            foreach (i, ref r; resources)
                states ~= [r.nowState, counters[i]];
        }
        else if (phase == AqPhase.transporting)
            states ~= [worldStateDaysLeft, daysLeft(now)];
        return states;
    }

    // --- what changes it ---

    /// `count` of `resource` handed in (`AddWarEffortProgress`): counted while gathering, and once every goal
    /// is reached, the supplies set out. Whether it was counted.
    bool contribute(AqResource resource, uint count, long now) pure nothrow @nogc @safe
    {
        if (phase != AqPhase.gathering || resource > AqResource.max)
            return false;
        const sum = ulong(counters[resource]) + count;
        counters[resource] = sum > uint.max ? uint.max : cast(uint) sum;
        if (counters[resource] >= resources[resource].goal && allGathered())
            enter(AqPhase.transporting, now);
        return true;
    }

    /// The effort moves to `next` (`HandleWarEffortPhaseTransition`): the timed phases get their end.
    void enter(AqPhase next, long now) pure nothrow @nogc @safe
    {
        phase = next > AqPhase.done ? AqPhase.done : next;
        ends = 0;
        if (phase == AqPhase.transporting)
        {
            ends = now + transportSeconds;
            phase2Tier = daysLeft(now);
        }
        else if (phase == AqPhase.tenHourWar)
            ends = now + warSeconds;
    }

    /**
     * Time passes (`WorldState::Update`): a timed phase that ended moves on; while the supplies are carried,
     * the piles shrink to the days left (`ChangeWarEffortPhase2Tier`). Whether anything changed.
     */
    bool advance(long now) pure nothrow @nogc @safe
    {
        bool changed;
        if (ends && now >= ends)
        {
            enter(cast(AqPhase)(phase + 1), now);
            changed = true;
        }
        if (phase == AqPhase.transporting)
        {
            const days = daysLeft(now);
            if (days < phase2Tier)
            {
                phase2Tier = days;
                changed = true;
            }
        }
        return changed;
    }

    /// The Scarab Gong was rung: the war begins if it is the gong's time. Whether it did.
    bool ringGong(long now) pure nothrow @nogc @safe
    {
        if (phase != AqPhase.gongTime)
            return false;
        enter(AqPhase.tenHourWar, now);
        return true;
    }

    /// A Colossus fell (`SetSilithusBossKilled`). Whether it was news.
    bool colossusFell(Colossus which) pure nothrow @nogc @safe
    {
        const bit = 1u << which;
        if (which > Colossus.max || (killedBosses & bit))
            return false;
        killedBosses |= bit;
        return true;
    }

    // --- the saved text ---

    /**
     * The `world_state` row's text (`AhnQirajData::GetData`): the phase, the end as Unix time, the thirty
     * counters, the piles' tier and the fallen Colossi, separated by spaces. A phase without an end saves 0.
     */
    string saveText() const pure @safe
    {
        import std.conv : to;

        string text = to!string(cast(uint) phase) ~ " " ~ to!string(ends);
        foreach (c; counters)
            text ~= " " ~ to!string(c);
        return text ~ " " ~ to!string(phase2Tier) ~ " " ~ to!string(killedBosses);
    }

    /**
     * The state from a `world_state` row's text (`WorldState::Load`), at `now`: an end that has passed in a
     * phase without one (CMaNGOS saves the time of saving there) is dropped. Missing numbers stay 0; a text
     * that is not numbers gives the initial state, and false.
     */
    static bool parse(string text, long now, out WarEffort state) pure @safe
    {
        import std.array : split;
        import std.conv : ConvException, to;

        auto words = text.split;
        try
        {
            ulong at(size_t i) { return i < words.length ? words[i].to!ulong : 0; }

            WarEffort s;
            if (words.length == 0)
                return true;
            s.phase = cast(AqPhase)(at(0) > AqPhase.done ? AqPhase.done : at(0));
            s.ends = cast(long) at(1);
            foreach (i; 0 .. resourceCount)
                s.counters[i] = cast(uint) at(2 + i);
            s.phase2Tier = cast(uint) at(2 + resourceCount);
            s.killedBosses = cast(uint) at(3 + resourceCount);
            if (s.phase != AqPhase.transporting && s.phase != AqPhase.tenHourWar)
                s.ends = 0;
            state = s;
            return true;
        }
        catch (ConvException)
            return false;
    }
}

// --- tests: the state ---

// Gathering: counts while gathering only; the last goal reached sets the supplies out for five days.
unittest
{
    WarEffort w;
    assert(!w.contribute(AqResource.tinBar, 20, 1000), "disabled: not counted");
    w.enter(AqPhase.gathering, 1000);
    assert(w.events == [ushort(120)] && w.ends == 0);
    assert(w.contribute(AqResource.tinBar, 20, 1000) && w.counters[AqResource.tinBar] == 20);
    foreach (i, ref r; resources)
        if (i != AqResource.runeclothBandageHorde)
            w.counters[i] = r.goal;
    assert(w.phase == AqPhase.gathering, "one goal is not reached yet");
    w.contribute(AqResource.runeclothBandageHorde, 199_999, 1000);
    assert(w.phase == AqPhase.gathering);
    w.contribute(AqResource.runeclothBandageHorde, 20, 2000);
    assert(w.phase == AqPhase.transporting && w.ends == 2000 + transportSeconds && w.phase2Tier == 5);
    assert(w.events == [ushort(121)]);
    assert(!w.contribute(AqResource.tinBar, 20, 2000), "the gathering is over");
}

// The phases move on with time: the days count down, the piles shrink a tier a day, the gong waits for a
// player, the war lasts ten hours, then it is done for good.
unittest
{
    WarEffort w;
    w.enter(AqPhase.transporting, 0);
    assert(w.daysLeft(0) == 5 && w.daysLeft(86_400 - 1) == 5 && w.daysLeft(86_400) == 4);
    assert(!w.advance(3600) && w.phase2Tier == 5);
    assert(w.advance(86_400) && w.phase2Tier == 4, "a day gone: a tier less");
    assert(w.advance(4 * 86_400 + 10) && w.phase2Tier == 1 && w.daysLeft(4 * 86_400 + 10) == 1);
    assert(!w.ringGong(4 * 86_400 + 20), "not the gong's time yet");
    assert(w.advance(transportSeconds) && w.phase == AqPhase.gongTime && w.ends == 0);
    assert(w.events == [ushort(122)] && w.pilesUp.length == 0);
    assert(!w.advance(transportSeconds + 1_000_000), "the gong waits");
    assert(w.ringGong(500_000) && w.phase == AqPhase.tenHourWar && w.ends == 500_000 + warSeconds);
    assert(!w.ringGong(500_001), "once");
    assert(w.colossusFell(Colossus.regal) && !w.colossusFell(Colossus.regal));
    assert(w.events == [ushort(123), 126]);
    assert(w.advance(500_000 + warSeconds) && w.phase == AqPhase.done && w.events == [ushort(124)]);
    assert(!w.advance(10_000_000) && w.phase == AqPhase.done, "done for good");
}

// The piles: a tier at each step of a group's goal while gathering; the days' tier while carrying.
unittest
{
    assert(pileTier(0, 1000) == 0 && pileTier(100, 1000) == 0 && pileTier(101, 1000) == 1);
    assert(pileTier(500, 1000) == 2 && pileTier(501, 1000) == 3 && pileTier(1000, 1000) == 5);
    assert(supplyPiles.length == 50 && supplyPiles[0].guid == 155_010 && supplyPiles[$ - 1].guid == 155_554);
    assert(isSupplyPile(155_010) && isSupplyPile(155_554) && isSupplyPile(155_532));
    assert(!isSupplyPile(155_000) && !isSupplyPile(155_005) && !isSupplyPile(155_100) && !isSupplyPile(155_500)
        && !isSupplyPile(155_201) && !isSupplyPile(155_060), "the initial piles, the war's objects: not tiered");
    foreach (ref p; supplyPiles)
        assert(isSupplyPile(p.guid));

    WarEffort w;
    w.enter(AqPhase.gathering, 0);
    assert(w.pilesUp.length == 0);
    // The Alliance's bars: iron 28000, thorium 24000, copper 45000 = 97000; past a tenth is tier 1.
    w.contribute(AqResource.copperBarAlliance, 9_701, 0);
    assert(w.tierOf(SupplyGroup.bars, Side.alliance) == 1 && w.pilesUp == [155_012u]);
    assert(w.tierOf(SupplyGroup.bars, Side.horde) == 0, "the Horde's copper is its own");
    w.contribute(AqResource.ironBar, 28_000, 0);
    w.contribute(AqResource.thoriumBar, 24_000, 0);
    assert(w.tierOf(SupplyGroup.bars, Side.alliance) == 3 && w.pileUp(155_032) && !w.pileUp(155_042));

    w.enter(AqPhase.transporting, 0);
    assert(w.pilesUp.length == 50, "carried: every pile at the days' tier");
    w.advance(3 * 86_400);
    assert(w.pilesUp.length == 20 && w.pileUp(155_514) && !w.pileUp(155_530));
}

// The world states: in the capitals only; every goal and count while gathering, the days while carrying.
unittest
{
    WarEffort w;
    assert(w.worldStates(1519, 0).length == 0, "disabled: none");
    w.enter(AqPhase.gathering, 0);
    w.contribute(AqResource.peacebloom, 40, 0);
    auto states = w.worldStates(1637, 0);
    assert(states.length == 25 + 30);
    assert(states[0] == [2020u, 96_000u] && states[25] == [2021u, 40u]);
    assert(w.worldStates(12, 0).length == 0, "Elwynn: none");
    w.enter(AqPhase.transporting, 0);
    assert(w.worldStates(1497, 86_400 * 2) == [[worldStateDaysLeft, 3u]]);
}

// The saved text: CMaNGOS's, both ways.
unittest
{
    WarEffort w;
    w.enter(AqPhase.transporting, 1_700_000_000);
    w.counters[AqResource.peacebloom] = 96_000;
    w.counters[AqResource.runeclothBandageHorde] = 200_001;
    w.killedBosses = 5;
    const text = w.saveText;
    assert(text == "2 1700432000 96000" ~ " 0".replicate(28) ~ " 200001 5 5");
    WarEffort back;
    assert(WarEffort.parse(text, 1_700_000_100, back) && back == w);

    // CMaNGOS writes the time of saving as the end of a phase without one: dropped.
    assert(WarEffort.parse("1 1699999999 5", 1_700_000_000, back));
    assert(back.phase == AqPhase.gathering && back.ends == 0 && back.counters[0] == 5 && back.counters[1] == 0);
    assert(WarEffort.parse("", 0, back) && back == WarEffort.init, "an empty row: the initial state");
    assert(!WarEffort.parse("2 x", 0, back) && back == WarEffort.init, "rubbish: the initial state");
}

version (unittest) private string replicate(string s, size_t n) pure @safe
{
    string r;
    foreach (_; 0 .. n)
        r ~= s;
    return r;
}

// ---------------------------------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------------------------------

/// Resources handed in: the request of `WarEffortHost.contribute`.
struct WarEffortContribution
{
    AqResource resource;
    uint count;
}

/// The Scarab Gong was rung.
struct WarEffortGong
{
    ulong player;
}

/// A Colossus fell.
struct WarEffortColossus
{
    Colossus which;
}

/// Asking for the state as it stands.
struct WarEffortQuery
{
    ushort node;
}

/// What `WarEffortHost.gong` answers: whether it began the war.
struct WarEffortGongReply
{
    bool warBegan;
}

/**
 * The war effort as a cluster service (docs/SERVICES.md): the one place it is counted and moved on. Its
 * node saves it and announces each change (`WarEffort`, the whole state) to every node, and once a minute
 * besides, for nodes that came or missed a change.
 */
@Service(ServiceKind.warEffort)
struct WarEffortHost
{
    WarEffort state;
    long delegate() clock;                         /// Unix time now
    void delegate(string text) save;               /// writes the `world_state` row
    void delegate(const ref WarEffort) announce;   /// tells every node
    private Duration sinceAnnounced;

    /// Re-announced this often while nothing changes.
    enum announceEvery = 60.seconds;

    /// Starting on its node: every node hears how it stands (its first tick moves on what ended meanwhile).
    void start()
    {
        tell();
    }

    /// Resources handed in at an officer.
    @Call void contribute(const ref WarEffortContribution c)
    {
        if (state.contribute(c.resource, c.count, clock()))
            changed();
    }

    /// The gong rung: the war begins if it is its time.
    @Call WarEffortGongReply gong(const ref WarEffortGong)
    {
        const began = state.ringGong(clock());
        if (began)
            changed();
        return WarEffortGongReply(began);
    }

    /// A Colossus fell.
    @Call void colossusDied(const ref WarEffortColossus c)
    {
        if (state.colossusFell(c.which))
            changed();
    }

    /// The state as it stands (a node starting).
    @Call WarEffort current(const ref WarEffortQuery)
    {
        return state;
    }

    /// The phases' clock; and the state again, now and then.
    void tick(Duration elapsed)
    {
        if (state.advance(clock()))
            return changed();
        sinceAnnounced += elapsed;
        if (sinceAnnounced >= announceEvery)
            tell();
    }

    /// Moving: the state goes along.
    ubyte[] saveState()
    {
        import dmangos.plaindata : encode;

        ubyte[] bytes;
        encode(bytes, state);
        return bytes;
    }

    private void changed()
    {
        persist();
        tell();
    }

    private void persist()
    {
        if (save !is null)
            save(state.saveText);
    }

    private void tell()
    {
        sinceAnnounced = Duration.zero;
        if (announce !is null)
            announce(state);
    }
}

// The service: counts, saves the row and tells every node at each change; the gong once; a move keeps it.
unittest
{
    import dmangos.cluster.services : ServiceHost;
    import dmangos.plaindata : decode;

    long now = 1000;
    string[] saved;
    WarEffort[] told;
    WarEffortHost make(const(ubyte)[] state)
    {
        WarEffortHost h;
        if (state.length)
            decode(state, h.state);
        h.clock = () => now;
        h.save = (string text) { saved ~= text; };
        h.announce = (const ref WarEffort w) { told ~= w; };
        return h;
    }

    auto host = new ServiceHost;
    host.provide!WarEffortHost(&make);
    host.start(ServiceKind.warEffort);
    assert(told.length == 1 && saved.length == 0, "started: told, nothing to save");
    host.local!WarEffortHost().state.enter(AqPhase.gathering, now);

    host.call!(WarEffortHost.contribute)(WarEffortContribution(AqResource.linenBandage, 20));
    assert(told[$ - 1].counters[AqResource.linenBandage] == 20 && saved[$ - 1].startsWith("1 0 0 0"));
    host.local!WarEffortHost().state.enter(AqPhase.gongTime, now);
    bool began;
    host.call!(WarEffortHost.gong)(WarEffortGong(7), (WarEffortGongReply r) { began = r.warBegan; });
    assert(began && told[$ - 1].phase == AqPhase.tenHourWar);
    host.call!(WarEffortHost.gong)(WarEffortGong(7), (WarEffortGongReply r) { began = r.warBegan; });
    assert(!began, "once");
    host.call!(WarEffortHost.colossusDied)(WarEffortColossus(Colossus.zora));
    assert(told[$ - 1].events == [ushort(123), 127]);

    // Ten hours later the tick ends the war.
    now += warSeconds;
    const before = told.length;
    host.tick(1.seconds);
    assert(told.length == before + 1 && told[$ - 1].phase == AqPhase.done && saved[$ - 1].startsWith("5 0 "));
    host.tick(30.seconds);
    assert(told.length == before + 1);
    host.tick(31.seconds);
    assert(told.length == before + 2, "a minute without news: told again");

    // It moves to another node with its state.
    const state = host.stop(ServiceKind.warEffort);
    auto other = new ServiceHost;
    other.provide!WarEffortHost(&make);
    other.start(ServiceKind.warEffort, state);
    WarEffort seen;
    other.call!(WarEffortHost.current)(WarEffortQuery(2), (WarEffort w) { seen = w; });
    assert(seen.phase == AqPhase.done && seen.killedBosses == 1 << Colossus.zora);
}

version (unittest) private bool startsWith(string s, string prefix) pure nothrow @nogc @safe
{
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}

// ---------------------------------------------------------------------------------------------------
// A server following it
// ---------------------------------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.context : WorldContext;
    import dmangos.world.database : MemoryWorldDatabase;

    // A world with the war effort's first two phases' events and the Alliance bars' first pile, from
    // `world_state` text `saved`.
    private WorldContext warEffortWorld(MemoryWorldDatabase db, string saved)
    {
        import dmangos.world.config : WorldConfig;
        import dmangos.world.gameevents : GameEvent, ScheduleType;
        import dmangos.world.gameobject : GameObjectSpawn;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.testdata : testClientData, testWorldData;

        auto client = testClientData();
        auto data = testWorldData(client);
        data.gameEvents ~= GameEvent(120, ScheduleType.serverSide, 0, 0, 525_600, 1, 0, "AQ War Effort Phase 1");
        data.gameEvents ~= GameEvent(121, ScheduleType.serverSide, 0, 0, 525_600, 1, 0, "AQ War Effort Phase 2");
        data.gameObjectCells[0][cellKeyAt(-8945, -140)] ~= data.gameObjectSpawns.length;
        data.gameObjectSpawns ~= GameObjectSpawn(155_012, 32349, 0, -8945, -140, 83, 0);
        db.worldStateRows[saveId] = saved;
        WorldConfig config;
        config.logoutDelay = 0;
        return new WorldContext(config, db, data, client);
    }

    // Whether the pile of spawn `guid` is in map 0.
    private bool pileHere(WorldContext context, uint guid)
    {
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.map : MapObject;

        bool found;
        context.map(0).forEachObject((MapObject o) {
            if (auto go = cast(GameObject) o)
                found = found || go.spawn.guid == guid;
        });
        return found;
    }
}

// A server: the saved row's phase starts its event; a hand-in is counted, saved, shown in the capitals,
// and grows the pile; the gathering done, the next phase's event follows and the capitals count the days.
unittest
{
    import dmangos.world.character : Character;
    import dmangos.world.player : CharacterData;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = warEffortWorld(db, "1 0");
    assert(context.warEffort.phase == AqPhase.gathering && context.gameEvents.isActive(120));
    assert(!context.gameEvents.isActive(121));
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 1, (ref CharacterData c) { c.zone = 1519; });
    anduin.read();
    assert(!pileHere(context, 155_012), "a tenth of the bars is not there yet");

    context.services.call!(WarEffortHost.contribute)(WarEffortContribution(AqResource.copperBarAlliance, 9_701));
    assert(db.worldStateRows[saveId] == "1 0" ~ " 0".replicate(20) ~ " 9701" ~ " 0".replicate(9) ~ " 0 0");
    bool shown;
    foreach (p; anduin.read())
        shown = shown || (p.opcode == Opcode.SMSG_UPDATE_WORLD_STATE && p.body_ == [205, 7, 0, 0, 0xe5, 0x25, 0, 0]);
    assert(shown, "Stormwind sees the Alliance's copper count (1997 = 9701)");
    assert(pileHere(context, 155_012), "past a tenth: the bars' first pile");

    // Every init in a capital carries the goals and counts.
    (context.onlinePlayer("Anduin")).sendInitWorldStates(1519);
    const init = anduin.read();
    assert(init.length == 1 && init[0].opcode == Opcode.SMSG_INIT_WORLD_STATES);
    assert(init[0].body_[8] == 55 && init[0].body_[9] == 0, "25 goals and 30 counts");

    // Every goal reached: the supplies set out, the second phase's event on.
    foreach (i, ref r; resources)
        context.services.call!(WarEffortHost.contribute)(WarEffortContribution(cast(AqResource) i, r.goal));
    assert(context.warEffort.phase == AqPhase.transporting);
    assert(!context.gameEvents.isActive(120) && context.gameEvents.isActive(121));
    bool days;
    foreach (p; anduin.read())
        days = days || (p.opcode == Opcode.SMSG_UPDATE_WORLD_STATE && p.body_ == [0x41, 8, 0, 0, 5, 0, 0, 0]);
    assert(days, "the capitals count five days");
    assert(pileHere(context, 155_012), "carried: still there, at tier 5");
}

// Two nodes: the service runs on one; the other asks how it stands, hears each change, and its hand-ins
// are counted on the first.
unittest
{
    import dmangos.cluster.protocol : ServiceCall, ServiceNews, ServiceReply;
    import dmangos.world.testclient : newDatabase;

    auto dbA = newDatabase(), dbB = newDatabase();
    auto a = warEffortWorld(dbA, "1 0 5"), b = warEffortWorld(dbB, "");
    b.services.stopAll();
    a.services.self = 1;
    b.services.self = 2;
    a.services.placement = b.services.placement = (ServiceKind) => cast(ushort) 1;
    b.services.sendCall = (ushort node, const ref ServiceCall c) { a.services.receiveCall(2, c); return true; };
    a.services.sendReply = (ushort node, const ref ServiceReply r) { b.services.receiveReply(1, r); return true; };
    a.services.sendNews = (const ref ServiceNews n) { b.services.receiveNews(1, n); };
    assert(b.warEffort.phase == AqPhase.disabled, "its own row says nothing");

    b.askWarEffort();
    assert(b.warEffort.phase == AqPhase.gathering && b.warEffort.counters[0] == 5 && b.gameEvents.isActive(120));
    b.warEffortColossusFell(Colossus.ashi);
    b.services.call!(WarEffortHost.contribute)(WarEffortContribution(AqResource.peacebloom, 20));
    assert(a.warEffort.counters[0] == 25 && b.warEffort.counters[0] == 25, "counted on a, heard on b");
    assert(dbA.worldStateRows[saveId].startsWith("1 0 25 ") && dbB.worldStateRows.get(saveId, "") == "",
        "saved by the service's node only");
    assert(a.warEffort.killedBosses == 1, "a Colossus's fall is remembered whatever the phase");
}
