/**
 * A player's derived numbers: stats with item bonuses, health and mana,
 * armor and resistances, attack power, weapon damage and swing times.
 *
 * Auras and talents are not applied yet, so this is what a character has
 * with its gear and nothing else. Crit, dodge, parry and block chances come
 * from `meleeChances`.
 */
module dmangos.world.stats;

import dmangos.world.enchantments : EnchantmentBonus;

import std.algorithm.comparison : max, min;
import std.math : round;
import std.traits : EnumMembers;

public import dmangos.world.defines : Power, Stat;
import dmangos.world.defines;
import dmangos.world.worlddata : ItemTemplate, LevelStats, ClassLevelStats;

/// The kinds of weapon attack.
enum AttackType
{
    mainHand,
    offHand,
    ranged,
}

/// Item stat types (`item_template`'s `stat_type*`) that change stats.
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
private enum float offHandDamagePct = 0.5f; // the off hand deals half damage

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
    AuraMods auras;      /// what auras add (`dmangos.world.auras`)
    EnchantmentBonus enchantments; /// what the worn items' enchantments add (`dmangos.world.enchantments`)
    const(ItemTemplate)* ammo; /// the ammunition set (`PLAYER_AMMO_ID`); null if none
}

/**
 * The damage per second the ammunition `ammo` adds to `weapon`'s shots: its own damage, if it is a
 * projectile that fits the weapon (arrows a bow or crossbow, bullets a gun); else none
 * (CMaNGOS `Player::_ApplyAmmoBonuses`, `CheckAmmoCompatibility`).
 */
DamageRange ammoDps(const(ItemTemplate)* weapon, const(ItemTemplate)* ammo) pure nothrow @nogc @safe
{
    enum uint projectile = 6, arrow = 2, bullet = 3, bow = 2, gun = 3, crossbow = 18;
    if (weapon is null || ammo is null || weapon.itemClass != ItemClass.weapon || ammo.itemClass != projectile)
        return DamageRange(0, 0);
    const fits = weapon.subClass == bow || weapon.subClass == crossbow ? ammo.subClass == arrow
        : weapon.subClass == gun ? ammo.subClass == bullet : false;
    return fits ? DamageRange(ammo.details.damage[0].min, ammo.details.damage[0].max) : DamageRange(0, 0);
}

/// What a player's auras add to its stats (`SPELL_AURA_MOD_STAT`, `MOD_RESISTANCE`, `MOD_ATTACK_POWER`, ...).
struct AuraMods
{
    float[5] stats = 0;          /// `MOD_STAT`
    float[5] statPercent = 0;    /// `MOD_PERCENT_STAT`: percent more of each
    float[7] resistances = 0;    /// `MOD_RESISTANCE`: armor, then holy .. arcane
    float attackPower = 0;       /// `MOD_ATTACK_POWER`
    float rangedAttackPower = 0; /// `MOD_RANGED_ATTACK_POWER`
    float health = 0;            /// `MOD_INCREASE_HEALTH`
    float mana = 0;              /// `MOD_INCREASE_ENERGY` of mana
    // Multipliers (how percentages of one kind stack: `AuraSet.multiplier`).
    float[5] statTotal = 1;      /// `MOD_TOTAL_STAT_PERCENTAGE`: each stat's total
    float[7] resistanceBase = 1; /// `MOD_BASE_RESISTANCE_PCT`: armor and resistances from items
    float[7] resistanceTotal = 1; /// `MOD_RESISTANCE_PCT`: the totals
    float healthTotal = 1;       /// `MOD_INCREASE_HEALTH_PERCENT`
    float[5] powerTotal = 1;     /// `MOD_INCREASE_ENERGY_PERCENT`, by `Power`
    float attackPowerTotal = 1;  /// `MOD_ATTACK_POWER_PCT`
    float offHandDamage = 1;     /// `MOD_OFFHAND_DAMAGE_PCT`
    float[3] attackTime = 1;     /// haste and slows by `AttackType` (`AuraSet.attackTimeFactor`)
    float armorFromIntellect = 0; /// `MOD_RESISTANCE_OF_STAT_PERCENT` (Arcane Resilience): percent of intellect as armor
}

/// A player's derived numbers: its level's base stats with what its gear and `input`'s other bonuses add.
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
        armor += item.details.armor * input.auras.resistanceBase[0];
        foreach (i, value; item.details.resistances)
            resistance[i] += value * input.auras.resistanceBase[i + 1];
    }

    // Enchantments: stats, health and mana, resistances (armor first).
    with (input.enchantments)
    {
        manaMod += mods[itemModMana];
        healthMod += mods[itemModHealth];
        addStatBonus(result, Stat.agility, mods[itemModAgility]);
        addStatBonus(result, Stat.strength, mods[itemModStrength]);
        addStatBonus(result, Stat.intellect, mods[itemModIntellect]);
        addStatBonus(result, Stat.spirit, mods[itemModSpirit]);
        addStatBonus(result, Stat.stamina, mods[itemModStamina]);
        armor += resistances[0];
        foreach (i; 1 .. 7)
            resistance[i - 1] += resistances[i];
    }

    // Auras: flat stats, then percentages of the totals.
    foreach (i; 0 .. 5)
    {
        if (input.auras.stats[i] != 0)
            addStatBonus(result, cast(Stat) i, input.auras.stats[i]);
        if (input.auras.statPercent[i] != 0)
            addStatBonus(result, cast(Stat) i, result.stats[i] * input.auras.statPercent[i] / 100);
        if (input.auras.statTotal[i] != 1)
            addStatBonus(result, cast(Stat) i, result.stats[i] * (input.auras.statTotal[i] - 1));
    }
    healthMod += input.auras.health;
    manaMod += input.auras.mana;
    armor += input.auras.resistances[0];
    foreach (i; 0 .. 6)
        resistance[i] += input.auras.resistances[i + 1];

    // Maximum health and power
    result.maxHealth = cast(uint) max(round((healthMod + result.baseHealth
        + healthBonusFromStamina(result.stats[Stat.stamina])) * input.auras.healthTotal), 1);
    if (result.baseMana > 0)
        result.maxPower[Power.mana] = cast(uint) max(round((manaMod + result.baseMana
            + manaBonusFromIntellect(result.stats[Stat.intellect])) * input.auras.powerTotal[Power.mana]), 0);
    result.maxPower[Power.rage] = cast(uint) round(1000 * input.auras.powerTotal[Power.rage]);
    result.maxPower[Power.energy] = cast(uint) round(100 * input.auras.powerTotal[Power.energy]);

    // Armor and resistances
    result.resistances[0] = cast(int)((armor + result.stats[Stat.agility] * 2
        + result.stats[Stat.intellect] * input.auras.armorFromIntellect / 100) * input.auras.resistanceTotal[0]);
    foreach (i; 0 .. 6)
        result.resistances[i + 1] = cast(int)(resistance[i] * input.auras.resistanceTotal[i + 1]);

    // Attack power and damage
    result.attackPower = cast(int)((meleeAttackPower(input.classId, input.level, result.stats) + input.auras.attackPower)
        * input.auras.attackPowerTotal);
    result.rangedAttackPower = cast(int)(rangedAttackPower(input.classId, input.level, result.stats)
        + input.auras.rangedAttackPower);
    foreach (type; EnumMembers!AttackType)
        weaponDamage(input, type, result);
    return result;
}

/// Health from stamina: the first 20 points give 1 health each, the rest 10.
float healthBonusFromStamina(float stamina) pure nothrow @nogc @safe
{
    const base = min(stamina, 20.0f);
    return base + (stamina - base) * 10.0f;
}

/// Mana from intellect: the first 20 points give 1 mana each, the rest 15.
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

/// Physical weapon damage, without auras; a ranged weapon's with its ammunition's damage per second times its
/// speed (CMaNGOS `Player::CalculateMinMaxDamage`).
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
    weaponMin += input.enchantments.damage[type];
    weaponMax += input.enchantments.damage[type];
    if (type == AttackType.ranged && isWeapon)
    {
        const ammo = ammoDps(weapon, input.ammo), speed = result.attackTime[type] / 1000.0f;
        weaponMin += ammo.min * speed;
        weaponMax += ammo.max * speed;
    }
    const pct = type == AttackType.offHand ? offHandDamagePct * input.auras.offHandDamage : 1.0f;
    result.damage[type] = DamageRange(max((fromAttackPower + weaponMin) * pct, 0.0f),
        max((fromAttackPower + weaponMax) * pct, 0.0f));
    // Haste and slows change how often it swings, not what a swing deals (that by the weapon's own speed).
    result.attackTime[type] = cast(uint)(result.attackTime[type] * input.auras.attackTime[type]);
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
    assert(isClose(s.damage[AttackType.mainHand].min, fromAp + 2)
        && isClose(s.damage[AttackType.mainHand].max, fromAp + 5));
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

// Percentages of totals (talents, Blessing of Kings): they multiply; the items' armor alone is the base.
unittest
{
    import std.math : isClose;

    auto chest = ItemTemplate.display(1, 5);
    chest.details.armor = 100;
    auto dagger = ItemTemplate.display(2, 13);
    dagger.itemClass = 2;
    dagger.details.delay = 2000;
    dagger.details.damage[0].min = 10;
    dagger.details.damage[0].max = 10;
    StatInputs input;
    input.classId = PlayerClass.rogue;
    input.level = 1;
    input.levelStats = LevelStats([20, 20, 100, 20, 20]);
    input.classStats = ClassLevelStats(100, 0);
    input.equipment[4] = &chest;
    input.equipment[equipmentSlotOffhand] = &dagger;
    const plain = computeStats(input);

    input.auras.statTotal[Stat.stamina] = 1.1f * 1.2f; // Kings and Heart of the Wild: 32%, not 30%
    input.auras.resistanceBase[0] = 1.1f;            // Toughness: the items' armor only
    input.auras.healthTotal = 1.05f;
    input.auras.powerTotal[Power.energy] = 1.1f;
    input.auras.offHandDamage = 1.1f;                // Dual Wield Specialization
    const s = computeStats(input);
    assert(isClose(s.stats[Stat.stamina], 132.0f) && isClose(s.positiveBonus[Stat.stamina], 32.0f, 1e-4));
    assert(s.resistances[0] == plain.resistances[0] + 10, "a tenth more of the chest's 100, none of the agility's");
    assert(s.maxHealth == cast(uint) round((100 + healthBonusFromStamina(132)) * 1.05f));
    assert(s.maxPower[Power.energy] == 110);
    assert(isClose(s.damage[AttackType.offHand].min, plain.damage[AttackType.offHand].min * 1.1f));
}

/**
 * A player's own melee chances (crit, dodge, parry, block) and shield block value: what the combat
 * rolls use, and what the character sheet shows, which adds
 * the weapon or defense skill against a target of the same level.
 */
struct MeleeChances
{
    float crit = 0, rangedCrit = 0, dodge = 0, parry = 0, block = 0; /// what the rolls use
    float critShown = 0, rangedCritShown = 0, dodgeShown = 0, parryShown = 0, blockShown = 0; /// the fields
    uint shieldBlock;            /// the shield's block value
    bool canParry, canBlock;     /// the Parry and Block spells are known
}

/// What `meleeChances` needs.
struct ChanceInputs
{
    ubyte classId;
    uint level;
    float agility = 0, strength = 0;
    uint mainHandSkill, rangedSkill, defenseSkill; /// current values
    bool canParry, canBlock;
    uint shieldBlock;            /// the worn shield's block value; 0 without one
    float auraCrit = 0, auraRangedCrit = 0; /// what auras add to melee and ranged crit (`MOD_CRIT_PERCENT`, by weapon)
    float auraDodge = 0, auraParry = 0, auraBlock = 0; /// `MOD_DODGE_PERCENT`, `MOD_PARRY_PERCENT`, `MOD_BLOCK_PERCENT`
}

/// Crit and dodge from agility: agility per percent, by class and level.
private float agilityPerPercent(ubyte classId, uint level, bool dodge) pure nothrow @nogc @safe
{
    float low, high; // at levels 1 and 60
    switch (classId)
    {
    case 2: case 7: case 11: low = 4.6f; high = 20.0f; break; // paladin, shaman, druid
    case 8: low = 12.9f; high = 20.0f; break;                  // mage
    case 4: low = dodge ? 1.1f : 2.2f; high = dodge ? 14.5f : 29.0f; break; // rogue
    case 3: low = dodge ? 1.8f : 3.5f; high = dodge ? 26.5f : 53.0f; break; // hunter
    case 5: low = 11.0f; high = 20.0f; break;                  // priest
    case 9: low = 8.4f; high = 20.0f; break;                   // warlock
    case 1: low = 3.9f; high = 20.0f; break;                   // warrior
    default: return 0;
    }
    return low * float(60.0f - level) / 59.0f + high * float(level - 1.0f) / 59.0f;
}

/// See `MeleeChances`.
MeleeChances meleeChances(const ChanceInputs input) pure nothrow @nogc @safe
{
    static immutable float[12] baseDodge = [0, 0, 0.75f, 0.64f, 0, 3.00f, 0, 1.75f, 3.25f, 2.00f, 0, 0.75f];
    float clampPct(float v) { return v < 0 ? 0 : v > 100 ? 100 : v; }
    MeleeChances r;
    const cap = input.level * 5; // the highest skill at this level
    const critRate = agilityPerPercent(input.classId, input.level, false);
    const agilityCrit = critRate > 0 ? input.agility / critRate : 0;
    r.crit = agilityCrit + input.auraCrit;
    r.rangedCrit = agilityCrit + input.auraRangedCrit;
    r.critShown = clampPct(r.crit + (int(input.mainHandSkill) - int(cap)) * 0.04f);
    r.rangedCritShown = clampPct(r.rangedCrit + (int(input.rangedSkill) - int(cap)) * 0.04f);
    const defense = (int(input.defenseSkill) - int(cap)) * 0.04f;
    const dodgeRate = agilityPerPercent(input.classId, input.level, true);
    r.dodge = (input.classId < baseDodge.length ? baseDodge[input.classId] : 0)
        + (dodgeRate > 0 ? input.agility / dodgeRate : 0) + input.auraDodge;
    r.dodgeShown = clampPct(r.dodge + defense);
    r.canParry = input.canParry;
    if (input.canParry)
    {
        r.parry = 5 + input.auraParry;
        r.parryShown = clampPct(r.parry + defense);
    }
    r.canBlock = input.canBlock;
    if (input.canBlock)
    {
        r.block = 5 + input.auraBlock;
        r.blockShown = clampPct(r.block + defense);
    }
    const shield = input.shieldBlock + input.strength / 20 - 1;
    r.shieldBlock = shield < 0 ? 0 : cast(uint) shield;
    return r;
}

unittest
{
    // A level 1 human warrior: 23 agility over 3.9 for crit and 23 over 3.9 for dodge, no class base dodge;
    // Parry and Block known, a shield with 5 block, 23 strength.
    auto input = ChanceInputs(1, 1, 23, 23, 5, 0, 5, true, true, 5);
    const c = meleeChances(input);
    assert(c.crit > 5.89f && c.crit < 5.90f && c.critShown > 5.89f && c.critShown < 5.90f);
    assert(c.rangedCritShown < c.crit, "no ranged weapon skill: below the base");
    assert(c.dodge > 5.89f && c.dodge < 5.90f && c.parry == 5 && c.block == 5);
    assert(c.shieldBlock == 5, "5 + 23 / 20 - 1");
    // A mage: no parry or block, and a class base dodge.
    input = ChanceInputs(8, 1, 20, 20, 5, 0, 5, false, false, 0);
    const m = meleeChances(input);
    assert(m.parry == 0 && m.block == 0 && m.parryShown == 0 && m.dodge > 3.25f + 1.5f && m.shieldBlock == 0);
}


// Auras add to the chances: crit (melee and ranged apart), dodge, and parry and block where known.
unittest
{
    auto input = ChanceInputs(1, 1, 23, 23, 5, 0, 5, true, true, 5);
    const plain = meleeChances(input);
    input.auraCrit = 5;
    input.auraRangedCrit = 1;
    input.auraDodge = 2;
    input.auraParry = 3;
    input.auraBlock = 4;
    const buffed = meleeChances(input);
    assert(buffed.crit == plain.crit + 5 && buffed.rangedCrit == plain.rangedCrit + 1);
    assert(buffed.dodge == plain.dodge + 2 && buffed.parry == 8 && buffed.block == 9);
}

// Ammunition adds its damage per second times the ranged weapon's speed; arrows add nothing to a gun.
unittest
{
    import std.math : isClose;

    auto bow = ItemTemplate.display(8106, 15);
    bow.itemClass = ItemClass.weapon;
    bow.subClass = 2;
    bow.details.delay = 2000;
    bow.details.damage[0].min = 3;
    bow.details.damage[0].max = 6;
    auto arrows = ItemTemplate.display(5996, 24);
    arrows.itemClass = 6;
    arrows.subClass = 2;
    arrows.details.damage[0].min = 2;
    arrows.details.damage[0].max = 2.5f;

    StatInputs input;
    input.race = 2;
    input.classId = PlayerClass.hunter;
    input.level = 1;
    input.levelStats = LevelStats([20, 20, 20, 20, 20]);
    input.classStats = ClassLevelStats(20, 0);
    input.equipment[equipmentSlotRanged] = &bow;
    const without = computeStats(input).damage[AttackType.ranged];
    input.ammo = &arrows;
    const with_ = computeStats(input).damage[AttackType.ranged];
    assert(isClose(with_.min, without.min + 4) && isClose(with_.max, without.max + 5), "2 and 2.5 a second, 2 seconds");
    bow.subClass = 3; // a gun
    assert(computeStats(input).damage[AttackType.ranged] == without);
}
