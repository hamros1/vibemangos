/**
 * World packet layouts and framing for 1.12.x clients.
 *
 * Framing (CMaNGOS `WorldSocket.cpp`):
 * $(UL
 *   $(LI server -> client: `uint16` size, big-endian, counting the opcode; `uint16` opcode; body;)
 *   $(LI client -> server: `uint16` size, big-endian, counting the opcode; `uint32` opcode; body.)
 * )
 * The headers are encrypted once the session is authenticated; see `dmangos.world.crypt`.
 */
module dmangos.world.packets;

import std.bitmanip : nativeToBigEndian;
import std.exception : enforce;

import dmangos.bytes;
import dmangos.serialization;
import dmangos.world.crypt : HeaderCrypt, serverHeaderLength;
import dmangos.world.opcodes;

/// Largest client packet CMaNGOS accepts, counting the opcode (`0x2800`).
enum maxClientPacketSize = 0x2800;

/// Declares the opcode of a server packet.
mixin template ServerPacket(Opcode code)
{
    enum Opcode opcode = code;
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

/// First packet on a new connection, sent in the clear.
struct ServerAuthChallenge
{
    mixin ServerPacket!(Opcode.SMSG_AUTH_CHALLENGE);
    uint serverSeed;
}

/// `CMSG_AUTH_SESSION`: the client proves it holds the session key from the login server.
struct ClientAuthSession
{
    uint build;
    uint serverId;                /// Unused by the client logic.
    @CString string account;
    uint clientSeed;
    ubyte[20] digest;             /// SHA1(account, uint32 0, clientSeed, serverSeed, K)
    @Remainder ubyte[] addonData; /// uint32 uncompressed size, then zlib data; see `dmangos.world.addons`
}

/// `SMSG_AUTH_RESPONSE` for anything but success.
struct ServerAuthFailure
{
    mixin ServerPacket!(Opcode.SMSG_AUTH_RESPONSE);
    AuthResponse result;
}

/// `SMSG_AUTH_RESPONSE` on success, with the (unused) billing fields.
struct ServerAuthSuccess
{
    mixin ServerPacket!(Opcode.SMSG_AUTH_RESPONSE);
    AuthResponse result = AuthResponse.AUTH_OK;
    uint billingTimeRemaining;
    ubyte billingPlanFlags;
    uint billingTimeRested;
}

static assert(wireSize!ServerAuthSuccess == 10);

/// `SMSG_ADDON_INFO`; the body is built by `dmangos.world.addons`.
struct ServerAddonInfo
{
    mixin ServerPacket!(Opcode.SMSG_ADDON_INFO);
    @Remainder ubyte[] body_;
}

// ---------------------------------------------------------------------------
// Keep-alive
// ---------------------------------------------------------------------------

/// `CMSG_PING`
struct ClientPing
{
    uint sequence;
    uint latency; /// The client's measured round trip, in milliseconds.
}

/// `SMSG_PONG`
struct ServerPong
{
    mixin ServerPacket!(Opcode.SMSG_PONG);
    uint sequence;
}

// ---------------------------------------------------------------------------
// Character screen
// ---------------------------------------------------------------------------

/// Number of equipment entries in a character list entry (`INVENTORY_SLOT_BAG_START + 1`).
enum characterListEquipmentSlots = 20;

/// The most characters a 1.12 client accepts in its list.
enum maxCharactersPerRealm = 10;

/// What one equipment slot looks like on the character screen.
struct EquipmentDisplay
{
    uint displayId;
    ubyte inventoryType;
}

static assert(wireSize!EquipmentDisplay == 5);

/// One character in `SMSG_CHAR_ENUM`.
struct CharacterEntry
{
    ulong guid;
    @CString string name;
    ubyte race;
    ubyte classId;
    ubyte gender;
    ubyte skin;
    ubyte face;
    ubyte hairStyle;
    ubyte hairColor;
    ubyte facialHair;
    ubyte level;
    uint zone;
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    uint guildId;
    uint flags;          /// `CharacterFlags`
    ubyte firstLogin;
    uint petDisplayId;
    uint petLevel;
    uint petFamily;
    EquipmentDisplay[characterListEquipmentSlots] equipment;
}

/// `SMSG_CHAR_ENUM`
struct ServerCharEnum
{
    mixin ServerPacket!(Opcode.SMSG_CHAR_ENUM);
    @LengthPrefix!ubyte CharacterEntry[] characters;
}

/// `CMSG_CHAR_CREATE`
struct ClientCharCreate
{
    @CString string name;
    ubyte race;
    ubyte classId;
    ubyte gender;
    ubyte skin;
    ubyte face;
    ubyte hairStyle;
    ubyte hairColor;
    ubyte facialHair;
    ubyte outfitId;
}

/// `SMSG_CHAR_CREATE`; the code is a `CharacterResponse` or, for name problems, a `CharNameResult`.
struct ServerCharCreate
{
    mixin ServerPacket!(Opcode.SMSG_CHAR_CREATE);
    ubyte result;
}

/// `CMSG_CHAR_DELETE`
struct ClientCharDelete
{
    ulong guid;
}

/// `SMSG_CHAR_DELETE`
struct ServerCharDelete
{
    mixin ServerPacket!(Opcode.SMSG_CHAR_DELETE);
    CharacterResponse result;
}

/// `CMSG_PLAYER_LOGIN`
struct ClientPlayerLogin
{
    ulong guid;
}

/// `SMSG_CHARACTER_LOGIN_FAILED`
struct ServerCharacterLoginFailed
{
    mixin ServerPacket!(Opcode.SMSG_CHARACTER_LOGIN_FAILED);
    CharacterLoginFailure reason;
}

// ---------------------------------------------------------------------------
// Entering the world (Player::SendInitialPacketsBeforeAddToMap and after)
// ---------------------------------------------------------------------------

/// `SMSG_LOGIN_VERIFY_WORLD`: the client starts loading the map.
struct ServerLoginVerifyWorld
{
    mixin ServerPacket!(Opcode.SMSG_LOGIN_VERIFY_WORLD);
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
}

/// Account data types (`NUM_ACCOUNT_DATA_TYPES`).
enum accountDataTypes = 8;

/// `SMSG_ACCOUNT_DATA_TIMES`: an MD5 per account data type; zero means "none stored".
struct ServerAccountDataTimes
{
    mixin ServerPacket!(Opcode.SMSG_ACCOUNT_DATA_TIMES);
    ubyte[16][accountDataTypes] digests;
}

/// `SMSG_EXPECTED_SPAM_RECORDS`
struct ServerExpectedSpamRecords
{
    mixin ServerPacket!(Opcode.SMSG_EXPECTED_SPAM_RECORDS);
    @LengthPrefix!uint CStringValue[] records;
}

/// A null-terminated string as an array element.
struct CStringValue
{
    @CString string text;
}

/// `SMSG_SET_REST_START`
struct ServerSetRestStart
{
    mixin ServerPacket!(Opcode.SMSG_SET_REST_START);
    uint unknown;
}

/// `SMSG_BINDPOINTUPDATE`: where the hearthstone leads.
struct ServerBindPointUpdate
{
    mixin ServerPacket!(Opcode.SMSG_BINDPOINTUPDATE);
    float x = 0;
    float y = 0;
    float z = 0;
    uint map;
    uint zone;
}

/// `SMSG_TUTORIAL_FLAGS`: 256 bits, one per tutorial seen.
struct ServerTutorialFlags
{
    mixin ServerPacket!(Opcode.SMSG_TUTORIAL_FLAGS);
    uint[8] flags;
}

/// One spellbook entry of `SMSG_INITIAL_SPELLS`.
struct InitialSpell
{
    ushort spell;
    ushort unknown; /// "it's not slot id"
}

/// `SMSG_INITIAL_SPELLS`, without cooldowns.
struct ServerInitialSpells
{
    mixin ServerPacket!(Opcode.SMSG_INITIAL_SPELLS);
    ubyte unknown;
    @LengthPrefix!ushort InitialSpell[] spells;
    ushort cooldownCount;
}

/// `SMSG_ACTION_BUTTONS`: 120 packed buttons.
struct ServerActionButtons
{
    mixin ServerPacket!(Opcode.SMSG_ACTION_BUTTONS);
    uint[120] buttons;
}

/// Reputation list entries (`MAX_REPUTATION_LIST`... 64 in 1.12).
enum reputationListSize = 64;

/// One faction of `SMSG_INITIALIZE_FACTIONS`.
struct FactionState
{
    ubyte flags;
    int standing;
}

/// `SMSG_INITIALIZE_FACTIONS`
struct ServerInitializeFactions
{
    mixin ServerPacket!(Opcode.SMSG_INITIALIZE_FACTIONS);
    uint count = reputationListSize;
    FactionState[reputationListSize] factions;
}

/// `SMSG_LOGIN_SETTIMESPEED`
struct ServerLoginSetTimeSpeed
{
    mixin ServerPacket!(Opcode.SMSG_LOGIN_SETTIMESPEED);
    uint gameTime;              /// `secsToTimeBitFields`
    float speed = 0.01666667f;  /// game minutes per real second, as the client expects
}

/// `SMSG_FRIEND_LIST`, empty.
struct ServerFriendList
{
    mixin ServerPacket!(Opcode.SMSG_FRIEND_LIST);
    ubyte count;
}

/// `SMSG_IGNORE_LIST`, empty.
struct ServerIgnoreList
{
    mixin ServerPacket!(Opcode.SMSG_IGNORE_LIST);
    ubyte count;
}

/// `SMSG_INIT_WORLD_STATES`, without any world states.
struct ServerInitWorldStates
{
    mixin ServerPacket!(Opcode.SMSG_INIT_WORLD_STATES);
    uint map;
    uint zone;
    ushort count;
}

/// `SMSG_SET_PROFICIENCY`
struct ServerSetProficiency
{
    mixin ServerPacket!(Opcode.SMSG_SET_PROFICIENCY);
    ubyte itemClass;
    uint subClassMask;
}

/// `SMSG_TRIGGER_CINEMATIC`: the race's intro.
struct ServerTriggerCinematic
{
    mixin ServerPacket!(Opcode.SMSG_TRIGGER_CINEMATIC);
    uint sequence;
}

/// `SMSG_UPDATE_OBJECT`; the body is built by `dmangos.world.objects.UpdateData`.
struct ServerUpdateObject
{
    mixin ServerPacket!(Opcode.SMSG_UPDATE_OBJECT);
    @Remainder ubyte[] body_;
}

/// `SMSG_COMPRESSED_UPDATE_OBJECT`
struct ServerCompressedUpdateObject
{
    mixin ServerPacket!(Opcode.SMSG_COMPRESSED_UPDATE_OBJECT);
    @Remainder ubyte[] body_;
}

// ---------------------------------------------------------------------------
// In the world
// ---------------------------------------------------------------------------

/// `CMSG_NAME_QUERY`
struct ClientNameQuery
{
    ulong guid;
}

/// `SMSG_NAME_QUERY_RESPONSE`
struct ServerNameQueryResponse
{
    mixin ServerPacket!(Opcode.SMSG_NAME_QUERY_RESPONSE);
    ulong guid;
    @CString string name;
    @CString string realm; /// empty: this realm
    uint race;
    uint gender;
    uint classId;
}

/// `CMSG_ITEM_QUERY_SINGLE`
struct ClientItemQuerySingle
{
    uint entry;
    ulong guid;
}

/// `SMSG_ITEM_QUERY_SINGLE_RESPONSE`; the body is built by `dmangos.world.queries`.
struct ServerItemQueryResponse
{
    mixin ServerPacket!(Opcode.SMSG_ITEM_QUERY_SINGLE_RESPONSE);
    @Remainder ubyte[] body_;
}

/// `SMSG_MESSAGECHAT`; the body is built by `dmangos.world.chat`.
struct ServerMessageChat
{
    mixin ServerPacket!(Opcode.SMSG_MESSAGECHAT);
    @Remainder ubyte[] body_;
}

/// `SMSG_NOTIFICATION`: a message in the middle of the screen.
struct ServerNotification
{
    mixin ServerPacket!(Opcode.SMSG_NOTIFICATION);
    @CString string text;
}

/// `SMSG_QUERY_TIME_RESPONSE`
struct ServerQueryTimeResponse
{
    mixin ServerPacket!(Opcode.SMSG_QUERY_TIME_RESPONSE);
    uint unixTime;
}

/// `SMSG_PLAYED_TIME`
struct ServerPlayedTime
{
    mixin ServerPacket!(Opcode.SMSG_PLAYED_TIME);
    uint total;
    uint level;
}

/// `CMSG_STANDSTATECHANGE`
struct ClientStandStateChange
{
    uint state;
}

/// `SMSG_STANDSTATE_UPDATE`
struct ServerStandStateUpdate
{
    mixin ServerPacket!(Opcode.SMSG_STANDSTATE_UPDATE);
    ubyte state;
}

/// `CMSG_SET_ACTION_BUTTON`
struct ClientSetActionButton
{
    ubyte button;
    uint packed; /// action | type << 24; 0 clears the button
}

/// `CMSG_SET_ACTIONBAR_TOGGLES`
struct ClientSetActionBarToggles
{
    ubyte toggles;
}

/// `CMSG_TUTORIAL_FLAG`
struct ClientTutorialFlag
{
    uint flag;
}

/// `CMSG_ZONEUPDATE`
struct ClientZoneUpdate
{
    uint zone;
}

/// `SMSG_LOGOUT_RESPONSE`
struct ServerLogoutResponse
{
    mixin ServerPacket!(Opcode.SMSG_LOGOUT_RESPONSE);
    uint reason;   /// 0 = can log out
    ubyte instant; /// 1 = no 20-second countdown
}

/// `SMSG_LOGOUT_COMPLETE`: back to the character screen.
struct ServerLogoutComplete
{
    mixin ServerPacket!(Opcode.SMSG_LOGOUT_COMPLETE);
}

/// `SMSG_LOGOUT_CANCEL_ACK`
struct ServerLogoutCancelAck
{
    mixin ServerPacket!(Opcode.SMSG_LOGOUT_CANCEL_ACK);
}

static assert(wireSize!ServerAccountDataTimes == 128);
static assert(wireSize!ServerInitializeFactions == 4 + 64 * 5);
static assert(wireSize!ServerActionButtons == 480);

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

/// Frames a server packet: the header (encrypted by `crypt` once active), then the body.
ubyte[] encodePacket(T)(auto ref const T packet, ref HeaderCrypt crypt) if (is(typeof(T.opcode) == Opcode))
out (bytes; bytes.length >= serverHeaderLength)
{
    ByteWriter payload;
    serialize(payload, packet);
    enforce!PacketException(payload.length + 2 <= ushort.max, "packet too large");

    ubyte[serverHeaderLength] header;
    header[0 .. 2] = nativeToBigEndian(cast(ushort)(payload.length + 2));
    header[2] = cast(ubyte)(T.opcode & 0xFF);
    header[3] = cast(ubyte)(T.opcode >> 8);
    crypt.encryptHeader(header);
    return header ~ payload.data;
}

unittest
{
    HeaderCrypt plain;
    const bytes = encodePacket(ServerAuthChallenge(0x11223344), plain);
    const ubyte[8] expected = [0x00, 0x06, 0xEC, 0x01, 0x44, 0x33, 0x22, 0x11];
    assert(bytes == expected[]);

    // One character with a 4-letter name: 158 fixed bytes + name + terminator, plus the count.
    ServerCharEnum list;
    list.characters = [CharacterEntry(1, "Test")];
    assert(encodePacket(list, plain).length == 4 + 1 + 158 + 5);
}
