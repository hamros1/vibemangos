/**
 * Handlers of CMaNGOS `Groups/GroupHandler.cpp` and the loot method of
 * `LootHandler.cpp`, mixed into `dmangos.world.session.WorldSession`. The
 * rules live here, as there; what a change does to a group, its rows and
 * its members is in `dmangos.world.group`.
 */
module dmangos.world.grouphandlers;

/// See the module documentation.
mixin template GroupHandlers()
{
    import std.random : uniform;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.group;
    import dmangos.world.map : packetBody;
    import dmangos.world.names : normalizePlayerName;
    import dmangos.world.online : OnlinePlayer;
    import dmangos.world.opcodes;
    import dmangos.world.packets;

private:
    /// `WorldSession::SendPartyResult`
    void sendPartyResult(PartyOperation operation, string member, PartyResult result)
    {
        send(ServerPartyCommandResult(operation, member, result));
    }

    /// `normalizePlayerName`, or null for a name that cannot be a player's.
    static string normalizedName(string name)
    {
        return normalizePlayerName(name) ? name : null;
    }

    /// The other session of an online player.
    static WorldSession sessionOf(OnlinePlayer player)
    {
        return cast(WorldSession) player;
    }

    @Handles(Opcode.CMSG_GROUP_INVITE, WorldState.inWorld)
    void handleGroupInvite(const ClientGroupName request)
    {
        with (PartyOperation) with (PartyResult)
        {
            const name = normalizedName(request.name);
            if (name is null)
                return sendPartyResult(PARTY_OP_INVITE, request.name, ERR_BAD_PLAYER_NAME_S);
            auto recipient = context.onlinePlayer(name);
            if (recipient is null || recipient is this)
                return sendPartyResult(PARTY_OP_INVITE, name, ERR_BAD_PLAYER_NAME_S);
            if (!gameMaster && !context.config.allowTwoSideInteractionGroup
                && context.client.teamForRace(player.data.race) != context.client.teamForRace(recipient.character.data.race))
                return sendPartyResult(PARTY_OP_INVITE, name, ERR_PLAYER_WRONG_FACTION);

            const guid = player.guid, recipientGuid = recipient.character.guid;
            auto group = context.groups.of(guid);
            if (group is null)
                group = context.groups.invitationOf(guid);
            if (context.groups.invitationOf(recipientGuid) !is null || context.groups.of(recipientGuid) !is null)
                return sendPartyResult(PARTY_OP_INVITE, name, ERR_ALREADY_IN_GROUP_S);
            if (group !is null)
            {
                if (!group.isLeader(guid) && !group.isAssistant(guid))
                {
                    if (group.isCreated)
                        sendPartyResult(PARTY_OP_INVITE, "", ERR_NOT_LEADER);
                    return;
                }
                if (group.isFull)
                    return sendPartyResult(PARTY_OP_INVITE, "", ERR_GROUP_FULL);
                if (!group.addInvite(recipient))
                    return;
            }
            else
            {
                group = context.groups.newGroup();
                if (!group.addLeaderInvite(this))
                    return;
                if (!group.addInvite(recipient))
                    return group.removeAllInvites();
            }
            recipient.deliver(Opcode.SMSG_GROUP_INVITE, packetBody(ServerGroupInvite(player.data.name)));
            sendPartyResult(PARTY_OP_INVITE, name, ERR_PARTY_RESULT_OK);
        }
    }

    @Handles(Opcode.CMSG_GROUP_ACCEPT, WorldState.inWorld)
    void handleGroupAccept()
    {
        auto group = context.groups.invitationOf(player.guid);
        if (group is null || group.leader == player.guid)
            return;
        group.removeInvite(player.guid);
        if (group.isFull)
            return sendPartyResult(PartyOperation.PARTY_OP_INVITE, "", PartyResult.ERR_GROUP_FULL);
        if (!group.isCreated)
            group.create();
        group.addMember(player.guid, player.data.name);
    }

    @Handles(Opcode.CMSG_GROUP_DECLINE, WorldState.inWorld)
    void handleGroupDecline()
    {
        auto group = context.groups.invitationOf(player.guid);
        if (group is null)
            return;
        auto leader = context.onlinePlayer(group.leader);
        context.groups.uninvite(player.guid);
        if (leader !is null)
            leader.deliver(Opcode.SMSG_GROUP_DECLINE, packetBody(ServerGroupDecline(player.data.name)));
    }

    /// `Player::CanUninviteFromGroup`
    PartyResult canUninvite()
    {
        auto group = context.groups.of(player.guid);
        if (group is null)
            return PartyResult.ERR_NOT_IN_GROUP;
        if (!group.isLeader(player.guid) && !group.isAssistant(player.guid))
            return PartyResult.ERR_NOT_LEADER;
        return PartyResult.ERR_PARTY_RESULT_OK;
    }

    @Handles(Opcode.CMSG_GROUP_UNINVITE_GUID, WorldState.inWorld)
    void handleGroupUninviteGuid(const ClientGuid request)
    {
        if (request.guid == player.guid)
            return;
        uninvite(request.guid, null);
    }

    @Handles(Opcode.CMSG_GROUP_UNINVITE, WorldState.inWorld)
    void handleGroupUninvite(const ClientGroupName request)
    {
        const name = normalizedName(request.name);
        if (name is null || name == player.data.name)
            return;
        auto group = context.groups.of(player.guid);
        if (group is null)
            return sendPartyResult(PartyOperation.PARTY_OP_LEAVE, "", canUninvite());
        ulong guid = group.memberGuid(name);
        if (guid == 0)
            if (auto invited = group.invited(name))
                guid = invited.character.guid;
        uninvite(guid, name);
    }

    /// The common part of the two uninvite handlers: kick a member, or withdraw an invitation.
    void uninvite(ulong guid, string name)
    {
        const allowed = canUninvite();
        if (allowed != PartyResult.ERR_PARTY_RESULT_OK)
            return sendPartyResult(PartyOperation.PARTY_OP_LEAVE, "", allowed);
        auto group = context.groups.of(player.guid);
        if (group.isLeader(guid))
            return sendPartyResult(PartyOperation.PARTY_OP_LEAVE, "", PartyResult.ERR_NOT_LEADER);
        if (guid && group.isMember(guid))
            return cast(void) group.removeMember(guid, RemoveMethod.kick);
        if (guid && group.isInvited(guid))
            return context.groups.uninvite(guid);
        sendPartyResult(PartyOperation.PARTY_OP_LEAVE, name is null ? "" : name, PartyResult.ERR_TARGET_NOT_IN_GROUP_S);
    }

    @Handles(Opcode.CMSG_GROUP_SET_LEADER, WorldState.inWorld)
    void handleGroupSetLeader(const ClientGuid request)
    {
        auto group = context.groups.of(player.guid);
        if (group is null || !group.isLeader(player.guid) || context.onlinePlayer(request.guid) is null
            || context.groups.of(request.guid) !is group)
            return;
        group.changeLeader(request.guid);
    }

    /// Leaving the group, or giving up a group that never formed.
    @Handles(Opcode.CMSG_GROUP_DISBAND, WorldState.inWorld)
    void handleGroupDisband()
    {
        if (auto group = context.groups.of(player.guid))
        {
            sendPartyResult(PartyOperation.PARTY_OP_LEAVE, player.data.name, PartyResult.ERR_PARTY_RESULT_OK);
            group.removeMember(player.guid, RemoveMethod.leave);
        }
        else if (auto pending = context.groups.invitationOf(player.guid))
            if (pending.leader == player.guid)
            {
                sendPartyResult(PartyOperation.PARTY_OP_LEAVE, player.data.name, PartyResult.ERR_PARTY_RESULT_OK);
                pending.disband();
            }
    }

    @Handles(Opcode.CMSG_LOOT_METHOD, WorldState.inWorld)
    void handleLootMethod(const ClientLootMethod request)
    {
        auto group = context.groups.of(player.guid);
        if (group is null || !group.isLeader(player.guid) || request.method > LootMethod.max)
            return;
        group.setLoot(cast(LootMethod) request.method, request.master, cast(ubyte) request.threshold);
    }

    @Handles(Opcode.MSG_MINIMAP_PING, WorldState.inWorld)
    void handleMinimapPing(const ClientMinimapPing request)
    {
        if (auto group = context.groups.of(player.guid))
            group.broadcast(Opcode.MSG_MINIMAP_PING, packetBody(ServerMinimapPing(player.guid, request.x, request.y)),
                -1, player.guid);
    }

    @Handles(Opcode.MSG_RANDOM_ROLL, WorldState.inWorld)
    void handleRandomRoll(const ClientRandomRoll request)
    {
        if (request.minimum > request.maximum || request.maximum > 10_000)
            return;
        const result = packetBody(ServerRandomRoll(request.minimum, request.maximum,
            uniform!"[]"(request.minimum, request.maximum), player.guid));
        if (auto group = context.groups.of(player.guid))
            group.broadcast(Opcode.MSG_RANDOM_ROLL, result);
        else
            deliver(Opcode.MSG_RANDOM_ROLL, result);
    }

    /// The icon list (`0xFF`), or an icon put on a target by the leader or an assistant.
    @Handles(Opcode.MSG_RAID_TARGET_UPDATE, WorldState.inWorld)
    void handleRaidTargetUpdate(ref ByteReader reader)
    {
        auto group = context.groups.of(player.guid);
        if (group is null)
            return;
        const icon = reader.read!ubyte;
        if (icon == 0xFF)
            return group.sendTargetIconList(this);
        if (!group.isLeader(player.guid) && !group.isAssistant(player.guid))
            return;
        group.setTargetIcon(icon, reader.read!ulong);
    }

    @Handles(Opcode.CMSG_GROUP_RAID_CONVERT, WorldState.inWorld)
    void handleGroupRaidConvert()
    {
        auto group = context.groups.of(player.guid);
        if (group is null || !group.isLeader(player.guid) || group.members.length < group.membersMinCount)
            return;
        sendPartyResult(PartyOperation.PARTY_OP_INVITE, "", PartyResult.ERR_PARTY_RESULT_OK);
        group.convertToRaid();
    }

    @Handles(Opcode.CMSG_GROUP_CHANGE_SUB_GROUP, WorldState.inWorld)
    void handleGroupChangeSubGroup(const ClientGroupChangeSubGroup request)
    {
        auto group = context.groups.of(player.guid);
        if (group is null || request.subGroup >= maxRaidSubGroups
            || !group.isLeader(player.guid) && !group.isAssistant(player.guid) || !group.hasFreeSlot(request.subGroup))
            return;
        if (const guid = group.memberGuid(normalizedName(request.name)))
            group.changeSubGroup(guid, request.subGroup);
    }

    @Handles(Opcode.CMSG_GROUP_SWAP_SUB_GROUP, WorldState.inWorld)
    void handleGroupSwapSubGroup(const ClientGroupSwapSubGroup request)
    {
        auto group = context.groups.of(player.guid);
        if (group is null || !group.isRaid || !group.isLeader(player.guid) && !group.isAssistant(player.guid))
            return;
        const first = group.memberGuid(request.first), second = group.memberGuid(request.second);
        if (first == 0 || second == 0)
            return;
        const a = group.subGroupOf(first), b = group.subGroupOf(second);
        if (a == b)
            return;
        group.changeSubGroup(first, b);
        group.changeSubGroup(second, a);
    }

    @Handles(Opcode.CMSG_GROUP_ASSISTANT_LEADER, WorldState.inWorld)
    void handleGroupAssistantLeader(const ClientGroupAssistantLeader request)
    {
        auto group = context.groups.of(player.guid);
        if (group !is null && group.isLeader(player.guid))
            group.setAssistant(request.guid, request.flag != 0);
    }

    /// The leader asks (no body) and everyone is asked; a member answers (one byte) to the leader.
    @Handles(Opcode.MSG_RAID_READY_CHECK, WorldState.inWorld)
    void handleRaidReadyCheck(ref ByteReader reader)
    {
        auto group = context.groups.of(player.guid);
        if (group is null)
            return;
        if (reader.empty)
        {
            if (group.isLeader(player.guid) || group.isAssistant(player.guid))
                group.broadcast(Opcode.MSG_RAID_READY_CHECK, null);
            return;
        }
        const state = reader.read!ubyte;
        if (auto leader = context.onlinePlayer(group.leader))
        {
            ByteWriter answer;
            answer.put(player.guid);
            answer.put(state);
            leader.deliver(Opcode.MSG_RAID_READY_CHECK, answer.data);
        }
    }

    @Handles(Opcode.CMSG_REQUEST_PARTY_MEMBER_STATS, WorldState.inWorld)
    void handleRequestPartyMemberStats(const ClientGuid request)
    {
        auto member = context.onlinePlayer(request.guid);
        deliver(Opcode.SMSG_PARTY_MEMBER_STATS_FULL, partyMemberStatsFull(request.guid,
            member is null ? null : member.character, memberStatus(member)));
    }

    @Handles(Opcode.CMSG_REQUEST_RAID_INFO, WorldState.inWorld)
    void handleRequestRaidInfo()
    {
        send(ServerRaidInstanceInfo(0));
    }

    /// `WorldSession::LogoutPlayer`'s group part: invitations lapse; a party (not a raid) is left
    /// when logging out normally; the others see the player go offline.
    void leaveGroupsOnLogout(bool loggingOut)
    {
        context.groups.uninvite(player.guid);
        auto group = context.groups.of(player.guid);
        if (group !is null && !group.isRaid && loggingOut)
            group.removeMember(player.guid, RemoveMethod.leave);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.zlib : uncompress;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    /// The decompressed body of an `SMSG_COMPRESSED_UPDATE_OBJECT`.
    const(ubyte)[] inflate(const(ubyte)[] body_)
    {
        return cast(const(ubyte)[]) uncompress(body_[4 .. $]);
    }
}

/// Inviting, accepting, real health between members, party chat, and leaving on logout.
unittest
{
    import dmangos.world.group : MemberStatus, RemoveMethod;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8940, -132, 83.5f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8945, -132, 83.5f));
    anduin.read();
    jaina.read();

    // Unknown names, and oneself, are bad names.
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("nobody"));
    auto reader = ByteReader(anduin.read()[0].body_);
    assert(deserialize!ServerPartyCommandResult(reader).result == PartyResult.ERR_BAD_PLAYER_NAME_S);

    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_PARTY_COMMAND_RESULT]);
    const invitation = jaina.read();
    reader = ByteReader(invitation[0].body_);
    assert(invitation[0].opcode == Opcode.SMSG_GROUP_INVITE && deserialize!ServerGroupInvite(reader).inviter == "Anduin");

    // Jaina accepts: a group with a row, two members, and Anduin leading.
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    auto group = context.groups.of(7);
    assert(group !is null && group.isLeader(7) && group.members.length == 2 && db.groups.length == 1);
    const joined = jaina.read();
    assert(opcodesOf(joined).canFind(Opcode.SMSG_GROUP_LIST));

    // Jaina now sees Anduin's real health, and the others strangers' percentages.
    const anduinHealth = anduin.session.character.values[UNIT_FIELD_HEALTH];
    bool sawRealHealth;
    foreach (p; joined)
        if (p.opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT)
        {
            const update = inflate(p.body_);
            // One values block for guid 7 with health and maximum health: the last eight bytes.
            if (update[5] == 0 && update[6 .. 8] == [1, 7])
                sawRealHealth = update[$ - 8] == anduinHealth && anduinHealth != 100;
        }
    assert(sawRealHealth);
    anduin.read();
    varian.read();

    // Party chat reaches the group and nobody else.
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_PARTY, "inc"));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_MESSAGECHAT] && opcodesOf(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);
    assert(varian.read().length == 0);

    // Varian is invited and declines; Anduin is told.
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("Varian"));
    varian.read();
    varian.write(Opcode.CMSG_GROUP_DECLINE, null);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_GROUP_DECLINE) && context.groups.invitationOf(9) is null);

    // Jaina cannot kick (she does not lead); Anduin can give her the lead.
    jaina.write(Opcode.CMSG_GROUP_UNINVITE_GUID, ClientGuid(7));
    reader = ByteReader(bodyOf(jaina.read(), Opcode.SMSG_PARTY_COMMAND_RESULT));
    assert(deserialize!ServerPartyCommandResult(reader).result == PartyResult.ERR_NOT_LEADER);
    anduin.write(Opcode.CMSG_GROUP_SET_LEADER, ClientGuid(8));
    assert(group.isLeader(8) && db.groups[group.id].leader == 8);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_GROUP_SET_LEADER));

    // Logging out of a party leaves it; two are too few, so the group is gone.
    jaina.read();
    jaina.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    assert(context.groups.of(7) is null && db.groups.length == 0);
    assert(bodyOf(anduin.read(), Opcode.SMSG_GROUP_LIST).length == 24, "an empty list");
}

/// A raid survives a lost connection: the member shows offline, and is back in it after logging in.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(5, 0, 0));
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("Jaina"));
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    anduin.write(Opcode.CMSG_GROUP_RAID_CONVERT, null);
    auto raid = context.groups.of(7);
    assert(raid.isRaid && db.groups[raid.id].isRaid);
    anduin.read();
    jaina.read();

    // Raid chat, and a raid warning from the leader.
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_RAID, "pull?"));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_MESSAGECHAT] && opcodesOf(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_RAID_WARNING, "go"));
    assert(anduin.read().length == 0, "only the leader and assistants warn");
    anduin.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_RAID_WARNING, "go"));
    assert(opcodesOf(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);

    // Jaina's connection drops: she stays, offline.
    jaina.session.disconnected();
    assert(context.groups.of(8) is raid);
    const list = bodyOf(anduin.read(), Opcode.SMSG_GROUP_LIST);
    assert(list[6 .. 12] == "Jaina\0" && list[20] == 0, "offline");

    // She logs in again and gets the list at once; her member stats asked for by Anduin.
    jaina = TestClient(new WorldSession(context, "127.0.0.1"), testKey);
    authenticate(jaina, "JAINA");
    jaina.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(8));
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_GROUP_LIST));
    anduin.read();
    anduin.write(Opcode.CMSG_REQUEST_PARTY_MEMBER_STATS, ClientGuid(8));
    const stats = anduin.read();
    assert(stats[0].opcode == Opcode.SMSG_PARTY_MEMBER_STATS_FULL && stats[0].body_[6] == 1, "online");

    // Rolls go to the whole group.
    jaina.write(Opcode.MSG_RANDOM_ROLL, ClientRandomRoll(1, 100));
    auto reader = ByteReader(bodyOf(anduin.read(), Opcode.MSG_RANDOM_ROLL));
    const roll = deserialize!ServerRandomRoll(reader);
    assert(roll.roll >= 1 && roll.roll <= 100 && roll.guid == 8);
}
