/**
 * Friends and ignore lists (CMaNGOS's `SocialMgr`, `MiscHandler.cpp`'s friend handlers): up to 50
 * friends and 25 ignored players a character, kept in `character_social` (flag 1 a friend, 2
 * ignored). The friend list shows who is online (zone, level, class, away or busy), here or on
 * another node of a cluster; a player's friends hear when it comes online and goes offline; an
 * ignored player's whispers are refused (`CHAT_MSG_IGNORED`) and its group invitations too.
 * Mixed into `dmangos.world.session.Character`.
 */
module dmangos.world.social;

import dmangos.bytes : ByteWriter;

/// `SocialFlag`
enum SocialFlag : ubyte
{
    friend = 0x01,
    ignored = 0x02,
}

/// `SOCIALMGR_FRIEND_LIMIT`, `SOCIALMGR_IGNORE_LIMIT`
enum uint friendLimit = 50, ignoreLimit = 25;

/// `FriendsResult`
enum FriendsResult : ubyte
{
    dbError = 0x00,
    listFull = 0x01,
    online = 0x02,
    offline = 0x03,
    notFound = 0x04,
    removed = 0x05,
    addedOnline = 0x06,
    addedOffline = 0x07,
    already = 0x08,
    self = 0x09,
    enemy = 0x0A,
    ignoreFull = 0x0B,
    ignoreSelf = 0x0C,
    ignoreNotFound = 0x0D,
    ignoreAlready = 0x0E,
    ignoreAdded = 0x0F,
    ignoreRemoved = 0x10,
}

/// `FriendStatus`
enum FriendStatus : ubyte
{
    offline = 0,
    online = 1,
    afk = 2,
    dnd = 4,
}

/// What a friend list says of an online friend.
struct FriendInfo
{
    FriendStatus status;
    uint area, level, classId;
}

/// `SMSG_FRIEND_STATUS`: `result` about `guid` (with its state when it is online).
const(ubyte)[] friendStatusPacket(FriendsResult result, ulong guid, const FriendInfo info = FriendInfo.init)
{
    ByteWriter w;
    w.put(cast(ubyte) result);
    w.put(guid);
    if (result == FriendsResult.addedOnline || result == FriendsResult.online)
    {
        w.put(cast(ubyte) info.status);
        w.put(info.area);
        w.put(info.level);
        w.put(info.classId);
    }
    return w.data;
}

/// See the module documentation.
mixin template SocialHandlers()
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.social : FriendInfo, friendLimit, FriendsResult, friendStatusPacket, FriendStatus,
        ignoreLimit, SocialFlag;

    private ubyte[ulong] social; // guid -> `SocialFlag`s

    /// `PlayerSocial::LoadFromDB`.
    package void loadSocial()
    {
        import dmangos.world.objects : HighGuid, makeGuid;

        social = null;
        foreach (row; context.database.loadSocial(player.data.guid))
            social[makeGuid(HighGuid.player, row.other)] |= row.flags; // rows of older servers may split them
    }

    /// Whether this player ignores `guid` (`PlayerSocial::HasIgnore`; `OnlinePlayer.ignores`).
    bool ignoresGuid(ulong guid) const
    {
        return (social.get(guid, 0) & SocialFlag.ignored) != 0;
    }

    /// Whether `guid` is on this player's friend list.
    bool befriends(ulong guid) const
    {
        return (social.get(guid, 0) & SocialFlag.friend) != 0;
    }

    /// `PlayerSocial::SendFriendList` and `SendIgnoreList`.
    package void sendSocialLists()
    {
        ByteWriter friends, ignored;
        ubyte friendCount, ignoredCount;
        ByteWriter friendEntries, ignoredEntries;
        foreach (guid, flags; social)
        {
            if (flags & SocialFlag.friend)
            {
                ++friendCount;
                friendEntries.put(guid);
                const info = friendInfo(guid);
                friendEntries.put(cast(ubyte) info.status);
                if (info.status != FriendStatus.offline)
                {
                    friendEntries.put(info.area);
                    friendEntries.put(info.level);
                    friendEntries.put(info.classId);
                }
            }
            if (flags & SocialFlag.ignored)
            {
                ++ignoredCount;
                ignoredEntries.put(guid);
            }
        }
        friends.put(friendCount);
        friends.putBytes(friendEntries.data);
        ignored.put(ignoredCount);
        ignored.putBytes(ignoredEntries.data);
        deliver(Opcode.SMSG_FRIEND_LIST, friends.data);
        deliver(Opcode.SMSG_IGNORE_LIST, ignored.data);
    }

    /// `sSocialMgr.GetFriendInfo`: a friend's state, here or on another node; offline if it is not online
    /// (or a game master hiding from this player).
    FriendInfo friendInfo(ulong guid)
    {
        import dmangos.world.player : PlayerFlags;
        import dmangos.world.character : Character;

        if (auto other = cast(Character) context.onlinePlayer(guid))
            if (other.character !is null && (!other.character.gmTagOn || hasPermissions))
            {
                const c = other.character;
                const status = c.hasFlag(PlayerFlags.afk) ? FriendStatus.afk
                    : c.hasFlag(PlayerFlags.dnd) ? FriendStatus.dnd : FriendStatus.online;
                return FriendInfo(status, c.data.zone, c.data.level, c.data.classId);
            }
        if (auto remote = context.remotePlayer(guid))
        {
            import dmangos.world.context : PresenceFlags;

            const e = remote.entry;
            if ((e.flags & PresenceFlags.gmTag) && !hasPermissions)
                return FriendInfo.init;
            const status = (e.flags & PresenceFlags.afk) ? FriendStatus.afk
                : (e.flags & PresenceFlags.dnd) ? FriendStatus.dnd : FriendStatus.online;
            return FriendInfo(status, e.zone, e.level, e.classId);
        }
        return FriendInfo.init;
    }

    @Handles(Opcode.CMSG_FRIEND_LIST, WorldState.inWorld)
    void handleFriendList()
    {
        sendSocialLists();
    }

    /// `HandleAddFriendOpcode`: by name, of the player's faction (unless allowed), not itself, not twice.
    @Handles(Opcode.CMSG_ADD_FRIEND, WorldState.inWorld)
    void handleAddFriend(ref ByteReader reader)
    {
        import dmangos.world.objects : HighGuid, makeGuid;
        import dmangos.world.names : normalizedName;

        const name = normalizedName(reader.readCString());
        const low = name.length ? context.database.characterGuid(name) : 0;
        if (low == 0)
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.notFound, 0));
        const guid = makeGuid(HighGuid.player, low);
        if (guid == player.guid)
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.self, guid));
        if (befriends(guid))
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.already, guid));
        const info = context.database.nameInfo(low);
        if (!hasPermissions && !context.config.allowTwoSideAddFriend && !info.isNull
            && context.client.teamForRace(info.get.race) != context.client.teamForRace(player.data.race))
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.enemy, guid));
        if (countWith(SocialFlag.friend) >= friendLimit)
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.listFull, guid));
        setSocial(guid, cast(ubyte)(social.get(guid, 0) | SocialFlag.friend));
        const state = friendInfo(guid);
        deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(state.status != FriendStatus.offline
            ? FriendsResult.addedOnline : FriendsResult.addedOffline, guid, state));
    }

    @Handles(Opcode.CMSG_DEL_FRIEND, WorldState.inWorld)
    void handleDelFriend(const ClientGuid request)
    {
        if (!befriends(request.guid))
            return;
        setSocial(request.guid, cast(ubyte)(social[request.guid] & ~SocialFlag.friend));
        deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.removed, request.guid));
    }

    /// `HandleAddIgnoreOpcode`: by name, not itself, not twice.
    @Handles(Opcode.CMSG_ADD_IGNORE, WorldState.inWorld)
    void handleAddIgnore(ref ByteReader reader)
    {
        import dmangos.world.objects : HighGuid, makeGuid;
        import dmangos.world.names : normalizedName;

        const name = normalizedName(reader.readCString());
        const low = name.length ? context.database.characterGuid(name) : 0;
        if (low == 0)
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.ignoreNotFound, 0));
        const guid = makeGuid(HighGuid.player, low);
        if (guid == player.guid)
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.ignoreSelf, guid));
        if (ignoresGuid(guid))
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.ignoreAlready, guid));
        if (countWith(SocialFlag.ignored) >= ignoreLimit)
            return deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.ignoreFull, guid));
        setSocial(guid, cast(ubyte)(social.get(guid, 0) | SocialFlag.ignored));
        deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.ignoreAdded, guid));
    }

    @Handles(Opcode.CMSG_DEL_IGNORE, WorldState.inWorld)
    void handleDelIgnore(const ClientGuid request)
    {
        if (!ignoresGuid(request.guid))
            return;
        setSocial(request.guid, cast(ubyte)(social[request.guid] & ~SocialFlag.ignored));
        deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(FriendsResult.ignoreRemoved, request.guid));
    }

    /**
     * `sSocialMgr.SendFriendStatus` on a login or logout: the players who have this one as a friend
     * (here, and in a cluster on the other nodes) hear of it. A game master hiding is not announced.
     */
    package void announceToFriends(bool online)
    {
        import dmangos.world.character : Character;

        if (player.gmTagOn)
            return;
        const info = online ? friendInfoOfSelf() : FriendInfo.init;
        foreach (other; context.onlinePlayers)
            if (auto session = cast(Character) other)
                if (session !is this && session.character !is null)
                    session.friendChanged(player.guid, online, info);
        if (context.announceFriendElsewhere !is null)
            context.announceFriendElsewhere(player.guid, online, info.status, info.area, info.level, info.classId);
    }

    /// A player came online or went offline: told if it is a friend of this one.
    void friendChanged(ulong guid, bool online, const FriendInfo info)
    {
        if (!befriends(guid))
            return;
        deliver(Opcode.SMSG_FRIEND_STATUS, friendStatusPacket(online ? FriendsResult.online : FriendsResult.offline,
            guid, info));
    }

    private FriendInfo friendInfoOfSelf()
    {
        import dmangos.world.player : PlayerFlags;

        const status = player.hasFlag(PlayerFlags.afk) ? FriendStatus.afk
            : player.hasFlag(PlayerFlags.dnd) ? FriendStatus.dnd : FriendStatus.online;
        return FriendInfo(status, player.data.zone, player.data.level, player.data.classId);
    }

    private uint countWith(SocialFlag flag)
    {
        uint n;
        foreach (flags; social)
            n += (flags & flag) != 0;
        return n;
    }

    private void setSocial(ulong guid, ubyte flags)
    {
        if (flags)
            social[guid] = flags;
        else
            social.remove(guid);
        context.database.saveSocial(player.data.guid, cast(uint) guid, flags);
    }
}

/**
 * Two players: Anduin befriends Jaina (online), hears when she logs out and back in; she ignores him,
 * so his whispers and his invitation are refused. Names that are no one's, or his own, are refused.
 */
unittest
{
    import core.time : seconds;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGroupName, ClientGuid, ClientPlayerLogin;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto anduin = loggedIn(context, db, 7, "Anduin", at);
    auto jaina = loggedIn(context, db, 8, "Jaina", at);
    anduin.read();
    jaina.read();
    const jainaGuid = makeGuid(HighGuid.player, 8), anduinGuid = makeGuid(HighGuid.player, 7);

    ubyte[] name(string n)
    {
        ByteWriter w;
        w.putCString(n);
        return w.data.dup;
    }

    FriendsResult statusResult(TestClient* c)
    {
        foreach (p; c.read())
            if (p.opcode == Opcode.SMSG_FRIEND_STATUS)
                return cast(FriendsResult) p.body_[0];
        return FriendsResult.dbError;
    }

    anduin.write(Opcode.CMSG_ADD_FRIEND, name("jaina"));
    assert(statusResult(&anduin) == FriendsResult.addedOnline);
    assert(db.loadSocial(7).length == 1, "saved");
    anduin.write(Opcode.CMSG_ADD_FRIEND, name("Jaina"));
    assert(statusResult(&anduin) == FriendsResult.already);
    anduin.write(Opcode.CMSG_ADD_FRIEND, name("Anduin"));
    assert(statusResult(&anduin) == FriendsResult.self);
    anduin.write(Opcode.CMSG_ADD_FRIEND, name("Nobody"));
    assert(statusResult(&anduin) == FriendsResult.notFound);

    // Her logout and login are announced to him.
    jaina.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    jaina.session.update(30.seconds); // the logout's wait (a player's)
    assert(statusResult(&anduin) == FriendsResult.offline, "she went offline");
    jaina.read();
    jaina.write(Opcode.CMSG_PLAYER_LOGIN, ClientPlayerLogin(8));
    jaina.read();
    assert(statusResult(&anduin) == FriendsResult.online, "back online");

    // She ignores him: his whisper is refused, as is his invitation.
    jaina.write(Opcode.CMSG_ADD_IGNORE, name("anduin"));
    assert(statusResult(&jaina) == FriendsResult.ignoreAdded);
    anduin.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_WHISPER, "hello", "Jaina"));
    const refused = anduin.read();
    assert(refused.length == 1 && refused[0].opcode == Opcode.SMSG_MESSAGECHAT && refused[0].body_[0] == ChatType.CHAT_MSG_IGNORED);
    assert(jaina.read().length == 0, "she hears nothing");
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    assert(context.groups.invitationOf(jaina.session.character.guid) is null, "no invitation");

    // His list after a login of his own: she is there, online.
    anduin.write(Opcode.CMSG_FRIEND_LIST, null);
    foreach (p; anduin.read())
        if (p.opcode == Opcode.SMSG_FRIEND_LIST)
            assert(p.body_[0] == 1 && p.body_[9] == FriendStatus.online);
    jaina.write(Opcode.CMSG_DEL_IGNORE, ClientGuid(anduinGuid));
    assert(statusResult(&jaina) == FriendsResult.ignoreRemoved && db.loadSocial(8).length == 0);
    cast(void) jainaGuid;
}
