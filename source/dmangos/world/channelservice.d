/**
 * Chat channels as a cluster service (docs/SERVICES.md; first docs/CLUSTER.md).
 *
 * A channel's members may be simulated by any node, so the channels' state lives in one place: the
 * `ChannelService` hosted by the node the cluster placed the channels service on (`ChannelsHost`;
 * standalone, the one server). Every channel command a player gives (joining, leaving, talking,
 * moderating, logging out, changing zone) becomes a `ChannelCommand` with what the channels need of
 * the player, and a call of the service's `run`: on its node a direct call, from another the command
 * as bytes (`dmangos.cluster.services`). What a channel tells a member goes to the node simulating it
 * (`DeliverTo`), found by presence, or the node its last command came from. The service moves like a
 * region and carries its channel state on a clean handoff.
 */
module dmangos.world.channelservice;

public import dmangos.cluster.protocol : ChannelOp; // a cluster message's field

import dmangos.cluster.protocol : ChannelCommand;
import dmangos.cluster.services : Call, Service, ServiceKind;
import dmangos.world.channel;
import dmangos.world.clientdata : ClientData;
import dmangos.world.context : WorldContext;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.opcodes : Language, Opcode;


/// `op` on `channel`, by `who`.
ChannelCommand channelCommand(const OnlinePlayer who, ChannelOp op, string channel, string arg = null,
    Language language = Language.LANG_UNIVERSAL)
{
    import dmangos.world.honor : rankInfo;
    import dmangos.world.updatefields : PLAYER_BYTES_3;

    const p = who.character;
    return ChannelCommand(p.guid, p.data.name, p.data.race, who.canUseCommand('c'), p.chatTag, op, channel, arg,
        cast(uint) language, rankInfo(p.values.getByte!PLAYER_BYTES_3(3)).visualRank);
}

/// A channel command for the channels service, and the node it came from.
struct ChannelCall
{
    ChannelCommand command;
    ushort via;
}

/// The channels as a cluster service: the node it is placed on runs every channel command.
@Service(ServiceKind.channels)
struct ChannelsHost
{
    ChannelService channels;

    ubyte[] saveState() const
    {
        return channels.saveState();
    }

    void tick(imported!"core.time".Duration)
    {
        channels.checkpoint(false);
    }

    /// A player's channel command.
    @Call void run(const ref ChannelCall call)
    {
        channels.run(call.command, call.via);
    }
}

/// See the module documentation.
final class ChannelService : MemberDirectory
{
    /// The channels of each team.
    ChannelManagers channels;

    private
    {
        WorldContext context;
        Member[ulong] members;    // players who gave a command, while in a channel
        bool checkpointEnabled;
        ulong checkpointRevision;
        long nextCheckpoint;
    }

    private static struct SavedMember
    {
        ulong guid;
        string name;
        ubyte race;
        bool moderatesAll;
        byte pvpRank;
        ushort node;
    }

    private static struct SavedState
    {
        SavedChannel[] alliance, horde;
        SavedMember[] members;
    }

    ///
    this(WorldContext context, const ClientData client, ChannelSettings settings, const(ubyte)[] state = null)
    {
        this.context = context;
        channels.alliance = new Channels(this, client, settings);
        channels.horde = settings.crossFaction ? channels.alliance : new Channels(this, client, settings);
        const clustered = context.config.cluster.nodeId != 0 && context.regionOwnerAround !is null;
        if (clustered)
        {
            import dmangos.log : warning;
            import std.base64 : Base64;
            import std.algorithm.searching : startsWith;

            try
            {
                const saved = context.database.loadChannelCheckpoint(context.config.realmId);
                checkpointRevision = saved.revision;
                const age = context.unixTime - saved.at;
                if (!state.length && saved.revision && age >= -5 && age <= 120 && saved.state.startsWith("1:"))
                {
                    restoreState(Base64.decode(saved.state[2 .. $]));
                    nodeLost(saved.node);
                }
            }
            catch (Exception error)
                warning!"channels: could not read the saved service state: %s"(error.msg);
        }
        if (state.length)
            restoreState(state);
        checkpointEnabled = clustered;
    }

    private void restoreState(const(ubyte)[] state)
    {
        import dmangos.plaindata : decode;

        if (!state.length)
            return;
        SavedState saved;
        decode(state, saved);
        channels.alliance.restoreState(saved.alliance);
        if (channels.horde !is channels.alliance)
            channels.horde.restoreState(saved.horde);
        foreach (ref row; saved.members)
        {
            auto member = new Member(context, row.guid, row.name, row.race, row.moderatesAll, row.node);
            member.pvpRank_ = row.pvpRank;
            members[row.guid] = member;
        }
    }

    private void checkpoint(bool changed)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.database : ChannelCheckpoint;
        import std.base64 : Base64;

        const now = context.unixTime;
        if (!checkpointEnabled || (!changed && now < nextCheckpoint) || !context.canWrite())
            return;
        nextCheckpoint = now + 10;
        try
        {
            const saved = ChannelCheckpoint(checkpointRevision, now, context.nodeId,
                "1:" ~ Base64.encode(saveState()).idup);
            if (context.database.saveChannelCheckpoint(context.config.realmId, saved))
                ++checkpointRevision;
            else if (context.canWrite())
            {
                checkpointEnabled = false;
                warning!"channels: another host has a newer service checkpoint"();
            }
        }
        catch (DatabaseException error)
            warning!"channels: could not checkpoint the service: %s"(error.msg);
    }

    private ubyte[] saveState() const
    {
        import dmangos.plaindata : encode;

        SavedState saved;
        saved.alliance = channels.alliance.saveState();
        if (channels.horde !is channels.alliance)
            saved.horde = channels.horde.saveState();
        foreach (member; members)
            if (channels.alliance.channelsOf(member.guid).length || channels.horde.channelsOf(member.guid).length)
                saved.members ~= SavedMember(member.guid, member.name, member.race, member.moderatesAll,
                    member.pvpRank, member.node);
        ubyte[] bytes;
        encode(bytes, saved);
        return bytes;
    }

    /// Runs a command that came from node `via` (this node's own id for its own players).
    void run(const ChannelCommand c, ushort via)
    {
        import std.algorithm.comparison : among;

        scope (success)
            if (!c.op.among(ChannelOp.say, ChannelOp.forcedSay, ChannelOp.list, ChannelOp.owner, ChannelOp.invite))
                checkpoint(true);
        auto who = memberFor(c, via);
        auto set = channels.forTeam(context.client.teamForRace(c.race));
        Channel named()
        {
            return set.find(c.channel, who);
        }

        final switch (c.op)
        {
        case ChannelOp.join:
            return set.getOrCreate(c.channel).join(who, c.arg);
        case ChannelOp.leave:
            if (auto channel = named())
                channel.leave(who);
            set.leftChannel(c.channel);
            return forgetIfIdle(who);
        case ChannelOp.list:
            if (auto channel = named())
                channel.sendList(who);
            return;
        case ChannelOp.password:
            if (auto channel = named())
                channel.setPassword(who, c.arg);
            return;
        case ChannelOp.owner:
            if (auto channel = named())
                channel.sendOwner(who);
            return;
        case ChannelOp.announcements:
            if (auto channel = named())
                channel.toggleAnnouncements(who);
            return;
        case ChannelOp.moderate:
            if (auto channel = named())
                channel.toggleModeration(who);
            return;
        case ChannelOp.setOwner:
            if (auto channel = named())
                channel.setOwner(who, c.arg);
            return;
        case ChannelOp.moderator:
        case ChannelOp.unmoderator:
            if (auto channel = named())
                channel.setModeFlags(who, c.arg, MemberFlags.moderator, c.op == ChannelOp.moderator);
            return;
        case ChannelOp.mute:
        case ChannelOp.unmute:
            if (auto channel = named())
                channel.setModeFlags(who, c.arg, MemberFlags.muted, c.op == ChannelOp.mute);
            return;
        case ChannelOp.invite:
            if (auto channel = named())
                channel.invite(who, c.arg);
            return;
        case ChannelOp.kick:
        case ChannelOp.ban:
            if (auto channel = named())
                channel.kickOrBan(who, c.arg, c.op == ChannelOp.ban);
            return;
        case ChannelOp.unban:
            if (auto channel = named())
                channel.unban(who, c.arg);
            return;
        case ChannelOp.say:
            if (auto channel = named())
                channel.say(who, c.arg, cast(Language) c.language, c.chatTag);
            return;
        case ChannelOp.forcedSay:
            if (auto channel = set.find(c.channel, null))
                channel.forcedSay(c.guid, c.arg, c.chatTag);
            return;
        case ChannelOp.leaveAll:
            set.leaveAll(who);
            members.remove(c.guid);
            return;
        case ChannelOp.zoneChanged:
            set.zoneChanged(who, c.arg);
            return forgetIfIdle(who);
        }
    }

    /// Node `node` was lost: its players leave their channels, as if they had logged out.
    void nodeLost(ushort node)
    {
        Member[] gone;
        foreach (m; members)
        {
            if (m.node != node)
                continue;
            if (context.onlinePlayer(m.guid) !is null)
                m.node = context.nodeId;
            else if (auto moved = context.remotePlayer(m.guid))
                m.node = moved.node;
            else
                gone ~= m;
        }
        foreach (m; gone)
        {
            channels.forTeam(context.client.teamForRace(m.race)).leaveAll(m);
            members.remove(m.guid);
        }
        if (gone.length)
            checkpoint(true);
    }

    /// Players remembered (those in a channel, and the last to give a command).
    @property size_t remembered() const
    {
        return members.length;
    }

    /// `MemberDirectory`: a player online on any node.
    ChannelMember member(ulong guid)
    {
        if (auto known = guid in members)
            return *known;
        if (auto local = context.onlinePlayer(guid))
        {
            const p = local.character;
            return new Member(context, guid, p.data.name, p.data.race, false, context.nodeId);
        }
        if (auto remote = context.remotePlayer(guid))
            return new Member(context, guid, remote.entry.name, remote.entry.race, false, remote.node);
        return null;
    }

    /// ditto
    ChannelMember member(string name)
    {
        if (auto local = context.onlinePlayer(name))
            return member(local.character.guid);
        if (auto remote = context.remotePlayer(name))
            return member(remote.entry.guid);
        return null;
    }

private:
    Member memberFor(const ref ChannelCommand c, ushort via)
    {
        if (auto known = c.guid in members)
        {
            known.update(c, via);
            return *known;
        }
        auto m = new Member(context, c.guid, c.name, c.race, c.moderateAll, via);
        members[c.guid] = m;
        return m;
    }

    void forgetIfIdle(Member who)
    {
        if (channels.forTeam(context.client.teamForRace(who.race)).channelsOf(who.guid).length == 0)
            members.remove(who.guid);
    }
}

/// A player as a channel member: its messages go to its node, wherever that is now.
private final class Member : ChannelMember
{
    immutable ulong guid_;
    private
    {
        WorldContext context;
        string name_;
        ubyte race_;
        bool moderatesAll_;
        byte pvpRank_;
        ushort node;              // where its last command came from
    }

    this(WorldContext context, ulong guid, string name, ubyte race, bool moderatesAll, ushort node)
    {
        this.context = context;
        guid_ = guid;
        name_ = name;
        race_ = race;
        moderatesAll_ = moderatesAll;
        this.node = node;
    }

    @property byte pvpRank() const
    {
        return pvpRank_;
    }

    void update(const ref ChannelCommand c, ushort via)
    {
        name_ = c.name;
        race_ = c.race;
        moderatesAll_ = c.moderateAll;
        pvpRank_ = c.pvpRank;
        node = via;
    }

    @property ulong guid() const { return guid_; }
    @property string name() const { return name_; }
    @property ubyte race() const { return race_; }
    @property bool moderatesAll() const { return moderatesAll_; }

    void deliver(Opcode opcode, const(ubyte)[] body_)
    {
        if (auto local = context.onlinePlayer(guid_))
            return local.deliver(opcode, body_);
        if (context.deliverRemote is null)
            return;
        if (auto remote = context.remotePlayer(guid_))
            node = remote.node; // presence follows it between nodes
        if (node != context.nodeId)
            context.deliverRemote(node, guid_, cast(ushort) opcode, body_);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Players of two nodes in one channel, served by the coordinator; a lost node's players leave.
unittest
{
    import dmangos.cluster.protocol : PresenceEntry;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.nodeId = 1;
    struct Sent { ushort node; ulong guid; ushort opcode; ubyte code; }
    Sent[] sent;
    context.deliverRemote = (ushort node, ulong guid, ushort opcode, const(ubyte)[] body_) {
        sent ~= Sent(node, guid, opcode, body_[0]);
    };
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(0, 0, 0));
    anduin.read();
    auto service = context.channelService;

    // Anduin, here, joins; Jaina, on node 2, joins too: both hear of each other.
    service.run(channelCommand(anduin.session.inWorld, ChannelOp.join, "Club"), 1);
    anduin.read();
    context.presence(2, true, [PresenceEntry(0x40, "Jaina", 9, 1, 8, 10, 1, 12, 0, 0, "")], null);
    auto jaina = ChannelCommand(0x40, "Jaina", 1, false, 0, ChannelOp.join, "club", "", 0);
    service.run(jaina, 2);
    assert(sent.length == 1 && sent[0] == Sent(2, 0x40, Opcode.SMSG_CHANNEL_NOTIFY, ChatNotify.youJoined));
    assert(anduin.read()[0].body_[0] == ChatNotify.joined);

    // Jaina talks: Anduin hears it here, Jaina's copy goes to node 2.
    sent = null;
    auto say = ChannelCommand(0x40, "Jaina", 1, false, 0, ChannelOp.say, "Club", "hello", 7);
    service.run(say, 2);
    assert(anduin.read()[0].opcode == Opcode.SMSG_MESSAGECHAT);
    assert(sent.length == 1 && sent[0].opcode == Opcode.SMSG_MESSAGECHAT);

    // The owner, Anduin, makes Jaina a moderator by name: found through presence.
    service.run(channelCommand(anduin.session.inWorld, ChannelOp.moderator, "Club", "jaina"), 1);
    assert(service.channels.alliance.find("Club", null).flagsOf(0x40) & MemberFlags.moderator);

    // The player's former node is lost after she handed off. Her channel membership survives.
    context.presence(3, true, [PresenceEntry(0x40, "Jaina", 9, 1, 8, 10, 1, 12, 0, 0, "")], null);
    anduin.read();
    context.presenceLost(2);
    assert(service.channels.alliance.find("Club", null).isOn(0x40) && !anduin.read().length);

    // The current node is lost: Jaina leaves the channel, which Anduin is told.
    context.presenceLost(3);
    assert(!service.channels.alliance.find("Club", null).isOn(0x40));
    assert(anduin.read()[0].body_[0] == ChatNotify.left);

    // Anduin logs out: the channel goes, and nobody is remembered.
    service.run(channelCommand(anduin.session.inWorld, ChannelOp.leaveAll, null), 1);
    assert(service.channels.alliance.count == 0 && service.remembered == 0);
}

/// A replacement host loads the last checkpoint and clears the failed node's disconnected member.
unittest
{
    import dmangos.world.config : WorldConfig;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    void clustered(ref WorldConfig config) { config.cluster.nodeId = 1; }
    auto db = newDatabase();
    auto previous = newCreationContext(db, &clustered), replacement = newCreationContext(db, &clustered);
    previous.nodeId = 1;
    replacement.nodeId = 2;
    previous.regionOwnerAround = (uint, Position, float) => ushort(1);
    replacement.regionOwnerAround = (uint, Position, float) => ushort(2);
    assert(previous.services.start(ServiceKind.channels));
    auto service = previous.channelService;
    auto disconnected = ChannelCommand(7, "Anduin", 1, false, 0, ChannelOp.join, "Club", "", 0);
    auto surviving = ChannelCommand(8, "Jaina", 1, false, 0, ChannelOp.join, "Club", "", 0);
    service.run(disconnected, 1);
    service.run(surviving, 3);
    disconnected.op = ChannelOp.password;
    disconnected.arg = "secret";
    service.run(disconnected, 1);
    const snapshot = db.loadChannelCheckpoint(previous.config.realmId);
    assert(snapshot.node == 1 && snapshot.revision && snapshot.state.length);
    previous.services.release(ServiceKind.channels);

    assert(replacement.services.start(ServiceKind.channels));
    auto recovered = replacement.channelService;
    auto club = recovered.channels.alliance.find("Club", null);
    assert(club !is null && !club.isOn(7) && club.isOn(8) && club.ownerOf == 8);
    auto visitor = ChannelCommand(9, "Tirion", 1, false, 0, ChannelOp.join, "Club", "", 0);
    recovered.run(visitor, 3);
    assert(!club.isOn(9), "the checkpoint kept the channel password");
    const advanced = db.loadChannelCheckpoint(previous.config.realmId);
    assert(advanced.node == 2 && advanced.revision > snapshot.revision);
    service.checkpoint(true);
    assert(db.loadChannelCheckpoint(previous.config.realmId) == advanced, "the old host cannot overwrite recovery");
}

/// Players keep listening and channel controls survive when the channels service changes nodes.
unittest
{
    import dmangos.cluster.protocol : ServiceCall, ServiceReply;
    import dmangos.cluster.services : ServiceKind;
    import dmangos.world.movement : Position;
    import dmangos.world.packets : ClientChannelPassword;
    import dmangos.world.testclient;

    // Two nodes, each its own world; the channels run on node 2.
    auto dbA = newDatabase(), dbB = newDatabase();
    auto a = newCreationContext(dbA), b = newCreationContext(dbB);
    a.nodeId = 1;
    b.nodeId = 2;
    a.services.stopAll();
    a.services.self = 1;
    b.services.self = 2;
    ushort host = 2;
    a.services.placement = b.services.placement = (ServiceKind) => host;
    a.services.sendCall = (ushort node, const ref ServiceCall c) { b.services.receiveCall(1, c); return true; };
    b.services.sendReply = (ushort node, const ref ServiceReply r) { a.services.receiveReply(2, r); return true; };
    b.services.sendCall = (ushort node, const ref ServiceCall c) { a.services.receiveCall(2, c); return true; };
    a.services.sendReply = (ushort node, const ref ServiceReply r) { b.services.receiveReply(1, r); return true; };
    // What node 2's channels tell node 1's players goes there (`DeliverTo`).
    b.deliverRemote = (ushort node, ulong guid, ushort opcode, const(ubyte)[] body_) {
        if (auto who = a.onlinePlayer(guid))
            who.deliver(cast(Opcode) opcode, body_);
    };
    a.deliverRemote = (ushort node, ulong guid, ushort opcode, const(ubyte)[] body_) {
        assert(node == 2);
        if (auto who = b.onlinePlayer(guid))
            who.deliver(cast(Opcode) opcode, body_);
    };

    auto anduin = loggedIn(a, dbA, 7, "Anduin", Position(0, 0, 0));
    auto jaina = loggedIn(b, dbB, 8, "Jaina", Position(0, 0, 0));
    anduin.read();
    jaina.read();
    assert(a.channelService is null && b.channelService !is null, "only node 2 hosts the channels");

    anduin.write(Opcode.CMSG_JOIN_CHANNEL, ClientChannelPassword("Club", ""));
    const joined = anduin.read();
    assert(joined.length && joined[0].opcode == Opcode.SMSG_CHANNEL_NOTIFY && joined[0].body_[0] == ChatNotify.youJoined,
        "the join ran on node 2 and its answer came back to node 1's player");
    jaina.write(Opcode.CMSG_JOIN_CHANNEL, ClientChannelPassword("Club", ""));
    jaina.read();
    anduin.read();
    // Node 2's player speaks: node 1's hears it.
    import dmangos.world.opcodes : ChatType;

    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_CHANNEL, "hello across", "Club"));
    bool heard;
    foreach (p; anduin.read())
        heard = heard || p.opcode == Opcode.SMSG_MESSAGECHAT;
    assert(heard, "said on node 2, heard on node 1");

    b.presence(1, true, [imported!"dmangos.cluster.protocol".PresenceEntry(
        7, "Anduin", 9, 1, 8, 10, 1, 12, 0, 0, "")], null);
    auto service = b.channelService;
    service.run(channelCommand(anduin.session.inWorld, ChannelOp.password, "Club", "secret"), 1);
    service.run(channelCommand(anduin.session.inWorld, ChannelOp.moderator, "Club", "Jaina"), 1);
    service.run(channelCommand(anduin.session.inWorld, ChannelOp.moderate, "Club"), 1);
    auto uther = loggedIn(b, dbB, 9, "Uther", Position(0, 0, 0));
    service.run(channelCommand(uther.session.inWorld, ChannelOp.join, "Club", "secret"), 2);
    service.run(channelCommand(anduin.session.inWorld, ChannelOp.ban, "Club", "Uther"), 1);
    uther.read();
    anduin.read();
    jaina.read();

    const state = b.services.stop(ServiceKind.channels);
    host = 1;
    assert(a.services.start(ServiceKind.channels, state));
    assert(b.channelService is null);
    auto club = a.channelService.channels.alliance.find("CLUB", null);
    assert(club !is null && club.ownerOf == 7 && club.isOn(8) && (club.flagsOf(8) & MemberFlags.moderator),
        "the moved service keeps its owner, members and moderators");
    assert(a.channelService.remembered == 2 && !anduin.read().length && !jaina.read().length);

    jaina.write(Opcode.CMSG_MESSAGECHAT, chatBody(ChatType.CHAT_MSG_CHANNEL, "hello after handoff", "Club"));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MESSAGECHAT));
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_MESSAGECHAT));
    uther.write(Opcode.CMSG_JOIN_CHANNEL, ClientChannelPassword("Club", "secret"));
    assert(!club.isOn(9) && uther.read()[0].body_[0] == ChatNotify.banned);
    auto visitor = loggedIn(a, dbA, 10, "Tirion", Position(0, 0, 0));
    visitor.write(Opcode.CMSG_JOIN_CHANNEL, ClientChannelPassword("Club", ""));
    assert(!club.isOn(10) && visitor.read()[0].body_[0] == ChatNotify.wrongPassword);
}
