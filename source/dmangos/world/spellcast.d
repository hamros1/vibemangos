/**
 * The parts of casting a spell that need no session or map: cast
 * targets as the client sends them, the cast time, duration and range from the DBCs, an effect's
 * value at a level, the power a cast costs, the spell hit roll, and the packets that show a cast.
 * `dmangos.world.spellhandlers` puts them to work.
 */
module dmangos.world.spellcast;

import dmangos.world.spellids;

public import dmangos.world.spellids : ImplicitTarget, DamageClass;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.clientdata : ClientData;
import dmangos.world.spells : SpellInfo;
import dmangos.world.combat : Fighter;

/// `SpellCastResult` (1.12's values); `ok` is never sent as a failure.
enum SpellCastResult : ubyte
{
    noComboPoints = 0x46, /// "That ability requires combo points"
    equippedItemClassMainhand = 0x1A,
    notBehind = 0x33,
    notShapeshift = 0x3D,
    onlyOutdoors = 0x55,
    onlyShapeshift = 0x56,
    onlyStealthed = 0x57,
    targetAffectingCombat = 0x66,
    unitNotInfront = 0x7C,
    confused = 0x16,
    fleeing = 0x1E,
    pacified = 0x5A,
    silenced = 0x60,
    stunned = 0x64,
    affectingCombat = 0x00,
    alreadyAtFullHealth = 0x01,
    alreadyAtFullPower = 0x02,
    alreadyHaveCharm = 0x04,
    alreadyHaveSummon = 0x05,
    alreadyOpen = 0x06,
    badImplicitTargets = 0x09,
    badTargets = 0x0A,
    casterAuraState = 0x12,
    targetAuraState = 0x67,    /// the target lacks what the spell needs on it (Conflagrate's Immolate), or is immune
    fizzle = 0x1D,
    auraBounced = 0x07,        /// "A more powerful spell is already active"
    nothingToDispel = 0x4E,
    casterDead = 0x13,
    chestInUse = 0x15,
    dontReport = 0x17,
    equippedItemClass = 0x19,
    error = 0x1C,
    lowCastLevel = 0x2C,
    targetNotDead = 0x6E,
    targetNotLooted = 0x70,
    targetNoPockets = 0x72,
    targetUnskinnable = 0x74,
    highLevel = 0x20,
    interrupted = 0x23,
    itemNotReady = 0x28,
    lineOfSight = 0x2A,
    notFishable = 0x34,
    moving = 0x2E,
    notInfront = 0x36,
    notKnown = 0x38,
    notReady = 0x3C,
    notStanding = 0x3E,
    notTrading = 0x40,         /// "Tried to enchant a trade item, but not trading"
    notMounted = 0x39,         /// "You are mounted"
    notOnTaxi = 0x3A,          /// "You are in flight"
    notWhileGhost = 0x42,
    noPet = 0x4C,
    lowLevel = 0x2B,
    trainingPoints = 0x79,
    noPower = 0x4D,
    outOfRange = 0x59,
    reagents = 0x5C,
    requiresSpellFocus = 0x5E, /// "Requires %s": the spell focus id follows
    totems = 0x78,             /// a tool missing: the spell's tools follow
    cantBeDisenchanted = 0x0C,
    cantCastOnTapped = 0x0E,
    itemGone = 0x26,
    itemNotFound = 0x27,
    tryAgain = 0x7A,           /// "Failed attempt"
    noChargesRemain = 0x44,
    noAmmo = 0x43,
    spellInProgress = 0x61,
    targetsDead = 0x65,
    targetEnemy = 0x69,
    targetFriendly = 0x6B,
    tooClose = 0x76,
    tooManyOfItem = 0x77,
    unknown = 0x91,
    ok = 0xFF,
}

/// What a cast's targets include, as the client sends them.
enum TargetFlags : ushort
{
    self = 0x0000,
    unit = 0x0002,
    item = 0x0010,
    sourceLocation = 0x0020,
    destLocation = 0x0040,
    unitEnemy = 0x0080,
    unitAlly = 0x0100,
    corpseEnemy = 0x0200,
    unitDead = 0x0400,
    gameObject = 0x0800,
    tradeItem = 0x1000,
    string_ = 0x2000,
    locked = 0x4000,
    corpseAlly = 0x8000,
}

/// `SpellMissInfo`
enum SpellMissInfo : ubyte
{
    none = 0,
    miss = 1,
    resist = 2,
    dodge = 3,
    parry = 4,
    block = 5,
    evade = 6,
    immune = 7,
    immune2 = 8,
    deflect = 9,
    absorb = 10,
    reflect = 11,
}


/// What interrupts a cast (`Spell.dbc`'s interrupt flags).
enum uint interruptMovement = 0x01, interruptDamagePushback = 0x02, interruptDamageCancels = 0x10;
/// ... `SPELL_INTERRUPT_FLAG_COMBAT`
enum uint interruptCombat = 0x08;
/// `POWER_HEALTH`: a spell's `PowerType` when it costs health (Bloodrage, Health Funnel, Life Tap), -2 in the data.
enum uint powerHealth = uint.max - 1;
/// `PreventionType`: what stops a spell: silence (a caster's spells), or pacify (Aimed Shot, Slam, Arcane Shot).
enum uint preventionSilence = 1, preventionPacify = 2;

/**
 * Whether an interrupt (Kick, Pummel, Counterspell) stops `spell` being cast or channelled, and so locks out its
 * school: one that combat interrupts and silence stops (CMaNGOS's `Spell::IsInterruptible`). Not Aimed Shot or
 * Volley (pacify's), not a trade skill's.
 */
bool isInterruptible(const ref SpellInfo spell) pure nothrow @nogc @safe
{
    return (spell.casting.interruptFlags & interruptCombat) && spell.casting.preventionType == preventionSilence;
}

unittest
{
    // As spell_template has them: Frostbolt (116) InterruptFlags 15, PreventionType 1; Aimed Shot (19434) 15, 2;
    // Volley (1510) 9, 2; Copper Dagger (8880) 15, 0.
    SpellInfo frostbolt, aimed, volley, dagger;
    frostbolt.casting.interruptFlags = 15;
    frostbolt.casting.preventionType = 1;
    aimed.casting.interruptFlags = 15;
    aimed.casting.preventionType = 2;
    volley.casting.interruptFlags = 9;
    volley.casting.preventionType = 2;
    dagger.casting.interruptFlags = 15;
    assert(isInterruptible(frostbolt) && !isInterruptible(aimed) && !isInterruptible(volley) && !isInterruptible(dagger));
}

/// `SPELL_ATTR_ON_NEXT_SWING_NO_DAMAGE` and `SPELL_ATTR_ON_NEXT_SWING`: Heroic Strike and its kind.
enum uint spellAttrOnNextSwing1 = 0x00000004, spellAttrOnNextSwing2 = 0x00000400;
/// `SPELL_ATTR_CANT_USED_IN_COMBAT`
enum uint spellAttrNotInCombat = 0x10000000;
/// `SPELL_ATTR_CASTABLE_WHILE_DEAD`
enum uint spellAttrCastableWhileDead = 0x00800000;
/// `SPELL_ATTR_EX2_CANT_CRIT`
enum uint spellAttrEx2CantCrit = 0x20000000;
/// `SPELL_ATTR_EX3_ALWAYS_HIT`
enum uint spellAttrEx3AlwaysHit = 0x00040000;

/// The cast flags of `SMSG_SPELL_START` and `SMSG_SPELL_GO`.
enum ushort castFlagUnknown2 = 0x0002, castFlagUnknown9 = 0x0100, castFlagAmmo = 0x0020;


/// Whether a spell waits for the next main-hand swing (Heroic Strike).
bool isNextMeleeSwingSpell(const ref SpellInfo spell) pure nothrow @nogc @safe
{
    return (spell.attributes & (spellAttrOnNextSwing1 | spellAttrOnNextSwing2)) != 0;
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

/// What the client says a cast is at.
struct SpellTargets
{
    ushort mask;
    ulong unit;
    ulong gameObject;
    ulong item;
    ulong corpse;
    float[3] source = 0;
    float[3] dest = 0;
    string text;

    /// Reads the targets from a client packet.
    static SpellTargets read(ref ByteReader r)
    {
        SpellTargets t;
        t.mask = r.read!ushort;
        if (t.mask == TargetFlags.self)
            return t;
        if (t.mask & (TargetFlags.unit | TargetFlags.unitEnemy))
            t.unit = r.readPackedGuid();
        if (t.mask & (TargetFlags.gameObject | TargetFlags.locked))
            t.gameObject = r.readPackedGuid();
        if (t.mask & (TargetFlags.item | TargetFlags.tradeItem))
            t.item = r.readPackedGuid();
        if (t.mask & TargetFlags.sourceLocation)
            foreach (ref f; t.source)
                f = r.read!float;
        if (t.mask & TargetFlags.destLocation)
            foreach (ref f; t.dest)
                f = r.read!float;
        if (t.mask & TargetFlags.string_)
            t.text = r.readCString();
        if (t.mask & (TargetFlags.corpseAlly | TargetFlags.corpseEnemy))
            t.corpse = r.readPackedGuid();
        return t;
    }

    /// Writes the targets into a packet.
    void write(ref ByteWriter w) const
    {
        w.put(mask);
        if (mask & (TargetFlags.unit | TargetFlags.corpseEnemy | TargetFlags.gameObject | TargetFlags.corpseAlly))
        {
            if (mask & TargetFlags.unit)
                w.putPackedGuid(unit);
            else if (mask & (TargetFlags.gameObject | TargetFlags.locked))
                w.putPackedGuid(gameObject);
            else
                w.putPackedGuid(corpse);
        }
        if (mask & (TargetFlags.item | TargetFlags.tradeItem))
            w.putPackedGuid(item);
        if (mask & TargetFlags.sourceLocation)
            foreach (f; source)
                w.put(f);
        if (mask & TargetFlags.destLocation)
            foreach (f; dest)
                w.put(f);
        if (mask & TargetFlags.string_)
            w.putCString(text);
    }
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

/// The cast time, in milliseconds, by `SpellCastTimes.dbc` (and the caster's level); 0 is instant.
int castTime(const ref SpellInfo spell, const ClientData client, uint level)
{
    const entry = client.spellCastTimes.lookup(spell.casting.castingTimeIndex);
    if (entry is null)
        return 0;
    int time = entry.castTime + entry.perLevel * cast(int) level;
    if (time < entry.minimum)
        time = entry.minimum;
    return time > 0 ? time : 0;
}

/**
 * The share of its caster's spell power effect `i` of `spell` adds (each tick's, for an effect over time); see
 * docs/FORMULAS.md. Blizzard's own (`ClientData.spellCoefficients`) where its data has the effect as 1.12 has it;
 * otherwise the 1.12 rule: a direct damage or heal by its cast time (1.5 to 3.5 seconds) over 3.5, one over time by
 * its duration over 15 seconds (at most whole) shared among its ticks; less for a spell learned before level 20
 * (3.75% a level). Nothing for anything else.
 */
float bonusCoefficient(const ref SpellInfo spell, size_t i, const ClientData client, uint level)
{
    if (auto row = spell.id in client.spellCoefficients)
    {
        const c = (*row)[i];
        if (c.known && c.effect == spell.effect[i] && c.aura == spell.casting.applyAuraName[i])
            return c.value;
    }
    const penalty = spell.spellLevel > 0 && spell.spellLevel < 20 ? 1.0f - (20.0f - spell.spellLevel) * 0.0375f : 1.0f;
    switch (spell.effect[i])
    {
    case SpellEffect.schoolDamage, SpellEffect.heal, SpellEffect.healthLeech:
        int time = castTime(spell, client, level);
        time = time < 1500 ? 1500 : time > 3500 ? 3500 : time;
        return time / 3500.0f * penalty;
    case SpellEffect.applyAura, SpellEffect.persistentAreaAura, SpellEffect.applyAreaAuraParty:
        const type = spell.casting.applyAuraName[i];
        if (type != AuraType.periodicDamage && type != AuraType.periodicHeal && type != AuraType.periodicLeech)
            return 0;
        const ms = duration(spell, client, level), amplitude = spell.casting.amplitude[i];
        if (ms <= 0 || amplitude <= 0 || ms < amplitude)
            return 0;
        return (ms >= 15_000 ? 1.0f : ms / 15_000.0f) / (ms / amplitude) * penalty;
    default:
        return 0;
    }
}

/// The milliseconds an aura lasts; -1 until cancelled, 0 none.
int duration(const ref SpellInfo spell, const ClientData client, uint level)
{
    const entry = client.spellDurations.lookup(spell.casting.durationIndex);
    if (entry is null)
        return 0;
    int value = entry.duration;
    if (value < 0)
        return -1;
    value += entry.perLevel * cast(int) level;
    if (entry.maximum > 0 && value > entry.maximum)
        value = entry.maximum;
    return value;
}

/**
 * A finishing move's duration with `points` combo points: toward its greatest duration (`maximum`), a fifth a point
 * (CMaNGOS's `CalculateSpellDuration`); from nothing for one whose base is 0 (Kidney Shot rank 1). One that lasts
 * until cancelled (-1) stays so.
 */
int comboDuration(int base, int maximum, uint points) pure nothrow @nogc @safe
{
    return base >= 0 && maximum > base ? base + (maximum - base) * cast(int) points / 5 : base;
}

unittest
{
    // `SpellDuration.dbc` as Kidney Shot rank 1 (408, DurationIndex 187: 0, 0, 5000) and rank 2 (8643, index 285:
    // 1000, 0, 6000) and Slice and Dice (5171, index 185: 6000, 0, 21000) have it.
    assert(comboDuration(0, 5000, 1) == 1000 && comboDuration(0, 5000, 5) == 5000, "Kidney Shot rank 1: a second a point");
    assert(comboDuration(1000, 6000, 1) == 2000 && comboDuration(1000, 6000, 5) == 6000);
    assert(comboDuration(6000, 21000, 3) == 15000);
    assert(comboDuration(-1, -1, 5) == -1);
}

/// The spell's least and greatest range (yards).
float[2] range(const ref SpellInfo spell, const ClientData client)
{
    const entry = client.spellRanges.lookup(spell.casting.rangeIndex);
    if (entry is null)
        return [0, 0];
    return [entry.minRange, entry.maxRange];
}

/// The radius of effect `index` (yards).
float radius(const ref SpellInfo spell, size_t index, const ClientData client)
{
    const entry = client.spellRadii.lookup(spell.casting.radiusIndex[index]);
    return entry is null ? 0 : entry.radius;
}

/**
 * Effect `index`'s value for a caster of `level` (base points, more per
 * level between the spell's levels, and the dice); `roll` picks within the dice (0 .. 1).
 */
int effectValue(const ref SpellInfo spell, size_t index, uint level, float roll)
{
    const c = &spell.casting;
    const baseDice = spell.baseDice[index];
    float basePoints = spell.basePoints[index];
    int randomPoints = c.dieSides[index];
    if (c.realPointsPerLevel[index] != 0)
    {
        int l = cast(int) level;
        if (l > cast(int) c.maxLevel && c.maxLevel > 0)
            l = cast(int) c.maxLevel;
        else if (l < cast(int) c.baseLevel)
            l = cast(int) c.baseLevel;
        l -= cast(int) spell.spellLevel;
        basePoints += l * c.realPointsPerLevel[index];
        randomPoints += cast(int)(l * c.dicePerLevel[index]);
    }
    if (randomPoints <= 1)
        basePoints += baseDice;
    else
    {
        const lo = baseDice < randomPoints ? baseDice : randomPoints;
        const hi = baseDice < randomPoints ? randomPoints : baseDice;
        basePoints += lo + cast(int)(roll * (hi - lo + 1) - 0.0001f > 0 ? roll * (hi - lo + 1) - 0.0001f : 0);
    }
    return cast(int) basePoints;
}

/// The power a cast costs (no item, no modifiers): the cost and its percentage of the base.
int powerCost(const ref SpellInfo spell, uint level, uint createMana, uint createHealth, uint maxPower)
{
    const c = &spell.casting;
    int cost = cast(int) c.manaCost;
    if (c.manaCostPerLevel)
    {
        const rankLevel = cast(int) level; // a player's rank for this is its level
        cost += cast(int) c.manaCostPerLevel * (rankLevel / 5 - cast(int) c.baseLevel);
    }
    if (c.manaCostPercentage)
    {
        enum uint powerMana = 0;
        if (c.powerType == powerMana)
            cost += c.manaCostPercentage * createMana / 100;
        else if (c.powerType == powerHealth)
            cost += c.manaCostPercentage * createHealth / 100;
        else
            cost += c.manaCostPercentage * maxPower / 100;
    }
    return cost > 0 ? cost : 0;
}

/**
 * The chance a magic spell misses: 4%, and the level difference (1% a level up to
 * two above; then 11% a level against creatures, 7% against players), 1% at least.
 */
float spellMissChance(uint casterLevel, uint victimLevel, bool victimIsPlayer) pure nothrow @nogc @safe
{
    float chance = 4;
    const difference = cast(int) victimLevel - cast(int) casterLevel;
    if (difference > 2)
        chance += 2 + (difference - 2) * (victimIsPlayer ? 7 : 11);
    else
        chance += difference;
    if (chance < 1)
        chance = 1;
    return chance > 100 ? 100 : chance;
}

unittest
{
    assert(spellMissChance(10, 10, false) == 4 && spellMissChance(10, 12, false) == 6);
    assert(spellMissChance(10, 13, false) == 17 && spellMissChance(10, 13, true) == 13);
    assert(spellMissChance(20, 10, false) == 1, "never below 1%");

    SpellInfo fireball;
    fireball.basePoints[0] = 13;
    fireball.baseDice[0] = 1;
    fireball.casting.dieSides[0] = 9;
    assert(effectValue(fireball, 0, 1, 0) == 14 && effectValue(fireball, 0, 1, 0.9999f) == 22, "14 .. 22");
    fireball.casting.dieSides[0] = 1;
    assert(effectValue(fireball, 0, 1, 0.5f) == 14);
    fireball.casting.realPointsPerLevel[0] = 0.5f;
    fireball.casting.baseLevel = 1;
    fireball.spellLevel = 1;
    fireball.casting.maxLevel = 5;
    assert(effectValue(fireball, 0, 3, 0) == 15 && effectValue(fireball, 0, 20, 0) == 16, "+0.5 a level up to 5");
}

// ---------------------------------------------------------------------------
// Packets
// ---------------------------------------------------------------------------

/// `SMSG_CAST_RESULT`: 0 for success, or 2 and the reason.
ubyte[] castResultPacket(uint spell, SpellCastResult result, const SpellInfo* info = null)
{
    ByteWriter w;
    w.put(spell);
    if (result == SpellCastResult.ok)
        w.put(ubyte(0));
    else
    {
        w.put(ubyte(2));
        w.put(cast(ubyte) result);
        if (info !is null && result == SpellCastResult.equippedItemClass)
        {
            w.put(cast(uint) info.equippedItemClass);
            w.put(cast(uint) info.equippedItemSubClassMask);
        }
        else if (info !is null && result == SpellCastResult.reagents)
        {
            foreach (i, reagent; info.reagents)
                if (reagent > 0)
                {
                    w.put(cast(uint) reagent);
                    break;
                }
        }
        else if (info !is null && result == SpellCastResult.requiresSpellFocus)
            w.put(info.casting.requiresSpellFocus);
        else if (info !is null && result == SpellCastResult.totems)
            foreach (totem; info.casting.totems)
                if (totem)
                    w.put(totem);
    }
    return w.data.dup;
}

/// `SMSG_SPELL_START`
ubyte[] spellStartPacket(ulong caster, uint spell, uint castTimeMs, const ref SpellTargets targets)
{
    ByteWriter w;
    w.putPackedGuid(caster);
    w.putPackedGuid(caster);
    w.put(spell);
    w.put(castFlagUnknown2);
    w.put(castTimeMs);
    targets.write(w);
    return w.data.dup;
}

/// A target hit or missed, for `SMSG_SPELL_GO`.
struct TargetResult
{
    ulong guid;
    SpellMissInfo miss;
}

/// `SMSG_SPELL_GO`: who was hit, who missed (and how), and the targets.
ubyte[] spellGoPacket(ulong caster, uint spell, const(TargetResult)[] results, const ref SpellTargets targets)
{
    ByteWriter w;
    w.putPackedGuid(caster);
    w.putPackedGuid(caster);
    w.put(spell);
    w.put(castFlagUnknown9);
    // The client has one byte for each list's length. Only the listed targets are capped.
    foreach (listMisses; [false, true])
    {
        ubyte count;
        const offset = w.data.length;
        w.put(count);
        foreach (r; results)
            if ((r.miss != SpellMissInfo.none) == listMisses)
            {
                if (count == ubyte.max)
                    break;
                w.put(r.guid);
                if (listMisses)
                    w.put(cast(ubyte) r.miss);
                ++count;
            }
        w.patch(offset, count);
    }
    targets.write(w);
    return w.data.dup;
}

unittest
{
    TargetResult[] crowd;
    foreach (ulong guid; 10 .. 266)
    {
        crowd ~= TargetResult(guid, SpellMissInfo.none);
        crowd ~= TargetResult(guid + 1000, SpellMissInfo.resist);
    }
    const targets = SpellTargets.init;
    auto packet = ByteReader(spellGoPacket(1, 2, crowd, targets));
    assert(packet.readPackedGuid() == 1 && packet.readPackedGuid() == 1);
    assert(packet.read!uint == 2 && packet.read!ushort == castFlagUnknown9);
    assert(packet.read!ubyte == ubyte.max);
    foreach (ulong guid; 10 .. 265)
        assert(packet.read!ulong == guid);
    assert(packet.read!ubyte == ubyte.max);
    foreach (ulong guid; 1010 .. 1265)
        assert(packet.read!ulong == guid && packet.read!ubyte == SpellMissInfo.resist);
    assert(SpellTargets.read(packet).mask == TargetFlags.self && packet.empty);
}

/// `SMSG_SPELL_FAILURE` (to everyone around) for an interrupted cast.
ubyte[] spellFailurePacket(ulong caster, uint spell, SpellCastResult result)
{
    ByteWriter w;
    w.putPackedGuid(caster);
    w.put(spell);
    w.put(cast(ubyte) result);
    return w.data.dup;
}

/// `SMSG_SPELLNONMELEEDAMAGELOG`
ubyte[] nonMeleeDamageLog(ulong target, ulong attacker, uint spell, uint damage, uint school, uint absorb, int resist,
    bool periodic, uint blocked, bool crit)
{
    enum uint hitTypeCrit = 0x02;
    ByteWriter w;
    w.putPackedGuid(target);
    w.putPackedGuid(attacker);
    w.put(spell);
    w.put(damage);
    w.put(cast(ubyte) school);
    w.put(absorb);
    w.put(resist);
    w.put(ubyte(periodic));
    w.put(ubyte(0));
    w.put(blocked);
    w.put(crit ? hitTypeCrit : 0u);
    w.put(ubyte(0));
    return w.data.dup;
}

/// `SMSG_SPELLHEALLOG`
ubyte[] healLog(ulong target, ulong caster, uint spell, uint amount, bool crit)
{
    ByteWriter w;
    w.putPackedGuid(target);
    w.putPackedGuid(caster);
    w.put(spell);
    w.put(amount);
    w.put(ubyte(crit));
    return w.data.dup;
}

/// `SMSG_SPELLENERGIZELOG`
ubyte[] energizeLog(ulong target, ulong caster, uint spell, uint power, uint amount)
{
    ByteWriter w;
    w.putPackedGuid(target);
    w.putPackedGuid(caster);
    w.put(spell);
    w.put(power);
    w.put(amount);
    return w.data.dup;
}

/**
 * `SMSG_SPELLLOGEXECUTE` of one effect on one target (CMaNGOS's `SpellLog::AddLog` and `SendToSet`): the
 * caster, the spell, one effect, one target, and what the effect writes of it (`targetData`: the target's
 * packed guid, then for some effects more: a power drain's amount, power and multiplier, extra attacks'
 * count, an interrupted spell). It gives the client's combat log its line ("X drains 30 Mana from Y",
 * "You gain 1 extra attack", "You interrupt ..."). The targets' guids are packed, as the 1.12 client reads
 * them (CMaNGOS writes them whole).
 */
ubyte[] executeLog(ulong caster, uint spell, uint effect, const(ubyte)[] targetData)
{
    ByteWriter w;
    w.putPackedGuid(caster);
    w.put(spell);
    w.put(1u); // effects
    w.put(effect);
    w.put(1u); // targets of it
    w.putBytes(targetData);
    return w.data.dup;
}

/// The target part of an `executeLog`: the target, then `more` (each written as it is).
ubyte[] executeTarget(T...)(ulong target, T more)
{
    ByteWriter w;
    w.put(target); // whole, as CMaNGOS and vmangos write it (the caster packed)
    foreach (m; more)
        w.put(m);
    return w.data.dup;
}

///
unittest
{
    import dmangos.bytes : ByteReader;

    const body_ = executeLog(0x10, 5138, 8, executeTarget(0xF130000000000042UL, 30u, 0u, 1.5f));
    auto r = ByteReader(body_);
    assert(r.readPackedGuid == 0x10 && r.read!uint == 5138 && r.read!uint == 1 && r.read!uint == 8 && r.read!uint == 1);
    assert(r.read!ulong == 0xF130000000000042UL && r.read!uint == 30 && r.read!uint == 0 && r.read!float == 1.5f);
    assert(r.empty);
}

/// `SMSG_SPELLLOGMISS` for one target.
ubyte[] spellMissLog(uint spell, ulong caster, ulong target, SpellMissInfo miss)
{
    ByteWriter w;
    w.put(spell);
    w.put(caster);
    w.put(ubyte(0));
    w.put(1u);
    w.put(target);
    w.put(cast(ubyte) miss);
    return w.data.dup;
}

/**
 * Whether a spell is binary: resisted whole or not at all, its resistance adding to its chance to miss instead of
 * taking a share of its damage. Blizzard (docs/FORMULAS.md, "Spell resistance"): "Against most spells, this
 * resistance percentage is the straight % chance to completely resist the spell. Against direct-damage spells
 * (spells that deliver their full damage upon impact, such as Fireball, Mind Blast, and Earth Shock), this
 * resistance is the percentage of damage you will resist on average." So a spell is resisted in part when it deals
 * damage on impact and lays no debuff beside it: Fireball's burn is damage, Earth Shock's interrupt no aura. A
 * spell without direct damage (an aura, a damage over time alone, a stun) is binary, and so is one whose direct
 * damage carries a debuff on the same targets (Frostbolt's slow, Frost Nova's root: "spells which deal a debuff",
 * documented 1.x research). Dummy (3) and trigger spell (64) effects do not count.
 */
bool isBinarySpell(const ref SpellInfo spell) pure nothrow @nogc @safe
{
    bool any;
    ubyte direct, debuffs;
    foreach (i; 0 .. 3)
    {
        const effect = spell.effect[i];
        if (effect == 0 || effect == SpellEffect.dummy || effect == SpellEffect.triggerSpell)
            continue;
        any = true;
        const auraName = spell.casting.applyAuraName[i];
        if (auraName)
        {
            if (auraName != AuraType.periodicDamage && auraName != AuraType.periodicLeech
                    && auraName != AuraType.periodicManaLeech && auraName != AuraType.periodicDamagePercent)
                debuffs |= 1 << i;
        }
        else if (effect == SpellEffect.schoolDamage || effect == SpellEffect.environmentalDamage
                || effect == SpellEffect.healthLeech || effect == SpellEffect.weaponDamageNoschool
                || effect == SpellEffect.weaponPercentDamage || effect == SpellEffect.weaponDamage
                || effect == SpellEffect.normalizedWeaponDmg)
            direct |= 1 << i;
    }
    if (!direct)
        return any;
    foreach (i; 0 .. 3)
        if (direct & (1 << i))
            foreach (j; 0 .. 3)
                if ((debuffs & (1 << j)) && spell.implicitTargetA[i] == spell.implicitTargetA[j]
                    && spell.casting.implicitTargetB[i] == spell.casting.implicitTargetB[j])
                    return true;
    return false;
}

unittest
{
    SpellInfo bolt;
    bolt.effect[0] = SpellEffect.schoolDamage; // school damage
    assert(!isBinarySpell(bolt), "Fireball's direct part");
    bolt.effect[1] = SpellEffect.applyAura; // a slow on the same target
    bolt.casting.applyAuraName[1] = AuraType.modDecreaseSpeed;
    assert(isBinarySpell(bolt), "Frostbolt: a debuff on its damage");
    SpellInfo shock;
    shock.effect[0] = SpellEffect.schoolDamage;
    shock.effect[1] = SpellEffect.interruptCast;
    assert(!isBinarySpell(shock), "Earth Shock: Blizzard's own example of a spell resisted in part");
    SpellInfo burn = shock;
    burn.effect[1] = SpellEffect.applyAura;
    burn.casting.applyAuraName[1] = AuraType.periodicDamage;
    assert(!isBinarySpell(burn), "Fireball with its burn: Blizzard's example too");
    SpellInfo dot;
    dot.effect[0] = SpellEffect.applyAura;
    dot.casting.applyAuraName[0] = AuraType.periodicDamage;
    assert(isBinarySpell(dot), "a pure damage over time");
}

/**
 * The chance (percent) a magic spell misses `victim`, or is resisted whole by its `resistance` to the
 * spell's school, for every caster kind and victim kind alike: `spellMissChance` less the caster's
 * `hitBonus`, and for a magic spell of a school other than physical and holy, `fullResistChance` (the
 * level bonus counting for a creature victim of a spell that is not binary).
 */
float magicMissChance(const Fighter caster, const Fighter victim, const ref SpellInfo spell, int resistance,
    float hitBonus) pure nothrow @nogc @safe
{
    import dmangos.world.combat : fullResistChance;

    import dmangos.world.combat : mechanics;

    float chance = spellMissChance(caster.level, victim.level, victim.player) - hitBonus - victim.attackerHit[2];
    // Resisted more often for its mechanic (a fear, a stun): the victim's `MOD_MECHANIC_RESISTANCE`.
    if (spell.casting.mechanic && spell.casting.mechanic < mechanics)
        chance += victim.mechanicResist[spell.casting.mechanic];
    if (spell.casting.dmgClass == DamageClass.magic && spell.casting.school > 1)
    {
        const binary = isBinarySpell(spell);
        chance += fullResistChance(resistance, caster.level, victim.level, binary, !victim.player && !binary);
    }
    return chance;
}

/// `SPELL_ATTR_HEARTBEAT_RESIST`: a hostile aura of the spell may break early, at each heartbeat.
enum uint spellAttrHeartbeatResist = 0x40000000;

/// `SPELL_ATTR_EX3_COMPLETELY_BLOCKED`: an ability a shield blocks whole (a miss), not in part.
enum uint spellAttrEx3CompletelyBlocked = 0x00000008;

/**
 * The chance (percent) a hostile aura of `spell` breaks at each heartbeat (CMaNGOS's `MeleeSpellHitResult` and
 * `MagicSpellHitResult` keep it): its chance to miss or be resisted at the hit, for a spell with
 * `SPELL_ATTR_HEARTBEAT_RESIST`; none for others, nor for a spell without a damage class (never avoided).
 */
float heartbeatResistChance(const Fighter caster, const Fighter victim, const ref SpellInfo spell, int resistance,
    float hitBonus) pure nothrow @nogc @safe
{
    import dmangos.world.combat : AttackType, missChance;

    if (!(spell.attributes & spellAttrHeartbeatResist))
        return 0;
    float chance = 0;
    switch (spell.casting.dmgClass)
    {
    case DamageClass.melee, DamageClass.ranged:
        chance = missChance(caster, victim, spell.casting.dmgClass == DamageClass.ranged ? AttackType.ranged
            : AttackType.mainHand);
        break;
    case DamageClass.magic:
        chance = magicMissChance(caster, victim, spell, resistance, hitBonus);
        break;
    default:
        break;
    }
    return chance > 0 ? chance : 0;
}

/**
 * How `spell` fares against one target it may attack, for every caster kind and victim kind alike: an
 * evading creature evades; a spell that always hits, or has no damage class, hits; a melee or ranged one
 * may be missed, dodged or parried as a blow is; a magic one missed or resisted whole (`magicMissChance`).
 * One number is drawn from `rng`, and only when there is something to roll.
 */
/// Whether the spell's hit is rolled at its caster's weapon skill: a weapon it needs, a melee ability, a shot from
/// the ranged slot (CMaNGOS's `IsSpellUseWeaponSkill`).
bool usesWeaponSkill(const ref SpellInfo spell) pure nothrow @nogc @safe
{
    enum int itemClassWeapon = 2;
    enum uint usesRangedSlot = 0x2; // SPELL_ATTR_USES_RANGED_SLOT
    return spell.equippedItemClass == itemClassWeapon || spell.casting.dmgClass == DamageClass.melee
        || (spell.casting.dmgClass == DamageClass.ranged && (spell.attributes & usesRangedSlot));
}

SpellMissInfo rollSpellHit(Rng)(const Fighter caster, const Fighter victim, const ref SpellInfo spell,
    int resistance, float hitBonus, ref Rng rng)
{
    import std.random : uniform01;
    import dmangos.world.combat : AttackType, blockChance, canBlock, canDodge, canParry, dodgeChance, missChance,
        parryChance;

    enum uint noActiveDefense = 0x00200000; // SPELL_ATTR_NO_ACTIVE_DEFENSE: never dodged or parried (Overpower, Ambush)

    if (victim.evading)
        return SpellMissInfo.evade;
    // Immune to it (its school, dispel type or mechanic): "Immune", unless it ignores immunities (Charge).
    enum uint noImmunities = 0x20000000; // SPELL_ATTR_NO_IMMUNITIES
    if (!(spell.attributes & noImmunities)
            && victim.immune.toSpell(spell.casting.school, spell.casting.dispel, spell.casting.mechanic))
        return SpellMissInfo.immune;
    if ((spell.casting.attributesEx3 & spellAttrEx3AlwaysHit) || spell.casting.dmgClass == DamageClass.none)
        return SpellMissInfo.none;
    const roll = uniform01(rng) * 100;
    if (spell.casting.dmgClass == DamageClass.melee || spell.casting.dmgClass == DamageClass.ranged)
    {
        import dmangos.world.combat : Fighter, levelFor;

        const type = spell.casting.dmgClass == DamageClass.ranged ? AttackType.ranged : AttackType.mainHand;
        // An ability that is no weapon's (Blind: ranged, but not from the ranged slot) is rolled at the most skill
        // the caster's level allows, not at a weapon's it may not hold (CMaNGOS's `IsSpellUseWeaponSkill`).
        Fighter attacker = caster;
        if (!usesWeaponSkill(spell))
            attacker.weaponSkill[type] = attacker.weaponSkillMax[type] = levelFor(caster, victim) * 5;
        float edge = missChance(attacker, victim, type);
        if (roll < edge)
            return SpellMissInfo.miss;
        if (spell.attributes & noActiveDefense)
            return SpellMissInfo.none;
        // As a swing: no dodge or parry where a swing has none (a player from behind, parry only from the front).
        if (type != AttackType.ranged && canDodge(victim, attacker))
        {
            edge += dodgeChance(victim, attacker, type);
            if (roll < edge)
                return SpellMissInfo.dodge;
        }
        if (type != AttackType.ranged && canParry(victim, attacker))
        {
            edge += parryChance(victim, attacker, type);
            if (roll < edge)
                return SpellMissInfo.parry;
        }
        // An ability a shield blocks whole: blocked on the same roll (`CanBlockAbility` with `miss`).
        if ((spell.casting.attributesEx3 & spellAttrEx3CompletelyBlocked) && canBlock(victim, attacker, 0))
        {
            edge += blockChance(victim, attacker, type);
            if (roll < edge)
                return SpellMissInfo.block;
        }
        return SpellMissInfo.none;
    }
    return roll < magicMissChance(caster, victim, spell, resistance, hitBonus) ? SpellMissInfo.resist
        : SpellMissInfo.none;
}

unittest
{
    import dmangos.world.combat : Fighter;

    // A generator that gives the numbers it is told to, as uniform01 reads them.
    static struct Fixed
    {
        enum bool isUniformRandom = true;
        enum ulong min = 0, max = 1_000_000;
        ulong value;
        @property ulong front() const { return value; }
        void popFront() {}
        enum bool empty = false;
    }

    static float hits(float percent) { return percent / 100 * Fixed.max; }
    Fighter mage, wolf;
    mage.level = wolf.level = 10;
    mage.player = true;
    SpellInfo bolt;
    bolt.casting.dmgClass = DamageClass.magic;
    bolt.casting.school = 4; // frost
    auto low = Fixed(cast(ulong) hits(3.9f)), high = Fixed(cast(ulong) hits(4.1f));
    assert(rollSpellHit(mage, wolf, bolt, 0, 0, low) == SpellMissInfo.resist, "4% base miss at an even level");
    assert(rollSpellHit(mage, wolf, bolt, 0, 0, high) == SpellMissInfo.none);
    assert(rollSpellHit(mage, wolf, bolt, 0, 2, low) == SpellMissInfo.none, "hit bonus off the miss chance");
    wolf.evading = true;
    assert(rollSpellHit(mage, wolf, bolt, 0, 0, low) == SpellMissInfo.evade);
    wolf.evading = false;
    bolt.casting.dmgClass = DamageClass.none;
    assert(rollSpellHit(mage, wolf, bolt, 0, 0, low) == SpellMissInfo.none, "no damage class: no roll");

    // A melee ability: dodged by a roll past the miss chance, unless it cannot be (Overpower, Ambush).
    SpellInfo strike;
    strike.casting.dmgClass = DamageClass.melee;
    wolf.dodge = 5;
    wolf.canDodge = true;
    wolf.position.orientation = 3.14159f; // facing the warrior (at its west)
    mage.position.x = -1;
    import dmangos.world.combat : AttackType, missChance;

    auto dodged = Fixed(cast(ulong) hits(missChance(mage, wolf, AttackType.mainHand) + 2.5f)); // past the miss
    assert(rollSpellHit(mage, wolf, strike, 0, 0, dodged) == SpellMissInfo.dodge);
    strike.attributes = 0x00200000; // SPELL_ATTR_NO_ACTIVE_DEFENSE
    assert(rollSpellHit(mage, wolf, strike, 0, 0, dodged) == SpellMissInfo.none, "it cannot be dodged");

    // A victim immune to the spell's mechanic (a boss and Hammer of Justice's stun): "Immune", whatever the roll.
    SpellInfo hammer;
    hammer.casting.dmgClass = DamageClass.magic;
    hammer.casting.mechanic = 12; // MECHANIC_STUN
    wolf.immune.mechanics = 1u << (12 - 1);
    assert(rollSpellHit(mage, wolf, hammer, 0, 0, high) == SpellMissInfo.immune);
    hammer.attributes = 0x20000000; // SPELL_ATTR_NO_IMMUNITIES
    assert(rollSpellHit(mage, wolf, hammer, 0, 0, high) == SpellMissInfo.none);

    // An ability a shield blocks whole (`SPELL_ATTR_EX3_COMPLETELY_BLOCKED`): blocked past the dodge; others not.
    import dmangos.world.combat : blockChance, dodgeChance;

    SpellInfo bash;
    bash.casting.dmgClass = DamageClass.melee;
    wolf.block = 10;
    wolf.canBlock = true;
    const pastDodge = missChance(mage, wolf, AttackType.mainHand) + dodgeChance(wolf, mage, AttackType.mainHand);
    auto blocked = Fixed(cast(ulong) hits(pastDodge + blockChance(wolf, mage, AttackType.mainHand) / 2));
    assert(rollSpellHit(mage, wolf, bash, 0, 0, blocked) == SpellMissInfo.none, "blocked in part only, later");
    bash.casting.attributesEx3 = spellAttrEx3CompletelyBlocked;
    assert(rollSpellHit(mage, wolf, bash, 0, 0, blocked) == SpellMissInfo.block);
    bash.casting.dmgClass = DamageClass.magic; // not for spells
    assert(rollSpellHit(mage, wolf, bash, 0, 0, blocked) != SpellMissInfo.block);

    // Heartbeat resistance: the chance to miss or be resisted, for spells marked so.
    SpellInfo root;
    root.casting.dmgClass = DamageClass.magic;
    root.casting.school = 3; // nature
    assert(heartbeatResistChance(mage, wolf, root, 0, 0) == 0, "not marked");
    root.attributes = spellAttrHeartbeatResist;
    assert(heartbeatResistChance(mage, wolf, root, 0, 0) == magicMissChance(mage, wolf, root, 0, 0));
    assert(heartbeatResistChance(mage, wolf, root, 0, 0) > 0);
}

// A victim's resistance to a mechanic (a dwarf's or a talent's against fear) adds to the magic miss chance.
unittest
{
    import std.math : isClose;
    import dmangos.world.combat : Fighter;

    Fighter caster, victim;
    caster.level = victim.level = 60;
    caster.player = victim.player = true;
    SpellInfo fear;
    fear.casting.dmgClass = DamageClass.magic;
    fear.casting.school = 5; // shadow
    fear.casting.mechanic = 5; // MECHANIC_FEAR
    const plain = magicMissChance(caster, victim, fear, 0, 0);
    victim.mechanicResist[5] = 15;
    assert(isClose(magicMissChance(caster, victim, fear, 0, 0), plain + 15));
    fear.casting.mechanic = 12; // a stun: not resisted for the fear's sake
    assert(isClose(magicMissChance(caster, victim, fear, 0, 0), plain));
}
