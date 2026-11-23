/**
 * Groups as a cluster service (docs/CLUSTER.md): the rules for what changes a group:
 * invitations, leaving, kicks, leadership, loot settings, raids and subgroups.
 *
 * A group's members may be simulated by any node, so its changes happen in one place: the
 * coordinator's `Groups` (standalone, the one server's), which saves them and tells the members
 * wherever they are. A player's group command is a `GroupCommand` carrying what the rules need of
 * it; another node sends it to the coordinator, which runs it as for its own players and sends the
 * changed group to every node's mirror (`Groups.mirror`). What only reads a group (party chat,
 * member stats, ready checks, rolls) stays on the player's node, with its mirror.
 */
module dmangos.world.groupservice;

public import dmangos.cluster.protocol : GroupOp; // a cluster message's field

import dmangos.cluster.protocol : GroupCommand;
import dmangos.cluster.services : Call, Service, ServiceKind;
import dmangos.world.context : WorldContext;
import dmangos.world.group;
import dmangos.world.map : packetBody;
import dmangos.world.meetingstone;
import core.time : Duration, MonoTime, msecs;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets;

struct LootTurnRequest
{
    uint group;
    ulong recipient;
    ulong[] eligible;
    ushort node;
    ulong token;
    long issuedAt;
}

struct LootTurnReply
{
    ulong looter;
}

/// The cursor belongs to the coordinator's real group, wherever the drop was made.
@Service(ServiceKind.lootTurns)
struct LootTurnHost
{
    Groups groups;
    WorldContext context;

    @Call LootTurnReply take(const ref LootTurnRequest request)
    {
        import dmangos.log : warning;
        import dmangos.world.database : GroupLootRotation;

        auto group = groups.of(request.recipient);
        if (group is null || group.id != request.group)
            return LootTurnReply.init;
        if (context is null || !context.config.cluster.enabled || !group.persistentLootTurns)
            return LootTurnReply(group.takeLootTurn(request.eligible));
        const now = context.unixTime, age = now - request.issuedAt;
        if (!context.canWrite() || !request.node || !request.token || age < -5 || age > 60)
            return LootTurnReply.init;
        const previous = group.nextLooter;
        try
        {
            const recorded = context.database.loadGroupLootRotation(request.group, request.node, request.token);
            if (recorded.assigned)
                return LootTurnReply(recorded.assigned);
            const order = group.lootTurnOrder(recorded.order);
            group.nextLooter = recorded.nextLooter;
            const chosen = group.takeLootTurn(request.eligible, order);
            const turn = GroupLootRotation(group.nextLooter, chosen, order);
            if (chosen && context.database.recordGroupLootRotation(request.group, request.node, request.token, turn, now))
                return LootTurnReply(chosen);
        }
        catch (Exception error)
            warning!"group %s: could not save the round-robin turn: %s"(group.id, error.msg);
        group.nextLooter = previous;
        return LootTurnReply.init;
    }
}

unittest
{
    import dmangos.world.characterdb : GroupMemberRecord, GroupRecord;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    void clustered(ref WorldConfig config) { config.cluster.nodeId = 1; }
    auto db = newDatabase();
    db.groups[42] = GroupRecord(id: 42, leader: 7, leaderName: "Anduin",
        members: [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(9, "Varian"), GroupMemberRecord(8, "Jaina")]);
    auto first = newCreationContext(db, &clustered);
    auto oldHost = LootTurnHost(first.groups, first);
    const now = first.unixTime;
    auto turn = LootTurnRequest(42, 7, [7UL, 8, 9], 1, 100, now);
    assert(oldHost.take(turn).looter == 7);
    turn.node = 2;
    assert(oldHost.take(turn).looter == 9);

    db.groups[42].members = [db.groups[42].members[0], db.groups[42].members[2], db.groups[42].members[1]];
    auto second = newCreationContext(db, &clustered);
    auto replacement = LootTurnHost(second.groups, second);
    turn.node = 1;
    assert(replacement.take(turn).looter == 7, "a retry gets the original answer");
    turn.token = 101;
    assert(replacement.take(turn).looter == 8, "the cursor survives the coordinator switch");
    turn.token = 102;
    assert(replacement.take(turn).looter == 7, "the original party order also survives");
    turn.token = 103;
    turn.issuedAt -= 61;
    assert(replacement.take(turn).looter == 0, "a parked request older than the retry window cannot advance the cursor");
}

/// `op` by `who`.
GroupCommand groupCommand(const OnlinePlayer who, GroupOp op, ulong target = 0, string text = null,
    string text2 = null, uint number = 0, uint number2 = 0)
{
    const p = who.character;
    return GroupCommand(p.guid, p.data.name, p.data.race, who.hasPermissions, op, target, text, text2, number,
        number2);
}

/// See the module documentation.
final class GroupService
{
    private WorldContext context;
    /// Who waits at the meeting stones (`dmangos.world.meetingstone`).
    MeetingStoneQueue meetingStones;
    private long sinceMeetingStones; // milliseconds since the queue last moved
    private imported!"dmangos.world.servicecheckpoint".RealmServiceCheckpoint durable;
    private bool savesCoordinatorState, clearOldCheckpoint;
    private ubyte[] lastSavedState;
    private MonoTime recoveredInvitesUntil;

    private static struct CoordinatorState
    {
        OpenGroupInvite[] invites;
        MeetingStoneQueue stones;
    }

    ///
    this(WorldContext context)
    {
        this.context = context;
    }

    /// Refresh the write revision on startup and restore the old coordinator's queues on promotion.
    void startCoordinator(bool takeOver)
    {
        import dmangos.log : warning;
        import dmangos.plaindata : decode;
        import dmangos.world.servicecheckpoint : RealmServiceCheckpoint;

        stopCoordinator();
        savesCoordinatorState = true;
        durable = RealmServiceCheckpoint(context, ServiceKind.groupQueue);
        ushort previous;
        Duration age;
        const saved = durable.load(takeOver, previous, age);
        clearOldCheckpoint = !saved.length;
        if (!saved.length)
            return;
        try
        {
            CoordinatorState state;
            const(ubyte)[] bytes = saved;
            decode(bytes, state);
            foreach (ref invite; state.invites)
                context.groups.restoreInvitation(invite);
            meetingStones = state.stones;
            lastSavedState = saved.dup;
            const cluster = context.config.cluster;
            recoveredInvitesUntil = context.clock() + (long(cluster.leaseMs) + cluster.failureTimeoutMs + 2000).msecs;
        }
        catch (Exception error)
        {
            clearOldCheckpoint = true;
            warning!"groups: saved invitations and meeting stones could not be restored: %s"(error.msg);
        }
    }

    void stopCoordinator()
    {
        savesCoordinatorState = false;
        clearOldCheckpoint = false;
        lastSavedState = null;
        recoveredInvitesUntil = MonoTime.init;
        sinceMeetingStones = 0;
        meetingStones = MeetingStoneQueue.init;
    }

    private ubyte[] saveCoordinatorState()
    {
        import dmangos.plaindata : encode;

        ubyte[] bytes;
        const state = CoordinatorState(context.groups.openInvitations(), meetingStones);
        encode(bytes, state);
        return bytes;
    }

    private void checkpoint(bool changed)
    {
        if (!savesCoordinatorState || !context.canWrite())
            return;
        const active = context.groups.invitedTo.length || meetingStones.players.length || meetingStones.parties.length
            || meetingStones.offline.length;
        if (!active && !lastSavedState.length && !clearOldCheckpoint)
            return;
        ubyte[] state;
        if (changed)
        {
            state = saveCoordinatorState();
            if (!clearOldCheckpoint && state == lastSavedState)
                return;
        }
        if (durable.save(changed || clearOldCheckpoint, () {
            if (!state.length)
                state = saveCoordinatorState();
            return state;
        }))
        {
            lastSavedState = active ? state : null;
            clearOldCheckpoint = false;
        }
    }

    /// Runs a command that came from node `via` (this node's own id for its own players).
    void run(const GroupCommand c, ushort via)
    {
        if (!context.canWrite())
            return;
        scope (success) checkpoint(true);
        context.heardFrom(c.guid, via);
        auto groups = context.groups;
        final switch (c.op) // the deserializer refused any other value
        {
        case GroupOp.invite:
            return invite(c);
        case GroupOp.accept:
            auto group = groups.invitationOf(c.guid);
            if (group is null || group.leader == c.guid)
                return;
            group.removeInvite(c.guid);
            if (group.isFull)
                return result(c, PartyOperation.PARTY_OP_INVITE, "", PartyResult.ERR_GROUP_FULL);
            if (!group.isCreated)
                group.create();
            group.addMember(c.guid, c.name);
            return;
        case GroupOp.decline:
            auto group = groups.invitationOf(c.guid);
            if (group is null)
                return;
            const leader = group.leader;
            groups.uninvite(c.guid);
            context.deliverTo(leader, Opcode.SMSG_GROUP_DECLINE, packetBody(ServerGroupDecline(c.name)));
            return;
        case GroupOp.uninviteGuid:
            if (c.target != c.guid)
                uninvite(c, c.target, null);
            return;
        case GroupOp.uninvite:
            if (c.text == c.name)
                return;
            auto group = groups.of(c.guid);
            if (group is null)
                return result(c, PartyOperation.PARTY_OP_LEAVE, "", canUninvite(c));
            ulong guid = group.memberGuid(c.text);
            if (guid == 0)
                guid = group.invitedGuid(c.text);
            return uninvite(c, guid, c.text);
        case GroupOp.setLeader:
            auto group = groups.of(c.guid);
            if (group is null || !group.isLeader(c.guid) || context.statusOf(c.target) == MemberStatus.offline
                || groups.of(c.target) !is group)
                return;
            group.changeLeader(c.target);
            return;
        case GroupOp.disband:
            if (auto group = groups.of(c.guid))
            {
                result(c, PartyOperation.PARTY_OP_LEAVE, c.name, PartyResult.ERR_PARTY_RESULT_OK);
                group.removeMember(c.guid, RemoveMethod.leave);
            }
            else if (auto pending = groups.invitationOf(c.guid))
                if (pending.leader == c.guid)
                {
                    result(c, PartyOperation.PARTY_OP_LEAVE, c.name, PartyResult.ERR_PARTY_RESULT_OK);
                    pending.disband();
                }
            return;
        case GroupOp.lootMethod:
            auto group = groups.of(c.guid);
            if (group is null || !group.isLeader(c.guid) || c.number > LootMethod.max)
                return;
            group.setLoot(cast(LootMethod) c.number, c.target, cast(ubyte) c.number2);
            return;
        case GroupOp.targetIcon:
            auto group = groups.of(c.guid);
            if (group !is null && (group.isLeader(c.guid) || group.isAssistant(c.guid)))
                group.setTargetIcon(cast(ubyte) c.number, c.target);
            return;
        case GroupOp.raidConvert:
            auto group = groups.of(c.guid);
            if (group is null || !group.isLeader(c.guid) || group.members.length < group.membersMinCount)
                return;
            result(c, PartyOperation.PARTY_OP_INVITE, "", PartyResult.ERR_PARTY_RESULT_OK);
            group.convertToRaid();
            return;
        case GroupOp.changeSubGroup:
            auto group = groups.of(c.guid);
            if (group is null || c.number >= maxRaidSubGroups
                || !group.isLeader(c.guid) && !group.isAssistant(c.guid) || !group.hasFreeSlot(cast(ubyte) c.number))
                return;
            if (const guid = group.memberGuid(c.text))
                group.changeSubGroup(guid, cast(ubyte) c.number);
            return;
        case GroupOp.swapSubGroup:
            auto group = groups.of(c.guid);
            if (group is null || !group.isRaid || !group.isLeader(c.guid) && !group.isAssistant(c.guid))
                return;
            const first = group.memberGuid(c.text), second = group.memberGuid(c.text2);
            if (first == 0 || second == 0)
                return;
            const a = group.subGroupOf(first), b = group.subGroupOf(second);
            if (a == b)
                return;
            group.changeSubGroup(first, b);
            group.changeSubGroup(second, a);
            return;
        case GroupOp.assistant:
            auto group = groups.of(c.guid);
            if (group !is null && group.isLeader(c.guid))
                group.setAssistant(c.target, c.number != 0);
            return;
        case GroupOp.battlegroundAdd:
        {
            // A battleground's team raid: no invitation is shown; the leader's group is made if need be, and a raid.
            if (groups.of(c.target) !is null || groups.invitationOf(c.target) !is null)
                return;
            auto group = groups.of(c.guid);
            if (group is null)
            {
                if (groups.invitationOf(c.guid) !is null)
                    return;
                group = groups.newGroup();
                if (!group.addLeaderInvite(c.guid, c.name))
                    return;
                group.create();
            }
            else if (!group.isLeader(c.guid))
                return;
            if (group.isFull)
                return;
            group.addMember(c.target, c.text);
            if (!group.isRaid)
                group.convertToRaid();
            return;
        }
        case GroupOp.meetingStoneJoin:
            return meetingStoneJoin(c);
        case GroupOp.meetingStoneLeave:
            return meetingStoneLeave(c);
        case GroupOp.meetingStoneInfo:
            return meetingStoneInfo(c);
        case GroupOp.logout:
            // Logging out: invitations lapse; a party (not a raid) is left
            // when logging out normally; a place in the meeting stone's queue is kept for the player's return.
            meetingStones.setOffline(c.guid);
            groups.uninvite(c.guid);
            auto group = groups.of(c.guid);
            if (group !is null && !group.isRaid && c.number)
                group.removeMember(c.guid, RemoveMethod.leave);
            return;
        }
    }

    /**
     * The meeting stones' queue moves once a second: parties checked against their groups (disbanded, a new
     * leader, made a raid, filled by invitation), players who found a party taken out, then the queue's
     * own rules (`MeetingStoneQueue.update`), carried out.
     */
    void meetingStonesTick(Duration elapsed)
    {
        import std.sumtype : match;

        scope (success) checkpoint(false);
        if (recoveredInvitesUntil != MonoTime.init)
        {
            if (context.clock() < recoveredInvitesUntil)
                return; // a gateway may still be restoring its players and their presence
            recoveredInvitesUntil = MonoTime.init;
            foreach (ref invite; context.groups.openInvitations())
                if (!invite.group && !online(invite.leader))
                    context.groups.uninvite(invite.leader);
                else if (!online(invite.recipient))
                    context.groups.uninvite(invite.recipient);
        }
        sinceMeetingStones += elapsed.total!"msecs";
        if (sinceMeetingStones < 1000)
            return;
        const ms = sinceMeetingStones;
        sinceMeetingStones = 0;
        if (meetingStones.parties.length == 0 && meetingStones.players.length == 0)
            return;
        auto groups = context.groups;
        foreach (q; meetingStones.parties.dup)
        {
            auto group = groups.byId.get(q.group, null);
            if (group is null)
            {
                meetingStones.removeParty(q.group);
                continue;
            }
            if (group.leader != q.leader || group.isRaid)
            {
                meetingStones.removeParty(q.group);
                broadcast(group, ServerMeetingStoneSetQueue(0, QueueStatus.leftQueue));
                continue;
            }
            if (group.members.length != q.members)
            {
                auto party = meetingStones.party(q.group);
                MeetingStoneQueue.fillRoles(*party, classesOf(group));
                if (party.members >= partySize)
                {
                    meetingStones.removeParty(q.group);
                    completed(group);
                }
            }
        }
        foreach (p; meetingStones.players.dup)
            if (!online(p.guid)) // its node went away without its logout: as if it logged out
                meetingStones.setOffline(p.guid);
            else if (groups.of(p.guid) !is null)
            {
                meetingStones.removePlayer(p.guid);
                send(p.guid, ServerMeetingStoneSetQueue(0, QueueStatus.none));
            }
        foreach (event; meetingStones.update(ms))
            event.match!(
                (Joins j) {
                    auto group = groups.byId.get(j.group, null);
                    if (group is null || group.isFull || groups.of(j.player) !is null)
                        return;
                    broadcast(group, ServerMeetingStoneMemberAdded(j.player));
                    group.addMember(j.player, j.name);
                },
                (Forms f) {
                    if (groups.of(f.leader) !is null || groups.of(f.member) !is null)
                        return;
                    send(f.leader, ServerMeetingStoneMemberAdded(f.member));
                    auto group = groups.newGroup();
                    if (!group.addLeaderInvite(f.leader, f.leaderName))
                        return;
                    group.create();
                    group.addMember(f.member, f.memberName);
                    queueParty(group, f.area, f.team);
                },
                (Completes c) {
                    if (auto group = groups.byId.get(c.group, null))
                        completed(group);
                },
                (StillLooking s) {
                    if (auto group = groups.byId.get(s.group, null))
                        foreach (ref m; group.members)
                            context.deliverTo(m.guid, Opcode.SMSG_MEETINGSTONE_IN_PROGRESS, null);
                });
    }

private:
    // At a stone: a party's leader queues its party; a player alone queues itself.
    void meetingStoneJoin(const ref GroupCommand c)
    {
        auto groups = context.groups;
        const team = cast(uint) context.client.teamForRace(c.race);
        if (auto group = groups.of(c.guid))
        {
            if (!group.isLeader(c.guid))
                return send(c.guid, ServerMeetingStoneJoinFailed(JoinFailure.notPartyLeader));
            if (group.isRaid)
                return send(c.guid, ServerMeetingStoneJoinFailed(JoinFailure.raid));
            if (group.isFull)
                return send(c.guid, ServerMeetingStoneJoinFailed(JoinFailure.partyFull));
            return queueParty(group, c.number, team, true);
        }
        meetingStones.removePlayer(c.guid);
        meetingStones.players ~= QueuedPlayer(c.guid, c.name, cast(ubyte) c.number2, team, c.number);
        checkpoint(true);
        send(c.guid, ServerMeetingStoneSetQueue(c.number, QueueStatus.joinedQueue));
    }

    void meetingStoneLeave(const ref GroupCommand c)
    {
        if (auto group = context.groups.of(c.guid))
        {
            if (group.isLeader(c.guid) && meetingStones.removeParty(group.id))
                return broadcast(group, ServerMeetingStoneSetQueue(0, QueueStatus.leftQueue));
            return send(c.guid, ServerMeetingStoneSetQueue(0, QueueStatus.none));
        }
        const left = meetingStones.removePlayer(c.guid) || meetingStones.forgetOffline(c.guid);
        send(c.guid, ServerMeetingStoneSetQueue(0, left ? QueueStatus.leftQueue : QueueStatus.none));
    }

    void meetingStoneInfo(const ref GroupCommand c)
    {
        if (auto group = context.groups.of(c.guid))
        {
            meetingStones.forgetOffline(c.guid); // in a group now: its own place is no more
            if (const party = meetingStones.party(group.id))
                return send(c.guid, ServerMeetingStoneSetQueue(party.area, QueueStatus.joinedQueue));
            return send(c.guid, ServerMeetingStoneSetQueue(0, QueueStatus.none));
        }
        meetingStones.restore(c.guid); // back from a logout: waiting again
        if (const p = meetingStones.player(c.guid))
            return send(c.guid, ServerMeetingStoneSetQueue(p.area, QueueStatus.joinedQueue));
        send(c.guid, ServerMeetingStoneSetQueue(0, QueueStatus.none));
    }

    // `group` waits for members for `area`, its open roles from its members' classes.
    void queueParty(Group group, uint area, uint team, bool recordImmediately = false)
    {
        meetingStones.removeParty(group.id);
        auto party = QueuedParty(group.id, group.leader, team, area);
        MeetingStoneQueue.fillRoles(party, classesOf(group));
        meetingStones.parties ~= party;
        if (recordImmediately)
            checkpoint(true);
        broadcast(group, ServerMeetingStoneSetQueue(area, QueueStatus.joinedQueue));
    }

    // A party is complete: told so, and its stone windows emptied.
    void completed(Group group)
    {
        foreach (ref m; group.members)
            context.deliverTo(m.guid, Opcode.SMSG_MEETINGSTONE_COMPLETE, null);
        broadcast(group, ServerMeetingStoneSetQueue(0, QueueStatus.none));
    }

    // The members' classes, as this node knows them (its own players, the others' presence); 0 for one offline.
    ubyte[] classesOf(const Group group)
    {
        ubyte[] classes;
        foreach (ref m; group.members)
        {
            ubyte c;
            if (auto local = context.onlinePlayer(m.guid))
                c = local.character.data.classId;
            else if (auto remote = context.remotePlayer(m.guid))
                c = remote.entry.classId;
            classes ~= c;
        }
        return classes;
    }

    bool online(ulong guid)
    {
        return context.onlinePlayer(guid) !is null || context.remotePlayer(guid) !is null;
    }

    void send(T)(ulong guid, const T packet)
    {
        context.deliverTo(guid, T.opcode, packetBody(packet));
    }

    void broadcast(T)(const Group group, const T packet)
    {
        const body_ = packetBody(packet);
        foreach (ref m; group.members)
            context.deliverTo(m.guid, T.opcode, body_);
    }

    /// `SMSG_PARTY_COMMAND_RESULT` to the player who gave the command.
    void result(const ref GroupCommand c, PartyOperation operation, string member, PartyResult code)
    {
        context.deliverTo(c.guid, Opcode.SMSG_PARTY_COMMAND_RESULT,
            packetBody(ServerPartyCommandResult(operation, member, code)));
    }

    /// An invitation; the name is checked on the player's node.
    void invite(const ref GroupCommand c)
    {
        with (PartyOperation) with (PartyResult)
        {
            const name = c.text;
            auto raids = context.groups.battlegroundRaids;
            if (raids !is null && raids.of(c.guid) !is null)
                return result(c, PARTY_OP_INVITE, name, ERR_ALREADY_IN_GROUP_S);
            ulong recipient;
            ubyte recipientRace;
            string recipientName;
            if (auto local = context.onlinePlayer(name))
            {
                recipient = local.character.guid;
                recipientRace = local.character.data.race;
                recipientName = local.character.data.name;
            }
            else if (auto remote = context.remotePlayer(name))
            {
                recipient = remote.entry.guid;
                recipientRace = remote.entry.race;
                recipientName = remote.entry.name;
            }
            if (recipient == 0 || recipient == c.guid)
                return result(c, PARTY_OP_INVITE, name, ERR_BAD_PLAYER_NAME_S);
            if (!c.permissions && context.database.isIgnoring(cast(uint) recipient, cast(uint) c.guid))
                return result(c, PARTY_OP_INVITE, name, ERR_IGNORING_YOU_S);
            if (!c.permissions && !context.config.allowTwoSideInteractionGroup
                && context.client.teamForRace(c.race) != context.client.teamForRace(recipientRace))
                return result(c, PARTY_OP_INVITE, name, ERR_PLAYER_WRONG_FACTION);

            auto groups = context.groups;
            auto group = groups.of(c.guid);
            if (group is null)
                group = groups.invitationOf(c.guid);
            if (groups.invitationOf(recipient) !is null || groups.of(recipient) !is null)
                return result(c, PARTY_OP_INVITE, name, ERR_ALREADY_IN_GROUP_S);
            if (group !is null)
            {
                if (!group.isLeader(c.guid) && !group.isAssistant(c.guid))
                {
                    if (group.isCreated)
                        result(c, PARTY_OP_INVITE, "", ERR_NOT_LEADER);
                    return;
                }
                if (group.isFull)
                    return result(c, PARTY_OP_INVITE, "", ERR_GROUP_FULL);
                if (!group.addInvite(recipient, recipientName))
                    return;
            }
            else
            {
                group = groups.newGroup();
                if (!group.addLeaderInvite(c.guid, c.name))
                    return;
                if (!group.addInvite(recipient, recipientName))
                    return group.removeAllInvites();
            }
            checkpoint(true);
            context.deliverTo(recipient, Opcode.SMSG_GROUP_INVITE, packetBody(ServerGroupInvite(c.name)));
            result(c, PARTY_OP_INVITE, name, ERR_PARTY_RESULT_OK);
        }
    }

    /// Whether the player may uninvite: only a group's leader or an assistant.
    PartyResult canUninvite(const ref GroupCommand c)
    {
        auto group = context.groups.of(c.guid);
        if (group is null)
            return PartyResult.ERR_NOT_IN_GROUP;
        if (!group.isLeader(c.guid) && !group.isAssistant(c.guid))
            return PartyResult.ERR_NOT_LEADER;
        return PartyResult.ERR_PARTY_RESULT_OK;
    }

    /// The common part of the two uninvites: kick a member, or withdraw an invitation.
    void uninvite(const ref GroupCommand c, ulong guid, string name)
    {
        const allowed = canUninvite(c);
        if (allowed != PartyResult.ERR_PARTY_RESULT_OK)
            return result(c, PartyOperation.PARTY_OP_LEAVE, "", allowed);
        auto group = context.groups.of(c.guid);
        if (group.isLeader(guid))
            return result(c, PartyOperation.PARTY_OP_LEAVE, "", PartyResult.ERR_NOT_LEADER);
        if (guid && group.isMember(guid))
            return cast(void) group.removeMember(guid, RemoveMethod.kick);
        if (guid && group.isInvited(guid))
            return context.groups.uninvite(guid);
        result(c, PartyOperation.PARTY_OP_LEAVE, name is null ? "" : name, PartyResult.ERR_TARGET_NOT_IN_GROUP_S);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Promotion preserves the original party prompts and solo meeting stone positions.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.cluster.protocol : PresenceEntry;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    foreach (created; [false, true])
    {
        auto db = newDatabase();
        auto former = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 1; });
        former.nodeId = 1;
        former.regionOwnerAround = (uint, Position, float) => former.nodeId;
        const players = [PresenceEntry(7, "Anduin", 7, 1, 1, 20, 0, 12, 0, 0, ""),
            PresenceEntry(8, "Jaina", 8, 1, 8, 20, 0, 12, 0, 0, ""),
            PresenceEntry(9, "Lina", 9, 1, 8, 20, 0, 12, 0, 0, ""),
            PresenceEntry(10, "Quill", 10, 1, 8, 20, 0, 12, 0, 0, ""),
            PresenceEntry(11, "Mira", 11, 1, 5, 20, 0, 12, 0, 0, "")];
        former.presence(3, true, players, null);
        auto original = former.groupService;
        original.startCoordinator(false);
        ulong[] prompted;
        former.deliverRemote = (ushort node, ulong player, ushort opcode, const(ubyte)[]) {
            if (opcode == Opcode.SMSG_GROUP_INVITE)
            {
                assert(db.loadServiceCheckpoint(ServiceKind.groupQueue, former.config.realmId).revision > 0);
                prompted ~= player;
            }
        };
        original.run(GroupCommand(7, "Anduin", 1, false, GroupOp.invite, 0, "Jaina"), 3);
        original.run(GroupCommand(7, "Anduin", 1, false, GroupOp.invite, 0, "Lina"), 3);
        if (created)
            original.run(GroupCommand(8, "Jaina", 1, false, GroupOp.accept), 3);
        assert(prompted == [8UL, 9UL]);
        const originalGroup = former.groups.of(7);
        const groupId = originalGroup is null ? 0 : originalGroup.id;
        if (groupId)
            db.groups[groupId].leaderName = "Anduin"; // the SQL loader joins the leader's character row
        enum uint deadmines = 1581;
        original.run(GroupCommand(10, "Quill", 1, false, GroupOp.meetingStoneJoin, 0, null, null, deadmines, 8), 3);
        original.run(GroupCommand(11, "Mira", 1, false, GroupOp.meetingStoneJoin, 0, null, null, deadmines, 5), 3);
        original.run(GroupCommand(11, "Mira", 1, false, GroupOp.logout), 3);

        auto successor = newCreationContext(db, (ref WorldConfig c) { c.cluster.nodeId = 2; });
        successor.nodeId = 2;
        successor.regionOwnerAround = (uint, Position, float) => successor.nodeId;
        successor.presence(3, true, players[0 .. 4], null);
        auto current = successor.groupService;
        current.startCoordinator(true);
        assert(current.meetingStones.player(10).area == deadmines && current.meetingStones.offline[0].guid == 11);
        assert(successor.groups.invitationOf(9) !is null);
        ushort[] packets;
        successor.deliverRemote = (ushort node, ulong player, ushort opcode, const(ubyte)[]) { packets ~= opcode; };
        if (!created)
            current.run(GroupCommand(8, "Jaina", 1, false, GroupOp.accept), 3);
        current.run(GroupCommand(9, "Lina", 1, false, GroupOp.accept), 3);
        auto group = successor.groups.of(7);
        assert(group.members.length == 3 && group is successor.groups.of(8) && group is successor.groups.of(9));
        assert(!groupId || group.id == groupId);
        assert(!packets.canFind(Opcode.SMSG_GROUP_INVITE), "players can accept the original prompts");

        successor.presence(3, true, players, null);
        current.run(GroupCommand(11, "Mira", 1, false, GroupOp.meetingStoneInfo), 3);
        assert(current.meetingStones.player(11).area == deadmines && !current.meetingStones.offline.length);
    }
}

/**
 * A party across two nodes: the coordinator invites a player of node 2 and creates the group when it
 * accepts; node 2's mirror follows, and there the two are group mates.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.cluster.protocol : GroupState, PresenceEntry;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;

    // The coordinator, node 1, with Anduin; Jaina is on node 2.
    auto db = newDatabase();
    auto coordinator = newCreationContext(db);
    coordinator.nodeId = 1;
    struct Sent { ushort node; ulong guid; ushort opcode; }
    Sent[] sent;
    coordinator.deliverRemote = (ushort node, ulong guid, ushort opcode, const(ubyte)[]) {
        sent ~= Sent(node, guid, opcode);
    };
    GroupState[] states;
    coordinator.groups.changes = (const Group g) { states ~= Groups.stateOf(g); };
    auto anduin = loggedIn(coordinator, db, 7, "Anduin", Position(0, 0, 0));
    anduin.read();
    enum ulong jainaGuid = 8;
    coordinator.presence(2, true, [PresenceEntry(jainaGuid, "Jaina", 9, 1, 8, 10, 1, 12, 0, 0, "")], null);

    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    assert(sent.canFind(Sent(2, jainaGuid, Opcode.SMSG_GROUP_INVITE)), "the invitation goes to node 2");
    sent = null;
    coordinator.groupService.run(GroupCommand(jainaGuid, "Jaina", 1, false, GroupOp.accept), 2);
    auto group = coordinator.groups.of(jainaGuid);
    assert(group !is null && group.isLeader(anduin.session.character.guid) && group.members.length == 2);
    assert(sent.canFind(Sent(2, jainaGuid, Opcode.SMSG_GROUP_LIST)), "Jaina's list, on node 2");
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_GROUP_LIST));
    assert(states.length && states[$ - 1].members.length == 2, "the mirrors are told");

    // Node 2, with Jaina, mirrors it: the two are group mates there, and Jaina's stats go out.
    auto db2 = newDatabase();
    auto node2 = newCreationContext(db2);
    node2.nodeId = 2;
    Sent[] fromNode2;
    node2.deliverRemote = (ushort node, ulong guid, ushort opcode, const(ubyte)[]) {
        fromNode2 ~= Sent(node, guid, opcode);
    };
    node2.groups.clear();
    node2.presence(1, true, [PresenceEntry(anduin.session.character.guid, "Anduin", 7, 1, 1, 1, 0, 12, 0, 0, "")],
        null);
    auto jaina = loggedIn(node2, db2, 8, "Jaina", Position(5000, 0, 0));
    jaina.read();
    node2.groups.mirror(states[$ - 1]);
    assert(node2.groups.sameGroup(jainaGuid, anduin.session.character.guid));
    assert(fromNode2.canFind(Sent(1, anduin.session.character.guid, Opcode.SMSG_PARTY_MEMBER_STATS)),
        "the newcomer's stats, for the member on node 1");

    // Party chat on node 2 reaches Anduin on node 1.
    fromNode2 = null;
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_PARTY, "hi"));
    assert(fromNode2.canFind(Sent(1, anduin.session.character.guid, Opcode.SMSG_MESSAGECHAT)));

    // Disbanded on the coordinator: the mirror forgets it.
    GroupState gone;
    gone.id = group.id;
    gone.removed = true;
    node2.groups.mirror(gone);
    assert(node2.groups.of(jainaGuid) is null && node2.groups.count == 0);
}

/**
 * The meeting stones on the coordinator: five players of node 2 queue alone for one dungeon; the queue makes a
 * party of the first two, which then takes the tank, the healer and the damage it lacks and is complete.
 */
unittest
{
    import core.time : seconds;
    import std.algorithm.searching : canFind;
    import dmangos.cluster.protocol : PresenceEntry;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto coordinator = newCreationContext(db);
    coordinator.nodeId = 1;
    struct Sent { ulong guid; ushort opcode; }
    Sent[] sent;
    coordinator.deliverRemote = (ushort node, ulong guid, ushort opcode, const(ubyte)[]) {
        sent ~= Sent(guid, opcode);
    };
    enum uint deadmines = 1581;
    // A mage, a rogue, a warrior, a priest, a hunter: all human.
    immutable ubyte[5] classes = [8, 4, 1, 5, 3];
    PresenceEntry[] entries;
    foreach (i, c; classes)
        entries ~= PresenceEntry(100 + i, "P" ~ cast(char)('a' + i), 9, 1, c, 20, 0, 1581, 0, 0, "");
    coordinator.presence(2, true, entries, null);
    auto service = coordinator.groupService;
    foreach (i, c; classes)
        service.run(GroupCommand(100 + i, entries[i].name, 1, false, GroupOp.meetingStoneJoin, 0, null, null,
            deadmines, c), 2);
    assert(service.meetingStones.players.length == 5);
    assert(sent.canFind(Sent(100, Opcode.SMSG_MEETINGSTONE_SETQUEUE)));

    service.meetingStonesTick(1.seconds);
    auto group = coordinator.groups.of(100);
    assert(group !is null && group.isLeader(100) && group.members.length == 2, "the first two are a party");
    assert(service.meetingStones.party(group.id) !is null && service.meetingStones.players.length == 3);

    sent = null;
    service.meetingStonesTick(1.seconds);
    assert(group.members.length == 5, "the warrior, the priest and the hunter joined");
    assert(service.meetingStones.parties.length == 0 && service.meetingStones.players.length == 0);
    assert(sent.canFind(Sent(100, Opcode.SMSG_MEETINGSTONE_MEMBER_ADDED)));
    assert(sent.canFind(Sent(104, Opcode.SMSG_MEETINGSTONE_COMPLETE)));

    // Leaving: a player alone is told it left; one who never queued, that it is not queued.
    service.run(GroupCommand(200, "Q", 1, false, GroupOp.meetingStoneJoin, 0, null, null, deadmines, 8), 2);
    service.run(GroupCommand(200, "Q", 1, false, GroupOp.meetingStoneLeave), 2);
    assert(service.meetingStones.players.length == 0);

    // Logging out keeps a place: four wait, one of them away; nothing forms without it (five must wait).
    coordinator.presence(2, true, [PresenceEntry(300, "Ra", 9, 1, 8, 20, 0, 1581, 0, 0, ""),
        PresenceEntry(301, "Rb", 9, 1, 4, 20, 0, 1581, 0, 0, ""), PresenceEntry(302, "Rc", 9, 1, 1, 20, 0, 1581, 0, 0, ""),
        PresenceEntry(303, "Rd", 9, 1, 5, 20, 0, 1581, 0, 0, ""), PresenceEntry(304, "Re", 9, 1, 3, 20, 0, 1581, 0, 0, "")],
        null);
    foreach (ubyte i; 0 .. 5)
        service.run(GroupCommand(300 + i, "R", 1, false, GroupOp.meetingStoneJoin, 0, null, null, deadmines,
            classes[i]), 2);
    service.run(GroupCommand(304, "Re", 1, false, GroupOp.logout, 1), 2);
    assert(service.meetingStones.players.length == 4 && service.meetingStones.offline.length == 1);
    service.meetingStonesTick(1.seconds);
    assert(coordinator.groups.of(300) is null, "four are not enough to make a party");
    // Back, its stone window asks: it waits again, and is told so; then a party forms.
    sent = null;
    service.run(GroupCommand(304, "Re", 1, false, GroupOp.meetingStoneInfo), 2);
    assert(service.meetingStones.players.length == 5 && service.meetingStones.offline.length == 0);
    assert(sent.canFind(Sent(304, Opcode.SMSG_MEETINGSTONE_SETQUEUE)));
    service.meetingStonesTick(1.seconds);
    assert(coordinator.groups.of(300) !is null);
    // Leaving while away (asked at the next login): the place is given up.
    service.run(GroupCommand(302, "Rc", 1, false, GroupOp.logout, 0), 2);
    assert(service.meetingStones.offline.length == 1);
    service.run(GroupCommand(302, "Rc", 1, false, GroupOp.meetingStoneLeave), 2);
    assert(service.meetingStones.offline.length == 0 && service.meetingStones.player(302) is null);
}
