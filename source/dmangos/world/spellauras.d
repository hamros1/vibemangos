/**
 * The aura stage of the spell pipeline (docs/SPELLS.md, step 3): a cast's aura on a unit, and each periodic tick of
 * it, done once for whoever cast it.
 *
 * `applyAura` works out an aura's amounts and duration from its caster (rolled, its talents or a pet's owner's, a
 * finisher's combo points, its spell power over time, `SPELLMOD_DOT`), and puts it on its target: a debuff on an
 * enemy (diminished in PvP, broken early by its resistance), a buff on a friend. What an aura then does is the
 * target's own (a player's stats and forms: `aurahandlers.d`; a creature's movement, flags and look: `creature.d`).
 * `periodicTick` is a tick of damage, a drain or a leech, done for its caster whatever it is.
 */
module dmangos.world.spellauras;

import dmangos.world.auras : Aura, AuraType;
import dmangos.world.caster : Caster;
import dmangos.world.spellids;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitKind, UnitRef;

/// Whether effect `j` of `spell` is an aura effect among `effects` (bits; 0: all).
bool isAuraEffect(const(SpellInfo)* spell, size_t j, ubyte effects = 0) pure nothrow @nogc @safe
{
    const effect = spell.effect[j];
    return (effect == SpellEffect.applyAura || effect == SpellEffect.applyAreaAuraParty
        || effect == SpellEffect.applyAreaAuraPet) && (!effects || (effects & (1 << j)));
}

/// An aura as its caster casts it: its effects' amounts, and how long it lasts.
struct AuraCast
{
    int[3] values;
    int ms;
}

/**
 * The amounts of `spell`'s aura effects among `effects` as `caster` casts them, and their duration: each rolled (or a
 * cast's own) with the caster's modifiers (`Caster.effectAmount`), its class rules' (Rip's and Rupture's attack
 * power), its spell power over time (each tick its coefficient's share), and `SPELLMOD_DOT` on damage over time.
 */
AuraCast auraCast(ref Caster caster, const(SpellInfo)* spell, ubyte effects)
{
    import dmangos.world.spellcast : bonusCoefficient, duration;
    import dmangos.world.spellmods : SpellModOp;

    AuraCast a;
    foreach (j; 0 .. 3)
        if (isAuraEffect(spell, j, effects))
            a.values[j] = caster.effectAmount(spell, j);
    if (auto p = caster.character)
        p.classAuraValues(spell, a.values); // Rip's and Rupture's attack power, Mana Shield's spell power
    a.ms = caster.modDuration(spell, duration(*spell, caster.context.client, caster.level));
    foreach (j; 0 .. 3)
        if (isAuraEffect(spell, j, effects) && spell.casting.amplitude[j] > 0 && a.ms > 0)
        {
            const type = cast(AuraType) spell.casting.applyAuraName[j];
            int done;
            if ((type == AuraType.periodicDamage || type == AuraType.periodicLeech) && spell.casting.school != 0)
                done = caster.spellPower(1 << spell.casting.school);
            else if (type == AuraType.periodicHeal)
                done = caster.healingPower();
            if (done > 0)
                a.values[j] += cast(int)(done * bonusCoefficient(*spell, j, caster.context.client, caster.level));
        }
    foreach (j; 0 .. 3)
        if (isAuraEffect(spell, j, effects) && (spell.casting.applyAuraName[j] == AuraType.periodicDamage
                || spell.casting.applyAuraName[j] == AuraType.periodicLeech))
            a.values[j] = caster.spellMod(SpellModOp.dot, spell, a.values[j]);
    return a;
}

/**
 * `SPELL_EFFECT_APPLY_AURA` and the area auras on their caster, at the spell's first aura effect at `target`, for
 * all of them: the aura on its target, with only the aura effects aimed at it (`effects`, bits; 0: all of them:
 * Mind Control's possession on the creature, its dummy on its caster). On an enemy it is a debuff, which may break
 * early (`SPELL_ATTR_HEARTBEAT_RESIST`), diminished on a player by its kind before it when a player or its pet cast
 * it; and it pulls the enemy into the fight.
 */
void applyAura(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, ubyte effects)
{
    import dmangos.world.auras : makeAura;
    import dmangos.world.spellcast : heartbeatResistChance;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.unit : Blow, dealDamage;
    import dmangos.world.updatefields : UNIT_FIELD_RESISTANCES;

    foreach (j; 0 .. i)
        if (isAuraEffect(spell, j, effects))
            return;
    if (!target || !caster)
        return;
    auto a = auraCast(caster, spell, effects);
    const self = target.combatGuid == caster.guid;
    const hostile = !self && caster.hostileTo(target);
    auto map = caster.map;
    auto p = caster.character;

    Aura made(int lasts)
    {
        auto aura = makeAura(spell, caster.guid, caster.level, lasts, !hostile, a.values);
        if (aura.charges) // (`SPELLMOD_CHARGES`: Improved Shield Block)
            aura.charges = caster.spellMod(SpellModOp.charges, spell, aura.charges);
        if (effects)
            aura.effects &= effects;
        if (hostile)
            aura.setHeartbeatResist(heartbeatResistChance(caster.fighter, target.fighter, *spell,
                caster.targetResistance(target.resistance(spell.casting.school), spell.casting.school),
                caster.hitBonus(spell)), a.ms);
        return aura;
    }

    final switch (target.kind)
    {
    case UnitKind.none:
        return;
    case UnitKind.creature:
    {
        auto creature = target.creature;
        if (!creature.alive)
            return;
        auto aura = made(a.ms);
        transformLook(caster, aura, map);
        bool isNew;
        auto applied = creature.receiveAura(aura, map, isNew);
        if (p !is null)
        {
            if (isNew)
                p.classCreatureAuraApplied(creature, applied); // the sting or curse it replaces
            p.scorpidStingLanded(applied, target); // Improved Scorpid Sting (dmangos.world.physicalclasses)
            map.flushObjectChanges(creature);
            foreach (j; 0 .. 3)
                if (isAuraEffect(spell, j, effects))
                    p.auraAppliedScript(spell, j, target.combatGuid, a.values[j]);
            // A charm (Enslave Demon) or a possession (Mind Control, Eyes of the Beast): the creature is the player's.
            foreach (j; 0 .. 3)
                if (isAuraEffect(spell, j, effects))
                {
                    const kind = spell.casting.applyAuraName[j];
                    if (kind == AuraType.modCharm || kind == AuraType.modPossess || kind == AuraType.modPossessPet)
                    {
                        p.takeCharm(creature, spell, kind != AuraType.modCharm);
                        break;
                    }
                }
            if (p.charmed is creature)
                return;
        }
        else
        {
            if (!self)
                map.flushCreature(creature);
            map.wake(creature.guid);
            if (isNew) // its spell's script hears of each of its effects (Stoned's statue, a woodcutter's empty hands)
            {
                import dmangos.script.api : AuraApplied, EntityRef;

                foreach (j; 0 .. 3)
                    if (applied.effects & (1 << j))
                        caster.ai.spellScriptEvent(spell, AuraApplied(EntityRef(caster.guid), EntityRef(creature.guid),
                            cast(ubyte) j, a.values[j]), map);
            }
        }
        if (hostile && creature.alive) // an enemy's aura is an attack (it fights back)
        {
            caster.enteredCombat(0);
            dealDamage(caster.unit, target, 0, Blow.spell());
        }
        return;
    }
    case UnitKind.player:
    {
        auto who = target.session;
        if (who.player is null || (hostile && !target.alive))
            return;
        // On an enemy (a duel's opponent; a creature's victim) it is a debuff; a player's or its pet's diminished by
        // those of its kind before it.
        int lasts = a.ms;
        if (hostile && (caster.kind == UnitKind.player || caster.fighter.playerControlled))
        {
            lasts = who.diminishedDuration(spell, a.ms);
            if (lasts == 0 && a.ms > 0)
                return; // immune for now
        }
        auto given = made(lasts);
        who.addAura(given);
        if (hostile && p !is null)
            p.scorpidStingLanded(given, target); // Improved Scorpid Sting (dmangos.world.physicalclasses)
        if (!hostile && !self) // a buff on one fighting: those it fights fight its caster too
            imported!"dmangos.world.creatureai".assistThreat(map, who.threateners, caster.unit, 0, *spell);
        return;
    }
    }
}

/**
 * A transform's look on a creature (Hex, Polymorph's sheep, the Wondervolt's shapes): the model of its misc value's
 * creature (its first), kept in the aura's amount for the creature to show while it has it (`Creature.refreshLook`;
 * CMaNGOS's `HandleAuraTransform`); a pink pig for a creature not in the data.
 */
private void transformLook(ref Caster caster, Aura aura, imported!"dmangos.world.map".Map map)
{
    import dmangos.world.creature : chooseDisplay;

    enum uint pinkPig = 16358;
    foreach (j; 0 .. 3)
        if ((aura.effects & (1 << j)) && aura.type(j) == AuraType.transform)
        {
            aura.amount[j] = 0;
            if (const misc = aura.misc(j))
            {
                const t = cast(uint) misc in caster.context.data.creatureTemplates;
                aura.amount[j] = t is null ? pinkPig : cast(int) chooseDisplay(*t, map.random);
            }
        }
}

/// A periodic aura's log (`SMSG_PERIODICAURALOG`) for those who see `target`.
void periodicLog(ref Caster caster, ulong target, const Aura aura, size_t i, uint amount, uint powerOrSchool,
    uint absorbed = 0, float gainMultiplier = 0)
{
    import dmangos.bytes : ByteWriter;
    import dmangos.world.opcodes : Opcode;

    ByteWriter w;
    w.putPackedGuid(target);
    w.putPackedGuid(aura.caster);
    w.put(aura.spell.id);
    w.put(1u);
    w.put(cast(uint) aura.type(i));
    switch (aura.type(i))
    {
    case AuraType.periodicDamage:
        w.put(amount);
        w.put(aura.spell.casting.school);
        w.put(absorbed);
        w.put(0);
        break;
    case AuraType.periodicHeal, AuraType.obsModHealth:
        w.put(amount);
        break;
    case AuraType.periodicManaLeech:
        w.put(powerOrSchool);
        w.put(amount);
        w.put(gainMultiplier);
        break;
    default:
        w.put(powerOrSchool);
        w.put(amount);
        break;
    }
    caster.tellAround(target, Opcode.SMSG_PERIODICAURALOG, w.data);
}

/**
 * A periodic effect of `caster`'s aura on a creature ticked (`UnitRef.auraTick`): damage over time hurts it as a
 * spell would (armor; a partial resist, a binary spell's at a tenth; tapping, threat, the kill) and sets off what a
 * tick does; a leech heals its caster, a mana leech gives it power. Its spell's script may make the tick another
 * amount (a player's).
 */
void periodicTick(ref Caster caster, imported!"dmangos.world.creature".Creature target, Aura aura, size_t i)
{
    import std.random : uniform;
    import dmangos.world.combat : armorReducedDamage, partiallyResisted;
    import dmangos.world.spellcast : isBinarySpell;
    import dmangos.world.unit : Blow, dealDamage;
    import dmangos.world.updatefields : UNIT_FIELD_RESISTANCES;

    if (!target.alive || !caster)
        return;
    auto map = caster.map;
    auto victim = map.unitOf(target);
    int scripted = aura.amount[i];
    if (auto p = caster.character)
        if (aura.period[i] > 0 && aura.maxDuration > 0)
            scripted = p.auraTickScript(aura.spell, i, target.guid, (aura.maxDuration - aura.duration) / aura.period[i],
                aura.maxDuration / aura.period[i], aura.amount[i]);
    const amount = scripted > 0 ? cast(uint) scripted : 0;
    switch (aura.type(i))
    {
    case AuraType.periodicHeal: // (the creature healed itself: `Creature.selfTick`) Improved Mend Pet
        if (auto p = caster.character)
            p.hunterHealTick(aura, victim);
        break;
    case AuraType.periodicDamage, AuraType.periodicLeech:
        uint damage = amount;
        const school = aura.spell.casting.school;
        if (school == 0)
            damage = cast(uint) armorReducedDamage(caster.level, target.fighter.armor, damage);
        else if (school != 1)
            damage = partiallyResisted(damage, caster.targetResistance(cast(int) target.values.get!UNIT_FIELD_RESISTANCES(school),
                school), caster.level, target.fighter, isBinarySpell(*aura.spell), uniform!"[]"(1u, 10000u, map.random)).damage;
        if (aura.type(i) == AuraType.periodicLeech)
            return leechTick(caster, victim, aura, i, damage);
        periodicLog(caster, target.guid, aura, i, damage, school);
        if (target.alive)
        {
            import dmangos.world.spellmods : SpellModOp;

            caster.enteredCombat(damage);
            auto blow = Blow.periodic(school);
            blow.threat = caster.spellMod(SpellModOp.threat, aura.spell, 1.0f);
            dealDamage(caster.unit, victim, damage, blow);
        }
        caster.damageDealt(aura.spell, victim, false, damage, true); // Nightfall, Vampiric Embrace
        break;
    case AuraType.periodicManaLeech:
        return manaLeechTick(caster, victim, aura, i, amount);
    default:
        break;
    }
}

/**
 * A tick of `caster`'s `SPELL_AURA_PERIODIC_LEECH` (Drain Life, Siphon Life) on `victim`: its damage, logged as a
 * periodic spell hit (`SMSG_SPELLNONMELEEDAMAGELOG`, as CMaNGOS's leech sends), and the caster healed by what it took
 * (at most the victim's health) times the effect's multiplier.
 */
void leechTick(ref Caster caster, UnitRef victim, Aura aura, size_t i, uint damage)
{
    import dmangos.world.spellcast : nonMeleeDamageLog;
    import dmangos.world.spelldamage : SpellHeal, spellHeal;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.unit : Blow, dealDamage;

    if (!victim || !victim.alive)
        return;
    const school = aura.spell.casting.school;
    const absorbed = victim.absorb(school, damage);
    const health = victim.health;
    const dealt = damage < health ? damage : health;
    caster.tellAround(victim.combatGuid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(victim.combatGuid,
        caster.guid, aura.spell.id, damage, school, absorbed, 0, true, 0, false));
    caster.enteredCombat(damage);
    auto blow = Blow.periodic(school);
    if (victim.kind == UnitKind.creature)
        blow.threat = caster.spellMod(SpellModOp.threat, aura.spell, 1.0f);
    dealDamage(caster.unit, victim, damage, blow);
    const factor = aura.spell.casting.multipleValue[i] > 0 ? aura.spell.casting.multipleValue[i] : 1.0f;
    if (caster.alive)
        spellHeal(caster, aura.spell, caster.unit, cast(int)(dealt * caster.spellMod(SpellModOp.multipleValue, aura.spell,
            factor)), SpellHeal(true));
    caster.damageDealt(aura.spell, victim, false, damage, true); // a tick as any damage over time's: Nightfall
}

/**
 * A tick of `caster`'s `SPELL_AURA_PERIODIC_MANA_LEECH` (Drain Mana, Viper Sting) on `victim`: up to its amount of
 * the victim's power of the misc value's kind is drained, logged (`SMSG_PERIODICAURALOG` with the gain multiplier),
 * and the caster gets it times the multiplier if it has that power at all; a creature drained hates it by half the
 * gain (CMaNGOS's `PERIODIC_MANA_LEECH` tick).
 */
void manaLeechTick(ref Caster caster, UnitRef victim, Aura aura, size_t i, uint amount)
{
    import dmangos.world.defines : Power;
    import dmangos.world.spelldamage : changeUnitPower, effectMultiplier, unitPower;
    import dmangos.world.updatefields : UNIT_FIELD_MAXPOWER1;

    const kind = aura.misc(i);
    uint now;
    if (!victim || !victim.alive || !caster.alive || kind < 0 || kind > Power.happiness
            || !unitPower(victim, cast(Power) kind, now))
        return;
    const power = cast(Power) kind;
    const drained = now < amount ? now : amount;
    changeUnitPower(caster, victim, power, -cast(int) drained);
    if (auto p = caster.character)
        p.classManaDrained(victim, aura, drained); // Improved Drain Mana
    const gainFactor = caster.fields.get!UNIT_FIELD_MAXPOWER1(power) > 0 ? effectMultiplier(caster, aura.spell, i) : 0.0f;
    periodicLog(caster, victim.combatGuid, aura, i, drained, power, 0, gainFactor);
    const gain = cast(int)(drained * gainFactor);
    if (gain <= 0)
        return;
    changeUnitPower(caster, caster.unit, power, gain);
    caster.flush();
    if (victim.kind == UnitKind.creature && victim.creature.ai !is null)
        victim.creature.ai.addThreat(caster.unit, gain * 0.5f);
}
