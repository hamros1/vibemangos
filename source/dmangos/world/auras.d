/**
 * Auras (CMaNGOS `Spells/SpellAuras.cpp`: `SpellAuraHolder` and `Aura`): what a spell leaves on a
 * unit for a while, the unit's aura fields that show it, and what it adds up to.
 *
 * An `AuraSet` is a unit's auras. Applying one gives it a visible slot (positive 0 .. 31, negative
 * 32 .. 47; passive ones none) and fills `UNIT_FIELD_AURA`, its flags, level and applications;
 * applying the same spell from the same caster again refreshes it (and stacks it, up to
 * `StackAmount`). Each aura counts down its duration and its periodic effects' timers; `update`
 * says which ticked and which ended, and the unit's owner (a session, a creature's map) does what
 * they do. The sums (`total`, `totalByMisc`) are what stats, speeds and states are made of.
 */
module dmangos.world.auras;

import dmangos.world.objects : UpdateValues;
import dmangos.world.spells : SpellInfo;
import dmangos.world.updatefields;

/// `AuraType`: the ones this server does something with.
enum AuraType : uint
{
    none = 0,
    bindSight = 1,
    modPossess = 2,
    periodicDamage = 3,
    dummy = 4,
    modConfuse = 5,
    modCharm = 6,
    modFear = 7,
    periodicHeal = 8,
    modAttackSpeed = 9,
    modThreat = 10,
    modTaunt = 11,
    modStun = 12,
    modDamageDone = 13,
    modDamageTaken = 14,
    damageShield = 15,
    modStealth = 16,
    modInvisibility = 18,
    obsModHealth = 20,
    obsModMana = 21,
    modResistance = 22,
    periodicTriggerSpell = 23,
    periodicEnergize = 24,
    modPacify = 25,
    modRoot = 26,
    modSilence = 27,
    reflectSpells = 28,
    modStat = 29,
    modSkill = 30,
    modIncreaseSpeed = 31,
    modIncreaseMountedSpeed = 32,
    modDecreaseSpeed = 33,
    modIncreaseHealth = 34,
    modIncreaseEnergy = 35,
    modShapeshift = 36,
    effectImmunity = 37,
    stateImmunity = 38,
    schoolImmunity = 39,
    damageImmunity = 40,
    dispelImmunity = 41,
    procTriggerSpell = 42,
    procTriggerDamage = 43,
    trackCreatures = 44,
    trackResources = 45,
    modParryPercent = 47,
    modDodgePercent = 49,
    modBlockPercent = 51,
    modCritPercent = 52,
    periodicLeech = 53,
    modHitChance = 54,
    modSpellHitChance = 55,
    transform = 56,
    modSpellCritChance = 57,
    modIncreaseSwimSpeed = 58,
    modDamageDoneCreature = 59,
    modPacifySilence = 60,
    modScale = 61,
    modMeleeHaste = 61 + 1000, // placeholder, not a vanilla id
    periodicManaLeech = 64,
    modCastingSpeed = 65,
    modPowerCostSchoolPct = 72,
    modPowerCostSchool = 73,
    mounted = 78,
    modDamagePercentDone = 79,
    modPercentStat = 80,
    modRegen = 84,
    modPowerRegen = 85,
    modAttackPower = 99,
    modResistancePct = 101,
    modRangedAttackPower = 124,
}

/// `MAX_AURAS`, `MAX_POSITIVE_AURAS`
enum uint maxAuras = 48, maxPositiveAuras = 32;
/// No visible slot.
enum ubyte noSlot = 0xFF;

/// `AuraInterruptFlags`
enum AuraInterrupt : uint
{
    hostileAction = 0x00000001,
    damage = 0x00000002,
    action = 0x00000004,
    moving = 0x00000008,
    turning = 0x00000010,
    attacking = 0x00001000,
    standingCancels = 0x00040000,
    leaveWorld = 0x00080000,
    mounting = 0x00020000,
    nonPeriodicDamage = 0x01000000,
}

/// `AuraFlags`
enum ubyte auraFlagCancelable = 0x01, auraFlagPositive = 0x04 /* AFLAG_UNK3 */, auraFlagNegative = 0x08;

/// `SPELL_ATTR_NO_AURA_CANCEL`
enum uint spellAttrNoAuraCancel = 0x80000000;

/// One spell's aura on a unit (`SpellAuraHolder` with its `Aura`s).
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
     * `Unit::AddSpellAuraHolder`: `aura` is applied, or the same spell's from the same caster is
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

    /// `_RemoveSpellAuraHolder`: the aura goes, and its slot empties.
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

    /// `SetAura`, `SetAuraFlag`, `SetAuraLevel`, `UpdateAuraApplication`
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
     * `SpellAuraHolder::Update`: `diff` milliseconds on. Periodic effects that came due are added to
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

    /// `GetTotalAuraModifier`: the amounts of every effect of `type`.
    int total(AuraType type) const
    {
        int sum;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type)
                    sum += aura.amount[i] * cast(int) aura.stacks;
        return sum;
    }

    /// `GetTotalAuraModifierByMiscValue`: those whose misc value is `misc`.
    int totalByMisc(AuraType type, int misc) const
    {
        int sum;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && aura.misc(i) == misc)
                    sum += aura.amount[i] * cast(int) aura.stacks;
        return sum;
    }

    /// `GetTotalAuraModifierByMiscMask`: those whose misc value has a bit of `mask`.
    int totalByMiscMask(AuraType type, int mask) const
    {
        int sum;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && (aura.misc(i) & mask))
                    sum += aura.amount[i] * cast(int) aura.stacks;
        return sum;
    }

    /// `GetMaxPositiveAuraModifier`/`GetMaxNegativeAuraModifier` of speeds: the strongest of each kind counts.
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

    /// The auras whose `AuraInterruptFlags` has any of `flags` (`RemoveAurasWithInterruptFlags`).
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

/// `CreateAura`'s amounts and periods for `spell`'s aura effects, from `effectValue`s already rolled.
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
    foreach (i; 0 .. 3)
    {
        enum uint applyAura = 6, areaAuraParty = 35;
        if (spell.effect[i] != applyAura && spell.effect[i] != areaAuraParty)
            continue;
        aura.effects |= cast(ubyte)(1 << i);
        aura.amount[i] = values[i];
        int period = spell.casting.amplitude[i];
        switch (cast(AuraType) spell.casting.applyAuraName[i])
        {
        case AuraType.modRegen:
            period = 5000; // `HandleModRegen`
            break;
        case AuraType.modPowerRegen:
            period = 0; // drink adds to the regeneration (`UpdateManaRegen`)
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
    dot.effect[0] = 6;
    dot.casting.applyAuraName[0] = AuraType.periodicDamage;
    dot.casting.amplitude[0] = 3000;
    SpellInfo buff;
    buff.id = 1459;
    buff.effect[0] = 6;
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
