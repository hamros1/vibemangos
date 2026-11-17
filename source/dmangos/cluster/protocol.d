/**
 * The messages nodes of a cluster send each other, and how they are framed (docs/CLUSTER.md).
 *
 * A frame is a 16-byte header, then the payload:
 *
 * ---
 * uint   length    payload bytes
 * ushort type      MessageType
 * ushort flags     0 for now
 * ulong  sequence  per sender incarnation and receiver, from 1; 0 during the handshake
 * ---
 *
 * Payloads are plain structs (de)serialized by `dmangos.serialization`, little-endian like the
 * client protocol. Frames are written into a buffer the link reuses and read in place, so a message
 * made only of numbers (a heartbeat) costs no allocation either way.
 */
module dmangos.cluster.protocol;

import std.exception : enforce;

import dmangos.bytes : ByteReader, ByteWriter, PacketException;
import dmangos.cluster.ownership : IdKind;
import dmangos.cluster.regions : Region;
import dmangos.serialization : deserialize, LengthPrefix, serialize;

/// Changes whenever a message changes; nodes speaking another version are turned away.
enum ushort protocolVersion = 22;

/// Size of a frame header.
enum frameHeaderSize = 16;

/// The largest payload accepted: a bound on what a broken or hostile peer can make a node buffer.
enum maxPayload = 16 * 1024 * 1024;

/// What a frame holds.
enum MessageType : ushort
{
    hello = 1,
    reject = 2,
    heartbeat = 3,
    view = 4,
    regionTable = 5,
    regionReleased = 6,
    idRequest = 7,
    idGrant = 8,
    idReport = 9,
    interestUpdate = 10,
    replicaCreate = 11,
    replicaValues = 12,
    replicaMove = 13,
    replicaRemove = 14,
    sessionClaim = 15,
    sessionGrant = 16,
    sessionEvict = 17,
    sessionReleased = 18,
    regionHandover = 19,
    player = 20,
    inRange = 21,
    presence = 22,
    deliverTo = 23,
    whisper = 24,
    stockRequest = 25,
    stockReply = 26,
    stockRelease = 27,
    channelCommand = 28,
    groupCommand = 29,
    groupState = 30,
    memberStatsRequest = 31,
    toEveryone = 32,
    gmRemote = 33,
    drain = 34,
    regionLoads = 35,
    takeover = 36,
    takeoverAccepted = 37,
    killShare = 38,
    scriptSignal = 39,
    dungeonEntryRequest = 40,
    dungeonEntryReply = 41,
}

/// Why a hello was refused.
enum RejectReason : ubyte
{
    none = 0,             /// not refused
    wrongCluster = 1,     /// another cluster's name
    wrongProtocol = 2,    /// another protocol version
    staleIncarnation = 3, /// an older start of a node that has since restarted: fenced out
    duplicateNode = 4,    /// the node id is this node's, or another live process's
    unexpectedNode = 5,   /// not the node that was dialed
    notInView = 6,        /// a member the coordinator has not admitted
}

/// A frame's header.
struct FrameHeader
{
    uint length;
    MessageType type;
    ushort flags;
    ulong sequence;
}

/// The first message each way on a link: who the sender is.
struct Hello
{
    enum type = MessageType.hello;

    ushort protocol = protocolVersion;
    @LengthPrefix!ubyte string cluster;
    ushort nodeId;
    ulong incarnation;      /// larger for every start of the process
    @LengthPrefix!ubyte string address; /// "host:port" others dial it at
    @LengthPrefix!ubyte string clientAddress; /// "host:port" clients connect to (phase 3b)
    bool coordinator;       /// whether the sender is the coordinator
    ushort expected;        /// the node the dialer meant to reach; 0 for the coordinator
}

/// The reply to a hello that is refused; the link closes after it.
struct Reject
{
    enum type = MessageType.reject;

    RejectReason reason;
}

/// Sent on every link every `heartbeat_ms`: liveness, round-trip time and load.
struct Heartbeat
{
    enum type = MessageType.heartbeat;

    ulong sentAt;          /// microseconds on the sender's clock
    ulong echo;            /// the `sentAt` of the last heartbeat received from the peer; 0 if none
    uint echoHeld;         /// microseconds between receiving that heartbeat and sending this one
    uint tickAverageUs;    /// the sender's mean tick over its last measurement interval
    uint players;          /// players in the world on the sender
    uint objects;          /// creatures and game objects on the sender
}

/// A member, as a view lists it.
struct ViewMember
{
    ushort nodeId;
    ulong incarnation;
    @LengthPrefix!ubyte string address;
    bool coordinator;
}

/// The coordinator's list of the cluster's live members; each change increases `version_`.
struct View
{
    enum type = MessageType.view;

    ulong coordinatorIncarnation; /// versions compare only within one coordinator start
    ulong version_;
    @LengthPrefix!ushort ViewMember[] members;
}

/// The coordinator's region table (phase 2): who owns what. Sent whole when it changes; it is small.
struct RegionTable
{
    enum type = MessageType.regionTable;

    ulong coordinatorIncarnation; /// versions compare only within one coordinator start
    ulong version_;
    @LengthPrefix!ushort Region[] regions;
}

/// A member has stopped simulating a region the coordinator revoked.
struct RegionReleased
{
    enum type = MessageType.regionReleased;

    uint region;
    ulong epoch;    /// the grant given up; a release of another epoch counts for nothing
    @LengthPrefix!uint ubyte[] objects; /// the state of its objects, for the next owner (phase 4); may be empty
}

/// The state of a region's objects from its last owner, sent ahead of the grant on the same link (phase 4).
struct RegionHandover
{
    enum type = MessageType.regionHandover;

    uint region;
    @LengthPrefix!uint ubyte[] objects;
}

/// A member asks the coordinator for a block of ids.
struct IdRequest
{
    enum type = MessageType.idRequest;

    IdKind kind;
    uint count;
}

/// The coordinator's answer: ids [first, first + count) are the member's.
struct IdGrant
{
    enum type = MessageType.idGrant;

    IdKind kind;
    uint first;
    uint count;
}

/// A member's highest ids held, so a restarted coordinator does not hand them out again.
struct IdReport
{
    enum type = MessageType.idReport;

    uint character;
    uint item;
    uint mail;
    uint group;
    uint instance;
}

/// The cells of a map the sender's players became near (`added`) and left (`removed`) (phase 3).
struct InterestUpdate
{
    enum type = MessageType.interestUpdate;

    uint map;
    @LengthPrefix!uint ulong[] added;
    @LengthPrefix!uint ulong[] removed;
}

/// The receiver holds a replica of the sender's object from now on (`dmangos.world.replication`).
struct ReplicaCreate
{
    enum type = MessageType.replicaCreate;

    uint map;
    ulong cell;
    ulong guid;
    @LengthPrefix!uint ubyte[] state;
}

/// A replicated object's fields changed.
struct ReplicaValues
{
    enum type = MessageType.replicaValues;

    uint map;
    ulong guid;
    @LengthPrefix!uint ubyte[] slots;
}

/// A replicated object started or stopped moving: the client packet and the movement after it.
struct ReplicaMove
{
    enum type = MessageType.replicaMove;

    uint map;
    ulong guid;
    ushort opcode;
    @LengthPrefix!uint ubyte[] body_;
    @LengthPrefix!uint ubyte[] motion;
}

/// The receiver holds no replica of the object any more.
struct ReplicaRemove
{
    enum type = MessageType.replicaRemove;

    uint map;
    ulong guid;
}

/// A node accepted a session for `account` (`dmangos.cluster.sessions`).
struct SessionClaim
{
    enum type = MessageType.sessionClaim;

    uint account;
    ulong serial;  /// the node's number for the session
}

/// The session may enter the world: no other session has the account.
struct SessionGrant
{
    enum type = MessageType.sessionGrant;

    uint account;
    ulong serial;
}

/// The session must end: another one claimed the account.
struct SessionEvict
{
    enum type = MessageType.sessionEvict;

    uint account;
    ulong serial;
}

/// The session ended (its character saved), or never entered the world.
struct SessionReleased
{
    enum type = MessageType.sessionReleased;

    uint account;
    ulong serial;
}

/// What a `PlayerMessage` is (phase 4b: a player simulated on another node than its client's).
enum PlayerMessageKind : ubyte
{
    migrate = 1,     /// the player's simulation moves to the receiver (`data`: its state)
    toOwner = 2,     /// a packet from the client, for the node that simulates the player
    toHome = 3,      /// a packet for the client, to the node that holds its connection
    left = 4,        /// the player left the world on the owner (`opcode` 1: to the character screen)
    disconnect = 5,  /// the client is gone: the owner saves the player and says `left`
    moved = 6,       /// to the home: the player's simulation moved on to node `opcode`
}

/// See `PlayerMessageKind`. Players are known by their account: one session per account in the cluster.
struct PlayerMessage
{
    enum type = MessageType.player;

    PlayerMessageKind kind;
    uint account;
    ushort opcode;
    @LengthPrefix!uint ubyte[] data;
}

/// A packet for every player within `range` of a point (say, yell, emotes: phase 5).
struct InRange
{
    enum type = MessageType.inRange;

    uint map;
    float x, y, z;
    float range;
    ushort opcode;
    @LengthPrefix!uint ubyte[] body_;
}

/// A player as other nodes need to know it to whisper it or list it (phase 5).
struct PresenceEntry
{
    ulong guid;
    @LengthPrefix!ubyte string name;
    uint account;
    ubyte race, classId, level, gender;
    uint zone;
    uint flags;          /// `PresenceFlags`
    ubyte security;      /// the account's level (the who list hides GMs from players above `gm_level_in_who_list`)
    @LengthPrefix!ubyte string autoReply; /// while away or busy
    @LengthPrefix!ubyte string permissions; /// ArcEmu's GM permission letters (`.gm list`)
}

/// The players the sender simulates that changed (`entries`) or left (`gone`) (phase 5).
struct Presence
{
    enum type = MessageType.presence;

    bool full;           /// `entries` is everything: forget what the sender said before
    @LengthPrefix!uint PresenceEntry[] entries;
    @LengthPrefix!uint ulong[] gone;
}

/// A packet for one player the receiver simulates (a whisper: phase 5).
struct DeliverTo
{
    enum type = MessageType.deliverTo;

    ulong guid;
    ushort opcode;
    @LengthPrefix!uint ubyte[] body_;
}

/// A whisper for a player the receiver simulates; it checks and delivers it, and answers the sender (phase 5).
struct WhisperMessage
{
    enum type = MessageType.whisper;

    ulong to;
    ulong from;
    ubyte fromRace;
    bool fromPermissions;
    ubyte fromChatTag;
    @LengthPrefix!uint string text;
}

/// A player on the sender buys a limited item from a creature the receiver simulates: reserve it (phase 5).
struct StockRequest
{
    enum type = MessageType.stockRequest;

    uint request;
    uint map;
    ulong creature;
    uint item, maxCount, incrTime, buyCount, wanted;
}

/// Whether the stock was there (and is now the buyer's), and what is left.
struct StockReply
{
    enum type = MessageType.stockReply;

    uint request;
    bool reserved;
    uint left;
}

/// A purchase did not complete: the reserved stock goes back.
struct StockRelease
{
    enum type = MessageType.stockRelease;

    uint map;
    ulong creature;
    uint item, maxCount, count;
}

/// A player's chat channel command, for the coordinator, which keeps the channels (phase 5b).
struct ChannelCommand
{
    enum type = MessageType.channelCommand;

    ulong guid;
    @LengthPrefix!uint string name;
    ubyte race;
    bool moderateAll;      /// ArcEmu's `c` permission
    ubyte chatTag;
    ubyte op;              /// `dmangos.world.channelservice.ChannelOp`
    @LengthPrefix!uint string channel;
    @LengthPrefix!uint string arg;
    uint language;
}

/// A player's group command (invitations, kicks, the leader, loot, raids), for the coordinator (phase 5b).
struct GroupCommand
{
    enum type = MessageType.groupCommand;

    ulong guid;
    @LengthPrefix!uint string name;
    ubyte race;
    bool permissions;      /// any GM permission: invites across factions
    ubyte op;              /// `dmangos.world.groupservice.GroupOp`
    ulong target;
    @LengthPrefix!uint string text;
    @LengthPrefix!uint string text2;
    uint number;
    uint number2;
}

/// One member of a `GroupState`.
struct GroupMemberState
{
    ulong guid;
    @LengthPrefix!uint string name;
    ubyte subGroup;
    bool assistant;
}

/// A group as the coordinator has it now, for the other nodes' mirrors; or that it is gone.
struct GroupState
{
    enum type = MessageType.groupState;

    uint id;
    bool removed;
    ubyte groupType;
    ulong leader;
    @LengthPrefix!uint string leaderName;
    ulong mainTank;
    ulong mainAssistant;
    ubyte lootMethod;
    ulong looter;
    ubyte lootThreshold;
    @LengthPrefix!uint ulong[] icons;
    @LengthPrefix!uint GroupMemberState[] members;
}

/// A member's full stats, for a player on the sender (`CMSG_REQUEST_PARTY_MEMBER_STATS`).
struct MemberStatsRequest
{
    enum type = MessageType.memberStatsRequest;

    ulong requester;
    ulong member;
}

/// A packet for every player the receiver simulates (world texts: phase 5b); with `permission`, only for
/// those who have that GM permission letter.
struct ToEveryone
{
    enum type = MessageType.toEveryone;

    ushort opcode;
    ubyte permission;
    @LengthPrefix!uint ubyte[] body_;
}

/// A GM command for a player the receiver simulates (`dmangos.world.gmtargets.GmRemoteOp`), from a GM on
/// the sender; what the GM is told goes back to it (`DeliverTo`).
struct GmRemote
{
    enum type = MessageType.gmRemote;

    ubyte op;
    ulong gm;
    @LengthPrefix!uint string gmName;
    bool gmCanKickGms;       /// the GM has the `z` permission
    ulong target;
    uint map;
    float x, y, z, orientation;
    @LengthPrefix!uint string text;
    uint instance = uint.max; /// the dungeon copy at `map` (`summon`, `appearAt`); uint.max: none known
}

/**
 * A group member's share of a kill on the sender, for the receiver, which simulates that member
 * (`Group::RewardGroupAtKill` across nodes): the kill credit, the experience and the reputation.
 */
struct KillShare
{
    enum type = MessageType.killShare;

    ulong target;          /// the member
    ulong victim;          /// the creature killed
    uint entry;            /// its entry
    uint level;            /// its level
    uint xp;               /// the member's experience (0: none)
    float rate;            /// the group rate the experience came with
    float reputationRate;  /// the share of the kill's reputation (0: none)
}

/**
 * A script's signal for a creature the receiver simulates (docs/SCRIPTING.md). `origin` and
 * `sequence` make it apply once: a receiver drops what it has seen from `origin` (a resend after a
 * reconnect). `hops` counts the nodes it was passed on to, after its creature.
 */
struct ScriptSignal
{
    enum type = MessageType.scriptSignal;

    ulong to;        /// the creature
    ulong from;      /// who signals (a creature, a player, or nothing)
    uint map;
    uint instance;
    uint id;
    int value;
    ushort origin;   /// the node that sent it first
    ulong sequence;  /// increasing per origin
    ubyte hops;
}

/// To the node hosting a dungeon: may this player go in (into `instance`, uint.max: its own)?
struct DungeonEntryRequest
{
    enum type = MessageType.dungeonEntryRequest;

    uint request;
    ulong player;
    uint map;
    uint instance;
    bool gameMaster;
}

/// The host's answer: 0 to go in, else `SMSG_TRANSFER_ABORTED`'s reason.
struct DungeonEntryReply
{
    enum type = MessageType.dungeonEntryReply;

    uint request;
    ubyte abort;
}

/// To the coordinator: the sender is shutting down; its regions should go to the others first.
struct Drain
{
    enum type = MessageType.drain;

    ulong incarnation;
}

/// What one region cost its owner: µs of loop time a second (phase 6).
struct RegionLoad
{
    uint region;
    uint busyUs;
}

/// To the coordinator: what the sender's regions cost it lately.
struct RegionLoads
{
    enum type = MessageType.regionLoads;

    @LengthPrefix!uint RegionLoad[] loads;
}

/// From the standby: the coordinator is gone and the sender is the coordinator now (phase 7).
struct Takeover
{
    enum type = MessageType.takeover;

    ulong incarnation;
}

/// To the new coordinator: the sender takes it as its coordinator.
struct TakeoverAccepted
{
    enum type = MessageType.takeoverAccepted;

    ulong incarnation;
}

/// Appends a framed message to `writer`.
void putMessage(M)(ref ByteWriter writer, ulong sequence, auto ref const M message)
{
    const start = writer.length;
    writer.put(uint(0));
    writer.put(cast(ushort) M.type);
    writer.put(ushort(0));
    writer.put(sequence);
    serialize(writer, message);
    const length = writer.length - start - frameHeaderSize;
    enforce(length <= maxPayload, "cluster message too large");
    writer.patch(start, cast(uint) length);
}

/**
 * Takes the first complete frame off `input`: its header and payload (a slice of `input`). False,
 * leaving `input` alone, if the frame is not all there yet. Throws on a frame no node would send.
 */
bool takeFrame(ref const(ubyte)[] input, out FrameHeader header, out const(ubyte)[] payload)
{
    if (input.length < frameHeaderSize)
        return false;
    auto r = ByteReader(input[0 .. frameHeaderSize]);
    header.length = r.read!uint;
    const type = r.read!ushort;
    header.flags = r.read!ushort;
    header.sequence = r.read!ulong;
    if (header.length > maxPayload)
        throw new PacketException("cluster frame too large");
    if (type < MessageType.min || type > MessageType.max)
        throw new PacketException("unknown cluster message type");
    header.type = cast(MessageType) type;
    if (input.length < frameHeaderSize + header.length)
        return false;
    payload = input[frameHeaderSize .. frameHeaderSize + header.length];
    input = input[frameHeaderSize + header.length .. $];
    return true;
}

/// The payload as an `M`; throws if it is not one.
M decode(M)(const(ubyte)[] payload)
{
    auto r = ByteReader(payload);
    auto message = deserialize!M(r);
    if (!r.empty)
        throw new PacketException("trailing bytes in cluster message");
    return message;
}

unittest
{
    import std.exception : assertThrown;

    ByteWriter w;
    const hello = Hello(protocolVersion, "dmangos", 2, 1234, "10.0.0.2:9001", "10.0.0.2:8085", false, 0);
    putMessage(w, 0, hello);
    putMessage(w, 7, Heartbeat(100, 50, 3, 400, 2, 900));
    const all = w.data;

    // Byte by byte, a frame appears only when it is complete.
    const(ubyte)[] input = all[0 .. 10];
    FrameHeader header;
    const(ubyte)[] payload;
    assert(!takeFrame(input, header, payload) && input.length == 10);
    input = all;
    assert(takeFrame(input, header, payload) && header.type == MessageType.hello && header.sequence == 0);
    assert(decode!Hello(payload) == hello);
    assert(takeFrame(input, header, payload) && header.type == MessageType.heartbeat && header.sequence == 7);
    assert(decode!Heartbeat(payload) == Heartbeat(100, 50, 3, 400, 2, 900) && payload.length == 32);
    assert(input.length == 0 && !takeFrame(input, header, payload));

    const view = View(9, 3, [ViewMember(1, 5, "a:1", true), ViewMember(2, 6, "b:2", false)]);
    w.clear();
    putMessage(w, 1, view);
    input = w.data;
    assert(takeFrame(input, header, payload) && decode!View(payload) == view);

    import dmangos.cluster.regions : CellRect, RegionState;

    const table = RegionTable(9, 4, [Region(1, 0, CellRect(-256, -256, 3, 256), 2, 77, RegionState.revoking)]);
    w.clear();
    putMessage(w, 2, table);
    putMessage(w, 3, IdGrant(IdKind.mail, 1000, 500));
    input = w.data;
    assert(takeFrame(input, header, payload) && decode!RegionTable(payload) == table);
    assert(takeFrame(input, header, payload) && decode!IdGrant(payload) == IdGrant(IdKind.mail, 1000, 500));

    // Rubbish is refused.
    ubyte[frameHeaderSize] bad;
    bad[4] = 99; // type
    input = bad[];
    assertThrown!PacketException(takeFrame(input, header, payload));
    bad[4] = 3;
    bad[3] = 0x7F; // length
    input = bad[];
    assertThrown!PacketException(takeFrame(input, header, payload));
    assertThrown!PacketException(decode!Heartbeat(new ubyte[37]));
}
