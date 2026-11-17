/**
 * Test fixtures: a small, consistent set of client (DBC) and world data
 * with two races, three classes, their looks, outfits, skills and spells.
 *
 * Values follow the real 1.12 data where it matters (ids, inventory
 * types, skill categories) so the creation logic runs its real paths.
 */
module dmangos.world.testdata;

version (unittest):

import dmangos.dbc : buildDbc;
import dmangos.world.clientdata;
import dmangos.world.spells;
import dmangos.world.worlddata;
import dmangos.world.creature : CreatureSpawn, CreatureTemplate;
import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate;
import dmangos.world.conditions : Condition, ConditionType, Conditions;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.npcdata;

enum ubyte raceHuman = 1, raceOrc = 2;
enum ubyte classWarrior = 1, classHunter = 3, classMage = 8;

enum uint itemSword = 25, itemShirt = 38, itemJerky = 117, itemHearthstone = 6948, itemStaff = 35;
enum uint itemBow = 2504, itemQuiver = 2101, itemArrow = 2512;

/// Maps of `Map.dbc`, by their real ids, and the Deadmines entrance (`AreaTrigger.dbc` 78).
enum uint mapEasternKingdoms = 0, mapKalimdor = 1, mapDeadmines = 36, mapMoltenCore = 409, mapWarsongGulch = 489;
enum uint triggerDeadmines = 78; /// ditto
enum uint triggerInn = 562;       /// an inn's area trigger (the Lion's Pride Inn), at `innPosition`
enum float[3] innPosition = [-9459.6f, 42.1f, 57.5f]; /// ditto
enum uint zoneElwynn = 12, zoneStormwind = 1519;      /// `AreaTable.dbc`: a zone, and a capital
enum uint zoneStranglethorn = 33, areaGurubashiArena = 2177; /// a contested zone, and its free-for-all arena
enum uint areaGoldshire = 87;                          /// an area of Elwynn, level 5
enum uint exploreElwynn = 40, exploreStormwind = 41, exploreGoldshire = 42; /// their explore flags
enum uint creatureWillem = 823;                        /// Deputy Willem, spawned near Northshire Abbey
/// NPCs right next to the Northshire start position: a warrior trainer, an innkeeper who sells food, a banker.
enum uint creatureTrainer = 911, creatureInnkeeper = 6774, creatureBanker = 2455;
enum uint trainerSpawn = 79950, innkeeperSpawn = 79951, bankerSpawn = 79952; /// ditto, their spawn guids
/// The trainer's lessons: Heroic Strike and its second rank, each taught by a trainer spell.
enum uint spellHeroicStrike = 78, spellHeroicStrike2 = 284, spellTeachHeroicStrike = 9101,
    spellTeachHeroicStrike2 = 9102;
enum float[3] deadminesEntrance = [-11208.5f, 1685.34f, 25.76f]; /// ditto
enum float[4] deadminesInside = [-16.4f, -383.07f, 61.78f, 1.86f]; /// ditto

enum uint skillSwords = 43, skillStaves = 136, skillBows = 45, skillUnarmed = 162, skillCommon = 98,
    skillOrcish = 109, skillFireMagic = 8;
enum uint spellOneHandedSwords = 201, spellStaves = 227, spellBows = 264, spellLanguageCommon = 668,
    spellFireball = 133, spellPassiveTrainer = 9000, spellLearnedByPassive = 9001, spellDualWield = 674;

/// The client data fixture.
ClientData testClientData()
{
    auto client = new ClientData;
    // ChrClasses: id, 2 skipped, powerType, skip, 8 names, 2 skipped, spellFamily, skip
    client.classes = typeof(client.classes).parse(buildDbc(chrClassesFormat, [
        classRecord(classWarrior, 1), classRecord(classHunter, 0), classRecord(classMage, 0),
    ]), "ChrClasses.dbc");
    client.races = typeof(client.races).parse(buildDbc(chrRacesFormat, [
        raceRecord(raceHuman, 7, 0x2), raceRecord(raceOrc, 1, 0x4),
    ]), "ChrRaces.dbc");

    // CharSections: for both races and genders, skin/face/hair/facial hair variation 0 color 0, hair 1 color 0.
    uint[][] sections;
    uint id = 1;
    foreach (race; [raceHuman, raceOrc])
        foreach (gender; [0, 1])
            foreach (section; [[0, 0], [1, 0], [3, 0], [3, 1], [2, 0]])
                sections ~= [id++, race, gender, section[0], section[1], 0, 0, 0, 0, 0];
    client.charSections = typeof(client.charSections).parse(buildDbc(charSectionsFormat, sections), "CharSections.dbc");
    uint[][] facial;
    foreach (race; [raceHuman, raceOrc])
        foreach (gender; [0, 1])
            facial ~= [race, gender, 0, 0, 0, 0, 0, 0, 0];
    client.facialHairStyles = typeof(client.facialHairStyles).parse(buildDbc(characterFacialHairStylesFormat, facial),
        "CharacterFacialHairStyles.dbc");

    // Outfits: human warrior male, orc hunter male, human mage male.
    client.startOutfits = typeof(client.startOutfits).parse(buildDbc(charStartOutfitFormat, [
        outfitRecord(1, raceHuman | classWarrior << 8, [itemSword, itemShirt, itemJerky, itemHearthstone]),
        outfitRecord(2, raceOrc | classHunter << 8, [itemBow, itemQuiver, itemArrow, itemHearthstone]),
        outfitRecord(3, raceHuman | classMage << 8, [itemStaff, itemHearthstone]),
    ]), "CharStartOutfit.dbc");

    // SkillLine: id, category, skip, 8 names, 10 skipped, icon
    client.skillLines = typeof(client.skillLines).parse(buildDbc(skillLineFormat, [
        skillRecord(skillSwords, 6), skillRecord(skillStaves, 6), skillRecord(skillBows, 6),
        skillRecord(skillUnarmed, 6), skillRecord(skillCommon, 10), skillRecord(skillOrcish, 10),
        skillRecord(skillFireMagic, 7),
    ]), "SkillLine.dbc");
    // SkillRaceClassInfo: id, skill, raceMask, classMask, flags, reqLevel, tier, skip
    client.skillRaceClassInfos = typeof(client.skillRaceClassInfos).parse(buildDbc(skillRaceClassInfoFormat, [
        [1, skillSwords, 0xFF, maskOf(classWarrior), 0, 0, 0, 0],
        [2, skillStaves, 0xFF, maskOf(classMage) | maskOf(classWarrior), 0, 0, 0, 0],
        [3, skillBows, 0xFF, maskOf(classHunter) | maskOf(classWarrior), 0, 0, 0, 0],
        [4, skillUnarmed, 0xFF, 0x5DF, 0, 0, 0, 0],
        [5, skillCommon, maskOf(raceHuman), 0x5DF, 0, 0, 0, 0],
        [6, skillOrcish, maskOf(raceOrc), 0x5DF, 0, 0, 0, 0],
        [7, skillFireMagic, 0xFF, maskOf(classMage), skillFlagMaximized, 0, 0, 0],
    ]), "SkillRaceClassInfo.dbc");
    // SkillLineAbility: id, skill, spell, raceMask, classMask, 2 skipped, reqValue, forward, learnOnGetSkill, max,
    // min, 2 skipped, trainPoints
    client.skillLineAbilities = typeof(client.skillLineAbilities).parse(buildDbc(skillLineAbilityFormat, [
        abilityRecord(1, skillSwords, spellOneHandedSwords, 2),
        abilityRecord(2, skillStaves, spellStaves, 2),
        abilityRecord(3, skillBows, spellBows, 2),
        abilityRecord(4, skillCommon, spellLanguageCommon, 2),
        abilityRecord(5, skillFireMagic, spellFireball, 0),
    ]), "SkillLineAbility.dbc");
    // Map: id, skip, type, skip, 8 names, ..., the area at 19, the loading screen at 38.
    uint[] mapRecord(uint id, uint type)
    {
        auto record = new uint[mapFormat.length];
        record[0] = id;
        record[2] = type;
        return record;
    }
    client.maps = typeof(client.maps).parse(buildDbc(mapFormat, [mapRecord(mapEasternKingdoms, MapType.common),
        mapRecord(mapKalimdor, MapType.common), mapRecord(mapDeadmines, MapType.instance),
        mapRecord(mapMoltenCore, MapType.raid), mapRecord(mapWarsongGulch, MapType.battleground)]), "Map.dbc");
    // AreaTrigger: id, map, x, y, z, radius, box.
    client.areaTriggers = typeof(client.areaTriggers).parse(buildDbc(areaTriggerFormat, [[triggerDeadmines,
        mapEasternKingdoms, floatBits(deadminesEntrance[0]), floatBits(deadminesEntrance[1]),
        floatBits(deadminesEntrance[2]), floatBits(5), 0, 0, 0, 0], [triggerInn, mapEasternKingdoms,
        floatBits(innPosition[0]), floatBits(innPosition[1]), floatBits(innPosition[2]), floatBits(10), 0, 0, 0, 0]]),
        "AreaTrigger.dbc");
    // AreaTable: id, map, zone, explore flag, flags (0x100 for a capital), ..., area level (10), ..., team (20)
    uint[] areaRecord(uint id, uint flags, uint explore, uint zone = 0, uint level = 0, uint team = 0)
    {
        auto record = new uint[areaTableFormat.length];
        record[0] = id;
        record[2] = zone;
        record[3] = explore;
        record[4] = flags;
        record[10] = level;
        record[20] = team;
        return record;
    }
    // Elwynn and Stormwind are the Alliance's (team 2); the Gurubashi Arena (area 2177) is free-for-all.
    client.areas = typeof(client.areas).parse(buildDbc(areaTableFormat, [areaRecord(zoneElwynn, 0, exploreElwynn, 0, 0, 2),
        areaRecord(zoneStormwind, 0x100, exploreStormwind, 0, 0, 2), areaRecord(areaGoldshire, 0, exploreGoldshire, zoneElwynn, 5, 2),
        areaRecord(zoneStranglethorn, 0, 0), areaRecord(areaGurubashiArena, 0x80, 0, zoneStranglethorn)]),
        "AreaTable.dbc");
    // WMOAreaTable: the test house's group (root 500, name set 3, group 600) is in Goldshire.
    auto wmoArea = new uint[wmoAreaTableFormat.length];
    wmoArea[0] = 1;
    wmoArea[1] = testHouseRoot;
    wmoArea[2] = testHouseNameSet;
    wmoArea[3] = testHouseGroup;
    wmoArea[10] = areaGoldshire;
    client.wmoAreas = typeof(client.wmoAreas).parse(buildDbc(wmoAreaTableFormat, [wmoArea]), "WMOAreaTable.dbc");
    client.buildIndexes();
    return client;
}

/// The building of the vmap tests: its WMO root and group ids and its placement's name set.
enum int testHouseRoot = 500, testHouseGroup = 600, testHouseNameSet = 3;

private uint floatBits(float value) @trusted
{
    return *cast(uint*)&value;
}

/// Item guids for tests: 1000, 1001, ...
uint delegate() testItemGuids()
{
    uint next = 1000;
    return () => next++;
}

/// The world data fixture, consistent with `testClientData`.
WorldData testWorldData(const ClientData client)
{
    auto world = new WorldData;
    world.items[itemSword] = item(itemSword, 2, 7, 1542, 21, 1, 1, 0, 20);   // one-hand sword, main hand
    world.items[itemShirt] = item(itemShirt, 4, 0, 9891, 4, 1, 1, 0, 0);     // shirt
    world.items[itemJerky] = item(itemJerky, 0, 0, 2473, 0, 5, 20, 0, 0);    // food, BuyCount 5
    world.items[itemHearthstone] = item(itemHearthstone, 15, 0, 6418, 0, 1, 1, 1, 0); // binds when picked up
    world.items[itemStaff] = item(itemStaff, 2, 10, 472, 17, 1, 1, 0, 25);   // staff, two-hand
    world.items[itemBow] = item(itemBow, 2, 2, 8106, 15, 1, 1, 0, 20);       // bow, ranged
    world.items[itemQuiver] = item(itemQuiver, 11, 2, 21328, 18, 1, 1, 0, 0); // quiver, bag type
    world.items.edit(itemQuiver).containerSlots = 6;
    world.items[itemArrow] = item(itemArrow, 6, 2, 5996, 24, 200, 200, 0, 0); // arrows, ammo
    world.items.edit(itemArrow).bagFamily = 1;
    world.items.edit(itemSword).details.name = "Worn Shortsword";
    world.items.edit(itemJerky).details.name = "Tough Jerky";
    world.items.edit(itemJerky).details.buyPrice = 25;
    world.items.edit(itemJerky).details.sellPrice = 1;
    world.items.edit(itemSword).details.sellPrice = 7;

    // The Deadmines entrance needs level 10; a place for `.tele`.
    world.areaTriggers[triggerDeadmines] = AreaTriggerTeleport(triggerDeadmines, "Deadmines - Entering", 10, 0, 0, 0,
        mapDeadmines, deadminesInside[0], deadminesInside[1], deadminesInside[2], deadminesInside[3],
        "You must be at least level 10 to enter.", 0);
    world.taverns[triggerInn] = true;

    // Northshire: Deputy Willem (a quest giver) by the abbey, and a mailbox.
    CreatureTemplate willem;
    willem.entry = creatureWillem;
    willem.name = "Deputy Willem";
    willem.subName = "";
    willem.minLevel = willem.maxLevel = 18;
    willem.modelId1 = 1906;
    willem.faction = 12;
    willem.npcFlags = 2;
    willem.unitClass = 1;
    willem.minLevelHealth = willem.maxLevelHealth = 1342;
    willem.meleeBaseAttackTime = 2000;
    world.creatureTemplates[creatureWillem] = willem;
    world.creatureSpawns = [CreatureSpawn(79942, creatureWillem, mapEasternKingdoms, -8933, -136, 83, 3)];
    addNpcs(world);
    foreach (i, ref spawn; world.creatureSpawns)
        world.creatureCells[mapEasternKingdoms][cellKeyAt(spawn.x, spawn.y)] ~= i;
    GameObjectTemplate mailbox;
    mailbox.entry = 32349;
    mailbox.type = 19;
    mailbox.displayId = 3851;
    mailbox.name = "Mailbox";
    world.gameObjectTemplates[32349] = mailbox;
    world.gameObjectSpawns = [GameObjectSpawn(26880, 32349, mapEasternKingdoms, -8940, -140, 83, 0.5f)];
    world.gameObjectCells[mapEasternKingdoms][cellKeyAt(-8940, -140)] = [0];
    // Warsong Gulch (`battleground_template`, `world_safe_locs`, `mangos_string`).
    {
        import dmangos.world.bgqueue : BattlegroundTemplate, BattlegroundType;
        import dmangos.world.worlddata : SafeLocation;

        world.battlegroundTemplates[BattlegroundType.warsongGulch] = BattlegroundTemplate(2, 5, 10, 10, 60, [769, 770],
            75, 0);
        world.safeLocations[769] = SafeLocation(mapWarsongGulch, 1519.53f, 1481.87f, 352.024f, 3.14159f);
        world.safeLocations[770] = SafeLocation(mapWarsongGulch, 933.331f, 1433.72f, 345.536f, 0);
        world.serverStrings[600] = "The Alliance wins!";
        world.serverStrings[601] = "The Horde wins!";
        world.serverStrings[602] = "The battle for Warsong Gulch begins in 1 minute.";
        world.serverStrings[603] = "The battle for Warsong Gulch begins in 30 seconds. Prepare yourselves!";
        world.serverStrings[604] = "Let the battle for Warsong Gulch begin!";
        world.serverStrings[750] = "Not enough players. This game will close in %u mins.";
        world.serverStrings[751] = "Not enough players. This game will close in %u seconds.";
    }
    world.teleports = [GameTele(-9464, 62, 56, 0, mapEasternKingdoms, "Goldshire"),
        GameTele(1629, -4373, 31, 3.5f, mapKalimdor, "Orgrimmar")];

    auto spells = new SpellData;
    foreach (id; [spellOneHandedSwords, spellStaves, spellBows, spellLanguageCommon, spellFireball,
        spellPassiveTrainer, spellLearnedByPassive, spellDualWield])
        spells.spells[id] = SpellInfo(id);
    // A passive spell that, cast at learning, teaches another spell (saved as non-dependent).
    spells.spells.edit(spellPassiveTrainer).attributes = spellAttrPassive;
    spells.spells.edit(spellPassiveTrainer).effect[0] = SpellEffect.learnSpell;
    spells.spells.edit(spellPassiveTrainer).triggerSpell[0] = spellLearnedByPassive;
    spells.spells.edit(spellDualWield).attributes = spellAttrPassive;
    spells.spells.edit(spellDualWield).effect[0] = SpellEffect.dualWield;
    foreach (id; [spellHeroicStrike, spellHeroicStrike2, spellTeachHeroicStrike, spellTeachHeroicStrike2])
        spells.spells[id] = SpellInfo(id);
    spells.spells.edit(spellTeachHeroicStrike2).spellLevel = 8; // trainers read the level from their own spell
    spells.spells.edit(spellTeachHeroicStrike).effect[0] = SpellEffect.learnSpell;
    spells.spells.edit(spellTeachHeroicStrike).triggerSpell[0] = spellHeroicStrike;
    spells.spells.edit(spellTeachHeroicStrike2).effect[0] = SpellEffect.learnSpell;
    spells.spells.edit(spellTeachHeroicStrike2).triggerSpell[0] = spellHeroicStrike2;
    spells.build(client, null, null);
    spells.chains[spellHeroicStrike2] = SpellChainNode(spellHeroicStrike, spellHeroicStrike, 2, 0);
    world.spells = spells;
    world.npcs.trainers = NpcData.loadTrainers([
        TrainerRow(creatureTrainer, spellTeachHeroicStrike, 10),
        TrainerRow(creatureTrainer, spellTeachHeroicStrike2, 100),
    ], spells);

    PlayerInfo human;
    human.map = 0;
    human.zone = 12;
    human.x = -8949.95f;
    human.y = -132.493f;
    human.z = 83.5312f;
    human.levelStats = [LevelStats([23, 20, 22, 20, 21])];
    PlayerInfo warrior = human;
    warrior.spells = [spellOneHandedSwords, spellLanguageCommon, spellPassiveTrainer];
    warrior.skills = [CreateSkill(skillUnarmed, 0)];
    warrior.actions = [CreateAction(0, 6603, 0)];
    world.playerInfo[WorldData.raceClassKey(raceHuman, classWarrior)] = warrior;

    PlayerInfo mage = human;
    mage.levelStats = [LevelStats([20, 20, 20, 23, 22])];
    mage.spells = [spellStaves, spellLanguageCommon, spellFireball];
    mage.skills = [CreateSkill(skillFireMagic, 0)];
    world.playerInfo[WorldData.raceClassKey(raceHuman, classMage)] = mage;

    PlayerInfo hunter;
    hunter.map = 1;
    hunter.zone = 14;
    hunter.levelStats = [LevelStats([22, 20, 22, 20, 21])];
    hunter.spells = [spellBows];
    world.playerInfo[WorldData.raceClassKey(raceOrc, classHunter)] = hunter;

    world.classLevelStats[classWarrior] = [ClassLevelStats(20, 0)];
    world.classLevelStats[classMage] = [ClassLevelStats(32, 100)];
    world.classLevelStats[classHunter] = [ClassLevelStats(46, 65)];
    world.reservedNames[toLowerName("Thrall")] = true;
    // Frozen as the server freezes what it loads, so the tests read the tables the way it does; a test
    // that changes one thaws it.
    import dmangos.frozen : freezeAll;

    freezeAll(world);
    return world;
}

private ItemTemplate item(uint entry, uint itemClass, uint subClass, uint display, ubyte inventoryType,
    uint buyCount, uint stackable, uint bonding, uint durability)
{
    auto t = ItemTemplate.display(display, inventoryType);
    t.entry = entry;
    t.itemClass = itemClass;
    t.subClass = subClass;
    t.buyCount = buyCount;
    t.stackable = stackable;
    t.bonding = bonding;
    t.maxDurability = durability;
    return t;
}

private uint[] classRecord(uint id, uint powerType)
{
    auto r = new uint[chrClassesFormat.length];
    r[0] = id;
    r[3] = powerType;
    return r;
}

private uint[] raceRecord(uint id, uint team, uint taxiMask)
{
    auto r = new uint[chrRacesFormat.length];
    r[0] = id;
    r[8] = team;
    r[14] = taxiMask;
    return r;
}

private uint[] outfitRecord(uint id, uint raceClassGender, uint[] itemIds)
{
    auto r = new uint[charStartOutfitFormat.length];
    r[0] = id;
    foreach (i; 0 .. 4)
        r[1 + i] = (raceClassGender >> (8 * i)) & 0xFF; // race, class, gender, outfit bytes
    foreach (i, itemId; itemIds)
        r[5 + i] = itemId;
    return r;
}

private uint[] skillRecord(uint id, uint category)
{
    auto r = new uint[skillLineFormat.length];
    r[0] = id;
    r[1] = category;
    return r;
}

private uint[] abilityRecord(uint id, uint skill, uint spell, uint learnOnGetSkill)
{
    auto r = new uint[skillLineAbilityFormat.length];
    r[0] = id;
    r[1] = skill;
    r[2] = spell;
    r[9] = learnOnGetSkill;
    return r;
}

/// A `npc_trainer` row as `NpcData.loadTrainers` reads one: entry, spell, cost, and no requirements.
private struct TrainerRow
{
    uint entry, spell, cost;

    T get(T)(size_t column) const
    {
        switch (column)
        {
        case 0: return cast(T) entry;
        case 1: return cast(T) spell;
        case 2: return cast(T) cost;
        default: return T.init;
        }
    }
}

/// The NPCs of `testWorldData`, their menus, texts, conditions, lessons and wares.
private void addNpcs(WorldData world)
{
    CreatureTemplate npc(uint entry, string name, uint npcFlags)
    {
        CreatureTemplate t;
        t.entry = entry;
        t.name = name;
        t.minLevel = t.maxLevel = 30;
        t.modelId1 = 1906;
        t.faction = 12;
        t.npcFlags = npcFlags;
        t.unitClass = 1;
        t.minLevelHealth = t.maxLevelHealth = 1000;
        t.meleeBaseAttackTime = 2000;
        return t;
    }

    auto trainer = npc(creatureTrainer, "Llane Beshere", 0x1 | 0x10);
    trainer.trainerType = 0;
    trainer.trainerClass = classWarrior;
    trainer.gossipMenuId = 100;
    world.creatureTemplates[creatureTrainer] = trainer;
    world.creatureTemplates[creatureInnkeeper] = npc(creatureInnkeeper, "Innkeeper Farley", 0x1 | 0x4 | 0x80);
    world.creatureTemplates[creatureBanker] = npc(creatureBanker, "Olivia Burnside", 0x1 | 0x100);
    world.creatureSpawns ~= [CreatureSpawn(trainerSpawn, creatureTrainer, mapEasternKingdoms, -8948, -132, 83.5f, 0),
        CreatureSpawn(innkeeperSpawn, creatureInnkeeper, mapEasternKingdoms, -8951, -130, 83.5f, 0),
        CreatureSpawn(bankerSpawn, creatureBanker, mapEasternKingdoms, -8951, -134, 83.5f, 0)];

    auto npcs = world.npcs;
    npcs.conditions = new Conditions([Condition(50, ConditionType.level, 10, 1),
        Condition(51, ConditionType.raceClass, 1 << (raceOrc - 1), 0)]);
    // The trainer's menu: a text for level 10 and up, training, more talk with a map flag, and an orc's option.
    npcs.menus[100] = [GossipMenuText(100, 1001, 0, 0), GossipMenuText(100, 1002, 0, 50)];
    npcs.menus[101] = [GossipMenuText(101, 1003, 0, 0)];
    npcs.options[100] = [
        GossipMenuOption(100, 0, 3, "I require training.", 0, GossipOption.trainer, 0x10),
        GossipMenuOption(100, 1, 0, "Tell me more.", 0, GossipOption.gossip, 0x1, 101, 7),
        GossipMenuOption(100, 2, 0, "For the Horde!", 0, GossipOption.gossip, 0x1, 101, 0, 0, false, 0, "", 0, 51),
    ];
    // The default menu: an innkeeper's, a vendor's and a banker's options, from their broadcast texts.
    npcs.options[0] = [
        GossipMenuOption(0, 1, 1, "GOSSIP_OPTION_VENDOR", 0, GossipOption.vendor, 0x4),
        GossipMenuOption(0, 6, 5, "GOSSIP_OPTION_INNKEEPER", 2822, GossipOption.innkeeper, 0x80),
        GossipMenuOption(0, 7, 6, "GOSSIP_OPTION_BANKER", 0, GossipOption.banker, 0x100),
    ];
    npcs.broadcastTexts[2822] = BroadcastText("Make this inn your home.", "", 0);
    GossipText greeting;
    greeting.options[0].text0 = "Hail, $c.";
    greeting.options[0].probability = 1;
    greeting.options[1].broadcastText = 2822;
    npcs.texts[1001] = greeting;
    npcs.pointsOfInterest[7] = PointOfInterest(-8900, -120, 7, 99, 0, "Northshire Abbey");
    npcs.vendors[creatureInnkeeper] = [VendorItem(itemJerky, 0, 0, 0, 0), VendorItem(itemSword, 0, 0, 0, 51)];
}
