/**
 * Static game data from the CMaNGOS world (`mangos`) database.
 *
 * As in CMaNGOS, everything is read into memory once at start-up. The
 * `playercreateinfo_*` tables go through the same filters as
 * `ObjectMgr::LoadPlayerInfo`, so a character gets exactly what mangosd
 * would give it.
 */
module dmangos.world.worlddata;

import std.random : Random;

import dmangos.log;
import dmangos.mysql : MySqlConnection;
import dmangos.world.clientdata : ClientData, maskOf, maxSkillStep, playableClassMask, playableRaceMask;
import dmangos.world.eventai : EventAiData;
import dmangos.world.reputation : Spillover;
import dmangos.world.creature : CreatureAddon, CreatureClassStats, CreatureSpawn, CreatureTemplate, classStatsKey,
    creatureTemplateQuery;
import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate, GameObjectType;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.motion : MotionType, WaypointNode, WaypointStore;
import dmangos.world.loot : lootColumns, lootRow, LootStore, LootStores;
import dmangos.world.npcdata : NpcData;
import dmangos.world.quests : QuestData, questQuery, QuestRow;
import dmangos.world.spells : SpellData;

/// The `item_template` fields the character screen and character creation use.
struct ItemTemplate
{
    uint entry;
    uint itemClass;
    uint subClass;
    uint displayId;
    uint flags;
    uint buyCount;
    ubyte inventoryType;
    uint allowableClass;
    uint allowableRace;
    uint requiredLevel;
    uint requiredSkill;
    uint requiredSkillRank;
    uint requiredSpell;
    uint requiredHonorRank;
    uint requiredReputationFaction;
    uint requiredReputationRank;
    int maxCount;
    uint stackable;
    uint containerSlots;
    int[5] spellCharges;
    uint[5] spellCategory;
    uint bonding;
    uint randomProperty;
    uint maxDurability;
    uint bagFamily;
    uint duration;
    ItemDetails details; /// what only `SMSG_ITEM_QUERY_SINGLE_RESPONSE` and stats use

    /// Shorthand for tests and the character screen: only looks.
    static ItemTemplate display(uint displayId, ubyte inventoryType) pure nothrow @safe
    {
        ItemTemplate item;
        item.displayId = displayId;
        item.inventoryType = inventoryType;
        item.stackable = 1;
        item.allowableClass = uint.max;
        item.allowableRace = uint.max;
        return item;
    }
}

/// One of an item's stat bonuses (`_ItemStat`).
struct ItemStat
{
    uint type;  /// `ItemModType`
    int value;
}

/// One of an item's damage ranges (`_Damage`).
struct ItemDamage
{
    float min = 0;
    float max = 0;
    uint school;
}

/// One of an item's spells (`_Spell`), apart from the charges and category kept in `ItemTemplate`.
struct ItemSpell
{
    uint id;
    uint trigger;
    int cooldown = -1;         /// -1: use the spell's own
    int categoryCooldown = -1; /// -1: use the spell's own
}

/// The rest of `item_template`.
struct ItemDetails
{
    string name;
    uint quality;
    uint buyPrice;
    uint sellPrice;
    uint itemLevel;
    uint requiredCityRank;
    ItemStat[10] stats;
    ItemDamage[5] damage;
    uint armor;
    uint[6] resistances; /// holy, fire, nature, frost, shadow, arcane
    uint delay;          /// milliseconds between swings
    uint ammoType;
    float rangedModRange = 0;
    ItemSpell[5] spells;
    string description;
    uint pageText;
    uint languageId;
    uint pageMaterial;
    uint startQuest;
    uint lockId;
    uint minMoneyLoot;      /// what opening it gives in money, from ...
    uint maxMoneyLoot;      /// ... to
    int material;
    uint sheath;
    uint block;
    uint itemSet;
    uint area;
    uint map;
}

/**
 * `item_template` columns read into `ItemDetails`, with the field each goes
 * to. Built at compile time; the loader below is generated from it.
 */
private enum string[2][] itemDetailColumns = () {
    import std.conv : to;

    string[2][] columns = [["name", "name"], ["Quality", "quality"], ["BuyPrice", "buyPrice"],
        ["SellPrice", "sellPrice"], ["ItemLevel", "itemLevel"], ["RequiredCityRank", "requiredCityRank"]];
    foreach (i; 0 .. 10)
        columns ~= [["stat_type" ~ to!string(i + 1), "stats[" ~ to!string(i) ~ "].type"],
            ["stat_value" ~ to!string(i + 1), "stats[" ~ to!string(i) ~ "].value"]];
    foreach (i; 0 .. 5)
        columns ~= [["dmg_min" ~ to!string(i + 1), "damage[" ~ to!string(i) ~ "].min"],
            ["dmg_max" ~ to!string(i + 1), "damage[" ~ to!string(i) ~ "].max"],
            ["dmg_type" ~ to!string(i + 1), "damage[" ~ to!string(i) ~ "].school"]];
    columns ~= ["armor", "armor"];
    foreach (i, school; ["holy", "fire", "nature", "frost", "shadow", "arcane"])
        columns ~= [school ~ "_res", "resistances[" ~ to!string(i) ~ "]"];
    columns ~= [["delay", "delay"], ["ammo_type", "ammoType"], ["RangedModRange", "rangedModRange"]];
    foreach (i; 0 .. 5)
        columns ~= [["spellid_" ~ to!string(i + 1), "spells[" ~ to!string(i) ~ "].id"],
            ["spelltrigger_" ~ to!string(i + 1), "spells[" ~ to!string(i) ~ "].trigger"],
            ["spellcooldown_" ~ to!string(i + 1), "spells[" ~ to!string(i) ~ "].cooldown"],
            ["spellcategorycooldown_" ~ to!string(i + 1), "spells[" ~ to!string(i) ~ "].categoryCooldown"]];
    columns ~= [["description", "description"], ["PageText", "pageText"], ["LanguageID", "languageId"],
        ["PageMaterial", "pageMaterial"], ["startquest", "startQuest"], ["lockid", "lockId"],
        ["minMoneyLoot", "minMoneyLoot"], ["maxMoneyLoot", "maxMoneyLoot"],
        ["Material", "material"], ["sheath", "sheath"], ["block", "block"], ["itemset", "itemSet"],
        ["area", "area"], ["Map", "map"]];
    return columns;
}();

/// The statement that reads `itemDetailColumns`, entry first.
private enum itemDetailQuery = () {
    import std.algorithm.iteration : map;
    import std.array : join;

    return "SELECT entry, " ~ itemDetailColumns.map!(column => column[0]).join(", ") ~ " FROM item_template";
}();

static assert(itemDetailColumns.length == 6 + 20 + 15 + 7 + 3 + 20 + 14);

/// `creature_model_info`: a model's size.
struct ModelInfo
{
    float boundingRadius = 0;
    float combatReach = 0;
    ubyte gender;
}

/// `PlayerCreateInfoItem`
struct CreateItem
{
    uint itemId;
    uint amount;
}

/// `SkillRaceClassInfo`-checked `playercreateinfo_skills` entry.
struct CreateSkill
{
    uint skillId;
    uint step;
}

/// `PlayerCreateInfoAction`
struct CreateAction
{
    ubyte button;
    uint action;
    ubyte type;
}

/// `player_levelstats`: strength, agility, stamina, intellect, spirit.
struct LevelStats
{
    uint[5] stats;
}

/// `player_classlevelstats`
struct ClassLevelStats
{
    uint baseHealth;
    uint baseMana;
}

/// `PlayerInfo`: everything a new character of one race and class starts with.
struct PlayerInfo
{
    uint map;
    uint zone;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
    CreateItem[] items;
    CreateSkill[] skills;
    uint[] spells;
    CreateAction[] actions;
    LevelStats[] levelStats; /// index = level - 1
}

/// Highest level the stats tables are read for (`MAX_LEVEL` for 1.12 data is 60; up to 255 accepted).
enum maxLevel = 255;

/// `areatrigger_teleport` (`AreaTrigger`): where an area trigger takes a player, and who may go.
struct AreaTriggerTeleport
{
    uint id;
    string name;
    uint requiredLevel;
    uint requiredItem;
    uint requiredItem2;
    uint requiredQuest;
    uint targetMap;
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
    string failedText;   /// `status_failed_text`, shown when a requirement is not met
    uint conditionId;
}

/// `game_tele`: a named place for `.tele`.
struct GameTele
{
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;
    uint map;
    string name;
}

/// The columns of `AreaTriggerTeleport`, as `ObjectMgr::LoadAreaTriggerTeleports` reads them.
enum areaTriggerTeleportQuery = "SELECT id, IFNULL(name, ''), required_level, required_item, required_item2, "
    ~ "required_quest_done, target_map, target_position_x, target_position_y, target_position_z, target_orientation, "
    ~ "IFNULL(status_failed_text, ''), condition_id FROM areatrigger_teleport";

/// The columns of `GameTele`, as `ObjectMgr::LoadGameTele` reads them.
enum gameTeleQuery = "SELECT position_x, position_y, position_z, orientation, map, name FROM game_tele ORDER BY id";

/// See the module documentation.
/// `GraveYardData`: a graveyard (`WorldSafeLocs.dbc`) for an area, zone or map, and for which team.
struct GraveyardLink
{
    uint safeLoc;
    uint team;   /// 0: both, otherwise ALLIANCE (469) or HORDE (67)
}

/// `GraveyardManager::GraveyardLinkKey`: an area or zone id (`GRAVEYARD_AREALINK`, 0) or a map id (`GRAVEYARD_MAPLINK`, 1).
uint graveyardLinkKey(uint location, uint linkKind) pure nothrow @nogc @safe
{
    return location | linkKind << 31;
}

/// `ReputationOnKillEntry`: what killing a creature does to two factions' reputations.
struct OnKillReputation
{
    uint[2] faction;
    int[2] maxStanding;    /// the rank it gives reputation up to
    bool[2] teamAward;     /// the faction's team gets half as much
    int[2] value;
    bool teamDependent;    /// the first for the Alliance only, the second for the Horde
}

/// `InstanceTemplate`'s ghost entrance: where on which map a ghost of an instance comes back out.
struct GhostEntrance
{
    int map = -1;
    float x = 0, y = 0;
}

final class WorldData
{
    ItemTemplate[uint] items;               /// by entry
    ubyte[uint] creatureFamilies;           /// `creature_template.Family`, by entry; every creature is present
    PlayerInfo[ushort] playerInfo;          /// by `raceClassKey`
    ClassLevelStats[][uint] classLevelStats; /// by class, index = level - 1
    bool[dstring] reservedNames;            /// lower-cased
    SpellData spells;
    uint[] xpForNextLevel;                  /// `player_xp_for_level`, index = level
    uint[uint] baseXp;                      /// `exploration_basexp`, by level (`ObjectMgr::GetBaseXP`)
    ModelInfo[uint] models;                 /// `creature_model_info`, by display id
    AreaTriggerTeleport[uint] areaTriggers; /// `areatrigger_teleport`, by trigger id
    GameTele[] teleports;                   /// `game_tele`, in id order
    bool[uint] taverns;                     /// `areatrigger_tavern`: the inns' area triggers

    CreatureTemplate[uint] creatureTemplates;       /// by entry
    GameObjectTemplate[uint] gameObjectTemplates;   /// by entry
    CreatureSpawn[] creatureSpawns;                 /// the spawns in the world now (pools chosen, events off)
    GameObjectSpawn[] gameObjectSpawns;             /// ditto
    size_t[][ulong][uint] creatureCells;            /// map -> cell key -> indexes into `creatureSpawns`
    size_t[][ulong][uint] gameObjectCells;          /// ditto, into `gameObjectSpawns`
    CreatureAddon[uint] creatureAddons;             /// `creature_addon`, by spawn guid
    CreatureAddon[uint] creatureTemplateAddons;     /// `creature_template_addon`, by entry
    uint[3][uint] creatureEquipment;                /// `creature_equip_template`: item entries, by id
    CreatureClassStats[uint] creatureClassStats;    /// by `classStatsKey`
    NpcData npcs;                                   /// gossip, texts, trainers, vendors
    LootStores loot;                                /// `creature_loot_template`, `reference_loot_template`
    QuestData quests;                               /// `quest_template` and who gives and takes back each
    GraveyardLink[][uint] graveyards;               /// `game_graveyard_zone`, by `graveyardLinkKey`
    GhostEntrance[uint] ghostEntrances;             /// `instance_template`'s ghost entrances, by instance map
    WaypointStore waypoints;                        /// `creature_movement` and `creature_movement_template`
    EventAiData eventAi;                            /// `creature_ai_scripts`, by creature entry
    OnKillReputation[uint] onKillReputation;        /// `creature_onkill_reputation`, by creature entry
    Spillover[uint] spillovers;                     /// `reputation_spillover_template`, by faction
    float[3][uint] reputationRates;                 /// `reputation_reward_rate`: quest, kill, spell rates by faction

    ///
    this()
    {
        npcs = new NpcData;
        waypoints = new WaypointStore;
        quests = new QuestData;
        eventAi = new EventAiData;
        loot = LootStores(new LootStore("creature_loot_template"), new LootStore("reference_loot_template"),
            new LootStore("gameobject_loot_template"), new LootStore("item_loot_template"));
    }

    /**
     * `ObjectMgr::GetMapEntranceTrigger`: a trigger that leads into `map` from another map, whose
     * requirements are those of entering the map.
     */
    const(AreaTriggerTeleport)* mapEntranceTrigger(uint map, const ClientData client) const
    {
        foreach (id, ref trigger; areaTriggers)
            if (trigger.targetMap == map)
                if (const entry = client.areaTriggers.lookup(id))
                    if (entry.mapId != map)
                        return &trigger;
        return null;
    }

    /**
     * `ObjectMgr::GetGameTele`: the place called `name` (any case), or else the first whose name
     * contains it; null if none.
     */
    const(GameTele)* findTeleport(string name) const
    {
        import std.algorithm.searching : canFind;
        import std.uni : toLower;

        const wanted = name.toLower;
        const(GameTele)* partial;
        foreach (ref tele; teleports)
        {
            const lowered = tele.name.toLower;
            if (lowered == wanted)
                return &tele;
            if (partial is null && lowered.canFind(wanted))
                partial = &tele;
        }
        return partial;
    }

    /// `ObjectMgr::GetXPForLevel`
    uint xpForLevel(uint level) const
    {
        return level < xpForNextLevel.length ? xpForNextLevel[level] : 0;
    }

    /// Key into `playerInfo`.
    static ushort raceClassKey(ubyte race, ubyte classId) pure nothrow @nogc @safe
    {
        return cast(ushort)(race << 8 | classId);
    }

    /// Whether a character of this race and class may exist (`GetPlayerInfo` is not null).
    bool isValidRaceClass(ubyte race, ubyte classId) const
    {
        return (raceClassKey(race, classId) in playerInfo) !is null;
    }

    /// `GetPlayerInfo`
    const(PlayerInfo)* createInfo(ubyte race, ubyte classId) const
    {
        return raceClassKey(race, classId) in playerInfo;
    }

    /// `GetPlayerLevelInfo`: stats for a level, falling back to the highest level known.
    LevelStats levelStats(ubyte race, ubyte classId, uint level) const
    {
        import std.algorithm.comparison : min;

        if (auto player = createInfo(race, classId))
        {
            if (player.levelStats.length == 0 || level == 0)
                return LevelStats.init;
            return player.levelStats[min(level, player.levelStats.length) - 1];
        }
        return LevelStats.init;
    }

    /// `GetPlayerClassLevelInfo`
    ClassLevelStats classStats(ubyte classId, uint level) const
    {
        import std.algorithm.comparison : min;

        const table = classLevelStats.get(classId, null);
        if (table.length == 0 || level == 0)
            return ClassLevelStats.init;
        return table[min(level, table.length) - 1];
    }

    /// Reads the tables from a world database. `client` is needed to validate create skills.
    static WorldData load(MySqlConnection world, const ClientData client, ulong spawnSeed = 0)
    {
        auto data = new WorldData;
        data.spells = SpellData.load(world, client);

        foreach (row; world.queryAs!(ItemRow, "SELECT entry, class, subclass, displayid, Flags, BuyCount, "
            ~ "InventoryType, AllowableClass, AllowableRace, RequiredLevel, RequiredSkill, RequiredSkillRank, "
            ~ "requiredspell, requiredhonorrank, RequiredReputationFaction, RequiredReputationRank, maxcount, "
            ~ "stackable, ContainerSlots, spellcharges_1, spellcharges_2, spellcharges_3, spellcharges_4, "
            ~ "spellcharges_5, spellcategory_1, spellcategory_2, spellcategory_3, spellcategory_4, spellcategory_5, "
            ~ "bonding, RandomProperty, MaxDurability, BagFamily, Duration FROM item_template")())
        {
            auto item = row.toTemplate();
            // ObjectMgr::LoadItemPrototypes: every stack holds 1 to 255.
            if (item.stackable == 0 || item.stackable > 255)
            {
                const fixed = item.stackable == 0 ? 1 : 255;
                warning!"item %s has wrong value in stackable (%s), replaced by %s"(item.entry, item.stackable, fixed);
                item.stackable = fixed;
            }
            data.items[row.entry] = item;
        }
        foreach (row; world.query!itemDetailQuery())
            if (auto item = row.get!uint(0) in data.items)
                static foreach (i, column; itemDetailColumns)
                    mixin("item.details." ~ column[1]) = row.get!(typeof(mixin("item.details." ~ column[1])))(i + 1);
        foreach (row; world.query!"SELECT lvl, xp_for_next_level FROM player_xp_for_level"())
        {
            const level = row.get!uint(0);
            if (level == 0 || level > maxLevel)
                continue;
            if (data.xpForNextLevel.length <= level)
                data.xpForNextLevel.length = level + 1;
            data.xpForNextLevel[level] = row.get!uint(1);
        }
        foreach (row; world.query!"SELECT level, basexp FROM exploration_basexp"())
            data.baseXp[row.get!uint(0)] = row.get!uint(1);
        foreach (row; world.query!"SELECT modelid, bounding_radius, combat_reach, gender FROM creature_model_info"())
            data.models[row.get!uint(0)] = ModelInfo(row.get!float(1), row.get!float(2), cast(ubyte) row.get!uint(3));
        foreach (row; world.query!"SELECT Entry, Family FROM creature_template"())
            data.creatureFamilies[row.get!uint(0)] = cast(ubyte) row.get!int(1);
        foreach (row; world.query!"SELECT name FROM reserved_name"())
            data.reservedNames[toLowerName(row.get!string(0))] = true;

        data.npcs = NpcData.load(world, data.spells);
        data.loadTeleports(world, client);
        data.loadSpawns(world, client, spawnSeed);
        data.loadWaypoints(world);
        data.loadPlayerInfo(world, client);
        data.eventAi = EventAiData.load(world);
        info!"loaded %s item templates, %s creature templates, %s race/class combinations, %s reserved names"(
            data.items.length, data.creatureFamilies.length, data.playerInfo.length, data.reservedNames.length);
        if (data.playerInfo.length == 0)
            warning!("playercreateinfo is empty: no character can be listed or created "
                ~ "(is the world database populated?)")();
        return data;
    }

    /**
     * `ObjectMgr::LoadCreatureTemplates`, `LoadCreatures`, `LoadGameObjectTemplate`, `LoadGameObjects`,
     * and what decides which spawns are in the world: pools (`PoolManager`, one choice per start-up) and
     * game events (spawns that only exist during an event are left out; no event is running).
     */
    /**
     * `spawnSeed` decides pools, spawn groups and spawns' entries; 0 for an unpredictable one. Every
     * node of a cluster must choose the same (docs/CLUSTER.md, phase 4), so they pass the same seed.
     */
    void loadSpawns(MySqlConnection world, const ClientData client, ulong spawnSeed = 0)
    {
        import std.random : unpredictableSeed;

        foreach (row; world.queryAs!(CreatureTemplate, creatureTemplateQuery)())
            creatureTemplates[row.entry] = row;
        foreach (row; world.query!("SELECT entry, type, displayId, name, faction, flags, size, data0, data1, "
            ~ "data2, data3, data4, data5, data6, data7, data8, data9, data10, data11, data12, data13, data14, data15, "
            ~ "data16, data17, data18, data19, data20, data21, data22, data23 FROM gameobject_template")())
        {
            GameObjectTemplate t;
            t.entry = row.get!uint(0);
            t.type = row.get!uint(1);
            t.displayId = row.get!uint(2);
            t.name = row.get!string(3);
            t.faction = row.get!uint(4);
            t.flags = row.get!uint(5);
            t.size = row.get!float(6);
            foreach (i; 0 .. 24)
                t.data[i] = row.get!int(7 + i);
            gameObjectTemplates[t.entry] = t;
        }
        foreach (row; world.queryAs!(QuestRow, questQuery)())
            quests.quests[row.id] = row.toQuest();
        foreach (row; world.query!"SELECT id, quest FROM creature_questrelation"())
            quests.creatureStarts[row.get!uint(0)] ~= row.get!uint(1);
        foreach (row; world.query!"SELECT id, quest FROM creature_involvedrelation"())
            quests.creatureEnds[row.get!uint(0)] ~= row.get!uint(1);
        foreach (row; world.query!"SELECT id, quest FROM gameobject_questrelation"())
            quests.gameObjectStarts[row.get!uint(0)] ~= row.get!uint(1);
        foreach (row; world.query!"SELECT id, quest FROM gameobject_involvedrelation"())
            quests.gameObjectEnds[row.get!uint(0)] ~= row.get!uint(1);
        foreach (row; world.query!"SELECT id, quest FROM areatrigger_involvedrelation"())
            quests.triggerQuests[row.get!uint(0)] = row.get!uint(1);
        quests.link();
        foreach (row; world.query!("SELECT creature_id, RewOnKillRepFaction1, RewOnKillRepFaction2, MaxStanding1, "
            ~ "IsTeamAward1, RewOnKillRepValue1, MaxStanding2, IsTeamAward2, RewOnKillRepValue2, TeamDependent "
            ~ "FROM creature_onkill_reputation")())
            onKillReputation[row.get!uint(0)] = OnKillReputation([row.get!uint(1), row.get!uint(2)],
                [row.get!int(3), row.get!int(6)], [row.get!int(4) != 0, row.get!int(7) != 0],
                [row.get!int(5), row.get!int(8)], row.get!uint(9) != 0);
        foreach (row; world.query!("SELECT faction, faction1, rate_1, rank_1, faction2, rate_2, rank_2, faction3, "
            ~ "rate_3, rank_3, faction4, rate_4, rank_4 FROM reputation_spillover_template")())
        {
            Spillover s;
            foreach (i; 0 .. 4)
            {
                s.faction[i] = row.get!uint(1 + 3 * i);
                s.rate[i] = row.get!float(2 + 3 * i);
                s.rank[i] = row.get!uint(3 + 3 * i);
            }
            spillovers[row.get!uint(0)] = s;
        }
        foreach (row; world.query!"SELECT faction, quest_rate, creature_rate, spell_rate FROM reputation_reward_rate"())
            reputationRates[row.get!uint(0)] = [row.get!float(1), row.get!float(2), row.get!float(3)];
        static foreach (table; [["creature", "creature"], ["reference", "reference"], ["gameobject", "gameObject"],
                ["item", "item"]])
            foreach (row; world.query!("SELECT " ~ lootColumns ~ " FROM " ~ table[0] ~ "_loot_template")())
                __traits(getMember, loot, table[1]).add(row.get!uint(0), lootRow(row.get!uint(1), row.get!float(2),
                    row.get!uint(3), row.get!int(4), row.get!uint(5), row.get!uint(6)));
        foreach (row; world.query!"SELECT id, ghost_loc, link_kind, faction FROM game_graveyard_zone"())
            graveyards[graveyardLinkKey(row.get!uint(1), row.get!uint(2))] ~= GraveyardLink(row.get!uint(0),
                row.get!uint(3));
        foreach (row; world.query!"SELECT map, ghostEntranceMap, ghostEntranceX, ghostEntranceY FROM instance_template"())
            ghostEntrances[row.get!uint(0)] = GhostEntrance(row.get!int(1), row.get!float(2), row.get!float(3));
        foreach (row; world.query!"SELECT entry, equipentry1, equipentry2, equipentry3 FROM creature_equip_template"())
            creatureEquipment[row.get!uint(0)] = [row.get!uint(1), row.get!uint(2), row.get!uint(3)];
        foreach (row; world.query!"SELECT guid, mount, stand_state, sheath_state, emote FROM creature_addon"())
            creatureAddons[row.get!uint(0)] = CreatureAddon(row.get!uint(1), row.get!uint(2), row.get!uint(3),
                row.get!uint(4));
        foreach (row; world.query!("SELECT entry, mount, stand_state, sheath_state, emote "
            ~ "FROM creature_template_addon")())
            creatureTemplateAddons[row.get!uint(0)] = CreatureAddon(row.get!uint(1), row.get!uint(2), row.get!uint(3),
                row.get!uint(4));
        foreach (row; world.query!("SELECT Level, Class, BaseHealthExp0, BaseMana, BaseDamageExp0, "
            ~ "BaseMeleeAttackPower, BaseRangedAttackPower, BaseArmor FROM creature_template_classlevelstats")())
            creatureClassStats[classStatsKey(row.get!uint(0), row.get!uint(1))] = CreatureClassStats(row.get!uint(2),
                row.get!uint(3), row.get!float(4), row.get!float(5), row.get!float(6), row.get!float(7));

        // Which spawns are out: those of events, and the pool members not chosen this time.
        bool[uint] eventCreatures, eventObjects;
        foreach (row; world.query!"SELECT guid FROM game_event_creature WHERE event > 0"())
            eventCreatures[row.get!uint(0)] = true;
        foreach (row; world.query!"SELECT guid FROM game_event_gameobject WHERE event > 0"())
            eventObjects[row.get!uint(0)] = true;
        auto pools = new PoolChooser;
        foreach (row; world.query!"SELECT entry, max_limit FROM pool_template"())
            pools.limits[row.get!uint(0)] = row.get!uint(1);
        foreach (row; world.query!"SELECT pool_id, mother_pool, chance FROM pool_pool"())
            pools.add(row.get!uint(1), PoolMember(PoolMember.Kind.pool, row.get!uint(0), row.get!float(2)));
        foreach (row; world.query!"SELECT guid, pool_entry, chance FROM pool_creature"())
            pools.add(row.get!uint(1), PoolMember(PoolMember.Kind.creature, row.get!uint(0), row.get!float(2)));
        foreach (row; world.query!"SELECT guid, pool_entry, chance FROM pool_gameobject"())
            pools.add(row.get!uint(1), PoolMember(PoolMember.Kind.gameObject, row.get!uint(0), row.get!float(2)));
        auto rng = Random(spawnSeed ? cast(uint)(spawnSeed ^ spawnSeed >> 32) : unpredictableSeed);
        pools.choose(rng);

        // Spawn groups (`SpawnGroup`): at most MaxCount members up at once, entries for members without one;
        // groups that depend on a world state stay down, as no world state is kept yet.
        auto groups = new SpawnGroups;
        foreach (row; world.query!"SELECT Id, Type, MaxCount, WorldState, WorldStateExpression FROM spawn_group"())
            groups.add(row.get!uint(0), row.get!uint(1), row.get!int(2), row.get!int(3) != 0 || row.get!int(4) != 0);
        foreach (row; world.query!"SELECT Id, Guid FROM spawn_group_spawn"())
            groups.addSpawn(row.get!uint(0), row.get!uint(1));
        foreach (row; world.query!"SELECT Id, Entry, Chance FROM spawn_group_entry"())
            groups.addEntry(row.get!uint(0), row.get!uint(1), row.get!uint(2));
        groups.choose(rng);

        // Spawns without an entry take one of `creature_spawn_entry`'s, or their group's.
        uint[][uint] spawnEntries;
        foreach (row; world.query!"SELECT guid, entry FROM creature_spawn_entry"())
            spawnEntries[row.get!uint(0)] ~= row.get!uint(1);
        size_t skipped;
        foreach (row; world.queryAs!(CreatureSpawn, "SELECT guid, id, map, position_x, position_y, position_z, "
            ~ "orientation, spawntimesecsmin, spawndist, MovementType, spawntimesecsmax FROM creature")())
        {
            import std.random : uniform;

            if (row.guid in eventCreatures || !pools.spawns(PoolMember.Kind.creature, row.guid) || row.guid >= 1 << 24
                || !groups.spawns(0, row.guid))
                continue;
            if (row.entry == 0)
            {
                if (auto entries = row.guid in spawnEntries)
                    row.entry = (*entries)[uniform(0, entries.length, rng)];
                else
                    row.entry = groups.entryFor(row.guid, rng);
            }
            if (row.entry !in creatureTemplates || !client.isValidMapCoord(row.map, row.x, row.y, row.z))
            {
                ++skipped;
                continue;
            }
            // ObjectMgr::LoadCreatures: a wander needs a distance, and only a wander has one.
            if (row.wanderDistance < 0)
                row.wanderDistance = 0;
            else if (row.movementType == MotionType.random && row.wanderDistance == 0)
                row.movementType = MotionType.idle;
            else if (row.movementType == MotionType.idle)
                row.wanderDistance = 0;
            if (row.movementType > MotionType.max)
                row.movementType = MotionType.idle;
            creatureCells[row.map][cellKeyAt(row.x, row.y)] ~= creatureSpawns.length;
            creatureSpawns ~= row;
        }
        foreach (row; world.query!("SELECT guid, id, map, position_x, position_y, position_z, orientation, rotation0, "
            ~ "rotation1, rotation2, rotation3, spawntimesecsmin FROM gameobject")())
        {
            GameObjectSpawn s;
            s.guid = row.get!uint(0);
            s.entry = row.get!uint(1);
            s.map = row.get!uint(2);
            s.x = row.get!float(3);
            s.y = row.get!float(4);
            s.z = row.get!float(5);
            s.orientation = row.get!float(6);
            foreach (i; 0 .. 4)
                s.rotation[i] = row.get!float(7 + i);
            s.respawnSeconds = row.get!int(11);
            if (s.guid in eventObjects || !pools.spawns(PoolMember.Kind.gameObject, s.guid) || s.guid >= 1 << 24
                || !groups.spawns(1, s.guid))
                continue;
            if (s.entry == 0)
                s.entry = groups.entryFor(s.guid, rng);
            const t = s.entry in gameObjectTemplates;
            if (t is null || t.type == GameObjectType.moTransport || !client.isValidMapCoord(s.map, s.x, s.y, s.z))
            {
                ++skipped;
                continue;
            }
            gameObjectCells[s.map][cellKeyAt(s.x, s.y)] ~= gameObjectSpawns.length;
            gameObjectSpawns ~= s;
        }
        info!"loaded %s creature and %s game object templates; %s creatures and %s game objects spawn (%s skipped)"(
            creatureTemplates.length, gameObjectTemplates.length, creatureSpawns.length, gameObjectSpawns.length,
            skipped);
    }

    /**
     * `WaypointManager::Load` for `creature_movement` (by spawn guid) and `creature_movement_template`
     * (by entry and path): points outside the world are left out (CMaNGOS moves them inside and
     * writes them back; the database is not changed here), and so are paths with a point 0.
     */
    void loadWaypoints(MySqlConnection world)
    {
        import std.math : abs;

        static bool valid(const ref WaypointNode n)
        {
            enum float limit = 17_066.6656f; // MAP_HALFSIZE - 0.5 (IsValidMapCoord)
            return abs(n.x) <= limit && abs(n.y) <= limit && abs(n.z) <= limit;
        }

        static WaypointNode node(R)(R row, size_t first)
        {
            WaypointNode n;
            n.point = row.get!uint(first);
            n.x = row.get!float(first + 1);
            n.y = row.get!float(first + 2);
            n.z = row.get!float(first + 3);
            const orientation = row.get!float(first + 4);
            n.orientation = orientation == 100 ? float.nan : orientation; // 100: no facing
            n.delay = row.get!uint(first + 5);
            n.scriptId = row.get!uint(first + 6);
            return n;
        }

        bool[uint] spawnGuids;
        foreach (row; world.query!"SELECT guid FROM creature"())
            spawnGuids[row.get!uint(0)] = true;
        size_t skipped;
        foreach (row; world.query!("SELECT Id, Point, PositionX, PositionY, PositionZ, Orientation, WaitTime, ScriptId "
            ~ "FROM creature_movement")())
        {
            const n = node(row, 1);
            if (row.get!uint(0) !in spawnGuids || !valid(n))
                ++skipped;
            else
                waypoints.addSpawnNode(row.get!uint(0), n);
        }
        foreach (row; world.query!("SELECT Entry, PathId, Point, PositionX, PositionY, PositionZ, Orientation, "
            ~ "WaitTime, ScriptId FROM creature_movement_template")())
        {
            const n = node(row, 2);
            if (row.get!uint(0) !in creatureTemplates || !valid(n))
                ++skipped;
            else
                waypoints.addEntryNode(row.get!uint(0), row.get!uint(1), n);
        }
        waypoints.finish();
        info!"loaded %s creature waypoint paths (%s points skipped)"(waypoints.length, skipped);
    }

    /// `ObjectMgr::LoadAreaTriggerTeleports` and `LoadGameTele`, with the same checks.
    void loadTeleports(MySqlConnection world, const ClientData client)
    {
        setTeleports(world.queryAs!(AreaTriggerTeleport, areaTriggerTeleportQuery)(),
            world.queryAs!(GameTele, gameTeleQuery)(), client);
        foreach (row; world.query!"SELECT id FROM areatrigger_tavern"())
            taverns[row.get!uint(0)] = true;
    }

    /// Replaces the area trigger teleports and `.tele` places with those of these rows that are valid.
    void setTeleports(AreaTriggerTeleport[] triggers, GameTele[] places, const ClientData client)
    {
        areaTriggers = null;
        teleports = null;
        foreach (row; triggers)
        {
            if (client.areaTriggers.lookup(row.id) is null)
                warning!"areatrigger_teleport: trigger %s is not in AreaTrigger.dbc"(row.id);
            else if (row.requiredItem && row.requiredItem !in items || row.requiredItem2 && row.requiredItem2 !in items)
                warning!"areatrigger_teleport: trigger %s requires an item that does not exist"(row.id);
            else if (client.maps.lookup(row.targetMap) is null)
                warning!"areatrigger_teleport: trigger %s leads to map %s, which does not exist"(row.id, row.targetMap);
            else if (row.x == 0 && row.y == 0 && row.z == 0)
                warning!"areatrigger_teleport: trigger %s has no target position"(row.id);
            else
                areaTriggers[row.id] = row;
        }
        foreach (row; places)
        {
            if (client.isValidMapCoord(row.map, row.x, row.y, row.z, row.orientation))
                teleports ~= row;
            else
                warning!"game_tele: '%s' is not a valid position on map %s"(row.name, row.map);
        }
        info!"loaded %s area trigger teleports and %s teleport locations"(areaTriggers.length, teleports.length);
    }

private:
    /// `ObjectMgr::LoadPlayerInfo`
    void loadPlayerInfo(MySqlConnection world, const ClientData client)
    {
        static bool playable(uint race, uint classId)
        {
            return race && (maskOf(race) & playableRaceMask) && classId && (maskOf(classId) & playableClassMask);
        }

        foreach (row; world.query!("SELECT race, class, map, zone, position_x, position_y, position_z, "
            ~ "orientation FROM playercreateinfo")())
        {
            const race = row.get!ubyte(0), classId = row.get!ubyte(1);
            if (!playable(race, classId))
                continue;
            PlayerInfo player;
            player.map = row.get!uint(2);
            player.zone = row.get!uint(3);
            player.x = row.get!float(4);
            player.y = row.get!float(5);
            player.z = row.get!float(6);
            player.orientation = row.get!float(7);
            playerInfo[raceClassKey(race, classId)] = player;
        }

        foreach (row; world.query!"SELECT race, class, itemid, amount FROM playercreateinfo_item"())
        {
            auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;
            const item = row.get!uint(2), amount = row.get!uint(3);
            if (player is null || (item in items) is null || amount == 0)
                continue;
            player.items ~= CreateItem(item, amount);
        }

        // Each skill row applies to every race/class its masks allow, if SkillRaceClassInfo makes it obtainable.
        foreach (row; world.query!"SELECT raceMask, classMask, skill, step FROM playercreateinfo_skills"())
        {
            const raceMask = row.get!uint(0), classMask = row.get!uint(1);
            const skill = CreateSkill(row.get!uint(2), row.get!uint(3));
            if (skill.step > maxSkillStep || (raceMask && !(raceMask & playableRaceMask))
                || (classMask && !(classMask & playableClassMask)) || client.skillLines.lookup(skill.skillId) is null)
                continue;
            foreach (ubyte race; 1 .. 9)
            {
                if (raceMask && !(raceMask & maskOf(race)))
                    continue;
                foreach (ubyte classId; 1 .. 12)
                {
                    if (classMask && !(classMask & maskOf(classId)))
                        continue;
                    bool obtainable;
                    foreach (entry; client.raceClassInfo(skill.skillId))
                    {
                        if (!(entry.raceMask & maskOf(race)) || !(entry.classMask & maskOf(classId)))
                            continue;
                        if (skill.step)
                        {
                            const tiers = client.skillTiers.lookup(entry.skillTierId);
                            if (tiers is null || !tiers.maxSkillValue[skill.step - 1])
                                continue;
                        }
                        obtainable = true;
                        break;
                    }
                    if (!obtainable)
                        continue;
                    if (auto player = raceClassKey(race, classId) in playerInfo)
                        player.skills ~= skill;
                }
            }
        }

        foreach (row; world.query!"SELECT race, class, Spell FROM playercreateinfo_spell"())
        {
            auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;
            const spellId = row.get!uint(2);
            if (player is null || spells.spell(spellId) is null)
                continue;
            player.spells ~= spellId;
        }

        foreach (row; world.query!"SELECT race, class, button, action, type FROM playercreateinfo_action"())
        {
            auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;
            const action = CreateAction(row.get!ubyte(2), row.get!uint(3), row.get!ubyte(4));
            if (player is null || !isActionButtonDataValid(action))
                continue;
            player.actions ~= action;
        }

        foreach (row; world.query!"SELECT class, level, basehp, basemana FROM player_classlevelstats"())
        {
            const classId = row.get!uint(0), level = row.get!uint(1);
            if (!classId || !(maskOf(classId) & playableClassMask) || level == 0 || level > maxLevel)
                continue;
            auto table = &classLevelStats.require(classId);
            if (table.length < level)
                table.length = level;
            (*table)[level - 1] = ClassLevelStats(row.get!uint(2), row.get!uint(3));
        }
        foreach (ref table; classLevelStats) // fill gaps with the level below, as CMaNGOS does
            foreach (level; 1 .. table.length)
                if (table[level] == ClassLevelStats.init)
                    table[level] = table[level - 1];

        foreach (row; world.query!"SELECT race, class, level, str, agi, sta, inte, spi FROM player_levelstats"())
        {
            auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;
            const level = row.get!uint(2);
            if (player is null || level == 0 || level > maxLevel)
                continue;
            if (player.levelStats.length < level)
                player.levelStats.length = level;
            player.levelStats[level - 1] = LevelStats([row.get!uint(3), row.get!uint(4), row.get!uint(5),
                row.get!uint(6), row.get!uint(7)]);
        }
        foreach (ref player; playerInfo)
            foreach (level; 1 .. player.levelStats.length)
                if (player.levelStats[level] == LevelStats.init)
                    player.levelStats[level] = player.levelStats[level - 1];
    }

    /// `Player::IsActionButtonDataValid`
    public bool isActionButtonDataValid(CreateAction action) const
    {
        import dmangos.world.defines : ActionButtonType, maxActionButtons;

        if (action.button >= maxActionButtons)
            return false;
        if (action.type == ActionButtonType.spell)
            return spells.spell(action.action) !is null;
        if (action.type == ActionButtonType.item)
            return (action.action in items) !is null;
        return true;
    }
}

/// CMaNGOS's `wstrToLower` (`wcharToLower`), used for reserved name comparisons.
dstring toLowerName(string name) pure @safe
{
    import std.utf : toUTF32;

    auto text = name.toUTF32.dup;
    foreach (ref c; text)
        c = wcharToLower(c);
    return text.idup;
}

/// CMaNGOS's `wcharToLower`.
dchar wcharToLower(dchar c) pure nothrow @nogc @safe
{
    if (c >= 'A' && c <= 'Z')
        return c + 0x20;
    if ((c >= 0x00C0 && c <= 0x00D6) || (c >= 0x00D8 && c <= 0x00DE))
        return c + 0x20;
    if (c >= 0x0100 && c <= 0x012E && c % 2 == 0)
        return c + 1;
    if (c == 0x1E9E)
        return 0x00DF;
    if (c == 0x0401)
        return 0x0451;
    if (c >= 0x0410 && c <= 0x042F)
        return c + 0x20;
    return c;
}

/// CMaNGOS's `wcharToUpper`.
dchar wcharToUpper(dchar c) pure nothrow @nogc @safe
{
    if (c >= 'a' && c <= 'z')
        return c - 0x20;
    if (c == 0x00DF)
        return 0x1E9E;
    if ((c >= 0x00E0 && c <= 0x00F6) || (c >= 0x00F8 && c <= 0x00FE))
        return c - 0x20;
    if (c >= 0x0101 && c <= 0x012F && c % 2 == 1)
        return c - 1;
    if (c >= 0x0430 && c <= 0x044F)
        return c - 0x20;
    if (c == 0x0451)
        return 0x0401;
    return c;
}

/// One `item_template` row as loaded (flat, for `Row.as`).
private struct ItemRow
{
    uint entry, itemClass, subClass, displayId, flags, buyCount, inventoryType;
    int allowableClass, allowableRace;
    uint requiredLevel, requiredSkill, requiredSkillRank, requiredSpell, requiredHonorRank;
    uint requiredReputationFaction, requiredReputationRank;
    int maxCount;
    uint stackable, containerSlots;
    int c1, c2, c3, c4, c5;
    uint k1, k2, k3, k4, k5;
    uint bonding, randomProperty, maxDurability, bagFamily, duration;

    ItemTemplate toTemplate() const
    {
        return ItemTemplate(entry, itemClass, subClass, displayId, flags, buyCount, cast(ubyte) inventoryType,
            cast(uint) allowableClass, cast(uint) allowableRace, requiredLevel, requiredSkill, requiredSkillRank,
            requiredSpell, requiredHonorRank, requiredReputationFaction, requiredReputationRank, maxCount, stackable,
            containerSlots, [c1, c2, c3, c4, c5], [k1, k2, k3, k4, k5], bonding, randomProperty, maxDurability,
            bagFamily, duration);
    }
}

unittest
{
    assert(toLowerName("ThRALL") == "thrall"d);
    assert(wcharToUpper('ä') == 'Ä' && wcharToLower('Ä') == 'ä');
    assert(wcharToUpper('ж') == 'Ж' && wcharToLower('Ё') == 'ё');
}

/// One member of a pool: a creature, a game object, or another pool.
struct PoolMember
{
    enum Kind
    {
        creature,
        gameObject,
        pool,
    }

    Kind kind;
    uint id;
    float chance = 0; /// percent; 0 for "as likely as the others"
}

/**
 * `PoolManager` at start-up: each pool spawns at most its `max_limit` members, chosen at random
 * (those with a chance by their chance, the others evenly), and a pool inside another one only if
 * that one chose it. Spawns that are in no pool always spawn.
 */
final class PoolChooser
{
    uint[uint] limits;                 /// `pool_template.max_limit`, by pool
    private PoolMember[][uint] members; // by pool
    private bool[uint] childPools;
    private bool[uint][PoolMember.Kind] pooled, chosen;

    /// Adds a member to a pool.
    void add(uint pool, PoolMember member)
    {
        members[pool] ~= member;
        pooled[member.kind][member.id] = true;
        if (member.kind == PoolMember.Kind.pool)
            childPools[member.id] = true;
    }

    /// Chooses the members of every top-level pool, and of the pools those choose.
    void choose(ref Random rng)
    {
        foreach (pool, _; members)
            if (pool !in childPools)
                choosePool(pool, rng);
    }

    /// Whether a spawn is in the world: in no pool, or chosen.
    bool spawns(PoolMember.Kind kind, uint id) const
    {
        const inPool = kind in pooled;
        if (inPool is null || id !in *inPool)
            return true;
        const picked = kind in chosen;
        return picked !is null && (id in *picked) !is null;
    }

private:
    void choosePool(uint pool, ref Random rng)
    {
        import std.random : randomShuffle, uniform01;

        auto candidates = members.get(pool, null).dup;
        const limit = limits.get(pool, 1);
        size_t picked;
        // Members with a chance get one roll among them; the rest share what remains, evenly.
        float roll = uniform01(rng) * 100;
        foreach (ref member; candidates)
            if (member.chance > 0 && picked < limit)
            {
                if (roll < member.chance)
                {
                    pick(member, rng);
                    ++picked;
                    break;
                }
                roll -= member.chance;
            }
        randomShuffle(candidates, rng);
        foreach (ref member; candidates)
        {
            if (picked >= limit)
                break;
            if (member.chance > 0)
                continue;
            pick(member, rng);
            ++picked;
        }
    }

    void pick(const PoolMember member, ref Random rng)
    {
        chosen[member.kind][member.id] = true;
        if (member.kind == PoolMember.Kind.pool)
            choosePool(member.id, rng);
    }
}

unittest
{
    auto pools = new PoolChooser;
    pools.limits[1] = 1;
    pools.limits[2] = 2;
    foreach (guid; [10u, 11, 12])
        pools.add(1, PoolMember(PoolMember.Kind.gameObject, guid));
    pools.add(3, PoolMember(PoolMember.Kind.pool, 2));
    pools.limits[3] = 0;
    foreach (guid; [20u, 21, 22])
        pools.add(2, PoolMember(PoolMember.Kind.creature, guid));
    auto rng = Random(7);
    pools.choose(rng);
    size_t spawned;
    foreach (guid; [10u, 11, 12])
        spawned += pools.spawns(PoolMember.Kind.gameObject, guid);
    assert(spawned == 1, "one of the three");
    assert(!pools.spawns(PoolMember.Kind.creature, 20) && !pools.spawns(PoolMember.Kind.creature, 21),
        "pool 3 may spawn no member, so pool 2 is not chosen");
    assert(pools.spawns(PoolMember.Kind.creature, 99), "not in a pool");
}

/**
 * CMaNGOS's spawn groups (`spawn_group`, `spawn_group_spawn`, `spawn_group_entry`), as far as a
 * world without world states needs them: which members are up, and what a member without its own
 * entry is.
 */
final class SpawnGroups
{
    private static struct Group
    {
        uint type;          // 0 creatures, 1 game objects
        int maxCount;       // 0: every member
        bool conditional;   // depends on a world state
        uint[] guids;
        uint[] entries;
        uint[] chances;
    }

    private Group[uint] groups;
    private uint[uint][2] groupOf;     // type -> spawn guid -> group
    private bool[uint][2] active;      // type -> spawn guids that are up

    ///
    void add(uint id, uint type, int maxCount, bool conditional)
    {
        groups[id] = Group(type, maxCount, conditional);
    }

    ///
    void addSpawn(uint id, uint guid)
    {
        if (auto group = id in groups)
            if (group.type < 2)
            {
                group.guids ~= guid;
                groupOf[group.type][guid] = id;
            }
    }

    ///
    void addEntry(uint id, uint entry, uint chance)
    {
        if (auto group = id in groups)
        {
            group.entries ~= entry;
            group.chances ~= chance;
        }
    }

    /// Chooses which members of each group are up.
    void choose(ref Random rng)
    {
        import std.random : randomShuffle;

        foreach (ref group; groups)
        {
            if (group.conditional || group.type >= 2)
                continue;
            auto members = group.guids.dup;
            randomShuffle(members, rng);
            const count = group.maxCount > 0 && group.maxCount < members.length ? group.maxCount : members.length;
            foreach (guid; members[0 .. count])
                active[group.type][guid] = true;
        }
    }

    /// Whether a spawn is up: in no group, or chosen.
    bool spawns(uint type, uint guid) const
    {
        return guid !in groupOf[type] || (guid in active[type]) !is null;
    }

    /// An entry for a member without one: by the entries' chances, or evenly; 0 if the group has none.
    uint entryFor(uint guid, ref Random rng) const
    {
        import std.random : uniform;

        foreach (type; 0 .. 2)
            if (const id = guid in groupOf[type])
            {
                const group = groups[*id];
                if (group.entries.length == 0)
                    return 0;
                uint total;
                foreach (chance; group.chances)
                    total += chance;
                if (total == 0)
                    return group.entries[uniform(0, group.entries.length, rng)];
                auto roll = uniform(0, total, rng);
                foreach (i, chance; group.chances)
                {
                    if (roll < chance)
                        return group.entries[i];
                    roll -= chance;
                }
                return group.entries[$ - 1];
            }
        return 0;
    }
}

unittest
{
    auto groups = new SpawnGroups;
    groups.add(1, 0, 1, false);
    groups.add(2, 0, 0, true);
    foreach (guid; [5u, 6, 7])
        groups.addSpawn(1, guid);
    groups.addSpawn(2, 9);
    groups.addEntry(1, 100, 0);
    groups.addEntry(1, 101, 0);
    auto rng = Random(3);
    groups.choose(rng);
    assert(groups.spawns(0, 5) + groups.spawns(0, 6) + groups.spawns(0, 7) == 1, "MaxCount 1");
    assert(!groups.spawns(0, 9) && groups.spawns(0, 42) && groups.spawns(1, 5));
    const entry = groups.entryFor(5, rng);
    assert(entry == 100 || entry == 101);
}
