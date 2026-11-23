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

@safe: // the compiler checks every function here

/// Changes whenever a message changes; nodes speaking another version are turned away.
enum ushort protocolVersion = 83; // 83: migrate pending projectile impacts with player and creature casters

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
    friendStatus = 42,
    guildReload = 43,
    guildBroadcast = 44,
    guildInvitation = 45,
    serviceCall = 46,
    serviceReply = 47,
    serviceNews = 48,
    creatureLoan = 49,
    groupLootRoll = 50,
    lootCoinShare = 51,
    questLootCheck = 52,
    partyHeal = 53,
    areaDamage = 54,
    creatureSwing = 55,
    periodicResult = 56,
    sessionRoute = 57,
    quorumVote = 58,
    quorumWorkerLease = 59,
    gameObjectSpell = 60,
    partyQuest = 61,
}

/// Group quest offers cross the same realm's ownership boundaries. The sharer authorizes acceptance.
struct PartyQuest
{
    enum type = MessageType.partyQuest;
    enum Action : ubyte { offer, escort, confirm, grant }
    Action action;
    ulong sharer, member;
    uint group, quest, map, instance;
    float x, y, z;
    long deadline;
}

/// Request the owning node's animation of a game object named by a spell.
struct GameObjectSpell
{
    enum type = MessageType.gameObjectSpell;

    ulong sequence;
    ulong caster, target;
    uint spell, map, instance;
    ubyte effect;
    float x, y, z;
    bool triggered, reply;
}

/// A candidate's lease round, or a voter's reply with its latest durable term.
struct QuorumVote
{
    enum type = MessageType.quorumVote;

    ulong term, round, seenTerm;
    bool reply, granted;
}

/// A worker's fresh challenge and the remaining authority granted in its reply.
struct QuorumWorkerLease
{
    enum type = MessageType.quorumWorkerLease;

    ulong term, stamp;
    uint remainingMs;
    bool reply;
    ulong appliedVersion; /// the ownership table the requesting worker has applied under this term's lease
}

/// The target's node reports a resolved tick to the caster's node.
struct PeriodicResult
{
    enum type = MessageType.periodicResult;

    ulong sequence, caster, target;
    uint map, instance, spell;
    ubyte effect;
    uint damage; /// resolved damage before capping it by health
    uint drained; /// actual health or power taken by a leech
    bool targetAlive;
    bool forwarded;
    bool detached; /// a triggered aura does not have a caster channel to maintain
    @LengthPrefix!ubyte RemoteSpellBenefit[] benefits;
}

/// A creature's main-hand swing addressed to the node that owned its target.
struct CreatureSwing
{
    enum type = MessageType.creatureSwing;

    ulong sequence, attacker, target;
    ulong controller; /// the controlling player at the time of the swing, or zero for a wild creature
    uint map, instance;
    ushort destination;
    float facing;
    bool running;
    uint school, armorIgnored;
    float minDamage, maxDamage, damageFactor, crit, critVersus, hitBonus;
    uint spell; /// zero for an ordinary swing
    int spellValue; /// the attacker's roll for its weapon effect
    float spellThreat = 1;
    bool secondary; /// another target of the same weapon cast will announce it

    // The target's node returns the outcome of an accepted swing.
    bool reply;
    ubyte outcome, spellMiss;
    uint damage, absorbed;
    bool killed, targetPvP;
    @LengthPrefix!ubyte SwingRetaliation[] retaliation;
}

/// Damage from a shield or a block proc on the player who was struck.
struct SwingRetaliation
{
    uint damage, school;
    uint spell; /// zero for SMSG_SPELLDAMAGESHIELD, otherwise the spell for SMSG_SPELLNONMELEEDAMAGELOG
    float threatFactor = 1;
}

/// One target's share of a hostile area or chain cast, with the caster's spell modifiers.
struct AreaDamage
{
    enum type = MessageType.areaDamage;
    enum int completedChannel = -1; /// auraMs for a named channel confirmed complete by its caster

    ulong sequence;
    ulong caster;
    ulong target;
    uint spell;
    ubyte effect;
    uint map;
    uint instance;
    ulong previous; /// the previous chain target, or zero for a caster-centered effect
    float x, y, z, radius;
    uint casterLevel;
    float amount;
    float threatFactor = 1;
    float hitBonus, critChance, frozenCritBonus, critBonusFactor, critBonusFlat;
    int resistanceModifier;
    bool alwaysHits;
    bool triggered; /// a targeted proc instead of an area or chain hit
    bool creatureCast; /// a regular cast aimed at a player by a creature on another node
    bool creatureArea; /// hostile area or cone of a creature spell
    bool namedCreature; /// the spell selects a living creature by its spell_script_target entry
    bool channelled;   /// a player started a channel on its own node
    bool channelUpdate; /// shorten (positive auraMs), cancel (zero), or complete (completedChannel)
    bool groundTick; /// a tick of a persistent effect centered on the spot, independent of the caster's position
    ushort groundRedirect; /// reply: new target owner; request: previous owner already declined the tick
    uint groundAmount; /// before the caster's and recipient's damage factors, for a tick redirected here
    float facing;      /// the creature's orientation at completion
    bool auraAbsent; /// the caster asked to apply this aura only if it is absent
    bool suppressProcs;
    int auraMs;
    int[3] auraValues;

    // The target node fills these after checking eligibility and rolling the hit.
    bool reply;
    ubyte miss;
    uint damage, absorbed, resisted;
    bool critical, targetPvP, killed, honorless;
    ubyte targetRace, targetRank;
    byte targetVisualRank;
    uint targetLevel;
    @LengthPrefix!ubyte RemoteSpellBenefit[] benefits;
    ulong channelToken; /// identifies one named channel across messages and target owners
}

/// A proc on the victim's aura that benefits the original caster.
struct RemoteSpellBenefit
{
    uint spell;
    int amount;
}

/// A single party member's heal, prepared by the caster's node and applied by the recipient's node.
struct PartyHeal
{
    enum type = MessageType.partyHeal;

    ulong sequence;
    ulong caster;
    ulong target;
    uint spell;
    ubyte effect;
    uint map;
    uint instance;
    uint group;
    ulong previous; /// the previous Chain Heal target, or zero for a caster-centered party heal
    float x, y, z, radius;
    uint amount; /// before the target's modifiers on request, the logged heal on reply
    float threatFactor = 1;
    float threatFlat;
    bool critical;
    bool landed;
    bool pvp;
    bool contested;
    bool inPvPCombat;
    bool causedThreat;
    bool suppressProcs;
}

/// Checks which quest loot slots a remote group member needs. Zero entries are not quest items.
struct QuestLootCheck
{
    enum type = MessageType.questLootCheck;

    uint map;
    ulong loot;
    ulong player;
    ulong sequence;
    bool reply;
    ushort eligible; /// a bit per slot in a reply
    @LengthPrefix!ubyte uint[] items; /// indexed by slot in a request
}

/// One player's share of a coin drop, sequenced by the node that divided it.
struct LootCoinShare
{
    enum type = MessageType.lootCoinShare;

    ulong sequence;
    ulong player;
    uint map;
    uint copper;
}

/// Votes and awards go only between the corpse's node and a participant's node.
struct GroupLootRoll
{
    enum type = MessageType.groupLootRoll;
    enum Action : ubyte { offer, vote, award, result, masterAward }

    Action action;
    uint map;
    ulong loot;
    ulong player;
    ulong roll;
    ubyte slot;
    uint item;
    uint count;
    int randomProperty;
    uint condition;
    bool needBeforeGreed;
    ubyte choice;
    bool stored;
    ubyte inventoryError; /// InventoryResult for a rejected master award
}

struct CreatureLoan
{
    enum type = MessageType.creatureLoan;

    enum Action : ubyte { lend, returnHome, retire }
    Action action;
    uint spawn;
    uint map;
    ulong cell;
    ulong caller;
    ulong enemy;
    ulong epoch;
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
    wrongRealm = 7,       /// a different realm on the login server
}

/// A frame's header.
struct FrameHeader
{
    uint length;
    MessageType type;
    ushort flags;
    ulong sequence;
}

enum ushort termFrame = 1; // the payload starts with the elected term

/// The first message each way on a link: who the sender is.
struct Hello
{
    enum type = MessageType.hello;

    ushort protocol = protocolVersion;
    @LengthPrefix!ubyte string cluster;
    ushort nodeId;
    ulong incarnation;      /// larger for every start of the process
    @LengthPrefix!ubyte string address; /// "host:port" others dial it at
    @LengthPrefix!ubyte string clientAddress; /// "host:port" clients connect to
    bool coordinator;       /// whether the sender is the coordinator
    ushort expected;        /// the node the dialer meant to reach; 0 for the coordinator
    bool gateway;           /// a gateway (docs/SERVICES.md): clients' connections, no regions or services
    ulong quorum;           /// fixed voter roster and lease identity, or zero for the original mode
    uint realmId = 1;       /// the login server's realm ID, shared by all nodes in this cluster
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
    ulong received;        /// the highest sequence number the sender has received from the peer (all below too)
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

    ulong coordinatorIncarnation; /// elected term in quorum mode, coordinator incarnation otherwise
    ulong version_;
    @LengthPrefix!ushort ViewMember[] members;
}

/// The coordinator's region table: who owns what. Sent whole when it changes; it is small.
struct RegionTable
{
    enum type = MessageType.regionTable;

    ulong coordinatorIncarnation; /// elected term in quorum mode, coordinator incarnation otherwise
    ulong version_;
    @LengthPrefix!ushort Region[] regions;
}

/// A member has stopped simulating a region the coordinator revoked.
struct RegionReleased
{
    enum type = MessageType.regionReleased;

    uint region;
    ulong epoch;    /// the grant given up; a release of another epoch counts for nothing
    @LengthPrefix!uint ubyte[] objects; /// the state of its objects, for the next owner; may be empty
}

/// The state of a region's objects from its last owner, sent ahead of the grant on the same link.
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
    uint pet;
}

/// The cells of a map the sender's players became near (`added`) and left (`removed`).
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

/// The exact process that may simulate a gateway's character.
struct SimulationOwner
{
    ushort node;
    ulong incarnation;
}

enum SessionRouteKind : ubyte { move, recover, observe, stopped }
enum SessionRouteResult : ubyte { retry, denied, granted }

/// The gateway asks the coordinator to record and fence changes to the simulation owner.
struct SessionRoute
{
    enum type = MessageType.sessionRoute;

    SessionRouteKind kind;
    uint account, character;
    ulong serial, token;
    SimulationOwner previous, next;
    bool reply;
    SessionRouteResult result;
}

/// What a `PlayerMessage` is (a player simulated on another node than its client's).
enum PlayerMessageKind : ubyte
{
    migrate = 1,     /// the player's simulation moves to the receiver (`data`: its state)
    toOwner = 2,     /// a packet from the client, for the node that simulates the player
    toHome = 3,      /// a packet for the client, to the node that holds its connection
    left = 4,        /// the player left the world on the owner (`opcode` 1: to the character screen)
    disconnect = 5,  /// the client is gone: the owner saves the player and says `left`
    moved = 6,       /// to the home: the player's simulation moved on to node `opcode`
    gatewayMove = 7, /// the old owner saved and stopped; the gateway is to route the state to `opcode`
    gatewayArrival = 8, /// a migration forwarded by the gateway after the coordinator recorded the route
    gatewayRecover = 9, /// resume the saved character after the coordinator fenced the old owner
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

/// A packet for every player within `range` of a point (say, yell, emotes).
struct InRange
{
    enum type = MessageType.inRange;

    uint map;
    float x, y, z;
    float range;
    ushort opcode;
    @LengthPrefix!uint ubyte[] body_;
}

/// A player as other nodes need to know it to whisper it or list it.
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
    @LengthPrefix!ubyte string permissions; /// the account's GM permission letters (`.gm list`)
}

/// The players the sender simulates that changed (`entries`) or left (`gone`).
struct Presence
{
    enum type = MessageType.presence;

    bool full;           /// `entries` is everything: forget what the sender said before
    @LengthPrefix!uint PresenceEntry[] entries;
    @LengthPrefix!uint ulong[] gone;
}

/// A packet for one player the receiver simulates (a whisper).
struct DeliverTo
{
    enum type = MessageType.deliverTo;

    ulong guid;
    ushort opcode;
    @LengthPrefix!uint ubyte[] body_;
}

/// A whisper for a player the receiver simulates; it checks and delivers it, and answers the sender.
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

/// A player on the sender buys a limited item from a creature the receiver simulates: reserve it.
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

/// What a `ChannelCommand` does.
enum ChannelOp : ubyte
{
    join,           /// `arg`: the password
    leave,
    list,
    password,       /// `arg`: the new password
    owner,
    announcements,
    moderate,
    setOwner,       /// `arg`, here and below: the target's name
    moderator,
    unmoderator,
    mute,
    unmute,
    invite,
    kick,
    ban,
    unban,
    say,            /// `arg`: the text, in `language`
    leaveAll,       /// logging out
    zoneChanged,    /// `arg`: the new zone's name
    forcedSay,      /// `arg`: the text, to every member of an existing channel, its sayer a member or not
}

/// What a `GroupCommand` does.
enum GroupOp : ubyte
{
    invite,          /// `text`: the invitee's name
    accept,
    decline,
    uninviteGuid,    /// `target`
    uninvite,        /// `text`: the name
    setLeader,       /// `target`
    disband,         /// leaving, or giving up a group that never formed
    lootMethod,      /// `number`: the method, `target`: the master looter, `number2`: the threshold
    targetIcon,      /// `number`: the icon, `target`: what it marks
    raidConvert,
    changeSubGroup,  /// `text`: the member's name, `number`: the sub-group
    swapSubGroup,    /// `text`, `text2`: the two members' names
    assistant,       /// `target`, `number`: set (1) or not (0)
    logout,          /// `number`: 1 when logging out normally, 0 for a lost connection
    battlegroundAdd, /// `target` (named `text`) joins its team's battleground raid, whose leader gives the command
    meetingStoneJoin,  /// at a meeting stone: `number` its area, `number2` the player's class (alone, or its party)
    meetingStoneLeave, /// out of the meeting stone's queue
    meetingStoneInfo,  /// the stone's window asks how the player stands
}

/// What a `GmRemote` does to its target.
enum GmRemoteOp : ubyte
{
    kick,         /// `.kick`; `text`: the reason
    summon,       /// `.summon`: to the GM's map and position
    appear,       /// `.appear`: the GM comes to the target (`appearAt` goes back)
    appearAt,     /// the target's map and position, for the GM
    disconnect,   /// `.kill`-by-name: the player's session is disconnected
    banKick,      /// `.ban character`: the account is banned already; the player goes
    rename,       /// `.rename`: the database has the new name (`text`) already
    playerInfo,   /// `.playerinfo`
    kill,         /// `.killplr`; `text`: the name as the GM typed it
    revive,       /// `.reviveplr`; `text`: ditto
    saveAll,      /// `.server saveall`: every node saves its players (no target)
    massSummon,   /// `.masssummon`: every node asks its players to the GM's place; `text`: the GM's zone
    instanceInfo,     /// `.instance info` of copy `instance`, on its dungeon's host (no target)
    instanceShutdown, /// `.instance shutdown` of copy `instance`, ditto
    instanceReset,    /// `.instance reset` of copy `instance` for the player `target`, ditto
    instanceResetAll, /// `.instance resetall`: the player `target`'s copies each node hosts
}

/// A player's chat channel command, for the coordinator, which keeps the channels.
struct ChannelCommand
{
    enum type = MessageType.channelCommand;

    ulong guid;
    @LengthPrefix!uint string name;
    ubyte race;
    bool moderateAll;      /// the `c` permission: moderates every channel
    ubyte chatTag;
    ChannelOp op;
    @LengthPrefix!uint string channel;
    @LengthPrefix!uint string arg;
    uint language;
    byte pvpRank;          /// the visual honor rank (-4 to 14), for the defense channels
}

/// A player's group command (invitations, kicks, the leader, loot, raids), for the coordinator.
struct GroupCommand
{
    enum type = MessageType.groupCommand;

    ulong guid;
    @LengthPrefix!uint string name;
    ubyte race;
    bool permissions;      /// any GM permission: invites across factions
    GroupOp op;
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

/// A packet for every player the receiver simulates (world texts); with `permission`, only for
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

    GmRemoteOp op;
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
 * A player's share of a kill on the sender, for the node simulating that player.
 * Creature kills carry quest credit, experience and reputation. Periodic PvP kills carry the honor victim.
 */
struct KillShare
{
    enum type = MessageType.killShare;

    ulong target;          /// the player receiving credit
    ulong victim;          /// the creature or player killed
    uint entry;            /// the creature's entry; 0 for a PvP kill
    uint level;            /// its level
    uint xp;               /// the member's experience (0: none)
    float rate;            /// the group rate the experience came with
    float reputationRate;  /// the share of the kill's reputation (0: none)
    uint map, instance;    /// PvP victim's map and position for group reward range
    float x, y, z;
    ubyte race, rank;
    byte visualRank;
    bool honorless;
    bool forwarded;        /// the recipient's old node passed the credit to its new owner
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

/// A player of the sender logged in or out: its friends on the receiver hear of it.
struct FriendStatusChange
{
    enum type = MessageType.friendStatus;

    ulong guid;
    bool online;
    ubyte status; /// `FriendStatus`
    uint area, level, classId;
}

/// The sender changed guild `guild` (in the database): read it again.
struct GuildReload
{
    enum type = MessageType.guildReload;

    uint guild;
}

/// A guild's packet for its members on the receiver whose rank has `right` (0: all).
struct GuildBroadcast
{
    enum type = MessageType.guildBroadcast;

    uint guild;
    uint right;
    ushort opcode;
    @LengthPrefix!uint ubyte[] body_;
}

/// A guild's invitation for a player the receiver simulates.
struct GuildInvitation
{
    enum type = MessageType.guildInvitation;

    ulong target;
    uint guild;
    ulong inviter;
    @LengthPrefix!uint string inviterName;
    @LengthPrefix!uint string guildName;
}

/// To the coordinator: the sender is shutting down; its regions should go to the others first.
struct Drain
{
    enum type = MessageType.drain;

    ulong incarnation;
}

/// What one region cost its owner: µs of loop time a second.
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

/// From the standby: the coordinator is gone and the sender is the coordinator now.
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
    @LengthPrefix!uint GatewaySessionRoute[] gatewayRoutes;
}

/// A gateway's last acknowledged route, including an owner that disappeared before takeover.
struct GatewaySessionRoute
{
    uint account, character;
    ulong serial, token;
    SimulationOwner owner;
    ulong term;
}

/// Appends a framed message to `writer`.
void putMessage(M)(ref ByteWriter writer, ulong sequence, auto ref const M message, ulong term = 0)
{
    const start = writer.length;
    writer.put(uint(0));
    writer.put(cast(ushort) M.type);
    writer.put(term ? termFrame : ushort(0));
    writer.put(sequence);
    if (term)
        writer.put(term);
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
    if (header.flags & ~termFrame)
        throw new PacketException("unknown cluster frame flags");
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
    assert(decode!Heartbeat(payload) == Heartbeat(100, 50, 3, 400, 2, 900) && payload.length == 40);
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
    auto bad = new ubyte[frameHeaderSize];
    const(ubyte)[] badInput = bad;
    const(ubyte)[] badPayload;
    bad[4] = 99; // type
    assertThrown!PacketException(takeFrame(badInput, header, badPayload));
    bad[4] = 3;
    bad[3] = 0x7F; // length
    badInput = bad;
    assertThrown!PacketException(takeFrame(badInput, header, badPayload));
    assertThrown!PacketException(decode!Heartbeat(new ubyte[37]));
}

/// A call of a cluster service on the node that hosts it (docs/SERVICES.md): `dmangos.cluster.services`.
struct ServiceCall
{
    enum type = MessageType.serviceCall;

    ushort kind;       /// `ServiceKind`
    ulong call;        /// `callId`: the method, and its request's and reply's layout
    ushort origin;     /// the calling node
    ulong sequence;    /// the caller's number for it: the reply's key, and a resent duplicate's
    @LengthPrefix!uint ubyte[] request;
}

/// How a `ServiceCall` went (one byte on the wire; a value not listed here is refused when the reply is read).
enum ServiceStatus : ubyte
{
    ok = 0,
    notHere = 1,       /// the service does not run on that node (any more): ask again where it is
    unknownCall = 2,   /// that node's build has no such call
}

/// The answer to a `ServiceCall`.
struct ServiceReply
{
    enum type = MessageType.serviceReply;

    ushort kind;
    ulong sequence;
    ServiceStatus status;
    @LengthPrefix!uint ubyte[] reply;
}

/**
 * News a cluster service gives every node (docs/SERVICES.md, `ServiceHost.announce`): the war effort's
 * state, say. `news` names the news's type and layout (`newsId`).
 */
struct ServiceNews
{
    enum type = MessageType.serviceNews;

    ushort kind;       /// `ServiceKind`
    ulong news;        /// `newsId`
    @LengthPrefix!uint ubyte[] body_;
}

// A reply's status is checked as it is read: a peer cannot put an unknown one in front of a final switch.
unittest
{
    import std.exception : assertThrown;
    import dmangos.bytes : ByteReader, ByteWriter, PacketException;
    import dmangos.serialization : deserialize, serialize;

    ByteWriter w;
    serialize(w, ServiceReply(1, 2, ServiceStatus.notHere, null));
    auto bytes = w.data.dup;
    auto good = ByteReader(bytes);
    assert(deserialize!ServiceReply(good).status == ServiceStatus.notHere);
    bytes[ushort.sizeof + ulong.sizeof] = 7; // the status byte
    auto bad = ByteReader(bytes);
    assertThrown!PacketException(deserialize!ServiceReply(bad));
}

// ---------------------------------------------------------------------------------------------------
// What the compiler checks about the protocol
// ---------------------------------------------------------------------------------------------------

/// The protocol's message structs: those with an `enum type` naming their `MessageType`.
private template messageStructs()
{
    import std.meta : AliasSeq;

    alias messageStructs = AliasSeq!();
    static foreach (name; __traits(allMembers, dmangos.cluster.protocol))
        static if (is(__traits(getMember, dmangos.cluster.protocol, name) == struct))
            static if (__traits(compiles, { enum MessageType t = __traits(getMember, dmangos.cluster.protocol, name).type; }))
                messageStructs = AliasSeq!(messageStructs, __traits(getMember, dmangos.cluster.protocol, name));
}

// Every message type has exactly one struct, and the types are contiguous (`takeFrame` checks min..max).
static assert(() {
    import std.traits : EnumMembers;

    foreach (m; EnumMembers!MessageType)
    {
        size_t structs;
        static foreach (S; messageStructs!())
            if (S.type == m)
                ++structs;
        if (structs != 1)
            return false;
    }
    return [EnumMembers!MessageType].length == MessageType.max - MessageType.min + 1;
}(), "each MessageType needs exactly one message struct, and the types must be contiguous");

/**
 * A fingerprint of every message's layout on the wire: each struct's name, its fields' types and attributes
 * (their length prefixes), and every enum's members (an enum field refuses values it does not list). It is
 * recorded for the current `protocolVersion`, so a message changed without the version raised does not
 * compile: nodes of the two builds would misread each other. Raise `protocolVersion` and record the new
 * fingerprint (the assertion's message says it).
 */
private enum ulong protocolFingerprint = () {
    string text;
    static foreach (S; messageStructs!())
    {
        text ~= __traits(identifier, S) ~ "{";
        static foreach (i, F; typeof(S.tupleof))
        {
            text ~= F.stringof ~ " " ~ __traits(identifier, S.tupleof[i]);
            static foreach (attribute; __traits(getAttributes, S.tupleof[i]))
                text ~= " @" ~ attribute.stringof;
            static if (is(F == enum))
                text ~= " " ~ [__traits(allMembers, F)].stringof;
            text ~= ";";
        }
        text ~= "}";
    }
    ulong hash = 0xcbf29ce484222325; // FNV-1a
    foreach (c; text)
    {
        hash ^= c;
        hash *= 0x100000001b3;
    }
    return hash;
}();

/// The protocol version whose messages `protocolFingerprint` was recorded for, and the fingerprint.
private enum recordedVersion = 83, recordedFingerprint = 0xde67f0a3bbbc0422UL;

static assert(protocolVersion == recordedVersion && protocolFingerprint == recordedFingerprint,
    "the cluster messages (or protocolVersion) changed: if the messages changed, raise protocolVersion; then record "
    ~ "recordedVersion = protocolVersion and recordedFingerprint = "
    ~ imported!"std.format".format!"0x%016x"(protocolFingerprint));
