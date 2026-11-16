/**
 * Wire definitions of the 1.12.x login protocol (sometimes called "grunt").
 *
 * Each packet is a plain struct, (de)serialized by
 * `dmangos.serialization`. Fixed-size packets `static assert` their
 * length so that a layout mistake fails the build. The expected lengths come
 * from CMaNGOS `realmd/AuthSocket.cpp` and Ember's `libs/grunt`.
 *
 * Client packets omit their opcode byte, which the session reads before
 * dispatching. Server packets declare their opcode through the
 * `ServerPacket` mixin template, and `encode` writes it.
 */
module dmangos.auth.protocol;

import std.exception : enforce;
import std.traits : hasUDA;

import dmangos.bytes;
import dmangos.crypto.srp6 : generator, keyLength, primeBytes, proofLength, saltLength;
import dmangos.serialization;

/// First byte of every login packet.
enum Opcode : ubyte
{
    logonChallenge = 0x00,
    logonProof = 0x01,
    reconnectChallenge = 0x02,
    reconnectProof = 0x03,
    realmList = 0x10,
    xferInitiate = 0x30,
    xferData = 0x31,
    xferAccept = 0x32,
    xferResume = 0x33,
    xferCancel = 0x34,
}

/// Login result codes, which the client turns into error dialogs.
enum AuthResult : ubyte
{
    success = 0x00,
    failUnknown0 = 0x01,
    failUnknown1 = 0x02,
    failBanned = 0x03,
    failUnknownAccount = 0x04,
    failIncorrectPassword = 0x05,
    failAlreadyOnline = 0x06,
    failNoTime = 0x07,
    failDbBusy = 0x08,
    failVersionInvalid = 0x09,
    failVersionUpdate = 0x0A,
    failInvalidServer = 0x0B,
    failSuspended = 0x0C,
    failNoAccess = 0x0D,
    successSurvey = 0x0E,
    failParentControl = 0x0F,
    failLockedEnforced = 0x10,
}

/// Realm type, shown as the realm's category ("PvP", "RP", ...).
enum RealmType : uint
{
    normal = 0,
    pvp = 1,
    normal2 = 4,
    rp = 6,
    rpPvp = 8,
}

/// Realm status flags, combined with bitwise or.
enum RealmFlags : ubyte
{
    none = 0x00,
    invalid = 0x01,
    offline = 0x02,
    specifyBuild = 0x04,
    newPlayers = 0x20,
    recommended = 0x40,
    full = 0x80,
}

/// A client build that this server speaks the protocol of.
struct ClientBuild
{
    ushort build;
    string versionName;
    ubyte major;
    ubyte minor;
    ubyte patch;
}

/// Builds whose login packets match the definitions in this module.
immutable ClientBuild[] supportedBuilds = [
    ClientBuild(5875, "1.12.1", 1, 12, 1),
    ClientBuild(6005, "1.12.2", 1, 12, 2),
    ClientBuild(6141, "1.12.3", 1, 12, 3),
];

/// The supported build `build`, or an all-zero entry (as CMaNGOS shows unknown builds).
ClientBuild findBuild(ushort build) pure nothrow @nogc @safe
{
    foreach (known; supportedBuilds)
        if (known.build == build)
            return known;
    return ClientBuild.init;
}

/// Version string of a supported build, or null. The switch cases are generated from `supportedBuilds`.
string versionName(ushort build) pure nothrow @nogc @safe
{
    switch (build)
    {
        static foreach (known; supportedBuilds)
        {
    case known.build:
            return known.versionName;
        }
    default:
        return null;
    }
}

/// Declares the opcode of a server packet.
mixin template ServerPacket(Opcode code)
{
    enum Opcode opcode = code;
}

// ---------------------------------------------------------------------------
// Client -> server
// ---------------------------------------------------------------------------

/// Bytes between the opcode and the body of a logon or reconnect challenge.
struct LogonChallengeHeader
{
    ubyte protocolVersion;
    ushort size; /// Size of the body that follows.
}

static assert(wireSize!LogonChallengeHeader == 3);

/// Fixed-size part of a challenge: information about the client.
struct ClientInfo
{
    @FourCC string game;     /// Always "WoW".
    ubyte major;
    ubyte minor;
    ubyte patch;
    ushort build;
    @FourCC string platform; /// "x86", "PPC"
    @FourCC string os;       /// "Win", "OSX"
    @FourCC string locale;   /// "enUS", "deDE", ...
    int timezoneBias;        /// Minutes from UTC.
    ubyte[4] ip;             /// The client's idea of its own address. Not trusted.
}

static assert(wireSize!ClientInfo == 29);

/// Body of `Opcode.logonChallenge` and `Opcode.reconnectChallenge`.
struct ClientLogonChallenge
{
    ClientInfo info;
    @LengthPrefix!ubyte string username;
}

/// `Opcode.logonProof`: the client's SRP6 public key and proof.
struct ClientLogonProof
{
    ubyte[keyLength] clientPublicKey; /// A
    ubyte[proofLength] clientProof;   /// M1
    ubyte[proofLength] crcHash;       /// Hash of the client files. Not checked yet.
    ubyte keyCount;                   /// Number of telemetry keys that follow. Always 0 on 1.12.
    ubyte securityFlags;              /// Nonzero only if the server requested a PIN.
}

static assert(wireSize!ClientLogonProof == 74);

/// `Opcode.reconnectProof`
struct ClientReconnectProof
{
    ubyte[16] proofData;            /// R1, client randomness
    ubyte[proofLength] clientProof; /// R2 = H(user, R1, challenge, K)
    ubyte[proofLength] crcHash;     /// R3
    ubyte keyCount;
}

static assert(wireSize!ClientReconnectProof == 57);

/// `Opcode.realmList`
struct ClientRealmList
{
    uint unused;
}

// ---------------------------------------------------------------------------
// Server -> client
// ---------------------------------------------------------------------------

/// Successful reply to a logon challenge. It carries everything the client needs to run SRP6.
struct ServerLogonChallenge
{
    mixin ServerPacket!(Opcode.logonChallenge);

    ubyte protocolVersion = 0;
    AuthResult result = AuthResult.success;
    ubyte[keyLength] serverPublicKey; /// B
    ubyte generatorLength = 1;
    ubyte generatorValue = generator;
    ubyte primeLength = keyLength;
    ubyte[keyLength] prime = primeBytes;
    ubyte[saltLength] salt;
    ubyte[16] versionChallenge;
    ubyte securityFlags = 0;          /// 0x01 would request a PIN. Not supported.
}

static assert(wireSize!ServerLogonChallenge + 1 == 119);

/// Failed reply to a logon challenge.
struct ServerLogonChallengeFailure
{
    mixin ServerPacket!(Opcode.logonChallenge);

    ubyte protocolVersion = 0;
    AuthResult result;
}

/// Successful reply to a logon proof, in the layout used by builds 5875-6141.
struct ServerLogonProof
{
    mixin ServerPacket!(Opcode.logonProof);

    AuthResult result = AuthResult.success;
    ubyte[proofLength] serverProof; /// M2
    uint loginFlags = 0;
}

static assert(wireSize!ServerLogonProof + 1 == 26);

/// Failed logon proof for builds 5875 and 6005.
struct ServerLogonProofFailure
{
    mixin ServerPacket!(Opcode.logonProof);

    AuthResult result;
}

/// Failed logon proof for build 6141, which expects two padding bytes.
struct ServerLogonProofFailurePadded
{
    mixin ServerPacket!(Opcode.logonProof);

    AuthResult result;
    ushort padding = 0;
}

/// Reply to a reconnect challenge.
struct ServerReconnectChallenge
{
    mixin ServerPacket!(Opcode.reconnectChallenge);

    AuthResult result = AuthResult.success;
    ubyte[16] challenge;
    ubyte[16] versionChallenge;
}

static assert(wireSize!ServerReconnectChallenge + 1 == 34);

/// Successful reply to a reconnect proof.
struct ServerReconnectProof
{
    mixin ServerPacket!(Opcode.reconnectProof);

    AuthResult result = AuthResult.success;
    ushort padding = 0;
}

/// One realm in the realm list, in the 1.12 layout.
struct RealmEntry
{
    RealmType type;
    ubyte flags;              /// `RealmFlags` combined with bitwise or.
    @CString string name;
    @CString string address;  /// "host:port" of the world server
    float population = 0;
    ubyte characters;         /// How many characters the account has on this realm.
    ubyte timezone;           /// Realm category/region.
    ubyte unknown = 0;
}

/// Realm list. Unlike the other packets, its body is preceded by its size.
@SizePrefixed struct ServerRealmList
{
    mixin ServerPacket!(Opcode.realmList);

    uint unused = 0;
    @LengthPrefix!ubyte RealmEntry[] realms;
    ushort trailer = 2;
}

/// Encodes a server packet: opcode, then the size if `@SizePrefixed`, then the body.
ubyte[] encode(T)(auto ref const T packet) if (is(typeof(T.opcode) == Opcode))
out (bytes; wireSize!T == 0 || bytes.length == 1 + wireSize!T, "fixed-size packet encoded to the wrong length")
{
    ByteWriter payload;
    serialize(payload, packet);

    ByteWriter writer;
    writer.put(cast(ubyte) T.opcode);
    static if (hasUDA!(T, SizePrefixed))
    {
        enforce!PacketException(payload.length <= ushort.max, "packet too large");
        writer.put(cast(ushort) payload.length);
    }
    writer.putBytes(payload.data);
    return writer.release();
}

unittest
{
    static assert(versionName(5875) == "1.12.1");
    static assert(versionName(12340) is null);

    ServerLogonProof proof;
    proof.serverProof[] = 0xAA;
    const bytes = encode(proof);
    assert(bytes.length == 26);
    assert(bytes[0] == Opcode.logonProof && bytes[1] == AuthResult.success && bytes[2] == 0xAA);

    const failure = encode(ServerLogonProofFailurePadded(AuthResult.failUnknownAccount));
    const ubyte[4] expectedFailure = [0x01, 0x04, 0x00, 0x00];
    assert(failure == expectedFailure[]);
}

unittest
{
    ServerRealmList list;
    list.realms = [RealmEntry(RealmType.pvp, RealmFlags.recommended, "Test", "127.0.0.1:8085", 1.0f, 3, 1)];
    const bytes = encode(list);

    auto reader = ByteReader(bytes);
    assert(reader.read!ubyte == Opcode.realmList);
    assert(reader.read!ushort == bytes.length - 3);
    assert(reader.read!uint == 0);
    assert(reader.read!ubyte == 1);
    assert(reader.read!uint == RealmType.pvp);
    assert(reader.read!ubyte == RealmFlags.recommended);
    assert(reader.readCString() == "Test");
    assert(reader.readCString() == "127.0.0.1:8085");
    assert(reader.read!float == 1.0f);
    assert(reader.read!ubyte == 3); // characters
    assert(reader.read!ubyte == 1); // timezone
    assert(reader.read!ubyte == 0); // unknown
    assert(reader.read!ushort == 2);
    assert(reader.empty);
}
