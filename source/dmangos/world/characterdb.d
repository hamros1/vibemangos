/**
 * The characters database (and the realm's character counts in the login database): creating,
 * loading, saving and deleting characters, with their items, spells, skills, groups, mail,
 * auctions, honor and instances. The tables and columns are the CMaNGOS-classic `characters` and
 * `realmd` schemas, which this server reads and writes unchanged.
 */
module dmangos.world.characterdb;

import dmangos.cluster.protocol : ScriptQuestCredit;
import dmangos.world.honorweek : HonorWeekEntry;
import dmangos.cluster.services : ServiceKind;
import std.algorithm.comparison : max;
import std.algorithm.iteration : map;
import std.algorithm.searching : find;
import std.array : array, replicate;
import std.datetime.systime : Clock;
import std.typecons : Nullable, nullable;

import dmangos.log;
import dmangos.mysql : Column, DatabaseException, MySqlConnection;
import dmangos.world.inventory : ItemChange, ItemRecord, ItemState;
import dmangos.world.player : CharacterData, CharacterProgress, HomeBind, tutorialFields;
import dmangos.world.playercreate : NewCharacter, NewSkill, NewSpell, maxEnchantmentSlot;
import dmangos.world.database : AuraRecord, TicketRecord, BattlegroundData, PvpStatsBattleground, PvpStatsPlayer, HonorColumns, HonorPointRecord, HonorRecord, CooldownRecord, PetRecord, PetSpellRecord, GuildEventRecord, GuildMemberRecord, GuildRankRecord, GuildRecord,
    PetitionRecord, SocialRow, CorpseRecord, InstanceBindRecord, InstanceRecord, InstanceRecords,
    InstanceRespawnRecord, MailRecord, ServiceCheckpoint, GroupLootRotation, LootCoinCredit, LootCoinRedemption,
    LootAwardKey, LootAwardResult, lootAwardClaimed, lootAwardClaimSeconds, BattlegroundCheckpoint, BattlegroundReward, BattlegroundPayment, BattlegroundEventReward,
    OutdoorSummonKind, OutdoorSummonRequest, OutdoorWorldState, QuestActorCheckpoint;
import dmangos.world.reputation : ReputationRecord;
import dmangos.world.auctionhouse : AuctionRecord;
import dmangos.world.quests : QuestState, QuestStatus;
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

/// Next free ids, taken from `MAX(id) + 1` at start-up.
struct GuidCounters
{
    uint character = 1;
    uint item = 1;
    uint mail = 1;
    uint group = 1;
    uint instance = 1;
    uint pet = 1;
}

/// A `groups` row with its `group_member` rows.
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
/// A `characters` row as `loadCharacter` reads it (`MySqlConnection.select` makes the column list).
private struct CharacterRow
{
    uint guid, account;
    string name;
    ubyte race;
    @Column("class") ubyte classId;
    ubyte gender;
    uint level, xp, money, playerBytes, playerBytes2, playerFlags;
    @Column("position_x") float x;
    @Column("position_y") float y;
    @Column("position_z") float z;
    float orientation;
    uint map, zone, cinematic;
    @Column("totaltime") uint totalTime;
    @Column("leveltime") uint levelTime;
    @Column("at_login") uint atLogin;
    uint watchedFaction, drunk, health, power1, power2, power3, power4, power5;
    string exploredZones;
    uint ammoId;
    ubyte actionBars;
    @Column("rest_bonus") float restBonus;
    @Column("logout_time") long logoutTime;
    @Column("is_logout_resting") int logoutResting;
    @Column("death_expire_time") long deathExpireTime;
    @Column("IFNULL(taximask, '')") string taxiMask;
    @Column("IFNULL(taxi_path, '')") string taxiPath;

    CharacterData toData() const
    {
        import std.array : split;
        import std.conv : to, ConvException;
        import dmangos.world.movement : Position;

        CharacterData c;
        static foreach (field; ["guid", "account", "name", "race", "classId", "gender", "level", "xp", "money",
            "playerBytes", "playerBytes2", "playerFlags", "map", "zone", "cinematic", "totalTime", "levelTime",
            "atLogin", "watchedFaction", "health", "exploredZones", "ammoId", "actionBars", "restBonus",
            "logoutTime", "deathExpireTime", "taxiPath", "drunk"])
            __traits(getMember, c, field) = __traits(getMember, this, field);
        c.position = Position(x, y, z, orientation);
        c.power = [power1, power2, power3, power4, power5];
        c.logoutResting = logoutResting != 0;
        foreach (i, word; taxiMask.split)
            if (i < c.taxiMask.length)
            {
                try
                    c.taxiMask[i] = word.to!uint;
                catch (ConvException) {}
            }
        return c;
    }
}

/// A `character_queststatus` row.
private struct QuestStatusRow
{
    uint quest, status;
    bool rewarded, explored;
    long timer;
    @Column("mobcount1") uint mob1;
    @Column("mobcount2") uint mob2;
    @Column("mobcount3") uint mob3;
    @Column("mobcount4") uint mob4;
    @Column("itemcount1") uint item1;
    @Column("itemcount2") uint item2;
    @Column("itemcount3") uint item3;
    @Column("itemcount4") uint item4;

    QuestStatus toStatus() const
    {
        QuestStatus q;
        q.quest = quest;
        q.status = cast(QuestState) status;
        q.rewarded = rewarded;
        q.explored = explored;
        q.timer = timer;
        q.mobCount = [mob1, mob2, mob3, mob4];
        q.itemCount = [item1, item2, item3, item4];
        return q;
    }
}

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

    /// The next free ids, for those creation and deletion allocate.
    GuidCounters highestGuids()
    {
        GuidCounters next;
        next.character = maxPlusOne!"SELECT MAX(guid) FROM characters";
        next.item = maxPlusOne!"SELECT MAX(guid) FROM item_instance";
        // Mail bodies (`item_text`) and auctions take their ids from the same counter.
        next.mail = maxPlusOne!("SELECT GREATEST(IFNULL((SELECT MAX(id) FROM mail), 0), "
            ~ "IFNULL((SELECT MAX(id) FROM item_text), 0), IFNULL((SELECT MAX(id) FROM auction), 0))");
        next.group = maxPlusOne!"SELECT MAX(groupId) FROM `groups`";
        prepareBattlegroundCheckpoints();
        next.instance = maxPlusOne!("SELECT GREATEST(IFNULL((SELECT MAX(id) FROM instance), 0), "
            ~ "IFNULL((SELECT MAX(instance & 2147483647) FROM dmangos_bg_match_checkpoint), 0))");
        next.pet = maxPlusOne!"SELECT MAX(id) FROM character_pet";
        return next;
    }

    private uint maxPlusOne(string sql)()
    {
        const rows = characters.query!sql();
        return rows.length ? rows[0].get!uint(0) + 1 : 1;
    }

    /// Whether a character is called `name` already.
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

    /// Whether `character_tutorial` has the account's row.
    bool hasTutorialData(uint accountId)
    {
        return characters.query!"SELECT 1 FROM character_tutorial WHERE account = ?"(accountId).length > 0;
    }

    /// Saves a new character, with everything it starts with, in one transaction.
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

    /// A character with everything it logs in with. Null if there is no such character.
    Nullable!CharacterData loadCharacter(uint guid)
    {
        const rows = characters.select!(CharacterRow, "FROM characters WHERE guid = ?")(guid);
        if (rows.length == 0)
            return Nullable!CharacterData.init;
        CharacterData c = rows[0].toData();

        // Ordered by bag, so bags come before what is in them.
        c.items = characters.queryAs!(ItemRecord, "SELECT ci.bag, ci.slot, ci.item, ii.itemEntry, ii.creatorGuid, "
            ~ "ii.giftCreatorGuid, ii.count, ii.duration, ii.charges, ii.flags, ii.enchantments, "
            ~ "ii.randomPropertyId, ii.durability, ii.itemTextId FROM character_inventory ci "
            ~ "JOIN item_instance ii ON ii.guid = ci.item WHERE ci.guid = ? ORDER BY ci.bag, ci.slot")(guid);
        c.skills = characters.queryAs!(NewSkill, "SELECT skill, value, max FROM character_skills WHERE guid = ?")(guid);
        foreach (row; characters.select!(QuestStatusRow, "FROM character_queststatus WHERE guid = ?")(guid))
        {
            c.quests ~= row.toStatus();
        }
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

    /// Moves the character's hearthstone bind; at login, a character without one is bound where it
    /// was created.
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
        if (online)
            login.execute!"UPDATE account SET active_realm_id = ? WHERE id = ?"(realmId, accountId);
        else // handing this account off or leaving this realm must preserve a newer login to another realm
            login.execute!"UPDATE account SET active_realm_id = 0 WHERE id = ? AND active_realm_id = ?"(accountId, realmId);
    }

    /// At start-up: nobody is online on this realm (`clearOnlineAccounts`).
    void markAllOffline(uint realmId)
    {
        characters.execute!"UPDATE characters SET online = 0 WHERE online <> 0"();
        login.execute!"UPDATE account SET active_realm_id = 0 WHERE active_realm_id = ?"(realmId);
    }

    /// Saves the part of a character that changes in the world so far.
    void saveProgress(const ref CharacterProgress p)
    {
        const now = Clock.currTime.toUnixTime;
        characters.execute!("UPDATE characters SET position_x = ?, position_y = ?, position_z = ?, orientation = ?, "
            ~ "map = ?, zone = ?, totaltime = ?, leveltime = ?, logout_time = ?, health = ?, power1 = ?, "
            ~ "power2 = ?, power3 = ?, power4 = ?, power5 = ?, actionBars = ?, cinematic = ?, at_login = (at_login & 1) | ?, "
            ~ "level = ?, xp = ?, money = ?, exploredZones = ?, equipmentCache = ?, ammoId = ?, rest_bonus = ?, "
            ~ "is_logout_resting = ?, playerFlags = ?, death_expire_time = ?, taximask = ?, taxi_path = ?, drunk = ? "
            ~ "WHERE guid = ?")(
            p.position.x, p.position.y, p.position.z, p.position.orientation, p.map, p.zone, p.totalTime, p.levelTime,
            now, p.health, p.power[0], p.power[1], p.power[2], p.power[3], p.power[4], p.actionBars, p.cinematic,
            p.atLogin, p.level, p.xp, p.money, p.exploredZones, p.equipmentCache, p.ammoId, p.restBonus,
            p.resting ? 1 : 0, p.playerFlags, p.deathExpireTime, p.taxiMask, p.taxiPath, p.drunk, p.guid);
    }

    /// See `WorldDatabase.saveCorpse`.
    void saveCorpse(const ref CorpseRecord c)
    {
        characters.execute!"DELETE FROM corpse WHERE player = ?"(c.player);
        characters.execute!("INSERT INTO corpse (guid, player, position_x, position_y, position_z, orientation, map, "
            ~ "time, corpse_type, instance) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)")(c.player, c.player, c.x, c.y, c.z,
            c.orientation, c.map, c.time, c.type);
    }

    /// See `WorldDatabase.saveQuestStatus`.
    void saveQuestStatus(uint player, const(QuestStatus)[] quests)
    {
        foreach (ref q; quests)
        {
            if (q.status == QuestState.none && !q.rewarded)
            {
                characters.execute!"DELETE FROM character_queststatus WHERE guid = ? AND quest = ?"(player, q.quest);
                continue;
            }
            characters.execute!("REPLACE INTO character_queststatus (guid, quest, status, rewarded, explored, timer, "
                ~ "mobcount1, mobcount2, mobcount3, mobcount4, itemcount1, itemcount2, itemcount3, itemcount4) "
                ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(player, q.quest, cast(uint) q.status,
                q.rewarded ? 1 : 0, q.explored ? 1 : 0, q.timer, q.mobCount[0], q.mobCount[1], q.mobCount[2],
                q.mobCount[3], q.itemCount[0], q.itemCount[1], q.itemCount[2], q.itemCount[3]);
        }
    }

    /// See `WorldDatabase.saveAuras`.
    void saveAuras(uint player, const(AuraRecord)[] auras)
    {
        characters.execute!"DELETE FROM character_aura WHERE guid = ?"(player);
        foreach (ref a; auras)
            characters.execute!("INSERT INTO character_aura (guid, caster_guid, item_guid, spell, stackcount, "
                ~ "remaincharges, basepoints0, basepoints1, basepoints2, periodictime0, periodictime1, periodictime2, "
                ~ "maxduration, remaintime, effIndexMask) VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(player,
                a.caster, a.spell, a.stacks, a.charges, a.amount[0], a.amount[1], a.amount[2], a.periodTimer[0], a.periodTimer[1],
                a.periodTimer[2], a.maxDuration, a.remaining, a.effectMask);
    }

    /// See `WorldDatabase.loadGuilds`.
    GuildRecord[] loadGuilds()
    {
        GuildRecord[] guilds;
        foreach (row; characters.query!"SELECT guildid FROM guild"())
        {
            auto g = loadGuild(row.get!uint(0));
            if (!g.isNull)
                guilds ~= g.get;
        }
        return guilds;
    }

    /// See `WorldDatabase.loadGuild`.
    Nullable!GuildRecord loadGuild(uint id)
    {
        const rows = characters.query!("SELECT guildid, name, leaderguid, EmblemStyle, EmblemColor, BorderStyle, "
            ~ "BorderColor, BackgroundColor, IFNULL(info, ''), IFNULL(motd, ''), createdate FROM guild WHERE guildid = ?")(id);
        if (rows.length == 0)
            return Nullable!GuildRecord.init;
        const r = rows[0];
        GuildRecord g;
        g.id = r.get!uint(0);
        g.name = r.get!string(1);
        g.leader = r.get!uint(2);
        foreach (i; 0 .. 5)
            g.emblem[i] = r.get!uint(3 + i);
        g.info = r.get!string(8);
        g.motd = r.get!string(9);
        g.created = r.get!long(10);
        foreach (row; characters.query!"SELECT rid, rname, rights FROM guild_rank WHERE guildid = ? ORDER BY rid"(id))
            g.ranks ~= GuildRankRecord(row.get!uint(0), row.get!string(1), row.get!uint(2));
        foreach (row; characters.query!("SELECT m.guid, m.rank, IFNULL(m.pnote, ''), IFNULL(m.offnote, ''), c.name, "
                ~ "c.level, c.class, c.zone, c.logout_time, c.account FROM guild_member m JOIN characters c "
                ~ "ON c.guid = m.guid WHERE m.guildid = ?")(id))
            g.members ~= GuildMemberRecord(row.get!uint(0), row.get!uint(1), row.get!string(2), row.get!string(3),
                row.get!string(4), cast(ubyte) row.get!uint(5), cast(ubyte) row.get!uint(6), row.get!uint(7),
                row.get!long(8), row.get!uint(9));
        // The newest 100 events, put oldest first (`LoadGuildEventLogFromDB`).
        foreach_reverse (row; characters.query!("SELECT LogGuid, EventType, PlayerGuid1, PlayerGuid2, NewRank, "
                ~ "TimeStamp FROM guild_eventlog WHERE guildid = ? ORDER BY TimeStamp DESC, LogGuid DESC LIMIT 100")(id))
            g.events ~= GuildEventRecord(row.get!uint(0), cast(ubyte) row.get!uint(1), row.get!uint(2), row.get!uint(3),
                cast(ubyte) row.get!uint(4), row.get!long(5));
        return nullable(g);
    }

    /// See `WorldDatabase.nextGuildId`.
    uint nextGuildId()
    {
        prepareGuildRevision();
        uint next;
        characters.transaction({
            const rows = characters.query!"SELECT last_guild FROM dmangos_guild_revision WHERE id = 1 FOR UPDATE WAIT 1"();
            const highest = characters.query!"SELECT IFNULL(MAX(guildid), 0) FROM guild"()[0].get!uint(0);
            next = max(rows[0].get!uint(0), highest) + 1;
            characters.execute!"UPDATE dmangos_guild_revision SET last_guild = ? WHERE id = 1"(next);
        });
        return next;
    }

    private bool guildRevisionReady;

    private void prepareGuildRevision()
    {
        if (guildRevisionReady)
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_guild_revision ("
            ~ "id TINYINT UNSIGNED NOT NULL, revision BIGINT UNSIGNED NOT NULL, last_guild INT UNSIGNED NOT NULL, "
            ~ "PRIMARY KEY (id)) ENGINE=InnoDB")();
        characters.execute!("INSERT IGNORE INTO dmangos_guild_revision (id, revision, last_guild) "
            ~ "SELECT 1, 1, IFNULL(MAX(guildid), 0) FROM guild")();
        guildRevisionReady = true;
    }

    ulong guildRevision()
    {
        prepareGuildRevision();
        const rows = characters.query!"SELECT revision FROM dmangos_guild_revision WHERE id = 1"();
        return rows.length ? rows[0].get!ulong(0) : 0;
    }

    ulong commitGuildChange(scope bool delegate(ulong revision) change)
    {
        prepareGuildRevision();
        ulong revision;
        characters.transactionOnce({
            const rows = characters.query!"SELECT revision FROM dmangos_guild_revision WHERE id = 1 FOR UPDATE WAIT 1"();
            if (!rows.length)
                throw new DatabaseException("the guild revision row is missing");
            revision = rows[0].get!ulong(0);
            if (change(revision))
            {
                characters.execute!"UPDATE dmangos_guild_revision SET revision = revision + 1 WHERE id = 1"();
                ++revision;
            }
        });
        return revision;
    }

    /// See `WorldDatabase.saveGuild`.
    void saveGuild(const ref GuildRecord g)
    {
        characters.execute!("REPLACE INTO guild (guildid, name, leaderguid, EmblemStyle, EmblemColor, BorderStyle, "
            ~ "BorderColor, BackgroundColor, info, motd, createdate) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(g.id,
            g.name, g.leader, g.emblem[0], g.emblem[1], g.emblem[2], g.emblem[3], g.emblem[4], g.info, g.motd, g.created);
    }

    /// See `WorldDatabase.saveGuildRanks`.
    void saveGuildRanks(uint guild, const(GuildRankRecord)[] ranks)
    {
        characters.transaction({
            characters.execute!"DELETE FROM guild_rank WHERE guildid = ?"(guild);
            foreach (ref r; ranks)
                characters.execute!"INSERT INTO guild_rank (guildid, rid, rname, rights) VALUES (?, ?, ?, ?)"(guild,
                    r.id, r.name, r.rights);
        });
    }

    /// See `WorldDatabase.saveGuildMember`.
    void saveGuildMember(uint guild, uint member, uint rank, string publicNote, string officerNote)
    {
        characters.execute!("REPLACE INTO guild_member (guildid, guid, `rank`, pnote, offnote) VALUES (?, ?, ?, ?, ?)")(
            guild, member, rank, publicNote, officerNote);
    }

    /// See `WorldDatabase.deleteGuildMember`.
    void deleteGuildMember(uint member)
    {
        characters.execute!"DELETE FROM guild_member WHERE guid = ?"(member);
    }

    /// See `WorldDatabase.saveGuildEvent`.
    void saveGuildEvent(uint guild, const ref GuildEventRecord e)
    {
        characters.transaction({
            characters.execute!"DELETE FROM guild_eventlog WHERE guildid = ? AND LogGuid = ?"(guild, e.logGuid);
            characters.execute!("INSERT INTO guild_eventlog (guildid, LogGuid, EventType, PlayerGuid1, PlayerGuid2, "
                ~ "NewRank, TimeStamp) VALUES (?, ?, ?, ?, ?, ?, ?)")(guild, e.logGuid, uint(e.type), e.player1,
                e.player2, uint(e.newRank), e.time);
        });
    }

    /// See `WorldDatabase.deleteGuild`.
    void deleteGuild(uint guild)
    {
        characters.transaction({
            characters.execute!"DELETE FROM guild WHERE guildid = ?"(guild);
            characters.execute!"DELETE FROM guild_rank WHERE guildid = ?"(guild);
            characters.execute!"DELETE FROM guild_member WHERE guildid = ?"(guild);
            characters.execute!"DELETE FROM guild_eventlog WHERE guildid = ?"(guild);
        });
    }

    /// See `WorldDatabase.loadPetition`.
    Nullable!PetitionRecord loadPetition(uint petition)
    {
        const rows = characters.query!"SELECT ownerguid, name FROM petition WHERE petitionguid = ?"(petition);
        if (rows.length == 0)
            return Nullable!PetitionRecord.init;
        PetitionRecord p;
        p.petition = petition;
        p.owner = rows[0].get!uint(0);
        p.name = rows[0].get!string(1);
        foreach (row; characters.query!"SELECT playerguid FROM petition_sign WHERE petitionguid = ?"(petition))
            p.signers ~= row.get!uint(0);
        return nullable(p);
    }

    /// See `WorldDatabase.createPetition`.
    void createPetition(uint owner, uint petition, string name)
    {
        characters.transaction({
            foreach (row; characters.query!"SELECT petitionguid FROM petition WHERE ownerguid = ?"(owner))
                characters.execute!"DELETE FROM petition_sign WHERE petitionguid = ?"(row.get!uint(0));
            characters.execute!"DELETE FROM petition WHERE ownerguid = ? OR petitionguid = ?"(owner, petition);
            characters.execute!"DELETE FROM petition_sign WHERE petitionguid = ?"(petition);
            characters.execute!"INSERT INTO petition (ownerguid, petitionguid, name) VALUES (?, ?, ?)"(owner, petition,
                name);
        });
    }

    /// See `WorldDatabase.signPetition`.
    void signPetition(uint owner, uint petition, uint player, uint account)
    {
        characters.execute!("INSERT INTO petition_sign (ownerguid, petitionguid, playerguid, player_account) "
            ~ "VALUES (?, ?, ?, ?)")(owner, petition, player, account);
    }

    /// See `WorldDatabase.accountSignedPetition`.
    bool accountSignedPetition(uint account, uint petition)
    {
        return characters.query!"SELECT 1 FROM petition_sign WHERE player_account = ? AND petitionguid = ?"(account,
            petition).length > 0;
    }

    /// See `WorldDatabase.deletePetition`.
    void deletePetition(uint petition)
    {
        characters.transaction({
            characters.execute!"DELETE FROM petition WHERE petitionguid = ?"(petition);
            characters.execute!"DELETE FROM petition_sign WHERE petitionguid = ?"(petition);
        });
    }

    /// See `WorldDatabase.deletePetitionsOf`.
    void deletePetitionsOf(uint player)
    {
        characters.transaction({
            foreach (row; characters.query!"SELECT petitionguid FROM petition WHERE ownerguid = ?"(player))
                characters.execute!"DELETE FROM petition_sign WHERE petitionguid = ?"(row.get!uint(0));
            characters.execute!"DELETE FROM petition WHERE ownerguid = ?"(player);
            characters.execute!"DELETE FROM petition_sign WHERE playerguid = ?"(player);
        });
    }

    /// See `WorldDatabase.loadSocial`.
    SocialRow[] loadSocial(uint player)
    {
        SocialRow[] rows;
        foreach (row; characters.query!"SELECT friend, flags FROM character_social WHERE guid = ?"(player))
            rows ~= SocialRow(row.get!uint(0), cast(ubyte) row.get!uint(1));
        return rows;
    }

    /// See `WorldDatabase.saveSocial`. Its flags are part of the key: the row goes and comes back.
    void saveSocial(uint player, uint other, ubyte flags)
    {
        characters.execute!"DELETE FROM character_social WHERE guid = ? AND friend = ?"(player, other);
        if (flags)
            characters.execute!"INSERT INTO character_social (guid, friend, flags) VALUES (?, ?, ?)"(player, other, flags);
    }

    /// See `WorldDatabase.isIgnoring`.
    bool isIgnoring(uint player, uint other)
    {
        return characters.query!"SELECT 1 FROM character_social WHERE guid = ? AND friend = ? AND flags & 2"(player,
            other).length > 0;
    }

    /// See `WorldDatabase.saveTalentReset`.
    void saveTalentReset(uint player, uint cost, long time)
    {
        characters.execute!"UPDATE characters SET resettalents_cost = ?, resettalents_time = ? WHERE guid = ?"(cost,
            time, player);
    }

    /// See `WorldDatabase.loadTalentReset`.
    void loadTalentReset(uint player, out uint cost, out long time)
    {
        const rows = characters.query!"SELECT resettalents_cost, resettalents_time FROM characters WHERE guid = ?"(player);
        if (rows.length)
        {
            cost = rows[0].get!uint(0);
            time = rows[0].get!long(1);
        }
    }

    /// See `WorldDatabase.saveCooldowns`.
    void saveCooldowns(uint player, const(CooldownRecord)[] cooldowns)
    {
        characters.transaction({
            characters.execute!"DELETE FROM character_spell_cooldown WHERE guid = ?"(player);
            foreach (ref c; cooldowns)
                characters.execute!("INSERT INTO character_spell_cooldown (guid, SpellId, SpellExpireTime, Category, "
                    ~ "CategoryExpireTime, ItemId) VALUES (?, ?, ?, ?, ?, ?)")(player, c.spell, c.spellExpires, c.category,
                    c.categoryExpires, c.item);
        });
    }

    /// See `WorldDatabase.loadCooldowns`.
    CooldownRecord[] loadCooldowns(uint player)
    {
        CooldownRecord[] found;
        foreach (row; characters.query!("SELECT SpellId, SpellExpireTime, Category, CategoryExpireTime, ItemId "
                ~ "FROM character_spell_cooldown WHERE guid = ?")(player))
            found ~= CooldownRecord(row.get!uint(0), row.get!long(1), row.get!uint(2), row.get!long(3), row.get!uint(4));
        return found;
    }

    /// See `WorldDatabase.loadPets`.
    PetRecord[] loadPets(uint owner)
    {
        PetRecord[] found;
        foreach (row; characters.query!("SELECT id, entry, owner, IFNULL(modelid, 0), CreatedBySpell, PetType, level, "
                ~ "exp, Reactstate, loyaltypoints, loyalty, xpForNextLoyalty, trainpoint, IFNULL(name, ''), renamed, slot, "
                ~ "curhealth, curmana, curhappiness, savetime, IFNULL(abdata, ''), IFNULL(teachspelldata, ''), "
                ~ "resettalents_cost, resettalents_time FROM character_pet WHERE owner = ? ORDER BY id")(owner))
        {
            PetRecord p;
            p.id = row.get!uint(0);
            p.entry = row.get!uint(1);
            p.owner = row.get!uint(2);
            p.modelId = row.get!uint(3);
            p.createdBySpell = row.get!uint(4);
            p.type = cast(ubyte) row.get!uint(5);
            p.level = row.get!uint(6);
            p.exp = row.get!uint(7);
            p.reactState = cast(ubyte) row.get!uint(8);
            p.loyaltyPoints = row.get!int(9);
            p.loyalty = row.get!uint(10);
            p.xpForNextLoyalty = row.get!uint(11);
            p.trainingPoints = row.get!int(12);
            p.name = row.get!string(13);
            p.renamed = row.get!uint(14) != 0;
            p.slot = row.get!uint(15);
            p.health = row.get!uint(16);
            p.mana = row.get!uint(17);
            p.happiness = row.get!uint(18);
            p.saveTime = row.get!long(19);
            p.actionBar = row.get!string(20);
            p.teachSpells = row.get!string(21);
            p.resetCost = row.get!uint(22);
            p.resetTime = row.get!long(23);
            foreach (s; characters.query!"SELECT spell, active FROM pet_spell WHERE guid = ? ORDER BY spell"(p.id))
                p.spells ~= PetSpellRecord(s.get!uint(0), cast(ubyte) s.get!uint(1));
            found ~= p;
        }
        return found;
    }

    /// See `WorldDatabase.savePet`.
    void savePet(const ref PetRecord p)
    {
        characters.transaction({
            characters.execute!"DELETE FROM character_pet WHERE owner = ? AND id = ?"(p.owner, p.id);
            characters.execute!("INSERT INTO character_pet (id, entry, owner, modelid, level, exp, Reactstate, "
                ~ "loyaltypoints, loyalty, trainpoint, slot, name, renamed, curhealth, curmana, curhappiness, abdata, "
                ~ "teachspelldata, savetime, resettalents_cost, resettalents_time, CreatedBySpell, PetType, "
                ~ "xpForNextLoyalty) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(
                p.id, p.entry, p.owner, p.modelId, p.level, p.exp, uint(p.reactState), p.loyaltyPoints, p.loyalty,
                p.trainingPoints, p.slot, p.name, uint(p.renamed), p.health, p.mana, p.happiness, p.actionBar,
                p.teachSpells, p.saveTime, p.resetCost, p.resetTime, p.createdBySpell, uint(p.type), p.xpForNextLoyalty);
            characters.execute!"DELETE FROM pet_spell WHERE guid = ?"(p.id);
            foreach (s; p.spells)
                characters.execute!"INSERT INTO pet_spell (guid, spell, active) VALUES (?, ?, ?)"(p.id, s.spell,
                    uint(s.active));
        });
    }

    /// See `WorldDatabase.setPetSlot`.
    void setPetSlot(uint owner, uint pet, uint slot)
    {
        characters.execute!"UPDATE character_pet SET slot = ? WHERE owner = ? AND id = ?"(slot, owner, pet);
    }

    /// See `WorldDatabase.deletePet`.
    void deletePet(uint owner, uint pet)
    {
        characters.transaction({
            characters.execute!"DELETE FROM character_pet WHERE owner = ? AND id = ?"(owner, pet);
            characters.execute!"DELETE FROM pet_spell WHERE guid = ?"(pet);
            characters.execute!"DELETE FROM pet_aura WHERE guid = ?"(pet);
            characters.execute!"DELETE FROM pet_spell_cooldown WHERE guid = ?"(pet);
        });
    }

    /// See `WorldDatabase.loadStableSlots`.
    uint loadStableSlots(uint player)
    {
        const rows = characters.query!"SELECT stable_slots FROM characters WHERE guid = ?"(player);
        return rows.length ? rows[0].get!uint(0) : 0;
    }

    /// See `WorldDatabase.saveStableSlots`.
    void saveStableSlots(uint player, uint slots)
    {
        characters.execute!"UPDATE characters SET stable_slots = ? WHERE guid = ?"(slots, player);
    }

    /// See `WorldDatabase.loadAuras`.
    AuraRecord[] loadAuras(uint player)
    {
        AuraRecord[] found;
        foreach (row; characters.query!("SELECT caster_guid, spell, stackcount, basepoints0, basepoints1, basepoints2, "
                ~ "periodictime0, periodictime1, periodictime2, maxduration, remaintime, effIndexMask, remaincharges "
                ~ "FROM character_aura WHERE guid = ?")(player))
            found ~= AuraRecord(row.get!ulong(0), row.get!uint(1), row.get!uint(2), [row.get!int(3), row.get!int(4),
                row.get!int(5)], [row.get!int(6), row.get!int(7), row.get!int(8)], row.get!int(9), row.get!int(10),
                row.get!uint(11), row.get!uint(12));
        return found;
    }

    /// See `WorldDatabase.saveReputation`.
    void saveReputation(uint player, const(ReputationRecord)[] rows)
    {
        foreach (ref r; rows)
        {
            characters.execute!"DELETE FROM character_reputation WHERE guid = ? AND faction = ?"(player, r.faction);
            characters.execute!("INSERT INTO character_reputation (guid, faction, standing, flags) "
                ~ "VALUES (?, ?, ?, ?)")(player, r.faction, r.standing, r.flags);
        }
    }

    /// See `WorldDatabase.loadReputation`.
    ReputationRecord[] loadReputation(uint player)
    {
        ReputationRecord[] found;
        foreach (row; characters.query!"SELECT faction, standing, flags FROM character_reputation WHERE guid = ?"(player))
            found ~= ReputationRecord(row.get!uint(0), row.get!int(1), row.get!uint(2));
        return found;
    }

    /// See `WorldDatabase.loadHonor`.
    HonorRecord loadHonor(uint player)
    {
        HonorRecord found;
        const columns = characters.query!("SELECT honor_highest_rank, honor_standing, stored_honor_rating, "
            ~ "stored_dishonorable_kills, stored_honorable_kills FROM characters WHERE guid = ?")(player);
        if (columns.length)
        {
            const r = columns[0];
            found.columns = HonorColumns(r.get!uint(0), r.get!uint(1), r.get!float(2), r.get!int(3), r.get!int(4));
        }
        foreach (row; characters.query!"SELECT victim_type, victim, honor, date, type FROM character_honor_cp WHERE guid = ?"(player))
            found.points ~= HonorPointRecord(cast(ubyte) row.get!uint(0), row.get!uint(1), row.get!float(2),
                row.get!uint(3), cast(ubyte) row.get!uint(4));
        return found;
    }

    /// See `WorldDatabase.loadBattlegroundData`.
    BattlegroundData loadBattlegroundData(uint player)
    {
        BattlegroundData d;
        foreach (row; characters.query!("SELECT instance_id, team, join_x, join_y, join_z, join_o, join_map "
                ~ "FROM character_battleground_data WHERE guid = ?")(player))
        {
            d.instance = row.get!uint(0);
            d.team = row.get!uint(1) == teamHorde ? 1 : 0;
            d.joinX = row.get!float(2);
            d.joinY = row.get!float(3);
            d.joinZ = row.get!float(4);
            d.joinO = row.get!float(5);
            d.joinMap = row.get!uint(6);
        }
        return d;
    }

    /// See `WorldDatabase.saveBattlegroundData`.
    /// See `WorldDatabase.savePvpStats`: the battle's id is the table's next (`LAST_INSERT_ID`, this connection's), so
    /// two nodes ending battles at once cannot take one id.
    void savePvpStats(const PvpStatsBattleground b, const(PvpStatsPlayer)[] players)
    {
        characters.transaction({
            characters.execute!("INSERT INTO pvpstats_battlegrounds (winner_team, bracket_id, type, date) "
                ~ "VALUES (?, ?, ?, NOW())")(uint(b.winner), uint(b.bracket), uint(b.type));
            foreach (ref p; players)
                characters.execute!("INSERT INTO pvpstats_players (battleground_id, character_guid, score_killing_blows, "
                    ~ "score_deaths, score_honorable_kills, score_bonus_honor, score_damage_done, score_healing_done, attr_1, "
                    ~ "attr_2, attr_3, attr_4, attr_5) VALUES (LAST_INSERT_ID(), ?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?)")(p.guid,
                    p.killingBlows, p.deaths, p.honorableKills, p.bonusHonor, p.attr[0], p.attr[1], p.attr[2], p.attr[3],
                    p.attr[4]);
        });
    }

    void saveBattlegroundData(uint player, const BattlegroundData d)
    {
        characters.transaction({
            characters.execute!"DELETE FROM character_battleground_data WHERE guid = ?"(player);
            if (d != BattlegroundData.init)
                characters.execute!("INSERT INTO character_battleground_data (guid, instance_id, team, join_x, join_y, "
                    ~ "join_z, join_o, join_map) VALUES (?, ?, ?, ?, ?, ?, ?, ?)")(player, d.instance,
                    d.team ? teamHorde : teamAlliance, d.joinX, d.joinY, d.joinZ, d.joinO, d.joinMap);
        });
    }

    /// `Team`, as the battleground row keeps it.
    private enum uint teamAlliance = 469, teamHorde = 67;

    /// See `WorldDatabase.saveHonor`.
    void saveHonor(uint player, const HonorColumns c, const(HonorPointRecord)[] added)
    {
        characters.transaction({
            characters.execute!("UPDATE characters SET honor_highest_rank = ?, honor_standing = ?, stored_honor_rating = ?, "
                ~ "stored_dishonorable_kills = ?, stored_honorable_kills = ? WHERE guid = ?")(c.highestRank, c.standing,
                c.storedRating, c.storedDishonorableKills, c.storedHonorableKills, player);
            foreach (ref p; added)
                characters.execute!("INSERT INTO character_honor_cp (guid, victim_type, victim, honor, date, type) "
                    ~ "VALUES (?, ?, ?, ?, ?, ?)")(player, p.victimType, p.victim, p.honor, p.date, p.type);
        });
    }

    /// See `WorldDatabase.nextHonorMaintenance`.
    uint nextHonorMaintenance()
    {
        const rows = characters.query!"SELECT NextMaintenanceDate FROM saved_variables"();
        return rows.length ? rows[0].get!uint(0) : 0;
    }

    /// See `WorldDatabase.setNextHonorMaintenance`.
    void setNextHonorMaintenance(uint day)
    {
        if (characters.query!"SELECT 1 FROM saved_variables"().length)
            characters.execute!"UPDATE saved_variables SET NextMaintenanceDate = ?"(day);
        else
            characters.execute!"INSERT INTO saved_variables (NextMaintenanceDate) VALUES (?)"(day);
    }

    /// See `WorldDatabase.oldestHonorDay`.
    uint oldestHonorDay()
    {
        const rows = characters.query!"SELECT IFNULL(MIN(date), 0) FROM character_honor_cp WHERE type = 1"();
        return rows.length ? rows[0].get!uint(0) : 0;
    }

    /// See `WorldDatabase.honorWeek`. (Days compare as numbers: the year is in the high bits.)
    HonorWeekEntry[] honorWeek(uint from, uint until)
    {
        HonorWeekEntry[] found;
        foreach (row; characters.query!("SELECT h.guid, SUM(h.honor), SUM(h.victim_type IN (3, 4)), c.race, "
            ~ "c.stored_honor_rating FROM character_honor_cp h JOIN characters c ON c.guid = h.guid "
            ~ "WHERE h.type = 1 AND h.date >= ? AND h.date < ? GROUP BY h.guid, c.race, c.stored_honor_rating")(from, until))
            found ~= HonorWeekEntry(row.get!uint(0), row.get!float(1), row.get!uint(2), cast(ubyte) row.get!uint(3),
                row.get!float(4));
        return found;
    }

    /// See `WorldDatabase.setHonorRating`.
    void setHonorRating(uint player, float rating, uint standing, bool setStanding)
    {
        if (setStanding)
            characters.execute!"UPDATE characters SET stored_honor_rating = ?, honor_standing = ? WHERE guid = ?"(
                rating, standing, player);
        else
            characters.execute!"UPDATE characters SET stored_honor_rating = ? WHERE guid = ?"(rating, player);
    }

    /// See `WorldDatabase.clearHonorStandings`.
    void clearHonorStandings()
    {
        characters.execute!"UPDATE characters SET honor_standing = 0 WHERE honor_standing <> 0"();
    }

    /// See `WorldDatabase.foldHonorPoints`.
    void foldHonorPoints(uint day)
    {
        characters.transaction({
            foreach (row; characters.query!("SELECT guid, type, COUNT(*) FROM character_honor_cp "
                ~ "WHERE date < ? AND victim_type IN (3, 4) GROUP BY guid, type")(day))
            {
                if (row.get!uint(1) == 1)
                    characters.execute!"UPDATE characters SET stored_honorable_kills = stored_honorable_kills + ? WHERE guid = ?"(
                        row.get!uint(2), row.get!uint(0));
                else
                    characters.execute!"UPDATE characters SET stored_dishonorable_kills = stored_dishonorable_kills + ? WHERE guid = ?"(
                        row.get!uint(2), row.get!uint(0));
            }
            characters.execute!"DELETE FROM character_honor_cp WHERE date < ?"(day);
        });
    }

    /// See `WorldDatabase.deleteCorpse`.
    void deleteCorpse(uint player)
    {
        characters.execute!"DELETE FROM corpse WHERE player = ?"(player);
    }

    /// See `WorldDatabase.loadCorpse`.
    Nullable!CorpseRecord loadCorpse(uint player)
    {
        const rows = characters.query!("SELECT player, position_x, position_y, position_z, orientation, map, time, "
            ~ "corpse_type FROM corpse WHERE player = ? AND corpse_type > 0")(player);
        if (rows.length == 0)
            return Nullable!CorpseRecord.init;
        const r = rows[0];
        return Nullable!CorpseRecord(CorpseRecord(r.get!uint(0), r.get!float(1), r.get!float(2), r.get!float(3),
            r.get!float(4), r.get!uint(5), r.get!long(6), r.get!ubyte(7)));
    }

    /// See `WorldDatabase.saveCreatureRespawn`.
    void saveCreatureRespawn(uint spawnGuid, long respawnTime)
    {
        if (respawnTime)
            characters.transaction({
                characters.execute!"REPLACE INTO creature_respawn (guid, respawntime, instance) VALUES (?, ?, 0)"(
                    spawnGuid, respawnTime);
                deletePickpocket(0, spawnGuid);
            });
        else
            characters.execute!"DELETE FROM creature_respawn WHERE guid = ? AND instance = 0"(spawnGuid);
    }

    private bool creaturePoolsReady;

    private void prepareCreaturePools()
    {
        if (creaturePoolsReady)
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_creature_pool ("
            ~ "realm INT UNSIGNED NOT NULL, pool INT UNSIGNED NOT NULL, spawn INT UNSIGNED NOT NULL, "
            ~ "due BIGINT NOT NULL, revision BIGINT UNSIGNED NOT NULL, PRIMARY KEY (realm, pool)) ENGINE=InnoDB")();
        creaturePoolsReady = true;
    }

    imported!"dmangos.world.database".CreaturePoolState[uint] loadCreaturePoolStates(uint realm)
    {
        import dmangos.world.database : CreaturePoolState;

        prepareCreaturePools();
        CreaturePoolState[uint] states;
        foreach (row; characters.query!"SELECT pool, spawn, due, revision FROM dmangos_creature_pool WHERE realm = ?"(realm))
            states[row.get!uint(0)] = CreaturePoolState(row.get!uint(1), row.get!long(2), row.get!ulong(3));
        return states;
    }

    bool updateCreaturePoolState(uint realm, uint pool, ulong revision, uint spawn, long due)
    {
        prepareCreaturePools();
        if (!revision)
            return characters.execute!("INSERT IGNORE INTO dmangos_creature_pool (realm, pool, spawn, due, revision) "
                ~ "VALUES (?, ?, ?, ?, 1)")(realm, pool, spawn, due) == 1;
        return characters.execute!("UPDATE dmangos_creature_pool SET spawn = ?, due = ?, revision = revision + 1 "
            ~ "WHERE realm = ? AND pool = ? AND revision = ?")(spawn, due, realm, pool, revision) == 1;
    }

    void prepareGameObjectPools()
    {
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_gameobject_pool ("
            ~ "realm INT UNSIGNED NOT NULL, pool INT UNSIGNED NOT NULL, revision BIGINT UNSIGNED NOT NULL, "
            ~ "placements MEDIUMTEXT CHARACTER SET ascii NOT NULL, PRIMARY KEY (realm, pool)) ENGINE=InnoDB")();
    }

    imported!"dmangos.world.database".GameObjectPoolState[uint] loadGameObjectPoolStates(uint realm)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.database : GameObjectPoolPlacement, GameObjectPoolState;
        import dmangos.world.instancescripting : fromHex;

        GameObjectPoolState[uint] states;
        foreach (row; characters.query!("SELECT pool, revision, placements FROM dmangos_gameobject_pool "
                ~ "WHERE realm = ?")(realm))
        {
            auto bytes = ByteReader(fromHex(row.get!string(2)));
            GameObjectPoolState state;
            state.revision = row.get!ulong(1);
            while (bytes.remaining)
                state.placements ~= GameObjectPoolPlacement(bytes.read!uint, bytes.read!long);
            states[row.get!uint(0)] = state;
        }
        return states;
    }

    bool updateGameObjectPoolState(uint realm, uint pool, const ref imported!"dmangos.world.database".GameObjectPoolState state)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.instancescripting : toHex;

        ByteWriter bytes;
        foreach (placement; state.placements)
        {
            bytes.put(placement.spawn);
            bytes.put(placement.due);
        }
        const placements = toHex(bytes.data);
        if (!state.revision)
            return characters.execute!("INSERT IGNORE INTO dmangos_gameobject_pool (realm, pool, revision, placements) "
                ~ "VALUES (?, ?, 1, ?)")(realm, pool, placements) == 1;
        return characters.execute!("UPDATE dmangos_gameobject_pool SET revision = revision + 1, placements = ? "
            ~ "WHERE realm = ? AND pool = ? AND revision = ?")(placements, realm, pool, state.revision) == 1;
    }

    /// The `auction` columns, in `AuctionRecord` order.
    enum auctionColumns = "id, houseid, itemguid, item_template, item_count, item_randompropertyid, itemowner, "
        ~ "buyoutprice, time, buyguid, lastbid, startbid, deposit";

    /// See `WorldDatabase.insertAuction`.
    void insertAuction(const ref AuctionRecord a)
    {
        characters.execute!("INSERT INTO auction (" ~ auctionColumns ~ ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(
            a.id, a.houseId, a.itemGuid, a.itemEntry, a.itemCount, a.randomPropertyId, a.owner, a.buyout,
            a.expireTime, a.bidder, a.bid, a.startBid, a.deposit);
    }

    /// See `WorldDatabase.loadAuctions`.
    AuctionRecord[] loadAuctions(uint houseId)
    {
        AuctionRecord[] found;
        if (houseId)
        {
            foreach (row; characters.queryAs!(AuctionRecord, "SELECT " ~ auctionColumns
                    ~ " FROM auction WHERE houseid = ? ORDER BY id")(houseId))
                found ~= row;
        }
        else
            foreach (row; characters.queryAs!(AuctionRecord, "SELECT " ~ auctionColumns ~ " FROM auction ORDER BY id")())
                found ~= row;
        return found;
    }

    /// See `WorldDatabase.auctionById`.
    Nullable!AuctionRecord auctionById(uint id)
    {
        foreach (row; characters.queryAs!(AuctionRecord, "SELECT " ~ auctionColumns ~ " FROM auction WHERE id = ?")(id))
            return Nullable!AuctionRecord(row);
        return Nullable!AuctionRecord.init;
    }

    /// See `WorldDatabase.bidOnAuction`.
    bool bidOnAuction(uint id, uint oldBidder, uint oldBid, uint bidder, uint bid)
    {
        return characters.execute!("UPDATE auction SET buyguid = ?, lastbid = ? WHERE id = ? AND buyguid = ? "
            ~ "AND lastbid = ?")(bidder, bid, id, oldBidder, oldBid) == 1;
    }

    /// See `WorldDatabase.deleteAuction`.
    bool deleteAuction(uint id, uint bid)
    {
        return characters.execute!"DELETE FROM auction WHERE id = ? AND lastbid = ?"(id, bid) == 1;
    }

    /// See `WorldDatabase.expiredAuctions`.
    AuctionRecord[] expiredAuctions(long now)
    {
        AuctionRecord[] found;
        foreach (row; characters.queryAs!(AuctionRecord, "SELECT " ~ auctionColumns ~ " FROM auction WHERE time <= ?")(now))
            found ~= row;
        return found;
    }

    /// See `WorldDatabase.maxAuctionId`.
    uint maxAuctionId()
    {
        foreach (row; characters.query!"SELECT IFNULL(MAX(id), 0) FROM auction"())
            return row.get!uint(0);
        return 0;
    }

    /// See `WorldDatabase.saveGameObjectRespawn`.
    void saveGameObjectRespawn(uint spawnGuid, long respawnTime)
    {
        if (respawnTime)
            characters.execute!"REPLACE INTO gameobject_respawn (guid, respawntime, instance) VALUES (?, ?, 0)"(
                spawnGuid, respawnTime);
        else
            characters.execute!"DELETE FROM gameobject_respawn WHERE guid = ? AND instance = 0"(spawnGuid);
    }

    /// See `WorldDatabase.loadGameObjectRespawns`.
    long[uint] loadGameObjectRespawns()
    {
        long[uint] all;
        foreach (row; characters.query!"SELECT guid, respawntime FROM gameobject_respawn WHERE instance = 0"())
            all[row.get!uint(0)] = row.get!long(1);
        return all;
    }

    private bool instanceChestsReady;

    /// Also run on the write-behind connection before it starts a transaction.
    void prepareInstanceChests()
    {
        if (instanceChestsReady)
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_instance_chest ("
            ~ "instance INT UNSIGNED NOT NULL, spawn INT UNSIGNED NOT NULL, expires_at BIGINT NOT NULL, "
            ~ "loot MEDIUMTEXT CHARACTER SET ascii NOT NULL, PRIMARY KEY (instance, spawn)) ENGINE=InnoDB")();
        instanceChestsReady = true;
    }

    private bool instanceCorpsesReady;

    void prepareInstanceCorpses()
    {
        if (instanceCorpsesReady)
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_instance_corpse ("
            ~ "instance INT UNSIGNED NOT NULL, spawn INT UNSIGNED NOT NULL, expires_at BIGINT NOT NULL, "
            ~ "state MEDIUMTEXT CHARACTER SET ascii NOT NULL, PRIMARY KEY (instance, spawn), KEY (expires_at)) ENGINE=InnoDB")();
        instanceCorpsesReady = true;
    }

    /// See `WorldDatabase.loadInstances`.
    InstanceRecords loadInstances()
    {
        import dmangos.world.database : InstanceChestRecord, InstanceCorpseRecord;

        prepareInstanceChests();
        prepareInstanceCorpses();
        InstanceRecords all;
        foreach (row; characters.query!"SELECT id, map, resettime, IFNULL(data, '') FROM instance"())
            all.instances ~= InstanceRecord(row.get!uint(0), row.get!uint(1), row.get!long(2), row.get!string(3));
        foreach (row; characters.query!"SELECT guid, instance, permanent FROM character_instance"())
            all.binds ~= InstanceBindRecord(false, row.get!uint(0), row.get!uint(1), row.get!uint(2) != 0);
        foreach (row; characters.query!"SELECT leaderGuid, instance, permanent FROM group_instance"())
            all.binds ~= InstanceBindRecord(true, row.get!uint(0), row.get!uint(1), row.get!uint(2) != 0);
        foreach (row; characters.query!"SELECT guid, instance, respawntime FROM creature_respawn WHERE instance <> 0"())
            all.respawns ~= InstanceRespawnRecord(false, row.get!uint(0), row.get!uint(1), row.get!long(2));
        foreach (row; characters.query!"SELECT guid, instance, respawntime FROM gameobject_respawn WHERE instance <> 0"())
            all.respawns ~= InstanceRespawnRecord(true, row.get!uint(0), row.get!uint(1), row.get!long(2));
        foreach (row; characters.query!("SELECT instance, spawn, expires_at, loot FROM dmangos_instance_chest "
                ~ "WHERE instance <> 0")())
            all.chests ~= InstanceChestRecord(row.get!uint(0), row.get!uint(1), row.get!long(2), row.get!string(3));
        foreach (row; characters.query!("SELECT instance, spawn, expires_at, state FROM dmangos_instance_corpse "
                ~ "WHERE instance <> 0 AND expires_at > UNIX_TIMESTAMP()")())
            all.corpses ~= InstanceCorpseRecord(row.get!uint(0), row.get!uint(1), row.get!long(2), row.get!string(3));
        return all;
    }

    /// See `WorldDatabase.saveInstance`.
    void saveInstance(uint id, uint map, long resetTime)
    {
        characters.execute!"REPLACE INTO instance (id, map, resettime, encountersMask, data) VALUES (?, ?, ?, 0, '')"(
            id, map, resetTime);
    }

    /// See `WorldDatabase.instanceMapOf`.
    uint instanceMapOf(uint id)
    {
        const rows = characters.query!"SELECT map FROM instance WHERE id = ?"(id);
        return rows.length ? rows[0].get!uint(0) : uint.max;
    }

    /// See `WorldDatabase.instanceBindsOf`.
    uint[uint] instanceBindsOf(uint player)
    {
        uint[uint] binds;
        foreach (row; characters.query!("SELECT i.map, c.instance FROM character_instance c JOIN instance i "
                ~ "ON i.id = c.instance WHERE c.guid = ?")(player))
            binds[row.get!uint(0)] = row.get!uint(1);
        return binds;
    }

    /// See `WorldDatabase.saveInstanceData`.
    void saveInstanceData(uint id, string data)
    {
        characters.execute!"UPDATE instance SET data = ? WHERE id = ?"(data, id);
    }

    void saveInstanceChest(const imported!"dmangos.world.database".InstanceChestRecord chest)
    {
        if (chest.instance)
            characters.execute!("INSERT INTO dmangos_instance_chest (instance, spawn, expires_at, loot) "
                ~ "SELECT id, ?, ?, ? FROM instance WHERE id = ? "
                ~ "ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at), loot = VALUES(loot)")(
                    chest.spawn, chest.expiresAt, chest.loot, chest.instance);
        else
            characters.execute!("INSERT INTO dmangos_instance_chest (instance, spawn, expires_at, loot) "
                ~ "VALUES (0, ?, ?, ?) ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at), loot = VALUES(loot)")(
                    chest.spawn, chest.expiresAt, chest.loot);
    }

    imported!"dmangos.world.database".InstanceChestRecord[] loadOutdoorChests()
    {
        import dmangos.world.database : InstanceChestRecord;

        prepareInstanceChests();
        InstanceChestRecord[] result;
        foreach (row; characters.query!"SELECT spawn, expires_at, loot FROM dmangos_instance_chest WHERE instance = 0"())
            result ~= InstanceChestRecord(0, row.get!uint(0), row.get!long(1), row.get!string(2));
        return result;
    }

    void deleteOutdoorChest(uint spawn)
    {
        characters.execute!"DELETE FROM dmangos_instance_chest WHERE instance = 0 AND spawn = ?"(spawn);
    }

    imported!"dmangos.world.database".InstanceChestRecord loadOutdoorChest(uint spawn)
    {
        import dmangos.world.database : InstanceChestRecord;

        foreach (row; characters.query!("SELECT expires_at, loot FROM dmangos_instance_chest "
                ~ "WHERE instance = 0 AND spawn = ?")(spawn))
            return InstanceChestRecord(0, spawn, row.get!long(0), row.get!string(1));
        return InstanceChestRecord.init;
    }

    void saveInstanceCorpse(const imported!"dmangos.world.database".InstanceCorpseRecord corpse)
    {
        if (corpse.instance)
            characters.execute!("INSERT INTO dmangos_instance_corpse (instance, spawn, expires_at, state) "
                ~ "SELECT id, ?, ?, ? FROM instance WHERE id = ? "
                ~ "ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at), state = VALUES(state)")(
                    corpse.spawn, corpse.expiresAt, corpse.state, corpse.instance);
        else
            characters.execute!("INSERT INTO dmangos_instance_corpse (instance, spawn, expires_at, state) "
                ~ "VALUES (0, ?, ?, ?) ON DUPLICATE KEY UPDATE expires_at = VALUES(expires_at), state = VALUES(state)")(
                    corpse.spawn, corpse.expiresAt, corpse.state);
    }

    imported!"dmangos.world.database".InstanceCorpseRecord[] loadOutdoorCorpses()
    {
        import dmangos.world.database : InstanceCorpseRecord;

        prepareInstanceCorpses();
        InstanceCorpseRecord[] result;
        foreach (row; characters.query!("SELECT spawn, expires_at, state FROM dmangos_instance_corpse "
                ~ "WHERE instance = 0 AND expires_at > UNIX_TIMESTAMP()")())
            result ~= InstanceCorpseRecord(0, row.get!uint(0), row.get!long(1), row.get!string(2));
        return result;
    }

    void deleteInstanceCorpse(uint instance, uint spawn)
    {
        characters.execute!"DELETE FROM dmangos_instance_corpse WHERE instance = ? AND spawn = ?"(instance, spawn);
    }

    void purgeExpiredOutdoorCorpses(long before)
    {
        prepareInstanceCorpses();
        characters.execute!"DELETE FROM dmangos_instance_corpse WHERE instance = 0 AND expires_at < ?"(before);
    }

    void preparePickpockets()
    {
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_pickpocket ("
            ~ "instance INT UNSIGNED NOT NULL, spawn INT UNSIGNED NOT NULL, restock_at BIGINT NOT NULL, "
            ~ "loot MEDIUMTEXT CHARACTER SET ascii NOT NULL, PRIMARY KEY (instance, spawn)) ENGINE=InnoDB")();
    }

    imported!"dmangos.world.database".PickpocketRecord loadPickpocket(uint instance, uint spawn)
    {
        import dmangos.world.database : PickpocketRecord;

        const rows = characters.query!("SELECT restock_at, loot FROM dmangos_pickpocket "
            ~ "WHERE instance = ? AND spawn = ?")(instance, spawn);
        return rows.length ? PickpocketRecord(instance, spawn, rows[0].get!long(0), rows[0].get!string(1))
            : PickpocketRecord.init;
    }

    void savePickpocket(const imported!"dmangos.world.database".PickpocketRecord pocket)
    {
        enum insert = "INSERT INTO dmangos_pickpocket (instance, spawn, restock_at, loot) ";
        enum update = " ON DUPLICATE KEY UPDATE restock_at = VALUES(restock_at), loot = VALUES(loot)";
        if (pocket.instance)
            characters.execute!(insert ~ "SELECT id, ?, ?, ? FROM instance WHERE id = ?" ~ update)(
                pocket.spawn, pocket.restockAt, pocket.loot, pocket.instance);
        else
            characters.execute!(insert ~ "VALUES (0, ?, ?, ?)" ~ update)(pocket.spawn, pocket.restockAt, pocket.loot);
    }

    void deletePickpocket(uint instance, uint spawn)
    {
        characters.execute!"DELETE FROM dmangos_pickpocket WHERE instance = ? AND spawn = ?"(instance, spawn);
    }

    void prepareQuestActors()
    {
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_quest_actor ("
            ~ "realm INT UNSIGNED NOT NULL, actor BIGINT UNSIGNED NOT NULL, map INT UNSIGNED NOT NULL, "
            ~ "home BIGINT UNSIGNED NOT NULL, player BIGINT UNSIGNED NOT NULL, saved_at BIGINT NOT NULL, "
            ~ "state MEDIUMTEXT CHARACTER SET ascii NOT NULL, PRIMARY KEY (realm, actor)) ENGINE=InnoDB")();
    }

    imported!"dmangos.world.database".QuestActorCheckpoint[] loadQuestActors(uint realm)
    {
        import dmangos.world.database : QuestActorCheckpoint;

        QuestActorCheckpoint[] actors;
        foreach (row; characters.query!("SELECT map, actor, home, player, saved_at, state FROM dmangos_quest_actor "
                ~ "WHERE realm = ?")(realm))
            actors ~= QuestActorCheckpoint(row.get!uint(0), row.get!ulong(1), row.get!ulong(2), row.get!ulong(3),
                row.get!long(4), row.get!string(5));
        return actors;
    }

    void saveQuestActor(uint realm, const imported!"dmangos.world.database".QuestActorCheckpoint actor)
    {
        characters.execute!("REPLACE INTO dmangos_quest_actor (realm, actor, map, home, player, saved_at, state) "
            ~ "VALUES (?, ?, ?, ?, ?, ?, ?)")(realm, actor.actor, actor.map, actor.home, actor.player, actor.savedAt, actor.state);
    }

    void deleteQuestActor(uint realm, ulong actor)
    {
        characters.execute!"DELETE FROM dmangos_quest_actor WHERE realm = ? AND actor = ?"(realm, actor);
    }

    void prepareDungeonFights()
    {
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_dungeon_fight ("
            ~ "instance INT UNSIGNED NOT NULL, spawn INT UNSIGNED NOT NULL, "
            ~ "state MEDIUMTEXT CHARACTER SET ascii NOT NULL, PRIMARY KEY (instance, spawn)) ENGINE=InnoDB")();
    }

    imported!"dmangos.world.database".DungeonFightCheckpoint[] loadDungeonFights(uint instance)
    {
        import dmangos.world.database : DungeonFightCheckpoint;

        DungeonFightCheckpoint[] fights;
        foreach (row; characters.query!"SELECT spawn, state FROM dmangos_dungeon_fight WHERE instance = ?"(instance))
            fights ~= DungeonFightCheckpoint(row.get!uint(0), row.get!string(1));
        return fights;
    }

    void saveDungeonFight(uint instance, const imported!"dmangos.world.database".DungeonFightCheckpoint fight)
    {
        characters.execute!"REPLACE INTO dmangos_dungeon_fight (instance, spawn, state) VALUES (?, ?, ?)"(
            instance, fight.spawn, fight.state);
    }

    void deleteDungeonFight(uint instance, uint spawn)
    {
        characters.execute!"DELETE FROM dmangos_dungeon_fight WHERE instance = ? AND spawn = ?"(instance, spawn);
    }

    void prepareOutdoorScripts()
    {
        characters.execute!"CREATE TABLE IF NOT EXISTS dmangos_script_credit (
            realm INT UNSIGNED NOT NULL, origin SMALLINT UNSIGNED NOT NULL, sequence BIGINT UNSIGNED NOT NULL,
            player INT UNSIGNED NOT NULL, kind TINYINT UNSIGNED NOT NULL, quest INT UNSIGNED NOT NULL,
            rewarder BIGINT UNSIGNED NOT NULL, applied BOOLEAN NOT NULL DEFAULT FALSE,
            PRIMARY KEY (realm, origin, sequence), KEY pending (realm, applied, sequence), KEY (player)
        ) ENGINE=InnoDB"();
        characters.execute!"CREATE TABLE IF NOT EXISTS dmangos_gameplay_sequence (
            realm INT UNSIGNED NOT NULL, node SMALLINT UNSIGNED NOT NULL, reserved BIGINT UNSIGNED NOT NULL,
            PRIMARY KEY (realm, node)
        ) ENGINE=InnoDB"();
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_outdoor_script ("
            ~ "realm INT UNSIGNED NOT NULL, origin SMALLINT UNSIGNED NOT NULL, sequence BIGINT UNSIGNED NOT NULL, "
            ~ "map INT UNSIGNED NOT NULL, home BIGINT UNSIGNED NOT NULL, `cursor` INT UNSIGNED NOT NULL, "
            ~ "state TEXT CHARACTER SET ascii NOT NULL, PRIMARY KEY (realm, origin, sequence)) ENGINE=InnoDB")();
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_outdoor_world_state ("
            ~ "realm INT UNSIGNED NOT NULL, map INT UNSIGNED NOT NULL, id INT UNSIGNED NOT NULL, "
            ~ "value INT NOT NULL, PRIMARY KEY (realm, map, id)) ENGINE=InnoDB")();
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_outdoor_summon ("
            ~ "realm INT UNSIGNED NOT NULL, origin SMALLINT UNSIGNED NOT NULL, sequence BIGINT UNSIGNED NOT NULL, "
            ~ "`cursor` INT UNSIGNED NOT NULL, ordinal INT UNSIGNED NOT NULL, map INT UNSIGNED NOT NULL, "
            ~ "home BIGINT UNSIGNED NOT NULL, state TEXT CHARACTER SET ascii NOT NULL, "
            ~ "actor BIGINT UNSIGNED NOT NULL DEFAULT 0, kind TINYINT UNSIGNED NOT NULL DEFAULT 0, "
            ~ "PRIMARY KEY (realm, origin, sequence, `cursor`, ordinal)) ENGINE=InnoDB")();
        characters.execute!("ALTER TABLE dmangos_outdoor_summon ADD COLUMN IF NOT EXISTS "
            ~ "kind TINYINT UNSIGNED NOT NULL DEFAULT 0")();
    }

    imported!"dmangos.world.database".OutdoorScriptCheckpoint[] loadOutdoorScripts(uint realm)
    {
        import dmangos.world.database : OutdoorScriptCheckpoint;

        OutdoorScriptCheckpoint[] scripts;
        foreach (row; characters.query!("SELECT s.origin, s.sequence, s.map, s.`cursor`, s.home, s.state, "
                ~ "EXISTS(SELECT 1 FROM dmangos_outdoor_summon q WHERE q.realm = s.realm AND q.origin = s.origin "
                ~ "AND q.sequence = s.sequence) FROM dmangos_outdoor_script s WHERE s.realm = ? "
                ~ "ORDER BY s.sequence, s.origin")(realm))
            scripts ~= OutdoorScriptCheckpoint(row.get!ushort(0), row.get!ulong(1), row.get!uint(2),
                row.get!uint(3), row.get!ulong(4), row.get!string(5), row.get!bool(6));
        return scripts;
    }

    bool beginOutdoorScript(uint realm, const ref imported!"dmangos.world.database".OutdoorScriptCheckpoint script)
    {
        return characters.execute!("INSERT IGNORE INTO dmangos_outdoor_script "
            ~ "(realm, origin, sequence, map, home, `cursor`, state) VALUES (?, ?, ?, ?, ?, ?, ?)")(
                realm, script.origin, script.sequence, script.map, script.home, script.cursor, script.state) == 1;
    }

    bool advanceOutdoorScript(uint realm, ushort origin, ulong sequence, uint cursor, bool finished)
    {
        enum key = " WHERE realm = ? AND origin = ? AND sequence = ? AND `cursor` = ?";
        if (finished)
            return characters.execute!("DELETE FROM dmangos_outdoor_script" ~ key)(realm, origin, sequence, cursor) == 1;
        return characters.execute!("UPDATE dmangos_outdoor_script SET `cursor` = `cursor` + 1" ~ key)(
            realm, origin, sequence, cursor) == 1;
    }

    void enqueueScriptQuestCredit(uint realm, const ref ScriptQuestCredit credit)
    {
        characters.execute!"INSERT INTO dmangos_script_credit (realm, origin, sequence, player, kind, quest, rewarder)
            VALUES (?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE realm = realm"
            (realm, credit.origin, credit.sequence, cast(uint) credit.player, cast(ubyte) credit.kind, credit.quest, credit.rewarder);
    }

    ScriptQuestCredit[] pendingScriptQuestCredits(uint realm)
    {
        ScriptQuestCredit[] pending;
        foreach (row; characters.query!"SELECT player, kind, quest, rewarder, origin, sequence FROM dmangos_script_credit
                WHERE realm = ? AND applied = FALSE ORDER BY sequence, origin"(realm))
            pending ~= ScriptQuestCredit(row.get!uint(0), cast(ScriptQuestCredit.Kind) row.get!ubyte(1),
                row.get!uint(2), row.get!ulong(3), row.get!ushort(4), row.get!ulong(5));
        return pending;
    }

    bool consumeScriptQuestCredit(uint realm, const ref ScriptQuestCredit credit, const(QuestStatus)[] quests)
    {
        bool applied;
        characters.transaction({
            if (!characters.execute!"UPDATE dmangos_script_credit SET applied = TRUE WHERE realm = ?
                    AND origin = ? AND sequence = ? AND player = ? AND kind = ? AND quest = ?
                    AND rewarder = ? AND applied = FALSE"(realm, credit.origin, credit.sequence, credit.player,
                        cast(ubyte) credit.kind, credit.quest, credit.rewarder))
                return;
            saveQuestStatus(cast(uint) credit.player, quests);
            applied = true; // preserved if a lost COMMIT reply forces the transaction to run again
        });
        return applied;
    }

    ulong reserveGameplaySequences(uint realm, ushort node, ulong floor, uint count)
    {
        ulong last;
        characters.transaction({
            characters.execute!"INSERT INTO dmangos_gameplay_sequence (realm, node, reserved) VALUES (?, ?, ?)
                ON DUPLICATE KEY UPDATE reserved = GREATEST(reserved, ?) + ?"(realm, node, floor + count, floor, count);
            last = characters.query!"SELECT reserved FROM dmangos_gameplay_sequence WHERE realm = ? AND node = ?"
                (realm, node)[0].get!ulong(0);
        });
        return last - count + 1;
    }

    OutdoorWorldState[] loadOutdoorWorldStates(uint realm)
    {
        OutdoorWorldState[] states;
        foreach (row; characters.query!"SELECT map, id, value FROM dmangos_outdoor_world_state WHERE realm = ?"(realm))
            states ~= OutdoorWorldState(row.get!uint(0), row.get!uint(1), row.get!int(2));
        return states;
    }

    void saveOutdoorWorldState(uint realm, const ref OutdoorWorldState state)
    {
        characters.execute!("INSERT INTO dmangos_outdoor_world_state (realm, map, id, value) VALUES (?, ?, ?, ?) "
            ~ "ON DUPLICATE KEY UPDATE value = VALUES(value)")(realm, state.map, state.id, state.value);
    }

    void insertOutdoorSummon(uint realm, const ref OutdoorSummonRequest request)
    {
        characters.execute!("INSERT INTO dmangos_outdoor_summon "
            ~ "(realm, origin, sequence, `cursor`, ordinal, map, home, state, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) "
            ~ "ON DUPLICATE KEY UPDATE realm = realm")(
                realm, request.origin, request.sequence, request.cursor, request.ordinal, request.map, request.home,
                request.state, cast(ubyte) request.kind);
    }

    OutdoorSummonRequest[] loadOutdoorSummons(uint realm)
    {
        OutdoorSummonRequest[] requests;
        foreach (row; characters.query!("SELECT q.origin, q.sequence, q.`cursor`, q.ordinal, q.map, q.home, q.state, "
                ~ "q.actor, a.saved_at, a.state, q.kind FROM dmangos_outdoor_summon q LEFT JOIN dmangos_quest_actor a "
                ~ "ON a.realm = q.realm AND a.actor = q.actor AND a.player = 0 AND a.map = q.map AND a.home = q.home "
                ~ "WHERE q.realm = ? ORDER BY q.sequence, q.origin, q.`cursor`, q.ordinal")(realm))
        {
            auto request = OutdoorSummonRequest(row.get!ushort(0), row.get!ulong(1), row.get!uint(2), row.get!uint(3),
                row.get!uint(4), row.get!ulong(5), row.get!string(6), row.get!ulong(7));
            request.kind = cast(OutdoorSummonKind) row.get!ubyte(10);
            if (!row.isNull(8))
                request.checkpoint = QuestActorCheckpoint(request.map, request.actor, request.home, 0,
                    row.get!long(8), row.get!string(9));
            requests ~= request;
        }
        return requests;
    }

    bool outdoorSummonsPending(uint realm, ushort origin, ulong sequence)
    {
        return characters.query!("SELECT 1 FROM dmangos_outdoor_summon WHERE realm = ? AND origin = ? "
            ~ "AND sequence = ? LIMIT 1")(realm, origin, sequence).length != 0;
    }

    private enum outdoorSummonKey = " WHERE realm = ? AND origin = ? AND sequence = ? AND `cursor` = ? AND ordinal = ?";

    bool completeOutdoorSummon(uint realm, const ref OutdoorSummonRequest request, ulong actor)
    {
        return characters.execute!("UPDATE dmangos_outdoor_summon SET actor = ?" ~ outdoorSummonKey ~ " AND actor = 0")(
            actor, realm, request.origin, request.sequence, request.cursor, request.ordinal) == 1;
    }

    bool retireOutdoorSummon(uint realm, const ref OutdoorSummonRequest request)
    {
        return characters.execute!("DELETE FROM dmangos_outdoor_summon" ~ outdoorSummonKey ~ " AND actor = ?")(
            realm, request.origin, request.sequence, request.cursor, request.ordinal, request.actor) == 1;
    }

    void preparePlayerSummons()
    {
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_player_summons ("
            ~ "player INT UNSIGNED NOT NULL PRIMARY KEY, state MEDIUMTEXT CHARACTER SET ascii NOT NULL) ENGINE=InnoDB")();
    }

    string loadPlayerSummons(uint player)
    {
        const rows = characters.query!"SELECT state FROM dmangos_player_summons WHERE player = ?"(player);
        return rows.length ? rows[0].get!string(0) : null;
    }

    void savePlayerSummons(uint player, string state)
    {
        if (state.length)
            characters.execute!("INSERT INTO dmangos_player_summons (player, state) VALUES (?, ?) "
                ~ "ON DUPLICATE KEY UPDATE state = VALUES(state)")(player, state);
        else
            characters.execute!"DELETE FROM dmangos_player_summons WHERE player = ?"(player);
    }

    void prepareGmSessions()
    {
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_gm_session ("
            ~ "player INT UNSIGNED NOT NULL PRIMARY KEY, state TEXT CHARACTER SET ascii NOT NULL) ENGINE=InnoDB")();
    }

    string loadGmSession(uint player)
    {
        const rows = characters.query!"SELECT state FROM dmangos_gm_session WHERE player = ?"(player);
        return rows.length ? rows[0].get!string(0) : null;
    }

    void saveGmSession(uint player, string state)
    {
        if (state.length)
            characters.execute!("INSERT INTO dmangos_gm_session (player, state) VALUES (?, ?) "
                ~ "ON DUPLICATE KEY UPDATE state = VALUES(state)")(player, state);
        else
            characters.execute!"DELETE FROM dmangos_gm_session WHERE player = ?"(player);
    }

    void preparePartySummonOffers()
    {
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_party_summon_offer ("
            ~ "player INT UNSIGNED NOT NULL PRIMARY KEY, sequence BIGINT UNSIGNED NOT NULL, "
            ~ "state TEXT CHARACTER SET ascii NOT NULL) ENGINE=InnoDB")();
    }

    imported!"dmangos.world.database".PartySummonCheckpoint loadPartySummonOffer(uint player)
    {
        import dmangos.world.database : PartySummonCheckpoint;

        const rows = characters.query!"SELECT sequence, state FROM dmangos_party_summon_offer WHERE player = ?"(player);
        return rows.length ? PartySummonCheckpoint(rows[0].get!ulong(0), rows[0].get!string(1))
            : PartySummonCheckpoint.init;
    }

    bool publishPartySummonOffer(uint player, ulong sequence, string state)
    {
        return characters.execute!("INSERT INTO dmangos_party_summon_offer (player, sequence, state) VALUES (?, ?, ?) "
            ~ "ON DUPLICATE KEY UPDATE state = IF(sequence < VALUES(sequence), VALUES(state), state), "
            ~ "sequence = GREATEST(sequence, VALUES(sequence))")(player, sequence, state) != 0;
    }

    bool consumePartySummonOffer(uint player, ulong sequence)
    {
        return characters.execute!("UPDATE dmangos_party_summon_offer SET state = '' "
            ~ "WHERE player = ? AND sequence = ? AND state <> ''")(player, sequence) == 1;
    }

    void deletePartySummonOffer(uint player)
    {
        characters.execute!"DELETE FROM dmangos_party_summon_offer WHERE player = ?"(player);
    }

    /// See `WorldDatabase.deleteInstance`.
    void deleteInstance(uint id)
    {
        characters.execute!"DELETE FROM instance WHERE id = ?"(id);
        characters.execute!"DELETE FROM character_instance WHERE instance = ?"(id);
        characters.execute!"DELETE FROM group_instance WHERE instance = ?"(id);
        characters.execute!"DELETE FROM creature_respawn WHERE instance = ?"(id);
        characters.execute!"DELETE FROM gameobject_respawn WHERE instance = ?"(id);
        characters.execute!"DELETE FROM dmangos_instance_chest WHERE instance = ?"(id);
        characters.execute!"DELETE FROM dmangos_instance_corpse WHERE instance = ?"(id);
        characters.execute!"DELETE FROM dmangos_pickpocket WHERE instance = ?"(id);
        characters.execute!"DELETE FROM dmangos_dungeon_fight WHERE instance = ?"(id);
    }

    /// See `WorldDatabase.saveInstanceBind`.
    void saveInstanceBind(bool group, uint owner, uint instance, bool permanent)
    {
        if (group)
            characters.execute!"REPLACE INTO group_instance (leaderGuid, instance, permanent) VALUES (?, ?, ?)"(owner,
                instance, permanent ? 1 : 0);
        else
            characters.execute!"REPLACE INTO character_instance (guid, instance, permanent) VALUES (?, ?, ?)"(owner,
                instance, permanent ? 1 : 0);
    }

    /// See `WorldDatabase.deleteInstanceBind`.
    void deleteInstanceBind(uint guid, uint instance)
    {
        characters.execute!"DELETE FROM character_instance WHERE guid = ? AND instance = ?"(guid, instance);
    }

    /// See `WorldDatabase.deleteInstanceRespawn`.
    void deleteInstanceRespawn(uint spawnGuid, uint instance)
    {
        characters.execute!"DELETE FROM creature_respawn WHERE guid = ? AND instance = ?"(spawnGuid, instance);
    }

    /// See `WorldDatabase.saveInstanceRespawn`.
    void saveInstanceRespawn(bool gameObject, uint spawnGuid, uint instance, long until)
    {
        if (gameObject)
            characters.execute!"REPLACE INTO gameobject_respawn (guid, respawntime, instance) VALUES (?, ?, ?)"(spawnGuid,
                until, instance);
        else
            characters.transaction({
                characters.execute!"REPLACE INTO creature_respawn (guid, respawntime, instance) VALUES (?, ?, ?)"(
                    spawnGuid, until, instance);
                deletePickpocket(instance, spawnGuid);
            });
    }

    /// See `WorldDatabase.loadCreatureRespawns`.
    long[uint] loadCreatureRespawns()
    {
        long[uint] all;
        foreach (row; characters.query!"SELECT guid, respawntime FROM creature_respawn WHERE instance = 0"())
            all[row.get!uint(0)] = row.get!long(1);
        return all;
    }

    /// The guid of the character called `name`, or 0.
    uint characterGuid(string name)
    {
        const rows = characters.query!"SELECT guid FROM characters WHERE name = ?"(name);
        return rows.length ? rows[0].get!uint(0) : 0;
    }

    /// `.character rename` for an offline character.
    /// See `WorldDatabase.renameGuild`.
    void renameGuild(uint guildId, string name)
    {
        characters.execute!"UPDATE guild SET name = ? WHERE guildid = ?"(name, guildId);
    }

    /// See `WorldDatabase.addAtLoginFlags`.
    void addAtLoginFlags(uint guid, uint flags)
    {
        characters.execute!"UPDATE characters SET at_login = at_login | ? WHERE guid = ?"(flags, guid);
    }

    void renameCharacter(uint guid, string newName)
    {
        // A rename asked for at login (`at_login` 1) is done with it.
        characters.execute!"UPDATE characters SET name = ?, at_login = at_login & ~1 WHERE guid = ?"(newName, guid);
    }

    /// See `WorldDatabase.saveGift`.
    void saveGift(uint owner, uint item, uint entry, uint flags)
    {
        characters.execute!"REPLACE INTO character_gifts (guid, item_guid, entry, flags) VALUES (?, ?, ?, ?)"(owner,
            item, entry, flags);
    }

    /// See `WorldDatabase.loadGift`.
    bool loadGift(uint item, out uint entry, out uint flags)
    {
        const rows = characters.query!"SELECT entry, flags FROM character_gifts WHERE item_guid = ?"(item);
        if (rows.length == 0)
            return false;
        entry = rows[0].get!uint(0);
        flags = rows[0].get!uint(1);
        return true;
    }

    /// See `WorldDatabase.deleteGift`.
    void deleteGift(uint item)
    {
        characters.execute!"DELETE FROM character_gifts WHERE item_guid = ?"(item);
    }

    /// See `WorldDatabase.loadRaidResets`.
    long[uint] loadRaidResets()
    {
        long[uint] found;
        foreach (row; characters.query!"SELECT mapid, resettime FROM instance_reset"())
            found[row.get!uint(0)] = row.get!long(1);
        return found;
    }

    /// See `WorldDatabase.saveRaidReset`.
    void saveRaidReset(uint map, long time)
    {
        characters.execute!"REPLACE INTO instance_reset (mapid, resettime) VALUES (?, ?)"(map, time);
    }

    /// See `WorldDatabase.savePetAuras`.
    void savePetAuras(uint pet, const(AuraRecord)[] auras)
    {
        characters.transaction({
            characters.execute!"DELETE FROM pet_aura WHERE guid = ?"(pet);
            foreach (ref a; auras)
                characters.execute!("INSERT IGNORE INTO pet_aura (guid, caster_guid, item_guid, spell, stackcount, "
                    ~ "remaincharges, basepoints0, basepoints1, basepoints2, periodictime0, periodictime1, periodictime2, "
                    ~ "maxduration, remaintime, effIndexMask) VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(pet,
                    a.caster, a.spell, a.stacks, a.charges, a.amount[0], a.amount[1], a.amount[2], a.periodTimer[0],
                    a.periodTimer[1], a.periodTimer[2], a.maxDuration, a.remaining, a.effectMask);
        });
    }

    /// See `WorldDatabase.loadPetAuras`.
    AuraRecord[] loadPetAuras(uint pet)
    {
        AuraRecord[] found;
        foreach (row; characters.query!("SELECT caster_guid, spell, stackcount, basepoints0, basepoints1, basepoints2, "
                ~ "periodictime0, periodictime1, periodictime2, maxduration, remaintime, effIndexMask, remaincharges "
                ~ "FROM pet_aura WHERE guid = ?")(pet))
            found ~= AuraRecord(row.get!ulong(0), row.get!uint(1), row.get!uint(2), [row.get!int(3), row.get!int(4),
                row.get!int(5)], [row.get!int(6), row.get!int(7), row.get!int(8)], row.get!int(9), row.get!int(10),
                row.get!uint(11), row.get!uint(12));
        return found;
    }

    /// See `WorldDatabase.savePetCooldowns`.
    void savePetCooldowns(uint pet, const(ulong[2])[] cooldowns)
    {
        characters.transaction({
            characters.execute!"DELETE FROM pet_spell_cooldown WHERE guid = ?"(pet);
            foreach (c; cooldowns)
                characters.execute!"INSERT IGNORE INTO pet_spell_cooldown (guid, spell, time) VALUES (?, ?, ?)"(pet,
                    cast(uint) c[0], c[1]);
        });
    }

    /// See `WorldDatabase.loadPetCooldowns`.
    ulong[2][] loadPetCooldowns(uint pet)
    {
        ulong[2][] found;
        foreach (row; characters.query!"SELECT spell, time FROM pet_spell_cooldown WHERE guid = ?"(pet))
            found ~= [ulong(row.get!uint(0)), row.get!ulong(1)];
        return found;
    }

    /// See `WorldDatabase.gameEventStatus`.
    ushort[] gameEventStatus()
    {
        ushort[] events;
        foreach (row; characters.query!"SELECT event FROM game_event_status"())
            events ~= cast(ushort) row.get!uint(0);
        return events;
    }

    /// See `WorldDatabase.setGameEventStatus`.
    void setGameEventStatus(ushort event, bool on)
    {
        if (on)
            characters.execute!"INSERT IGNORE INTO game_event_status (event) VALUES (?)"(event);
        else
            characters.execute!"DELETE FROM game_event_status WHERE event = ?"(event);
    }

    /// See `WorldDatabase.worldState`.
    string worldState(uint id)
    {
        foreach (row; characters.query!"SELECT Data FROM world_state WHERE Id = ?"(id))
            return row.isNull(0) ? null : row.get!string(0);
        return null;
    }

    /// See `WorldDatabase.saveWorldState`.
    void saveWorldState(uint id, string data)
    {
        characters.execute!"REPLACE INTO world_state (Id, Data) VALUES (?, ?)"(id, data);
    }

    private bool[ServiceKind] checkpointsReady;

    private template checkpointTable(ServiceKind kind)
    {
        static if (kind == ServiceKind.channels)
            enum checkpointTable = "dmangos_channel_checkpoint";
        else static if (kind == ServiceKind.battlegroundQueue)
            enum checkpointTable = "dmangos_bg_queue_checkpoint";
        else static if (kind == ServiceKind.weather)
            enum checkpointTable = "dmangos_weather_checkpoint";
        else static if (kind == ServiceKind.groupQueue)
            enum checkpointTable = "dmangos_group_checkpoint";
        else
            static assert(false, "unexpected checkpoint service");
    }

    private enum checkpointed = [ServiceKind.channels, ServiceKind.battlegroundQueue, ServiceKind.weather, ServiceKind.groupQueue];

    private void prepareServiceCheckpoints(ServiceKind kind)()
    {
        if (checkpointsReady.get(kind, false))
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS " ~ checkpointTable!kind ~ " ("
            ~ "realm INT UNSIGNED NOT NULL, revision BIGINT UNSIGNED NOT NULL, saved_at BIGINT NOT NULL, "
            ~ "node SMALLINT UNSIGNED NOT NULL, state LONGTEXT NOT NULL, PRIMARY KEY (realm)) ENGINE=InnoDB")();
        checkpointsReady[kind] = true;
    }

    ServiceCheckpoint loadServiceCheckpoint(ServiceKind kind, uint realm)
    {
        static foreach (candidate; checkpointed)
            if (kind == candidate)
            {
                prepareServiceCheckpoints!candidate();
                foreach (row; characters.query!("SELECT revision, saved_at, node, state FROM "
                    ~ checkpointTable!candidate ~ " WHERE realm = ?")(realm))
                    return ServiceCheckpoint(row.get!ulong(0), row.get!long(1), cast(ushort) row.get!uint(2),
                        row.get!string(3));
                return ServiceCheckpoint.init;
            }
        assert(0, "unexpected checkpoint service");
    }

    bool saveServiceCheckpoint(ServiceKind kind, uint realm, const ref ServiceCheckpoint checkpoint)
    {
        static foreach (candidate; checkpointed)
            if (kind == candidate)
            {
                prepareServiceCheckpoints!candidate();
                if (!checkpoint.revision)
                    return characters.execute!("INSERT IGNORE INTO " ~ checkpointTable!candidate
                        ~ " (realm, revision, saved_at, node, state) VALUES (?, 1, ?, ?, ?)")(
                            realm, checkpoint.at, checkpoint.node, checkpoint.state) == 1;
                return characters.execute!("UPDATE " ~ checkpointTable!candidate
                    ~ " SET revision = revision + 1, saved_at = ?, node = ?, state = ? WHERE realm = ? AND revision = ?")(
                        checkpoint.at, checkpoint.node, checkpoint.state, realm, checkpoint.revision) == 1;
            }
        assert(0, "unexpected checkpoint service");
    }

    private bool battlegroundCheckpointsReady;

    private void prepareBattlegroundCheckpoints()
    {
        if (battlegroundCheckpointsReady)
            return;
        characters.execute!"CREATE TABLE IF NOT EXISTS dmangos_bg_match_checkpoint (
            realm INT UNSIGNED NOT NULL, map INT UNSIGNED NOT NULL, instance INT UNSIGNED NOT NULL,
            revision BIGINT UNSIGNED NOT NULL, saved_at BIGINT NOT NULL,
            state LONGTEXT NOT NULL, PRIMARY KEY (realm, instance), KEY recent (realm, map, saved_at)
        ) ENGINE=InnoDB"();
        battlegroundCheckpointsReady = true;
    }

    BattlegroundCheckpoint[] loadBattlegroundCheckpoints(uint realm, uint map, long since)
    {
        prepareBattlegroundCheckpoints();
        BattlegroundCheckpoint[] matches;
        foreach (row; characters.query!"SELECT instance, revision, saved_at, state FROM dmangos_bg_match_checkpoint
            WHERE realm = ? AND map = ? AND state <> '' AND (saved_at >= ? OR state LIKE 'F:%')"(realm, map, since))
            matches ~= BattlegroundCheckpoint(row.get!uint(0), row.get!ulong(1), row.get!long(2), row.get!string(3));
        return matches;
    }

    bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint,
        const(BattlegroundEventReward)[] rewards)
    {
        if (!rewards.length)
            return saveBattlegroundCheckpoint(realm, map, checkpoint);
        prepareBattlegroundCheckpoints(); // before the transaction: a CREATE TABLE would commit it
        prepareBattlegroundRewards();
        bool saved;
        characters.transaction({
            // The rewards only with the checkpoint that records their objectives: a superseded owner writes neither.
            saved = saveBattlegroundCheckpoint(realm, map, checkpoint);
            if (!saved)
                return;
            foreach (ref reward; rewards)
                characters.execute!"INSERT IGNORE INTO dmangos_bg_event_reward (realm, instance, event, player, reward)
                    VALUES (?, ?, ?, ?, ?)"(reward.reward.realm, reward.reward.match, reward.event, reward.reward.player,
                        encodeBattleResult(cast(BattlegroundEventReward) reward));
        });
        return saved;
    }

    bool saveBattlegroundCheckpoint(uint realm, uint map, const ref BattlegroundCheckpoint checkpoint)
    {
        prepareBattlegroundCheckpoints();
        if (!checkpoint.revision)
            return characters.execute!"INSERT IGNORE INTO dmangos_bg_match_checkpoint
                (realm, map, instance, revision, saved_at, state) VALUES (?, ?, ?, 1, ?, ?)"(
                    realm, map, checkpoint.instance, checkpoint.at, checkpoint.state) == 1;
        return characters.execute!"UPDATE dmangos_bg_match_checkpoint
            SET revision = revision + 1, saved_at = ?, state = ?
            WHERE realm = ? AND map = ? AND instance = ? AND revision = ?"(
                checkpoint.at, checkpoint.state, realm, map, checkpoint.instance, checkpoint.revision) == 1;
    }

    private bool battlegroundRewardsReady;

    private void prepareBattlegroundRewards()
    {
        if (battlegroundRewardsReady)
            return;
        characters.execute!"CREATE TABLE IF NOT EXISTS dmangos_bg_result (
            realm INT UNSIGNED NOT NULL, instance INT UNSIGNED NOT NULL,
            winner TINYINT UNSIGNED NOT NULL, bracket TINYINT UNSIGNED NOT NULL, type TINYINT UNSIGNED NOT NULL,
            scores LONGTEXT NOT NULL, PRIMARY KEY (realm, instance)) ENGINE=InnoDB"();
        characters.execute!"CREATE TABLE IF NOT EXISTS dmangos_bg_reward (
            realm INT UNSIGNED NOT NULL, instance INT UNSIGNED NOT NULL, player INT UNSIGNED NOT NULL,
            reward TEXT NOT NULL, paid BOOLEAN NOT NULL DEFAULT FALSE,
            PRIMARY KEY (realm, instance, player), KEY pending (paid, player)) ENGINE=InnoDB"();
        // An objective's rewards during the match: a table of their own, so the final rewards' rows (one per player
        // and match) stay as they are.
        characters.execute!"CREATE TABLE IF NOT EXISTS dmangos_bg_event_reward (
            realm INT UNSIGNED NOT NULL, instance INT UNSIGNED NOT NULL, event BIGINT UNSIGNED NOT NULL,
            player INT UNSIGNED NOT NULL, reward TEXT NOT NULL, paid BOOLEAN NOT NULL DEFAULT FALSE,
            PRIMARY KEY (realm, instance, event, player), KEY pending (paid, player)) ENGINE=InnoDB"();
        battlegroundRewardsReady = true;
    }

    private static string encodeBattleResult(T)(T value)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.battlegroundstate : BattlegroundState;
        import std.base64 : Base64;

        ByteWriter bytes;
        auto writer = BattlegroundState(writer: &bytes);
        writer.transfer(value);
        return Base64.encode(bytes.data).idup;
    }

    bool publishBattlegroundResult(uint realm, uint match, const PvpStatsBattleground result,
        const(PvpStatsPlayer)[] scores, const(BattlegroundReward)[] rewards, bool keepStatistics)
    {
        prepareBattlegroundRewards();
        const encodedScores = encodeBattleResult(scores.dup);
        characters.transaction({
            if (!characters.execute!"INSERT IGNORE INTO dmangos_bg_result
                (realm, instance, winner, bracket, type, scores) VALUES (?, ?, ?, ?, ?, ?)"(
                    realm, match, result.winner, result.bracket, result.type, encodedScores))
                return;
            foreach (ref reward; rewards)
                characters.execute!"INSERT INTO dmangos_bg_reward (realm, instance, player, reward)
                    VALUES (?, ?, ?, ?)"(realm, match, reward.player, encodeBattleResult(cast(BattlegroundReward) reward));
            if (keepStatistics)
                savePvpStats(result, scores);
        });
        return true;
    }

    BattlegroundReward[] pendingBattlegroundRewards()
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.battlegroundstate : BattlegroundState;
        import std.base64 : Base64;

        prepareBattlegroundRewards();
        BattlegroundReward[] pending;
        foreach (row; characters.query!"SELECT reward FROM dmangos_bg_reward WHERE paid = FALSE ORDER BY realm, instance"())
        {
            auto bytes = ByteReader(Base64.decode(row.get!string(0)));
            auto reader = BattlegroundState(reader: &bytes);
            BattlegroundReward reward;
            reader.transfer(reward);
            pending ~= reward;
        }
        return pending;
    }

    BattlegroundEventReward[] pendingBattlegroundEventRewards()
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.battlegroundstate : BattlegroundState;
        import std.base64 : Base64;

        prepareBattlegroundRewards();
        BattlegroundEventReward[] pending;
        foreach (row; characters.query!"SELECT reward FROM dmangos_bg_event_reward WHERE paid = FALSE
            ORDER BY realm, instance, event"())
        {
            auto bytes = ByteReader(Base64.decode(row.get!string(0)));
            auto reader = BattlegroundState(reader: &bytes);
            BattlegroundEventReward reward;
            reader.transfer(reward);
            pending ~= reward;
        }
        return pending;
    }

    bool payBattlegroundEventReward(const ref BattlegroundEventReward reward, const ref BattlegroundPayment payment)
    {
        prepareBattlegroundRewards();
        bool applied;
        characters.transaction({
            applied = false;
            if (!characters.execute!"UPDATE dmangos_bg_event_reward SET paid = TRUE
                WHERE realm = ? AND instance = ? AND event = ? AND player = ? AND paid = FALSE"(
                    reward.reward.realm, reward.reward.match, reward.event, reward.reward.player))
                return;
            applied = true;
            writeBattlegroundPayment(reward.reward, payment);
        });
        return applied;
    }

    bool payBattlegroundReward(const ref BattlegroundReward reward, const ref BattlegroundPayment payment)
    {
        prepareBattlegroundRewards();
        bool applied;
        characters.transaction({
            if (!characters.execute!"UPDATE dmangos_bg_reward SET paid = TRUE
                WHERE realm = ? AND instance = ? AND player = ? AND paid = FALSE"(
                    reward.realm, reward.match, reward.player))
                return;
            applied = true; // also true if a retry finds that the first COMMIT took effect
            writeBattlegroundPayment(reward, payment);
        });
        return applied;
    }

    /// A reward's writes, in its receipt's transaction.
    private void writeBattlegroundPayment(const ref BattlegroundReward reward, const ref BattlegroundPayment payment)
    {
        {
            if (payment.quests.length)
                saveQuestStatus(reward.player, payment.quests);
            if (payment.inventory.length)
                saveInventory(reward.player, payment.money, payment.playerBytes, payment.inventory);
            if (payment.mail.id)
            {
                saveLooseItem(payment.mailedItem, reward.player);
                sendMailRecord(payment.mail);
            }
            saveReputation(reward.player, payment.reputation);
            if (reward.honor)
                characters.execute!"INSERT INTO character_honor_cp (guid, victim_type, victim, honor, date, type)
                    VALUES (?, 0, ?, ?, ?, 1)"(reward.player, reward.player, float(reward.honor), reward.honorDay);
        }
    }

    /// See `WorldDatabase.charactersFor`.
    uint[] charactersFor(uint raceMask, uint quest)
    {
        uint[] guids;
        if (quest)
            foreach (row; characters.query!("SELECT c.guid FROM characters c JOIN character_queststatus q ON q.guid = c.guid "
                ~ "WHERE (1 << (c.race - 1)) & ? AND q.quest = ? AND q.rewarded <> 0")(raceMask, quest))
                guids ~= row.get!uint(0);
        else
            foreach (row; characters.query!"SELECT guid FROM characters WHERE (1 << (race - 1)) & ?"(raceMask))
                guids ~= row.get!uint(0);
        return guids;
    }

    /// See `WorldDatabase.saveBugReport`.
    void saveBugReport(string type, string content)
    {
        characters.execute!"INSERT INTO bugreport (type, content) VALUES (?, ?)"(type, content);
    }

    /// See `WorldDatabase.saveAccountData`.
    void saveAccountData(bool perCharacter, uint owner, uint type, long time, const(ubyte)[] data)
    {
        if (perCharacter)
        {
            characters.execute!"DELETE FROM character_account_data WHERE guid = ? AND type = ?"(owner, type);
            if (data.length)
                characters.execute!"INSERT INTO character_account_data (guid, type, time, data) VALUES (?, ?, ?, ?)"(
                    owner, type, time, cast(const(char)[]) data);
        }
        else
        {
            characters.execute!"DELETE FROM account_data WHERE account = ? AND type = ?"(owner, type);
            if (data.length)
                characters.execute!"INSERT INTO account_data (account, type, time, data) VALUES (?, ?, ?, ?)"(
                    owner, type, time, cast(const(char)[]) data);
        }
    }

    /// See `WorldDatabase.accountData`.
    const(ubyte)[] accountData(bool perCharacter, uint owner, uint type)
    {
        auto rows = perCharacter
            ? characters.query!"SELECT data FROM character_account_data WHERE guid = ? AND type = ?"(owner, type)
            : characters.query!"SELECT data FROM account_data WHERE account = ? AND type = ?"(owner, type);
        foreach (row; rows)
            return cast(const(ubyte)[]) row.get!string(0);
        return null;
    }

    /// See `WorldDatabase.tickets`.
    TicketRecord[] tickets(bool all)
    {
        TicketRecord[] found;
        foreach (row; characters.query!("SELECT id, author_guid, author_name, level, mapid, x, y, z, text, created, "
            ~ "state FROM gm_tickets ORDER BY id")())
        {
            TicketRecord t;
            t.id = row.get!uint(0);
            t.player = row.get!uint(1);
            t.name = row.get!string(2);
            t.level = row.get!uint(3);
            t.map = row.get!uint(4);
            t.x = row.get!float(5);
            t.y = row.get!float(6);
            t.z = row.get!float(7);
            t.text = row.get!string(8);
            t.created = row.get!long(9);
            t.closed = row.get!uint(10) != 0;
            if (all || !t.closed)
                found ~= t;
        }
        return found;
    }

    /// See `WorldDatabase.addTicket`.
    uint addTicket(TicketRecord t)
    {
        characters.execute!("INSERT INTO gm_tickets (category, state, status, level, author_guid, author_name, mapid, "
            ~ "x, y, z, o, text, created, updated, seen) VALUES (0, 0, 0, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, 0)")(
            t.level, t.player, t.name, t.map, t.x, t.y, t.z, t.text, t.created, t.created);
        foreach (row; characters.query!"SELECT LAST_INSERT_ID()"())
            return row.get!uint(0);
        return 0;
    }

    /// See `WorldDatabase.updateTicketText`.
    void updateTicketText(uint id, string text, long now)
    {
        characters.execute!"UPDATE gm_tickets SET text = ?, updated = ? WHERE id = ?"(text, now, id);
    }

    /// See `WorldDatabase.closeTicket`.
    void closeTicket(uint id)
    {
        characters.execute!"UPDATE gm_tickets SET state = 1 WHERE id = ?"(id);
    }

    /// See `WorldDatabase.deleteTicket`.
    void deleteTicket(uint id)
    {
        characters.execute!"DELETE FROM gm_tickets WHERE id = ?"(id);
    }

    /// See `WorldDatabase.moveOfflineCharacter`.
    void moveOfflineCharacter(uint guid, uint map, float x, float y, float z, uint zone)
    {
        characters.execute!("UPDATE characters SET map = ?, position_x = ?, position_y = ?, position_z = ?, zone = ? "
            ~ "WHERE guid = ?")(map, x, y, z, zone, guid);
    }

    /// Saves one known spell.
    void saveSpell(uint guid, uint spell, bool active, bool disabled)
    {
        deleteSpell(guid, spell);
        characters.execute!"INSERT INTO character_spell (guid, spell, active, disabled) VALUES (?, ?, ?, ?)"(
            guid, spell, active, disabled);
    }

    /// Deletes a spell no longer known.
    void deleteSpell(uint guid, uint spell)
    {
        characters.execute!"DELETE FROM character_spell WHERE guid = ? AND spell = ?"(guid, spell);
    }

    /// Saves one skill; a `max` of 0 deletes it.
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

    /// Saves one action button. An action of 0 removes the button.
    void setActionButton(uint guid, ubyte button, uint action, ubyte type)
    {
        characters.execute!"DELETE FROM character_action WHERE guid = ? AND button = ?"(guid, button);
        if (action != 0)
            characters.execute!"INSERT INTO character_action (guid, button, action, type) VALUES (?, ?, ?, ?)"(
                guid, button, action, type);
    }

    /// Saves the account's tutorial flags.
    void saveTutorials(uint accountId, const uint[tutorialFields] t)
    {
        characters.execute!("UPDATE character_tutorial SET tut0 = ?, tut1 = ?, tut2 = ?, tut3 = ?, tut4 = ?, "
            ~ "tut5 = ?, tut6 = ?, tut7 = ? WHERE account = ?")(t[0], t[1], t[2], t[3], t[4], t[5], t[6], t[7],
            accountId);
    }

    /// Every group with its members, and the names of both.
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

    private bool groupLootTurnsReady;

    private void prepareGroupLootTurns()
    {
        if (groupLootTurnsReady)
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_group_loot_turn ("
            ~ "id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, group_id INT UNSIGNED NOT NULL, "
            ~ "node SMALLINT UNSIGNED NOT NULL, drop_token BIGINT UNSIGNED NOT NULL, assigned BIGINT UNSIGNED NOT NULL, "
            ~ "next_looter BIGINT UNSIGNED NOT NULL, member_order VARCHAR(448) NOT NULL, recorded_at BIGINT NOT NULL, PRIMARY KEY (id), "
            ~ "UNIQUE KEY drop_identity (group_id, node, drop_token), KEY group_order (group_id, id), "
            ~ "KEY group_expiry (group_id, recorded_at)) ENGINE=InnoDB")();
        groupLootTurnsReady = true;
    }

    GroupLootRotation loadGroupLootRotation(uint group, ushort node, ulong drop)
    {
        import dmangos.plaindata : decode;
        import std.base64 : Base64;

        prepareGroupLootTurns();
        foreach (row; characters.query!("SELECT next_looter, assigned FROM dmangos_group_loot_turn "
            ~ "WHERE group_id = ? AND node = ? AND drop_token = ?")(group, node, drop))
            return GroupLootRotation(row.get!ulong(0), row.get!ulong(1));
        foreach (row; characters.query!("SELECT next_looter, member_order FROM dmangos_group_loot_turn WHERE group_id = ? "
            ~ "ORDER BY id DESC LIMIT 1")(group))
        {
            const(ubyte)[] bytes = Base64.decode(row.get!string(1));
            ulong[] order;
            decode(bytes, order);
            return GroupLootRotation(row.get!ulong(0), 0, order);
        }
        return GroupLootRotation.init;
    }

    bool recordGroupLootRotation(uint group, ushort node, ulong drop, const ref GroupLootRotation turn, long now)
    {
        import dmangos.plaindata : encode;
        import std.base64 : Base64;

        prepareGroupLootTurns();
        ubyte[] bytes;
        encode(bytes, turn.order);
        const order = Base64.encode(bytes).idup;
        bool saved;
        characters.transaction({
            saved = characters.execute!("INSERT IGNORE INTO dmangos_group_loot_turn "
                ~ "(group_id, node, drop_token, assigned, next_looter, member_order, recorded_at) "
                ~ "SELECT groupId, ?, ?, ?, ?, ?, ? FROM `groups` WHERE groupId = ?")(
                    node, drop, turn.assigned, turn.nextLooter, order, now, group) == 1;
            if (saved)
                characters.execute!("DELETE FROM dmangos_group_loot_turn WHERE group_id = ? AND recorded_at < ?")(
                    group, now - 120);
        });
        return saved;
    }

    private bool lootCoinsReady;

    private void prepareLootCoins()
    {
        if (lootCoinsReady)
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_loot_coin ("
            ~ "issuer SMALLINT UNSIGNED NOT NULL, token BIGINT UNSIGNED NOT NULL, player INT UNSIGNED NOT NULL, "
            ~ "copper INT UNSIGNED NOT NULL, paid_at BIGINT NOT NULL DEFAULT 0, PRIMARY KEY (issuer, token, player), "
            ~ "KEY pending_player (player, paid_at), KEY paid_at (paid_at, player)) ENGINE=InnoDB")();
        lootCoinsReady = true;
    }

    bool saveLootCoinSplit(ushort issuer, ulong token, const(LootCoinCredit)[] shares)
    {
        if (!issuer || !token || !shares.length)
            return false;
        prepareLootCoins();
        characters.transaction({
            foreach (ref share; shares)
                if (share.copper)
                    characters.execute!("INSERT IGNORE INTO dmangos_loot_coin (issuer, token, player, copper) "
                        ~ "SELECT ?, ?, guid, ? FROM characters WHERE guid = ? AND account <> 0")(
                            issuer, token, share.copper, share.player);
        });
        return true;
    }

    uint[] pendingLootCoinPlayers()
    {
        prepareLootCoins();
        return characters.query!"SELECT DISTINCT player FROM dmangos_loot_coin WHERE paid_at = 0"()
            .map!(row => row.get!uint(0)).array;
    }

    LootCoinRedemption redeemLootCoins(uint player, uint wallet, long now)
    {
        import dmangos.world.money : Copper;

        prepareLootCoins();
        LootCoinRedemption result;
        characters.transaction({
            // The live wallet, not `characters.money`: spending the session has not saved yet stays spent.
            if (!characters.query!"SELECT guid FROM characters WHERE guid = ? AND account <> 0 FOR UPDATE"(player).length)
                return;
            Copper coins;
            foreach (row; characters.query!("SELECT copper FROM dmangos_loot_coin WHERE player = ? "
                ~ "AND paid_at = 0 FOR UPDATE")(player))
                coins = coins + Copper(row.get!uint(0));
            const money = (Copper(wallet) + coins).amount;
            if (coins)
            {
                characters.execute!"UPDATE characters SET money = ? WHERE guid = ?"(money, player);
                characters.execute!"UPDATE dmangos_loot_coin SET paid_at = ? WHERE player = ? AND paid_at = 0"(now, player);
            }
            result = LootCoinRedemption(true, money, coins.amount);
        });
        return result;
    }

    private bool lootAwardsReady;

    void prepareLootAwards()
    {
        if (lootAwardsReady)
            return;
        characters.execute!("CREATE TABLE IF NOT EXISTS dmangos_loot_award ("
            ~ "token BIGINT UNSIGNED NOT NULL, loot BIGINT UNSIGNED NOT NULL, map_id INT UNSIGNED NOT NULL, "
            ~ "slot TINYINT UNSIGNED NOT NULL, player INT UNSIGNED NOT NULL, result TINYINT UNSIGNED NOT NULL, "
            ~ "recorded_at BIGINT NOT NULL, PRIMARY KEY (token, loot, map_id, slot, player), "
            ~ "KEY player_age (player, recorded_at)) ENGINE=InnoDB")();
        lootAwardsReady = true;
    }

    LootAwardResult loadLootAward(const ref LootAwardKey key)
    {
        prepareLootAwards();
        const rows = characters.query!("SELECT result FROM dmangos_loot_award "
            ~ "WHERE token = ? AND loot = ? AND map_id = ? AND slot = ? AND player = ?")(
                key.token, key.loot, key.map, key.slot, key.player);
        return rows.length ? LootAwardResult(true, rows[0].get!ubyte(0)) : LootAwardResult.init;
    }

    bool claimLootAward(const ref LootAwardKey key, long now)
    {
        prepareLootAwards();
        return characters.execute!("INSERT IGNORE INTO dmangos_loot_award "
            ~ "(token, loot, map_id, slot, player, result, recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?)")(
                key.token, key.loot, key.map, key.slot, key.player, lootAwardClaimed, now) != 0;
    }

    void expireLootAward(const ref LootAwardKey key, long now)
    {
        import dmangos.world.inventory : InventoryResult;

        prepareLootAwards();
        characters.transaction({
            characters.execute!("INSERT IGNORE INTO dmangos_loot_award "
                ~ "(token, loot, map_id, slot, player, result, recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?)")(
                    key.token, key.loot, key.map, key.slot, key.player, InventoryResult.itemNotFound, now);
            characters.execute!("UPDATE dmangos_loot_award SET result = ?, recorded_at = ? "
                ~ "WHERE token = ? AND loot = ? AND map_id = ? AND slot = ? AND player = ? AND result = ? "
                ~ "AND recorded_at <= ?")(InventoryResult.itemNotFound, now, key.token, key.loot, key.map, key.slot,
                    key.player, lootAwardClaimed, now - lootAwardClaimSeconds);
        });
    }

    void saveLootAward(const ref LootAwardKey key, ubyte result, long now, uint money, uint playerBytes2,
        const(ItemChange)[] changes)
    {
        prepareLootAwards();
        characters.transaction({
            if (result)
            {
                // A refusal: where nothing is recorded, or over the recipient's own claim.
                characters.execute!("INSERT IGNORE INTO dmangos_loot_award "
                    ~ "(token, loot, map_id, slot, player, result, recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?)")(
                        key.token, key.loot, key.map, key.slot, key.player, result, now);
                characters.execute!("UPDATE dmangos_loot_award SET result = ?, recorded_at = ? "
                    ~ "WHERE token = ? AND loot = ? AND map_id = ? AND slot = ? AND player = ? AND result = ?")(
                        result, now, key.token, key.loot, key.map, key.slot, key.player, lootAwardClaimed);
                return;
            }
            // Stored: the claim turns into stored together with the item's rows, or neither is written (the loot's
            // node expired the claim meanwhile).
            if (characters.execute!("UPDATE dmangos_loot_award SET result = 0, recorded_at = ? "
                ~ "WHERE token = ? AND loot = ? AND map_id = ? AND slot = ? AND player = ? AND result = ?")(
                    now, key.token, key.loot, key.map, key.slot, key.player, lootAwardClaimed) == 1)
                saveInventory(key.player, money, playerBytes2, changes);
        });
    }

    /// Saves a new group with its members.
    void createGroup(const ref GroupRecord g)
    {
        prepareGroupLootTurns();
        characters.transaction({
            characters.execute!"DELETE FROM `groups` WHERE groupId = ?"(g.id);
            characters.execute!"DELETE FROM group_member WHERE groupId = ?"(g.id);
            characters.execute!"DELETE FROM dmangos_group_loot_turn WHERE group_id = ?"(g.id);
            characters.execute!("INSERT INTO `groups` (groupId, leaderGuid, mainTank, mainAssistant, lootMethod, "
                ~ "looterGuid, lootThreshold, icon1, icon2, icon3, icon4, icon5, icon6, icon7, icon8, isRaid) "
                ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(g.id, g.leader, g.mainTank,
                g.mainAssistant, g.lootMethod, g.looter, g.lootThreshold, g.icons[0], g.icons[1], g.icons[2],
                g.icons[3], g.icons[4], g.icons[5], g.icons[6], g.icons[7], g.isRaid ? 1 : 0);
        });
    }

    /// The `groups` columns that change after creation (leader, raid, loot method, ...).
    void updateGroup(const ref GroupRecord g)
    {
        characters.execute!("UPDATE `groups` SET leaderGuid = ?, mainTank = ?, mainAssistant = ?, lootMethod = ?, "
            ~ "looterGuid = ?, lootThreshold = ?, isRaid = ? WHERE groupId = ?")(g.leader, g.mainTank, g.mainAssistant,
            g.lootMethod, g.looter, g.lootThreshold, g.isRaid ? 1 : 0, g.id);
    }

    /// Deletes a disbanded group and its members.
    void deleteGroup(uint groupId)
    {
        prepareGroupLootTurns();
        characters.transaction({
            characters.execute!"DELETE FROM `groups` WHERE groupId = ?"(groupId);
            characters.execute!"DELETE FROM group_member WHERE groupId = ?"(groupId);
            characters.execute!"DELETE FROM dmangos_group_loot_turn WHERE group_id = ?"(groupId);
        });
    }

    /// Adds a member to a group.
    void addGroupMember(uint groupId, const GroupMemberRecord m)
    {
        characters.execute!"INSERT INTO group_member (groupId, memberGuid, assistant, subgroup) VALUES (?, ?, ?, ?)"(
            groupId, m.guid, m.assistant ? 1 : 0, m.subGroup);
    }

    /// A member's assistant flag and subgroup.
    void updateGroupMember(const GroupMemberRecord m)
    {
        characters.execute!"UPDATE group_member SET assistant = ?, subgroup = ? WHERE memberGuid = ?"(
            m.assistant ? 1 : 0, m.subGroup, m.guid);
    }

    /// Removes a member from its group.
    void removeGroupMember(uint guid)
    {
        characters.execute!"DELETE FROM group_member WHERE memberGuid = ?"(guid);
    }

    /// A character's name, race, gender and class, for a name query; null if there is no such character.
    Nullable!NameInfo nameInfo(uint guid)
    {
        auto rows = characters.queryAs!(NameInfo, "SELECT name, race, gender, class FROM characters WHERE guid = ?")(
            guid);
        return rows.length ? nullable(rows[0]) : Nullable!NameInfo.init;
    }

    /// The account's character count on this realm, in the login database's `realmcharacters`.
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

    /// Whether the character leads a guild.
    bool isGuildLeader(uint guid)
    {
        return characters.query!"SELECT 1 FROM guild WHERE leaderguid = ?"(guid).length > 0;
    }

    /// Deletes a character (or, with method 1, unlinks it to be restored). `nextMailId` allocates ids
    /// for returned mail.
    void deleteCharacter(uint guid, uint accountId, DeleteOptions options, uint delegate() nextMailId)
    {
        uint method = options.method;
        const level = characters.query!"SELECT level FROM characters WHERE guid = ?"(guid);
        if (level.length == 0 || level[0].get!uint(0) < options.minLevel)
            method = 0;

        commitGuildChange((ulong) => leaveGuild(guid));
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
        prepareLootCoins();
        prepareLootAwards();
        prepareBattlegroundRewards();
        prepareGmSessions();
        const pets = characters.query!"SELECT id FROM character_pet WHERE owner = ?"(guid)
            .map!(row => row.get!uint(0)).array;

        characters.transaction({
            characters.execute!"DELETE FROM dmangos_script_credit WHERE player = ?"(guid);
            characters.execute!"DELETE FROM dmangos_loot_coin WHERE player = ?"(guid);
            characters.execute!"DELETE FROM dmangos_loot_award WHERE player = ?"(guid);
            // An unpaid battleground reward goes with its character: a new one given the same guid gets none of it.
            characters.execute!"DELETE FROM dmangos_bg_reward WHERE player = ?"(guid);
            characters.execute!"DELETE FROM dmangos_bg_event_reward WHERE player = ?"(guid);
            savePlayerSummons(guid, null);
            deletePartySummonOffer(guid);
            saveGmSession(guid, null);
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

    /// Removes the character from its guild, disbanding the guild if it is left empty.
    private bool leaveGuild(uint guid)
    {
        const rows = characters.query!"SELECT guildid FROM guild_member WHERE guid = ?"(guid);
        if (rows.length == 0)
            return false;
        const guildId = rows[0].get!uint(0);
        characters.execute!"DELETE FROM guild_member WHERE guid = ?"(guid);
        const remaining = characters.query!("SELECT guid FROM guild_member WHERE guildid = ? "
            ~ "ORDER BY `rank`, guid LIMIT 1")(guildId);
        if (!remaining.length)
        {
            characters.transaction({
                characters.execute!"DELETE FROM guild WHERE guildid = ?"(guildId);
                characters.execute!"DELETE FROM guild_rank WHERE guildid = ?"(guildId);
                characters.execute!"DELETE FROM guild_eventlog WHERE guildid = ?"(guildId);
            });
            info!"guild %s disbanded: its last member was deleted"(guildId);
        }
        else
        {
            const next = remaining[0].get!uint(0);
            if (characters.execute!"UPDATE guild SET leaderguid = ? WHERE guildid = ? AND leaderguid = ?"(next, guildId, guid))
                characters.execute!"UPDATE guild_member SET `rank` = 0 WHERE guid = ? AND guildid = ?"(next, guildId);
        }
        return true;
    }

    /// An offline member leaves its group: leave, pass on the lead, or disband a two-person group.
    private void leaveGroup(uint guid)
    {
        const rows = characters.query!"SELECT groupId FROM group_member WHERE memberGuid = ?"(guid);
        if (rows.length == 0)
            return;
        const groupId = rows[0].get!uint(0);
        const members = characters.query!"SELECT memberGuid FROM group_member WHERE groupId = ?"(groupId)
            .map!(row => row.get!uint(0)).array;

        if (members.length <= 2)
            return deleteGroup(groupId);

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

    /// Deletes the character's petitions and its signatures on others.
    private void removePetitions(uint guid)
    {
        characters.execute!"DELETE FROM petition_sign WHERE playerguid = ?"(guid);
        characters.transaction({
            characters.execute!"DELETE FROM petition WHERE ownerguid = ?"(guid);
            characters.execute!"DELETE FROM petition_sign WHERE ownerguid = ?"(guid);
        });
    }

    /// The character's auctions are cancelled (bids refunded by mail), its own bids dropped.
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

    /// Mail with items still unpaid (COD) goes back to its senders.
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

    /// See `WorldDatabase.sendMail`.
    void sendMailRecord(const ref MailRecord m)
    {
        characters.transaction({
            characters.execute!("INSERT INTO mail (id, messageType, stationery, mailTemplateId, sender, receiver, "
                ~ "subject, itemTextId, has_items, expire_time, deliver_time, money, cod, checked) "
                ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(m.id, m.messageType, m.stationery, m.templateId,
                m.sender, m.receiver, m.subject, m.itemTextId, m.itemGuid ? 1 : 0, m.expireTime, m.deliverTime, m.money,
                m.cod, m.checked);
            if (m.itemGuid)
                characters.execute!("INSERT INTO mail_items (mail_id, item_guid, item_template, receiver) "
                    ~ "VALUES (?, ?, ?, ?)")(m.id, m.itemGuid, m.itemEntry, m.receiver);
        });
    }

    private enum mailColumns = "SELECT m.id, m.messageType, m.stationery, m.mailTemplateId, m.sender, m.receiver, "
        ~ "IFNULL(m.subject, ''), m.itemTextId, m.expire_time, m.deliver_time, m.money, m.cod, m.checked, "
        ~ "IFNULL(mi.item_guid, 0), IFNULL(mi.item_template, 0) FROM mail m LEFT JOIN mail_items mi ON mi.mail_id = m.id ";

    private static MailRecord mailOf(R)(R row)
    {
        return MailRecord(row.get!uint(0), cast(ubyte) row.get!uint(1), cast(ubyte) row.get!int(2), row.get!uint(3),
            row.get!uint(4), row.get!uint(5), row.get!string(6), row.get!uint(7), row.get!long(8), row.get!long(9),
            row.get!uint(10), row.get!uint(11), row.get!uint(12), row.get!uint(13), row.get!uint(14));
    }

    /// See `WorldDatabase.loadMail`.
    MailRecord[] loadMail(uint receiver)
    {
        MailRecord[] found;
        foreach (row; characters.query!(mailColumns ~ "WHERE m.receiver = ? ORDER BY m.id")(receiver))
            found ~= mailOf(row);
        return found;
    }

    /// See `WorldDatabase.mailById`.
    Nullable!MailRecord mailById(uint id)
    {
        const rows = characters.query!(mailColumns ~ "WHERE m.id = ?")(id);
        return rows.length ? Nullable!MailRecord(mailOf(rows[0])) : Nullable!MailRecord.init;
    }

    /// See `WorldDatabase.updateMail`.
    void updateMail(const ref MailRecord m)
    {
        characters.transaction({
            characters.execute!("UPDATE mail SET money = ?, cod = ?, checked = ?, has_items = ?, expire_time = ? WHERE id = ?")(m.money,
                m.cod, m.checked, m.itemGuid ? 1 : 0, m.expireTime, m.id);
            if (!m.itemGuid)
                characters.execute!"DELETE FROM mail_items WHERE mail_id = ?"(m.id);
        });
    }

    /// See `WorldDatabase.deleteMail`.
    void deleteMail(uint id)
    {
        characters.transaction({
            characters.execute!"DELETE FROM mail WHERE id = ?"(id);
            characters.execute!"DELETE FROM mail_items WHERE mail_id = ?"(id);
        });
    }

    /// See `WorldDatabase.expiredMail`.
    MailRecord[] expiredMail(long now)
    {
        MailRecord[] found;
        foreach (row; characters.query!(mailColumns ~ "WHERE m.expire_time < ? ORDER BY m.expire_time")(now))
            found ~= mailOf(row);
        return found;
    }

    /// See `WorldDatabase.deleteLooseItem`.
    void deleteLooseItem(uint guid)
    {
        characters.execute!"DELETE FROM item_instance WHERE guid = ?"(guid);
    }

    /// See `WorldDatabase.saveItemText`.
    void saveItemText(uint id, string text)
    {
        characters.execute!"REPLACE INTO item_text (id, text) VALUES (?, ?)"(id, text);
    }

    /// See `WorldDatabase.itemText`.
    string itemText(uint id)
    {
        const rows = characters.query!"SELECT IFNULL(text, '') FROM item_text WHERE id = ?"(id);
        return rows.length ? rows[0].get!string(0) : null;
    }

    /// See `WorldDatabase.saveLooseItem`.
    void saveLooseItem(const ref ItemRecord i, uint owner)
    {
        characters.execute!("REPLACE INTO item_instance (owner_guid, itemEntry, creatorGuid, giftCreatorGuid, count, "
            ~ "duration, charges, flags, enchantments, randomPropertyId, durability, itemTextId, guid) "
            ~ "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")(owner, i.entry, i.creator, i.giftCreator, i.count,
            i.duration, i.charges, i.flags, i.enchantments, i.randomPropertyId, i.durability, i.textId, i.guid);
    }

    /// See `WorldDatabase.looseItem`.
    Nullable!ItemRecord looseItem(uint guid)
    {
        const rows = characters.query!("SELECT itemEntry, creatorGuid, giftCreatorGuid, count, duration, charges, "
            ~ "flags, enchantments, randomPropertyId, durability, itemTextId FROM item_instance WHERE guid = ?")(guid);
        if (rows.length == 0)
            return Nullable!ItemRecord.init;
        auto r = rows[0];
        ItemRecord i;
        i.guid = guid;
        i.entry = r.get!uint(0);
        i.creator = r.get!uint(1);
        i.giftCreator = r.get!uint(2);
        i.count = r.get!uint(3);
        i.duration = r.get!uint(4);
        i.charges = r.get!string(5);
        i.flags = r.get!uint(6);
        i.enchantments = r.get!string(7);
        i.randomPropertyId = r.get!int(8);
        i.durability = r.get!uint(9);
        i.textId = r.get!uint(10);
        return Nullable!ItemRecord(i);
    }

    /// See `WorldDatabase.characterRaceAccount`.
    uint[2] characterRaceAccount(uint guid)
    {
        const rows = characters.query!"SELECT race, account FROM characters WHERE guid = ?"(guid);
        return rows.length ? [rows[0].get!uint(0), rows[0].get!uint(1)] : [0u, 0u];
    }

    /// Writes a letter with its items, delivered after `deliverDelay` seconds.
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
