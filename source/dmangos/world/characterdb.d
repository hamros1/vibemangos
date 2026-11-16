/**
 * Creating and deleting characters in the CMaNGOS `characters` and
 * `realmd` databases, with CMaNGOS's statements (`Player::SaveToDB`,
 * `Player::DeleteFromDB`, `World::UpdateRealmCharCount`).
 */
module dmangos.world.characterdb;

import std.algorithm.iteration : map;
import std.algorithm.searching : find;
import std.array : array, replicate;
import std.datetime.systime : Clock;
import std.typecons : Nullable, nullable;

import dmangos.log;
import dmangos.mysql : MySqlConnection;
import dmangos.world.inventory : ItemChange, ItemRecord, ItemState;
import dmangos.world.player : CharacterData, CharacterProgress, HomeBind, tutorialFields;
import dmangos.world.playercreate : NewCharacter, NewSkill, NewSpell, maxEnchantmentSlot;
import dmangos.world.worlddata : CreateAction;

/// Who a character belongs to.
struct CharacterOwner
{
    uint account;
    string name;
    uint level;
}

/// What `SMSG_NAME_QUERY_RESPONSE` tells about a character.
struct NameInfo
{
    string name;
    ubyte race;
    ubyte gender;
    ubyte classId;
}

/// `CharDelete.Method` and `CharDelete.MinLevel`.
struct DeleteOptions
{
    uint method;      /// 0 = delete, 1 = unlink (keep the data, free the name)
    uint minLevel;    /// below this level characters are always deleted outright
    uint mailDeliveryDelay = 3600; /// `MailDeliveryDelay`, for returned mail to another account
}

/// Next free ids, taken from `MAX(id) + 1` at start-up as CMaNGOS's `SetHighestGuids` does.
struct GuidCounters
{
    uint character = 1;
    uint item = 1;
    uint mail = 1;
    uint group = 1;
}

/// A `groups` row with its `group_member` rows (`Group::LoadGroupFromDB`, `LoadMemberFromDB`).
struct GroupRecord
{
    uint id;
    uint leader;
    uint mainTank;
    uint mainAssistant;
    ubyte lootMethod;
    uint looter;
    ubyte lootThreshold;
    ulong[8] icons;
    bool isRaid;
    string leaderName;          /// null when the leader's character no longer exists
    GroupMemberRecord[] members;
}

/// A `group_member` row, with the member's name.
struct GroupMemberRecord
{
    uint guid;
    string name;                /// null when the character no longer exists
    bool assistant;
    ubyte subGroup;
}

private enum : uint
{
    mailNormal = 0,
    mailAuction = 2,
    mailStationeryDefault = 41,
    mailStationeryAuction = 62,
    mailCheckReturned = 0x02,
    mailCheckCopied = 0x04,
    auctionCancelledToBidder = 4,
    day = 24 * 60 * 60,
    gmTicketAssigned = 1,
    gmTicketNotAssigned = 0,
}

/// The character-related statements, on the characters and login connections.
final class CharacterStatements
{
    private MySqlConnection characters;
    private MySqlConnection login;

    ///
    this(MySqlConnection characters, MySqlConnection login)
    {
        this.characters = characters;
        this.login = login;
    }

    /// `ObjectMgr::SetHighestGuids`, for the ids creation and deletion allocate.
    GuidCounters highestGuids()
    {
        GuidCounters next;
        next.character = maxPlusOne!"SELECT MAX(guid) FROM characters";
        next.item = maxPlusOne!"SELECT MAX(guid) FROM item_instance";
        next.mail = maxPlusOne!"SELECT MAX(id) FROM mail";
        next.group = maxPlusOne!"SELECT MAX(groupId) FROM `groups`";
        return next;
    }

    private uint maxPlusOne(string sql)()
    {
        const rows = characters.query!sql();
        return rows.length ? rows[0].get!uint(0) + 1 : 1;
    }

    /// `ObjectMgr::GetPlayerGuidByName` found something.
    bool nameTaken(string name)
    {
        return characters.query!"SELECT guid FROM characters WHERE name = ?"(name).length > 0;
    }

    /// `SUM(numchars)` over every realm, from `realmcharacters`.
    uint accountCharacterTotal(uint accountId)
    {
        const rows = login.query!"SELECT SUM(numchars) FROM realmcharacters WHERE acctid = ?"(accountId);
        return rows.length ? rows[0].get!uint(0) : 0;
    }

    /// Characters the account has on this realm.
    uint realmCharacterCount(uint accountId)
    {
        return characters.query!"SELECT COUNT(guid) FROM characters WHERE account = ?"(accountId)[0].get!uint(0);
    }

    /// Races of the account's characters on this realm, in table order.
    ubyte[] characterRaces(uint accountId)
    {
        return characters.query!"SELECT race FROM characters WHERE account = ?"(accountId)
            .map!(row => row.get!ubyte(0)).array;
    }

    /// Whether `character_tutorial` has the account's row (`LoadTutorialsData`).
    bool hasTutorialData(uint accountId)
    {
        return characters.query!"SELECT 1 FROM character_tutorial WHERE account = ?"(accountId).length > 0;
    }

    /// `Player::SaveToDB` for a new character, in one transaction.
    void saveNew(const ref NewCharacter c, bool insertTutorialData)
    {
        const now = Clock.currTime.toUnixTime;
        characters.transaction({
            characters.execute!"DELETE FROM characters WHERE guid = ?"(c.guid);
            characters.execute!("INSERT INTO characters (guid, account, name, race, class, gender, level, xp, money, "
                ~ "playerBytes, playerBytes2, playerFlags, map, position_x, position_y, position_z, orientation, "
                ~ "taximask, online, cinematic, totaltime, leveltime, rest_bonus, logout_time, is_logout_resting, "
                ~ "resettalents_cost, resettalents_time, trans_x, trans_y, trans_z, trans_o, transguid, extra_flags, "
                ~ "stable_slots, at_login, zone, death_expire_time, taxi_path, honor_highest_rank, honor_standing, "
                ~ "stored_honor_rating, stored_dishonorable_kills, stored_honorable_kills, watchedFaction, drunk, "
                ~ "health, power1, power2, power3, power4, power5, exploredZones, equipmentCache, ammoId, actionBars, "
                ~ "fishingSteps) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 0, 0, 0, ?, 0, 0, "
                ~ "0, 0, 0, 0, 0, 0, 0, 0, ?, ?, 0, '', 0, 0, 0, 0, 0, 4294967295, "
                ~ "0, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0)")(
                c.guid, c.account, c.name, c.race, c.classId, c.gender, c.level, c.money, c.playerBytes,
                c.playerBytes2, c.playerFlags, c.map, c.x, c.y, c.z, c.orientation, c.taxiMaskText, c.cinematic, now,
                c.atLogin, c.zone, c.health, c.power[0], c.power[1], c.power[2], c.power[3], c.power[4],
                NewCharacter.exploredZonesText, c.equipmentCacheText, c.ammoId);

            foreach (ref item; c.items)
            {
                characters.execute!("INSERT INTO character_inventory (guid, bag, slot, item, item_template) "
                    ~ "VALUES (?, ?, ?, ?, ?)")(c.guid, item.containerGuid, item.slot, item.guid, item.entry);
                characters.execute!("REPLACE INTO item_instance (owner_guid, itemEntry, creatorGuid, giftCreatorGuid, "
                    ~ "count, duration, charges, flags, enchantments, randomPropertyId, durability, itemTextId, guid) "
                    ~ "VALUES (?, ?, 0, 0, ?, ?, ?, ?, ?, 0, ?, 0, ?)")(c.guid, item.entry, item.count,
                    item.duration, chargesText(item.charges), item.flags, emptyEnchantments, item.durability,
                    item.guid);
            }
            foreach (ref spell; c.spells)
                characters.execute!"INSERT INTO character_spell (guid, spell, active, disabled) VALUES (?, ?, ?, ?)"(
                    c.guid, spell.spell, spell.active ? 1 : 0, spell.disabled ? 1 : 0);
            foreach (ref action; c.actions)
                characters.execute!"INSERT INTO character_action (guid, button, action, type) VALUES (?, ?, ?, ?)"(
                    c.guid, action.button, action.action, action.type);
            foreach (ref skill; c.skills)
                characters.execute!"INSERT INTO character_skills (guid, skill, value, max) VALUES (?, ?, ?, ?)"(
                    c.guid, skill.skill, skill.value, skill.max);
            if (insertTutorialData)
                characters.execute!("INSERT INTO character_tutorial (account, tut0, tut1, tut2, tut3, tut4, tut5, "
                    ~ "tut6, tut7) VALUES (?, 0, 0, 0, 0, 0, 0, 0, 0)")(c.account);
        });
    }

    // -----------------------------------------------------------------------
    // Entering and leaving the world
    // -----------------------------------------------------------------------

    /// `Player::LoadFromDB` with the queries of `LoginQueryHolder`. Null if there is no such character.
    Nullable!CharacterData loadCharacter(uint guid)
    {
        const rows = characters.query!("SELECT guid, account, name, race, class, gender, level, xp, money, "
            ~ "playerBytes, playerBytes2, playerFlags, position_x, position_y, position_z, orientation, map, zone, "
            ~ "cinematic, totaltime, leveltime, at_login, watchedFaction, health, power1, power2, power3, power4, "
            ~ "power5, exploredZones, ammoId, actionBars, rest_bonus, logout_time, is_logout_resting "
            ~ "FROM characters WHERE guid = ?")(guid);
        if (rows.length == 0)
            return Nullable!CharacterData.init;

        const r = rows[0];
        CharacterData c;
        c.guid = r.get!uint(0);
        c.account = r.get!uint(1);
        c.name = r.get!string(2);
        c.race = r.get!ubyte(3);
        c.classId = r.get!ubyte(4);
        c.gender = r.get!ubyte(5);
        c.level = r.get!uint(6);
        c.xp = r.get!uint(7);
        c.money = r.get!uint(8);
        c.playerBytes = r.get!uint(9);
        c.playerBytes2 = r.get!uint(10);
        c.playerFlags = r.get!uint(11);
        c.position.x = r.get!float(12);
        c.position.y = r.get!float(13);
        c.position.z = r.get!float(14);
        c.position.orientation = r.get!float(15);
        c.map = r.get!uint(16);
        c.zone = r.get!uint(17);
        c.cinematic = r.get!uint(18);
        c.totalTime = r.get!uint(19);
        c.levelTime = r.get!uint(20);
        c.atLogin = r.get!uint(21);
        c.watchedFaction = r.get!uint(22);
        c.health = r.get!uint(23);
        foreach (i; 0 .. 5)
            c.power[i] = r.get!uint(24 + i);
        c.exploredZones = r.get!string(29);
        c.ammoId = r.get!uint(30);
        c.actionBars = r.get!ubyte(31);
        c.restBonus = r.get!float(32);
        c.logoutTime = r.get!long(33);
        c.logoutResting = r.get!int(34) != 0;

        // _LoadInventory orders by bag, so bags come before what is in them.
        c.items = characters.queryAs!(ItemRecord, "SELECT ci.bag, ci.slot, ci.item, ii.itemEntry, ii.creatorGuid, "
            ~ "ii.giftCreatorGuid, ii.count, ii.duration, ii.charges, ii.flags, ii.enchantments, "
            ~ "ii.randomPropertyId, ii.durability, ii.itemTextId FROM character_inventory ci "
            ~ "JOIN item_instance ii ON ii.guid = ci.item WHERE ci.guid = ? ORDER BY ci.bag, ci.slot")(guid);
        c.skills = characters.queryAs!(NewSkill, "SELECT skill, value, max FROM character_skills WHERE guid = ?")(guid);
        foreach (row; characters.query!"SELECT spell, active, disabled FROM character_spell WHERE guid = ?"(guid))
            c.spells ~= NewSpell(row.get!uint(0), row.get!bool(1), row.get!bool(2));
        c.actions = characters.queryAs!(CreateAction,
            "SELECT button, action, type FROM character_action WHERE guid = ? ORDER BY button")(guid);
        // Only whether a quest was handed in is used so far (area trigger requirements).
        foreach (row; characters.query!"SELECT quest FROM character_queststatus WHERE guid = ? AND rewarded = 1"(guid))
            c.rewardedQuests[row.get!uint(0)] = true;
        const bind = characters.queryAs!(HomeBind,
            "SELECT map, zone, position_x, position_y, position_z FROM character_homebind WHERE guid = ?")(guid);
        if (bind.length)
        {
            c.hasHomeBind = true;
            c.homeBind = bind[0];
        }
        const tutorials = characters.query!("SELECT tut0, tut1, tut2, tut3, tut4, tut5, tut6, tut7 "
            ~ "FROM character_tutorial WHERE account = ?")(c.account);
        if (tutorials.length)
            foreach (i; 0 .. tutorialFields)
                c.tutorials[i] = tutorials[0].get!uint(i);
        return nullable(c);
    }

    /// `_LoadHomeBind` for a character without one: binds it where it was created.
    /// `Player::SetHomebindToLocation`
    void updateHomeBind(uint guid, const HomeBind bind)
    {
        characters.execute!("UPDATE character_homebind SET map = ?, zone = ?, position_x = ?, position_y = ?, "
            ~ "position_z = ? WHERE guid = ?")(bind.map, bind.zone, bind.x, bind.y, bind.z, guid);
    }

    void insertHomeBind(uint guid, const HomeBind bind)
    {
        characters.execute!("INSERT INTO character_homebind (guid, map, zone, position_x, position_y, position_z) "
            ~ "VALUES (?, ?, ?, ?, ?, ?)")(guid, bind.map, bind.zone, bind.x, bind.y, bind.z);
    }

    /// `characters.online`, and `account.active_realm_id` on the login database.
    void setOnline(uint guid, uint accountId, bool online, uint realmId)
    {
        characters.execute!"UPDATE characters SET online = ? WHERE guid = ?"(online ? 1 : 0, guid);
        login.execute!"UPDATE account SET active_realm_id = ? WHERE id = ?"(online ? realmId : 0, accountId);
    }

    /// At start-up: nobody is online on this realm (`clearOnlineAccounts`).
    void markAllOffline(uint realmId)
    {
        characters.execute!"UPDATE characters SET online = 0 WHERE online <> 0"();
        login.execute!"UPDATE account SET active_realm_id = 0 WHERE active_realm_id = ?"(realmId);
    }

    /// The part of `Player::SaveToDB` that changes in the world so far.
    void saveProgress(const ref CharacterProgress p)
    {
        const now = Clock.currTime.toUnixTime;
        characters.execute!("UPDATE characters SET position_x = ?, position_y = ?, position_z = ?, orientation = ?, "
            ~ "map = ?, zone = ?, totaltime = ?, leveltime = ?, logout_time = ?, health = ?, power1 = ?, "
            ~ "power2 = ?, power3 = ?, power4 = ?, power5 = ?, actionBars = ?, cinematic = ?, at_login = ?, "
            ~ "level = ?, xp = ?, money = ?, exploredZones = ?, equipmentCache = ?, ammoId = ?, rest_bonus = ?, "
            ~ "is_logout_resting = ? WHERE guid = ?")(
            p.position.x, p.position.y, p.position.z, p.position.orientation, p.map, p.zone, p.totalTime, p.levelTime,
            now, p.health, p.power[0], p.power[1], p.power[2], p.power[3], p.power[4], p.actionBars, p.cinematic,
            p.atLogin, p.level, p.xp, p.money, p.exploredZones, p.equipmentCache, p.ammoId, p.restBonus,
            p.resting ? 1 : 0, p.guid);
    }

    /// `ObjectMgr::GetPlayerGuidByName`: the guid of the character called `name`, or 0.
    uint characterGuid(string name)
    {
        const rows = characters.query!"SELECT guid FROM characters WHERE name = ?"(name);
        return rows.length ? rows[0].get!uint(0) : 0;
    }

    /// `.character rename` for an offline character.
    void renameCharacter(uint guid, string newName)
    {
        characters.execute!"UPDATE characters SET name = ? WHERE guid = ?"(newName, guid);
    }

    /// See `WorldDatabase.moveOfflineCharacter`.
    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone)
    {
        characters.execute!("UPDATE characters SET map = ?, position_x = ?, position_y = ?, position_z = ?, zone = ? "
            ~ "WHERE guid = ?")(map, x, y, z, zone, guid);
    }

    /// `Player::_SaveSpells` for one spell.
    void saveSpell(uint guid, uint spell, bool active, bool disabled)
    {
        deleteSpell(guid, spell);
        characters.execute!"INSERT INTO character_spell (guid, spell, active, disabled) VALUES (?, ?, ?, ?)"(
            guid, spell, active, disabled);
    }

    /// `Player::_SaveSpells` for a removed spell.
    void deleteSpell(uint guid, uint spell)
    {
        characters.execute!"DELETE FROM character_spell WHERE guid = ? AND spell = ?"(guid, spell);
    }

    /// `Player::_SaveSkills` for one skill; a `max` of 0 deletes it.
    void saveSkill(uint guid, uint skill, uint value, uint max)
    {
        characters.execute!"DELETE FROM character_skills WHERE guid = ? AND skill = ?"(guid, skill);
        if (max)
            characters.execute!"INSERT INTO character_skills (guid, skill, value, max) VALUES (?, ?, ?, ?)"(guid,
                skill, value, max);
    }

    /// See `CharacterDatabase.saveInventory`.
    void saveInventory(uint owner, uint money, uint playerBytes2, const(ItemChange)[] changes)
    {
        characters.transaction({
            foreach (change; changes)
            {
                const i = change.record;
                final switch (change.state)
                {
                case ItemState.new_:
                    characters.execute!("INSERT INTO character_inventory (guid, bag, slot, item, item_template) "
                        ~ "VALUES (?, ?, ?, ?, ?)")(owner, i.bag, i.slot, i.guid, i.entry);
                    characters.execute!("REPLACE INTO item_instance (owner_guid, itemEntry, creatorGuid, "
                        ~ "giftCreatorGuid, count, duration, charges, flags, enchantments, randomPropertyId, durability, "
                        ~ "itemTextId, guid) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(owner, i.entry, i.creator,
                        i.giftCreator, i.count, i.duration, i.charges, i.flags, i.enchantments, i.randomPropertyId,
                        i.durability, i.textId, i.guid);
                    break;
                case ItemState.changed:
                    characters.execute!("UPDATE character_inventory SET guid = ?, bag = ?, slot = ?, item_template = ? "
                        ~ "WHERE item = ?")(owner, i.bag, i.slot, i.entry, i.guid);
                    characters.execute!("UPDATE item_instance SET owner_guid = ?, itemEntry = ?, creatorGuid = ?, "
                        ~ "giftCreatorGuid = ?, count = ?, duration = ?, charges = ?, flags = ?, enchantments = ?, "
                        ~ "randomPropertyId = ?, durability = ?, itemTextId = ? WHERE guid = ?")(owner, i.entry,
                        i.creator, i.giftCreator, i.count, i.duration, i.charges, i.flags, i.enchantments,
                        i.randomPropertyId, i.durability, i.textId, i.guid);
                    break;
                case ItemState.removed:
                    characters.execute!"DELETE FROM character_inventory WHERE item = ?"(i.guid);
                    characters.execute!"DELETE FROM item_instance WHERE guid = ?"(i.guid);
                    break;
                case ItemState.unchanged:
                    break;
                }
            }
            characters.execute!"UPDATE characters SET money = ?, playerBytes2 = ? WHERE guid = ?"(money,
                playerBytes2, owner);
        });
    }

    /// `Player::_SaveActions` for one button. An action of 0 removes the button.
    void setActionButton(uint guid, ubyte button, uint action, ubyte type)
    {
        characters.execute!"DELETE FROM character_action WHERE guid = ? AND button = ?"(guid, button);
        if (action != 0)
            characters.execute!"INSERT INTO character_action (guid, button, action, type) VALUES (?, ?, ?, ?)"(
                guid, button, action, type);
    }

    /// `WorldSession::SaveTutorialsData`
    void saveTutorials(uint accountId, const uint[tutorialFields] t)
    {
        characters.execute!("UPDATE character_tutorial SET tut0 = ?, tut1 = ?, tut2 = ?, tut3 = ?, tut4 = ?, "
            ~ "tut5 = ?, tut6 = ?, tut7 = ? WHERE account = ?")(t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7],
            accountId);
    }

    /// `ObjectMgr::LoadGroups`: every group with its members, and the names of both.
    GroupRecord[] loadGroups()
    {
        GroupRecord[] groups;
        size_t[uint] position;
        foreach (row; characters.query!("SELECT g.groupId, g.leaderGuid, g.mainTank, g.mainAssistant, g.lootMethod, "
            ~ "g.looterGuid, g.lootThreshold, g.icon1, g.icon2, g.icon3, g.icon4, g.icon5, g.icon6, g.icon7, g.icon8, "
            ~ "g.isRaid, c.name FROM `groups` g LEFT JOIN characters c ON c.guid = g.leaderGuid ORDER BY g.groupId")())
        {
            GroupRecord g;
            g.id = row.get!uint(0);
            g.leader = row.get!uint(1);
            g.mainTank = row.get!uint(2);
            g.mainAssistant = row.get!uint(3);
            g.lootMethod = cast(ubyte) row.get!uint(4);
            g.looter = row.get!uint(5);
            g.lootThreshold = cast(ubyte) row.get!uint(6);
            foreach (i; 0 .. 8)
                g.icons[i] = row.get!ulong(7 + i);
            g.isRaid = row.get!uint(15) != 0;
            g.leaderName = row.isNull(16) ? null : row.get!string(16);
            position[g.id] = groups.length;
            groups ~= g;
        }
        foreach (row; characters.query!("SELECT m.groupId, m.memberGuid, m.assistant, m.subgroup, c.name "
            ~ "FROM group_member m LEFT JOIN characters c ON c.guid = m.memberGuid ORDER BY m.groupId")())
        {
            const member = GroupMemberRecord(row.get!uint(1), row.isNull(4) ? null : row.get!string(4),
                row.get!uint(2) != 0, cast(ubyte) row.get!uint(3));
            if (auto at = row.get!uint(0) in position)
                groups[*at].members ~= member;
            else
                groups ~= GroupRecord(row.get!uint(0), 0, 0, 0, 0, 0, 0, (ulong[8]).init, false, null, [member]);
        }
        return groups;
    }

    /// `Group::Create`
    void createGroup(const ref GroupRecord g)
    {
        characters.transaction({
            characters.execute!"DELETE FROM `groups` WHERE groupId = ?"(g.id);
            characters.execute!"DELETE FROM group_member WHERE groupId = ?"(g.id);
            characters.execute!("INSERT INTO `groups` (groupId, leaderGuid, mainTank, mainAssistant, lootMethod, "
                ~ "looterGuid, lootThreshold, icon1, icon2, icon3, icon4, icon5, icon6, icon7, icon8, isRaid) "
                ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(g.id, g.leader, g.mainTank,
                g.mainAssistant, g.lootMethod, g.looter, g.lootThreshold, g.icons[0], g.icons[1], g.icons[2],
                g.icons[3], g.icons[4], g.icons[5], g.icons[6], g.icons[7], g.isRaid ? 1 : 0);
        });
    }

    /// The `groups` columns that change after creation (`_setLeader`, `ConvertToRaid`, `SetLootMethod`, ...).
    void updateGroup(const ref GroupRecord g)
    {
        characters.execute!("UPDATE `groups` SET leaderGuid = ?, mainTank = ?, mainAssistant = ?, lootMethod = ?, "
            ~ "looterGuid = ?, lootThreshold = ?, isRaid = ? WHERE groupId = ?")(g.leader, g.mainTank, g.mainAssistant,
            g.lootMethod, g.looter, g.lootThreshold, g.isRaid ? 1 : 0, g.id);
    }

    /// `Group::Disband`
    void deleteGroup(uint groupId)
    {
        characters.transaction({
            characters.execute!"DELETE FROM `groups` WHERE groupId = ?"(groupId);
            characters.execute!"DELETE FROM group_member WHERE groupId = ?"(groupId);
        });
    }

    /// `Group::_addMember`
    void addGroupMember(uint groupId, const GroupMemberRecord m)
    {
        characters.execute!"INSERT INTO group_member (groupId, memberGuid, assistant, subgroup) VALUES (?, ?, ?, ?)"(
            groupId, m.guid, m.assistant ? 1 : 0, m.subGroup);
    }

    /// `Group::_setAssistantFlag`, `_setMembersGroup`
    void updateGroupMember(const GroupMemberRecord m)
    {
        characters.execute!"UPDATE group_member SET assistant = ?, subgroup = ? WHERE memberGuid = ?"(
            m.assistant ? 1 : 0, m.subGroup, m.guid);
    }

    /// `Group::_removeMember`
    void removeGroupMember(uint guid)
    {
        characters.execute!"DELETE FROM group_member WHERE memberGuid = ?"(guid);
    }

    /// `SendNameQueryResponseFromDB`
    Nullable!NameInfo nameInfo(uint guid)
    {
        auto rows = characters.queryAs!(NameInfo, "SELECT name, race, gender, class FROM characters WHERE guid = ?")(
            guid);
        return rows.length ? nullable(rows[0]) : Nullable!NameInfo.init;
    }

    /// `World::UpdateRealmCharCount`
    void updateRealmCharacters(uint accountId, uint realmId)
    {
        const count = realmCharacterCount(accountId);
        login.transaction({
            login.execute!"DELETE FROM realmcharacters WHERE acctid = ? AND realmid = ?"(accountId, realmId);
            login.execute!"INSERT INTO realmcharacters (numchars, acctid, realmid) VALUES (?, ?, ?)"(count, accountId,
                realmId);
        });
    }

    /// The account, name and level of a character, or null.
    Nullable!CharacterOwner owner(uint guid)
    {
        const rows = characters.query!"SELECT account, name, level FROM characters WHERE guid = ?"(guid);
        if (rows.length == 0)
            return Nullable!CharacterOwner.init;
        return nullable(CharacterOwner(rows[0].get!uint(0), rows[0].get!string(1), rows[0].get!uint(2)));
    }

    /// `GuildMgr::GetGuildByLeader`
    bool isGuildLeader(uint guid)
    {
        return characters.query!"SELECT 1 FROM guild WHERE leaderguid = ?"(guid).length > 0;
    }

    /// `Player::DeleteFromDB`. `nextMailId` allocates ids for returned mail.
    void deleteCharacter(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId)
    {
        uint method = options.method;
        const level = characters.query!"SELECT level FROM characters WHERE guid = ?"(guid);
        if (level.length == 0 || level[0].get!uint(0) < options.minLevel)
            method = 0;

        leaveGuild(guid);
        leaveGroup(guid);
        removePetitions(guid);
        if (method == 0)
            removeAuctions(guid, nextMailId);

        if (method == 1)
        {
            characters.execute!("UPDATE characters SET deleteInfos_Name = name, deleteInfos_Account = account, "
                ~ "deleteDate = ?, name = '', account = 0 WHERE guid = ?")(Clock.currTime.toUnixTime, guid);
            return;
        }

        returnMail(guid, accountId, options, nextMailId);
        const pets = characters.query!"SELECT id FROM character_pet WHERE owner = ?"(guid)
            .map!(row => row.get!uint(0)).array;

        characters.transaction({
            foreach (pet; pets)
            {
                characters.execute!"DELETE FROM character_pet WHERE id = ?"(pet);
                characters.execute!"DELETE FROM pet_aura WHERE guid = ?"(pet);
                characters.execute!"DELETE FROM pet_spell WHERE guid = ?"(pet);
                characters.execute!"DELETE FROM pet_spell_cooldown WHERE guid = ?"(pet);
            }
            static foreach (statement; [
                "DELETE FROM characters WHERE guid = ?",
                "DELETE FROM character_action WHERE guid = ?",
                "DELETE FROM character_aura WHERE guid = ?",
                "DELETE FROM character_battleground_data WHERE guid = ?",
                "DELETE FROM character_gifts WHERE guid = ? AND item_guid IN "
                    ~ "(SELECT guid FROM item_instance WHERE owner_guid = ?)",
                "UPDATE character_gifts SET guid = 0 WHERE guid = ?",
                "DELETE FROM character_homebind WHERE guid = ?",
                "DELETE FROM character_instance WHERE guid = ?",
                "DELETE FROM group_instance WHERE leaderGuid = ?",
                "DELETE FROM character_inventory WHERE guid = ?",
                "DELETE FROM character_queststatus WHERE guid = ?",
                "DELETE FROM character_reputation WHERE guid = ?",
                "DELETE FROM character_skills WHERE guid = ?",
                "DELETE FROM character_spell WHERE guid = ?",
                "DELETE FROM character_spell_cooldown WHERE guid = ?",
                "DELETE FROM item_instance WHERE owner_guid = ?",
                "DELETE FROM character_social WHERE guid = ? OR friend = ?",
                "DELETE FROM mail WHERE receiver = ?",
                "DELETE FROM mail_items WHERE receiver = ?",
                "DELETE FROM character_pet WHERE owner = ?",
                "DELETE FROM guild_eventlog WHERE PlayerGuid1 = ? OR PlayerGuid2 = ?",
                "DELETE FROM character_account_data WHERE guid = ?",
                "DELETE FROM character_stats WHERE guid = ?",
                "DELETE FROM character_queststatus_weekly WHERE guid = ?",
                "DELETE FROM character_honor_cp WHERE guid = ?",
                "DELETE FROM character_forgotten_skills WHERE guid = ?",
                "DELETE FROM item_loot WHERE owner_guid = ?",
                "DELETE FROM pvpstats_players WHERE character_guid = ?",
                "DELETE FROM character_aura WHERE caster_guid = ?",
                "DELETE FROM pet_aura WHERE caster_guid = ?",
                "UPDATE item_instance SET creatorGuid = 0 WHERE creatorGuid = ?",
                "DELETE FROM gm_tickets WHERE author_guid = ?",
            ])
                executeWithGuid!statement(guid);
            characters.execute!("UPDATE gm_tickets SET assignee_guid = 0, assignee_name = '', status = CASE WHEN "
                ~ "status = ? THEN ? ELSE status END WHERE assignee_guid = ?")(gmTicketAssigned, gmTicketNotAssigned,
                guid);
        });
    }

    /// Runs a statement whose every placeholder is the character's guid.
    private void executeWithGuid(string statement)(uint guid)
    {
        import std.algorithm.searching : count;

        enum placeholders = statement.count('?');
        static if (placeholders == 1)
            characters.execute!statement(guid);
        else
            characters.execute!statement(guid, guid);
    }

    /// `Guild::DelMember`, disbanding the guild if it is left empty.
    private void leaveGuild(uint guid)
    {
        const rows = characters.query!"SELECT guildid FROM guild_member WHERE guid = ?"(guid);
        if (rows.length == 0)
            return;
        const guildId = rows[0].get!uint(0);
        characters.execute!"DELETE FROM guild_member WHERE guid = ?"(guid);
        if (characters.query!"SELECT 1 FROM guild_member WHERE guildid = ? LIMIT 1"(guildId).length == 0)
        {
            characters.transaction({
                characters.execute!"DELETE FROM guild WHERE guildid = ?"(guildId);
                characters.execute!"DELETE FROM guild_rank WHERE guildid = ?"(guildId);
                characters.execute!"DELETE FROM guild_eventlog WHERE guildid = ?"(guildId);
            });
            info!"guild %s disbanded: its last member was deleted"(guildId);
        }
    }

    /// `Group::RemoveMember` for an offline member: leave, pass on the lead, or disband a two-person group.
    private void leaveGroup(uint guid)
    {
        const rows = characters.query!"SELECT groupId FROM group_member WHERE memberGuid = ?"(guid);
        if (rows.length == 0)
            return;
        const groupId = rows[0].get!uint(0);
        const members = characters.query!"SELECT memberGuid FROM group_member WHERE groupId = ?"(groupId)
            .map!(row => row.get!uint(0)).array;

        if (members.length <= 2)
        {
            characters.transaction({
                characters.execute!"DELETE FROM `groups` WHERE groupId = ?"(groupId);
                characters.execute!"DELETE FROM group_member WHERE groupId = ?"(groupId);
            });
            return;
        }

        characters.execute!"DELETE FROM group_member WHERE memberGuid = ?"(guid);
        const leader = characters.query!"SELECT leaderGuid FROM `groups` WHERE groupId = ?"(groupId);
        if (leader.length == 0 || leader[0].get!uint(0) != guid)
            return;

        // _chooseLeader: no member is online, so the first remaining one leads.
        const next = members.find!(member => member != guid)[0];
        characters.transaction({
            characters.execute!("DELETE FROM group_instance WHERE leaderGuid = ? AND (permanent = 1 OR instance IN "
                ~ "(SELECT instance FROM character_instance WHERE guid = ?))")(guid, next);
            characters.execute!"UPDATE group_instance SET leaderGuid = ? WHERE leaderGuid = ?"(next, guid);
            characters.execute!("INSERT INTO group_instance SELECT guid, instance, permanent FROM character_instance "
                ~ "WHERE guid = ?")(next);
            characters.execute!"DELETE FROM character_instance WHERE guid = ? AND permanent = 0"(next);
            characters.execute!"UPDATE `groups` SET leaderGuid = ? WHERE groupId = ?"(next, groupId);
        });
    }

    /// `Player::RemovePetitionsAndSigns`
    private void removePetitions(uint guid)
    {
        characters.execute!"DELETE FROM petition_sign WHERE playerguid = ?"(guid);
        characters.transaction({
            characters.execute!"DELETE FROM petition WHERE ownerguid = ?"(guid);
            characters.execute!"DELETE FROM petition_sign WHERE ownerguid = ?"(guid);
        });
    }

    /// `AuctionHouseMgr::RemovePlayerAuctions`: own auctions are cancelled (bids refunded by mail), own bids dropped.
    private void removeAuctions(uint guid, uint delegate() nextMailId)
    {
        characters.execute!"UPDATE auction SET buyguid = 0, lastbid = 0 WHERE buyguid = ? AND itemowner <> ?"(guid,
            guid);
        foreach (row; characters.query!("SELECT id, houseid, itemguid, item_template, item_randompropertyid, buyguid, "
            ~ "lastbid FROM auction WHERE itemowner = ?")(guid))
        {
            const auctionId = row.get!uint(0), house = row.get!uint(1), itemGuid = row.get!uint(2);
            const bidder = row.get!uint(5), bid = row.get!uint(6);
            if (bidder && characters.query!"SELECT 1 FROM characters WHERE guid = ?"(bidder).length)
            {
                import std.conv : to;

                const subject = row.get!uint(3).to!string ~ ":" ~ row.get!int(4).to!string ~ ":"
                    ~ auctionCancelledToBidder.to!string;
                sendMail(nextMailId(), mailAuction, mailStationeryAuction, 0, house, bidder, subject, 0, null, bid,
                    mailCheckCopied, 0);
            }
            characters.execute!"DELETE FROM item_instance WHERE guid = ?"(itemGuid);
            characters.execute!"DELETE FROM auction WHERE id = ?"(auctionId);
        }
    }

    /// Mail with items still unpaid (COD) goes back to its senders, as `MailDraft::SendReturnToSender` does.
    private void returnMail(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId)
    {
        foreach (mail; characters.query!("SELECT id, messageType, mailTemplateId, sender, subject, itemTextId, money, "
            ~ "has_items FROM mail WHERE receiver = ? AND has_items <> 0 AND cod <> 0")(guid))
        {
            const mailId = mail.get!uint(0), type = mail.get!uint(1), sender = mail.get!uint(3);
            const hasItems = mail.get!uint(7) != 0;
            characters.execute!"DELETE FROM mail WHERE id = ?"(mailId);
            if (type != mailNormal)
            {
                if (hasItems)
                    characters.execute!"DELETE FROM mail_items WHERE mail_id = ?"(mailId);
                continue;
            }

            uint[2][] items; // guid, template
            if (hasItems)
                foreach (row; characters.query!("SELECT item_guid, item_template FROM mail_items WHERE mail_id = ?")(
                    mailId))
                    items ~= [row.get!uint(0), row.get!uint(1)];
            characters.execute!"DELETE FROM mail_items WHERE mail_id = ?"(mailId);

            const senderAccount = characters.query!"SELECT account FROM characters WHERE guid = ?"(sender);
            if (senderAccount.length == 0)
            {
                foreach (item; items) // the sender is gone too: the items are destroyed
                    characters.execute!"DELETE FROM item_instance WHERE guid = ?"(item[0]);
                continue;
            }
            foreach (item; items)
                characters.execute!"UPDATE item_instance SET owner_guid = ? WHERE guid = ?"(sender, item[0]);
            const delay = senderAccount[0].get!uint(0) != accountId ? options.mailDeliveryDelay : 0;
            sendMail(nextMailId(), mailNormal, mailStationeryDefault, mail.get!uint(2), guid, sender,
                mail.get!string(4), mail.get!uint(5), items, mail.get!uint(6), mailCheckReturned, delay);
        }
    }

    /// `MailDraft::SendMailTo`
    private void sendMail(uint mailId, uint type, uint stationery, uint templateId, uint sender, uint receiver,
        string subject, uint itemTextId, const(uint[2])[] items, uint money, uint checked, uint deliverDelay)
    {
        const deliver = Clock.currTime.toUnixTime + deliverDelay;
        const expire = deliver + (type == mailAuction && items.length == 0 && money == 0 ? 60 * 60 : 30 * day);
        characters.transaction({
            characters.execute!("INSERT INTO mail (id, messageType, stationery, mailTemplateId, sender, receiver, "
                ~ "subject, itemTextId, has_items, expire_time, deliver_time, money, cod, checked) "
                ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)")(mailId, type, stationery, templateId, sender,
                receiver, subject, itemTextId, items.length ? 1 : 0, expire, deliver, money, checked);
            foreach (item; items)
                characters.execute!("INSERT INTO mail_items (mail_id, item_guid, item_template, receiver) "
                    ~ "VALUES (?, ?, ?, ?)")(mailId, item[0], item[1], receiver);
        });
    }

    private static string chargesText(const int[5] charges)
    {
        import std.conv : to;

        string text;
        foreach (c; charges)
            text ~= c.to!string ~ " ";
        return text;
    }

    /// `enchantments` of a new item: id, duration and charges for every slot, all zero.
    private static immutable string emptyEnchantments = "0 ".replicate(maxEnchantmentSlot * 3);
}
