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
enum ushort protocolVersion = 5;

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
