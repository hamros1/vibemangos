/**
 * Static game data from the world (`mangos`) database, which has the
 * CMaNGOS-classic schema.
 *
 * Everything is read into memory once at start-up. The `playercreateinfo_*`
 * rows are filtered (playable races and classes, items, spells, skills and
 * action buttons that exist), so a new character starts with exactly what
 * the data means it to.
 */
module dmangos.world.worlddata;

import dmangos.frozen : StaticMap;
import std.random : Random;

import dmangos.log;
import dmangos.mysql : MySqlConnection;
import dmangos.world.clientdata : ClientData, maskOf, maxSkillStep, playableClassMask, playableRaceMask;
import dmangos.world.eventai : EventAiData;
import dmangos.world.pet : PetData;
import dmangos.world.dbscripts : DbScriptData;
import dmangos.world.reputation : Spillover;
import dmangos.world.creature : CreatureAddon, CreatureClassStats, CreatureSpawn, CreatureTemplate, classStatsKey,
    creatureTemplateQuery;
import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate, GameObjectType;
import dmangos.world.bgqueue : BattlegroundTemplate, BattlegroundType;
import dmangos.world.enchantments : EnchantmentEffect, EnchantmentType, RandomEnchantment;
import dmangos.world.gameevents : GameEvent, ScheduleType;
import dmangos.world.creaturelinking : CreatureLinks, Formation;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.motion : MotionType, WaypointNode, WaypointStore;
import dmangos.world.loot : lootColumns, lootRow, LootStore, LootStores;
import dmangos.world.npcdata : BroadcastText, NpcData;
import dmangos.script.api : Location, Waypoint;
import dmangos.world.quests : QuestData, QuestGreeting, questQuery, QuestRow;
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

/// One of an item's stat bonuses (`stat_typeN`, `stat_valueN`).
struct ItemStat
{
    uint type;  /// which stat
    int value;
}

/// One of an item's damage ranges (`_Damage`).
struct ItemDamage
{
    float min = 0;
    float max = 0;
    uint school;
}

/// One of an item's spells (`spellid_N` and its columns), apart from the charges and category kept in `ItemTemplate`.
struct ItemSpell
{
    uint id;
    uint trigger;
    int cooldown = -1;         /// -1: use the spell's own
    int categoryCooldown = -1; /// -1: use the spell's own
    float ppmRate = 0;         /// `spellppmRate`: procs a minute of a chance-on-hit spell; 0: the spell's chance
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
            ["spellcategorycooldown_" ~ to!string(i + 1), "spells[" ~ to!string(i) ~ "].categoryCooldown"],
            ["spellppmRate_" ~ to!string(i + 1), "spells[" ~ to!string(i) ~ "].ppmRate"]];
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

static assert(itemDetailColumns.length == 6 + 20 + 15 + 7 + 3 + 25 + 14);

/// `creature_model_info`: a model's size.
struct ModelInfo
{
    float boundingRadius = 0;
    float combatReach = 0;
    ubyte gender;
}

/// An item a new character starts with (`playercreateinfo_item`).
struct CreateItem
{
    uint itemId;
    uint amount;
}

/// A `playercreateinfo_skills` entry, checked against `SkillRaceClassInfo.dbc`.
struct CreateSkill
{
    uint skillId;
    uint step;
}

/// An action button a new character starts with (`playercreateinfo_action`).
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

/// Everything a new character of one race and class starts with.
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

/// Highest level the stats tables are read for (1.12 data stops at 60; up to 255 accepted).
enum maxLevel = 255;

/// An `areatrigger_teleport` row: where an area trigger takes a player, and who may go.
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

/// The columns of `AreaTriggerTeleport`.
enum areaTriggerTeleportQuery = "SELECT id, IFNULL(name, ''), required_level, required_item, required_item2, "
    ~ "required_quest_done, target_map, target_position_x, target_position_y, target_position_z, target_orientation, "
    ~ "IFNULL(status_failed_text, ''), condition_id FROM areatrigger_teleport";

/// The columns of `GameTele`.
enum gameTeleQuery = "SELECT position_x, position_y, position_z, orientation, map, name FROM game_tele ORDER BY id";

/// See the module documentation.
/// A graveyard (`WorldSafeLocs.dbc`) for an area, zone or map, and for which team.
struct GraveyardLink
{
    uint safeLoc;
    uint team;   /// 0: both, otherwise ALLIANCE (469) or HORDE (67)
}

/// The key graveyards are linked by: an area or zone id (`linkKind` 0) or a map id (`linkKind` 1).
uint graveyardLinkKey(uint location, uint linkKind) pure nothrow @nogc @safe
{
    return location | linkKind << 31;
}

/// What killing a creature does to two factions' reputations.
struct OnKillReputation
{
    uint[2] faction;
    int[2] maxStanding;    /// the rank it gives reputation up to
    bool[2] teamAward;     /// the faction's team gets half as much
    int[2] value;
    bool teamDependent;    /// the first for the Alliance only, the second for the Horde
}

/// An instance's ghost entrance: where on which map a ghost of an instance comes back out.
struct GhostEntrance
{
    int map = -1;
    float x = 0, y = 0;
}

/// A row of `world_safe_locs`.
struct SafeLocation
{
    uint map;
    float x = 0, y = 0, z = 0, orientation = 0;
}

final class WorldData
{
    enum holdsStaticData = true; // `dmangos.frozen.freezeAll` goes into it

    StaticMap!(uint, ItemTemplate) items;               /// by entry
    ubyte[uint] creatureFamilies;           /// `creature_template.Family`, by entry; every creature is present
    PlayerInfo[ushort] playerInfo;          /// by `raceClassKey`
    ClassLevelStats[][uint] classLevelStats; /// by class, index = level - 1
    bool[dstring] reservedNames;            /// lower-cased
    SpellData spells;
    uint[] xpForNextLevel;                  /// `player_xp_for_level`, index = level
    uint[uint] baseXp;                      /// `exploration_basexp`, by level
    StaticMap!(uint, ModelInfo) models;                 /// `creature_model_info`, by display id
    AreaTriggerTeleport[uint] areaTriggers; /// `areatrigger_teleport`, by trigger id
    GameTele[] teleports;                   /// `game_tele`, in id order
    bool[uint] taverns;                     /// `areatrigger_tavern`: the inns' area triggers

    StaticMap!(uint, CreatureTemplate) creatureTemplates;       /// by entry
    StaticMap!(uint, GameObjectTemplate) gameObjectTemplates;   /// by entry
    CreatureSpawn[] creatureSpawns;                 /// the spawns in the world now (pools chosen, events off)
    GameObjectSpawn[] gameObjectSpawns;             /// ditto
    size_t[][ulong][uint] creatureCells;            /// map -> cell key -> indexes into `creatureSpawns`
    size_t[][ulong][uint] gameObjectCells;          /// ditto, into `gameObjectSpawns`
    StaticMap!(uint, CreatureAddon) creatureAddons;             /// `creature_addon`, by spawn guid
    StaticMap!(uint, CreatureAddon) creatureTemplateAddons;     /// `creature_template_addon`, by entry
    uint[3][uint] creatureEquipment;                /// `creature_equip_template`: item entries, by id
    CreatureClassStats[uint] creatureClassStats;    /// by `classStatsKey`
    NpcData npcs;                                   /// gossip, texts, trainers, vendors
    LootStores loot;                                /// `creature_loot_template`, `reference_loot_template`
    QuestData quests;                               /// `quest_template` and who gives and takes back each
    GraveyardLink[][uint] graveyards;               /// `game_graveyard_zone`, by `graveyardLinkKey`
    BattlegroundTemplate[ubyte] battlegroundTemplates;  /// `battleground_template`, by type
    BattlegroundType[uint] battlemasters;           /// `battlemaster_entry`: a creature entry's battleground
    SafeLocation[uint] safeLocations;               /// `world_safe_locs` (with the facing the DBC lacks)
    ubyte[2][uint] creatureBattleEvents;            /// `creature_battleground`: a spawn's battleground event
    RandomEnchantment[][uint] randomProperties;     /// `item_enchantment_template`, by an item's `RandomProperty`
    short[uint] creatureGameEvents;                 /// `game_event_creature`: a spawn's game event (negative: away while it is on)
    short[uint] gameObjectGameEvents;               /// `game_event_gameobject`: ditto
    GameEvent[] gameEvents;                         /// `game_event` and `game_event_time`
    ushort[][uint] questGameEvents;                 /// `game_event_quest`: the events a quest is given during
    CreatureLinks creatureLinks;                    /// `creature_linking` and `creature_linking_template`
    Formation[uint] formations;                     /// `spawn_group_formation`, by spawn group
    uint[2][uint] formationSlots;                   /// a formation member's spawn -> (its group, its slot)
    uint[3][uint] propertyEnchantments;             /// a random property's enchantments (`ItemRandomProperties.dbc`)
    EnchantmentEffect[3][uint] enchantmentEffects;  /// an enchantment's effects (`SpellItemEnchantment.dbc`)
    ubyte[2][uint] gameObjectBattleEvents;          /// `gameobject_battleground`: ditto
    string[uint] serverStrings;                     /// `mangos_string`'s default texts
    GhostEntrance[uint] ghostEntrances;             /// `instance_template`'s ghost entrances, by instance map
    uint[uint] instanceMaxPlayers;                  /// `instance_template.maxPlayers`, by instance map
    int[uint] fishingBaseSkill;                     /// `skill_fishing_base_level`: area or zone -> skill to fish there
    uint[uint] instanceResetDays;                   /// `instance_template.reset_delay` (a raid's lockout), by map
    WaypointStore waypoints;                        /// `creature_movement` and `creature_movement_template`
    EventAiData eventAi;                            /// `creature_ai_scripts`, by creature entry
    PetData pets;                                   /// `pet_levelstats`, `petcreateinfo_spell`, `pet_name_generation`
    string[uint] creatureScriptNames;               /// `creature_template.ScriptName`, by entry (docs/SCRIPTING.md)
    string[uint] instanceScriptNames;               /// `instance_template.ScriptName`, by map
    string[uint] gameObjectScriptNames;             /// `gameobject_template.ScriptName`, by entry
    string[uint] spellScriptNames;                  /// `spell_scripts`, by spell
    string[uint] areaTriggerScriptNames;            /// `scripted_areatrigger`, by trigger
    Waypoint[][uint] escortPaths;                   /// `script_waypoint` (path 0), by creature entry
    BroadcastText[int] scriptTexts;                 /// `script_texts`, by (negative) entry
    uint[int] scriptTextSounds;                     /// their sounds
    DbScriptData dbScripts;
    import dmangos.world.weather : ZoneChances;
    ZoneChances[uint] weatherChances;               /// `game_weather`, by zone                         /// `dbscripts_on_*`
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
        dbScripts = new DbScriptData;
        loot = LootStores.create();
        creatureLinks = new CreatureLinks;
    }

    /**
     * A trigger that leads into `map` from another map, whose
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
     * The place called `name` (any case), or else the first whose name
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

    /// The experience a character of `level` needs for the next level; 0 if unknown.
    uint xpForLevel(uint level) const
    {
        return level < xpForNextLevel.length ? xpForNextLevel[level] : 0;
    }

    /// Key into `playerInfo`.
    static ushort raceClassKey(ubyte race, ubyte classId) pure nothrow @nogc @safe
    {
        return cast(ushort)(race << 8 | classId);
    }

    /// Whether a character of this race and class may exist (it has create info).
    bool isValidRaceClass(ubyte race, ubyte classId) const
    {
        return (raceClassKey(race, classId) in playerInfo) !is null;
    }

    /// What a new character of this race and class starts with; null if it may not exist.
    const(PlayerInfo)* createInfo(ubyte race, ubyte classId) const
    {
        return raceClassKey(race, classId) in playerInfo;
    }

    /// A race and class's stats for a level, falling back to the highest level known.
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

    /// A class's base health and mana for a level, falling back to the highest level known.
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
            // Every stack holds 1 to 255.
            if (item.stackable == 0 || item.stackable > 255)
            {
                const fixed = item.stackable == 0 ? 1 : 255;
                warning!"item %s has wrong value in stackable (%s), replaced by %s"(item.entry, item.stackable, fixed);
                item.stackable = fixed;
            }
            data.items[row.entry] = item;
        }
        foreach (row; world.query!itemDetailQuery())
            if (auto item = data.items.edit(row.get!uint(0)))
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
        data.loadEnchantments(world, client);
        data.loadGameEvents(world);
        foreach (row; world.query!"SELECT Id, FormationType, FormationSpread, PathId, MovementType FROM spawn_group_formation"())
            data.formations[row.get!uint(0)] = Formation(row.get!uint(1), row.get!float(2), row.get!uint(3), row.get!uint(4));
        foreach (row; world.query!"SELECT Id, Guid, SlotId FROM spawn_group_spawn"())
            if (row.get!uint(0) in data.formations && row.get!int(2) >= 0)
                data.formationSlots[row.get!uint(1)] = [row.get!uint(0), cast(uint) row.get!int(2)];
        foreach (row; world.query!"SELECT guid, master_guid, flag FROM creature_linking"())
            data.creatureLinks.addGuid(row.get!uint(0), row.get!uint(1), row.get!uint(2));
        foreach (row; world.query!"SELECT entry, map, master_entry, flag, search_range FROM creature_linking_template"())
            data.creatureLinks.addTemplate(row.get!uint(0), row.get!uint(1), row.get!uint(2), row.get!uint(3),
                row.get!uint(4));
        data.loadSpawns(world, client, spawnSeed);
        data.loadWaypoints(world);
        data.loadPlayerInfo(world, client);
        data.eventAi = EventAiData.load(world);
        data.pets = PetData.load(world);
        data.dbScripts = DbScriptData.load(world);
        {
            import dmangos.world.weather : SeasonChances, ZoneChances;

            foreach (row; world.query!("SELECT zone, spring_rain_chance, spring_snow_chance, spring_storm_chance, "
                ~ "summer_rain_chance, summer_snow_chance, summer_storm_chance, fall_rain_chance, fall_snow_chance, "
                ~ "fall_storm_chance, winter_rain_chance, winter_snow_chance, winter_storm_chance FROM game_weather")())
            {
                ZoneChances chances;
                foreach (season; 0 .. 4)
                    chances[season] = SeasonChances(row.get!ubyte(1 + season * 3), row.get!ubyte(2 + season * 3),
                        row.get!ubyte(3 + season * 3));
                data.weatherChances[row.get!uint(0)] = chances;
            }
        }
        info!"loaded %s item templates, %s creature templates, %s race/class combinations, %s reserved names"(
            data.items.length, data.creatureFamilies.length, data.playerInfo.length, data.reservedNames.length);
        if (data.playerInfo.length == 0)
            warning!("playercreateinfo is empty: no character can be listed or created "
                ~ "(is the world database populated?)")();
        return data;
    }

    /**
     * Creature and game object templates and spawns,
     * and what decides which spawns are in the world: pools (one choice per start-up) and
     * game events (spawns that only exist during an event are left out; no event is running).
     */
    /**
     * `spawnSeed` decides pools, spawn groups and spawns' entries; 0 for an unpredictable one. Every
     * node of a cluster must choose the same (docs/CLUSTER.md), so they pass the same seed.
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
        foreach (row; world.query!"SELECT Entry, Type, IFNULL(Text, ''), EmoteId, EmoteDelay FROM questgiver_greeting"())
            quests.greetings[(ulong(row.get!uint(1)) << 32) | row.get!uint(0)] = QuestGreeting(row.get!string(2).idup,
                row.get!uint(3), row.get!uint(4));
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
                ["item", "item"], ["fishing", "fishing"], ["skinning", "skinning"], ["pickpocketing", "pickpocketing"], ["mail", "mail"]])
            foreach (row; world.query!("SELECT " ~ lootColumns ~ " FROM " ~ table[0] ~ "_loot_template")())
                __traits(getMember, loot, table[1]).add(row.get!uint(0), lootRow(row.get!uint(1), row.get!float(2),
                    row.get!uint(3), row.get!int(4), row.get!uint(5), row.get!uint(6)));
        foreach (row; world.query!"SELECT entry, skill FROM skill_fishing_base_level"())
            fishingBaseSkill[row.get!uint(0)] = row.get!int(1);
        foreach (row; world.query!"SELECT id, ghost_loc, link_kind, faction FROM game_graveyard_zone"())
            graveyards[graveyardLinkKey(row.get!uint(1), row.get!uint(2))] ~= GraveyardLink(row.get!uint(0),
                row.get!uint(3));
        foreach (row; world.query!("SELECT id, MinPlayersPerTeam, MaxPlayersPerTeam, MinLvl, MaxLvl, AllianceStartLoc, "
                ~ "HordeStartLoc, StartMaxDist, PlayerSkinReflootId FROM battleground_template")())
        {
            const id = row.get!uint(0);
            if (id == 0 || id > BattlegroundType.max)
                continue;
            battlegroundTemplates[cast(ubyte) id] = BattlegroundTemplate(cast(ubyte) id, row.get!uint(1), row.get!uint(2),
                cast(ubyte) row.get!uint(3), cast(ubyte) row.get!uint(4), [row.get!uint(5), row.get!uint(6)],
                row.get!float(7), row.get!uint(8));
        }
        foreach (row; world.query!"SELECT entry, bg_template FROM battlemaster_entry"())
            if (row.get!uint(1) && row.get!uint(1) <= BattlegroundType.max) // battleground types that exist
                battlemasters[row.get!uint(0)] = cast(BattlegroundType) row.get!uint(1);
        // Spawns' battleground events: 255 is no event.
        foreach (row; world.query!"SELECT guid, event1, event2 FROM creature_battleground"())
            if (row.get!uint(1) != 255)
                creatureBattleEvents[row.get!uint(0)] = [cast(ubyte) row.get!uint(1), cast(ubyte) row.get!uint(2)];
        foreach (row; world.query!"SELECT guid, event1, event2 FROM gameobject_battleground"())
            if (row.get!uint(1) != 255)
                gameObjectBattleEvents[row.get!uint(0)] = [cast(ubyte) row.get!uint(1), cast(ubyte) row.get!uint(2)];
        foreach (row; world.query!"SELECT id, map, x, y, z, o FROM world_safe_locs"())
            safeLocations[row.get!uint(0)] = SafeLocation(row.get!uint(1), row.get!float(2), row.get!float(3),
                row.get!float(4), row.get!float(5));
        foreach (row; world.query!"SELECT entry, content_default FROM mangos_string"())
            serverStrings[row.get!uint(0)] = row.get!string(1);
        foreach (row; world.query!"SELECT Entry, ScriptName FROM creature_template WHERE ScriptName <> ''"())
            creatureScriptNames[row.get!uint(0)] = row.get!string(1);
        foreach (row; world.query!"SELECT map, ScriptName FROM instance_template WHERE ScriptName <> ''"())
            instanceScriptNames[row.get!uint(0)] = row.get!string(1);
        foreach (row; world.query!"SELECT entry, ScriptName FROM gameobject_template WHERE ScriptName <> ''"())
            gameObjectScriptNames[row.get!uint(0)] = row.get!string(1);
        foreach (row; world.query!"SELECT Id, ScriptName FROM spell_scripts"())
            spellScriptNames[row.get!uint(0)] = row.get!string(1);
        foreach (row; world.query!"SELECT entry, ScriptName FROM scripted_areatrigger"())
            areaTriggerScriptNames[row.get!uint(0)] = row.get!string(1);
        foreach (row; world.query!("SELECT Entry, PositionX, PositionY, PositionZ, Orientation, WaitTime FROM script_waypoint "
                ~ "WHERE PathId = 0 ORDER BY Entry, Point")())
            escortPaths[row.get!uint(0)] ~= Waypoint(Location(row.get!float(1), row.get!float(2), row.get!float(3),
                row.get!float(4)), row.get!uint(5));
        // Newer escort paths (`waypoint_path`, named "... Escort path"), by the creature entry they are numbered by.
        Waypoint[][uint] named;
        foreach (row; world.query!("SELECT p.PathId, p.PositionX, p.PositionY, p.PositionZ, p.Orientation, p.WaitTime "
                ~ "FROM waypoint_path p JOIN waypoint_path_name n ON n.PathId = p.PathId "
                ~ "WHERE n.Name LIKE '%Escort%' ORDER BY p.PathId, p.Point")())
            named[row.get!uint(0)] ~= Waypoint(Location(row.get!float(1), row.get!float(2), row.get!float(3),
                row.get!float(4)), row.get!uint(5));
        foreach (entry, path; named)
            if (entry !in escortPaths)
                escortPaths[entry] = path;
        foreach (row; world.query!"SELECT entry, content_default, type, language, emote, sound FROM script_texts"())
        {
            BroadcastText text;
            text.maleText = row.get!string(1);
            text.chatType = row.get!uint(2);
            text.language = row.get!uint(3);
            text.emotes[0].emote = row.get!uint(4);
            scriptTexts[row.get!int(0)] = text;
            if (row.get!uint(5))
                scriptTextSounds[row.get!int(0)] = row.get!uint(5);
        }
        foreach (row; world.query!"SELECT map, ghostEntranceMap, ghostEntranceX, ghostEntranceY, maxPlayers, reset_delay FROM instance_template"())
        {
            if (row.get!uint(5))
                instanceResetDays[row.get!uint(0)] = row.get!uint(5);
            ghostEntrances[row.get!uint(0)] = GhostEntrance(row.get!int(1), row.get!float(2), row.get!float(3));
            if (row.get!uint(4))
                instanceMaxPlayers[row.get!uint(0)] = row.get!uint(4);
        }
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

        // The game events' spawns (`dmangos.world.gameevents`): in the world or not as their events are.
        foreach (row; world.query!"SELECT guid, event FROM game_event_creature"())
            creatureGameEvents[row.get!uint(0)] = cast(short) row.get!int(1);
        foreach (row; world.query!"SELECT guid, event FROM game_event_gameobject"())
            gameObjectGameEvents[row.get!uint(0)] = cast(short) row.get!int(1);
        // Which spawns are out: the pool members not chosen this time.
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

        // Spawn groups: at most MaxCount members up at once, entries for members without one;
        // groups that depend on a world state stay down, as no world state is kept yet.
        auto groups = new SpawnGroups;
        foreach (row; world.query!"SELECT Id, Type, MaxCount, WorldState, WorldStateExpression FROM spawn_group"())
            groups.add(row.get!uint(0), row.get!uint(1), row.get!int(2), row.get!int(3) != 0 || row.get!int(4) != 0);
        foreach (row; world.query!"SELECT Id, Guid FROM spawn_group_spawn"())
            groups.addSpawn(row.get!uint(0), row.get!uint(1));
        foreach (row; world.query!"SELECT Id, Entry, Chance, MinCount, MaxCount FROM spawn_group_entry"())
            groups.addEntry(row.get!uint(0), row.get!uint(1), row.get!uint(2), row.get!uint(3), row.get!uint(4));
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

            if (!pools.spawns(PoolMember.Kind.creature, row.guid) || row.guid >= 1 << 24
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
            // A wander needs a distance, and only a wander has one.
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
            if (!pools.spawns(PoolMember.Kind.gameObject, s.guid) || s.guid >= 1 << 24
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
     * Waypoints from `creature_movement` (by spawn guid) and `creature_movement_template`
     * (by entry and path): points outside the world are left out (the database is not
     * changed), and so are paths with a point 0.
     */
    void loadWaypoints(MySqlConnection world)
    {
        import std.math : abs;

        static bool valid(const ref WaypointNode n)
        {
            enum float limit = 17_066.6656f; // half a map's width, less half a yard
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
        foreach (row; world.query!("SELECT PathId, Point, PositionX, PositionY, PositionZ, Orientation, WaitTime, "
            ~ "ScriptId FROM waypoint_path")())
        {
            const n = node(row, 1);
            if (valid(n))
                waypoints.addPathNode(row.get!uint(0), n);
        }
        waypoints.finish();
        info!"loaded %s creature waypoint paths (%s points skipped)"(waypoints.length, skipped);
    }

    /// Area trigger teleports and `.recall` places, checked against the client data.
    /// The game events and their dates (`game_event`, `game_event_time`).
    void loadGameEvents(MySqlConnection world)
    {
        import std.datetime : DateTime, LocalTime, SysTime;

        GameEvent[ushort] byId;
        foreach (row; world.query!"SELECT entry, schedule_type, occurence, length, holiday, description, linkedTo FROM game_event"())
        {
            const id = row.get!uint(0);
            if (id == 0 || id > ushort.max)
                continue;
            // A schedule type this server does not know never starts by itself.
            const type = row.get!uint(1);
            ScheduleType schedule = ScheduleType.serverSide;
            static foreach (known; __traits(allMembers, ScheduleType))
                if (type == __traits(getMember, ScheduleType, known))
                    schedule = cast(ScheduleType) type;
            byId[cast(ushort) id] = GameEvent(cast(ushort) id, schedule, 0, 0, row.get!uint(2),
                row.get!uint(3), row.get!uint(4), row.get!string(5), cast(ushort) row.get!uint(6));
        }
        foreach (row; world.query!"SELECT entry, UNIX_TIMESTAMP(start_time), UNIX_TIMESTAMP(end_time) FROM game_event_time"())
            if (auto e = cast(ushort) row.get!uint(0) in byId)
            {
                e.start = row.get!long(1);
                e.end = row.get!long(2);
            }
        gameEvents = byId.values;
        foreach (row; world.query!"SELECT quest, event FROM game_event_quest"())
            questGameEvents[row.get!uint(0)] ~= cast(ushort) row.get!uint(1);
        info!"loaded %s game events"(gameEvents.length);
    }

    /// Random properties (`item_enchantment_template`) and what properties and enchantments are (the DBCs).
    void loadEnchantments(MySqlConnection world, const ClientData client)
    {
        foreach (row; world.query!"SELECT entry, ench, chance FROM item_enchantment_template"())
            randomProperties[row.get!uint(0)] ~= RandomEnchantment(row.get!uint(1), row.get!float(2));
        setEnchantments(client);
        loot.randomProperties = cast(const(RandomEnchantment[])[uint]) randomProperties;
        info!"loaded %s random property lists, %s enchantments"(randomProperties.length, enchantmentEffects.length);
    }

    /// The properties' and enchantments' data from the client's DBCs.
    void setEnchantments(const ClientData client)
    {
        foreach (ref p; client.itemRandomProperties.rows)
            propertyEnchantments[p.id] = p.enchantments;
        foreach (ref e; client.spellItemEnchantments.rows)
        {
            EnchantmentEffect[3] effects;
            foreach (i; 0 .. 3)
                effects[i] = EnchantmentEffect(e.type[i] <= EnchantmentType.max ? cast(EnchantmentType) e.type[i]
                    : EnchantmentType.none, e.amount[i], e.arg[i]);
            enchantmentEffects[e.id] = effects;
        }
    }

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
    /// What new characters start with, and the race and class stats per level.
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
        foreach (ref table; classLevelStats) // fill gaps with the level below
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

    /// Whether an action button's slot, type and action are valid.
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

/// A name in lower case (by `wcharToLower`), used for reserved name comparisons.
dstring toLowerName(string name) pure @safe
{
    import std.utf : toUTF32;

    auto text = name.toUTF32.dup;
    foreach (ref c; text)
        c = wcharToLower(c);
    return text.idup;
}

/// Lower case for the Latin, Latin-1, Latin Extended-A (up to U+012F) and Cyrillic capitals; other characters unchanged.
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

/// Upper case for the same letters as `wcharToLower`; other characters unchanged.
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
 * Pools at start-up: each pool spawns at most its `max_limit` members, chosen at random
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
 * Spawn groups (`spawn_group`, `spawn_group_spawn`, `spawn_group_entry`), as far as a
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
        uint[] minCounts, maxCounts; // per entry: at least, at most so many members (0: no limit)
    }

    private uint[uint] assigned; // spawn guid -> the entry its group gave it (`choose`)

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
    void addEntry(uint id, uint entry, uint chance, uint minCount = 0, uint maxCount = 0)
    {
        if (auto group = id in groups)
        {
            group.entries ~= entry;
            group.chances ~= chance;
            group.minCounts ~= minCount;
            group.maxCounts ~= maxCount;
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
            assignEntries(group, members[0 .. count], rng);
        }
    }

    /**
     * A group's entries for its members: each entry's `MinCount` first (one Lady Anacondra),
     * then the rest by chance among the entries not at their `MaxCount` (three Druids of the Fang).
     */
    private void assignEntries(const ref Group group, const(uint)[] members, ref Random rng)
    {
        import std.random : uniform;

        if (group.entries.length == 0)
            return;
        auto used = new uint[group.entries.length];
        size_t next;
        foreach (i, minimum; group.minCounts)
            foreach (_; 0 .. minimum)
                if (next < members.length)
                {
                    assigned[members[next++]] = group.entries[i];
                    ++used[i];
                }
        foreach (guid; members[next .. $])
        {
            uint total;
            size_t open, last;
            foreach (i; 0 .. group.entries.length)
                if (group.maxCounts[i] == 0 || used[i] < group.maxCounts[i])
                {
                    total += group.chances[i];
                    ++open;
                    last = i;
                }
            if (open == 0)
                break;
            size_t pick = last;
            if (total == 0)
            {
                auto n = uniform(0, open, rng);
                foreach (i; 0 .. group.entries.length)
                    if (group.maxCounts[i] == 0 || used[i] < group.maxCounts[i])
                        if (n-- == 0)
                        {
                            pick = i;
                            break;
                        }
            }
            else
            {
                auto roll = uniform(0, total, rng);
                foreach (i; 0 .. group.entries.length)
                    if (group.maxCounts[i] == 0 || used[i] < group.maxCounts[i])
                    {
                        if (roll < group.chances[i])
                        {
                            pick = i;
                            break;
                        }
                        roll -= group.chances[i];
                    }
            }
            assigned[guid] = group.entries[pick];
            ++used[pick];
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

        if (const entry = guid in assigned)
            return *entry;
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

    // `MinCount` and `MaxCount`: one Lady Anacondra and three Druids of the Fang among four spots.
    {
        auto fang = new SpawnGroups;
        fang.add(4300001, 0, 0, false);
        foreach (guid; [1u, 2, 3, 4])
            fang.addSpawn(4300001, guid);
        fang.addEntry(4300001, 3671, 0, 1, 1);
        fang.addEntry(4300001, 3840, 0, 3, 3);
        foreach (seed; 0 .. 20)
        {
            auto r = Random(seed);
            fang.choose(r);
            uint ladies;
            foreach (guid; [1u, 2, 3, 4])
                ladies += fang.entryFor(guid, r) == 3671;
            assert(ladies == 1, "one Anacondra");
        }
    }
    assert(entry == 100 || entry == 101);
}

// Every loot store exists from the start (the loader fills them; a missing one would crash it).
unittest
{
    import dmangos.world.loot : LootStore;

    auto data = new WorldData;
    static foreach (member; __traits(allMembers, typeof(data.loot)))
        static if (is(typeof(__traits(getMember, data.loot, member)) == LootStore))
            assert(__traits(getMember, data.loot, member) !is null, "the " ~ member ~ " loot store");
}
