/**
 * Battleground copies and the players' battleground opcodes (CMaNGOS-classic's `BattleGround`,
 * `BattleGroundMgr::SendToBattleGround` and `BattleGroundHandler.cpp`).
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

import dmangos.bytes : ByteWriter;
import dmangos.world.bgqueue;
import dmangos.world.context : WorldContext;
import dmangos.world.opcodes : ChatType, Language, Opcode;

/// `SPELL_ID_BATTLEGROUND_DESERTER`
enum uint spellDeserter = 26013;

/// `BattleGroundStartTimeIntervals`, `TIME_TO_AUTOREMOVE`, `MAX_OFFLINE_TIME`
enum Duration startDelay = 2.minutes, endDelay = 2.minutes, offlineLimit = 300.seconds;

/// `mangos_string`: each battleground's "begins in 1 minute", "in 30 seconds" and "begin!" (by type).
immutable uint[3][4] countdownStrings = [[0, 0, 0], [784, 785, 786], [602, 603, 604], [661, 662, 663]];

/// `mangos_string` 600, 601: "The Alliance wins!", "The Horde wins!"
enum uint stringAllianceWins = 600, stringHordeWins = 601;

/// `mangos_string` 715: "You don't meet Battleground level requirements"
enum uint stringLevelRequirement = 715;

/// The sound of the start (`SOUND_BG_START`) and of each team's win.
enum uint soundStart = 3439, soundAllianceWins = 8455, soundHordeWins = 8454;

/// `BattleGroundWinner`: what the scoreboard says of the winner.
enum ubyte winnerHorde = 0, winnerAlliance = 1, winnerNone = 2;

/// `GroupJoinBattlegroundResult`: what `SMSG_GROUP_JOINED_BATTLEGROUND` says of a deserter.
enum int joinedDeserter = -2;

/// The number of extra scoreboard columns of each battleground.
immutable uint[4] extraScores = [0, 7, 2, 2];

/// A system message of a battleground (`CHAT_MSG_BG_SYSTEM_*`), as `SMSG_MESSAGECHAT`'s body.
ubyte[] battlegroundMessage(ChatType type, string text, ulong source = 0)
{
    import dmangos.world.queries : chatMessage;

    return chatMessage(type, Language.LANG_UNIVERSAL, source, text);
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

    /// A player of the copy (`BattleGroundPlayer`) and its score (`BattleGroundScore`).
    static struct Member
    {
        ubyte team;
        MonoTime offlineSince; /// set while logged out
        uint killingBlows, deaths, honorableKills, bonusHonor;
        uint[7] extra;
    }

    /// Its players, by guid.
    Member[ulong] members;

    private
    {
        WorldContext context;
        Duration startLeft = startDelay;
        ubyte said;            // countdown messages said
        Duration endLeft;
        MonoTime emptySince;
        bool asking;           // whether the queue was asked if anyone may still come
    }

    ///
    this(WorldContext context, uint instance, BattlegroundType type)
    {
        this.context = context;
        this.instance = instance;
        this.type = type;
        made = context.clock();
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
        return cast(uint)(context.clock() - made).total!"msecs";
    }

    /// The copy's map id.
    @property uint mapId() const
    {
        return battlegroundMaps[type];
    }

    /**
     * `BattleGround::AddPlayer`: player `guid` of `team` came in (or came back after logging out). The
     * other players of its team are told; over already, it is shown the scoreboard.
     */
    void arrived(ulong guid, ubyte team)
    {
        import dmangos.log : info;

        if (auto known = guid in members)
        {
            known.offlineSince = MonoTime.init;
            return;
        }
        members[guid] = Member(team);
        ByteWriter w;
        w.put(guid);
        toTeam(team, Opcode.SMSG_BATTLEGROUND_PLAYER_JOINED, w.data, guid);
        if (status == BattlegroundStatus.waitLeave)
            if (auto who = context.onlinePlayer(guid))
                who.deliver(Opcode.MSG_PVP_LOG_DATA, scoreboard());
        info!"battleground: %s (copy %s) has %s Alliance and %s Horde players"(type, instance, count(0), count(1));
    }

    /**
     * `BattleGround::RemovePlayerAtLeave`, the copy's part: player `guid` is out, its team told, and the
     * queue (which frees its slot and its place). Whether it deserted is the leaving player's to know.
     */
    void removed(ulong guid)
    {
        auto m = guid in members;
        if (m is null)
            return;
        const team = m.team;
        members.remove(guid);
        ByteWriter w;
        w.put(guid);
        toTeam(team, Opcode.SMSG_BATTLEGROUND_PLAYER_LEFT, w.data, guid);
        context.services.call!(BattlegroundQueueHost.left)(BattlegroundLeft(instance, guid, team));
    }

    /// `BattleGround::EventPlayerLoggedOut`: it keeps its place for five minutes.
    void loggedOut(ulong guid)
    {
        if (auto m = guid in members)
            m.offlineSince = context.clock();
    }

    /// Whether players leaving now desert (`LeaveBattleground`'s deserter rule).
    @property bool deserting() const
    {
        return status == BattlegroundStatus.waitJoin || status == BattlegroundStatus.inProgress;
    }

    /// `BattleGround::Update`
    void tick(Duration elapsed)
    {
        const now = context.clock();
        // Those offline too long go (`m_offlineQueue`).
        ulong[] gone;
        foreach (guid, ref m; members)
            if (m.offlineSince != MonoTime.init && now - m.offlineSince >= offlineLimit)
                gone ~= guid;
        foreach (guid; gone)
            removed(guid);

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
            break;
        case BattlegroundStatus.waitLeave:
            endLeft -= elapsed;
            if (endLeft <= Duration.zero)
                sendEveryoneOut();
            break;
        case BattlegroundStatus.none, BattlegroundStatus.waitQueue:
            break;
        }
        closeIfEmpty(now);
    }

    /// The countdown's end: the battle begins (`StartingEventOpenDoors`, `SetStatus(STATUS_IN_PROGRESS)`).
    void start()
    {
        import dmangos.log : info;

        if (status != BattlegroundStatus.waitJoin)
            return;
        said = 3;
        startLeft = Duration.zero;
        message(countdownStrings[type][2], ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
        playSound(soundStart);
        setStatus(BattlegroundStatus.inProgress);
        info!"battleground: %s (copy %s) begins"(type, instance);
    }

    /**
     * `BattleGround::EndBattleGround`: `winner` (`winnerAlliance`, `winnerHorde`, `winnerNone`) is
     * told, everyone shown the scoreboard, and sent out two minutes later.
     */
    void end(ubyte winner)
    {
        import dmangos.log : info;

        if (status == BattlegroundStatus.waitLeave)
            return;
        this.winner = winner;
        setStatus(BattlegroundStatus.waitLeave);
        endLeft = endDelay;
        if (winner == winnerAlliance)
        {
            playSound(soundAllianceWins, 0);
            message(stringAllianceWins, ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
        }
        else if (winner == winnerHorde)
        {
            playSound(soundHordeWins, 1);
            message(stringHordeWins, ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
        }
        const board = scoreboard();
        foreach (guid, ref m; members)
            if (auto who = context.onlinePlayer(guid))
            {
                who.deliver(Opcode.MSG_PVP_LOG_DATA, board);
                const slot = 0; // the client finds the slot by the map
                who.deliver(Opcode.SMSG_BATTLEFIELD_STATUS, battlefieldStatus(slot, type, 0,
                    BattlegroundStatus.inProgress, cast(uint) endDelay.total!"msecs", sinceMs));
            }
        info!"battleground: %s (copy %s) is over, won by %s"(type, instance,
            winner == winnerAlliance ? "the Alliance" : winner == winnerHorde ? "the Horde" : "nobody");
    }

    /// ArcEmu's `CBattleground::Close` (`.battleground leave`): everyone out now, the copy closed.
    void close()
    {
        if (status != BattlegroundStatus.waitLeave)
            setStatus(BattlegroundStatus.waitLeave);
        sendEveryoneOut();
    }

    /// `BattleGroundMgr::BuildPvpLogDataPacket`: `MSG_PVP_LOG_DATA`'s body.
    const(ubyte)[] scoreboard()
    {
        ByteWriter w;
        const over = status == BattlegroundStatus.waitLeave;
        w.put(ubyte(over));
        if (over)
            w.put(winner);
        w.put(cast(uint) members.length);
        foreach (guid, ref m; members)
        {
            w.put(guid);
            uint rank = 4; // `GetHonorRankInfo().rank` of a player not here
            if (auto who = context.onlinePlayer(guid))
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

    /// `BattleGround::SendMessageToAll`: `mangos_string` `id` to everyone in it.
    void message(uint id, ChatType chatType, ulong source = 0)
    {
        if (const text = id in context.data.serverStrings)
            toAll(Opcode.SMSG_MESSAGECHAT, battlegroundMessage(chatType, *text, source));
    }

    /// `PlaySoundToAll`, `PlaySoundToTeam` (`team` 0, 1; -1 all).
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
                if (auto who = context.onlinePlayer(guid))
                    who.deliver(opcode, body_);
    }

    /// A packet to the players of `team`, but `except`.
    void toTeam(ubyte team, Opcode opcode, const(ubyte)[] body_, ulong except = 0)
    {
        foreach (guid, ref m; members)
            if (m.team == team && guid != except && m.offlineSince == MonoTime.init)
                if (auto who = context.onlinePlayer(guid))
                    who.deliver(opcode, body_);
    }

private:
    void sayCountdown(ubyte which)
    {
        said = cast(ubyte)(which + 1);
        message(countdownStrings[type][which], ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL);
    }

    void setStatus(BattlegroundStatus to)
    {
        status = to;
        context.services.call!(BattlegroundQueueHost.changed)(BattlegroundChanged(instance, to));
    }

    /// Its players back where they came from (`RemovePlayerAtLeave` with teleport), not deserters.
    void sendEveryoneOut()
    {
        import dmangos.world.character : Character;

        foreach (guid; members.keys)
        {
            if (auto c = cast(Character) context.onlinePlayer(guid))
                c.battlegroundLeave(true);
            removed(guid); // logged out, or not left by the above
        }
    }

    /// `BattleGroundMap::Update`: empty and with nobody invited, it closes.
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

/// The battleground copies this node runs (`BattleGroundMgr`'s copies).
final class Battlegrounds
{
    private
    {
        WorldContext context;
        Battleground[uint] copies;
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

    /// Copy `instance` of `type`, made if it is new (`CreateNewBattleGround`, when its first player comes).
    Battleground open(uint instance, BattlegroundType type)
    {
        import dmangos.log : info;

        if (auto known = instance in copies)
            return *known;
        info!"battleground: copy %s of %s made"(instance, type);
        return copies[instance] = new Battleground(context, instance, type);
    }

    /// Each copy's tick.
    void tick(Duration elapsed)
    {
        foreach (copy; copies.values)
            copy.tick(elapsed);
    }

    /// The copy closed: the queue told, its map gone.
    void closed(Battleground copy)
    {
        import dmangos.log : info;

        if (copies.get(copy.instance, null) !is copy)
            return;
        copies.remove(copy.instance);
        context.services.call!(BattlegroundQueueHost.changed)(BattlegroundChanged(copy.instance, BattlegroundStatus.none));
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
    import dmangos.world.database : BattlegroundData;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.updatefields;

    /// `BGData`: the copy the player is in, and where it came from.
    package BattlegroundData battleground_;

    /// `Player::_LoadBGData`, at login or arrival.
    package void loadBattleground()
    {
        battleground_ = context.database.loadBattlegroundData(player.data.guid);
    }

    /// `Player::_SaveBGData`, with the character.
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

    /// `Player::CanJoinToBattleground`: no Deserter.
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

    /// `BattleGroundMgr::SendBattleGroundList`: the battlemaster's list of copies (by the queue, which knows them).
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

    /// `Creature::CanInteractWithBattleMaster`: whether the player is of the levels it takes (told if not).
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
     * `Player::LeaveBattleground`: out of the copy, back where it came from if `teleport`; Deserter if
     * the battle was on (or about to be), but for game masters.
     */
    package void leaveBattleground(bool teleport)
    {
        import dmangos.auth.accounts : AccountLevel;
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        if (battleground_.instance == 0)
            return;
        bool deserted;
        if (auto copy = context.battlegrounds.find(battleground_.instance))
        {
            deserted = copy.deserting && account.level < AccountLevel.gameMaster && context.config.battlegroundCastDeserter;
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

    /// `Player::TeleportToBGEntryPoint`: where it was when it went in (else its home).
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

        const t = e.type in context.data.battlegroundTemplates;
        if (t is null)
            return;
        const start = t.startLocations[e.team] in context.data.safeLocations;
        if (start is null)
            return warning!"battleground %s: no start location %s"(e.type, t.startLocations[e.team]);
        // Already in another copy: out of it first (`RemovePlayerAtLeave` without teleport, no deserter).
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
            resurrect(1.0f);
        info!"%s: '%s' goes into %s (copy %s)"(remoteAddress, player.data.name, cast(BattlegroundType) e.type,
            e.instance);
        teleportTo(start.map, Position(start.x, start.y, start.z, start.orientation), null, e.instance);
    }

    /// The player arrived on a battleground map (`BattleGround::AddPlayer` from the world port's end).
    package void battlegroundArrived()
    {
        if (battlegroundOfMap(player.data.map) == BattlegroundType.none || battleground_.instance != instanceId_)
            return;
        if (auto copy = context.battlegrounds.find(battleground_.instance))
            copy.arrived(player.guid, battleground_.team);
    }

    /**
     * Logged in (or arrived from another node) on a battleground's map (`Player::LoadFromDB`'s
     * battleground part): back into its copy if it still runs and keeps the player's place; else out,
     * back where it came from.
     */
    package void battlegroundOnLogin()
    {
        if (battlegroundOfMap(player.data.map) == BattlegroundType.none || !context.hostsDungeon(player.data.map))
            return;
        auto copy = currentBattleground();
        if (copy !is null && player.guid in copy.members && copy.status != BattlegroundStatus.waitLeave)
            return copy.arrived(player.guid, battleground_.team);
        info!"%s: '%s' is on a battleground's map, out of its copy: sent back"(remoteAddress, player.data.name);
        const back = battleground_;
        if (copy !is null)
            copy.removed(player.guid);
        battleground_ = BattlegroundData.init;
        saveBattleground();
        returnFromBattleground(back);
    }

    /// Logging out: the queues left, a copy it is in keeps it a while (`WorldSession::LogoutPlayer`).
    package void battlegroundLoggedOut()
    {
        context.services.call!(BattlegroundQueueHost.logout)(BattlegroundPlayer(player.guid, context.nodeId));
        if (auto copy = currentBattleground())
            copy.loggedOut(player.guid);
    }

private:
    /// `HandleBattlemasterHelloOpcode`
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

    /// `HandleBattlefieldListOpcode`: the list, from the battleground's map (the player's own guid as the battlemaster's).
    @Handles(Opcode.CMSG_BATTLEFIELD_LIST, WorldState.inWorld)
    void handleBattlefieldList(ref ByteReader reader)
    {
        const type = battlegroundOfMap(reader.read!uint);
        if (type != BattlegroundType.none)
            sendBattlegroundList(player.guid, type);
    }

    /// `HandleBattlemasterJoinOpcode`: queueing, alone (a group's joining comes with the groups' battlegrounds).
    @Handles(Opcode.CMSG_BATTLEMASTER_JOIN, WorldState.inWorld)
    void handleBattlemasterJoin(ref ByteReader reader)
    {
        const guid = reader.read!ulong, mapId = reader.read!uint, desired = reader.read!uint;
        const type = battlegroundOfMap(mapId);
        if (type == BattlegroundType.none || type !in context.data.battlegroundTemplates)
            return;
        if (battleground_.instance && battlegroundOfMap(player.data.map) != BattlegroundType.none)
            return; // `InBattleGround()`
        if (interactableNpc(guid, NpcFlag.battlemaster) is null)
            return;
        if (!mayJoinBattleground())
            return sendGroupJoinedBattleground(joinedDeserter);
        context.services.call!(BattlegroundQueueHost.join)(BattlegroundJoin(player.guid, context.nodeId,
            battlegroundTeam(), cast(ubyte) player.data.level, type, desired));
    }

    /// `HandleBattleFieldPortOpcode`: accepting an invitation (`action` 1), or leaving a queue.
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

    /// `HandleBattlefieldStatusOpcode`: every queue slot's state again.
    @Handles(Opcode.CMSG_BATTLEFIELD_STATUS, WorldState.inWorld)
    void handleBattlefieldStatus()
    {
        context.services.call!(BattlegroundQueueHost.status)(BattlegroundPlayer(player.guid, context.nodeId));
    }

    /// `HandleLeaveBattlefieldOpcode`: not in combat, unless the battle is over.
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

    /// `HandlePVPLogDataOpcode`: the scoreboard.
    @Handles(Opcode.MSG_PVP_LOG_DATA, WorldState.inWorld)
    void handlePvPLogData()
    {
        if (auto copy = currentBattleground())
            deliver(Opcode.MSG_PVP_LOG_DATA, copy.scoreboard());
    }

    /// `HandleBattleGroundPlayerPositionsOpcode`: nobody to show yet (Warsong Gulch's flag carriers come with it).
    @Handles(Opcode.MSG_BATTLEGROUND_PLAYER_POSITIONS, WorldState.inWorld)
    void handleBattlegroundPlayerPositions()
    {
        if (currentBattleground() is null)
            return;
        ByteWriter w;
        w.put(uint(0));
        w.put(ubyte(0));
        deliver(Opcode.MSG_BATTLEGROUND_PLAYER_POSITIONS, w.data);
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
