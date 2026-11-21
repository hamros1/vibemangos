/**
 * What a spell does to a unit's health and power, whoever casts it and whoever it reaches (docs/SPELLS.md, step 2):
 * spell damage, heals, power given, burnt or drained, health leeched.
 *
 * Each is written once over a `Caster` (a player, a creature, a pet, a totem) and a `UnitRef`: the caster's numbers
 * (its spell power, crit, modifiers: `Caster`'s hooks) and the victim's (its auras, armor, resistances, shields)
 * meet here, the combat log is told, and the blow goes the one way damage goes (`dealDamage`).
 */
module dmangos.world.spelldamage;

import dmangos.cluster.protocol : AreaDamage, PartyHeal;
import dmangos.world.caster : Caster;
import dmangos.world.combat : Fighter;
import dmangos.world.movement : Position;
import dmangos.world.spellids;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitKind, UnitRef;

enum float spellJumpRadius = 10;

/// The spell's multiplier applied once per jump, before the recipient's modifiers.
struct SpellBounce
{
    float multiplier = 1;
    uint index;

    uint scale(uint amount) const
    {
        if (!index || !(multiplier > 0))
            return amount;
        float scaled = amount;
        foreach (_; 0 .. index)
            scaled *= multiplier;
        return cast(uint) scaled;
    }
}

/// How a spell's damage comes.
struct SpellDamage
{
    bool withBonus = true; /// the caster's spell power by the spell's coefficient
    int modOp = -1;        /// a `SpellModOp` its modifiers apply as (`SPELLMOD_DAMAGE`); -1: none
    bool periodic;         /// a tick (a persistent area's, a drain's): never crits, and sets off what a tick does
    bool weaponRolled;     /// a creature's weapon ability: its melee roll made it already (armor, crit)
    SpellBounce bounce;
}

/// `SPELL_ATTR_EX2_CANT_CRIT`.
enum uint spellAttrEx2CantCrit = 0x20000000;

/// The coefficient (`bonusCoefficient`) of `spell`'s direct damage effect (`heal`: its heal), its first.
float directCoefficient(ref Caster caster, const(SpellInfo)* spell, bool heal)
{
    import dmangos.world.spellcast : bonusCoefficient;

    foreach (i; 0 .. 3)
        if (heal ? spell.effect[i] == SpellEffect.heal
            : (spell.effect[i] == SpellEffect.schoolDamage || spell.effect[i] == SpellEffect.healthLeech))
            return bonusCoefficient(*spell, i, caster.context.client, caster.level);
    return 0;
}

/**
 * The damage bonus of a direct spell: the caster's spell power for the spell's school times its damage effect's
 * coefficient (`bonusCoefficient`). Physical spells get none.
 */
uint spellDamageBonus(ref Caster caster, const(SpellInfo)* spell, uint school)
{
    if (school == 0 || school >= 7)
        return 0;
    const done = caster.spellPower(1 << school);
    return done <= 0 ? 0 : cast(uint)(done * directCoefficient(caster, spell, false));
}

/// The healing bonus: the caster's healing power times its heal's coefficient.
uint healingBonus(ref Caster caster, const(SpellInfo)* spell)
{
    const done = caster.healingPower();
    return done <= 0 ? 0 : cast(uint)(done * directCoefficient(caster, spell, true));
}

/// The crit chance more of a spell of `school` at the bearer of `auras` (`MOD_ATTACKER_SPELL_CRIT_CHANCE`, of the
/// schools of its misc value: Winter's Chill's frost only).
float spellCritTaken(A)(const ref A auras, uint school)
{
    import dmangos.world.auras : AuraType;

    return school < 7 ? auras.totalByMiscMask(AuraType.modAttackerSpellCritChance, 1 << school) : 0;
}

/// The victim's spell damage multiplier for a weapon ability that has already rolled its attack.
package uint weaponRolledAmount(uint damage, uint school, const ref Fighter target)
{
    return school < 7 ? cast(uint)(damage * target.damageTaken[school]) : damage;
}

/**
 * `damage` of `school` (an index) from `caster`'s `spell` to `victim`, as `how` says it comes: the caster's spell
 * power and modifiers, the auras of both, a crit, armor (physical) or a partial resist (not holy, not a binary spell),
 * the victim's shields; the combat log (`SMSG_SPELLNONMELEEDAMAGELOG`), the blow (`dealDamage`: threat, tapping,
 * death), and the procs. Returns the damage dealt.
 */
uint spellDamage(ref Caster caster, const(SpellInfo)* spell, UnitRef victim, uint damage, uint school,
    SpellDamage how = SpellDamage.init)
{
    import std.random : uniform, uniform01;
    import dmangos.world.combat : armorAgainst, armorReducedDamage, partiallyResisted;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : isBinarySpell, nonMeleeDamageLog;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.unit : Blow, dealDamage;

    if (!victim || !caster)
        return 0;
    auto map = caster.map;
    if (how.withBonus)
        damage += spellDamageBonus(caster, spell, school);
    if (how.modOp >= 0)
        damage = caster.spellMod(cast(SpellModOp) how.modOp, spell, damage);
    damage = how.bounce.scale(damage);
    const target = victim.fighter;
    bool crit;
    uint resisted;
    if (how.weaponRolled)
        damage = weaponRolledAmount(damage, school, target);
    else
    {
        damage = caster.damageFactors(damage, school, target);
        const victimAuras = victim.auraSet;
        const victimCrit = victimAuras is null || Caster.weaponCrit(spell) ? 0 : spellCritTaken(*victimAuras, school); // Winter's Chill
        crit = !how.periodic && !(spell.attributesEx2 & spellAttrEx2CantCrit)
            && uniform01(map.random) * 100 < caster.critChance(spell, victim) + victimCrit; // (a weapon's has the victim's in it)
        if (crit)
            damage = caster.critDamage(spell, damage);
        if (school == 0)
            damage = cast(uint) armorReducedDamage(caster.level, armorAgainst(caster.fighter, target), damage);
        else if (school != 1 && !isBinarySpell(*spell)) // holy: no resistance; a binary spell: all or nothing
        {
            const r = partiallyResisted(damage, caster.targetResistance(victim.resistance(school), school), caster.level,
                target, false, uniform!"[]"(1u, 10000u, map.random));
            damage = r.damage;
            resisted = r.resisted;
        }
    }
    const absorbed = victim.absorb(school, damage); // a player's shields
    caster.sendAround(Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(target: victim.combatGuid,
        attacker: caster.guid, spell.id, damage, school, absorbed, resisted, false, 0, crit));
    if (victim.alive)
    {
        caster.enteredCombat(damage);
        auto blow = how.periodic ? Blow.periodic(school) : Blow.spell(school, crit);
        blow.threat = caster.spellMod(SpellModOp.threat, spell, 1.0f); // (`SPELLMOD_THREAT`: Shadow Affinity)
        dealDamage(caster.unit, victim, damage, blow);
    }
    caster.damageDealt(spell, victim, crit, damage, how.periodic);
    return damage;
}

private bool isDirectMagicDamageEffect(const ref SpellInfo spell, size_t i)
{
    return i < spell.effect.length && spell.effect[i] == SpellEffect.schoolDamage
        && spell.casting.school > 0 && spell.casting.school < 7
        && (spell.casting.dmgClass == DamageClass.magic || spell.casting.dmgClass == DamageClass.none);
}

private bool instantaneous(const ref SpellInfo spell)
{
    return !(spell.attributesEx & (0x04 | 0x40)) && spell.casting.speed <= 0;
}

/// The instant magical area effects that can be split between nodes.
bool isHostileAreaEffect(const ref SpellInfo spell, size_t i)
{
    import std.algorithm.searching : count;

    if (!instantaneous(spell) || !isDirectMagicDamageEffect(spell, i) || spell.effect[].count(SpellEffect.schoolDamage) != 1
        || spell.casting.chainTarget[i] > 1)
        return false;
    const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
    return b == ImplicitTarget.enemiesAroundSource
        || (b == ImplicitTarget.none && a == ImplicitTarget.enemiesAroundSource);
}

/// A magical hit that selects successive hostile targets, as Chain Lightning does.
bool isHostileChainEffect(const ref SpellInfo spell, size_t i)
{
    import std.algorithm.searching : count;

    return instantaneous(spell) && isDirectMagicDamageEffect(spell, i)
        && spell.effect[].count(SpellEffect.none) == spell.effect.length - 1
        && spell.implicitTargetA[i] == ImplicitTarget.enemy && spell.casting.implicitTargetB[i] == ImplicitTarget.none
        && spell.casting.chainTarget[i] > 1;
}

/// The explicit target of a proc sent to the node that simulates it.
bool isTargetedProcEffect(const ref SpellInfo spell, size_t i)
{
    if (i >= spell.effect.length || spell.casting.implicitTargetB[i] != ImplicitTarget.none
        || spell.casting.chainTarget[i] > 1)
        return false;
    const target = spell.implicitTargetA[i];
    if (target != ImplicitTarget.enemy && target != ImplicitTarget.friend && target != ImplicitTarget.unit
        && target != ImplicitTarget.unitRaid)
        return false;
    const effect = spell.effect[i];
    if (effect == SpellEffect.applyAura)
    {
        const mask = remoteTargetAuraEffects(spell, i);
        return mask && (mask & ((1 << i) - 1)) == 0;
    }
    return effect == SpellEffect.heal || isDirectMagicDamageEffect(spell, i);
}

/// Aura effects sharing a single explicit target and therefore one duration, slot and application.
ubyte remoteTargetAuraEffects(const ref SpellInfo spell, size_t first)
{
    const target = spell.implicitTargetA[first];
    const secondary = spell.casting.implicitTargetB[first];
    ubyte mask;
    foreach (i, effect; spell.effect)
    {
        if (effect != SpellEffect.applyAura || spell.implicitTargetA[i] != target
            || spell.casting.implicitTargetB[i] != secondary || spell.casting.chainTarget[i] > 1)
            continue;
        const aura = spell.casting.applyAuraName[i];
        if (aura == AuraType.modPossess || aura == AuraType.modPossessPet || aura == AuraType.modCharm)
            return 0;
        mask |= cast(ubyte)(1 << i);
    }
    return mask;
}

/// The hostile effect of a regular remote creature cast.
bool isCreatureTargetEffect(const ref SpellInfo spell, size_t i)
{
    return isTargetedProcEffect(spell, i) && (spell.implicitTargetA[i] == ImplicitTarget.enemy
        || spell.effect[i] == SpellEffect.schoolDamage) && spell.effect[i] != SpellEffect.heal;
}

/// One named-creature hit, heal, or group of auras can be applied on its target's node.
package size_t namedCreatureEffect(const ref SpellInfo spell)
{
    if (spell.attributesEx & (0x04 | 0x40))
        return size_t.max; // channels need their own lifetime and interrupt routing
    size_t first = size_t.max;
    foreach (i, effect; spell.effect)
    {
        if (effect == SpellEffect.none)
            continue;
        if (spell.implicitTargetA[i] == ImplicitTarget.caster
            && spell.casting.implicitTargetB[i] == ImplicitTarget.none)
            continue;
        if (spell.implicitTargetA[i] != ImplicitTarget.unitScriptNearCaster)
            return size_t.max;
        if (spell.casting.implicitTargetB[i] != ImplicitTarget.none || spell.casting.chainTarget[i] > 1
            || spell.casting.school >= 7)
            return size_t.max;
        if (effect == SpellEffect.applyAura)
        {
            if (!remoteTargetAuraEffects(spell, i) || (first != size_t.max && spell.effect[first] != effect))
                return size_t.max;
        }
        else if (first != size_t.max || (effect != SpellEffect.heal && !isDirectMagicDamageEffect(spell, i)))
            return size_t.max;
        if (first == size_t.max)
            first = i;
    }
    return first;
}

/// Drains whose entire channel aura can run on one hostile target.
package bool isRemoteLeechChannel(const ref SpellInfo spell)
{
    if (!(spell.attributesEx & (0x04 | 0x40)) || spell.casting.speed > 0)
        return false;
    bool drains;
    foreach (i, effect; spell.effect)
    {
        if (effect == SpellEffect.none)
            continue;
        const aura = spell.casting.applyAuraName[i];
        if (effect != SpellEffect.applyAura || spell.implicitTargetA[i] != ImplicitTarget.enemy
            || spell.casting.implicitTargetB[i] != ImplicitTarget.none || spell.casting.chainTarget[i] > 1
            || (aura != AuraType.periodicLeech && aura != AuraType.periodicManaLeech))
            return false;
        drains = true;
    }
    return drains;
}

package ImplicitTarget creatureAreaShape(const ref SpellInfo spell, size_t i)
{
    import std.algorithm.comparison : among;

    if (i >= spell.effect.length || spell.casting.chainTarget[i] > 1)
        return ImplicitTarget.none;
    const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
    with (ImplicitTarget)
    {
        const shape = b.among(enemiesAroundSource, enemiesAroundDest) ? b
            : a.among(enemiesAroundSource, enemiesAroundDest, enemiesInCone) ? a : none;
        if (shape == none)
            return none;
        if (isDirectMagicDamageEffect(spell, i))
            return shape;
        if (spell.effect[i] == SpellEffect.applyAura)
        {
            const effects = remoteTargetAuraEffects(spell, i);
            if (effects && !(effects & ((1 << i) - 1)))
                return shape;
        }
        return none;
    }
}

/// Creature spell range includes both units' combat reaches at its outer edge.
bool creatureTargetInRange(const(SpellInfo)* spell, const imported!"dmangos.world.combat".Fighter caster,
    const imported!"dmangos.world.combat".Fighter target, const imported!"dmangos.world.clientdata".ClientData client)
{
    import dmangos.world.spellcast : range;

    const r = range(*spell, client);
    const a = caster.position, b = target.position;
    const distanceSquared = (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2;
    return distanceSquared >= r[0] ^^ 2 && distanceSquared <= (r[1] + caster.combatReach + target.combatReach) ^^ 2;
}

/// Resolve a remote hit using the recipient's current combat stats and auras.
void rollRemoteAreaDamage(ref AreaDamage hit, const(SpellInfo)* spell, UnitRef victim)
{
    import std.algorithm.comparison : max;
    import std.random : uniform, uniform01;
    import dmangos.world.character : Character;
    import dmangos.world.combat : armorAgainst, armorReducedDamage, Fighter, partiallyResisted;
    import dmangos.world.spellcast : isBinarySpell, rollSpellHit, SpellMissInfo;

    enum uint noImmunities = 0x20000000;
    const school = spell.casting.school;
    auto target = victim.fighter;
    const immune = target.immune;
    if (!hit.groundTick && !(spell.attributes & noImmunities)
        && (immune.toSpell(school, spell.casting.dispel, spell.casting.mechanic)
            || immune.toEffect(SpellEffect.schoolDamage, spell.casting.effectMechanic[hit.effect],
                spell.casting.applyAuraName[hit.effect])))
    {
        hit.miss = SpellMissInfo.immune;
        return;
    }
    const resistance = max(0, victim.resistance(school) + hit.resistanceModifier);
    auto rng = &victim.map.random();
    if (!hit.groundTick && !hit.alwaysHits)
    {
        const isPlayer = hit.caster <= uint.max;
        const caster = Fighter(guid: hit.caster, player: isPlayer, playerControlled: isPlayer, level: hit.casterLevel);
        hit.miss = rollSpellHit(caster, target, *spell, resistance, hit.hitBonus, *rng);
        if (hit.miss)
            return;
    }
    if (!hit.groundTick)
        victim.hostileSpellLanded();
    target = victim.fighter;
    uint damage = cast(uint) max(0, (hit.amount + target.damageTakenFlat[school]) * target.damageTaken[school]);
    const frozenBonus = Character.frozenForSpellCrit(victim) ? hit.frozenCritBonus : 0;
    hit.critical = !hit.groundTick && !(spell.attributesEx2 & spellAttrEx2CantCrit)
        && uniform01(*rng) * 100 < hit.critChance + frozenBonus + spellCritTaken(*victim.auraSet, school);
    if (hit.critical)
        damage += cast(uint) max(0, damage / 2 * hit.critBonusFactor + hit.critBonusFlat);
    if (hit.groundTick && school == 0)
    {
        const source = Fighter(armorIgnored: cast(uint) max(0, hit.resistanceModifier));
        damage = cast(uint) armorReducedDamage(hit.casterLevel, armorAgainst(source, target), damage);
    }
    else if (school > 1 && !isBinarySpell(*spell))
    {
        const reduced = partiallyResisted(damage, resistance, hit.casterLevel, target, false,
            uniform!"[]"(1u, 10000u, *rng));
        damage = reduced.damage;
        hit.resisted = reduced.resisted;
    }
    hit.absorbed = victim.absorb(school, damage);
    hit.damage = damage;
}

/// How a heal comes.
struct SpellHeal
{
    bool plain; /// no healing power, no crit, no class rules, procs nor threat: a leech's (CMaNGOS's `DealHeal`)
    SpellBounce bounce;
}

/// A direct heal that selects successive friendly targets, as Chain Heal does.
bool isChainHealEffect(const ref SpellInfo spell, size_t i)
{
    import std.algorithm.searching : count;

    enum uint channels = 0x04 | 0x40;
    return i < spell.effect.length && spell.effect[i] == SpellEffect.heal
        && spell.effect[].count(SpellEffect.none) == spell.effect.length - 1
        && spell.implicitTargetA[i] == ImplicitTarget.unitFriendChainHeal
        && spell.casting.implicitTargetB[i] == ImplicitTarget.none && spell.casting.chainTarget[i] > 1
        && spell.casting.speed == 0 && !(spell.attributesEx & channels);
}

/// A direct party heal is centered on the caster and selects their own party or raid subgroup.
bool isPartyHealEffect(const ref SpellInfo spell, size_t i)
{
    import std.algorithm.comparison : among;
    import dmangos.world.spellids : ImplicitTarget, SpellEffect;

    enum uint channels = 0x04 | 0x40;
    if (i >= spell.effect.length || spell.effect[i] != SpellEffect.heal || (spell.attributesEx & channels)
        || spell.casting.speed > 0 || spell.casting.chainTarget[i] > 1)
        return false;
    with (ImplicitTarget)
    {
        const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
        return b.among(partyAroundSource, partyInRange, party)
            || (b == none && a.among(partyAroundSource, partyInRange, party));
    }
}

bool withinPartyHealRadius(const ref PartyHeal heal, Position target)
{
    return heal.radius > 0
        && ((target.x - heal.x) ^^ 2 + (target.y - heal.y) ^^ 2 + (target.z - heal.z) ^^ 2 <= heal.radius ^^ 2);
}

/// Roll the caster's part of a heal, before the recipient's own modifiers and health cap.
uint rollHealing(ref Caster caster, const(SpellInfo)* spell, int value, out bool critical,
    SpellBounce bounce = SpellBounce.init)
{
    import std.random : uniform01;
    import dmangos.world.auras : AuraType;

    value += healingBonus(caster, spell);
    value = cast(int)(value * caster.auras.multiplier(AuraType.modHealingDonePercent));
    critical = !(spell.attributesEx2 & spellAttrEx2CantCrit) && uniform01(caster.map.random) * 100 < caster.spellCritChance(spell);
    const amount = critical ? value * 3 / 2 : value;
    return bounce.scale(cast(uint) amount);
}

/// Apply the recipient's healing modifiers and health cap. Returns the amount for the heal log.
uint applyHealAmount(const(SpellInfo)* spell, UnitRef target, uint amount, out uint restored)
{
    import std.algorithm.comparison : min;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    const taken = target.auraSet.healingTaken(amount, spell.casting.school);
    auto fields = target.fields;
    const health = fields.get!UNIT_FIELD_HEALTH, maxHealth = fields.get!UNIT_FIELD_MAXHEALTH;
    if (health < maxHealth)
    {
        restored = min(taken, maxHealth - health);
        fields.set!UNIT_FIELD_HEALTH(health + restored);
    }
    return taken;
}

/**
 * `value` of health back to `target` from `caster`'s `spell`: the caster's class rules (a player's: Swiftmend,
 * Blessing of Light), its healing power and `MOD_HEALING_DONE_PERCENT`, a crit half again, what heals the target
 * less (`healingTaken`: Mortal Strike), never past its maximum; the heal log, the procs, and its threat on those the
 * target fights. A dead target is not healed. Returns the health it got.
 */
uint spellHeal(ref Caster caster, const(SpellInfo)* spell, UnitRef target, int value, SpellHeal how = SpellHeal.init)
{
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : healLog;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (value <= 0 || !target || !caster)
        return 0;
    auto fields = target.fields;
    auto auras = target.auraSet;
    if (fields is null || auras is null || fields.get!UNIT_FIELD_HEALTH == 0)
        return 0;
    const self = target.combatGuid == caster.guid;
    auto p = caster.character;
    bool crit;
    uint rolled = cast(uint) value;
    if (!how.plain)
    {
        if (p !is null && target.kind == UnitKind.player && !self)
            p.pvpAssisted(target.session);
        if (p !is null)
            value = p.classHeal(spell, target, value); // Swiftmend, Blessing of Light, Healing Way
        rolled = rollHealing(caster, spell, value, crit, how.bounce);
    }
    uint healed;
    const amount = applyHealAmount(spell, target, rolled, healed);
    caster.sendAround(Opcode.SMSG_SPELLHEALLOG, healLog(target: target.combatGuid, caster: caster.guid, spell.id, amount,
        crit));
    flushUnit(caster, target);
    if (how.plain)
        return healed;
    import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;

    const hit = ProcHit(spell, crit ? ProcEx.criticalHit : ProcEx.normalHit, amount, 0, amount != 0);
    final switch (caster.kind)
    {
    case UnitKind.none:
        break;
    case UnitKind.player:
        p.procAuras(spellProcFlags(*spell, true, false), target, hit);
        break;
    case UnitKind.creature:
        caster.ai.procAuras(spellProcFlags(*spell, true, false), target, hit); // a pet's
        break;
    }
    // Its threat, less by the healer's talents (Healing Grace, Subtlety, Improved Tranquility), on those fighting the
    // player it healed.
    if (target.kind == UnitKind.player)
    {
        const threat = caster.spellMod(SpellModOp.threat, spell, cast(int) healed);
        imported!"dmangos.world.creatureai".assistThreat(caster.map, target.session.threateners, caster.unit,
            threat > 0 ? threat : 0, *spell);
    }
    return healed;
}

/// What changed in `unit`'s fields, to those who see it (the caster's own wait for the end of its cast).
private void flushUnit(ref Caster caster, UnitRef unit)
{
    if (unit.combatGuid == caster.guid)
        return;
    final switch (unit.kind)
    {
    case UnitKind.none:
        return;
    case UnitKind.player:
        return unit.session.flushPlayerChanges();
    case UnitKind.creature:
        return unit.map.flushCreature(unit.creature);
    }
}

/// A unit's power of `power` now, and whether that is its power at all (a warrior has no mana; happiness is a pet's).
bool unitPower(UnitRef who, imported!"dmangos.world.defines".Power power, out uint now)
{
    import dmangos.world.defines : Power;
    import dmangos.world.updatefields : UNIT_FIELD_BYTES_0, UNIT_FIELD_POWER1;

    auto fields = who.fields;
    if (fields is null)
        return false;
    now = fields.get!UNIT_FIELD_POWER1(power);
    return power == Power.happiness || fields.getByte!UNIT_FIELD_BYTES_0(3) == power;
}

/// Gives (`amount` > 0) or takes a unit's `power`, within none and its maximum.
void changeUnitPower(ref Caster caster, UnitRef who, imported!"dmangos.world.defines".Power power, int amount)
{
    import dmangos.world.updatefields : UNIT_FIELD_MAXPOWER1, UNIT_FIELD_POWER1;

    final switch (who.kind)
    {
    case UnitKind.none:
        return;
    case UnitKind.player:
        who.session.player.modifyPower(power, amount);
        break;
    case UnitKind.creature:
        auto v = &who.creature.values;
        const now = cast(long) v.get!UNIT_FIELD_POWER1(power) + amount, top = v.get!UNIT_FIELD_MAXPOWER1(power);
        v.set!UNIT_FIELD_POWER1(power, cast(uint)(now < 0 ? 0 : now > top ? top : now));
        break;
    }
    flushUnit(caster, who);
}

/// `SPELL_EFFECT_ENERGIZE`: `value` of the effect's power (`EffectMiscValue`) to `target`, logged.
void energize(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, int value)
{
    import dmangos.world.defines : Power;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : energizeLog;

    if (value <= 0 || !target || !target.alive || spell.miscValue[i] < 0 || spell.miscValue[i] > Power.happiness)
        return;
    const power = cast(Power) spell.miscValue[i];
    changeUnitPower(caster, target, power, value);
    caster.sendAround(Opcode.SMSG_SPELLENERGIZELOG, energizeLog(target.combatGuid, caster.guid, spell.id, power, value));
}

/// The effect's multiplier (`EffectMultipleValue`) as the caster's talents make it (`SPELLMOD_MULTIPLE_VALUE`).
float effectMultiplier(ref Caster caster, const(SpellInfo)* spell, size_t i)
{
    import dmangos.world.spellmods : SpellModOp;

    return caster.spellMod(SpellModOp.multipleValue, spell, spell.casting.multipleValue[i]);
}

/**
 * Whether `caster`'s spell may hurt `victim`, once it has reached it: a player's a creature or an enemy (a duel's
 * opponent, world PvP); a creature's whatever its targets are (Harvest Swarm's leech of a scripted creature).
 */
bool mayHurt(ref Caster caster, UnitRef victim)
{
    if (!victim)
        return false;
    final switch (caster.kind)
    {
    case UnitKind.none: return false;
    case UnitKind.player: return victim.kind == UnitKind.creature || caster.hostileTo(victim);
    case UnitKind.creature: return true;
    }
}

/// The combat log's line of effect `i` of `spell` on its target (`targetData`: `executeTarget`).
void logExecute(ref Caster caster, const(SpellInfo)* spell, size_t i, const(ubyte)[] targetData)
{
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : executeLog;

    caster.sendAround(Opcode.SMSG_SPELLLOGEXECUTE, executeLog(caster.guid, spell.id, cast(uint) spell.effect[i],
        targetData));
}

/**
 * `SPELL_EFFECT_POWER_BURN` (Mana Burn): up to `value` of the target's power of the effect's kind is burned
 * away, and the target takes the burned amount times the effect's multiplier as the spell's damage (with no
 * spell power: CMaNGOS's `EffectPowerBurn`). A target of another power is not touched.
 */
void powerBurn(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef victim, int value)
{
    import dmangos.world.defines : Power;

    const kind = spell.miscValue[i];
    uint now;
    if (kind < 0 || kind > Power.happiness || value <= 0 || !victim || !victim.alive
            || !unitPower(victim, cast(Power) kind, now))
        return;
    const burned = now < value ? now : cast(uint) value;
    changeUnitPower(caster, victim, cast(Power) kind, -cast(int) burned);
    const damage = cast(uint)(burned * effectMultiplier(caster, spell, i));
    if (victim.combatGuid != caster.guid && mayHurt(caster, victim))
        spellDamage(caster, spell, victim, damage, spell.casting.school, SpellDamage(false));
}

/**
 * `SPELL_EFFECT_POWER_DRAIN` (Dark Pact, Drain Mana's kind at once): up to `value` of the target's power of the
 * effect's kind goes to the caster, times the effect's multiplier if that is the caster's power too
 * (`SMSG_SPELLENERGIZELOG`), and the combat log says how much was drained (CMaNGOS's `EffectPowerDrain`).
 */
void powerDrain(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef victim, int value)
{
    import dmangos.world.defines : Power;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : energizeLog, executeTarget;

    const kind = spell.miscValue[i];
    uint now;
    if (kind < 0 || kind > Power.happiness || value < 0 || !victim || !victim.alive
            || !unitPower(victim, cast(Power) kind, now))
        return;
    const power = cast(Power) kind;
    const drained = now < value ? now : cast(uint) value;
    changeUnitPower(caster, victim, power, -cast(int) drained);
    const gainFactor = caster.powerType == power && victim.combatGuid != caster.guid ? effectMultiplier(caster, spell, i)
        : 1.0f;
    logExecute(caster, spell, i, executeTarget(victim.combatGuid, drained, cast(uint) power, gainFactor));
    if (const gain = cast(int)(drained * gainFactor))
    {
        auto self = caster.unit;
        changeUnitPower(caster, self, power, gain);
        caster.sendAround(Opcode.SMSG_SPELLENERGIZELOG, energizeLog(caster.guid, caster.guid, spell.id, power, gain));
        caster.flush();
    }
}

/**
 * `SPELL_EFFECT_HEALTH_LEECH` (Death Coil): the spell's damage to the target (at most what health it has), and the
 * caster healed by it times the effect's multiplier (CMaNGOS's `EffectHealthLeech`).
 */
void healthLeech(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef victim, int value)
{
    if (value < 0 || !victim || !victim.alive || victim.combatGuid == caster.guid)
        return;
    const health = victim.health;
    uint dealt = mayHurt(caster, victim) ? spellDamage(caster, spell, victim, cast(uint) value, spell.casting.school) : 0;
    if (dealt > health)
        dealt = health;
    if (caster.alive)
        spellHeal(caster, spell, caster.unit, cast(int)(dealt * effectMultiplier(caster, spell, i)), SpellHeal(true));
}

/**
 * `SPELL_EFFECT_HEAL_MAX_HEALTH` (Lay on Hands): the target healed by the caster's maximum health, its heal logged,
 * its procs (Improved Lay on Hands' armor on its target) (CMaNGOS's `EffectHealMaxHealth`).
 */
void healMaxHealth(ref Caster caster, const(SpellInfo)* spell, UnitRef target)
{
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;
    import dmangos.world.spellcast : healLog;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    auto v = target.fields;
    if (v is null || v.get!UNIT_FIELD_HEALTH == 0)
        return;
    const amount = caster.fields.get!UNIT_FIELD_MAXHEALTH;
    const health = v.get!UNIT_FIELD_HEALTH, maxHealth = v.get!UNIT_FIELD_MAXHEALTH;
    v.set!UNIT_FIELD_HEALTH(health + amount > maxHealth ? maxHealth : health + amount);
    auto p = caster.character;
    if (p !is null && target.kind == UnitKind.player && target.combatGuid != caster.guid)
        p.pvpAssisted(target.session);
    caster.sendAround(Opcode.SMSG_SPELLHEALLOG, healLog(target.combatGuid, caster.guid, spell.id, amount, false));
    if (target.kind == UnitKind.player)
        target.session.flushPlayerChanges();
    else
        flushUnit(caster, target);
    const hit = ProcHit(spell, ProcEx.normalHit, amount, 0, true);
    if (p !is null)
        p.procAuras(spellProcFlags(*spell, true, false), target, hit);
    else
        caster.ai.procAuras(spellProcFlags(*spell, true, false), target, hit);
}
