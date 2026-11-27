/**
 * Battleground copies, sending players into them, and the players' battleground opcodes.
 *
 * The queues (`dmangos.world.bgqueue`) are a cluster service and decide who goes where. A copy of a
 * battleground runs on the node hosting its map, like a dungeon's copies: it is made when its first
 * invited player comes in through the queue, counts down two minutes from then, runs, and when it is
 * over sends its players back after two minutes. Players go back to where they were when they
 * accepted; leaving a copy before it is over gives Deserter (spell 26013), which keeps a player from
 * queueing for 15 minutes. A player who logs out inside keeps its place for five minutes.
 *
 * Each battleground's rules (flags, bases), its doors and spawns, the scoreboard's points and the
 * rewards come with the battlegrounds themselves; this module is what they all share.
 */
module dmangos.world.battleground;

import core.time : Duration, MonoTime, minutes, msecs, seconds;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.bgqueue;
import dmangos.world.characterdb : NameInfo;
import dmangos.world.database : BattlegroundReward, PvpStatsBattleground, PvpStatsPlayer;
import dmangos.world.context : WorldContext;
import dmangos.world.gameobject : GameObject;
import dmangos.world.map : Map, MapObject;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.packets : ServerNameQueryResponse;
import dmangos.world.player : Player;

/// Deserter: no queueing for 15 minutes.
enum uint spellDeserter = 26013;

/// `Waiting to Resurrect`: a ghost queued at a spirit guide.
enum uint spellWaitingToResurrect = 2584;

/// The countdown before the battle, the wait after it before everyone is sent out, and how long a player may be offline inside.
enum Duration startDelay = 2.minutes, endDelay = 2.minutes, offlineLimit = 300.seconds;

/// `mangos_string`: each battleground's "begins in 1 minute", "in 30 seconds" and "begin!" (by type).
immutable uint[3][4] countdownStrings = [[0, 0, 0], [784, 785, 786], [602, 603, 604], [661, 662, 663]];

/// `mangos_string` 600, 601: "The Alliance wins!", "The Horde wins!"
enum uint stringAllianceWins = 600, stringHordeWins = 601;

/// `mangos_string` 715: "You don't meet Battleground level requirements"
enum uint stringLevelRequirement = 715;

/// The sound of the start and of each team's win.
enum uint soundStart = 3439, soundAllianceWins = 8455, soundHordeWins = 8454;

/// What the scoreboard says of the winner.
enum ubyte winnerHorde = 0, winnerAlliance = 1, winnerNone = 2;

/// What `SMSG_GROUP_JOINED_BATTLEGROUND` says of a deserter.
enum int joinedDeserter = -2;

/// The number of extra scoreboard columns of each battleground.
immutable uint[4] extraScores = [0, 7, 2, 2];

/// A system message of a battleground (`CHAT_MSG_BG_SYSTEM_*`), as `SMSG_MESSAGECHAT`'s body.
ubyte[] battlegroundMessage(ChatType type, string text, ulong source = 0)
{
    import dmangos.world.queries : chatMessage;

    return chatMessage(type, Language.LANG_UNIVERSAL, source, text);
}

/// A graveyard's side for `Battleground.graveyardTeams` (the team's faction id), and closed.
enum uint teamAllianceLink = 469, teamHordeLink = 67, teamInvalidLink = 1;

/// The doors' event, and no event.
enum ubyte eventDoors = 254, eventNone = 255;

/// `mangos_string` 750, 751: the premature end's warnings (minutes, seconds).
enum uint stringClosingMinutes = 750, stringClosingSeconds = 751;

/// The original client removes spaces and tabs from realm names in chat.
private string chatRealmName(string realm)
{
    import std.array : replace;

    return realm.replace(" ", "").replace("\t", "");
}

/// How long a team may be short of players before it loses (the premature end).
enum Duration prematureFinish = 5.minutes;

/// The mark of honor spells of each battleground: a win's three marks, a loss's one.
immutable uint[2][4] markSpells = [[0, 0], [24955, 24954], [24951, 24950], [24953, 24952]];

/**
 * The bonus honor of `units` bonus honor units (BHU) to a player of `level` in battleground `t`: each unit is what a
 * rank-1 kill gives at the top of the player's bracket (Wowpedia "Honor system (pre-2.0 formulas)": 24 in 10-19,
 * 41, 68, 113, 189, and 198 at 60 and in Alterac Valley's 51-60; `rankOneHonorAt`).
 */
uint bonusHonor(uint units, const ref BattlegroundTemplate t, uint level) pure nothrow @nogc @safe
{
    import std.math : round;
    import dmangos.world.honor : rankOneHonorAt;

    const top = t.minLevel + 10 * (bracketOf(t, level) + 1) - 1;
    return units * cast(uint) round(rankOneHonorAt(top < t.maxLevel ? top : t.maxLevel));
}

unittest
{
    BattlegroundTemplate warsong = {minLevel: 10, maxLevel: 60}, alterac = {minLevel: 51, maxLevel: 60};
    assert(bonusHonor(1, warsong, 10) == 24 && bonusHonor(1, warsong, 19) == 24 && bonusHonor(1, warsong, 25) == 41);
    assert(bonusHonor(2, warsong, 55) == 378 && bonusHonor(2, warsong, 60) == 396, "a capture: 2 units");
    assert(bonusHonor(4, alterac, 51) == 792, "the general: 4 units, Alterac Valley's one bracket at 198");
}

/**
 * What one battleground adds to the copy every battleground shares: its events and world states, what
 * its objectives do. The default does nothing: a battleground without rules of its own has only doors.
 */
class BattlegroundRules
{
    void transferState(ref imported!"dmangos.world.battlegroundstate".BattlegroundState state) {}

    /// Before the first player comes: events and world states as they start.
    void reset(Battleground copy) {}

    /// The countdown is over, after the doors opened.
    void started(Battleground copy) {}

    /// Each tick while the battle is on.
    void tick(Battleground copy, Duration elapsed) {}

    /// `victim` died, killed by `killer` (0: no player), after the scores counted it.
    void playerKilled(Battleground copy, ulong victim, ulong killer) {}

    /// A creature of `entry` died in the copy, killed by `killer` (the player who tapped it; 0: none).
    void creatureKilled(Battleground copy, uint entry, ulong killer) {}

    /// `guid` leaves (or logs out while it runs): what it carried is dropped.
    void playerLeaving(Battleground copy, ulong guid) {}

    /// `who` used `go` (a flag, a banner); true if it was the battleground's to handle.
    bool objectUsed(Battleground copy, ulong who, GameObject go) { return false; }

    /// `who` lost the aura of `spell` (cancelled, purged by an immunity, dispelled).
    void auraLost(Battleground copy, ulong who, uint spell) {}

    /// Repair objective auras if a character checkpoint and the match were saved at different times.
    void playerRestored(Battleground copy, ulong guid) {}

    /// `who` was rewarded for `quest` in the copy (a turn-in).
    void questRewarded(Battleground copy, ulong who, uint quest) {}

    /// `who` walked into `trigger`; true if the trigger is the battleground's (handled).
    bool areaTrigger(Battleground copy, ulong who, uint trigger) { return false; }

    /// Who wins if it ends early; `winnerNone` leaves it to the player counts.
    ubyte prematureWinner(Battleground copy) { return winnerNone; }

    /// The battle is over: the battleground's own part, before the shared rewards.
    void ending(Battleground copy, ubyte winner) {}

    /// `MSG_BATTLEGROUND_PLAYER_POSITIONS`' body for a player of `team`.
    const(ubyte)[] playerPositions(Battleground copy, ubyte team)
    {
        ByteWriter w;
        w.put(uint(0));
        w.put(ubyte(0));
        return w.data.dup;
    }
}

/// A copy of a battleground on this node. See the module documentation.
final class Battleground
{
    immutable uint instance;
    immutable BattlegroundType type;
    BattlegroundStatus status = BattlegroundStatus.waitJoin;
    MonoTime made;
    /// The winner (`winnerNone` until it is over).
    ubyte winner = winnerNone;
    /// Its rules.
    BattlegroundRules rules;
    /// Each event's spawned state (`event1` -> `event2`); absent, none.
    ubyte[ubyte] activeEvents;
    /// Its world states, sent to players coming in.
    uint[uint] worldStates;
    /// Testing: too few players do not end it.
    /// Made during its Call to Arms weekend (holidays 283 to 285): more honor and reputation.
    bool weekend;
    bool testing;
    /// The graveyards it gives a team (469, 67) or closes (`teamInvalidLink`), by `world_safe_locs` id.
    uint[uint] graveyardTeams;
    /// Players waiting at a spirit guide (`Waiting to Resurrect`), and the guide.
    ulong[ulong] awaitingResurrection;
    /// The spirit guides' pulse: every 30 s from the copy's making (`Spirit Heal Channel`).
    enum Duration spiritHealInterval = 30.seconds;

    /// A player of the copy and its score.
    static struct Member
    {
        ubyte team;
        MonoTime offlineSince; /// set while logged out
        uint killingBlows, deaths, honorableKills, bonusHonor;
        uint[7] extra;
        NameInfo identity; /// retained with the score while the player is offline
    }

    /// Its players, by guid.
    Member[ulong] members;

    /// Each team's battleground raid: who leads it (by team), and who is in it (players who came alone).
    ulong[ubyte] raidLeaderOf;
    bool[ulong] inTeamRaid; /// ditto

    package WorldContext context;
    package @property bool crossRealm() const
    {
        import dmangos.world.battlegroup : battlegroupInstance;

        return context.battlegroup !is null && (instance & battlegroupInstance) != 0;
    }

    package auto memberSession(ulong guid)
    {
        if (crossRealm)
            return context.battlegroup.member(instance, guid);
        return context.onlinePlayer(guid);
    }

    /// The 1.12 client derives its foreign nameplate, chat and scoreboard labels from the separate realm field.
    package bool foreignName(ulong viewer, ulong guid, out ServerNameQueryResponse response)
    {
        if (!crossRealm || viewer !in members || (viewer >> 32) == (guid >> 32))
            return false;
        const member = guid in members;
        if (member is null || !member.identity.name.length)
            return false;
        auto realm = context.battlegroup.homeOf(guid);
        if (realm is null)
            return false;
        const id = member.identity;
        response = ServerNameQueryResponse(guid, id.name, realm.realmDisplayName, id.race, id.gender, id.classId);
        return true;
    }

    /// A name as the client shows it in chat, when the subject is from another realm.
    package string foreignChatName(ulong viewer, ulong subject)
    {
        ServerNameQueryResponse name;
        if (foreignName(viewer, subject, name))
            if (const realm = chatRealmName(name.realm))
                return name.name ~ "-" ~ realm;
        return null;
    }

    /// Resolves a realm-qualified whisper only among allies in this shared copy.
    package OnlinePlayer alliedWhisperTarget(ulong sender, string address)
    {
        import std.string : indexOf;
        import dmangos.world.battlegroup : battlegroupInstance;
        import dmangos.world.worlddata : toLowerName;

        const dash = address.indexOf('-');
        if (dash <= 0 || dash + 1 == address.length || !(instance & battlegroupInstance)
            || context.battlegroup is null)
            return null;
        const ally = sender in members;
        if (ally is null || ally.offlineSince != MonoTime.init || memberSession(sender) is null)
            return null;

        const name = toLowerName(address[0 .. dash]);
        const realmName = toLowerName(chatRealmName(address[dash + 1 .. $]));
        if (!realmName.length)
            return null;
        OnlinePlayer target;
        foreach (guid, ref member; members)
        {
            if (member.team != ally.team || member.offlineSince != MonoTime.init || (guid >> 32) == (sender >> 32))
                continue;
            if (auto who = memberSession(guid))
            {
                if (toLowerName(who.character.data.name) != name)
                    continue;
                auto realm = context.battlegroup.homeOf(guid);
                if (toLowerName(chatRealmName(realm.realmDisplayName)) != realmName)
                    continue;
                if (target !is null) // realm names can become ambiguous when spaces are removed
                    return null;
                target = who;
            }
        }
        return target;
    }

    private
    {
        Duration startLeft = startDelay;
        ubyte said;            // countdown messages said
        Duration endLeft;
        MonoTime emptySince;
        bool asking;           // whether the queue was asked if anyone may still come
        Duration prematureLeft;
        bool prematureCounting;
        uint lastWarning;      // the premature end's last warning, in seconds left
        bool checkpointDirty = true;
        bool checkpointRetired;
        ulong checkpointRevision;
        MonoTime nextCheckpoint;
        bool endingPending;
        ubyte pendingWinner;
        bool collectingFinalRewards;
        bool finalPublicationPending;
        ubyte finalBracket;
        struct FinalPlayer
        {
            PvpStatsPlayer score;
            BattlegroundReward reward;
        }
        FinalPlayer[ulong] finalPlayers;
        struct PowerUp
        {
            uint spawn;
            MonoTime readyAt;
        }
        PowerUp[ulong] powerUps; // standalone placement GUID or pool ID in the high half
        /// Each member's level when it last came in: its final reward when it is not online to ask.
        ubyte[ulong] memberLevels;
        /// Members offline only because the copy's worker crashed (not by their own logout): the match
        /// goes on without them, and their final rewards are still kept for them until they return or go.
        bool[ulong] offlineByCrash;
    }

    package void transferState(ref imported!"dmangos.world.battlegroundstate".BattlegroundState state,
        uint formatVersion = 3, bool durableSnapshot = false)
    {
        state.transfer(made, status, winner, activeEvents, worldStates, weekend, testing, graveyardTeams,
            awaitingResurrection, members, raidLeaderOf, inTeamRaid, startLeft, said, endLeft, emptySince,
            prematureLeft, prematureCounting, lastWarning, joinOrder_, pulses);
        rules.transferState(state);
        if (formatVersion >= 2)
            state.transfer(powerUps);
        if (formatVersion >= 3)
        {
            bool stillEnding = !durableSnapshot && endingPending;
            state.transfer(stillEnding, pendingWinner, finalPublicationPending, finalBracket, finalPlayers);
            if (state.reader !is null)
                endingPending = stillEnding;
        }
    }

    private MonoTime pausedAt;

    @property bool paused() const { return pausedAt != MonoTime.init; }

    package bool setPaused(bool enable)
    {
        if ((status != BattlegroundStatus.waitJoin && status != BattlegroundStatus.inProgress) || endingPending)
            return false;
        if (enable == paused)
            return true;

        const now = context.clock();
        if (enable)
            pausedAt = now;
        else
        {
            const elapsed = now - pausedAt;
            made += elapsed;
            foreach (ref powerUp; powerUps)
                if (powerUp.readyAt != MonoTime.init)
                    powerUp.readyAt += elapsed;
            pausedAt = MonoTime.init;
        }
        checkpointDirty = true;
        return true;
    }

    /// Optional tails keep older match records readable: the pause, then the members' levels and who
    /// is offline because of a crash.
    package void transferPause(ref imported!"dmangos.world.battlegroundstate".BattlegroundState state)
    {
        if (state.writer !is null || !state.reader.empty)
            state.transfer(pausedAt);
        if (state.writer !is null || !state.reader.empty)
            state.transfer(memberLevels, offlineByCrash);
    }

    package void recoveredAfterCrash()
    {
        const now = context.clock();
        foreach (guid, ref member; members)
            if (member.offlineSince == MonoTime.init)
            {
                member.offlineSince = now; // keep the place and any carried objective while the gateway reconnects
                offlineByCrash[guid] = true;
            }
        checkpointDirty = true;
        if (crossRealm)
        {
            // The combined host's unsaved team raids are rebuilt as their members return.
            inTeamRaid = null;
            raidLeaderOf = null;
        }
    }

    ///
    this(WorldContext context, uint instance, BattlegroundType type, BattlegroundRules rules = null)
    {
        this.context = context;
        this.instance = instance;
        this.type = type;
        this.rules = rules is null ? new BattlegroundRules : rules;
        made = context.clock();
        static immutable uint[4] callToArms = [0, 283, 284, 285];
        weekend = context.calendar.gameEvents !is null && context.calendar.gameEvents.holidayActive(callToArms[type]);
        activeEvents[eventDoors] = 0; // the doors are there, closed
        this.rules.reset(this);
    }

    /// Players of `team` in the copy.
    uint count(ubyte team) const
    {
        uint n;
        foreach (ref m; members)
            n += m.team == team;
        return n;
    }

    /// The time since it was made, as the status packet says it.
    @property uint sinceMs() const
    {
        return cast(uint)((paused ? pausedAt : context.clock()) - made).total!"msecs";
    }

    /// The copy's map id.
    @property uint mapId() const
    {
        return battlegroundMaps[type];
    }

    /// The template it was made from.
    @property const(BattlegroundTemplate)* template_() const
    {
        return cast(ubyte) type in context.data.battlegroundTemplates;
    }

    /**
     * A player of `team` came in (or came back after logging out). The
     * other players of its team are told; over already, it is shown the scoreboard.
     */
    void arrived(const Player player, ubyte team)
    {
        import dmangos.log : info;

        checkpointDirty = true;
        const guid = player.guid;
        const identity = NameInfo(player.data.name, player.data.race, player.data.gender, player.data.classId);
        memberLevels[guid] = cast(ubyte) player.data.level;
        offlineByCrash.remove(guid);
        if (auto known = guid in members)
        {
            known.offlineSince = MonoTime.init;
            known.identity = identity;
            if (status == BattlegroundStatus.waitLeave && !endingPending)
                if (auto who = memberSession(guid))
                    showFinalBoard(who, scoreboard());
            return;
        }
        members[guid] = Member(team, identity: identity);
        joinOrder_ ~= guid;
        ByteWriter w;
        w.put(guid);
        toTeam(team, Opcode.SMSG_BATTLEGROUND_PLAYER_JOINED, w.data, guid);
        if (status == BattlegroundStatus.waitLeave)
            if (auto who = memberSession(guid))
                who.deliver(Opcode.MSG_PVP_LOG_DATA, scoreboard());
        info!"battleground: %s (copy %s) has %s Alliance and %s Horde players"(type, instance, count(0), count(1));
    }

    /**
     * A player leaves, the copy's part: player `guid` is out, its team told, and the
     * queue (which frees its slot and its place). Whether it deserted is the leaving player's to know.
     */
    void removed(ulong guid)
    {
        auto m = guid in members;
        if (m is null)
            return;
        checkpointDirty = true;
        rules.playerLeaving(this, guid);
        const team = m.team;
        if (context.battlegroup !is null && guid in inTeamRaid)
        {
            import dmangos.world.group : RemoveMethod;

            inTeamRaid.remove(guid);
            if (auto raid = context.battlegroup.raids.of(guid))
                raid.removeMember(guid, RemoveMethod.leave);
            if (raidLeaderOf.get(team, 0) == guid)
            {
                raidLeaderOf.remove(team);
                foreach (mate; joinOrder_)
                    if (mate in inTeamRaid && members[mate].team == team)
                    {
                        auto raid = context.battlegroup.raids.of(mate);
                        raidLeaderOf[team] = raid is null ? mate : raid.leader;
                        break;
                    }
            }
        }
        members.remove(guid);
        memberLevels.remove(guid);
        offlineByCrash.remove(guid);
        {
            import std.algorithm.mutation : remove;
            import std.algorithm.searching : countUntil;

            const i = joinOrder_.countUntil(guid);
            if (i >= 0)
                joinOrder_ = joinOrder_.remove(i);
        }
        ByteWriter w;
        w.put(guid);
        toTeam(team, Opcode.SMSG_BATTLEGROUND_PLAYER_LEFT, w.data, guid);
        context.services.call!(BattlegroundQueueHost.left)(BattlegroundLeft(instance, guid, team));
    }

    /// A player logged out inside: it keeps its place for five minutes (what it carried drops).
    void loggedOut(ulong guid)
    {
        if (auto m = guid in members)
        {
            checkpointDirty = true;
            m.offlineSince = context.clock();
            offlineByCrash.remove(guid);
            if (status == BattlegroundStatus.inProgress)
                rules.playerLeaving(this, guid);
        }
    }

    /// Whether players leaving now desert: before the battle and while it is on.
    @property bool deserting() const
    {
        return status == BattlegroundStatus.waitJoin || status == BattlegroundStatus.inProgress;
    }

    /// The time to the spirit guides' next pulse (`SMSG_AREA_SPIRIT_HEALER_TIME`).
    @property Duration untilSpiritHeal() const
    {
        const since = sinceMs % spiritHealInterval.total!"msecs";
        return (spiritHealInterval.total!"msecs" - since).msecs;
    }

    /// Each tick: the spirit guides, those offline too long, the countdown, the battle, the end.
    void tick(Duration elapsed)
    {
        if (endingPending)
        {
            end(pendingWinner);
            return;
        }
        const now = context.clock();
        if (!paused)
            spiritHealPulse(elapsed);
        // Those offline too long go.
        ulong[] gone;
        foreach (guid, ref m; members)
            if (m.offlineSince != MonoTime.init && now - m.offlineSince >= offlineLimit)
                gone ~= guid;
        foreach (guid; gone)
            removed(guid);

        if (paused)
        {
            closeIfEmpty(now);
            return;
        }

        final switch (status)
        {
        case BattlegroundStatus.waitJoin:
            if (members.length == 0)
                break; // the countdown starts with the first player
            startLeft -= elapsed;
            if (said < 1 && startLeft <= 1.minutes)
                sayCountdown(0);
            if (said < 2 && startLeft <= 30.seconds)
                sayCountdown(1);
            if (startLeft <= Duration.zero)
                start();
            break;
        case BattlegroundStatus.inProgress:
            checkPrematureEnd(elapsed);
            if (status == BattlegroundStatus.inProgress)
            {
                refreshPowerUps(now);
                rules.tick(this, elapsed);
            }
            break;
        case BattlegroundStatus.waitLeave:
            if (finalPublicationPending)
                publishFinalResult();
            endLeft -= elapsed;
            if (endLeft <= Duration.zero)
                sendEveryoneOut();
            break;
        case BattlegroundStatus.none, BattlegroundStatus.waitQueue:
            break;
        }
        closeIfEmpty(now);
    }

    /// The countdown's end: the doors open and the battle begins.
    void start()
    {
        import dmangos.log : info;

        if (status != BattlegroundStatus.waitJoin || paused)
            return;
        said = 3;
        startLeft = Duration.zero;
        openDoors();
        rules.started(this);
        message(countdownStrings[type][2], ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
        playSound(soundStart);
        setStatus(BattlegroundStatus.inProgress);
        info!"battleground: %s (copy %s) begins"(type, instance);
    }

    /**
     * The battle is over: `winner` (`winnerAlliance`, `winnerHorde`, `winnerNone`) is
     * told; the winners get three marks of honor, the others one; everyone is shown the scoreboard,
     * and sent out two minutes later.
     */
    void end(ubyte winner, scope void delegate() finalObjectiveReward = null)
    {
        import dmangos.log : info;
        import dmangos.world.character : Character;

        if (status == BattlegroundStatus.waitLeave && !endingPending)
            return;
        const managed = context.battlegrounds.durable && context.battlegrounds.find(instance) is this;
        if (!endingPending)
        {
            pendingWinner = winner;
            endingPending = true;
            if (managed)
                collectFinalRewards(winner, finalObjectiveReward);
            else
            {
                if (finalObjectiveReward !is null)
                    finalObjectiveReward();
                rules.ending(this, winner);
            }
            this.winner = winner;
            status = BattlegroundStatus.waitLeave;
            endLeft = endDelay;
        }
        if (managed && !context.battlegrounds.saveCheckpoint(this, false))
            return;
        endingPending = false;
        setStatus(BattlegroundStatus.waitLeave);
        if (finalPublicationPending)
            publishFinalResult();
        if (winner == winnerAlliance)
            playSound(soundAllianceWins, 0);
        else if (winner == winnerHorde)
            playSound(soundHordeWins, 1);
        foreach (guid, ref m; members)
            if (auto c = cast(Character) memberSession(guid))
            {
                const won = winner != winnerNone && teamWins(m.team, winner);
                c.battlegroundEnded(managed ? 0 : markSpells[type][won ? 0 : 1]);
            }
        if (winner == winnerAlliance)
            message(stringAllianceWins, ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
        else if (winner == winnerHorde)
            message(stringHordeWins, ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
        if (!managed && (context.config.battlegroundScoreStatistics || context.battlegroup !is null))
            keepScores();
        const board = scoreboard();
        foreach (guid, ref m; members)
            if (auto who = memberSession(guid))
                showFinalBoard(who, board);
        info!"battleground: %s (copy %s) is over, won by %s"(type, instance,
            winner == winnerAlliance ? "the Alliance" : winner == winnerHorde ? "the Horde" : "nobody");
    }

    private void showFinalBoard(OnlinePlayer who, const(ubyte)[] board)
    {
        who.deliver(Opcode.MSG_PVP_LOG_DATA, board);
        who.deliver(Opcode.SMSG_BATTLEFIELD_STATUS, battlefieldStatus(0, type, 0,
            BattlegroundStatus.inProgress, cast(uint) endLeft.total!"msecs", sinceMs));
    }

    package bool canRejoinFinalScore() const
    {
        return context.battlegrounds.durable && !checkpointRetired && !endingPending && endLeft > Duration.zero;
    }

    private void collectFinalRewards(ubyte winner, scope void delegate() finalObjectiveReward)
    {
        import dmangos.world.bgqueue : bracketOf;
        import dmangos.world.honor : honorDay, honorToday;

        uint level;
        const day = honorDay(honorToday());
        foreach (guid, ref member; members)
        {
            // Those offline only because of a crash fought until it: their rows are paid when they return.
            const present = member.offlineSince == MonoTime.init && memberSession(guid) !is null;
            if (!present && guid !in offlineByCrash)
                continue;
            level = rewardLevel(guid);
            const won = teamWins(member.team, winner);
            finalPlayers[guid] = FinalPlayer(score: PvpStatsPlayer.init,
                reward: BattlegroundReward(context.config.realmId, instance, cast(uint) guid,
                    markSpells[type][won ? 0 : 1], 0, day));
        }
        collectingFinalRewards = true;
        scope (exit) collectingFinalRewards = false;
        if (finalObjectiveReward !is null)
            finalObjectiveReward();
        rules.ending(this, winner);
        foreach (guid, ref finished; finalPlayers)
        {
            const m = &members[guid];
            finished.score = PvpStatsPlayer(cast(uint) guid, m.killingBlows, m.deaths, m.honorableKills, m.bonusHonor);
            finished.score.attr = m.extra[0 .. 5];
        }
        if (const t = template_)
            finalBracket = cast(ubyte)((t.minLevel + 10 * (level ? bracketOf(*t, level) : 0)) / 10);
        finalPublicationPending = true;
    }

    /// A member's level for its rewards: online, its own; else as it came in; else (a record from before
    /// levels were kept) another member's, as one copy's players share a bracket.
    private uint rewardLevel(ulong guid)
    {
        if (auto who = memberSession(guid))
            return who.character.data.level;
        if (const level = guid in memberLevels)
            return *level;
        foreach (_, level; memberLevels)
            return level;
        foreach (other, ref m; members)
            if (auto who = memberSession(other))
                return who.character.data.level;
        const t = template_;
        return t is null ? 0 : t.minLevel;
    }

    private bool publishFinalResult()
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!finalPublicationPending)
            return true;
        struct RealmResult
        {
            PvpStatsPlayer[] scores;
            BattlegroundReward[] rewards;
        }
        RealmResult[WorldContext] results;
        results[context] = RealmResult.init;
        foreach (guid, ref finished; finalPlayers)
        {
            auto home = context.battlegroup is null ? context : context.battlegroup.homeOf(guid);
            if (home is null)
                return false;
            auto result = &results.require(home, RealmResult.init);
            result.scores ~= finished.score;
            result.rewards ~= finished.reward;
        }
        const result = PvpStatsBattleground(winner, finalBracket, cast(ubyte) type);
        try
        {
            foreach (home, ref rows; results)
                if (!home.database.publishBattlegroundResult(context.config.realmId, instance, result, rows.scores,
                    rows.rewards, home.config.battlegroundScoreStatistics
                        && (rows.scores.length != 0 || context.battlegroup is null)))
                    return false;
        }
        catch (DatabaseException error)
        {
            warning!"battleground: could not publish result for copy %s: %s"(instance, error.msg);
            return false;
        }
        finalPublicationPending = false;
        finalPlayers = null;
        checkpointDirty = true;
        return true;
    }

    /**
     * The scoreboard kept (`Battleground.ScoreStatistics`, CMaNGOS's `EndBattleGround`): the battle (the winner as the
     * scoreboard says it, the bracket's lowest level / 10, the type), and each player still in it (not one logged out),
     * its first five columns of the battleground's own.
     */
    private void keepScores()
    {
        import dmangos.world.bgqueue : bracketOf;
        import dmangos.world.database : PvpStatsBattleground, PvpStatsPlayer;

        const t = template_;
        PvpStatsPlayer[][WorldContext] byHome;
        uint level;
        foreach (guid, ref m; members)
        {
            if (m.offlineSince != MonoTime.init)
                continue;
            PvpStatsPlayer p = {guid: cast(uint) guid, killingBlows: m.killingBlows, deaths: m.deaths,
                honorableKills: m.honorableKills, bonusHonor: m.bonusHonor};
            p.attr = m.extra[0 .. 5];
            auto home = context.battlegroup is null ? context : context.battlegroup.homeOf(guid);
            if (home !is null && home.config.battlegroundScoreStatistics)
                byHome[home] ~= p;
            if (auto who = memberSession(guid))
                level = who.character.data.level;
        }
        ubyte bracket;
        if (t !is null)
            bracket = cast(ubyte)((t.minLevel + 10 * (level ? bracketOf(*t, level) : 0)) / 10);
        const result = PvpStatsBattleground(winner, bracket, cast(ubyte) type);
        if (!byHome.length && context.battlegroup is null)
            context.database.savePvpStats(result, null);
        foreach (home, rows; byHome)
            home.database.savePvpStats(result, rows);
    }

    /// Whether `team` (0 the Alliance) is `winner`.
    static bool teamWins(ubyte team, ubyte winner) pure nothrow @nogc @safe
    {
        return (team == 0 && winner == winnerAlliance) || (team == 1 && winner == winnerHorde);
    }

    /// `winnerAlliance` or `winnerHorde` for team 0 or 1.
    static ubyte winnerOf(ubyte team) pure nothrow @nogc @safe
    {
        return team == 0 ? winnerAlliance : winnerHorde;
    }

    /// `.battleground leave`: everyone out now, the copy closed.
    void close()
    {
        if (!context.battlegrounds.retireCheckpoint(this))
            return;
        if (status != BattlegroundStatus.waitLeave)
            setStatus(BattlegroundStatus.waitLeave);
        sendEveryoneOut();
    }

    /**
     * A player died: the victim's death, the killer's killing blow and honorable
     * kill, and an honorable kill to each of the killer's team near the victim (within group reward distance).
     */
    void playerKilled(ulong victim, ulong killer)
    {
        import dmangos.world.experience : groupXpDistance;

        if (status != BattlegroundStatus.inProgress)
            return;
        checkpointDirty = true;
        if (auto v = victim in members)
            ++v.deaths;
        if (auto k = killer in members)
        {
            ++k.killingBlows;
            ++k.honorableKills;
            const team = k.team;
            auto dead = memberSession(victim);
            foreach (guid, ref m; members)
            {
                if (guid == killer || m.team != team || dead is null)
                    continue;
                if (auto mate = memberSession(guid))
                {
                    const a = mate.character.position, b = dead.character.position;
                    if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 <= groupXpDistance ^^ 2)
                        ++m.honorableKills;
                }
            }
        }
        rules.playerKilled(this, victim: victim, killer: killer);
        // Its insignia may be taken from its body (`removedInsignia`).
        if (auto dead = cast(imported!"dmangos.world.character".Character) memberSession(victim))
            if (dead.player !is null)
                dead.markInsignia();
    }

    /**
     * `who` acted on an objective (took a flag or a banner, captured): what ends with that ends
     * (`AURA_INTERRUPT_FLAG_PVP_ACTIVE_CANCELS`: Stealth, Divine Shield, Ice Block and the like).
     */
    void pvpActive(ulong who)
    {
        import dmangos.world.auras : AuraInterrupt;

        if (auto c = cast(imported!"dmangos.world.character".Character) memberSession(who))
            c.interruptAuras(AuraInterrupt.pvpActiveCancels);
    }

    /// `units` bonus honor units to everyone of `team` here, each by its bracket (`bonusHonor`), on their scores.
    void rewardHonorToTeam(uint units, ubyte team)
    {
        import dmangos.world.character : Character;

        const t = template_;
        if (t is null)
            return;
        foreach (guid, ref m; members)
        {
            if (m.team != team)
                continue;
            if (collectingFinalRewards)
            {
                // Every finishing player, those offline because of a crash too, into its durable reward.
                if (auto finished = guid in finalPlayers)
                {
                    const honor = bonusHonor(units, *t, rewardLevel(guid));
                    finished.reward.honor += honor;
                    m.bonusHonor += honor;
                }
            }
            else if (auto event = eventRewardFor(guid, m))
            {
                const honor = bonusHonor(units, *t, rewardLevel(guid));
                if (honor)
                {
                    event.reward.honor = honor;
                    m.bonusHonor += honor;
                }
            }
            else if (m.offlineSince == MonoTime.init)
                if (auto c = cast(Character) memberSession(guid))
                {
                    const honor = bonusHonor(units, *t, c.player.data.level);
                    if (c.battlegroundBonusHonor(honor))
                        m.bonusHonor += honor;
                }
        }
    }

    /// Reputation: `amount` with `faction` to everyone of `team` here.
    void rewardReputationToTeam(uint faction, int amount, ubyte team)
    {
        import dmangos.world.character : Character;
        import dmangos.world.database : BattlegroundReputation;

        foreach (guid, ref m; members)
        {
            if (m.team != team)
                continue;
            if (collectingFinalRewards)
            {
                if (auto finished = guid in finalPlayers)
                    finished.reward.reputation ~= BattlegroundReputation(faction, amount);
            }
            else if (auto event = eventRewardFor(guid, m))
                event.reward.reputation ~= BattlegroundReputation(faction, amount);
            else if (m.offlineSince == MonoTime.init)
                if (auto c = cast(Character) memberSession(guid))
                    c.battlegroundReputation(faction, amount);
        }
    }

    /// Casts `spell` on everyone of `team` here (a quest's credit).
    void castOnTeam(uint spell, ubyte team)
    {
        import dmangos.world.character : Character;

        foreach (guid, ref m; members)
        {
            if (m.team != team)
                continue;
            if (auto event = eventRewardFor(guid, m))
                event.castSpell = spell;
            else if (m.offlineSince == MonoTime.init)
                if (auto c = cast(Character) memberSession(guid))
                    c.battlegroundCast(spell);
        }
    }

    /// Kill credit `entry` to every member of `team` here (`KilledMonsterCredit` for each).
    void killCreditToTeam(ubyte team, uint entry)
    {
        import dmangos.world.character : Character;

        foreach (guid, ref m; members)
        {
            if (m.team != team)
                continue;
            if (auto event = eventRewardFor(guid, m))
                event.killCredit = entry;
            else if (m.offlineSince == MonoTime.init)
                if (auto c = cast(Character) memberSession(guid))
                    c.battlegroundKillCredit(entry);
        }
    }

    /**
     * Objectives' rewards during the match, not yet in a checkpoint: each goes into the database with the checkpoint
     * that records its objective (`Battlegrounds.saveCheckpoint`), both or neither, and is paid from there once
     * (`Character.payBattlegroundEventReward`). A crash before the checkpoint loses the objective and its rewards
     * together; one after keeps both.
     */
    package imported!"dmangos.world.database".BattlegroundEventReward[] eventRewards;

    /**
     * A new event reward for `guid` (an objective's honor, reputation or quest credit), or null where it is paid as
     * before, in memory: outside a durable match, during the final rewards, to a player of another realm's database
     * (a cross-realm match), or to one logged out other than by a crash. A crash-offline player's waits for its
     * return.
     */
    private imported!"dmangos.world.database".BattlegroundEventReward* eventRewardFor(ulong guid, const ref Member m)
    {
        import dmangos.world.database : BattlegroundEventReward;
        import dmangos.world.honor : honorDay, honorToday;

        if (collectingFinalRewards || !context.battlegrounds.durable || checkpointRetired || endingPending)
            return null;
        if (context.battlegroup !is null && context.battlegroup.homeOf(guid) !is context)
            return null;
        if (m.offlineSince != MonoTime.init && guid !in offlineByCrash)
            return null;
        eventRewards ~= BattlegroundEventReward(BattlegroundReward(context.config.realmId, instance, cast(uint) guid,
            0, 0, honorDay(honorToday())));
        checkpointDirty = true;
        return &eventRewards[$ - 1];
    }

    /// Kill credit `entry` to `guid` and the members of its group here (`RewardPlayerAndGroupAtEventCredit`).
    void killCreditToGroupOf(ulong guid, uint entry)
    {
        import dmangos.world.character : Character;

        foreach (other, ref m; members)
            if (m.offlineSince == MonoTime.init && (other == guid || context.groups.sameGroup(guid, other)))
                if (auto c = cast(Character) memberSession(other))
                    c.battlegroundKillCredit(entry);
    }

    /// A battleground's own score column: `extra[column]` of `guid` up by `by`.
    void addScore(ulong guid, size_t column, uint by = 1)
    {
        if (auto m = guid in members)
            if (column < m.extra.length)
            {
                m.extra[column] += by;
                checkpointDirty = true;
            }
    }

    package void objectiveChanged() { checkpointDirty = true; }

    /// The scoreboard: `MSG_PVP_LOG_DATA`'s body.
    const(ubyte)[] scoreboard()
    {
        ByteWriter w;
        const over = status == BattlegroundStatus.waitLeave && !endingPending;
        w.put(ubyte(over));
        if (over)
            w.put(winner);
        w.put(cast(uint) members.length);
        foreach (guid, ref m; members)
        {
            w.put(guid);
            uint rank = 4; // the honor rank shown for a player not on this node
            if (auto who = memberSession(guid))
            {
                import dmangos.world.character : Character;

                if (auto c = cast(Character) who)
                    rank = c.visibleHonorRank;
            }
            w.put(rank);
            w.put(m.killingBlows);
            w.put(m.honorableKills);
            w.put(m.deaths);
            w.put(m.bonusHonor);
            w.put(extraScores[type]);
            foreach (i; 0 .. extraScores[type])
                w.put(m.extra[i]);
        }
        return w.data.dup;
    }

    // --- the players, for the rules ---

    /// Member `guid`, if it is online here.
    OnlinePlayer onlinePlayerOf(ulong guid)
    {
        if (auto m = guid in members)
            if (m.offlineSince == MonoTime.init)
                return memberSession(guid);
        return null;
    }

    /// Whether member `guid` is here and alive (and so may use the battleground's objects).
    bool memberAlive(ulong guid)
    {
        import dmangos.world.player : DeathState;

        auto who = onlinePlayerOf(guid);
        return who !is null && who.character.deathState == DeathState.alive;
    }

    /// `spell` cast on member `guid` (triggered).
    void castOn(ulong guid, uint spell)
    {
        import dmangos.world.character : Character;

        if (auto c = cast(Character) onlinePlayerOf(guid))
            c.battlegroundCast(spell);
    }

    /// Member `guid`'s aura of `spell` taken off.
    void removeAuraOf(ulong guid, uint spell)
    {
        import dmangos.world.character : Character;

        if (auto c = cast(Character) memberSession(guid))
            c.battlegroundRemoveAura(spell);
    }

    /// A notification (`mangos_string` `id`) to member `guid`.
    void notify(ulong guid, uint id)
    {
        import dmangos.world.packets : ServerNotification;
        import dmangos.serialization : serialize;

        if (const text = id in context.data.serverStrings)
            if (auto who = onlinePlayerOf(guid))
            {
                ByteWriter w;
                w.putCString(*text);
                who.deliver(Opcode.SMSG_NOTIFICATION, w.data);
            }
    }

    /// Member `guid` out, back where it came from.
    void sendOut(ulong guid)
    {
        import dmangos.world.character : Character;

        if (auto c = cast(Character) onlinePlayerOf(guid))
            c.battlegroundLeave(true);
    }

    /**
     * A creature of `entry` summoned at `x`, `y` (on the ground there, looking `o`) on the copy's map, staying until
     * it dies or the copy goes; its guid, 0 if it could not be.
     */
    ulong summonAt(uint entry, float x, float y, float z, float o)
    {
        import dmangos.world.creature : TempSpawnType;
        import dmangos.world.movement : Position;

        auto map = context.existingMap(mapId, instance);
        if (map is null)
            return 0;
        const ground = map.groundHeight(x, y, z + 10, false);
        auto made = context.summonCreature(map, entry, Position(x, y, ground > -100_000 ? ground : z, o),
            TempSpawnType.dead, 0, 0);
        return made is null ? 0 : made.guid;
    }

    /// Each creature of `entry` on the copy's map casts `spell` on itself (triggered); how many did.
    uint creaturesCast(uint entry, uint spell)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.map : MapObject;

        auto map = context.existingMap(mapId, instance);
        if (map is null)
            return 0;
        Creature[] casters;
        map.forEachObject((MapObject o) {
            if (auto c = cast(Creature) o)
                if (c.template_.entry == entry && c.alive && c.ai !is null)
                    casters ~= c;
        });
        uint cast_;
        foreach (c; casters)
        {
            import dmangos.script.api : ActionResult;

            if (c.ai.castFor(map, spell, c.guid, true) == ActionResult.ok)
                ++cast_;
        }
        return cast_;
    }

    /**
     * A game object of `entry` put down where member `guid` stands (a dropped flag: the spell that
     * summons it); its guid, 0 if it could not be.
     */
    ulong placeObjectAt(ulong guid, uint entry)
    {
        import dmangos.world.gameobject : GameObjectSpawn;

        auto who = memberSession(guid);
        auto map = context.existingMap(mapId, instance);
        const t = entry in context.data.gameObjectTemplates;
        if (who is null || map is null || t is null)
            return 0;
        const at = who.character.position;
        GameObjectSpawn spawn = {guid: context.nextTemporaryCounter(), entry: entry, map: mapId, x: at.x, y: at.y,
            z: at.z, orientation: at.orientation, respawnSeconds: -1};
        auto go = new GameObject(spawn, t);
        go.instanceId = instance;
        map.addObject(go);
        return go.guid;
    }

    /// The battleground event a game object of the copy belongs to; null if none.
    const(ubyte[2])* eventOf(GameObject go)
    {
        return go.spawn.guid in context.data.gameObjectBattleEvents;
    }

    /// A `mangos_string`'s text (empty if there is none).
    string serverString(uint id)
    {
        return context.data.serverStrings.get(id, null);
    }

    /// An object taken off the copy's map.
    void removeObject(ulong guid)
    {
        if (auto map = context.existingMap(mapId, instance))
            map.removeObject(guid);
    }

    // --- events: what is spawned, and the doors ---

    /// Whether a spawn of event `event` (null: of none) belongs in the copy now.
    bool spawnAllowed(const(ubyte[2])* event) const
    {
        return event is null || activeEvents.get((*event)[0], eventNone) == (*event)[1];
    }

    private ulong powerUpSlot(uint spawn) const
    {
        const pool = context.data.pools is null ? 0 : context.data.pools.singleGameObjectPool(spawn);
        return pool ? cast(ulong) pool << 32 : spawn;
    }

    /// The first active variant belongs to the match, just as each later respawn does.
    package bool powerUpAvailable(uint spawn, bool fromCheckpoint = false)
    {
        import dmangos.world.worlddata : PoolMember;

        const key = powerUpSlot(spawn);
        if (const slot = key in powerUps)
            return slot.readyAt == MonoTime.init && slot.spawn == spawn;
        if (!fromCheckpoint && !context.upInPool(PoolMember.Kind.gameObject, spawn))
            return false;
        if (key >> 32)
        {
            // Older checkpoints recorded the active object even before saving its pool choice.
            powerUps[key] = PowerUp(spawn, MonoTime.init);
            checkpointDirty = true;
        }
        return true;
    }

    /// A loaded destination cell may still contain the local worker's initial roll.
    package void reconcilePowerUps(Map map)
    {
        map.forEachObject((MapObject object) {
            if (auto pickup = cast(GameObject) object)
                if (pickup.spawn.battlegroundPowerUp && !powerUpAvailable(pickup.spawn.guid))
                    map.removeObject(pickup.guid);
        });
        foreach (ref slot; powerUps)
            if (slot.readyAt == MonoTime.init)
                spawnPowerUp(map, slot.spawn);
    }

    package bool takePowerUp(Map map, GameObject pickup, ulong member)
    {
        if (paused || status != BattlegroundStatus.inProgress || !memberAlive(member) || !context.canWrite()
            || !powerUpAvailable(pickup.spawn.guid) || map.gameObjectAt(pickup.guid) !is pickup)
            return false;
        const delay = pickup.spawn.respawnSeconds > 0 ? pickup.spawn.respawnSeconds : 180;
        powerUps[powerUpSlot(pickup.spawn.guid)] = PowerUp(pickup.spawn.guid, context.clock() + delay.seconds);
        checkpointDirty = true;
        map.removeObject(pickup.guid);
        return true;
    }

    private void refreshPowerUps(MonoTime now)
    {
        auto map = context.existingMap(mapId, instance);
        if (map is null)
            return;
        foreach (key, ref slot; powerUps)
        {
            if (slot.readyAt == MonoTime.init || now < slot.readyAt)
                continue;
            const pool = cast(uint)(key >> 32);
            const next = pool && context.data.pools !is null
                ? context.data.pools.rollSingleGameObject(pool, slot.spawn, map.random) : slot.spawn;
            const candidate = context.gameObjectSpawnOf(next);
            if (candidate !is null && candidate.map == mapId && candidate.battlegroundPowerUp)
                slot.spawn = next;
            slot.readyAt = MonoTime.init;
            checkpointDirty = true;
            spawnPowerUp(map, slot.spawn);
        }
    }

    private void spawnPowerUp(Map map, uint guid)
    {
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.objects : HighGuid, makeGuid;

        const spawn = context.gameObjectSpawnOf(guid);
        if (spawn is null || !map.cellLoaded(cellKeyAt(spawn.x, spawn.y)) || !context.calendar.gameObjectInEvents(guid)
            || !spawnAllowed(guid in context.data.gameObjectBattleEvents)
            || map.gameObjectAt(makeGuid(HighGuid.gameObject, spawn.entry, guid)) !is null)
            return;
        auto go = context.makeGameObject(*spawn);
        go.instanceId = instance;
        map.addObject(go);
    }

    /// Whether the doors are open (the battle began).
    @property bool doorsOpen() const
    {
        return status >= BattlegroundStatus.inProgress;
    }

    /**
     * The spawns of the pair (`event1`, `event2`) come (an event shows one `event2` at a
     * time: the one before goes) or go.
     */
    void spawnEvent(ubyte event1, ubyte event2, bool spawn)
    {
        if (spawn)
        {
            const before = activeEvents.get(event1, eventNone);
            if (before == event2)
                return;
            if (before != eventNone)
                despawnPair(event1, before);
            activeEvents[event1] = event2;
            spawnPair(event1, event2);
        }
        else
        {
            if (activeEvents.get(event1, eventNone) != event2)
                return;
            activeEvents.remove(event1);
            despawnPair(event1, event2);
        }
        checkpointDirty = true;
    }

    /// The doors (`eventDoors`) open for good.
    void openDoors()
    {
        import dmangos.world.gameobject : GameObject;

        auto map = context.existingMap(mapId, instance);
        if (map is null)
            return;
        GameObject[] doors;
        map.forEachObject((MapObject o) {
            if (auto go = cast(GameObject) o)
                if (const e = go.spawn.guid in context.data.gameObjectBattleEvents)
                    if ((*e)[0] == eventDoors)
                        doors ~= go;
        });
        foreach (door; doors)
        {
            door.setDoorOpen(true);
            map.flushGameObject(door);
        }
    }

    // --- world states ---

    /// Sets a world state, sent to everyone in the copy if it changed.
    void setWorldState(uint id, uint value)
    {
        if (auto known = id in worldStates)
            if (*known == value)
                return;
        worldStates[id] = value;
        checkpointDirty = true;
        if (status == BattlegroundStatus.none)
            return;
        ByteWriter w;
        w.put(id);
        w.put(value);
        toAll(Opcode.SMSG_UPDATE_WORLD_STATE, w.data);
    }

    // --- messages ---

    /// `mangos_string` `id` (with `args` for its `%s`s) to everyone in it.
    void message(uint id, ChatType chatType, ulong source = 0, string[] args = null)
    {
        import std.algorithm.searching : canFind;
        import std.array : replace;

        const text = id in context.data.serverStrings;
        if (text is null)
            return;
        const formatted = formatServerString(*text, args);
        const local = battlegroundMessage(chatType, formatted, source);
        if (context.battlegroup is null || !source || !formatted.canFind("$n"))
            return toAll(Opcode.SMSG_MESSAGECHAT, local);

        // The client expands $n to the bare character name in battleground system messages.
        const(ubyte)[] foreign;
        foreach (guid, ref member; members)
            if (member.offlineSince == MonoTime.init)
                if (auto who = memberSession(guid))
                {
                    if (const name = foreignChatName(guid, source))
                    {
                        if (foreign is null)
                            foreign = battlegroundMessage(chatType,
                                formatted.replace("$n", name), source);
                        who.deliver(Opcode.SMSG_MESSAGECHAT, foreign);
                    }
                    else
                        who.deliver(Opcode.SMSG_MESSAGECHAT, local);
                }
    }

    /// Plays a sound to everyone in it, or to one team (`team` 0, 1; -1 all).
    void playSound(uint sound, int team = -1)
    {
        ByteWriter w;
        w.put(sound);
        if (team < 0)
            toAll(Opcode.SMSG_PLAY_SOUND, w.data);
        else
            toTeam(cast(ubyte) team, Opcode.SMSG_PLAY_SOUND, w.data);
    }

    /// A packet to every player in it (not those logged out).
    void toAll(Opcode opcode, const(ubyte)[] body_)
    {
        foreach (guid, ref m; members)
            if (m.offlineSince == MonoTime.init)
                if (auto who = memberSession(guid))
                    who.deliver(opcode, body_);
    }

    /// A packet to the players of `team`, but `except`.
    void toTeam(ubyte team, Opcode opcode, const(ubyte)[] body_, ulong except = 0)
    {
        foreach (guid, ref m; members)
            if (m.team == team && guid != except && m.offlineSince == MonoTime.init)
                if (auto who = memberSession(guid))
                    who.deliver(opcode, body_);
    }

    /**
     * `CHAT_MSG_BATTLEGROUND` and `_LEADER`: what `sender` says to its team. Its leader is the first of
     * the team who came in (and is still here).
     */
    void teamChat(ulong sender, ChatType chatType, Language language, string text, ubyte chatTag)
    {
        import dmangos.world.queries : chatMessage;

        auto m = sender in members;
        if (m is null)
            return;
        if (chatType == ChatType.CHAT_MSG_BATTLEGROUND_LEADER && leaderOf(m.team) != sender)
            chatType = ChatType.CHAT_MSG_BATTLEGROUND;
        toTeam(m.team, Opcode.SMSG_MESSAGECHAT, chatMessage(chatType, language, sender, text, chatTag));
    }

    /// The team's leader: the one there longest.
    ulong leaderOf(ubyte team) const
    {
        foreach (guid; joinOrder)
            if (auto m = guid in members)
                if (m.team == team)
                    return guid;
        return 0;
    }

private:
    ulong[] joinOrder_;

    @property const(ulong)[] joinOrder() const
    {
        return joinOrder_;
    }

    long pulses; // the spirit guides' pulses so far

    /// `Spirit Heal` (22012): every 30 s, those waiting at a spirit guide come back to life, whole.
    void spiritHealPulse(Duration elapsed)
    {
        import dmangos.world.character : Character;

        const now = (context.clock() - made).total!"msecs" / spiritHealInterval.total!"msecs";
        if (now == pulses)
            return; // no pulse since the last tick
        pulses = now;
        if (awaitingResurrection.length == 0)
            return;
        foreach (guid; awaitingResurrection.keys)
            if (auto c = cast(Character) memberSession(guid))
                c.battlegroundSpiritHealed();
        awaitingResurrection = null;
    }

    void sayCountdown(ubyte which)
    {
        said = cast(ubyte)(which + 1);
        message(countdownStrings[type][which], ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
    }

    void setStatus(BattlegroundStatus to)
    {
        status = to;
        checkpointDirty = true;
        context.battlegrounds.queueChanged(this, to);
    }

    /// The objects of event pair (`event1`, `event2`) loaded in the copy's map.
    MapObject[] objectsOf(ubyte event1, ubyte event2)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.gameobject : GameObject;

        auto map = context.existingMap(mapId, instance);
        if (map is null)
            return null;
        MapObject[] found;
        const ubyte[2] pair = [event1, event2];
        map.forEachObject((MapObject o) {
            const(ubyte[2])* e;
            if (auto c = cast(Creature) o)
                e = c.spawnId in context.data.creatureBattleEvents;
            else if (auto go = cast(GameObject) o)
                e = go.spawn.guid in context.data.gameObjectBattleEvents;
            if (e !is null && *e == pair)
                found ~= o;
        });
        return found;
    }

    void despawnPair(ubyte event1, ubyte event2)
    {
        auto map = context.existingMap(mapId, instance);
        if (map is null)
            return;
        foreach (o; objectsOf(event1, event2))
            map.removeObject(o.guid);
    }

    /// The pair's spawns whose cells are loaded come now; the others when their cells load.
    void spawnPair(ubyte event1, ubyte event2)
    {
        import dmangos.world.grid : cellKeyAt;

        auto map = context.existingMap(mapId, instance);
        if (map is null)
            return;
        bool[ulong] present;
        foreach (o; objectsOf(event1, event2))
            present[o.guid] = true;
        foreach (o; context.battlegrounds.eventSpawns(mapId, event1, event2, instance))
            if (o.guid !in present && map.cellLoaded(cellKeyAt(o.position.x, o.position.y)))
            {
                if (doorsOpen && event1 == eventDoors)
                    if (auto go = cast(GameObject) o)
                        go.setDoorOpen(true);
                map.addObject(o);
            }
    }

    /// The premature end: a team short of players for five minutes loses.
    void checkPrematureEnd(Duration elapsed)
    {
        import std.conv : to;

        const t = template_;
        if (t is null || testing || !context.config.battlegroundPrematureFinish)
            return;
        const short_ = count(0) < t.minPerTeam || count(1) < t.minPerTeam;
        if (!short_)
        {
            prematureCounting = false;
            return;
        }
        if (!prematureCounting)
        {
            prematureCounting = true;
            prematureLeft = context.config.battlegroundPrematureFinish.seconds;
            lastWarning = uint.max;
        }
        prematureLeft -= elapsed;
        if (prematureLeft <= Duration.zero)
        {
            prematureCounting = false;
            ubyte w = rules.prematureWinner(this);
            if (w == winnerNone)
                w = count(0) > count(1) ? winnerAlliance : count(1) > count(0) ? winnerHorde : winnerNone;
            return end(w);
        }
        // Every whole minute while more than one is left, then every 15 seconds.
        const left = cast(uint) prematureLeft.total!"seconds";
        if (left > 60)
        {
            const minutes = (left + 59) / 60;
            if (minutes * 60 != lastWarning)
            {
                lastWarning = minutes * 60;
                message(stringClosingMinutes, ChatType.CHAT_MSG_SYSTEM, 0, [minutes.to!string]);
            }
        }
        else
        {
            const quarter = ((left + 14) / 15) * 15;
            if (quarter != lastWarning)
            {
                lastWarning = quarter;
                message(stringClosingSeconds, ChatType.CHAT_MSG_SYSTEM, 0, [quarter.to!string]);
            }
        }
    }

    /// Its players back where they came from (teleported), not deserters.
    void sendEveryoneOut()
    {
        import dmangos.world.character : Character;

        foreach (guid; members.keys)
        {
            if (auto c = cast(Character) memberSession(guid))
                c.battlegroundLeave(true);
            removed(guid); // logged out, or not left by the above
        }
    }

    /// Empty and with nobody invited, it closes.
    void closeIfEmpty(MonoTime now)
    {
        if (members.length || asking)
        {
            if (members.length)
                emptySince = MonoTime.init;
            return;
        }
        if (emptySince == MonoTime.init)
        {
            emptySince = now;
            return;
        }
        if (now - emptySince < 5.seconds && status != BattlegroundStatus.waitLeave)
            return;
        if (status == BattlegroundStatus.waitLeave)
            return context.battlegrounds.closed(this);
        asking = true;
        context.services.call!(BattlegroundQueueHost.invited)(BattlegroundInstance(instance), (BattlegroundInvited r) {
            asking = false;
            emptySince = context.clock();
            if (r.count == 0 && members.length == 0)
                context.battlegrounds.closed(this);
        });
    }
}

/// The real power-up spells trigger on movement and the Arathi station's cooldown survives a crash.
unittest
{
    import dmangos.world.packets : ClientTeleportAck;
    import dmangos.world.realspelltests : haveRealData, RealWorld;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.worlddata : PoolChooser, PoolMember;
    import std.random : Random;

    if (!haveRealData())
        return;

    auto w = RealWorld.make();
    auto user = w.character(17, "Runner", 1, 60, []);
    auto me = user.session.inWorld;
    enum uint warsong = 489, arathi = 529;
    enum uint[3] entries = [179871, 179904, 179905], spells = [23451, 23493, 23505];
    uint locate(uint mapId, uint entry)
    {
        foreach (ref spawn; w.context.data.gameObjectSpawns)
            if (spawn.map == mapId && spawn.entry == entry)
                return spawn.guid;
        assert(0, "battleground power-up spawn missing");
    }

    void begin(Battleground copy)
    {
        copy.testing = true;
        me.enterBattleground(BattlegroundEntry(true, copy.instance, 0, copy.type));
        user.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        user.read();
        assert(me.player.data.map == copy.mapId && me.currentMap.instanceId == copy.instance,
            "the test player entered the intended match");
    }

    void near(Battleground copy, Position at)
    {
        assert(me.teleportTo(copy.mapId, Position(at.x + 5, at.y, at.z), null, copy.instance, true));
        user.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(me.player.guid, 0, 0));
        user.read();
    }

    void step(Position at)
    {
        auto movement = me.player.movement;
        movement.position = at;
        me.player.movement = movement;
        me.movedOn(movement, Opcode.MSG_MOVE_HEARTBEAT);
        user.read();
    }

    auto gulch = w.context.battlegrounds.open(500, BattlegroundType.warsongGulch);
    begin(gulch);
    foreach (i, entry; entries)
    {
        const spawn = w.context.gameObjectSpawnOf(locate(warsong, entry));
        const at = Position(spawn.x, spawn.y, spawn.z);
        near(gulch, at);
        const guid = makeGuid(HighGuid.gameObject, entry, spawn.guid);
        assert(me.currentMap.gameObjectAt(guid) !is null);
        if (i == 0)
        {
            step(at);
            assert(me.player.auras.find(spells[i]) is null && me.currentMap.gameObjectAt(guid) !is null,
                "a power-up stays available before the gates open");
            gulch.start();
            near(gulch, at);
        }
        step(at);
        assert(me.player.auras.find(spells[i]) !is null && me.currentMap.gameObjectAt(guid) is null);
        step(at);
        assert(me.currentMap.gameObjectAt(guid) is null, "a second step cannot collect the same object");
    }

    gulch.close();
    user.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    user.read();
    auto basin = w.context.battlegrounds.open(501, BattlegroundType.arathiBasin);
    begin(basin);
    basin.start();
    const spawn = w.context.gameObjectSpawnOf(locate(arathi, entries[0]));
    const pos = Position(spawn.x, spawn.y, spawn.z);
    near(basin, pos);
    GameObject[] pickups(Map map)
    {
        GameObject[] found;
        foreach (object; map.objectsNear(pos, 3))
            if (auto go = cast(GameObject) object)
                if (go.spawn.battlegroundPowerUp)
                    found ~= go;
        return found;
    }

    assert(pickups(me.currentMap).length == 1);
    {
        const selected = pickups(me.currentMap)[0].spawn.guid;
        const bytes = w.context.dungeons.snapshotBattleground(basin);
        const key = basin.powerUpSlot(selected);
        const active = basin.powerUps[key];
        basin.powerUps.remove(key); // older matches capture the object with no recorded pool slot
        const legacy = w.context.dungeons.snapshotBattleground(basin);
        basin.powerUps[key] = active;
        auto originalPools = w.context.data.pools;
        scope (exit) w.context.data.pools = originalPools;
        const pool = originalPools.singleGameObjectPool(selected);
        auto differentPools = new PoolChooser;
        differentPools.limits[pool] = 1;
        uint alternate;
        foreach (ref option; w.context.data.gameObjectSpawns)
            if (option.map == arathi && option.battlegroundPowerUp && originalPools.singleGameObjectPool(option.guid) == pool)
            {
                const chosen = option.guid != selected && !alternate;
                if (chosen)
                    alternate = option.guid;
                differentPools.add(pool, PoolMember(PoolMember.Kind.gameObject, option.guid, chosen ? 100 : 0));
            }
        auto rng = Random(1);
        differentPools.choose(rng);
        w.context.data.pools = differentPools;
        foreach (snapshot; [bytes, legacy])
        {
            auto successor = RealWorld.make();
            successor.context.battlegrounds.open(basin.instance, basin.type);
            auto map = successor.context.map(arathi, basin.instance);
            map.loadCell(cellKeyAt(pos.x, pos.y));
            auto warm = pickups(map);
            assert(warm.length == 1 && warm[0].spawn.guid == alternate);

            successor.context.dungeons.restoreBattleground(arathi, basin.instance, snapshot);
            auto restored = pickups(map);
            assert(restored.length == 1 && restored[0].spawn.guid == selected,
                "the checkpoint's active pickup replaces the variant already loaded by this worker");
            auto copy = successor.context.battlegrounds.find(basin.instance);
            assert(copy.powerUpAvailable(selected) && !copy.powerUpAvailable(alternate));
        }
    }
    step(pos);
    assert(!pickups(me.currentMap).length);
    w.now += 90.seconds;
    const bytes = w.context.dungeons.snapshotBattleground(basin);
    auto replacement = RealWorld.make();
    auto clock = w.now + 30.seconds;
    replacement.context.clock = () => clock;
    replacement.context.battlegrounds.open(basin.instance, basin.type);
    auto map = replacement.context.map(arathi, basin.instance);
    map.loadCell(cellKeyAt(pos.x, pos.y));
    assert(pickups(map).length == 1);
    replacement.context.dungeons.restoreBattleground(arathi, basin.instance, bytes);
    auto recovered = replacement.context.battlegrounds.find(basin.instance);
    clock += 89.seconds;
    recovered.tick(Duration.zero);
    assert(!pickups(map).length, "no early respawn after recovery");
    clock += 1.seconds;
    recovered.tick(Duration.zero);
    assert(pickups(map).length == 1, "the same station respawns once on its remaining timer");
}

/// A `mangos_string` with its `%s`, `%u` and `%d` filled in order with `args`.
string formatServerString(string text, const(string)[] args)
{
    import std.array : appender;

    auto out_ = appender!string;
    size_t next;
    for (size_t i = 0; i < text.length; ++i)
    {
        if (text[i] == '%' && i + 1 < text.length && (text[i + 1] == 's' || text[i + 1] == 'u' || text[i + 1] == 'd'))
        {
            out_ ~= next < args.length ? args[next] : "";
            ++next;
            ++i;
        }
        else
            out_ ~= text[i];
    }
    return out_.data;
}

unittest
{
    assert(formatServerString("The battleground will close in %u mins.", ["4"]) == "The battleground will close in 4 mins.");
    assert(formatServerString("%s claims the %s!", ["The Alliance", "farm"]) == "The Alliance claims the farm!");
}

/// The battleground copies this node runs.
final class Battlegrounds
{
    private enum checkpointInterval = 2.seconds;
    private enum checkpointFormat = "3:", pendingResultFormat = "F:";
    private enum checkpointLifetime = 120;

    private
    {
        WorldContext context;
        Battleground[uint] copies;
        MonoTime[uint] mapRecoveryDue;
        bool[uint] mapsToRestore; // true when the old host transferred the live state
    }

    ///
    this(WorldContext context)
    {
        this.context = context;
    }

    /// Copy `instance`, if it runs here.
    Battleground find(uint instance)
    {
        return copies.get(instance, null);
    }

    /// The copies running here.
    @property Battleground[] all()
    {
        return copies.values;
    }

    /// Copy `instance` of `type`, made if it is new (when its first player comes).
    Battleground open(uint instance, BattlegroundType type)
    {
        import dmangos.log : info;

        if (auto known = instance in copies)
            return *known;
        info!"battleground: copy %s of %s made"(instance, type);
        auto copy = copies[instance] = new Battleground(context, instance, type, rulesFor(type));
        if (durable)
            queueChanged(copy, BattlegroundStatus.waitJoin);
        return copy;
    }

    /// A region move preserves the live copy without announcing a new match to the queue.
    package Battleground restore(uint instance, BattlegroundType type, ref ByteReader reader, uint formatVersion = 3)
    {
        import dmangos.world.battlegroundstate : BattlegroundState;

        auto restored = new Battleground(context, instance, type, rulesFor(type));
        auto state = BattlegroundState(context.clock(), reader: &reader);
        restored.transferState(state, formatVersion);
        restored.checkpointRetired = formatVersion < 3 && restored.status == BattlegroundStatus.waitLeave;
        return copies[instance] = restored;
    }

    /// The simulation is leaving with its map. Its queue slots remain valid on the new host.
    package void forgetMap(uint map)
    {
        if (context.battlegroup !is null && context.battlegroup.host !is context)
            return;
        mapsToRestore.remove(map);
        mapRecoveryDue.remove(map);
        foreach (id; copies.keys)
            if (copies[id].mapId == map)
                copies.remove(id);
    }

    /// Each battleground's rules (Warsong Gulch's, Arathi Basin's, ...); the shared ones for the others.
    BattlegroundRules rulesFor(BattlegroundType type)
    {
        import dmangos.world.warsong : WarsongRules;

        switch (type)
        {
        case BattlegroundType.warsongGulch:
            return new WarsongRules;
        case BattlegroundType.arathiBasin:
        {
            import dmangos.world.arathi : ArathiRules;

            return new ArathiRules;
        }
        case BattlegroundType.alteracValley:
        {
            import dmangos.world.alterac : AlteracRules;

            return new AlteracRules;
        }
        default:
            return new BattlegroundRules;
        }
    }

    /// New objects for the spawns of event pair (`event1`, `event2`) on `mapId`, for copy `instance`.
    MapObject[] eventSpawns(uint mapId, ubyte event1, ubyte event2, uint instance)
    {
        indexEvents();
        const ubyte[2] pair = [event1, event2];
        MapObject[] made;
        foreach (index; eventCreatures.get(eventKey(mapId, pair), null))
            if (auto c = context.makeCreature(&context.data.creatureSpawns[index]))
            {
                c.instanceId = instance;
                made ~= c;
            }
        foreach (index; eventObjects.get(eventKey(mapId, pair), null))
        {
            auto go = context.makeGameObject(context.data.gameObjectSpawns[index]);
            go.instanceId = instance;
            made ~= go;
        }
        return made;
    }

    private
    {
        size_t[][uint] eventCreatures, eventObjects; // by `eventKey`: indexes into the spawns
        bool indexed;

        static uint eventKey(uint mapId, const ubyte[2] pair) pure nothrow @nogc @safe
        {
            return mapId << 16 | pair[0] << 8 | pair[1];
        }
    }

    /// The spawns of each event pair (from `creature_battleground` and `gameobject_battleground`), found once.
    void indexEvents()
    {
        if (indexed)
            return;
        indexed = true;
        foreach (i, ref spawn; context.data.creatureSpawns)
            if (const e = spawn.guid in context.data.creatureBattleEvents)
                eventCreatures[eventKey(spawn.map, *e)] ~= i;
        foreach (i, ref spawn; context.data.gameObjectSpawns)
            if (const e = spawn.guid in context.data.gameObjectBattleEvents)
                eventObjects[eventKey(spawn.map, *e)] ~= i;
    }

    /// Each copy's tick.
    void tick(Duration elapsed)
    {
        foreach (map; mapsToRestore.keys)
            mapReady(map);
        reportRecoveredMaps();
        foreach (copy; copies.values)
            if (copy.mapId !in mapsToRestore && (!durable || context.canWrite()))
                copy.tick(elapsed);
        flushCheckpoints(true);
    }

    package @property bool durable() const
    {
        return context.battlegroundMapEpoch !is null;
    }

    package void recoverMap(uint map, bool transferred)
    {
        mapsToRestore[map] = transferred;
        mapReady(map);
    }

    /// Do not admit a player or report an empty map while its durable copies are still being loaded.
    package bool mapReady(uint map)
    {
        import dmangos.log : info, warning;
        import dmangos.mysql : DatabaseException;
        import std.algorithm.searching : startsWith;
        import std.base64 : Base64;

        if (map !in mapsToRestore)
            return true;
        if (!canCheckpoint(map))
            return false;
        const transferred = mapsToRestore[map];
        try
        {
            const since = transferred ? long.min : context.unixTime - checkpointLifetime;
            foreach (ref saved; context.database.loadBattlegroundCheckpoints(context.config.realmId, map, since))
            {
                if (auto copy = find(saved.instance))
                {
                    copy.checkpointRevision = saved.revision;
                    continue;
                }
                const formatVersion = saved.state.startsWith(checkpointFormat) || saved.state.startsWith(pendingResultFormat)
                    ? 3u : saved.state.startsWith("2:") ? 2u : saved.state.startsWith("1:") ? 1u : 0u;
                if (transferred || !formatVersion)
                    continue;
                // Claim the row before exposing the match. A late write using the old revision fails.
                if (!context.database.saveBattlegroundCheckpoint(context.config.realmId, map, saved))
                    return false;
                try
                {
                    context.dungeons.restoreBattleground(map, saved.instance, Base64.decode(saved.state[checkpointFormat.length .. $]),
                        formatVersion);
                    find(saved.instance).checkpointRevision = saved.revision + 1;
                    info!"battleground: copy %s restored on node %s after loss of its map host"(saved.instance, context.nodeId);
                }
                catch (Exception error)
                {
                    copies.remove(saved.instance);
                    context.closeBattlegroundMap(saved.instance);
                    warning!"battleground: could not restore copy %s: %s"(saved.instance, error.msg);
                }
            }
        }
        catch (DatabaseException error)
        {
            warning!"battleground: could not read saved copies of map %s: %s"(map, error.msg);
            return false;
        }
        mapsToRestore.remove(map);
        mapRecoveryDue[map] = MonoTime.init;
        return true;
    }

    package void flushCheckpoints(bool periodic = false)
    {
        if (!durable)
            return;
        const now = context.clock();
        foreach (copy; copies)
            if (!copy.checkpointRetired && !copy.endingPending
                && (copy.checkpointDirty || (periodic && now >= copy.nextCheckpoint)))
                saveCheckpoint(copy, false);
    }

    private bool canCheckpoint(uint map)
    {
        return context.dungeons.hostsDungeon(map) && context.battlegroundMapEpoch(map) && context.canWrite();
    }

    private bool retireCheckpoint(Battleground copy)
    {
        if (!durable || find(copy.instance) !is copy || copy.checkpointRetired)
            return true;
        if (copy.endingPending || !copy.publishFinalResult())
            return false;
        return saveCheckpoint(copy, true);
    }

    private bool saveCheckpoint(Battleground copy, bool retire)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.database : BattlegroundCheckpoint;
        import std.base64 : Base64;

        if (copy.mapId in mapsToRestore || !canCheckpoint(copy.mapId))
            return false;
        try
        {
            const format = copy.finalPublicationPending ? pendingResultFormat : checkpointFormat;
            const state = retire ? null : format ~ Base64.encode(context.dungeons.snapshotBattleground(copy)).idup;
            const row = BattlegroundCheckpoint(copy.instance, copy.checkpointRevision, context.unixTime, state);
            // Its objectives' rewards with it, each named by this revision (which only one save can take) and its
            // place: written again after a failed save, they are the same rows, and a superseded owner writes none.
            foreach (i, ref reward; copy.eventRewards)
                reward.event = (copy.checkpointRevision << 20) | i;
            if (context.database.saveBattlegroundCheckpoint(context.config.realmId, copy.mapId, row, copy.eventRewards))
            {
                copy.eventRewards = null;
                ++copy.checkpointRevision;
                copy.checkpointDirty = false;
                copy.checkpointRetired = retire;
                copy.nextCheckpoint = context.clock() + checkpointInterval;
                return true;
            }
            warning!"battleground: copy %s checkpoint was superseded by another owner"(copy.instance);
        }
        catch (DatabaseException error)
            warning!"battleground: could not checkpoint copy %s: %s"(copy.instance, error.msg);
        return false;
    }

    private void reportRecoveredMaps()
    {
        const now = context.clock();
        foreach (map; mapRecoveryDue.keys)
        {
            if (!context.dungeons.hostsDungeon(map))
            {
                mapRecoveryDue.remove(map);
                continue;
            }
            if (now < mapRecoveryDue[map])
                continue;
            const epoch = context.battlegroundMapEpoch(map);
            if (!epoch)
                continue;
            mapRecoveryDue[map] = now + 5.seconds;
            sendRecoveredMap(map, epoch);
        }
    }

    private void sendRecoveredMap(uint map, ulong epoch)
    {
        BattlegroundChanged[] live;
        foreach (copy; copies)
            if (copy.mapId == map)
                live ~= BattlegroundChanged(copy.instance, copy.status, epoch);
        context.services.call!(BattlegroundQueueHost.mapRecovered)(BattlegroundMapRecovered(map, epoch, live),
            (BattlegroundMapRecoveryReply reply) {
                if (reply.received && context.battlegroundMapEpoch(map) == epoch)
                    mapRecoveryDue.remove(map);
            });
    }

    private void queueChanged(Battleground copy, BattlegroundStatus status)
    {
        ulong epoch;
        if (durable)
        {
            if (!context.dungeons.hostsDungeon(copy.mapId))
                return;
            epoch = context.battlegroundMapEpoch(copy.mapId);
        }
        context.services.call!(BattlegroundQueueHost.changed)(BattlegroundChanged(copy.instance, status, epoch));
    }

    /// The copy closed: the queue told, its map gone.
    void closed(Battleground copy)
    {
        import dmangos.log : info;

        if (copies.get(copy.instance, null) !is copy)
            return;
        if (!retireCheckpoint(copy))
            return;
        copies.remove(copy.instance);
        queueChanged(copy, BattlegroundStatus.none);
        context.closeBattlegroundMap(copy.instance);
        info!"battleground: copy %s of %s closed"(copy.instance, copy.type);
    }
}

/// The battleground opcodes of a player in the world. See the module documentation.
mixin template BattlegroundHandlers()
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info, warning;
    import dmangos.world.battleground;
    import dmangos.world.bgqueue;
    import dmangos.world.database : BattlegroundData, BattlegroundReward;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.updatefields;

    /// `BGData`: the copy the player is in, and where it came from.
    package BattlegroundData battleground_;

    /// Loads the player's battleground data, at login or arrival.
    package void loadBattleground()
    {
        battleground_ = context.database.loadBattlegroundData(player.data.guid);
    }

    /// Saves the player's battleground data, with the character.
    package void saveBattleground()
    {
        context.database.saveBattlegroundData(player.data.guid, battleground_);
    }

    /// The player's team as the battlegrounds count it: 0 the Alliance, 1 the Horde.
    package ubyte battlegroundTeam()
    {
        import dmangos.world.clientdata : Team;

        return context.client.teamForRace(player.data.race) == Team.horde ? 1 : 0;
    }

    /// The copy the player is in, if it runs on this node.
    package Battleground currentBattleground()
    {
        if (battleground_.instance == 0 || battlegroundOfMap(player.data.map) == BattlegroundType.none)
            return null;
        return context.battlegrounds.find(battleground_.instance);
    }

    /// Whether the player may join a battleground: no Deserter.
    package bool mayJoinBattleground()
    {
        return player.auras.find(spellDeserter) is null;
    }

    /// `SMSG_GROUP_JOINED_BATTLEGROUND`
    package void sendGroupJoinedBattleground(int result)
    {
        ByteWriter w;
        w.put(result);
        deliver(Opcode.SMSG_GROUP_JOINED_BATTLEGROUND, w.data);
    }

    /// The battlemaster's list of copies (by the queue, which knows them).
    package void sendBattlegroundList(ulong battlemaster, BattlegroundType type)
    {
        context.services.call!(BattlegroundQueueHost.list)(BattlegroundList(player.guid, context.nodeId, battlemaster,
            type, cast(ubyte) player.data.level));
    }

    /// The battleground a battlemaster creature sends players to; `none` if it is none.
    package BattlegroundType battlemasterType(Npc creature)
    {
        const entry = creature.npcValues.get!OBJECT_FIELD_ENTRY;
        return context.data.battlemasters.get(entry, BattlegroundType.none);
    }

    /// Whether the player is of the levels a battlemaster takes (told if not).
    package bool canTalkToBattlemaster(BattlegroundType type, bool tell)
    {
        const t = type in context.data.battlegroundTemplates;
        if (t is null)
            return false;
        if (levelAllowed(*t, player.data.level))
            return true;
        if (tell)
            if (const text = stringLevelRequirement in context.data.serverStrings)
                send(ServerNotification(*text));
        return false;
    }

    /**
     * The player leaves its copy: out of it, back where it came from if `teleport`; Deserter if
     * the battle was on (or about to be), but for game masters.
     */
    package void leaveBattleground(bool teleport)
    {
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        if (battleground_.instance == 0)
            return;
        bool deserted;
        if (auto copy = context.battlegrounds.find(battleground_.instance))
        {
            deserted = copy.deserting && !allowsStaff("staff.game_master") && context.config.battlegroundCastDeserter;
            leaveTeamRaid(copy, battleground_.team);
            copy.removed(player.guid);
        }
        else // its copy runs elsewhere, or is gone: the queue frees the slot all the same
            context.services.call!(BattlegroundQueueHost.left)(BattlegroundLeft(battleground_.instance, player.guid,
                battleground_.team));
        const back = battleground_;
        battleground_ = BattlegroundData.init;
        saveBattleground();
        info!"%s: '%s' left battleground copy %s%s"(remoteAddress, player.data.name, back.instance,
            deserted ? " (a deserter)" : "");
        if (deserted)
            if (const spell = context.data.spells.spell(spellDeserter))
                castSpell(spell, SpellTargets(TargetFlags.self, player.guid), true, 0);
        if (teleport && battlegroundOfMap(player.data.map) != BattlegroundType.none)
            returnFromBattleground(back);
    }

    /// Back to where it was when it went in (else its home).
    package void returnFromBattleground(const BattlegroundData back)
    {
        if (back.joinMap != 0 || back.joinX != 0 || back.joinY != 0)
            if (teleportTo(back.joinMap, Position(back.joinX, back.joinY, back.joinZ, back.joinO)))
                return;
        const home = player.data.homeBind;
        teleportTo(home.map, Position(home.x, home.y, home.z, 0));
    }

    /**
     * `CMSG_BATTLEFIELD_PORT`'s entering half: the queue's answer. The player's way back is where it is
     * now (a dungeon or another battleground: its home), and it goes to its team's start.
     */
    package void enterBattleground(const BattlegroundEntry e)
    {
        import dmangos.world.clientdata : MapType;

        if (battleground_.instance == e.instance && (instanceId_ == e.instance || transferring))
            return;
        const t = e.type in context.data.battlegroundTemplates;
        if (t is null)
            return;
        const start = t.startLocations[e.team] in context.data.safeLocations;
        if (start is null)
            return warning!"battleground %s: no start location %s"(e.type, t.startLocations[e.team]);
        // Already in another copy: out of it first (no teleport, no deserter).
        if (battleground_.instance && battleground_.instance != e.instance)
        {
            if (auto copy = context.battlegrounds.find(battleground_.instance))
                copy.removed(player.guid);
            else
                context.services.call!(BattlegroundQueueHost.left)(BattlegroundLeft(battleground_.instance,
                    player.guid, battleground_.team));
        }
        BattlegroundData d;
        const here = context.client.maps.lookup(player.data.map);
        if (battleground_.instance && battlegroundOfMap(player.data.map) != BattlegroundType.none)
        {
            d = battleground_; // the way back stays the first copy's
        }
        else if (here is null || here.isDungeon || here.isBattleground)
        {
            const home = player.data.homeBind;
            d.joinMap = home.map;
            d.joinX = home.x;
            d.joinY = home.y;
            d.joinZ = home.z;
        }
        else
        {
            const p = player.position;
            d.joinMap = player.data.map;
            d.joinX = p.x;
            d.joinY = p.y;
            d.joinZ = p.z;
            d.joinO = p.orientation;
        }
        d.instance = e.instance;
        d.type = e.type;
        d.team = e.team;
        battleground_ = d;
        saveBattleground();
        if (player.deathState != DeathState.alive)
            bringBack(1.0f);
        info!"%s: '%s' goes into %s (copy %s)"(remoteAddress, player.data.name, cast(BattlegroundType) e.type,
            e.instance);
        teleportTo(start.map, Position(start.x, start.y, start.z, start.orientation), null, e.instance, false,
            e.requiresLiveCopy);
    }

    package void refusedBattlegroundEntry(uint instance)
    {
        if (battleground_.instance != instance)
            return;
        context.services.call!(BattlegroundQueueHost.left)(BattlegroundLeft(instance, player.guid, battleground_.team));
        battleground_ = BattlegroundData.init;
        saveBattleground();
    }

    /// The player arrived on a battleground map (at the world port's end): the copy adds it.
    package void battlegroundArrived()
    {
        if (battlegroundOfMap(player.data.map) == BattlegroundType.none || battleground_.instance != instanceId_)
            return;
        if (auto copy = context.battlegrounds.find(battleground_.instance))
        {
            if (context.battlegrounds.durable)
            {
                const progress = player.progress(secondsInWorld());
                context.database.saveProgress(progress);
                context.settleWrites(); // recovery must be able to find the character on this map
            }
            copy.arrived(player, battleground_.team); // its world states went with the map's packets
            updatePvP(true);
            flushPlayerChanges();
            joinTeamRaid(copy);
        }
    }

    /**
     * A player who came alone joins its team's raid in the copy: the first of the team leads it (the group
     * is made when the second comes). One who came with a group stays in it.
     */
    private void joinTeamRaid(Battleground copy)
    {
        import dmangos.world.groupservice : GroupOp;

        if (context.groups.of(player.guid) !is null || player.guid in copy.inTeamRaid)
            return;
        const team = battleground_.team;
        const leaderGuid = copy.raidLeaderOf.get(team, 0);
        auto leader = leaderGuid && leaderGuid != player.guid && leaderGuid in copy.members
            ? cast(typeof(this)) copy.memberSession(leaderGuid) : null;
        if (leader is null || leader.player is null)
        {
            copy.raidLeaderOf[team] = player.guid;
            copy.inTeamRaid[player.guid] = true;
            return;
        }
        copy.inTeamRaid[player.guid] = true;
        if (context.battlegroup is null)
            return leader.groupCommand(GroupOp.battlegroundAdd, player.guid, player.data.name);

        auto raids = context.battlegroup.raids;
        auto raid = raids.of(leaderGuid);
        if (raid is null)
        {
            raid = raids.newGroup();
            if (!raid.addLeaderInvite(leaderGuid, leader.player.data.name))
                return;
            raid.create();
            raid.convertToRaid();
        }
        raid.addMember(player.guid, player.data.name);
    }

    /// Leaving the copy: out of its team raid; a leader's place passes to whoever leads the raid now.
    private void leaveTeamRaid(Battleground copy, ubyte team)
    {
        import dmangos.world.groupservice : GroupOp;

        if (context.battlegroup !is null || player.guid !in copy.inTeamRaid)
            return;
        copy.inTeamRaid.remove(player.guid);
        auto group = context.groups.of(player.guid);
        if (copy.raidLeaderOf.get(team, 0) == player.guid)
        {
            copy.raidLeaderOf.remove(team);
            if (group !is null)
                foreach (ref m; group.members)
                    if (m.guid != player.guid && m.guid in copy.inTeamRaid)
                    {
                        copy.raidLeaderOf[team] = m.guid;
                        break;
                    }
        }
        if (group !is null)
            groupCommand(GroupOp.disband);
    }

    /**
     * Logged in (or arrived from another node) on a battleground's map: back into its copy if it
     * still runs and keeps the player's place; else out,
     * back where it came from.
     */
    package void battlegroundOnLogin(bool migrated = false)
    {
        if (battlegroundOfMap(player.data.map) == BattlegroundType.none || !context.dungeons.hostsDungeon(player.data.map))
            return;
        auto copy = currentBattleground();
        if (copy !is null && (migrated || copy.status != BattlegroundStatus.waitLeave || copy.canRejoinFinalScore()))
            if (auto member = player.guid in copy.members)
            {
                const rejoined = member.offlineSince != MonoTime.init;
                copy.arrived(player, battleground_.team);
                // A login on another node can send an empty world-state packet before this handoff.
                if (migrated)
                    sendInitWorldStates(player.data.zone);
                updatePvP(true);
                flushPlayerChanges();
                copy.rules.playerRestored(copy, player.guid);
                // A gateway's login packets cannot see the temporary raid on the shared match host.
                if (rejoined && context.battlegroup !is null)
                {
                    joinTeamRaid(copy);
                    if (auto raid = context.battlegroup.raids.of(player.guid))
                    {
                        groupChanged();
                        raid.updatePlayerOnlineStatus(this, true);
                    }
                }
                return;
            }
        info!"%s: '%s' is on a battleground's map, out of its copy: sent back"(remoteAddress, player.data.name);
        const back = battleground_;
        if (copy !is null)
        {
            leaveTeamRaid(copy, battleground_.team);
            copy.removed(player.guid);
        }
        else if (back.instance)
            context.services.call!(BattlegroundQueueHost.left)(BattlegroundLeft(back.instance, player.guid, back.team));
        battleground_ = BattlegroundData.init;
        saveBattleground();
        context.services.call!(BattlegroundQueueHost.status)(BattlegroundPlayer(player.guid, context.nodeId));
        returnFromBattleground(back);
    }

    /**
     * The battle is over, for this player: alive again if dead (else out of combat), its marks of honor
     * (a spell that makes them).
     */
    package void battlegroundEndedHere(uint markSpell)
    {
        if (player.deathState != DeathState.alive)
            bringBack(1.0f);
        battlegroundCastHere(markSpell);
    }

    /// Pays from a durable entitlement on the node that owns the character.
    package void payBattlegroundReward(const ref BattlegroundReward reward)
    {
        payBattleground(reward, null, (ref const p) => context.database.payBattlegroundReward(reward, p));
    }

    /// The event rewards whose quest credit this session applied, their payment not yet written.
    private bool[ulong[4]] creditedBattlegroundEvents;

    /**
     * Pays an objective's reward from its durable row (`Battleground.eventRewards`), once: its quest credit is applied
     * here and the quest log's changed rows are written with the receipt, its honor and its reputation. A payment
     * that does not commit is tried at the next poll; the credit is not applied twice meanwhile.
     */
    package void payBattlegroundEventReward(const ref imported!"dmangos.world.database".BattlegroundEventReward event)
    {
        import dmangos.world.quests : QuestStatus;

        const ulong[4] key = [event.reward.realm, event.reward.match, event.event, event.reward.player];
        if (key !in creditedBattlegroundEvents)
        {
            if (event.castSpell)
                battlegroundCastHere(event.castSpell);
            if (event.killCredit)
                scriptKillCredit(event.killCredit, 0);
            creditedBattlegroundEvents[key] = true;
        }
        QuestStatus[] quests;
        foreach (ref q; player.questStatus)
            if (q.changed)
                quests ~= q;
        if (!payBattleground(event.reward, quests,
                (ref const p) => context.database.payBattlegroundEventReward(event, p)))
            return;
        creditedBattlegroundEvents.remove(key);
        foreach (ref q; player.questStatus) // written with the receipt
            foreach (ref saved; quests)
                if (q.quest == saved.quest && q == saved)
                    q.changed = false;
    }

    /// The payment of `reward`, with `quests` written alongside; `commit` writes it with its receipt. Whether it paid.
    private bool payBattleground(const ref BattlegroundReward reward, imported!"dmangos.world.quests".QuestStatus[] quests,
        scope bool delegate(ref const imported!"dmangos.world.database".BattlegroundPayment) commit)
    {
        import std.algorithm.comparison : max;
        import dmangos.mysql : TransactionLost;
        import dmangos.world.database : BattlegroundPayment, MailRecord;
        import dmangos.world.defines : nullBag, nullSlot, inventorySlotBag0;
        import dmangos.world.inventory : Inventory, Item, ItemChange, ItemPosCount, ItemState, itemDynFlagBound;
        import dmangos.world.reputation : Reputation;
        import dmangos.world.spellids : SpellEffect;

        BattlegroundPayment payment;
        payment.quests = quests;
        payment.money = player.money.amount;
        payment.playerBytes = player.values[PLAYER_BYTES_2];
        auto inventory = player.inventory;
        if (inventory.hasChanges)
            flushInventory();

        ItemPosCount[] destinations;
        Item[] stacks;
        uint carried;
        // A mark that can never be made (its spell or item missing from the data) must not hold back the
        // honor and reputation of the same entitlement, nor keep it pending to be retried every second.
        bool markPrepared()
        {
            const spell = context.data.spells.spell(reward.markSpell);
            if (spell is null)
                return false;
            uint entry, count;
            foreach (i, effect; spell.effect)
                if (effect == SpellEffect.createItem)
                {
                    entry = spell.itemType[i];
                    count = cast(uint) max(1, spell.simpleValue(i));
                    break;
                }
            if (!entry || entry !in context.data.items)
                return false;
            inventory.canStoreNew(nullBag, nullSlot, destinations, entry, count);
            foreach (destination; destinations)
            {
                auto item = inventory.create(entry, destination.count);
                if (item is null)
                    return false;
                stacks ~= item;
                auto existing = inventory[destination.pos];
                auto row = existing is null ? item.record : existing.record;
                if (existing !is null)
                    row.count += destination.count;
                else
                {
                    const bag = cast(ubyte)(destination.pos >> 8);
                    if (bag != inventorySlotBag0)
                        row.bag = inventory[inventorySlotBag0, bag].record.guid;
                    row.slot = cast(ubyte) destination.pos;
                }
                if (Inventory.bindsWhenStored(item.proto, destination.pos))
                    row.flags |= itemDynFlagBound;
                payment.inventory ~= ItemChange(existing is null ? ItemState.new_ : ItemState.changed, row);
                carried += destination.count;
            }
            if (carried < count)
            {
                // Bags full: the rest comes by mail.
                auto item = inventory.create(entry, count - carried);
                if (item is null || item.count != count - carried)
                    return false;
                item.bind();
                payment.mailedItem = item.record;
                auto mail = &payment.mail;
                mail.id = context.nextMailId();
                mail.stationery = 61;
                mail.sender = mail.receiver = player.data.guid;
                mail.subject = "Battleground rewards";
                mail.checked = 0x04;
                mail.itemGuid = payment.mailedItem.guid;
                mail.itemEntry = entry;
                mail.deliverTime = context.unixTime;
                mail.expireTime = mail.deliverTime + 30 * 24 * 60 * 60;
            }
            return true;
        }
        if (reward.markSpell && !markPrepared())
        {
            import dmangos.log : warning;

            warning!"battleground reward of match %s for player %s: mark spell %s cannot make an item; paying the rest"(
                reward.match, reward.player, reward.markSpell);
            destinations = null;
            stacks = null;
            carried = 0;
            payment.inventory = null;
            payment.mail = MailRecord.init;
            payment.mailedItem = typeof(payment.mailedItem).init;
        }

        Reputation draft;
        if (reward.reputation.length && player.reputation !is null)
        {
            draft = new Reputation(context.client, 1u << (player.data.race - 1), 1u << (player.data.classId - 1));
            draft.states = player.reputation.states;
            draft.made = player.reputation.made.dup;
            foreach (ref gain; reward.reputation)
                if (const faction = context.client.factions.lookup(gain.faction))
                    draft.change(faction, gain.amount, true, context.data.spillovers);
            payment.reputation = draft.takeChanged();
        }
        if (reward.honor)
            saveHonor();
        if (!context.settleWrites())
            return false;
        try
        {
            if (!commit(payment))
                return false;
        }
        catch (TransactionLost error)
        {
            // If COMMIT succeeded before the connection dropped, this session may have stale item slots.
            connection.kick("the battleground reward transaction lost its database connection");
            throw error;
        }

        Item delivered;
        foreach (i, item; stacks)
            delivered = inventory.store(destinations[i .. i + 1], item);
        if (delivered !is null)
        {
            sendNewItem(delivered, carried, true, true);
            flushInventory(alreadySaved: true);
        }
        if (payment.mail.id)
            deliver(Opcode.SMSG_RECEIVED_MAIL, [ubyte(0), 0, 0, 0]);
        if (draft !is null)
        {
            player.reputation = draft;
            sendReputationChanges(-1);
            foreach (ref gain; reward.reputation)
                reputationChanged(gain.faction);
        }
        if (reward.honor)
        {
            loadHonor();
            ByteWriter credit;
            credit.put(reward.honor);
            credit.put(0UL);
            credit.put(0u);
            deliver(Opcode.SMSG_PVP_CREDIT, credit.data);
            flushPlayerChanges();
        }
        return true;
    }

    /// Casts `spell` on the player itself, triggered, if the spell exists.
    package void battlegroundCastHere(uint spell)
    {
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        if (spell)
            if (const info = context.data.spells.spell(spell))
                castSpell(info, SpellTargets(TargetFlags.self, player.guid), true, 0);
    }

    /// Removes the player's aura of `spell`, if it has one.
    package void battlegroundRemoveAuraHere(uint spell)
    {
        if (auto aura = player.auras.find(spell))
            removeAura(aura);
    }

    /// Bonus honor on the scoreboard: `honor` gained from no kill; whether it counted.
    package bool battlegroundBonusHonorHere(uint honor)
    {
        import dmangos.world.honor : HonorType;

        if (honor == 0)
            return false;
        addHonorPoints(honor, HonorType.honorable);
        return true;
    }

    /// The graveyards the player's copy gives or closes (`closestGraveyard`'s `linkTeams`); outside one, world PvP's.
    package const(uint[uint]) battlegroundGraveyards()
    {
        if (auto copy = currentBattleground())
            return copy.graveyardTeams;
        return context.worldPvp.graveyardTeams;
    }

    /// `SMSG_AREA_SPIRIT_HEALER_TIME`: when spirit guide `guide`'s next pulse is.
    package void sendSpiritHealerTime(ulong guide)
    {
        if (auto copy = currentBattleground())
        {
            ByteWriter w;
            w.put(guide);
            w.put(cast(uint) copy.untilSpiritHeal.total!"msecs");
            deliver(Opcode.SMSG_AREA_SPIRIT_HEALER_TIME, w.data);
        }
    }

    /**
     * Queueing at spirit guide `guide` (its gossip, `CMSG_AREA_SPIRIT_HEALER_QUEUE`): the dead wait for its
     * next pulse (`Waiting to Resurrect`, 2584).
     */
    package void queueAtSpiritGuide(ulong guide)
    {
        auto copy = currentBattleground();
        if (copy is null || player.deathState == DeathState.alive)
            return;
        copy.awaitingResurrection[player.guid] = guide;
        battlegroundCastHere(spellWaitingToResurrect);
        sendSpiritHealerTime(guide);
    }

    /// The spirit guides' pulse came: alive again, whole.
    package void spiritHealedHere()
    {
        if (player.deathState == DeathState.alive)
            return;
        bringBack(1.0f);
        spawnCorpseBones();
        if (auto waiting = player.auras.find(spellWaitingToResurrect))
            removeAura(waiting);
    }

    /// `SMSG_INIT_WORLD_STATES` for `zone`: on a battleground's map, its copy's states; elsewhere the
    /// server-wide ones (the war effort's, in the capitals; world PvP's, in the Eastern Plaguelands and Silithus).
    package void sendInitWorldStates(uint zone)
    {
        ByteWriter w;
        w.put(player.data.map);
        w.put(zone);
        auto copy = currentBattleground();
        if (copy is null)
        {
            auto states = context.warEffortHere.warEffortWorldStates(zone) ~ worldPvpStates(zone);
            if (context.invasion.running) states ~= context.invasion.worldStates();
            w.put(cast(ushort) states.length);
            foreach (s; states)
            {
                w.put(s[0]);
                w.put(s[1]);
            }
            return deliver(Opcode.SMSG_INIT_WORLD_STATES, w.data);
        }
        import std.algorithm.sorting : sort;

        auto ids = copy.worldStates.keys;
        ids.sort();
        w.put(cast(ushort) ids.length);
        foreach (id; ids)
        {
            w.put(id);
            w.put(copy.worldStates[id]);
        }
        deliver(Opcode.SMSG_INIT_WORLD_STATES, w.data);
    }

    /**
     * A group queues together: every member online (here or on another
     * node), of the player's side and bracket, none a Deserter (of those here: another node's refuse at the
     * invitation), no more than a team. The queue checks their slots.
     */
    package void joinBattlegroundAsGroup(BattlegroundType type, uint desired)
    {
        import dmangos.world.clientdata : Team;

        auto group = context.groups.of(player.guid);
        if (group is null)
            return;
        const t = type in context.data.battlegroundTemplates;
        enum : uint { tooLarge = 720, offlineMember = 727, mixedFaction = 728, mixedLevels = 729, memberDeserter = 731 }
        void refuse(uint stringId)
        {
            if (const text = stringId in context.data.serverStrings)
                deliver(Opcode.SMSG_MESSAGECHAT, battlegroundMessage(ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL, *text));
        }
        if (group.members.length > t.maxPerTeam)
            return refuse(tooLarge);
        const myTeam = context.client.teamForRace(player.data.race);
        const myBracket = bracketOf(*t, player.data.level);
        ulong[] guids;
        ushort[] nodes;
        foreach (ref slot; group.members)
        {
            ubyte race, level;
            ushort node;
            bool deserter;
            if (auto local = context.onlinePlayer(slot.guid))
            {
                if (local.player is null)
                    return refuse(offlineMember);
                race = local.player.data.race;
                level = cast(ubyte) local.player.data.level;
                deserter = !local.mayJoinBattleground();
                node = context.nodeId;
            }
            else if (auto remote = context.remotePlayer(slot.guid))
            {
                race = remote.entry.race;
                level = remote.entry.level;
                node = remote.node;
            }
            else
                return refuse(offlineMember);
            if (context.client.teamForRace(race) != myTeam)
                return refuse(mixedFaction);
            if (bracketOf(*t, level) != myBracket)
                return refuse(mixedLevels);
            if (deserter)
                return refuse(memberDeserter);
            guids ~= slot.guid;
            nodes ~= node;
        }
        context.services.call!(BattlegroundQueueHost.joinGroup)(BattlegroundGroupJoin(guids, nodes, battlegroundTeam(),
            cast(ubyte) player.data.level, type, desired), (BattlegroundJoinResult r) {
                enum ubyte alreadyQueued = 6, noSlot = 8;
                if (player is null)
                    return;
                if (r.error == alreadyQueued)
                    refuse(730);
                else if (r.error == noSlot)
                    refuse(732);
            });
    }

    /// Logging out: the queues left, a copy it is in keeps it a while.
    package void battlegroundLoggedOut()
    {
        context.services.call!(BattlegroundQueueHost.logout)(BattlegroundPlayer(player.guid, context.nodeId));
        if (auto copy = currentBattleground())
            copy.loggedOut(player.guid);
    }

private:
    /// The player talks to a battlemaster: the list of copies of its battleground.
    @Handles(Opcode.CMSG_BATTLEMASTER_HELLO, WorldState.inWorld)
    void handleBattlemasterHello(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        auto creature = interactableNpc(guid, NpcFlag.battlemaster);
        if (creature is null)
            return;
        const type = battlemasterType(creature);
        if (type == BattlegroundType.none || !canTalkToBattlemaster(type, true))
            return;
        sendBattlegroundList(guid, type);
    }

    /// The list of copies, asked for by map (the player's own guid as the battlemaster's).
    @Handles(Opcode.CMSG_BATTLEFIELD_LIST, WorldState.inWorld)
    void handleBattlefieldList(ref ByteReader reader)
    {
        const type = battlegroundOfMap(reader.read!uint);
        if (type != BattlegroundType.none)
            sendBattlegroundList(player.guid, type);
    }

    /// Queueing at a battlemaster, alone or as a group.
    @Handles(Opcode.CMSG_BATTLEMASTER_JOIN, WorldState.inWorld)
    void handleBattlemasterJoin(ref ByteReader reader)
    {
        const guid = reader.read!ulong, mapId = reader.read!uint, desired = reader.read!uint;
        const asGroup = reader.remaining >= 1 && reader.read!ubyte != 0;
        const type = battlegroundOfMap(mapId);
        if (type == BattlegroundType.none || type !in context.data.battlegroundTemplates)
            return;
        if (battleground_.instance && battlegroundOfMap(player.data.map) != BattlegroundType.none)
            return; // already in a battleground
        if (interactableNpc(guid, NpcFlag.battlemaster) is null)
            return;
        if (asGroup)
            return joinBattlegroundAsGroup(type, desired);
        if (!mayJoinBattleground())
            return sendGroupJoinedBattleground(joinedDeserter);
        context.services.call!(BattlegroundQueueHost.join)(BattlegroundJoin(player.guid, context.nodeId,
            battlegroundTeam(), cast(ubyte) player.data.level, type, desired));
    }

    /// Accepting an invitation (`action` 1), or leaving a queue.
    @Handles(Opcode.CMSG_BATTLEFIELD_PORT, WorldState.inWorld)
    void handleBattlefieldPort(ref ByteReader reader)
    {
        const mapId = reader.read!uint, action = reader.read!ubyte;
        const type = battlegroundOfMap(mapId);
        if (type == BattlegroundType.none || action > 1)
            return;
        bool enter = action == 1;
        if (enter && !mayJoinBattleground())
        {
            sendGroupJoinedBattleground(joinedDeserter);
            enter = false;
        }
        const asked = player.guid;
        context.services.call!(BattlegroundQueueHost.port)(BattlegroundPort(player.guid, context.nodeId, type, enter),
            (BattlegroundEntry e) {
                if (player is null || player.guid != asked || state_ != WorldState.inWorld || !e.enter)
                    return;
                enterBattleground(e);
            });
    }

    /// Every queue slot's state again.
    @Handles(Opcode.CMSG_BATTLEFIELD_STATUS, WorldState.inWorld)
    void handleBattlefieldStatus()
    {
        refreshBattlegroundQueue();
    }

package:
    /// Rebind the queue's delivery route after the gateway reloads this character.
    void refreshBattlegroundQueue()
    {
        context.services.call!(BattlegroundQueueHost.status)(BattlegroundPlayer(player.guid, context.nodeId));
    }

private:
    /// Leaving the battleground: not in combat, unless the battle is over.
    @Handles(Opcode.CMSG_LEAVE_BATTLEFIELD, WorldState.inWorld)
    void handleLeaveBattlefield(ref ByteReader reader)
    {
        const mapId = reader.remaining >= 4 ? reader.read!uint : player.data.map;
        if (mapId != player.data.map || battlegroundOfMap(mapId) == BattlegroundType.none)
            return;
        auto copy = currentBattleground();
        if (player.inCombat && (copy is null || copy.status != BattlegroundStatus.waitLeave))
            return;
        leaveBattleground(true);
    }

    /// The time to a spirit guide's next pulse.
    @Handles(Opcode.CMSG_AREA_SPIRIT_HEALER_QUERY, WorldState.inWorld)
    void handleAreaSpiritHealerQuery(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        if (interactableNpc(guid, NpcFlag.spiritGuide) !is null)
            sendSpiritHealerTime(guid);
    }

    /// A ghost queues at a spirit guide.
    @Handles(Opcode.CMSG_AREA_SPIRIT_HEALER_QUEUE, WorldState.inWorld)
    void handleAreaSpiritHealerQueue(ref ByteReader reader)
    {
        const guid = reader.read!ulong;
        if (interactableNpc(guid, NpcFlag.spiritGuide) !is null)
            queueAtSpiritGuide(guid);
    }

    /// The scoreboard.
    @Handles(Opcode.MSG_PVP_LOG_DATA, WorldState.inWorld)
    void handlePvPLogData()
    {
        if (auto copy = currentBattleground())
            deliver(Opcode.MSG_PVP_LOG_DATA, copy.scoreboard());
    }

    /// The positions of players to show on the map (Warsong Gulch's flag carriers), from the battleground's rules.
    @Handles(Opcode.MSG_BATTLEGROUND_PLAYER_POSITIONS, WorldState.inWorld)
    void handleBattlegroundPlayerPositions()
    {
        if (auto copy = currentBattleground())
            deliver(Opcode.MSG_BATTLEGROUND_PLAYER_POSITIONS, copy.rules.playerPositions(copy, battleground_.team));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Queued and invited, into a new copy of Warsong Gulch; its countdown; leaving: back where it was, out of the queue.
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata : mapEasternKingdoms, mapWarsongGulch;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto queue = context.battlegroundQueue;
    assert(queue !is null, "standalone, the queue runs here");
    queue.testing = true; // one player makes a copy
    queue.join(7, context.nodeId, 0, 10, BattlegroundType.warsongGulch, 0);
    uint[] statuses;
    foreach (p; anduin.read())
        if (p.opcode == Opcode.SMSG_BATTLEFIELD_STATUS)
            statuses ~= p.body_.length > 17 ? (cast(const(uint)[]) p.body_[13 .. 17])[0] : 0;
    assert(statuses == [BattlegroundStatus.waitQueue, BattlegroundStatus.waitJoin], "queued, then invited");

    ByteWriter port;
    port.put(mapWarsongGulch);
    port.put(ubyte(1));
    anduin.write(Opcode.CMSG_BATTLEFIELD_PORT, port.data);
    bool newWorld;
    foreach (p; anduin.read())
        newWorld = newWorld || p.opcode == Opcode.SMSG_NEW_WORLD;
    assert(newWorld, "sent into Warsong Gulch");
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    anduin.read();
    auto copy = context.battlegrounds.all[0];
    assert(copy.type == BattlegroundType.warsongGulch && 7 in copy.members && copy.members[7].team == 0);
    assert(db.battlegroundRows[7].instance == copy.instance && db.battlegroundRows[7].joinMap == mapEasternKingdoms,
        "its copy and its way back saved");

    // The countdown, from the first player in: a minute left, thirty seconds, the start.
    copy.tick(61.seconds);
    bool said(string text)
    {
        import std.string : indexOf;

        foreach (p; anduin.read())
            if (p.opcode == Opcode.SMSG_MESSAGECHAT && (cast(string) p.body_).indexOf(text) >= 0)
                return true;
        return false;
    }

    assert(said("begins in 1 minute"));
    copy.tick(30.seconds);
    assert(said("30 seconds"));
    copy.tick(30.seconds);
    assert(said("Let the battle") && copy.status == BattlegroundStatus.inProgress);

    // Leaving while it runs: back to Elwynn, out of the copy and the queue's slot.
    ByteWriter leave;
    leave.put(mapWarsongGulch);
    anduin.write(Opcode.CMSG_LEAVE_BATTLEFIELD, leave.data);
    anduin.read();
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    anduin.read();
    assert(anduin.session.character.data.map == mapEasternKingdoms);
    assert(copy.members.length == 0 && queue.ticketsOf(7) is null && 7 !in db.battlegroundRows);
    // Empty, and nobody else invited: it closes.
    copy.tick(1.seconds);
    now += 6.seconds;
    copy.tick(1.seconds);
    assert(context.battlegrounds.find(copy.instance) is null && queue.copies.length == 0, "closed");
}

/// Logging out inside keeps the place; logging back in after the copy closed sends the player back.
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.movement : Position;
    import dmangos.world.packets : ClientPlayerLogin;
    import dmangos.world.testclient;
    import dmangos.world.testdata : mapEasternKingdoms, mapWarsongGulch;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto varian = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    varian.read();
    auto queue = context.battlegroundQueue;
    queue.testing = true;
    queue.join(7, context.nodeId, 0, 10, BattlegroundType.warsongGulch, 0);
    ByteWriter port;
    port.put(mapWarsongGulch);
    port.put(ubyte(1));
    varian.write(Opcode.CMSG_BATTLEFIELD_PORT, port.data);
    varian.read();
    varian.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    varian.read();
    auto copy = context.battlegrounds.all[0];

    varian.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    varian.read();
    assert(copy.members[7].offlineSince != MonoTime.init, "its place kept a while");
    void savedWhereItWas() // the memory database keeps the saved place apart
    {
        db.loadable[7].map = db.progressSaves[$ - 1].map;
        db.loadable[7].position = db.progressSaves[$ - 1].position;
    }
    savedWhereItWas();
    varian.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    varian.read();
    assert(varian.session.character.data.map == mapWarsongGulch && copy.members[7].offlineSince == MonoTime.init,
        "back in its copy");

    varian.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    varian.read();
    copy.close();
    assert(copy.members.length == 0);
    savedWhereItWas();
    varian.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(7));
    varian.read();
    varian.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    varian.read();
    assert(varian.session.character.data.map == mapEasternKingdoms, "its copy is gone: back where it came from");
    assert(7 !in db.battlegroundRows);
}

version (unittest)
{
    import dmangos.world.testclient : TestClient;

    /// Two players of each side in a Warsong Gulch copy (testing: none needed), past the world port.
    private Battleground enterWarsong(WorldContext context, TestClient*[] players, const(uint)[] guids,
        const(ubyte)[] teams)
    {
        auto queue = context.battlegroundQueue;
        queue.testing = true;
        foreach (i, guid; guids)
            queue.join(guid, context.nodeId, teams[i], 10, BattlegroundType.warsongGulch, 0);
        foreach (p; players)
        {
            ByteWriter port;
            port.put(battlegroundMaps[BattlegroundType.warsongGulch]);
            port.put(ubyte(1));
            p.write(Opcode.CMSG_BATTLEFIELD_PORT, port.data);
            p.read();
            p.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
            p.read();
        }
        return context.battlegrounds.all[0];
    }
}

/// The shared framework: event spawns and doors, world states, kills on the scoreboard, team chat, bonus honor, the end.
unittest
{
    import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, goStateActive, goStateReady;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata : mapWarsongGulch, raceOrc;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    // A door (event 254) and a flag (event 0) by the Alliance's start.
    foreach (i, entry; [179918u, 179830u])
    {
        auto t = GameObjectTemplate.init;
        t.entry = entry;
        t.type = 0;
        t.displayId = 411;
        t.name = entry == 179918 ? "Doodad_PortcullisActive01" : "Silverwing Flag";
        context.data.gameObjectTemplates[entry] = t;
        const at = Position(1515 - i * 3, 1480, 352);
        context.data.gameObjectSpawns ~= GameObjectSpawn(90008 - cast(uint) i * 8, entry, mapWarsongGulch, at.x, at.y, at.z);
        context.data.gameObjectCells[mapWarsongGulch][cellKeyAt(at.x, at.y)] ~= context.data.gameObjectSpawns.length - 1;
    }
    context.data.gameObjectBattleEvents[90008] = [eventDoors, 0];
    context.data.gameObjectBattleEvents[90000] = [0, 0];

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8949.95f, -132.49f, 83.53f));
    auto thrall = loggedIn(context, db, 8, "Thrall", Position(1629, -4373, 31), AccountLevel.player, raceOrc, 1);
    anduin.read();
    varian.read();
    thrall.read();
    auto copy = enterWarsong(context, [&anduin, &varian, &thrall], [7, 9, 8], [0, 0, 1]);
    auto map = context.existingMap(mapWarsongGulch, copy.instance);
    GameObject find(uint spawn)
    {
        GameObject found;
        map.forEachObject((MapObject o) {
            if (auto go = cast(GameObject) o)
                if (go.spawn.guid == spawn)
                    found = go;
        });
        return found;
    }

    assert(find(90008) !is null && find(90008).goState == goStateReady, "the door is there, closed");
    assert(find(90000) is null, "the flag is not spawned before its event");
    copy.spawnEvent(0, 0, true);
    assert(find(90000) !is null, "spawned with its event");
    copy.spawnEvent(0, 0, false);
    assert(find(90000) is null, "and gone with it");
    copy.start();
    assert(find(90008).goState == goStateActive, "the doors open at the start");

    // World states go to everyone in it, and come with the map to whoever arrives.
    copy.setWorldState(1581, 2);
    bool stateSeen(ref TestClient c)
    {
        foreach (p; c.read())
            if (p.opcode == Opcode.SMSG_UPDATE_WORLD_STATE)
                return true;
        return false;
    }
    assert(stateSeen(anduin) && stateSeen(thrall));

    // Thrall killed by Anduin: a killing blow and a kill to Anduin, a death to Thrall; none to Varian, at
    // the Alliance's start, far from Thrall at the Horde's.
    copy.playerKilled(victim: 8, killer: 7);
    assert(copy.members[7].killingBlows == 1 && copy.members[7].honorableKills == 1);
    assert(copy.members[9].honorableKills == 0 && copy.members[9].killingBlows == 0);
    assert(copy.members[8].deaths == 1);

    // Thrall dead in it: his insignia may be taken; Anduin takes it from his body (not yet released). He is
    // released, his corpse turns to bones, and Anduin gets their loot (a little money).
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.character : Character;
        import dmangos.world.corpse : Corpse, CorpseType, corpseDynLootable;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.player : DeathState;
        import dmangos.world.updatefields : CORPSE_FIELD_DYNAMIC_FLAGS, UNIT_FIELD_FLAGS, UNIT_FIELD_HEALTH;

        auto dead = context.onlinePlayer(8), looter = context.onlinePlayer(7);
        dead.player.values.set!UNIT_FIELD_HEALTH(0u);
        dead.playerDied(false);
        assert(dead.player.values.get!UNIT_FIELD_FLAGS & UnitFlags.skinnable, "marked for his insignia");
        thrall.read();
        anduin.read();
        dead.removedInsignia(looter);
        assert(dead.player.deathState == DeathState.ghost, "released");
        assert(thrall.read().canFind!(p => p.opcode == Opcode.SMSG_PLAYER_SKINNED));
        Corpse bones;
        map.forEachObject((MapObject o) {
            if (auto c = cast(Corpse) o)
                if (c.type == CorpseType.bones)
                    bones = c;
        });
        size_t bodies;
        map.forEachObject((MapObject o) {
            if (auto c = cast(Corpse) o)
                bodies += c.type != CorpseType.bones;
        });
        assert(bodies == 0, "his body gone");
        assert(bones !is null && bones.loot !is null, "lootable bones (no money at level 1: CMaNGOS's formula)");
        assert(bones.values.get!CORPSE_FIELD_DYNAMIC_FLAGS == corpseDynLootable);
        assert(anduin.read().canFind!(p => p.opcode == Opcode.SMSG_LOOT_RESPONSE), "the loot shown to Anduin");
    }

    // Battleground chat is the team's.
    anduin.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_BATTLEGROUND, "for the Alliance"));
    bool heard(ref TestClient c)
    {
        foreach (p; c.read())
            if (p.opcode == Opcode.SMSG_MESSAGECHAT && p.body_[0] == ChatType.CHAT_MSG_BATTLEGROUND)
                return true;
        return false;
    }
    assert(heard(varian) && !heard(thrall));

    copy.rewardHonorToTeam(1, 0);
    // One unit, in the bracket 10-19 (the players' level 1 below it): 24.
    assert(copy.members[7].bonusHonor == 24 && copy.members[9].bonusHonor == 24 && copy.members[8].bonusHonor == 0);

    thrall.read();
    copy.end(winnerAlliance);
    assert(copy.status == BattlegroundStatus.waitLeave);
    bool board;
    foreach (p; thrall.read())
        if (p.opcode == Opcode.MSG_PVP_LOG_DATA)
            board = p.body_[0] == 1 && p.body_[1] == winnerAlliance;
    assert(board, "the scoreboard, over, the Alliance the winner");
    // Two minutes on, everyone is sent back.
    copy.tick(endDelay);
    assert(copy.members.length == 0);
}

/// A team short of players for five minutes: warned each minute, then it ends.
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto copy = enterWarsong(context, [&anduin], [7], [0]);
    copy.start();
    anduin.read();
    copy.tick(1.seconds);
    string[] warnings;
    foreach (p; anduin.read())
        if (p.opcode == Opcode.SMSG_MESSAGECHAT)
            warnings ~= cast(string) p.body_;
    assert(warnings.length == 1, "warned at once");
    copy.tick(60.seconds);
    assert(copy.status == BattlegroundStatus.inProgress);
    copy.tick(240.seconds);
    assert(copy.status == BattlegroundStatus.waitLeave && copy.winner == winnerAlliance, "the side with players wins");
}

/// The dead queue at a spirit guide and come back at its next pulse; a battleground's graveyards are its own.
unittest
{
    import dmangos.world.combat : MeleeDamage, MeleeHitOutcome;
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.player : DeathState;
    import dmangos.world.testclient;
    import dmangos.world.testdata : creatureInnkeeper, mapWarsongGulch;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // An Alliance spirit guide at the Alliance's start.
    auto guide = cast() context.data.creatureTemplates[creatureInnkeeper];
    guide.entry = 13116;
    guide.npcFlags = 0x40; // UNIT_NPC_FLAG_SPIRITGUIDE
    context.data.creatureTemplates[13116] = guide;
    const at = Position(1517, 1481, 352);
    context.data.creatureSpawns ~= CreatureSpawn(150000, 13116, mapWarsongGulch, at.x, at.y, at.z);
    context.data.creatureCells[mapWarsongGulch][cellKeyAt(at.x, at.y)] ~= context.data.creatureSpawns.length - 1;

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto copy = enterWarsong(context, [&anduin], [7], [0]);
    copy.start();
    auto me = anduin.session.character;
    MeleeDamage blow;
    blow.damage = 10_000;
    blow.outcome = MeleeHitOutcome.normal;
    anduin.session.inWorld.unit.meleeHitBy(0xF130_0000_0000_0001, blow);
    anduin.read();
    assert(me.deathState != DeathState.alive);
    assert(copy.members[7].deaths == 1, "a death on the scoreboard, though no player killed it");

    ByteWriter w;
    w.put(makeGuid(HighGuid.unit, 13116, 150000));
    anduin.write(Opcode.CMSG_AREA_SPIRIT_HEALER_QUEUE, w.data);
    bool timeSent;
    foreach (p; anduin.read())
        timeSent = timeSent || p.opcode == Opcode.SMSG_AREA_SPIRIT_HEALER_TIME;
    assert(timeSent && 7 in copy.awaitingResurrection, "queued, and told when");
    now += copy.untilSpiritHeal + 1.msecs;
    copy.tick(1.seconds);
    assert(me.deathState == DeathState.alive && copy.awaitingResurrection.length == 0, "the pulse brought it back");

    // A graveyard the battleground closes is not chosen; one it gives a team is.
    import dmangos.world.death : closestGraveyard, teamAlliance, teamInvalid;
    import dmangos.world.worlddata : GraveyardLink, graveyardLinkKey;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : worldSafeLocsFormat;

    import dmangos.bytes : bits = floatBits;
    context.client.worldSafeLocs = typeof(context.client.worldSafeLocs).parse(buildDbc(worldSafeLocsFormat,
        [[769u, mapWarsongGulch, bits(1400), bits(1500), bits(350), 0, 0, 0, 0, 0, 0, 0, 0, 0],
         [771u, mapWarsongGulch, bits(1000), bits(1500), bits(350), 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "WorldSafeLocs.dbc");
    context.data.graveyards[graveyardLinkKey(3277, 0)] = [GraveyardLink(769, 0), GraveyardLink(771, teamAlliance)];
    const near = Position(1450, 1500, 350);
    assert(closestGraveyard(context.data, context.client, mapWarsongGulch, near, teamAlliance, 3277, 0).id == 769);
    const uint[uint] closed = [769: teamInvalid];
    assert(closestGraveyard(context.data, context.client, mapWarsongGulch, near, teamAlliance, 3277, 0, closed).id == 771);
}

/// The GM can inspect and start a live match and send a world-state update to its clients.
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto gm = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    gm.read();
    auto copy = enterWarsong(context, [&gm], [7], [0]);
    gm.say(".battleground bginfo");
    assert(gm.read().length);
    gm.say(".battleground startbg");
    assert(copy.status == BattlegroundStatus.inProgress);
    gm.say(".battleground setworldstates 9999 42");
    assert(copy.worldStates[9999] == 42 && gm.read().opcodesOf.canFind(Opcode.SMSG_UPDATE_WORLD_STATE));
    gm.say(".battleground playsound 3439");
    assert(gm.read().opcodesOf.canFind(Opcode.SMSG_PLAY_SOUND));

    gm.say(".bg pause on");
    assert(copy.paused);
    const pausedAt = copy.sinceMs;
    now += 10.seconds;
    copy.tick(10.seconds);
    assert(copy.sinceMs == pausedAt);
    auto successor = newCreationContext(db);
    successor.clock = () => now;
    successor.dungeons.restoreBattleground(copy.mapId, copy.instance, context.dungeons.snapshotBattleground(copy));
    auto restored = successor.battlegrounds.find(copy.instance);
    assert(restored.paused && restored.sinceMs == pausedAt && restored.worldStates[9999] == 42);
    assert(restored.setPaused(false));
    now += 1.seconds;
    assert(restored.sinceMs == pausedAt + 1000);
}

/// A group queues as one: every member gets the slot; one already queued keeps the group out.
unittest
{
    auto now = MonoTime.currTime;
    BattlegroundQueue q = new BattlegroundQueue;
    q.templates[BattlegroundType.warsongGulch] = BattlegroundTemplate(2, 2, 3, 10, 60, [769, 770], 75, 0);
    q.clock = () => now;
    Opcode[] sent;
    q.deliver = (ulong, ushort, Opcode op, const(ubyte)[]) { sent ~= op; };
    assert(q.joinGroup([1, 2], [1, 1], 0, 15, BattlegroundType.warsongGulch, 0) == BattlegroundQueue.JoinError.ok);
    assert(q.ticketsOf(1).length && q.ticketsOf(2).length && q.queuedPlayers == 2);
    import std.algorithm.searching : count;

    assert(sent.count(Opcode.SMSG_GROUP_JOINED_BATTLEGROUND) == 2);
    assert(q.joinGroup([3, 2], [1, 1], 0, 15, BattlegroundType.warsongGulch, 0)
        == BattlegroundQueue.JoinError.memberAlreadyInQueue);
    assert(q.ticketsOf(3) is null);
}

/// A battleground whose rules throw on every tick: the tick logs it, counts it and goes on.
unittest
{
    import dmangos.world.testclient;

    static class Broken : BattlegroundRules
    {
        override void tick(Battleground, Duration)
        {
            throw new Exception("broken rules");
        }
    }

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto copy = context.battlegrounds.open(4242, BattlegroundType.warsongGulch);
    copy.rules = new Broken;
    copy.testing = true;
    copy.start();
    foreach (i; 0 .. 3)
    {
        now += 100.msecs;
        context.update(now); // throws nothing
    }
    assert(context.tickFaults == 3);
}

/// A team's raid: the players of a team who came alone are in one raid in the copy, and leave it as they leave.
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata : raceOrc;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8949.95f, -132.49f, 83.53f));
    auto thrall = loggedIn(context, db, 8, "Thrall", Position(1629, -4373, 31), AccountLevel.player, raceOrc, 1);
    anduin.read();
    varian.read();
    thrall.read();
    auto copy = enterWarsong(context, [&anduin, &varian, &thrall], [7, 9, 8], [0, 0, 1]);
    auto raid = context.groups.of(7);
    assert(raid !is null && context.groups.of(9) is raid && raid.isRaid, "the Alliance's raid");
    assert(context.groups.of(8) is null, "alone on his side: no raid yet");

    varian.session.inWorld.leaveBattleground(false);
    assert(context.groups.of(9) is null, "out of the raid as he leaves");
}

/// A mark the data cannot make still pays the entitlement's honor and ends its retries.
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto varian = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f));
    varian.read();
    const reward = BattlegroundReward(context.config.realmId, 1, 7, 999_999, 24, 1);
    db.publishBattlegroundResult(reward.realm, reward.match, PvpStatsBattleground.init, null, [reward], false);
    varian.session.inWorld.payBattlegroundReward(reward);
    assert(!db.pendingBattlegroundRewards().length, "paid, not pending again every second");
    assert(db.loadHonor(7).points.length == 1, "the honor is not withheld");
}

/// A cluster member out of item ids pays a mark later: the reward waits, unpaid, and the rest of the tick goes on.
/// A deleted character's unpaid reward goes with it, for no new character of the same guid to collect.
unittest
{
    import core.time : seconds;
    import dmangos.cluster.ownership : IdPool;
    import dmangos.world.characterdb : DeleteOptions;
    import dmangos.world.movement : Position;
    import dmangos.world.spells : SpellEffect, SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata : itemJerky;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.battlegroundMapEpoch = (uint) => 1UL;
    enum uint mark = 91_509;
    SpellInfo makesMark;
    makesMark.id = mark;
    makesMark.effect[0] = SpellEffect.createItem;
    makesMark.itemType[0] = itemJerky;
    context.data.spells.spells[mark] = makesMark;
    auto varian = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f));
    varian.read();
    context.idPool = new IdPool(8); // no block has come
    const reward = BattlegroundReward(context.config.realmId, 1, 7, mark, 24, 1);
    db.publishBattlegroundResult(reward.realm, reward.match, PvpStatsBattleground.init, null, [reward], false);
    {
        import std.exception : assertThrown;
        import dmangos.world.context : IdsExhausted;

        assertThrown!IdsExhausted(varian.session.inWorld.payBattlegroundReward(reward), "no id for the mark");
    }
    now += 2.seconds;
    context.update(now); // the poll meets the same: it does not escape the tick
    assert(db.pendingBattlegroundRewards().length == 1, "nothing paid without an id for the mark");

    db.deleteCharacter(7, 1, DeleteOptions.init, () => 0u);
    assert(!db.pendingBattlegroundRewards().length, "the reward goes with its character");
}

/// A match recovered after a crash that ends before its players reconnect still keeps their final rewards.
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.warsong : winKills;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto varian = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), characterLevel: 25);
    varian.read();
    auto copy = enterWarsong(context, [&varian], [7], [0]);
    copy.start();
    assert(copy.memberLevels.get(7, 0) == 25);

    auto successor = newCreationContext(db);
    successor.clock = () => now;
    successor.battlegroundMapEpoch = (uint) => 1UL;
    successor.dungeons.restoreBattleground(copy.mapId, copy.instance, context.dungeons.snapshotBattleground(copy));
    auto restored = successor.battlegrounds.find(copy.instance);
    assert(restored.members[7].offlineSince != MonoTime.init && 7 in restored.offlineByCrash);
    restored.end(winnerAlliance);
    const rewards = db.pendingBattlegroundRewards();
    assert(rewards.length == 1 && rewards[0].player == 7, "the crash-offline winner keeps its reward");
    assert(rewards[0].markSpell == markSpells[BattlegroundType.warsongGulch][0]);
    assert(rewards[0].honor == bonusHonor(winKills, *restored.template_, 25), "by its own bracket");
}

/// An objective's honor during a durable match is written with the checkpoint that records the objective and paid
/// once from there: not before, not twice, and to a crash-offline player when it is back.
unittest
{
    import core.time : seconds;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata : mapWarsongGulch;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.battlegroundMapEpoch = (uint map) => map == mapWarsongGulch ? 1UL : 0UL;
    auto varian = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), characterLevel: 25);
    varian.read();
    auto copy = enterWarsong(context, [&varian], [7], [0]);
    copy.start();
    context.battlegrounds.flushCheckpoints();
    const before = db.loadHonor(7).points.length;

    copy.rewardHonorToTeam(2, 0); // a flag captured
    const scored = copy.members[7].bonusHonor;
    assert(scored > 0, "on the scoreboard at once");
    assert(!db.pendingBattlegroundEventRewards().length, "not in the database before its checkpoint");
    context.battlegrounds.flushCheckpoints();
    assert(db.pendingBattlegroundEventRewards().length == 1, "with the checkpoint that records the capture");
    now += 2.seconds;
    context.update(now);
    assert(!db.pendingBattlegroundEventRewards().length && db.loadHonor(7).points.length == before + 1, "paid");
    now += 2.seconds;
    context.update(now);
    assert(db.loadHonor(7).points.length == before + 1, "once");

    // Another capture; the worker crashes before its checkpoint: the capture and its honor are lost together.
    copy.rewardHonorToTeam(2, 0);
    auto successor = newCreationContext(db);
    successor.clock = () => now;
    successor.battlegroundMapEpoch = (uint map) => map == mapWarsongGulch ? 2UL : 0UL;
    successor.battlegrounds.recoverMap(mapWarsongGulch, false);
    auto restored = successor.battlegrounds.find(copy.instance);
    assert(restored !is null && restored.members[7].bonusHonor == scored, "the checkpoint's score");
    assert(!db.pendingBattlegroundEventRewards().length, "and no honor for the capture it does not record");

    // A capture on the successor while Varian is offline by the crash: his honor waits for his return.
    assert(7 in restored.offlineByCrash);
    restored.rewardHonorToTeam(2, 0);
    successor.battlegrounds.flushCheckpoints();
    assert(db.pendingBattlegroundEventRewards().length == 1);
    auto back = loggedIn(successor, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), characterLevel: 25);
    back.read();
    now += 2.seconds;
    successor.update(now);
    assert(!db.pendingBattlegroundEventRewards().length && db.loadHonor(7).points.length == before + 2,
        "paid on his return, once");
}
