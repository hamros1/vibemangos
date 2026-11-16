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

import std.bitmanip : nativeToBigEndian, nativeToLittleEndian;
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

/// `CMSG_CREATURE_QUERY`, `CMSG_GAMEOBJECT_QUERY`
struct ClientObjectQuery
{
    uint entry;
    ulong guid;
}

/// `SMSG_CREATURE_QUERY_RESPONSE`, built by `queries.creatureQueryResponse`.
struct ServerCreatureQueryResponse
{
    mixin ServerPacket!(Opcode.SMSG_CREATURE_QUERY_RESPONSE);
    @Remainder ubyte[] body_;
}

/// `SMSG_GAMEOBJECT_QUERY_RESPONSE`, built by `queries.gameObjectQueryResponse`.
struct ServerGameObjectQueryResponse
{
    mixin ServerPacket!(Opcode.SMSG_GAMEOBJECT_QUERY_RESPONSE);
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

// ---------------------------------------------------------------------------
// Other players
// ---------------------------------------------------------------------------

/// `SMSG_DESTROY_OBJECT`: the client forgets an object (a player that left the world).
struct ServerDestroyObject
{
    mixin ServerPacket!(Opcode.SMSG_DESTROY_OBJECT);
    ulong guid;
}

/// `CMSG_SET_SELECTION`
struct ClientSetSelection
{
    ulong guid;
}

/// `SMSG_CHAT_WRONG_FACTION`: a whisper to the other faction.
struct ServerChatWrongFaction
{
    mixin ServerPacket!(Opcode.SMSG_CHAT_WRONG_FACTION);
}

/// `SMSG_CHAT_PLAYER_NOT_FOUND`: a whisper to nobody.
struct ServerChatPlayerNotFound
{
    mixin ServerPacket!(Opcode.SMSG_CHAT_PLAYER_NOT_FOUND);
    @CString string name;
}

/// `CMSG_TEXT_EMOTE`: /wave, /dance, ...
struct ClientTextEmote
{
    uint textEmote; /// `EmotesText.dbc` id
    uint emoteNum;  /// which of the emote's texts
    ulong target;
}

/// `SMSG_EMOTE`: a one-shot animation.
struct ServerEmote
{
    mixin ServerPacket!(Opcode.SMSG_EMOTE);
    uint emote;  /// `Emotes.dbc` id
    ulong guid;
}

/// `SMSG_TEXT_EMOTE`: the text of an emote, in the chat window of those around.
struct ServerTextEmote
{
    mixin ServerPacket!(Opcode.SMSG_TEXT_EMOTE);
    ulong guid;
    uint textEmote;
    uint emoteNum;
    uint targetNameLength; /// with the terminator; 1 for no target
    @CString string targetName;
}

// ---------------------------------------------------------------------------
// Teleports (MovementHandler.cpp, MiscHandler.cpp, Player::TeleportTo)
// ---------------------------------------------------------------------------

/// `SMSG_TRANSFER_PENDING`: the loading screen of a far teleport.
struct ServerTransferPending
{
    mixin ServerPacket!(Opcode.SMSG_TRANSFER_PENDING);
    uint map;
}

/// `SMSG_NEW_WORLD`: where the far teleport ends; the client answers `MSG_MOVE_WORLDPORT_ACK` once loaded.
struct ServerNewWorld
{
    mixin ServerPacket!(Opcode.SMSG_NEW_WORLD);
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
}

/// `TransferAbortReason`
enum TransferAbortReason : ubyte
{
    TRANSFER_ABORT_NONE = 0x00,
    TRANSFER_ABORT_MAX_PLAYERS = 0x01,
    TRANSFER_ABORT_NOT_FOUND = 0x02,
    TRANSFER_ABORT_TOO_MANY_INSTANCES = 0x03,
    TRANSFER_ABORT_ZONE_IN_COMBAT = 0x05,
}

/// `SMSG_TRANSFER_ABORTED`
struct ServerTransferAborted
{
    mixin ServerPacket!(Opcode.SMSG_TRANSFER_ABORTED);
    TransferAbortReason reason;
}

/// `SMSG_AREA_TRIGGER_MESSAGE`: a yellow message, such as a dungeon's level requirement.
struct ServerAreaTriggerMessage
{
    mixin ServerPacket!(Opcode.SMSG_AREA_TRIGGER_MESSAGE);
    uint length; /// with the terminator
    @CString string text;

    ///
    this(string text)
    {
        this.length = cast(uint) text.length + 1;
        this.text = text;
    }
}

/// `CMSG_AREATRIGGER`: the client walked into an `AreaTrigger.dbc` zone.
struct ClientAreaTrigger
{
    uint id;
}

/// `CMSG_WORLD_TELEPORT`: the client's `worldport` console command, for administrators.
struct ClientWorldTeleport
{
    uint time;
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
}

/// `MSG_MOVE_TELEPORT_ACK` from the client: it has arrived at a near teleport's destination.
struct ClientTeleportAck
{
    ulong guid;
    uint counter;
    uint time;
}

// ---------------------------------------------------------------------------
// Groups (GroupHandler.cpp)
// ---------------------------------------------------------------------------

/// `PartyOperation`
enum PartyOperation : uint
{
    PARTY_OP_INVITE = 0,
    PARTY_OP_LEAVE = 2,
}

/// `PartyResult`
enum PartyResult : uint
{
    ERR_PARTY_RESULT_OK = 0,
    ERR_BAD_PLAYER_NAME_S = 1,
    ERR_TARGET_NOT_IN_GROUP_S = 2,
    ERR_GROUP_FULL = 3,
    ERR_ALREADY_IN_GROUP_S = 4,
    ERR_NOT_IN_GROUP = 5,
    ERR_NOT_LEADER = 6,
    ERR_PLAYER_WRONG_FACTION = 7,
    ERR_IGNORING_YOU_S = 8,
}

/// `SMSG_PARTY_COMMAND_RESULT`
struct ServerPartyCommandResult
{
    mixin ServerPacket!(Opcode.SMSG_PARTY_COMMAND_RESULT);
    PartyOperation operation;
    @CString string member;
    PartyResult result;
}

/// `CMSG_GROUP_INVITE`, `CMSG_GROUP_UNINVITE`
struct ClientGroupName
{
    @CString string name;
}

/// A packet that only carries a guid: `CMSG_GROUP_UNINVITE_GUID`, `CMSG_GROUP_SET_LEADER`,
/// `CMSG_REQUEST_PARTY_MEMBER_STATS`.
struct ClientGuid
{
    ulong guid;
}

/// `SMSG_GROUP_INVITE`: the invitation dialog.
struct ServerGroupInvite
{
    mixin ServerPacket!(Opcode.SMSG_GROUP_INVITE);
    @CString string inviter;
}

/// `SMSG_GROUP_DECLINE`: told to the leader.
struct ServerGroupDecline
{
    mixin ServerPacket!(Opcode.SMSG_GROUP_DECLINE);
    @CString string name;
}

/// `SMSG_GROUP_UNINVITE`: "You have been removed from the group."
struct ServerGroupUninvite
{
    mixin ServerPacket!(Opcode.SMSG_GROUP_UNINVITE);
}

/// `SMSG_GROUP_SET_LEADER`
struct ServerGroupSetLeader
{
    mixin ServerPacket!(Opcode.SMSG_GROUP_SET_LEADER);
    @CString string name;
}

/// `SMSG_GROUP_DESTROYED`
struct ServerGroupDestroyed
{
    mixin ServerPacket!(Opcode.SMSG_GROUP_DESTROYED);
}

/// `CMSG_LOOT_METHOD`
struct ClientLootMethod
{
    uint method;
    ulong master;
    uint threshold;
}

/// `CMSG_GROUP_CHANGE_SUB_GROUP`
struct ClientGroupChangeSubGroup
{
    @CString string name;
    ubyte subGroup;
}

/// `CMSG_GROUP_SWAP_SUB_GROUP`
struct ClientGroupSwapSubGroup
{
    @CString string first;
    @CString string second;
}

/// `CMSG_GROUP_ASSISTANT_LEADER`
struct ClientGroupAssistantLeader
{
    ulong guid;
    ubyte flag;
}

/// `MSG_MINIMAP_PING` from the client.
struct ClientMinimapPing
{
    float x = 0;
    float y = 0;
}

/// `MSG_MINIMAP_PING` to the group.
struct ServerMinimapPing
{
    mixin ServerPacket!(Opcode.MSG_MINIMAP_PING);
    ulong guid;
    float x = 0;
    float y = 0;
}

/// `MSG_RANDOM_ROLL` from the client.
struct ClientRandomRoll
{
    uint minimum;
    uint maximum;
}

/// `MSG_RANDOM_ROLL`: the result, to the roller's group.
struct ServerRandomRoll
{
    mixin ServerPacket!(Opcode.MSG_RANDOM_ROLL);
    uint minimum;
    uint maximum;
    uint roll;
    ulong guid;
}

/// `SMSG_RAID_INSTANCE_INFO`: the raids the player is saved to.
struct ServerRaidInstanceInfo
{
    mixin ServerPacket!(Opcode.SMSG_RAID_INSTANCE_INFO);
    uint count; /// instance binds are not kept yet
}

// ---------------------------------------------------------------------------
// Channels (ChannelHandler.cpp)
// ---------------------------------------------------------------------------

/// `CMSG_JOIN_CHANNEL`, `CMSG_CHANNEL_PASSWORD`
struct ClientChannelPassword
{
    @CString string channel;
    @CString string password;
}

/// `CMSG_LEAVE_CHANNEL`, `CMSG_CHANNEL_LIST`, `CMSG_CHANNEL_OWNER`, `CMSG_CHANNEL_ANNOUNCEMENTS`,
/// `CMSG_CHANNEL_MODERATE`
struct ClientChannelName
{
    @CString string channel;
}

/// The channel commands aimed at a player: set owner, (un)moderator, (un)mute, invite, kick, (un)ban.
struct ClientChannelTarget
{
    @CString string channel;
    @CString string target;
}

// ---------------------------------------------------------------------------
// What GM commands change (Player::SetSpeedRate, SetRoot, LearnSpell, GiveLevel, ...)
// ---------------------------------------------------------------------------

/// The orders that only name the player and count: `SMSG_FORCE_MOVE_ROOT`, `SMSG_FORCE_MOVE_UNROOT`,
/// `SMSG_MOVE_WATER_WALK`, `SMSG_MOVE_LAND_WALK`. The client acknowledges each.
struct ServerMovementOrder(Opcode code)
{
    mixin ServerPacket!code;
    @PackedGuid ulong guid;
    uint counter;
}

/// `SMSG_FORCE_*_SPEED_CHANGE`: the player's own speed.
struct ServerForceSpeedChange(Opcode code)
{
    mixin ServerPacket!code;
    @PackedGuid ulong guid;
    uint counter;
    float speed = 0;
}

/// `SMSG_MOVE_KNOCK_BACK`
struct ServerKnockBack
{
    mixin ServerPacket!(Opcode.SMSG_MOVE_KNOCK_BACK);
    @PackedGuid ulong guid;
    uint counter;
    float cos = 0;
    float sin = 0;
    float horizontalSpeed = 0;
    float verticalSpeed = 0;
}

/// `SMSG_LEARNED_SPELL`
struct ServerLearnedSpell
{
    mixin ServerPacket!(Opcode.SMSG_LEARNED_SPELL);
    uint spell;
}

/// `SMSG_REMOVED_SPELL`
struct ServerRemovedSpell
{
    mixin ServerPacket!(Opcode.SMSG_REMOVED_SPELL);
    ushort spell;
}

/// `SMSG_ITEM_PUSH_RESULT` (`Player::SendNewItem`): "You receive item: ..."
struct ServerItemPushResult
{
    mixin ServerPacket!(Opcode.SMSG_ITEM_PUSH_RESULT);
    ulong player;
    uint received;      /// 0 looted, 1 from an NPC
    uint created;       /// 0 received, 1 created
    uint showInChat = 1;
    ubyte bag;          /// the bag's slot, or 255 for the player's own slots
    uint slot;          /// `uint.max` when added to a stack
    uint entry;
    uint suffixFactor;
    int randomPropertyId;
    uint count;
}

/// `SMSG_LEVELUP_INFO`: the level reached and what it added.
struct ServerLevelUpInfo
{
    mixin ServerPacket!(Opcode.SMSG_LEVELUP_INFO);
    uint level;
    uint health;
    uint[5] powers;
    uint[5] stats;
}

/// `ServerMessageType`
enum ServerMessageType : uint
{
    shutdownTime = 1,
    restartTime = 2,
    text = 3,
    shutdownCancelled = 4,
    restartCancelled = 5,
}

/// `SMSG_SERVER_MESSAGE`: a red message in the middle of the screen, such as a shutdown countdown.
struct ServerServerMessage
{
    mixin ServerPacket!(Opcode.SMSG_SERVER_MESSAGE);
    ServerMessageType type;
    @CString string text;
}

/// `SMSG_UPDATE_WORLD_STATE`
struct ServerUpdateWorldState
{
    mixin ServerPacket!(Opcode.SMSG_UPDATE_WORLD_STATE);
    uint state;
    uint value;
}

/// `SMSG_SUMMON_REQUEST`: someone offers to summon the player (`Player::SendSummonRequest`).
struct ServerSummonRequest
{
    mixin ServerPacket!(Opcode.SMSG_SUMMON_REQUEST);
    ulong summoner;
    uint zone;
    uint timeoutMs;
}

/// `CMSG_SUMMON_RESPONSE`: the player accepts a summon (1.12 sends nothing when it declines).
struct ClientSummonResponse
{
    ulong summoner;
}

/// `SMSG_PLAY_SOUND`
struct ServerPlaySound
{
    mixin ServerPacket!(Opcode.SMSG_PLAY_SOUND);
    uint sound;
}

static assert(wireSize!ServerItemPushResult == 8 + 4 * 3 + 1 + 4 * 5);
static assert(wireSize!ServerLevelUpInfo == 48);

static assert(wireSize!ServerNewWorld == 20);
static assert(wireSize!ClientWorldTeleport == 24);
static assert(wireSize!ClientLootMethod == 16);
static assert(wireSize!ServerRandomRoll == 20);

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
    return encodePacket(T.opcode, payload.data, crypt);
}

/// Frames a body that is already serialized, e.g. one body sent to many players.
ubyte[] encodePacket(Opcode opcode, const(ubyte)[] body_, ref HeaderCrypt crypt)
out (bytes; bytes.length == serverHeaderLength + body_.length)
{
    enforce!PacketException(body_.length + 2 <= ushort.max, "packet too large");

    ubyte[serverHeaderLength] header;
    header[0 .. 2] = nativeToBigEndian(cast(ushort)(body_.length + 2));
    header[2 .. 4] = nativeToLittleEndian(cast(ushort) opcode);
    crypt.encryptHeader(header);
    return header ~ body_;
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
