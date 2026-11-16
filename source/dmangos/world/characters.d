/**
 * Turning `characters` rows into character screen entries, as CMaNGOS's
 * `Player::BuildEnumData` does.
 */
module dmangos.world.characters;

import std.typecons : Nullable, nullable;

import dmangos.world.database : CharacterRecord;
import dmangos.world.packets : CharacterEntry, characterListEquipmentSlots, EquipmentDisplay;
import dmangos.world.worlddata : ItemTemplate, PlayerInfo, WorldData;

/// `characters.playerFlags` bits that the character screen shows (`PlayerFlags`).
enum PlayerFlags : uint
{
    ghost = 0x00000010,
    hideHelm = 0x00000400,
    hideCloak = 0x00000800,
}

/// `characters.at_login` bits (`AtLoginFlags`).
enum AtLoginFlags : uint
{
    rename = 0x01,
    firstLogin = 0x20,
}

/// Flags in a character screen entry (`CharacterFlags`).
enum CharacterFlags : uint
{
    hideHelm = 0x00000400,
    hideCloak = 0x00000800,
    ghost = 0x00002000,
    rename = 0x00004000,
}

/// Classes that keep a pet next to them on the character screen.
private enum ubyte classHunter = 3, classWarlock = 9;

/// The high part of a player's 64-bit guid (`HIGHGUID_PLAYER`); players use the low 32 bits.
enum ulong playerGuidHigh = 0x0000;

/// The character screen entry for `record`, or null if its race/class pair does not exist.
Nullable!CharacterEntry buildCharacterEntry(const ref CharacterRecord record, const WorldData data)
{
    if (!data.isValidRaceClass(record.race, record.classId))
        return Nullable!CharacterEntry.init;

    CharacterEntry entry;
    entry.guid = playerGuidHigh << 48 | record.guid;
    entry.name = record.name;
    entry.race = record.race;
    entry.classId = record.classId;
    entry.gender = record.gender;
    entry.skin = cast(ubyte) record.playerBytes;
    entry.face = cast(ubyte)(record.playerBytes >> 8);
    entry.hairStyle = cast(ubyte)(record.playerBytes >> 16);
    entry.hairColor = cast(ubyte)(record.playerBytes >> 24);
    entry.facialHair = cast(ubyte) record.playerBytes2;

    const firstLogin = (record.atLogin & AtLoginFlags.firstLogin) != 0;
    // A character that has never entered the world is listed at level 0 (shown as 1).
    entry.level = firstLogin && record.level == 1 ? 0 : record.level;
    entry.zone = record.zone;
    entry.map = record.map;
    entry.x = record.x;
    entry.y = record.y;
    entry.z = record.z;
    entry.guildId = record.guildId;

    // Compile-time table: which player flag maps to which character flag.
    static immutable uint[2][] flagMap = [
        [PlayerFlags.hideHelm, CharacterFlags.hideHelm],
        [PlayerFlags.hideCloak, CharacterFlags.hideCloak],
        [PlayerFlags.ghost, CharacterFlags.ghost],
    ];
    foreach (pair; flagMap)
        if (record.playerFlags & pair[0])
            entry.flags |= pair[1];
    if (record.atLogin & AtLoginFlags.rename)
        entry.flags |= CharacterFlags.rename;
    entry.firstLogin = firstLogin;

    const isGhost = (record.playerFlags & PlayerFlags.ghost) != 0;
    if (!isGhost && (record.classId == classHunter || record.classId == classWarlock))
    {
        if (auto family = record.petEntry in data.creatureFamilies)
        {
            entry.petDisplayId = record.petModel;
            entry.petLevel = record.petLevel;
            entry.petFamily = *family;
        }
    }

    const items = equippedItems(record.equipmentCache);
    foreach (slot; 0 .. characterListEquipmentSlots)
        if (auto display = items[slot] in data.items)
            entry.equipment[slot] = EquipmentDisplay(display.displayId, display.inventoryType);
    return nullable(entry);
}

/**
 * Item entries per equipment slot, from `characters.equipmentCache`: a space-separated list
 * of "entry enchantment" pairs, one per slot. Missing or malformed values are 0, as with
 * CMaNGOS's `GetUInt32ValueFromArray`.
 */
uint[characterListEquipmentSlots] equippedItems(string equipmentCache) pure @safe
{
    import std.algorithm.iteration : splitter;
    import std.conv : ConvException, to;

    uint[characterListEquipmentSlots] items;
    size_t index;
    foreach (token; equipmentCache.splitter(' '))
    {
        if (token.length == 0)
            continue;
        if (index % 2 == 0 && index / 2 < items.length)
        {
            try
                items[index / 2] = token.to!uint;
            catch (ConvException)
            {
            }
        }
        ++index;
    }
    return items;
}

unittest
{
    auto data = new WorldData;
    data.playerInfo[WorldData.raceClassKey(1, 1)] = PlayerInfo.init; // human warrior
    data.playerInfo[WorldData.raceClassKey(3, 3)] = PlayerInfo.init; // dwarf hunter
    data.items[25] = ItemTemplate.display(1542, 13);
    data.items[6125] = ItemTemplate.display(9891, 4);
    data.creatureFamilies[299] = 1; // a wolf

    CharacterRecord warrior;
    warrior.guid = 7;
    warrior.name = "Anduin";
    warrior.race = 1;
    warrior.classId = 1;
    warrior.playerBytes = 0x04030201;
    warrior.playerBytes2 = 0x05;
    warrior.level = 1;
    warrior.atLogin = AtLoginFlags.firstLogin;
    warrior.playerFlags = PlayerFlags.hideHelm;
    warrior.equipmentCache = "0 0 0 0 0 0 6125 0 0 0 0 0 0 0 0 0 25 0 bogus";

    const entry = buildCharacterEntry(warrior, data).get;
    assert(entry.guid == 7 && entry.name == "Anduin");
    assert(entry.skin == 1 && entry.face == 2 && entry.hairStyle == 3 && entry.hairColor == 4 && entry.facialHair == 5);
    assert(entry.level == 0 && entry.firstLogin == 1, "an unplayed level-1 character is listed at level 0");
    assert(entry.flags == CharacterFlags.hideHelm);
    assert(entry.equipment[3] == EquipmentDisplay(9891, 4));
    assert(entry.equipment[8] == EquipmentDisplay(1542, 13));
    assert(entry.equipment[0] == EquipmentDisplay.init);

    CharacterRecord hunter;
    hunter.race = 3;
    hunter.classId = 3;
    hunter.level = 12;
    hunter.petEntry = 299;
    hunter.petModel = 903;
    hunter.petLevel = 11;
    const withPet = buildCharacterEntry(hunter, data).get;
    assert(withPet.level == 12 && withPet.petDisplayId == 903 && withPet.petLevel == 11 && withPet.petFamily == 1);

    hunter.playerFlags = PlayerFlags.ghost;
    const ghost = buildCharacterEntry(hunter, data).get;
    assert(ghost.petDisplayId == 0 && ghost.flags == CharacterFlags.ghost, "ghosts are listed without their pet");

    CharacterRecord invalid;
    invalid.race = 1;
    invalid.classId = 9; // no human warlocks in 1.12
    assert(buildCharacterEntry(invalid, data).isNull);
}
