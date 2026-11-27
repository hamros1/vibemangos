/**
 * A creature's spells and script: the creature as a caster, and the script's side of its AI, mixed
 * into `dmangos.world.creatureai.CreatureAI`.
 *
 * A spell is cast at itself or at a player: refused while it casts another (unless the flags say
 * otherwise), out of range or mana, or on one that has its aura already when asked. A cast with a
 * cast time stops it where it is and keeps it from swinging until the spell goes off; a spell on
 * the next swing waits for the swing. Then, at its targets (the one chosen, itself, or the enemies
 * in its area or cone): school damage (less armor for physical; a magic spell may miss by the
 * level difference), weapon damage (a melee roll with the effect's bonus), an aura (a debuff on a
 * player, a buff on itself), a heal of itself, a triggered spell.
 *
 * The script (`dmangos.world.eventai`) calls back here for what its actions do: texts (said,
 * yelled, emoted, whispered), emotes, fleeing, calls for help, combat movement, ranged mode.
 */
module dmangos.world.creaturecasting;

import dmangos.world.spellids;
import dmangos.world.combat : MeleeDamage, MeleeHitOutcome, VictimState;
import dmangos.world.spellcast : isNextMeleeSwingSpell, SpellMissInfo;
import dmangos.world.spells : SpellInfo;

/// Arcane Missiles channels used by creature AI and creatures casting the player ranks.
package bool isArcaneMissilesChannel(const ref SpellInfo spell)
{
    import std.algorithm.comparison : among;

    return spell.id.among(5143, 5144, 5145, 8416, 8417, 10211, 10212, 15735, 15790, 22272, 25345)
        && spell.effect[0] == SpellEffect.applyAura && spell.implicitTargetA[0] == ImplicitTarget.caster
        && spell.casting.applyAuraName[0] == AuraType.periodicTriggerSpell && spell.casting.amplitude[0] > 0;
}

/// A next-swing spell with one weapon effect, aimed at one enemy or a chain of enemies.
package int nextWeaponSwingEffect(const ref SpellInfo spell)
{
    import std.algorithm.comparison : among;

    if (!isNextMeleeSwingSpell(spell))
        return -1;
    int weapon = -1;
    foreach (i, effect; spell.effect)
    {
        if (effect == SpellEffect.none)
            continue;
        if (weapon >= 0 || !effect.among(SpellEffect.weaponDamageNoschool, SpellEffect.weaponDamage,
                SpellEffect.weaponPercentDamage, SpellEffect.normalizedWeaponDmg)
            || spell.implicitTargetA[i] != ImplicitTarget.enemy
            || spell.casting.implicitTargetB[i] != ImplicitTarget.none)
            return -1;
        weapon = cast(int) i;
    }
    return weapon;
}

package SpellMissInfo weaponSpellMiss(const ref MeleeDamage hit)
{
    if (hit.targetState == VictimState.isImmune)
        return SpellMissInfo.immune;
    switch (hit.outcome)
    {
    case MeleeHitOutcome.miss: return SpellMissInfo.miss;
    case MeleeHitOutcome.dodge: return SpellMissInfo.dodge;
    case MeleeHitOutcome.parry: return SpellMissInfo.parry;
    case MeleeHitOutcome.evade: return SpellMissInfo.evade;
    default: return SpellMissInfo.none;
    }
}

/// A creature's rolled weapon damage, plus the effect's bonus or as a percentage of the roll.
package uint creatureWeaponSpellDamage(SpellEffect effect, uint damage, int value, uint level, uint armor)
{
    import dmangos.world.combat : armorReducedDamage;

    if (effect == SpellEffect.weaponPercentDamage)
        return cast(uint)(damage * (value > 0 ? value : 0) / 100.0f);
    return damage + (value > 0 ? cast(uint) armorReducedDamage(level, armor, value) : 0);
}

/// See the module documentation.
mixin template CreatureCasting()
{
    import dmangos.world.map : Map;
    import dmangos.world.spellids;
    import std.math : PI, sqrt;
    import std.random : uniform, uniform01;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.auras : makeAura;
    import dmangos.world.combat : AttackType, calculateMeleeDamage, hasInArc, MeleeDamage, MeleeHitOutcome;
    import dmangos.world.creaturecasting : creatureWeaponSpellDamage, isArcaneMissilesChannel, nextWeaponSwingEffect,
        weaponSpellMiss;
    import dmangos.world.eventai;
    import dmangos.world.motion : launch, stopMoving;
    import dmangos.world.opcodes : ChatType, Language, Opcode;
    import dmangos.world.queries : monsterChatMessage;
    import dmangos.world.relations : canAttack;
    import dmangos.world.spellcast : castTime, duration, effectValue, healLog, spellMissLog, isNextMeleeSwingSpell, nonMeleeDamageLog,
        powerCost, radius, range, spellGoPacket, spellStartPacket, SpellMissInfo, SpellTargets,
        TargetFlags, TargetResult, preventionPacify, preventionSilence;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.unit : combatRelations;
    import dmangos.world.updatefields;
    import dmangos.world.npcdata : BroadcastText;
    import dmangos.script.api : AuraRemoved, EntityRef, KilledUnit, SpellHit;
    import dmangos.world.context : WorldContext;

    private
    {
        Map world_;            // the map, while the AI acts
        EventAI script;                // its `creature_ai_scripts`; null if it has none
        WorldContext lore;
        const(SpellInfo)* casting_;    // the spell being cast
        ulong castTarget;
        int castTimer;                 // until it goes off
        bool castAuraMustBeAbsent;
        bool castAtSelectedChannelTarget;
        const(SpellInfo)* nextSwing;   // a spell on its next swing
        bool combatMovement_ = true;   // it chases its victim
        bool rangedModeSet;            // its script keeps it at a distance to cast
        bool rangedMode_;              // and it does now (not out of mana)
        float chaseDistance_ = 0;      // how far from its victim it keeps
        int fleeTimer;                 // running in fear, for so long yet
        bool critterFleeing;           // ... a critter's flight from its attacker: it gives up the fight after
        int despawnTimer;              // gone in so long (0: not)
        bool meleeEnabled = true;      // it swings at its victim
        imported!"dmangos.world.spellareas".PersistentArea[] persistentAreas_; // its spots of persistent area auras
        const(ubyte)[] groundHandoff_; // ground objects to install once the creature is on its new map
        ulong[] totems_;               // its totems (`dmangos.world.spellsummons`)
    }

    bool deathPrevention;              /// damage leaves it at 1 health

    /// What its casts and texts need of the world's data (every creature made in the world has it).
    void setLore(WorldContext lore)
    {
        this.lore = lore;
    }

    /// The creature runs `events` (from `data`) as its script.
    void setScript(const(EventAiEvent)[] events, const EventAiData data)
    {
        this.script = new EventAI(events, data);
    }

    package void saveEventAi(ref ByteWriter writer) const
    {
        const state = script is null ? null : script.saveState();
        writer.put(cast(uint) state.length);
        writer.putBytes(state);
    }

    package void loadEventAi(ref imported!"dmangos.bytes".ByteReader reader)
    {
        const state = reader.readBytes(reader.read!uint);
        if (script !is null && state.length)
            script.restoreState(state);
    }

    package void saveGroundHandoff(ref ByteWriter writer) const
    {
        import dmangos.world.spellareas : writeGroundAreas;

        ByteWriter ground;
        if (persistentAreas_.length)
            writeGroundAreas(persistentAreas_, ground);
        writer.put(cast(uint) ground.data.length);
        writer.putBytes(ground.data);
    }

    package void detachGroundHandoff()
    {
        import dmangos.world.spellareas : detachGroundAreas;

        if (auto map_ = world_)
            detachGroundAreas(map_, persistentAreas_);
    }

    package void loadGroundHandoff(ref imported!"dmangos.bytes".ByteReader reader)
    {
        groundHandoff_ = reader.readBytes(reader.read!uint);
    }

    package void saveCastHandoff(ref ByteWriter writer) const
    {
        foreach (lock; schoolLockMs)
            writer.put(lock);
        writer.put(casting_ is null ? 0u : casting_.id);
        if (casting_ !is null)
        {
            writer.put(castTarget);
            writer.put(castTimer);
            writer.put(castAuraMustBeAbsent);
            writer.put(castAtSelectedChannelTarget);
        }
    }

    package void loadCastHandoff(ref imported!"dmangos.bytes".ByteReader reader)
    {
        foreach (ref lock; schoolLockMs)
            lock = reader.read!int;
        if (const id = reader.read!uint)
        {
            casting_ = lore.spellInfo(id);
            castTarget = reader.read!ulong;
            castTimer = reader.read!int;
            castAuraMustBeAbsent = reader.read!bool;
            castAtSelectedChannelTarget = reader.read!bool;
        }
    }

    /// A player's spell hit it (its script hears of it).
    void spellHitBy(ulong caster, uint spell, uint schoolMask, Map world)
    {
        world_ = world;
        raiseScript(SpellHit(EntityRef(caster), spell, schoolMask));
        if (script is null)
            return;
        script.spellHit(this, caster, spell, schoolMask);
    }

    package void healedBy(uint spell, Map world)
    {
        import dmangos.script.api : CreatureHealed;

        if (behaviour && scripts_.handles!CreatureHealed(behaviour))
        {
            world_ = world;
            raiseScript(CreatureHealed(spell));
        }
    }

    /// Its aura of `spell` from `caster` went (`Creature.loseAura`): its script hears of it.
    void auraLost(ulong caster, uint spell, Map world)
    {
        world_ = world;
        // A charm's aura went: the charmer lets it go (`Unit::Uncharm`).
        if (me.petOwner == caster && caster)
            if (const info = lore.spellInfo(spell))
                foreach (i; 0 .. 3)
                {
                    const kind = info.casting.applyAuraName[i];
                    if (kind == AuraType.modCharm || kind == AuraType.modPossess || kind == AuraType.modPossessPet)
                        if (auto charmer = world.unit(caster))
                            if (charmer.kind == imported!"dmangos.world.unit".UnitKind.player)
                                charmer.session.endCharm();
                }
        raiseScript(AuraRemoved(EntityRef(caster), spell));
    }

    /// A player's text emote at it.
    void receivedEmote(ulong player, uint textEmote, Map world)
    {
        import dmangos.script.api : EmoteReceived;

        if (behaviour) // its script hears of it
        {
            world_ = world;
            raiseScript(EmoteReceived(EntityRef(player), textEmote));
        }
        if (script is null)
            return;
        script.receivedEmote(this, player, textEmote);
    }

    /// `.castself` on a creature: it casts `spell` at itself.
    void castFromCommand(const(SpellInfo)* spell, Map world)
    {
        world_ = world;
        castSpell(spell, me.guid, 0);
        world.wake(me.guid);
    }

    /// Whether it is casting a spell now.
    @property bool castingNow() const
    {
        return casting_ !is null || channelSpell !is null;
    }

    private const(SpellInfo)* channelSpell;
    private int channelTimer;
    private ulong namedChannelSequence;
    private ushort namedChannelPeer;
    private int missingChannelTarget;
    private int missilePulsesRemaining;

    package @property bool hasCreatureChannel() const
    {
        return channelSpell !is null;
    }

    package void saveCreatureChannel(ref ByteWriter writer) const
    {
        import dmangos.world.context : WorldContext;

        writer.put(namedChannelSequence);
        writer.put(channelTimer);
        writer.put(missilePulsesRemaining);
        const context = cast(const WorldContext) lore;
        writer.put(namedChannelPeer ? namedChannelPeer : context.nodeId);
    }

    private int visualRenewalMs;

    package void loadCreatureChannel(ref imported!"dmangos.bytes".ByteReader reader, int transit)
    {
        import std.algorithm.comparison : max;

        namedChannelSequence = reader.read!ulong;
        const timer = reader.read!int;
        // The named target's aura advances off-node. A missile channel's own aura transfers with its caster.
        channelTimer = namedChannelSequence && timer >= 0 ? max(0, timer - max(0, transit)) : timer;
        visualRenewalMs = 0;
        missilePulsesRemaining = reader.read!int;
        namedChannelPeer = reader.read!ushort;
        channelSpell = lore.spellInfo(me.values.get!UNIT_CHANNEL_SPELL);
    }

    /// Restore spells that need this caster installed on its new map.
    package void resumeSpellHandoff(imported!"dmangos.world.map".Map map_)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.spellareas : readGroundAreas;

        world_ = map_;
        if (groundHandoff_.length)
        {
            auto reader = ByteReader(groundHandoff_);
            groundHandoff_ = null;
            auto caster = spellCaster();
            persistentAreas_ = readGroundAreas(caster, reader);
        }
        if (!hasCreatureChannel)
            return;
        map_.trackCreatureCombat(me, inCombat);
        if (!namedChannelSequence)
            return; // Arcane Missiles launches from its restored periodic aura.
        namedChannelPeer = currentChannelPeer(map_, me.values.get!UNIT_FIELD_CHANNEL_OBJECT);
        map_.holdCasterReplica(me.guid, namedChannelPeer,
            cast(uint) imported!"std.algorithm.comparison".max(channelTimer, 0) + 5_000, true);
    }

    private ushort currentChannelPeer(imported!"dmangos.world.map".Map map_, ulong target)
    {
        import dmangos.world.replication : Replica;

        if (map_.creatureAt(target) !is null)
            return 0;
        if (auto copy = cast(Replica) map_.findObject(target))
            return copy.owner;
        return namedChannelPeer;
    }

    private bool beginCreatureChannel(const(SpellInfo)* spell, UnitRef target, bool named)
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.spellcast : duration;
        import dmangos.world.spelldamage : namedVisualRenewalMs, permanentNamedCreatureVisual;

        auto caster = spellCaster();
        const ms = caster.modDuration(spell, duration(*spell, lore.clientData, caster.level));
        if ((ms <= 0 && !(ms < 0 && named && permanentNamedCreatureVisual(spell.id)))
            || !world_.inLineOfSight(me.position, target.position))
            return false;
        if (!me.spline.finalized)
            stopMoving(me, world_);
        channelSpell = spell;
        channelTimer = ms;
        namedChannelSequence = named ? lore.nextGameplaySequence() : 0;
        namedChannelPeer = target.replica is null ? 0 : target.replica.owner;
        missingChannelTarget = 0;
        visualRenewalMs = namedVisualRenewalMs;
        missilePulsesRemaining = named ? 0 : ms / spell.casting.amplitude[0];
        me.values.set!UNIT_CHANNEL_SPELL(spell.id);
        me.values.set!UNIT_FIELD_CHANNEL_OBJECT(target.combatGuid);
        world_.flushCreature(me);
        world_.wake(me.guid);
        if (auto map_ = cast(imported!"dmangos.world.map".Map) world_)
            map_.trackCreatureCombat(me, inCombat);
        return true;
    }

    package void finishCreatureChannel(bool cancelled)
    {
        import dmangos.cluster.protocol : AreaDamage;
        import dmangos.world.context : WorldContext;
        import dmangos.world.spellcast : spellFailurePacket, SpellCastResult;

        auto spell = channelSpell;
        if (spell is null)
            return;
        channelSpell = null;
        channelTimer = 0;
        missilePulsesRemaining = 0;
        const channelToken = namedChannelSequence;
        namedChannelSequence = 0;
        const guid = me.values.get!UNIT_FIELD_CHANNEL_OBJECT;
        me.values.set!UNIT_CHANNEL_SPELL(0);
        me.values.set!UNIT_FIELD_CHANNEL_OBJECT(0UL);
        if (world_ is null)
            return;
        if (auto map_ = world_)
            map_.trackCreatureCombat(me, inCombat);
        if (cancelled)
        {
            if (!channelToken)
            {
                if (auto aura = me.auras.find(spell.id, me.guid))
                    if (aura.duration > 0) // an expiring aura is removed by the tick that found it
                        me.loseAura(aura, world_);
            }
            else if (auto target = world_.creatureAt(guid))
            {
                if (auto aura = target.auras.find(spell.id, me.guid))
                    if (aura.channelToken == channelToken)
                    {
                        target.loseAura(aura, world_);
                        world_.flushCreature(target);
                    }
            }
            else if (auto map_ = world_)
                if (const peer = currentChannelPeer(map_, guid))
                    if (auto context = lore)
                        context.remoteSpells.sendReplicaSpell(map_, peer, spell,
                            AreaDamage(caster: me.guid, target: guid, spell: spell.id, map: map_.id,
                                instance: map_.instanceId, creatureCast: true, namedCreature: true,
                                channelled: true, channelUpdate: true, channelToken: channelToken));
            world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_FAILURE,
                spellFailurePacket(me.guid, spell.id, SpellCastResult.interrupted));
        }
        world_.flushCreature(me);
        if (!cancelled && channelToken)
            if (auto context = lore)
                if (auto map = world_)
                    context.remoteSpells.completeNamedChannel(map, map.unitOf(me), guid, spell, channelToken);
    }

    package void namedCreatureChannelRejected(ulong sequence)
    {
        if (sequence && sequence == namedChannelSequence)
            finishCreatureChannel(true);
    }

    private void updateCreatureChannel(int diff)
    {
        import dmangos.world.spelldamage : permanentNamedCreatureVisual;

        const spell = channelSpell;
        if (spell is null)
            return;
        auto target = spellTarget(me.values.get!UNIT_FIELD_CHANNEL_OBJECT);
        const permanent = namedChannelSequence && permanentNamedCreatureVisual(spell.id);
        if (!permanent)
            channelTimer -= diff;
        if (!target)
        {
            if ((missingChannelTarget += diff) >= 1000 || (!permanent && channelTimer <= 0))
                finishCreatureChannel(true);
            return;
        }
        missingChannelTarget = 0;
        if (!canMaintainCreatureChannel(spell, target, namedChannelSequence != 0)
            || (!namedChannelSequence && channelTimer > 0 && me.auras.find(spell.id, me.guid) is null))
            finishCreatureChannel(true);
        else if (!permanent && channelTimer <= 0)
            finishCreatureChannel(false);
        else if (permanent)
        {
            const newPeer = target.replica is null ? 0 : target.replica.owner;
            if ((visualRenewalMs -= diff) <= 0 || newPeer != namedChannelPeer)
                renewCreatureVisual(spell, target, newPeer);
        }
        else if (namedChannelSequence)
        {
            const ushort peer = target.replica is null ? 0 : target.replica.owner;
            if (peer && peer != namedChannelPeer)
                if (auto map = world_)
                    map.holdCasterReplica(me.guid, peer, cast(uint) channelTimer + 5000, true);
            namedChannelPeer = peer;
        }
    }

    private void renewCreatureVisual(const(SpellInfo)* spell, UnitRef target, ushort peer)
    {
        import dmangos.cluster.protocol : AreaDamage;
        import dmangos.world.context : WorldContext;
        import dmangos.world.spelldamage : namedVisualLifetimeMs, namedVisualRenewalMs;

        visualRenewalMs = namedVisualRenewalMs;
        namedChannelPeer = peer;
        if (peer)
        {
            if (auto context = lore)
                context.remoteSpells.sendReplicaSpell(target.map, peer, spell,
                    AreaDamage(caster: me.guid, target: target.combatGuid, spell: spell.id, map: target.map.id,
                        instance: target.map.instanceId, creatureCast: true, namedCreature: true, channelled: true,
                        channelUpdate: true, channelToken: namedChannelSequence, auraMs: namedVisualLifetimeMs));
        }
        else if (auto aura = target.auraSet.find(spell.id, me.guid))
        {
            if (aura.channelToken == namedChannelSequence)
                aura.duration = namedVisualLifetimeMs;
        }
        else
            finishCreatureChannel(true);
    }

    private bool canMaintainCreatureChannel(const(SpellInfo)* spell, UnitRef target, bool named)
    {
        import dmangos.world.spelldamage : creatureTargetInRange;
        import dmangos.world.spellselection : namedCreatureRange;

        const at = target.position, from = me.position;
        if (!target.alive || (!me.spline.finalized && (spell.casting.channelInterruptFlags & 0x08))
            || !world_.inLineOfSight(from, at))
            return false;
        if (!named)
            return isMissileTarget(target) && creatureTargetInRange(spell, me.fighter, target.fighter, lore.clientData);
        const reach = namedCreatureRange(*spell, lore.clientData) + me.fighter.combatReach + target.fighter.combatReach;
        return (at.x - from.x) ^^ 2 + (at.y - from.y) ^^ 2 + (at.z - from.z) ^^ 2 <= reach ^^ 2;
    }

    private bool isMissileTarget(UnitRef target)
    {
        return target && target.alive && target.combatGuid != me.guid
            && canAttack(relating, target.combatRelations(me.client), me.client);
    }

    /// A tick of the caster's Arcane Missiles aura uses the original channel target.
    package void arcaneMissilesTick(const(SpellInfo)* spell, size_t effect)
    {
        if (spell != channelSpell || namedChannelSequence || effect != 0 || missilePulsesRemaining <= 0)
            return;
        --missilePulsesRemaining;
        if (auto target = spellTarget(me.values.get!UNIT_FIELD_CHANNEL_OBJECT))
        {
            if (!canMaintainCreatureChannel(spell, target, false))
                return finishCreatureChannel(true);
            if (const pulse = lore.spellInfo(spell.triggerSpell[effect]))
                castSpell(pulse, target.combatGuid, castTriggered);
        }
    }

    /// Whether its script wants ticks out of combat (timers, or its spawn events still to run).
    private @property bool scriptWantsTicks()
    {
        return script !is null && script.wantsTicks;
    }

    // -----------------------------------------------------------------------
    // Casting
    // -----------------------------------------------------------------------

    /// Why the last `castSpell` that could not did not (`SPELL_FAILED_*`, a pet's owner told it).
    imported!"dmangos.world.spellcast".SpellCastResult castRefusal;

    private size_t selectableNamedCreatureEffect(const(SpellInfo)* spell)
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.spelldamage : databaseSpellEffect, namedCreatureEffect;

        if (auto context = lore)
            return context.remoteSpells.namedCreatureRouting(spell);

        const effect = namedCreatureEffect(*spell);
        if (effect != noEffect && !databaseSpellEffect(spell.effect[effect])
            && lore.spellScriptTargets(spell.id).length && !lore.spellScript(spell.id))
            return effect;
        return noEffect;
    }

    /**
     * Casts `spell` at `target` (itself, or a player) as `flags`
     * (`castTriggered`, ...) allow; false if it could not (`castRefusal` says why).
     */
    import dmangos.world.classspells : CustomValues;

    /**
     * Its addon's auras (`Creature.addonAuras`), each put on itself as an aura, not cast: no cast, no channel (a
     * channelling visual would hold it busy for good), as CMaNGOS's `LoadCreatureAddon` adds them. One it has already
     * (brought by a handoff) is left.
     */
    package void castAddonAuras(Map world, const(uint)[] ids)
    {
        import dmangos.world.spellauras : applyAura;
        import dmangos.world.spellids : SpellEffect;

        if (lore is null || world is null)
            return;
        world_ = world;
        auto caster = spellCaster(world);
        foreach (id; ids)
            if (me.auras.find(id) is null)
                if (const spell = lore.spellInfo(id))
                    foreach (i; 0 .. 3)
                        if (spell.effect[i] == SpellEffect.applyAura)
                        {
                            applyAura(caster, spell, i, world.unitOf(me), 0);
                            break;
                        }
    }

    bool castSpell(const(SpellInfo)* spell, ulong target, uint flags, CustomValues custom = CustomValues.init)
    {
        return prepareCast(spell, target, flags, custom, false);
    }

    private bool prepareCast(const(SpellInfo)* spell, ulong target, uint flags, CustomValues custom,
        bool selectedChannelTarget)
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.spellcast : SpellCastResult;
        import dmangos.world.spelldamage : creatureAreaShape, creatureTargetInRange, isCreatureTargetEffect,
            namedCreatureShape;

        // Why it could not, for a pet's owner (`castRefusal`).
        bool refuse(SpellCastResult why)
        {
            castRefusal = why;
            return false;
        }

        // A dead creature may still cast (CMaNGOS refuses only dead players): EventAI's spells on its death.
        if (spell is null || lore is null || world_ is null)
            return refuse(SpellCastResult.error);
        const triggered = (flags & castTriggered) != 0;
        if (evadingHome && !triggered)
            return refuse(SpellCastResult.dontReport);
        if (!triggered && refusedByCrowdControl(spell))
            return refuse(SpellCastResult.dontReport);
        if (castingNow && !(flags & (castTriggered | castInterruptPrevious)))
            return refuse(SpellCastResult.spellInProgress);
        // Its school locked out: only for a spell silence stops (`WorldObject::IsSpellReady`).
        if (!triggered && spell.casting.preventionType == preventionSilence && spell.casting.school < schoolLockMs.length
                && schoolLockMs[spell.casting.school] > 0)
            return refuse(SpellCastResult.notReady);
        // `CAST_FORCE_TARGET_SELF`: the target casts it on itself (CMaNGOS's EventAI `DoCastSpellIfCan`: the
        // caster is the target), triggered: a Death Talon Captain's Mark of Detonation on a player marks the player.
        if ((flags & castForceTargetSelf) && target && target != me.guid)
        {
            import dmangos.world.unit : UnitKind;

            auto other = world_.unit(target);
            if (!other || !other.alive)
                return refuse(SpellCastResult.badTargets);
            if ((flags & castAuraNotPresent) && other.hasAuraOf(spell.id))
                return refuse(SpellCastResult.dontReport);
            if (other.kind == UnitKind.player)
            {
                other.session.castForcedOnSelf(spell.id);
                return true;
            }
            auto creature = world_.creatureAt(target);
            auto map = world_;
            if (creature is null || creature.ai is null || map is null)
                return refuse(SpellCastResult.badTargets);
            return creature.ai.castFor(map, spell.id, target, true) == ActionResult.ok
                || refuse(creature.ai.castRefusal);
        }
        const namedEffect = selectableNamedCreatureEffect(spell);
        auto context = lore;
        const namedObject = context !is null && context.remoteSpells.onlyNamedGameObjectEffects(spell);
        const channelEffect = (!triggered || imported!"dmangos.world.spelldamage".permanentNamedCreatureVisual(spell.id))
            && !me.meleeController && context !is null
            ? context.remoteSpells.namedCreatureChannel(spell) : noEffect;
        if (selectedChannelTarget && channelEffect == noEffect)
            return refuse(SpellCastResult.badTargets);
        const selectsTargets = namedObject || channelEffect != noEffect || (namedEffect != noEffect
            && (namedCreatureShape(*spell, namedEffect) != ImplicitTarget.unitScriptNearCaster
                || (context !is null && context.sendAreaDamage !is null)));
        if (selectsTargets && !selectedChannelTarget)
            target = me.guid; // the spell selects its targets at completion
        else if (target == 0)
            target = victim ? victim : me.guid;
        auto other = spellTarget(target);
        const missiles = !triggered && isArcaneMissilesChannel(*spell);
        if (missiles && !isMissileTarget(other))
            return refuse(SpellCastResult.badTargets);
        if (selectedChannelTarget && !validChannelTarget(spell, channelEffect, other, context))
            return refuse(SpellCastResult.badTargets);
        if (target != me.guid)
        {
            if (other)
            {
                // Only a resurrection is for the dead (Mandokir's chained spirits' Revive).
                if (!other.alive && !spell.hasEffect(SpellEffect.resurrect) && !spell.hasEffect(SpellEffect.resurrectNew))
                    return refuse(SpellCastResult.targetsDead);
                if (other.alive && (spell.hasEffect(SpellEffect.resurrect) || spell.hasEffect(SpellEffect.resurrectNew)))
                    return refuse(SpellCastResult.badTargets);
                if ((flags & castAuraNotPresent) && other.hasAuraOf(spell.id))
                    return refuse(SpellCastResult.dontReport);
                if (other.replica !is null && !selectedChannelTarget && !missiles)
                {
                    import std.algorithm.searching : any;
                    import std.range : iota;

                    if (isNextMeleeSwingSpell(*spell) && !triggered
                        ? nextWeaponSwingEffect(*spell) < 0
                        : !iota(spell.effect.length).any!(i => isCreatureTargetEffect(*spell, i)
                            || creatureAreaShape(*spell, i) != ImplicitTarget.none))
                        return refuse(SpellCastResult.badTargets);
                }
            }
            else if (auto friend = world_.creatureAt(target))
            {
                // A friend (to heal, to buff).
                if (!friend.alive)
                    return refuse(SpellCastResult.targetsDead);
                if ((flags & castAuraNotPresent) && friend.auras.find(spell.id) !is null)
                    return refuse(SpellCastResult.dontReport);
            }
            else
                return refuse(SpellCastResult.badTargets);
        }
        else if ((flags & castAuraNotPresent) && me.auras.find(spell.id) !is null)
            return refuse(SpellCastResult.dontReport);
        if (!(flags & (castForceCast | castForceTargetSelf)) && !triggered)
        {
            if (!selectedChannelTarget && (other.replica !is null
                ? !creatureTargetInRange(spell, me.fighter, other.fighter, lore.clientData)
                    || !world_.inLineOfSight(me.position, other.position)
                : !inRangeFor(spell, target)))
                return refuse(SpellCastResult.outOfRange);
            if (paysMana(spell) && manaCost(spell) > me.values.get!UNIT_FIELD_POWER1)
            {
                // Out of mana, it comes in to fight (unless told not to).
                if (rangedMode_ && !(flags & castNoMeleeIfOom))
                    rangedMode_ = false;
                return refuse(SpellCastResult.noPower);
            }
        }
        // An aura's pulse (Unholy Aura's) goes off beside the cast under way (CMaNGOS's periodic trigger does).
        if (casting_ !is null && !(flags & castBesideCurrent))
            interruptCast();
        if (channelSpell !is null && (flags & castInterruptPrevious))
            finishCreatureChannel(true);
        if (!triggered && isNextMeleeSwingSpell(*spell))
        {
            nextSwing = spell;
            if (remoteMeleeMap(world_) !is null)
                restoringThreat = combatHandoffGraceMs;
            return true;
        }
        int time = triggered ? 0 : cast(int)(castTime(*spell, lore.clientData, me.values.get!UNIT_FIELD_LEVEL)
            * me.auras.castTimeFactor()); // Curse of Tongues
        if (time > 0)
            if (auto owner = petModOwner()) // a pet's: its owner's talents (Improved Firebolt)
            {
                import dmangos.world.spellmods : SpellModOp;

                time = owner.petSpellMod(SpellModOp.castingTime, spell, time, me);
            }
        if (time <= 0)
        {
            go(spell, target, !triggered, (flags & castAuraNotPresent) != 0, null, custom, selectedChannelTarget);
            return true;
        }
        casting_ = spell;
        castTarget = target;
        castTimer = time;
        castAuraMustBeAbsent = (flags & castAuraNotPresent) != 0;
        castAtSelectedChannelTarget = selectedChannelTarget;
        world_.wake(me.guid);
        if (!me.spline.finalized)
            stopMoving(me, world_);
        auto targets = targetsOf(target);
        world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_START, spellStartPacket(me.guid, spell.id, time, targets));
        return true;
    }

    /// The cast under way: it goes off when its time is up, or fails if its target is gone.
    private void updateCasting(int diff)
    {
        updateCreatureChannel(diff);
        foreach (ref t; schoolLockMs)
            if (t > 0)
                t -= diff;
        if (totems_.length)
            updateTotems();
        if (persistentAreas_.length)
        {
            import dmangos.world.spellareas : endPersistentAreas, updatePersistentAreas;

            auto caster = spellCaster();
            if (me.alive)
                updatePersistentAreas(caster, persistentAreas_, diff);
            else // its spots go with it
                endPersistentAreas(caster, persistentAreas_);
        }
        if (casting_ is null)
            return;
        if (castTarget != me.guid)
        {
            auto other = castAtSelectedChannelTarget ? spellTarget(castTarget) : combatTarget(world_, castTarget);
            auto friend = !other ? world_.creatureAt(castTarget) : null;
            if ((!other || !other.alive) && (friend is null || !friend.alive))
                return interruptCast();
        }
        castTimer -= diff;
        if (castTimer > 0)
            return;
        auto spell = casting_;
        casting_ = null;
        go(spell, castTarget, true, castAuraMustBeAbsent, null, CustomValues.init, castAtSelectedChannelTarget);
    }

    private int[7] schoolLockMs; /// each school's lockout left (an interrupt's), in milliseconds

    /**
     * What its state refuses (CMaNGOS's `CheckCasterAuras`): nothing while stunned, feared or disoriented, no
     * silence-type spell silenced, no pacify-type one pacified.
     */
    private bool refusedByCrowdControl(const(SpellInfo)* spell)
    {
        const flags = me.values.get!UNIT_FIELD_FLAGS;
        if (flags & (UnitFlags.stunned | UnitFlags.fleeing | UnitFlags.confused))
            return true;
        return ((flags & UnitFlags.silenced) && spell.casting.preventionType == preventionSilence)
            || ((flags & UnitFlags.pacified) && spell.casting.preventionType == preventionPacify);
    }

    /// Crowd control began (`silenceOnly`: a silence): the cast under way stops if it is one that stops.
    package void crowdControlBegan(bool silenceOnly)
    {
        auto current = casting_ is null ? channelSpell : casting_;
        if (current !is null && (!silenceOnly || current.casting.preventionType == preventionSilence))
            interruptCast();
    }

    /// An interrupt (Kick, Pummel, Counterspell) hit it: the cast stops if it may be interrupted
    /// (`Spell::IsInterruptible`), and its school is locked for `lockMs`.
    void interruptedBySpell(int lockMs)
    {
        import dmangos.world.spellcast : isInterruptible;

        auto current = casting_ is null ? channelSpell : casting_;
        if (current !is null && isInterruptible(*current))
            interruptCast(lockMs);
    }

    /// The cast stops (`SMSG_SPELL_FAILURE` around); an interrupt locks its school for `lockMs`.
    void interruptCast(int lockMs = 0)
    {
        import dmangos.world.spellcast : spellFailurePacket, SpellCastResult;

        auto current = casting_ is null ? channelSpell : casting_;
        if (current is null)
            return;
        if (lockMs > 0 && current.casting.school < schoolLockMs.length)
            schoolLockMs[current.casting.school] = lockMs;
        if (channelSpell !is null)
            return finishCreatureChannel(true);
        if (world_ !is null)
            world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_FAILURE,
                spellFailurePacket(me.guid, casting_.id, SpellCastResult.interrupted));
        casting_ = null;
    }

    /**
     * The player whose talents change its spells (CMaNGOS's `GetSpellModOwner`): a pet's owner, here and in the world;
     * null for any other creature (a totem's are its owner's too, by `effectMod`).
     */
    package imported!"dmangos.world.character".Character petModOwner()
    {
        if (!me.petOwner || world_ is null)
            return null;
        auto owner = world_.unit(me.petOwner);
        return owner.kind == imported!"dmangos.world.unit".UnitKind.player && owner.session.player !is null
            ? owner.session : null;
    }

    /**
     * Whether it pays `spell`'s cost: in mana, if it has a mana pool or is a pet. A creature without one (a warrior's
     * class: Lucifron, casting Shadow Shock in every account of his fight) casts its mana spells freely, and no
     * creature pays another power (vmangos's `Spell::CheckPower`: "Allow creatures to cast spells that require a
     * power type they don't have"; CMaNGOS refuses them, which leaves such bosses without their spells).
     */
    private bool paysMana(const(SpellInfo)* spell)
    {
        return spell.casting.powerType == 0 && (me.petOwner || me.values.get!UNIT_FIELD_MAXPOWER1 > 0);
    }

    /// The spell's mana cost for it.
    private int manaCost(const(SpellInfo)* spell)
    {
        import dmangos.world.creatureevents : levelScaledCost, spellAttrScalesWithCreatureLevel;

        const cost = powerCost(*spell, me.values.get!UNIT_FIELD_LEVEL, me.values.get!UNIT_FIELD_MAXPOWER1,
            me.values.get!UNIT_FIELD_MAXHEALTH, me.values.get!UNIT_FIELD_MAXPOWER1);
        return spell.attributes & spellAttrScalesWithCreatureLevel
            ? levelScaledCost(cost, spell.spellLevel, me.values.get!UNIT_FIELD_LEVEL) : cost;
    }

    private void spendSpellMana(const(SpellInfo)* spell)
    {
        if (!paysMana(spell))
            return;
        const cost = manaCost(spell), mana = me.values.get!UNIT_FIELD_POWER1;
        me.values.set!UNIT_FIELD_POWER1(cost >= mana ? 0 : mana - cost);
    }

    /// Within the spell's range of its target (and out of its minimum).
    private bool inRangeFor(const(SpellInfo)* spell, ulong target)
    {
        import dmangos.world.spelldamage : spellRangeResult;
        import dmangos.world.spellcast : SpellCastResult;

        if (target == me.guid)
            return true;
        const r = range(*spell, lore.clientData);
        // Its combat reach and the target's count towards the maximum, as a player's spell's (`spellRangeResult`).
        auto other = world_.unit(target);
        const reach = other ? other.fighter.combatReach : 1.5f;
        return spellRangeResult(*spell, r[0], r[1], distanceTo(target), me.fighter.combatReach, reach)
            == SpellCastResult.ok;
    }

    /// Yards to a target; infinity if it is not here.
    private float distanceTo(ulong target)
    {
        if (target == me.guid)
            return 0;
        Position p;
        if (auto other = world_.unit(target))
            p = other.position;
        else if (auto friend = world_.creatureAt(target))
            p = friend.position;
        else
            return float.infinity;
        const dx = p.x - me.position.x, dy = p.y - me.position.y, dz = p.z - me.position.z;
        return sqrt(dx * dx + dy * dy + dz * dz);
    }

    /// A spell can reach observed units even on a map with no remote melee link.
    private UnitRef spellTarget(ulong guid)
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.replication : Replica;

        if (auto visible = combatTarget(world_, guid))
            return visible;
        if (auto map = world_)
            if (auto context = lore)
                if (context.sendAreaDamage !is null)
                    if (auto copy = cast(Replica) map.findObject(guid))
                        if (copy.fields.type == TypeId.unit || copy.fields.type == TypeId.player)
                            return UnitRef.observed(copy, map);
        return UnitRef.init;
    }

    private SpellTargets targetsOf(ulong target)
    {
        SpellTargets t;
        if (target != me.guid)
        {
            t.mask = TargetFlags.unit;
            t.unit = target;
        }
        return t;
    }

    /// The implicit targets the creature resolves: the caster, enemies in an area or cone, or the target.
    private ulong[] targetsFor(const(SpellInfo)* spell, size_t i, ulong target)
    {
        import dmangos.world.spelldamage : namedCreatureShape;
        import dmangos.world.spellselection : excludedAreaTarget;

        const a = spell.implicitTargetA[i], b = spell.casting.implicitTargetB[i];
        if (spell.casting.chainTarget[i] > 1 && nextWeaponSwingEffect(*spell) == i)
            if (auto primary = world_.unit(target))
            {
                ulong[] targets;
                foreach (other; swingTargets(primary, spell.casting.chainTarget[i], false))
                    targets ~= other.combatGuid;
                return targets;
            }
        // Its enemies in an area: around its source or a destination, or around itself
        // (`TARGET_ENUM_UNITS_ENEMY_WITHIN_CASTER_RANGE`: Walking Bomb's explosion, CMaNGOS's `PUSH_SELF_CENTER`).
        // (Without a radius it names no area: Sand Storms' summons come as before.)
        const aroundItself = a == ImplicitTarget.enumUnitsEnemyWithinCasterRange && spell.casting.radiusIndex[i] != 0;
        const area = aroundItself || a == ImplicitTarget.enemiesAroundSource || a == ImplicitTarget.enemiesAroundDest
            || b == ImplicitTarget.enemiesAroundSource || b == ImplicitTarget.enemiesAroundDest;
        // A cone in front (`TARGET_UNIT_CONE_ENEMY`, `TARGET_ENUM_UNITS_ENEMY_IN_CONE_54`: Magmadar's Lava Breath).
        const cone = a == ImplicitTarget.enemiesInCone || a == ImplicitTarget.enumUnitsEnemyInCone54;
        import dmangos.world.spellselection : inSpellCone, spellCone;
        const coneDegrees = spellCone(lore is null ? null : lore.data, spell.id);
        if (area || cone)
        {
            // Around its target, unless it is at its own place: itself, its source, or the destination at itself
            // (`TARGET_LOCATION_CASTER_DEST`: a creature's cast at a unit gives no destination, so CMaNGOS sets it
            // at the caster).
            auto center = me.position;
            if (area && !aroundItself && a != ImplicitTarget.casterSource && a != ImplicitTarget.caster
                    && a != ImplicitTarget.locationCasterDest && target != me.guid)
                if (auto other = world_.unit(target))
                    center = other.position;
            import dmangos.world.combat : detects;
            const rule = lore is null ? typeof(lore.scripts.rule(0)).init : lore.scripts.rule(spell.id);
            // At its place in the database (`TARGET_LOCATION_DATABASE`, `spell_target_position`), on this map: Onyxia's
            // Deep Breath, each Breath of it at the next point across her lair; Frost Breath's spot below Sapphiron.
            if (a == ImplicitTarget.database && lore !is null)
                if (const fixed = spell.id in lore.data.spellTargets)
                    if (fixed.map == world_.id)
                        center = fixed.at;
            import dmangos.world.spellselection : mostAffected, unitsInArea;

            const r = radius(*spell, i, lore.clientData);
            // Its enemies there: the players it may attack, and of the creatures what the players control (their pets,
            // guardians and totems); a player's totem's (Fire Nova, Magma Totem) every creature its owner may fight.
            // Not one creature's area at another of the world's: an escort's fight (Isillien's Mana Burn at Taelan) is
            // scripted as it is.
            bool enemy(UnitRef u)
            {
                if (!u.alive)
                    return false;
                if (u.kind == UnitKind.creature)
                {
                    auto other = u.creature;
                    if (other is me || other.ai is null || !canAttack(relating, other.ai.relatingOf, me.client)
                        || !(me.totemOwner ? !other.totemOwner : other.ai.relatingOf.playerControlled))
                        return false;
                }
                else if (!canAttack(relating, u.relating, me.client))
                    return false;
                // Only what its centre sees (`SpellRule.areaSeenFromCenter`: Frost Breath and the ice blocks).
                const f = u.fighter;
                return !rule.areaSeenFromCenter || (world_.inLineOfSight(center, u.position)
                    && (!f.stealthed || detects(me.fighter, f, r)));
            }
            auto found = unitsInArea(world_, center, r, cone, coneDegrees, me.position,
                excludedAreaTarget(spell.id, i, target), &enemy);
            if (rule.areaOneAtRandom) // one of the players there (Sand Trap)
            {
                import std.algorithm.iteration : filter;
                import std.array : array;
                import std.random : uniform;

                auto players = found.filter!(g => world_.unit(g).kind == UnitKind.player).array;
                return players.length ? [players[uniform(0, players.length, world_.random)]] : null;
            }
            return mostAffected(world_, found, spell.casting.maxAffectedTargets, target, center);
        }
        // Its friends around it or the destination (`TARGET_ENUM_UNITS_FRIEND_AOE_AT_SRC_LOC`, `_DEST_LOC`: a Battle
        // Command, a Frenzied Command): every creature there that is not its enemy (as a creature's heal picks its
        // friends) and every player friendly to it, itself too, at most as many as the
        // spell says (CMaNGOS's `SPELL_TARGETS_ASSISTABLE`). A party of its own it has none: a party spell is its own.
        {
            import std.algorithm.comparison : among;
            import dmangos.world.relations : isEnemy, isFriend;
            import dmangos.world.spellselection : mostAffected;

            with (ImplicitTarget)
            {
                const friends = a.among(friendsAroundSource, friendsAroundDest) || b.among(friendsAroundSource,
                    friendsAroundDest);
                const atDest = a == friendsAroundDest || b == friendsAroundDest;
                const r = friends ? radius(*spell, i, lore.clientData) : 0;
                if (friends && r > 0)
                {
                    auto center = me.position;
                    if (atDest && a != locationCasterDest && target != me.guid) // (at itself: as for its enemies)
                        if (auto other = world_.unit(target))
                            center = other.position;
                    import dmangos.world.spellselection : unitsInArea;

                    bool friend(UnitRef u)
                    {
                        if (!u.alive)
                            return false;
                        if (u.kind == UnitKind.creature)
                            return u.creature is me
                                || (u.creature.ai !is null && !isEnemy(relating, u.creature.ai.relatingOf, me.client));
                        return isFriend(relating, u.relating, me.client);
                    }
                    auto found = unitsInArea(world_, center, r, false, 0, me.position, 0, &friend);
                    return mostAffected(world_, found, spell.casting.maxAffectedTargets, target, center);
                }
            }
        }
        // A script's area around the caster (`TARGET_ENUM_UNITS_SCRIPT_AOE_AT_SRC_LOC`): the living creatures there
        // `spell_script_target` names, or (it names none) every unit there, the caster too, which its script picks
        // from (CMaNGOS's `SPELL_TARGETS_ALL`). Without either, its target as before.
        const named = lore.spellScriptTargets(spell.id, i);
        if (!named.length && lore.spellScriptTargets(spell.id).length
            && namedCreatureShape(*spell, i) != ImplicitTarget.none)
            return null;
        if ((a == ImplicitTarget.enumUnitsScriptAoeAtSrcLoc || b == ImplicitTarget.enumUnitsScriptAoeAtSrcLoc)
            && (named.length || lore.spellScript(spell.id)))
        {
            import std.algorithm.searching : canFind;

            const r = radius(*spell, i, lore.clientData);
            ulong[] found;
            foreach (other; world_.creaturesNear(me.position, r))
                if (named.length ? other.alive && named.canFind(other.spawn.entry) : true)
                    found ~= other.guid;
            if (!named.length)
                foreach (other; world_.playersNear(me.position, r))
                    found ~= other.combatGuid;
            return found;
        }
        // A script's area at a destination this cast does not resolve
        // (`TARGET_ENUM_UNITS_SCRIPT_AOE_AT_DEST_LOC`, none named) reaches nobody, not its caster: Emi Shortfuse's
        // Explosion, an instant kill at the tunnel's `spell_target_position`, killed Emi herself.
        if (b == ImplicitTarget.enumUnitsScriptAoeAtDestLoc && !named.length)
            return null;
        // `TARGET_UNIT_SCRIPT_NEAR_CASTER` is the nearest living creature
        // `spell_script_target` names within the spell's range, as a player's cast has it: a Nightmare
        // Suppressor's Suppression reaches the Shade of Hakkar, not itself. None near, the caster as before.
        if (a == ImplicitTarget.unitScriptNearCaster && named.length)
        {
            import dmangos.world.spellselection : namedCreatureRange, nearestNamedCreature;

            if (auto other = nearestNamedCreature(world_, me.position, namedCreatureRange(*spell, lore.clientData),
                named, me.guid, false))
                return [other.combatGuid];
        }
        // Its master (`TARGET_UNIT_CASTER_MASTER`: a voidwalker's Sacrifice shields its warlock).
        if (a == ImplicitTarget.unitCasterMaster)
        {
            const master = me.petOwner ? me.petOwner : me.guardianOwner ? me.guardianOwner : me.totemOwner;
            return master ? [master] : null;
        }
        if (a == ImplicitTarget.caster || target == 0)
            return [me.guid];
        // A chain from its target (Chain Lightning; Chain Heal at the most hurt friends), as a player's chain jumps:
        // at its enemies, the players and what they control; at its friends, as its friends' areas take them.
        if (spell.casting.chainTarget[i] > 1 && target != me.guid
            && (a == ImplicitTarget.enemy || a == ImplicitTarget.unitFriendChainHeal))
        {
            import dmangos.world.relations : isEnemy, isFriend;
            import dmangos.world.spellselection : chainFrom;

            const hostile = a == ImplicitTarget.enemy;
            bool takes(UnitRef u)
            {
                if (!u.alive || u.combatGuid == me.guid)
                    return false;
                if (u.kind == UnitKind.creature)
                {
                    auto other = u.creature;
                    if (other.ai is null)
                        return false;
                    return hostile ? other.ai.relatingOf.playerControlled && canAttack(relating, other.ai.relatingOf,
                        me.client) : !isEnemy(relating, other.ai.relatingOf, me.client);
                }
                return hostile ? canAttack(relating, u.relating, me.client) : isFriend(relating, u.relating, me.client);
            }
            if (auto chain = chainFrom(world_, target, spell.casting.chainTarget[i] - 1, !hostile, &takes))
                return chain;
        }
        return [target];
    }

    /**
     * The spell goes off (`SMSG_SPELL_GO` with who it hit and missed) and its effects
     * happen to each target; its mana is spent.
     */
    private void go(const(SpellInfo)* spell, ulong target, bool takeMana, bool auraAbsent = false,
        ulong[] selectedWeaponTargets = null, CustomValues custom = CustomValues.init, bool selectedChannelTarget = false)
    {
        import dmangos.script.api : CreatureCastFinished;
        import dmangos.world.context : WorldContext;
        import dmangos.world.spellcast : spellFailurePacket, SpellCastResult;
        import dmangos.world.spelldamage : creatureTargetInRange, databaseSpellEffect, namedCreatureShape;
        import dmangos.world.spellselection : namedCreatureCenter, spellCone, namedCreatureRadius,
            namedCreatureEntry, namedCreaturesInArea, nearestNamedCreature;

        // EventAI may start a triggered cast from the death callback. A living caster killed
        // during one of its own effects still stops at that effect.
        const castOnDeath = !me.alive && !takeMana;
        auto context = lore;
        import dmangos.world.spelldamage : namedVisualLifetimeMs, permanentNamedCreatureVisual;

        const channelEffect = (takeMana || permanentNamedCreatureVisual(spell.id)) && !me.meleeController
            && selectedWeaponTargets is null && context !is null
            ? context.remoteSpells.namedCreatureChannel(spell) : noEffect;
        const missiles = takeMana && selectedWeaponTargets is null && isArcaneMissilesChannel(*spell);
        if (selectedChannelTarget && channelEffect == noEffect)
            return;
        UnitRef channelTarget;
        size_t firstChannelEffect = noEffect;
        uint channelExclusions;
        if (channelEffect != noEffect)
        {
            import dmangos.world.spellselection : namedCreatureRange;

            if (selectedChannelTarget)
            {
                channelTarget = spellTarget(target);
                if (!validChannelTarget(spell, channelEffect, channelTarget, context))
                {
                    world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_FAILURE,
                        spellFailurePacket(me.guid, spell.id, SpellCastResult.badTargets));
                    return;
                }
            }
            else
                channelTarget = nearestNamedCreature(world_, me.position, namedCreatureRange(*spell, lore.clientData),
                    context.remoteSpells.namedCreatureEntries(spell, channelEffect), me.guid, context.sendAreaDamage !is null);
            if (!channelTarget || !beginCreatureChannel(spell, channelTarget, true))
                return;
            const entry = namedCreatureEntry(channelTarget);
            firstChannelEffect = context.remoteSpells.namedCreatureEffectFor(spell, channelEffect, entry);
            channelExclusions = context.scriptTargetExclusions(spell.id, entry);
        }
        bool remotePrimary, sentArea;
        if (missiles)
        {
            auto other = spellTarget(target);
            if (!isMissileTarget(other)
                || !creatureTargetInRange(spell, me.fighter, other.fighter, lore.clientData)
                || !beginCreatureChannel(spell, other, false))
                return;
            // The periodic aura is on the caster. Each missile routes to the target separately.
            remotePrimary = other.replica !is null;
        }
        else if (selectedWeaponTargets is null && channelEffect == noEffect)
        if (auto other = spellTarget(target))
            if (other.replica !is null)
            {
                remotePrimary = true;
                bool sentTarget;
                if (context !is null && context.canWrite()
                    && (!takeMana || (creatureTargetInRange(spell, me.fighter, other.fighter, lore.clientData)
                        && world_.inLineOfSight(me.position, other.position))))
                {
                    sentTarget = sendCreatureTargetSpell(context, spell, other, !takeMana, auraAbsent);
                    sentArea = sendCreatureAreaEffects(spell, target, !takeMana, auraAbsent);
                }
                if (!sentTarget && !sentArea)
                {
                    if (takeMana)
                        world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_FAILURE,
                            spellFailurePacket(me.guid, spell.id, SpellCastResult.outOfRange));
                    return;
                }
            }
        if (!remotePrimary && selectedWeaponTargets is null)
            sentArea = sendCreatureAreaEffects(spell, target, !takeMana, auraAbsent);
        if (takeMana)
            spendSpellMana(spell);
        const level = me.values.get!UNIT_FIELD_LEVEL;
        // Who each effect reaches; a hostile target rolls once to be hit.
        ulong[][3] reached;
        bool[ulong] all;
        ulong[] inOrder; // each target once, in the order the effects found them (as the packet lists them)
        ulong[] remoteNamed;
        const namedEffect = selectedWeaponTargets is null ? selectableNamedCreatureEffect(spell) : noEffect;
        const namedEntries = context is null ? lore.spellScriptTargets(spell.id) : context.remoteSpells.namedCreatureEntries(spell, namedEffect);
        const objectOrigin = me.position;
        Position objectDestination;
        bool hasObjectDestination;
        const namedShape = namedEffect != noEffect ? namedCreatureShape(*spell, namedEffect) : ImplicitTarget.none;
        const namedRange = namedEffect != noEffect ? namedCreatureRadius(*spell, namedEffect, lore.clientData) : 0;
        const routeNamed = context !is null && context.sendAreaDamage !is null;
        const namedArea = namedShape != ImplicitTarget.none && namedShape != ImplicitTarget.unitScriptNearCaster;
        auto namedCenter = me.position;
        bool hasNamedCenter;
        UnitRef[] named;
        if (namedArea)
        {
            auto map = world_;
            const database = context is null ? null : spell.id in context.data.spellTargets;
            hasNamedCenter = namedCreatureCenter(*spell, namedEffect, lore.clientData, map is null ? me.spawn.map : map.id,
                me.position, database, null, namedCenter);
            if (hasNamedCenter)
                named = namedCreaturesInArea(world_, namedCenter, namedRange, namedEntries, routeNamed,
                    spell.casting.maxAffectedTargets, namedShape,
                    spellCone(context is null ? null : context.data, spell.id));
        }
        else if (namedShape == ImplicitTarget.unitScriptNearCaster)
            if (auto nearest = nearestNamedCreature(world_, me.position, namedRange, namedEntries, me.guid, routeNamed))
                named = [nearest];
        foreach (i; 0 .. 3)
            if (spell.effect[i])
            {
                const objectShape = selectedWeaponTargets is null && context !is null
                    ? context.remoteSpells.namedGameObjectRouting(spell, i) : ImplicitTarget.none;
                if (channelEffect != noEffect)
                {
                    import dmangos.world.spellselection : namedCreatureRange;

                    if (channelTarget.replica is null)
                    {
                        if (!(channelExclusions & (1u << i)))
                            reached[i] = [channelTarget.combatGuid];
                    }
                    else if (i == firstChannelEffect)
                    {
                        if (!sendCreatureTargetSpell(context, spell, channelTarget, false, auraAbsent, cast(int) i,
                                me.position, namedCreatureRange(*spell, lore.clientData), true, namedChannelSequence))
                            return finishCreatureChannel(true);
                        remoteNamed ~= channelTarget.combatGuid;
                    }
                }
                else if (objectShape != ImplicitTarget.none)
                {
                    if (auto map = world_)
                    {
                        Position center;
                        reached[i] = context.remoteSpells.namedGameObjectTargets(map, spell, i, objectShape, objectOrigin, center);
                        if (objectShape == ImplicitTarget.enumGameobjectsScriptAoeAtDestLoc && reached[i].length)
                        {
                            objectDestination = center;
                            hasObjectDestination = true;
                        }
                    }
                }
                else if (namedShape != ImplicitTarget.none && namedCreatureShape(*spell, i) == namedShape
                    && (named.length || namedArea || !namedEntries.length || databaseSpellEffect(spell.effect[namedEffect])))
                {
                    foreach (other; named)
                    {
                        const entry = namedCreatureEntry(other);
                        if (context !is null && (context.scriptTargetExclusions(spell.id, entry) & (1u << i)))
                            continue;
                        if (other.replica is null)
                            reached[i] ~= other.combatGuid;
                        else if (i == context.remoteSpells.namedCreatureEffectFor(spell, namedEffect, entry)
                            && sendCreatureTargetSpell(context, spell, other, !takeMana, auraAbsent,
                                cast(int) i, namedCenter, namedRange, true))
                            remoteNamed ~= other.combatGuid;
                    }
                }
                else
                    reached[i] = scriptPicked(spell, i, selectedWeaponTargets is null
                        ? targetsFor(spell, i, target) : selectedWeaponTargets);
                foreach (guid; reached[i])
                    if ((!remotePrimary || guid != target) && guid !in all)
                    {
                        all[guid] = true;
                        inOrder ~= guid;
                    }
            }
        TargetResult[] results;
        bool[ulong] attacked; // the targets it may attack (rolled)
        MeleeDamage[ulong] weaponRolls;
        bool weapon;
        foreach (i; 0 .. 3)
            weapon |= spell.effect[i] == SpellEffect.weaponDamageNoschool || spell.effect[i] == SpellEffect.weaponPercentDamage
                || spell.effect[i] == SpellEffect.weaponDamage || spell.effect[i] == SpellEffect.normalizedWeaponDmg;
        imported!"dmangos.world.unit".UnitRef[] reflectedBy, resistedBy;
        foreach (guid; inOrder)
        {
            auto miss = SpellMissInfo.none;
            if (guid != me.guid)
                if (auto other = world_.unit(guid))
                {
                    // Only what it may attack rolls (a heal on a friend never misses).
                    if (!canAttack(relating, other.relating, me.client))
                    {
                        results ~= TargetResult(guid, miss);
                        continue;
                    }
                    attacked[guid] = true;
                    const f = other.fighter;
                    if (weapon)
                    {
                        const d = calculateMeleeDamage(me.fighter, f, AttackType.mainHand, world_.random);
                        weaponRolls[guid] = d;
                        miss = weaponSpellMiss(d);
                    }
                    else
                    {
                        // As a player's spell is rolled (dmangos.world.spellcast.rollSpellHit), whoever the target.
                        import dmangos.world.spellcast : rollSpellHit;

                        auto caster = spellCaster();
                        miss = imported!"dmangos.world.spelleffects".rollHit(caster, spell, other);
                        // A player's ward may send it back (Fire Ward, Frost Ward); a whole resist is the player's
                        // to proc on (Magic Absorption).
                        if (other.kind == imported!"dmangos.world.unit".UnitKind.player)
                        {
                            if (miss == SpellMissInfo.none && other.session.reflectsSpell(spell))
                            {
                                miss = SpellMissInfo.reflect;
                                reflectedBy ~= other;
                            }
                            else if (miss == SpellMissInfo.resist)
                                resistedBy ~= other;
                        }
                    }
                }
            results ~= TargetResult(guid, miss);
        }
        foreach (other; reflectedBy)
            other.session.reflectBack(spell, me.guid);
        foreach (other; resistedBy)
            other.session.spellResistedBy(spell, world_.unit(me.guid));
        auto targets = targetsOf(target);
        if (namedShape == ImplicitTarget.enumUnitsScriptAoeAtDestLoc && hasNamedCenter)
        {
            targets.mask |= TargetFlags.destLocation;
            targets.dest = [namedCenter.x, namedCenter.y, namedCenter.z];
        }
        else if (hasObjectDestination)
        {
            targets.mask |= TargetFlags.destLocation;
            targets.dest = [objectDestination.x, objectDestination.y, objectDestination.z];
        }
        if (results.length || !remotePrimary || sentArea || remoteNamed.length)
        {
            auto displayed = results;
            foreach (guid; remoteNamed)
                displayed ~= TargetResult(guid, SpellMissInfo.none);
            world_.sendToObservers(me.guid, Opcode.SMSG_SPELL_GO, spellGoPacket(me.guid, spell.id, displayed, targets));
        }
        foreach (r; results) // the combat log's line for each miss, as for a player's spell
            if (r.miss != SpellMissInfo.none)
                world_.sendToObservers(me.guid, Opcode.SMSG_SPELLLOGMISS, spellMissLog(spell.id, me.guid, r.guid, r.miss));
        // Creatures hit by a creature's spell hear of it, `SpellHit`, as they do of
        // a player's; Whitemane's Scarlet Resurrection raising Mograine waits on it. Not the caster itself.
        foreach (r; results)
            if (r.miss == SpellMissInfo.none && r.guid != me.guid)
                if (auto hit = world_.creatureAt(r.guid))
                    if (hit.ai !is null)
                        hit.ai.spellHitBy(me.guid, spell.id, 1u << spell.casting.school, world_);
        bool[ulong] missed;
        foreach (r; results)
            if (r.miss != SpellMissInfo.none)
                missed[r.guid] = true;
            else if (r.guid in attacked) // a hostile spell landed: what that ends (`AURA_INTERRUPT_FLAG_HOSTILE_ACTION`)
                if (auto other = world_.unit(r.guid))
                    other.hostileSpellLanded();
        // The effects on each target they reached (`dmangos.world.spelleffects`, as a player's): each target's aura
        // has the aura effects at it.
        import dmangos.world.caster : Caster;
        import dmangos.world.spelleffects : applyEffect, SpellCast;

        SpellCast c;
        c.custom = custom;
        c.spell = spell;
        c.targets = targetsOf(target);
        c.triggered = !takeMana;
        c.active = true;
        c.weaponRolls = weaponRolls;
        c.gameObjectOrigin = objectOrigin;
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == SpellEffect.applyAreaAuraParty || spell.effect[i] == SpellEffect.applyAreaAuraPet)
                c.auraEffects[me.guid] |= cast(ubyte)(1 << i);
            else if (spell.effect[i] == SpellEffect.applyAura)
                foreach (guid; reached[i])
                    c.auraEffects[guid] |= cast(ubyte)(1 << i);
        }
        // A persistent area is made once, wherever its destination is, whoever stands there yet (CMaNGOS's
        // `EffectPersistentAA` at `m_destPos`): at the target's place for an area at the destination (a creature's
        // Blizzard at a player), else at the caster (Starfall around it).
        foreach (i; 0 .. 3)
            if (spell.effect[i] == SpellEffect.persistentAreaAura && !reached[i].length)
            {
                reached[i] = [me.guid];
                const a = spell.implicitTargetA[i];
                if (!(c.targets.mask & TargetFlags.destLocation) && target != me.guid
                    && a != ImplicitTarget.caster && a != ImplicitTarget.casterSource
                    && a != ImplicitTarget.locationCasterDest)
                    if (auto other = world_.unit(target))
                    {
                        c.targets.mask |= TargetFlags.destLocation;
                        c.targets.dest = [other.position.x, other.position.y, other.position.z];
                    }
            }
        // A destination at what its spell names nearest it (`TARGET_LOCATION_SCRIPT_NEAR_CASTER`, `spell_script_target`,
        // a creature before an object: CMaNGOS's `CheckScriptTargeting`), within its range: what it summons comes there
        // (Rockwing Gargoyles at their statue, a firework at its launcher). None named or near: before it, as before.
        foreach (i; 0 .. 3)
            if (spell.effect[i] && spell.implicitTargetA[i] == ImplicitTarget.locationScriptNearCaster
                    && !(c.targets.mask & TargetFlags.destLocation) && lore !is null)
            {
                import dmangos.world.spellselection : namedCreatureRange, nearestNamedCreature, nearestNamedGameObject;

                const reach = namedCreatureRange(*spell, lore.clientData);
                bool found;
                Position at;
                if (const entries = lore.spellScriptTargets(spell.id, i))
                    if (auto nearest = nearestNamedCreature(world_, me.position, reach, entries, me.guid, false))
                    {
                        at = nearest.position;
                        found = true;
                    }
                if (!found && context !is null)
                    if (const objects = spell.id in context.data.spellScriptObjects)
                        if (auto object = nearestNamedGameObject(world_, me.position, reach, i, *objects, false))
                        {
                            at = object.position;
                            found = true;
                        }
                if (found)
                {
                    c.targets.mask |= TargetFlags.destLocation;
                    c.targets.dest = [at.x, at.y, at.z];
                }
            }
        auto caster = spellCaster();
        foreach (i; 0 .. 3)
        {
            if (spell.effect[i] == SpellEffect.none)
                continue;
            foreach (guid; reached[i])
            {
                if (guid in missed || (remotePrimary && guid == target))
                    continue;
                if (!me.alive && !castOnDeath)
                    return;
                // A chain's later targets are struck less, each by the spell's multiplier (`SpellBounce`).
                import std.algorithm.searching : countUntil;

                const bounce = spell.casting.chainTarget[i] > 1 ? reached[i].countUntil(guid) : 0;
                applyEffect(caster, spell, i, guid, c, bounce > 0 ? cast(uint) bounce : 0);
            }
        }
        foreach (r; results) // its script hears whom it hit, once the effects are done (`SpellHitTarget`)
            if (r.miss == SpellMissInfo.none && script !is null && me.alive)
                script.spellHitTarget(this, r.guid, spell.id, 1u << spell.casting.school);
        if (channelTarget.creature !is null)
        {
            if (auto aura = channelTarget.creature.auras.find(spell.id, me.guid))
            {
                aura.channelToken = namedChannelSequence;
                if (permanentNamedCreatureVisual(spell.id))
                {
                    aura.detachedChannel = false;
                    aura.duration = aura.maxDuration = namedVisualLifetimeMs;
                }
            }
            else
                finishCreatureChannel(true);
        }
        if (me.alive && behaviour && scripts_.handles!CreatureCastFinished(behaviour))
            raiseScript(CreatureCastFinished(spell.id));
        world_.flushCreature(me);
    }

    private bool sendCreatureAreaEffects(const(SpellInfo)* spell, ulong target, bool triggered, bool auraAbsent)
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.replication : Replica;
        import dmangos.world.spelldamage : creatureAreaShape;
        import dmangos.world.spellselection : excludedAreaTarget;
        import dmangos.world.unit : combatRelations;

        auto context = lore;
        auto map = world_;
        if (context is null || map is null || context.sendAreaDamage is null)
            return false;
        bool sent;
        foreach (i; 0 .. spell.effect.length)
        {
            const shape = creatureAreaShape(*spell, i);
            if (shape == ImplicitTarget.none)
                continue;
            auto at = me.position;
            if (shape == ImplicitTarget.enemiesAroundDest)
                if (auto primary = spellTarget(target))
                    at = primary.position;
            const reach = radius(*spell, i, lore.clientData);
            if (!(reach > 0))
                continue;
            const excluded = excludedAreaTarget(spell.id, i, target);
            foreach (object; map.objectsNear(at, reach))
                if (auto copy = cast(Replica) object)
                    if (copy.fields.type == TypeId.player || copy.fields.type == TypeId.unit)
                    {
                        auto other = UnitRef.observed(copy, map);
                        if (other.combatGuid != excluded && other.alive
                            && canAttack(relating, other.combatRelations(me.client), me.client)
                            && (shape != ImplicitTarget.enemiesInCone || imported!"dmangos.world.spellselection".inSpellCone(
                                me.position, other.position, imported!"dmangos.world.spellselection".spellCone(
                                lore is null ? null : lore.data, spell.id))))
                            sent |= sendCreatureTargetSpell(context, spell, other, triggered, auraAbsent,
                                cast(int) i, at, reach);
                    }
        }
        return sent;
    }
    /// It as a spell's caster (`dmangos.world.caster`): its map is the world's only `Map`, its lore the
    /// `WorldContext`.
    package imported!"dmangos.world.caster".Caster spellCaster(Map world = null)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.context : WorldContext;

        if (world !is null)
            world_ = world;
        return Caster.of(me, world_, lore);
    }

    /**
     * The amount of effect `i` of `spell` as it casts it: rolled at its level (and scaled by it:
     * `SPELL_ATTR_SCALES_WITH_CREATURE_LEVEL`); a pet's or a totem's with its owner's talents (Improved Voidwalker on
     * Torment; their damage's, Improved Imp's and Call of Flame's, are `Caster.spellMod`'s in `spellDamage`).
     */
    package int effectAmount(const(SpellInfo)* spell, size_t i)
    {
        int value = levelScaled(spell, i, effectValue(*spell, i, me.values.get!UNIT_FIELD_LEVEL, uniform01(world_.random)));
        if (auto owner = petModOwner())
            value = owner.petEffectMod(spell, i, value, me);
        else if (me.totemOwner)
            if (auto owner = world_.unit(me.totemOwner))
                if (owner.session !is null && owner.session.player !is null)
                    value = owner.session.effectMod(spell, i, value);
        return value;
    }

    /// `SPELL_EFFECT_PERSISTENT_AREA_AURA` by it (`dmangos.world.spellareas.makePersistentArea`): a spot it keeps.
    package void makePersistentArea(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, int value)
    {
        static import dmangos.world.spellareas;

        auto caster = spellCaster();
        dmangos.world.spellareas.makePersistentArea(caster, persistentAreas_, spell, i, targets, value);
        world_.wake(me.guid);
    }

    /**
     * `SPELL_EFFECT_CHARGE` by it: it rushes to `victim` at the spell's speed (27 yards a second if it has none),
     * stopping at its reach and facing it, and fights it (CMaNGOS's `EffectCharge`).
     */
    package void chargeAt(const(SpellInfo)* spell, UnitRef victim)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.effecthandlers : baseChargeSpeed;
        import dmangos.world.spellmoves : chargeEnd;

        if (!victim || !victim.alive || !me.alive)
            return;
        const end = chargeEnd(world_, me.position, victim);
        const speed = spell.casting.speed > 0 ? spell.casting.speed : baseChargeSpeed;
        if ((end.x - me.position.x) ^^ 2 + (end.y - me.position.y) ^^ 2 >= 0.01f)
            launch(me, world_, [Vector3(me.position.x, me.position.y, me.position.z), Vector3(end.x, end.y, end.z)],
                false, end.orientation, true, speed);
        attackStart(victim, world_);
        world_.wake(me.guid);
    }

    /// `SPELL_EFFECT_SUMMON_TOTEM` by it (`dmangos.world.spellsummons.summonTotem`): a totem it keeps while it lasts.
    package void summonTotem(const(SpellInfo)* spell, size_t i, int value)
    {
        static import dmangos.world.spellsummons;

        auto caster = spellCaster();
        if (auto totem = dmangos.world.spellsummons.summonTotem(caster, spell, i, value, uint.max))
            totems_ ~= totem.guid;
        world_.wake(me.guid);
    }

    /// Its totems: those gone forgotten, its active ones casting at its enemies; they go when it dies.
    private void updateTotems()
    {
        import dmangos.world.spellsummons : totemsAct;

        Creature[] alive;
        ulong[] kept;
        foreach (guid; totems_)
            if (auto totem = world_.creatureAt(guid))
                if (totem.alive)
                {
                    alive ~= totem;
                    kept ~= guid;
                }
        totems_ = kept;
        if (!me.alive)
        {
            foreach (totem; alive)
                totem.ai.scriptDespawn(0);
            totems_ = null;
            return;
        }
        auto caster = spellCaster();
        totemsAct(caster, alive);
    }

    /// Its spell killed `guid` outright (an instant kill): its script hears of it.
    package void killedBySpell(ulong guid)
    {
        raiseScript(KilledUnit(EntityRef(guid)));
    }

    /// A weapon spell's damage to `guid`, its melee roll `d` made at the hit roll: the effect's bonus (or percentage).
    package void weaponSpellDamage(const(SpellInfo)* spell, size_t i, ulong guid, MeleeDamage d, int value)
    {
        auto target = world_.unit(guid);
        const damage = creatureWeaponSpellDamage(spell.effect[i], d.damage, value, me.values.get!UNIT_FIELD_LEVEL,
            target ? target.fighter.armor : 0);
        spellDamageTo(spell, guid, damage, -1);
        if (auto other = world_.unit(guid))
            weaponSpellProcs(spell, other, d.outcome, damage);
    }

    private void weaponSpellProcs(const(SpellInfo)* spell, UnitRef target, MeleeHitOutcome outcome, uint damage)
    {
        import dmangos.world.procs : procExOfSwing, ProcHit, spellProcFlags;

        procAuras(spellProcFlags(*spell, false, false), target, ProcHit(spell, procExOfSwing(outcome), damage, 0,
            damage != 0));
    }

    package void remoteWeaponSpellFinished(const(SpellInfo)* spell, UnitRef target, MeleeHitOutcome outcome,
        uint damage, bool killed)
    {
        remoteSpellDamageDealt(spell, target, false, damage, killed);
        weaponSpellProcs(spell, target, outcome, damage);
        if (script !is null && me.alive)
            script.spellHitTarget(this, target.combatGuid, spell.id, 1u << spell.casting.school);
    }


    /// A school's damage to `guid` (`dmangos.world.spelldamage.spellDamage`); -1: a weapon's, its roll made already.
    package void spellDamageTo(const(SpellInfo)* spell, ulong guid, uint damage, int school)
    {
        import dmangos.world.spelldamage : spellDamage, SpellDamage;

        auto other = world_.unit(guid);
        if (!other)
            return;
        auto caster = spellCaster();
        SpellDamage how;
        how.weaponRolled = school < 0;
        spellDamage(caster, spell, other, damage, school < 0 ? 0 : school, how);
    }

    /// Its spell hurt `victim` (`Caster.damageDealt`): a pet's procs (`dmangos.world.creatureprocs`), and its script
    /// hears of a kill.
    package void spellDamageDealt(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage)
    {
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;

        if (victim.alive)
            procAuras(spellProcFlags(*spell, false, false), victim, ProcHit(spell, crit ? ProcEx.criticalHit
                : ProcEx.normalHit, damage, 0, damage != 0));
        if (victim.alive)
            return;
        spellKilled(victim.combatGuid);
    }

    package void remoteSpellDamageDealt(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage, bool killed)
    {
        if (inCombat_ && damage)
            triggerCombatTimer();
        if (killed)
            spellKilled(victim.combatGuid);
        else if (victim.alive)
            spellDamageDealt(spell, victim, crit, damage);
    }

    package void remoteNamedSpellHit(ulong victim, const(SpellInfo)* spell)
    {
        if (script !is null && me.alive)
            script.spellHitTarget(this, victim, spell.id, 1u << spell.casting.school);
    }

    private void spellKilled(ulong guid)
    {
        if (script !is null)
            script.killed(this, guid);
        raiseScript(KilledUnit(EntityRef(guid)));
    }

    /// `SPELL_EFFECT_APPLY_AURA` by it at `guid` (`dmangos.world.spellauras.applyAura`).
    package void auraOn(const(SpellInfo)* spell, size_t i, ulong guid, ubyte effects = 0, bool detached = false)
    {
        import dmangos.world.spellauras : applyAura;

        auto caster = spellCaster();
        applyAura(caster, spell, i, guid == me.guid ? world_.unitOf(me) : world_.unit(guid), effects, detached);
    }

    /// `SPELL_EFFECT_HEAL` on itself or a friend.
    /**
     * `SPELL_EFFECT_SUMMON`, `_SUMMON_WILD`, `_SUMMON_GUARDIAN`: the creature of the effect's misc value (several for
     * a wild summon's value, at most five) beside the caster, for the spell's duration, fighting its victim. A spell
     * aimed at a place puts the first there: its destination, or its target's position (Kel'Thuzad's Shadow Fissure,
     * `TARGET_LOCATION_CASTER_TARGET_POSITION`). One no unit may touch (`UNIT_FLAG_NOT_SELECTABLE`: the fissure, which
     * erupts on an out-of-combat timer) does not fight.
     */
    package void summonBySpell(const(SpellInfo)* spell, size_t i, int value,
        const imported!"dmangos.world.spellcast".SpellTargets targets = imported!"dmangos.world.spellcast".SpellTargets.init)
    {
        import dmangos.world.spellcast : TargetFlags;
        import dmangos.world.spellids : ImplicitTarget;

        import std.math : cos, sin, PI;
        import dmangos.world.creature : TempSpawnType;
        import dmangos.world.spellcast : duration;

        const entry = cast(uint) spell.miscValue[i];
        if (entry == 0 || lore is null || world_ is null)
            return;
        // A demon (`SPELL_EFFECT_SUMMON_DEMON`, Inferno's Infernal): as many as its value, of the caster's level, for
        // an hour or until it dies (`EffectSummonDemon`).
        const demon = spell.effect[i] == SpellEffect.summonDemon;
        if (demon && value <= 0)
            return;
        const count = (spell.effect[i] == SpellEffect.summonWild || demon) && value > 1 ? (value > 5 ? 5 : value) : 1;
        const ms = demon ? 3_600_000 : duration(*spell, lore.clientData, me.values.get!UNIT_FIELD_LEVEL);
        auto victim = world_.unit(currentVictim);
        bool placed;
        Position place;
        if (targets.mask & TargetFlags.destLocation)
        {
            place = Position(targets.dest[0], targets.dest[1], targets.dest[2], me.position.orientation);
            placed = true;
        }
        else if (spell.implicitTargetA[i] == ImplicitTarget.locationCasterTargetPosition && targets.unit)
            if (auto aimed = world_.unit(targets.unit))
            {
                place = aimed.position;
                placed = true;
            }
        foreach (n; 0 .. count)
        {
            const angle = me.position.orientation + PI / 2 + n * 2 * PI / count;
            auto at = me.position;
            at.x += 3 * cos(angle);
            at.y += 3 * sin(angle);
            if (placed && n == 0)
                at = place;
            auto summoned = lore.summon(world_, entry, at, demon ? TempSpawnType.timedOrDead
                : ms > 0 ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, ms > 0 ? ms : 0, me.guid);
            if (summoned !is null && demon)
                summoned.values.set!UNIT_FIELD_LEVEL(me.values.get!UNIT_FIELD_LEVEL);
            if (summoned !is null && victim && !(summoned.values.get!UNIT_FIELD_FLAGS & UnitFlags.uninteractible))
                summoned.ai.attackStart(victim, world_);
        }
    }


    /// The spell on its next swing, instead of the swing (`true`): its weapon damage.
    private bool swingSpell(UnitRef target)
    {
        if (nextSwing is null)
            return false;
        auto spell = nextSwing;
        const effect = nextWeaponSwingEffect(*spell);
        if (effect >= 0)
            if (auto map = remoteMeleeMap(world_))
                return distributedWeaponSwing(spell, effect, target, map);
        if (target.replica !is null)
            return false;
        nextSwing = null;
        go(spell, target.combatGuid, true);
        return true;
    }

    private UnitRef[] swingTargets(UnitRef primary, uint cap, bool includeReplicas)
    {
        import std.algorithm.sorting : sort;
        import dmangos.world.combat : creatureSwingInReach;
        import dmangos.world.replication : Replica;
        import dmangos.world.spelldamage : spellJumpRadius;
        import dmangos.world.unit : UnitKind, combatRelations;

        if (cap <= 1)
            return [primary];
        const center = primary.position;
        const attacker = me.fighter;
        UnitRef[] nearby;
        void consider(UnitRef candidate)
        {
            if (!candidate.alive || candidate.combatGuid == me.guid || candidate.combatGuid == primary.combatGuid
                || candidate.untouchable || !canAttack(relating, candidate.combatRelations(me.client), me.client)
                || !creatureSwingInReach(attacker, candidate.fighter)
                || !world_.inLineOfSight(attacker.position, candidate.position)
                || (candidate.kind == UnitKind.player && candidate.session.transferring))
                return;
            nearby ~= candidate;
        }
        foreach (player; world_.playersNear(center, spellJumpRadius))
            consider(player);
        foreach (creature; world_.creaturesNear(center, spellJumpRadius))
            if (creature.ai !is null)
                consider(world_.unitOf(creature));
        if (includeReplicas)
            if (auto map = world_)
                foreach (object; map.objectsNear(center, spellJumpRadius))
                    if (auto replica = cast(Replica) object)
                        if (replica.fields.type == TypeId.player
                            || replica.fields.type == TypeId.unit && (me.meleeController || replica.meleeController))
                            consider(UnitRef.observed(replica, map));
        float distance(UnitRef other) { return moved(center, other.position); }
        nearby.sort!((a, b) => distance(a) < distance(b)
            || (distance(a) == distance(b) && a.combatGuid < b.combatGuid));
        if (nearby.length >= cap)
            nearby = nearby[0 .. cap - 1];
        return [primary] ~ nearby;
    }

    private bool distributedWeaponSwing(const(SpellInfo)* spell, size_t effect, UnitRef primary,
        imported!"dmangos.world.map".Map map)
    {
        import dmangos.world.spellmods : SpellModOp;

        if (primary.replica !is null && paysMana(spell) && manaCost(spell) > me.values.get!UNIT_FIELD_POWER1)
        {
            nextSwing = null;
            return false;
        }
        auto targets = swingTargets(primary, spell.casting.chainTarget[effect], true);
        auto caster = spellCaster();
        const threat = caster.spellMod(SpellModOp.threat, spell, 1.0f);
        ulong[] local;
        foreach (target; targets)
            if (target.replica is null)
                local ~= target.combatGuid;
        foreach (i, target; targets)
            if (target.replica !is null && !map.remoteCreatureSwing(me, target, spell.id,
                effectAmount(spell, effect), threat, i != 0 || local.length != 0) && i == 0)
            {
                attackTimer = 100;
                return true; // The primary request did not leave. Nothing else has been committed.
            }
        nextSwing = null;
        if (local.length)
            go(spell, primary.combatGuid, true, false, local);
        else
        {
            spendSpellMana(spell);
            world_.flushCreature(me);
        }
        return true;
    }

    // -----------------------------------------------------------------------
    // Fleeing
    // -----------------------------------------------------------------------

    /**
     * Feared (`SPELL_AURA_MOD_FEAR`) or disoriented (`MOD_CONFUSE`): walked by the aura, as CMaNGOS's fleeing and
     * confused movement generators do: feared, away from whoever feared it, about 10 yards at a time; disoriented,
     * a few yards any way. It neither fights nor casts meanwhile. As it ends, it stops where it is.
     */
    package void updateControlledWalk(bool feared)
    {
        import std.math : cos, sin, PI;

        controlledWalking = true;
        if (!me.spline.finalized)
            return;
        auto from = me.position;
        if (feared)
            foreach (aura; me.auras.list)
                if (aura.has(AuraType.modFear))
                    if (auto caster = world_.unit(aura.caster))
                    {
                        from = caster.position;
                        break;
                    }
        const angle = feared && (from.x != me.position.x || from.y != me.position.y)
            ? angleTo(from, me.position) + uniform(-0.6f, 0.6f, world_.random) : uniform(0.0f, 2 * PI, world_.random);
        const distance = feared ? 10.0f : uniform(3.0f, 6.0f, world_.random);
        const x = me.position.x + distance * cos(angle), y = me.position.y + distance * sin(angle);
        auto z = world_.groundHeight(x, y, me.position.z + 2, false);
        if (!(z > -100_000))
            z = me.position.z;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(x, y, z)];
        launch(me, world_, points, !feared, float.nan, true);
    }

    /// The fear or disorientation ended: it stops, and fights again.
    package void controlledWalkEnded()
    {
        if (!controlledWalking)
            return;
        controlledWalking = false;
        if (!me.spline.finalized)
            stopMoving(me, world_);
    }

    private bool controlledWalking; // walked by a fear or disorientation

    /// Running away at low health (`fleeTimer`), not by an aura.
    @property bool fleeingAtLowHealth() const
    {
        return fleeTimer > 0;
    }

    /// Running in fear from its victim: away, and again when it gets there; it does not fight meanwhile.
    private void updateFleeing(int diff)
    {
        fleeTimer -= diff;
        if (fleeTimer <= 0)
        {
            fleeTimer = 0;
            me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.fleeing);
            world_.flushCreature(me);
            if (!me.spline.finalized)
                stopMoving(me, world_);
            // A critter's flight ends its fight (`CreatureAI::TimedFleeingEnded`, `ORDER_CRITTER_FLEE`).
            if (critterFleeing)
            {
                critterFleeing = false;
                if (me.alive && inCombat_)
                    enterEvadeMode(world_);
            }
            return;
        }
        if (!me.spline.finalized)
            return;
        auto from = me.position;
        if (auto enemy = world_.unit(victim))
            from = enemy.position;
        // Away from the enemy, a little to one side or the other.
        const angle = angleTo(from, me.position) + uniform(-0.6f, 0.6f, world_.random);
        import std.math : cos, sin;

        const x = me.position.x + 12 * cos(angle), y = me.position.y + 12 * sin(angle);
        auto z = world_.groundHeight(x, y, me.position.z + 2, false);
        if (!(z > -100_000))
            z = me.position.z;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(x, y, z)];
        launch(me, world_, points, false, float.nan, true);
    }

    // -----------------------------------------------------------------------
    // `Scripted`: what the script's actions do
    // -----------------------------------------------------------------------

    /// See `Scripted`.
    uint healthPercent()
    {
        const maximum = me.values.get!UNIT_FIELD_MAXHEALTH;
        return maximum ? cast(uint)(ulong(me.values.get!UNIT_FIELD_HEALTH) * 100 / maximum) : 0;
    }

    /// ditto
    uint manaPercent()
    {
        const maximum = me.values.get!UNIT_FIELD_MAXPOWER1;
        return maximum ? cast(uint)(ulong(me.values.get!UNIT_FIELD_POWER1) * 100 / maximum) : 0;
    }

    /// ditto
    @property bool fighting()
    {
        return inCombat_;
    }

    /// ditto
    bool hasOwnAura(uint spell)
    {
        return me.auras.find(spell) !is null;
    }

    /// ditto
    bool victimCasting()
    {
        auto other = victim ? world_.unit(victim) : UnitRef.init;
        return other && other.castingSpell;
    }

    /// A wounded ally chosen by EventAI must remain an eligible recipient at cast time.
    private bool validChannelTarget(const(SpellInfo)* spell, size_t effect, UnitRef target,
        imported!"dmangos.world.context".WorldContext context)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.spellselection : namedCreatureEntry, namedCreatureRange;
        import dmangos.world.unit : combatRelations;

        if (!target.alive || target.combatGuid == me.guid || (target.creature is null
            && (target.replica is null || target.replica.fields.type != TypeId.unit)))
            return false;
        if (!context.remoteSpells.namedCreatureEntries(spell, effect).canFind(namedCreatureEntry(target))
            || isEnemy(relating, combatRelations(target, me.client), me.client))
            return false;
        const from = me.position, to = target.position;
        const reach = namedCreatureRange(*spell, lore.clientData);
        return (from.x - to.x) ^^ 2 + (from.y - to.y) ^^ 2 + (from.z - to.z) ^^ 2 <= reach ^^ 2
            && world_.inLineOfSight(from, to);
    }

    /// See `Scripted`. An event can use remote allies if every possible action can channel on them.
    ulong lowestHpFriendly(float radius, uint deficit, bool percent, scope const(EventAiAction)[] actions,
        out bool selectedChannelTarget)
    {
        import dmangos.world.context : WorldContext;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.replication : Replica;

        auto context = lore;
        const(SpellInfo)*[3] spells;
        size_t[3] effects;
        size_t count;
        if (context !is null && !me.meleeController && actions.length <= spells.length)
            foreach (ref action; actions)
            {
                if (action.type == ActionType.none)
                    continue;
                const spell = action.type == ActionType.castSpell && action.params[1] == EventTarget.eventSpecific
                    && !(action.params[2] & (castTriggered | castForceTargetSelf))
                    ? lore.spellInfo(action.params[0]) : null;
                const effect = spell is null ? noEffect : context.remoteSpells.namedCreatureChannel(spell);
                if (effect == noEffect)
                {
                    count = 0;
                    break;
                }
                spells[count] = spell;
                effects[count++] = effect;
            }
        selectedChannelTarget = count != 0;

        ulong best;
        uint mostMissing;
        void consider(UnitRef target, const ref imported!"dmangos.world.objects".UpdateValues fields)
        {
            const maximum = fields.get!UNIT_FIELD_MAXHEALTH, health = fields.get!UNIT_FIELD_HEALTH;
            if (!health || health >= maximum)
                return;
            const missing = maximum - health;
            const measure = percent ? cast(uint)(ulong(missing) * 100 / maximum) : missing;
            if (measure <= deficit || measure <= mostMissing)
                return;
            foreach (i; 0 .. count)
                if (!validChannelTarget(spells[i], effects[i], target, context))
                    return;
            mostMissing = measure;
            best = target.combatGuid;
        }
        foreach (other; world_.creaturesNear(me.position, radius))
        {
            if (!other.alive || other.ai is null || !other.ai.inCombat)
                continue;
            if (!count && other !is me && isEnemy(relating, other.ai.relating, me.client))
                continue;
            consider(world_.unitOf(other), other.values);
        }
        if (count && context.sendAreaDamage !is null)
            if (auto map = world_)
                foreach (object; map.objectsNear(me.position, radius))
                    if (auto copy = cast(Replica) object)
                        if (copy.fields.type == TypeId.unit && (copy.fields.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat))
                            consider(UnitRef.observed(copy, map), copy.fieldsOf());
        return best;
    }

    /// ditto
    void scriptSound(uint sound)
    {
        ByteWriter w;
        w.put(sound);
        world_.sendToObservers(me.guid, Opcode.SMSG_PLAY_SOUND, w.data);
    }

    /// ditto: on itself or another creature here.
    void scriptUnitFlags(ulong target, uint flags, bool set)
    {
        auto who = target == me.guid ? me : world_.creatureAt(target);
        if (who is null)
            return;
        const now = who.values.get!UNIT_FIELD_FLAGS;
        who.values.set!UNIT_FIELD_FLAGS(set ? now | flags : now & ~flags);
        world_.flushCreature(who);
    }

    /// ditto. Let swing again in a fight, it swings at its victim at once (CMaNGOS's `SetMeleeEnabled`): attacking the
    /// victim it already has would not start it again.
    void scriptMelee(bool on)
    {
        import dmangos.world.combat : attackStart;
        import dmangos.world.opcodes : Opcode;

        meleeEnabled = on;
        if (!on)
            meleeStop(world_);
        else if (inCombat_ && victim && !meleeAttacking && world_ !is null)
        {
            meleeAttacking = true;
            world_.sendToObservers(me.guid, Opcode.SMSG_ATTACKSTART, attackStart(me.guid, victim));
        }
    }

    /// ditto
    void scriptRemoveAura(ulong target, uint spell)
    {
        if (auto creature = target == me.guid ? me : world_.creatureAt(target))
        {
            if (auto aura = creature.auras.find(spell))
            {
                creature.loseAura(aura, world_);
                world_.flushCreature(creature);
            }
        }
        else if (auto other = world_.unit(target))
            other.auraRemovedBy(spell);
    }

    /// ditto
    void scriptDespawn(uint delay)
    {
        despawnTimer = delay ? delay : 1;
    }

    /// ditto
    void scriptDeathPrevention(bool on)
    {
        deathPrevention = on;
    }

    /// ditto
    void scriptRelay(int id, ulong target)
    {
        if (lore !is null && id != 0)
            lore.startRelay(id, world_, me.guid, target);
    }

    /// ditto: an entry's model (its first) or a model; neither: back to its own.
    void scriptMorph(uint entry, uint model)
    {
        const display = entry && lore !is null ? lore.displayOf(entry) : model;
        me.values.set!UNIT_FIELD_DISPLAYID(display ? display : me.values.get!UNIT_FIELD_NATIVEDISPLAYID);
        world_.flushCreature(me);
    }

    /// ditto: mounted on an entry's model (its first) or a model; neither: off its mount.
    void scriptMount(uint entry, uint model)
    {
        me.values.set!UNIT_FIELD_MOUNTDISPLAYID(entry && lore !is null ? lore.displayOf(entry) : model);
        world_.flushCreature(me);
    }

    /// ditto
    void scriptSheath(uint state)
    {
        me.values.setByte!UNIT_FIELD_BYTES_2(0, cast(ubyte) state);
        world_.flushCreature(me);
    }

    /// ditto: it dies as if killed by nobody (no one's kill).
    void scriptDie()
    {
        if (!me.alive)
            return;
        if (auto self = world_.unitOf(me))
            self.spellHitBy(0, me.values.get!UNIT_FIELD_HEALTH);
    }

    /// ditto: in a dungeon copy, every living player in it joins its fight.
    void scriptZoneCombatPulse()
    {
        if (!me.instanceId || !me.alive)
            return;
        foreach (p; world_.playersNear(me.position, 10_000))
            if (p.alive)
                attackedBy(p, world_);
    }

    /// ditto: its dungeon copy's script gets a signal of id `field` with `value` (the instance data).
    void scriptInstanceData(uint field, int value)
    {
        if (lore !is null && me.instanceId)
            lore.signalDungeon(me.instanceId, EntityRef(me.guid), field, value);
    }

    /// ditto: each percent of threat added (negative: taken off; -100: none left).
    void scriptThreatPercent(ulong target, int percent)
    {
        foreach (guid, ref amount; threat)
            if (target == 0 || guid == target)
            {
                amount += amount * percent / 100.0f;
                if (amount < 0)
                    amount = 0;
            }
    }

    /// ditto: only a creature's, and only its unit fields.
    void scriptUnitField(ulong target, uint field, uint value)
    {
        import dmangos.world.updatefields : OBJECT_END, UNIT_END;

        auto c = world_.creatureAt(target);
        if (c is null || field < OBJECT_END || field >= UNIT_END)
            return;
        c.values.setSlot(field, value);
        world_.flushCreature(c);
    }

    /// ditto
    void scriptWalk(uint type)
    {
        import dmangos.world.movement : MovementFlags;

        switch (type)
        {
        case 0:
            me.movement.flags |= MovementFlags.walkMode;
            break;
        case 1:
            me.movement.flags &= ~MovementFlags.walkMode;
            break;
        case 2, 3:
            chaseWalking = type == 2;
            break;
        default:
            break;
        }
    }

    /// ditto
    void scriptFace(ulong target, bool reset)
    {
        import std.math : atan2;
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : launch;

        float facing = me.spawn.orientation;
        if (!reset)
        {
            Position at;
            if (!world_.positionOf(target, at))
                return;
            facing = atan2(at.y - me.position.y, at.x - me.position.x);
        }
        const p = me.position;
        launch(me, world_, [Vector3(p.x, p.y, p.z), Vector3(p.x, p.y, p.z)], true, facing);
    }

    /// ditto
    void scriptImmobilized(bool on, bool combatOnly)
    {
        import dmangos.world.motion : stopMoving;

        me.scriptRooted = on;
        rootedForFight = on && combatOnly;
        if (on)
            stopMoving(me, world_);
    }

    /// ditto
    bool scriptUpdateTemplate(uint entry)
    {
        if (lore is null || !lore.changeEntry(me, entry))
            return false;
        world_.flushCreature(me);
        return true;
    }

    /// ditto: back to its template's faction with 0.
    void scriptFaction(uint faction)
    {
        const id = faction ? faction : me.template_.faction;
        me.factionTemplate = lore is null ? null : lore.clientData.factionTemplates.lookup(id);
        me.values.set!UNIT_FIELD_FACTIONTEMPLATE(id);
        world_.flushCreature(me);
    }

    /// ditto: for every player fighting it (`all`: those on its threat list), or one.
    void scriptQuestEvent(uint quest, ulong player, bool all)
    {
        if (!all)
        {
            if (auto other = world_.unit(player))
                other.questEventHappened(quest);
            return;
        }
        foreach (guid, _; threat)
            if (auto other = world_.unit(guid))
                if (other.alive)
                    other.questEventHappened(quest);
    }

    /// ditto
    void scriptKillCredit(uint entry, ulong player)
    {
        if (auto other = world_.unit(player))
            other.killCreditFrom(entry, me.guid);
    }

    /// ditto: summoned for a while out of combat, or until its corpse goes (`timedOutOfCombatOrDead`), or until
    /// out of combat at all (`timedOutOfCombat` with no time).
    bool scriptSummon(uint entry, ulong target, uint durationMs, uint spot)
    {
        import dmangos.world.creature : TempSpawnType;

        if (lore is null)
            return false;
        Position at;
        if (spot)
        {
            uint seconds;
            if (!lore.summonSpot(spot, at, seconds))
                return false;
            durationMs = seconds * 1000;
        }
        auto summoned = lore.summon(world_, entry, at,
            durationMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.timedOutOfCombat, durationMs, me.guid);
        if (summoned is null)
            return false;
        if (target)
            if (auto victim = world_.unit(target))
                summoned.ai.attackStart(victim, world_);
        return true;
    }

    /// ditto: to the creatures near that are not its enemies (itself left out).
    void scriptThrowAiEvent(uint type, float radius, ulong invoker)
    {
        foreach (other; world_.creaturesNear(me.position, radius))
            if (other !is me && other.alive && other.ai !is null && !isEnemy(relating, other.ai.relating, me.client))
                other.ai.aiEventFrom(type, me, invoker, world_);
    }

    /// Another creature's AI event, for its script.
    void aiEventFrom(uint type, Creature sender, ulong invoker, Map world)
    {
        if (script is null)
            return;
        world_ = world;
        script.aiEventReceived(this, type, sender.guid, sender.template_.entry, invoker);
    }

    /// ditto
    void scriptReactState(uint state)
    {
        if (state <= ReactState.max)
            react = cast(ReactState) state;
    }

    /// ditto
    uint victimHealthPercent()
    {
        auto other = victim ? world_.unit(victim) : UnitRef.init;
        return !other ? uint.max : other.healthPercent;
    }

    /// ditto
    float victimDistance()
    {
        return victim ? distanceTo(victim) : float.infinity;
    }

    /// ditto: by the target type, its threat list among the choices.
    ulong targetFor(int type, ulong invoker)
    {
        import std.algorithm.sorting : sort;

        switch (type)
        {
        case EventTarget.self:
            return me.guid;
        case EventTarget.hostile:
            return victim;
        case EventTarget.actionInvoker:
            return invoker;
        case EventTarget.hostileSecondAggro, EventTarget.hostileLastAggro, EventTarget.hostileRandom,
                EventTarget.hostileRandomNotTop, EventTarget.hostileRandomPlayer,
                EventTarget.hostileRandomNotTopPlayer:
        {
            ulong[] list = threat.keys;
            if (list.length == 0)
                return 0;
            list.sort!((a, b) => threat[a] > threat[b] || (threat[a] == threat[b] && a < b));
            switch (type)
            {
            case EventTarget.hostileSecondAggro:
                return list.length > 1 ? list[1] : 0;
            case EventTarget.hostileLastAggro:
                return list[$ - 1];
            case EventTarget.hostileRandom, EventTarget.hostileRandomPlayer:
                return list[uniform(0, list.length, world_.random)];
            default:
                return list.length > 1 ? list[uniform(1, list.length, world_.random)] : 0;
            }
        }
        default:
            return 0;
        }
    }

    /// ditto
    bool scriptCast(uint spell, ulong target, uint flags, bool selectedChannelTarget = false)
    {
        return prepareCast(lore is null ? null : lore.spellInfo(spell), target, flags, CustomValues.init,
            selectedChannelTarget);
    }

    /**
     * ditto: the text said, yelled or emoted around it (as far as each is heard),
     * or whispered to `target`; its emote with it.
     */
    void scriptText(uint id, ulong target)
    {
        const text = lore is null ? null : lore.broadcastText(id);
        if (text is null)
            return;
        speak(text, target);
    }

    /// `text` said, yelled or emoted as its type says (whispered to `target`).
    void speak(const(BroadcastText)* text, ulong target)
    {
        ChatType type;
        auto language = Language.LANG_UNIVERSAL;
        switch (text.chatType)
        {
        case 0:
            type = ChatType.CHAT_MSG_MONSTER_SAY;
            language = cast(Language) text.language;
            break;
        case 1, 6:
            type = ChatType.CHAT_MSG_MONSTER_YELL;
            break;
        case 2:
            type = ChatType.CHAT_MSG_MONSTER_EMOTE;
            break;
        case 3:
            type = ChatType.CHAT_MSG_RAID_BOSS_EMOTE;
            break;
        case 4, 5:
            type = text.chatType == 4 ? ChatType.CHAT_MSG_MONSTER_WHISPER : ChatType.CHAT_MSG_RAID_BOSS_WHISPER;
            break;
        default:
            return;
        }
        const body_ = monsterChatMessage(type, me.guid, me.template_.name, text.text(false), language, target);
        if (type == ChatType.CHAT_MSG_MONSTER_WHISPER || type == ChatType.CHAT_MSG_RAID_BOSS_WHISPER)
        {
            if (auto other = world_.unit(target))
                other.tell(Opcode.SMSG_MESSAGECHAT, body_);
        }
        else
        {
            // A zone yell, `CHAT_TYPE_ZONE_YELL` 6, is heard in the whole zone: in a
            // dungeon, its whole copy (Baron Rivendare's warnings across Stratholme). The open world's still by range.
            const zoneWide = text.chatType == 6 && me.instanceId;
            world_.sendInRange(me.position, zoneWide ? 2000 : lore.listenRange(type == ChatType.CHAT_MSG_RAID_BOSS_EMOTE
                ? ChatType.CHAT_MSG_MONSTER_YELL : type), Opcode.SMSG_MESSAGECHAT, body_);
        }
        if (text.emotes[0].emote)
            scriptEmote(text.emotes[0].emote);
    }

    /// ditto
    void scriptEmote(uint emote)
    {
        ByteWriter w;
        w.put(emote);
        w.put(me.guid);
        world_.sendToObservers(me.guid, Opcode.SMSG_EMOTE, w.data);
    }

    /// ditto
    void scriptStandState(uint state)
    {
        me.values.setByte!UNIT_FIELD_BYTES_1(0, cast(ubyte) state);
        world_.flushCreature(me);
    }

    /// ditto (`ACTION_T_FLEE_FOR_ASSIST`): in panic for `CreatureFamilyFleeDelay`, 10 seconds (`UnitAI::DoFlee`).
    bool scriptFlee()
    {
        enum int creatureFamilyFleeDelay = 10_000;
        return panic(creatureFamilyFleeDelay);
    }

    /**
     * In panic for `ms` (`Unit::SetInPanic`): its cast stopped, `UNIT_FLAG_FLEEING`, running from its enemy. Not
     * with Curse of Recklessness on it (`PREVENTS_FLEEING`), nor while disoriented, nor already running.
     */
    private bool panic(int ms)
    {
        if (!victim || fleeTimer > 0 || me.auras.has(AuraType.preventsFleeing) || me.auras.has(AuraType.modConfuse))
            return false;
        interruptCast();
        fleeTimer = ms;
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS | UnitFlags.fleeing);
        world_.flushCreature(me);
        if (!me.spline.finalized)
            stopMoving(me, world_);
        return true;
    }

    /// `CreatureStaticFlags::NO_MELEE_FLEE` (`StaticFlags1`): no melee, and it runs from a player that attacks it.
    enum uint staticFlagNoMeleeFlee = 0x00100000;

    /**
     * Entering a fight with `enemy`: a creature that does not melee (`NO_MELEE_FLEE`: a critter) runs from a player's
     * side for 30 seconds, then gives the fight up (`Unit::SetInCombatWith`), unless made by a spell, rooted,
     * already running, or casting.
     */
    void critterFleeAtAggro(UnitRef enemy)
    {
        if (!(me.template_.staticFlags1 & staticFlagNoMeleeFlee) || me.values.get!UNIT_CREATED_BY_SPELL
                || me.immobilized || fleeTimer > 0 || castingNow || !enemy
                || !(enemy.kind == UnitKind.player || enemy.relating.playerOwned))
            return;
        if (panic(30_000))
            critterFleeing = true;
    }

    /// ditto: the allies within `radius` yards that may help join in now.
    void scriptCallForHelp(float radius)
    {
        auto enemy = victim ? world_.unit(victim) : UnitRef.init;
        if (!enemy)
            return;
        foreach (other; world_.creaturesNear(me.position, radius))
            if (other !is me && other.ai !is null && other.ai.canAssistAgainst(me, enemy) && other.ai.answersCallsForHelp
                    && world_.inLineOfSight(me.position, other.position))
                other.ai.joinFightAgainst(enemy, world_);
    }

    /// ditto
    void scriptEvade()
    {
        if (inCombat_)
            enterEvadeMode(world_);
    }

    /// ditto
    void scriptAttack(ulong target)
    {
        if (auto other = world_.unit(target))
            attackStart(other, world_);
    }

    /// ditto: it stops where it is, or chases again.
    void scriptCombatMovement(bool on)
    {
        combatMovement_ = on;
        if (!on && !me.spline.finalized && !evadingHome)
            stopMoving(me, world_);
    }

    /// ditto: it keeps `distance` yards from its victim to cast.
    void scriptRangedMode(bool on, float distance)
    {
        rangedModeSet = rangedMode_ = on;
        chaseDistance_ = on ? distance : 0;
    }

    /// ditto
    @property bool rangedMode()
    {
        return rangedMode_;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A scripted creature (`creature_ai_scripts`): attacked, it yells and starts casting a bolt (1.5 s,
 * standing still), which hits the player; it puts damage over time on it that ticks; below half
 * health it heals itself once; out of mana it does not cast; evading, its script starts over.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind, count;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellDurationFormat,
        spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.eventai;
    import dmangos.world.movement : Position;
    import dmangos.world.npcdata : BroadcastText;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    import dmangos.bytes : bits = floatBits;
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0], [2u, 1500, 0, 1500]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 6000, 0, 6000]]), "SpellDuration.dbc");
    enum uint bolt = 95001, mend = 95002, rot = 95003, yell = 95004;
    with (context.data.spells)
    {
        spells[bolt] = testSpell(bolt, 2, 6, 7, 2);         // 7 fire damage, 1.5 s
        spells.edit(bolt).casting.school = 2;
        spells.edit(bolt).casting.interruptFlags = 15; // as Fireball's (133): one an interrupt stops
        spells.edit(bolt).casting.preventionType = 1;
        spells.edit(bolt).casting.dmgClass = DamageClass.none;                  // never resisted, for the test
        spells.edit(bolt).casting.manaCost = 50;
        spells[mend] = testSpell(mend, 10, 1, 200);         // heals itself 200
        spells[rot] = testSpell(rot, 6, 6, 3);              // 3 shadow damage every second for 6 s
        spells.edit(rot).casting.applyAuraName[0] = AuraType.periodicDamage;
        spells.edit(rot).casting.amplitude[0] = 1000;
        spells.edit(rot).casting.durationIndex = 1;
        spells.edit(rot).casting.school = 5;
        spells.edit(rot).casting.dmgClass = DamageClass.none;
    }
    context.data.npcs.broadcastTexts[yell] = BroadcastText("You will die!", "", 0, 1);

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    enum uint players = 1, monsters = 8;
    const humans = anduin.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_LEVEL(1u);
    keeper.values.set!UNIT_FIELD_MINDAMAGE(1.0f);
    keeper.values.set!UNIT_FIELD_MAXDAMAGE(1.0f);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    keeper.values.set!UNIT_FIELD_MAXPOWER1(120u);
    keeper.values.set!UNIT_FIELD_POWER1(120u);

    // On aggro: the yell and the bolt; every 5 s in combat the rot; below 50% the mend, once.
    EventAiEvent aggro = {id: 1, type: EventType.aggro, chance: 100};
    aggro.actions[0] = EventAiAction(ActionType.text, [yell, 0, 0]);
    aggro.actions[1] = EventAiAction(ActionType.castSpell, [bolt, EventTarget.hostile, 0]);
    EventAiEvent rotting = {id: 2, type: EventType.timerInCombat, chance: 100, flags: eventRepeatable,
        params: [2000, 2000, 5000, 5000, 0, 0]};
    rotting.actions[0] = EventAiAction(ActionType.castSpell, [rot, EventTarget.hostile, castAuraNotPresent]);
    EventAiEvent mending = {id: 3, type: EventType.hp, chance: 100, params: [50, 0, 0, 0, 0, 0]};
    mending.actions[0] = EventAiAction(ActionType.castSpell, [mend, EventTarget.self, 0]);
    auto events = [aggro, rotting, mending];
    keeper.ai.setScript(events, context.data.eventAi);

    const me = anduin.session.character;
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
    }

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(keeper.guid));
    auto got = anduin.read();
    tick(50);
    got ~= anduin.read();
    assert(opcodesOf(got).canFind(Opcode.SMSG_MESSAGECHAT), "the yell");
    assert(opcodesOf(got).canFind(Opcode.SMSG_SPELL_START) && keeper.ai.castingNow, "the bolt begins");
    const health = me.values.get!UNIT_FIELD_HEALTH;
    tick(1000);
    assert(keeper.ai.castingNow && me.values.get!UNIT_FIELD_HEALTH == health, "not yet");
    tick(600);
    got = anduin.read();
    assert(opcodesOf(got).canFind(Opcode.SMSG_SPELL_GO) && opcodesOf(got).canFind(Opcode.SMSG_SPELLNONMELEEDAMAGELOG));
    assert(!keeper.ai.castingNow);
    assert(keeper.values.get!UNIT_FIELD_POWER1 == 70, "its mana spent");
    assert(me.values.get!UNIT_FIELD_HEALTH < health, "the bolt hurt");

    // The rot after two seconds, ticking on the player.
    foreach (_; 0 .. 4)
        tick(500);
    assert(anduin.session.inWorld.hasAuraOf(rot), "the rot on the player");
    anduin.read();
    foreach (_; 0 .. 6)
        tick(500);
    assert(opcodesOf(anduin.read()).count(Opcode.SMSG_PERIODICAURALOG) >= 2, "it ticks");

    // Below half: it heals itself, once.
    keeper.values.set!UNIT_FIELD_HEALTH(200u);
    tick(500);
    tick(500);
    assert(keeper.values.get!UNIT_FIELD_HEALTH >= 400 - 50, "the mend");
    keeper.values.set!UNIT_FIELD_HEALTH(200u);
    foreach (_; 0 .. 4)
        tick(500);
    assert(keeper.values.get!UNIT_FIELD_HEALTH < 300, "not again");

    // Out of mana, no bolt: 70 left, 50 a bolt.
    keeper.values.set!UNIT_FIELD_POWER1(10u);
    assert(!keeper.ai.castSpell(context.data.spells.spell(bolt), me.guid, 0), "out of mana");

    // A bolt begun, and the player's interrupt (Pummel's effect): it stops.
    import dmangos.bytes : ByteWriter;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;

    keeper.values.set!UNIT_FIELD_POWER1(120u);
    assert(keeper.ai.castSpell(context.data.spells.spell(bolt), me.guid, 0) && keeper.ai.castingNow);
    enum uint pummel = 95011;
    context.data.spells.spells[pummel] = testSpell(pummel, 68, 6, 0);
    context.data.spells.spells.edit(pummel).casting.dmgClass = DamageClass.none;
    context.data.spells.spells.edit(pummel).casting.durationIndex = 1; // locks out for 6 s
    (cast(Player) me).spells ~= pummel;
    ByteWriter w;
    w.put(pummel);
    SpellTargets(TargetFlags.unit, keeper.guid).write(w);
    anduin.read();
    anduin.write(Opcode.CMSG_CAST_SPELL, w.data);
    assert(!keeper.ai.castingNow && opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_FAILURE), "interrupted");
    // Its school locked for the interrupt's 6 seconds; another school's spell it may cast.
    assert(!keeper.ai.castSpell(context.data.spells.spell(bolt), me.guid, 0), "fire locked out");
    assert(keeper.ai.castSpell(context.data.spells.spell(mend), keeper.guid, 0), "not its other spells");
    foreach (_; 0 .. 13)
        tick(500);
    assert(keeper.ai.castSpell(context.data.spells.spell(bolt), me.guid, 0), "fire again after the lockout");
    keeper.ai.interruptCast();

    // A friend in the fight, badly hurt: healed (`EVENT_T_FRIENDLY_HP`, cast at the event's own target).
    auto trainer = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    trainer.factionTemplate = keeper.factionTemplate;
    trainer.values.set!UNIT_FIELD_MAXHEALTH(500u);
    trainer.values.set!UNIT_FIELD_HEALTH(100u);
    trainer.ai.attackedBy(anduin.session.inWorld.unit, map);
    enum uint mendOther = 95012;
    context.data.spells.spells[mendOther] = testSpell(mendOther, 10, 21, 200);
    context.data.spells.spells.edit(mendOther).attributesEx2 = 0x20000000; // SPELL_ATTR_EX2_CANT_CRIT: exactly 200
    EventAiEvent friendly = {id: 4, type: EventType.friendlyHp, chance: 100, flags: eventRepeatable,
        params: [100, 30, 3000, 3000, 0, 0]};
    friendly.actions[0] = EventAiAction(ActionType.castSpell, [mendOther, EventTarget.eventSpecific, 0]);
    auto healing = [friendly];
    keeper.ai.setScript(healing, context.data.eventAi);
    keeper.values.set!UNIT_FIELD_HEALTH(keeper.values.get!UNIT_FIELD_MAXHEALTH); // only the friend hurt
    assert(keeper.ai.inCombat && trainer.ai.inCombat);
    tick(600);
    assert(trainer.values.get!UNIT_FIELD_HEALTH == 300, "the friend healed");
}

/// A spell list: in a fight the creature casts its list's spell at its victim, and again after its repeat time.
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind, count;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat, spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;
    import dmangos.world.worlddata : SpellListEntry;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    import dmangos.bytes : bits = floatBits;
    context.client.spellCastTimes = typeof(context.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
        [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint shout = 95201;
    context.data.spells.spells[shout] = testSpell(shout, 2, 6, 4); // 4 damage, instant
    context.data.spells.spells.edit(shout).casting.school = 2;
    context.data.spells.spells.edit(shout).casting.dmgClass = DamageClass.none;
    context.data.creatureTemplates.edit(creatureInnkeeper).spellList = 77;
    context.data.creatureSpellLists[77] = [SpellListEntry(shout, 0, 1, 100, 0, 1000, 1000, 3000, 3000)];

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    enum uint players = 1, monsters = 8;
    const humans = anduin.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_MINDAMAGE(0.0f);
    keeper.values.set!UNIT_FIELD_MAXDAMAGE(0.0f);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(5000u);
    keeper.values.set!UNIT_FIELD_HEALTH(5000u);
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
    }

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(keeper.guid));
    anduin.read();
    import std.bitmanip : nativeToLittleEndian;

    uint casts;
    foreach (_; 0 .. 50) // five seconds: at one second, then at four
    {
        tick(100);
        foreach (p; anduin.read())
            if (p.opcode == Opcode.SMSG_SPELL_GO && p.body_.canFind(nativeToLittleEndian(shout)[]))
                ++casts;
    }
    assert(casts == 2, "its list's spell, twice");
}

// A creature's aura on an enemy creature (a hunter's pet, say) is a debuff; on itself, a buff.
unittest
{
    import core.time : MonoTime;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : factionTemplateFormat, spellDurationFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.client.spellDurations = typeof(context.client.spellDurations).parse(buildDbc(spellDurationFormat,
        [[1u, 6000, 0, 6000]]), "SpellDuration.dbc");
    enum uint rot = 95101, ward = 95102;
    with (context.data.spells)
    {
        spells[rot] = testSpell(rot, 6, 6, 3); // a periodic shadow aura
        spells.edit(rot).casting.applyAuraName[0] = AuraType.periodicDamage;
        spells.edit(rot).casting.amplitude[0] = 1000;
        spells.edit(rot).casting.durationIndex = 1;
        spells[ward] = testSpell(ward, 6, 6, 0);
        spells.edit(ward).casting.applyAuraName[0] = AuraType.modResistance;
        spells.edit(ward).casting.durationIndex = 1;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto banker = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureBanker, bankerSpawn));
    assert(keeper !is null && banker !is null);
    enum uint players = 1, monsters = 8, playerSide = 1, monsterSide = 14;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[playerSide, 1, 0, players, 0, monsters, 0, 0, 0, 0, 0, 0, 0, 0],
         [monsterSide, 14, 0, monsters, 0, players, 0, 0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(monsterSide);
    banker.factionTemplate = context.client.factionTemplates.lookup(playerSide); // as a pet would be

    keeper.ai.moveInLineOfSight(map.unit(banker.guid), map); // as the map does: the AI learns its world
    keeper.ai.auraOn(rot in context.data.spells.spells, 0, banker.guid);
    auto debuff = banker.auras.find(rot);
    assert(debuff !is null && !debuff.positive, "on an enemy creature: a debuff, in a negative slot");
    keeper.ai.auraOn(ward in context.data.spells.spells, 0, keeper.guid);
    auto buff = keeper.auras.find(ward);
    assert(buff !is null && buff.positive, "on itself: a buff");
}

// A creature's melee-class spell that deals no weapon damage (Pierce Armor) is rolled like a blow: some of
// many casts at a player are missed, dodged or parried, and each such is told (SMSG_SPELLLOGMISS).
unittest
{
    import core.time : MonoTime;
    import std.algorithm.searching : count;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    import dmangos.bytes : bits = floatBits;
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint pierce = 95301;
    with (context.data.spells)
    {
        spells[pierce] = testSpell(pierce, 6, 6, 0); // an aura, no damage
        spells.edit(pierce).casting.dmgClass = DamageClass.melee;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    enum uint players = 1, monsters = 8;
    const humans = anduin.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    keeper.values.set!UNIT_FIELD_LEVEL(1u); // the player's level: the usual chances to miss and dodge
    keeper.ai.moveInLineOfSight(map.unit(anduin.session.character.guid), map);

    enum tries = 400;
    size_t told, went;
    foreach (i; 0 .. tries)
    {
        keeper.ai.castSpell(pierce in context.data.spells.spells, anduin.session.character.guid, castTriggered);
        const got = opcodesOf(anduin.read());
        told += got.count(Opcode.SMSG_SPELLLOGMISS);
        went += got.count(Opcode.SMSG_SPELL_GO);
    }
    assert(went == tries, "every cast went");
    assert(told > 0, "some casts missed, dodged or parried");
    assert(told < tries / 2, "most land");
}

// A creature's summons (a wild summon's two beside it), its knockback on a player, its drain of a player's power.
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat, spellRangeFormat;
    import dmangos.world.creature : Creature;
    import dmangos.world.map : MapObject;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    import dmangos.bytes : bits = floatBits;
    context.client.spellRanges = typeof(context.client.spellRanges).parse(buildDbc(spellRangeFormat,
        [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
    enum uint call = 95301, shove = 95302, drain = 95303;
    with (context.data.spells)
    {
        spells[call] = testSpell(call, SpellEffect.summonWild, ImplicitTarget.caster, 2);
        spells.edit(call).miscValue[0] = creatureTrainer;
        spells.edit(call).casting.dmgClass = DamageClass.none;
        spells[shove] = testSpell(shove, SpellEffect.knockBack, ImplicitTarget.enemy, 50);
        spells.edit(shove).miscValue[0] = 100;
        spells.edit(shove).casting.dmgClass = DamageClass.none;
        spells[drain] = testSpell(drain, SpellEffect.powerDrain, ImplicitTarget.enemy, 50);
        spells.edit(drain).miscValue[0] = 1; // rage
        spells.edit(drain).casting.dmgClass = DamageClass.none;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    enum uint players = 1, monsters = 8;
    const humans = anduin.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    const me = anduin.session.character;

    size_t trainers()
    {
        size_t n;
        map.forEachObject((MapObject o) {
            if (auto c = cast(Creature) o)
                if (c.template_.entry == creatureTrainer)
                    ++n;
        });
        return n;
    }

    import dmangos.world.packets : ClientGuid;

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(keeper.guid)); // it fights, and knows its map
    now += 50.msecs;
    anduin.session.update(50.msecs);
    map.update(50.msecs);
    anduin.read();
    const before = trainers();
    assert(keeper.ai.castSpell(context.data.spells.spell(call), keeper.guid, 0));
    assert(trainers() == before + 2, "two summoned beside it");

    assert(keeper.ai.castSpell(context.data.spells.spell(shove), me.guid, 0));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MOVE_KNOCK_BACK), "thrown");

    alias Power = imported!"dmangos.world.defines".Power;
    anduin.session.inWorld.player.modifyPower(Power.rage, 200);
    const rage = me.values.get!UNIT_FIELD_POWER1(Power.rage);
    assert(rage >= 50);
    assert(keeper.ai.castSpell(context.data.spells.spell(drain), me.guid, 0));
    assert(me.values.get!UNIT_FIELD_POWER1(Power.rage) == rage - 50, "50 of its rage drained");
}

/// A critter (`NO_MELEE_FLEE`): it never swings; attacked by a player it runs for 30 seconds, then gives up the fight.
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.creatureTemplates.edit(creatureInnkeeper).staticFlags1 = 0x00100000; // NO_MELEE_FLEE
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto critter = cast(Creature) context.map(0).findObject(innkeeper);
    assert(critter !is null);
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    anduin.session.update(50.msecs);
    assert(critter.ai.inCombat && critter.ai.fleeingAtLowHealth, "running");
    assert(critter.values.get!UNIT_FIELD_FLAGS & UnitFlags.fleeing);
    foreach (_; 0 .. 31)
    {
        now += 1.seconds;
        context.map(0).update(1000.msecs);
    }
    assert(!critter.ai.fleeingAtLowHealth && !(critter.values.get!UNIT_FIELD_FLAGS & UnitFlags.fleeing));
    assert(!critter.ai.inCombat || critter.ai.runningHome, "it gave up the fight");
}
