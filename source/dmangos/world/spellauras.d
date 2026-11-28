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
void applyAura(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, ubyte effects, bool detached = false)
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
        aura.detachedChannel = detached;
        if (aura.charges) // (`SPELLMOD_CHARGES`: Improved Shield Block)
            aura.charges = caster.spellMod(SpellModOp.charges, spell, aura.charges);
        if (effects)
            aura.effects &= effects;
        const school = spell.casting.school;
        if (p !is null && school < 7 && (aura.has(AuraType.periodicDamage) || aura.has(AuraType.periodicLeech)))
        {
            aura.periodicThreat = p.player.damageMods.threat[school] * caster.threatFactor(spell);
            aura.periodicResistanceMod = caster.auras.totalByMiscMask(AuraType.modTargetResistance, 1 << school);
            aura.periodicCasterPvP = p.pvp.isPvP;
        }
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
        if (applied is null)
            return;
        if (p !is null)
        {
            if (isNew && (spell.id == 21794 || spell.id == 21866))
                if (auto copy = p.currentBattleground())
                {
                    import dmangos.world.alterac : AlteracRules;
                    if (auto rules = cast(AlteracRules) copy.rules)
                        rules.collar(copy, p, creature, spell.id);
                }
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
        if (!who.addAura(given))
            return;
        if (given.positive && !hostile && !self && p !is null && spell.effect[i] == SpellEffect.applyAura
            && spell.implicitTargetA[i] == ImplicitTarget.friend)
            who.outsideQuestAid(caster.guid);
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
    import dmangos.world.opcodes : Opcode;

    caster.tellAround(target, Opcode.SMSG_PERIODICAURALOG,
        periodicLogPacket(target, aura, i, amount, powerOrSchool, absorbed, gainMultiplier));
}

private const(ubyte)[] periodicLogPacket(ulong target, const Aura aura, size_t i, uint amount, uint powerOrSchool,
    uint absorbed = 0, float gainMultiplier = 0)
{
    import dmangos.bytes : ByteWriter;

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
    return w.data;
}

/// The target's node resolves a player's damage tick when the caster is no longer on this map.
package void remotePeriodicCreatureTick(imported!"dmangos.world.context".WorldContext context, UnitRef victim,
    Aura aura, size_t i)
{
    import std.algorithm.comparison : max;
    import dmangos.script.api : AuraTicked, EntityRef, SpellContext;
    import dmangos.world.opcodes : Opcode;

    if (!context.canWrite())
        return;
    if (aura.type(i) == AuraType.periodicManaLeech)
        return remoteManaLeechTick(context, victim, aura, i);
    int amount = aura.amount[i];
    if (aura.period[i] > 0 && aura.maxDuration > 0)
        if (auto handle = context.spellScript(aura.spell.id))
        {
            // AuraTicked's amount calculation (Curse of Agony) needs only the tick and original caster ID.
            SpellContext tick;
            context.scripts.raise(handle, tick, AuraTicked(EntityRef(aura.caster), EntityRef(victim.combatGuid),
                cast(ubyte) i, (aura.maxDuration - aura.duration) / aura.period[i], aura.maxDuration / aura.period[i],
                amount));
            if (tick.amountChanged)
                amount = tick.amount;
        }
    const school = aura.spell.casting.school;
    const damage = creaturePeriodicDamage(victim, aura.spell, aura.casterLevel, cast(uint) max(0, amount),
        max(0, victim.resistance(school) + aura.periodicResistanceMod));
    if (aura.type(i) == AuraType.periodicLeech)
        return remoteLeechTick(context, victim, aura, i, damage);
    victim.map.sendToObservers(victim.combatGuid, Opcode.SMSG_PERIODICAURALOG,
        periodicLogPacket(victim.combatGuid, aura, i, damage, school));
    context.remoteSpells.dealRemotePeriodicDamage(victim, aura, damage, i);
}

package void remoteLeechTick(imported!"dmangos.world.context".WorldContext context, UnitRef victim, Aura aura,
    size_t i, uint damage)
{
    import std.algorithm.comparison : min;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : nonMeleeDamageLog;

    if (!victim.alive || !context.canWrite() || !channelAuraActive(victim, aura))
        return;
    const school = aura.spell.casting.school;
    const absorbed = victim.absorb(school, damage);
    const log = nonMeleeDamageLog(victim.combatGuid, aura.caster, aura.spell.id, damage, school, absorbed, 0,
        true, 0, false);
    if (victim.kind == UnitKind.player)
        victim.session.tellAround(victim.combatGuid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, log);
    else
        victim.map.sendToObservers(victim.combatGuid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, log);
    context.remoteSpells.dealRemotePeriodicDamage(victim, aura, damage, i, min(damage, victim.health));
}

package void remoteManaLeechTick(imported!"dmangos.world.context".WorldContext context, UnitRef victim, Aura aura,
    size_t i)
{
    import std.algorithm.comparison : min;
    import dmangos.world.character : Character;
    import dmangos.world.defines : Power;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.replication : Replica;
    import dmangos.world.spelldamage : changeUnitPower, unitPower;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    const kind = aura.misc(i);
    if (!context.canWrite() || !channelAuraActive(victim, aura) || aura.amount[i] <= 0
        || kind < 0 || kind > Power.happiness)
        return;
    if (auto caster = context.onlinePlayer(aura.caster))
    {
        if (caster.player is null || !caster.player.alive)
            return;
    }
    else if (!context.remoteKillRecipient(aura.caster, victim.map).node)
        return;
    if (auto copy = cast(Replica) victim.map.findObject(aura.caster))
        if (!copy.fieldsOf.get!UNIT_FIELD_HEALTH)
            return;
    uint available;
    const power = cast(Power) kind;
    if (!unitPower(victim, power, available))
        return;
    const drained = min(cast(uint) aura.amount[i], available);
    Caster absent;
    changeUnitPower(absent, victim, power, -cast(int) drained);
    const factor = aura.spell.casting.multipleValue[i];
    const log = periodicLogPacket(victim.combatGuid, aura, i, drained, power, 0, factor);
    if (victim.kind == UnitKind.player)
        victim.session.tellAround(victim.combatGuid, Opcode.SMSG_PERIODICAURALOG, log);
    else
    {
        victim.map.sendToObservers(victim.combatGuid, Opcode.SMSG_PERIODICAURALOG, log);
        if (victim.creature.ai !is null && drained && factor > 0)
            victim.creature.ai.addRemoteThreat(aura.caster, drained * factor * 0.5f);
    }
    context.remoteSpells.reportPeriodicResult(victim, aura, i, 0, drained);
}

/// A channel's caster must still be channeling it at this target.
package bool channelAuraActive(UnitRef victim, Aura aura, bool allowFinalTick = false)
{
    import dmangos.world.objects : UpdateValues;
    import dmangos.world.replication : Replica;
    import dmangos.world.updatefields : TypeId, UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT, UNIT_FIELD_HEALTH;
    import dmangos.world.unit : UnitKind;

    if (!(aura.spell.attributesEx & (0x04 | 0x40)) || aura.detachedChannel)
        return true;
    if (victim.map is null)
        return false;
    bool channelMatches(const UpdateValues* fields)
    {
        const active = fields.get!UNIT_CHANNEL_SPELL;
        return (active == aura.spell.id && fields.get!UNIT_FIELD_CHANNEL_OBJECT == victim.combatGuid)
            || (allowFinalTick && aura.duration <= 0 && !active);
    }
    if (auto caster = victim.map.unit(aura.caster))
        return caster.alive && (caster.kind == UnitKind.player
            ? caster.session.channelledAt(aura.spell) == victim.combatGuid : allowFinalTick && channelMatches(caster.fields));
    if (auto copy = cast(Replica) victim.map.findObject(aura.caster))
        return (copy.fieldsOf.type == TypeId.player || (allowFinalTick && copy.fieldsOf.type == TypeId.unit))
            && copy.fieldsOf.get!UNIT_FIELD_HEALTH && channelMatches(&copy.fieldsOf());
    return false;
}

private uint creaturePeriodicDamage(UnitRef victim, const(SpellInfo)* spell, uint level, uint amount, int resistance)
{
    import std.random : uniform;
    import dmangos.world.combat : armorReducedDamage, partiallyResisted;
    import dmangos.world.spellcast : isBinarySpell;

    const school = spell.casting.school;
    if (school == 0)
        return cast(uint) armorReducedDamage(level, victim.fighter.armor, amount);
    if (school == 1)
        return amount;
    return partiallyResisted(amount, resistance, level, victim.fighter, isBinarySpell(*spell),
        uniform!"[]"(1u, 10000u, victim.map.random)).damage;
}

/**
 * A periodic effect of `caster`'s aura on a creature ticked (`UnitRef.auraTick`): damage over time hurts it as a
 * spell would (armor; a partial resist, a binary spell's at a tenth; tapping, threat, the kill) and sets off what a
 * tick does; a leech heals its caster, a mana leech gives it power. Its spell's script may make the tick another
 * amount (a player's).
 */
void periodicTick(ref Caster caster, imported!"dmangos.world.creature".Creature target, Aura aura, size_t i)
{
    import dmangos.world.unit : Blow, dealDamage;

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
        const school = aura.spell.casting.school;
        const damage = creaturePeriodicDamage(victim, aura.spell, caster.level, amount,
            caster.targetResistance(victim.resistance(school), school));
        if (aura.type(i) == AuraType.periodicLeech)
            return leechTick(caster, victim, aura, i, damage);
        periodicLog(caster, target.guid, aura, i, damage, school);
        if (target.alive)
        {
            import dmangos.world.spellmods : SpellModOp;

            caster.enteredCombat(damage);
            auto blow = Blow.periodic(school);
            blow.threat = caster.threatFactor(aura.spell);
            dealDamage(caster.unit, victim, damage, blow);
        }
        caster.damageDealt(aura.spell, victim, false, damage, true); // Nightfall, Vampiric Embrace
        break;
    case AuraType.periodicManaLeech:
        return manaLeechTick(caster, victim, aura, i, amount);
    case AuraType.periodicHealthFunnel:
        return funnelTick(caster, victim, aura, i, amount);
    case AuraType.periodicTriggerSpell:
        if (caster.kind == UnitKind.creature && caster.creature is target)
        {
            import dmangos.world.eventai : EventTarget, castBesideCurrent, castTriggered;

            import std.algorithm.comparison : among;

            enum uint fireBlossom = 19636, unholyAura = 17467, drakonidSpawner = 22653, kelThuzadChannel = 29423,
                chill = 28534;
            if (!aura.spell.id.among(fireBlossom, unholyAura, drakonidSpawner, kelThuzadChannel, chill))
                caster.ai.arcaneMissilesTick(aura.spell, i);
            else
                if (const child = caster.context.data.spells.spell(aura.spell.triggerSpell[i]))
                {
                    // Fire Blossom chooses a raider. Unholy Aura, Drakonid Spawner, Kel'Thuzad's channel (the effect
                    // its clients see pulse) and the Blizzard's Chill (its patch of cold where it is) use their caster.
                    const selected = aura.spell.id == fireBlossom
                        ? caster.ai.moreTargetFor(EventTarget.hostileRandomPlayer, 0, child.id, castTriggered)
                        : caster.guid;
                    if (selected) // beside a cast under way, not cutting it short
                        caster.ai.castSpell(child, selected, castTriggered | castBesideCurrent);
                }
        }
        break;
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
        blow.threat = caster.threatFactor(aura.spell);
    dealDamage(caster.unit, victim, damage, blow);
    const factor = aura.spell.casting.multipleValue[i] > 0 ? aura.spell.casting.multipleValue[i] : 1.0f;
    if (caster.alive)
        spellHeal(caster, aura.spell, caster.unit, cast(int)(dealt * caster.spellMod(SpellModOp.multipleValue, aura.spell,
            factor)), SpellHeal(true));
    caster.damageDealt(aura.spell, victim, false, damage, true); // a tick as any damage over time's: Nightfall
}

/**
 * A tick of `caster`'s `SPELL_AURA_PERIODIC_HEALTH_FUNNEL` on `beneficiary` (Blood Siphon: a raider's blood into
 * Hakkar): a leech the other way round, as CMaNGOS's tick has it. The caster takes the amount (logged as a periodic
 * spell hit), and the aura's bearer is healed by what it took (at most the caster's health) times the effect's
 * multiplier.
 */
void funnelTick(ref Caster caster, UnitRef beneficiary, Aura aura, size_t i, uint amount)
{
    import dmangos.world.spellcast : nonMeleeDamageLog;
    import dmangos.world.spelldamage : SpellHeal, spellHeal;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.unit : Blow, dealDamage;

    if (!beneficiary || !beneficiary.alive || !caster.alive || amount == 0)
        return;
    const school = aura.spell.casting.school;
    auto victim = caster.unit;
    const health = victim.health;
    const dealt = amount < health ? amount : health;
    caster.tellAround(victim.combatGuid, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(victim.combatGuid,
        caster.guid, aura.spell.id, amount, school, 0, 0, true, 0, false));
    dealDamage(victim, victim, dealt, Blow.periodic(school));
    const factor = aura.spell.casting.multipleValue[i] > 0 ? aura.spell.casting.multipleValue[i] : 1.0f;
    if (beneficiary.alive)
        spellHeal(caster, aura.spell, beneficiary, cast(int)(dealt * factor), SpellHeal(true));
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

/// `unit` loses `aura` (a dispel's, a cleanse's), whoever it is.
void loseAuraOf(imported!"dmangos.world.map".Map map, UnitRef unit, Aura aura)
{
    final switch (unit.kind)
    {
    case UnitKind.none:
        return;
    case UnitKind.creature:
        unit.creature.loseAura(aura, map);
        map.flushObjectChanges(unit.creature);
        return;
    case UnitKind.player:
        unit.session.removeAura(aura);
        return;
    }
}

/**
 * `SPELL_EFFECT_DISPEL` (Dispel Magic, Purge, Cleanse, Remove Curse): up to `count` (at least one) of `target`'s
 * auras of the effect's dispel type (all of them: 7), picked at random; magic only the caster's enemy's buffs or its
 * friend's debuffs. `SMSG_SPELLDISPELLOG` names what went.
 */
void dispel(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, int count)
{
    import std.algorithm.mutation : remove;
    import std.random : uniform;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.opcodes : Opcode;

    enum uint dispelMagic = 1, dispelAll = 7;
    if (!target)
        return;
    auto auras = target.auraSet;
    if (auras is null)
        return;
    const type = spell.miscValue[i];
    const uint mask = type == dispelAll ? 0b11110 : type < 32 ? 1u << type : 0;
    const friendly = !caster.hostileTo(target);
    Aura[] eligible;
    foreach (aura; auras.list)
    {
        if (aura.passive || !(mask & (1u << aura.spell.casting.dispel)))
            continue;
        if (aura.spell.casting.dispel == dispelMagic && aura.positive == friendly)
            continue;
        eligible ~= aura;
    }
    Aura[] removed;
    foreach (_; 0 .. count > 0 ? count : 1)
    {
        if (eligible.length == 0)
            break;
        const at = uniform(0, eligible.length, caster.map.random);
        removed ~= eligible[at];
        eligible = eligible.remove(at);
    }
    if (removed.length == 0)
        return;
    ByteWriter w;
    w.putPackedGuid(target.combatGuid);
    w.putPackedGuid(caster.guid);
    w.put(cast(uint) removed.length);
    foreach (aura; removed)
        w.put(aura.spell.id);
    caster.sendAround(Opcode.SMSG_SPELLDISPELLOG, w.data);
    foreach (aura; removed)
        loseAuraOf(caster.map, target, aura);
}

/// Whether the aura is of mechanic `mechanic` (its spell's, or one of its effects').
bool ofMechanic(const Aura aura, uint mechanic) pure nothrow @nogc @safe
{
    if (aura.spell.casting.mechanic == mechanic)
        return true;
    foreach (j; 0 .. 3)
        if ((aura.effects & (1 << j)) && aura.spell.casting.effectMechanic[j] == mechanic)
            return true;
    return false;
}

/**
 * `SPELL_EFFECT_DISPEL_MECHANIC` (Escape Artist's roots and snares, Polymorph's mount): up to `value` (at least one)
 * of the target's auras of the effect's mechanic go, picked at random (a player's passive ones stay; CMaNGOS's
 * `EffectDispelMechanic`).
 */
void dispelMechanic(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, int value)
{
    import std.random : uniform;
    import dmangos.world.spelldamage : logExecute;
    import dmangos.world.spellcast : executeTarget;

    const mechanic = cast(uint) spell.miscValue[i];
    if (mechanic == 0 || !target || !target.alive)
        return;
    auto auras = target.auraSet;
    if (auras is null)
        return;
    auto count = value > 0 ? value : 1;
    Aura[] found;
    foreach (aura; auras.list)
        if ((target.kind != UnitKind.player || !aura.passive) && ofMechanic(aura, mechanic))
            found ~= aura;
    for (; count > 0 && found.length; --count)
    {
        const k = uniform(0, found.length, caster.map.random);
        loseAuraOf(caster.map, target, found[k]);
        found = found[0 .. k] ~ found[k + 1 .. $];
    }
    logExecute(caster, spell, i, executeTarget(target.combatGuid));
}
