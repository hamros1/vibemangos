/**
 * Guilds: a guild's ranks (at least 5, at most 10; rank 0 its
 * master) with their rights, its members with their notes, its message of the day, information and
 * tabard; and the packets that show them. `dmangos.world.guildhandlers` does what players ask.
 *
 * Every guild is kept in memory and in the characters database. In a cluster every node holds them
 * all: a change is written to the database and the other nodes are told to read that guild again
 * (`GuildReload`), and what a guild says to its members (events, chat) reaches its members on the
 * other nodes too (`GuildBroadcast`).
 */
module dmangos.world.guild;

import std.uni : toLower;

import dmangos.bytes : ByteWriter;
import dmangos.world.database : GuildEventRecord, GuildMemberRecord, GuildRankRecord, GuildRecord;

/// The fewest and the most ranks a guild has.
enum uint minRanks = 5, maxRanks = 10;

/// The ranks a new guild starts with.
enum GuildRank : uint
{
    master = 0,
    officer = 1,
    veteran = 2,
    member = 3,
    initiate = 4,
}

/// What a rank may do (bits).
enum GuildRight : uint
{
    empty = 0x40,
    chatListen = 0x41,
    chatSpeak = 0x42,
    officerChatListen = 0x44,
    officerChatSpeak = 0x48,
    promote = 0xC0,
    demote = 0x140,
    invite = 0x50,
    remove = 0x60,
    setMotd = 0x1040,
    editPublicNote = 0x2040,
    viewOfficerNote = 0x4040,
    editOfficerNote = 0x8040,
    modifyInfo = 0x10040,
    all = 0xFF1FF,
}

/// The guild command a `SMSG_GUILD_COMMAND_RESULT` answers.
enum GuildCommand : uint
{
    create = 0x00,
    invite = 0x01,
    quit = 0x03,
    founder = 0x0E,
}

/// The errors of `SMSG_GUILD_COMMAND_RESULT`.
enum GuildError : uint
{
    noMoreInGuild = 0x00,
    internal = 0x01,
    alreadyInGuild = 0x02,
    alreadyInGuildS = 0x03,
    invitedToGuild = 0x04,
    alreadyInvitedS = 0x05,
    nameInvalid = 0x06,
    nameExistsS = 0x07,
    leaderLeave = 0x08,
    permissions = 0x08,
    notInGuild = 0x09,
    notInGuildS = 0x0A,
    playerNotFoundS = 0x0B,
    notAllied = 0x0C,
    rankTooHighS = 0x0D,
    rankTooLowS = 0x0E,
}

/// What a guild's event log records (`GuildEventLogTypes`). The 1.12 client has no way to ask for it: it is the
/// server's, kept in `guild_eventlog` as CMaNGOS keeps it (who invited whom, joined, was promoted or demoted, removed, left).
enum GuildEventLogType : ubyte
{
    invitePlayer = 1,
    joinGuild = 2,
    promotePlayer = 3,
    demotePlayer = 4,
    uninvitePlayer = 5,
    leaveGuild = 6,
}

/// The events a guild's log keeps (`GUILD_EVENTLOG_MAX_RECORDS`, and `Guild.EventLogRecordsCount`'s only value): the
/// rows are a ring of so many places.
enum uint guildEventLogMax = 100;

/// The events of `SMSG_GUILD_EVENT`.
enum GuildEvent : ubyte
{
    promotion = 0x00,
    demotion = 0x01,
    motd = 0x02,
    joined = 0x03,
    left = 0x04,
    removed = 0x05,
    leaderIs = 0x06,
    leaderChanged = 0x07,
    disbanded = 0x08,
    tabardChange = 0x09,
    signedOn = 0x0C,
    signedOff = 0x0D,
}

/// See the module documentation.
final class Guild
{
    GuildRecord record;
    alias record this;

    ///
    this(GuildRecord record)
    {
        this.record = record;
    }

    /// The member `guid` (low guid); null if it is not one.
    inout(GuildMemberRecord)* member(uint guid) inout
    {
        foreach (ref m; record.members)
            if (m.guid == guid)
                return &m;
        return null;
    }

    /// The member called `name` (any case); null if none.
    inout(GuildMemberRecord)* memberNamed(string name) inout
    {
        const wanted = toLower(name);
        foreach (ref m; record.members)
            if (toLower(m.name) == wanted)
                return &m;
        return null;
    }

    /// Whether rank `rank` has `right` (all its bits).
    bool hasRight(uint rank, GuildRight right) const
    {
        foreach (ref r; record.ranks)
            if (r.id == rank)
                return (r.rights & right) == right;
        return false;
    }

    /// The lowest rank (the highest number).
    @property uint lowestRank() const
    {
        return record.ranks.length ? cast(uint) record.ranks.length - 1 : GuildRank.initiate;
    }

    /**
     * An event for its log (`LogGuildEvent`): in the place after the newest one's (a ring of `guildEventLogMax`), the
     * oldest dropped once there are that many. The caller saves it (`WorldDatabase.saveGuildEvent`).
     */
    GuildEventRecord logEvent(GuildEventLogType type, uint player1, uint player2, ubyte newRank, long now)
    {
        const last = record.events.length ? record.events[$ - 1].logGuid : 0;
        auto e = GuildEventRecord((last + 1) % guildEventLogMax, type, player1, player2, newRank, now);
        if (record.events.length >= guildEventLogMax)
            record.events = record.events[1 .. $];
        record.events ~= e;
        return e;
    }

    /// Who last invited `player` (low guid), by the log (`GetGuildInviter`); 0 if nobody did.
    uint inviterOf(uint player) const
    {
        foreach_reverse (ref e; record.events)
            if (e.type == GuildEventLogType.invitePlayer && e.player2 == player)
                return e.player1;
        return 0;
    }

    unittest
    {
        // The ring: after the 99th place the 0th, the oldest event dropped past 100.
        auto g = new Guild(GuildRecord.init);
        foreach (i; 0 .. 150)
            g.logEvent(GuildEventLogType.joinGuild, i, 0, 0, i);
        assert(g.events.length == guildEventLogMax && g.events[0].player1 == 50 && g.events[$ - 1].player1 == 149);
        assert(g.events[$ - 1].logGuid == 150 % 100 && g.events[49].logGuid == 0);
    }

    /// How many accounts its members belong to.
    @property uint accountCount() const
    {
        bool[uint] accounts;
        foreach (ref m; record.members)
            accounts[m.account] = true;
        return cast(uint) accounts.length;
    }

    /// The ranks a new guild starts with, named, with their rights.
    static GuildRankRecord[] defaultRanks()
    {
        with (GuildRight)
            return [GuildRankRecord(0, "Guild Master", all), GuildRankRecord(1, "Officer", all),
                GuildRankRecord(2, "Veteran", chatListen | chatSpeak), GuildRankRecord(3, "Member", chatListen | chatSpeak),
                GuildRankRecord(4, "Initiate", chatListen | chatSpeak)];
    }

    /// `SMSG_GUILD_QUERY_RESPONSE`: its name, ten rank names, its tabard.
    const(ubyte)[] queryResponse() const
    {
        ByteWriter w;
        w.put(record.id);
        w.putCString(record.name);
        foreach (i; 0 .. maxRanks)
            w.putCString(i < record.ranks.length ? record.ranks[i].name : "");
        foreach (part; record.emblem)
            w.put(part);
        return w.data;
    }
}

/// `SMSG_GUILD_EVENT`: `event` with up to three strings, and a guid (0: none).
const(ubyte)[] guildEventPacket(GuildEvent event, const(string)[] strings, ulong guid = 0)
{
    ByteWriter w;
    w.put(cast(ubyte) event);
    w.put(cast(ubyte) strings.length);
    foreach (s; strings)
        w.putCString(s);
    if (guid)
        w.put(guid);
    return w.data;
}

/// `SMSG_GUILD_COMMAND_RESULT`
const(ubyte)[] guildCommandResult(GuildCommand command, string text, GuildError result)
{
    ByteWriter w;
    w.put(cast(uint) command);
    w.putCString(text);
    w.put(cast(uint) result);
    return w.data;
}

/// The guilds of the server.
final class Guilds
{
    private Guild[uint] byId;
    private uint[string] byName;   // lower-case name -> id
    private uint[uint] memberOf;   // member low guid -> guild id

    /// Every guild as saved.
    void load(const(GuildRecord)[] records)
    {
        byId = null;
        byName = null;
        memberOf = null;
        foreach (ref r; records)
            put(new Guild(cast(GuildRecord) r));
    }

    /// One guild as saved now (another node changed it); null `record` (`isNull`): it is gone.
    void replace(uint id, Guild guild)
    {
        remove(id);
        if (guild !is null)
            put(guild);
    }

    /// Adds a guild (made, or read).
    void put(Guild guild)
    {
        byId[guild.id] = guild;
        byName[toLower(guild.name)] = guild.id;
        foreach (ref m; guild.members)
            memberOf[m.guid] = guild.id;
    }

    /// A guild gone from memory.
    void remove(uint id)
    {
        if (auto g = id in byId)
        {
            byName.remove(toLower(g.name));
            foreach (ref m; g.members)
                if (memberOf.get(m.guid, 0) == id)
                    memberOf.remove(m.guid);
            byId.remove(id);
        }
    }

    /// A member joined or left `guild` (its index is kept up to date).
    void memberJoined(Guild guild, uint member)
    {
        memberOf[member] = guild.id;
    }

    /// ditto
    void memberLeft(uint member)
    {
        memberOf.remove(member);
    }

    /// The guild `id`; null if none.
    Guild find(uint id)
    {
        return byId.get(id, null);
    }

    /// The guild called `name` (any case); null if none.
    Guild named(string name)
    {
        if (const id = toLower(name) in byName)
            return byId.get(*id, null);
        return null;
    }

    /// The guild of character `member` (low guid); null if it has none.
    Guild of(uint member)
    {
        if (const id = member in memberOf)
            return byId.get(*id, null);
        return null;
    }

    /// How many guilds there are.
    @property size_t count() const
    {
        return byId.length;
    }
}

unittest
{
    GuildRecord r;
    r.id = 3;
    r.name = "Knights";
    r.ranks = Guild.defaultRanks();
    r.members = [GuildMemberRecord(7, GuildRank.master, "", "", "Anduin"), GuildMemberRecord(8, GuildRank.initiate,
        "", "", "Jaina")];
    auto guilds = new Guilds;
    guilds.load([r]);
    auto g = guilds.named("knights");
    assert(g !is null && guilds.of(8) is g && guilds.of(9) is null);
    assert(g.hasRight(GuildRank.officer, GuildRight.setMotd) && !g.hasRight(GuildRank.member, GuildRight.invite));
    assert(g.hasRight(GuildRank.initiate, GuildRight.chatSpeak) && g.memberNamed("JAINA").guid == 8);
    assert(g.queryResponse()[4 .. 12] == cast(const(ubyte)[]) "Knights\0");
    assert(guildEventPacket(GuildEvent.motd, ["Hello"]) == [2, 1, 'H', 'e', 'l', 'l', 'o', 0]);
}
