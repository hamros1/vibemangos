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

import dmangos.cluster.protocol : GroupCommand;
import dmangos.world.context : WorldContext;
import dmangos.world.group;
import dmangos.world.map : packetBody;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.opcodes : Opcode;
import dmangos.world.packets;

/// What a `GroupCommand` does.
enum GroupOp : ubyte
{
    invite,          /// `text`: the invitee's name
    accept,
    decline,
    uninviteGuid,    /// `target`
    uninvite,        /// `text`: the name
    setLeader,       /// `target`
    disband,         /// leaving, or giving up a group that never formed
    lootMethod,      /// `number`: the method, `target`: the master looter, `number2`: the threshold
    targetIcon,      /// `number`: the icon, `target`: what it marks
    raidConvert,
    changeSubGroup,  /// `text`: the member's name, `number`: the sub-group
    swapSubGroup,    /// `text`, `text2`: the two members' names
    assistant,       /// `target`, `number`: set (1) or not (0)
    logout,          /// `number`: 1 when logging out normally, 0 for a lost connection
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

    ///
    this(WorldContext context)
    {
        this.context = context;
    }

    /// Runs a command that came from node `via` (this node's own id for its own players).
    void run(const GroupCommand c, ushort via)
    {
        if (c.op > GroupOp.max)
            return;
        context.heardFrom(c.guid, via);
        auto groups = context.groups;
        final switch (cast(GroupOp) c.op)
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
        case GroupOp.logout:
            // Logging out: invitations lapse; a party (not a raid) is left
            // when logging out normally.
            groups.uninvite(c.guid);
            auto group = groups.of(c.guid);
            if (group !is null && !group.isRaid && c.number)
                group.removeMember(c.guid, RemoveMethod.leave);
            return;
        }
    }

private:
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
