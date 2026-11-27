/**
 * The client's chat channel requests (join, leave, list, moderate). Each finds the channel in the
 * player's command to the channels, wherever they are kept
 * (`dmangos.world.channelservice`); `dmangos.world.channel` does the rest.
 */
module dmangos.world.channelhandlers;

/// See the module documentation.
final class Channels
{
    import dmangos.world.character : Character;
    import dmangos.world.session : Handles, WorldState;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import std.algorithm.searching : canFind;
    import std.uni : sicmp;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.channel;
    import dmangos.world.channelservice : ChannelOp;
    import dmangos.world.names : normalizedName;
    import dmangos.world.opcodes;
    import dmangos.world.packets;

package:
    /// Checks a channel name and password: names are cut at 128 characters, passwords are not.
    bool checkChannelName(ref string channel, string password)
    {
        if (channel.length > 128)
            channel = channel[0 .. 128];
        if (password.length > 128)
        {
            me.deliver(Opcode.SMSG_CHANNEL_NOTIFY, notice(ChatNotify.wrongPassword, channel));
            return false;
        }
        // Chat links and colours ('|') are for game masters.
        if (!me.isStaff && channel.canFind('|'))
        {
            me.deliver(Opcode.SMSG_CHANNEL_NOTIFY, notice(ChatNotify.invalidName, channel));
            return false;
        }
        return true;
    }

    /// Runs `op` on `channel` where the channels are (`ChannelService`).
    void channelCommand(ChannelOp op, string channel, string arg = null)
    {
        me.context.channelCommand(me, op, channel, arg);
    }

    @Handles(Opcode.CMSG_JOIN_CHANNEL, WorldState.inWorld)
    void handleJoinChannel(const ClientChannelPassword request)
    {
        string name = request.channel;
        if (name.length == 0 || !checkChannelName(name, request.password))
            return;
        // The GM client channel (`gm_client_channel`): only accounts with permissions may join it.
        const gmChannel = me.context.config.gmClientChannel;
        if (gmChannel.length && sicmp(gmChannel, name) == 0 && !me.isStaff)
            return;
        channelCommand(ChannelOp.join, name, request.password);
    }

    @Handles(Opcode.CMSG_LEAVE_CHANNEL, WorldState.inWorld)
    void handleLeaveChannel(const ClientChannelName request)
    {
        if (request.channel.length)
            channelCommand(ChannelOp.leave, request.channel);
    }

    @Handles(Opcode.CMSG_CHANNEL_LIST, WorldState.inWorld)
    void handleChannelList(const ClientChannelName request)
    {
        channelCommand(ChannelOp.list, request.channel);
    }

    @Handles(Opcode.CMSG_CHANNEL_PASSWORD, WorldState.inWorld)
    void handleChannelPassword(const ClientChannelPassword request)
    {
        channelCommand(ChannelOp.password, request.channel, request.password);
    }

    @Handles(Opcode.CMSG_CHANNEL_OWNER, WorldState.inWorld)
    void handleChannelOwner(const ClientChannelName request)
    {
        channelCommand(ChannelOp.owner, request.channel);
    }

    @Handles(Opcode.CMSG_CHANNEL_ANNOUNCEMENTS, WorldState.inWorld)
    void handleChannelAnnouncements(const ClientChannelName request)
    {
        channelCommand(ChannelOp.announcements, request.channel);
    }

    @Handles(Opcode.CMSG_CHANNEL_MODERATE, WorldState.inWorld)
    void handleChannelModerate(const ClientChannelName request)
    {
        channelCommand(ChannelOp.moderate, request.channel);
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
        ChannelOp op;
        switch (opcode)
        {
        case Opcode.CMSG_CHANNEL_SET_OWNER: op = ChannelOp.setOwner; break;
        case Opcode.CMSG_CHANNEL_MODERATOR: op = ChannelOp.moderator; break;
        case Opcode.CMSG_CHANNEL_UNMODERATOR: op = ChannelOp.unmoderator; break;
        case Opcode.CMSG_CHANNEL_MUTE: op = ChannelOp.mute; break;
        case Opcode.CMSG_CHANNEL_UNMUTE: op = ChannelOp.unmute; break;
        case Opcode.CMSG_CHANNEL_INVITE: op = ChannelOp.invite; break;
        case Opcode.CMSG_CHANNEL_KICK: op = ChannelOp.kick; break;
        case Opcode.CMSG_CHANNEL_BAN: op = ChannelOp.ban; break;
        case Opcode.CMSG_CHANNEL_UNBAN: op = ChannelOp.unban; break;
        default:
            assert(0, "every opcode of the @Handles list has a case");
        }
        channelCommand(op, request.channel, target);
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
    import dmangos.world.opcodes : Language;

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

    // A language is usable in a channel once learned. Racial languages are retained on the wire.
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_CHANNEL, "unlearned", "Stormwind",
        Language.LANG_DARNASSIAN));
    assert(anduin.read().length == 0);
    assert(bodyOf(jaina.read(), Opcode.SMSG_MESSAGECHAT)[0] == ChatType.CHAT_MSG_SYSTEM);
    assert(jaina.session.inWorld.player.setSkill(113, 300, 300));
    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_CHANNEL, "learned", "Stormwind",
        Language.LANG_DARNASSIAN));
    const translated = bodyOf(anduin.read(), Opcode.SMSG_MESSAGECHAT);
    assert(translated[0] == ChatType.CHAT_MSG_CHANNEL && translated[1] == Language.LANG_DARNASSIAN);
    jaina.read();

    // The list: Anduin (owner and moderator) and Jaina.
    jaina.write(Opcode.CMSG_CHANNEL_LIST, ClientChannelName("Stormwind"));
    const list = bodyOf(jaina.read(), Opcode.SMSG_CHANNEL_LIST);
    assert(list[0 .. 10] == "Stormwind\0" && list[11 .. 15] == [2, 0, 0, 0]);

    // The Horde has channels of its own with the same names.
    assert(thrall.session.inWorld.player.setSkill(109, 300, 300));
    thrall.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_CHANNEL, "lok'tar", "Stormwind", Language.LANG_ORCISH));
    assert(thrall.read()[0].body_[0] == ChatNotify.notMember && anduin.read().length == 0);

    // Kicking takes a moderator; Anduin owns the channel.
    jaina.write(Opcode.CMSG_CHANNEL_KICK, ClientChannelTarget("Stormwind", "anduin"));
    assert(jaina.read()[0].body_[0] == ChatNotify.notModerator);
    anduin.write(Opcode.CMSG_CHANNEL_KICK, ClientChannelTarget("Stormwind", "jaina"));
    assert(jaina.read()[0].body_[0] == ChatNotify.playerKicked);

    // Leaving, and logging out, empties the channel, which then goes away.
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    assert(context.channelService.channels.alliance.count == 0);
}


/// GM language skills are visible to the client and remain temporary.
unittest
{
    import dmangos.world.opcodes : languageSkills;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0), AccountLevel.gameMaster);
    auto character = gm.session.inWorld.player;
    foreach (skill; languageSkills)
        assert(character.skillValue(skill)[1] != 0);
    assert(character.data.skills.length == 0);
}
