/**
 * Chat channels (CMaNGOS `Chat/Channel.cpp`, `ChannelMgr.cpp`).
 *
 * `Channels` is one team's set of channels (`ChannelMgr`); there is one per
 * team, or one for everybody with `allow_two_side_interaction_channel`. A
 * channel exists while somebody is in it. The built-in ones of
 * `ChatChannels.dbc` (General, Trade, LocalDefense, ...) have no owner and
 * announce nobody; a custom channel's first member owns it.
 *
 * The client joins the built-in channels by itself after logging in, naming
 * them after its zone ("General - Elwynn Forest"). When the zone changes,
 * the server moves the player to the new zone's channels
 * (`Player::UpdateLocalChannels`).
 *
 * Every reply is an `SMSG_CHANNEL_NOTIFY`: a `ChatNotify` code, the channel's
 * name, and what the code needs (`notice`).
 *
 * Members are `ChannelMember`s, which may be on another node of a cluster: the
 * channels are a cluster service (`dmangos.world.channelservice`).
 */
module dmangos.world.channel;

import std.algorithm.iteration : filter;
import std.algorithm.sorting : sort;
import std.array : array, replace;
import std.uni : toLower;

import dmangos.bytes : ByteWriter;
import dmangos.world.clientdata : ChatChannelsEntry, ClientData, Team;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.queries : chatMessage;

/// `ChatNotify`
enum ChatNotify : ubyte
{
    joined = 0x00,           /// "%s joined channel."
    left = 0x01,             /// "%s left channel."
    youJoined = 0x02,        /// "Joined Channel: [%s]"
    youLeft = 0x03,          /// "Left Channel: [%s]"
    wrongPassword = 0x04,
    notMember = 0x05,
    notModerator = 0x06,
    passwordChanged = 0x07,
    ownerChanged = 0x08,
    playerNotFound = 0x09,
    notOwner = 0x0A,
    channelOwner = 0x0B,
    modeChange = 0x0C,
    announcementsOn = 0x0D,
    announcementsOff = 0x0E,
    moderationOn = 0x0F,
    moderationOff = 0x10,
    muted = 0x11,
    playerKicked = 0x12,
    banned = 0x13,
    playerBanned = 0x14,
    playerUnbanned = 0x15,
    playerNotBanned = 0x16,
    playerAlreadyMember = 0x17,
    invite = 0x18,
    inviteWrongFaction = 0x19,
    wrongFaction = 0x1A,
    invalidName = 0x1B,
    notModerated = 0x1C,
    playerInvited = 0x1D,
    playerInviteBanned = 0x1E,
    throttled = 0x1F,
}

/// `Channel::ChannelFlags`, as the client sees them.
enum ChannelFlags : ubyte
{
    none = 0x00,
    custom = 0x01,
    trade = 0x04,
    notLfg = 0x08,
    general = 0x10,
    city = 0x20,
    lfg = 0x40,
}

/// `Channel::ChannelDBCFlags`
enum ChannelDbcFlags : uint
{
    initial = 0x00001,
    zoneDependent = 0x00002,
    global = 0x00004,
    trade = 0x00008,
    cityOnly = 0x00010,
    cityOnly2 = 0x00020,
    defense = 0x10000,
    guildRequired = 0x20000,
    lfg = 0x40000,
}

/// `Channel::ChannelMemberFlags`
enum MemberFlags : ubyte
{
    none = 0x00,
    owner = 0x01,
    moderator = 0x02,
    voiced = 0x04,
    muted = 0x08,
    custom = 0x10,
}

/// A channel member, on this node or (in a cluster) another: what the channels need of a player.
interface ChannelMember
{
    @property ulong guid() const;
    @property string name() const;
    @property ubyte race() const;

    /// ArcEmu's `c` permission: it moderates every channel but the built-in ones.
    @property bool moderatesAll() const;

    /// The visual honor rank (-4 to 14): the defense channels need one (`SPEAK_IN_*DEFENSE_RANK`).
    @property byte pvpRank() const;

    void deliver(Opcode opcode, const(ubyte)[] body_);
}

/// Finds the players online, as members: by guid, or by name in any case; null if none.
interface MemberDirectory
{
    ChannelMember member(ulong guid);
    ChannelMember member(string name);
}

/// The channel settings of `mangosd.conf`.
struct ChannelSettings
{
    bool crossFaction;                                   /// `AllowTwoSide.Interaction.Channel`
}

/**
 * An `SMSG_CHANNEL_NOTIFY` body: the code, the channel's name, then each extra value: a guid
 * (`ulong`), a name (`string`), or a number.
 */
ubyte[] notice(Args...)(ChatNotify type, string channel, Args extra)
{
    ByteWriter w;
    w.put(cast(ubyte) type);
    w.putCString(channel);
    foreach (value; extra)
    {
        static if (is(typeof(value) : string))
            w.putCString(value);
        else
            w.put(value);
    }
    return w.data.dup;
}

/// See the module documentation.
final class Channel
{
    immutable string name;
    private
    {
        Channels owner_;
        const(ChatChannelsEntry)* entry;  // null for a custom channel
        ubyte flags;
        string password;
        ulong ownerGuid;
        MemberFlags[ulong] players;
        bool[ulong] bannedGuids;
        bool announcements;
        bool moderation;
    }

    private this(Channels owner, string name, const(ChatChannelsEntry)* entry)
    {
        this.owner_ = owner;
        this.name = name;
        this.entry = entry;
        if (entry !is null)
        {
            // Built-in: no announcements, and the client's flags from the DBC's.
            flags = ChannelFlags.general;
            if (entry.flags & ChannelDbcFlags.trade)
                flags |= ChannelFlags.trade;
            if (entry.flags & ChannelDbcFlags.cityOnly2)
                flags |= ChannelFlags.city;
            flags |= entry.flags & ChannelDbcFlags.lfg ? ChannelFlags.lfg : ChannelFlags.notLfg;
        }
        else
        {
            announcements = true;
            flags = ChannelFlags.custom;
        }
    }

    /// `IsConstant`: a built-in channel.
    @property bool isConstant() const
    {
        return entry !is null;
    }

    /// The `ChatChannels.dbc` entry, or null.
    @property const(ChatChannelsEntry)* channelEntry() const
    {
        return entry;
    }

    /// Number of players in the channel.
    @property size_t population() const
    {
        return players.length;
    }

    /// Whether the player is in the channel.
    bool isOn(ulong guid) const
    {
        return (guid in players) !is null;
    }

    /// The owner, or 0.
    @property ulong ownerOf() const
    {
        return ownerGuid;
    }

    /// The member's flags.
    MemberFlags flagsOf(ulong guid) const
    {
        return players.get(guid, MemberFlags.none);
    }

    /// `Channel::Join`
    void join(ChannelMember player, string pass)
    {
        const guid = player.guid;
        if (isOn(guid))
        {
            if (!isConstant)
                notify(player, ChatNotify.playerAlreadyMember, guid);
            return;
        }
        if (guid in bannedGuids)
            return notify(player, ChatNotify.banned);
        if (password.length && pass != password)
            return notify(player, ChatNotify.wrongPassword);

        if (announcements)
            sendToAll(notice(ChatNotify.joined, name, guid));
        // ArcEmu's Channel::AttemptJoin: the `c` permission moderates every channel but the built-in ones.
        players[guid] = !isConstant && player.moderatesAll ? MemberFlags.moderator : MemberFlags.none;
        owner_.joined(guid, this);
        notify(player, ChatNotify.youJoined, uint(flags), uint(0));
        if (!isConstant && ownerGuid == 0)
            setOwner(guid, players.length > 1);
    }

    /// `Channel::Leave`; `tell` is false when the client already knows (logging out, changing zone).
    void leave(ChannelMember player, bool tell = true)
    {
        const guid = player.guid;
        if (!isOn(guid))
        {
            if (tell)
                notify(player, ChatNotify.notMember);
            return;
        }
        if (tell)
            notify(player, ChatNotify.youLeft);
        const wasOwner = (players[guid] & MemberFlags.owner) != 0;
        players.remove(guid);
        owner_.left(guid, this);
        if (announcements)
            sendToAll(notice(ChatNotify.left, name, guid));
        if (wasOwner && !isConstant)
            setOwner(selectNewOwner(), players.length > 1);
    }

    /// `Channel::KickOrBan`
    void kickOrBan(ChannelMember player, string targetName, bool ban)
    {
        const guid = player.guid;
        if (!checkModerator(player))
            return;
        auto target = memberNamed(player, targetName);
        if (target is null)
            return;
        const targetGuid = target.guid;
        const ownerLeaves = ownerGuid == targetGuid;
        if (ownerLeaves && guid != ownerGuid)
            return notify(player, ChatNotify.notOwner);
        if (ban && targetGuid !in bannedGuids)
        {
            bannedGuids[targetGuid] = true;
            sendToAll(notice(ChatNotify.playerBanned, name, targetGuid, guid));
        }
        else
            sendToAll(notice(ChatNotify.playerKicked, name, targetGuid, guid));
        players.remove(targetGuid);
        owner_.left(targetGuid, this);
        if (ownerLeaves && !isConstant)
            setOwner(selectNewOwner(), players.length > 1);
    }

    /// `Channel::UnBan`
    void unban(ChannelMember player, string targetName)
    {
        if (!checkModerator(player))
            return;
        auto target = owner_.directory.member(targetName);
        if (target is null)
            return notify(player, ChatNotify.playerNotFound, targetName);
        const targetGuid = target.guid;
        if (targetGuid !in bannedGuids)
            return notify(player, ChatNotify.playerNotBanned, targetName);
        bannedGuids.remove(targetGuid);
        sendToAll(notice(ChatNotify.playerUnbanned, name, targetGuid, player.guid));
    }

    /// `Channel::SetPassword`
    void setPassword(ChannelMember player, string pass)
    {
        if (!checkModerator(player))
            return;
        password = pass;
        sendToAll(notice(ChatNotify.passwordChanged, name, player.guid));
    }

    /// `Channel::SetModeFlags` for a player: moderator or muted.
    void setModeFlags(ChannelMember player, string targetName, MemberFlags flag, bool set)
    in (flag == MemberFlags.moderator || flag == MemberFlags.muted)
    {
        const guid = player.guid;
        if (!checkModerator(player))
            return;
        auto target = owner_.directory.member(targetName);
        if (target is null)
            return notify(player, ChatNotify.playerNotFound, targetName);
        const targetGuid = target.guid;
        if (flag == MemberFlags.moderator && guid == ownerGuid && targetGuid == ownerGuid)
            return;
        if (!isOn(targetGuid) || !owner_.sameTeam(player, target))
            return notify(player, ChatNotify.playerNotFound, targetName);
        if (ownerGuid == targetGuid && ownerGuid != guid)
            return notify(player, ChatNotify.notOwner);
        setMemberFlag(targetGuid, flag, set);
    }

    /// `Channel::SetOwner` for a player.
    void setOwner(ChannelMember player, string targetName)
    {
        const guid = player.guid;
        if (!isOn(guid))
            return notify(player, ChatNotify.notMember);
        if (guid != ownerGuid)
            return notify(player, ChatNotify.notOwner);
        auto target = owner_.directory.member(targetName);
        if (target is null || !isOn(target.guid) || !owner_.sameTeam(player, target))
            return notify(player, ChatNotify.playerNotFound, targetName);
        setOwner(target.guid, players.length > 1);
    }

    /// `Channel::SendChannelOwnerResponse`: the owner's name, or "Nobody".
    void sendOwner(ChannelMember player)
    {
        if (!isOn(player.guid))
            return notify(player, ChatNotify.notMember);
        // CMaNGOS writes the asking player's guid here, so the client always names the asker; this sends
        // the owner, as the message means.
        string ownerName = "Nobody";
        if (ownerGuid)
        {
            auto found = owner_.directory.member(ownerGuid);
            ownerName = found is null ? "PLAYER_NOT_FOUND" : found.name;
        }
        notify(player, ChatNotify.channelOwner, ownerName);
    }

    /// `Channel::SendChannelListResponse`: the members, each with its flags.
    void sendList(ChannelMember player)
    {
        if (!isOn(player.guid))
            return notify(player, ChatNotify.notMember);
        ByteWriter w;
        w.putCString(name);
        w.put(flags);
        const listed = memberGuids.filter!(guid => owner_.directory.member(guid) !is null).array;
        w.put(cast(uint) listed.length);
        foreach (guid; listed)
        {
            w.put(guid);
            w.put(cast(ubyte) players[guid]);
        }
        player.deliver(Opcode.SMSG_CHANNEL_LIST, w.data);
    }

    /// `Channel::ToggleAnnouncements`
    void toggleAnnouncements(ChannelMember player)
    {
        if (!checkModerator(player))
            return;
        announcements = !announcements;
        sendToAll(notice(announcements ? ChatNotify.announcementsOn : ChatNotify.announcementsOff, name,
            player.guid));
    }

    /// `Channel::ToggleModeration`
    void toggleModeration(ChannelMember player)
    {
        // ArcEmu's Channel::Moderate: moderators, and anyone with the `c` permission.
        if (!checkModerator(player, player.moderatesAll))
            return;
        moderation = !moderation;
        sendToAll(notice(moderation ? ChatNotify.moderationOn : ChatNotify.moderationOff, name,
            player.guid));
    }

    /// `Channel::Say`
    void say(ChannelMember player, string text, Language language, ubyte chatTag)
    {
        const guid = player.guid;
        if (!isOn(guid))
            return notify(player, ChatNotify.notMember);
        // `SPEAK_IN_LOCALDEFENSE_RANK` and `SPEAK_IN_WORLDDEFENSE_RANK`: LocalDefense needs a rank of 0 (none of
        // the dishonored ranks), WorldDefense 11 (Knight-Captain, Legionnaire).
        enum uint localDefense = 22, worldDefense = 23;
        if ((players[guid] & MemberFlags.muted) || (entry !is null && ((entry.channelId == worldDefense
            && player.pvpRank < 11) || (entry.channelId == localDefense && player.pvpRank < 0))))
            return notify(player, ChatNotify.muted);
        if (moderation && !(players[guid] & MemberFlags.moderator))
            return notify(player, ChatNotify.notModerator);
        if (owner_.settings.crossFaction)
            language = Language.LANG_UNIVERSAL;
        sendToAll(chatMessage(ChatType.CHAT_MSG_CHANNEL, language, guid, text, chatTag, name), Opcode.SMSG_MESSAGECHAT);
    }

    /// `Channel::Invite`
    void invite(ChannelMember player, string targetName)
    {
        const guid = player.guid;
        if (!isOn(guid))
            return notify(player, ChatNotify.notMember);
        auto target = owner_.directory.member(targetName);
        if (target is null)
            return notify(player, ChatNotify.playerNotFound, targetName);
        const targetGuid = target.guid;
        if (isOn(targetGuid))
            return notify(player, ChatNotify.playerAlreadyMember, targetGuid);
        if (targetGuid in bannedGuids)
            return notify(player, ChatNotify.playerInviteBanned, targetName);
        if (!owner_.sameTeam(player, target))
            return notify(player, ChatNotify.inviteWrongFaction);
        notify(target, ChatNotify.invite, guid);
        notify(player, ChatNotify.playerInvited, targetName);
    }

private:
    /// Tells `player` something about this channel: an `SMSG_CHANNEL_NOTIFY` with the extra values of `notice`.
    void notify(Args...)(ChannelMember player, ChatNotify type, Args extra)
    {
        player.deliver(Opcode.SMSG_CHANNEL_NOTIFY, notice(type, name, extra));
    }

    /// The members in guid order, as CMaNGOS's `std::map` keeps them.
    ulong[] memberGuids() const
    {
        auto guids = players.keys;
        guids.sort();
        return guids;
    }

    /// In the channel, and a moderator (or `anyway`); otherwise tells the player why not.
    bool checkModerator(ChannelMember player, bool anyway = false)
    {
        const guid = player.guid;
        if (!isOn(guid))
        {
            notify(player, ChatNotify.notMember);
            return false;
        }
        if (!(players[guid] & MemberFlags.moderator) && !anyway)
        {
            notify(player, ChatNotify.notModerator);
            return false;
        }
        return true;
    }

    /// The online member called `targetName`, or null after telling the player it was not found.
    ChannelMember memberNamed(ChannelMember player, string targetName)
    {
        auto target = owner_.directory.member(targetName);
        if (target is null || !isOn(target.guid))
        {
            notify(player, ChatNotify.playerNotFound, targetName);
            return null;
        }
        return target;
    }

    ulong selectNewOwner() const
    {
        const guids = memberGuids;
        foreach (guid; guids)
            if (players[guid] & MemberFlags.moderator)
                return guid;
        return guids.length ? guids[0] : 0;
    }

    void setMemberFlag(ulong guid, MemberFlags flag, bool set)
    {
        auto current = guid in players;
        if (current is null || ((*current & flag) != 0) == set)
            return;
        const old = *current;
        *current = cast(MemberFlags)(set ? old | flag : old & ~flag);
        sendToAll(notice(ChatNotify.modeChange, name, guid, cast(ubyte) old, cast(ubyte) *current));
    }

    /// `Channel::SetOwner(guid)`: the old owner stays a moderator, the new one becomes both.
    void setOwner(ulong guid, bool exclaim)
    {
        if (ownerGuid)
            if (auto previous = ownerGuid in players)
            {
                const old = *previous;
                *previous = cast(MemberFlags)((guid ? old | MemberFlags.moderator : old & ~MemberFlags.moderator)
                    & ~MemberFlags.owner);
                sendToAll(notice(ChatNotify.modeChange, name, ownerGuid, cast(ubyte) old, cast(ubyte) *previous));
            }
        ownerGuid = guid;
        if (guid)
        {
            const old = players.get(guid, MemberFlags.none);
            players[guid] = cast(MemberFlags)(old | MemberFlags.moderator | MemberFlags.owner);
            sendToAll(notice(ChatNotify.modeChange, name, guid, cast(ubyte) old, cast(ubyte) players[guid]));
        }
        if (exclaim)
            sendToAll(notice(ChatNotify.ownerChanged, name, guid));
    }

    void sendToAll(const(ubyte)[] body_, Opcode opcode = Opcode.SMSG_CHANNEL_NOTIFY)
    {
        foreach (guid; memberGuids)
            if (auto member = owner_.directory.member(guid))
                member.deliver(opcode, body_);
    }
}

/// See the module documentation.
final class Channels
{
    package
    {
        MemberDirectory directory;
        const ClientData client;
        ChannelSettings settings;
    }
    private
    {
        Channel[dstring] byName;          // by lower-cased name
        Channel[][ulong] joinedBy;        // player guid -> the channels it is in
    }

    ///
    this(MemberDirectory directory, const ClientData client, ChannelSettings settings)
    in (directory !is null && client !is null)
    {
        this.directory = directory;
        this.client = client;
        this.settings = settings;
    }

    /// `ChannelMgr::GetJoinChannel`: the channel, created if needed.
    Channel getOrCreate(string name)
    {
        const key = keyOf(name);
        if (auto found = key in byName)
            return *found;
        auto channel = new Channel(this, name, client.chatChannelFor(name));
        byName[key] = channel;
        return channel;
    }

    /// `ChannelMgr::GetChannel`: the channel, or null after telling `player` it is not in it.
    Channel find(string name, ChannelMember player)
    {
        if (auto found = keyOf(name) in byName)
            return *found;
        if (player !is null)
            player.deliver(Opcode.SMSG_CHANNEL_NOTIFY, notice(ChatNotify.notMember, name));
        return null;
    }

    /// The channels a player is in.
    const(Channel)[] channelsOf(ulong guid) const
    {
        return joinedBy.get(guid, null);
    }

    /// Number of channels.
    @property size_t count() const
    {
        return byName.length;
    }

    /// `ChannelMgr::LeftChannel`: a channel nobody is in goes away.
    void leftChannel(string name)
    {
        const key = keyOf(name);
        if (auto found = key in byName)
            if (found.population == 0)
                byName.remove(key);
    }

    /// `Player::CleanupChannels`: logging out leaves every channel without telling the client.
    void leaveAll(ChannelMember player)
    {
        foreach (channel; joinedBy.get(player.guid, null).dup)
        {
            channel.leave(player, false);
            leftChannel(channel.name);
        }
        joinedBy.remove(player.guid);
    }

    /**
     * `Player::UpdateLocalChannels`: after a zone change, the zone channels the player is in are
     * replaced by those of the new zone ("General - Elwynn Forest" by "General - Westfall").
     */
    void zoneChanged(ChannelMember player, string zoneName)
    {
        if (zoneName.length == 0)
            return;
        foreach (channel; joinedBy.get(player.guid, null).dup)
        {
            const entry = channel.channelEntry;
            if (entry is null || (entry.flags & ChannelDbcFlags.global))
                continue;
            auto replacement = getOrCreate(entry.pattern[0].replace("%s", zoneName));
            if (replacement is channel)
                continue;
            replacement.join(player, "");
            channel.leave(player, false);
            leftChannel(channel.name);
        }
    }

    /// Whether two players may meet in a channel (`Player::GetTeam` comparisons).
    bool sameTeam(const ChannelMember a, const ChannelMember b) const
    {
        return settings.crossFaction
            || client.teamForRace(a.race) == client.teamForRace(b.race);
    }

private:
    static dstring keyOf(string name)
    {
        import std.conv : to;

        return name.toLower.to!dstring;
    }

    void joined(ulong guid, Channel channel)
    {
        joinedBy[guid] ~= channel;
    }

    void left(ulong guid, Channel channel)
    {
        import std.algorithm.mutation : remove;

        if (auto list = guid in joinedBy)
        {
            *list = (*list).remove!(c => c is channel);
            if (list.length == 0)
                joinedBy.remove(guid);
        }
    }
}

/// The team's channel manager, or the shared one (`channelMgr(Team)`).
struct ChannelManagers
{
    Channels alliance;
    Channels horde;

    /// The channels of `team`; with cross-faction channels, everybody shares the Alliance set.
    Channels forTeam(Team team)
    {
        return team == Team.horde && !alliance.settings.crossFaction ? horde : alliance;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : chatChannelsFormat;
    import dmangos.world.testdata : testClientData;

    final class TestMember : ChannelMember
    {
        ulong guid_;
        string name_;
        Opcode[] received;
        const(ubyte)[][] bodies;

        this(ulong guid, string name)
        {
            guid_ = guid;
            name_ = name;
        }

        @property ulong guid() const { return guid_; }
        @property string name() const { return name_; }
        @property ubyte race() const { return 1; }
        @property bool moderatesAll() const { return false; }
        byte rank;
        @property byte pvpRank() const { return rank; }
        void deliver(Opcode opcode, const(ubyte)[] body_) { received ~= opcode; bodies ~= body_.dup; }

        Opcode[] take()
        {
            auto got = received;
            received = null;
            bodies = null;
            return got;
        }
    }

    final class TestDirectory : MemberDirectory
    {
        TestMember[ulong] players;
        ChannelMember member(ulong guid) { return players.get(guid, null); }
        ChannelMember member(string name)
        {
            foreach (p; players)
                if (p.name.toLower == name.toLower)
                    return p;
            return null;
        }
    }

    /// Client data with General ("General - %s", zone dependent) and WorldDefense (global).
    ClientData channelClientData()
    {
        auto client = testClientData();
        const ubyte[] strings = cast(const(ubyte)[]) "\0General - %s\0WorldDefense\0";
        uint[] general = new uint[chatChannelsFormat.length], defense = new uint[chatChannelsFormat.length];
        general[0] = 1;
        general[1] = ChannelDbcFlags.initial | ChannelDbcFlags.zoneDependent;
        general[3] = 1;
        defense[0] = 23;
        defense[1] = ChannelDbcFlags.global | ChannelDbcFlags.defense;
        defense[3] = 14;
        client.chatChannels = typeof(client.chatChannels).parse(buildDbc(chatChannelsFormat, [general, defense],
            strings), "ChatChannels.dbc");
        return client;
    }
}

/// A custom channel: its first member owns it; joins, chat, moderation, kicks and bans.
unittest
{
    auto directory = new TestDirectory;
    auto channels = new Channels(directory, channelClientData(), ChannelSettings.init);
    auto anduin = new TestMember(1, "Anduin"), jaina = new TestMember(2, "Jaina"), varian = new TestMember(3, "Varian");
    foreach (p; [anduin, jaina, varian])
        directory.players[p.guid] = p;

    auto club = channels.getOrCreate("Club");
    assert(!club.isConstant);
    club.join(anduin, "");
    assert(anduin.take() == [Opcode.SMSG_CHANNEL_NOTIFY, Opcode.SMSG_CHANNEL_NOTIFY], "you joined, mode change");
    assert(club.ownerOf == 1 && club.flagsOf(1) == (MemberFlags.owner | MemberFlags.moderator));

    club.join(jaina, "");
    assert(anduin.take() == [Opcode.SMSG_CHANNEL_NOTIFY] && jaina.take() == [Opcode.SMSG_CHANNEL_NOTIFY]);

    // Only moderators set passwords; then a wrong password keeps Varian out.
    club.setPassword(jaina, "secret");
    assert(jaina.bodies[0][0] == ChatNotify.notModerator);
    club.setPassword(anduin, "secret");
    club.join(varian, "wrong");
    assert(varian.bodies[0][0] == ChatNotify.wrongPassword && !club.isOn(3));

    // Chat reaches every member.
    anduin.take();
    jaina.take();
    club.say(jaina, "hello", Language.LANG_COMMON, 0);
    assert(anduin.take() == [Opcode.SMSG_MESSAGECHAT] && jaina.take() == [Opcode.SMSG_MESSAGECHAT]);

    // Muting Jaina; then a ban, which also removes her.
    club.setModeFlags(anduin, "Jaina", MemberFlags.muted, true);
    club.say(jaina, "hello", Language.LANG_COMMON, 0);
    assert(jaina.bodies[$ - 1][0] == ChatNotify.muted);
    club.kickOrBan(anduin, "Jaina", true);
    assert(!club.isOn(2) && channels.channelsOf(2).length == 0);
    club.join(jaina, "secret");
    assert(jaina.bodies[$ - 1][0] == ChatNotify.banned);

    // When the owner leaves, the next member takes over; the last one out removes the channel.
    club.unban(anduin, "Jaina");
    club.join(jaina, "secret");
    club.leave(anduin);
    assert(club.ownerOf == 2);
    channels.leaveAll(jaina);
    channels.leftChannel("Club");
    assert(channels.find("club", null) is null && channels.count == 0);
}

/// Built-in channels: no owner, no announcements, and zone channels follow the zone.
unittest
{
    auto directory = new TestDirectory;
    auto channels = new Channels(directory, channelClientData(), ChannelSettings.init);
    auto anduin = new TestMember(1, "Anduin"), jaina = new TestMember(2, "Jaina");
    directory.players[1] = anduin;
    directory.players[2] = jaina;

    auto general = channels.getOrCreate("General - Elwynn Forest");
    assert(general.isConstant && general.channelEntry.channelId == 1);
    general.join(anduin, "");
    general.join(jaina, "");
    assert(anduin.take() == [Opcode.SMSG_CHANNEL_NOTIFY], "only its own join notice");
    assert(general.ownerOf == 0);

    channels.zoneChanged(anduin, "Westfall");
    auto westfall = channels.find("General - Westfall", null);
    assert(westfall !is null && westfall.isOn(1) && !general.isOn(1));
    assert(channels.channelsOf(1).length == 1);

    // WorldDefense needs a PvP rank nobody has yet.
    auto defense = channels.getOrCreate("WorldDefense");
    defense.join(anduin, "");
    anduin.take();
    defense.say(anduin, "help", Language.LANG_COMMON, 0);
    assert(anduin.bodies[0][0] == ChatNotify.muted);
}
