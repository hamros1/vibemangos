/**
 * Alterac Valley's rules as patch 1.12 had them: graveyards and towers, mines, captains and generals.
 *
 * Killing the other side's general (Vanndar Stormpike, Drek'Thar) wins: the only way to. Reinforcements (600 a side,
 * lost by deaths, towers and captains) and the end's honor for towers and captains still standing came with patch
 * 2.3.0 (13 November 2007): the 1.12.1 client's WorldStateUI.dbc has no reinforcement counter for the valley either.
 *
 * Fifteen nodes: seven graveyards (Snowfall in the middle starts neutral) and eight towers, four a side. A
 * player who opens an enemy (or neutral) node's banner assaults it: five minutes later (as for Snowfall's
 * first capture) it falls. A graveyard then is the assaulting side's; a tower is destroyed, for good, and the
 * marshal (or warmaster) it sheltered near the general goes. A side that opens its own banner on a node the
 * other side assaults defends it; a node whose assault was finished cannot be taken back. An assaulted
 * graveyard serves nobody.
 *
 * Two mines, Irondeep in the north and Coldtooth in the south, start neutral: killing the mine's boss gives it
 * to the killer's side; twenty minutes later its old owners take it back (it is neutral again).
 *
 * At the end each side earns reputation for the graveyards and mines it holds. All as CMaNGOS has it (`BattleGroundAV`), whose world states, events
 * and texts the database's spawns use; the herald's lines are the battleground's messages here, as Arathi
 * Basin's are.
 *
 * The turn-ins (docs/FORMULAS.md, "Alterac Valley's turn-ins"): each side's armor scraps, twenty a turn-in, upgrade its
 * graveyards' defenders at 500, 1000 and 1500 (seasoned, veteran, champion: the defenders' events' second numbers
 * 1 to 3), and from the first upgrade its general cries General's Warcry (28418 .. 28420, a rank an upgrade) every two
 * minutes; 200 Storm Crystals (the Alliance's) or Stormpike Soldier's Blood (the Horde's), one or five a turn-in, call
 * the summoner and guards to the Field of Strife. Ten allies channel their altar to call Ivus or Lokholar. The
 * lord fights there for ten minutes before advancing on the enemy base. The cavalry, the fleets and the mines' ground
 * assault are not yet: their commanders' orders have no gossip in the database.
 *
 * Events (the map's battleground spawns): a node's banner and defenders are event1 = the node, event2 = its
 * owner * 2 + its state (0 assaulted, 1 held; owner 0 the Alliance, 1 the Horde, 2 neutral); a graveyard's
 * defenders also event1 = 15 + the node, event2 = owner * 4; the mines' creatures 50 + the mine and their
 * bosses 46 + the mine, event2 the owner; the marshals 52 to 59; a captain's death 63, 64.
 */
module dmangos.world.alterac;

import core.time : Duration, minutes, msecs, seconds;

import dmangos.world.battleground;
import dmangos.world.gameobject : GameObject;
import dmangos.world.creature : Creature;
import dmangos.world.character : Character;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : ChatType;

/// The nodes (`AVNodeIds`): graveyards 0 to 6, towers 7 to 14.
enum ubyte nodeFirstAid = 0, nodeStormpikeGrave = 1, nodeStoneheartGrave = 2, nodeSnowfall = 3,
    nodeIcebloodGrave = 4, nodeFrostwolfGrave = 5, nodeFrostwolfHut = 6, nodeDunBaldarSouth = 7,
    nodeDunBaldarNorth = 8, nodeIcewing = 9, nodeStoneheartBunker = 10, nodeIcebloodTower = 11,
    nodeTowerPoint = 12, nodeFrostwolfEast = 13, nodeFrostwolfWest = 14;
/// ditto
enum size_t nodeCount = 15;

/// A node's or a mine's owner: the sides' indexes, and nobody's.
enum ubyte ownerAlliance = 0, ownerHorde = 1, ownerNeutral = 2;

/// A node's state (`AVStates`).
enum ubyte stateAssaulted = 0, stateHeld = 1;

/// Reinforcements: at the start, the warning, and what a captain and a tower cost.

/// How long an assault takes; Snowfall's first, from neutral: five minutes each in 1.12 (patch 2.3.0: "Towers and
/// Graveyards in Alterac Valley are now captured in 4 minutes (down from 5)"; docs/FORMULAS.md "Battlegrounds").
enum Duration captureTime = 5.minutes, snowfallFirstCapture = 5.minutes;
/// A mine's tick, and how long a side holds it.
enum Duration mineHeld = 20.minutes;

/// Snowfall's neutral icon.
enum uint stateSnowfallNeutral = 1966;
/// Each node's icon: the Alliance's, its assault's (grey); the Horde's, its assault's.
immutable uint[4][nodeCount] nodeIcons = [
    [1325, 1326, 1327, 1328], [1333, 1335, 1334, 1336], [1302, 1304, 1301, 1303], [1341, 1343, 1342, 1344],
    [1346, 1348, 1347, 1349], [1337, 1339, 1338, 1340], [1329, 1331, 1330, 1332],
    [1361, 1375, 1370, 1378], [1362, 1374, 1371, 1379], [1363, 1376, 1372, 1380], [1364, 1377, 1373, 1381],
    [1368, 1390, 1385, 1395], [1367, 1389, 1384, 1394], [1366, 1388, 1383, 1393], [1365, 1387, 1382, 1392]];
/// Each mine's icon: the Alliance's, the Horde's, neutral.
immutable uint[3][2] mineIcons = [[1358, 1359, 1360], [1355, 1356, 1357]];

/// Each node's first owner and its graveyard (0: a tower).
immutable ubyte[nodeCount] initialOwners = [0, 0, 0, 2, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1];
/// ditto
immutable uint[nodeCount] nodeGraveyards = [751, 689, 729, 169, 749, 690, 750, 0, 0, 0, 0, 0, 0, 0, 0];
/// The sides' own graveyards (always theirs).
immutable uint[2] sideGraveyards = [611, 610];

/// The sides' factions: the Stormpike Guard, the Frostwolf Clan.
immutable uint[2] factions = [730, 729];

/// Events beyond the nodes'.
enum ubyte eventGraveDefenders = 15, eventMineBosses = 46, eventCaptainAlliance = 48, eventCaptainHorde = 49,
    eventMine = 50, eventMarshals = 52, eventHerald = 60, eventBossAlliance = 61, eventBossHorde = 62,
    eventCaptainDeadAlliance = 63, eventCaptainDeadHorde = 64;

/// The creatures whose deaths matter.
enum uint npcVanndar = 11948, npcDrekThar = 11946, npcCaptainStonehearth = 11949, npcCaptainGalvangar = 11947;
/// The mines' bosses: neutral, the Alliance's, the Horde's (north, south).
immutable uint[3][2] mineBosses = [[11657, 13078, 13079], [11677, 13086, 13088]];

/// Kill credit for the quests: a mine taken, a graveyard or tower assaulted.
enum uint creditMine = 13796, creditGraveyard = 13756, creditTower = 13778;
/// The spell that completes the sides' "the general is dead" quests.
enum uint spellGeneralDead = 23658;

/// Honor (in bonus honor units) and reputation: a general, a captain, a tower; surviving ones at the end; graves and
/// mines held at the end. The second of each pair is a Call to Arms weekend's. The honor: Wowpedia "Honor system
/// (pre-2.0 formulas)", Alterac Valley's table (the general 4, the others 1).
enum uint honorBoss = 4, honorCaptain = 1, honorTower = 1;
/// ditto
immutable int[2] repBoss = [350, 525], repCaptain = [125, 185], repTower = [12, 18], repOwnedGrave = [12, 18],
    repOwnedMine = [24, 36];
/// ditto: the battle's completion, to both sides.
immutable uint[2] honorMapComplete = [0, 4];

/// The messages (`mangos_string`): taken, assaulted, defended (towers, graveyards), a mine taken and the mines'
/// names, the nodes' names, near losing, a general dead; the sides' names.
enum uint stringTowerTaken = 759, stringTowerAssaulted = 760, stringTowerDefended = 761,
    stringGraveTaken = 762, stringGraveDefended = 763, stringGraveAssaulted = 764, stringMineTaken = 765;
/// ditto
immutable uint[2] stringMines = [766, 767];
/// ditto
immutable uint[nodeCount] stringNodes = [768, 771, 773, 775, 777, 779, 782, 769, 770, 772, 774, 776, 778, 780, 781];
/// ditto
immutable uint[2] stringGeneralDead = [790, 789], stringSides = [650, 651];
/// "Only the Alliance (the Horde) can use that portal"
enum uint stringOnlyAlliancePortal = 752, stringOnlyHordePortal = 753;

/// The sounds: an assault by a side, a side's good news, a tower defended, near losing.
immutable uint[2] soundAssaults = [8212, 8174], soundGood = [8173, 8213];
/// ditto
enum uint soundTowerDefended = 8192;

/// The area triggers out of the valley: the Alliance's two, the Horde's.
enum uint triggerAllianceExit1 = 95, triggerAllianceExit2 = 2608, triggerHordeExit = 2606;

/// The armor scraps quests (twenty scraps each), the Alliance's then the Horde's (Murgot Deepforge's, Smith Regzar's).
immutable uint[2][2] questsScraps = [[7223, 6781], [7224, 6741]];
/// Scraps a turn-in, and an upgrade's (each of the three).
enum uint scrapsPerTurnIn = 20, scrapsPerUpgrade = 500, maxUpgrades = 3;
/// The general's cry, a rank an upgrade (10%, 20%, 30% more damage), and how often it is cried (its duration).
immutable uint[maxUpgrades] spellsGeneralsWarcry = [28_418, 28_419, 28_420];
/// ditto
enum Duration warcryEvery = 2.minutes;
/// The generals, by side.
immutable uint[2] generals = [npcVanndar, npcDrekThar];

/// The elemental lords' offerings (Arch Druid Renferal's Storm Crystals, Primalist Thurloga's Stormpike Soldier's
/// Blood): the quests taking one, and five; the lord each side calls; how many call it.
immutable uint[2] questsOfferOne = [6881, 6801], questsOfferFive = [7386, 7385];
/// ditto
immutable uint[2] lords = [13_419, 13_256];
/// ditto
enum uint offeringsToCall = 200;
/// The Alliance Circle of Calling and the Horde Altar of Summoning on the Field of Strife.
immutable float[4][2] lordsAt = [[-199.993f, -343.217f, 6.77662f, 3.68265f], [-360.139f, -133.403f, 26.4856f, 4.41568f]];
immutable uint[2] summoners = [13442, 13236], escorts = [13443, 13284], altars = [178670, 178465];

/// The scoreboard's columns (`WorldStateUI.dbc`'s, map 30, in order): "Graveyards Assaulted", "Graveyards Defended",
/// "Towers Assaulted", "Towers Defended", "Mines Captured" ("Number of times a deathblow was dealt to the lieutenant of
/// an enemy mine"), "Leaders Killed" ("Number of enemy NPC officers you have killed"), "Secondary Objectives" ("Number
/// of secondary units activated").
enum size_t scoreGravesAssaulted = 0, scoreGravesDefended = 1, scoreTowersAssaulted = 2, scoreTowersDefended = 3,
    scoreMines = 4, scoreLeaders = 5, scoreSecondary = 6;

/**
 * The sides' officers ("enemy NPC officers"), the Alliance's then the Horde's: the generals, the captains, the
 * lieutenants and commanders (`creature_template` 13137 .. 13154, 13296 .. 13320 by faction: 1216 the Stormpike's,
 * 1214 the Frostwolf's), and the towers' marshals and warmasters (14762 .. 14777).
 */
immutable uint[][2] officers = [
    [11948, 11949, 13138, 13139, 13296, 13297, 13298, 13299, 13300, 13318, 13319, 13320,
        14762, 14763, 14764, 14765, 14766, 14767, 14768, 14769],
    [11946, 11947, 13137, 13140, 13143, 13144, 13145, 13146, 13147, 13152, 13153, 13154,
        14770, 14771, 14772, 14773, 14774, 14775, 14776, 14777]];

/// The side whose officer `entry` is, or `ownerNeutral` for none.
ubyte officerSide(uint entry) pure nothrow @nogc @safe
{
    foreach (ubyte side; 0 .. 2)
        foreach (e; officers[side])
            if (e == entry)
                return side;
    return ownerNeutral;
}

/// A node (`AVNodeInfo`).
struct Node
{
    ubyte totalOwner; /// who holds it for good (an assault finished): no assault of theirs, and no taking back
    ubyte owner;
    ubyte previousOwner;
    ubyte state = stateHeld;
    Duration left;    /// until an assault finishes
    uint icon;        /// its icon now
}

/// Whether node `n` is a tower.
bool isTower(size_t n) pure nothrow @nogc @safe
{
    return nodeGraveyards[n] == 0;
}

/// See the module documentation.
final class AlteracRules : BattlegroundRules
{
    import dmangos.world.alteracassaults : ValleyAssaults;
    mixin ValleyAssaults;
    import dmangos.world.alteracair : ValleyAir;
    mixin ValleyAir;

    override void started(Battleground copy)
    {
        placeFocuses(copy);
    }

    override void playerLeaving(Battleground copy, ulong who)
    {
        clearCaptured(copy, who);
    }

    Node[nodeCount] nodes;
    ubyte[2] mineOwner = [ownerNeutral, ownerNeutral];
    Duration[2] mineHeldLeft;
    ubyte[2] homeTowers = [4, 4];   /// each side's towers still standing
    bool[2] captainDead;
    /// Whether a player may open a banner: alive; tests stand in for it.
    bool delegate(ulong) alive;
    uint[2] scraps;                 /// armor scraps turned in, by side
    ubyte[2] upgrades;              /// the graveyards' defenders' upgrades, by side (0 to 3)
    Duration[2] warcryLeft;         /// until the general cries again
    uint[2] offerings;              /// the lords' offerings, by side
    private struct Procession
    {
        ulong leader, altar, contributor, lord;
        Duration marchLeft;
        Duration nextCheck;
    }
    Procession[2] processions;
    bool[2] lordCalled;             /// once a battle

    override void reset(Battleground copy)
    {
        foreach (side; 0 .. 2)
        {
            copy.graveyardTeams[sideGraveyards[side]] = side == 0 ? teamAllianceLink : teamHordeLink;
            foreach (owner; 0 .. 3)
                copy.setWorldState(mineIcons[side][owner], owner == ownerNeutral);
            copy.activeEvents[cast(ubyte)(eventMine + side)] = ownerNeutral;
            copy.activeEvents[cast(ubyte)(eventMineBosses + side)] = ownerNeutral;
        }
        foreach (n; 0 .. nodeCount)
            foreach (icon; nodeIcons[n])
                copy.setWorldState(icon, 0);
        foreach (ubyte n; 0 .. nodeCount)
        {
            const owner = initialOwners[n];
            nodes[n] = Node(owner, owner, owner, stateHeld, Duration.zero,
                owner == ownerNeutral ? stateSnowfallNeutral : nodeIcons[n][owner * 2]);
            copy.setWorldState(nodes[n].icon, 1);
            copy.activeEvents[n] = eventOf(owner, stateHeld);
            if (!isTower(n))
            {
                copy.activeEvents[cast(ubyte)(eventGraveDefenders + n)] = defendersOf(owner);
                copy.graveyardTeams[nodeGraveyards[n]] = linkOf(owner);
            }
        }
        foreach (ubyte e; [eventCaptainAlliance, eventCaptainHorde, eventHerald, eventBossAlliance, eventBossHorde])
            copy.activeEvents[e] = 0;
        foreach (ubyte i; 0 .. 8)
            copy.activeEvents[cast(ubyte)(eventMarshals + i)] = 0;
    }

    override void tick(Battleground copy, Duration elapsed)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        if (copy.status != BattlegroundStatus.inProgress)
            return;
        updateAir(copy, elapsed);
        updateAssaults(copy, elapsed);
        foreach (ubyte side; 0 .. 2)
        {
            auto trail = &processions[side];
            if (offerings[side] >= offeringsToCall && !lordCalled[side])
                advanceProcession(copy, side, elapsed);
            if (trail.marchLeft > Duration.zero && (trail.marchLeft -= elapsed) <= Duration.zero)
            {
                auto map = copy.context.existingMap(copy.mapId, copy.instance);
                if (map !is null)
                    if (auto lord = map.creatureAt(trail.lord))
                        if (lord.alive)
                            sendToEnemyBase(copy, lord, side);
            }
        }
        foreach (ubyte mine; 0 .. 2)
        {
            const owner = mineOwner[mine];
            if (owner == ownerNeutral)
                continue;
            mineHeldLeft[mine] -= elapsed;
            if (mineHeldLeft[mine] <= Duration.zero)
                changeMineOwner(copy, mine, ownerNeutral);
        }
        foreach (ubyte n; 0 .. nodeCount)
            if (nodes[n].state == stateAssaulted)
            {
                nodes[n].left -= elapsed;
                if (nodes[n].left <= Duration.zero)
                    destroyed(copy, n);
            }
        foreach (ubyte side; 0 .. 2)
            if (upgrades[side])
            {
                warcryLeft[side] -= elapsed;
                if (warcryLeft[side] <= Duration.zero)
                    warcry(copy, side);
            }
    }

    /// The turn-ins: armor scraps upgrade the defenders; the offerings call the lord.
    override void questRewarded(Battleground copy, ulong who, uint quest)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        if (copy.status != BattlegroundStatus.inProgress || who !in copy.members)
            return;
        provision(copy, copy.members[who].team, quest, who);
        foreach (ubyte side; 0 .. 2)
        {
            if (quest == questsScraps[side][0] || quest == questsScraps[side][1])
            {
                scraps[side] += scrapsPerTurnIn;
                while (upgrades[side] < maxUpgrades && scraps[side] >= (upgrades[side] + 1) * scrapsPerUpgrade)
                    upgrade(copy, side);
            }
            else if (quest == questsOfferOne[side] || quest == questsOfferFive[side])
            {
                offerings[side] += quest == questsOfferFive[side] ? 5 : 1;
                if (!lordCalled[side] && offerings[side] >= offeringsToCall && !processions[side].contributor)
                {
                    processions[side].contributor = who;
                    advanceProcession(copy, side, Duration.zero);
                }
            }
        }
    }


    /// `HandleKillUnit`: the generals, the captains, the mines' bosses.
    override void creatureKilled(Battleground copy, uint entry, ulong killer)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        if (copy.status != BattlegroundStatus.inProgress)
            return;
        const weekend = copy.weekend ? 1 : 0;
        creditLeader(copy, entry, killer);
        switch (entry)
        {
        case npcVanndar, npcDrekThar:
            const winner = entry == npcVanndar ? ownerHorde : ownerAlliance;
            copy.castOnTeam(spellGeneralDead, winner);
            copy.rewardReputationToTeam(factions[winner], repBoss[weekend], winner);
            copy.rewardHonorToTeam(honorBoss, winner);
            copy.message(stringGeneralDead[1 - winner], ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
            copy.end(winner == ownerAlliance ? winnerAlliance : winnerHorde);
            return;
        case npcCaptainStonehearth, npcCaptainGalvangar:
            const loser = entry == npcCaptainStonehearth ? ownerAlliance : ownerHorde, winner = cast(ubyte)(1 - loser);
            captainDead[loser] = true;
            copy.rewardReputationToTeam(factions[winner], repCaptain[weekend], winner);
            copy.rewardHonorToTeam(honorCaptain, winner);
            copy.spawnEvent(loser == ownerAlliance ? eventCaptainDeadAlliance : eventCaptainDeadHorde, 0, true);
            return;
        default:
            foreach (ubyte mine; 0 .. 2)
                foreach (boss; mineBosses[mine])
                    if (entry == boss)
                        if (auto m = killer in copy.members)
                        {
                            if (mineOwner[mine] != m.team) // an enemy (or neutral) mine's: the deathblow counts
                                copy.addScore(killer, scoreMines);
                            changeMineOwner(copy, mine, m.team);
                        }
        }
    }

    /// `HandlePlayerClickedOnFlag`: a node's banner opened: an assault, or a defence.
    override bool objectUsed(Battleground copy, ulong who, GameObject go)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        if (disruptBeacon(copy, who, go))
            return true;
        foreach (ubyte side; 0 .. 2)
            if (go.template_.entry == altars[side])
            {
                if (go.guid == processions[side].altar && copy.status == BattlegroundStatus.inProgress)
                    joinLordRitual(copy, side, go, who);
                return true;
            }
        const event = copy.eventOf(go);
        if (event is null || (*event)[0] >= nodeCount)
            return false;
        auto m = who in copy.members;
        if (m is null || copy.status != BattlegroundStatus.inProgress
            || !(alive !is null ? alive(who) : copy.memberAlive(who)))
            return true;
        const n = (*event)[0];
        if ((*event)[1] % 2 == stateHeld)
            assault(copy, who, n, m.team);
        else
            defend(copy, who, n, m.team);
        return true;
    }

    override bool areaTrigger(Battleground copy, ulong who, uint trigger)
    {
        auto m = who in copy.members;
        if (m is null)
            return false;
        int side;
        if (trigger == triggerAllianceExit1 || trigger == triggerAllianceExit2)
            side = ownerAlliance;
        else if (trigger == triggerHordeExit)
            side = ownerHorde;
        else
            return false;
        if (m.team != side)
            copy.notify(who, side == ownerAlliance ? stringOnlyAlliancePortal : stringOnlyHordePortal);
        else
            copy.sendOut(who);
        return true;
    }

    override ubyte prematureWinner(Battleground copy)
    {
        // No reinforcements to compare in 1.12: the towers each side still has.
        return homeTowers[0] > homeTowers[1] ? winnerAlliance : homeTowers[1] > homeTowers[0] ? winnerHorde : winnerNone;
    }

    /// The end: the graveyards and mines held, the battle's completion (no reward for towers and captains standing:
    /// that came with patch 2.3.0).
    override void ending(Battleground copy, ubyte winner)
    {
        const weekend = copy.weekend ? 1 : 0;
        uint[2] graves, mines;
        foreach (ref node; nodes)
            if (node.state == stateHeld && node.owner != ownerNeutral)
                ++graves[node.owner]; // as CMaNGOS counts them: every node held (towers too)
        foreach (owner; mineOwner)
            if (owner != ownerNeutral)
                ++mines[owner];
        foreach (ubyte side; 0 .. 2)
        {
            if (graves[side])
                copy.rewardReputationToTeam(factions[side], graves[side] * repOwnedGrave[weekend], side);
            if (mines[side])
                copy.rewardReputationToTeam(factions[side], mines[side] * repOwnedMine[weekend], side);
            if (honorMapComplete[weekend])
                copy.rewardHonorToTeam(honorMapComplete[weekend], side);
        }
    }

    /// The event2 of a graveyard's defenders held by `owner`: its side's, at its upgrades.
    ubyte defendersOf(ubyte owner) const pure nothrow @nogc @safe
    {
        return cast(ubyte)(owner * 4 + (owner < 2 ? upgrades[owner] : 0));
    }

    /// A node's event2 for its owner and state.
    static ubyte eventOf(ubyte owner, ubyte state) pure nothrow @nogc @safe
    {
        return cast(ubyte)(owner * 2 + state);
    }

private:
    static uint linkOf(ubyte owner) pure nothrow @nogc @safe
    {
        return owner == ownerAlliance ? teamAllianceLink : owner == ownerHorde ? teamHordeLink : teamInvalidLink;
    }

    static ChatType chatOf(ubyte side) pure nothrow @nogc @safe
    {
        return side == ownerAlliance ? ChatType.CHAT_MSG_BG_SYSTEM_ALLIANCE : ChatType.CHAT_MSG_BG_SYSTEM_HORDE;
    }

    /// `killer` killed an enemy officer: "Leaders Killed" goes up.
    static void creditLeader(Battleground copy, uint entry, ulong killer)
    {
        const side = officerSide(entry);
        if (side == ownerNeutral)
            return;
        if (auto m = killer in copy.members)
            if (m.team != side)
                copy.addScore(killer, scoreLeaders);
    }

    /// The node's icon is now `icon`.
    void setIcon(Battleground copy, ubyte n, uint icon)
    {
        copy.setWorldState(nodes[n].icon, 0);
        nodes[n].icon = icon;
        copy.setWorldState(icon, 1);
    }

    /// The node's banner and defenders as it now stands (`PopulateNode`; the defenders of their first kind).
    void populate(Battleground copy, ubyte n)
    {
        auto node = &nodes[n];
        if (!isTower(n) && node.owner != ownerNeutral)
        {
            const defenders = cast(ubyte)(eventGraveDefenders + n);
            if (node.state == stateHeld)
                copy.spawnEvent(defenders, defendersOf(node.owner), true);
            else if (node.previousOwner != ownerNeutral)
                copy.spawnEvent(defenders, defendersOf(node.previousOwner), false);
        }
        copy.spawnEvent(n, eventOf(node.owner, node.state), true);
    }

    /**
     * `side`'s armor scraps reached an upgrade: the defenders of each graveyard it holds are the next kind (their
     * event's second number one up), and its general cries the next rank of General's Warcry, then every two minutes.
     */
    void upgrade(Battleground copy, ubyte side)
    {
        ++upgrades[side];
        foreach (ubyte n; 0 .. nodeCount)
            if (!isTower(n) && nodes[n].owner == side && nodes[n].state == stateHeld)
                copy.spawnEvent(cast(ubyte)(eventGraveDefenders + n), defendersOf(side), true);
        warcry(copy, side);
    }

    /// `side`'s general cries General's Warcry of its upgrades' rank.
    void warcry(Battleground copy, ubyte side)
    {
        warcryLeft[side] = warcryEvery;
        copy.creaturesCast(generals[side], spellsGeneralsWarcry[upgrades[side] - 1]);
    }

    private void sendToEnemyBase(Battleground copy, Creature unit, ubyte side)
    {
        import dmangos.script.api : Location;
        foreach (ref spawn; copy.context.data.creatureSpawns)
            if (spawn.map == copy.mapId && spawn.entry == generals[1 - side])
            {
                unit.ai.hostMoveTo(Location(spawn.x, spawn.y, spawn.z, spawn.orientation), 0, true);
                copy.context.map(copy.mapId, copy.instance).wake(unit.guid);
                return;
            }
    }

    private void advanceProcession(Battleground copy, ubyte side, Duration elapsed)
    {
        import dmangos.script.api : Location;
        import dmangos.world.map : MapObject;
        auto trail = &processions[side];
        trail.nextCheck -= elapsed;
        if (trail.nextCheck > Duration.zero)
            return;
        trail.nextCheck = 1.seconds;
        auto map = copy.context.existingMap(copy.mapId, copy.instance);
        if (map is null)
            return;
        auto leader = map.creatureAt(trail.leader);
        if (trail.leader && (leader is null || !leader.alive))
        {
            if (trail.altar)
                map.removeObject(trail.altar);
            *trail = Procession.init;
            offerings[side] = 0;
            return;
        }
        if (trail.altar)
            return;
        const dest = lordsAt[side];
        if (leader is null)
        {
            // The hand-in is at the summoner in its home camp. Use the existing NPCs, including their combat AI.
            map.forEachObject((MapObject obj) {
                auto c = cast(Creature) obj;
                if (c !is null && c.alive && c.template_.entry == summoners[side])
                    leader = c;
            });
            if (leader is null)
                return;
            trail.leader = leader.guid;
            auto goal = Location(dest[0], dest[1], dest[2], dest[3]);
            leader.ai.hostMoveTo(goal, 0, true);
            map.wake(leader.guid);
            uint rank;
            foreach (guard; map.creaturesNear(leader.position, 45))
                if (guard.alive && guard.template_.entry == escorts[side])
                {
                    auto flank = goal;
                    flank.x += ++rank * 2;
                    guard.ai.hostMoveTo(flank, 0, true);
                    map.wake(guard.guid);
                }
            return;
        }
        const at = leader.position;
        if (leader.ai.inCombat || (at.x - dest[0]) ^^ 2 + (at.y - dest[1]) ^^ 2 + (at.z - dest[2]) ^^ 2 > 25)
            return;
        const pos = Position(dest[0], dest[1], dest[2], dest[3]);
        if (auto go = copy.context.summonWildGameObject(map, altars[side], pos, 0))
        {
            trail.altar = go.guid;
            foreach (c; map.creaturesNear(pos, 25))
                if (c.alive && (c is leader || c.template_.entry == escorts[side]))
                    c.ai.castFor(map, 11206, leader.guid, true);
        }
    }

    private void joinLordRitual(Battleground copy, ubyte side, GameObject go, ulong who)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.rituals : RitualData;
        auto map = copy.context.existingMap(copy.mapId, copy.instance);
        if (map is null || lordCalled[side])
            return;
        auto leader = map.creatureAt(processions[side].leader);
        if (leader is null || !leader.alive)
            return;
        Character participant(ulong guid)
        {
            const member = guid in copy.members;
            if (member is null || member.team != side)
                return null;
            auto c = cast(Character) copy.onlinePlayerOf(guid);
            if (c is null || c.currentMap !is map || !c.character.alive)
                return null;
            const p = c.character.position, at = go.position;
            return (p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2 <= 25 ? c : null;
        }
        auto newcomer = participant(who);
        if (newcomer is null)
            return;
        const ritual = RitualData.of(go.template_.data[]);
        size_t count;
        foreach (guid; go.ritualUsers)
            if (auto c = participant(guid))
                if (c.channelsRitualAt(go.guid))
                    go.ritualUsers[count++] = guid;
        go.ritualUsers.length = count;
        if (!go.ritualUsers.canFind(who) && newcomer.channelRitualAt(go, ritual.animSpell))
            go.ritualUsers ~= who;
        if (go.ritualUsers.length < ritual.participants)
            return;
        const at = go.position;
        auto trail = &processions[side];
        trail.lord = copy.summonAt(lords[side], at.x, at.y, at.z, at.orientation);
        if (!trail.lord)
            return;
        trail.marchLeft = 10.minutes;
        lordCalled[side] = true;
        processions[side].altar = 0;
        foreach (guid; go.ritualUsers)
            if (auto c = participant(guid))
                c.endChannel(false);
        map.removeObject(go.guid);
        copy.addScore(who, scoreSecondary);
    }

    /// `ProcessPlayerAssaultsPoint`
    void assault(Battleground copy, ulong who, ubyte n, ubyte side)
    {
        auto node = &nodes[n];
        if (node.owner == side || node.totalOwner == side)
            return;
        const tower = isTower(n);
        if (!tower)
            copy.graveyardTeams[nodeGraveyards[n]] = teamInvalidLink;
        copy.message(tower ? stringTowerAssaulted : stringGraveAssaulted, chatOf(side), 0,
            [copy.serverString(stringNodes[n]), copy.serverString(stringSides[side])]);
        copy.playSound(soundAssaults[side]);
        copy.addScore(who, tower ? scoreTowersAssaulted : scoreGravesAssaulted);
        copy.killCreditToGroupOf(who, tower ? creditTower : creditGraveyard);
        // `AssaultNode`
        node.left = node.previousOwner != ownerNeutral ? captureTime : snowfallFirstCapture;
        node.previousOwner = node.owner;
        node.owner = side;
        node.state = stateAssaulted;
        setIcon(copy, n, nodeIcons[n][side * 2 + 1]);
        populate(copy, n);
    }

    /// `ProcessPlayerDefendsPoint`
    void defend(Battleground copy, ulong who, ubyte n, ubyte side)
    {
        auto node = &nodes[n];
        if (node.owner == side || node.state != stateAssaulted)
            return;
        if (node.totalOwner == ownerNeutral && n == nodeSnowfall) // Snowfall's first capture, contested
            return assault(copy, who, n, side);
        if (node.previousOwner != side)
            return;
        const tower = isTower(n);
        copy.message(tower ? stringTowerDefended : stringGraveDefended, chatOf(side), 0,
            [copy.serverString(stringNodes[n]), copy.serverString(stringSides[side])]);
        copy.playSound(tower ? soundTowerDefended : soundGood[side]);
        copy.addScore(who, tower ? scoreTowersDefended : scoreGravesDefended);
        // `DefendNode`
        node.previousOwner = node.owner;
        node.owner = side;
        node.state = stateHeld;
        node.left = Duration.zero;
        if (!tower)
            copy.graveyardTeams[nodeGraveyards[n]] = linkOf(side);
        populate(copy, n);
        setIcon(copy, n, nodeIcons[n][side * 2]);
    }

    /// `ProcessPlayerDestroyedPoint`: an assault finished.
    void destroyed(Battleground copy, ubyte n)
    {
        auto node = &nodes[n];
        const side = node.owner, other = cast(ubyte)(1 - side);
        const weekend = copy.weekend ? 1 : 0;
        node.totalOwner = side;
        node.previousOwner = side;
        node.state = stateHeld;
        node.left = Duration.zero;
        populate(copy, n);
        setIcon(copy, n, nodeIcons[n][side * 2]);
        if (isTower(n))
        {
            copy.spawnEvent(cast(ubyte)(eventMarshals + n - nodeDunBaldarSouth), 0, false);
            copy.rewardReputationToTeam(factions[side], repTower[weekend], side);
            copy.rewardHonorToTeam(honorTower, side);
            copy.message(stringTowerTaken, chatOf(side), 0,
                [copy.serverString(stringNodes[n]), copy.serverString(stringSides[side])]);
            if (homeTowers[other])
                --homeTowers[other];
        }
        else
        {
            copy.message(stringGraveTaken, chatOf(side), 0,
                [copy.serverString(stringNodes[n]), copy.serverString(stringSides[side])]);
            copy.graveyardTeams[nodeGraveyards[n]] = linkOf(side);
        }
    }

    /// `ChangeMineOwner`
    void changeMineOwner(Battleground copy, ubyte mine, ubyte owner)
    {
        if (mineOwner[mine] == owner)
            return;
        copy.setWorldState(mineIcons[mine][mineOwner[mine]], 0);
        mineOwner[mine] = owner;
        copy.setWorldState(mineIcons[mine][owner], 1);
        copy.spawnEvent(cast(ubyte)(eventMine + mine), owner, true);
        copy.spawnEvent(cast(ubyte)(eventMineBosses + mine), owner, true);
        if (owner == ownerNeutral)
            return;
        mineHeldLeft[mine] = mineHeld;
        copy.message(stringMineTaken, chatOf(owner), 0,
            [copy.serverString(stringSides[owner]), copy.serverString(stringMines[mine])]);
        copy.playSound(soundGood[owner]);
        copy.killCreditToTeam(owner, creditMine);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The nodes: an assault, a defence, a tower destroyed for good; a graveyard taken.
unittest
{
    import core.time : MonoTime, minutes, seconds;
    import dmangos.world.bgqueue : BattlegroundStatus, BattlegroundType;
    import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto copy = context.battlegrounds.open(778, BattlegroundType.alteracValley);
    auto rules = cast(AlteracRules) copy.rules;
    assert(rules !is null);
    assert(3127 !in copy.worldStates && 3128 !in copy.worldStates, "no reinforcements in 1.12");
    assert(copy.worldStates[stateSnowfallNeutral] == 1 && copy.graveyardTeams[nodeGraveyards[nodeIcebloodGrave]] == teamHordeLink);
    assert(copy.activeEvents[nodeIcebloodTower] == 3 && copy.activeEvents[eventMarshals + 4] == 0);
    copy.testing = true;
    copy.members[7] = Battleground.Member(0);
    copy.members[8] = Battleground.Member(1);
    copy.start();
    rules.alive = (ulong) => true;

    GameObject banner(uint guid, ubyte n, ubyte event2)
    {
        auto t = GameObjectTemplate.init;
        t.entry = 178940;
        t.type = 10;
        context.data.gameObjectTemplates[178940] = t;
        context.data.gameObjectBattleEvents[guid] = [n, event2];
        const spawn = GameObjectSpawn(guid, 178940, 30, 0, 0, 0);
        return new GameObject(spawn, 178940 in context.data.gameObjectTemplates);
    }

    // The Alliance assaults Iceblood Tower (the Horde's, held); the Horde defends it; assaulted again, it falls.
    auto held = banner(96000, nodeIcebloodTower, AlteracRules.eventOf(ownerHorde, stateHeld));
    assert(rules.objectUsed(copy, 7, held));
    assert(rules.nodes[nodeIcebloodTower].state == stateAssaulted && copy.members[7].extra[scoreTowersAssaulted] == 1);
    assert(copy.worldStates[nodeIcons[nodeIcebloodTower][1]] == 1, "the Alliance's grey icon");
    auto assaulted = banner(96001, nodeIcebloodTower, AlteracRules.eventOf(ownerAlliance, stateAssaulted));
    assert(rules.objectUsed(copy, 8, assaulted));
    assert(rules.nodes[nodeIcebloodTower].owner == ownerHorde && rules.nodes[nodeIcebloodTower].state == stateHeld);
    assert(copy.members[8].extra[scoreTowersDefended] == 1);
    assert(rules.objectUsed(copy, 7, held));
    copy.tick(5.minutes + 1.seconds);
    assert(rules.nodes[nodeIcebloodTower].totalOwner == ownerAlliance, "destroyed");
    assert(rules.homeTowers[ownerHorde] == 3);
    assert((eventMarshals + 4) !in copy.activeEvents, "its warmaster went");
    assert(!rules.objectUsed(copy, 8, assaulted) || rules.nodes[nodeIcebloodTower].owner == ownerAlliance,
        "and it cannot be taken back");

    // A graveyard: assaulted, nobody's; taken, the Alliance's.
    auto grave = banner(96002, nodeIcebloodGrave, AlteracRules.eventOf(ownerHorde, stateHeld));
    assert(rules.objectUsed(copy, 7, grave));
    assert(copy.graveyardTeams[nodeGraveyards[nodeIcebloodGrave]] == teamInvalidLink);
    copy.tick(5.minutes + 1.seconds);
    assert(copy.graveyardTeams[nodeGraveyards[nodeIcebloodGrave]] == teamAllianceLink);
    assert(copy.activeEvents[eventGraveDefenders + nodeIcebloodGrave] == ownerAlliance * 4, "its defenders");
}

// A captain, a mine; deaths cost nothing (no reinforcements in 1.12); a general's death ends it, the only way.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.world.bgqueue : BattlegroundStatus, BattlegroundType;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto copy = context.battlegrounds.open(779, BattlegroundType.alteracValley);
    auto rules = cast(AlteracRules) copy.rules;
    copy.testing = true;
    copy.members[7] = Battleground.Member(0);
    copy.members[8] = Battleground.Member(1);
    copy.start();

    foreach (_; 0 .. 700)
        rules.playerKilled(copy, 7, 8);
    assert(copy.status == BattlegroundStatus.inProgress, "700 deaths: still on");
    rules.creatureKilled(copy, npcCaptainGalvangar, 7);
    assert(rules.captainDead[ownerHorde] && copy.status == BattlegroundStatus.inProgress);
    assert(copy.activeEvents[eventCaptainDeadHorde] == 0);

    // The Horde kills Irondeep's boss: its mine.
    rules.creatureKilled(copy, mineBosses[0][0], 8);
    assert(rules.mineOwner[0] == ownerHorde && copy.worldStates[mineIcons[0][ownerHorde]] == 1);
    assert(copy.activeEvents[eventMine] == ownerHorde);

    // The scoreboard's columns: the mine's deathblow (its own mine's boss again: nothing), the officers killed (the
    // captain above, a Horde lieutenant; an Alliance one by the Alliance: nothing).
    assert(copy.members[8].extra[scoreMines] == 1 && copy.members[7].extra[scoreLeaders] == 1);
    rules.creatureKilled(copy, mineBosses[0][2], 8);
    assert(copy.members[8].extra[scoreMines] == 1, "its own mine");
    rules.creatureKilled(copy, 13145, 7); // Lieutenant Grummus, the Frostwolf's
    rules.creatureKilled(copy, 13138, 7); // Lieutenant Spencer, the Stormpike's own
    rules.creatureKilled(copy, 14764, 8); // the Icewing Marshal, by the Horde
    assert(copy.members[7].extra[scoreLeaders] == 2 && copy.members[8].extra[scoreLeaders] == 1);

    context.config.battlegroundScoreStatistics = true;
    rules.creatureKilled(copy, npcDrekThar, 7);
    assert(copy.status == BattlegroundStatus.waitLeave && copy.winner == winnerAlliance, "Drek'Thar dead: the Alliance");
    assert(copy.members[7].extra[scoreLeaders] == 3, "the general an officer too");

    // Its seven columns on the scoreboard, and kept (`Battleground.ScoreStatistics`).
    {
        import dmangos.bytes : ByteReader;

        auto r = ByteReader(copy.scoreboard());
        assert(r.read!ubyte == 1 && r.read!ubyte == winnerAlliance && r.read!uint == 2);
        foreach (i; 0 .. 2)
        {
            const guid = r.read!ulong;
            r.read!uint; // rank
            foreach (_; 0 .. 4)
                r.read!uint;
            assert(r.read!uint == 7);
            uint[7] columns;
            foreach (ref c; columns)
                c = r.read!uint;
            assert(columns == copy.members[guid].extra);
        }
    }
    assert(db.pvpStatsRows.length == 1 && db.pvpStatsRows[0].winner == winnerAlliance);
    assert(db.pvpStatsRows.length == 1, "kept once");
    assert(db.pvpStatsRows[0].type == BattlegroundType.alteracValley && db.pvpStatsPlayerRows[0].length == 2);
    foreach (p; db.pvpStatsPlayerRows[0])
        assert(p.attr[] == copy.members[p.guid].extra[0 .. 5] && p.deaths == copy.members[p.guid].deaths);
}

// The turn-ins: armor scraps upgrade a side's graveyards' defenders three times (and its general cries); the
// offerings call its lord once, at 200, a secondary objective for the one whose turn-in did.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.world.bgqueue : BattlegroundType;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto copy = context.battlegrounds.open(780, BattlegroundType.alteracValley);
    auto rules = cast(AlteracRules) copy.rules;
    copy.testing = true;
    copy.members[7] = Battleground.Member(0);
    copy.members[8] = Battleground.Member(1);
    const allianceDefenders = cast(ubyte)(eventGraveDefenders + nodeStormpikeGrave),
        hordeDefenders = cast(ubyte)(eventGraveDefenders + nodeFrostwolfGrave);
    rules.questRewarded(copy, 7, questsScraps[ownerAlliance][0]);
    assert(rules.scraps[ownerAlliance] == 0, "before the battle: nothing");
    copy.start();

    foreach (i; 0 .. 24)
        rules.questRewarded(copy, 7, questsScraps[ownerAlliance][i % 2]);
    assert(rules.scraps[ownerAlliance] == 480 && rules.upgrades[ownerAlliance] == 0
        && copy.activeEvents[allianceDefenders] == 0);
    rules.questRewarded(copy, 7, questsScraps[ownerAlliance][0]);
    assert(rules.upgrades[ownerAlliance] == 1 && copy.activeEvents[allianceDefenders] == 1, "seasoned defenders");
    assert(copy.activeEvents[hordeDefenders] == 4, "the Horde's are as they were");
    assert(rules.warcryLeft[ownerAlliance] == warcryEvery);
    copy.tick(30.seconds);
    assert(rules.warcryLeft[ownerAlliance] == warcryEvery - 30.seconds && rules.warcryLeft[ownerHorde] == Duration.zero);
    foreach (i; 0 .. 100)
        rules.questRewarded(copy, 7, questsScraps[ownerAlliance][1]);
    assert(rules.upgrades[ownerAlliance] == maxUpgrades && copy.activeEvents[allianceDefenders] == 3, "champions");
    // A graveyard taken by the Horde gets the Horde's defenders as they are (none upgraded).
    assert(rules.defendersOf(ownerHorde) == 4 && rules.defendersOf(ownerAlliance) == 3);

    // Thirty-nine offerings of five and four of one: 199; then one more calls Lokholar, once.
    foreach (_; 0 .. 39)
        rules.questRewarded(copy, 8, questsOfferFive[ownerHorde]);
    foreach (_; 0 .. 4)
        rules.questRewarded(copy, 8, questsOfferOne[ownerHorde]);
    assert(rules.offerings[ownerHorde] == 199 && !rules.lordCalled[ownerHorde]);
    rules.questRewarded(copy, 8, questsOfferOne[ownerHorde]);
    assert(!rules.lordCalled[ownerHorde] && rules.offerings[ownerHorde] == offeringsToCall);
    rules.questRewarded(copy, 8, questsOfferFive[ownerHorde]);
    assert(copy.members[8].extra[scoreSecondary] == 0 && !rules.lordCalled[ownerAlliance], "offerings alone do not summon the lord");
}
