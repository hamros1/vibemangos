/**
 * World PvP of patch 1.12 ("Drums of War"): the four towers of the Eastern Plaguelands, and the Silithyst of Silithus.
 *
 * $(B The towers.) Northpass, Crown Guard, Eastwall and Plaguewood each have a capture point (a game object of type
 * 29, its rules in its template's data): a slider from 0 (the Horde's end) to 100 (the Alliance's), starting in the
 * middle, with a neutral band of 20 around it. PvP-flagged players alive and seen within 80 yards push it toward their
 * end, as fast as their side outnumbers the other (one more: the whole length in 1200 seconds; five or more: in 480).
 * A side takes the tower when the slider leaves the neutral band toward its end; a tower held loses its holder when the
 * slider is pushed back into the band. Each tower's state is on the zone map (seven world states, `AreaPOI.dbc`), the
 * towers held in the zone's frame, and the slider in the capture bar of those in range. Taking a tower: those of its
 * side counted there get 189 bonus honor and the tower's quest credit; the banners turn to its side
 * (`GameObjectArtKit.dbc`); the zone's defense channel is told. Each side holding towers has Echoes of Lordaeron in the zone and in Stratholme, a rank per tower held.
 * Crown Guard's graveyard is its holder's; Northpass's shrine (Lordaeron's Blessing) is its holder's; Plaguewood's
 * capture brings the flight master William Kielar, Eastwall's a squad that marches on Northpass (their database
 * scripts, `dbscripts_on_event`).
 *
 * $(B Silithyst.) Geysers in Silithus give Silithyst (an aura) to a player who opens one; a carrier who dies (or
 * mounts, or loses it otherwise but at its camp) drops it as a mound anyone may pick up. Brought to its side's camp (an
 * area trigger), it is turned in: Traces of Silithyst, Cenarion Circle reputation, a bonus honor unit, the quest credit,
 * and a count for its side. The first side
 * to 200 has Cenarion Favor in Silithus and Ahn'Qiraj until the other side reaches 200; the counts then start again.
 *
 * The state is one truth in a cluster: the world PvP service (`WorldPvpHost`, docs/SERVICES.md) moves the sliders,
 * counts the Silithyst and announces every change (`WorldPvp`, the whole state) to every node. Each node reports the
 * players it simulates near each tower (they may stand on several nodes' ground), and follows what it hears
 * (`WorldPvpFollower`): world states, buffs, banners, graveyard, rewards, and the capture events on the node that
 * simulates the tower. Neither zone's state outlived a restart in 1.12 (warcraft.wiki.gg "The Silithyst Must Flow":
 * "A server reboot will reset the battle"), so it is not saved: it moves with the service, and starts anew otherwise.
 * The rules and their sources are in docs/FORMULAS.md ("World PvP").
 */
module dmangos.world.worldpvp;

import core.time : Duration, seconds;

import dmangos.cluster.services : Call, Service, ServiceKind;

/// A side, as an index.
enum PvpTeam : ubyte
{
    alliance,
    horde,
}

/// Who holds a tower (or is favored by the Cenarion Circle): nobody, or a side.
enum Holder : ubyte
{
    none,
    alliance,
    horde,
}

/// The holder that is `team`.
Holder holderOf(PvpTeam team) pure nothrow @nogc @safe
{
    return team == PvpTeam.alliance ? Holder.alliance : Holder.horde;
}

/// The team that is `holder` (not `none`).
PvpTeam teamOf(Holder holder) pure nothrow @nogc @safe
in (holder != Holder.none)
{
    return holder == Holder.alliance ? PvpTeam.alliance : PvpTeam.horde;
}

// ---------------------------------------------------------------------------------------------------
// The towers of the Eastern Plaguelands
// ---------------------------------------------------------------------------------------------------

/// The zones (`AreaTable.dbc`): the Eastern Plaguelands, Stratholme (the dungeon), the Fungal Vale (an area of the first).
enum uint zoneEasternPlaguelands = 139, zoneStratholme = 2017, areaFungalVale = 2258;

/// The map the towers are on (the Eastern Kingdoms).
enum uint towersMap = 0;

/// The towers.
enum Tower : ubyte
{
    northpass,
    crownGuard,
    eastwall,
    plaguewood,
}

/// How many.
enum towerCount = Tower.max + 1;

/// What the zone map shows of a tower: one of its seven world states (`AreaPOI.dbc`'s descriptions) is 1.
enum TowerLook : ubyte
{
    neutral,
    allianceContested,   /// the Alliance's, the slider last pushed toward the Horde
    hordeContested,
    allianceProgressing, /// the Alliance's, the slider last pushed toward its end (not there yet)
    hordeProgressing,
    alliance,
    horde,
}

/// A tower: its capture point, its world states, its quest credit and its capture events.
struct TowerInfo
{
    string name;
    uint capturePoint;        /// `gameobject_template` (type 29, `Doodad_BattlefieldBanner_State_Base_Plaguelands0N`)
    float x, y, z;            /// the capture point's spawn
    uint[TowerLook.max + 1] lookStates; /// the map's world states, by `TowerLook`
    uint questCredit;         /// `<TXT>... Capture Quest Doodad`: "Establishing New Outposts", "Bolstering Our Defenses"
    uint[2] capturedEvent;    /// the capture point's data 8 and 9, by team: `dbscripts_on_event` run when it is taken
    uint[2] takenText;        /// `broadcast_text`: "... has been taken by the Alliance/Horde!", by team
}

/// The four (the capture points' templates and spawns, `AreaPOI.dbc`, `quest_template` 9664/9665, `broadcast_text`).
/// Plaguewood's "Horde, Contested" (2367) has no point of interest in the client's data; its number is the gap in its
/// run of states.
immutable TowerInfo[towerCount] towers = [
    TowerInfo("Northpass Tower", 181_899, 3181.08f, -4379.36f, 174.123f, [2352, 2362, 2363, 2364, 2365, 2372, 2373],
        17_696, [10_699, 10_698], [13_630, 13_635]),
    TowerInfo("Crown Guard Tower", 182_096, 1860.85f, -3731.23f, 196.716f, [2355, 2374, 2375, 2376, 2377, 2378, 2379],
        17_689, [10_705, 10_704], [13_632, 13_633]),
    TowerInfo("Eastwall Tower", 182_097, 2574.51f, -4794.89f, 144.704f, [2361, 2359, 2360, 2357, 2358, 2354, 2356],
        17_690, [10_691, 10_692], [13_631, 13_636]),
    TowerInfo("Plaguewood Tower", 182_098, 2962.71f, -3042.31f, 154.789f, [2353, 2366, 2367, 2368, 2369, 2370, 2371],
        17_698, [10_701, 10_700], [13_629, 13_634]),
];

/// "All four towers are now in control of the Alliance/Horde!" (`broadcast_text`), by team.
immutable uint[2] allTowersText = [13_638, 13_637];

/**
 * The capture points' rules, their templates' data (all four the same): the radius (data 0), the least and the most
 * superiority that counts (14, 15), the time the slider takes over its whole length at the most and at the least (16,
 * 17), the neutral band's width in percent (12) and the slider's start (20).
 */
enum float captureRadius = 80;
/// ditto
enum uint minSuperiority = 1, maxSuperiority = 5;
/// ditto
enum uint minCaptureSeconds = 480, maxCaptureSeconds = 1200;
/// ditto
enum uint neutralPercent = 20;
/// ditto
enum float sliderStart = 50;
/// The slider's ends: the Alliance's, the Horde's.
enum float sliderAlliance = 100, sliderHorde = 0;
/// The neutral band (50 ± 10).
enum float neutralLow = sliderStart - neutralPercent / 2, neutralHigh = sliderStart + neutralPercent / 2;

/// The zone's world states: the towers each side holds (`WorldStateUI.dbc` 136, 137), and the capture bar (138): shown,
/// the slider, the neutral band.
enum uint stateTowersAlliance = 2327, stateTowersHorde = 2328;
/// ditto
enum uint stateBarShown = 2426, stateBarSlider = 2427, stateBarNeutral = 2428;

/// Bonus honor to each of the side's players counted at a tower it takes (warcraft.wiki.gg "A Game of Towers").
enum uint captureHonor = 189;

/// The banners' looks (`GameObjectArtKit.dbc`: `BattlefieldBanner_State_Flag{H,A,N}_Plaguelands`), by holder.
immutable uint[3] bannerArtKits = [21, 2, 1];

/// The towers' other banners (`Tower Banner`, two at each tower), turned with the capture point.
enum uint towerBanner = 182_106;
/// How near its capture point a tower's banners stand.
enum float bannerRange = 60;

/// Echoes of Lordaeron, by team and towers held (1 to 4): the Alliance's (`INV_BannerPVP_02`), the Horde's (`_01`).
immutable uint[4][2] echoesOfLordaeron = [[11_413, 11_414, 11_415, 1386], [30_880, 30_683, 30_682, 29_520]];

/// Crown Guard Tower's graveyard (`WorldSafeLocs.dbc` "Eastern Plaguelands, Graveyard CG Tower").
enum uint crownGuardGraveyard = 927;

/// Northpass's shrine of Lordaeron's Blessing (`Lordaeron Shrine`), by team: its spawn (not in the world by default)
/// and its template (faction templates 1315, the Alliance's; 1314, the Horde's).
immutable uint[2] shrineSpawns = [80_005, 80_004];
/// ditto
immutable uint[2] shrineEntries = [181_682, 181_955];

/// The flight master Plaguewood's capture brings (`Spectral Gryphon Master`), and Eastwall's squads (a commander and
/// soldiers for the Alliance, a veteran and fighters for the Horde), whom a lost tower takes away.
enum uint williamKielar = 17_209;
/// ditto
immutable uint[2][2] eastwallSquads = [[17_635, 17_647], [17_995, 17_996]];
/// The flight master's faction by his side: his template's (84, the Alliance's: `FactionTemplate.dbc`), and its Horde
/// counterpart (83).
immutable uint[2] flightMasterFactions = [84, 83];

/// A tower's state: its slider, its holder, the way the slider last moved (1 toward the Alliance, -1 toward the Horde),
/// and how often it was taken (each taking rewarded once, wherever it is heard).
struct TowerState
{
    float slider = sliderStart;
    Holder holder;
    byte pushed;
    uint taken;

    /// What the map shows of it: nobody's in the neutral band; a side's beyond it, held at the end, progressing toward
    /// it, contested when the other side last pushed.
    TowerLook look() const pure nothrow @nogc @safe
    {
        final switch (holder)
        {
        case Holder.alliance:
            return slider >= sliderAlliance ? TowerLook.alliance
                : pushed < 0 ? TowerLook.allianceContested : TowerLook.allianceProgressing;
        case Holder.horde:
            return slider <= sliderHorde ? TowerLook.horde
                : pushed > 0 ? TowerLook.hordeContested : TowerLook.hordeProgressing;
        case Holder.none:
            return TowerLook.neutral;
        }
    }

    /// The slider as the capture bar shows it (a whole percent).
    uint shownSlider() const pure nothrow @nogc @safe
    {
        return cast(uint)(slider + 0.5f);
    }

    /**
     * `seconds` pass with `alliance` and `horde` players counted in range: the side that outnumbers the other by at
     * least `minSuperiority` pushes the slider, faster the more it does (up to `maxSuperiority`). What changed hands.
     */
    TowerChange advance(uint alliance, uint horde, double seconds) pure nothrow @nogc @safe
    {
        TowerChange change;
        const lead = cast(long) alliance - cast(long) horde;
        const superiority = lead < 0 ? -lead : lead;
        if (superiority < minSuperiority || seconds <= 0)
            return change;
        const s = superiority > maxSuperiority ? maxSuperiority : superiority;
        const whole = maxCaptureSeconds - double(maxCaptureSeconds - minCaptureSeconds) * (s - minSuperiority)
            / (maxSuperiority - minSuperiority);
        const step = (sliderAlliance - sliderHorde) * seconds / whole;
        float next = slider + (lead > 0 ? step : -step);
        slider = next > sliderAlliance ? sliderAlliance : next < sliderHorde ? sliderHorde : next;
        pushed = lead > 0 ? 1 : -1;

        // Pushed back into the neutral band, it is nobody's; out of it, the side's it went toward.
        if ((holder == Holder.alliance && slider <= neutralHigh) || (holder == Holder.horde && slider >= neutralLow))
        {
            change.lost = holder;
            holder = Holder.none;
        }
        if (holder == Holder.none && (slider > neutralHigh || slider < neutralLow))
        {
            holder = slider > neutralHigh ? Holder.alliance : Holder.horde;
            change.taken = holder;
            ++taken;
        }
        return change;
    }
}

/// What a tower's `advance` did: the side that lost it, the side that took it (each `none` if not).
struct TowerChange
{
    Holder lost, taken;
}

// ---------------------------------------------------------------------------------------------------
// Silithyst
// ---------------------------------------------------------------------------------------------------

/// The zones where Cenarion Favor holds: Silithus, the Ahn'Qiraj raids (the temple, the ruins) and their gates (a zone
/// of its own in Silithus).
enum uint zoneSilithus = 1377, zoneTempleOfAhnQiraj = 3428, zoneRuinsOfAhnQiraj = 3429, zoneGatesOfAhnQiraj = 3478;

/// The map Silithus is on (Kalimdor).
enum uint silithusMap = 1;

/// The spells: carrying it (`Silithyst`), turned in (`Traces of Silithyst`), the winners' `Cenarion Favor`, and dropping
/// it (`Sillithus Flag Drop (DND)`: a mound, 181597, for three minutes).
enum uint spellSilithyst = 29_519, spellTracesOfSilithyst = 29_534, spellCenarionFavor = 30_754,
    spellSilithystDrop = 29_533;

/// The game objects that give it: a geyser (spawned, back after its respawn time), a mound (a carrier's drop).
enum uint silithystGeyser = 181_598, silithystMound = 181_597;

/// The camps' area triggers (`AreaTrigger.dbc` 4162 at the Alliance's flag stand, 4168 at the Horde's), by team.
immutable uint[2] turnInTriggers = [4162, 4168];

/// Their quest credit (`Silithus Dust Turnin Quest Doodad`, "Scouring the Desert" 9419 and 9422), by team.
immutable uint[2] turnInCredit = [17_090, 18_199];

/// Each turn-in's reward (warcraft.wiki.gg "The Silithyst Must Flow": "20 Cenarion Circle reputation, 1 Honor Point"):
/// reputation with faction 609, and a bonus honor unit at the player's level.
enum uint factionCenarionCircle = 609;
/// ditto
enum int silithystReputation = 20;
/// ditto
enum uint silithystHonorUnits = 1;

/// The turn-ins a side needs (warcraft.wiki.gg "The Silithyst Must Flow": "The first faction to collect 200").
enum uint silithystGoal = 200;

/// The world states (`WorldStateUI.dbc` 126, 127: "%2313w/%2317w", "%2314w/%2317w"): each side's count, the goal.
immutable uint[2] stateSilithystCollected = [2313, 2314];
/// ditto
enum uint stateSilithystGoal = 2317;

/**
 * The camps' announcers (`creature` 43205 Marshal Bluewall, 43204 General Kirika: "Scouring the Desert"'s givers), by
 * team, and where they stand; what each says as its side's count reaches a quarter, half and three quarters of the goal
 * (`broadcast_text` 13479 .. 13481 the Alliance's, 13476 .. 13478 the Horde's) and when it wins (13470, 13469).
 */
immutable uint[2] silithusAnnouncers = [17_080, 17_079];
/// ditto
immutable float[3][2] silithusAnnouncerAt = [[-7144.34f, 1377.83f, 3.26f], [-7573.79f, 769.70f, -17.66f]];
/// ditto
immutable uint[3][2] silithystProgressTexts = [[13_479, 13_480, 13_481], [13_476, 13_477, 13_478]];
/// ditto
immutable uint[2] silithystVictoryTexts = [13_470, 13_469];
/// "The Alliance (Horde) has collected 200 silithyst!" (`mangos_string` 1636, 1635: CMaNGOS's `LANG_OPVP_SI_CAPTURE_*`),
/// in Silithus's defense channel, by team.
immutable uint[2] silithystCapturedStrings = [1636, 1635];

/// Which of `silithystProgressTexts` a count of `collected` calls for (0 .. 2), or -1: a quarter, half, three quarters.
int silithystProgress(uint collected) pure nothrow @nogc @safe
{
    foreach (i, at; [silithystGoal / 4, silithystGoal / 2, silithystGoal - silithystGoal / 4])
        if (collected == at)
            return cast(int) i;
    return -1;
}

/// Silithus's race.
struct SilithusState
{
    uint[2] collected;   /// by team
    Holder favored;      /// the side that won the last race: Cenarion Favor is its
    uint races;          /// how many were won

    /// A turn-in for `team`: counted; at the goal the side is favored and a new race begins. Whether it won.
    bool turnIn(PvpTeam team) pure nothrow @nogc @safe
    {
        if (++collected[team] < silithystGoal)
            return false;
        favored = holderOf(team);
        collected = [0, 0];
        ++races;
        return true;
    }
}

// ---------------------------------------------------------------------------------------------------
// The whole state
// ---------------------------------------------------------------------------------------------------

/// World PvP's state: what the service keeps and announces, and every node follows. Plain data.
struct WorldPvp
{
    TowerState[towerCount] towers;
    SilithusState silithus;

    /// The towers `team` holds.
    uint held(PvpTeam team) const pure nothrow @nogc @safe
    {
        uint n;
        foreach (ref t; towers)
            n += t.holder == holderOf(team);
        return n;
    }

    /// Whether `zone` is where Echoes of Lordaeron hold.
    static bool echoesZone(uint zone) pure nothrow @nogc @safe
    {
        return zone == zoneEasternPlaguelands || zone == zoneStratholme;
    }

    /// Whether `zone` is where Cenarion Favor holds.
    static bool favorZone(uint zone) pure nothrow @nogc @safe
    {
        return zone == zoneSilithus || zone == zoneTempleOfAhnQiraj || zone == zoneRuinsOfAhnQiraj
            || zone == zoneGatesOfAhnQiraj;
    }

    /// The rank of Echoes of Lordaeron a player of `team` has in `zone`; 0 for none.
    uint echoes(PvpTeam team, uint zone) const pure nothrow @nogc @safe
    {
        const n = held(team);
        return echoesZone(zone) && n ? echoesOfLordaeron[team][n - 1] : 0;
    }

    /// Whether a player of `team` in `zone` has Cenarion Favor.
    bool favor(PvpTeam team, uint zone) const pure nothrow @nogc @safe
    {
        return favorZone(zone) && silithus.favored == holderOf(team);
    }

    /// Whether game object spawn `guid` is one world PvP brings and takes away (Northpass's shrines).
    static bool follows(uint guid) pure nothrow @nogc @safe
    {
        return guid == shrineSpawns[0] || guid == shrineSpawns[1];
    }

    /// Whether such a spawn is in the world now: a shrine while its side holds Northpass.
    bool spawnUp(uint guid) const pure nothrow @nogc @safe
    {
        foreach (ubyte team, spawn; shrineSpawns)
            if (guid == spawn)
                return towers[Tower.northpass].holder == holderOf(cast(PvpTeam) team);
        return true;
    }

    /// Crown Guard's graveyard's team (`game_graveyard_zone.faction`: 469 the Alliance, 67 the Horde), or closed (1).
    uint crownGuardGraveyardTeam() const pure nothrow @nogc @safe
    {
        final switch (towers[Tower.crownGuard].holder)
        {
        case Holder.alliance:
            return 469;
        case Holder.horde:
            return 67;
        case Holder.none:
            return 1;
        }
    }

    /**
     * The world states a player in `zone` sees (`SMSG_INIT_WORLD_STATES`): in the Eastern Plaguelands the towers held,
     * every tower's map state, and the capture bar (shown at tower `near`, -1 for none); in Silithus the counts and the
     * goal. Elsewhere none.
     */
    uint[2][] worldStates(uint zone, int near) const pure @safe
    {
        uint[2][] states;
        if (zone == zoneEasternPlaguelands)
        {
            states ~= [stateTowersAlliance, held(PvpTeam.alliance)];
            states ~= [stateTowersHorde, held(PvpTeam.horde)];
            foreach (i, ref t; towers)
                foreach (look, id; .towers[i].lookStates)
                    states ~= [id, t.look == look ? 1u : 0u];
            states ~= [stateBarShown, near >= 0 ? 1u : 0u];
            states ~= [stateBarSlider, near >= 0 ? towers[near].shownSlider : cast(uint) sliderStart];
            states ~= [stateBarNeutral, neutralPercent];
        }
        else if (zone == zoneSilithus)
        {
            states ~= [stateSilithystCollected[0], silithus.collected[0]];
            states ~= [stateSilithystCollected[1], silithus.collected[1]];
            states ~= [stateSilithystGoal, silithystGoal];
        }
        return states;
    }
}

/// The tower whose capture point is within `captureRadius` of (`x`, `y`, `z`) on the towers' map; -1 if none.
int towerInRange(float x, float y, float z) pure nothrow @nogc @safe
{
    foreach (i, ref t; towers)
        if ((t.x - x) ^^ 2 + (t.y - y) ^^ 2 + (t.z - z) ^^ 2 <= captureRadius * captureRadius)
            return cast(int) i;
    return -1;
}

// --- tests: the rules ---

// A tower taken alone: one player's lead moves the slider the whole length in 1200 s, so out of the neutral band (10
// from the middle) in 120 s; five players' in 480 s (48 s out of the band). Taken there; the map shows it progressing
// to the end, held there.
unittest
{
    TowerState t;
    assert(t.look == TowerLook.neutral && t.holder == Holder.none);
    auto c = t.advance(1, 0, 119);
    assert(c == TowerChange.init && t.look == TowerLook.neutral, "still in the neutral band (59.9)");
    c = t.advance(1, 0, 2);
    assert(c.taken == Holder.alliance && t.holder == Holder.alliance && t.taken == 1);
    assert(t.look == TowerLook.allianceProgressing);
    c = t.advance(1, 0, 600 - 121 - 1);
    assert(c == TowerChange.init && t.slider < 100 && t.look == TowerLook.allianceProgressing, "a second short");
    c = t.advance(1, 0, 1);
    assert(c == TowerChange.init && t.look == TowerLook.alliance && t.taken == 1, "held at the end");

    TowerState five;
    five.advance(0, 7, 47);
    assert(five.holder == Holder.none && five.look == TowerLook.neutral);
    assert(five.advance(0, 5, 2).taken == Holder.horde && five.look == TowerLook.hordeProgressing,
        "five or more: 48 s");

    TowerState three; // three ahead: halfway between 1200 and 480, 840 s the whole length, 84 out of the band
    three.advance(4, 1, 83);
    assert(three.holder == Holder.none);
    assert(three.advance(4, 1, 2).taken == Holder.alliance);
}

// Even numbers hold it; the other side pushes a tower back (contested) and into the neutral band (lost), then on to
// its own end (taken).
unittest
{
    TowerState t;
    t.advance(1, 0, 600);
    assert(t.holder == Holder.alliance && t.taken == 1);
    assert(t.advance(3, 3, 1000) == TowerChange.init && t.slider == 100, "even: nothing moves");
    assert(t.advance(0, 0, 1000) == TowerChange.init, "nobody: nothing moves");
    assert(t.look == TowerLook.alliance);
    t.advance(0, 1, 12);
    assert(t.look == TowerLook.allianceContested && t.holder == Holder.alliance);
    t.advance(1, 0, 12);
    assert(t.look == TowerLook.alliance, "defended");
    auto c = t.advance(0, 1, 479);
    assert(c == TowerChange.init && t.look == TowerLook.allianceContested, "60.08: still the Alliance's");
    c = t.advance(0, 1, 2);
    assert(c.lost == Holder.alliance && c.taken == Holder.none && t.look == TowerLook.neutral);
    c = t.advance(0, 2, 2000);
    assert(c.taken == Holder.horde && t.slider == 0 && t.taken == 2 && t.look == TowerLook.horde);
}

// Echoes of Lordaeron by towers held, in the zone and Stratholme; the shrines and the graveyard follow their towers.
unittest
{
    WorldPvp w;
    assert(w.echoes(PvpTeam.alliance, zoneEasternPlaguelands) == 0);
    w.towers[Tower.eastwall].holder = Holder.horde;
    assert(w.echoes(PvpTeam.horde, zoneStratholme) == 30_880 && w.echoes(PvpTeam.alliance, zoneStratholme) == 0);
    assert(w.echoes(PvpTeam.horde, 1519) == 0, "Stormwind: none");
    foreach (ref t; w.towers)
        t.holder = Holder.horde;
    assert(w.echoes(PvpTeam.horde, zoneEasternPlaguelands) == 29_520 && w.held(PvpTeam.horde) == 4);
    assert(w.spawnUp(shrineSpawns[1]) && !w.spawnUp(shrineSpawns[0]) && w.spawnUp(12));
    assert(w.crownGuardGraveyardTeam == 67);
    w.towers[Tower.crownGuard].holder = Holder.none;
    assert(w.crownGuardGraveyardTeam == 1, "nobody's: closed");
}

// The world states: 2 + 28 + 3 in the Eastern Plaguelands, one map state of each tower on; 3 in Silithus.
unittest
{
    WorldPvp w;
    w.towers[Tower.plaguewood].holder = Holder.alliance;
    w.towers[Tower.plaguewood].slider = 100;
    auto states = w.worldStates(zoneEasternPlaguelands, Tower.plaguewood);
    assert(states.length == 33);
    uint[uint] byId;
    foreach (s; states)
        byId[s[0]] = s[1];
    assert(byId[stateTowersAlliance] == 1 && byId[stateTowersHorde] == 0);
    assert(byId[2370] == 1 && byId[2353] == 0 && byId[2352] == 1 && byId[2355] == 1 && byId[2361] == 1);
    assert(byId[stateBarShown] == 1 && byId[stateBarSlider] == 100 && byId[stateBarNeutral] == 20);
    assert(w.worldStates(zoneEasternPlaguelands, -1)[$ - 3] == [stateBarShown, 0u]);
    w.silithus.collected = [7, 9];
    assert(w.worldStates(zoneSilithus, -1) == [[2313u, 7u], [2314u, 9u], [2317u, 200u]]);
    assert(w.worldStates(12, -1).length == 0);
}

// Silithyst: the first side to 200 is favored, and a new race begins; the favor stays until the other side wins one.
unittest
{
    WorldPvp w;
    foreach (_; 0 .. 199)
        assert(!w.silithus.turnIn(PvpTeam.horde));
    w.silithus.turnIn(PvpTeam.alliance);
    assert(w.silithus.collected == [1, 199] && !w.favor(PvpTeam.horde, zoneSilithus));
    assert(w.silithus.turnIn(PvpTeam.horde) && w.silithus.collected == [0, 0] && w.silithus.races == 1);
    assert(w.favor(PvpTeam.horde, zoneSilithus) && w.favor(PvpTeam.horde, zoneTempleOfAhnQiraj)
        && w.favor(PvpTeam.horde, zoneGatesOfAhnQiraj));
    assert(!w.favor(PvpTeam.horde, 1637) && !w.favor(PvpTeam.alliance, zoneSilithus));
    foreach (_; 0 .. 200)
        w.silithus.turnIn(PvpTeam.alliance);
    assert(w.favor(PvpTeam.alliance, zoneRuinsOfAhnQiraj) && !w.favor(PvpTeam.horde, zoneSilithus));
}

/// The tower in range: within 80 yards of its capture point.
unittest
{
    assert(towerInRange(3181, -4379, 174) == Tower.northpass);
    assert(towerInRange(3160, -4340, 135) == Tower.northpass, "below it, by the shrine");
    assert(towerInRange(2574, -4794 + 81, 144.7f) == -1);
    assert(towerInRange(1860, -3731, 196) == Tower.crownGuard);
}

// ---------------------------------------------------------------------------------------------------
// The service
// ---------------------------------------------------------------------------------------------------

/// A node's players counted at each tower: the request of `WorldPvpHost.present` (`counts[tower * 2 + team]`).
struct TowerPresence
{
    ushort node;
    uint[towerCount * 2] counts;
}

/// Silithyst turned in by a player of `team`.
struct SilithystTurnIn
{
    PvpTeam team;
}

/// Asking for the state as it stands.
struct WorldPvpQuery
{
    ushort node;
}

/**
 * World PvP as a cluster service (docs/SERVICES.md): the one place the sliders move and the Silithyst is counted.
 * Nodes report their players at the towers (`present`, when the counts change and every few seconds while any are
 * there); the service sums the reports it has had lately, moves the sliders once a second, and announces the whole
 * state (`WorldPvp`) at every change of what a client sees, and once a minute besides.
 */
@Service(ServiceKind.worldPvp)
struct WorldPvpHost
{
    WorldPvp state;
    void delegate(const ref WorldPvp) announce;   /// tells every node

    /// A node's report counts for this long, unless renewed (its node may have gone).
    enum presenceLifetime = 15.seconds;
    /// Re-announced this often while nothing changes.
    enum announceEvery = 60.seconds;

    private struct Report
    {
        uint[towerCount * 2] counts;
        Duration age;
    }

    private Report[ushort] reports;
    private Duration sinceStep, sinceAnnounced;

    /// Starting on its node: every node hears how it stands.
    void start()
    {
        tell();
    }

    /// A node's players at the towers.
    @Call void present(const ref TowerPresence p)
    {
        reports[p.node] = Report(p.counts, Duration.zero);
    }

    /// Silithyst turned in.
    @Call void silithyst(const ref SilithystTurnIn t)
    {
        if (t.team > PvpTeam.max)
            return;
        state.silithus.turnIn(t.team);
        tell();
    }

    /// The state as it stands (a node starting).
    @Call WorldPvp current(const ref WorldPvpQuery)
    {
        return state;
    }

    /// Once a second the sliders move by the players counted; and the state again, now and then.
    void tick(Duration elapsed)
    {
        foreach (node; reports.keys)
            if ((reports[node].age += elapsed) > presenceLifetime)
                reports.remove(node);
        sinceAnnounced += elapsed;
        sinceStep += elapsed;
        if (sinceStep >= 1.seconds)
        {
            const seconds = sinceStep.total!"msecs" / 1000.0;
            sinceStep = Duration.zero;
            if (step(seconds))
                return tell();
        }
        if (sinceAnnounced >= announceEvery)
            tell();
    }

    /// Moving: the state goes along (the reports do not: the nodes renew them).
    ubyte[] saveState()
    {
        import dmangos.plaindata : encode;

        ubyte[] bytes;
        encode(bytes, state);
        return bytes;
    }

    /// The sliders move `seconds` on; whether a client would see a difference.
    private bool step(double seconds)
    {
        uint[towerCount * 2] sum;
        foreach (ref r; reports)
            foreach (i, n; r.counts)
                sum[i] += n;
        bool changed;
        foreach (i, ref t; state.towers)
        {
            const before = t;
            t.advance(sum[i * 2], sum[i * 2 + 1], seconds);
            changed = changed || t.holder != before.holder || t.look != before.look
                || t.shownSlider != before.shownSlider;
        }
        return changed;
    }

    private void tell()
    {
        sinceAnnounced = Duration.zero;
        if (announce !is null)
            announce(state);
    }
}

// The service: the reports' sum moves the sliders, each visible change is told, reports age out, a move keeps it.
unittest
{
    import dmangos.cluster.services : ServiceHost;
    import dmangos.plaindata : decode;

    WorldPvp[] told;
    WorldPvpHost make(const(ubyte)[] saved)
    {
        WorldPvpHost h;
        if (saved.length)
            decode(saved, h.state);
        h.announce = (const ref WorldPvp w) { told ~= w; };
        return h;
    }

    auto host = new ServiceHost;
    host.provide!WorldPvpHost(&make);
    host.start(ServiceKind.worldPvp);
    assert(told.length == 1);

    // Two nodes' Alliance players at Crown Guard, one Horde player: a lead of one.
    TowerPresence a = {node: 1}, b = {node: 2};
    a.counts[Tower.crownGuard * 2] = 1;
    b.counts[Tower.crownGuard * 2] = 1;
    b.counts[Tower.crownGuard * 2 + 1] = 1;
    host.call!(WorldPvpHost.present)(a);
    host.call!(WorldPvpHost.present)(b);
    host.tick(500.msecs);
    assert(told.length == 1, "half a second: nothing yet");
    host.tick(500.msecs);
    assert(told.length == 1, "a twelfth of a percent: the bar shows the same");
    foreach (_; 0 .. 11)
        host.tick(1.seconds);
    assert(told.length == 2 && told[$ - 1].towers[Tower.crownGuard].shownSlider == 51);
    foreach (_; 0 .. 600)
    {
        host.call!(WorldPvpHost.present)(a); // renewed, as the nodes do
        host.call!(WorldPvpHost.present)(b);
        host.tick(1.seconds);
    }
    assert(told[$ - 1].towers[Tower.crownGuard].holder == Holder.alliance && told[$ - 1].held(PvpTeam.alliance) == 1);

    // A second Horde player at node 2: even (two each). Node 1 goes quiet: after 15 seconds its player no longer
    // counts, and the Horde pushes the slider back.
    b.counts[Tower.crownGuard * 2 + 1] = 2;
    host.call!(WorldPvpHost.present)(a);
    foreach (_; 0 .. 15)
    {
        host.call!(WorldPvpHost.present)(b);
        host.tick(1.seconds);
    }
    assert(host.local!WorldPvpHost().state.towers[Tower.crownGuard].slider == 100, "even while node 1 counts");
    foreach (_; 0 .. 15)
    {
        host.call!(WorldPvpHost.present)(b);
        host.tick(1.seconds);
    }
    const t = host.local!WorldPvpHost().state.towers[Tower.crownGuard];
    assert(t.slider < 100 && t.holder == Holder.alliance && t.look == TowerLook.allianceContested);
    assert(told[$ - 1].towers[Tower.crownGuard].look == TowerLook.allianceContested, "told");

    // Silithyst: counted and told at once.
    const before = told.length;
    host.call!(WorldPvpHost.silithyst)(SilithystTurnIn(PvpTeam.horde));
    assert(told.length == before + 1 && told[$ - 1].silithus.collected == [0, 1]);

    // It moves to another node with its state.
    const saved = host.stop(ServiceKind.worldPvp);
    auto other = new ServiceHost;
    other.provide!WorldPvpHost(&make);
    other.start(ServiceKind.worldPvp, saved);
    WorldPvp seen;
    other.call!(WorldPvpHost.current)(WorldPvpQuery(2), (WorldPvp w) { seen = w; });
    assert(seen.silithus.collected == [0, 1] && seen.towers[Tower.crownGuard].holder == Holder.alliance);
}

version (unittest) private import core.time : msecs;

// ---------------------------------------------------------------------------------------------------
// A node following it
// ---------------------------------------------------------------------------------------------------

/**
 * What a node does with the state it hears (`WorldContext.worldPvp`): it keeps it; tells its players what changed in
 * their zone; turns the banners it simulates; rewards its players counted at a tower when it is taken, tells the zone,
 * and, if it simulates the tower's capture point, runs the capture's event and takes away what a lost tower brought.
 * Once a second it counts its players at the towers and reports them to the service.
 */
final class WorldPvpFollower
{
    import dmangos.world.context : WorldContext;

    private WorldContext context;
    /// The state as this node last heard it.
    WorldPvp state;
    private bool heardOnce;
    private uint[towerCount * 2] reported;
    private Duration sinceCounted, sinceReported;

    /// How often a node's counts are renewed while any are at a tower.
    enum reportEvery = 5.seconds;

    this(WorldContext context)
    {
        this.context = context;
    }

    /// The service's news: the state now.
    void heard(const ref WorldPvp now)
    {
        const before = state;
        state = now;
        const first = !heardOnce;
        heardOnce = true;
        foreach (session; players)
            session.worldPvpHeard(before);
        bool holdersChanged = first;
        foreach (i, ref t; now.towers)
        {
            const was = before.towers[i];
            if (t.holder != was.holder)
                holdersChanged = true;
            if (first)
                continue;
            if (was.holder != Holder.none && t.holder != was.holder)
                towerLost(cast(Tower) i, teamOf(was.holder));
            if (t.taken != was.taken && t.holder != Holder.none)
                towerTaken(cast(Tower) i, teamOf(t.holder), now.held(teamOf(t.holder)) == towerCount);
        }
        if (holdersChanged)
        {
            dressBanners();
            context.worldPvpSpawnsChanged();
        }
        if (!first)
            silithystNews(before.silithus, now.silithus);
    }

    /**
     * Silithus's count changed: at a quarter, half and three quarters of the goal the side's announcer says so; when a
     * side wins, its announcer cheers and the zone is told (`SMSG_DEFENSE_MESSAGE`), as vmangos's `DoSilithystYell` and
     * CMaNGOS's capture message have it. Each node does it with what it simulates (the announcer, the zone's players).
     */
    private void silithystNews(const ref SilithusState before, const ref SilithusState now)
    {
        if (now.races != before.races)
        {
            if (now.favored == Holder.none)
                return;
            const winner = teamOf(now.favored);
            announcerSays(winner, silithystVictoryTexts[winner]);
            zoneDefenseNotice(zoneSilithus, context.data.serverStrings.get(silithystCapturedStrings[winner], null));
            return;
        }
        foreach (team; [PvpTeam.alliance, PvpTeam.horde])
            if (now.collected[team] > before.collected[team])
                if (const i = silithystProgress(now.collected[team]) + 1)
                    announcerSays(team, silithystProgressTexts[team][i - 1]);
    }

    /// The camp's announcer of `team`, where this node simulates it, says `broadcast_text` `text`.
    private void announcerSays(PvpTeam team, uint text)
    {
        import dmangos.world.movement : Position;

        auto map = context.existingMap(silithusMap);
        if (map is null)
            return;
        const at = silithusAnnouncerAt[team];
        foreach (c; map.creaturesNear(Position(at[0], at[1], at[2], 0), 10))
            if (c.template_.entry == silithusAnnouncers[team] && c.ai !is null)
                return c.ai.sayFor(map, text, 0);
    }

    /// Asks the service how it stands (a cluster node starting).
    void ask()
    {
        context.services.call!(WorldPvpHost.current)(WorldPvpQuery(context.nodeId), (WorldPvp w) { heard(w); });
    }

    /// Each tick: once a second the players at the towers counted, and reported when the counts changed (or every
    /// few seconds while any are there).
    void tick(Duration elapsed)
    {
        sinceCounted += elapsed;
        sinceReported += elapsed;
        if (sinceCounted < 1.seconds)
            return;
        sinceCounted = Duration.zero;
        dressFlightMaster();
        uint[towerCount * 2] counts;
        foreach (session; players)
            if (session.worldPvpCounted)
                ++counts[session.worldPvpTower * 2 + session.worldPvpTeam];
        bool any;
        foreach (n; counts)
            any = any || n;
        if (counts == reported && !(any && sinceReported >= reportEvery))
            return;
        reported = counts;
        sinceReported = Duration.zero;
        context.services.call!(WorldPvpHost.present)(TowerPresence(context.nodeId, counts));
    }

    /// The banner's look a game object of world PvP has now (its art kit); 0 for one that is none of its.
    uint artKitOf(uint entry, float x, float y, float z) const
    {
        foreach (i, ref t; towers)
            if (entry == t.capturePoint || (entry == towerBanner
                    && (t.x - x) ^^ 2 + (t.y - y) ^^ 2 + (t.z - z) ^^ 2 <= bannerRange * bannerRange))
                return bannerArtKits[state.towers[i].holder];
        return 0;
    }

    /// The graveyards world PvP opens and closes (`closestGraveyard`'s `linkTeams`).
    const(uint[uint]) graveyardTeams() const
    {
        return [crownGuardGraveyard: state.crownGuardGraveyardTeam];
    }

    // --- what follows from a change ---

    /// The sessions this node simulates (in the world).
    private auto players()
    {
        import dmangos.world.character : Character;

        Character[] found;
        foreach (c; context.onlinePlayers())
            if (c.character !is null)
                found ~= c;
        return found;
    }

    /// Turns the banners this node simulates on the towers' map to their holders' colours.
    private void dressBanners()
    {
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.movement : Position;
        import dmangos.world.updatefields : GAMEOBJECT_ARTKIT;

        auto map = context.existingMap(towersMap);
        if (map is null)
            return;
        foreach (ref t; towers)
            foreach (o; map.objectsNear(Position(t.x, t.y, t.z, 0), bannerRange))
                if (auto go = cast(GameObject) o)
                {
                    const p = go.position;
                    const kit = artKitOf(go.spawn.entry, p.x, p.y, p.z);
                    if (kit && go.values.get!GAMEOBJECT_ARTKIT != kit)
                    {
                        go.values.set!GAMEOBJECT_ARTKIT(kit);
                        map.flushGameObject(go);
                    }
                }
    }

    /// Plaguewood's flight master, where this node simulates him, serves the tower's holder.
    private void dressFlightMaster()
    {
        import dmangos.world.movement : Position;
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

        const holder = state.towers[Tower.plaguewood].holder;
        auto map = context.existingMap(towersMap);
        if (holder == Holder.none || map is null)
            return;
        const faction = flightMasterFactions[teamOf(holder)];
        const t = &towers[Tower.plaguewood];
        foreach (c; map.creaturesNear(Position(t.x, t.y, t.z, 0), 60))
            if (c.template_.entry == williamKielar && c.values.get!UNIT_FIELD_FACTIONTEMPLATE != faction)
            {
                c.factionTemplate = context.client.factionTemplates.lookup(faction);
                c.values.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
                map.flushCreature(c);
            }
    }

    /// The capture point of `tower`, if this node simulates it.
    private auto capturePoint(Tower tower)
    {
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.movement : Position;

        GameObject found;
        if (auto map = context.existingMap(towersMap))
        {
            const t = &towers[tower];
            foreach (o; map.objectsNear(Position(t.x, t.y, t.z, 0), 5))
                if (auto go = cast(GameObject) o)
                    if (go.spawn.entry == t.capturePoint)
                        found = go;
        }
        return found;
    }

    /// `team` took `tower`: its players counted there rewarded, the zone told, and (where the capture point is
    /// simulated) its event run.
    private void towerTaken(Tower tower, PvpTeam team, bool all)
    {
        import dmangos.world.dbscripts : DbScriptType;

        foreach (session; players)
            if (session.worldPvpTower == tower && session.worldPvpCounted && session.worldPvpTeam == team)
                session.worldPvpRewardCapture(towers[tower].questCredit);
        defenseNotice(towers[tower].takenText[team]);
        if (all)
            defenseNotice(allTowersText[team]);
        if (auto go = capturePoint(tower))
            context.startScript(DbScriptType.event, towers[tower].capturedEvent[team], context.map(towersMap), go.guid, 0);
    }

    /// `team` lost `tower`: what its capture brought goes (where it is simulated).
    private void towerLost(Tower tower, PvpTeam team)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.movement : Position;

        auto map = context.existingMap(towersMap);
        if (map is null)
            return;
        void dismiss(const(uint)[] entries, Position around, float range)
        {
            ulong[] gone;
            foreach (c; map.creaturesNear(around, range))
                foreach (e; entries)
                    if (c.template_.entry == e)
                        gone ~= c.guid;
            foreach (guid; gone)
                map.removeObject(guid);
        }
        const t = &towers[tower];
        if (tower == Tower.plaguewood)
            dismiss([williamKielar], Position(t.x, t.y, t.z, 0), 60);
        else if (tower == Tower.eastwall) // the squad marches from Eastwall to Northpass: between them, and at both
            dismiss(eastwallSquads[team][], Position(2850, -4417, 90, 0), 600);
    }

    /// `broadcast_text` row `text` in the Eastern Plaguelands' defense channel, to this node's players in the zone.
    private void defenseNotice(uint text)
    {
        import dmangos.world.npcdata : BroadcastText;

        const said = context.data.npcs.broadcastTexts.get(text, BroadcastText.init);
        if (said.maleText.length == 0 && said.femaleText.length == 0)
            return;
        zoneDefenseNotice(zoneEasternPlaguelands, said.text(false));
    }

    /// `words` in `zone`'s defense channel (`SMSG_DEFENSE_MESSAGE`: the zone, the text's length with its end, the
    /// text), to this node's players in the zone.
    private void zoneDefenseNotice(uint zone, string words)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.opcodes : Opcode;

        if (words.length == 0)
            return;
        ByteWriter w;
        w.put(zone);
        w.put(cast(uint)(words.length + 1));
        w.putCString(words);
        const body_ = w.data.idup;
        foreach (session; players)
            if (session.character.data.zone == zone)
                session.deliver(Opcode.SMSG_DEFENSE_MESSAGE, body_);
    }
}

// Two nodes: the service runs on the first. The second asks how it stands, its players at Crown Guard are counted on
// the first (with the first's own), it hears the tower taken, and its turn-ins are counted there. Its report ages out
// when it stops renewing it (its node lost): the first's player alone then holds the slider.
unittest
{
    import dmangos.cluster.protocol : ServiceCall, ServiceNews, ServiceReply;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.context : WorldContext;
    import dmangos.world.testclient : newDatabase;
    import dmangos.world.testdata : testClientData, testWorldData;

    WorldContext node()
    {
        auto client = testClientData();
        WorldConfig config;
        config.logoutDelay = 0;
        return new WorldContext(config, newDatabase(), testWorldData(client), client);
    }

    auto a = node(), b = node();
    b.services.stopAll();
    a.services.self = a.nodeId = 1;
    b.services.self = b.nodeId = 2;
    a.services.placement = b.services.placement = (ServiceKind) => cast(ushort) 1;
    b.services.sendCall = (ushort, const ref ServiceCall c) { a.services.receiveCall(2, c); return true; };
    a.services.sendReply = (ushort, const ref ServiceReply r) { b.services.receiveReply(1, r); return true; };
    a.services.sendNews = (const ref ServiceNews n) { b.services.receiveNews(1, n); };

    a.services.local!WorldPvpHost().state.silithus.collected = [3, 4];
    b.worldPvp.ask();
    assert(b.worldPvp.state.silithus.collected == [3, 4], "asked");

    // An Alliance player at Crown Guard on a, two Horde players there on b: the Horde leads by one.
    TowerPresence onA = {node: 1}, onB = {node: 2};
    onA.counts[Tower.crownGuard * 2] = 1;          // an Alliance player on a
    onB.counts[Tower.crownGuard * 2 + 1] = 2;      // two Horde players on b
    foreach (_; 0 .. 200) // out of the neutral band at 120 s, and on
    {
        a.services.call!(WorldPvpHost.present)(onA);
        b.services.call!(WorldPvpHost.present)(onB);
        a.services.tick(1.seconds);
    }
    assert(a.worldPvp.state.towers[Tower.crownGuard].holder == Holder.horde, "counted together: a lead of one");
    assert(b.worldPvp.state.towers[Tower.crownGuard].holder == Holder.horde, "heard on b");
    assert(b.worldPvp.graveyardTeams[crownGuardGraveyard] == 67, "b's dead go to the Horde's graveyard");

    // b goes quiet: after its report ages out, a's Alliance player pushes the slider back.
    const slider = a.worldPvp.state.towers[Tower.crownGuard].slider;
    foreach (_; 0 .. 45) // 15 seconds more for b's last report, then 30 without it
    {
        a.services.call!(WorldPvpHost.present)(onA);
        a.services.tick(1.seconds);
    }
    assert(a.worldPvp.state.towers[Tower.crownGuard].slider > slider && b.worldPvp.state.towers[Tower.crownGuard]
        .look == TowerLook.hordeContested);

    b.services.call!(WorldPvpHost.silithyst)(SilithystTurnIn(PvpTeam.alliance));
    assert(a.worldPvp.state.silithus.collected == [4, 4] && b.worldPvp.state.silithus.collected == [4, 4]);
}

// ---------------------------------------------------------------------------------------------------
// A player's side
// ---------------------------------------------------------------------------------------------------

/// World PvP on the player's side: `Character` mixes it in.
mixin template WorldPvpHandlers()
{
    import dmangos.world.worldpvp;

    /// The tower whose capture bar the player sees (in range of it), -1 for none; and whether it counts there (alive,
    /// flagged for PvP, seen: not stealthed or invisible).
    package int worldPvpTower = -1;
    /// ditto
    package bool worldPvpCounted;
    // Whether it carried Silithyst at the last look, and where.
    private bool carriedSilithyst;

    /// The player's side.
    package @property PvpTeam worldPvpTeam()
    {
        import dmangos.world.clientdata : Team;

        return context.client.teamForRace(player.data.race) == Team.horde ? PvpTeam.horde : PvpTeam.alliance;
    }

    /// World PvP's world states for this player in `zone` (`SMSG_INIT_WORLD_STATES`).
    package uint[2][] worldPvpStates(uint zone)
    {
        return context.worldPvp.state.worldStates(zone, zone == zoneEasternPlaguelands ? worldPvpTower : -1);
    }

    package int conditionWorldState(uint id)
    {
        foreach (field; worldPvpStates(player.data.zone))
            if (field[0] == id)
                return cast(int) field[1];
        return context.conditionMapWorldState(map, id);
    }

    /**
     * Each second (the zone check): the tower in range and the capture bar, the zones' buffs, and the Silithyst (the
     * PvP flag while it is carried; a mound where it was lost otherwise than at its camp).
     */
    package void worldPvpCheck()
    {
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.player : DeathState;
        import dmangos.world.spellids : AuraType;
        import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

        if (player is null)
            return;
        const p = player.position;
        const alive = player.deathState == DeathState.alive;
        const near = player.data.map == towersMap && player.data.zone == zoneEasternPlaguelands
            ? towerInRange(p.x, p.y, p.z) : -1;
        if (near != worldPvpTower)
        {
            const before = context.worldPvp.state.worldStates(zoneEasternPlaguelands, worldPvpTower);
            worldPvpTower = near;
            if (player.data.zone == zoneEasternPlaguelands)
                sendWorldPvpChanges(before, context.worldPvp.state.worldStates(zoneEasternPlaguelands, near));
        }
        const flying = (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight) != 0;
        worldPvpCounted = near >= 0 && alive && pvp.isPvP && !flying && !player.auras.has(AuraType.modStealth)
            && !player.auras.has(AuraType.modInvisibility);
        worldPvpBuffs();

        const carrying = player.auras.find(spellSilithyst) !is null;
        if (carrying)
        {
            pvp.updatePvP(true);
            flushPlayerChanges();
        }
        else if (carriedSilithyst && player.data.zone == zoneSilithus)
            dropSilithyst(); // mounting (or stealth, an immunity) took it: it falls here
        carriedSilithyst = carrying;
    }

    /// The service's news: what changed in this player's zone, and its buffs.
    package void worldPvpHeard(const ref WorldPvp before)
    {
        const zone = player.data.zone;
        const tower = zone == zoneEasternPlaguelands ? worldPvpTower : -1;
        sendWorldPvpChanges(before.worldStates(zone, tower), context.worldPvp.state.worldStates(zone, tower));
        worldPvpBuffs();
    }

    /// `SMSG_UPDATE_WORLD_STATE` for each state that differs.
    private void sendWorldPvpChanges(const(uint[2])[] before, const(uint[2])[] now)
    {
        import dmangos.world.map : packetBody;
        import dmangos.world.packets : ServerUpdateWorldState;
        import dmangos.world.opcodes : Opcode;

        uint[uint] was;
        foreach (s; before)
            was[s[0]] = s[1];
        foreach (s; now)
            if (was.get(s[0], uint.max) != s[1])
                deliver(Opcode.SMSG_UPDATE_WORLD_STATE, packetBody(ServerUpdateWorldState(s[0], s[1])));
    }

    /// Echoes of Lordaeron and Cenarion Favor as the state and the player's zone say: the rank it should have on (if
    /// alive), every other off.
    private void worldPvpBuffs()
    {
        import dmangos.world.player : DeathState;

        const state = &context.worldPvp.state;
        const team = worldPvpTeam, zone = player.data.zone;
        const alive = player.deathState == DeathState.alive;
        const echoes = state.echoes(team, zone);
        foreach (ref ranks; echoesOfLordaeron)
            foreach (spell; ranks)
                if (spell != echoes && player.auras.find(spell) !is null)
                    battlegroundRemoveAuraHere(spell);
        if (echoes && alive && player.auras.find(echoes) is null)
            battlegroundCastHere(echoes);
        const favor = state.favor(team, zone);
        const hasFavor = player.auras.find(spellCenarionFavor) !is null;
        if (hasFavor && !favor)
            battlegroundRemoveAuraHere(spellCenarionFavor);
        else if (favor && !hasFavor && alive)
            battlegroundCastHere(spellCenarionFavor);
    }

    /// `team` took the tower the player was counted at: bonus honor and the quest credit.
    package void worldPvpRewardCapture(uint questCredit)
    {
        import dmangos.world.honor : HonorType;

        addHonorPoints(captureHonor, HonorType.honorable);
        scriptKillCredit(questCredit, 0);
        flushPlayerChanges();
    }

    /**
     * A world PvP object used (before its usual use): a Silithyst geyser or mound gives the dust to a player in
     * Silithus without it (true: nothing happens otherwise); a Lordaeron Shrine serves its side only. Whether the use is
     * done with.
     */
    package bool worldPvpObjectUsed(imported!"dmangos.world.gameobject".GameObject go)
    {
        const entry = go.spawn.entry;
        if (entry == silithystGeyser || entry == silithystMound)
        {
            if (player.data.zone != zoneSilithus || player.auras.find(spellSilithyst) !is null)
                return true;
            battlegroundCastHere(spellSilithyst);
            if (player.auras.find(spellSilithyst) is null)
                return true;
            carriedSilithyst = true;
            pvp.updatePvP(true);
            flushPlayerChanges();
            return false; // the goober's own use follows: it is used up
        }
        foreach (team, shrine; shrineEntries)
            if (entry == shrine)
                return team != worldPvpTeam;
        return false;
    }

    /// The player walked into an area trigger: at its side's camp, its Silithyst is turned in. Whether it was a
    /// camp's.
    package bool worldPvpAreaTrigger(uint id)
    {
        import dmangos.world.honor : HonorType;

        import std.math : round;
        import dmangos.world.honor : rankOneHonorAt;
        import dmangos.world.player : DeathState;

        const team = worldPvpTeam;
        if (id != turnInTriggers[0] && id != turnInTriggers[1])
            return false;
        if (id != turnInTriggers[team] || player.deathState != DeathState.alive
                || player.auras.find(spellSilithyst) is null)
            return true;
        carriedSilithyst = false;
        battlegroundRemoveAuraHere(spellSilithyst);
        battlegroundCastHere(spellTracesOfSilithyst);
        reputations.modifyReputation(factionCenarionCircle, reputations.reputationGain(Reputations.ReputationSource.spell, silithystReputation,
            factionCenarionCircle, 0));
        addHonorPoints(silithystHonorUnits * round(rankOneHonorAt(player.data.level)), HonorType.honorable);
        scriptKillCredit(turnInCredit[team], 0);
        flushPlayerChanges();
        context.services.call!(WorldPvpHost.silithyst)(SilithystTurnIn(team));
        return true;
    }

    /**
     * The player leaves the world (logging out, or its connection lost) carrying Silithyst: it falls where the player
     * was, a mound for anyone, and goes from the player (its aura ends on leaving the world: `AuraInterruptFlags`
     * 0x80000; a lost connection must not keep it either).
     */
    package void worldPvpLeaving()
    {
        if (player is null || player.auras.find(spellSilithyst) is null)
            return;
        dropSilithyst();
        battlegroundRemoveAuraHere(spellSilithyst);
    }

    /// The player dies (before its auras go): its Silithyst falls where it does.
    package void worldPvpDied()
    {
        if (player.auras.find(spellSilithyst) !is null)
            dropSilithyst();
    }

    /// A mound of Silithyst where the player is, for anyone to pick up (its drop spell's).
    private void dropSilithyst()
    {
        carriedSilithyst = false;
        battlegroundCastHere(spellSilithystDrop);
    }

    /**
     * Fungal Vale (1.12.1: "Players who die in the Fungal Vale will now port to the Crown Guard Tower graveyard if
     * their faction controls that tower"): the graveyard for a player who died in `area`, if world PvP decides it.
     */
    package const(imported!"dmangos.world.clientdata".WorldSafeLocsEntry)* worldPvpGraveyard(uint area)
    {
        if (area != areaFungalVale || context.worldPvp.state.towers[Tower.crownGuard].holder != holderOf(worldPvpTeam))
            return null;
        return context.client.worldSafeLocs.lookup(crownGuardGraveyard);
    }
}
