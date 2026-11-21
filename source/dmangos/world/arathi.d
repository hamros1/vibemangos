/**
 * Arathi Basin's rules: five bases, 2000 resources win.
 *
 * Each base (the stables, the blacksmith, the farm, the lumber mill, the gold mine) has a banner. A
 * player who opens a neutral or enemy banner assaults the base: it is contested by its side for a
 * minute, then the side's. Opening one's own side's banner on a base the other side contests (one
 * that was one's own) defends it at once. Each side's bases bring resources at a pace set by how many
 * it holds (10 every 12, 9, 6 or 3 seconds for one to four; 30 a second for all five); every 330
 * resources (200 on its holiday) bring the side a bonus honor unit and every 200 (150 on its holiday), 10 reputation (the League of
 * Arathor, the Defilers). The first to 2000 wins, and a unit more; at 1800 everyone is told it is near.
 *
 * A base's banners are the map's battleground events: event1 is the base, event2 its state (0
 * neutral, 1 contested by the Alliance, 2 by the Horde, 3 the Alliance's, 4 the Horde's), shown three
 * seconds after a change. A base's graveyard is its holder's; the sides' own graveyards are theirs from
 * the start, their start rooms' until then.
 */
module dmangos.world.arathi;

import core.time : Duration, msecs, seconds;

import dmangos.world.battleground;
import dmangos.world.gameobject : GameObject;
import dmangos.world.opcodes : ChatType;

/// The bases (`ABNodes`): their battleground event numbers.
enum ubyte nodeStables = 0, nodeBlacksmith = 1, nodeFarm = 2, nodeLumberMill = 3, nodeGoldMine = 4;
/// ditto
enum size_t nodeCount = 5;

/// A base's state (`ABNodeStatus`), its banner's event2.
enum ubyte statusNeutral = 0, statusContested = 1, statusOccupied = 3; // + the side (0, 1)

/// `BG_AB_FLAG_CAPTURING_TIME`, and how long a new banner takes to show.
enum Duration captureTime = 60.seconds, bannerDelay = 3.seconds;

/// `BG_AB_MAX_TEAM_SCORE`, `BG_AB_WARNING_NEAR_VICTORY_SCORE`
enum uint maxResources = 2000, nearVictory = 1800;

/// Resources each `honorInterval` bring a bonus honor unit (Wowpedia "Honor system (pre-2.0 formulas)": "every time
/// your team collects a multiple of 330 resource", 200 on the holiday); each `reputationInterval`, `reputationGain`.
/// The reputation: WoWWiki "Arathi Basin" (2006-11): "Collecting multiples of 200 resources ... = 10 rep (total 100 rep if
/// you win)", "on the Battlegrounds Holiday weekend ... multiples of 150" (docs/FORMULAS.md "Battlegrounds").
enum uint honorInterval = 330, reputationInterval = 200;
/// The same on a Call to Arms weekend.
enum uint weekendHonorInterval = 200, weekendReputationInterval = 150;
/// ditto
enum int reputationGain = 10;

/// The sides' factions: the League of Arathor, the Defilers.
immutable uint[2] factions = [509, 510];

/// By bases held (0 to 5): the time between ticks, and the resources a tick brings.
immutable uint[6] tickIntervalsMs = [0, 12000, 9000, 6000, 3000, 1000];
/// ditto
immutable uint[6] tickPoints = [0, 10, 10, 10, 10, 30];

/// The world states: resources, bases held, the maximum and the warning.
enum uint stateResourcesAlliance = 1776, stateResourcesHorde = 1777, stateResourcesMax = 1780,
    stateResourcesWarning = 1955, stateOccupiedAlliance = 1779, stateOccupiedHorde = 1778;
/// ditto, by side
immutable uint[2] resourceStates = [stateResourcesAlliance, stateResourcesHorde];
/// ditto
immutable uint[2] occupiedStates = [stateOccupiedAlliance, stateOccupiedHorde];

/// Each base's map icon: neutral; held by a side; contested by a side.
immutable uint[nodeCount] neutralIcons = [1842, 1846, 1845, 1844, 1843];
/// ditto
immutable uint[nodeCount][2] heldIcons = [[1767, 1782, 1772, 1792, 1787], [1768, 1783, 1773, 1793, 1788]];
/// ditto
immutable uint[nodeCount][2] contestedIcons = [[1769, 1784, 1774, 1794, 1789], [1770, 1785, 1775, 1795, 1790]];

/// Each base's graveyard; the sides' own; their start rooms'.
immutable uint[nodeCount] nodeGraveyards = [895, 894, 893, 897, 896];
/// ditto
immutable uint[2] sideGraveyards = [898, 899];
/// ditto
immutable uint[2] startGraveyards = [890, 889];

/// The exit portals' area triggers.
enum uint triggerAllianceExit = 3948, triggerHordeExit = 3949;

/// The messages: the sides' names, the bases', taken, defended, assaulted, claimed, near victory.
immutable uint[2] stringSides = [650, 651];
/// ditto
immutable uint[nodeCount] stringNodes = [652, 653, 654, 655, 656];
/// ditto
enum uint stringTaken = 657, stringDefended = 658, stringAssaulted = 659, stringClaimed = 660;
/// ditto
immutable uint[2] stringNearVictory = [664, 665];
/// "Only the Alliance (the Horde) can use that portal"
enum uint stringOnlyAlliancePortal = 752, stringOnlyHordePortal = 753;

/// The sounds: a base claimed; captured by a side; assaulted by a side; a side near victory.
enum uint soundClaimed = 8192;
/// ditto
immutable uint[2] soundCaptured = [8173, 8213], soundAssaulted = [8212, 8174], soundNearVictory = [8457, 8456];

/// The quest credit spells of four and of five bases held.
enum uint spellFourBases = 24061, spellFiveBases = 24064;

/// The scoreboard's columns: bases assaulted, bases defended.
enum size_t scoreAssaulted = 0, scoreDefended = 1;

/// See the module documentation.
final class ArathiRules : BattlegroundRules
{
    ubyte[nodeCount] status;        /// each base's state
    ubyte[nodeCount] previous;      /// and the one before
    Duration[nodeCount] captureLeft; /// until a contested base is its side's
    Duration[nodeCount] bannerLeft; /// until its banner shows ...
    ubyte[nodeCount] bannerStatus;  /// ... for this state
    uint[nodeCount] icon;           /// its map icon now
    Duration[2] sinceTick;          /// each side's time towards its next resources
    uint[2] towardsHonor, towardsReputation;
    bool warned;                    /// near victory said
    /// Whether a player may open a banner (`CanUseBattleGroundObject`): alive; tests stand in for it.
    bool delegate(ulong) alive;

    override void reset(Battleground copy)
    {
        foreach (side; 0 .. 2)
        {
            copy.setWorldState(resourceStates[side], 0);
            copy.setWorldState(occupiedStates[side], 0);
            foreach (n; 0 .. nodeCount)
            {
                copy.setWorldState(heldIcons[side][n], 0);
                copy.setWorldState(contestedIcons[side][n], 0);
            }
            copy.graveyardTeams[sideGraveyards[side]] = side == 0 ? teamAllianceLink : teamHordeLink;
        }
        copy.setWorldState(stateResourcesMax, maxResources);
        copy.setWorldState(stateResourcesWarning, nearVictory);
        foreach (ubyte n; 0 .. nodeCount)
        {
            icon[n] = neutralIcons[n];
            copy.setWorldState(icon[n], 1);
            copy.activeEvents[n] = statusNeutral;
            copy.graveyardTeams[nodeGraveyards[n]] = teamInvalidLink;
        }
    }

    override void started(Battleground copy)
    {
        copy.graveyardTeams[startGraveyards[0]] = teamInvalidLink;
        copy.graveyardTeams[startGraveyards[1]] = teamInvalidLink;
    }

    override void tick(Battleground copy, Duration elapsed)
    {
        uint[2] held;
        foreach (ubyte n; 0 .. nodeCount)
        {
            if (bannerLeft[n] > Duration.zero)
            {
                bannerLeft[n] -= elapsed;
                if (bannerLeft[n] <= Duration.zero)
                    copy.spawnEvent(n, bannerStatus[n], true);
            }
            if (captureLeft[n] > Duration.zero)
            {
                captureLeft[n] -= elapsed;
                if (captureLeft[n] <= Duration.zero)
                    taken(copy, n);
            }
            foreach (side; 0 .. 2)
                if (status[n] == statusOccupied + side)
                    ++held[side];
        }
        foreach (ubyte side; 0 .. 2)
        {
            const bases = held[side];
            if (bases == 0)
                continue;
            sinceTick[side] += elapsed;
            const interval = tickIntervalsMs[bases].msecs;
            if (sinceTick[side] <= interval)
                continue;
            sinceTick[side] -= interval;
            const points = tickPoints[bases];
            uint value = copy.worldStates.get(resourceStates[side], 0) + points;
            if (value > maxResources)
                value = maxResources;
            towardsHonor[side] += points;
            towardsReputation[side] += points;
            const repEvery = copy.weekend ? weekendReputationInterval : reputationInterval;
            const honorEvery = copy.weekend ? weekendHonorInterval : honorInterval;
            if (towardsReputation[side] >= repEvery)
            {
                copy.rewardReputationToTeam(factions[side], reputationGain, side);
                towardsReputation[side] -= repEvery;
            }
            if (towardsHonor[side] >= honorEvery)
            {
                copy.rewardHonorToTeam(1, side);
                towardsHonor[side] -= honorEvery;
            }
            if (!warned && value > nearVictory)
            {
                copy.message(stringNearVictory[side], ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
                copy.playSound(soundNearVictory[side]);
                warned = true;
            }
            copy.setWorldState(resourceStates[side], value);
        }
        if (copy.worldStates.get(stateResourcesAlliance, 0) >= maxResources)
            copy.end(winnerAlliance);
        else if (copy.worldStates.get(stateResourcesHorde, 0) >= maxResources)
            copy.end(winnerHorde);
    }

    /// `HandlePlayerClickedOnFlag`: a base's banner opened.
    override bool objectUsed(Battleground copy, ulong who, GameObject go)
    {
        import dmangos.world.bgqueue : BattlegroundStatus;

        const event = copy.eventOf(go);
        if (event is null || (*event)[0] >= nodeCount)
            return false;
        auto m = who in copy.members;
        if (m is null || copy.status != BattlegroundStatus.inProgress
            || !(alive !is null ? alive(who) : copy.memberAlive(who)))
            return true;
        const n = (*event)[0], side = m.team;
        const other = cast(ubyte)(1 - side);
        size_t score;
        uint sound, text;
        uint newIcon;
        bool claimed;
        if (status[n] == statusNeutral)
        {
            score = scoreAssaulted;
            newIcon = contestedIcons[side][n];
            previous[n] = status[n];
            status[n] = cast(ubyte)(statusContested + side);
            captureLeft[n] = captureTime;
            text = stringClaimed;
            claimed = true;
            sound = soundClaimed;
        }
        else if (status[n] == statusContested || status[n] == statusContested + 1)
        {
            if (status[n] == statusContested + side)
                return true; // already its side's assault
            if (previous[n] < statusOccupied)
            {
                score = scoreAssaulted;
                newIcon = contestedIcons[side][n];
                previous[n] = status[n];
                status[n] = cast(ubyte)(statusContested + side);
                captureLeft[n] = captureTime;
                text = stringAssaulted;
            }
            else
            {
                score = scoreDefended;
                newIcon = heldIcons[side][n];
                previous[n] = status[n];
                status[n] = cast(ubyte)(statusOccupied + side);
                captureLeft[n] = Duration.zero;
                text = stringDefended;
                captured(copy, n, side);
            }
            sound = soundAssaulted[side];
        }
        else
        {
            if (status[n] == statusOccupied + side)
                return true; // its own
            score = scoreAssaulted;
            newIcon = contestedIcons[side][n];
            previous[n] = status[n];
            status[n] = cast(ubyte)(statusContested + side);
            captureLeft[n] = captureTime;
            text = stringAssaulted;
            sound = soundAssaulted[side];
            copy.setWorldState(occupiedStates[other], copy.worldStates.get(occupiedStates[other], 0) - 1);
            copy.graveyardTeams[nodeGraveyards[n]] = teamInvalidLink;
        }
        copy.addScore(who, score);
        showBanner(n, status[n]);
        setIcon(copy, n, newIcon);
        string[] args = [copy.serverString(stringNodes[n])];
        if (claimed)
            args ~= copy.serverString(stringSides[side]);
        copy.message(text, side == 0 ? ChatType.CHAT_MSG_BG_SYSTEM_ALLIANCE : ChatType.CHAT_MSG_BG_SYSTEM_HORDE, who, args);
        copy.playSound(sound);
        return true;
    }

    override bool areaTrigger(Battleground copy, ulong who, uint trigger)
    {
        auto m = who in copy.members;
        if (m is null || (trigger != triggerAllianceExit && trigger != triggerHordeExit))
            return false;
        const side = trigger == triggerAllianceExit ? 0 : 1;
        if (m.team != side)
            copy.notify(who, side == 0 ? stringOnlyAlliancePortal : stringOnlyHordePortal);
        else
            copy.sendOut(who);
        return true;
    }

    override ubyte prematureWinner(Battleground copy)
    {
        const a = copy.worldStates.get(stateResourcesAlliance, 0), h = copy.worldStates.get(stateResourcesHorde, 0);
        return a > h ? winnerAlliance : h > a ? winnerHorde : winnerNone;
    }

    /// A bonus honor unit more to the winner (Wowpedia: "an additional bonus honor award for winning the match").
    override void ending(Battleground copy, ubyte winner)
    {
        if (winner == winnerAlliance)
            copy.rewardHonorToTeam(1, 0);
        else if (winner == winnerHorde)
            copy.rewardHonorToTeam(1, 1);
    }

private:
    /// A contested base's minute is over: its side's.
    void taken(Battleground copy, ubyte n)
    {
        const side = cast(ubyte)(status[n] - statusContested);
        previous[n] = status[n];
        status[n] = cast(ubyte)(statusOccupied + side);
        showBanner(n, status[n]);
        captured(copy, n, side);
        setIcon(copy, n, heldIcons[side][n]);
        copy.message(stringTaken, side == 0 ? ChatType.CHAT_MSG_BG_SYSTEM_ALLIANCE : ChatType.CHAT_MSG_BG_SYSTEM_HORDE, 0,
            [copy.serverString(stringSides[side]), copy.serverString(stringNodes[n])]);
        copy.playSound(soundCaptured[side]);
    }

    /// `ProcessNodeCapture`: one more base for `side`; four or five bring their quests' credit; its graveyard.
    void captured(Battleground copy, ubyte n, ubyte side)
    {
        const held = copy.worldStates.get(occupiedStates[side], 0) + 1;
        copy.setWorldState(occupiedStates[side], held);
        if (held >= 5)
            copy.castOnTeam(spellFiveBases, side);
        else if (held >= 4)
            copy.castOnTeam(spellFourBases, side);
        copy.graveyardTeams[nodeGraveyards[n]] = side == 0 ? teamAllianceLink : teamHordeLink;
    }

    /// `DoUpdateBanner` with its delay.
    void showBanner(ubyte n, ubyte state)
    {
        bannerLeft[n] = bannerDelay;
        bannerStatus[n] = state;
    }

    /// `DoUpdateNodeWorldstate`: the base's old icon off, the new one on.
    void setIcon(Battleground copy, ubyte n, uint newIcon)
    {
        copy.setWorldState(icon[n], 0);
        icon[n] = newIcon;
        copy.setWorldState(icon[n], 1);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The rules alone, on a copy with no map: claiming, taking, assaulting, defending, the resources.
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
    auto copy = context.battlegrounds.open(777, BattlegroundType.arathiBasin);
    auto rules = cast(ArathiRules) copy.rules;
    assert(rules !is null);
    assert(copy.worldStates[stateResourcesMax] == 2000 && copy.worldStates[neutralIcons[nodeStables]] == 1);
    assert(copy.graveyardTeams[sideGraveyards[0]] == teamAllianceLink && copy.graveyardTeams[nodeGraveyards[0]] == teamInvalidLink);
    copy.testing = true;
    // Two players, of each side, alive as far as the rules can tell: the copy's members (not online, so
    // the rules are driven directly; the alive check is passed over by making them the copy's own).
    copy.members[7] = Battleground.Member(0);
    copy.members[8] = Battleground.Member(1);
    copy.start();
    // A stables banner (event 0, neutral).
    auto t = GameObjectTemplate.init;
    t.entry = 180087;
    t.type = 10;
    context.data.gameObjectTemplates[180087] = t;
    context.data.gameObjectBattleEvents[95000] = [nodeStables, statusNeutral];
    const spawn = GameObjectSpawn(95000, 180087, 529, 0, 0, 0);
    auto banner = new GameObject(spawn, 180087 in context.data.gameObjectTemplates);

    rules.alive = (ulong) => true;
    assert(rules.objectUsed(copy, 7, banner));
    assert(rules.status[nodeStables] == statusContested + 0 && copy.members[7].extra[scoreAssaulted] == 1);
    assert(copy.worldStates[contestedIcons[0][nodeStables]] == 1 && copy.worldStates[neutralIcons[nodeStables]] == 0);
    copy.tick(61.seconds);
    assert(rules.status[nodeStables] == statusOccupied + 0, "the Alliance's after a minute");
    assert(copy.worldStates[stateOccupiedAlliance] == 1 && copy.graveyardTeams[nodeGraveyards[0]] == teamAllianceLink);

    // One base: 10 resources every 12 s; its banner shows three seconds after it changed hands.
    const before = copy.worldStates[stateResourcesAlliance];
    copy.tick(12.seconds + 1.msecs);
    assert(copy.worldStates[stateResourcesAlliance] > before);
    assert(copy.activeEvents[nodeStables] == statusOccupied, "its banner is the Alliance's");

    // The Horde assaults it; the Alliance defends it back at once.
    assert(rules.objectUsed(copy, 8, banner));
    assert(rules.status[nodeStables] == statusContested + 1 && copy.worldStates[stateOccupiedAlliance] == 0);
    assert(copy.graveyardTeams[nodeGraveyards[0]] == teamInvalidLink);
    assert(rules.objectUsed(copy, 7, banner));
    assert(rules.status[nodeStables] == statusOccupied + 0 && copy.members[7].extra[scoreDefended] == 1);

    // To 2000: the Alliance wins.
    copy.setWorldState(stateResourcesAlliance, 1995);
    copy.tick(13.seconds);
    assert(copy.status == BattlegroundStatus.waitLeave && copy.winner == winnerAlliance);
}
