/**
 * Static game data from the CMaNGOS world (`mangos`) database.
 *
 * As in CMaNGOS, everything is read into memory once at start-up. The
 * `playercreateinfo_*` tables go through the same filters as
 * `ObjectMgr::LoadPlayerInfo`, so a character gets exactly what mangosd
 * would give it.
 */
module dmangos.world.worlddata;

import dmangos.log;
import dmangos.mysql : MySqlConnection;
import dmangos.world.clientdata : ClientData, maskOf, maxSkillStep, playableClassMask, playableRaceMask;
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
        ["Material", "material"], ["sheath", "sheath"], ["block", "block"], ["itemset", "itemSet"],
        ["area", "area"], ["Map", "map"]];
    return columns;
}();

/// The statement that reads `itemDetailColumns`, entry first.
private enum itemDetailQuery = () {
    string sql = "SELECT entry";
    foreach (column; itemDetailColumns)
        sql ~= ", " ~ column[0];
    return sql ~ " FROM item_template";
}();

static assert(itemDetailColumns.length == 6 + 20 + 15 + 7 + 3 + 20 + 12);

/// `creature_model_info`: a model's size.
struct ModelInfo
{
    float boundingRadius = 0;
    float combatReach = 0;
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

/// See the module documentation.
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

final class WorldData
{
    ItemTemplate[uint] items;               /// by entry
    ubyte[uint] creatureFamilies;           /// `creature_template.Family`, by entry; every creature is present
    PlayerInfo[ushort] playerInfo;          /// by `raceClassKey`
    ClassLevelStats[][uint] classLevelStats; /// by class, index = level - 1
    bool[dstring] reservedNames;            /// lower-cased
    SpellData spells;
    uint[] xpForNextLevel;                  /// `player_xp_for_level`, index = level
    ModelInfo[uint] models;                 /// `creature_model_info`, by display id
    AreaTriggerTeleport[uint] areaTriggers; /// `areatrigger_teleport`, by trigger id
    GameTele[] teleports;                   /// `game_tele`, in id order

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
        if (auto player = createInfo(race, classId))
        {
            if (player.levelStats.length == 0 || level == 0)
                return LevelStats.init;
            return player.levelStats[(level <= player.levelStats.length ? level : player.levelStats.length) - 1];
        }
        return LevelStats.init;
    }

    /// `GetPlayerClassLevelInfo`
    ClassLevelStats classStats(ubyte classId, uint level) const
    {
        const table = classLevelStats.get(classId, null);
        if (table.length == 0 || level == 0)
            return ClassLevelStats.init;
        return table[(level <= table.length ? level : table.length) - 1];
    }

    /// Reads the tables from a world database. `client` is needed to validate create skills.
    static WorldData load(MySqlConnection world, const ClientData client)
    {
        auto data = new WorldData;
        data.spells = SpellData.load(world, client);

        foreach (row; world.queryAs!(ItemRow, "SELECT entry, class, subclass, displayid, Flags, BuyCount, "
            ~ "InventoryType, AllowableClass, AllowableRace, RequiredLevel, RequiredSkill, RequiredSkillRank, "
            ~ "requiredspell, requiredhonorrank, RequiredReputationFaction, RequiredReputationRank, maxcount, "
            ~ "stackable, ContainerSlots, spellcharges_1, spellcharges_2, spellcharges_3, spellcharges_4, "
            ~ "spellcharges_5, spellcategory_1, spellcategory_2, spellcategory_3, spellcategory_4, spellcategory_5, "
            ~ "bonding, RandomProperty, MaxDurability, BagFamily, Duration FROM item_template")())
            data.items[row.entry] = row.toTemplate();
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
        foreach (row; world.query!"SELECT modelid, bounding_radius, combat_reach FROM creature_model_info"())
            data.models[row.get!uint(0)] = ModelInfo(row.get!float(1), row.get!float(2));
        foreach (row; world.query!"SELECT Entry, Family FROM creature_template"())
            data.creatureFamilies[row.get!uint(0)] = cast(ubyte) row.get!int(1);
        foreach (row; world.query!"SELECT name FROM reserved_name"())
            data.reservedNames[toLowerName(row.get!string(0))] = true;

        data.loadTeleports(world, client);
        data.loadPlayerInfo(world, client);
        info!"loaded %s item templates, %s creature templates, %s race/class combinations, %s reserved names"(
            data.items.length, data.creatureFamilies.length, data.playerInfo.length, data.reservedNames.length);
        if (data.playerInfo.length == 0)
            warning!"playercreateinfo is empty: no character can be listed or created (is the world database populated?)"();
        return data;
    }

private:
    /// `ObjectMgr::LoadPlayerInfo`
    /// `ObjectMgr::LoadAreaTriggerTeleports` and `LoadGameTele`, with the same checks.
    void loadTeleports(MySqlConnection world, const ClientData client)
    {
        foreach (row; world.queryAs!(AreaTriggerTeleport, "SELECT id, IFNULL(name, ''), required_level, "
            ~ "required_item, required_item2, required_quest_done, target_map, target_position_x, target_position_y, "
            ~ "target_position_z, target_orientation, IFNULL(status_failed_text, ''), condition_id "
            ~ "FROM areatrigger_teleport")())
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
        foreach (row; world.queryAs!(GameTele, "SELECT position_x, position_y, position_z, orientation, map, name "
            ~ "FROM game_tele ORDER BY id")())
        {
            if (client.isValidMapCoord(row.map, row.x, row.y, row.z, row.orientation))
                teleports ~= row;
            else
                warning!"game_tele: '%s' is not a valid position on map %s"(row.name, row.map);
        }
        info!"loaded %s area trigger teleports and %s teleport locations"(areaTriggers.length, teleports.length);
    }

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
        foreach (classId, ref table; classLevelStats) // fill gaps with the level below, as CMaNGOS does
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
        foreach (key, ref player; playerInfo)
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
