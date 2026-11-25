/**
 * What the world server reads and writes in the login (`realmd`) and
 * `characters` databases, which have the CMaNGOS-classic schema.
 *
 * `MySqlWorldDatabase` runs the statements on MySQL.
 * `MemoryWorldDatabase` stands in for it in tests.
 */
module dmangos.world.database;

import dmangos.world.honorweek : HonorWeekEntry;
import dmangos.cluster.services : ServiceKind;
import std.typecons : Nullable, nullable;

import dmangos.crypto.srp6 : sessionKeyLength;
import dmangos.mysql : DatabaseException, MySqlConnection;
import dmangos.world.gmaccess : GmAccess;
import dmangos.auth.accounts : canonicalAccountName, decodeBigNumberHex;
import dmangos.world.characterdb : CharacterOwner, CharacterStatements, DeleteOptions, GuidCounters, NameInfo;
public import dmangos.world.characterdb : GroupMemberRecord, GroupRecord;
import dmangos.world.movement : Position;
import dmangos.world.motion : MotionType, WaypointNode;
import dmangos.world.creature : CreatureSpawn;
import dmangos.world.gameobject : GameObjectSpawn;
import dmangos.world.inventory : ItemChange, ItemRecord, ItemState;
import dmangos.world.npcdata : VendorItem, readVendorItems;
import dmangos.world.worldcatalog : WorldCatalog, WorldCatalogJournal, WorldCatalogKey, WorldCatalogVersion;
import dmangos.world.quests : QuestStatus;
import dmangos.world.reputation : ReputationRecord;
import dmangos.world.auctionhouse : AuctionRecord;
import dmangos.world.player : CharacterData, CharacterProgress, HomeBind, tutorialFields;
import dmangos.world.worlddata : AreaTriggerTeleport, areaTriggerTeleportQuery, creatureSpawnQuery, GameTele,
    gameObjectSpawnFromRow, gameObjectSpawnQuery, gameTeleQuery;
import dmangos.world.playercreate : NewCharacter;

import dmangos.auth.staffroles : staffAccess, changeStaffRole, defaultRoleGrants;

struct GmNameReview
{
    uint guid;
    string name;
}

/// The parts of an `account` row a world session needs.
struct WorldAccount
{
    uint id;
    string username;
    ubyte[sessionKeyLength] sessionKey;
    bool hasSessionKey;  /// False unless `sessionkey` holds a full 80-digit key.
    bool locked;
    string lockedIp;
    string os;           /// As recorded by the login server: "Win" or "OSX".
    string platform;     /// "x86" or "PPC"
    long muteTime;       /// `account.mutetime`: chat is off until this Unix time
}

/// One row of the character list query, in its column order.
struct CharacterRecord
{
    uint guid;
    string name;
    ubyte race;
    ubyte classId;
    ubyte gender;
    uint playerBytes;
    uint playerBytes2;
    ubyte level;
    uint zone;
    uint map;
    float x = 0;
    float y = 0;
    float z = 0;
    uint guildId;
    uint playerFlags;
    uint atLogin;
    uint petEntry;
    uint petModel;
    uint petLevel;
    string equipmentCache;
}

/// See the module documentation.
/// A `corpse` row.
struct CorpseRecord
{
    uint player;
    float x = 0, y = 0, z = 0, orientation = 0;
    uint map;
    long time;          /// when the spirit was released
    ubyte type;         /// a `CorpseType`
}

/// The last saved realm service state and the node that hosted it.
struct ServiceCheckpoint
{
    ulong revision;
    long at;
    ushort node;
    string state;
}

/// One durable match. An empty state retires the copy while reserving its instance ID.
struct BattlegroundCheckpoint
{
    uint instance;
    ulong revision;
    long at;
    string state;
}

/// The next round-robin recipient, or the original answer for a retried drop.
struct GroupLootRotation
{
    ulong nextLooter;
    ulong assigned;
    const(ulong)[] order;
}

struct LootCoinCredit
{
    uint player;
    uint copper;
}

struct LootCoinRedemption
{
    bool valid;
    uint wallet;
    uint copper;
}

/// The same award can reach a player again after either simulation changes workers.
struct LootAwardKey
{
    ulong token, loot;
    uint map, player;
    ubyte slot;
}

/**
 * `dmangos_loot_award.result` while a recipient's claim waits for its item to be written: the token is the
 * recipient's, but the award is not decided until the item's rows and the result commit together (`saveLootAward`).
 */
enum ubyte lootAwardClaimed = 0xff;

/**
 * How long a claim whose item was never written holds the award before the loot's node may record a refusal over
 * it (`expireLootAward`): far beyond any write a worker can still make under its lease.
 */
enum long lootAwardClaimSeconds = 600;

struct LootAwardResult
{
    bool recorded;
    ubyte error;

    /// The award is settled: stored, or refused. A recipient's claim alone is not.
    bool decided() const
    {
        return recorded && error != lootAwardClaimed;
    }

    /// The recipient took the token, but its item is not written yet.
    bool claimed() const
    {
        return recorded && error == lootAwardClaimed;
    }
}

/// A `mail` row and its one item (`mail_items`; 1.12 sends at most one).
struct MailRecord
{
    uint id;
    ubyte messageType;     /// who sent it: 0 a player
    ubyte stationery = 41;
    uint templateId;
    uint sender;
    uint receiver;
    string subject;
    uint itemTextId;       /// the body, in `item_text`
    long expireTime;
    long deliverTime;
    uint money;
    uint cod;
    uint checked;          /// the `mail.checked` flags (read, returned, ...)
    uint itemGuid;         /// 0: none
    uint itemEntry;
}

/// A `character_spell_cooldown` row: when a spell (and its category) are ready again, Unix time.
struct CooldownRecord
{
    uint spell;
    long spellExpires;    /// 0: no cooldown of its own
    uint category;
    long categoryExpires; /// 0: no category cooldown
    uint item;            /// the item it was cast from (its cooldown is the item's)
}

/// A `guild_rank` row.
struct GuildRankRecord
{
    uint id;
    string name;
    uint rights;
}

/// A `guild_member` row, with what `characters` says of the member.
struct GuildMemberRecord
{
    uint guid;
    uint rank;
    string publicNote, officerNote;
    string name;
    ubyte level, classId;
    uint zone;
    long logoutTime;
    uint account;
}

/// A `guild_eventlog` row (CMaNGOS's `GuildEventLogEntry`): who did what to whom, and when.
struct GuildEventRecord
{
    uint logGuid;   /// its place in the guild's ring of rows (1 to 99, then 0)
    ubyte type;     /// `GuildEventLogType`
    uint player1;   /// who did it (low guid)
    uint player2;   /// to whom (0: nobody)
    ubyte newRank;  /// a promotion's or demotion's new rank
    long time;      /// Unix time
}

/// A `guild` row with its ranks and members.
struct GuildRecord
{
    uint id;
    string name;
    uint leader;
    uint[5] emblem; /// style, colour, border style, border colour, background colour
    string info, motd;
    long created;
    GuildRankRecord[] ranks;
    GuildMemberRecord[] members;
    GuildEventRecord[] events; /// its event log, the oldest first (the newest 100)
}

/// A `petition` (a guild charter) and its `petition_sign`s.
struct PetitionRecord
{
    uint petition; /// the charter item's guid
    uint owner;
    string name;
    uint[] signers;
}

/// A `character_social` row of a player: another character, and whether it is a friend or ignored.
struct SocialRow
{
    uint other;
    ubyte flags; /// `SocialFlag` bits
}

/// A `character_pet` row with its `pet_spell` rows.
struct PetRecord
{
    uint id;                  /// the pet number
    uint entry;
    uint owner;
    uint modelId;
    uint createdBySpell;
    ubyte type;               /// `PetType`
    uint level = 1;
    uint exp;
    ubyte reactState;
    int loyaltyPoints;
    uint loyalty;
    uint xpForNextLoyalty;
    int trainingPoints;
    string name = "Pet";
    bool renamed;
    uint slot;                /// a `PetSlot`: 0 out with its owner, 1 and 2 stabled, 100 not in a slot
    uint health;
    uint mana;
    uint happiness;
    long saveTime;
    string actionBar;         /// `abdata`: type and action of each of the ten buttons
    string teachSpells;       /// `teachspelldata`
    uint resetCost;           /// `resettalents_cost`: what its last untraining cost
    long resetTime;           /// `resettalents_time`: when (Unix time)
    PetSpellRecord[] spells;
}

/// A `pet_spell` row: a spell the pet knows, and its autocast state (an `ActiveState`).
struct PetSpellRecord
{
    uint spell;
    ubyte active;
}

/// A `character_aura` row.
struct AuraRecord
{
    ulong caster;
    uint spell;
    uint stacks = 1;
    int[3] amount;       /// `basepointsN`: the effects' amounts
    int[3] periodTimer;  /// `periodictimeN`: until each next tick
    int maxDuration;
    int remaining;       /// `remaintime`: -1 until cancelled
    uint effectMask;     /// `effIndexMask`
    uint charges;        /// Remaining proc charges. Older rows have zero.
}

/// An `instance` row.
struct InstanceRecord
{
    uint id;
    uint map;
    long resetTime; /// Unix time; 0 for a dungeon that resets when it has been empty a while
    string data;    /// its dungeon script's state (docs/SCRIPTING.md); empty if none
}

/// A `character_instance` or `group_instance` row.
struct InstanceBindRecord
{
    bool group;     /// `group_instance` (`owner` the group's leader); else `character_instance`
    uint owner;
    uint instance;
    bool permanent;
}

/// A `creature_respawn` or `gameobject_respawn` row of an instance.
struct InstanceRespawnRecord
{
    bool gameObject;
    uint spawnGuid;
    uint instance;
    long until;
}

/// The only selected placement of a single-choice world creature pool and when it may roll again.
struct CreaturePoolState
{
    uint spawn;
    long due;
    ulong revision;
}

struct GameObjectPoolPlacement
{
    uint spawn;
    long due;
}

/// Every selected placement in one outdoor object pool, including any waiting to respawn.
struct GameObjectPoolState
{
    ulong revision;
    GameObjectPoolPlacement[] placements;
}

/// The rolled contents and expiry of one scripted reward chest in a lockout.
struct InstanceChestRecord
{
    uint instance, spawn;
    long expiresAt;
    string loot;
}

/// An unexpired creature corpse and its original loot. Instance zero means an outdoor spawn.
struct InstanceCorpseRecord
{
    uint instance, spawn;
    long expiresAt;
    string state;
}

/// One living creature's rolled pockets, or the deadline when its emptied pockets refill.
struct PickpocketRecord
{
    uint instance, spawn;
    long restockAt;
    string loot;
}

/// A live quest escort or follower and the temporary creatures it owns in its region.
struct QuestActorCheckpoint
{
    uint map;
    ulong actor, home, player;
    long savedAt;
    string state;
}

/// A living native creature in a specific copy of a dungeon or raid.
struct DungeonFightCheckpoint
{
    uint spawn;
    string state;
}

/// The next unclaimed step of a delayed script on an outdoor region.
struct OutdoorScriptCheckpoint
{
    ushort origin;
    ulong sequence;
    uint map, cursor;
    ulong home;
    string state;
    bool waitingForSummons;
}

/// A database-script variable shared by the workers of an outdoor map in one realm.
struct OutdoorWorldState
{
    uint map, id;
    int value;
}

enum OutdoorSummonKind : ubyte { creature, gameObject, openable, scriptedObject, scriptedDespawn, relay, staticDespawn }

/// A durable summon routed by destination cell, with a receipt after the actor commits.
struct OutdoorSummonRequest
{
    ushort origin;
    ulong sequence;
    uint cursor, ordinal, map;
    ulong home;
    string state;
    ulong actor;
    QuestActorCheckpoint checkpoint;
    OutdoorSummonKind kind;

    bool sameRequest(const ref OutdoorSummonRequest other) const
    {
        return origin == other.origin && sequence == other.sequence && cursor == other.cursor && ordinal == other.ordinal;
    }
}

/// Quest rows advanced by one durable outdoor script step.
struct OutdoorQuestUpdate
{
    uint player;
    const(QuestStatus)[] quests;
}

/// A gateway player's latest summon request, including a consumed request's sequence.
struct PartySummonCheckpoint
{
    ulong sequence;
    string state;
}

/// A `character_honor_cp` row: honor from a kill or another source, on a day.
struct HonorPointRecord
{
    ubyte victimType;  /// the victim's `TypeId` (3 a creature, 4 a player; 0 no victim)
    uint victim;       /// a player's guid, a creature's entry
    float honor = 0;
    uint date;         /// `(year - 1900) << 16 | day of the year`, as the honor tables count days
    ubyte type;        /// 1 honorable, 2 dishonorable
}

/// The honor columns of `characters`.
struct HonorColumns
{
    uint highestRank;       /// `honor_highest_rank`
    uint standing;          /// `honor_standing`: last week's place
    float storedRating = 0; /// `stored_honor_rating`: the rank points
    int storedDishonorableKills;
    int storedHonorableKills;
}

/**
 * `BGData`, as `character_battleground_data` keeps it: the battleground copy a player is in (0: none),
 * its team there, and where it came from (where it goes back to).
 */
struct BattlegroundData
{
    uint instance;
    ubyte type;     /// a `BattlegroundType`
    ubyte team;     /// 0 the Alliance, 1 the Horde
    uint joinMap;
    float joinX = 0, joinY = 0, joinZ = 0, joinO = 0;
}

/// A `pvpstats_battlegrounds` row: a battle over (`winner` as the scoreboard says it: 0 the Horde, 1 the Alliance,
/// 2 nobody; `bracket` the bracket's lowest level / 10; `type` the `BattlegroundType`); its id is the table's own.
struct PvpStatsBattleground
{
    ubyte winner;
    ubyte bracket;
    ubyte type;
}

/// A `pvpstats_players` row: one player's score in it (`attr` the battleground's own columns, the first five).
struct PvpStatsPlayer
{
    uint guid;
    uint killingBlows, deaths, honorableKills, bonusHonor;
    uint[5] attr;
}

struct BattlegroundReputation
{
    uint faction;
    int amount;
}

/// Earned when the result becomes durable. The key is scoped to the recipient's home database.
struct BattlegroundReward
{
    uint realm, match, player;
    uint markSpell, honor, honorDay;
    BattlegroundReputation[] reputation;
}

/**
 * A reward an objective gives during a match (a flag captured, a tower or a mine taken, a captain slain): written with
 * the match checkpoint that records the objective (`WorldDatabase.saveBattlegroundCheckpoint`), and paid once
 * (`payBattlegroundEventReward`), to a player online or, crash-offline, when it returns. `event` is unique within the
 * match: the checkpoint's revision and the reward's place in it.
 */
struct BattlegroundEventReward
{
    BattlegroundReward reward; /// its honor and reputation (no mark)
    ulong event;
    uint castSpell;            /// a quest's credit cast on the player (`Battleground.castOnTeam`), or 0
    uint killCredit;           /// a quest's kill credit (`Battleground.killCreditToTeam`), or 0
}

/// The prepared writes for one reward. These are applied together with its receipt.
struct BattlegroundPayment
{
    uint money, playerBytes;
    ItemChange[] inventory;
    ItemRecord mailedItem;
    MailRecord mail;
    ReputationRecord[] reputation;
    QuestStatus[] quests; /// the quest log's changed rows, with a quest credit the reward gave
}

/// What `loadHonor` gives.
struct HonorRecord
{
    HonorColumns columns;
    HonorPointRecord[] points;
}

/**
 * A write that replaces everything an earlier call of the method with the same key wrote (the key: its
 * first argument, or that argument's `guid`), so a queued earlier one need not be written
 * (`dmangos.world.writebehind`).
 */
struct Replaces
{
}

/// A database method that returns or fills in data without changing durable game state.
struct DatabaseRead
{
}

/// A write that returns a value and must still respect the node's write lease.
struct DatabaseWrite
{
}

/**
 * Where the writer behind the game loop (`dmangos.world.writebehind`) records which of its writes the
 * database has, so that writing its log again after a crash skips them: the table `dmangos_write_applied`
 * in the characters database, one row per stream of writes (a server, or a node of a cluster), holding the
 * number of the newest write carried out. The row is updated in the transaction of the write itself, so
 * the two are committed together or not at all.
 *
 * Statements a write makes on the login or world database are not in that transaction: they may be made
 * twice after a crash, and are written so that this does no harm.
 */
interface WriteLedger
{
    /// Makes the ledger's table if it is missing. Throws if it cannot.
    void prepareLedger();

    /// The number of the newest write of `stream` carried out (0: none).
    ulong appliedUpTo(uint stream);

    /**
     * Runs `work` (one write) and records write `seq` of `stream` as carried out, in one transaction.
     * `beforeCommit` runs last in that transaction, just before its commit: if it throws, the transaction
     * is rolled back (nothing of the write is in the database) and the exception goes on to the caller.
     */
    void applying(uint stream, ulong seq, scope void delegate() work, scope void delegate() beforeCommit);
}

/// A `gm_tickets` row: a player's request for help.
struct TicketRecord
{
    uint id;
    uint player;      /// `author_guid`
    string name;      /// `author_name`
    uint level;
    uint map;
    float x = 0, y = 0, z = 0;
    string text;
    long created;     /// Unix time
    bool closed;      /// removed by a GM or the player (`state` 1); kept until deleted permanently
}

/// What `loadInstances` reads.
struct InstanceRecords
{
    InstanceRecord[] instances;
    InstanceBindRecord[] binds;
    InstanceRespawnRecord[] respawns;
    InstanceChestRecord[] chests;
    InstanceCorpseRecord[] corpses;
}

interface WorldDatabase
{
    /// The account named `username`, or null.
    @DatabaseRead Nullable!WorldAccount findAccount(string username);

    @DatabaseRead GmAccess gmAccessFor(uint accountId);
    @DatabaseWrite bool changeGmRole(uint accountId, string role, bool grant);

    /// Whether the account or the address has a ban in force.
    @DatabaseRead bool isBanned(uint accountId, string ip);

    /// Logs the connection in `account_logons`, with the world server as its source.
    void recordLogon(uint accountId, string ip);

    /// The account's characters on this realm, by guid.
    @DatabaseRead CharacterRecord[] characters(uint accountId);

    // --- character creation and deletion ---

    /// Next free character, item and mail ids.
    @DatabaseRead GuidCounters highestGuids();

    /// Whether a character already has this (normalized) name.
    @DatabaseRead bool nameTaken(string name);

    /// Characters on every realm, from `realmcharacters`.
    @DatabaseRead uint accountCharacterTotal(uint accountId);

    /// Characters on this realm.
    @DatabaseRead uint realmCharacterCount(uint accountId);

    /// Races of the account's characters on this realm, in table order.
    @DatabaseRead ubyte[] characterRaces(uint accountId);

    /// Whether the account has its `character_tutorial` row.
    @DatabaseRead bool hasTutorialData(uint accountId);

    /// Stores a newly created character (and, if asked, the account's empty tutorial row).
    void saveNewCharacter(const ref NewCharacter character, bool insertTutorialData);

    /// Sets `realmcharacters.numchars` for this realm.
    void setRealmCharacterCount(uint accountId, uint realmId, uint count);

    /// The account, name and level of a character, or null.
    @DatabaseRead Nullable!CharacterOwner characterOwner(uint guid);

    /// Whether the character leads a guild.
    @DatabaseRead bool isGuildLeader(uint guid);

    /// Deletes (or unlinks) a character and everything that belongs to it.
    void deleteCharacter(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId);

    // --- entering and leaving the world ---

    /// Everything logging in reads about a character, or null if there is no such character.
    @DatabaseRead Nullable!CharacterData loadCharacter(uint guid);

    /// Stores the home a character without one gets.
    void insertHomeBind(uint guid, const HomeBind bind);

    /// The hearthstone's new place.
    void updateHomeBind(uint guid, const HomeBind bind);

    /// Marks a character (and its account, on this realm) as online or offline.
    void setOnline(uint guid, uint accountId, bool online, uint realmId);

    /// At start-up: marks every character and account of this realm as offline.
    void markAllOffline(uint realmId);

    /// Saves where a character is and what changed while it played.
    @Replaces void saveProgress(const ref CharacterProgress progress);

    /// Sets (or, with action 0, clears) an action bar button.
    void setActionButton(uint guid, ubyte button, uint action, ubyte type);

    /// Saves the account's tutorial flags.
    void saveTutorials(uint accountId, const uint[tutorialFields] tutorials);

    /// A player's corpse (its row replaces any earlier one).
    void saveCorpse(const ref CorpseRecord corpse);

    /// The player's corpse is gone.
    void deleteCorpse(uint player);

    /// The player's corpse, if it has one.
    @DatabaseRead Nullable!CorpseRecord loadCorpse(uint player);

    /// A dead creature comes back at `respawnTime` (0: forget it).
    void saveCreatureRespawn(uint spawnGuid, long respawnTime);

    /// The persisted choices for this realm's single-choice world creature pools, keyed by pool.
    @DatabaseRead CreaturePoolState[uint] loadCreaturePoolStates(uint realm);

    /// Claim the initial row (revision 0) or update the expected revision. A stale owner cannot renew it.
    @DatabaseWrite bool updateCreaturePoolState(uint realm, uint pool, ulong revision, uint spawn, long due,
        const InstanceCorpseRecord corpse = InstanceCorpseRecord.init);
    @DatabaseRead GameObjectPoolState[uint] loadGameObjectPoolStates(uint realm);
    @DatabaseWrite bool updateGameObjectPoolState(uint realm, uint pool, const ref GameObjectPoolState state,
        uint exhaustedChest = 0);

    /// The player's auras, replacing those saved before.
    @Replaces void saveAuras(uint player, const(AuraRecord)[] auras);

    /// Every guild, with its ranks and members; one guild alone.
    @DatabaseRead GuildRecord[] loadGuilds();
    /// ditto
    @DatabaseRead Nullable!GuildRecord loadGuild(uint id);
    @DatabaseRead ulong guildRevision();
    @DatabaseWrite ulong commitGuildChange(scope bool delegate(WorldDatabase db, ulong revision) change);
    /// Reserves a guild ID. A stale invitation must never point at a guild created later.
    @DatabaseWrite uint nextGuildId();
    /// A guild's own row (name, leader, emblem, texts), written whole (created if new).
    void saveGuild(const ref GuildRecord guild);
    /// Its ranks, all of them (the old rows go).
    void saveGuildRanks(uint guild, const(GuildRankRecord)[] ranks);
    /// A member's row (created if new).
    void saveGuildMember(uint guild, uint member, uint rank, string publicNote, string officerNote);
    /// A member gone.
    void deleteGuildMember(uint member);
    /// An event of the guild's log, in its place (`logGuid`: the row there before goes).
    void saveGuildEvent(uint guild, const ref GuildEventRecord event);
    /// A guild gone: its rows, ranks, members and log.
    void deleteGuild(uint guild);

    /// The petition (charter) of item `petition`, with its signers; null if none.
    @DatabaseRead Nullable!PetitionRecord loadPetition(uint petition);
    /// A new charter of `owner`'s (its older ones go).
    void createPetition(uint owner, uint petition, string name);
    /// A signature; whether an account signed a petition already.
    void signPetition(uint owner, uint petition, uint player, uint account);
    /// ditto
    @DatabaseRead bool accountSignedPetition(uint account, uint petition);
    /// A charter turned in or gone.
    void deletePetition(uint petition);
    /// A character's own charters and its signatures go (it joined a guild).
    void deletePetitionsOf(uint player);

    /// `character_social`: the player's friends and ignored players.
    @DatabaseRead SocialRow[] loadSocial(uint player);
    /// ditto: one row, written (flags 0: deleted)
    void saveSocial(uint player, uint other, ubyte flags);
    /// Whether `player` ignores `other`.
    @DatabaseRead bool isIgnoring(uint player, uint other);

    /// `characters.resettalents_cost` and `resettalents_time`: what the last talent reset cost, and when.
    void saveTalentReset(uint player, uint cost, long time);
    /// ditto
    @DatabaseRead void loadTalentReset(uint player, out uint cost, out long time);

    /// `character_spell_cooldown`: the player's cooldowns still running, all of them (the old rows go).
    @Replaces void saveCooldowns(uint player, const(CooldownRecord)[] cooldowns);

    /// ditto, as saved
    @DatabaseRead CooldownRecord[] loadCooldowns(uint player);

    /// `character_pet` and `pet_spell`: every pet of `owner`, in id order.
    @DatabaseRead PetRecord[] loadPets(uint owner);
    @DatabaseRead string loadPlayerSummons(uint player);
    @Replaces void savePlayerSummons(uint player, string state);
    /// Update position and active effects atomically when they describe the same transition.
    void savePlayerRecovery(const ref CharacterProgress progress, string state);
    @DatabaseRead PartySummonCheckpoint loadPartySummonOffer(uint player);
    @DatabaseWrite bool publishPartySummonOffer(uint player, ulong sequence, string state);
    @DatabaseWrite bool consumePartySummonOffer(uint player, ulong sequence);
    void deletePartySummonOffer(uint player);
    /// A pet's row and spells, written whole.
    void savePet(const ref PetRecord pet);
    /// A pet moved to another slot.
    void setPetSlot(uint owner, uint pet, uint slot);
    /// A pet gone for good (abandoned): its row, spells, auras and cooldowns.
    void deletePet(uint owner, uint pet);
    /// `characters.stable_slots`: how many stable slots the player bought.
    @DatabaseRead uint loadStableSlots(uint player);
    /// ditto
    void saveStableSlots(uint player, uint slots);

    /// The player's saved auras.
    @DatabaseRead AuraRecord[] loadAuras(uint player);

    /// The player's reputation: these factions' rows replaced.
    void saveReputation(uint player, const(ReputationRecord)[] rows);

    /// The player's `character_reputation` rows.
    @DatabaseRead ReputationRecord[] loadReputation(uint player);

    /// What the player has of honor: its honor columns and `character_honor_cp` rows.
    @DatabaseRead HonorRecord loadHonor(uint player);

    /// The player's `character_battleground_data` row (none: all 0).
    @DatabaseRead BattlegroundData loadBattlegroundData(uint player);

    /// The player's `character_battleground_data` row replaced (deleted if the player is in no copy and came from nowhere).
    void saveBattlegroundData(uint player, const BattlegroundData data);
    /// A battle's scoreboard kept (`Battleground.ScoreStatistics`): its row, and each player's under its id.
    void savePvpStats(const PvpStatsBattleground battle, const(PvpStatsPlayer)[] players);

    /**
     * The player's honor: the columns, and the honor gained since the
     * last save (`character_honor_cp` rows added).
     */
    void saveHonor(uint player, const HonorColumns columns, const(HonorPointRecord)[] added);

    // --- the honor week (`dmangos.world.honorweek`) ---

    /// `saved_variables.NextMaintenanceDate`: the next maintenance day; 0 if never set.
    @DatabaseRead uint nextHonorMaintenance();

    /// ditto
    void setNextHonorMaintenance(uint day);

    /// The day of the oldest honorable `character_honor_cp` row; 0 if none.
    @DatabaseRead uint oldestHonorDay();

    /// The standing's input: each player's honorable honor and kills on days from `from` until `until`.
    @DatabaseRead HonorWeekEntry[] honorWeek(uint from, uint until);

    /// A player's rating after a week, and with `setStanding` its place in last week's standing.
    void setHonorRating(uint player, float rating, uint standing, bool setStanding);

    /// Every player's place in last week's standing back to none.
    void clearHonorStandings();

    /// The kills of rows before `day` added to the stored totals, and the rows deleted.
    void foldHonorPoints(uint day);

    /// The quests that changed (a status of none, never rewarded, deletes the row).
    void saveQuestStatus(uint player, const(QuestStatus)[] quests);

    /// A mail sent: the mail and its item row.
    void sendMail(const ref MailRecord mail);

    /// The player's mail, delivered or not, oldest first (`_LoadMail`).
    @DatabaseRead MailRecord[] loadMail(uint receiver);

    /// One mail by id, if it exists.
    @DatabaseRead Nullable!MailRecord mailById(uint id);

    /// A mail's money, cash on delivery, flags and item (`_SaveMail`'s update).
    void updateMail(const ref MailRecord mail);

    /// The mail and its item row are gone.
    void deleteMail(uint id);

    /// The mail whose time is up by `now` (Unix time), oldest first.
    @DatabaseRead MailRecord[] expiredMail(long now);

    /// An item gone with its mail (`item_instance`).
    void deleteLooseItem(uint guid);

    /// `item_text`: a body.
    void saveItemText(uint id, string text);

    /// ditto; empty if there is none.
    @DatabaseRead string itemText(uint id);

    /// An item kept outside any inventory (in the mail), as `item_instance` with its owner to be.
    void saveLooseItem(const ref ItemRecord item, uint owner);

    /// ditto, to take it back out; null if there is none.
    @DatabaseRead Nullable!ItemRecord looseItem(uint guid);

    /// A character's race and account; [0, 0] if it does not exist.
    @DatabaseRead uint[2] characterRaceAccount(uint guid);

    /// Every creature that is dead now: spawn guid -> when it comes back (Unix time).
    @DatabaseRead long[uint] loadCreatureRespawns();

    /// A new auction.
    void insertAuction(const ref AuctionRecord auction);

    /// The auctions of house `houseId` (0: of every house).
    @DatabaseRead AuctionRecord[] loadAuctions(uint houseId);

    /// The auction `id`, if it is still there.
    @DatabaseRead Nullable!AuctionRecord auctionById(uint id);

    /// A bid: true if the auction still had the bid `oldBid` of `oldBidder` (it now has the new one).
    @DatabaseWrite bool bidOnAuction(uint id, uint oldBidder, uint oldBid, uint bidder, uint bid);

    /// The auction gone (sold, cancelled, expired): true if it was still there with the bid `bid`.
    @DatabaseWrite bool deleteAuction(uint id, uint bid);

    /// The auctions over by `now` (Unix time).
    @DatabaseRead AuctionRecord[] expiredAuctions(long now);

    /// The highest auction id in use.
    @DatabaseRead uint maxAuctionId();

    /// A used-up game object comes back at `respawnTime` (0: it is back).
    void saveGameObjectRespawn(uint spawnGuid, long respawnTime);

    /// Every game object used up now: spawn guid -> when it comes back (Unix time).
    @DatabaseRead long[uint] loadGameObjectRespawns();

    /// The dungeon instances that exist (`instance`), their binds and what is dead or used up in them.
    @DatabaseRead InstanceRecords loadInstances();

    /// An instance made (`instance`): its map, and (a raid's) when it resets (Unix time; 0: when empty).
    void saveInstance(uint id, uint map, long resetTime);

    /// An instance reset: its row, binds and respawn rows go.
    void deleteInstance(uint id);

    /// `instance.data`: its dungeon script's state.
    void saveInstanceData(uint id, string data);

    void saveInstanceChest(const InstanceChestRecord chest);
    @DatabaseRead InstanceChestRecord[] loadOutdoorChests();
    @DatabaseRead InstanceChestRecord loadOutdoorChest(uint spawn);
    /// Retire the original chest and record its respawn together.
    void finishOutdoorChest(uint spawn, long respawnAt);
    void finishScriptedOutdoorChest(uint realm, ulong actor, uint spawn);
    /// When recording a native creature's death, commit its respawn deadline with the corpse.
    void saveInstanceCorpse(const InstanceCorpseRecord corpse, long respawnAt);
    void deleteInstanceCorpse(uint instance, uint spawn);
    @DatabaseRead InstanceCorpseRecord[] loadOutdoorCorpses();
    @DatabaseRead PickpocketRecord loadPickpocket(uint instance, uint spawn);
    void savePickpocket(const PickpocketRecord pocket);
    @DatabaseRead QuestActorCheckpoint[] loadQuestActors(uint realm);
    void saveQuestActor(uint realm, const QuestActorCheckpoint actor);
    void deleteQuestActor(uint realm, ulong actor);
    @DatabaseRead DungeonFightCheckpoint[] loadDungeonFights(uint instance);
    void saveDungeonFight(uint instance, const DungeonFightCheckpoint fight);
    void deleteDungeonFight(uint instance, uint spawn);
    @DatabaseRead OutdoorScriptCheckpoint[] loadOutdoorScripts(uint realm);
    @DatabaseWrite bool beginOutdoorScript(uint realm, const ref OutdoorScriptCheckpoint script);
    @DatabaseWrite bool advanceOutdoorScript(uint realm, ushort origin, ulong sequence, uint cursor, bool finished,
        const(OutdoorQuestUpdate)[] updates = null, const(QuestActorCheckpoint)[] summons = null,
        const(OutdoorScriptCheckpoint)[] relays = null, const(OutdoorSummonRequest)[] forwards = null,
        const(OutdoorWorldState)[] worldStates = null);
    @DatabaseRead OutdoorWorldState[] loadOutdoorWorldStates(uint realm);
    @DatabaseWrite void saveOutdoorWorldState(uint realm, const ref OutdoorWorldState state);
    @DatabaseRead OutdoorSummonRequest[] loadOutdoorSummons(uint realm);
    @DatabaseWrite bool enqueueOutdoorSummon(uint realm, const ref OutdoorSummonRequest request);
    @DatabaseRead bool outdoorSummonsPending(uint realm, ushort origin, ulong sequence);
    @DatabaseWrite bool commitOutdoorSummon(uint realm, const ref OutdoorSummonRequest request,
        const ref QuestActorCheckpoint actor, const(OutdoorScriptCheckpoint)[] relays, uint chest = 0);
    @DatabaseWrite bool commitOutdoorDespawn(uint realm, const ref OutdoorSummonRequest request, ulong actor, uint chest = 0,
        long respawnAt = 0);
    @DatabaseWrite bool retireOutdoorSummon(uint realm, const ref OutdoorSummonRequest request);

    /// The map of instance `id`; uint.max if there is no such instance.
    @DatabaseRead uint instanceMapOf(uint id);

    /// A character's binds as saved (`character_instance`): map -> instance.
    @DatabaseRead uint[uint] instanceBindsOf(uint player);

    /// `character_instance` (`group` false, `owner` a character) or `group_instance` (`owner` a leader).
    void saveInstanceBind(bool group, uint owner, uint instance, bool permanent);

    /// Realm-wide rolling instance history, kept in the realm's shared character database.
    @DatabaseRead bool instanceLimitReached(uint account, uint instance, long now);
    @DatabaseWrite bool admitInstance(uint account, uint instance, long now);

    /// A saved `creature` spawn, with its ID allocated by the world database.
    @DatabaseWrite uint createCreatureSpawn(const ref CreatureSpawn spawn);

    /// The first counter in a new reserved block of temporary object IDs, or null if fenced.
    @DatabaseWrite Nullable!ulong reserveTemporaryCounters(uint realm, uint count);

    /// A saved spawn with a direct creature entry.
    @DatabaseRead Nullable!CreatureSpawn savedCreatureSpawn(uint guid);

    @DatabaseWrite bool saveSpawnWaypoints(uint spawn, MotionType mode, const(WaypointNode)[] nodes);

    @DatabaseWrite bool saveGmSpawnLink(uint follower, const ref imported!"dmangos.world.creaturelinking".CreatureLink link);
    @DatabaseWrite bool addGmNpcSpell(uint list, uint spell, int target, uint repeatMs);
    @DatabaseWrite bool setGmTransportPeriod(uint entry, uint period);

    /// Direct creature spawn rows added above a node's initial world-data snapshot.
    @DatabaseRead CreatureSpawn[] savedCreatureSpawnsAfter(uint guid);

    /// An explicit spawn ID, including replays of writes queued by older releases.
    void insertCreatureSpawn(const ref CreatureSpawn spawn);

    /// A spawn a GM deleted.
    void deleteCreatureSpawn(uint guid);

    /// Confirm the world row is gone before the map drops the saved spawn.
    @DatabaseWrite bool eraseSavedSpawn(uint guid, bool gameObject);

    /// A creature's quest a GM added or removed: `creature_questrelation` (`start`) or `creature_involvedrelation`.
    void insertQuestRelation(bool start, uint entry, uint quest);
    /// ditto
    void deleteQuestRelation(bool start, uint entry, uint quest);

    /// A creature template's scale a GM fixed (`creature_template.Scale`).
    void updateCreatureScale(uint entry, float scale);

    @DatabaseWrite bool insertTrainerLesson(uint entry, uint spell, uint cost, ubyte requiredLevel);
    @DatabaseRead imported!"dmangos.world.npcdata".TrainerSpell[] loadTrainerLessons(uint entry,
        const imported!"dmangos.world.spells".SpellData spells);
    @DatabaseRead imported!"dmangos.world.quests".QuestData loadQuestCatalog();
    @DatabaseWrite imported!"dmangos.world.quests".QuestData reloadQuestCatalog();

    /// A vendor's ware a GM added (`npc_vendor`: unlimited, in `slot`) or removed.
    void insertVendorItem(uint entry, uint item);
    /// ditto
    void deleteVendorItem(uint entry, uint item);

    /// A saved `gameobject` spawn, with its ID allocated by the world database.
    @DatabaseWrite uint createGameObjectSpawn(const ref GameObjectSpawn spawn);

    /// Save a game object's transform while keeping the rest of its row.
    @DatabaseWrite bool updateGameObjectPlacement(const ref GameObjectSpawn spawn);

    /// A saved spawn with a direct game-object entry.
    @DatabaseRead Nullable!GameObjectSpawn savedGameObjectSpawn(uint guid);

    /// Direct game-object spawn rows added above a node's initial world-data snapshot.
    @DatabaseRead GameObjectSpawn[] savedGameObjectSpawnsAfter(uint guid);

    /// The saved transforms on a map, including rows whose entry comes from a spawn group.
    @DatabaseRead GameObjectSpawn[] savedGameObjectSpawnsOnMap(uint map);

    /// A saved game object at its existing ID, including replays of queued writes.
    void insertGameObjectSpawn(const ref GameObjectSpawn spawn);

    /// A game object spawn a GM deleted.
    void deleteGameObjectSpawn(uint guid);

    /// A character's bind to an instance revoked (`character_instance`).
    void deleteInstanceBind(uint guid, uint instance);

    /// A creature (or game object) spawn dead (used up) in an instance until `until` (`creature_respawn`, `gameobject_respawn`).
    void saveInstanceRespawn(bool gameObject, uint spawnGuid, uint instance, long until);

    /// Instance round 2: a creature spawn of an instance alive again (its `creature_respawn` row goes).
    void deleteInstanceRespawn(uint spawnGuid, uint instance);

    /// Name, race, gender and class of a character, or null.
    @DatabaseRead Nullable!NameInfo nameInfo(uint guid);

    /// Every group with its members.
    @DatabaseRead GroupRecord[] loadGroups();

    @DatabaseRead GroupLootRotation loadGroupLootRotation(uint group, ushort node, ulong drop);
    @DatabaseWrite bool recordGroupLootRotation(uint group, ushort node, ulong drop, const ref GroupLootRotation turn, long now);

    /// Deposits every group share together, identified by the original drop's immutable payout token.
    @DatabaseWrite bool saveLootCoinSplit(ushort issuer, ulong token, const(LootCoinCredit)[] shares);
    @DatabaseRead uint[] pendingLootCoinPlayers();
    /**
     * Adds the player's unpaid credits to `wallet`, the online session's live purse, saves the sum as the
     * character's money and marks the credits paid in the same transaction. The saved money is never the
     * older `characters.money`, which may not yet hold what the session spent.
     */
    @DatabaseWrite LootCoinRedemption redeemLootCoins(uint player, uint wallet, long now);

    /// The `groups` row of a new group.
    void createGroup(const ref GroupRecord group);

    /// The `groups` columns that change after creation.
    void updateGroup(const ref GroupRecord group);

    /// Deletes a group and its members.
    void deleteGroup(uint groupId);

    /// A member joins a group.
    void addGroupMember(uint groupId, const GroupMemberRecord member);

    /// A member's assistant flag and sub-group.
    void updateGroupMember(const GroupMemberRecord member);

    /// A member leaves its group.
    void removeGroupMember(uint guid);

    // --- what GM commands change ---

    /// `account.mutetime`: chat is off until `until` (Unix time); 0 lifts it.
    void setMuteTime(uint accountId, long until);

    /// The guid of the character called `name`, or 0.
    @DatabaseRead uint characterGuid(string name);

    @DatabaseRead GmNameReview[] gmNamesToReview();
    @DatabaseWrite bool gmMarkNameForChange(uint guid, string name);

    /// Gives an offline character a new name (`characters.name`).
    void renameCharacter(uint guid, string newName);

    /// A guild's name in the database (`.guild rename`: what the next start loads).
    void renameGuild(uint guildId, string name);

    /// Sets flags in an offline character's `at_login` (a rename asked for: `.character forcerename`).
    void addAtLoginFlags(uint guid, uint flags);

    /// Moves a character that is not online (`.summon` of an offline player).
    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone);

    /// A bug report or suggestion from a client (`bugreport`).
    void saveBugReport(string type, string content);

    /// A wrapped item's own entry and flags (`character_gifts`): kept, read back (found: true), and dropped.
    void saveGift(uint owner, uint item, uint entry, uint flags);
    /// ditto
    @DatabaseRead bool loadGift(uint item, out uint entry, out uint flags);
    /// ditto
    void deleteGift(uint item);

    /// The raids' next resets (`instance_reset`: Unix time, by map); and one's change.
    @DatabaseRead long[uint] loadRaidResets();
    /// ditto
    void saveRaidReset(uint map, long time);

    /// A pet's auras that last (`pet_aura`), all of them (the old rows go); and those saved.
    void savePetAuras(uint pet, const(AuraRecord)[] auras);
    /// ditto
    @DatabaseRead AuraRecord[] loadPetAuras(uint pet);

    /// A pet's cooldowns still running (`pet_spell_cooldown`: spell, Unix time ready), all of them; and those saved.
    void savePetCooldowns(uint pet, const(ulong[2])[] cooldowns);
    /// ditto
    @DatabaseRead ulong[2][] loadPetCooldowns(uint pet);

    /// The game events on when last looked (`game_event_status`), and one's change.
    @DatabaseRead ushort[] gameEventStatus();
    /// ditto
    void setGameEventStatus(ushort event, bool on);

    /// The characters of races in `raceMask` (and, `quest` not 0, rewarded for it): a game event's letters' receivers.
    @DatabaseRead uint[] charactersFor(uint raceMask, uint quest);

    /// A server-wide state's saved text (`world_state`, by its id: 1 the war effort), empty if none; and its change.
    @DatabaseRead string worldState(uint id);
    /// ditto
    @Replaces void saveWorldState(uint id, string data);

    /// The client's saved settings of `type` (macros, key bindings, ...): the account's (`account_data`) or,
    /// `perCharacter`, the character's (`character_account_data`); `owner` the account or character.
    void saveAccountData(bool perCharacter, uint owner, uint type, long time, const(ubyte)[] data);
    @DatabaseRead const(ubyte)[] accountData(bool perCharacter, uint owner, uint type); /// ditto

    /// GM tickets (`gm_tickets`): every ticket, the open ones only (`closed` too with `all`).
    @DatabaseRead TicketRecord[] tickets(bool all);
    /// A new ticket; returns its id.
    @DatabaseWrite uint addTicket(TicketRecord ticket);
    /// A ticket's text changed, at `now`.
    void updateTicketText(uint id, string text, long now);
    /// A ticket removed (closed, kept); or deleted for good.
    void closeTicket(uint id);
    void deleteTicket(uint id); /// ditto

    /// One spell learned, or changed (a higher rank made it inactive).
    void saveSpell(uint guid, uint spell, bool active, bool disabled);

    /// A spell forgotten: its row is deleted.
    void deleteSpell(uint guid, uint spell);

    /// One skill's value and maximum; a `max` of 0 removes it.
    void saveSkill(uint guid, uint skill, uint value, uint max);

    /**
     * Inventory changes with the money and `playerBytes2` (the bank bag slots bought) that
     * paid for them, in one transaction: each item's `character_inventory` and
     * `item_instance` rows written or deleted.
     */
    void saveInventory(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes);

    /// Commits the inventory award and the remaining chest loot together.
    void saveChestAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const InstanceChestRecord chest);

    /// Commits the inventory award and the remaining corpse loot together.
    void saveCorpseAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const InstanceCorpseRecord corpse);

    void savePickpocketAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const PickpocketRecord pocket);

    @DatabaseRead LootAwardResult loadLootAward(const ref LootAwardKey key);
    /**
     * Takes the award's token for its recipient before the item is made: records it claimed (`lootAwardClaimed`),
     * unless a result (the loot's node expiring it) is already recorded. True when this call recorded it.
     */
    @DatabaseWrite bool claimLootAward(const ref LootAwardKey key, long now);
    /**
     * The loot's node gives up on an unanswered award: records it refused, unless a result is already recorded or
     * the recipient's claim is younger than `lootAwardClaimSeconds` (its item may still be written).
     */
    @DatabaseWrite void expireLootAward(const ref LootAwardKey key, long now);
    /**
     * Records the result and any new inventory rows in the same transaction. Stored (`error` 0): only over the
     * recipient's claim, and the rows are saved only when this call turned the claim into stored. Refused: over
     * the claim, or where nothing is recorded.
     */
    void saveLootAward(const ref LootAwardKey key, ubyte error, long now, uint money, uint playerBytes2,
        const(ItemChange)[] changes);

    /// Ids and names in a world table whose name contains `text` (`.lookup`), at most `limit`.
    @DatabaseRead LookupResult[] lookup(LookupTable table, string text, uint limit);

    /// `game_tele`: adds a place (`.recall add`), or deletes one by name; false if there was none.
    void addTeleport(const GameTele tele);
    /// ditto
    @DatabaseWrite bool deleteTeleport(string name);

    /// `areatrigger_teleport` and `game_tele`, read again (`.server reloadtable`).
    @DatabaseRead AreaTriggerTeleport[] loadAreaTriggerTeleports();
    /// ditto
    @DatabaseRead GameTele[] loadTeleports();

    @DatabaseRead WorldCatalogVersion[] worldCatalogVersions();
    void markWorldCatalogReload(WorldCatalogKey key);
    @DatabaseRead VendorItem[] loadVendorItems(uint entry);
    @DatabaseRead uint[] loadCreatureQuestRelations(bool start, uint entry);
    @DatabaseRead Nullable!float loadCreatureScale(uint entry);

    /// Last durable service state for this realm. The revision fences subsequent writes.
    @DatabaseRead ServiceCheckpoint loadServiceCheckpoint(ServiceKind kind, uint realm);
    @DatabaseWrite bool saveServiceCheckpoint(ServiceKind kind, uint realm, const ref ServiceCheckpoint checkpoint);
    @DatabaseRead BattlegroundCheckpoint[] loadBattlegroundCheckpoints(uint realm, uint map, long since);
    @DatabaseWrite bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint);
    /// ditto, and the rewards its objectives gave since the last one, in the same transaction: both or neither.
    @DatabaseWrite bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint,
        const(BattlegroundEventReward)[] rewards);
    @DatabaseWrite bool publishBattlegroundResult(uint realm, uint match, const PvpStatsBattleground result,
        const(PvpStatsPlayer)[] scores, const(BattlegroundReward)[] rewards, bool keepStatistics);
    @DatabaseRead BattlegroundReward[] pendingBattlegroundRewards();
    @DatabaseWrite bool payBattlegroundReward(const ref BattlegroundReward reward, const ref BattlegroundPayment payment);
    @DatabaseRead BattlegroundEventReward[] pendingBattlegroundEventRewards();
    /// Pays `reward` once: false if it was paid already (or is not there).
    @DatabaseWrite bool payBattlegroundEventReward(const ref BattlegroundEventReward reward,
        const ref BattlegroundPayment payment);
}

/// The world tables `.lookup` searches.
enum LookupTable
{
    quest,
    creature,
    gameObject,
    spell,
}

/// One `.lookup` match.
struct LookupResult
{
    uint id;
    string name;
}

/// `account_logons.loginSource` for connections to the world server.
enum uint loginSourceMangosd = 1;

/// `WorldDatabase` on the MySQL login and characters databases.
final class MySqlWorldDatabase : WorldDatabase, WriteLedger
{
    private MySqlConnection login;
    private MySqlConnection characterDb;
    private MySqlConnection world;
    private CharacterStatements statements;
    private bool temporaryCounterReady;
    private WorldCatalogJournal catalog;

    ///
    this(MySqlConnection login, MySqlConnection characterDb, MySqlConnection world)
    in (login !is null && characterDb !is null && world !is null)
    {
        this.login = login;
        this.characterDb = characterDb;
        this.world = world;
        this.statements = new CharacterStatements(characterDb, login);
        this.catalog = WorldCatalogJournal(world);
    }

    void prepareLedger()
    {
        statements.prepareInstanceChests();
        statements.prepareInstanceCorpses();
        statements.preparePickpockets();
        statements.prepareGameObjectPools();
        statements.prepareQuestActors();
        statements.prepareDungeonFights();
        statements.prepareOutdoorScripts();
        statements.preparePlayerSummons();
        statements.preparePartySummonOffers();
        statements.prepareLootAwards();
        characterDb.execute!("CREATE TABLE IF NOT EXISTS `dmangos_write_applied` ("
            ~ "`stream` INT UNSIGNED NOT NULL, `seq` BIGINT UNSIGNED NOT NULL, PRIMARY KEY (`stream`)"
            ~ ") ENGINE=InnoDB DEFAULT CHARSET=utf8 COMMENT='dmangos: the newest write of each stream carried out'")();
    }

    ulong appliedUpTo(uint stream)
    {
        auto rows = characterDb.query!"SELECT seq FROM dmangos_write_applied WHERE stream = ?"(stream);
        return rows.length ? rows[0].get!ulong(0) : 0;
    }

    void applying(uint stream, ulong seq, scope void delegate() work, scope void delegate() beforeCommit)
    {
        characterDb.transaction({
            work();
            characterDb.execute!("INSERT INTO dmangos_write_applied (stream, seq) VALUES (?, ?) "
                ~ "ON DUPLICATE KEY UPDATE seq = VALUES(seq)")(stream, seq);
            beforeCommit();
        });
    }

    GuidCounters highestGuids() { return statements.highestGuids(); }
    bool nameTaken(string name) { return statements.nameTaken(name); }
    uint accountCharacterTotal(uint accountId) { return statements.accountCharacterTotal(accountId); }
    uint realmCharacterCount(uint accountId) { return statements.realmCharacterCount(accountId); }
    ubyte[] characterRaces(uint accountId) { return statements.characterRaces(accountId); }
    bool hasTutorialData(uint accountId) { return statements.hasTutorialData(accountId); }
    Nullable!CharacterOwner characterOwner(uint guid) { return statements.owner(guid); }
    bool isGuildLeader(uint guid) { return statements.isGuildLeader(guid); }
    Nullable!CharacterData loadCharacter(uint guid) { return statements.loadCharacter(guid); }
    void insertHomeBind(uint guid, const HomeBind bind) { statements.insertHomeBind(guid, bind); }
    void updateHomeBind(uint guid, const HomeBind bind) { statements.updateHomeBind(guid, bind); }
    void setOnline(uint guid, uint accountId, bool online, uint realmId)
    {
        statements.setOnline(guid, accountId, online, realmId);
    }
    void markAllOffline(uint realmId) { statements.markAllOffline(realmId); }
    void saveProgress(const ref CharacterProgress progress) { statements.saveProgress(progress); }
    void setActionButton(uint guid, ubyte button, uint action, ubyte type)
    {
        statements.setActionButton(guid, button, action, type);
    }
    void saveTutorials(uint accountId, const uint[tutorialFields] tutorials)
    {
        statements.saveTutorials(accountId, tutorials);
    }
    void saveCorpse(const ref CorpseRecord c) { statements.saveCorpse(c); }
    void deleteCorpse(uint player) { statements.deleteCorpse(player); }
    Nullable!CorpseRecord loadCorpse(uint player) { return statements.loadCorpse(player); }
    void saveCreatureRespawn(uint spawnGuid, long respawnTime) { statements.saveCreatureRespawn(spawnGuid, respawnTime); }
    CreaturePoolState[uint] loadCreaturePoolStates(uint realm) { return statements.loadCreaturePoolStates(realm); }
    bool updateCreaturePoolState(uint realm, uint pool, ulong revision, uint spawn, long due,
        const InstanceCorpseRecord corpse = InstanceCorpseRecord.init)
    {
        if (!corpse.spawn && !due)
            return statements.updateCreaturePoolState(realm, pool, revision, spawn, due);
        bool changed;
        characterDb.transaction({
            changed = statements.updateCreaturePoolState(realm, pool, revision, spawn, due);
            if (!changed)
                return;
            if (due)
                statements.deletePickpocket(0, spawn);
            if (corpse.spawn)
                statements.saveInstanceCorpse(corpse);
        });
        return changed;
    }

    GameObjectPoolState[uint] loadGameObjectPoolStates(uint realm) { return statements.loadGameObjectPoolStates(realm); }

    bool updateGameObjectPoolState(uint realm, uint pool, const ref GameObjectPoolState state, uint exhaustedChest = 0)
    {
        if (!exhaustedChest)
            return statements.updateGameObjectPoolState(realm, pool, state);
        bool changed;
        characterDb.transaction({
            changed = statements.updateGameObjectPoolState(realm, pool, state);
            if (changed)
                statements.deleteOutdoorChest(exhaustedChest);
        });
        return changed;
    }
    void saveAuras(uint player, const(AuraRecord)[] auras) { statements.saveAuras(player, auras); }
    void saveCooldowns(uint player, const(CooldownRecord)[] cooldowns) { statements.saveCooldowns(player, cooldowns); }
    void saveTalentReset(uint player, uint cost, long time) { statements.saveTalentReset(player, cost, time); }
    SocialRow[] loadSocial(uint player) { return statements.loadSocial(player); }
    GuildRecord[] loadGuilds() { return statements.loadGuilds(); }
    Nullable!GuildRecord loadGuild(uint id) { return statements.loadGuild(id); }
    ulong guildRevision() { return statements.guildRevision(); }
    ulong commitGuildChange(scope bool delegate(WorldDatabase db, ulong revision) change)
    {
        return statements.commitGuildChange((ulong revision) => change(this, revision));
    }
    uint nextGuildId() { return statements.nextGuildId(); }
    void saveGuild(const ref GuildRecord guild) { statements.saveGuild(guild); }
    void saveGuildRanks(uint guild, const(GuildRankRecord)[] ranks) { statements.saveGuildRanks(guild, ranks); }
    void saveGuildMember(uint guild, uint member, uint rank, string publicNote, string officerNote)
    {
        statements.saveGuildMember(guild, member, rank, publicNote, officerNote);
    }
    void deleteGuildMember(uint member) { statements.deleteGuildMember(member); }
    void saveGuildEvent(uint guild, const ref GuildEventRecord event) { statements.saveGuildEvent(guild, event); }
    void deleteGuild(uint guild) { statements.deleteGuild(guild); }
    Nullable!PetitionRecord loadPetition(uint petition) { return statements.loadPetition(petition); }
    void createPetition(uint owner, uint petition, string name) { statements.createPetition(owner, petition, name); }
    void signPetition(uint owner, uint petition, uint player, uint account)
    {
        statements.signPetition(owner, petition, player, account);
    }
    bool accountSignedPetition(uint account, uint petition) { return statements.accountSignedPetition(account, petition); }
    void deletePetition(uint petition) { statements.deletePetition(petition); }
    void deletePetitionsOf(uint player) { statements.deletePetitionsOf(player); }
    void saveSocial(uint player, uint other, ubyte flags) { statements.saveSocial(player, other, flags); }
    bool isIgnoring(uint player, uint other) { return statements.isIgnoring(player, other); }
    void loadTalentReset(uint player, out uint cost, out long time) { statements.loadTalentReset(player, cost, time); }
    CooldownRecord[] loadCooldowns(uint player) { return statements.loadCooldowns(player); }
    PetRecord[] loadPets(uint owner) { return statements.loadPets(owner); }
    string loadPlayerSummons(uint player) { return statements.loadPlayerSummons(player); }
    void savePlayerSummons(uint player, string state) { statements.savePlayerSummons(player, state); }
    void savePlayerRecovery(const ref CharacterProgress progress, string state)
    {
        characterDb.transaction({
            statements.saveProgress(progress);
            statements.savePlayerSummons(progress.guid, state);
        });
    }
    PartySummonCheckpoint loadPartySummonOffer(uint player) { return statements.loadPartySummonOffer(player); }
    bool publishPartySummonOffer(uint player, ulong sequence, string state)
    {
        return statements.publishPartySummonOffer(player, sequence, state);
    }
    bool consumePartySummonOffer(uint player, ulong sequence)
    {
        return statements.consumePartySummonOffer(player, sequence);
    }
    void deletePartySummonOffer(uint player) { statements.deletePartySummonOffer(player); }
    void savePet(const ref PetRecord pet) { statements.savePet(pet); }
    void setPetSlot(uint owner, uint pet, uint slot) { statements.setPetSlot(owner, pet, slot); }
    void deletePet(uint owner, uint pet) { statements.deletePet(owner, pet); }
    uint loadStableSlots(uint player) { return statements.loadStableSlots(player); }
    void saveStableSlots(uint player, uint slots) { statements.saveStableSlots(player, slots); }
    AuraRecord[] loadAuras(uint player) { return statements.loadAuras(player); }
    void saveReputation(uint player, const(ReputationRecord)[] rows) { statements.saveReputation(player, rows); }
    ReputationRecord[] loadReputation(uint player) { return statements.loadReputation(player); }
    HonorRecord loadHonor(uint player) { return statements.loadHonor(player); }
    BattlegroundData loadBattlegroundData(uint player) { return statements.loadBattlegroundData(player); }
    void saveBattlegroundData(uint player, const BattlegroundData data) { statements.saveBattlegroundData(player, data); }
    void savePvpStats(const PvpStatsBattleground battle, const(PvpStatsPlayer)[] players)
    {
        statements.savePvpStats(battle, players);
    }
    void saveHonor(uint player, const HonorColumns columns, const(HonorPointRecord)[] added)
    {
        statements.saveHonor(player, columns, added);
    }
    uint nextHonorMaintenance() { return statements.nextHonorMaintenance(); }
    void setNextHonorMaintenance(uint day) { statements.setNextHonorMaintenance(day); }
    uint oldestHonorDay() { return statements.oldestHonorDay(); }
    HonorWeekEntry[] honorWeek(uint from, uint until) { return statements.honorWeek(from, until); }
    void setHonorRating(uint player, float rating, uint standing, bool setStanding)
    {
        statements.setHonorRating(player, rating, standing, setStanding);
    }
    void clearHonorStandings() { statements.clearHonorStandings(); }
    void foldHonorPoints(uint day) { statements.foldHonorPoints(day); }
    void saveQuestStatus(uint player, const(QuestStatus)[] quests) { statements.saveQuestStatus(player, quests); }
    void sendMail(const ref MailRecord mail) { statements.sendMailRecord(mail); }
    MailRecord[] loadMail(uint receiver) { return statements.loadMail(receiver); }
    Nullable!MailRecord mailById(uint id) { return statements.mailById(id); }
    void updateMail(const ref MailRecord mail) { statements.updateMail(mail); }
    void deleteMail(uint id) { statements.deleteMail(id); }
    MailRecord[] expiredMail(long now) { return statements.expiredMail(now); }
    void deleteLooseItem(uint guid) { statements.deleteLooseItem(guid); }
    void saveItemText(uint id, string text) { statements.saveItemText(id, text); }
    string itemText(uint id) { return statements.itemText(id); }
    void saveLooseItem(const ref ItemRecord item, uint owner) { statements.saveLooseItem(item, owner); }
    Nullable!ItemRecord looseItem(uint guid) { return statements.looseItem(guid); }
    uint[2] characterRaceAccount(uint guid) { return statements.characterRaceAccount(guid); }
    long[uint] loadCreatureRespawns() { return statements.loadCreatureRespawns(); }
    void insertAuction(const ref AuctionRecord auction) { statements.insertAuction(auction); }
    AuctionRecord[] loadAuctions(uint houseId) { return statements.loadAuctions(houseId); }
    Nullable!AuctionRecord auctionById(uint id) { return statements.auctionById(id); }
    bool bidOnAuction(uint id, uint oldBidder, uint oldBid, uint bidder, uint bid)
    {
        return statements.bidOnAuction(id, oldBidder, oldBid, bidder, bid);
    }
    bool deleteAuction(uint id, uint bid) { return statements.deleteAuction(id, bid); }
    AuctionRecord[] expiredAuctions(long now) { return statements.expiredAuctions(now); }
    uint maxAuctionId() { return statements.maxAuctionId(); }
    void saveGameObjectRespawn(uint spawnGuid, long respawnTime) { statements.saveGameObjectRespawn(spawnGuid, respawnTime); }
    long[uint] loadGameObjectRespawns() { return statements.loadGameObjectRespawns(); }
    InstanceRecords loadInstances() { return statements.loadInstances(); }
    void saveInstance(uint id, uint map, long resetTime) { statements.saveInstance(id, map, resetTime); }
    void deleteInstance(uint id) { statements.deleteInstance(id); }
    void saveInstanceData(uint id, string data) { statements.saveInstanceData(id, data); }
    void saveInstanceChest(const InstanceChestRecord chest) { statements.saveInstanceChest(chest); }
    InstanceChestRecord[] loadOutdoorChests() { return statements.loadOutdoorChests(); }
    InstanceChestRecord loadOutdoorChest(uint spawn) { return statements.loadOutdoorChest(spawn); }
    void finishOutdoorChest(uint spawn, long respawnAt)
    {
        characterDb.transaction({
            statements.saveGameObjectRespawn(spawn, respawnAt);
            statements.deleteOutdoorChest(spawn);
        });
    }
    void finishScriptedOutdoorChest(uint realm, ulong actor, uint spawn)
    {
        characterDb.transaction({
            statements.deleteOutdoorChest(spawn);
            statements.deleteQuestActor(realm, actor);
        });
    }
    void saveInstanceCorpse(const InstanceCorpseRecord corpse, long respawnAt)
    {
        if (respawnAt)
            characterDb.transaction({
                if (corpse.instance)
                    statements.saveInstanceRespawn(false, corpse.spawn, corpse.instance, respawnAt);
                else
                    statements.saveCreatureRespawn(corpse.spawn, respawnAt);
                statements.saveInstanceCorpse(corpse);
            });
        else
            statements.saveInstanceCorpse(corpse);
    }
    void deleteInstanceCorpse(uint instance, uint spawn) { statements.deleteInstanceCorpse(instance, spawn); }
    InstanceCorpseRecord[] loadOutdoorCorpses() { return statements.loadOutdoorCorpses(); }
    PickpocketRecord loadPickpocket(uint instance, uint spawn) { return statements.loadPickpocket(instance, spawn); }
    void savePickpocket(const PickpocketRecord pocket) { statements.savePickpocket(pocket); }
    QuestActorCheckpoint[] loadQuestActors(uint realm) { return statements.loadQuestActors(realm); }
    void saveQuestActor(uint realm, const QuestActorCheckpoint actor) { statements.saveQuestActor(realm, actor); }
    void deleteQuestActor(uint realm, ulong actor) { statements.deleteQuestActor(realm, actor); }
    DungeonFightCheckpoint[] loadDungeonFights(uint instance) { return statements.loadDungeonFights(instance); }
    void saveDungeonFight(uint instance, const DungeonFightCheckpoint fight) { statements.saveDungeonFight(instance, fight); }
    void deleteDungeonFight(uint instance, uint spawn) { statements.deleteDungeonFight(instance, spawn); }
    OutdoorScriptCheckpoint[] loadOutdoorScripts(uint realm) { return statements.loadOutdoorScripts(realm); }
    bool beginOutdoorScript(uint realm, const ref OutdoorScriptCheckpoint script)
    {
        return statements.beginOutdoorScript(realm, script);
    }
    bool advanceOutdoorScript(uint realm, ushort origin, ulong sequence, uint cursor, bool finished,
        const(OutdoorQuestUpdate)[] updates = null, const(QuestActorCheckpoint)[] summons = null,
        const(OutdoorScriptCheckpoint)[] relays = null, const(OutdoorSummonRequest)[] forwards = null,
        const(OutdoorWorldState)[] worldStates = null)
    {
        // Always in a transaction, even alone: a lost reply to a bare claim would be retried on a new
        // connection, match no row (the first attempt moved the cursor) and read as claimed elsewhere.
        // A transaction rolls back on the lost connection and runs again whole, and `advanced` survives
        // a lost COMMIT reply.
        bool advanced;
        characterDb.transaction({
            if (!statements.advanceOutdoorScript(realm, origin, sequence, cursor, finished))
                return;
            foreach (ref update; updates)
                statements.saveQuestStatus(update.player, update.quests);
            foreach (ref summon; summons)
                statements.saveQuestActor(realm, summon);
            saveSummonRelays(realm, relays);
            foreach (ref request; forwards)
                statements.insertOutdoorSummon(realm, request);
            foreach (ref state; worldStates)
                statements.saveOutdoorWorldState(realm, state);
            // Retain this on a retry if COMMIT succeeded but its response was lost.
            advanced = true;
        });
        return advanced;
    }

    private void saveSummonRelays(uint realm, const(OutdoorScriptCheckpoint)[] relays)
    {
        foreach (ref relay; relays)
            if (!statements.beginOutdoorScript(realm, relay))
                throw new imported!"dmangos.mysql".DatabaseException("summon relay checkpoint already exists");
    }

    OutdoorWorldState[] loadOutdoorWorldStates(uint realm) { return statements.loadOutdoorWorldStates(realm); }
    void saveOutdoorWorldState(uint realm, const ref OutdoorWorldState state)
    {
        statements.saveOutdoorWorldState(realm, state);
    }

    OutdoorSummonRequest[] loadOutdoorSummons(uint realm) { return statements.loadOutdoorSummons(realm); }
    bool enqueueOutdoorSummon(uint realm, const ref OutdoorSummonRequest request)
    {
        statements.insertOutdoorSummon(realm, request);
        return true;
    }
    bool outdoorSummonsPending(uint realm, ushort origin, ulong sequence)
    {
        return statements.outdoorSummonsPending(realm, origin, sequence);
    }

    bool commitOutdoorSummon(uint realm, const ref OutdoorSummonRequest request,
        const ref QuestActorCheckpoint actor, const(OutdoorScriptCheckpoint)[] relays, uint chest = 0)
    {
        bool saved;
        characterDb.transaction({
            if (!statements.completeOutdoorSummon(realm, request, actor.actor))
                return;
            if (chest)
                statements.deleteOutdoorChest(chest);
            statements.saveQuestActor(realm, actor);
            saveSummonRelays(realm, relays);
            saved = true;
        });
        return saved;
    }

    bool retireOutdoorSummon(uint realm, const ref OutdoorSummonRequest request)
    {
        return statements.retireOutdoorSummon(realm, request);
    }

    bool commitOutdoorDespawn(uint realm, const ref OutdoorSummonRequest request, ulong actor, uint chest = 0,
        long respawnAt = 0)
    {
        import dmangos.world.objects : counterOf;

        bool removed;
        characterDb.transaction({
            if (!statements.completeOutdoorSummon(realm, request, actor))
                return;
            if (chest)
                statements.deleteOutdoorChest(chest);
            statements.deleteQuestActor(realm, actor);
            if (respawnAt)
                statements.saveGameObjectRespawn(counterOf(actor), respawnAt);
            removed = true;
        });
        return removed;
    }
    uint instanceMapOf(uint id) { return statements.instanceMapOf(id); }
    uint[uint] instanceBindsOf(uint player) { return statements.instanceBindsOf(player); }
    bool instanceLimitReached(uint account, uint instance, long now)
    {
        import dmangos.world.context : InstanceEntry, tooManyInstances;

        InstanceEntry[] entries;
        foreach (row; characterDb.query!("SELECT InstanceId, ExpireTime FROM account_instances_entered "
            ~ "WHERE AccountId = ? AND InstanceId <> 0 AND ExpireTime > ?")(account, now))
            entries ~= InstanceEntry(row.get!uint(0), row.get!long(1) - 3600);
        return tooManyInstances(entries, instance);
    }

    bool admitInstance(uint account, uint instance, long now)
    {
        assert(instance);
        bool allowed;
        characterDb.transaction({
            // Copy zero is never entered. Its row serializes simultaneous admissions for this account.
            characterDb.execute!("INSERT INTO account_instances_entered (AccountId, InstanceId, ExpireTime) "
                ~ "VALUES (?, 0, 0) ON DUPLICATE KEY UPDATE ExpireTime = 0")(account);
            characterDb.execute!("DELETE FROM account_instances_entered WHERE AccountId = ? AND InstanceId <> 0 "
                ~ "AND ExpireTime <= ?")(account, now);
            allowed = !instanceLimitReached(account, instance, now);
            if (allowed)
                characterDb.execute!("INSERT INTO account_instances_entered (AccountId, InstanceId, ExpireTime) "
                    ~ "VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE ExpireTime = ExpireTime")(account, instance, now + 3600);
        });
        return allowed;
    }
    void saveInstanceBind(bool group, uint owner, uint instance, bool permanent)
    {
        statements.saveInstanceBind(group, owner, instance, permanent);
    }
    void saveInstanceRespawn(bool gameObject, uint spawnGuid, uint instance, long until)
    {
        statements.saveInstanceRespawn(gameObject, spawnGuid, instance, until);
    }
    void deleteInstanceRespawn(uint spawnGuid, uint instance) { statements.deleteInstanceRespawn(spawnGuid, instance); }
    void deleteInstanceBind(uint guid, uint instance) { statements.deleteInstanceBind(guid, instance); }
    uint createCreatureSpawn(const ref CreatureSpawn s)
    {
        return worldSpawnId!"creature"(storeCreatureSpawn!true(s));
    }

    Nullable!ulong reserveTemporaryCounters(uint realm, uint count)
    {
        if (!temporaryCounterReady)
        {
            characterDb.execute!("CREATE TABLE IF NOT EXISTS dmangos_temporary_counter ("
                ~ "realm INT UNSIGNED NOT NULL, next_counter BIGINT UNSIGNED NOT NULL, PRIMARY KEY (realm)"
                ~ ") ENGINE=InnoDB")();
            temporaryCounterReady = true;
        }
        ulong first;
        characterDb.transaction({
            characterDb.execute!("INSERT INTO dmangos_temporary_counter (realm, next_counter) VALUES (?, ?) "
                ~ "ON DUPLICATE KEY UPDATE next_counter = next_counter + VALUES(next_counter)")(realm, count);
            first = characterDb.query!"SELECT next_counter FROM dmangos_temporary_counter WHERE realm = ?"(realm)
                [0].get!ulong(0) - count;
        });
        return nullable!ulong(first);
    }

    Nullable!CreatureSpawn savedCreatureSpawn(uint guid)
    {
        const rows = world.queryAs!(CreatureSpawn, creatureSpawnQuery ~ " WHERE guid = ? AND id <> 0")(guid);
        return rows.length ? nullable(cast(CreatureSpawn) rows[0]) : Nullable!CreatureSpawn.init;
    }

    bool saveSpawnWaypoints(uint spawn, MotionType mode, const(WaypointNode)[] nodes)
    {
        import std.math : isFinite;

        if (world.query!("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() "
            ~ "AND table_name IN ('creature', 'creature_movement') AND engine='InnoDB'")()[0].get!uint(0) != 2)
            return false;
        import std.algorithm.searching : canFind;
        const extended = world.query!("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() "
            ~ "AND table_name='dmangos_gm_waypoint' AND engine='InnoDB'")()[0].get!uint(0) != 0;
        if (!extended && nodes.canFind!(node => node.gait || node.emote || node.model))
            return false;
        bool saved;
        world.transaction({
            saved = false;
            if (!world.query!"SELECT guid FROM creature WHERE guid=? FOR UPDATE"(spawn).length)
                return;
            world.execute!"DELETE FROM creature_movement WHERE Id=?"(spawn);
            if (extended)
                world.execute!"DELETE FROM dmangos_gm_waypoint WHERE spawn=?"(spawn);
            foreach (ref node; nodes)
            {
                world.execute!("INSERT INTO creature_movement (Id, Point, PositionX, PositionY, PositionZ, Orientation, WaitTime, ScriptId) "
                    ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?)")(spawn, node.point, node.x, node.y, node.z,
                    node.orientation.isFinite ? node.orientation : 100.0f, node.delay, node.scriptId);
                if (node.gait || node.emote || node.model)
                    world.execute!("INSERT INTO dmangos_gm_waypoint (spawn,point,gait,emote,model) "
                        ~ "VALUES (?,?,?,?,?)")(spawn, node.point, cast(uint) node.gait, node.emote, node.model);
            }
            world.execute!"UPDATE creature SET MovementType=? WHERE guid=?"(cast(uint) mode, spawn);
            saved = true;
        });
        return saved;
    }

    bool saveGmSpawnLink(uint follower, const ref imported!"dmangos.world.creaturelinking".CreatureLink link)
    {
        const leader = link.masterGuid;
        if (!follower || leader == follower)
            return false;
        bool saved;
        world.transaction({
            saved = false;
            if (!world.query!"SELECT leader FROM dmangos_gm_spawn_link WHERE follower=0 FOR UPDATE"().length)
                return;
            const found = world.query!("SELECT COUNT(*) FROM creature WHERE guid=? OR (guid=? "
                ~ "AND map=(SELECT map FROM creature WHERE guid=?))")(follower, leader, follower);
            if (found[0].get!uint(0) != (leader ? 2 : 1))
                return;
            // Merge authored and original links in one read after acquiring the edit lock.
            uint[uint] masters;
            foreach (row; world.query!("SELECT c.guid, COALESCE(g.leader,c.master_guid) FROM creature_linking c "
                ~ "LEFT JOIN dmangos_gm_spawn_link g ON g.follower=c.guid UNION "
                ~ "SELECT follower, leader FROM dmangos_gm_spawn_link WHERE follower<>0")())
                masters[row.get!uint(0)] = row.get!uint(1);
            bool[uint] visited;
            for (uint next = leader; next; next = masters.get(next, 0))
            {
                if (next == follower || next in visited)
                    return;
                visited[next] = true;
            }
            world.execute!("INSERT INTO dmangos_gm_spawn_link (follower,leader,flags,has_offset,distance,angle) "
                ~ "VALUES (?,?,?,?,?,?) ON DUPLICATE KEY UPDATE leader=VALUES(leader),flags=VALUES(flags),"
                ~ "has_offset=VALUES(has_offset),distance=VALUES(distance),angle=VALUES(angle)")(
                    follower, leader, link.flags, cast(uint) link.hasOffset, link.distance, link.angle);
            saved = true;
        });
        return saved;
    }

    bool addGmNpcSpell(uint list, uint spell, int target, uint repeatMs)
    {
        bool saved;
        world.transaction({
            saved = false;
            auto rows = world.query!("SELECT Position, SpellId FROM creature_spell_list WHERE Id=? "
                ~ "ORDER BY Position FOR UPDATE")(list);
            if (!rows.length)
                return; // do not create a list which has no template binding
            foreach (row; rows)
                if (row.get!uint(1) == spell)
                    return;
            const position = rows[$ - 1].get!int(0);
            if (position == int.max)
                return;
            world.execute!("INSERT INTO creature_spell_list (Id,Position,SpellId,Flags,CombatCondition,TargetId,"
                ~ "ScriptId,Availability,Probability,InitialMin,InitialMax,RepeatMin,RepeatMax,Comments) "
                ~ "VALUES (?,?,?,0,-1,?,0,100,0,?,?,?,?, 'GM authored')")(
                    list, position + 1, spell, target, repeatMs, repeatMs, repeatMs, repeatMs);
            saved = true;
        });
        return saved;
    }

    bool setGmTransportPeriod(uint entry, uint period)
    {
        return world.execute!"UPDATE transports SET period=? WHERE entry=?"(period, entry) != 0
            || world.query!"SELECT entry FROM transports WHERE entry=?"(entry).length != 0;
    }

    CreatureSpawn[] savedCreatureSpawnsAfter(uint guid)
    {
        return world.queryAs!(CreatureSpawn, creatureSpawnQuery ~ " WHERE guid > ? AND id <> 0")(guid);
    }

    void insertCreatureSpawn(const ref CreatureSpawn s) { storeCreatureSpawn!false(s); }

    private ulong storeCreatureSpawn(bool allocate)(const ref CreatureSpawn s)
    {
        import std.typecons : tuple;

        enum prefix = "INSERT INTO creature (guid, id, map, position_x, position_y, position_z, orientation, "
            ~ "spawntimesecsmin, spawntimesecsmax, spawndist, MovementType) VALUES (";
        enum remaining = ", ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
        const row = tuple(s.entry, s.map, s.x, s.y, s.z, s.orientation, s.respawnSeconds,
            s.respawnSecondsMax, s.wanderDistance, s.movementType);
        static if (allocate)
            return world.insert!(prefix ~ "NULL" ~ remaining)(row.expand);
        else
            return world.execute!(prefix ~ "?" ~ remaining)(s.guid, row.expand);
    }
    void deleteCreatureSpawn(uint guid) { world.execute!"DELETE FROM creature WHERE guid = ?"(guid); }
    bool eraseSavedSpawn(uint guid, bool gameObject)
    {
        if (gameObject)
            deleteGameObjectSpawn(guid);
        else
            deleteCreatureSpawn(guid);
        return true;
    }
    void insertQuestRelation(bool start, uint entry, uint quest)
    {
        catalog.change(WorldCatalogKey(start ? WorldCatalog.questStarter : WorldCatalog.questFinisher, entry), {
            if (start)
                world.execute!"INSERT IGNORE INTO creature_questrelation (id, quest) VALUES (?, ?)"(entry, quest);
            else
                world.execute!"INSERT IGNORE INTO creature_involvedrelation (id, quest) VALUES (?, ?)"(entry, quest);
        });
    }
    void deleteQuestRelation(bool start, uint entry, uint quest)
    {
        catalog.change(WorldCatalogKey(start ? WorldCatalog.questStarter : WorldCatalog.questFinisher, entry), {
            if (start)
                world.execute!"DELETE FROM creature_questrelation WHERE id = ? AND quest = ?"(entry, quest);
            else
                world.execute!"DELETE FROM creature_involvedrelation WHERE id = ? AND quest = ?"(entry, quest);
        });
    }
    void updateCreatureScale(uint entry, float scale)
    {
        catalog.change(WorldCatalogKey(WorldCatalog.creatureScale, entry), {
            world.execute!"UPDATE creature_template SET Scale = ? WHERE Entry = ?"(scale, entry);
        });
    }
    bool insertTrainerLesson(uint entry, uint spell, uint cost, ubyte requiredLevel)
    {
        bool inserted;
        catalog.change(WorldCatalogKey(WorldCatalog.trainer, entry), {
            inserted = world.execute!("INSERT IGNORE INTO npc_trainer (entry, spell, spellcost, reqlevel) "
                ~ "VALUES (?, ?, ?, ?)")(entry, spell, cost, requiredLevel) != 0;
        });
        return inserted;
    }

    imported!"dmangos.world.npcdata".TrainerSpell[] loadTrainerLessons(uint entry,
        const imported!"dmangos.world.spells".SpellData spells)
    {
        import dmangos.world.npcdata : NpcData;
        return NpcData.loadTrainer(world, entry, spells);
    }

    imported!"dmangos.world.quests".QuestData loadQuestCatalog()
    {
        import dmangos.world.quests : QuestData;
        return QuestData.load(world);
    }

    imported!"dmangos.world.quests".QuestData reloadQuestCatalog()
    {
        auto snapshot = loadQuestCatalog();
        catalog.change(WorldCatalogKey(WorldCatalog.quests, 0));
        return snapshot;
    }

    void insertVendorItem(uint entry, uint item)
    {
        catalog.change(WorldCatalogKey(WorldCatalog.vendor, entry), {
            world.execute!("INSERT IGNORE INTO npc_vendor (entry, item, maxcount, incrtime, slot, condition_id) "
                ~ "SELECT ?, ?, 0, 0, COALESCE(MAX(slot), -1) + 1, 0 FROM npc_vendor WHERE entry = ?")(
                    entry, item, entry);
        });
    }
    void deleteVendorItem(uint entry, uint item)
    {
        catalog.change(WorldCatalogKey(WorldCatalog.vendor, entry), {
            world.execute!"DELETE FROM npc_vendor WHERE entry = ? AND item = ?"(entry, item);
        });
    }
    uint createGameObjectSpawn(const ref GameObjectSpawn s)
    {
        return worldSpawnId!"gameobject"(storeGameObjectSpawn!true(s));
    }

    bool updateGameObjectPlacement(const ref GameObjectSpawn s)
    {
        const changed = world.execute!("UPDATE gameobject SET position_x = ?, position_y = ?, position_z = ?, "
            ~ "orientation = ?, rotation0 = ?, rotation1 = ?, rotation2 = ?, rotation3 = ? WHERE guid = ?")(
            s.x, s.y, s.z, s.orientation, s.rotation[0], s.rotation[1], s.rotation[2], s.rotation[3], s.guid);
        return changed != 0 || world.query!"SELECT guid FROM gameobject WHERE guid = ?"(s.guid).length != 0;
    }

    Nullable!GameObjectSpawn savedGameObjectSpawn(uint guid)
    {
        const rows = world.query!(gameObjectSpawnQuery ~ " WHERE guid = ? AND id <> 0")(guid);
        return rows.length ? nullable(gameObjectSpawnFromRow(rows[0])) : Nullable!GameObjectSpawn.init;
    }

    GameObjectSpawn[] savedGameObjectSpawnsAfter(uint guid)
    {
        GameObjectSpawn[] spawns;
        foreach (ref row; world.query!(gameObjectSpawnQuery ~ " WHERE guid > ? AND id <> 0")(guid))
            spawns ~= gameObjectSpawnFromRow(row);
        return spawns;
    }

    GameObjectSpawn[] savedGameObjectSpawnsOnMap(uint map)
    {
        GameObjectSpawn[] spawns;
        foreach (ref row; world.query!(gameObjectSpawnQuery ~ " WHERE map = ?")(map))
            spawns ~= gameObjectSpawnFromRow(row);
        return spawns;
    }

    void insertGameObjectSpawn(const ref GameObjectSpawn s) { storeGameObjectSpawn!false(s); }

    private ulong storeGameObjectSpawn(bool allocate)(const ref GameObjectSpawn s)
    {
        import std.typecons : tuple;

        enum prefix = "INSERT INTO gameobject (guid, id, map, position_x, position_y, position_z, orientation, "
            ~ "rotation0, rotation1, rotation2, rotation3, spawntimesecsmin, spawntimesecsmax) VALUES (";
        enum remaining = ", ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
        const row = tuple(s.entry, s.map, s.x, s.y, s.z, s.orientation, s.rotation[0], s.rotation[1],
            s.rotation[2], s.rotation[3], s.respawnSeconds, s.respawnSeconds);
        static if (allocate)
            return world.insert!(prefix ~ "NULL" ~ remaining)(row.expand);
        else
            return world.execute!(prefix ~ "?" ~ remaining)(s.guid, row.expand);
    }

    private uint worldSpawnId(string table)(ulong id)
    {
        import dmangos.world.objects : temporaryCounterStart;

        if (id < temporaryCounterStart)
            return cast(uint) id;
        world.execute!("DELETE FROM " ~ table ~ " WHERE guid = ?")(id);
        return 0;
    }
    void deleteGameObjectSpawn(uint guid) { world.execute!"DELETE FROM gameobject WHERE guid = ?"(guid); }
    Nullable!NameInfo nameInfo(uint guid) { return statements.nameInfo(guid); }
    GroupRecord[] loadGroups() { return statements.loadGroups(); }
    GroupLootRotation loadGroupLootRotation(uint group, ushort node, ulong drop)
    {
        return statements.loadGroupLootRotation(group, node, drop);
    }
    bool recordGroupLootRotation(uint group, ushort node, ulong drop, const ref GroupLootRotation turn, long now)
    {
        return statements.recordGroupLootRotation(group, node, drop, turn, now);
    }
    bool saveLootCoinSplit(ushort issuer, ulong token, const(LootCoinCredit)[] shares)
    {
        return statements.saveLootCoinSplit(issuer, token, shares);
    }
    uint[] pendingLootCoinPlayers() { return statements.pendingLootCoinPlayers(); }
    LootCoinRedemption redeemLootCoins(uint player, uint wallet, long now)
    {
        return statements.redeemLootCoins(player, wallet, now);
    }
    void createGroup(const ref GroupRecord group) { statements.createGroup(group); }
    void updateGroup(const ref GroupRecord group) { statements.updateGroup(group); }
    void deleteGroup(uint groupId) { statements.deleteGroup(groupId); }
    void addGroupMember(uint groupId, const GroupMemberRecord member) { statements.addGroupMember(groupId, member); }
    void updateGroupMember(const GroupMemberRecord member) { statements.updateGroupMember(member); }
    void removeGroupMember(uint guid) { statements.removeGroupMember(guid); }
    uint characterGuid(string name) { return statements.characterGuid(name); }
    GmNameReview[] gmNamesToReview()
    {
        return characterDb.queryAs!(GmNameReview, "SELECT guid,name FROM characters "
            ~ "WHERE account<>0 AND online=0 AND (at_login & 1)=0 ORDER BY guid")();
    }

    bool gmMarkNameForChange(uint guid, string name)
    {
        return characterDb.execute!("UPDATE characters SET at_login=at_login|1 "
            ~ "WHERE guid=? AND BINARY name=? AND account<>0 AND online=0 AND (at_login&1)=0")(guid, name) != 0;
    }

    void renameCharacter(uint guid, string newName) { statements.renameCharacter(guid, newName); }
    void addAtLoginFlags(uint guid, uint flags) { statements.addAtLoginFlags(guid, flags); }
    void renameGuild(uint guildId, string name) { statements.renameGuild(guildId, name); }
    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone)
    {
        statements.moveOfflineCharacter(guid, map, x, y, z, zone);
    }
    TicketRecord[] tickets(bool all) { return statements.tickets(all); }
    void saveBugReport(string type, string content) { statements.saveBugReport(type, content); }
    ushort[] gameEventStatus() { return statements.gameEventStatus(); }
    void savePetAuras(uint pet, const(AuraRecord)[] auras) { statements.savePetAuras(pet, auras); }
    long[uint] loadRaidResets() { return statements.loadRaidResets(); }
    void saveGift(uint owner, uint item, uint entry, uint flags) { statements.saveGift(owner, item, entry, flags); }
    bool loadGift(uint item, out uint entry, out uint flags) { return statements.loadGift(item, entry, flags); }
    void deleteGift(uint item) { statements.deleteGift(item); }
    void saveRaidReset(uint map, long time) { statements.saveRaidReset(map, time); }
    AuraRecord[] loadPetAuras(uint pet) { return statements.loadPetAuras(pet); }
    void savePetCooldowns(uint pet, const(ulong[2])[] cooldowns) { statements.savePetCooldowns(pet, cooldowns); }
    ulong[2][] loadPetCooldowns(uint pet) { return statements.loadPetCooldowns(pet); }
    void setGameEventStatus(ushort event, bool on) { statements.setGameEventStatus(event, on); }
    uint[] charactersFor(uint raceMask, uint quest) { return statements.charactersFor(raceMask, quest); }
    string worldState(uint id) { return statements.worldState(id); }
    void saveWorldState(uint id, string data) { statements.saveWorldState(id, data); }
    ServiceCheckpoint loadServiceCheckpoint(ServiceKind kind, uint realm) { return statements.loadServiceCheckpoint(kind, realm); }
    bool saveServiceCheckpoint(ServiceKind kind, uint realm, const ref ServiceCheckpoint checkpoint)
    {
        return statements.saveServiceCheckpoint(kind, realm, checkpoint);
    }
    BattlegroundCheckpoint[] loadBattlegroundCheckpoints(uint realm, uint map, long since)
    {
        return statements.loadBattlegroundCheckpoints(realm, map, since);
    }
    bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint)
    {
        return statements.saveBattlegroundCheckpoint(realm, map, checkpoint);
    }

    bool publishBattlegroundResult(uint realm, uint match, const PvpStatsBattleground result,
        const(PvpStatsPlayer)[] scores, const(BattlegroundReward)[] rewards, bool keepStatistics)
    {
        return statements.publishBattlegroundResult(realm, match, result, scores, rewards, keepStatistics);
    }

    BattlegroundReward[] pendingBattlegroundRewards()
    {
        return statements.pendingBattlegroundRewards();
    }

    bool payBattlegroundReward(const ref BattlegroundReward reward, const ref BattlegroundPayment payment)
    {
        return statements.payBattlegroundReward(reward, payment);
    }

    bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint,
        const(BattlegroundEventReward)[] rewards)
    {
        return statements.saveBattlegroundCheckpoint(realm, map, checkpoint, rewards);
    }

    BattlegroundEventReward[] pendingBattlegroundEventRewards()
    {
        return statements.pendingBattlegroundEventRewards();
    }

    bool payBattlegroundEventReward(const ref BattlegroundEventReward reward, const ref BattlegroundPayment payment)
    {
        return statements.payBattlegroundEventReward(reward, payment);
    }
    void saveAccountData(bool perCharacter, uint owner, uint type, long time, const(ubyte)[] data)
    {
        statements.saveAccountData(perCharacter, owner, type, time, data);
    }
    const(ubyte)[] accountData(bool perCharacter, uint owner, uint type)
    {
        return statements.accountData(perCharacter, owner, type);
    }
    uint addTicket(TicketRecord ticket) { return statements.addTicket(ticket); }
    void updateTicketText(uint id, string text, long now) { statements.updateTicketText(id, text, now); }
    void closeTicket(uint id) { statements.closeTicket(id); }
    void deleteTicket(uint id) { statements.deleteTicket(id); }
    void saveSpell(uint guid, uint spell, bool active, bool disabled)
    {
        statements.saveSpell(guid, spell, active, disabled);
    }
    void deleteSpell(uint guid, uint spell) { statements.deleteSpell(guid, spell); }
    void saveSkill(uint guid, uint skill, uint value, uint max) { statements.saveSkill(guid, skill, value, max); }
    void saveInventory(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes)
    {
        statements.saveInventory(owner, money, playerBytes2, changes);
    }

    void saveChestAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const InstanceChestRecord chest)
    {
        characterDb.transaction({
            statements.saveInventory(owner, money, playerBytes2, changes);
            statements.saveInstanceChest(chest);
        });
    }

    void saveCorpseAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const InstanceCorpseRecord corpse)
    {
        characterDb.transaction({
            statements.saveInventory(owner, money, playerBytes2, changes);
            statements.saveInstanceCorpse(corpse);
        });
    }

    void savePickpocketAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const PickpocketRecord pocket)
    {
        characterDb.transaction({
            statements.saveInventory(owner, money, playerBytes2, changes);
            statements.savePickpocket(pocket);
        });
    }

    LootAwardResult loadLootAward(const ref LootAwardKey key)
    {
        return statements.loadLootAward(key);
    }

    bool claimLootAward(const ref LootAwardKey key, long now)
    {
        return statements.claimLootAward(key, now);
    }

    void expireLootAward(const ref LootAwardKey key, long now)
    {
        statements.expireLootAward(key, now);
    }

    void saveLootAward(const ref LootAwardKey key, ubyte error, long now, uint money, uint playerBytes2,
        const(ItemChange)[] changes)
    {
        statements.saveLootAward(key, error, now, money, playerBytes2, changes);
    }

    void setMuteTime(uint accountId, long until)
    {
        login.execute!"UPDATE account SET mutetime = ? WHERE id = ?"(until, accountId);
    }

    LookupResult[] lookup(LookupTable table, string text, uint limit)
    {
        const pattern = "%" ~ text ~ "%";
        final switch (table)
        {
        case LookupTable.quest:
            return world.queryAs!(LookupResult, "SELECT entry, Title FROM quest_template WHERE Title LIKE ? "
                ~ "ORDER BY entry LIMIT ?")(pattern, limit);
        case LookupTable.creature:
            return world.queryAs!(LookupResult, "SELECT Entry, Name FROM creature_template WHERE Name LIKE ? "
                ~ "ORDER BY Entry LIMIT ?")(pattern, limit);
        case LookupTable.gameObject:
            return world.queryAs!(LookupResult, "SELECT entry, name FROM gameobject_template WHERE name LIKE ? "
                ~ "ORDER BY entry LIMIT ?")(pattern, limit);
        case LookupTable.spell:
            return world.queryAs!(LookupResult, "SELECT Id, SpellName FROM spell_template WHERE SpellName LIKE ? "
                ~ "ORDER BY Id LIMIT ?")(pattern, limit);
        }
    }

    /// Adds a `game_tele` place.
    void addTeleport(const GameTele t)
    {
        catalog.change(WorldCatalogKey(WorldCatalog.teleports, 0), {
            world.execute!("INSERT INTO game_tele (position_x, position_y, position_z, orientation, map, name) "
                ~ "VALUES (?, ?, ?, ?, ?, ?)")(t.x, t.y, t.z, t.orientation, t.map, t.name);
        });
    }

    /// Deletes the `game_tele` place called `name`; false if there is none.
    bool deleteTeleport(string name)
    {
        bool deleted;
        catalog.change(WorldCatalogKey(WorldCatalog.teleports, 0), {
            deleted = world.execute!"DELETE FROM game_tele WHERE name = ?"(name) != 0;
        });
        return deleted;
    }

    AreaTriggerTeleport[] loadAreaTriggerTeleports()
    {
        return world.queryAs!(AreaTriggerTeleport, areaTriggerTeleportQuery)();
    }

    GameTele[] loadTeleports()
    {
        return world.queryAs!(GameTele, gameTeleQuery)();
    }

    WorldCatalogVersion[] worldCatalogVersions()
    {
        return catalog.current();
    }

    void markWorldCatalogReload(WorldCatalogKey key)
    {
        catalog.change(key);
    }

    VendorItem[] loadVendorItems(uint entry)
    {
        return readVendorItems(world, entry);
    }

    uint[] loadCreatureQuestRelations(bool start, uint entry)
    {
        const rows = start ? world.query!"SELECT quest FROM creature_questrelation WHERE id = ? ORDER BY quest"(entry)
            : world.query!"SELECT quest FROM creature_involvedrelation WHERE id = ? ORDER BY quest"(entry);
        uint[] quests;
        foreach (row; rows)
            quests ~= row.get!uint(0);
        return quests;
    }

    Nullable!float loadCreatureScale(uint entry)
    {
        const rows = world.query!"SELECT Scale FROM creature_template WHERE Entry = ?"(entry);
        return rows.length ? nullable(rows[0].get!float(0)) : Nullable!float.init;
    }

    void saveNewCharacter(const ref NewCharacter character, bool insertTutorialData)
    {
        statements.saveNew(character, insertTutorialData);
    }

    void setRealmCharacterCount(uint accountId, uint realmId, uint count)
    {
        login.transaction({
            login.execute!"DELETE FROM realmcharacters WHERE acctid = ? AND realmid = ?"(accountId, realmId);
            login.execute!"INSERT INTO realmcharacters (numchars, acctid, realmid) VALUES (?, ?, ?)"(count,
                accountId, realmId);
        });
    }

    void deleteCharacter(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId)
    {
        statements.deleteCharacter(guid, accountId, options, nextMailId);
    }

    private static struct AccountRow
    {
        uint id;
        string username;
        string sessionkey;
        string lockedIp;
        uint locked;
        string os;
        string platform;
        long mutetime;
    }

    Nullable!WorldAccount findAccount(string username)
    {
        const rows = login.queryAs!(AccountRow, "SELECT a.id, a.username, a.sessionkey, a.lockedIp, "
            ~ "a.locked, a.os, a.platform, a.mutetime FROM account a WHERE username = ?")(username);
        if (rows.length == 0)
            return Nullable!WorldAccount.init;

        const row = rows[0];
        WorldAccount account;
        account.id = row.id;
        account.username = row.username;
        account.locked = row.locked == 1;
        account.lockedIp = row.lockedIp;
        account.os = row.os;
        account.platform = row.platform;
        account.muteTime = row.mutetime;
        // Only a full 80-digit key is accepted: anything shorter (an empty string in
        // particular) would let a client compute the proof without knowing the key.
        if (row.sessionkey.length == 2 * sessionKeyLength)
        {
            const key = decodeBigNumberHex!sessionKeyLength(row.sessionkey);
            if (!key.isNull)
            {
                account.sessionKey = key.get;
                account.hasSessionKey = true;
            }
        }
        return nullable(account);
    }

    GmAccess gmAccessFor(uint accountId) { return staffAccess(login, accountId); }
    bool changeGmRole(uint accountId, string role, bool grant) { return changeStaffRole(login, accountId, role, grant); }

    bool isBanned(uint accountId, string ip)
    {
        return login.query!("SELECT 1 FROM account_banned WHERE account_id = ? AND active = 1 "
            ~ "AND (expires_at > UNIX_TIMESTAMP() OR expires_at = banned_at) "
            ~ "UNION SELECT 1 FROM ip_banned WHERE (expires_at = banned_at OR expires_at > UNIX_TIMESTAMP()) "
            ~ "AND ip = ?")(accountId, ip).length > 0;
    }

    void recordLogon(uint accountId, string ip)
    {
        login.execute!("INSERT INTO account_logons(accountId, ip, loginTime, loginSource) "
            ~ "VALUES (?, ?, NOW(), ?)")(accountId, ip, loginSourceMangosd);
    }

    CharacterRecord[] characters(uint accountId)
    {
        return characterDb.queryAs!(CharacterRecord, "SELECT characters.guid, characters.name, characters.race, "
            ~ "characters.class, characters.gender, characters.playerBytes, characters.playerBytes2, "
            ~ "characters.level, characters.zone, characters.map, characters.position_x, characters.position_y, "
            ~ "characters.position_z, guild_member.guildid, characters.playerFlags, characters.at_login, "
            ~ "character_pet.entry, character_pet.modelid, character_pet.level, characters.equipmentCache "
            ~ "FROM characters LEFT JOIN character_pet ON characters.guid = character_pet.owner "
            ~ "AND character_pet.slot = ? "
            ~ "LEFT JOIN guild_member ON characters.guid = guild_member.guid "
            ~ "WHERE characters.account = ? ORDER BY characters.guid")(petSaveAsCurrent, accountId);
    }

    /// `character_pet.slot` of the pet currently with its owner.
    private enum uint petSaveAsCurrent = 0;
}

/// A `WorldDatabase` for tests.
final class MemoryWorldDatabase : WorldDatabase, WriteLedger
{
    ulong[uint] appliedWrites; /// `WriteLedger`: by stream

    void prepareLedger() {}
    ulong appliedUpTo(uint stream) { return appliedWrites.get(stream, 0); }

    void applying(uint stream, ulong seq, scope void delegate() work, scope void delegate() beforeCommit)
    {
        beforeCommit(); // nothing to roll back: what it refuses is not carried out
        work(); // a write that throws records nothing
        appliedWrites[stream] = seq;
    }

    WorldAccount[string] accounts;        /// by canonical name
    CharacterRecord[][uint] characterLists; /// by account id
    bool[uint] bannedAccounts;
    bool[string] bannedAddresses;
    string[] logons;
    NewCharacter[uint] saved;      /// characters created through `saveNewCharacter`, by guid
    uint[uint] realmCounts;        /// `realmcharacters.numchars` for this realm, by account
    uint[uint] otherRealmCounts;   /// characters on other realms, by account
    bool[uint] tutorialRows;       /// accounts with a `character_tutorial` row
    bool[uint] guildLeaders;
    uint[] deleted;
    CharacterData[uint] loadable;     /// what `loadCharacter` returns, by guid
    HomeBind[uint] homeBinds;         /// inserted home binds, by guid
    bool[uint] online;                /// characters marked online
    CharacterProgress[] progressSaves;
    uint[4][] actionButtonWrites;     /// guid, button, action, type
    uint[tutorialFields][uint] tutorialSaves; /// by account
    GroupRecord[uint] groups;         /// `groups` and `group_member`, by group id
    private struct SavedLootTurn
    {
        ushort node;
        ulong drop;
        GroupLootRotation rotation;
        long at;
    }
    private SavedLootTurn[][uint] groupLootTurns;
    private struct LootCoinKey
    {
        ushort issuer;
        ulong token;
        uint player;
    }
    private struct SavedLootCoin
    {
        uint copper;
        long paidAt;
    }
    private SavedLootCoin[LootCoinKey] lootCredits;
    long[uint] muteTimes;             /// by account id
    bool[uint][uint] spellRows;       /// guid -> spells learned through `saveSpell`
    uint[2][uint][uint] skillRows;    /// guid -> skill -> value, max
    ItemRecord[uint] itemRows;        /// item guid -> the item, as saved
    uint[uint] itemOwners;            /// item guid -> owner
    uint[2][uint] moneySaves;         /// guid -> money and playerBytes2, as `saveInventory` last saved them
    LookupResult[][LookupTable] lookupRows; /// what `lookup` searches
    GameTele[] teleportRows;          /// `game_tele`
    AreaTriggerTeleport[] areaTriggerRows;

    void setMuteTime(uint accountId, long until)
    {
        muteTimes[accountId] = until;
        foreach (ref account; accounts)
            if (account.id == accountId)
                account.muteTime = until;
    }

    uint characterGuid(string name)
    {
        foreach (list; characterLists)
            foreach (record; list)
                if (record.name == name)
                    return record.guid;
        foreach (guid, c; loadable)
            if (c.name == name)
                return guid;
        return 0;
    }

    string[2][] bugReports;
    const(ubyte)[][string] accountDataRows;
    void saveAccountData(bool perCharacter, uint owner, uint type, long time, const(ubyte)[] data)
    {
        import std.format : format;

        accountDataRows[format!"%s:%s:%s"(perCharacter, owner, type)] = data.idup;
    }
    const(ubyte)[] accountData(bool perCharacter, uint owner, uint type)
    {
        import std.format : format;

        return accountDataRows.get(format!"%s:%s:%s"(perCharacter, owner, type), null);
    }
    void saveBugReport(string type, string content) { bugReports ~= [type, content]; }
    uint[2][uint] giftRows; /// by item: its entry and flags
    void saveGift(uint owner, uint item, uint entry, uint flags) { giftRows[item] = [entry, flags]; }
    bool loadGift(uint item, out uint entry, out uint flags)
    {
        if (auto g = item in giftRows)
        {
            entry = (*g)[0];
            flags = (*g)[1];
            return true;
        }
        return false;
    }
    void deleteGift(uint item) { giftRows.remove(item); }
    long[uint] raidResetRows;
    long[uint] loadRaidResets() { return raidResetRows.dup; }
    void saveRaidReset(uint map, long time) { raidResetRows[map] = time; }
    AuraRecord[][uint] petAuraRows;
    ulong[2][][uint] petCooldownRows;
    void savePetAuras(uint pet, const(AuraRecord)[] auras) { petAuraRows[pet] = auras.dup; }
    AuraRecord[] loadPetAuras(uint pet) { return petAuraRows.get(pet, null).dup; }
    void savePetCooldowns(uint pet, const(ulong[2])[] cooldowns) { petCooldownRows[pet] = cooldowns.dup; }
    ulong[2][] loadPetCooldowns(uint pet) { return petCooldownRows.get(pet, null).dup; }
    string[uint] worldStateRows;
    string worldState(uint id) { return worldStateRows.get(id, null); }
    void saveWorldState(uint id, string data) { worldStateRows[id] = data; }

    private ServiceCheckpoint[uint][ServiceKind] serviceCheckpoints;
    ServiceCheckpoint loadServiceCheckpoint(ServiceKind kind, uint realm) { return serviceCheckpoints.get(kind, null).get(realm, ServiceCheckpoint.init); }
    bool saveServiceCheckpoint(ServiceKind kind, uint realm, const ref ServiceCheckpoint checkpoint)
    {
        if (loadServiceCheckpoint(kind, realm).revision != checkpoint.revision)
            return false;
        serviceCheckpoints[kind][realm] = checkpoint;
        ++serviceCheckpoints[kind][realm].revision;
        return true;
    }
    private BattlegroundCheckpoint[uint][uint][uint] battlegroundCheckpoints;
    BattlegroundCheckpoint[] loadBattlegroundCheckpoints(uint realm, uint map, long since)
    {
        import std.algorithm.searching : startsWith;

        BattlegroundCheckpoint[] rows;
        foreach (row; battlegroundCheckpoints.get(realm, null).get(map, null))
            if (row.state.length && (row.at >= since || row.state.startsWith("F:")))
                rows ~= row;
        return rows;
    }
    bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint)
    {
        return saveBattlegroundCheckpoint(realm, map, checkpoint, null);
    }

    bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint,
        const(BattlegroundEventReward)[] rewards)
    {
        auto refRows = &battlegroundCheckpoints.require(realm, null).require(map, null);
        if (refRows.get(checkpoint.instance, BattlegroundCheckpoint.init).revision != checkpoint.revision)
            return false;
        (*refRows)[checkpoint.instance] = checkpoint;
        ++(*refRows)[checkpoint.instance].revision;
        foreach (ref reward; rewards)
            battlegroundEventRewards.require([reward.reward.realm, reward.reward.match, reward.event,
                reward.reward.player], cast(BattlegroundEventReward) reward);
        return true;
    }

    /// Event rewards not yet paid, by realm, match, event and player.
    BattlegroundEventReward[ulong[4]] battlegroundEventRewards;
    private bool[ulong[4]] paidBattlegroundEvents;

    BattlegroundEventReward[] pendingBattlegroundEventRewards()
    {
        BattlegroundEventReward[] pending;
        foreach (key, ref reward; battlegroundEventRewards)
            if (key !in paidBattlegroundEvents)
                pending ~= reward;
        return pending;
    }

    bool payBattlegroundEventReward(const ref BattlegroundEventReward reward, const ref BattlegroundPayment payment)
    {
        const ulong[4] key = [reward.reward.realm, reward.reward.match, reward.event, reward.reward.player];
        if (key !in battlegroundEventRewards || key in paidBattlegroundEvents)
            return false;
        paidBattlegroundEvents[key] = true;
        if (payment.quests.length)
            saveQuestStatus(reward.reward.player, payment.quests);
        saveReputation(reward.reward.player, payment.reputation);
        if (reward.reward.honor)
            saveHonor(reward.reward.player, loadHonor(reward.reward.player).columns,
                [HonorPointRecord(0, reward.reward.player, reward.reward.honor, reward.reward.honorDay, 1)]);
        return true;
    }

    private bool[uint[2]] publishedBattlegroundResults;
    private BattlegroundReward[uint[3]] battlegroundRewards;

    bool publishBattlegroundResult(uint realm, uint match, const PvpStatsBattleground result,
        const(PvpStatsPlayer)[] scores, const(BattlegroundReward)[] rewards, bool keepStatistics)
    {
        const uint[2] key = [realm, match];
        if (key in publishedBattlegroundResults)
            return true;
        publishedBattlegroundResults[key] = true;
        foreach (ref reward; rewards)
            battlegroundRewards[[realm, match, reward.player]] = cast(BattlegroundReward) reward;
        if (keepStatistics)
            savePvpStats(result, scores);
        return true;
    }

    BattlegroundReward[] pendingBattlegroundRewards() { return battlegroundRewards.values; }

    bool payBattlegroundReward(const ref BattlegroundReward reward, const ref BattlegroundPayment payment)
    {
        if (!battlegroundRewards.remove([reward.realm, reward.match, reward.player]))
            return false;
        if (payment.inventory.length)
            saveInventory(reward.player, payment.money, payment.playerBytes, payment.inventory);
        if (payment.mail.id)
        {
            saveLooseItem(payment.mailedItem, reward.player);
            sendMail(payment.mail);
        }
        saveReputation(reward.player, payment.reputation);
        if (reward.honor)
            saveHonor(reward.player, loadHonor(reward.player).columns,
                [HonorPointRecord(0, reward.player, reward.honor, reward.honorDay, 1)]);
        return true;
    }
    bool[ushort] gameEventStatusRows;
    ushort[] gameEventStatus() { return gameEventStatusRows.keys; }
    void setGameEventStatus(ushort event, bool on)
    {
        if (on)
            gameEventStatusRows[event] = true;
        else
            gameEventStatusRows.remove(event);
    }
    uint[] charactersFor(uint raceMask, uint quest)
    {
        uint[] found;
        foreach (guid, ref c; loadable)
            if (c.race && (raceMask & (1u << (c.race - 1))))
                if (quest == 0 || (guid in questRows && quest in questRows[guid] && questRows[guid][quest].rewarded))
                    found ~= guid;
        return found;
    }
    TicketRecord[] ticketRows;
    TicketRecord[] tickets(bool all)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        return ticketRows.filter!(t => all || !t.closed).array;
    }
    uint addTicket(TicketRecord ticket)
    {
        ticket.id = cast(uint) ticketRows.length + 1;
        ticketRows ~= ticket;
        return ticket.id;
    }
    void updateTicketText(uint id, string text, long now)
    {
        foreach (ref t; ticketRows)
            if (t.id == id)
                t.text = text;
    }
    void closeTicket(uint id)
    {
        foreach (ref t; ticketRows)
            if (t.id == id)
                t.closed = true;
    }
    void deleteTicket(uint id)
    {
        import std.algorithm.mutation : remove;

        foreach (i, t; ticketRows)
            if (t.id == id)
            {
                ticketRows = ticketRows.remove(i);
                return;
            }
    }

    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone)
    {
        if (auto c = guid in loadable)
        {
            c.map = map;
            c.zone = zone;
            c.position = Position(x, y, z, c.position.orientation);
        }
    }

    string[uint] guildRenames; /// `renameGuild`'s writes, by guild

    void renameGuild(uint guildId, string name)
    {
        guildRenames[guildId] = name;
    }

    void addAtLoginFlags(uint guid, uint flags)
    {
        foreach (ref list; characterLists)
            foreach (ref record; list)
                if (record.guid == guid)
                    record.atLogin |= flags;
        if (auto c = guid in loadable)
            c.atLogin |= flags;
    }

    GmNameReview[] gmNamesToReview()
    {
        GmNameReview[] names;
        foreach (guid, ref row; loadable)
            if (row.account && !(row.atLogin & 1))
                names ~= GmNameReview(guid, row.name);
        return names;
    }

    bool gmMarkNameForChange(uint guid, string name)
    {
        if (auto row = guid in loadable)
            if (row.name == name && !(row.atLogin & 1))
            {
                addAtLoginFlags(guid, 1);
                return true;
            }
        return false;
    }

    void renameCharacter(uint guid, string newName)
    {
        foreach (ref list; characterLists)
            foreach (ref record; list)
                if (record.guid == guid)
                {
                    record.name = newName;
                    record.atLogin &= ~1u;
                }
        if (auto c = guid in loadable)
            c.name = newName;
    }

    void saveSpell(uint guid, uint spell, bool active, bool disabled)
    {
        spellRows[guid][spell] = true;
    }

    void deleteSpell(uint guid, uint spell)
    {
        if (auto spells = guid in spellRows)
            (*spells).remove(spell);
    }

    void saveSkill(uint guid, uint skill, uint value, uint max)
    {
        if (max)
            skillRows[guid][skill] = [value, max];
        else if (auto skills = guid in skillRows)
            (*skills).remove(skill);
    }

    void saveInventory(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes)
    {
        foreach (change; changes)
            final switch (change.state)
            {
            case ItemState.new_, ItemState.changed:
                itemRows[change.record.guid] = cast(ItemRecord) change.record;
                itemOwners[change.record.guid] = owner;
                break;
            case ItemState.removed:
                itemRows.remove(change.record.guid);
                itemOwners.remove(change.record.guid);
                break;
            case ItemState.unchanged:
                break;
            }
        moneySaves[owner] = [money, playerBytes2];
    }

    void saveChestAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const InstanceChestRecord chest)
    {
        saveInventory(owner, money, playerBytes2, changes);
        saveInstanceChest(chest);
    }

    void saveCorpseAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const InstanceCorpseRecord corpse)
    {
        saveInventory(owner, money, playerBytes2, changes);
        saveInstanceCorpse(corpse, 0);
    }

    void savePickpocketAward(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes,
        const PickpocketRecord pocket)
    {
        saveInventory(owner, money, playerBytes2, changes);
        savePickpocket(pocket);
    }

    private LootAwardResult[LootAwardKey] lootAwards;
    private long[LootAwardKey] lootAwardTimes;

    LootAwardResult loadLootAward(const ref LootAwardKey key)
    {
        return lootAwards.get(key, LootAwardResult.init);
    }

    bool claimLootAward(const ref LootAwardKey key, long now)
    {
        if (key in lootAwards)
            return false;
        lootAwards[key] = LootAwardResult(true, lootAwardClaimed);
        lootAwardTimes[key] = now;
        return true;
    }

    void expireLootAward(const ref LootAwardKey key, long now)
    {
        import dmangos.world.inventory : InventoryResult;

        if (auto recorded = key in lootAwards)
        {
            if (recorded.claimed && lootAwardTimes.get(key, 0) <= now - lootAwardClaimSeconds)
                *recorded = LootAwardResult(true, InventoryResult.itemNotFound);
        }
        else
            lootAwards[key] = LootAwardResult(true, InventoryResult.itemNotFound);
    }

    void saveLootAward(const ref LootAwardKey key, ubyte error, long now, uint money, uint playerBytes2,
        const(ItemChange)[] changes)
    {
        auto recorded = key in lootAwards;
        if (error)
        {
            if (recorded is null)
                lootAwards[key] = LootAwardResult(true, error);
            else if (recorded.claimed)
                *recorded = LootAwardResult(true, error);
        }
        else if (recorded !is null && recorded.claimed)
        {
            *recorded = LootAwardResult(true, 0);
            saveInventory(key.player, money, playerBytes2, changes);
        }
    }

    LookupResult[] lookup(LookupTable table, string text, uint limit)
    {
        import std.algorithm.searching : canFind;
        import std.uni : toLower;

        LookupResult[] found;
        foreach (row; lookupRows.get(table, null))
            if (found.length < limit && row.name.toLower.canFind(text.toLower))
                found ~= row;
        return found;
    }

    void addTeleport(const GameTele tele)
    {
        teleportRows ~= tele;
        markWorldCatalogReload(WorldCatalogKey(WorldCatalog.teleports, 0));
    }

    bool deleteTeleport(string name)
    {
        import std.algorithm.mutation : remove;

        const before = teleportRows.length;
        teleportRows = teleportRows.remove!(t => t.name == name);
        if (teleportRows.length == before)
            return false;
        markWorldCatalogReload(WorldCatalogKey(WorldCatalog.teleports, 0));
        return true;
    }

    AreaTriggerTeleport[] loadAreaTriggerTeleports()
    {
        return areaTriggerRows.dup;
    }

    GameTele[] loadTeleports()
    {
        return teleportRows.dup;
    }

    private ulong[WorldCatalogKey] savedCatalogVersions;

    WorldCatalogVersion[] worldCatalogVersions()
    {
        WorldCatalogVersion[] versions;
        foreach (key, revision; savedCatalogVersions)
            versions ~= WorldCatalogVersion(key, revision, false);
        return versions;
    }

    void markWorldCatalogReload(WorldCatalogKey key)
    {
        ++savedCatalogVersions.require(key, 0);
    }

    VendorItem[] loadVendorItems(uint entry)
    {
        VendorItem[] result;
        foreach (ref row; vendorRows)
            if (row[0] == entry)
                result ~= VendorItem(row[1], 0, 0, cast(uint) result.length, 0);
        return result;
    }

    uint[] loadCreatureQuestRelations(bool start, uint entry)
    {
        uint[] quests;
        foreach (ref row; questRelationRows)
            if (row[0] == uint(start) && row[1] == entry)
                quests ~= row[2];
        return quests;
    }

    Nullable!float loadCreatureScale(uint entry)
    {
        if (auto scale = entry in creatureScales)
            return nullable(*scale);
        return Nullable!float.init;
    }

    GroupRecord[] loadGroups()
    {
        return groups.values;
    }

    GroupLootRotation loadGroupLootRotation(uint group, ushort node, ulong drop)
    {
        auto turns = groupLootTurns.get(group, null);
        foreach (ref turn; turns)
            if (turn.node == node && turn.drop == drop)
                return turn.rotation;
        if (!turns.length)
            return GroupLootRotation.init;
        const last = turns[$ - 1].rotation;
        return GroupLootRotation(last.nextLooter, 0, last.order);
    }

    bool recordGroupLootRotation(uint group, ushort node, ulong drop, const ref GroupLootRotation turn, long now)
    {
        import std.algorithm.mutation : remove;

        if (group !in groups || loadGroupLootRotation(group, node, drop).assigned)
            return false;
        auto turns = groupLootTurns.get(group, null).remove!(turn => turn.at < now - 120);
        groupLootTurns[group] = turns ~ SavedLootTurn(node, drop, GroupLootRotation(turn.nextLooter, turn.assigned, turn.order.dup), now);
        return true;
    }

    bool saveLootCoinSplit(ushort issuer, ulong token, const(LootCoinCredit)[] shares)
    {
        foreach (ref share; shares)
        {
            const key = LootCoinKey(issuer, token, share.player);
            if (share.copper && key !in lootCredits)
                lootCredits[key] = SavedLootCoin(share.copper);
        }
        return true;
    }

    uint[] pendingLootCoinPlayers()
    {
        bool[uint] players;
        foreach (key, ref credit; lootCredits)
            if (!credit.paidAt)
                players[key.player] = true;
        return players.keys;
    }

    LootCoinRedemption redeemLootCoins(uint player, uint wallet, long now)
    {
        import dmangos.world.money : Copper;

        auto character = player in loadable;
        if (character is null)
            return LootCoinRedemption.init;
        Copper credited;
        foreach (key, ref credit; lootCredits)
            if (key.player == player && !credit.paidAt)
            {
                credited = credited + Copper(credit.copper);
                credit.paidAt = now;
            }
        const saved = moneySaves.get(player, [character.money, character.playerBytes2]);
        const money = (Copper(wallet) + credited).amount;
        if (credited)
            saveInventory(player, money, saved[1], null);
        return LootCoinRedemption(true, money, credited.amount);
    }

    void createGroup(const ref GroupRecord group)
    {
        groupLootTurns.remove(group.id);
        GroupRecord row = cast(GroupRecord) group;
        row.members = null;
        groups[group.id] = row;
    }

    void updateGroup(const ref GroupRecord group)
    {
        auto row = &groups[group.id];
        auto members = row.members;
        *row = cast(GroupRecord) group;
        row.members = members;
    }

    void deleteGroup(uint groupId)
    {
        groupLootTurns.remove(groupId);
        groups.remove(groupId);
    }

    void addGroupMember(uint groupId, const GroupMemberRecord member)
    {
        groups[groupId].members ~= member;
    }

    void updateGroupMember(const GroupMemberRecord member)
    {
        foreach (ref group; groups)
            foreach (ref m; group.members)
                if (m.guid == member.guid)
                    m = member;
    }

    void removeGroupMember(uint guid)
    {
        import std.algorithm.mutation : remove;

        foreach (ref group; groups)
            group.members = group.members.remove!(m => m.guid == guid);
    }

    Nullable!CharacterData loadCharacter(uint guid)
    {
        if (auto c = guid in loadable)
            return nullable(*c);
        return Nullable!CharacterData.init;
    }

    void updateHomeBind(uint guid, const HomeBind bind)
    {
        homeBinds[guid] = bind;
    }

    void insertHomeBind(uint guid, const HomeBind bind)
    {
        homeBinds[guid] = bind;
    }

    void setOnline(uint guid, uint accountId, bool isOnline, uint realmId)
    {
        if (isOnline)
            online[guid] = true;
        else
            online.remove(guid);
    }

    void markAllOffline(uint realmId)
    {
        online = null;
    }

    void saveProgress(const ref CharacterProgress progress)
    {
        progressSaves ~= progress;
    }

    void setActionButton(uint guid, ubyte button, uint action, ubyte type)
    {
        actionButtonWrites ~= [guid, uint(button), action, uint(type)];
    }

    void saveTutorials(uint accountId, const uint[tutorialFields] tutorials)
    {
        tutorialSaves[accountId] = tutorials;
    }

    CorpseRecord[uint] corpses;      /// by player
    AuraRecord[][uint] auraRows;     /// by player
    QuestStatus[uint][uint] questRows; /// by player, then quest
    MailRecord[uint] mails;          /// by id
    string[uint] itemTexts;          /// `item_text`
    ItemRecord[uint] looseItems;     /// items in the mail, by guid
    long[uint] creatureRespawns;     /// by spawn guid
    long[uint] gameObjectRespawns;   /// by spawn guid
    AuctionRecord[uint] auctions;    /// `auction`, by id
    ReputationRecord[uint][uint] reputationRows; /// `character_reputation`: by player, then faction
    HonorRecord[uint] honorRows;                 /// the honor columns and `character_honor_cp`, by player
    BattlegroundData[uint] battlegroundRows;     /// `character_battleground_data`, by player
    PvpStatsBattleground[] pvpStatsRows;         /// `pvpstats_battlegrounds`, in order (the id: the index + 1)
    PvpStatsPlayer[][] pvpStatsPlayerRows;       /// `pvpstats_players`, by battle (ditto)
    void savePvpStats(const PvpStatsBattleground battle, const(PvpStatsPlayer)[] players)
    {
        pvpStatsRows ~= battle;
        pvpStatsPlayerRows ~= players.dup;
    }
    uint nextMaintenance;                        /// `saved_variables.NextMaintenanceDate`

    void saveCorpse(const ref CorpseRecord c) { corpses[c.player] = c; }
    void saveAuras(uint player, const(AuraRecord)[] auras) { auraRows[player] = auras.dup; }
    CooldownRecord[][uint] cooldownRows; /// by player
    long[2][uint] talentResets; /// by player: cost, time
    GuildRecord[uint] guildRows; /// by id
    private ulong guildVersion = 1;
    private uint lastGuildId;
    ulong guildRevision() { return guildVersion; }
    ulong commitGuildChange(scope bool delegate(WorldDatabase db, ulong revision) change)
    {
        if (change(this, guildVersion))
            ++guildVersion;
        return guildVersion;
    }
    GuildRecord[] loadGuilds()
    {
        GuildRecord[] records;
        foreach (id, ref record; guildRows)
            records ~= loadGuild(id).get;
        return records;
    }
    Nullable!GuildRecord loadGuild(uint id)
    {
        if (auto g = id in guildRows)
        {
            GuildRecord copy = *g;
            copy.ranks = g.ranks.dup;
            copy.members = g.members.dup;
            copy.events = g.events.dup;
            foreach (ref m; copy.members)
                if (auto c = m.guid in loadable)
                {
                    m.name = c.name;
                    m.level = cast(ubyte) c.level;
                    m.classId = c.classId;
                    m.account = c.account;
                }
            return nullable(copy);
        }
        return Nullable!GuildRecord.init;
    }
    uint nextGuildId()
    {
        foreach (k, _; guildRows)
            if (k > lastGuildId)
                lastGuildId = k;
        return ++lastGuildId;
    }
    void saveGuild(const ref GuildRecord guild)
    {
        auto g = &guildRows.require(guild.id, GuildRecord.init);
        auto ranks = g.ranks, members = g.members, events = g.events;
        *g = cast(GuildRecord) guild;
        g.ranks = ranks;
        g.members = members;
        g.events = events;
    }
    void saveGuildRanks(uint guild, const(GuildRankRecord)[] ranks)
    {
        if (auto g = guild in guildRows)
            g.ranks = ranks.dup;
    }
    void saveGuildMember(uint guild, uint member, uint rank, string publicNote, string officerNote)
    {
        deleteGuildMember(member);
        if (auto g = guild in guildRows)
            g.members ~= GuildMemberRecord(member, rank, publicNote, officerNote);
    }
    void deleteGuildMember(uint member)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        foreach (ref g; guildRows)
            g.members = g.members.filter!(m => m.guid != member).array;
    }
    void deleteGuild(uint guild) { guildRows.remove(guild); }
    void saveGuildEvent(uint guild, const ref GuildEventRecord event)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        if (auto g = guild in guildRows)
            g.events = g.events.filter!(e => e.logGuid != event.logGuid).array ~ event;
    }
    PetitionRecord[uint] petitionRows; /// by charter item
    uint[uint][uint] petitionAccounts; /// petition -> signer -> account
    Nullable!PetitionRecord loadPetition(uint petition)
    {
        if (auto p = petition in petitionRows)
        {
            PetitionRecord copy = *p;
            copy.signers = p.signers.dup;
            return nullable(copy);
        }
        return Nullable!PetitionRecord.init;
    }
    void createPetition(uint owner, uint petition, string name)
    {
        foreach (id, p; petitionRows.dup)
            if (p.owner == owner)
                deletePetition(id);
        petitionRows[petition] = PetitionRecord(petition, owner, name);
    }
    void signPetition(uint owner, uint petition, uint player, uint account)
    {
        if (auto p = petition in petitionRows)
        {
            p.signers ~= player;
            petitionAccounts.require(petition, null)[player] = account;
        }
    }
    bool accountSignedPetition(uint account, uint petition)
    {
        foreach (_, a; petitionAccounts.get(petition, null))
            if (a == account)
                return true;
        return false;
    }
    void deletePetition(uint petition)
    {
        petitionRows.remove(petition);
        petitionAccounts.remove(petition);
    }
    void deletePetitionsOf(uint player)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        foreach (id, p; petitionRows.dup)
            if (p.owner == player)
                deletePetition(id);
        foreach (ref p; petitionRows)
            p.signers = p.signers.filter!(s => s != player).array;
    }
    ubyte[uint][uint] socialRows; /// by player, then the other character
    SocialRow[] loadSocial(uint player)
    {
        SocialRow[] rows;
        foreach (other, flags; socialRows.get(player, null))
            rows ~= SocialRow(other, flags);
        return rows;
    }
    void saveSocial(uint player, uint other, ubyte flags)
    {
        if (flags)
            socialRows.require(player, null)[other] = flags;
        else if (auto rows = player in socialRows)
            (*rows).remove(other);
    }
    bool isIgnoring(uint player, uint other)
    {
        return (socialRows.get(player, null).get(other, 0) & 2) != 0;
    }
    void saveTalentReset(uint player, uint cost, long time) { talentResets[player] = [cost, time]; }
    void loadTalentReset(uint player, out uint cost, out long time)
    {
        if (auto r = player in talentResets)
        {
            cost = cast(uint)(*r)[0];
            time = (*r)[1];
        }
    }
    void saveCooldowns(uint player, const(CooldownRecord)[] cooldowns) { cooldownRows[player] = cooldowns.dup; }
    CooldownRecord[] loadCooldowns(uint player) { return cooldownRows.get(player, null).dup; }
    PetRecord[uint] petRows;    /// by pet number
    uint[uint] stableSlotRows;  /// by player
    PetRecord[] loadPets(uint owner)
    {
        import std.algorithm.sorting : sort;

        PetRecord[] found;
        foreach (ref p; petRows)
            if (p.owner == owner)
            {
                found ~= p;
                found[$ - 1].spells = p.spells.dup;
            }
        found.sort!((a, b) => a.id < b.id);
        return found;
    }
    void savePet(const ref PetRecord pet)
    {
        auto copy = cast(PetRecord) pet;
        copy.spells = pet.spells.dup;
        petRows[pet.id] = copy;
    }
    void setPetSlot(uint owner, uint pet, uint slot)
    {
        if (auto p = pet in petRows)
            if (p.owner == owner)
                p.slot = slot;
    }
    void deletePet(uint owner, uint pet)
    {
        if (auto p = pet in petRows)
            if (p.owner == owner)
                petRows.remove(pet);
    }
    uint loadStableSlots(uint player) { return stableSlotRows.get(player, 0); }
    void saveStableSlots(uint player, uint slots) { stableSlotRows[player] = slots; }
    AuraRecord[] loadAuras(uint player) { return auraRows.get(player, null).dup; }
    void saveReputation(uint player, const(ReputationRecord)[] rows)
    {
        foreach (ref r; rows)
            reputationRows.require(player, null)[r.faction] = r;
    }
    ReputationRecord[] loadReputation(uint player) { return reputationRows.get(player, null).values; }
    HonorRecord loadHonor(uint player) { return honorRows.get(player, HonorRecord.init); }
    BattlegroundData loadBattlegroundData(uint player) { return battlegroundRows.get(player, BattlegroundData.init); }
    void saveBattlegroundData(uint player, const BattlegroundData data)
    {
        if (data == BattlegroundData.init)
            battlegroundRows.remove(player);
        else
            battlegroundRows[player] = data;
    }
    void saveHonor(uint player, const HonorColumns columns, const(HonorPointRecord)[] added)
    {
        auto record = &honorRows.require(player, HonorRecord.init);
        record.columns = columns;
        record.points ~= added;
    }
    uint nextHonorMaintenance() { return nextMaintenance; }
    void setNextHonorMaintenance(uint day) { nextMaintenance = day; }
    uint oldestHonorDay()
    {
        import dmangos.world.honor : dateOfHonorDay;

        uint oldest;
        foreach (ref r; honorRows)
            foreach (ref p; r.points)
                if (p.type == 1 && (oldest == 0 || dateOfHonorDay(p.date) < dateOfHonorDay(oldest)))
                    oldest = p.date;
        return oldest;
    }
    HonorWeekEntry[] honorWeek(uint from, uint until)
    {
        import dmangos.world.honor : dateOfHonorDay;

        HonorWeekEntry[] found;
        foreach (guid, ref r; honorRows)
        {
            HonorWeekEntry e;
            e.guid = guid;
            e.storedRating = r.columns.storedRating;
            foreach (ref c; characterLists)
                foreach (ref ch; c)
                    if (ch.guid == guid)
                        e.race = ch.race;
            bool any;
            foreach (ref p; r.points)
                if (p.type == 1 && dateOfHonorDay(p.date) >= dateOfHonorDay(from) && dateOfHonorDay(p.date) < dateOfHonorDay(until))
                {
                    any = true;
                    e.honor += p.honor;
                    e.kills += p.victimType == 3 || p.victimType == 4;
                }
            if (any)
                found ~= e;
        }
        return found;
    }
    void setHonorRating(uint player, float rating, uint standing, bool setStanding)
    {
        auto r = &honorRows.require(player, HonorRecord.init);
        r.columns.storedRating = rating;
        if (setStanding)
            r.columns.standing = standing;
    }
    void clearHonorStandings()
    {
        foreach (ref r; honorRows)
            r.columns.standing = 0;
    }
    void foldHonorPoints(uint day)
    {
        import dmangos.world.honor : dateOfHonorDay;

        foreach (ref r; honorRows)
        {
            typeof(r.points) kept;
            foreach (ref p; r.points)
            {
                if (dateOfHonorDay(p.date) >= dateOfHonorDay(day))
                {
                    kept ~= p;
                    continue;
                }
                if (p.victimType == 3 || p.victimType == 4)
                {
                    if (p.type == 1)
                        ++r.columns.storedHonorableKills;
                    else
                        ++r.columns.storedDishonorableKills;
                }
            }
            r.points = kept;
        }
    }
    void saveQuestStatus(uint player, const(QuestStatus)[] quests)
    {
        foreach (ref q; quests)
            questRows.require(player, null)[q.quest] = q;
    }
    void sendMail(const ref MailRecord mail) { mails[mail.id] = mail; }
    MailRecord[] loadMail(uint receiver)
    {
        import std.algorithm.sorting : sort;

        MailRecord[] found;
        foreach (ref m; mails)
            if (m.receiver == receiver)
                found ~= m;
        found.sort!((a, b) => a.id < b.id);
        return found;
    }
    Nullable!MailRecord mailById(uint id)
    {
        if (auto m = id in mails)
            return Nullable!MailRecord(*m);
        return Nullable!MailRecord.init;
    }
    void updateMail(const ref MailRecord mail) { mails[mail.id] = mail; }
    void deleteMail(uint id) { mails.remove(id); }
    MailRecord[] expiredMail(long now)
    {
        import std.algorithm.sorting : sort;

        MailRecord[] found;
        foreach (ref m; mails)
            if (m.expireTime < now)
                found ~= m;
        found.sort!((a, b) => a.expireTime < b.expireTime);
        return found;
    }
    void deleteLooseItem(uint guid) { looseItems.remove(guid); itemRows.remove(guid); }
    void saveItemText(uint id, string text) { itemTexts[id] = text; }
    string itemText(uint id) { return itemTexts.get(id, null); }
    void saveLooseItem(const ref ItemRecord item, uint owner) { looseItems[item.guid] = item; itemRows[item.guid] = item; }
    Nullable!ItemRecord looseItem(uint guid)
    {
        if (auto item = guid in looseItems)
            return Nullable!ItemRecord(*item);
        return Nullable!ItemRecord.init;
    }
    uint[2] characterRaceAccount(uint guid)
    {
        if (auto c = guid in loadable)
            return [c.race, c.account];
        return [0, 0];
    }
    void deleteCorpse(uint player) { corpses.remove(player); }
    Nullable!CorpseRecord loadCorpse(uint player)
    {
        if (auto c = player in corpses)
            return Nullable!CorpseRecord(*c);
        return Nullable!CorpseRecord.init;
    }
    void saveCreatureRespawn(uint spawnGuid, long respawnTime)
    {
        if (respawnTime)
        {
            creatureRespawns[spawnGuid] = respawnTime;
            pockets.remove([0, spawnGuid]);
        }
        else
            creatureRespawns.remove(spawnGuid);
    }
    long[uint] loadCreatureRespawns() { return creatureRespawns.dup; }

    private CreaturePoolState[uint][uint] creaturePoolStates;
    private GameObjectPoolState[uint][uint] gameObjectPoolStates;

    CreaturePoolState[uint] loadCreaturePoolStates(uint realm) { return creaturePoolStates.get(realm, null).dup; }

    bool updateCreaturePoolState(uint realm, uint pool, ulong revision, uint spawn, long due,
        const InstanceCorpseRecord corpse = InstanceCorpseRecord.init)
    {
        auto states = realm in creaturePoolStates;
        const previous = states is null ? null : pool in *states;
        if ((previous is null ? 0 : previous.revision) != revision)
            return false;
        creaturePoolStates[realm][pool] = CreaturePoolState(spawn, due, revision + 1);
        if (due)
            pockets.remove([0, spawn]);
        if (corpse.spawn)
            saveInstanceCorpse(corpse, 0);
        return true;
    }

    GameObjectPoolState[uint] loadGameObjectPoolStates(uint realm)
    {
        GameObjectPoolState[uint] copies;
        foreach (pool, state; gameObjectPoolStates.get(realm, null))
            copies[pool] = GameObjectPoolState(state.revision, state.placements.dup);
        return copies;
    }

    bool updateGameObjectPoolState(uint realm, uint pool, const ref GameObjectPoolState state, uint exhaustedChest = 0)
    {
        if (gameObjectPoolStates.get(realm, null).get(pool, GameObjectPoolState.init).revision != state.revision)
            return false;
        gameObjectPoolStates[realm][pool] = GameObjectPoolState(state.revision + 1, state.placements.dup);
        if (exhaustedChest)
        {
            import std.algorithm.mutation : remove;

            instanceRows.chests = instanceRows.chests.remove!(row => row.instance == 0 && row.spawn == exhaustedChest);
        }
        return true;
    }
    InstanceRecords instanceRows;    /// what the instance methods keep
    InstanceRecords loadInstances() { return instanceRows; }
    void saveInstance(uint id, uint map, long resetTime) { instanceRows.instances ~= InstanceRecord(id, map, resetTime); }
    void saveInstanceData(uint id, string data)
    {
        foreach (ref r; instanceRows.instances)
            if (r.id == id)
                r.data = data;
    }

    void saveInstanceChest(const InstanceChestRecord chest)
    {
        foreach (ref row; instanceRows.chests)
            if (row.instance == chest.instance && row.spawn == chest.spawn)
            {
                row = chest;
                return;
            }
        instanceRows.chests ~= chest;
    }

    InstanceChestRecord[] loadOutdoorChests()
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        return instanceRows.chests.filter!(row => !row.instance).array;
    }

    InstanceChestRecord loadOutdoorChest(uint spawn)
    {
        foreach (ref row; instanceRows.chests)
            if (!row.instance && row.spawn == spawn)
                return row;
        return InstanceChestRecord.init;
    }

    void finishOutdoorChest(uint spawn, long respawnAt)
    {
        saveGameObjectRespawn(spawn, respawnAt);
        deleteOutdoorChest(spawn);
    }

    void finishScriptedOutdoorChest(uint realm, ulong actor, uint spawn)
    {
        deleteOutdoorChest(spawn);
        deleteQuestActor(realm, actor);
    }

    private void deleteOutdoorChest(uint spawn)
    {
        import std.algorithm.mutation : remove;

        instanceRows.chests = instanceRows.chests.remove!(row => row.instance == 0 && row.spawn == spawn);
    }

    void saveInstanceCorpse(const InstanceCorpseRecord corpse, long respawnAt)
    {
        if (respawnAt)
        {
            if (corpse.instance)
                saveInstanceRespawn(false, corpse.spawn, corpse.instance, respawnAt);
            else
                saveCreatureRespawn(corpse.spawn, respawnAt);
        }
        foreach (ref row; instanceRows.corpses)
            if (row.instance == corpse.instance && row.spawn == corpse.spawn)
            {
                row = corpse;
                return;
            }
        instanceRows.corpses ~= corpse;
    }

    void deleteInstanceCorpse(uint instance, uint spawn)
    {
        import std.algorithm.mutation : remove;

        instanceRows.corpses = instanceRows.corpses.remove!(r => r.instance == instance && r.spawn == spawn);
    }

    InstanceCorpseRecord[] loadOutdoorCorpses()
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        return instanceRows.corpses.filter!(row => !row.instance).array;
    }

    private PickpocketRecord[uint[2]] pockets;
    private QuestActorCheckpoint[ulong][uint] questActors;
    private OutdoorScriptCheckpoint[ulong][ushort][uint] outdoorScripts;
    private string[uint] playerSummons;
    private PartySummonCheckpoint[uint] partySummonOffers;

    PartySummonCheckpoint loadPartySummonOffer(uint player)
    {
        return partySummonOffers.get(player, PartySummonCheckpoint.init);
    }

    bool publishPartySummonOffer(uint player, ulong sequence, string state)
    {
        if (loadPartySummonOffer(player).sequence >= sequence)
            return false;
        partySummonOffers[player] = PartySummonCheckpoint(sequence, state);
        return true;
    }

    bool consumePartySummonOffer(uint player, ulong sequence)
    {
        auto offer = player in partySummonOffers;
        if (offer is null || offer.sequence != sequence || !offer.state.length)
            return false;
        offer.state = null;
        return true;
    }

    void deletePartySummonOffer(uint player) { partySummonOffers.remove(player); }

    string loadPlayerSummons(uint player) { return playerSummons.get(player, null); }

    void savePlayerSummons(uint player, string state)
    {
        if (state.length)
            playerSummons[player] = state;
        else
            playerSummons.remove(player);
    }

    void savePlayerRecovery(const ref CharacterProgress progress, string state)
    {
        saveProgress(progress);
        savePlayerSummons(progress.guid, state);
    }

    OutdoorScriptCheckpoint[] loadOutdoorScripts(uint realm)
    {
        OutdoorScriptCheckpoint[] scripts;
        foreach (origin; outdoorScripts.get(realm, null))
            foreach (script; origin.byValue)
            {
                script.waitingForSummons = outdoorSummonsPending(realm, script.origin, script.sequence);
                scripts ~= script;
            }
        return scripts;
    }

    bool beginOutdoorScript(uint realm, const ref OutdoorScriptCheckpoint script)
    {
        auto scripts = &outdoorScripts.require(realm, null).require(script.origin, null);
        if (script.sequence in *scripts)
            return false;
        (*scripts)[script.sequence] = script;
        return true;
    }

    bool advanceOutdoorScript(uint realm, ushort origin, ulong sequence, uint cursor, bool finished,
        const(OutdoorQuestUpdate)[] updates = null, const(QuestActorCheckpoint)[] summons = null,
        const(OutdoorScriptCheckpoint)[] relays = null, const(OutdoorSummonRequest)[] forwards = null,
        const(OutdoorWorldState)[] worldStates = null)
    {
        auto scripts = origin in outdoorScripts.get(realm, null);
        if (scripts is null)
            return false;
        auto script = sequence in *scripts;
        if (script is null || script.cursor != cursor)
            return false;
        checkSummonRelays(realm, relays);
        if (finished)
            (*scripts).remove(sequence);
        else
            ++script.cursor;
        foreach (ref update; updates)
            saveQuestStatus(update.player, update.quests);
        foreach (ref summon; summons)
            saveQuestActor(realm, summon);
        foreach (ref relay; relays)
            beginOutdoorScript(realm, relay);
        foreach (ref request; forwards)
            outdoorSummons[realm] ~= request;
        foreach (ref state; worldStates)
            saveOutdoorWorldState(realm, state);
        return true;
    }

    private OutdoorWorldState[ulong][uint] outdoorWorldStates;

    OutdoorWorldState[] loadOutdoorWorldStates(uint realm)
    {
        return outdoorWorldStates.get(realm, null).values;
    }

    void saveOutdoorWorldState(uint realm, const ref OutdoorWorldState state)
    {
        outdoorWorldStates[realm][(ulong(state.map) << 32) | state.id] = state;
    }

    private OutdoorSummonRequest[][uint] outdoorSummons;

    private void checkSummonRelays(uint realm, const(OutdoorScriptCheckpoint)[] relays)
    {
        foreach (ref relay; relays)
            if (relay.sequence in outdoorScripts.get(realm, null).get(relay.origin, null))
                throw new imported!"dmangos.mysql".DatabaseException("summon relay checkpoint already exists");
    }

    OutdoorSummonRequest[] loadOutdoorSummons(uint realm)
    {
        auto requests = outdoorSummons.get(realm, null).dup;
        foreach (ref request; requests)
            request.checkpoint = questActors.get(realm, null).get(request.actor, QuestActorCheckpoint.init);
        return requests;
    }

    bool enqueueOutdoorSummon(uint realm, const ref OutdoorSummonRequest request)
    {
        import std.algorithm.searching : any;

        if (!outdoorSummons.get(realm, null).any!(r => r.sameRequest(request)))
            outdoorSummons[realm] ~= request;
        return true;
    }

    bool outdoorSummonsPending(uint realm, ushort origin, ulong sequence)
    {
        import std.algorithm.searching : any;

        return outdoorSummons.get(realm, null).any!(r => r.origin == origin && r.sequence == sequence);
    }

    bool commitOutdoorSummon(uint realm, const ref OutdoorSummonRequest request,
        const ref QuestActorCheckpoint actor, const(OutdoorScriptCheckpoint)[] relays, uint chest = 0)
    {
        foreach (ref pending; outdoorSummons.get(realm, null))
            if (pending.sameRequest(request) && !pending.actor)
            {
                checkSummonRelays(realm, relays);
                pending.actor = actor.actor;
                if (chest)
                    deleteOutdoorChest(chest);
                saveQuestActor(realm, actor);
                foreach (ref relay; relays)
                    beginOutdoorScript(realm, relay);
                return true;
            }
        return false;
    }

    bool commitOutdoorDespawn(uint realm, const ref OutdoorSummonRequest request, ulong actor, uint chest = 0,
        long respawnAt = 0)
    {
        import dmangos.world.objects : counterOf;

        foreach (ref pending; outdoorSummons.get(realm, null))
            if (pending.sameRequest(request) && !pending.actor)
            {
                pending.actor = actor;
                if (chest)
                    deleteOutdoorChest(chest);
                deleteQuestActor(realm, actor);
                if (respawnAt)
                    saveGameObjectRespawn(counterOf(actor), respawnAt);
                return true;
            }
        return false;
    }

    bool retireOutdoorSummon(uint realm, const ref OutdoorSummonRequest request)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        if (auto requests = realm in outdoorSummons)
        {
            const index = (*requests).countUntil!(r => r.sameRequest(request) && r.actor == request.actor);
            if (index >= 0)
            {
                *requests = (*requests).remove(cast(size_t) index);
                return true;
            }
        }
        return false;
    }

    QuestActorCheckpoint[] loadQuestActors(uint realm) { return questActors.get(realm, null).values; }
    void saveQuestActor(uint realm, const QuestActorCheckpoint actor) { questActors[realm][actor.actor] = actor; }
    void deleteQuestActor(uint realm, ulong actor)
    {
        if (auto actors = realm in questActors)
            (*actors).remove(actor);
    }

    private DungeonFightCheckpoint[uint][uint] dungeonFights;
    DungeonFightCheckpoint[] loadDungeonFights(uint instance) { return dungeonFights.get(instance, null).values; }
    void saveDungeonFight(uint instance, const DungeonFightCheckpoint fight) { dungeonFights[instance][fight.spawn] = fight; }
    void deleteDungeonFight(uint instance, uint spawn)
    {
        if (auto fights = instance in dungeonFights)
            (*fights).remove(spawn);
    }

    PickpocketRecord loadPickpocket(uint instance, uint spawn)
    {
        return pockets.get([instance, spawn], PickpocketRecord.init);
    }

    void savePickpocket(const PickpocketRecord pocket)
    {
        pockets[[pocket.instance, pocket.spawn]] = pocket;
    }

    uint instanceMapOf(uint id)
    {
        foreach (ref r; instanceRows.instances)
            if (r.id == id)
                return r.map;
        return uint.max;
    }

    uint[uint] instanceBindsOf(uint player)
    {
        uint[uint] binds;
        foreach (ref b; instanceRows.binds)
            if (!b.group && b.owner == player)
            {
                const m = instanceMapOf(b.instance);
                if (m != uint.max)
                    binds[m] = b.instance;
            }
        return binds;
    }
    void deleteInstance(uint id)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        instanceRows.instances = instanceRows.instances.filter!(r => r.id != id).array;
        instanceRows.binds = instanceRows.binds.filter!(b => b.instance != id).array;
        instanceRows.respawns = instanceRows.respawns.filter!(r => r.instance != id).array;
        instanceRows.chests = instanceRows.chests.filter!(r => r.instance != id).array;
        instanceRows.corpses = instanceRows.corpses.filter!(r => r.instance != id).array;
        dungeonFights.remove(id);
        foreach (key; pockets.keys)
            if (key[0] == id)
                pockets.remove(key);
    }
    private import dmangos.world.context : InstanceEntry;
    private InstanceEntry[][uint] instanceEntries;

    bool instanceLimitReached(uint account, uint instance, long now)
    {
        import dmangos.world.context : tooManyInstances, withinTheHour;

        return tooManyInstances(withinTheHour(instanceEntries.get(account, null), now), instance);
    }

    bool admitInstance(uint account, uint instance, long now)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.context : InstanceEntry, tooManyInstances, withinTheHour;

        assert(instance);
        auto recent = withinTheHour(instanceEntries.get(account, null), now);
        if (tooManyInstances(recent, instance))
            return false;
        if (!recent.canFind!(e => e.instance == instance))
            recent ~= InstanceEntry(instance, now);
        instanceEntries[account] = recent;
        return true;
    }
    void saveInstanceBind(bool group, uint owner, uint instance, bool permanent)
    {
        instanceRows.binds ~= InstanceBindRecord(group, owner, instance, permanent);
    }
    void saveInstanceRespawn(bool gameObject, uint spawnGuid, uint instance, long until)
    {
        instanceRows.respawns ~= InstanceRespawnRecord(gameObject, spawnGuid, instance, until);
        if (!gameObject)
            pockets.remove([instance, spawnGuid]);
    }
    void deleteInstanceRespawn(uint spawnGuid, uint instance)
    {
        import std.algorithm.mutation : remove;

        instanceRows.respawns = instanceRows.respawns.remove!(r => !r.gameObject && r.spawnGuid == spawnGuid
            && r.instance == instance);
    }
    CreatureSpawn[uint] creatureSpawnRows;     /// what `insertCreatureSpawn` wrote, by guid
    GameObjectSpawn[uint] gameObjectSpawnRows; /// ditto, game objects
    private uint lastCreatureSpawn, lastGameObjectSpawn;
    private ulong[uint] temporaryCounters;
    uint createCreatureSpawn(const ref CreatureSpawn spawn)
    {
        CreatureSpawn row = spawn;
        while (++lastCreatureSpawn in creatureSpawnRows) {}
        row.guid = lastCreatureSpawn;
        insertCreatureSpawn(row);
        return row.guid;
    }
    Nullable!ulong reserveTemporaryCounters(uint realm, uint count)
    {
        const first = temporaryCounters.get(realm, 0);
        temporaryCounters[realm] = first + count;
        return nullable!ulong(first);
    }
    Nullable!CreatureSpawn savedCreatureSpawn(uint guid)
    {
        if (auto row = guid in creatureSpawnRows)
            return nullable(*row);
        return Nullable!CreatureSpawn.init;
    }
    WaypointNode[][uint] waypointRows;

    bool saveSpawnWaypoints(uint spawn, MotionType mode, const(WaypointNode)[] nodes)
    {
        auto creature = spawn in creatureSpawnRows;
        if (creature is null)
            return false;
        creature.movementType = mode;
        waypointRows[spawn] = nodes.dup;
        return true;
    }

    imported!"dmangos.world.creaturelinking".CreatureLink[uint] gmSpawnLinks;

    bool saveGmSpawnLink(uint follower, const ref imported!"dmangos.world.creaturelinking".CreatureLink link)
    {
        if (!follower || follower == link.masterGuid || follower !in creatureSpawnRows
            || (link.masterGuid && (link.masterGuid !in creatureSpawnRows
                || creatureSpawnRows[link.masterGuid].map != creatureSpawnRows[follower].map)))
            return false;
        bool[uint] visited;
        for (uint next = link.masterGuid; next; next = gmSpawnLinks.get(next, imported!"dmangos.world.creaturelinking".CreatureLink.init).masterGuid)
        {
            if (next == follower || next in visited)
                return false;
            visited[next] = true;
        }
        gmSpawnLinks[follower] = link;
        return true;
    }

    bool addGmNpcSpell(uint list, uint spell, int target, uint repeatMs) { return false; }
    bool setGmTransportPeriod(uint entry, uint period) { return false; }

    CreatureSpawn[] savedCreatureSpawnsAfter(uint guid)
    {
        CreatureSpawn[] spawns;
        foreach (id, ref row; creatureSpawnRows)
            if (id > guid && row.entry)
                spawns ~= row;
        return spawns;
    }
    void insertCreatureSpawn(const ref CreatureSpawn s) { creatureSpawnRows[s.guid] = s; }
    void deleteCreatureSpawn(uint guid) { creatureSpawnRows.remove(guid); }
    bool eraseSavedSpawn(uint guid, bool gameObject)
    {
        if (gameObject)
            deleteGameObjectSpawn(guid);
        else
            deleteCreatureSpawn(guid);
        return true;
    }
    uint[3][] questRelationRows; /// (start, entry, quest) that `insertQuestRelation` wrote and are not deleted
    void insertQuestRelation(bool start, uint entry, uint quest)
    {
        questRelationRows ~= [start, entry, quest];
        markWorldCatalogReload(WorldCatalogKey(start ? WorldCatalog.questStarter : WorldCatalog.questFinisher, entry));
    }
    void deleteQuestRelation(bool start, uint entry, uint quest)
    {
        import std.algorithm.mutation : remove;

        questRelationRows = questRelationRows.remove!(r => r == [uint(start), entry, quest]);
        markWorldCatalogReload(WorldCatalogKey(start ? WorldCatalog.questStarter : WorldCatalog.questFinisher, entry));
    }
    float[uint] creatureScales; /// what `updateCreatureScale` wrote, by entry
    void updateCreatureScale(uint entry, float scale)
    {
        creatureScales[entry] = scale;
        markWorldCatalogReload(WorldCatalogKey(WorldCatalog.creatureScale, entry));
    }
    uint[2][] vendorRows; /// what `insertVendorItem` wrote (entry, item), less what `deleteVendorItem` removed
    uint[3][ulong] trainerLessonRows;

    bool insertTrainerLesson(uint entry, uint spell, uint cost, ubyte requiredLevel)
    {
        const key = (ulong(entry) << 32) | spell;
        if (key in trainerLessonRows)
            return false;
        trainerLessonRows[key] = [spell, cost, requiredLevel];
        markWorldCatalogReload(WorldCatalogKey(WorldCatalog.trainer, entry));
        return true;
    }

    imported!"dmangos.world.npcdata".TrainerSpell[] loadTrainerLessons(uint entry,
        const imported!"dmangos.world.spells".SpellData spells)
    {
        import dmangos.world.npcdata : TrainerSpell, trainerLesson;

        TrainerSpell[] result;
        foreach (key, lesson; trainerLessonRows)
            if (key >> 32 == entry)
                result ~= trainerLesson(spells, lesson[0], lesson[1], lesson[2]);
        return result;
    }

    imported!"dmangos.world.quests".QuestData questCatalog;
    imported!"dmangos.world.quests".QuestData loadQuestCatalog() { return questCatalog; }
    imported!"dmangos.world.quests".QuestData reloadQuestCatalog()
    {
        if (questCatalog !is null)
            markWorldCatalogReload(WorldCatalogKey(WorldCatalog.quests, 0));
        return questCatalog;
    }

    void insertVendorItem(uint entry, uint item)
    {
        vendorRows ~= [entry, item];
        markWorldCatalogReload(WorldCatalogKey(WorldCatalog.vendor, entry));
    }
    void deleteVendorItem(uint entry, uint item)
    {
        import std.algorithm.mutation : remove;

        vendorRows = vendorRows.remove!(r => r == [entry, item]);
        markWorldCatalogReload(WorldCatalogKey(WorldCatalog.vendor, entry));
    }
    uint createGameObjectSpawn(const ref GameObjectSpawn spawn)
    {
        GameObjectSpawn row = spawn;
        while (++lastGameObjectSpawn in gameObjectSpawnRows) {}
        row.guid = lastGameObjectSpawn;
        insertGameObjectSpawn(row);
        return row.guid;
    }
    bool updateGameObjectPlacement(const ref GameObjectSpawn spawn)
    {
        auto row = spawn.guid in gameObjectSpawnRows;
        if (row is null)
            return false;
        row.x = spawn.x;
        row.y = spawn.y;
        row.z = spawn.z;
        row.orientation = spawn.orientation;
        row.rotation = spawn.rotation;
        return true;
    }
    Nullable!GameObjectSpawn savedGameObjectSpawn(uint guid)
    {
        if (auto row = guid in gameObjectSpawnRows)
            return nullable(*row);
        return Nullable!GameObjectSpawn.init;
    }
    GameObjectSpawn[] savedGameObjectSpawnsAfter(uint guid)
    {
        GameObjectSpawn[] spawns;
        foreach (id, ref row; gameObjectSpawnRows)
            if (id > guid && row.entry)
                spawns ~= row;
        return spawns;
    }
    GameObjectSpawn[] savedGameObjectSpawnsOnMap(uint map)
    {
        GameObjectSpawn[] spawns;
        foreach (ref row; gameObjectSpawnRows)
            if (row.map == map)
                spawns ~= row;
        return spawns;
    }
    void insertGameObjectSpawn(const ref GameObjectSpawn s) { gameObjectSpawnRows[s.guid] = s; }
    void deleteGameObjectSpawn(uint guid) { gameObjectSpawnRows.remove(guid); }
    void deleteInstanceBind(uint guid, uint instance)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        instanceRows.binds = instanceRows.binds.filter!(b => b.group || b.owner != guid || b.instance != instance).array;
    }
    void insertAuction(const ref AuctionRecord auction) { auctions[auction.id] = auction; }
    AuctionRecord[] loadAuctions(uint houseId)
    {
        import std.algorithm.sorting : sort;

        AuctionRecord[] found;
        foreach (ref a; auctions)
            if (houseId == 0 || a.houseId == houseId)
                found ~= a;
        found.sort!((a, b) => a.id < b.id);
        return found;
    }
    Nullable!AuctionRecord auctionById(uint id)
    {
        if (auto a = id in auctions)
            return Nullable!AuctionRecord(*a);
        return Nullable!AuctionRecord.init;
    }
    bool bidOnAuction(uint id, uint oldBidder, uint oldBid, uint bidder, uint bid)
    {
        auto a = id in auctions;
        if (a is null || a.bidder != oldBidder || a.bid != oldBid)
            return false;
        a.bidder = bidder;
        a.bid = bid;
        return true;
    }
    bool deleteAuction(uint id, uint bid)
    {
        auto a = id in auctions;
        if (a is null || a.bid != bid)
            return false;
        auctions.remove(id);
        return true;
    }
    AuctionRecord[] expiredAuctions(long now)
    {
        AuctionRecord[] found;
        foreach (ref a; auctions)
            if (a.expireTime <= now)
                found ~= a;
        return found;
    }
    uint maxAuctionId()
    {
        uint highest;
        foreach (id, _; auctions)
            if (id > highest)
                highest = id;
        return highest;
    }
    void saveGameObjectRespawn(uint spawnGuid, long respawnTime)
    {
        if (respawnTime)
            gameObjectRespawns[spawnGuid] = respawnTime;
        else
            gameObjectRespawns.remove(spawnGuid);
    }
    long[uint] loadGameObjectRespawns() { return gameObjectRespawns.dup; }

    Nullable!NameInfo nameInfo(uint guid)
    {
        if (auto c = guid in loadable)
            return nullable(NameInfo(c.name, c.race, c.gender, c.classId));
        return Nullable!NameInfo.init;
    }

    GuidCounters highestGuids()
    {
        uint highest;
        foreach (list; characterLists)
            foreach (record; list)
                if (record.guid > highest)
                    highest = record.guid;
        uint instance;
        foreach (r; instanceRows.instances)
            if (r.id > instance)
                instance = r.id;
        foreach (realm; battlegroundCheckpoints)
            foreach (map; realm)
                foreach (id, _; map)
                    if ((id & 0x7FFF_FFFF) > instance)
                        instance = id & 0x7FFF_FFFF;
        uint pet;
        foreach (id, _; petRows)
            if (id > pet)
                pet = id;
        return GuidCounters(highest + 1, 1, 1, 1, instance + 1, pet + 1);
    }

    bool nameTaken(string name)
    {
        foreach (list; characterLists)
            foreach (record; list)
                if (record.name == name)
                    return true;
        return false;
    }

    uint accountCharacterTotal(uint accountId)
    {
        return realmCounts.get(accountId, 0) + otherRealmCounts.get(accountId, 0);
    }

    uint realmCharacterCount(uint accountId)
    {
        return cast(uint) characterLists.get(accountId, null).length;
    }

    ubyte[] characterRaces(uint accountId)
    {
        import std.algorithm.iteration : map;
        import std.array : array;

        return characterLists.get(accountId, null).map!(record => record.race).array;
    }

    bool hasTutorialData(uint accountId)
    {
        return (accountId in tutorialRows) !is null;
    }

    void saveNewCharacter(const ref NewCharacter character, bool insertTutorialData)
    {
        saved[character.guid] = cast(NewCharacter) character;
        CharacterRecord record;
        record.guid = character.guid;
        record.name = character.name;
        record.race = character.race;
        record.classId = character.classId;
        record.gender = character.gender;
        record.playerBytes = character.playerBytes;
        record.playerBytes2 = character.playerBytes2;
        record.level = cast(ubyte) character.level;
        record.map = character.map;
        record.x = character.x;
        record.y = character.y;
        record.z = character.z;
        record.atLogin = character.atLogin;
        record.equipmentCache = character.equipmentCacheText;
        characterLists[character.account] ~= record;
        if (insertTutorialData)
            tutorialRows[character.account] = true;
    }

    void setRealmCharacterCount(uint accountId, uint realmId, uint count)
    {
        realmCounts[accountId] = count;
    }

    Nullable!CharacterOwner characterOwner(uint guid)
    {
        foreach (account, list; characterLists)
            foreach (record; list)
                if (record.guid == guid)
                    return nullable(CharacterOwner(account, record.name, record.level));
        if (auto c = guid in loadable)
            return nullable(CharacterOwner(c.account, c.name, cast(ubyte) c.level));
        return Nullable!CharacterOwner.init;
    }

    bool isGuildLeader(uint guid)
    {
        return (guid in guildLeaders) !is null;
    }

    void deleteCharacter(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        if (options.method != 1) // as the database does: an unpaid battleground reward goes with its character
        {
            foreach (key; battlegroundRewards.keys)
                if (key[2] == guid)
                    battlegroundRewards.remove(key);
            foreach (key; battlegroundEventRewards.keys)
                if (key[3] == guid)
                    battlegroundEventRewards.remove(key);
        }
        auto list = accountId in characterLists;
        if (list is null)
            return;
        *list = (*list).filter!(record => record.guid != guid).array;
        deleted ~= guid;
    }

    Nullable!WorldAccount findAccount(string username)
    {
        if (auto account = canonicalAccountName(username) in accounts)
            return nullable(*account);
        return Nullable!WorldAccount.init;
    }

    GmAccess[uint] gmAccessRows;

    GmAccess gmAccessFor(uint accountId) { return gmAccessRows.get(accountId, GmAccess.init); }
    bool changeGmRole(uint accountId, string role, bool grant)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : canFind;

        if (!defaultRoleGrants(role).length)
            return false;
        auto access = gmAccessFor(accountId);
        if (grant && !access.roles.canFind(role))
            access.roles ~= role;
        else if (!grant)
        {
            if (!access.roles.canFind(role))
                return false;
            access.roles = access.roles.dup.remove!(name => name == role);
        }
        access.grants = null;
        foreach (name; access.roles)
            foreach (capability; defaultRoleGrants(name))
                if (!access.grants.canFind(capability))
                    access.grants ~= capability;
        gmAccessRows[accountId] = access;
        return true;
    }

    bool isBanned(uint accountId, string ip)
    {
        return (accountId in bannedAccounts) !is null || (ip in bannedAddresses) !is null;
    }

    void recordLogon(uint accountId, string ip)
    {
        import std.conv : to;

        logons ~= accountId.to!string ~ "@" ~ ip;
    }

    CharacterRecord[] characters(uint accountId)
    {
        return characterLists.get(accountId, null);
    }
}
