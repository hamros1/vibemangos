/**
 * Handlers of CMaNGOS `Chat/ChannelHandler.cpp`, mixed into
 * `dmangos.world.session.WorldSession`. Each finds the channel in the
 * player's team's `Channels` and calls the `Channel` method of the same
 * name; `dmangos.world.channel` does the rest.
 */
module dmangos.world.channelhandlers;

/// See the module documentation.
mixin template ChannelHandlers()
{
    import std.algorithm.searching : canFind;
    import std.uni : sicmp;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.channel;
    import dmangos.world.names : normalizedName;
    import dmangos.world.opcodes;
    import dmangos.world.packets;

private:
    /// `WorldSession::CheckChatChannelNameAndPassword`: names are cut at 128 characters, passwords are not.
    bool checkChannelName(ref string channel, string password)
    {
        if (channel.length > 128)
            channel = channel[0 .. 128];
        if (password.length > 128)
        {
            deliver(Opcode.SMSG_CHANNEL_NOTIFY, notice(ChatNotify.wrongPassword, channel));
            return false;
        }
        // Chat links and colours ('|') are for game masters.
        if (account.level == AccountLevel.player && channel.canFind('|'))
        {
            deliver(Opcode.SMSG_CHANNEL_NOTIFY, notice(ChatNotify.invalidName, channel));
            return false;
        }
        return true;
    }

    /// The channel `name`, or null after telling the client it is not in it.
    Channel channelNamed(string name)
    {
        return context.channelsFor(this).find(name, this);
    }

    @Handles(Opcode.CMSG_JOIN_CHANNEL, WorldState.inWorld)
    void handleJoinChannel(const ClientChannelPassword request)
    {
        string name = request.channel;
        if (name.length == 0 || !checkChannelName(name, request.password))
            return;
        // ArcEmu's `GMClient.GmClientChannel`: only accounts with permissions may join it.
        const gmChannel = context.config.gmClientChannel;
        if (gmChannel.length && sicmp(gmChannel, name) == 0 && !hasPermissions)
            return;
        context.channelsFor(this).getOrCreate(name).join(this, request.password);
    }

    @Handles(Opcode.CMSG_LEAVE_CHANNEL, WorldState.inWorld)
    void handleLeaveChannel(const ClientChannelName request)
    {
        if (request.channel.length == 0)
            return;
        auto channels = context.channelsFor(this);
        if (auto channel = channels.find(request.channel, this))
            channel.leave(this);
        channels.leftChannel(request.channel);
    }

    @Handles(Opcode.CMSG_CHANNEL_LIST, WorldState.inWorld)
    void handleChannelList(const ClientChannelName request)
    {
        if (auto channel = channelNamed(request.channel))
            channel.sendList(this);
    }

    @Handles(Opcode.CMSG_CHANNEL_PASSWORD, WorldState.inWorld)
    void handleChannelPassword(const ClientChannelPassword request)
    {
        if (auto channel = channelNamed(request.channel))
            channel.setPassword(this, request.password);
    }

    @Handles(Opcode.CMSG_CHANNEL_OWNER, WorldState.inWorld)
    void handleChannelOwner(const ClientChannelName request)
    {
        if (auto channel = channelNamed(request.channel))
            channel.sendOwner(this);
    }

    @Handles(Opcode.CMSG_CHANNEL_ANNOUNCEMENTS, WorldState.inWorld)
    void handleChannelAnnouncements(const ClientChannelName request)
    {
        if (auto channel = channelNamed(request.channel))
            channel.toggleAnnouncements(this);
    }

    @Handles(Opcode.CMSG_CHANNEL_MODERATE, WorldState.inWorld)
    void handleChannelModerate(const ClientChannelName request)
    {
        if (auto channel = channelNamed(request.channel))
            channel.toggleModeration(this);
    }

    /// The commands aimed at a player, told apart by their opcode.
    @Handles([Opcode.CMSG_CHANNEL_SET_OWNER, Opcode.CMSG_CHANNEL_MODERATOR, Opcode.CMSG_CHANNEL_UNMODERATOR,
        Opcode.CMSG_CHANNEL_MUTE, Opcode.CMSG_CHANNEL_UNMUTE, Opcode.CMSG_CHANNEL_INVITE, Opcode.CMSG_CHANNEL_KICK,
        Opcode.CMSG_CHANNEL_BAN, Opcode.CMSG_CHANNEL_UNBAN], WorldState.inWorld)
    void handleChannelTarget(const ClientChannelTarget request, Opcode opcode)
    {
        const target = normalizedName(request.target);
        if (target is null)
            return;
        auto channel = channelNamed(request.channel);
        if (channel is null)
            return;
        switch (opcode)
        {
        case Opcode.CMSG_CHANNEL_SET_OWNER:
            return channel.setOwner(this, target);
        case Opcode.CMSG_CHANNEL_MODERATOR:
        case Opcode.CMSG_CHANNEL_UNMODERATOR:
            return channel.setModeFlags(this, target, MemberFlags.moderator, opcode == Opcode.CMSG_CHANNEL_MODERATOR);
        case Opcode.CMSG_CHANNEL_MUTE:
        case Opcode.CMSG_CHANNEL_UNMUTE:
            return channel.setModeFlags(this, target, MemberFlags.muted, opcode == Opcode.CMSG_CHANNEL_MUTE);
        case Opcode.CMSG_CHANNEL_INVITE:
            return channel.invite(this, target);
        case Opcode.CMSG_CHANNEL_KICK:
        case Opcode.CMSG_CHANNEL_BAN:
            return channel.kickOrBan(this, target, opcode == Opcode.CMSG_CHANNEL_BAN);
        case Opcode.CMSG_CHANNEL_UNBAN:
            return channel.unban(this, target);
        default:
            assert(0, "every opcode of the @Handles list has a case");
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.testclient;
}

/// Two players in a custom channel: joining, talking, the member list, and teams kept apart.
unittest
{
    import dmangos.world.channel : ChatNotify;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(5000, 0, 0));
    auto thrall = loggedIn(context, db, 9, "Thrall", Position(-5000, 0, 0), AccountLevel.player, raceOrc);
    anduin.read();

    anduin.write(Opcode.CMSG_JOIN_CHANNEL, ClientChannelPassword("Stormwind", ""));
    const joined = anduin.read();
    assert(joined[0].opcode == Opcode.SMSG_CHANNEL_NOTIFY && joined[0].body_[0] == ChatNotify.youJoined);
    jaina.write(Opcode.CMSG_JOIN_CHANNEL, ClientChannelPassword("stormwind", ""));
    assert(anduin.read()[0].body_[0] == ChatNotify.joined, "custom channels announce");
    jaina.read();

    // Far apart, they talk through the channel.
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_CHANNEL, "hi", "Stormwind"));
    const heard = anduin.read();
    assert(heard.length == 1 && heard[0].opcode == Opcode.SMSG_MESSAGECHAT
        && heard[0].body_[0] == ChatType.CHAT_MSG_CHANNEL);
    jaina.read();

    // The list: Anduin (owner and moderator) and Jaina.
    jaina.write(Opcode.CMSG_CHANNEL_LIST, ClientChannelName("Stormwind"));
    const list = bodyOf(jaina.read(), Opcode.SMSG_CHANNEL_LIST);
    assert(list[0 .. 10] == "Stormwind\0" && list[11 .. 15] == [2, 0, 0, 0]);

    // The Horde has channels of its own with the same names.
    thrall.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_CHANNEL, "lok'tar", "Stormwind"));
    assert(thrall.read()[0].body_[0] == ChatNotify.notMember && anduin.read().length == 0);

    // Kicking takes a moderator; Anduin owns the channel.
    jaina.write(Opcode.CMSG_CHANNEL_KICK, ClientChannelTarget("Stormwind", "anduin"));
    assert(jaina.read()[0].body_[0] == ChatNotify.notModerator);
    anduin.write(Opcode.CMSG_CHANNEL_KICK, ClientChannelTarget("Stormwind", "jaina"));
    assert(jaina.read()[0].body_[0] == ChatNotify.playerKicked);

    // Leaving, and logging out, empties the channel, which then goes away.
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    assert(context.channels.alliance.count == 0);
}
