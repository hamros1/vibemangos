/**
 * Game constants shared by the world server's modules: classes, powers,
 * stats, item classes and inventory types, inventory positions, action
 * buttons and unit flags.
 *
 * Values with a fixed set of members are enums, so a class can't be passed
 * where a power type is expected. Inventory positions stay plain `ubyte`
 * constants: they are arithmetic (ranges of slots), not choices.
 */
module dmangos.world.defines;

/// The player classes (`ChrClasses.dbc` ids).
enum PlayerClass : ubyte
{
    warrior = 1,
    paladin = 2,
    hunter = 3,
    rogue = 4,
    priest = 5,
    shaman = 7,
    mage = 8,
    warlock = 9,
    druid = 11,
}

/// The power types, also the index of a power in `UNIT_FIELD_POWER1..5`.
enum Power : ubyte
{
    mana,
    rage,
    focus,
    energy,
    happiness,
}

/// Number of powers.
enum maxPowers = Power.max + 1;

/// The primary stats, also the index of a stat in `UNIT_FIELD_STAT0..4`.
enum Stat : ubyte
{
    strength,
    agility,
    stamina,
    intellect,
    spirit,
}

/// Item classes (`item_template.class`).
enum ItemClass : uint
{
    consumable = 0,
    container = 1,
    weapon = 2,
    armor = 4,
    reagent = 5,
    projectile = 6,
    tradeGoods = 7,
    recipe = 9,
    quiver = 11,
    quest = 12,
    key = 13,
    misc = 15,
}

/// Skill categories (`SkillLine.dbc`'s category)
enum SkillCategory : int
{
    attributes = 5,
    weapon = 6,
    classSkill = 7,
    armor = 8,
    secondary = 9,
    languages = 10,
    profession = 11,
}

/// Where an item is worn (`item_template.InventoryType`).
enum InventoryType : ubyte
{
    nonEquip = 0, head, neck, shoulders, body, chest, waist, legs, feet, wrists, hands, finger, trinket, weapon,
    shield, ranged, cloak, twoHandWeapon, bag, tabard, robe, weaponMainhand, weaponOffhand, holdable, ammo, thrown,
    rangedRight, quiver, relic,
}

/// Number of explored-zone bit fields (`PLAYER_EXPLORED_ZONES_1` on).
enum exploredZonesSize = 64;

/// The rest state, kept in the top byte of `playerBytes2`.
enum RestState : ubyte
{
    rested = 0x01,
    normal = 0x02,
}

// Inventory positions: equipment, bags, backpack, bank, buyback and keyring slots.

enum ubyte inventorySlotBag0 = 255;  /// the player itself as a bag: equipment, backpack, bank
enum ubyte nullBag = 0;              /// no bag
enum ubyte nullSlot = 255;           /// no slot

enum : ubyte
{
    equipmentSlotHead = 0, equipmentSlotNeck, equipmentSlotShoulders, equipmentSlotBody, equipmentSlotChest,
    equipmentSlotWaist, equipmentSlotLegs, equipmentSlotFeet, equipmentSlotWrists, equipmentSlotHands,
    equipmentSlotFinger1, equipmentSlotFinger2, equipmentSlotTrinket1, equipmentSlotTrinket2, equipmentSlotBack,
    equipmentSlotMainhand, equipmentSlotOffhand, equipmentSlotRanged, equipmentSlotTabard,
    equipmentSlotEnd, /// 19
}

enum ubyte inventorySlotBagStart = 19, inventorySlotBagEnd = 23;   ///
enum ubyte inventorySlotItemStart = 23, inventorySlotItemEnd = 39; ///
enum ubyte bankSlotItemStart = 39, bankSlotItemEnd = 63;           ///
enum ubyte bankBagSlotStart = 63, bankBagSlotEnd = 69;             ///
enum ubyte buybackSlotStart = 69, buybackSlotEnd = 81;             ///
enum ubyte keyringSlotStart = 81, keyringSlotEnd = 97;             ///
enum playerSlots = keyringSlotEnd;                                  /// positions of bag 0 creation uses

/// Number of action bar buttons.
enum maxActionButtons = 120;

/// What an action button holds: a spell, a macro or an item.
enum ActionButtonType : ubyte
{
    spell = 0x00,
    macro_ = 0x40,
    item = 0x80,
}

/// Unit flags (`UNIT_FIELD_FLAGS`).
enum UnitFlags : uint
{
    spawning = 0x00000002,         /// not attackable
    playerControlled = 0x00000008, /// players and what they control
    notAttackable1 = 0x00000080,
    immuneToPlayer = 0x00000100,
    immuneToNpc = 0x00000200,
    looting = 0x00000400,          /// its loot window is open
    pvp = 0x00001000,
    swimming = 0x00008000,         /// swims (a creature of the water, in it)
    untargetable = 0x00010000,
    pacified = 0x00020000,
    stunned = 0x00040000,
    inCombat = 0x00080000,
    taxiFlight = 0x00100000,
    disarmed = 0x00200000,
    fleeing = 0x00800000,          /// running in fear
    uninteractible = 0x02000000,
    skinnable = 0x04000000,        /// a creature with a skin to take; a player dead in a battleground: its insignia
}

