/**
 * The effect stage of the spell pipeline (docs/SPELLS.md): what each spell effect does to a target it reached,
 * whoever cast it, through one `final switch` over `SpellEffect`.
 *
 * Every effect is decided here: done for every caster, done only for a player's cast (what needs its inventory,
 * spellbook, client or pet: `doneByCreatures` lists the others), or not done by any yet (logged once each). Where
 * the caster's kind still matters, the case says so (`caster.character`: a player's; `caster.ai`: a creature's,
 * a pet's or a totem's).
 */
module dmangos.world.spelleffects;

import dmangos.world.caster : Caster;
import dmangos.world.combat : MeleeDamage;
import dmangos.world.movement : Position;
import dmangos.world.spellcast : SpellTargets;
import dmangos.world.spellids;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitKind, UnitRef;

/// A cast whose effects are being done: what the effects need of it beyond the spell.
struct SpellCast
{
    const(SpellInfo)* spell;
    SpellTargets targets;
    int timer;            /// milliseconds until it goes
    uint castItemEntry;   /// the item it is cast from: no power, the item's cooldown
    bool triggered;
    bool active;
    ubyte persistentDone; /// effects done once a cast, not once a target (a persistent area, a summon)
    ulong castItemGuid;   /// ... that very item, whose charges it takes (`dmangos.world.itemuse`)
    int castTime;         /// its whole cast time (pushback adds back at most up to it); last: built by position
    imported!"dmangos.world.classspells".CustomValues custom; /// its own effect amounts (`castCustom`)
    /// Each target's aura effects (bits): each target's aura has only those at it (CMaNGOS's holder per
    /// target), so Arcane Missiles' trigger stays on the caster and its dummy on the enemy.
    ubyte[ulong] auraEffects;
    /// A creature's weapon spell: the melee roll against each target (its hit roll).
    MeleeDamage[ulong] weaponRolls;
    bool playerHandoff; /// the cast followed its player target across nodes
    Position gameObjectOrigin; /// where the caster completed a spell with a named game-object effect

    /// Whether effect `i` is to be done once this cast (the first target), and marks it done.
    bool once(size_t i)
    {
        if (persistentDone & (1 << i))
            return false;
        persistentDone |= cast(ubyte)(1 << i);
        return true;
    }
}

/// The effects no caster's cast does yet (some, such as skills and proficiencies, are done when a spell is learned).
private enum SpellEffect[] notDoneByAny = [SpellEffect.portalTeleport, SpellEffect.environmentalDamage,
    SpellEffect.bind, SpellEffect.ritualBase, SpellEffect.ritualSpecialize,
    SpellEffect.ritualActivatePortal, SpellEffect.dodge, SpellEffect.evade, SpellEffect.parry, SpellEffect.block,
    SpellEffect.weapon, SpellEffect.defense, SpellEffect.triggerMissile, SpellEffect.summonChangeItem,
    SpellEffect.spellDefense, SpellEffect.language, SpellEffect.dualWield,
    SpellEffect.addHonor, SpellEffect.tradeSkill, SpellEffect.stealth,
    SpellEffect.forceCriticalHit, SpellEffect.guaranteeHit, SpellEffect.proficiency, SpellEffect.healthFunnel,
    SpellEffect.powerFunnel, SpellEffect.pull, SpellEffect.healMechanical, SpellEffect.createHouse,
    SpellEffect.bindSight, SpellEffect.threatAll, SpellEffect.enchantHeldItem,
    SpellEffect.summonPhantasm, SpellEffect.destroyAllTotems,
    SpellEffect.spiritHeal, SpellEffect.skill, SpellEffect.teleportGraveyard, SpellEffect.n122,
    SpellEffect.modifyThreatPercent, SpellEffect.n126, SpellEffect.n127,
    SpellEffect.applyAreaAuraFriend, SpellEffect.applyAreaAuraEnemy];

/**
 * The hit roll of `caster`'s `spell` at `target` (`rollSpellHit`): only an enemy is rolled against, a friend (a heal,
 * a buff) never missed; the caster's hit (`MOD_SPELL_HIT_CHANCE`, its modifiers) and the target's resistance as the
 * caster's spells meet it count.
 */
imported!"dmangos.world.spellcast".SpellMissInfo rollHit(ref Caster caster, const(SpellInfo)* spell, UnitRef target)
{
    import dmangos.world.spellcast : rollSpellHit, SpellMissInfo;

    if (!target || !target.alive || !caster.hostileTo(target))
        return SpellMissInfo.none;
    const school = spell.casting.school;
    return rollSpellHit(caster.fighter, target.fighter, *spell, caster.targetResistance(target.resistance(school),
        school), caster.hitBonus(spell), caster.map.random);
}

/// What a creature's cast does of what a player's does (the rest of the effects a player's does are its own yet).
private enum SpellEffect[] creaturesDo = [SpellEffect.none, SpellEffect.schoolDamage,
    SpellEffect.weaponDamageNoschool, SpellEffect.weaponPercentDamage, SpellEffect.weaponDamage,
    SpellEffect.normalizedWeaponDmg, SpellEffect.applyAura, SpellEffect.applyAreaAuraParty,
    SpellEffect.applyAreaAuraPet, SpellEffect.threat, SpellEffect.heal, SpellEffect.triggerSpell, SpellEffect.dummy,
    SpellEffect.scriptEffect, SpellEffect.interruptCast, SpellEffect.sendEvent, SpellEffect.summon,
    SpellEffect.summonWild, SpellEffect.summonGuardian, SpellEffect.knockBack, SpellEffect.pullTowards, SpellEffect.healthLeech,
    SpellEffect.powerDrain, SpellEffect.powerBurn, SpellEffect.durabilityDamage, SpellEffect.durabilityDamagePct,
    SpellEffect.reputation, SpellEffect.teleportUnits, SpellEffect.teleportUnitsFaceCaster, SpellEffect.instantKill,
    SpellEffect.energize,
    SpellEffect.healMaxHealth, SpellEffect.summonObjectWild, SpellEffect.transDoor, SpellEffect.summonPet,
    SpellEffect.learnSpell, SpellEffect.createItem, SpellEffect.addComboPoints, SpellEffect.spawn, SpellEffect.detect,
    SpellEffect.attackMe, SpellEffect.attack, SpellEffect.persistentAreaAura, SpellEffect.dispel, SpellEffect.dispelMechanic,
    SpellEffect.charge, SpellEffect.leap, SpellEffect.addExtraAttacks, SpellEffect.summonTotem, SpellEffect.summonTotemSlot1,
    SpellEffect.summonTotemSlot2, SpellEffect.summonTotemSlot3, SpellEffect.summonTotemSlot4,
    // What CMaNGOS does for a creature's cast: nothing for a temporary enchantment, a lock, a skill step or Portal
    // (a player's, an item's, unused); the rest as for a player's.
    SpellEffect.enchantItemTemporary, SpellEffect.openLock, SpellEffect.openLockItem, SpellEffect.skillStep,
    SpellEffect.portal, SpellEffect.questComplete, SpellEffect.resurrect, SpellEffect.resurrectNew,
    SpellEffect.sanctuary, SpellEffect.summonObjectSlot1, SpellEffect.summonObjectSlot2, SpellEffect.summonObjectSlot3,
    SpellEffect.summonObjectSlot4, SpellEffect.inebriate, SpellEffect.sendTaxi, SpellEffect.summonDemon];

/// What a player's cast does not do yet, though a creature's does (a warlock's Inferno summons by its own script; a
/// skill step comes with the learning of a spell).
private enum SpellEffect[] notDoneByPlayers = [SpellEffect.summonDemon, SpellEffect.skillStep];

/// Whether a cast of `kind` does `effect` (the NPC sweep names what is not done by this).
bool doneBy(UnitKind kind, const ref SpellInfo spell, size_t i) pure nothrow @nogc @safe
{
    import dmangos.world.spellselection : namedGameObjectShape;

    const effect = spell.effect[i];
    if (effect == SpellEffect.activateObject)
        return kind != UnitKind.none && namedGameObjectShape(spell, i) != ImplicitTarget.none;
    if (effect > SpellEffect.max || undoneByAny[effect])
        return false;
    final switch (kind)
    {
    case UnitKind.none: return false;
    case UnitKind.player: return !undoneByPlayers[effect];
    case UnitKind.creature: return doneByCreatures[effect];
    }
}

/// The two lists as tables by effect, made at compile time.
private immutable bool[SpellEffect.max + 1] undoneByAny = table(notDoneByAny), doneByCreatures = table(creaturesDo),
    undoneByPlayers = table(notDoneByPlayers);

private bool[SpellEffect.max + 1] table(const SpellEffect[] effects) pure nothrow @safe
{
    bool[SpellEffect.max + 1] t;
    foreach (e; effects)
        t[e] = true;
    return t;
}

/// An effect a cast of `caster`'s kind does not do yet: said once per effect and kind.
private void notDone(ref Caster caster, const(SpellInfo)* spell, size_t i)
{
    import dmangos.log : info;

    static bool[SpellEffect][UnitKind.max + 1] told;
    const effect = spell.effect[i];
    if (effect in told[caster.kind])
        return;
    told[caster.kind][effect] = true;
    info!"spell effect %s (%s, of spell %s) is not done by a %s's cast yet"(effect, cast(uint) effect, spell.id,
        caster.kind == UnitKind.player ? "player" : "creature");
}

/**
 * Effect `i` of `c`'s spell, cast by `caster`, on `target` (a guid: a unit, or the caster, or a game object the
 * cast was aimed at), which it reached: what it does.
 */
void applyEffect(ref Caster caster, const(SpellInfo)* spell, size_t i, ulong target, ref SpellCast c, uint bounce = 0)
{
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.updatefields;

    const effect = spell.effect[i];
    if (!doneBy(caster.kind, *spell, i) && effect != SpellEffect.none)
        return notDone(caster, spell, i);
    auto map = caster.map;
    auto context = caster.context;
    // An effect the target is immune to (a stun on a boss, beside the damage it still takes) does nothing.
    if (target != caster.guid)
        if (auto other = map.unit(target))
        {
            enum uint noImmunities = 0x20000000; // SPELL_ATTR_NO_IMMUNITIES
            const immune = other.fighter.immune;
            if (immune.any && !(spell.attributes & noImmunities) && immune.toEffect(effect,
                    spell.casting.effectMechanic[i], spell.casting.applyAuraName[i]))
                return;
        }
    auto p = caster.character; // a player's cast: what is its own
    auto ai = caster.ai;       // a creature's
    if (p !is null)
        p.effectCustom = c.custom;
    scope (exit)
        if (p !is null)
            p.effectCustom = typeof(p.effectCustom).init;
    const value = p !is null ? p.effectAmount(spell, i)
        : c.custom.has(i) ? c.custom.values[i] : ai.effectAmount(spell, i);
    final switch (effect) // every effect decided: done, or listed as not done below
    {
    case SpellEffect.schoolDamage: // SPELL_EFFECT_SCHOOL_DAMAGE
    {
        import dmangos.world.spelldamage : mayHurt, spellDamage, SpellBounce, SpellDamage;
        import dmangos.world.spellmods : SpellModOp;

        auto victim = map.unit(target);
        if (!victim)
            break;
        // A player's at a creature or an enemy; a creature's at whatever its targets are, itself too (Quiet Suicide).
        // ... and one a script casts for a player at the player's friends (`SpellRule.harmsFriendsAround`).
        const atFriends = c.triggered && c.custom.has(i) && victim.kind == UnitKind.player && target != caster.guid
            && context !is null && context.scripts.rule(spell.id).harmsFriendsAround;
        if (!atFriends && !mayHurt(caster, victim))
            break;
        // (its modifiers, `SPELLMOD_DAMAGE`, on the damage with the spell power)
        auto damage = p !is null ? p.classSchoolDamage(spell, i, target, value) : value;
        if (p is null) // a creature's: its spell's script may set the amount (`EffectDamage`: Thundercrash)
            damage = ai.effectDamageScript(spell, i, target, damage);
        spellDamage(caster, spell, victim, damage > 0 ? damage : 0, spell.casting.school,
            SpellDamage(true, SpellModOp.damage, bounce: SpellBounce(spell.casting.dmgMultiplier[i], bounce)));
        break;
    }
    case SpellEffect.activateObject:
        if (context !is null && map !is null)
            context.activateNamedGameObject(caster.unit, spell, i, target, c.gameObjectOrigin, c.triggered);
        break;
    case SpellEffect.dummy, SpellEffect.scriptEffect: // SPELL_EFFECT_DUMMY, SPELL_EFFECT_SCRIPT_EFFECT: the spell's script, then its database script
    {
        import dmangos.world.dbscripts : DbScriptType;

        if (p !is null)
        {
            if (p.classDummyEffect(spell, i, target, value, c.castItemEntry) || p.spellEffectScript(spell, i, target, value))
                break;
            context.startScript(DbScriptType.spell, spell.id, map, caster.guid, target ? target : c.targets.gameObject);
        }
        else
        {
            if (spell.id == 26524 && caster.creature.spawn.entry == 15348)
            {
                auto victim = map.unit(target);
                if (victim.kind == UnitKind.player && c.once(i))
                    context.placeKurinnaxxTrap(map, victim.position);
                break;
            }
            ai.spellEffectScript(spell, i, target, value);
            if (map.creatureAt(target) !is null && context.namedCreatureRouting(spell) == i)
                context.startScript(DbScriptType.spell, spell.id, map, caster.guid, target);
        }
        break;
    }
    case SpellEffect.summonWild: // SPELL_EFFECT_SUMMON_WILD: creatures of its entry, at the destination or near the caster
        if (p !is null)
        {
            import dmangos.world.creature : TempSpawnType;
            import dmangos.world.spellcast : duration, TargetFlags;

            const entry = cast(uint) spell.miscValue[i];
            if (!entry)
                break;
            const ms = p.modDuration(spell, duration(*spell, context.client, caster.level));
            const count = value > 0 ? value : 1;
            foreach (n; 0 .. count)
            {
                Position at; // all zeros: near the caster
                if ((c.targets.mask & TargetFlags.destLocation) && n == 0)
                    at = Position(c.targets.dest[0], c.targets.dest[1], c.targets.dest[2], caster.position.orientation);
                context.summonCreature(map, entry, at, ms > 0 ? TempSpawnType.timedOrDead : TempSpawnType.dead,
                    ms > 0 ? ms : 0, caster.guid);
            }
        }
        else if (c.once(i)) // once for the effect, whatever its targets
            ai.summonBySpell(spell, i, value, c.targets);
        break;
    case SpellEffect.persistentAreaAura: // SPELL_EFFECT_PERSISTENT_AREA_AURA: a spot that hurts who stands in it, made once a cast
        if (!c.once(i))
            break;
        if (p !is null)
            p.makePersistentArea(spell, i, c.targets, value);
        else
            ai.makePersistentArea(spell, i, c.targets, value);
        break;
    case SpellEffect.transDoor: // SPELL_EFFECT_TRANS_DOOR: an object the spell puts down (a fishing bobber, a ritual's portal)
        if (p is null) // a creature's: the object by it
        {
            import dmangos.world.spellsummons : summonWildObject;

            if (c.once(i))
                summonWildObject(caster, spell, i, c.targets);
        }
        else if (p.isRitualPortal(cast(uint) spell.miscValue[i] in context.data.gameObjectTemplates))
            p.openRitualPortal(spell, i); // `dmangos.world.rituals`
        else if (p.isFishingBobber(cast(uint) spell.miscValue[i] in context.data.gameObjectTemplates))
            p.castBobber(spell, i);
        else
            p.transmitObject(spell, i, c.targets); // a mage's portal, a Lightwell
        break;
    case SpellEffect.sendEvent: // SPELL_EFFECT_SEND_EVENT: the event's script, the caster its source and a game object its target
        if (p !is null)
            if (auto copy = p.currentBattleground())
            {
                import dmangos.world.alterac : AlteracRules;
                if (auto rules = cast(AlteracRules) copy.rules)
                    if (rules.plantBeacon(copy, p, spell.id))
                        break;
            }
        if (p !is null)
            context.scriptedEvent(cast(uint) spell.miscValue[i], map, caster.guid, c.targets.gameObject);
        else if (c.once(i))
            context.scriptedEvent(cast(uint) spell.miscValue[i], map, caster.guid, target == caster.guid ? 0 : target);
        break;
    case SpellEffect.duel: // SPELL_EFFECT_DUEL
        p.startDuel(target);
        break;
    case SpellEffect.tamecreature: // SPELL_EFFECT_TAMECREATURE
        p.tameCreature(spell, target ? target : c.targets.unit);
        break;
    case SpellEffect.summonPet: // SPELL_EFFECT_SUMMON_PET
        if (p !is null)
            p.summonPetEffect(spell, i);
        else if (c.once(i)) // a creature's (a cultist's imp): beside it, fighting its victim (`EffectSummonPet`)
            ai.summonBySpell(spell, i, 1);
        break;
    case SpellEffect.dismissPet: // SPELL_EFFECT_DISMISS_PET
        p.dismissPetEffect();
        break;
    case SpellEffect.summonDeadPet: // SPELL_EFFECT_SUMMON_DEAD_PET
        p.reviveDeadPet(value);
        break;
    case SpellEffect.instantKill: // SPELL_EFFECT_INSTAKILL
        if (p !is null)
            p.instakill(spell, target);
        else if (auto other = map.unit(target))
            if (other.alive)
            {
                other.spellHitBy(caster.guid, other.health);
                if (!other.alive)
                    ai.killedBySpell(target);
            }
        break;
    case SpellEffect.learnSpell: // SPELL_EFFECT_LEARN_SPELL: the pet (a teaching spell aimed at it), or the target player, learns
    {
        const learned = spell.triggerSpell[i];
        if (p !is null && spell.implicitTargetA[i] == ImplicitTarget.unitCasterPet)
            p.teachPet(learned);
        else if (learned)
        {
            // A creature's teaches the player it is aimed at (CMaNGOS's `EffectLearnSpell`: `unitTarget`'s).
            auto other = map.unit(target);
            auto who = p !is null ? p : other.kind == UnitKind.player ? other.session : null;
            if (who !is null)
                who.learn(learned);
        }
        break;
    }
    case SpellEffect.learnPetSpell: // SPELL_EFFECT_LEARN_PET_SPELL
        p.teachPet(spell.triggerSpell[i]);
        break;
    case SpellEffect.summonTotem, SpellEffect.summonTotemSlot1, SpellEffect.summonTotemSlot2, SpellEffect.summonTotemSlot3, SpellEffect.summonTotemSlot4: // SPELL_EFFECT_SUMMON_TOTEM, _SLOT1 .. _SLOT4 (fire, earth, water, air)
        if (p !is null)
            p.summonTotem(spell, i, value);
        else if (c.once(i))
            ai.summonTotem(spell, i, value);
        break;
    case SpellEffect.selfResurrect: // SPELL_EFFECT_SELF_RESURRECT
        p.selfResurrect(spell, i, value);
        break;
    case SpellEffect.resurrect, SpellEffect.resurrectNew: // SPELL_EFFECT_RESURRECT (a share of health and mana), SPELL_EFFECT_RESURRECT_NEW (amounts)
        if (p !is null)
            p.resurrectEffect(spell, i, target, value, c);
        else // a creature's at a dead player (Mandokir's chained spirits): offered to come back beside the creature
            if (auto who = cast(typeof(p)) context.onlinePlayer(target))
                who.resurrectedByCreature(spell, i, value, map.id, caster.position, caster.guid);
        break;
    case SpellEffect.dispel: // SPELL_EFFECT_DISPEL
    {
        import dmangos.world.spellauras : dispel;

        dispel(caster, spell, i, target == 0 || target == caster.guid ? caster.unit : map.unit(target), value);
        break;
    }
    case SpellEffect.pickpocket: // SPELL_EFFECT_PICKPOCKET
        p.pickPocket(target);
        break;
    case SpellEffect.skinning: // SPELL_EFFECT_SKINNING
        p.skinCreature(target);
        break;
    case SpellEffect.openLock, SpellEffect.openLockItem: // SPELL_EFFECT_OPEN_LOCK, _OPEN_LOCK_ITEM: a game object's lock, or an item's
        if (p is null) // a creature opens none (`EffectOpenLock`: "No Player Caster")
            break;
        if (c.targets.gameObject)
            p.openLock(spell, i, c.targets.gameObject, c.castItemEntry);
        else if (c.targets.item)
            p.openItemLock(spell, i, c.targets.item, c.castItemEntry);
        break;
    case SpellEffect.questComplete: // SPELL_EFFECT_QUEST_COMPLETE: the target player's quest of the misc value (`AreaExploredOrEventHappens`)
    {
        auto who = p !is null && target == caster.guid ? p : cast(typeof(p)) context.onlinePlayer(target);
        if (who !is null && who.player !is null && spell.miscValue[i] > 0)
            who.areaExploredOrEventHappens(cast(uint) spell.miscValue[i]);
        break;
    }
    case SpellEffect.disenchant: // SPELL_EFFECT_DISENCHANT
        p.disenchantItem(spell, c.targets.item);
        break;
    case SpellEffect.interruptCast: // SPELL_EFFECT_INTERRUPT_CAST: the target's cast ends, and its school is locked out for the interrupt's time
    {
        import dmangos.world.spellcast : duration;

        const lockMs = duration(*spell, context.client, caster.level);
        if (p !is null)
        {
            if (auto creature = cast(Creature) map.findObject(target))
                creature.ai.interruptedBySpell(lockMs);
            else if (auto other = p.enemyPlayer(target))
                other.castInterruptedBy(caster.guid, lockMs);
        }
        else if (target != caster.guid)
            if (auto other = map.unit(target))
                other.castInterruptedBy(caster.guid, lockMs);
        break;
    }
    case SpellEffect.weaponDamageNoschool: // SPELL_EFFECT_WEAPON_DAMAGE_NOSCHOOL
    case SpellEffect.weaponDamage: // SPELL_EFFECT_WEAPON_DAMAGE
    case SpellEffect.normalizedWeaponDmg: // SPELL_EFFECT_NORMALIZED_WEAPON_DMG
    case SpellEffect.weaponPercentDamage: // SPELL_EFFECT_WEAPON_PERCENT_DAMAGE
        if (p !is null)
        {
            if (auto victim = map.unit(target)) // a creature or a player (a duel, world PvP)
                p.weaponSpellDamage(spell, i, victim, value);
        }
        else if (auto d = target in c.weaponRolls)
            ai.weaponSpellDamage(spell, i, target, *d, value);
        break;
    case SpellEffect.heal: // SPELL_EFFECT_HEAL
    {
        import dmangos.world.spelldamage : spellHeal, SpellBounce, SpellHeal;
        import dmangos.world.spellmods : SpellModOp;

        auto recipient = map.unit(target);
        const healed = spellHeal(caster, spell, recipient, caster.spellMod(SpellModOp.damage, spell, value),
            SpellHeal(bounce: SpellBounce(spell.casting.dmgMultiplier[i], bounce)));
        if (healed && p !is null && recipient.kind == UnitKind.player && target == c.targets.unit)
            recipient.session.outsideQuestAid(caster.guid);
        break;
    }
    case SpellEffect.summonCritter: // SPELL_EFFECT_SUMMON_CRITTER: a companion; the same again sends it away
        p.summonCompanion(spell, i);
        break;
    case SpellEffect.addComboPoints: // SPELL_EFFECT_ADD_COMBO_POINTS: Sinister Strike, Claw: a player's only
        // (CMaNGOS's `EffectAddComboPoints`: none for any other caster)
        if (p !is null && target != caster.guid)
            p.addComboPoints(target, value);
        break;
    case SpellEffect.skinPlayerCorpse: // SPELL_EFFECT_SKIN_PLAYER_CORPSE: Remove Insignia, a dead enemy's
        p.removeInsigniaEffect(c.targets);
        break;
    case SpellEffect.addFarsight: // SPELL_EFFECT_ADD_FARSIGHT: Far Sight, Eagle Eye: a spot to see from
        p.makeFarSightSpot(spell, i, c.targets);
        break;
    case SpellEffect.energize: // SPELL_EFFECT_ENERGIZE
    {
        import dmangos.world.spelldamage : energize;

        energize(caster, spell, i, map.unit(target), value);
        break;
    }
    case SpellEffect.reputation: // SPELL_EFFECT_REPUTATION: the faction of the misc value, by the value
        if (p !is null)
        {
            auto who = target == caster.guid ? p : cast(typeof(p)) context.onlinePlayer(target);
            if (who !is null && who.player !is null && spell.miscValue[i] > 0)
                who.modifyReputation(cast(uint) spell.miscValue[i], value);
        }
        else if (auto other = map.unit(target)) // a player it hits gains (or loses) standing
            if (other.session !is null && spell.miscValue[i] > 0)
                other.session.spellReputation(cast(uint) spell.miscValue[i], value);
        break;
    case SpellEffect.teleportUnits: // SPELL_EFFECT_TELEPORT_UNITS
    case SpellEffect.teleportUnitsFaceCaster:
    {
        import std.math : cos, sin, PI;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.spellcast : radius;
        import dmangos.world.terrain : invalidHeight;
        import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

        const facesCaster = effect == SpellEffect.teleportUnitsFaceCaster;
        if (!facesCaster && p !is null)
        {
            p.teleportUnits(spell, i, c);
            break;
        }
        auto who = map.unit(target);
        if (who.kind != UnitKind.player || (who.fields.get!UNIT_FIELD_FLAGS & UnitFlags.taxiFlight))
            break;
        const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
        if (a == ImplicitTarget.database || b == ImplicitTarget.database
            || (!facesCaster && spell.id in context.data.spellTargets))
        {
            context.teleportBySpell(target, spell.id);
            break;
        }

        auto at = caster.position;
        const front = a == ImplicitTarget.locationCasterFront || b == ImplicitTarget.locationCasterFront;
        const back = a == ImplicitTarget.locationCasterBack || b == ImplicitTarget.locationCasterBack;
        if (front || back)
        {
            const distance = (back ? -1 : 1) * radius(*spell, i, context.client);
            at.x += distance * cos(at.orientation);
            at.y += distance * sin(at.orientation);
            const floor = map.groundHeight(at.x, at.y, at.z + 2, false);
            if (floor > invalidHeight)
                at.z = floor;
        }
        else if (!facesCaster || (a != ImplicitTarget.locationCasterDest && b != ImplicitTarget.locationCasterDest))
            break;
        at.orientation = cast(float)((at.orientation + (back ? 0 : PI)) % (2 * PI));
        if (at.orientation < 0)
            at.orientation += 2 * PI;
        who.session.spellTeleport(map.id, at);
        break;
    }
    case SpellEffect.createItem: // SPELL_EFFECT_CREATE_ITEM: a player's for itself; a creature's for the player it is
        // aimed at (CMaNGOS's `DoCreateItem`: `unitTarget`'s)
        if (!spell.itemType[i])
            break;
        if (p !is null)
        {
            if (p.giveItem(spell.itemType[i], value > 0 ? value : 1, true, true, creator: p.player.guid)) // "You create"
                p.updateCraftSkill(spell.id); // made: a chance to learn from it
        }
        else if (auto other = map.unit(target))
            if (other.kind == UnitKind.player)
                other.session.giveItem(spell.itemType[i], value > 0 ? value : 1, true, true, creator: target);
        break;
    case SpellEffect.feedPet: // SPELL_EFFECT_FEED_PET
        p.feedPet(c.targets.item);
        break;
    case SpellEffect.enchantItem: // SPELL_EFFECT_ENCHANT_ITEM (at the trade window: the other's item)
        p.enchantTarget(c.targets, cast(uint) spell.miscValue[i], false, 0);
        p.updateCraftSkill(spell.id);
        break;
    case SpellEffect.enchantItemTemporary: // SPELL_EFFECT_ENCHANT_ITEM_TEMPORARY: a player's item; a creature's poison is nothing
        if (p !is null)
            p.enchantTarget(c.targets, cast(uint) spell.miscValue[i], true, value);
        break;
    case SpellEffect.portal: // SPELL_EFFECT_PORTAL: unused since 1.2 (CMaNGOS's `EffectUnused`)
    case SpellEffect.skillStep: // SPELL_EFFECT_SKILL_STEP: a creature's (Beast Tracking on itself) is nothing
        break;
    case SpellEffect.inebriate: // SPELL_EFFECT_INEBRIATE: the target player more drunk, 256 a point (`EffectInebriate`)
    {
        auto who = p !is null && target == caster.guid ? p : cast(typeof(p)) context.onlinePlayer(target);
        if (who !is null && who.player !is null && value > 0)
            who.player.setDrunk(who.player.drunk + value * 256);
        break;
    }
    case SpellEffect.sendTaxi: // SPELL_EFFECT_SEND_TAXI: the target player flies the misc value's taxi path, free
    {
        auto who = p !is null && target == caster.guid ? p : cast(typeof(p)) context.onlinePlayer(target);
        if (who !is null && who.player !is null && spell.miscValue[i] > 0)
            who.flyTaxiPath(cast(uint) spell.miscValue[i]);
        break;
    }
    case SpellEffect.summonDemon: // SPELL_EFFECT_SUMMON_DEMON: a creature's (Inferno): its demons at the destination
        if (c.once(i))
            ai.summonBySpell(spell, i, value, c.targets);
        break;
    case SpellEffect.triggerSpell: // SPELL_EFFECT_TRIGGER_SPELL
        if (const triggered = context.data.spells.spell(spell.triggerSpell[i]))
        {
            if (p !is null)
                p.castSpell(triggered, c.targets, true, 0);
            else
                caster.castTriggered(triggered, target);
        }
        break;
    case SpellEffect.applyAura: // SPELL_EFFECT_APPLY_AURA
        if (p !is null)
            p.applyAuraEffect(spell, i, target, c.auraEffects.get(target, 0));
        else
            ai.auraOn(spell, i, target, c.auraEffects.get(target, 0), c.triggered);
        break;
    case SpellEffect.applyAreaAuraParty: // SPELL_EFFECT_APPLY_AREA_AURA_PARTY: on the caster, and from it on its party (`updateAreaAuras`)
    case SpellEffect.applyAreaAuraPet: // SPELL_EFFECT_APPLY_AREA_AURA_PET: on the caster, and from it on its pet (`updatePetAreaAuras`)
        if (p !is null)
            p.applyAuraEffect(spell, i, caster.guid, c.auraEffects.get(caster.guid, 0));
        else
            ai.auraOn(spell, i, caster.guid, c.auraEffects.get(caster.guid, 0));
        break;
    case SpellEffect.attack: // SPELL_EFFECT_ATTACK
        break;
    case SpellEffect.threat: // SPELL_EFFECT_THREAT: Distracting Shot, Cower, Feint
        if (p !is null)
            p.threatEffect(spell, i, target, value);
        else if (target != caster.guid) // a creature's on a creature (a pet's Torment, Suffering)
            if (auto other = map.creatureAt(target))
                if (other.alive && other.ai !is null)
                {
                    other.ai.addThreat(caster.unit, value);
                    map.wake(other.guid);
                }
        break;
    case SpellEffect.attackMe: // SPELL_EFFECT_ATTACK_ME: Growl, Taunt
    {
        import dmangos.world.spelldamage : logExecute;
        import dmangos.world.spellcast : executeTarget;
        auto victim = map.creatureAt(target);
        if (victim !is null && victim.alive && !victim.petOwner && victim.ai !is null
            && victim.ai.currentVictim != caster.guid)
        {
            victim.ai.taunt(caster.unit, map);
            logExecute(caster, spell, i, executeTarget(target));
        }
        break;
    }
    case SpellEffect.sanctuary: // SPELL_EFFECT_SANCTUARY: Vanish, Divine Intervention
        if (p !is null)
            p.sanctuaryEffect(spell, i, target);
        else if (auto who = cast(typeof(p)) context.onlinePlayer(target)) // Aspect of Arlokk's: the player forgotten
            who.sanctuaryByCreature(spell, i, caster.guid);
        break;
    case SpellEffect.charge: // SPELL_EFFECT_CHARGE: Charge, Intercept, Feral Charge; a creature's rush
        if (p !is null)
            p.chargeEffect(spell, target != caster.guid ? target : c.targets.unit);
        else if (target != caster.guid)
            ai.chargeAt(spell, map.unit(target));
        break;
    case SpellEffect.leap: // SPELL_EFFECT_LEAP: Blink
        if (p !is null)
            p.leapEffect(spell, i);
        else if (target == caster.guid)
        {
            import dmangos.script.api : Location;
            import dmangos.world.spellcast : radius;
            import dmangos.world.spellmoves : blinkEnd;

            const from = caster.position;
            const end = blinkEnd(map, from, radius(*spell, i, context.client));
            if (end != from)
                ai.hostTeleport(Location(end.x, end.y, end.z, end.orientation));
        }
        break;
    case SpellEffect.stuck: // SPELL_EFFECT_STUCK: the help menu's Stuck
        p.stuckEffect();
        break;
    case SpellEffect.powerBurn: // SPELL_EFFECT_POWER_BURN: Mana Burn
    {
        import dmangos.world.spelldamage : powerBurn;

        powerBurn(caster, spell, i, map.unit(target), value);
        break;
    }
    case SpellEffect.powerDrain: // SPELL_EFFECT_POWER_DRAIN: Dark Pact, Drain Mana's kind at once
    {
        import dmangos.world.spelldamage : powerDrain;

        powerDrain(caster, spell, i, map.unit(target), value);
        break;
    }
    case SpellEffect.healthLeech: // SPELL_EFFECT_HEALTH_LEECH: Death Coil
    {
        import dmangos.world.spelldamage : healthLeech;

        healthLeech(caster, spell, i, map.unit(target), value);
        break;
    }
    case SpellEffect.healMaxHealth: // SPELL_EFFECT_HEAL_MAX_HEALTH: Lay on Hands
    {
        import dmangos.world.spelldamage : healMaxHealth;

        healMaxHealth(caster, spell, map.unit(target));
        break;
    }
    case SpellEffect.addExtraAttacks: // SPELL_EFFECT_ADD_EXTRA_ATTACKS: Sword Specialization, Reckoning, a creature's
        // Thrash: `value` more swings at its victim, at most five owed, at its next melee (CMaNGOS's
        // `EffectAddExtraAttacks`); the combat log's "gains 1 extra attack"
        if (target == caster.guid && caster.alive && value > 0)
        {
            import dmangos.world.spelldamage : logExecute;
            import dmangos.world.spellcast : executeTarget;

            ubyte* owed = p !is null ? &p.extraAttacks : &ai.extraAttacks;
            *owed = cast(ubyte)(*owed + value > 5 ? 5 : *owed + value);
            logExecute(caster, spell, i, executeTarget(target, cast(uint) value));
        }
        break;
    case SpellEffect.dispelMechanic: // SPELL_EFFECT_DISPEL_MECHANIC: Escape Artist
    {
        import dmangos.world.spellauras : dispelMechanic;

        dispelMechanic(caster, spell, i, target == caster.guid ? caster.unit : map.unit(target), value);
        break;
    }
    case SpellEffect.distract: // SPELL_EFFECT_DISTRACT: Distract
        p.distractEffect(spell, i, target, value, c.targets);
        break;
    case SpellEffect.summonObjectSlot1, SpellEffect.summonObjectSlot2, SpellEffect.summonObjectSlot3,
            SpellEffect.summonObjectSlot4: // SPELL_EFFECT_SUMMON_OBJECT_SLOT1 .. 4: the hunters' traps
        if (p is null)
        {
            import dmangos.world.spellsummons : summonCreatureTrap;

            if (c.once(i))
                summonCreatureTrap(caster, spell, i, c.targets);
        }
        else if (target == caster.guid)
            p.summonTrapEffect(spell, i, c.targets);
        break;
    case SpellEffect.detect: // SPELL_EFFECT_DETECT: Detect's marker; CMaNGOS does nothing with it either
        break;
    case SpellEffect.spawn: // SPELL_EFFECT_SPAWN: the caster's spawning in (its animation, the client's) is over: it
        // may be fought (CMaNGOS's `EffectSpawn`: Rookery Whelp Spawn-in Spell, Birth)
    {
        import dmangos.world.defines : UnitFlags;

        auto v = caster.fields;
        if (v.get!UNIT_FIELD_FLAGS & UnitFlags.spawning)
        {
            v.set!UNIT_FIELD_FLAGS(v.get!UNIT_FIELD_FLAGS & ~UnitFlags.spawning);
            caster.flush();
        }
        break;
    }
    case SpellEffect.summonGuardian, SpellEffect.summon, SpellEffect.summonObjectWild: // SPELL_EFFECT_SUMMON_GUARDIAN,
        // _SUMMON, _SUMMON_OBJECT_WILD (`dmangos.world.guardians`): once a cast, whatever its targets
        if (!c.once(i))
            break;
        if (effect == SpellEffect.summonObjectWild)
        {
            import dmangos.world.spellsummons : summonWildObject;

            summonWildObject(caster, spell, i, c.targets);
        }
        else if (p is null)
            ai.summonBySpell(spell, i, value, c.targets);
        else
            p.summonGuardianEffect(spell, i, value, c.targets, c.triggered, c.castItemEntry, effect == SpellEffect.summon);
        break;
    case SpellEffect.summonPossessed: // SPELL_EFFECT_SUMMON_POSSESSED: a creature the caster becomes (Eye of Kilrogg)
        if (c.once(i))
            p.summonPossessedEffect(spell, i);
        break;
    case SpellEffect.summonPlayer: // SPELL_EFFECT_SUMMON_PLAYER: the target asked to come (`dmangos.world.rituals`)
        if (c.once(i))
            p.summonPlayerEffect(c.targets.unit ? c.targets.unit : target);
        break;
    case SpellEffect.durabilityDamage, SpellEffect.durabilityDamagePct: // a player's gear worn (`dmangos.world.durability`)
    {
        auto other = target == caster.guid ? caster.unit : map.unit(target);
        if (other.kind == UnitKind.player)
            other.session.durabilityDamageEffect(spell, i, value, effect == SpellEffect.durabilityDamagePct, caster.guid);
        break;
    }
    case SpellEffect.knockBack: // SPELL_EFFECT_KNOCK_BACK: a player thrown from the caster
        if (target != caster.guid)
            if (auto other = map.unit(target))
                if (other.kind == UnitKind.player)
                    other.session.knockedBack(caster.position, spell.miscValue[i] / 10.0f, value / 10.0f);
        break;
    case SpellEffect.pullTowards:
    {
        import std.algorithm.comparison : max;
        import dmangos.world.updatefields : UNIT_FIELD_BOUNDINGRADIUS;

        auto other = map.unit(target);
        if (target != caster.guid && other.kind == UnitKind.player)
        {
            const contact = max(0, caster.fields.get!UNIT_FIELD_BOUNDINGRADIUS)
                + max(0, other.fields.get!UNIT_FIELD_BOUNDINGRADIUS);
            other.session.pulledToward(caster.position, contact, max(1, spell.miscValue[i]) * 0.1f);
        }
        break;
    }
    case SpellEffect.none:
        break;
    // Not done by any caster's cast: `doneBy` returned before the switch.
    static foreach (notDone; notDoneByAny)
    {
    case notDone:
        assert(0, "not done by any caster: `doneBy` returned before the switch");
    }
    }
}
