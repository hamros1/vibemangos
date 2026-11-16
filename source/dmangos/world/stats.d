/**
 * A player's derived numbers: stats with item bonuses, health and mana,
 * armor and resistances, attack power, weapon damage and swing times
 * (CMaNGOS `Entities/StatSystem.cpp`, `Player::_ApplyItemBonuses`).
 *
 * Auras and talents are not applied yet, so this is what a character has
 * with its gear and nothing else. Crit, dodge, parry and block chances are
 * left at zero.
 */
module dmangos.world.stats;

import std.algorithm.comparison : max, min;
import std.math : round;

public import dmangos.world.defines : Power, Stat;
import dmangos.world.defines;
import dmangos.world.worlddata : ItemTemplate, LevelStats, ClassLevelStats;

/// `WeaponAttackType`
enum AttackType
{
    mainHand,
    offHand,
    ranged,
}


/// `ItemModType` values that change stats.
private enum : uint
{
    itemModMana = 0,
    itemModHealth = 1,
    itemModAgility = 3,
    itemModStrength = 4,
    itemModIntellect = 5,
    itemModSpirit = 6,
    itemModStamina = 7,
}

private enum uint baseAttackTime = 2000;
private enum float baseMinDamage = 1, baseMaxDamage = 2;
private enum float offHandDamagePct = 0.5f; // UNIT_MOD_DAMAGE_OFFHAND starts at TOTAL_PCT 0.5

/// A weapon's damage range.
struct DamageRange
{
    float min = 0;
    float max = 0;
}

/// Everything `computeStats` derives.
struct PlayerStats
{
    float[5] stats = 0;          /// totals, `UNIT_FIELD_STAT0..4`
    float[5] positiveBonus = 0;  /// from gear, `PLAYER_FIELD_POSSTAT0..4`
    float[5] negativeBonus = 0;  /// `PLAYER_FIELD_NEGSTAT0..4`
    uint maxHealth;
    uint[5] maxPower;            /// by `Power`
    uint baseHealth;
    uint baseMana;
    int[7] resistances;          /// armor, then holy .. arcane
    int attackPower;
    int rangedAttackPower;
    uint[3] attackTime = baseAttackTime; /// by `AttackType`, milliseconds
    DamageRange[3] damage;       /// by `AttackType`
}

/// What `computeStats` needs about a character.
struct StatInputs
{
    ubyte race;
    ubyte classId;
    uint level;
    LevelStats levelStats;
    ClassLevelStats classStats;
    const(ItemTemplate)*[equipmentSlotEnd] equipment; /// null where nothing is equipped
}

/// `Player::InitStatsForLevel`, `_ApplyAllItemMods` and the `Update*` functions of `StatSystem.cpp`.
PlayerStats computeStats(const ref StatInputs input) pure nothrow @safe
in (input.level > 0)
out (result; result.maxHealth >= 1, "a living character has at least one health point")
{
    PlayerStats result;
    result.baseHealth = input.classStats.baseHealth;
    result.baseMana = input.classStats.baseMana;
    foreach (i; 0 .. 5)
        result.stats[i] = input.levelStats.stats[i];

    float healthMod = 0, manaMod = 0, armor = 0;
    float[6] resistance = 0;
    foreach (item; input.equipment)
    {
        if (item is null)
            continue;
        foreach (stat; item.details.stats)
        {
            const value = float(stat.value);
            if (value == 0)
                continue;
            switch (stat.type)
            {
            case itemModMana:
                manaMod += value;
                break;
            case itemModHealth:
                healthMod += value;
                break;
            case itemModAgility:
                addStatBonus(result, Stat.agility, value);
                break;
            case itemModStrength:
                addStatBonus(result, Stat.strength, value);
                break;
            case itemModIntellect:
                addStatBonus(result, Stat.intellect, value);
                break;
            case itemModSpirit:
                addStatBonus(result, Stat.spirit, value);
                break;
            case itemModStamina:
                addStatBonus(result, Stat.stamina, value);
                break;
            default:
                break;
            }
        }
        armor += item.details.armor;
        foreach (i, value; item.details.resistances)
            resistance[i] += value;
    }

    // UpdateMaxHealth, UpdateMaxPower
    result.maxHealth = cast(uint) max(round(healthMod + result.baseHealth
        + healthBonusFromStamina(result.stats[Stat.stamina])), 1);
    if (result.baseMana > 0)
        result.maxPower[Power.mana] = cast(uint) max(round(manaMod + result.baseMana
            + manaBonusFromIntellect(result.stats[Stat.intellect])), 0);
    result.maxPower[Power.rage] = 1000;
    result.maxPower[Power.energy] = 100;

    // UpdateArmor, UpdateResistances
    result.resistances[0] = cast(int)(armor + result.stats[Stat.agility] * 2);
    foreach (i; 0 .. 6)
        result.resistances[i + 1] = cast(int) resistance[i];

    // UpdateAttackPowerAndDamage
    result.attackPower = cast(int) meleeAttackPower(input.classId, input.level, result.stats);
    result.rangedAttackPower = cast(int) rangedAttackPower(input.classId, input.level, result.stats);
    foreach (type; [AttackType.mainHand, AttackType.offHand, AttackType.ranged])
        weaponDamage(input, type, result);
    return result;
}

/// `Player::GetHealthBonusFromStamina`: the first 20 points give 1 health each, the rest 10.
float healthBonusFromStamina(float stamina) pure nothrow @nogc @safe
{
    const base = min(stamina, 20.0f);
    return base + (stamina - base) * 10.0f;
}

/// `Player::GetManaBonusFromIntellect`: the first 20 points give 1 mana each, the rest 15.
float manaBonusFromIntellect(float intellect) pure nothrow @nogc @safe
{
    const base = min(intellect, 20.0f);
    return base + (intellect - base) * 15.0f;
}

private void addStatBonus(ref PlayerStats result, Stat stat, float value) pure nothrow @nogc @safe
{
    result.stats[stat] += value;
    if (value > 0)
        result.positiveBonus[stat] += value;
    else
        result.negativeBonus[stat] += value;
}

private float meleeAttackPower(ubyte classId, uint level, const float[5] s) pure nothrow @nogc @safe
{
    const l = float(level);
    switch (classId)
    {
    case PlayerClass.warrior:
    case PlayerClass.paladin:
    case PlayerClass.druid: // in caster form
        return l * 3 + s[Stat.strength] * 2 - 20;
    case PlayerClass.rogue:
    case PlayerClass.hunter:
        return l * 2 + s[Stat.strength] + s[Stat.agility] - 20;
    case PlayerClass.shaman:
        return l * 2 + s[Stat.strength] * 2 - 20;
    case PlayerClass.mage:
    case PlayerClass.priest:
    case PlayerClass.warlock:
        return s[Stat.strength] - 10;
    default:
        return 0;
    }
}

private float rangedAttackPower(ubyte classId, uint level, const float[5] s) pure nothrow @nogc @safe
{
    const l = float(level);
    switch (classId)
    {
    case PlayerClass.hunter:
        return l * 2 + s[Stat.agility] * 2 - 10;
    case PlayerClass.rogue:
    case PlayerClass.warrior:
        return l + s[Stat.agility] - 10;
    default:
        return s[Stat.agility] - 10;
    }
}

/// `UpdateDamagePhysical` via `CalculateMinMaxDamage`, without auras or ammo.
private void weaponDamage(const ref StatInputs input, AttackType type, ref PlayerStats result) pure nothrow @safe
{
    static immutable ubyte[3] slots = [equipmentSlotMainhand, equipmentSlotOffhand, equipmentSlotRanged];
    const weapon = input.equipment[slots[type]];
    const isWeapon = weapon !is null && weapon.itemClass == ItemClass.weapon;
    // The off hand only fights with a weapon in it; a ranged slot without one has no damage.
    if (!isWeapon && type != AttackType.mainHand)
        return;

    float weaponMin = baseMinDamage, weaponMax = baseMaxDamage;
    if (isWeapon)
    {
        weaponMin = weapon.details.damage[0].min;
        weaponMax = weapon.details.damage[0].max;
        if (weapon.details.delay)
            result.attackTime[type] = weapon.details.delay;
    }
    const attackPower = type == AttackType.ranged ? result.rangedAttackPower : result.attackPower;
    const fromAttackPower = max(attackPower, 0) / 14.0f * (result.attackTime[type] / 1000.0f);
    const pct = type == AttackType.offHand ? offHandDamagePct : 1.0f;
    result.damage[type] = DamageRange(max((fromAttackPower + weaponMin) * pct, 0.0f),
        max((fromAttackPower + weaponMax) * pct, 0.0f));
}

unittest
{
    import std.math : isClose;

    // A level 1 human warrior (23 str, 20 agi, 22 sta, 20 int, 21 spi; 20 base health) with a
    // 2.3-second 2-5 sword and a 3-armor, +1 stamina shirt.
    auto sword = ItemTemplate.display(1542, 21);
    sword.itemClass = 2;
    sword.details.delay = 2300;
    sword.details.damage[0].min = 2;
    sword.details.damage[0].max = 5;
    auto shirt = ItemTemplate.display(9891, 4);
    shirt.details.armor = 3;
    shirt.details.stats[0].type = 7;
    shirt.details.stats[0].value = 1;

    StatInputs input;
    input.race = 1;
    input.classId = PlayerClass.warrior;
    input.level = 1;
    input.levelStats = LevelStats([23, 20, 22, 20, 21]);
    input.classStats = ClassLevelStats(20, 0);
    input.equipment[equipmentSlotMainhand] = &sword;
    input.equipment[4] = &shirt;

    const s = computeStats(input);
    assert(s.stats == [23.0f, 20, 23, 20, 21] && s.positiveBonus[Stat.stamina] == 1);
    assert(s.maxHealth == 20 + 20 + 3 * 10, "base health, then 20 + 10 per stamina point over 20");
    assert(s.maxPower[Power.mana] == 0 && s.maxPower[Power.rage] == 1000 && s.maxPower[Power.energy] == 100);
    assert(s.resistances[0] == 3 + 40, "item armor plus twice the agility");
    assert(s.attackPower == 3 + 46 - 20 && s.rangedAttackPower == 1 + 20 - 10);
    assert(s.attackTime[AttackType.mainHand] == 2300 && s.attackTime[AttackType.offHand] == 2000);
    const fromAp = 29 / 14.0f * 2.3f;
    assert(isClose(s.damage[AttackType.mainHand].min, fromAp + 2) && isClose(s.damage[AttackType.mainHand].max, fromAp + 5));
    assert(s.damage[AttackType.offHand] == DamageRange.init && s.damage[AttackType.ranged] == DamageRange.init);

    // A mage: mana from intellect, unarmed damage, caster attack power.
    StatInputs mage;
    mage.classId = PlayerClass.mage;
    mage.level = 1;
    mage.levelStats = LevelStats([20, 20, 20, 23, 22]);
    mage.classStats = ClassLevelStats(32, 100);
    const m = computeStats(mage);
    assert(m.maxPower[Power.mana] == 100 + 20 + 3 * 15 && m.maxHealth == 32 + 20);
    assert(m.attackPower == 10 && isClose(m.damage[AttackType.mainHand].min, 10 / 14.0f * 2 + 1));
}
