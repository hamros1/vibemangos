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
        armor += item.details.armor;
        foreach (i, value; item.details.resistances)
            resistance[i] += value;
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
    }
    healthMod += input.auras.health;
    manaMod += input.auras.mana;
    armor += input.auras.resistances[0];
    foreach (i; 0 .. 6)
        resistance[i] += input.auras.resistances[i + 1];

    // Maximum health and power
    result.maxHealth = cast(uint) max(round(healthMod + result.baseHealth
        + healthBonusFromStamina(result.stats[Stat.stamina])), 1);
    if (result.baseMana > 0)
        result.maxPower[Power.mana] = cast(uint) max(round(manaMod + result.baseMana
            + manaBonusFromIntellect(result.stats[Stat.intellect])), 0);
    result.maxPower[Power.rage] = 1000;
    result.maxPower[Power.energy] = 100;

    // Armor and resistances
    result.resistances[0] = cast(int)(armor + result.stats[Stat.agility] * 2);
    foreach (i; 0 .. 6)
        result.resistances[i + 1] = cast(int) resistance[i];

    // Attack power and damage
    result.attackPower = cast(int)(meleeAttackPower(input.classId, input.level, result.stats) + input.auras.attackPower);
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

/// Physical weapon damage, without auras or ammo.
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
    r.crit = r.rangedCrit = agilityCrit;
    r.critShown = clampPct(r.crit + (int(input.mainHandSkill) - int(cap)) * 0.04f);
    r.rangedCritShown = clampPct(r.rangedCrit + (int(input.rangedSkill) - int(cap)) * 0.04f);
    const defense = (int(input.defenseSkill) - int(cap)) * 0.04f;
    const dodgeRate = agilityPerPercent(input.classId, input.level, true);
    r.dodge = (input.classId < baseDodge.length ? baseDodge[input.classId] : 0)
        + (dodgeRate > 0 ? input.agility / dodgeRate : 0);
    r.dodgeShown = clampPct(r.dodge + defense);
    r.canParry = input.canParry;
    if (input.canParry)
    {
        r.parry = 5;
        r.parryShown = clampPct(r.parry + defense);
    }
    r.canBlock = input.canBlock;
    if (input.canBlock)
    {
        r.block = 5;
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

