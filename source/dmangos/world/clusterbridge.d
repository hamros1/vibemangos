/**
 * The world server's side of replication (docs/CLUSTER.md): replicas of this node's
 * objects go out through the cluster's links, replication messages from other nodes go to the map
 * they are about, and every tick each map's interest changes go to every linked node.
 */
module dmangos.world.clusterbridge;

import dmangos.cluster.protocol : AreaDamage, CreatureSwing, GameObjectSpell, GroupLootRoll, LootCoinShare, PartyHeal, PeriodicResult,
    PartyAreaAura, PartyQuest, PartySummon, QuestLootCheck, ScriptCreatureStep, ScriptGameObject, TotemWeaponEnchant;

import core.time : Duration, MonoTime, msecs;

import dmangos.cluster.node : ClusterNode, PlayerHandler, ReplicationHandler;
import dmangos.cluster.protocol : DeliverTo, InRange, InterestUpdate, PlayerMessage, PlayerMessageKind, Presence,
    PresenceEntry, ChannelCommand, GmRemote, KillShare, ScriptSignal, DungeonEntryRequest, DungeonEntryReply, FriendStatusChange, GuildBroadcast, GuildInvitation, GuildReload, MessageType, GroupCommand, RegionLoad, ToEveryone, GroupState, MemberStatsRequest, ReplicaCreate, ReplicaMove, ReplicaRemove, ReplicaValues, StockRelease, StockReply, StockRequest,
    WhisperMessage;
import dmangos.world.creature : Creature;
import dmangos.world.group : Group, Groups;
import dmangos.world.whisper : deliverWhisper, WhisperFrom;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.log;
import dmangos.world.context : PlayerRelay, WorldContext;
import dmangos.world.replication : Replicator;
import dmangos.world.character : Character;
import dmangos.world.session : WorldSession, WorldState;

/// See the module documentation. Also relays players simulated away from their client.
final class ClusterBridge : Replicator, ReplicationHandler, PlayerRelay, PlayerHandler
{
    import dmangos.world.gatewaysessions : GatewaySessions;
    mixin GatewaySessions;

    private ClusterNode node;
    private WorldContext context;
    private WorldSession[uint] remote;         // owner: sessions whose client is on another node, by account
    private MonoTime[WorldSession] releaseAt;  // home: sessions whose owner was lost, released after its lease
    private uint leaseMs;
    private PresenceEntry[ulong] presenceSent;  // what peers were last told of this node's players
    private void delegate(bool, uint)[uint] stockWaiting; // stock requests sent, by number
    private uint nextStockRequest = 1;
    private MonoTime nextPresence;

    /// `leaseMs`: the cluster's lease, which a lost owner certainly stopped within.
    this(ClusterNode node, WorldContext context, uint leaseMs)
    {
        this(node, context);
        this.leaseMs = leaseMs;
    }

    ///
    this(ClusterNode node, WorldContext context)
    {
        this.node = node;
        this.context = context;
        context.gatewayReachable = (ushort home) => linkedOwner(home).node != 0;
    }

    /// Sends what each map's players became near and left since the last tick, and once a second what changed of them.
    void tick()
    {
        const now = context.clock();
        gatewayTick(now);
        if (now >= nextPresence)
        {
            nextPresence = now + 1000.msecs;
            sendPresence();
        }
        if (releaseAt.length)
        {
            WorldSession[] due;
            foreach (session, at; releaseAt)
                if (now >= at)
                    due ~= session;
            foreach (session; due)
            {
                releaseAt.remove(session);
                session.ownerLeft(false);
            }
        }
        foreach (map; context.allMaps)
        {
            ulong[] added, removed;
            map.takeInterest(added, removed);
            if (added.length || removed.length)
                node.broadcast(InterestUpdate(map.id, added, removed));
        }
    }

    /// Run before processing world ticks so an expired worker cannot keep a gateway's simulation alive.
    void fenceGatewaySimulations()
    {
        if (context.canWrite())
            return;
        WorldSession[] expired;
        foreach (session; remote)
            if (session.gatewayHome.node)
                expired ~= session;
        foreach (session; expired)
            session.clientGone();
    }

    // Replicator: this node's objects, to the nodes that want them.

    void create(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state)
    {
        node.sendTo(peer, ReplicaCreate(map, cell, guid, cast(ubyte[]) state));
    }

    void values(ushort peer, uint map, ulong guid, const(ubyte)[] slots)
    {
        node.sendTo(peer, ReplicaValues(map, guid, cast(ubyte[]) slots));
    }

    void move(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion)
    {
        node.sendTo(peer, ReplicaMove(map, guid, opcode, cast(ubyte[]) body_, cast(ubyte[]) motion));
    }

    void remove(ushort peer, uint map, ulong guid)
    {
        node.sendTo(peer, ReplicaRemove(map, guid));
    }

    // ReplicationHandler: other nodes' messages, to the maps.

    void peerLinked(ushort peer)
    {
        node.sendTo(peer, Presence(true, presenceSent.values, null));
        if (node.isCoordinator)
            foreach (ref state; context.groups.states())
                node.sendTo(peer, state);
        foreach (map; context.allMaps)
        {
            auto cells = map.interestCells;
            if (cells.length)
                node.sendTo(peer, InterestUpdate(map.id, cells, null));
        }
    }

    void peerLost(ushort peer)
    {
        context.services.peerLost(peer); // calls sent there wait for their service to be elsewhere
        context.presenceLost(peer);
        foreach (map; context.allMaps)
            map.peerGone(peer);
        // Players it held the clients of: they leave the world here, saved (it cannot say they did).
        WorldSession[] orphans;
        foreach (account, session; remote)
            if (session.home == peer && !session.gatewayHome.node)
                orphans ~= session;
        foreach (session; orphans)
            session.clientGone();
        // Players it simulated: their clients are told to go; the accounts are free once its lease is surely over.
        foreach (k; context.allSessions)
            if (auto session = cast(WorldSession) k)
                if (session.state == WorldState.elsewhere && session.owner == peer)
                {
                    if (accountGatewayPaused(session))
                        continue;
                    session.kick("the server simulating this character was lost");
                    releaseAt[session] = context.clock() + (leaseMs + 500).msecs;
                }
    }

    private bool accountGatewayPaused(WorldSession session)
    {
        if (auto route = gatewayRoutes.get(session.account.id, null))
            if (route.client is session)
            {
                session.gatewayPaused = true;
                return true;
            }
        return false;
    }

    void inRange(ushort peer, uint map, float x, float y, float z, float range, ushort opcode, const(ubyte)[] body_)
    {
        if (auto m = context.existingMap(map))
            m.deliverInRange(Position(x, y, z, 0), range, cast(Opcode) opcode, body_);
    }

    void presence(ushort peer, bool full, const(PresenceEntry)[] entries, const(ulong)[] gone)
    {
        context.presence(peer, full, entries, gone);
    }

    void deliverTo(ushort peer, ulong guid, ushort opcode, const(ubyte)[] body_)
    {
        if (auto who = context.onlinePlayer(guid))
            who.deliver(cast(Opcode) opcode, body_);
    }

    /// Replicator: a range packet for a peer's players.
    void inRange(ushort peer, uint map, Position center, float range, ushort opcode, const(ubyte)[] body_)
    {
        node.sendTo(peer, InRange(map, center.x, center.y, center.z, range, opcode, cast(ubyte[]) body_));
    }

    /// For the context: reserves limited stock on the node simulating a vendor.
    void reserveStock(ushort owner, uint map, ulong creature, uint item, uint maxCount, uint incrTime, uint buyCount,
        uint wanted, void delegate(bool, uint) then)
    {
        const request = nextStockRequest++;
        if (!node.sendTo(owner, StockRequest(request, map, creature, item, maxCount, incrTime, buyCount, wanted)))
            return then(false, 0);
        stockWaiting[request] = then;
    }

    /// For the context: gives reserved stock back.
    void releaseStock(ushort owner, uint map, ulong creature, uint item, uint maxCount, uint count)
    {
        node.sendTo(owner, StockRelease(map, creature, item, maxCount, count));
    }

    /// Another node's player buys from a creature this node simulates: its stock, counted here.
    void stockRequest(ushort peer, const ref StockRequest m)
    {
        auto vendor = vendorHere(m.map, m.creature);
        bool reserved;
        uint left;
        if (vendor !is null)
        {
            const now = context.unixTime;
            if (vendor.vendorItemCount(m.item, m.maxCount, m.incrTime, m.buyCount, now) >= m.wanted)
            {
                left = vendor.takeVendorItems(m.item, m.maxCount, m.incrTime, m.buyCount, m.wanted, now);
                reserved = true;
            }
        }
        node.sendTo(peer, StockReply(m.request, reserved, left));
    }

    void stockReply(ushort peer, const ref StockReply m)
    {
        if (auto then = m.request in stockWaiting)
        {
            auto callback = *then;
            stockWaiting.remove(m.request);
            callback(m.reserved, m.left);
        }
    }

    void stockRelease(ushort peer, const ref StockRelease m)
    {
        if (auto vendor = vendorHere(m.map, m.creature))
            vendor.giveBackVendorItems(m.item, m.maxCount, m.count);
    }

    /// A creature this node simulates (not a replica), or null.
    private Creature vendorHere(uint map, ulong guid)
    {
        if (auto m = context.existingMap(map))
            return cast(Creature) m.findObject(guid);
        return null;
    }

    /// For the context: a packet for a player another node simulates.
    void deliverRemote(ushort target, ulong guid, ushort opcode, const(ubyte)[] body_)
    {
        node.sendTo(target, DeliverTo(guid, opcode, cast(ubyte[]) body_));
    }

    /// For the context (not on the coordinator): a group command, for the coordinator's groups.
    void forwardGroup(const ref GroupCommand command)
    {
        node.sendToCoordinator(command);
    }

    /// On the coordinator: another node's player's group command.
    void groupCommand(ushort peer, const ref GroupCommand m)
    {
        context.groupService.run(m, peer);
    }

    /// Not on the coordinator: a group changed there; the mirror here follows.
    void groupState(ushort peer, const ref GroupState m)
    {
        context.groups.mirror(m);
    }

    /// For the context: asks a member's node for its full stats.
    void requestMemberStats(ushort target, ulong requester, ulong member)
    {
        node.sendTo(target, MemberStatsRequest(requester, member));
    }

    /// A member's full stats, for a player on `peer`.
    void memberStatsRequest(ushort peer, const ref MemberStatsRequest m)
    {
        import dmangos.world.group : memberStatus, partyMemberStatsFull;

        auto member = context.onlinePlayer(m.member);
        const body_ = partyMemberStatsFull(m.member, member is null ? null : member.character, memberStatus(member));
        node.sendTo(peer, DeliverTo(m.requester, cast(ushort) Opcode.SMSG_PARTY_MEMBER_STATS_FULL, body_.dup));
    }

    /// How much a cell's contents weigh in the loop: an object in the tick, a resting one, a player.
    enum uint weightTicking = 10, weightResting = 1, weightPlayer = 100;

    /**
     * Phase 6: this node's loop time over `elapsed` (`busy` of it), divided among the regions it owns
     * by what each holds (`Map.weighCells`), as µs a second.
     */
    RegionLoad[] regionLoads(Duration busy, Duration elapsed)
    {
        const owned = node.regions.ownedRegions;
        if (owned.length == 0 || elapsed <= Duration.zero)
            return null;
        ulong[uint] weight;
        ulong total;
        foreach (m; context.allMaps)
            m.weighCells(weightTicking, weightResting, weightPlayer, (ulong cell, ulong w) {
                const x = cast(int)(cell >> 32), y = cast(int) cast(uint) cell;
                foreach (ref r; owned)
                    if (r.map == m.id && r.rect.contains(x, y))
                    {
                        weight[r.id] = weight.get(r.id, 0) + w;
                        total += w;
                        break;
                    }
            });
        const perSecond = busy.total!"usecs" * 1_000_000 / elapsed.total!"usecs";
        RegionLoad[] loads;
        foreach (ref r; owned)
            loads ~= RegionLoad(r.id, total ? cast(uint)(perSecond * weight.get(r.id, 0) / total) : 0);
        return loads;
    }

    /// Players simulated here for clients on other nodes.
    @property size_t visitors() const
    {
        return remote.length;
    }

    /// For the context: a packet for every other node's players.
    void toEveryoneElsewhere(ushort opcode, char permission, const(ubyte)[] body_)
    {
        node.broadcast(ToEveryone(opcode, cast(ubyte) permission, body_.dup));
    }

    /// Another node's world text, for the players here.
    void toEveryone(ushort peer, const ref ToEveryone m)
    {
        context.deliverToOwn(cast(Opcode) m.opcode, m.body_, cast(char) m.permission);
    }

    /// For the context: a group member's share of a kill here, for the node that simulates it.
    void sendKillShare(ushort target, const ref KillShare share)
    {
        node.sendTo(target, share);
    }

    /// A share of another node's kill, for a player here.
    void killShare(ushort peer, const ref KillShare m)
    {
        context.killShareArrived(m);
    }

    bool sendGroupLootRoll(ushort peer, const ref GroupLootRoll message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void groupLootRoll(ushort peer, const ref GroupLootRoll message)
    {
        context.groupLootRollArrived(peer, message);
    }

    bool canSendLootCoins(ushort peer)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose;
    }

    bool sendLootCoinShare(ushort peer, const ref LootCoinShare message)
    {
        return canSendLootCoins(peer) && node.sendTo(peer, message);
    }

    void lootCoinShare(ushort peer, const ref LootCoinShare message)
    {
        context.lootCoinShareArrived(peer, message);
    }

    bool sendPartyQuest(ushort peer, const ref PartyQuest message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void partyQuest(ushort peer, const ref PartyQuest message)
    {
        if (context.canWrite())
            context.receivePartyQuest(message);
    }

    bool sendQuestLootCheck(ushort peer, const ref QuestLootCheck message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void questLootCheck(ushort peer, const ref QuestLootCheck message)
    {
        context.questLootCheckArrived(peer, message);
    }

    bool sendPartyHeal(ushort peer, const ref PartyHeal message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void partyHeal(ushort peer, const ref PartyHeal message)
    {
        context.partyHealArrived(peer, message);
    }

    bool sendAreaDamage(ushort peer, const ref AreaDamage message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void areaDamage(ushort peer, const ref AreaDamage message)
    {
        context.areaDamageArrived(peer, message);
    }

    bool sendGameObjectSpell(ushort peer, const ref GameObjectSpell message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void gameObjectSpell(ushort peer, const ref GameObjectSpell message)
    {
        context.gameObjectSpellArrived(peer, message);
    }

    bool sendScriptGameObject(ushort peer, const ref ScriptGameObject message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void scriptGameObject(ushort peer, const ref ScriptGameObject message)
    {
        context.scriptGameObjectArrived(peer, message);
    }

    bool sendPartySummon(ushort peer, const ref PartySummon message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void partySummon(ushort peer, const ref PartySummon message)
    {
        context.routePartySummon(message, peer);
    }

    bool sendScriptCreatureStep(ushort peer, const ref ScriptCreatureStep message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void scriptCreatureStep(ushort peer, const ref ScriptCreatureStep message)
    {
        context.scriptCreatureStepArrived(peer, message);
    }

    bool sendTotemWeaponEnchant(ushort peer, const ref TotemWeaponEnchant message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void totemWeaponEnchant(ushort peer, const ref TotemWeaponEnchant message)
    {
        context.totemWeaponEnchantArrived(peer, message);
    }

    import dmangos.cluster.protocol : MindVisionTarget;

    bool sendMindVisionTarget(ushort peer, const ref MindVisionTarget message)
    {
        return node.sendTo(peer, message);
    }

    void mindVisionTarget(ushort peer, const ref MindVisionTarget message)
    {
        context.mindVisionTargetArrived(peer, message);
    }

    bool sendPartyAreaAura(ushort peer, const ref PartyAreaAura message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void partyAreaAura(ushort peer, const ref PartyAreaAura message)
    {
        context.partyAreaAuraArrived(peer, message);
    }

    bool sendCreatureSwing(ushort peer, const ref CreatureSwing message)
    {
        auto link = node.linkTo(peer);
        return link !is null && !link.wantsClose && node.sendTo(peer, message);
    }

    void creatureSwing(ushort peer, const ref CreatureSwing message)
    {
        context.creatureSwingArrived(peer, message);
    }

    void sendPeriodicResult(ushort peer, const ref PeriodicResult message)
    {
        node.sendTo(peer, message);
    }

    void periodicResult(ushort peer, const ref PeriodicResult message)
    {
        context.periodicResultArrived(peer, message);
    }

    /// For the context: guild news for every other node.
    void sendGuildReload(uint guild)
    {
        foreach (peer; context.otherNodes())
            node.sendTo(peer, GuildReload(guild));
    }

    /// ditto
    void sendGuildBroadcast(uint guild, uint right, ushort opcode, const(ubyte)[] body_)
    {
        foreach (peer; context.otherNodes())
            node.sendTo(peer, GuildBroadcast(guild, right, opcode, body_.dup));
    }

    /// For the context: an invitation for a player node `target` simulates.
    void sendGuildInvitation(ushort target, ulong player, uint guild, ulong inviter, string inviterName, string guildName)
    {
        node.sendTo(target, GuildInvitation(player, guild, inviter, inviterName, guildName));
    }

    /// See `ReplicationHandler.guildNews`.
    void guildNews(ushort peer, MessageType type, const(ubyte)[] payload)
    {
        import dmangos.cluster.protocol : decode;

        switch (type)
        {
        case MessageType.guildReload:
            context.guildReloaded(decode!GuildReload(payload).guild);
            break;
        case MessageType.guildBroadcast:
        {
            const m = decode!GuildBroadcast(payload);
            context.guildToMembersHere(m.guild, cast(Opcode) m.opcode, m.body_, m.right);
            break;
        }
        case MessageType.guildInvitation:
        {
            const m = decode!GuildInvitation(payload);
            context.guildInvitationArrived(m.target, m.guild, m.inviter, m.inviterName, m.guildName);
            break;
        }
        default:
            break;
        }
    }

    /// For the context: a player here logged in or out; every other node hears of it, for its friends.
    void announceFriend(ulong guid, bool online, ubyte status, uint area, uint level, uint classId)
    {
        foreach (peer; context.otherNodes())
            node.sendTo(peer, FriendStatusChange(guid, online, status, area, level, classId));
    }

    /// See `ReplicationHandler.friendStatus`.
    void friendStatus(ushort peer, const ref FriendStatusChange m)
    {
        import dmangos.world.social : FriendInfo, FriendStatus;

        const info = FriendInfo(cast(FriendStatus) m.status, m.area, m.level, m.classId);
        foreach (other; context.onlinePlayers)
            if (auto session = cast(Character) other)
                if (session.character !is null)
                    session.friendNews(m.guid, m.online, info);
    }

    private uint nextEntryRequest = 1;
    private void delegate(ubyte)[uint] entryWaiting;

    /// For the context: asks the node hosting dungeon `map` whether `player` may go in.
    void askDungeonEntry(ushort host, ulong player, uint map, uint instance, bool gameMaster,
        void delegate(ubyte abort) then)
    {
        const request = nextEntryRequest++;
        if (!node.sendTo(host, DungeonEntryRequest(request, player, map, instance, gameMaster)))
            return then(0x02);
        entryWaiting[request] = then;
    }

    /// See `ReplicationHandler.dungeonEntryRequest`.
    void dungeonEntryRequest(ushort peer, const ref DungeonEntryRequest m)
    {
        node.sendTo(peer, DungeonEntryReply(m.request, context.dungeonEntryProblem(m.player, m.map, m.instance,
            m.gameMaster)));
    }

    /// See `ReplicationHandler.dungeonEntryReply`.
    void dungeonEntryReply(ushort peer, const ref DungeonEntryReply m)
    {
        if (auto then = m.request in entryWaiting)
        {
            auto callback = *then;
            entryWaiting.remove(m.request);
            callback(m.abort);
        }
    }

    /// For the context: a script's signal for a creature another node simulates.
    void sendScriptSignal(ushort target, const ref ScriptSignal signal)
    {
        node.sendTo(target, signal);
    }

    /// See `ReplicationHandler.scriptSignal`.
    void scriptSignal(ushort peer, const ref ScriptSignal m)
    {
        context.scriptSignalArrived(m);
    }

    /// For the context: a GM command for a player another node simulates.
    void sendGmRemote(ushort target, const ref GmRemote command)
    {
        node.sendTo(target, command);
    }

    /// A GM command of another node's GM, for a player here (or, `appearAt`, for that GM, here).
    void gmRemote(ushort peer, const ref GmRemote m)
    {
        import dmangos.world.gmtargets : GmSink;
        import dmangos.world.opcodes : ChatType, Language;
        import dmangos.world.queries : chatMessage;

        auto sink = GmSink((string text) {
            node.sendTo(peer, DeliverTo(m.gm, cast(ushort) Opcode.SMSG_MESSAGECHAT,
                chatMessage(ChatType.CHAT_MSG_SYSTEM, Language.LANG_UNIVERSAL, 0, text)));
        });
        import dmangos.world.gmtargets : aboutInstances, everywhere, GmRemoteOp;

        if (aboutInstances(m.op))
        {
            import dmangos.world.gminstance : describeInstance, resetAllHere, resetInstanceHere, shutdownInstanceHere;

            final switch (m.op)
            {
            case GmRemoteOp.instanceInfo:
                return describeInstance(context, m.instance, sink);
            case GmRemoteOp.instanceShutdown:
                return shutdownInstanceHere(context, m.instance, sink);
            case GmRemoteOp.instanceReset:
            {
                string name = "?";
                if (auto here = context.onlinePlayer(m.target))
                    name = here.character.data.name;
                else if (auto remote = context.remotePlayer(m.target))
                    name = remote.entry.name;
                return resetInstanceHere(context, m.instance, m.target, name, m.gmCanKickGms, sink);
            }
            case GmRemoteOp.instanceResetAll:
                return resetAllHere(context, m.target);
            case GmRemoteOp.kick, GmRemoteOp.summon, GmRemoteOp.appear, GmRemoteOp.appearAt, GmRemoteOp.disconnect,
                GmRemoteOp.banKick, GmRemoteOp.rename, GmRemoteOp.playerInfo, GmRemoteOp.kill, GmRemoteOp.revive,
                GmRemoteOp.saveAll, GmRemoteOp.massSummon:
                return;
            }
        }

        if (everywhere(m.op))
        {
            // For every player here.
            foreach (other; context.onlinePlayers)
                if (auto here = cast(Character) other)
                    if (here.character !is null)
                        here.gmTargeted(m, sink, (GmRemote back) {});
            return;
        }
        auto session = cast(Character) context.onlinePlayer(m.target);
        if (session is null || session.character is null)
            return sink.red("Player is not online at the moment.");
        session.gmTargeted(m, sink, (GmRemote back) { node.sendTo(peer, back); });
    }

    /// Every group, for every other node's mirror (a coordinator that has just taken over).
    void broadcastGroups()
    {
        foreach (ref state; context.groups.states())
            node.broadcast(state);
    }

    /// On the coordinator: groups for the other nodes' mirrors.
    void groupChanged(const Group group)
    {
        node.broadcast(Groups.stateOf(group));
    }

    /// ditto
    void groupRemoved(uint id)
    {
        GroupState gone;
        gone.id = id;
        gone.removed = true;
        node.broadcast(gone);
    }

    /// For the context: a whisper for a player another node simulates.
    void whisperRemote(ushort target, ulong guid, WhisperFrom from, string text)
    {
        node.sendTo(target, WhisperMessage(guid, from.guid, from.race, from.permissions, from.chatTag, text));
    }

    /// A whisper from another node for a player this one simulates: checked and delivered here, answered there.
    void whisper(ushort peer, const ref WhisperMessage m)
    {
        auto target = context.onlinePlayer(m.to);
        if (target is null)
            return; // it left meanwhile
        auto session = cast(Character) target;
        deliverWhisper(target, WhisperFrom(m.from, m.fromRace, m.fromPermissions, m.fromChatTag), m.text,
            context.config.allowTwoSideInteractionChat,
            (ulong sender) => session !is null && session.allowsWhispersFrom(sender),
            (ubyte race) => cast(uint) context.client.teamForRace(race),
            (Opcode op, const(ubyte)[] b) { node.sendTo(peer, DeliverTo(m.from, cast(ushort) op, cast(ubyte[]) b)); });
    }

    /// What changed of this node's players since the last time, to every peer.
    private void sendPresence()
    {
        import dmangos.world.context : PresenceFlags;
        import dmangos.world.player : PlayerFlags;

        PresenceEntry[] changed;
        bool[ulong] here;
        foreach (who; context.onlinePlayers)
        {
            const p = who.character;
            uint flags;
            if (p.gmTagOn)
                flags |= PresenceFlags.gmTag;
            if (p.hasFlag(PlayerFlags.afk))
                flags |= PresenceFlags.afk;
            if (p.hasFlag(PlayerFlags.dnd))
                flags |= PresenceFlags.dnd;
            if (who.hasPermissions)
                flags |= PresenceFlags.permissions;
            const entry = PresenceEntry(p.guid, p.data.name, p.data.account, p.data.race, p.data.classId,
                cast(ubyte) p.data.level, p.data.gender, p.data.zone, flags, cast(ubyte) who.security, p.autoReply,
                who.hasPermissions ? (cast(Character) who).permissions : null);
            here[p.guid] = true;
            if (auto sent = p.guid in presenceSent)
                if (*sent == entry)
                    continue;
            presenceSent[p.guid] = entry;
            changed ~= entry;
        }
        ulong[] gone;
        foreach (guid, _; presenceSent)
            if (guid !in here)
                gone ~= guid;
        foreach (guid; gone)
            presenceSent.remove(guid);
        if (changed.length || gone.length)
            node.broadcast(Presence(false, changed, gone));
    }

    // PlayerRelay: this node's half of players simulated away from their clients.

    void toHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_)
    {
        const message = PlayerMessage(PlayerMessageKind.toHome, account, opcode, cast(ubyte[]) body_);
        if (auto session = remote.get(account, null))
            if (session.gatewayHome.node)
            {
                if (context.canWrite())
                    node.sendToGateway(session.gatewayHome, message);
                return;
            }
        node.sendTo(home, message);
    }

    void toOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_)
    {
        node.sendTo(owner, PlayerMessage(PlayerMessageKind.toOwner, account, opcode, cast(ubyte[]) body_));
    }

    void disconnect(ushort owner, uint account)
    {
        if (auto route = gatewayRoutes.get(account, null))
        {
            route.closing = true;
            if (!route.pending.token)
                sendGatewayDisconnect(route, account);
            return;
        }
        node.sendTo(owner, PlayerMessage(PlayerMessageKind.disconnect, account, 0, null));
    }

    void migrate(ushort target, uint account, const(ubyte)[] state)
    {
        if (context.config.cluster.gateway)
            return startGatewayMove(account, target, state, node.id);
        if (auto session = remote.get(account, null))
            if (session.gatewayHome.node)
            {
                node.sendTo(session.home, PlayerMessage(PlayerMessageKind.gatewayMove, account, target,
                    cast(ubyte[]) state));
                return;
            }
        node.sendTo(target, PlayerMessage(PlayerMessageKind.migrate, account, 0, cast(ubyte[]) state));
        if (account in remote)
            movedOn[account] = MovedOn(target, MonoTime.currTime); // the client's packets still on their way
    }

    void moved(ushort home, uint account, ushort next)
    {
        if (auto session = remote.get(account, null))
            if (session.gatewayHome.node)
                return; // the saved handoff goes through the gateway
        node.sendTo(home, PlayerMessage(PlayerMessageKind.moved, account, next, null));
    }

    /// Where a player simulated here moved on to, for the client's packets sent before its home knew.
    private static struct MovedOn
    {
        ushort node;
        MonoTime at;
    }
    private MovedOn[uint] movedOn;

    /// The node a player simulated here until moments ago moved on to; 0 if none (or long ago).
    private ushort movedOnTo(uint account)
    {
        import core.time : seconds;

        if (auto m = account in movedOn)
        {
            if (MonoTime.currTime - m.at < 5.seconds)
                return m.node;
            movedOn.remove(account);
        }
        return 0;
    }

    void left(ushort home, uint account, bool toCharacterScreen)
    {
        const message = PlayerMessage(PlayerMessageKind.left, account, toCharacterScreen ? 1 : 0, null);
        if (auto session = remote.get(account, null))
            if (session.gatewayHome.node)
            {
                if (!context.canWrite() || !context.settleWrites())
                    return;
                node.simulationStopped(account, session.gatewayCharacter, session.gatewayToken);
                return node.sendToGateway(session.gatewayHome, message);
            }
        node.sendTo(home, message);
    }

    void remoteDone(uint account)
    {
        remote.remove(account);
    }

    // PlayerHandler: the other halves' messages.

    void player(ushort peer, PlayerMessageKind kind, uint account, ushort opcode, const(ubyte)[] data)
    {
        final switch (kind)
        {
        case PlayerMessageKind.migrate:
            // Back home, or arriving at a node that will simulate it for its home.
            if (auto home = cast(WorldSession) context.sessionOf(account))
                if (home.state == WorldState.elsewhere)
                {
                    if (!home.arrive(data))
                        home.kick("the character could not be loaded after moving between servers");
                    return;
                }
            // Its client's node: the sender's, or (from one third node to another) the one the state names.
            const homeNode = Character.migrationHome(data);
            const clientAt = homeNode ? homeNode : peer;
            movedOn.remove(account);
            auto session = new WorldSession(context, Character.migrationAccount(data), clientAt);
            remote[account] = session;
            if (!session.arrive(data))
            {
                warning!"cluster: a player of account %s from node %s could not be loaded"(account, peer);
                remote.remove(account);
                left(clientAt, account, false);
            }
            return;
        case PlayerMessageKind.toOwner:
            if (auto session = account in remote)
            {
                if (!session.gatewayHome.node || session.gatewayHome == linkedOwner(peer, true))
                    session.fromHome(opcode, data);
            }
            else if (const next = movedOnTo(account))
                toOwner(next, account, opcode, data); // sent before its home heard it moved on
            return;
        case PlayerMessageKind.toHome:
            if (auto route = gatewayRoutes.get(account, null))
            {
                if (route.owner == linkedOwner(peer, true) && node.simulationOwner(peer) == route.owner
                    && !route.pending.token)
                    route.client.fromOwner(opcode, data);
                return;
            }
            if (auto session = cast(WorldSession) context.sessionOf(account))
            {
                if (session.state == WorldState.elsewhere && session.owner != peer)
                    session.ownerMoved(peer); // its new owner spoke before its old one's word came
                session.fromOwner(opcode, data);
            }
            return;
        case PlayerMessageKind.left:
            if (auto route = gatewayRoutes.get(account, null))
            {
                if (route.owner == linkedOwner(peer, true) && !route.pending.token)
                    finishGatewayRoute(account, opcode == 1);
                return;
            }
            if (auto session = cast(WorldSession) context.sessionOf(account))
                if (session.state == WorldState.elsewhere || session.owner == peer)
                    session.ownerLeft(opcode == 1);
            return;
        case PlayerMessageKind.disconnect:
            if (auto session = account in remote)
            {
                if (!session.gatewayHome.node || session.gatewayHome == linkedOwner(peer, true))
                    session.clientGone();
            }
            else if (const next = movedOnTo(account))
                disconnect(next, account);
            return;
        case PlayerMessageKind.moved:
            if (account in gatewayRoutes)
                return;
            if (auto session = cast(WorldSession) context.sessionOf(account))
                if (session.owner == peer)
                    session.ownerMoved(opcode);
            return;
        case PlayerMessageKind.gatewayMove:
            if (context.config.cluster.gateway)
                startGatewayMove(account, opcode, data, peer);
            return;
        case PlayerMessageKind.gatewayArrival, PlayerMessageKind.gatewayRecover:
            return receiveGatewayPlayer(peer, kind, account, data);
        }
    }

    private void receiveGatewayPlayer(ushort peer, PlayerMessageKind kind, uint account, const(ubyte)[] data)
    {
        import dmangos.auth.accounts : AccountLevel;
        import dmangos.bytes : ByteReader;
        import dmangos.world.database : WorldAccount;

        const home = linkedOwner(peer);
        auto link = node.linkTo(peer);
        if (!home.node || link is null || !link.peer.gateway || account in remote)
            return;
        auto r = ByteReader(data);
        const token = r.read!ulong;
        if (!token)
            return;
        WorldSession session;
        if (kind == PlayerMessageKind.gatewayArrival)
        {
            const state = r.readBytes(r.remaining);
            const auth = Character.migrationAccount(state);
            const original = Character.migrationHome(state);
            if (auth.id != account || (original && original != peer))
                return;
            session = new WorldSession(context, auth, peer);
            session.gatewayHome = home;
            session.gatewayToken = token;
            session.gatewayCharacter = Character.migrationCharacter(state);
            remote[account] = session;
            if (session.arrive(state))
                return;
        }
        else
        {
            WorldAccount auth;
            auth.id = account;
            auth.username = r.readString(r.read!uint).idup;
            auth.level = cast(AccountLevel) r.read!ubyte;
            auth.muteTime = r.read!long;
            const clientBuild = r.read!uint, character = r.read!uint;
            if (!r.empty)
                return;
            session = new WorldSession(context, auth, peer);
            session.gatewayHome = home;
            session.gatewayToken = token;
            session.gatewayCharacter = character;
            remote[account] = session;
            if (session.beginGatewayRecovery(character, clientBuild))
                return;
        }
        left(peer, account, false);
        remote.remove(account);
    }

    void interest(ushort peer, uint map, const(ulong)[] added, const(ulong)[] removed)
    {
        context.map(map).peerInterest(peer, added, removed);
    }

    void replicaCreate(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state)
    {
        context.map(map).replicaCreated(owner: peer, cell: cell, guid: guid, state);
    }

    void replicaValues(ushort peer, uint map, ulong guid, const(ubyte)[] slots)
    {
        if (auto m = context.existingMap(map))
            m.replicaValues(peer, guid, slots);
    }

    void replicaMove(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion)
    {
        if (auto m = context.existingMap(map))
            m.replicaMoved(peer, guid, opcode, body_, motion);
    }

    void replicaRemove(ushort peer, uint map, ulong guid)
    {
        if (auto m = context.existingMap(map))
            m.replicaRemoved(peer, guid);
    }
}
