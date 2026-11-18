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

/// `SpellCastResult` (1.12's values); `ok` is never sent as a failure.
enum SpellCastResult : ubyte
{
    affectingCombat = 0x00,
    alreadyAtFullHealth = 0x01,
    alreadyAtFullPower = 0x02,
    alreadyHaveCharm = 0x04,
    alreadyHaveSummon = 0x05,
    alreadyOpen = 0x06,
    badImplicitTargets = 0x09,
    badTargets = 0x0A,
    casterAuraState = 0x12,
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
    notWhileGhost = 0x42,
    noPet = 0x4C,
    lowLevel = 0x2B,
    trainingPoints = 0x79,
    noPower = 0x4D,
    outOfRange = 0x59,
    reagents = 0x5C,
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
        enum uint powerMana = 0, powerHealth = uint.max - 1;
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
            foreach (i, reagent; info.reagents)
                if (reagent > 0)
                {
                    w.put(cast(uint) reagent);
                    break;
                }
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
    ubyte hits, misses;
    foreach (r; results)
        if (r.miss == SpellMissInfo.none)
            ++hits;
        else
            ++misses;
    w.put(hits);
    foreach (r; results)
        if (r.miss == SpellMissInfo.none)
            w.put(r.guid);
    w.put(misses);
    foreach (r; results)
        if (r.miss != SpellMissInfo.none)
        {
            w.put(r.guid);
            w.put(cast(ubyte) r.miss);
        }
    targets.write(w);
    return w.data.dup;
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
 * Whether a spell is binary (as before WotLK): a spell resisted whole or not at all, whose resistance adds to its
 * chance to miss instead of taking a share of its damage: all its effects are not damage, or all are
 * auras, or all its damage is over time, or a non-damage effect hits the targets of a direct damage
 * one (Frostbolt's slow). Dummy (3) and trigger spell (64) effects do not count.
 */
bool isBinarySpell(const ref SpellInfo spell) pure nothrow @nogc @safe
{
    ubyte valid, nonDamage, aura;
    foreach (i; 0 .. 3)
    {
        const effect = spell.effect[i];
        if (effect == 0 || effect == SpellEffect.dummy || effect == SpellEffect.triggerSpell)
            continue;
        const ubyte bit = cast(ubyte)(1 << i);
        valid |= bit;
        const auraName = spell.casting.applyAuraName[i];
        bool damage;
        if (auraName)
        {
            aura |= bit;
            damage = auraName == AuraType.periodicDamage || auraName == AuraType.periodicLeech || auraName == AuraType.periodicManaLeech
                || auraName == AuraType.periodicDamagePercent;
        }
        else
            damage = effect == SpellEffect.schoolDamage || effect == SpellEffect.environmentalDamage || effect == SpellEffect.healthLeech
                || effect == SpellEffect.weaponDamageNoschool || effect == SpellEffect.weaponPercentDamage || effect == SpellEffect.weaponDamage
                || effect == SpellEffect.normalizedWeaponDmg;
        if (!damage)
            nonDamage |= bit;
    }
    if (!valid)
        return false;
    if (nonDamage == valid || aura == valid)
        return true;
    const ubyte damageMask = valid & ~nonDamage, dots = damageMask & aura;
    if (damageMask == dots)
        return true;
    const ubyte direct = damageMask & ~dots;
    foreach (i; 0 .. 3)
        if (direct & (1 << i))
            foreach (j; 0 .. 3)
                if ((nonDamage & (1 << j)) && spell.implicitTargetA[i] == spell.implicitTargetA[j]
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
    assert(isBinarySpell(bolt), "Frostbolt");
    SpellInfo dot;
    dot.effect[0] = SpellEffect.applyAura;
    dot.casting.applyAuraName[0] = AuraType.periodicDamage;
    assert(isBinarySpell(dot), "a pure damage over time");
}
