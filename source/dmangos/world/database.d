/**
 * What the world server reads and writes in the CMaNGOS login (`realmd`)
 * and `characters` databases.
 *
 * `MySqlWorldDatabase` uses the same statements as CMaNGOS
 * (`Server/WorldSocket.cpp`, `Entities/CharacterHandler.cpp`).
 * `MemoryWorldDatabase` stands in for it in tests.
 */
module dmangos.world.database;

import std.typecons : Nullable, nullable;

import dmangos.crypto.srp6 : sessionKeyLength;
import dmangos.mysql : MySqlConnection;
import dmangos.auth.accounts : AccountLevel, canonicalAccountName, decodeBigNumberHex, toAccountLevel;
import dmangos.world.characterdb : CharacterOwner, CharacterStatements, DeleteOptions, GuidCounters, NameInfo;
public import dmangos.world.characterdb : GroupMemberRecord, GroupRecord;
import dmangos.world.movement : Position;
import dmangos.world.creature : CreatureSpawn;
import dmangos.world.gameobject : GameObjectSpawn;
import dmangos.world.inventory : ItemChange, ItemRecord, ItemState;
import dmangos.world.quests : QuestStatus;
import dmangos.world.reputation : ReputationRecord;
import dmangos.world.auctionhouse : AuctionRecord;
import dmangos.world.player : CharacterData, CharacterProgress, HomeBind, tutorialFields;
import dmangos.world.worlddata : AreaTriggerTeleport, areaTriggerTeleportQuery, GameTele, gameTeleQuery;
import dmangos.world.playercreate : NewCharacter;

/// The parts of an `account` row a world session needs.
struct WorldAccount
{
    uint id;
    string username;
    AccountLevel level;
    ubyte[sessionKeyLength] sessionKey;
    bool hasSessionKey;  /// False unless `sessionkey` holds a full 80-digit key.
    bool locked;
    string lockedIp;
    string os;           /// As recorded by the login server: "Win" or "OSX".
    string platform;     /// "x86" or "PPC"
    long muteTime;       /// `account.mutetime`: chat is off until this Unix time
}

/// One row of CMaNGOS's character list query, in its column order.
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
    ubyte type;         /// `CorpseType`
}

/// A `mail` row and its one item (`mail_items`; 1.12 sends at most one).
struct MailRecord
{
    uint id;
    ubyte messageType;     /// `MailMessageType`: 0 a player's
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
    uint checked;          /// `MailCheckMask`
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
    ubyte flags; /// `SocialFlag`s
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

/// What `loadInstances` reads.
struct InstanceRecords
{
    InstanceRecord[] instances;
    InstanceBindRecord[] binds;
    InstanceRespawnRecord[] respawns;
}

interface WorldDatabase
{
    /// The account named `username`, or null.
    Nullable!WorldAccount findAccount(string username);

    /// Whether the account or the address has a ban in force.
    bool isBanned(uint accountId, string ip);

    /// Logs the connection in `account_logons`, with the world server as its source.
    void recordLogon(uint accountId, string ip);

    /// The account's characters on this realm, by guid.
    CharacterRecord[] characters(uint accountId);

    // --- character creation and deletion ---

    /// Next free character, item and mail ids.
    GuidCounters highestGuids();

    /// Whether a character already has this (normalized) name.
    bool nameTaken(string name);

    /// Characters on every realm, from `realmcharacters`.
    uint accountCharacterTotal(uint accountId);

    /// Characters on this realm.
    uint realmCharacterCount(uint accountId);

    /// Races of the account's characters on this realm, in table order.
    ubyte[] characterRaces(uint accountId);

    /// Whether the account has its `character_tutorial` row.
    bool hasTutorialData(uint accountId);

    /// Stores a newly created character (and, if asked, the account's empty tutorial row).
    void saveNewCharacter(const ref NewCharacter character, bool insertTutorialData);

    /// Sets `realmcharacters.numchars` for this realm.
    void setRealmCharacterCount(uint accountId, uint realmId, uint count);

    /// The account, name and level of a character, or null.
    Nullable!CharacterOwner characterOwner(uint guid);

    /// Whether the character leads a guild.
    bool isGuildLeader(uint guid);

    /// Deletes (or unlinks) a character and everything that belongs to it.
    void deleteCharacter(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId);

    // --- entering and leaving the world ---

    /// Everything logging in reads about a character, or null if there is no such character.
    Nullable!CharacterData loadCharacter(uint guid);

    /// Stores the home a character without one gets.
    void insertHomeBind(uint guid, const HomeBind bind);

    /// `Player::SetHomebindToLocation`: the hearthstone's new place.
    void updateHomeBind(uint guid, const HomeBind bind);

    /// Marks a character (and its account, on this realm) as online or offline.
    void setOnline(uint guid, uint accountId, bool online, uint realmId);

    /// At start-up: marks every character and account of this realm as offline.
    void markAllOffline(uint realmId);

    /// Saves where a character is and what changed while it played.
    void saveProgress(const ref CharacterProgress progress);

    /// Sets (or, with action 0, clears) an action bar button.
    void setActionButton(uint guid, ubyte button, uint action, ubyte type);

    /// Saves the account's tutorial flags.
    void saveTutorials(uint accountId, const uint[tutorialFields] tutorials);

    /// `Corpse::SaveToDB`: a player's corpse (its row replaces any earlier one).
    void saveCorpse(const ref CorpseRecord corpse);

    /// `Corpse::DeleteFromDB`: the player's corpse is gone.
    void deleteCorpse(uint player);

    /// The player's corpse, if it has one.
    Nullable!CorpseRecord loadCorpse(uint player);

    /// `MapPersistentState::SaveCreatureRespawnTime`: a dead creature comes back at `respawnTime` (0: forget it).
    void saveCreatureRespawn(uint spawnGuid, long respawnTime);

    /// `Player::_SaveAuras`: the player's auras, replacing those saved before.
    void saveAuras(uint player, const(AuraRecord)[] auras);

    /// Every guild, with its ranks and members (`GuildMgr::LoadGuilds`); one guild alone.
    GuildRecord[] loadGuilds();
    /// ditto
    Nullable!GuildRecord loadGuild(uint id);
    /// A new guild's id: one above any there is.
    uint nextGuildId();
    /// A guild's own row (name, leader, emblem, texts), written whole (created if new).
    void saveGuild(const ref GuildRecord guild);
    /// Its ranks, all of them (the old rows go).
    void saveGuildRanks(uint guild, const(GuildRankRecord)[] ranks);
    /// A member's row (created if new).
    void saveGuildMember(uint guild, uint member, uint rank, string publicNote, string officerNote);
    /// A member gone.
    void deleteGuildMember(uint member);
    /// A guild gone: its rows, ranks, members and log.
    void deleteGuild(uint guild);

    /// The petition (charter) of item `petition`, with its signers; null if none.
    Nullable!PetitionRecord loadPetition(uint petition);
    /// A new charter of `owner`'s (its older ones go).
    void createPetition(uint owner, uint petition, string name);
    /// A signature; whether an account signed a petition already.
    void signPetition(uint owner, uint petition, uint player, uint account);
    /// ditto
    bool accountSignedPetition(uint account, uint petition);
    /// A charter turned in or gone.
    void deletePetition(uint petition);
    /// `RemovePetitionsAndSigns`: a character's own charters and its signatures go (it joined a guild).
    void deletePetitionsOf(uint player);

    /// `character_social`: the player's friends and ignored players.
    SocialRow[] loadSocial(uint player);
    /// ditto: one row, written (flags 0: deleted)
    void saveSocial(uint player, uint other, ubyte flags);
    /// Whether `player` ignores `other`.
    bool isIgnoring(uint player, uint other);

    /// `characters.resettalents_cost` and `resettalents_time`: what the last talent reset cost, and when.
    void saveTalentReset(uint player, uint cost, long time);
    /// ditto
    void loadTalentReset(uint player, out uint cost, out long time);

    /// `character_spell_cooldown`: the player's cooldowns still running, all of them (the old rows go).
    void saveCooldowns(uint player, const(CooldownRecord)[] cooldowns);

    /// ditto, as saved
    CooldownRecord[] loadCooldowns(uint player);

    /// `Player::_LoadAuras`
    AuraRecord[] loadAuras(uint player);

    /// `ReputationMgr::SaveToDB`: these factions' rows replaced.
    void saveReputation(uint player, const(ReputationRecord)[] rows);

    /// The player's `character_reputation` rows.
    ReputationRecord[] loadReputation(uint player);

    /// `Player::_SaveQuestStatus`: the quests that changed (a status of none, never rewarded, deletes the row).
    void saveQuestStatus(uint player, const(QuestStatus)[] quests);

    /// `MailDraft::SendMailTo`: the mail and its item row.
    void sendMail(const ref MailRecord mail);

    /// The player's mail, delivered or not, oldest first (`_LoadMail`).
    MailRecord[] loadMail(uint receiver);

    /// One mail by id, if it exists.
    Nullable!MailRecord mailById(uint id);

    /// A mail's money, cash on delivery, flags and item (`_SaveMail`'s update).
    void updateMail(const ref MailRecord mail);

    /// The mail and its item row are gone.
    void deleteMail(uint id);

    /// The mail whose time is up by `now` (Unix time), oldest first.
    MailRecord[] expiredMail(long now);

    /// An item gone with its mail (`item_instance`).
    void deleteLooseItem(uint guid);

    /// `item_text`: a body.
    void saveItemText(uint id, string text);

    /// ditto; empty if there is none.
    string itemText(uint id);

    /// An item kept outside any inventory (in the mail), as `item_instance` with its owner to be.
    void saveLooseItem(const ref ItemRecord item, uint owner);

    /// ditto, to take it back out; null if there is none.
    Nullable!ItemRecord looseItem(uint guid);

    /// A character's race and account; [0, 0] if it does not exist.
    uint[2] characterRaceAccount(uint guid);

    /// Every creature that is dead now: spawn guid -> when it comes back (Unix time).
    long[uint] loadCreatureRespawns();

    /// `AuctionEntry::SaveToDB`: a new auction.
    void insertAuction(const ref AuctionRecord auction);

    /// The auctions of house `houseId` (0: of every house).
    AuctionRecord[] loadAuctions(uint houseId);

    /// The auction `id`, if it is still there.
    Nullable!AuctionRecord auctionById(uint id);

    /// A bid: true if the auction still had the bid `oldBid` of `oldBidder` (it now has the new one).
    bool bidOnAuction(uint id, uint oldBidder, uint oldBid, uint bidder, uint bid);

    /// The auction gone (sold, cancelled, expired): true if it was still there with the bid `bid`.
    bool deleteAuction(uint id, uint bid);

    /// The auctions over by `now` (Unix time).
    AuctionRecord[] expiredAuctions(long now);

    /// The highest auction id in use.
    uint maxAuctionId();

    /// `GameObject::SaveRespawnTime`: a used-up game object comes back then (0: it is back).
    void saveGameObjectRespawn(uint spawnGuid, long respawnTime);

    /// Every game object used up now: spawn guid -> when it comes back (Unix time).
    long[uint] loadGameObjectRespawns();

    /// The dungeon instances that exist (`instance`), their binds and what is dead or used up in them.
    InstanceRecords loadInstances();

    /// An instance made (`instance`): its map, and (a raid's) when it resets (Unix time; 0: when empty).
    void saveInstance(uint id, uint map, long resetTime);

    /// An instance reset: its row, binds and respawn rows go.
    void deleteInstance(uint id);

    /// `instance.data`: its dungeon script's state.
    void saveInstanceData(uint id, string data);

    /// The map of instance `id`; uint.max if there is no such instance.
    uint instanceMapOf(uint id);

    /// A character's binds as saved (`character_instance`): map -> instance.
    uint[uint] instanceBindsOf(uint player);

    /// `character_instance` (`group` false, `owner` a character) or `group_instance` (`owner` a leader).
    void saveInstanceBind(bool group, uint owner, uint instance, bool permanent);

    /// A spawn a GM made (`creature`, in the world database).
    void insertCreatureSpawn(const ref CreatureSpawn spawn);

    /// A spawn a GM deleted.
    void deleteCreatureSpawn(uint guid);

    /// A creature's quest a GM added or removed: `creature_questrelation` (`start`) or `creature_involvedrelation`.
    void insertQuestRelation(bool start, uint entry, uint quest);
    /// ditto
    void deleteQuestRelation(bool start, uint entry, uint quest);

    /// A creature template's scale a GM fixed (`creature_template.Scale`).
    void updateCreatureScale(uint entry, float scale);

    /// A vendor's ware a GM added (`npc_vendor`: unlimited, in `slot`) or removed.
    void insertVendorItem(uint entry, uint item, uint slot);
    /// ditto
    void deleteVendorItem(uint entry, uint item);

    /// A game object spawn a GM made (`gameobject`).
    void insertGameObjectSpawn(const ref GameObjectSpawn spawn);

    /// A game object spawn a GM deleted.
    void deleteGameObjectSpawn(uint guid);

    /// A character's bind to an instance revoked (`character_instance`).
    void deleteInstanceBind(uint guid, uint instance);

    /// A creature (or game object) spawn dead (used up) in an instance until `until` (`creature_respawn`, `gameobject_respawn`).
    void saveInstanceRespawn(bool gameObject, uint spawnGuid, uint instance, long until);

    /// Name, race, gender and class of a character, or null.
    Nullable!NameInfo nameInfo(uint guid);

    /// Every group with its members (`ObjectMgr::LoadGroups`).
    GroupRecord[] loadGroups();

    /// The `groups` row of a new group (`Group::Create`).
    void createGroup(const ref GroupRecord group);

    /// The `groups` columns that change after creation.
    void updateGroup(const ref GroupRecord group);

    /// Deletes a group and its members (`Group::Disband`).
    void deleteGroup(uint groupId);

    /// `Group::_addMember`
    void addGroupMember(uint groupId, const GroupMemberRecord member);

    /// A member's assistant flag and sub-group.
    void updateGroupMember(const GroupMemberRecord member);

    /// `Group::_removeMember`
    void removeGroupMember(uint guid);

    // --- what GM commands change ---

    /// `account.mutetime`: chat is off until `until` (Unix time); 0 lifts it.
    void setMuteTime(uint accountId, long until);

    /// The guid of the character called `name`, or 0.
    uint characterGuid(string name);

    /// Gives an offline character a new name (`characters.name`).
    void renameCharacter(uint guid, string newName);

    /// Moves a character that is not online (ArcEmu's `.summon` of an offline player).
    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone);

    /// `Player::_SaveSpells` for one spell learned, or changed (a higher rank made it inactive).
    void saveSpell(uint guid, uint spell, bool active, bool disabled);

    /// `Player::_SaveSpells` for a spell forgotten: its row is deleted.
    void deleteSpell(uint guid, uint spell);

    /// `Player::_SaveSkills` for one skill; a `max` of 0 removes it.
    void saveSkill(uint guid, uint skill, uint value, uint max);

    /**
     * `Player::_SaveInventory` with the money and `playerBytes2` (the bank bag slots bought) that
     * paid for the changes, in one transaction: each item's `character_inventory` and
     * `item_instance` rows written or deleted, as `Player::SaveItemToInventory` and `Item::SaveToDB` do.
     */
    void saveInventory(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes);

    /// Ids and names in a world table whose name contains `text` (`.lookup`), at most `limit`.
    LookupResult[] lookup(LookupTable table, string text, uint limit);

    /// `game_tele`: adds a place (`.recall add`), or deletes one by name; false if there was none.
    void addTeleport(const GameTele tele);
    /// ditto
    bool deleteTeleport(string name);

    /// `areatrigger_teleport` and `game_tele`, read again (`.server reloadtable`).
    AreaTriggerTeleport[] loadAreaTriggerTeleports();
    /// ditto
    GameTele[] loadTeleports();
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

/// `account_logons.loginSource` for connections to the world server (`LOGIN_TYPE_MANGOSD`).
enum uint loginSourceMangosd = 1;

/// `WorldDatabase` on the CMaNGOS login and characters databases.
final class MySqlWorldDatabase : WorldDatabase
{
    private MySqlConnection login;
    private MySqlConnection characterDb;
    private MySqlConnection world;
    private CharacterStatements statements;

    ///
    this(MySqlConnection login, MySqlConnection characterDb, MySqlConnection world)
    in (login !is null && characterDb !is null && world !is null)
    {
        this.login = login;
        this.characterDb = characterDb;
        this.world = world;
        this.statements = new CharacterStatements(characterDb, login);
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
    void saveAuras(uint player, const(AuraRecord)[] auras) { statements.saveAuras(player, auras); }
    void saveCooldowns(uint player, const(CooldownRecord)[] cooldowns) { statements.saveCooldowns(player, cooldowns); }
    void saveTalentReset(uint player, uint cost, long time) { statements.saveTalentReset(player, cost, time); }
    SocialRow[] loadSocial(uint player) { return statements.loadSocial(player); }
    GuildRecord[] loadGuilds() { return statements.loadGuilds(); }
    Nullable!GuildRecord loadGuild(uint id) { return statements.loadGuild(id); }
    uint nextGuildId() { return statements.nextGuildId(); }
    void saveGuild(const ref GuildRecord guild) { statements.saveGuild(guild); }
    void saveGuildRanks(uint guild, const(GuildRankRecord)[] ranks) { statements.saveGuildRanks(guild, ranks); }
    void saveGuildMember(uint guild, uint member, uint rank, string publicNote, string officerNote)
    {
        statements.saveGuildMember(guild, member, rank, publicNote, officerNote);
    }
    void deleteGuildMember(uint member) { statements.deleteGuildMember(member); }
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
    AuraRecord[] loadAuras(uint player) { return statements.loadAuras(player); }
    void saveReputation(uint player, const(ReputationRecord)[] rows) { statements.saveReputation(player, rows); }
    ReputationRecord[] loadReputation(uint player) { return statements.loadReputation(player); }
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
    uint instanceMapOf(uint id) { return statements.instanceMapOf(id); }
    uint[uint] instanceBindsOf(uint player) { return statements.instanceBindsOf(player); }
    void saveInstanceBind(bool group, uint owner, uint instance, bool permanent)
    {
        statements.saveInstanceBind(group, owner, instance, permanent);
    }
    void saveInstanceRespawn(bool gameObject, uint spawnGuid, uint instance, long until)
    {
        statements.saveInstanceRespawn(gameObject, spawnGuid, instance, until);
    }
    void deleteInstanceBind(uint guid, uint instance) { statements.deleteInstanceBind(guid, instance); }
    void insertCreatureSpawn(const ref CreatureSpawn s)
    {
        world.execute!("INSERT INTO creature (guid, id, map, position_x, position_y, position_z, orientation, "
            ~ "spawntimesecsmin, spawntimesecsmax, spawndist, MovementType) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(
            s.guid, s.entry, s.map, s.x, s.y, s.z, s.orientation, s.respawnSeconds, s.respawnSecondsMax,
            s.wanderDistance, s.movementType);
    }
    void deleteCreatureSpawn(uint guid) { world.execute!"DELETE FROM creature WHERE guid = ?"(guid); }
    void insertQuestRelation(bool start, uint entry, uint quest)
    {
        if (start)
            world.execute!"INSERT INTO creature_questrelation (id, quest) VALUES (?, ?)"(entry, quest);
        else
            world.execute!"INSERT INTO creature_involvedrelation (id, quest) VALUES (?, ?)"(entry, quest);
    }
    void deleteQuestRelation(bool start, uint entry, uint quest)
    {
        if (start)
            world.execute!"DELETE FROM creature_questrelation WHERE id = ? AND quest = ?"(entry, quest);
        else
            world.execute!"DELETE FROM creature_involvedrelation WHERE id = ? AND quest = ?"(entry, quest);
    }
    void updateCreatureScale(uint entry, float scale)
    {
        world.execute!"UPDATE creature_template SET Scale = ? WHERE Entry = ?"(scale, entry);
    }
    void insertVendorItem(uint entry, uint item, uint slot)
    {
        world.execute!("INSERT INTO npc_vendor (entry, item, maxcount, incrtime, slot, condition_id) "
            ~ "VALUES (?, ?, 0, 0, ?, 0)")(entry, item, slot);
    }
    void deleteVendorItem(uint entry, uint item)
    {
        world.execute!"DELETE FROM npc_vendor WHERE entry = ? AND item = ?"(entry, item);
    }
    void insertGameObjectSpawn(const ref GameObjectSpawn s)
    {
        world.execute!("INSERT INTO gameobject (guid, id, map, position_x, position_y, position_z, orientation, "
            ~ "rotation0, rotation1, rotation2, rotation3, spawntimesecsmin, spawntimesecsmax) "
            ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(s.guid, s.entry, s.map, s.x, s.y, s.z, s.orientation,
            s.rotation[0], s.rotation[1], s.rotation[2], s.rotation[3], s.respawnSeconds, s.respawnSeconds);
    }
    void deleteGameObjectSpawn(uint guid) { world.execute!"DELETE FROM gameobject WHERE guid = ?"(guid); }
    Nullable!NameInfo nameInfo(uint guid) { return statements.nameInfo(guid); }
    GroupRecord[] loadGroups() { return statements.loadGroups(); }
    void createGroup(const ref GroupRecord group) { statements.createGroup(group); }
    void updateGroup(const ref GroupRecord group) { statements.updateGroup(group); }
    void deleteGroup(uint groupId) { statements.deleteGroup(groupId); }
    void addGroupMember(uint groupId, const GroupMemberRecord member) { statements.addGroupMember(groupId, member); }
    void updateGroupMember(const GroupMemberRecord member) { statements.updateGroupMember(member); }
    void removeGroupMember(uint guid) { statements.removeGroupMember(guid); }
    uint characterGuid(string name) { return statements.characterGuid(name); }
    void renameCharacter(uint guid, string newName) { statements.renameCharacter(guid, newName); }
    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone)
    {
        statements.moveOfflineCharacter(guid, map, x, y, z, zone);
    }
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

    /// `ObjectMgr::AddGameTele`
    void addTeleport(const GameTele t)
    {
        world.execute!("INSERT INTO game_tele (position_x, position_y, position_z, orientation, map, name) "
            ~ "VALUES (?, ?, ?, ?, ?, ?)")(t.x, t.y, t.z, t.orientation, t.map, t.name);
    }

    /// `ObjectMgr::DeleteGameTele`
    bool deleteTeleport(string name)
    {
        if (world.query!"SELECT id FROM game_tele WHERE name = ?"(name).length == 0)
            return false;
        world.execute!"DELETE FROM game_tele WHERE name = ?"(name);
        return true;
    }

    AreaTriggerTeleport[] loadAreaTriggerTeleports()
    {
        return world.queryAs!(AreaTriggerTeleport, areaTriggerTeleportQuery)();
    }

    GameTele[] loadTeleports()
    {
        return world.queryAs!(GameTele, gameTeleQuery)();
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
        uint gmlevel;
        string sessionkey;
        string lockedIp;
        uint locked;
        string os;
        string platform;
        long mutetime;
    }

    Nullable!WorldAccount findAccount(string username)
    {
        const rows = login.queryAs!(AccountRow, "SELECT a.id, a.username, a.gmlevel, a.sessionkey, a.lockedIp, "
            ~ "a.locked, a.os, a.platform, a.mutetime FROM account a WHERE username = ?")(username);
        if (rows.length == 0)
            return Nullable!WorldAccount.init;

        const row = rows[0];
        WorldAccount account;
        account.id = row.id;
        account.username = row.username;
        account.level = toAccountLevel(row.gmlevel);
        account.locked = row.locked == 1;
        account.lockedIp = row.lockedIp;
        account.os = row.os;
        account.platform = row.platform;
        account.muteTime = row.mutetime;
        // CMaNGOS accepts only a full 80-digit key: anything shorter (an empty string in
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

    /// `character_pet.slot` of the pet currently with its owner (`PET_SAVE_AS_CURRENT`).
    private enum uint petSaveAsCurrent = 0;
}

/// A `WorldDatabase` for tests.
final class MemoryWorldDatabase : WorldDatabase
{
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

    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone)
    {
        if (auto c = guid in loadable)
        {
            c.map = map;
            c.zone = zone;
            c.position = Position(x, y, z, c.position.orientation);
        }
    }

    void renameCharacter(uint guid, string newName)
    {
        foreach (ref list; characterLists)
            foreach (ref record; list)
                if (record.guid == guid)
                    record.name = newName;
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
    }

    bool deleteTeleport(string name)
    {
        import std.algorithm.mutation : remove;

        const before = teleportRows.length;
        teleportRows = teleportRows.remove!(t => t.name == name);
        return teleportRows.length < before;
    }

    AreaTriggerTeleport[] loadAreaTriggerTeleports()
    {
        return areaTriggerRows.dup;
    }

    GameTele[] loadTeleports()
    {
        return teleportRows.dup;
    }

    GroupRecord[] loadGroups()
    {
        return groups.values;
    }

    void createGroup(const ref GroupRecord group)
    {
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

    void saveCorpse(const ref CorpseRecord c) { corpses[c.player] = c; }
    void saveAuras(uint player, const(AuraRecord)[] auras) { auraRows[player] = auras.dup; }
    CooldownRecord[][uint] cooldownRows; /// by player
    long[2][uint] talentResets; /// by player: cost, time
    GuildRecord[uint] guildRows; /// by id
    GuildRecord[] loadGuilds() { return guildRows.values.dup; }
    Nullable!GuildRecord loadGuild(uint id)
    {
        if (auto g = id in guildRows)
        {
            GuildRecord copy = *g;
            copy.ranks = g.ranks.dup;
            copy.members = g.members.dup;
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
        uint id;
        foreach (k, _; guildRows)
            if (k > id)
                id = k;
        return id + 1;
    }
    void saveGuild(const ref GuildRecord guild)
    {
        auto g = &guildRows.require(guild.id, GuildRecord.init);
        auto ranks = g.ranks, members = g.members;
        *g = cast(GuildRecord) guild;
        g.ranks = ranks;
        g.members = members;
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
    AuraRecord[] loadAuras(uint player) { return auraRows.get(player, null).dup; }
    void saveReputation(uint player, const(ReputationRecord)[] rows)
    {
        foreach (ref r; rows)
            reputationRows.require(player, null)[r.faction] = r;
    }
    ReputationRecord[] loadReputation(uint player) { return reputationRows.get(player, null).values; }
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
            creatureRespawns[spawnGuid] = respawnTime;
        else
            creatureRespawns.remove(spawnGuid);
    }
    long[uint] loadCreatureRespawns() { return creatureRespawns.dup; }
    InstanceRecords instanceRows;    /// what the instance methods keep
    InstanceRecords loadInstances() { return instanceRows; }
    void saveInstance(uint id, uint map, long resetTime) { instanceRows.instances ~= InstanceRecord(id, map, resetTime); }
    void saveInstanceData(uint id, string data)
    {
        foreach (ref r; instanceRows.instances)
            if (r.id == id)
                r.data = data;
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
    }
    void saveInstanceBind(bool group, uint owner, uint instance, bool permanent)
    {
        instanceRows.binds ~= InstanceBindRecord(group, owner, instance, permanent);
    }
    void saveInstanceRespawn(bool gameObject, uint spawnGuid, uint instance, long until)
    {
        instanceRows.respawns ~= InstanceRespawnRecord(gameObject, spawnGuid, instance, until);
    }
    CreatureSpawn[uint] creatureSpawnRows;     /// what `insertCreatureSpawn` wrote, by guid
    GameObjectSpawn[uint] gameObjectSpawnRows; /// ditto, game objects
    void insertCreatureSpawn(const ref CreatureSpawn s) { creatureSpawnRows[s.guid] = s; }
    void deleteCreatureSpawn(uint guid) { creatureSpawnRows.remove(guid); }
    uint[3][] questRelationRows; /// (start, entry, quest) that `insertQuestRelation` wrote and are not deleted
    void insertQuestRelation(bool start, uint entry, uint quest) { questRelationRows ~= [start, entry, quest]; }
    void deleteQuestRelation(bool start, uint entry, uint quest)
    {
        import std.algorithm.mutation : remove;

        questRelationRows = questRelationRows.remove!(r => r == [uint(start), entry, quest]);
    }
    float[uint] creatureScales; /// what `updateCreatureScale` wrote, by entry
    void updateCreatureScale(uint entry, float scale) { creatureScales[entry] = scale; }
    uint[2][] vendorRows; /// what `insertVendorItem` wrote (entry, item), less what `deleteVendorItem` removed
    void insertVendorItem(uint entry, uint item, uint slot) { vendorRows ~= [entry, item]; }
    void deleteVendorItem(uint entry, uint item)
    {
        import std.algorithm.mutation : remove;

        vendorRows = vendorRows.remove!(r => r == [entry, item]);
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
        return GuidCounters(highest + 1, 1, 1, 1, instance + 1);
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
