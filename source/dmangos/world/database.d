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
import dmangos.world.player : CharacterData, CharacterProgress, HomeBind, tutorialFields;
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

    /// Name, race, gender and class of a character, or null.
    Nullable!NameInfo nameInfo(uint guid);
}

/// `account_logons.loginSource` for connections to the world server (`LOGIN_TYPE_MANGOSD`).
enum uint loginSourceMangosd = 1;

/// `WorldDatabase` on the CMaNGOS login and characters databases.
final class MySqlWorldDatabase : WorldDatabase
{
    private MySqlConnection login;
    private MySqlConnection characterDb;
    private CharacterStatements statements;

    ///
    this(MySqlConnection login, MySqlConnection characterDb)
    in (login !is null && characterDb !is null)
    {
        this.login = login;
        this.characterDb = characterDb;
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
    void setOnline(uint guid, uint accountId, bool online, uint realmId) { statements.setOnline(guid, accountId, online, realmId); }
    void markAllOffline(uint realmId) { statements.markAllOffline(realmId); }
    void saveProgress(const ref CharacterProgress progress) { statements.saveProgress(progress); }
    void setActionButton(uint guid, ubyte button, uint action, ubyte type) { statements.setActionButton(guid, button, action, type); }
    void saveTutorials(uint accountId, const uint[tutorialFields] tutorials) { statements.saveTutorials(accountId, tutorials); }
    Nullable!NameInfo nameInfo(uint guid) { return statements.nameInfo(guid); }

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
    }

    Nullable!WorldAccount findAccount(string username)
    {
        const rows = login.queryAs!(AccountRow, "SELECT a.id, a.username, a.gmlevel, a.sessionkey, a.lockedIp, "
            ~ "a.locked, a.os, a.platform FROM account a WHERE username = ?")(username);
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

    Nullable!CharacterData loadCharacter(uint guid)
    {
        if (auto c = guid in loadable)
            return nullable(*c);
        return Nullable!CharacterData.init;
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
        return GuidCounters(highest + 1, 1, 1);
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
        ubyte[] races;
        foreach (record; characterLists.get(accountId, null))
            races ~= record.race;
        return races;
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
        return Nullable!CharacterOwner.init;
    }

    bool isGuildLeader(uint guid)
    {
        return (guid in guildLeaders) !is null;
    }

    void deleteCharacter(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId)
    {
        auto list = accountId in characterLists;
        if (list is null)
            return;
        CharacterRecord[] kept;
        foreach (record; *list)
            if (record.guid != guid)
                kept ~= record;
        *list = kept;
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
