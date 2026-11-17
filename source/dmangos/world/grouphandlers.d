/**
 * Handlers of CMaNGOS `Groups/GroupHandler.cpp` and the loot method of
 * `LootHandler.cpp`, mixed into `dmangos.world.character.Character`. What
 * changes a group is a command for the groups' service, wherever it is
 * (`dmangos.world.groupservice`, which has the rules); what only reads one is
 * answered here. What a change does to a group, its rows and its members is
 * in `dmangos.world.group`.
 */
module dmangos.world.grouphandlers;

/// See the module documentation.
mixin template GroupHandlers()
{
    import std.random : uniform;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.group;
    import dmangos.world.groupservice : GroupOp;
    import dmangos.world.map : packetBody;
    import dmangos.world.names : normalizedName;
    import dmangos.world.online : OnlinePlayer;
    import dmangos.world.opcodes;
    import dmangos.world.packets;

private:
    /// `WorldSession::SendPartyResult`
    void sendPartyResult(PartyOperation operation, string member, PartyResult result)
    {
        send(ServerPartyCommandResult(operation, member, result));
    }

    /// The other session of an online player.
    static Character sessionOf(OnlinePlayer player)
    {
        return cast(Character) player;
    }

    /// Runs a group command where the groups change (`GroupService`).
    void groupCommand(GroupOp op, ulong target = 0, string text = null, string text2 = null, uint number = 0,
        uint number2 = 0)
    {
        context.groupCommand(this, op, target, text, text2, number, number2);
    }

    @Handles(Opcode.CMSG_GROUP_INVITE, WorldState.inWorld)
    void handleGroupInvite(const ClientGroupName request)
    {
        const name = normalizedName(request.name);
        if (name is null)
            return sendPartyResult(PartyOperation.PARTY_OP_INVITE, request.name, PartyResult.ERR_BAD_PLAYER_NAME_S);
        groupCommand(GroupOp.invite, 0, name);
    }

    @Handles(Opcode.CMSG_GROUP_ACCEPT, WorldState.inWorld)
    void handleGroupAccept()
    {
        groupCommand(GroupOp.accept);
    }

    @Handles(Opcode.CMSG_GROUP_DECLINE, WorldState.inWorld)
    void handleGroupDecline()
    {
        groupCommand(GroupOp.decline);
    }

    @Handles(Opcode.CMSG_GROUP_UNINVITE_GUID, WorldState.inWorld)
    void handleGroupUninviteGuid(const ClientGuid request)
    {
        groupCommand(GroupOp.uninviteGuid, request.guid);
    }

    @Handles(Opcode.CMSG_GROUP_UNINVITE, WorldState.inWorld)
    void handleGroupUninvite(const ClientGroupName request)
    {
        if (const name = normalizedName(request.name))
            groupCommand(GroupOp.uninvite, 0, name);
    }

    @Handles(Opcode.CMSG_GROUP_SET_LEADER, WorldState.inWorld)
    void handleGroupSetLeader(const ClientGuid request)
    {
        groupCommand(GroupOp.setLeader, request.guid);
    }

    /// Leaving the group, or giving up a group that never formed.
    @Handles(Opcode.CMSG_GROUP_DISBAND, WorldState.inWorld)
    void handleGroupDisband()
    {
        groupCommand(GroupOp.disband);
    }

    @Handles(Opcode.CMSG_LOOT_METHOD, WorldState.inWorld)
    void handleLootMethod(const ClientLootMethod request)
    {
        groupCommand(GroupOp.lootMethod, request.master, null, null, request.method, request.threshold);
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
            return group.sendTargetIconList(player.guid);
        groupCommand(GroupOp.targetIcon, reader.read!ulong, null, null, icon);
    }

    @Handles(Opcode.CMSG_GROUP_RAID_CONVERT, WorldState.inWorld)
    void handleGroupRaidConvert()
    {
        groupCommand(GroupOp.raidConvert);
    }

    @Handles(Opcode.CMSG_GROUP_CHANGE_SUB_GROUP, WorldState.inWorld)
    void handleGroupChangeSubGroup(const ClientGroupChangeSubGroup request)
    {
        groupCommand(GroupOp.changeSubGroup, 0, normalizedName(request.name), null, request.subGroup);
    }

    @Handles(Opcode.CMSG_GROUP_SWAP_SUB_GROUP, WorldState.inWorld)
    void handleGroupSwapSubGroup(const ClientGroupSwapSubGroup request)
    {
        groupCommand(GroupOp.swapSubGroup, 0, request.first, request.second);
    }

    @Handles(Opcode.CMSG_GROUP_ASSISTANT_LEADER, WorldState.inWorld)
    void handleGroupAssistantLeader(const ClientGroupAssistantLeader request)
    {
        groupCommand(GroupOp.assistant, request.guid, null, null, request.flag != 0);
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
        ByteWriter answer;
        answer.put(player.guid);
        answer.put(state);
        context.deliverTo(group.leader, Opcode.MSG_RAID_READY_CHECK, answer.data);
    }

    /// A member's stats; one another node simulates is asked for them there.
    @Handles(Opcode.CMSG_REQUEST_PARTY_MEMBER_STATS, WorldState.inWorld)
    void handleRequestPartyMemberStats(const ClientGuid request)
    {
        auto member = context.onlinePlayer(request.guid);
        if (member is null && context.requestMemberStats !is null)
            if (auto remote = context.remotePlayer(request.guid))
                return context.requestMemberStats(remote.node, player.guid, request.guid);
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
        groupCommand(GroupOp.logout, 0, null, null, loggingOut);
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
    assert(invitation[0].opcode == Opcode.SMSG_GROUP_INVITE
        && deserialize!ServerGroupInvite(reader).inviter == "Anduin");

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
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_MESSAGECHAT]
        && opcodesOf(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);
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
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_MESSAGECHAT]
        && opcodesOf(jaina.read()) == [Opcode.SMSG_MESSAGECHAT]);
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
