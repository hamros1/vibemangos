/**
 * Item enchantments and random properties.
 *
 * An item has seven enchantment slots in its `ITEM_FIELD_ENCHANTMENT` fields (an id, a duration and
 * charges each): the permanent one (0), a temporary one (1), and the random property's (3 to 5).
 * An item whose template has a `RandomProperty` gets one of the properties `item_enchantment_template`
 * lists for it, by their chances, when it is made (or when it drops, so the loot window shows it);
 * the property (`ItemRandomProperties.dbc`) names up to three enchantments, which fill slots 3 to 5.
 * The client works out the "of the Bear" name from the property id.
 *
 * What an enchantment does (`SpellItemEnchantment.dbc`) is up to three effects. Worn, these count:
 * a stat (its `ITEM_MOD_*` type and amount), a resistance (school and amount) and weapon damage
 * (added to the weapon's). An equip spell is on the wearer while the item is worn, and a combat spell
 * may be cast when the weapon hits (`castItemCombatSpells`). Totems are not applied yet.
 */
module dmangos.world.enchantments;

import std.random : Random, uniform01;

/// Enchantment slots.
enum EnchantmentSlot : ubyte
{
    permanent = 0,
    temporary = 1,
    property0 = 3, /// the random property's first; then 4 and 5
}

/// How many enchantment slots an item has, and the fields each takes (id, duration, charges).
enum size_t enchantmentSlots = 7, fieldsPerSlot = 3;

/// An enchantment effect's type (`SpellItemEnchantment.dbc`'s `type`).
enum EnchantmentType : uint
{
    none = 0,
    combatSpell = 1,
    damage = 2,
    equipSpell = 3,
    resistance = 4,
    stat = 5,
    totem = 6,
}

/// One effect of an enchantment.
struct EnchantmentEffect
{
    EnchantmentType type;
    uint amount;
    uint arg; /// the stat type, the resistance's school or the spell
}

/// A row of `item_enchantment_template`: a property an item of `RandomProperty` may get, and its chance.
struct RandomEnchantment
{
    uint property;
    float chance = 0;
}

/**
 * `item_enchantment_template`'s roll: one of `choices`' properties, each by its chance in percent
 * (rolled once in [0, 100)); 0 if the roll falls past them all.
 */
uint chooseRandomProperty(const(RandomEnchantment)[] choices, ref Random random)
{
    const roll = uniform01(random) * 100;
    float sum = 0;
    foreach (ref c; choices)
    {
        sum += c.chance;
        if (sum > roll)
            return c.property;
    }
    return 0;
}

unittest
{
    auto random = Random(7);
    const choices = [RandomEnchantment(10, 50), RandomEnchantment(20, 50)];
    uint[uint] seen;
    foreach (_; 0 .. 1000)
        ++seen[chooseRandomProperty(choices, random)];
    assert(seen.length == 2 && seen[10] > 400 && seen[20] > 400, "half and half");
    assert(chooseRandomProperty([RandomEnchantment(5, 0)], random) == 0, "no chance at all");
}

/// What the enchantments of a player's worn items add (see `dmangos.world.stats.StatInputs`).
struct EnchantmentBonus
{
    float[8] mods = 0;        /// by `ITEM_MOD_*` type: 0 mana, 1 health, 3 agility .. 7 stamina
    float[7] resistances = 0; /// armor, then holy .. arcane
    float[3] damage = 0;      /// weapon damage, by attack (main hand, off hand, ranged)

    /// Adds enchantment `effects` of an item worn in attack slot `attack` (-1: not a weapon).
    void add(const(EnchantmentEffect)[3] effects, int attack) pure nothrow @nogc @safe
    {
        foreach (ref e; effects)
            final switch (e.type)
            {
            case EnchantmentType.stat:
                if (e.arg < mods.length)
                    mods[e.arg] += e.amount;
                break;
            case EnchantmentType.resistance:
                if (e.arg < resistances.length)
                    resistances[e.arg] += e.amount;
                break;
            case EnchantmentType.damage:
                if (attack >= 0 && attack < 3)
                    damage[attack] += e.amount;
                break;
            case EnchantmentType.none, EnchantmentType.combatSpell, EnchantmentType.equipSpell,
                    EnchantmentType.totem:
                break;
            }
    }
}

unittest
{
    EnchantmentBonus b;
    b.add([EnchantmentEffect(EnchantmentType.stat, 5, 4), EnchantmentEffect(EnchantmentType.resistance, 10, 2),
        EnchantmentEffect(EnchantmentType.damage, 3, 0)], 0);
    assert(b.mods[4] == 5 && b.resistances[2] == 10 && b.damage[0] == 3);
    b.add([EnchantmentEffect(EnchantmentType.damage, 3, 0), EnchantmentEffect.init, EnchantmentEffect.init], -1);
    assert(b.damage[0] == 3, "damage only on a weapon");
}
