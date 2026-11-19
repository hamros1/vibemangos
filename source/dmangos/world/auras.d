/**
 * Auras: what a spell leaves on a
 * unit for a while, the unit's aura fields that show it, and what it adds up to.
 *
 * An `AuraSet` is a unit's auras. Applying one gives it a visible slot (positive 0 .. 31, negative
 * 32 .. 47; passive ones none) and fills `UNIT_FIELD_AURA`, its flags, level and applications;
 * applying the same spell from the same caster again refreshes it (and stacks it, up to the
 * spell's `StackAmount`). Each aura counts down its duration and its periodic effects' timers; `update`
 * says which ticked and which ended, and the unit's owner (a session, a creature's map) does what
 * they do. The sums (`total`, `totalByMisc`) are what stats, speeds and states are made of.
 */
module dmangos.world.auras;

import dmangos.world.spellids;

public import dmangos.world.spellids : AuraType;

import dmangos.world.objects : UpdateValues;
import dmangos.world.spells : SpellInfo;
import dmangos.world.updatefields;


/// Visible aura slots, and how many of them are for positive auras.
enum uint maxAuras = 48, maxPositiveAuras = 32;
/// No visible slot.
enum ubyte noSlot = 0xFF;

/// Bits of a spell's `AuraInterruptFlags`: what removes its aura.
enum AuraInterrupt : uint
{
    hostileAction = 0x00000001,
    damage = 0x00000002,
    action = 0x00000004,
    moving = 0x00000008,
    turning = 0x00000010,
    animCancels = 0x00000020,      /// an emote, sitting or standing
    dismount = 0x00000040,
    interacting = 0x00000400,      /// talking to an NPC, using an object
    looting = 0x00000800,
    attacking = 0x00001000,
    itemUse = 0x00002000,          /// a spell cast from an item
    shapeshifting = 0x00008000,
    actionLate = 0x00010000,       /// a cast completing
    standingCancels = 0x00040000,
    leaveWorld = 0x00080000,
    stealthInvisCancels = 0x00100000,
    enterWorld = 0x00400000,
    mounting = 0x00020000,
    pvpActiveCancels = 0x00800000, /// taking a battleground's objective (Stealth, Divine Shield, ...)
    nonPeriodicDamage = 0x01000000,
}

/// An aura slot's flags in the `UNIT_FIELD_AURAFLAGS` fields.
enum ubyte auraFlagCancelable = 0x01, auraFlagPositive = 0x04 /* what the client takes as positive */, auraFlagNegative = 0x08;

/// A spell attribute: its aura cannot be cancelled by the player.
enum uint spellAttrNoAuraCancel = 0x80000000;

/// One spell's aura on a unit, with each of its aura effects.
final class Aura
{
    const(SpellInfo)* spell;
    ulong caster;
    uint casterLevel;
    ubyte slot = noSlot;
    int duration;             /// milliseconds left; -1: until cancelled
    int maxDuration;
    bool positive;
    bool passive;
    uint stacks = 1;
    uint charges;             /// procs left before it goes (0: unlimited)
    ubyte effects;            /// which of the spell's effects are auras here
    int[3] amount;            /// `m_modifier.m_amount` of each
    int[3] period;            /// `periodictime`: milliseconds between ticks; 0 not periodic
    int[3] periodTimer;

    /// `m_modifier.m_auraname` of effect `i`.
    AuraType type(size_t i) const
    {
        return cast(AuraType) spell.casting.applyAuraName[i];
    }

    /// `m_modifier.m_miscvalue` of effect `i`.
    int misc(size_t i) const
    {
        return spell.miscValue[i];
    }

    /// Whether the aura has an effect of `type`.
    bool has(AuraType wanted) const
    {
        foreach (i; 0 .. 3)
            if ((effects & (1 << i)) && type(i) == wanted)
                return true;
        return false;
    }
}

/// A periodic effect that ticked: aura, effect index.
struct AuraTick
{
    Aura aura;
    size_t effect;
}

/// See the module documentation.
struct AuraSet
{
    Aura[] list;

    /**
     * Applies `aura`, or the same spell's from the same caster is
     * refreshed (and stacked) instead. Returns the aura in effect and whether it is new.
     */
    Aura apply(Aura aura, ref UpdateValues values, out bool isNew)
    {
        foreach (existing; list)
            if (existing.spell.id == aura.spell.id && existing.caster == aura.caster)
            {
                existing.duration = existing.maxDuration = aura.maxDuration;
                if (existing.stacks < (aura.spell.casting.stackAmount ? aura.spell.casting.stackAmount : 1))
                    ++existing.stacks;
                existing.amount = aura.amount;
                writeSlot(existing, values);
                isNew = false;
                return existing;
            }
        isNew = true;
        if (!aura.passive)
        {
            const from = aura.positive ? 0 : maxPositiveAuras, to = aura.positive ? maxPositiveAuras : maxAuras;
            foreach (s; from .. to)
                if (values.get!UNIT_FIELD_AURA(s) == 0)
                {
                    aura.slot = cast(ubyte) s;
                    break;
                }
        }
        list ~= aura;
        writeSlot(aura, values);
        return aura;
    }

    /// The aura goes, and its slot empties.
    void remove(Aura aura, ref UpdateValues values)
    {
        import std.algorithm.mutation : remove_ = remove;
        import std.algorithm.searching : countUntil;

        const at = list.countUntil!(a => a is aura);
        if (at < 0)
            return;
        list = list.remove_(at);
        if (aura.slot != noSlot)
        {
            values.set!UNIT_FIELD_AURA(aura.slot, 0u);
            setBits!UNIT_FIELD_AURAFLAGS(values, aura.slot, 4, 0);
            setBits!UNIT_FIELD_AURALEVELS(values, aura.slot, 8, 0);
            setBits!UNIT_FIELD_AURAAPPLICATIONS(values, aura.slot, 8, 0);
            aura.slot = noSlot;
        }
    }

    /// Writes the aura's slot: its spell, flags, level and applications.
    void writeSlot(const Aura aura, ref UpdateValues values)
    {
        if (aura.slot == noSlot)
            return;
        values.set!UNIT_FIELD_AURA(aura.slot, aura.spell.id);
        uint flags = aura.positive ? auraFlagPositive : auraFlagNegative;
        if (aura.positive && !(aura.spell.attributes & spellAttrNoAuraCancel))
            flags |= auraFlagCancelable;
        setBits!UNIT_FIELD_AURAFLAGS(values, aura.slot, 4, flags);
        setBits!UNIT_FIELD_AURALEVELS(values, aura.slot, 8, aura.casterLevel > 255 ? 255 : aura.casterLevel);
        setBits!UNIT_FIELD_AURAAPPLICATIONS(values, aura.slot, 8, aura.stacks > 255 ? 254 : aura.stacks - 1);
    }

    /// The field `field` holds `bits`-bit values: slot `slot`'s becomes `value`.
    private static void setBits(alias field)(ref UpdateValues values, uint slot, uint bits, uint value)
    {
        const perField = 32 / bits;
        const index = slot / perField, shift = (slot % perField) * bits;
        const mask = ((1u << bits) - 1) << shift;
        const old = values.get!field(index);
        values.set!field(index, (old & ~mask) | ((value << shift) & mask));
    }

    /**
     * `diff` milliseconds on. Periodic effects that came due are added to
     * `ticks`; auras whose time ran out to `expired` (not yet removed).
     */
    void update(int diff, ref AuraTick[] ticks, ref Aura[] expired)
    {
        foreach (aura; list)
        {
            foreach (i; 0 .. 3)
            {
                if (!(aura.effects & (1 << i)) || aura.period[i] <= 0)
                    continue;
                aura.periodTimer[i] -= diff;
                while (aura.periodTimer[i] <= 0)
                {
                    aura.periodTimer[i] += aura.period[i];
                    ticks ~= AuraTick(aura, i);
                }
            }
            if (aura.duration > 0)
            {
                aura.duration -= diff;
                if (aura.duration <= 0)
                    expired ~= aura;
            }
        }
    }

    /// Whether an effect of `type` is on, whatever its amount.
    bool hasType(AuraType type) const
    {
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type)
                    return true;
        return false;
    }

    /// The sum of the amounts of every effect of `type`.
    int total(AuraType type) const
    {
        int sum;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type)
                    sum += aura.amount[i] * cast(int) aura.stacks;
        return sum;
    }

    /**
     * The sum of the amounts of `type`, of auras with no item requirement or whose spell's weapon class
     * and subclasses take `weaponSubClass` (-1: no weapon: only those with no requirement).
     */
    int totalForWeapon(AuraType type, int weaponSubClass) const
    {
        enum int itemClassWeapon = 2;
        int sum;
        foreach (aura; list)
        {
            const needs = aura.spell.equippedItemClass;
            if (needs >= 0 && (needs != itemClassWeapon || weaponSubClass < 0
                    || !(aura.spell.equippedItemSubClassMask & (1 << weaponSubClass))))
                continue;
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type)
                    sum += aura.amount[i] * cast(int) aura.stacks;
        }
        return sum;
    }

    /**
     * How percentages of one kind stack (CMaNGOS's `TOTAL_PCT`): the product of (100 + amount) / 100 over the
     * effects of `type` whose misc value `matches` (null: any). Given a weapon subclass (-1: none), an aura whose
     * spell asks for a weapon counts only if it takes that one; `int.min` ignores the requirement.
     */
    float multiplier(AuraType type, scope bool delegate(int misc) matches = null, int weaponSubClass = int.min) const
    {
        enum int itemClassWeapon = 2;
        float product = 1;
        foreach (aura; list)
        {
            if (weaponSubClass != int.min)
            {
                const needs = aura.spell.equippedItemClass;
                if (needs >= 0 && (needs != itemClassWeapon || weaponSubClass < 0
                        || !(aura.spell.equippedItemSubClassMask & (1 << weaponSubClass))))
                    continue;
            }
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && (matches is null || matches(aura.misc(i))))
                    product *= (100.0f + aura.amount[i] * cast(int) aura.stacks) / 100.0f;
        }
        return product;
    }

    /// The sum of those whose misc value is `misc`.
    int totalByMisc(AuraType type, int misc) const
    {
        int sum;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && aura.misc(i) == misc)
                    sum += aura.amount[i] * cast(int) aura.stacks;
        return sum;
    }

    /// The sum of those whose misc value has a bit of `mask`.
    int totalByMiscMask(AuraType type, int mask) const
    {
        int sum;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && (aura.misc(i) & mask))
                    sum += aura.amount[i] * cast(int) aura.stacks;
        return sum;
    }

    /// The strongest positive (or negative) amount of `type`, as speeds count: only the strongest of each kind.
    int strongest(AuraType type, bool positive) const
    {
        int best;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type)
                {
                    const a = aura.amount[i];
                    if (positive ? a > best : a < best)
                        best = a;
                }
        return best;
    }

    /// Whether any aura has an effect of `type`.
    bool has(AuraType type) const
    {
        foreach (aura; list)
            if (aura.has(type))
                return true;
        return false;
    }

    /// The auras whose `AuraInterruptFlags` has any of `flags` (those the caller removes).
    Aura[] interruptedBy(uint flags)
    {
        Aura[] found;
        foreach (aura; list)
            if (aura.spell.casting.auraInterruptFlags & flags)
                found ~= aura;
        return found;
    }

    /// The aura of `spell` (from anyone); null if none.
    Aura find(uint spell)
    {
        foreach (aura; list)
            if (aura.spell.id == spell)
                return aura;
        return null;
    }
}

/// An aura of `spell`: its effects' amounts and periods, from `effectValue`s already rolled.
Aura makeAura(const(SpellInfo)* spell, ulong caster, uint casterLevel, int durationMs, bool positive,
    const int[3] values)
{
    auto aura = new Aura;
    aura.spell = spell;
    aura.caster = caster;
    aura.casterLevel = casterLevel;
    aura.duration = aura.maxDuration = durationMs;
    aura.positive = positive;
    aura.passive = spell.isPassive;
    aura.charges = spell.casting.procCharges;
    foreach (i; 0 .. 3)
    {
        if (spell.effect[i] != SpellEffect.applyAura && spell.effect[i] != SpellEffect.applyAreaAuraParty)
            continue;
        aura.effects |= cast(ubyte)(1 << i);
        aura.amount[i] = values[i];
        int period = spell.casting.amplitude[i];
        switch (cast(AuraType) spell.casting.applyAuraName[i])
        {
        case AuraType.modRegen:
            period = 5000; // regenerates every 5 seconds
            break;
        case AuraType.modPowerRegen:
            period = 0; // drink adds to the regeneration
            break;
        case AuraType.periodicDamage, AuraType.periodicHeal, AuraType.obsModHealth, AuraType.obsModMana,
                AuraType.periodicEnergize, AuraType.periodicTriggerSpell, AuraType.periodicLeech,
                AuraType.periodicManaLeech:
            break;
        default:
            period = 0;
            break;
        }
        aura.period[i] = period;
        aura.periodTimer[i] = cast(AuraType) spell.casting.applyAuraName[i] == AuraType.modRegen ? 5000 : period;
    }
    return aura;
}

unittest
{
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    SpellInfo dot;
    dot.id = 772;
    dot.effect[0] = SpellEffect.applyAura;
    dot.casting.applyAuraName[0] = AuraType.periodicDamage;
    dot.casting.amplitude[0] = 3000;
    SpellInfo buff;
    buff.id = 1459;
    buff.effect[0] = SpellEffect.applyAura;
    buff.casting.applyAuraName[0] = AuraType.modStat;
    buff.miscValue[0] = 3;

    AuraSet set;
    bool isNew;
    auto rend = set.apply(makeAura(&dot, 1, 10, 9000, false, [5, 0, 0]), values, isNew);
    auto intellect = set.apply(makeAura(&buff, 1, 10, 60_000, true, [2, 0, 0]), values, isNew);
    assert(isNew && rend.slot == 32 && intellect.slot == 0, "negative from 32, positive from 0");
    assert(values.get!UNIT_FIELD_AURA(32) == 772 && values.get!UNIT_FIELD_AURA(0) == 1459);
    assert((values.get!UNIT_FIELD_AURAFLAGS(0) & 0xF) == (auraFlagPositive | auraFlagCancelable));
    assert(((values.get!UNIT_FIELD_AURALEVELS(8)) & 0xFF) == 10, "slot 32's level");
    assert(set.totalByMisc(AuraType.modStat, 3) == 2 && set.total(AuraType.modStat) == 2);

    // Ticks every 3 s; gone after 9.
    AuraTick[] ticks;
    Aura[] expired;
    set.update(3000, ticks, expired);
    assert(ticks.length == 1 && ticks[0].aura is rend && expired.length == 0);
    ticks = null;
    set.update(6000, ticks, expired);
    assert(ticks.length == 2 && expired == [rend]);
    set.remove(rend, values);
    assert(values.get!UNIT_FIELD_AURA(32) == 0 && set.list.length == 1);

    // The same spell from the same caster refreshes.
    set.apply(makeAura(&buff, 1, 10, 60_000, true, [2, 0, 0]), values, isNew);
    assert(!isNew && set.list.length == 1);
}

// An aura for one kind of weapon counts only with it in hand.
unittest
{
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    SpellInfo axes; // +5% crit with axes (subclasses 0 and 1)
    axes.id = 12700;
    axes.effect[0] = SpellEffect.applyAura;
    axes.casting.applyAuraName[0] = AuraType.modCritPercent;
    axes.equippedItemClass = 2;
    axes.equippedItemSubClassMask = 0b11;
    SpellInfo any; // +1% crit with anything
    any.id = 12701;
    any.effect[0] = SpellEffect.applyAura;
    any.casting.applyAuraName[0] = AuraType.modCritPercent;
    AuraSet set;
    bool isNew;
    set.apply(makeAura(&axes, 1, 10, -1, true, [5, 0, 0]), values, isNew);
    set.apply(makeAura(&any, 1, 10, -1, true, [1, 0, 0]), values, isNew);
    assert(set.totalForWeapon(AuraType.modCritPercent, 0) == 6, "an axe in hand");
    assert(set.totalForWeapon(AuraType.modCritPercent, 7) == 1, "a sword: only the general one");
    assert(set.totalForWeapon(AuraType.modCritPercent, -1) == 1, "no weapon");
}

// Percentages of one kind multiply (`multiplier`), by misc mask; damage and threat mods built from them.
unittest
{
    import std.math : isClose;
    import dmangos.world.combat : AttackType, DamageMods;
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    SpellInfo defiance; // +15% threat, every school
    defiance.id = 12305;
    defiance.effect[0] = SpellEffect.applyAura;
    defiance.casting.applyAuraName[0] = AuraType.modThreat;
    defiance.miscValue[0] = 127;
    SpellInfo stance; // 10% less damage taken, every school; 10% more threat
    stance.id = 71;
    stance.effect[0] = stance.effect[1] = SpellEffect.applyAura;
    stance.casting.applyAuraName[0] = AuraType.modDamagePercentTaken;
    stance.miscValue[0] = 127;
    stance.casting.applyAuraName[1] = AuraType.modThreat;
    stance.miscValue[1] = 127;
    SpellInfo twoHanded; // +5% damage, physical, two-handed swords (subclass 8) only
    twoHanded.id = 12163;
    twoHanded.effect[0] = SpellEffect.applyAura;
    twoHanded.casting.applyAuraName[0] = AuraType.modDamagePercentDone;
    twoHanded.miscValue[0] = 1;
    twoHanded.equippedItemClass = 2;
    twoHanded.equippedItemSubClassMask = 1 << 8;
    AuraSet set;
    bool isNew;
    set.apply(makeAura(&defiance, 1, 10, -1, true, [15, 0, 0]), values, isNew);
    set.apply(makeAura(&stance, 1, 10, -1, true, [-10, 10, 0]), values, isNew);
    set.apply(makeAura(&twoHanded, 1, 10, -1, true, [5, 0, 0]), values, isNew);
    assert(isClose(set.multiplier(AuraType.modThreat), 1.15f * 1.1f), "they multiply");

    const m = DamageMods.of(set, (ubyte slot) => slot == 15 ? 8 : -1, (AttackType) => 0u);
    assert(isClose(m.threat[0], 1.265f) && isClose(m.threat[5], 1.265f));
    assert(isClose(m.taken[0], 0.9f) && isClose(m.swing[AttackType.mainHand], 1.05f));
    assert(m.swing[AttackType.offHand] == 1 && m.school[0] == 1, "not without the sword: not the off hand, not spells");
}
