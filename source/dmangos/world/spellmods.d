/**
 * Spell modifiers (`SPELL_AURA_ADD_FLAT_MODIFIER`, `SPELL_AURA_ADD_PCT_MODIFIER`): what most talents
 * are. An aura effect of either type changes one property (`SpellModOp`, its misc value) of the
 * spells of its own family whose family flags meet its mask (the effect's `EffectItemType`): flat
 * amounts are added first, then the percentages (`applySpellMod`).
 */
module dmangos.world.spellmods;

import dmangos.world.spellids;

import dmangos.world.auras : Aura, AuraType;
import dmangos.world.spells : SpellInfo;

/// `SpellModOp`
enum SpellModOp : int
{
    damage = 0,
    duration = 1,
    threat = 2,
    effect1 = 3,
    charges = 4,
    range = 5,
    radius = 6,
    critChance = 7,
    allEffects = 8,
    notLoseCastingTime = 9,
    castingTime = 10,
    cooldown = 11,
    effect2 = 12,
    cost = 14,
    critDamageBonus = 15,
    resistMissChance = 16,
    jumpTargets = 17,
    chanceOfSuccess = 18,
    activationTime = 19,
    effectPastFirst = 20,
    castingTimeOld = 21,
    dot = 22,
    effect3 = 23,
    bonusDamage = 24,
    multipleValue = 27,
    resistDispelChance = 28,
}

/// Whether effect `i` of `mod` changes `spell`.
bool affects(const Aura mod, size_t i, const ref SpellInfo spell)
{
    // `spell_affect` where it has a mask (one wider than `EffectItemType`'s 32 bits: Clearcasting's, Arcane Power's).
    const ulong mask = mod.spell.casting.affectMask[i] ? mod.spell.casting.affectMask[i] : mod.spell.itemType[i];
    return mask && spell.casting.spellFamilyName == mod.spell.casting.spellFamilyName
        && (spell.casting.spellFamilyFlags & mask) != 0;
}

/// `value` of `spell`'s property `op`, with the modifiers among `auras`.
T applySpellMod(T)(const(Aura)[] auras, SpellModOp op, const ref SpellInfo spell, T value)
{
    long flat;
    int percent;
    foreach (aura; auras)
        foreach (i; 0 .. 3)
        {
            const type = aura.spell.casting.applyAuraName[i];
            if ((type != AuraType.addFlatModifier && type != AuraType.addPctModifier) || aura.misc(i) != op || !(aura.effects & (1 << i)))
                continue;
            if (aura.spell.id == spell.id || !affects(aura, i, spell))
                continue;
            // (each stack's: Combustion's 10% a fire spell)
            if (type == AuraType.addFlatModifier)
                flat += aura.amount[i] * cast(int) aura.stacks;
            else
                percent += aura.amount[i] * cast(int) aura.stacks;
        }
    if (flat == 0 && percent == 0)
        return value;
    const total = (value + flat) * (100.0 + percent) / 100.0;
    return cast(T) total;
}

/// The modifier ops of an effect's value: its own (1st, 2nd, 3rd) and all effects'.
SpellModOp effectOp(size_t i) pure nothrow @nogc @safe
{
    return i == 0 ? SpellModOp.effect1 : i == 1 ? SpellModOp.effect2 : SpellModOp.effect3;
}

unittest
{
    import dmangos.world.auras : makeAura;

    auto fireball = SpellInfo(133);
    fireball.casting.spellFamilyName = 3;
    fireball.casting.spellFamilyFlags = 0x40000001;
    auto frostbolt = SpellInfo(116);
    frostbolt.casting.spellFamilyName = 3;
    frostbolt.casting.spellFamilyFlags = 0x20;
    auto improved = SpellInfo(12338); // Improved Fireball: 0.2 s less casting time
    improved.effect[0] = SpellEffect.applyAura;
    improved.casting.applyAuraName[0] = AuraType.addFlatModifier;
    improved.miscValue[0] = SpellModOp.castingTime;
    improved.itemType[0] = 1;
    improved.casting.spellFamilyName = 3;
    auto talent = makeAura(&improved, 1, 60, -1, true, [-200, 0, 0]);
    auto clearcasting = SpellInfo(12536); // a percent off the cost of every mage spell (of the mask)
    clearcasting.effect[0] = SpellEffect.applyAura;
    clearcasting.casting.applyAuraName[0] = AuraType.addPctModifier;
    clearcasting.miscValue[0] = SpellModOp.cost;
    clearcasting.itemType[0] = 0xFFFFFFFF;
    clearcasting.casting.spellFamilyName = 3;
    auto cheaper = makeAura(&clearcasting, 1, 60, -1, true, [-50, 0, 0]);

    const(Aura)[] auras = [talent, cheaper];
    assert(applySpellMod(auras, SpellModOp.castingTime, fireball, 3500) == 3300);
    assert(applySpellMod(auras, SpellModOp.castingTime, frostbolt, 3000) == 3000, "not its mask");
    assert(applySpellMod(auras, SpellModOp.cost, frostbolt, 100) == 50 && applySpellMod(auras, SpellModOp.cost, fireball, 410) == 205);
    assert(applySpellMod(auras, SpellModOp.damage, fireball, 500) == 500);
}
