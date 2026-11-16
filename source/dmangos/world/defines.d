/**
 * Game constants shared by the world server's modules (CMaNGOS
 * `Globals/SharedDefines.h`, `Entities/Player.h`, `Entities/ItemPrototype.h`).
 *
 * Values with a fixed set of members are enums, so a class can't be passed
 * where a power type is expected. Inventory positions stay plain `ubyte`
 * constants: they are arithmetic (ranges of slots), not choices.
 */
module dmangos.world.defines;

/// `Classes`
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

/// `Powers`, also the index of a power in `UNIT_FIELD_POWER1..5`.
enum Power : ubyte
{
    mana,
    rage,
    focus,
    energy,
    happiness,
}

/// Number of powers (`MAX_POWERS`).
enum maxPowers = Power.max + 1;

/// `Stats`, also the index of a stat in `UNIT_FIELD_STAT0..4`.
enum Stat : ubyte
{
    strength,
    agility,
    stamina,
    intellect,
    spirit,
}

/// `ItemClass`
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

/// `SkillCategory` (`SkillLine.dbc`'s category)
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

/// `InventoryType`
enum InventoryType : ubyte
{
    nonEquip = 0, head, neck, shoulders, body, chest, waist, legs, feet, wrists, hands, finger, trinket, weapon,
    shield, ranged, cloak, twoHandWeapon, bag, tabard, robe, weaponMainhand, weaponOffhand, holdable, ammo, thrown,
    rangedRight, quiver, relic,
}

/// `REST_STATE_*`, kept in the top byte of `playerBytes2`.
enum RestState : ubyte
{
    rested = 0x01,
    normal = 0x02,
}

// Inventory positions (`EquipmentSlots`, `InventorySlots`, `BankItemSlots`, ...).

enum ubyte inventorySlotBag0 = 255;  /// `INVENTORY_SLOT_BAG_0`
enum ubyte nullBag = 0;              /// `NULL_BAG`
enum ubyte nullSlot = 255;           /// `NULL_SLOT`

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
enum ubyte bankBagSlotStart = 63, bankBagSlotEnd = 69;             ///
enum ubyte keyringSlotStart = 81, keyringSlotEnd = 97;             ///
enum playerSlots = keyringSlotEnd;                                  /// positions of bag 0 creation uses

/// Number of action bar buttons (`MAX_ACTION_BUTTONS`).
enum maxActionButtons = 120;

/// `ActionButtonType`
enum ActionButtonType : ubyte
{
    spell = 0x00,
    macro_ = 0x40,
    item = 0x80,
}
