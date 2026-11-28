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

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.tooltipeffects : hiddenEffectsOf;
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

/**
 * Whether the same spell's auras from two casters stand side by side on one unit (CMaNGOS's
 * `SpellStacker::IsSpellStackableWithSpellForDifferentCasters` with the spell itself): damage and healing over time
 * do; a class's buff does not (two priests' Power Word: Fortitude), nor a debuff of which one caster's is enough
 * (Sunder Armor, Fire Vulnerability, Demoralizing Shout). `positive`: the aura is a buff here.
 */
bool stacksAcrossCasters(const ref SpellInfo spell, bool positive, bool targetPlayerControlled) pure nothrow @nogc @safe
{
    enum uint passiveAttr = 0x40, noAuraCancel = 0x80000000, auraUnique = 0x800, dotStackingRule = 0x80,
        notAnAction = 0x10000000, channelled = 0x04 | 0x40;
    const c = &spell.casting;
    if (c.attributesEx3 & dotStackingRule)
        return true;
    if (spell.attributesEx & auraUnique)
        return false;
    if (spell.attributes & noAuraCancel)
        return true;
    const family = c.spellFamilyName != 0;
    const multirank = family && c.spellFamilyFlags != 0; // `related && siblings && player`: it is itself
    const isChannelled = (spell.attributesEx & channelled) != 0;
    foreach (i; 0 .. 3)
    {
        const aura = c.applyAuraName[i];
        if (!spell.effect[i] || aura == AuraType.none)
            continue;
        bool nonmui; // one instance of it on a unit
        switch (aura)
        {
        case AuraType.dummy, AuraType.periodicTriggerSpell:
            // Reincarnation's passive, Tranquility
            if (multirank && ((c.spellFamilyName == 11 && (c.spellFamilyFlags & 0x200))
                    || (c.spellFamilyName == 7 && (c.spellFamilyFlags & 0x80))))
                continue;
            break;
        case AuraType.periodicLeech, AuraType.periodicManaLeech:
            if (targetPlayerControlled)
                return false;
            break;
        case AuraType.periodicDamage, AuraType.periodicDamagePercent, AuraType.powerBurnMana, AuraType.obsModHealth,
                AuraType.obsModMana:
            continue;
        case AuraType.rangedAttackPowerAttackerBonus, AuraType.meleeAttackPowerAttackerBonus:
            return false; // Hunter's Mark: one
        case AuraType.modAttackPower:
            if (!positive && spell.basePoints[i] < 1)
            {
                if (family)
                    return false; // Demoralizing Shout, Curse of Weakness
                continue;
            }
            break;
        case AuraType.modResistance:
            if (positive)
            {
                if (c.dispel && !family)
                    return false; // scrolls
            }
            else if (c.preventionType)
                return false; // Sunder Armor
            break;
        case AuraType.modResistancePct:
            if (positive && c.dispel)
                return false;
            nonmui = true;
            break;
        case AuraType.modStat:
            if (spell.id == 5320 || spell.id == 15366) // Echeyakee's Grace, Songflower Serenade
                continue;
            if (positive)
            {
                if (!family && (c.dispel || (spell.attributesEx2 & notAnAction)))
                    return false;
            }
            else
            {
                if (c.dispel)
                    return false;
                nonmui = true;
            }
            break;
        case AuraType.modTotalStatPercentage, AuraType.modPercentStat, AuraType.modIncreaseHealthPercent,
                AuraType.modDamageTaken, AuraType.modDamagePercentTaken, AuraType.modDecreaseSpeed,
                AuraType.modIncreaseSpeed, AuraType.modHealthRegenPercent, AuraType.preventsFleeing,
                AuraType.procTriggerSpell:
            nonmui = true;
            break;
        case AuraType.modHealingDone, AuraType.modHealingPct:
            if (!positive)
                continue; // Mortal Strike's, from two warriors
            break;
        case AuraType.modMeleeHaste, AuraType.modRangedHaste, AuraType.modDamageDone, AuraType.modDamagePercentDone:
            if (positive)
                continue;
            nonmui = true;
            break;
        case AuraType.modSpellCritChance, AuraType.modSpellHitChance:
            if (multirank && (spell.attributes & passiveAttr))
                continue;
            nonmui = true;
            break;
        case AuraType.spellMagnet:
            continue;
        case AuraType.modPossess, AuraType.modPossessPet, AuraType.modCharm, AuraType.aoeCharm, AuraType.damageShield,
                AuraType.modShapeshift, AuraType.mounted, AuraType.empathy, AuraType.modCastingSpeed,
                AuraType.modMountedSpeedNotStack, AuraType.modDetectRange:
            return false;
        default:
            break;
        }
        if (nonmui && !isChannelled)
            return false;
        if (multirank && positive)
            return false;
    }
    return true;
}

unittest
{
    // As spell_template has them. Sunder Armor (11597): MOD_RESISTANCE -armor, PreventionType 2, StackAmount 5.
    SpellInfo sunder;
    sunder.effect[0] = SpellEffect.applyAura;
    sunder.casting.applyAuraName[0] = AuraType.modResistance;
    sunder.casting.preventionType = 2;
    sunder.casting.spellFamilyName = 4;
    sunder.casting.spellFamilyFlags = 0x4000;
    assert(!stacksAcrossCasters(sunder, false, false), "one Sunder Armor stack for all the warriors");
    // Corruption (172): PERIODIC_DAMAGE: each warlock's own.
    SpellInfo corruption;
    corruption.effect[0] = SpellEffect.applyAura;
    corruption.casting.applyAuraName[0] = AuraType.periodicDamage;
    corruption.casting.spellFamilyName = 5;
    corruption.casting.spellFamilyFlags = 0x2;
    assert(stacksAcrossCasters(corruption, false, false));
    // Power Word: Fortitude (1243): MOD_STAT stamina, magic, priest family flags 0x8: one, whoever cast it.
    SpellInfo fortitude;
    fortitude.effect[0] = SpellEffect.applyAura;
    fortitude.casting.applyAuraName[0] = AuraType.modStat;
    fortitude.casting.dispel = 1;
    fortitude.casting.spellFamilyName = 6;
    fortitude.casting.spellFamilyFlags = 0x8;
    assert(!stacksAcrossCasters(fortitude, true, false));
    // Winter's Chill (12579): MOD_ATTACKER_SPELL_CRIT_CHANCE, family flags 0: each mage's own stack.
    SpellInfo chill;
    chill.effect[0] = SpellEffect.applyAura;
    chill.casting.applyAuraName[0] = AuraType.modAttackerSpellCritChance;
    chill.casting.dispel = 1;
    chill.casting.spellFamilyName = 3;
    assert(stacksAcrossCasters(chill, false, false));
}

/// Player spells documented as debuffs without a target icon.
bool hiddenTargetDebuff(const ref SpellInfo spell)
{
    // First ranks and their spell_chain successors. Several unrelated spells share family flags.
    switch (spell.id)
    {
    case 10, 6141, 8427, 10185, 10186, 10187: // Blizzard
    case 5143, 5144, 5145, 8416, 8417, 10211, 10212, 25345: // Arcane Missiles
    case 5740, 6219, 11677, 11678: // Rain of Fire
    case 2120, 2121, 8422, 8423, 10215, 10216: // Flamestrike
    case 1510, 14294, 14295: // Volley
    case 26573, 20116, 20922, 20923, 20924: // Consecration
    case 14183: // Premeditation
        return true;
    default: return false;
    }
}

/// One spell's aura on a unit, with each of its aura effects.
final class Aura
{
    const(SpellInfo)* spell;
    ulong caster;
    uint casterLevel;
    float periodicThreat = 1;  /// school and spell threat modifiers when cast, used while the caster is remote
    int periodicResistanceMod;
    bool periodicCasterPvP;
    bool detachedChannel;     /// a triggered spell's aura runs without a caster channel
    ulong channelToken;       /// the named channel that applied this aura, zero for other auras
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
    float heartbeatChance = 0; /// percent: the chance it breaks at each heartbeat (`SPELL_ATTR_HEARTBEAT_RESIST`)
    int heartbeatInterval;     /// milliseconds between heartbeats
    int heartbeatTimer;        /// until the next

    /// The low three bits select spell effects. Persist disposition alongside them so
    /// a relog cannot turn a hostile effect into a buff and free a debuff slot.
    enum uint savedNegative = 1 << 3, savedPositiveFlag = 1 << 4;
    uint savedEffectMask() const { return effects | (positive ? savedPositiveFlag : savedNegative); }

    static bool savedPositive(const ref SpellInfo spell, uint mask)
    {
        if (mask & (savedPositiveFlag | savedNegative))
            return (mask & savedPositiveFlag) != 0;
        // Older rows only carried effect bits. Enemy-targeted aura effects are unambiguous.
        foreach (i; 0 .. 3)
            if ((mask & (1 << i)) && (spell.implicitTargetA[i] == ImplicitTarget.enemy
                || spell.implicitTargetA[i] == ImplicitTarget.enemiesAroundDest
                || spell.implicitTargetA[i] == ImplicitTarget.enemiesAroundSource))
                return false;
        return true;
    }

    // A region handoff keeps the individual tick timers, stacks and caster modifiers.
    private enum migrationFields = ["caster", "casterLevel", "periodicThreat", "periodicResistanceMod",
        "periodicCasterPvP", "detachedChannel", "channelToken", "slot", "duration", "maxDuration", "positive", "passive",
        "stacks", "charges", "effects", "amount", "period", "periodTimer", "heartbeatChance",
        "heartbeatInterval", "heartbeatTimer"];

    package void saveState(ref ByteWriter writer) const
    {
        import std.traits : isStaticArray;

        writer.put(spell.id);
        static foreach (field; migrationFields)
        {
            static if (isStaticArray!(typeof(__traits(getMember, this, field))))
                foreach (value; __traits(getMember, this, field))
                    writer.put(value);
            else
                writer.put(__traits(getMember, this, field));
        }
    }

    package static Aura loadState(ref ByteReader reader, const(SpellInfo)* delegate(uint) lookup)
    {
        import std.traits : isStaticArray;

        auto aura = new Aura;
        const id = reader.read!uint;
        aura.spell = lookup is null ? null : lookup(id);
        static foreach (field; migrationFields)
        {
            static if (isStaticArray!(typeof(__traits(getMember, aura, field))))
                foreach (ref value; __traits(getMember, aura, field))
                    value = reader.read!(typeof(value));
            else
                __traits(getMember, aura, field) = reader.read!(typeof(__traits(getMember, aura, field)));
        }
        return aura;
    }

    /**
     * It may break early (`SpellAuraHolder::SetHeartbeatResist`): `chance` percent at each heartbeat, more for each
     * diminishing level; the heartbeats come at its whole duration over two plus that level, at least a second apart.
     */
    void setHeartbeatResist(float chance, int originalDuration, uint diminishLevel = 0) pure nothrow @nogc @safe
    {
        if (chance <= 0 || originalDuration <= 0)
            return;
        heartbeatChance = chance * (1 + diminishLevel);
        const interval = originalDuration / cast(int)(2 + diminishLevel);
        heartbeatInterval = interval > 1000 ? interval : 1000;
        heartbeatTimer = heartbeatInterval;
    }

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
    /// Counts each aura applied, refreshed or removed: what is made of the auras (a pet's stats) is made again when it
    /// changed.
    uint changes;

    /// Serialize live state alongside the unit's separately saved update fields.
    package void saveState(ref ByteWriter writer) const
    {
        writer.put(cast(uint) list.length);
        foreach (aura; list)
            aura.saveState(writer);
    }

    /// Restore the timers and slot identities without replaying application effects or scripts.
    package void loadState(ref ByteReader reader, ref UpdateValues values, const(SpellInfo)* delegate(uint) lookup)
    {
        list = null;
        const count = reader.read!uint;
        uint debuffs;
        foreach (_; 0 .. count)
        {
            auto aura = Aura.loadState(reader, lookup);
            if (aura.slot != noSlot && aura.slot >= maxAuras)
                continue;
            if (aura.spell !is null && (aura.positive || aura.passive ||
                ((aura.slot != noSlot || hiddenTargetDebuff(*aura.spell)) && debuffs < maxAuras - maxPositiveAuras)))
            {
                if (!aura.positive && !aura.passive)
                    ++debuffs;
                list ~= aura;
            }
            else if (aura.slot != noSlot)
                clearSlot(values, aura.slot);
        }
        ++changes;
    }

    /**
     * Applies `aura`, or the same spell's from the same caster is
     * refreshed (and stacked) instead. Returns the aura in effect and whether it is new.
     */
    Aura apply(Aura aura, ref UpdateValues values, out bool isNew)
    {
        // The same caster's again; or another's of a spell that stacks (`StackAmount`) but not side by side: one
        // stack for them all, now the new caster's (Sunder Armor from two warriors: `SetStackAmount`).
        enum uint channelled = 0x04 | 0x40;
        const shared_ = aura.spell.casting.stackAmount && !aura.passive && !(aura.spell.attributesEx & channelled)
            && !stacksAcrossCasters(*aura.spell, aura.positive, playerControlled(values));
        foreach (existing; list)
            if (existing.spell.id == aura.spell.id && (existing.caster == aura.caster || (shared_ && !existing.passive)))
            {
                existing.caster = aura.caster;
                existing.casterLevel = aura.casterLevel;
                existing.periodicThreat = aura.periodicThreat;
                existing.periodicResistanceMod = aura.periodicResistanceMod;
                existing.periodicCasterPvP = aura.periodicCasterPvP;
                existing.detachedChannel = aura.detachedChannel;
                existing.channelToken = aura.channelToken;
                existing.duration = existing.maxDuration = aura.maxDuration;
                if (existing.stacks < (aura.spell.casting.stackAmount ? aura.spell.casting.stackAmount : 1))
                    ++existing.stacks;
                existing.amount = aura.amount;
                writeSlot(existing, values);
                ++changes;
                isNew = false;
                return existing;
            }
        const hidden = !aura.positive && hiddenTargetDebuff(*aura.spell);
        if (!aura.positive && !aura.passive)
        {
            uint debuffs;
            foreach (existing; list)
                debuffs += !existing.positive && !existing.passive;
            if (debuffs >= maxAuras - maxPositiveAuras)
                return null;
        }
        isNew = true;
        if (!aura.passive && !hidden)
        {
            const from = aura.positive ? 0 : maxPositiveAuras, to = aura.positive ? maxPositiveAuras : maxAuras;
            foreach (s; from .. to)
                if (values.get!UNIT_FIELD_AURA(s) == 0)
                {
                    aura.slot = cast(ubyte) s;
                    break;
                }
        }
        if (!aura.positive && !aura.passive && !hidden && aura.slot == noSlot)
        {
            isNew = false;
            return null;
        }
        list ~= aura;
        ++changes;
        writeSlot(aura, values);
        showOnFields(aura, true, values);
        return aura;
    }

    /**
     * Another caster's aura of `aura`'s spell that `aura` takes the place of (CMaNGOS's `AddSpellAuraHolder`): one that
     * may not stand beside it (two priests' Power Word: Fortitude); null if none. The caller takes it away, with what
     * it did, before applying `aura`. One that stacks is shared instead (`apply`).
     */
    Aura displacedBy(const Aura aura, ref UpdateValues values)
    {
        if (aura.passive)
            return null;
        Aura periodic;
        uint debuffs;
        foreach (existing; list)
        {
            if (existing.spell.id == aura.spell.id)
            {
                if (existing.caster == aura.caster)
                    return null; // refresh
                if (!existing.passive && !stacksAcrossCasters(*aura.spell, aura.positive, playerControlled(values)))
                    return aura.spell.casting.stackAmount ? null : existing;
            }
            if (!existing.positive && !existing.passive)
            {
                ++debuffs;
                if (periodic is null && ordinaryDot(existing))
                    periodic = existing;
            }
        }
        // Periodic damage can replace a peer. Crowd control and Sunder Armor can
        // also displace it. Prefer the oldest eligible effect in application order.
        if (!aura.positive && periodic !is null && debuffs >= maxAuras - maxPositiveAuras)
        {
            const sunder = aura.spell.casting.spellFamilyName == 4 && (aura.spell.casting.spellFamilyFlags & 0x4000);
            if (ordinaryDot(aura) || sunder || aura.has(AuraType.modFear) || aura.has(AuraType.modConfuse)
                || aura.has(AuraType.modStun) || aura.has(AuraType.modRoot))
                return periodic;
        }
        return null;
    }

    private static bool ordinaryDot(const Aura aura)
    {
        if (!aura.effects)
            return hiddenTargetDebuff(*aura.spell) && aura.spell.hasEffect(SpellEffect.persistentAreaAura);
        foreach (i; 0 .. 3)
            if ((aura.effects & (1 << i)) && aura.type(i) != AuraType.periodicDamage)
                return false;
        return true;
    }

    /// Whether the unit is a player's or a player's pet (`UNIT_FLAG_PLAYER_CONTROLLED`).
    private static bool playerControlled(ref UpdateValues values)
    {
        enum uint playerControlledFlag = 0x00000008;
        return (values.get!UNIT_FIELD_FLAGS & playerControlledFlag) != 0;
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
        ++changes;
        if (aura.slot != noSlot)
        {
            clearSlot(values, aura.slot);
            aura.slot = noSlot;
        }
        showOnFields(aura, false, values);
    }

    private static void clearSlot(ref UpdateValues values, uint slot)
    {
        values.set!UNIT_FIELD_AURA(slot, 0u);
        setBits!UNIT_FIELD_AURAFLAGS(values, slot, 4, 0);
        setBits!UNIT_FIELD_AURALEVELS(values, slot, 8, 0);
        setBits!UNIT_FIELD_AURAAPPLICATIONS(values, slot, 8, 0);
    }

    /// `UNIT_DYNFLAG_TRACK_UNIT`, `UNIT_DYNFLAG_DEAD` and `UNIT_VIS_FLAG_UNTRACKABLE` (`UNIT_FIELD_BYTES_1`'s fourth byte).
    enum uint dynTrackUnit = 0x02, dynDead = 0x20;
    enum ubyte visUntrackable = 0x04; /// ditto

    /**
     * What the unit's fields show of an aura that began (`applied`) or ended, for every client that sees the
     * unit (CMaNGOS's aura handlers): Hunter's Mark (`MOD_STALKED`) the track-unit flag, Feign Death the dead
     * flag, while any such aura lasts; Aspect of the Beast (`UNTRACKABLE`) the untrackable flag; Bestial Wrath
     * (`MOD_SCALE`) its size, by its percentage (`ApplyPercentModFloatValue`).
     */
    private void showOnFields(const Aura aura, bool applied, ref UpdateValues values)
    {
        void dynamicFlag(uint flag, AuraType type)
        {
            const flags = values.get!UNIT_DYNAMIC_FLAGS;
            values.set!UNIT_DYNAMIC_FLAGS(has(type) ? flags | flag : flags & ~flag);
        }

        if (aura.has(AuraType.aurasVisible))
        {
            import dmangos.world.defines : UnitFlags;

            const flags = values.get!UNIT_FIELD_FLAGS;
            values.set!UNIT_FIELD_FLAGS(has(AuraType.aurasVisible) ? flags | UnitFlags.aurasVisible
                : flags & ~UnitFlags.aurasVisible);
        }
        if (aura.has(AuraType.modStalked))
            dynamicFlag(dynTrackUnit, AuraType.modStalked);
        if (aura.has(AuraType.feignDeath))
            dynamicFlag(dynDead, AuraType.feignDeath);
        if (aura.has(AuraType.untrackable))
        {
            const vis = values.getByte!UNIT_FIELD_BYTES_1(3);
            values.setByte!UNIT_FIELD_BYTES_1(3, cast(ubyte)(has(AuraType.untrackable) ? vis | visUntrackable
                : vis & ~visUntrackable));
        }
        foreach (i; 0 .. 3)
            if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.modScale && aura.amount[i] > -100)
            {
                const factor = (100.0f + aura.amount[i]) / 100;
                const scale = values.get!OBJECT_FIELD_SCALE_X;
                values.set!OBJECT_FIELD_SCALE_X(applied ? scale * factor : scale / factor);
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
        Aura[] heartbeats;
        update(diff, ticks, expired, heartbeats);
    }

    /**
     * ditto; each heartbeat that came due is added to `heartbeats` (`SpellAuraHolder::UpdateHeartbeatResist`), for
     * the caller to roll whether the aura breaks. As CMaNGOS's, a timer that comes to exactly none stops.
     */
    void update(int diff, ref AuraTick[] ticks, ref Aura[] expired, ref Aura[] heartbeats)
    {
        foreach (aura; list)
        {
            if (aura.heartbeatChance > 0 && aura.heartbeatInterval && aura.heartbeatTimer > 0 && aura.duration)
            {
                aura.heartbeatTimer -= diff;
                while (aura.heartbeatTimer < 0)
                {
                    aura.heartbeatTimer += aura.heartbeatInterval;
                    heartbeats ~= aura;
                }
            }
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
     * and subclasses take `weaponSubClass` (-1: no weapon: only those with no requirement). `mask` narrows the
     * effects to those whose misc value has one of its bits (-1: any misc value).
     */
    int totalForWeapon(AuraType type, int weaponSubClass, int mask = -1) const
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
                if ((aura.effects & (1 << i)) && aura.type(i) == type && (mask == -1 || (aura.misc(i) & mask)))
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
            foreach (ref e; hiddenEffectsOf(aura.spell.id)) // what only its tooltip gives (Barkskin's)
                if (e.type == type && (matches is null || matches(e.misc)))
                    product *= (100.0f + e.amount) / 100.0f;
        }
        return product;
    }

    /**
     * By how much its attacks of `attackType` (0 main hand, 1 off hand, 2 ranged) take longer: haste of a% makes
     * them take 100 / (100 + a) as long, a slow of a% (100 + a) / 100 as long (CMaNGOS's `ApplyAttackTimePercentMod`).
     * The main hand: `MOD_MELEE_HASTE` (Slice and Dice, Flurry) and `MOD_ATTACKSPEED`; the off hand the first;
     * ranged: `MOD_RANGED_HASTE` (Rapid Fire) and the greatest `MOD_RANGED_AMMO_HASTE` (a quiver).
     */
    float attackTimeFactor(uint attackType) const
    {
        float factor = 1;
        int ammo;
        void apply(int a)
        {
            factor *= a > 0 ? 100.0f / (100 + a) : (100.0f - a) / 100;
        }
        foreach (aura; list)
        {
            foreach (ref e; hiddenEffectsOf(aura.spell.id)) // what only its tooltip gives (Barkskin's slow)
                if (e.type == AuraType.modMeleeHaste && attackType < 2)
                    apply(e.amount);
            foreach (i; 0 .. 3)
            {
                if (!(aura.effects & (1 << i)))
                    continue;
                const amount = aura.amount[i] * cast(int) aura.stacks;
                switch (aura.type(i))
                {
                case AuraType.modMeleeHaste:
                    if (attackType < 2)
                        apply(amount);
                    break;
                case AuraType.modAttackSpeed:
                    if (attackType == 0)
                        apply(amount);
                    break;
                case AuraType.modRangedHaste:
                    if (attackType == 2)
                        apply(amount);
                    break;
                case AuraType.modRangedAmmoHaste:
                    if (attackType == 2 && amount > ammo)
                        ammo = amount;
                    break;
                default:
                    break;
                }
            }
        }
        if (ammo)
            apply(ammo);
        return factor;
    }

    /// By how much its casts take longer (`MOD_CASTING_SPEED`: Curse of Tongues), as attack times are (`UNIT_MOD_CAST_SPEED`).
    float castTimeFactor() const
    {
        float factor = 1;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.modCastingSpeed)
                {
                    const a = aura.amount[i] * cast(int) aura.stacks;
                    factor *= a > 0 ? 100.0f / (100 + a) : (100.0f - a) / 100;
                }
        return factor;
    }

    /**
     * Whether one with these auras sees through `target`'s invisibility (`MOD_INVISIBILITY` levels by type, summed,
     * against this set's strongest `MOD_INVISIBILITY_DETECTION` of the type): what `combat.seesThrough` decides, from the auras alone, for the
     * map's sight checks (no `Fighter` to build for each object).
     */
    bool seesThroughInvisibility(const ref AuraSet target) const
    {
        bool invisible;
        foreach (aura; target.list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == AuraType.modInvisibility)
                {
                    const type = aura.misc(i);
                    const level = target.totalByMisc(AuraType.modInvisibility, type);
                    if (level <= 0)
                        continue;
                    invisible = true;
                    if (level <= greatestByMisc(AuraType.modInvisibilityDetection, type))
                        return true;
                }
        return !invisible;
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

    /// The greatest of those whose misc value is `misc` (0 if none).
    int greatestByMisc(AuraType type, int misc) const
    {
        int greatest;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && aura.misc(i) == misc)
                {
                    const amount = aura.amount[i] * cast(int) aura.stacks;
                    if (amount > greatest)
                        greatest = amount;
                }
        return greatest;
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

    /**
     * Healing of `amount` from a spell of `school` as its target takes it (CMaNGOS's `SpellHealingBonusTaken`): what
     * `MOD_HEALING` adds (Amplify Magic; Dampen Magic takes off), then `MOD_HEALING_PCT` (Mortal Strike's half).
     */
    uint healingTaken(uint amount, uint school) const
    {
        if (list.length == 0)
            return amount;
        const flat = cast(long) amount + totalByMiscMask(AuraType.modHealing, 1 << school);
        const total = flat * multiplier(AuraType.modHealingPct);
        return total > 0 ? cast(uint) total : 0;
    }

    /// The greatest of those whose misc value has a bit of `mask` (0 if none): `MOD_RESISTANCE_EXCLUSIVE`'s, of
    /// which only the strongest of each school counts (Mark of the Wild and a resistance aura do not add up).
    int greatestByMiscMask(AuraType type, int mask) const
    {
        int greatest;
        foreach (aura; list)
            foreach (i; 0 .. 3)
                if ((aura.effects & (1 << i)) && aura.type(i) == type && (aura.misc(i) & mask))
                {
                    const amount = aura.amount[i] * cast(int) aura.stacks;
                    if (amount > greatest)
                        greatest = amount;
                }
        return greatest;
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
    Aura find(uint spell, ulong caster = 0)
    {
        foreach (aura; list)
            if (aura.spell.id == spell && (!caster || aura.caster == caster))
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
        if (spell.effect[i] != SpellEffect.applyAura && spell.effect[i] != SpellEffect.applyAreaAuraParty
                && spell.effect[i] != SpellEffect.applyAreaAuraPet)
            continue;
        enableAuraEffect(aura, i, values[i]);
    }
    return aura;
}

/// Initialize an effect included in this aura before it is applied.
package void enableAuraEffect(Aura aura, size_t i, int value)
{
    aura.effects |= cast(ubyte)(1 << i);
    aura.amount[i] = value;
    int period = aura.spell.casting.amplitude[i];
    switch (aura.type(i))
    {
    case AuraType.modRegen:
        period = 5000;
        break;
    case AuraType.periodicDamage, AuraType.periodicHeal, AuraType.obsModHealth, AuraType.obsModMana,
            AuraType.periodicEnergize, AuraType.periodicTriggerSpell, AuraType.periodicLeech,
            AuraType.periodicManaLeech, AuraType.periodicHealthFunnel:
        break;
    default:
        period = 0;
        break;
    }
    aura.period[i] = aura.periodTimer[i] = period;
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

/**
 * Invisibility detection: only the strongest of a type counts (CMaNGOS's `HandleInvisibilityDetect`). The rows of
 * spell_template, all misc value 0: Greater Invisibility (10228) 300; Detect Lesser Invisibility (132) 100,
 * Detect Invisibility (2970) 200, Detect Greater Invisibility (11743) 300.
 */
unittest
{
    import dmangos.world.combat : Fighter, seesThrough;
    import dmangos.world.updatefields : TypeId;

    SpellInfo[4] spells;
    foreach (n, row; [[10228, AuraType.modInvisibility], [132, AuraType.modInvisibilityDetection],
            [2970, AuraType.modInvisibilityDetection], [11743, AuraType.modInvisibilityDetection]])
    {
        spells[n].id = row[0];
        spells[n].effect[0] = SpellEffect.applyAura;
        spells[n].casting.applyAuraName[0] = cast(AuraType) row[1];
    }
    auto hidden = UpdateValues(TypeId.unit), seeing = UpdateValues(TypeId.unit);
    AuraSet target, viewer;
    bool isNew;
    target.apply(makeAura(&spells[0], 1, 60, 60_000, true, [300, 0, 0]), hidden, isNew);
    viewer.apply(makeAura(&spells[1], 2, 60, 60_000, true, [100, 0, 0]), seeing, isNew);
    viewer.apply(makeAura(&spells[2], 2, 60, 60_000, true, [200, 0, 0]), seeing, isNew);
    bool sees()
    {
        Fighter v, t;
        v.invisibilityFrom(viewer);
        t.invisibilityFrom(target);
        const bySight = viewer.seesThroughInvisibility(target);
        assert(bySight == seesThrough(v, t), "the map and combat agree");
        return bySight;
    }
    assert(!sees(), "100 and 200 do not add up to Greater Invisibility's 300");
    viewer.apply(makeAura(&spells[3], 2, 60, 60_000, true, [300, 0, 0]), seeing, isNew);
    assert(sees(), "Detect Greater Invisibility's 300 does");
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

/// Haste and slows on attack times: haste divides, a slow multiplies.
unittest
{
    import std.math : isClose;
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    SpellInfo sliceAndDice, thunderClap, rapidFire;
    sliceAndDice.id = 5171;
    sliceAndDice.effect[0] = SpellEffect.applyAura;
    sliceAndDice.casting.applyAuraName[0] = AuraType.modMeleeHaste;
    thunderClap.id = 6343;
    thunderClap.effect[0] = SpellEffect.applyAura;
    thunderClap.casting.applyAuraName[0] = AuraType.modAttackSpeed;
    rapidFire.id = 3045;
    rapidFire.effect[0] = SpellEffect.applyAura;
    rapidFire.casting.applyAuraName[0] = AuraType.modRangedHaste;

    AuraSet set;
    bool isNew;
    set.apply(makeAura(&sliceAndDice, 1, 10, 9000, true, [20, 0, 0]), values, isNew);
    assert(isClose(set.attackTimeFactor(0), 100.0f / 120) && isClose(set.attackTimeFactor(1), 100.0f / 120));
    assert(set.attackTimeFactor(2) == 1, "not ranged");
    set.apply(makeAura(&thunderClap, 2, 10, 10_000, false, [-10, 0, 0]), values, isNew);
    assert(isClose(set.attackTimeFactor(0), 100.0f / 120 * 1.1f) && isClose(set.attackTimeFactor(1), 100.0f / 120),
        "a slow of the main hand only");
    set.apply(makeAura(&rapidFire, 1, 10, 15_000, true, [40, 0, 0]), values, isNew);
    assert(isClose(set.attackTimeFactor(2), 100.0f / 140));
}

/// Curse of Tongues: casts take longer, as a slow makes swings.
unittest
{
    import std.math : isClose;
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    SpellInfo tongues;
    tongues.id = 1714;
    tongues.effect[0] = SpellEffect.applyAura;
    tongues.casting.applyAuraName[0] = AuraType.modCastingSpeed;
    AuraSet set;
    bool isNew;
    assert(set.castTimeFactor() == 1);
    set.apply(makeAura(&tongues, 1, 10, 30_000, false, [-50, 0, 0]), values, isNew);
    assert(isClose(set.castTimeFactor(), 1.5f));
}

/// Heartbeat resistance: a root of 8 s gets a heartbeat each 4 s (at least one a second); a timer at exactly none stops.
unittest
{
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    SpellInfo root;
    root.id = 339;
    root.effect[0] = SpellEffect.applyAura;
    root.casting.applyAuraName[0] = AuraType.modRoot;
    AuraSet set;
    bool isNew;
    auto aura = set.apply(makeAura(&root, 1, 10, 8000, false, [0, 0, 0]), values, isNew);
    aura.setHeartbeatResist(5, 8000);
    assert(aura.heartbeatChance == 5 && aura.heartbeatInterval == 4000);
    AuraTick[] ticks;
    Aura[] expired, heartbeats;
    set.update(3000, ticks, expired, heartbeats);
    assert(heartbeats.length == 0);
    set.update(1500, ticks, expired, heartbeats);
    assert(heartbeats == [aura] && aura.heartbeatTimer == 3500);
    heartbeats = null;
    set.update(3500, ticks, expired, heartbeats);
    assert(heartbeats.length == 0 && aura.heartbeatTimer == 0, "exactly none: no heartbeat");
    set.update(100, ticks, expired, heartbeats);
    assert(heartbeats.length == 0, "and none after (as CMaNGOS's)");

    auto brief = new Aura;
    brief.setHeartbeatResist(5, 1500, 1);
    assert(brief.heartbeatChance == 10 && brief.heartbeatInterval == 1000, "a diminished one: more, and sooner");
}

/**
 * The same spell from two casters: two warriors' Sunder Armor is one stack, the newest caster's; two warlocks'
 * Corruption stand side by side; a second priest's Power Word: Fortitude takes the first's place.
 */
unittest
{
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    // As spell_template has them: Sunder Armor (11597) MOD_RESISTANCE, PreventionType 2, StackAmount 5; Corruption
    // (172) PERIODIC_DAMAGE; Power Word: Fortitude (1243) MOD_STAT, Dispel 1, priest family flags 0x8.
    SpellInfo sunder, corruption, fortitude;
    sunder.id = 11597;
    sunder.effect[0] = SpellEffect.applyAura;
    sunder.casting.applyAuraName[0] = AuraType.modResistance;
    sunder.casting.preventionType = 2;
    sunder.casting.stackAmount = 5;
    sunder.casting.spellFamilyName = 4;
    sunder.casting.spellFamilyFlags = 0x4000;
    corruption.id = 172;
    corruption.effect[0] = SpellEffect.applyAura;
    corruption.casting.applyAuraName[0] = AuraType.periodicDamage;
    corruption.casting.spellFamilyName = 5;
    corruption.casting.spellFamilyFlags = 0x2;
    fortitude.id = 1243;
    fortitude.effect[0] = SpellEffect.applyAura;
    fortitude.casting.applyAuraName[0] = AuraType.modStat;
    fortitude.casting.dispel = 1;
    fortitude.casting.spellFamilyName = 6;
    fortitude.casting.spellFamilyFlags = 0x8;

    AuraSet set;
    bool isNew;
    auto first = set.apply(makeAura(&sunder, 1, 60, 30_000, false, [-450, 0, 0]), values, isNew);
    set.apply(makeAura(&sunder, 1, 60, 30_000, false, [-450, 0, 0]), values, isNew);
    auto shared_ = set.apply(makeAura(&sunder, 2, 60, 30_000, false, [-450, 0, 0]), values, isNew);
    assert(!isNew && shared_ is first && first.stacks == 3 && first.caster == 2, "one stack, the newest caster's");
    assert(set.total(AuraType.modResistance) == -1350);

    set.apply(makeAura(&corruption, 1, 60, 18_000, false, [100, 0, 0]), values, isNew);
    set.apply(makeAura(&corruption, 2, 60, 18_000, false, [100, 0, 0]), values, isNew);
    assert(isNew && set.total(AuraType.periodicDamage) == 200, "each warlock's");

    auto one = makeAura(&fortitude, 1, 60, 1_800_000, true, [54, 0, 0]);
    set.apply(one, values, isNew);
    auto other = makeAura(&fortitude, 2, 60, 1_800_000, true, [54, 0, 0]);
    assert(set.displacedBy(other, values) is one, "the second priest's takes its place");
    assert(set.displacedBy(makeAura(&corruption, 3, 60, 18_000, false, [100, 0, 0]), values) is null);
}

/// Detect Magic uses a public unit flag. Keep it while any revealing aura is active.
unittest
{
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.updatefields : TypeId;

    auto values = UpdateValues(TypeId.unit);
    values.set!UNIT_FIELD_FLAGS(UnitFlags.pvp);
    SpellInfo detect;
    detect.id = 2855;
    detect.effect[0] = SpellEffect.applyAura;
    detect.casting.applyAuraName[0] = AuraType.aurasVisible;
    AuraSet set;
    bool isNew;
    auto first = set.apply(makeAura(&detect, 1, 60, 120_000, false, [0, 0, 0]), values, isNew);
    auto second = set.apply(makeAura(&detect, 2, 60, 120_000, false, [0, 0, 0]), values, isNew);
    assert(values.get!UNIT_FIELD_FLAGS == (UnitFlags.pvp | UnitFlags.aurasVisible));
    set.remove(first, values);
    assert(values.get!UNIT_FIELD_FLAGS & UnitFlags.aurasVisible);
    set.remove(second, values);
    assert(values.get!UNIT_FIELD_FLAGS == UnitFlags.pvp);
}
