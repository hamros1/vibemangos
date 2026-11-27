/**
 * How this node's spells reach the units other nodes simulate, and theirs reach its own
 * (`WorldContext.remoteSpells`): area damage and heals, a game object's spell, a creature's swing, a periodic aura's
 * result and a spell's impact on a replica, each sent to the unit's node and the result sent back. The links
 * themselves (`sendAreaDamage` and the like) stay on the context, set by the cluster bridge.
 */
module dmangos.world.remotespells;

import dmangos.bytes : ByteReader, ByteWriter;
import core.time : Duration, minutes, MonoTime, msecs, seconds;
import dmangos.world.creature : Creature, CreatureParts, CreatureSpawn, CreatureTemplate, Npc, NpcStandIn, TempSpawn, TempSpawnType, VirtualItem;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType, GoLootState;
import dmangos.world.movement : Position;
import dmangos.world.replication : Replica, Replicator;
import dmangos.world.objects : HighGuid, highGuidOf, makeGuid, temporaryCounterStart, UpdateValues;
import dmangos.world.unit : UnitKind, UnitRef;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.map : Map;
import dmangos.world.spells : SpellInfo;
import dmangos.script.api : ActionResult, EntityRef, GameObjectHost, Location, QuestProgress, Waypoint;
import dmangos.cluster.protocol : AreaDamage, CreatureLoan, CreatureSwing, GameObjectSpell, GmRemote, GroupCommand, GroupLootRoll,
    KillShare, LootCoinShare, PartyHeal, PeriodicResult, QuestLootCheck, ScriptSignal, SwingRetaliation;
import dmangos.world.character : Character;
import dmangos.world.spellids : ImplicitTarget, SpellEffect, noEffect;
import dmangos.cluster.protocol : MindVisionTarget, TotemWeaponEnchant;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class RemoteSpells
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    package ulong[ushort] lastAreaDamage, lastAreaDamageReply;

    /// The first named effect with an implementation available on the chosen target's node.
    package size_t namedCreatureRouting(const(SpellInfo)* spell)
    {
        import dmangos.world.spelldamage : databaseSpellEffect, namedCreatureEffect;

        const effect = namedCreatureEffect(*spell);
        if (effect == noEffect || !world.spellScriptTargets(spell.id).length || world.spellScript(spell.id))
            return noEffect;
        if (databaseSpellEffect(spell.effect[effect]) && !world.data.dbScripts.targetsOnly(spell.id))
            return noEffect;
        return effect;
    }

    /// The first applicable effect in a shared target group, including auras when damage is excluded.
    package size_t namedCreatureEffectFor(const(SpellInfo)* spell, size_t first, uint entry)
    {
        import dmangos.world.spelldamage : remoteTargetAuraEffects;

        if (first == noEffect)
            return noEffect;
        const excluded = world.scriptTargetExclusions(spell.id, entry);
        if (!(excluded & (1u << first)))
            return first;
        if (spell.effect[first] == SpellEffect.schoolDamage || spell.effect[first] == SpellEffect.applyAura)
        {
            const auras = remoteTargetAuraEffects(*spell, first) & ~excluded;
            foreach (i; first + 1 .. spell.effect.length)
                if (auras & (1u << i))
                    return i;
        }
        return noEffect;
    }

    package const(uint)[] namedCreatureEntries(const(SpellInfo)* spell, size_t first)
    {
        const entries = world.spellScriptTargets(spell.id);
        if (spell.id !in world.data.spellScriptTargetMasks)
            return entries;
        uint[] eligible;
        foreach (entry; entries)
            if (namedCreatureEffectFor(spell, first, entry) != noEffect)
                eligible ~= entry;
        return eligible;
    }

    package size_t namedCreatureChannel(const(SpellInfo)* spell)
    {
        import dmangos.world.spellcast : duration;
        import dmangos.world.spelldamage : namedChannelTriggerEffect, namedCreatureChannelEffect,
            permanentNamedCreatureVisual;

        const effect = namedCreatureChannelEffect(*spell);
        const ms = duration(*spell, world.client, spell.spellLevel);
        return effect != noEffect && namedCreatureEntries(spell, effect).length && !world.spellScript(spell.id)
            && (ms > 0 || (ms < 0 && permanentNamedCreatureVisual(spell.id)))
            && (namedChannelTriggerEffect(*spell) == noEffect || namedChannelCompletionSpell(spell) !is null)
            ? effect : noEffect;
    }

    /// A single terminal dummy hit with no spell script of its own can run where its creature is owned.
    package const(SpellInfo)* namedChannelCompletionSpell(const(SpellInfo)* spell)
    {
        import dmangos.world.dbscripts : DbScriptType;
        import dmangos.world.spellcast : duration;
        import dmangos.world.spelldamage : crystalPrisonCompletion, namedChannelTriggerEffect, namedCreatureShape;
        import dmangos.world.spellids : SpellEffect;

        const effect = namedChannelTriggerEffect(*spell);
        if (effect == noEffect || spell.casting.amplitude[effect] != duration(*spell, world.client, spell.spellLevel))
            return null;
        const child = world.data.spells.spell(spell.triggerSpell[effect]);
        if (child is null || (child.casting.speed != 0 && child.id != crystalPrisonCompletion)
            || (child.attributesEx & (0x04 | 0x40))
            || child.effect[0] != SpellEffect.dummy || child.effect[1] || child.effect[2]
            || namedCreatureShape(*child, 0) != ImplicitTarget.unitScriptNearCaster || child.casting.chainTarget[0] > 1
            || !world.spellScriptTargets(child.id, 0).length || world.spellScript(child.id)
            || world.data.dbScripts.steps(DbScriptType.spell, child.id).length)
            return null;
        return child;
    }

    package ImplicitTarget namedGameObjectRouting(const(SpellInfo)* spell, size_t effect)
    {
        import dmangos.world.spellselection : namedGameObjectShape;

        const shape = namedGameObjectShape(*spell, effect);
        if (shape != ImplicitTarget.none && !world.spellScript(spell.id) && world.data.spellScriptObjects.get(spell.id, null).length)
            return shape;
        return ImplicitTarget.none;
    }

    package bool onlyNamedGameObjectEffects(const(SpellInfo)* spell)
    {
        bool found;
        foreach (i, effect; spell.effect)
        {
            if (effect == SpellEffect.none)
                continue;
            if (namedGameObjectRouting(spell, i) == ImplicitTarget.none)
                return false;
            found = true;
        }
        return found;
    }

    package ulong[ushort] lastGameObjectSpell, lastGameObjectSpellReply;

    package bool namedGameObjectGeometry(Map map_, const(SpellInfo)* spell, size_t effect, ImplicitTarget shape,
        Position origin, out Position center, out float reach)
    {
        import std.math : isFinite;
        import dmangos.world.spellcast : radius;
        import dmangos.world.spellselection : namedCreatureRange;

        center = origin;
        if (spell.implicitTargetA[effect] == ImplicitTarget.database)
        {
            const location = spell.id in world.data.spellTargets;
            if (location is null || location.map != map_.id)
                return false;
            center = location.at;
        }
        reach = shape == ImplicitTarget.gameobjectScriptNearCaster
            ? namedCreatureRange(*spell, world.client) : radius(*spell, effect, world.client);
        return isFinite(reach) && reach > 0 && world.client.isValidMapCoord(map_.id, center.x, center.y, center.z);
    }

    package ulong[] namedGameObjectTargets(Map map_, const(SpellInfo)* spell, size_t effect, ImplicitTarget shape,
        Position origin, out Position center, scope bool delegate(ulong) visible = null)
    {
        import dmangos.world.spellselection : namedGameObjectsInArea, nearestNamedGameObject;

        float reach;
        if (!namedGameObjectGeometry(map_, spell, effect, shape, origin, center, reach))
            return null;
        const entries = world.data.spellScriptObjects.get(spell.id, null);
        const acrossNodes = world.sendGameObjectSpell !is null;
        if (shape != ImplicitTarget.gameobjectScriptNearCaster)
            return namedGameObjectsInArea(map_, center, reach, effect, entries, acrossNodes, spell.casting.maxAffectedTargets,
                visible);
        auto object = nearestNamedGameObject(map_, center, reach, effect, entries, acrossNodes, visible);
        return object is null ? null : [object.guid];
    }

    package void activateNamedGameObject(UnitRef caster, const(SpellInfo)* spell, size_t effect, ulong guid,
        Position origin, bool triggered)
    {
        import dmangos.world.replication : Replica;

        const shape = namedGameObjectRouting(spell, effect);
        if (!world.canWrite() || caster.kind == UnitKind.none || shape == ImplicitTarget.none)
            return;
        auto map_ = caster.map;
        if (auto copy = cast(Replica) map_.findObject(guid))
        {
            if (world.sendGameObjectSpell is null || copy.owner == world.nodeId)
                return;
            const message = GameObjectSpell(world.nextGameplaySequence(), caster.combatGuid, guid,
                spell.id, map_.id, map_.instanceId, cast(ubyte) effect, origin.x, origin.y, origin.z, triggered);
            world.sendGameObjectSpell(copy.owner, message);
        }
        else if (auto object = map_.gameObjectAt(guid))
            applyNamedGameObject(map_, spell, effect, shape, object, origin, caster.combatGuid);
    }

    package struct ObjectAnimationImpact
    {
        MonoTime arrives;
        Map map;
        GameObject object;
        uint animation;
    }
    package ObjectAnimationImpact[] objectAnimations;

    /// A trap (game object `entry`) at `at` on `map` for `seconds`, its fuse lit for `fuseMs` (0: none); false if it
    /// could not be made.
    package bool placeFusedTrap(Map map, uint entry, Position at, uint seconds, uint fuseMs)
    {
        auto trap = world.summonWildGameObject(map, entry, at, seconds);
        if (trap is null)
            return false;
        if (fuseMs)
        {
            trap.restoreTimer = fuseMs;
            map.wake(trap.guid);
        }
        return true;
    }

    package void landObjectAnimations(MonoTime now)
    {
        import dmangos.world.gameobject : gameObjectAnimation;
        size_t kept;
        foreach (impact; objectAnimations)
            if (impact.arrives > now)
                objectAnimations[kept++] = impact;
            else if (impact.map.gameObjectAt(impact.object.guid) is impact.object && world.canWrite())
                impact.map.sendToObservers(impact.object.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM,
                    gameObjectAnimation(impact.object.guid, impact.animation));
        objectAnimations.length = kept;
    }

    package bool applyNamedGameObject(Map map_, const(SpellInfo)* spell, size_t effect, ImplicitTarget shape,
        GameObject object, Position origin, ulong casterGuid)
    {
        import dmangos.world.gameobject : gameObjectAnimation, GameObjectAction;
        import dmangos.world.spellselection : namedGameObjectAnimation, namedGameObjectEntry;

        if (!namedGameObjectEntry(world.data.spellScriptObjects.get(spell.id, null), effect, object.spawn.entry))
            return false;
        Position center;
        float reach;
        if (!namedGameObjectGeometry(map_, spell, effect, shape, origin, center, reach))
            return false;
        const at = object.position;
        if (!((at.x - center.x) ^^ 2 + (at.y - center.y) ^^ 2 + (at.z - center.z) ^^ 2 <= reach ^^ 2))
            return false;
        const animation = namedGameObjectAnimation(*spell, effect);
        if (animation >= 0 && spell.casting.speed > 0)
        {
            import core.time : msecs;
            import std.math : sqrt;
            const distance = sqrt((at.x-origin.x) ^^ 2 + (at.y-origin.y) ^^ 2 + (at.z-origin.z) ^^ 2);
            objectAnimations ~= ObjectAnimationImpact(world.clock() + (cast(int)(1000 * distance / spell.casting.speed)).msecs,
                map_, object, cast(uint) animation);
        }
        else if (animation >= 0)
            map_.sendToObservers(object.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM,
                gameObjectAnimation(object.guid, cast(uint) animation));
        else if (spell.id == 19873)
        {
            auto dragon = map_.creatureAt(casterGuid);
            if (dragon is null || dragon.spawn.entry != 12435 || !dragon.petOwner || !dragon.alive
                || map_.id != 469 || object.spawn.entry != 177807)
                return false;
            world.objectScripts.gameObjectUsed(object, map_, casterGuid);
        }
        else if (spell.miscValue[effect] == GameObjectAction.disturb)
        {
            // A trap: its spell; a button (Celebras's staff): used.
            if (object.template_.type == GameObjectType.trap)
                return disturbEncounterTrap(map_, object);
            if (object.template_.type != GameObjectType.button)
                return false;
            usedBySpell(object, map_, casterGuid);
        }
        else if (spell.miscValue[effect] == GameObjectAction.open && !object.doorOrButton)
        {
            if (object.template_.type != GameObjectType.goober)
                return false;
            usedBySpell(object, map_, casterGuid); // a cage, an egg: used as a player uses it
        }
        else if (spell.miscValue[effect] == GameObjectAction.despawn)
            map_.removeObject(object.guid);
        else
        {
            if (!object.applySpellState(map_, cast(GameObjectAction) spell.miscValue[effect]))
                return false;
            map_.wake(object.guid);
        }
        return true;
    }

    /**
     * `object` used by a spell of `casterGuid`'s (a creature's open or disturb): what a player's use does but what is
     * the player's own (quest credit, page, the goober's spell on its user): its script, its use scripts, and a
     * button's or a goober's own use with its event.
     */
    package void usedBySpell(GameObject object, Map map_, ulong casterGuid)
    {
        import dmangos.world.dbscripts : DbScriptType;

        if (world.objectScripts.gameObjectUsed(object, map_, casterGuid))
            return;
        world.startScript(DbScriptType.goTemplateUse, object.spawn.entry, map_, casterGuid, object.guid);
        world.startScript(DbScriptType.goUse, object.spawn.guid, map_, casterGuid, object.guid);
        if (object.template_.type == GameObjectType.button)
            object.useDoorOrButton(map_);
        else
        {
            object.activateGoober(map_);
            if (const event = object.template_.data[2])
                world.scriptedEvent(event, map_, casterGuid, object.guid);
        }
        map_.wake(object.guid);
    }

    /// Cast a dungeon trap's spell at the trap. The egg creates a second proximity trap and each
    /// plague fissure casts its own short-range Eruption at its location on the floor.
    package bool disturbEncounterTrap(Map map_, GameObject object)
    {
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.gameobject : GoLootState, gameObjectAnimation;
        import dmangos.world.spellcast : duration;
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE, UNIT_FIELD_FLAGS;

        const proto = object.template_;
        if (proto.type != GameObjectType.trap || object.lootState != GoLootState.ready)
            return false;
        const spell = world.data.spells.spell(cast(uint) proto.data[3]);
        if (spell is null)
            return false;
        if (spell.effect[0] == SpellEffect.summonObjectWild)
        {
            const ms = duration(*spell, world.client, cast(uint) proto.data[1]);
            if (world.summonWildGameObject(map_, cast(uint) spell.miscValue[0], object.position,
                    ms > 0 ? cast(uint)(ms / 1000) : 0) is null)
                return false;
        }
        else
        {
            enum worldTrigger = 15384;
            auto trigger = world.summonCreature(map_, worldTrigger, object.position, TempSpawnType.timed, 1000, 0);
            if (trigger is null || trigger.ai is null)
                return false;
            trigger.factionTemplate = world.client.factionTemplates.lookup(proto.faction);
            trigger.values.set!UNIT_FIELD_FACTIONTEMPLATE(proto.faction);
            // The invisible proxy is spawning an environmental hazard that can hit players and NPCs.
            trigger.values.set!UNIT_FIELD_FLAGS(trigger.values.get!UNIT_FIELD_FLAGS
                & ~(UnitFlags.immuneToPlayer | UnitFlags.immuneToNpc));
            if (trigger.ai.castFor(map_, spell.id, trigger.guid, true) != ActionResult.ok)
                return false;
        }
        if (proto.extraFlags & 1)
            map_.sendToObservers(object.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM, gameObjectAnimation(object.guid, 0));
        object.trapReadyAt = world.unixTime + (proto.data[5] > 0 ? proto.data[5] : 4);
        if (proto.data[4] > 0 && ++object.trapUses >= proto.data[4])
            map_.gameObjectUsedUp(object);
        return true;
    }

    void gameObjectSpellArrived(ushort peer, const ref GameObjectSpell message)
    {
        import dmangos.world.replication : Replica;
        import dmangos.world.updatefields : TypeId;

        if (!peer || !message.sequence || !world.canWrite())
            return;
        auto map_ = world.existingMap(message.map, message.instance);
        const spell = world.data.spells.spell(message.spell);
        if (map_ is null || map_.id != message.map || spell is null)
            return;
        const shape = namedGameObjectRouting(spell, message.effect);
        if (shape == ImplicitTarget.none)
            return;
        if (message.reply)
        {
            if (message.sequence <= lastGameObjectSpellReply.get(peer, 0))
                return;
            lastGameObjectSpellReply[peer] = message.sequence;
            if (auto caster = map_.unit(message.caster))
                if (caster.kind == UnitKind.player && !caster.session.transferring)
                    caster.session.rewardPlayerAndGroupAtCast(message.target, message.spell, peer);
            return;
        }
        if (message.sequence <= lastGameObjectSpell.get(peer, 0))
            return;
        lastGameObjectSpell[peer] = message.sequence;
        const high = highGuidOf(message.caster);
        const playerCast = high == HighGuid.player;
        if (!message.caster || (!playerCast && high != HighGuid.unit && high != HighGuid.pet))
            return;
        // An idle object owner may have no interest in the caster's cell. The casting node
        // checked the cast before sending it. Any locally known authority must agree.
        if (auto copy = cast(Replica) map_.findObject(message.caster))
        {
            if (copy.owner != peer || copy.fields.type != (playerCast ? TypeId.player : TypeId.unit)
                || (!UnitRef.observed(copy, map_).alive && !(message.triggered && !playerCast)))
                return;
        }
        else if (map_.unit(message.caster))
            return;
        auto object = map_.gameObjectAt(message.target);
        if (object is null || !world.client.isValidMapCoord(map_.id, message.x, message.y, message.z))
            return;
        const origin = Position(message.x, message.y, message.z);
        if (applyNamedGameObject(map_, spell, message.effect, shape, object, origin, message.caster)
            && playerCast && world.sendGameObjectSpell !is null)
        {
            auto reply = cast(GameObjectSpell) message;
            reply.reply = true;
            world.sendGameObjectSpell(peer, reply);
        }
    }

    package struct ReplicaSpellImpact
    {
        MonoTime due;
        AreaDamage hit;
        MonoTime retryUntil; // time allowed to resolve the target across a handoff
        ushort sentTo; // a completed channel can follow a replica to a different owner
        bool retired; // omitted from checkpoints before committing the impact
    }

    package enum replicaImpactGrace = 2.seconds;
    package ReplicaSpellImpact[] replicaSpellImpacts;

    /// Only a caster that completed its channel can authorize its terminal spell.
    package void completeNamedChannel(Map map_, UnitRef caster, ulong target, const(SpellInfo)* spell, ulong token)
    {
        import std.algorithm.comparison : max;
        import std.math : sqrt;

        const child = namedChannelCompletionSpell(spell);
        if (!token || !world.canWrite() || child is null)
            return;
        auto hit = AreaDamage(caster: caster.combatGuid, target: target, spell: spell.id,
            map: map_.id, instance: map_.instanceId, creatureCast: caster.creature !is null,
            namedCreature: true, channelled: true, channelUpdate: true,
            auraMs: AreaDamage.completedChannel, channelToken: token);
        const local = map_.creatureAt(target) !is null;
        Position at;
        int delay;
        if (child.casting.speed > 0 && map_.positionOf(target, at))
        {
            const from = caster.position;
            const yards = sqrt((at.x - from.x) ^^ 2 + (at.y - from.y) ^^ 2 + (at.z - from.z) ^^ 2);
            delay = cast(int) (max(5.0f, yards) / child.casting.speed * 1000);
        }
        if (local && delay == 0)
            applyAreaDamage(0, map_, hit);
        else if (local || world.sendAreaDamage !is null)
        {
            const due = world.clock() + delay.msecs;
            queueReplicaSpellImpact(ReplicaSpellImpact(due, hit, due + replicaImpactGrace));
        }
    }

    /// Move queued impacts with the caster. The deadlines use the shared node clock.
    package void writeReplicaImpacts(ulong caster, ref ByteWriter writer, bool departing = true)
    {
        import dmangos.serialization : serialize;

        const count = replicaImpactCount(caster);
        writer.put(count);
        if (!count)
            return;

        const now = world.clock();
        const transferTime = world.fleet.transportNow();
        foreach (ref impact; replicaSpellImpacts)
        {
            if (impact.retired || impact.hit.caster != caster)
                continue;
            writer.put(transferTime + cast(uint)(impact.due - now).total!"msecs");
            const waiting = impact.retryUntil != MonoTime.init;
            writer.put(waiting);
            if (waiting)
                writer.put(transferTime + cast(uint)(impact.retryUntil - now).total!"msecs");
            writer.put(impact.sentTo);
            serialize(writer, impact.hit);
            if (departing)
                impact.retired = true;
        }
    }

    package uint replicaImpactCount(ulong caster) const
    {
        uint count;
        foreach (ref impact; replicaSpellImpacts)
            if (!impact.retired && impact.hit.caster == caster)
                ++count;
        return count;
    }

    package bool discardReplicaImpacts(ulong caster)
    {
        bool discarded;
        foreach (ref impact; replicaSpellImpacts)
            if (!impact.retired && impact.hit.caster == caster)
            {
                impact.retired = true;
                discarded = true;
            }
        return discarded;
    }

    /// Adopt impacts for the caster on the same map and instance from which they were launched.
    package void readReplicaImpacts(ulong caster, uint mapId, uint instance, ref ByteReader reader)
    {
        import std.algorithm.comparison : max;
        import dmangos.serialization : deserialize;

        const count = reader.read!uint;
        if (!count)
            return;
        const now = world.clock();
        const arrived = world.fleet.transportNow();
        ReplicaSpellImpact[] restored;
        foreach (_; 0 .. count)
        {
            const deadline = reader.read!uint;
            const waiting = reader.read!bool;
            const expiresIn = waiting ? cast(int)(reader.read!uint - arrived) : 0;
            const sentTo = reader.read!ushort;
            auto hit = deserialize!AreaDamage(reader);
            if (hit.caster != caster || hit.reply || hit.benefits.length || hit.map != mapId || hit.instance != instance
                || (waiting && expiresIn <= 0))
                continue;
            const remaining = max(0, cast(int)(deadline - arrived));
            const due = now + remaining.msecs;
            restored ~= ReplicaSpellImpact(due, hit, waiting ? now + expiresIn.msecs : MonoTime.init, sentTo);
        }
        replicaSpellImpacts ~= restored;
    }

    /// Commit a cross-node effect now, or when its projectile reaches the target.
    package bool sendReplicaSpell(Map map_, ushort peer, const(SpellInfo)* spell, AreaDamage hit)
    {
        import std.math : isFinite, sqrt;
        import dmangos.world.spelldamage : namedCreatureShape;
        import dmangos.world.spellids : ImplicitTarget;

        if (world.sendAreaDamage is null || !world.canWrite())
            return false;
        if (hit.playerProjectile)
        {
            if (!sendReplicaSpellImpact(map_, peer, hit, true))
                queueReplicaSpellImpact(ReplicaSpellImpact(world.clock(), hit, MonoTime.init, hit.redirectOwner));
            return true;
        }
        if (!hit.channelled && spell.casting.speed > 0)
            if (auto copy = cast(Replica) map_.findObject(hit.target))
            {
                auto from = Position(hit.x, hit.y, hit.z), to = copy.position;
                if (hit.namedCreature && namedCreatureShape(*spell, hit.effect) == ImplicitTarget.enumUnitsScriptAoeAtDestLoc)
                {
                    auto caster = map_.unit(hit.caster);
                    if (!caster)
                        return false;
                    to = from;
                    from = caster.position;
                }
                const time = sqrt((to.x - from.x) ^^ 2 + (to.y - from.y) ^^ 2 + (to.z - from.z) ^^ 2)
                    / spell.casting.speed * 1000;
                if (!isFinite(time) || time >= int.max)
                    return false;
                if (time >= 1)
                {
                    queueReplicaSpellImpact(ReplicaSpellImpact(world.clock() + (cast(int) time).msecs, hit));
                    return true;
                }
            }
        return sendReplicaSpellImpact(map_, peer, hit);
    }

    package void queueReplicaSpellImpact(ReplicaSpellImpact impact)
    {
        replicaSpellImpacts ~= impact;
        if (auto caster = world.onlinePlayer(impact.hit.caster))
            caster.checkpointSummons(true);
    }

    package bool sendReplicaSpellImpact(Map map_, ushort peer, AreaDamage hit, bool projectile = false)
    {
        import std.algorithm.comparison : max;

        if (world.sendAreaDamage is null)
            return false;
        if (hit.channelled)
            map_.holdCasterReplica(hit.caster, peer, cast(uint) max(0, hit.auraMs) + 5_000,
                (hit.creatureCast && !hit.channelUpdate) || hit.channelOperation == AreaDamage.ChannelUpdate.complete);
        else if (hit.namedCreature || projectile)
            map_.holdCasterReplica(hit.caster, peer, 5_000, projectile);
        if (!hit.sequence || !hit.channelled)
            hit.sequence = world.nextGameplaySequence();
        return world.sendAreaDamage(peer, hit);
    }

    package void deliverReplicaSpells(MonoTime now)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import dmangos.world.unit : UnitKind;

        const queued = replicaSpellImpacts.length;
        if (!queued)
            return;
        foreach (i; 0 .. queued)
        {
            auto impact = replicaSpellImpacts[i];
            if (impact.retired || impact.due > now)
                continue;
            auto map_ = world.existingMap(impact.hit.map, impact.hit.instance);
            auto caster = world.onlinePlayer(impact.hit.caster);
            bool retire()
            {
                replicaSpellImpacts[i].retired = true;
                if (caster is null || caster.checkpointSummons(true))
                    return true;
                replicaSpellImpacts[i].retired = false;
                replicaSpellImpacts[i].due = now + 1.seconds;
                return false;
            }
            if (map_ is null || !map_.unit(impact.hit.caster) || !world.canWrite()
                || (impact.retryUntil != MonoTime.init && impact.retryUntil <= now))
            {
                retire();
                continue;
            }
            const completion = impact.hit.channelOperation == AreaDamage.ChannelUpdate.complete;
            if (auto copy = cast(Replica) map_.findObject(impact.hit.target))
            {
                if (copy.owner != impact.sentTo)
                {
                    if (!retire())
                        continue;
                    if (sendReplicaSpellImpact(map_, copy.owner, impact.hit, !completion))
                    {
                        if (!completion)
                            continue;
                        impact.sentTo = copy.owner;
                    }
                    impact.retired = false;
                }
            }
            else
            {
                auto target = map_.unit(impact.hit.target);
                if (target && (target.kind != UnitKind.player || !target.session.transferring))
                {
                    if (retire())
                        applyAreaDamage(0, map_, impact.hit);
                    continue;
                }
                if (completion)
                    impact.sentTo = 0;
            }
            if (impact.retryUntil == MonoTime.init)
                impact.retryUntil = now + replicaImpactGrace;
            const retry = replicaSpellImpacts[i].retired;
            replicaSpellImpacts[i] = impact;
            if (retry && caster !is null)
                caster.checkpointSummons(true);
        }
        replicaSpellImpacts = replicaSpellImpacts.remove!(impact => impact.retired, SwapStrategy.stable);
    }

    package ulong[ushort] lastCreatureSwing, lastCreatureSwingReply;

    package bool queueCreatureSwing(Creature attacker, UnitRef target, uint spell, int spellValue, float spellThreat,
        bool secondary)
    {
        import dmangos.world.combat : creatureTypeHumanoid;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

        if (!world.canWrite() || target.replica.owner == world.nodeId)
            return false;
        uint targetType = creatureTypeHumanoid;
        if (target.replica.fields.type == TypeId.unit)
        {
            const template_ = target.replica.fields.get!OBJECT_FIELD_ENTRY in world.data.creatureTemplates;
            if (template_ is null)
                return false;
            targetType = template_.creatureType;
        }
        const fighter = attacker.fighter;
        const damageVersus = targetType < fighter.damageVersus.length ? fighter.damageVersus[targetType] : 1;
        const critVersus = targetType < fighter.critVersus.length ? fighter.critVersus[targetType] : 0;
        const request = CreatureSwing(sequence: world.nextGameplaySequence(), attacker: attacker.guid,
            target: target.combatGuid, controller: attacker.meleeController, map: target.map.id, instance: target.map.instanceId,
            destination: target.replica.owner,
            facing: fighter.position.orientation, running: fighter.runningAround, school: fighter.damageSchool[0],
            armorIgnored: fighter.armorIgnored, minDamage: fighter.damage[0][0], maxDamage: fighter.damage[0][1],
            damageFactor: fighter.damageDone[0] * damageVersus, crit: fighter.crit,
            critVersus: critVersus, hitBonus: fighter.hitBonus, spell: spell, spellValue: spellValue,
            spellThreat: spellThreat, secondary: secondary);
        return world.sendCreatureSwing(request.destination, request);
    }

    /// The target's node resolves the attack table, armor and absorbs against the unit it simulates now.
    void creatureSwingArrived(ushort peer, const ref CreatureSwing request)
    {
        import std.math : isFinite;
        import dmangos.world.combat : attackerStateUpdate, AttackType, calculateMeleeDamage, creatureSwingInReach,
            HitInfo;
        import dmangos.world.creaturecasting : creatureWeaponSpellDamage, nextWeaponSwingEffect, weaponSpellMiss;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.relations : canAttackNow;
        import dmangos.world.spelldamage : creatureTargetInRange, weaponRolledAmount;
        import dmangos.world.unit : Blow, combatRelations, dealDamage;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

        if (!peer || !request.sequence || !world.canWrite())
            return;
        if (request.reply)
            return creatureSwingReply(peer, request);
        if (request.destination != world.nodeId || request.sequence <= lastCreatureSwing.get(peer, 0))
            return;
        lastCreatureSwing[peer] = request.sequence;
        if (request.retaliation.length)
            return;
        if (request.school >= 7 || !isFinite(request.facing) || !isFinite(request.minDamage)
            || !isFinite(request.maxDamage) || !isFinite(request.damageFactor) || !isFinite(request.crit)
            || !isFinite(request.critVersus) || !isFinite(request.hitBonus) || request.minDamage < 0
            || request.maxDamage < 0 || request.minDamage >= uint.max || request.maxDamage >= uint.max)
            return;
        auto map_ = world.existingMap(request.map, request.instance);
        if (map_ is null || map_.id != request.map || map_.instanceId != request.instance)
            return;
        auto victim = map_.unit(request.target);
        if (!victim.alive || victim.untouchable || (victim.kind == UnitKind.player && victim.session.transferring)
            || (victim.kind == UnitKind.creature && victim.creature.ai is null))
            return;
        auto copy = cast(Replica) map_.findObject(request.attacker);
        if (copy is null || copy.owner != peer || copy.fields.type != TypeId.unit)
            return;
        auto source = UnitRef.observed(copy, map_);
        const relation = source.combatRelations(world.client);
        const controller = copy.meleeController;
        enum disabled = UnitFlags.pacified | UnitFlags.stunned | UnitFlags.confused | UnitFlags.fleeing;
        if (request.controller != controller
            || (!controller && (relation.playerControlled
                || (victim.kind == UnitKind.creature && !victim.creature.meleeController)))
            || (controller && victim.kind == UnitKind.player && victim.session.dueling.duelingWith(controller))
            || (relation.unitFlags & disabled) || !canAttackNow(relation, victim.relating(), world.client))
            return;
        const template_ = copy.fields.get!OBJECT_FIELD_ENTRY in world.data.creatureTemplates;
        if (template_ is null)
            return;
        auto attacker = copy.meleeGeometry();
        attacker.position.orientation = request.facing; // A facing change alone may not have sent movement yet.
        attacker.runningAround = request.running;
        auto defender = victim.fighter;
        if (!creatureSwingInReach(attacker, defender))
            return;
        const spell = request.spell ? world.data.spells.spell(request.spell) : null;
        const weaponEffect = spell is null ? -1 : nextWeaponSwingEffect(*spell);
        if (request.spell && (weaponEffect < 0 || !isFinite(request.spellThreat) || request.spellThreat < 0
            || !creatureTargetInRange(spell, attacker, defender, world.client)
            || !map_.inLineOfSight(attacker.position, defender.position)))
            return;
        attacker.worldBoss = template_.rank == 3;
        attacker.armorIgnored = request.armorIgnored;
        attacker.damage[0] = [request.minDamage, request.maxDamage];
        attacker.damageSchool[0] = request.school;
        attacker.damageDone[0] = request.damageFactor;
        attacker.crit = request.crit;
        if (defender.creatureType < attacker.critVersus.length)
            attacker.critVersus[defender.creatureType] = request.critVersus;
        attacker.hitBonus = request.hitBonus;

        auto hit = calculateMeleeDamage(attacker, defender, AttackType.mainHand, map_.random);
        auto result = cast(CreatureSwing) request;
        result.reply = true;
        result.spellMiss = 0;
        Blow blow;
        SwingRetaliation[] retaliation;
        if (spell is null)
        {
            if ((hit.absorbed = victim.absorb(hit.school, hit.damage)) != 0)
                hit.hitInfo |= HitInfo.absorb;
            const packet = attackerStateUpdate(hit);
            if (victim.kind == UnitKind.player)
                map_.sendToWatchers(victim.session, Opcode.SMSG_ATTACKERSTATEUPDATE, packet, true);
            else
                map_.sendToObservers(request.target, Opcode.SMSG_ATTACKERSTATEUPDATE, packet);
            blow = Blow.swing(hit);
            blow.retaliate = (uint damage, uint school, uint procSpell, float threatFactor) {
                retaliation ~= SwingRetaliation(damage, school, procSpell, threatFactor);
            };
        }
        else
        {
            result.spellMiss = cast(ubyte) weaponSpellMiss(hit);
            if (!result.spellMiss)
            {
                if (victim.kind == UnitKind.creature)
                    victim.creature.ai.spellHitBy(request.attacker, spell.id, 1u << spell.casting.school, map_);
                victim.hostileSpellLanded();
                const current = victim.fighter;
                hit.damage = creatureWeaponSpellDamage(spell.effect[weaponEffect], hit.damage, request.spellValue,
                    attacker.level, current.armor);
                hit.damage = weaponRolledAmount(hit.damage, 0, current);
                hit.absorbed = victim.absorb(0, hit.damage);
                blow = Blow.spell();
                blow.threat = request.spellThreat;
            }
            else
                hit.damage = 0;
        }
        if (!result.spellMiss)
        {
            blow.remotePlayer = controller;
            blow.remotePlayerPvP = relation.hasFlag(UnitFlags.pvp);
            const honor = controller && victim.kind == UnitKind.player ? victim.session.describeHonorVictim()
                : HonorVictim.init;
            if (controller)
            {
                if (dealRemoteDamage(source, victim, hit.damage, blow) && honor.guid)
                    reportRemotePlayerKill(controller, honor, map_);
            }
            else
                dealDamage(source, victim, hit.damage, blow);
        }

        if (world.sendCreatureSwing !is null)
        {
            result.outcome = cast(ubyte) hit.outcome;
            result.damage = hit.damage;
            result.absorbed = hit.absorbed;
            result.killed = !victim.alive;
            result.targetPvP = victim.kind == UnitKind.player && victim.session.character !is null && victim.session.isPvP;
            result.retaliation = retaliation;
            world.sendCreatureSwing(peer, result);
        }
    }

    package void creatureSwingReply(ushort peer, const ref CreatureSwing reply)
    {
        import std.math : isFinite;
        import dmangos.bytes : ByteWriter;
        import dmangos.world.combat : MeleeHitOutcome;
        import dmangos.world.objects : highGuidOf;
        import dmangos.world.spellcast : nonMeleeDamageLog, spellGoPacket, spellMissLog, SpellMissInfo, SpellTargets,
            TargetFlags, TargetResult;
        import dmangos.world.unit : Blow;

        if (reply.destination != peer || reply.sequence <= lastCreatureSwingReply.get(peer, 0)
            || reply.outcome > MeleeHitOutcome.max)
            return;
        lastCreatureSwingReply[peer] = reply.sequence;
        auto map_ = world.existingMap(reply.map, reply.instance);
        if (map_ is null || map_.id != reply.map || map_.instanceId != reply.instance)
            return;
        auto attacker = map_.creatureAt(reply.attacker);
        if (attacker is null || !attacker.alive || attacker.ai is null
            || attacker.meleeController != reply.controller || reply.sequence <= attacker.charmSequence)
            return;
        auto target = attacker.ai.combatTarget(map_, reply.target);
        if (reply.targetPvP && reply.controller)
            if (auto owner = world.onlinePlayer(reply.controller))
                owner.attackedFlaggedPlayer();
        if (reply.spell)
        {
            const spell = world.data.spells.spell(reply.spell);
            if (spell is null || reply.spellMiss > SpellMissInfo.reflect)
                return;
            const miss = cast(SpellMissInfo) reply.spellMiss;
            const targets = SpellTargets(TargetFlags.unit, reply.target);
            if (!reply.secondary)
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELL_GO,
                    spellGoPacket(reply.attacker, reply.spell, [TargetResult(reply.target, miss)], targets));
            if (miss)
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLLOGMISS,
                    spellMissLog(reply.spell, reply.attacker, reply.target, miss));
            else
            {
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLNONMELEEDAMAGELOG,
                    nonMeleeDamageLog(reply.target, reply.attacker, reply.spell, reply.damage, 0, reply.absorbed,
                        0, false, 0, false));
                if (target)
                    attacker.ai.remoteWeaponSpellFinished(spell, target, cast(MeleeHitOutcome) reply.outcome,
                        reply.damage, reply.killed);
            }
            return;
        }
        foreach (ref hit; reply.retaliation)
        {
            if (!hit.damage || hit.school >= 7 || !isFinite(hit.threatFactor) || hit.threatFactor < 0
                || (hit.spell && reply.outcome != MeleeHitOutcome.block))
                continue;
            if (hit.spell)
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLNONMELEEDAMAGELOG,
                    nonMeleeDamageLog(reply.attacker, reply.target, hit.spell, hit.damage, hit.school,
                        0, 0, false, 0, false));
            else
            {
                ByteWriter log;
                log.put(reply.target);
                log.put(reply.attacker);
                log.put(hit.damage);
                log.put(hit.school);
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLDAMAGESHIELD, log.data);
            }
            auto blow = Blow.spell(hit.spell ? hit.school : 0); // Thorns uses the same damage path as on one node.
            if (highGuidOf(reply.target) == HighGuid.player)
                blow.remotePlayer = reply.target;
            blow.threat = hit.threatFactor;
            if (dealRemoteDamage(map_.unitOf(attacker), hit.damage, blow))
                return;
        }
        if (target)
            attacker.ai.remoteSwingFinished(target, cast(MeleeHitOutcome) reply.outcome, reply.damage, reply.killed);
    }

    void areaDamageArrived(ushort peer, const ref AreaDamage message)
    {
        if (!peer || !message.sequence || !world.canWrite())
            return;
        if (message.reply)
            return areaDamageLanded(peer, message);
        if (message.benefits.length || message.sequence <= lastAreaDamage.get(peer, 0))
            return;
        lastAreaDamage[peer] = message.sequence;
        if (auto map_ = world.existingMap(message.map, message.instance))
            if (map_.id == message.map)
                applyAreaDamage(peer, map_, message);
    }

    /// Resolve a prepared hit using the target now owned here. Peer zero is a local projectile impact.
    package void applyAreaDamage(ushort peer, Map map_, const ref AreaDamage message)
    {
        import std.math : isFinite, PI, sqrt;
        import dmangos.world.combat : hasInArc;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;
        import dmangos.world.relations : canAttack;
        import dmangos.world.replication : Replica;
        import dmangos.world.spellareas : admitGroundDamage, damagingGroundEffect, refreshGroundAura;
        import dmangos.world.spellcast : radius, SpellMissInfo;
        import dmangos.world.spelldamage : creatureAreaShape, creatureTargetInRange, databaseSpellEffect,
            isCreatureTargetEffect, isHostileAreaEffect, isHostileChainEffect, isRemoteLeechChannel, isTargetedProcEffect,
            namedCreatureShape, remoteTargetAuraEffects, rollRemoteAreaDamage, spellJumpRadius, unblockedAuraEffects;
        import dmangos.world.spellselection : inSpellCone, namedCreatureCenter, spellCone,
            namedCreatureRadius;
        import dmangos.world.spellids : ImplicitTarget, SpellEffect;
        import dmangos.world.unit : Blow, UnitKind, UnitRef, combatRelations;
        import dmangos.world.updatefields : TypeId, UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT, UNIT_FIELD_LEVEL;

        auto victim = map_.unit(message.target);
        if ((message.groundTick || message.playerProjectile) && !victim)
        {
            if (!message.redirectOwner)
                redirectAreaImpact(peer, map_, message);
            return;
        }
        if (!victim.alive || (victim.kind == UnitKind.player
            && (victim.session.transferring || victim.session.dueling.duelingWith(message.caster)))
            || (victim.kind == UnitKind.creature && (victim.creature.ai is null || victim.creature.ai.evading)))
            return;
        const p = victim.position;
        if ((!message.creatureCast || message.creatureArea || message.namedCreature) && !message.channelled
            && !message.playerProjectile
            && !(message.radius > 0
            && (p.x - message.x) ^^ 2 + (p.y - message.y) ^^ 2 + (p.z - message.z) ^^ 2 <= message.radius ^^ 2))
            return;
        UnitRef caster;
        if (peer)
        {
            auto copy = cast(Replica) map_.findObject(message.caster);
            if (copy is null || copy.owner != peer || (copy.fields.type != TypeId.player
                && ((!message.triggered && !message.creatureCast && !message.groundTick && !message.namedCreature)
                    || copy.fields.type != TypeId.unit)))
                return;
            caster = UnitRef.observed(copy, map_);
        }
        else
        {
            caster = map_.unit(message.caster);
            if (!caster)
                return;
        }
        const attacker = caster.combatRelations(world.client);
        const casterFields = caster.replica is null ? caster.fields : &caster.replica.fieldsOf();
        const hostile = canAttack(attacker, victim.relating(), world.client,
            world.groups.sameGroup(message.caster, message.target));
        const spell = world.data.spells.spell(message.spell);
        if (spell is null)
            return;
        if (message.namedCreature && (message.groundTick || message.creatureArea
            || message.previous))
            return;
        if ((message.channelToken != 0) != (message.namedCreature && message.channelled))
            return;
        if (message.playerProjectile && message.channelled)
            return;
        if (message.channelled)
        {
            import std.algorithm.searching : canFind;
            import dmangos.world.spellselection : namedCreatureRange;

            const named = message.namedCreature ? namedCreatureChannel(spell) : noEffect;
            const actorCanChannel = attacker.player ? !message.creatureCast : message.creatureCast && message.namedCreature;
            if (!actorCanChannel || message.triggered || message.creatureArea
                || (message.namedCreature ? named == noEffect : !isRemoteLeechChannel(*spell)))
                return;
            size_t targetEffect = noEffect;
            if (message.namedCreature)
            {
                if (victim.kind != UnitKind.creature || !world.spellScriptTargets(spell.id).canFind(victim.creature.spawn.entry))
                    return replyCreatureCast(peer, message, SpellMissInfo.evade);
                targetEffect = namedCreatureEffectFor(spell, named, victim.creature.spawn.entry);
                if (targetEffect == noEffect)
                    return replyCreatureCast(peer, message, SpellMissInfo.evade);
            }
            const operation = message.channelOperation;
            if (operation != AreaDamage.ChannelUpdate.none)
                return applyRemoteChannelUpdate(peer, message, operation, caster, victim, spell);
            const validEffect = message.namedCreature
                ? message.effect == targetEffect && message.radius == namedCreatureRange(*spell, world.client)
                    && message.auraMs > 0
                : isTargetedProcEffect(*spell, message.effect);
            if (!validEffect || casterFields.get!UNIT_CHANNEL_SPELL != message.spell
                || casterFields.get!UNIT_FIELD_CHANNEL_OBJECT != message.target)
                return;
            const origin = caster.fighter;
            const at = origin.position;
            const distance = sqrt((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2);
            if ((!message.namedCreature && !hostile) || !attacker.alive || victim.untouchable
                || !isFinite(message.radius) || message.radius <= 0
                || distance > message.radius + origin.combatReach + victim.fighter.combatReach
                || !map_.inLineOfSight(caster.position, victim.position))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            const capture = spell.id == imported!"dmangos.world.spelldamage".crystalPrison;
            if (capture && !hostile)
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            return remoteProcEffect(peer, message, spell, victim, !message.namedCreature || capture,
                attacker.hasFlag(UnitFlags.pvp));
        }
        if (message.playerProjectile)
        {
            if (!attacker.player || spell.casting.speed <= 0 || message.previous || message.creatureCast
                || message.namedCreature || message.creatureArea || message.groundTick || !message.alwaysHits
                || !isTargetedProcEffect(*spell, message.effect))
                return;
            const effect = spell.effect[message.effect];
            const shape = spell.implicitTargetA[message.effect];
            if ((shape == ImplicitTarget.enemy || effect == SpellEffect.schoolDamage) && !hostile)
                return;
            if ((effect == SpellEffect.heal || shape == ImplicitTarget.friend || shape == ImplicitTarget.unitRaid)
                && hostile)
                return;
            if (effect != SpellEffect.schoolDamage)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
        }
        else if (message.namedCreature)
        {
            import std.algorithm.searching : canFind;

            if (victim.kind != UnitKind.creature
                || message.effect != namedCreatureEffectFor(spell, namedCreatureRouting(spell), victim.creature.spawn.entry)
                || message.radius != namedCreatureRadius(*spell, message.effect, world.client)
                || !world.spellScriptTargets(spell.id).canFind(victim.creature.spawn.entry))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            const shape = namedCreatureShape(*spell, message.effect);
            if (!attacker.alive && !(message.triggered && casterFields.type == TypeId.unit
                && shape != ImplicitTarget.unitScriptNearCaster))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            if (shape == ImplicitTarget.enumUnitsScriptInCone60 && !inSpellCone(
                Position(message.x, message.y, message.z, message.facing), p, spellCone(world.data, spell.id)))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            if (shape == ImplicitTarget.enumUnitsScriptAoeAtDestLoc)
            {
                if (!world.client.isValidMapCoord(map_.id, message.x, message.y, message.z, 0))
                    return;
                if (spell.implicitTargetA[message.effect] == ImplicitTarget.database)
                {
                    Position expected;
                    if (!namedCreatureCenter(*spell, message.effect, world.client, map_.id, caster.position,
                        spell.id in world.data.spellTargets, null, expected) || message.x != expected.x || message.y != expected.y
                        || message.z != expected.z)
                        return;
                }
            }
            if (message.auraAbsent && victim.hasAuraOf(spell.id))
                return;
            const effect = spell.effect[message.effect];
            if (databaseSpellEffect(effect))
                return applyRemoteSpellScript(peer, message, spell, victim, hostile);
            if (effect != SpellEffect.schoolDamage)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
            if (!hostile)
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
        }
        else if (message.groundTick)
        {
            if (message.triggered || message.creatureCast || message.creatureArea || message.previous
                || !validGroundTick(spell, message) || !hostile || !attacker.alive || victim.untouchable)
                return;
            if (!damagingGroundEffect(*spell, message.effect))
            {
                if (refreshGroundAura(victim, spell, message.effect, message.caster, message.casterLevel,
                    message.auraMs, message.auraValues) && victim.kind == UnitKind.creature)
                {
                    const blow = Blow.spell();
                    dealRemoteDamage(caster, victim, 0, blow);
                }
                return;
            }
            if (!admitGroundDamage(victim, spell, message.caster, message.casterLevel, message.auraMs > 0 ? message.auraMs : 1))
                return;
        }
        else if (message.creatureArea)
        {
            if (casterFields.type != TypeId.unit || !hostile || !attacker.alive || victim.untouchable)
                return;
            const shape = creatureAreaShape(*spell, message.effect);
            if (shape == ImplicitTarget.none || message.radius != radius(*spell, message.effect, world.client)
                || !isFinite(message.facing))
                return;
            auto origin = caster.position;
            origin.orientation = message.facing;
            if (shape == ImplicitTarget.enemiesInCone && !imported!"dmangos.world.spellselection".inSpellCone(origin,
                    victim.position, imported!"dmangos.world.spellselection".spellCone(world.data, spell.id)))
                return;
            if (message.auraAbsent && victim.hasAuraOf(spell.id))
                return;
            if (spell.effect[message.effect] == SpellEffect.applyAura)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
        }
        else if (message.creatureCast)
        {
            if (casterFields.type != TypeId.unit || message.triggered || message.previous
                || !isCreatureTargetEffect(*spell, message.effect))
                return;
            if (!hostile || !attacker.alive || victim.untouchable
                || (message.auraAbsent && victim.hasAuraOf(spell.id))
                || !creatureTargetInRange(spell, caster.fighter, victim.fighter, world.client)
                || !map_.inLineOfSight(caster.position, victim.position))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            if (spell.effect[message.effect] == SpellEffect.applyAura)
                return remoteProcEffect(peer, message, spell, victim, hostile, false);
        }
        else if (message.triggered)
        {
            if (message.previous || !isTargetedProcEffect(*spell, message.effect))
                return;
            const effect = spell.effect[message.effect];
            const shape = spell.implicitTargetA[message.effect];
            if ((shape == ImplicitTarget.enemy || effect == SpellEffect.schoolDamage) && !hostile)
                return;
            if ((effect == SpellEffect.heal || shape == ImplicitTarget.friend || shape == ImplicitTarget.unitRaid)
                && hostile)
                return;
            if (effect != SpellEffect.schoolDamage)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
        }
        else if (!hostile)
            return;
        else if (message.previous)
        {
            if (!isHostileChainEffect(*spell, message.effect) || message.radius != spellJumpRadius
                || message.previous == message.target || message.previous == message.caster)
                return;
        }
        else if (!isHostileAreaEffect(*spell, message.effect))
            return;

        auto result = cast(AreaDamage) message; // the request holds no benefits to share with the reply
        result.reply = true;
        rollRemoteAreaDamage(result, spell, victim);
        if (!result.miss)
        {
            const honor = victim.kind == UnitKind.player ? victim.session.describeHonorVictim() : HonorVictim.init;
            auto blow = message.groundTick ? Blow.periodic(spell.casting.school)
                : Blow.spell(spell.casting.school, result.critical);
            if (peer)
                blow.remotePlayer = attacker.player ? message.caster : caster.replica.meleeController;
            blow.remotePlayerPvP = attacker.hasFlag(UnitFlags.pvp);
            blow.threat = message.threatFactor;
            blow.threatIncludesCaster = true;
            result.killed = dealRemoteDamage(peer && attacker.player ? UnitRef.init : caster, victim, result.damage, blow);
            if (victim.kind == UnitKind.player)
            {
                result.targetPvP = victim.session.isPvP;
                if (result.killed)
                {
                    result.honorless = honor.honorless;
                    result.targetRace = honor.race;
                    result.targetLevel = honor.level;
                    result.targetRank = honor.rank;
                    result.targetVisualRank = honor.visualRank;
                    result.x = honor.position.x;
                    result.y = honor.position.y;
                    result.z = honor.position.z;
                }
            }
            else if (attacker.player && result.killed && !victim.creature.petOwner)
                result.targetLevel = victim.fields.get!UNIT_FIELD_LEVEL;
            if (!message.triggered && !message.suppressProcs && victim.alive && result.damage)
            {
                const hit = ProcHit(spell, result.critical ? ProcEx.criticalHit : ProcEx.normalHit, result.damage);
                const flags = message.groundTick
                    ? imported!"dmangos.world.aurahandlers".ProcFlag.takeHarmfulPeriodic
                    : spellProcFlags(*spell, false, true);
                if (victim.kind == UnitKind.player)
                    victim.session.procAuras(flags, caster, hit);
                else
                    victim.creature.ai.procAuras(flags, caster, hit);
                result.benefits = Character.benefitsFromVictim(victim, message.caster, flags >> 1, hit);
            }
            if (message.namedCreature)
            {
                auto effects = cast(ubyte)(remoteTargetAuraEffects(*spell, message.effect)
                    & ~world.scriptTargetExclusions(spell.id, victim.creature.spawn.entry));
                if (effects && victim.alive)
                {
                    const immune = victim.fighter.immune;
                    effects = unblockedAuraEffects(*spell, effects, immune);
                    if (effects)
                        installRemoteAura(victim, message, spell, true, attacker.hasFlag(UnitFlags.pvp), message.auraMs,
                            effects);
                }
                namedCreatureHit(victim, message, spell);
            }
        }
        finishAreaDamage(peer, result);
    }

    package static bool validGroundTick(const(SpellInfo)* spell, const ref AreaDamage message)
    {
        import std.math : isFinite;
        import dmangos.world.spellids : SpellEffect;

        return spell !is null && message.effect < spell.effect.length
            && spell.effect[message.effect] == SpellEffect.persistentAreaAura && spell.casting.school < 7
            && message.radius > 0 && isFinite(message.radius) && isFinite(message.amount) && message.amount >= 0;
    }

    // The old owner declines without applying the impact. Only the source can issue a second request.
    package void redirectAreaImpact(ushort peer, Map map_, const ref AreaDamage message)
    {
        if (world.sendAreaDamage is null)
            return;
        ushort owner;
        if (const hint = world.recentHandoff(message.target))
            owner = hint.node;
        else if (auto copy = cast(Replica) map_.findObject(message.target))
            owner = copy.owner;
        if (!owner || owner == world.nodeId)
            return;
        auto redirect = cast(AreaDamage) message;
        redirect.reply = true;
        redirect.redirectOwner = owner;
        world.sendAreaDamage(peer, redirect);
    }

    package void retryGroundTick(ushort peer, const ref AreaDamage message)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellareas : admitGroundDamage, damagingGroundEffect, hitGroundTarget, refreshGroundAura, withinGroundArea;
        import dmangos.world.unit : UnitKind;

        auto map_ = world.existingMap(message.map, message.instance);
        const spell = world.data.spells.spell(message.spell);
        if (map_ is null || !validGroundTick(spell, message))
            return;
        auto unit = map_.unit(message.caster);
        if (!unit.alive)
            return;
        if (message.redirectOwner != world.nodeId)
        {
            if (world.sendAreaDamage !is null && message.redirectOwner != peer)
            {
                auto retry = cast(AreaDamage) message;
                retry.reply = false;
                retry.redirectOwner = peer;
                retry.sequence = world.nextGameplaySequence();
                world.sendAreaDamage(message.redirectOwner, retry);
            }
            return;
        }
        auto target = map_.unit(message.target);
        auto caster = unit.kind == UnitKind.player ? Caster.of(unit.session) : Caster.of(unit.creature, map_, world);
        if (!caster || !target.alive || target.untouchable
            || (target.kind == UnitKind.player && target.session.transferring)
            || (target.kind == UnitKind.creature && target.creature.ai is null)
            || !withinGroundArea(target.position, Position(message.x, message.y, message.z), message.radius)
            || !caster.hostileTo(target))
            return;
        if (damagingGroundEffect(*spell, message.effect))
        {
            if (admitGroundDamage(target, spell, caster.guid, caster.level, message.auraMs > 0 ? message.auraMs : 1))
                hitGroundTarget(caster, spell, target, message.groundAmount);
        }
        else
            refreshGroundAura(target, spell, message.effect, caster.guid, message.casterLevel,
                message.auraMs, message.auraValues);
    }

    package void applyRemoteChannelUpdate(ushort peer, const ref AreaDamage message,
        AreaDamage.ChannelUpdate operation, UnitRef caster, UnitRef victim, const(SpellInfo)* spell)
    {
        import dmangos.world.spellcast : SpellMissInfo;
        import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT;

        final switch (operation)
        {
        case AreaDamage.ChannelUpdate.none, AreaDamage.ChannelUpdate.invalid:
            return;
        case AreaDamage.ChannelUpdate.complete:
            if (message.namedCreature && caster.alive)
                applyNamedChannelCompletion(caster, victim, spell, message.channelToken);
            return;
        case AreaDamage.ChannelUpdate.cancel:
            updateRemoteChannelAura(victim, message, true);
            return;
        case AreaDamage.ChannelUpdate.shorten:
            const fields = caster.replica is null ? caster.fields : &caster.replica.fieldsOf();
            if (message.namedCreature && (fields.get!UNIT_CHANNEL_SPELL != message.spell
                || fields.get!UNIT_FIELD_CHANNEL_OBJECT != message.target))
                return;
            if (updateRemoteChannelAura(victim, message, false) && message.namedCreature)
                replyCreatureCast(peer, message, SpellMissInfo.none);
            return;
        }
    }

    package bool updateRemoteChannelAura(UnitRef victim, const ref AreaDamage message, bool cancel)
    {
        auto aura = victim.auraSet.find(message.spell, message.caster);
        if (aura is null || aura.detachedChannel || (message.namedCreature && aura.channelToken != message.channelToken))
            return false;
        if (cancel)
        {
            if (victim.kind == UnitKind.player)
                victim.session.removeAura(aura);
            else
            {
                victim.creature.loseAura(aura, victim.map);
                victim.map.flushCreature(victim.creature);
            }
        }
        else if (aura.duration > message.auraMs
            || (message.namedCreature && imported!"dmangos.world.spelldamage".permanentNamedCreatureVisual(message.spell)))
        {
            aura.duration = message.auraMs;
            if (victim.kind == UnitKind.player)
                victim.session.sendAuraDuration(aura);
        }
        return true;
    }

    package void applyNamedChannelCompletion(UnitRef caster, UnitRef victim, const(SpellInfo)* spell, ulong token)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.spelldamage : namedChannelTriggerEffect;
        import dmangos.world.spellselection : namedCreatureRange;

        const child = namedChannelCompletionSpell(spell);
        if (child is null || !world.spellScriptTargets(child.id, 0).canFind(victim.creature.spawn.entry))
            return;
        const from = caster.position, to = victim.position;
        const reach = namedCreatureRange(*spell, world.client) + caster.fighter.combatReach + victim.fighter.combatReach;
        if (!((from.x - to.x) ^^ 2 + (from.y - to.y) ^^ 2 + (from.z - to.z) ^^ 2 <= reach ^^ 2)
            || !victim.map.inLineOfSight(from, to))
            return;
        if (!victim.creature.consumeChannelCompletion(spell.id, caster.combatGuid, token,
                namedChannelTriggerEffect(*spell), world.fleet.transportNow(), victim.map))
            return;
        import dmangos.world.spelldamage : crystalPrisonCompletion, crystalPrisonConjure;

        auto creature = victim.creature;
        if (child.id == crystalPrisonCompletion && !creature.petOwner)
        {
            import dmangos.world.eventai : castTriggered;

            creature.ai.bind(victim.map);
            if (creature.ai.castSpell(world.spellInfo(crystalPrisonConjure), creature.guid, castTriggered))
            {
                creature.ai.scriptDespawn(0);
                victim.map.wake(creature.guid);
            }
        }
        else
            creature.ai.spellHitBy(caster.combatGuid, child.id, 1u << child.casting.school, victim.map);
    }

    package void replyCreatureCast(ushort peer, const ref AreaDamage message,
        imported!"dmangos.world.spellcast".SpellMissInfo miss)
    {
        if (!message.creatureCast && !message.namedCreature && !message.playerProjectile && !(message.channelled && miss))
            return;
        auto result = cast(AreaDamage) message;
        result.reply = true;
        result.miss = miss;
        finishAreaDamage(peer, result);
    }

    package void finishAreaDamage(ushort peer, AreaDamage result)
    {
        result.redirectOwner = 0;
        if (!peer)
            areaDamageLanded(0, result);
        else if (world.sendAreaDamage !is null)
            world.sendAreaDamage(peer, result);
    }

    /// Apply damage only at the target's authority. A lethal creature hit settles its tap once here.
    package bool dealRemoteDamage(UnitRef victim, uint damage, const ref imported!"dmangos.world.unit".Blow blow)
    {
        return dealRemoteDamage(UnitRef.init, victim, damage, blow);
    }

    package bool dealRemoteDamage(UnitRef attacker, UnitRef victim, uint damage,
        const ref imported!"dmangos.world.unit".Blow blow)
    {
        import dmangos.world.dbscripts : DbScriptType;
        import dmangos.world.unit : dealDamage;

        if (!victim.alive)
            return false;
        auto creature = victim.creature;
        if (blow.remotePlayer && damage && creature !is null && !creature.petOwner && !creature.lootRecipient)
        {
            auto group = world.groups.of(blow.remotePlayer);
            creature.setLootRecipient(blow.remotePlayer, group is null ? 0 : group.id);
        }
        dealDamage(attacker, victim, damage, blow);
        if (victim.alive)
            return false;
        if (blow.remotePlayer && creature !is null && !creature.petOwner)
        {
            Character.rewardCreatureKillFor(world, victim.map, creature, creature.lootRecipient);
            world.startScript(DbScriptType.creatureDeath, creature.template_.entry, victim.map, creature.guid,
                blow.remotePlayer);
        }
        return true;
    }

    /// A damage aura keeps the player who applied it as its source after their handoff.
    package void dealRemotePeriodicDamage(UnitRef victim, imported!"dmangos.world.auras".Aura aura, uint damage,
        size_t effect = 0, uint drained = 0)
    {
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.aurahandlers : ProcFlag;
        import dmangos.world.procs : ProcEx, ProcHit;
        import dmangos.world.unit : Blow;
        import dmangos.world.updatefields : TypeId, UNIT_FIELD_FLAGS;

        if (!victim.alive || !world.canWrite())
            return;
        auto blow = Blow.periodic(aura.spell.casting.school);
        blow.remotePlayer = aura.caster;
        blow.remotePlayerPvP = aura.periodicCasterPvP;
        blow.threat = aura.periodicThreat;
        auto copy = cast(Replica) victim.map.findObject(aura.caster);
        if (copy !is null && copy.fields.type == TypeId.player)
            blow.remotePlayerPvP = (copy.fields.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
        const honor = victim.kind == UnitKind.player ? victim.session.describeHonorVictim() : HonorVictim.init;
        const health = victim.health;
        const killed = dealRemoteDamage(victim, damage, blow);
        const loss = health > victim.health ? health - victim.health : 0;
        if (drained > loss)
            drained = loss;
        imported!"dmangos.cluster.protocol".RemoteSpellBenefit[] benefits;
        if (!killed && damage)
        {
            const hit = ProcHit(aura.spell, ProcEx.normalHit, damage);
            if (copy !is null && copy.fields.type == TypeId.player)
            {
                auto source = UnitRef.observed(copy, victim.map);
                if (victim.kind == UnitKind.player)
                    victim.session.procAuras(ProcFlag.takeHarmfulPeriodic, source, hit);
                else if (victim.creature.ai !is null)
                    victim.creature.ai.procAuras(ProcFlag.takeHarmfulPeriodic, source, hit);
            }
            benefits = Character.benefitsFromVictim(victim, aura.caster, ProcFlag.dealHarmfulPeriodic, hit);
        }
        reportPeriodicResult(victim, aura, effect, damage, drained, benefits);
        if (!killed || victim.kind != UnitKind.player)
            return;
        reportRemotePlayerKill(aura.caster, honor, victim.map);
    }

    package void reportRemotePlayerKill(ulong attacker, const ref imported!"dmangos.world.honor".HonorVictim honor, Map map_)
    {
        const share = KillShare(target: attacker, victim: honor.guid, level: honor.level,
            map: map_.id, instance: map_.instanceId, x: honor.position.x, y: honor.position.y,
            z: honor.position.z, race: honor.race, rank: honor.rank, visualRank: honor.visualRank,
            honorless: honor.honorless);
        if (world.onlinePlayer(attacker) !is null)
            world.killShareArrived(share);
        else if (world.killShareElsewhere !is null)
            if (const owner = world.remoteKillRecipient(attacker, map_).node)
                world.killShareElsewhere(owner, share);
    }

    package ulong[ushort] lastPeriodicResult;

    package void reportPeriodicResult(UnitRef victim, imported!"dmangos.world.auras".Aura aura, size_t effect,
        uint damage, uint drained, imported!"dmangos.cluster.protocol".RemoteSpellBenefit[] benefits = null)
    {
        if ((!damage && !drained) || !world.canWrite())
            return;
        const message = PeriodicResult(sequence: world.nextGameplaySequence(), caster: aura.caster,
            target: victim.combatGuid, map: victim.map.id, instance: victim.map.instanceId, spell: aura.spell.id,
            effect: cast(ubyte) effect, damage: damage, drained: drained, targetAlive: victim.alive,
            detached: aura.detachedChannel, benefits: benefits);
        if (world.onlinePlayer(aura.caster) !is null)
            return applyPeriodicResult(message);
        if (world.sendPeriodicResult !is null)
            if (const owner = world.remoteKillRecipient(aura.caster, victim.map).node)
                world.sendPeriodicResult(owner, message);
    }

    void periodicResultArrived(ushort peer, const ref PeriodicResult message)
    {
        if (!peer || !message.sequence || !world.canWrite() || message.sequence <= lastPeriodicResult.get(peer, 0))
            return;
        lastPeriodicResult[peer] = message.sequence;
        if (world.onlinePlayer(message.caster) !is null)
            return applyPeriodicResult(message);
        if (!message.forwarded && world.sendPeriodicResult !is null)
            if (const hint = world.recentHandoff(message.caster))
            {
                auto onward = cast(PeriodicResult) message;
                onward.sequence = world.nextGameplaySequence();
                onward.forwarded = true;
                world.sendPeriodicResult(hint.node, onward);
            }
    }

    package void applyPeriodicResult(const ref PeriodicResult message)
    {
        import dmangos.world.auras : AuraType;
        import dmangos.world.caster : Caster;
        import dmangos.world.defines : Power;
        import dmangos.world.spelldamage : changeUnitPower, effectMultiplier, SpellHeal, spellHeal;
        import dmangos.world.spellmods : SpellModOp;
        import dmangos.world.updatefields : UNIT_FIELD_MAXPOWER1;

        auto source = world.onlinePlayer(message.caster);
        const spell = world.data.spells.spell(message.spell);
        if (source is null || source.player is null || !source.player.alive || spell is null
            || message.effect >= spell.effect.length || message.target == message.caster)
            return;
        if ((spell.attributesEx & (0x04 | 0x40)) && !message.detached
            && source.channelledAt(spell) != message.target)
            return;
        foreach (ref benefit; message.benefits)
            source.applySpellBenefit(benefit);
        auto caster = Caster.of(source);
        const i = message.effect;
        switch (spell.casting.applyAuraName[i])
        {
        case AuraType.periodicLeech:
            // Only a caster still on the drained target's map takes the life (as a local drain's does).
            if (auto drainedOn = world.existingMap(message.map, message.instance))
                if (drainedOn is source.currentMap)
                {
                    const factor = spell.casting.multipleValue[i] > 0 ? spell.casting.multipleValue[i] : 1.0f;
                    spellHeal(caster, spell, caster.unit, cast(int)(message.drained
                        * caster.spellMod(SpellModOp.multipleValue, spell, factor)), SpellHeal(true));
                }
            goto case AuraType.periodicDamage;
        case AuraType.periodicDamage:
            auto map_ = world.existingMap(message.map, message.instance);
            if (message.targetAlive && map_ !is null && map_ is source.currentMap)
            {
                auto target = map_.unit(message.target);
                if (!target)
                    if (auto copy = cast(Replica) map_.findObject(message.target))
                        target = UnitRef.observed(copy, map_);
                caster.damageDealt(spell, target, false, message.damage, true);
            }
            break;
        case AuraType.periodicManaLeech:
            // Like the life drain above: only a caster still on the drained target's map takes the power.
            auto drainedFrom = world.existingMap(message.map, message.instance);
            if (drainedFrom !is null && drainedFrom is source.currentMap
                && spell.miscValue[i] >= 0 && spell.miscValue[i] <= Power.happiness)
            {
                const power = cast(Power) spell.miscValue[i];
                if (caster.fields.get!UNIT_FIELD_MAXPOWER1(power))
                {
                    const gain = cast(int)(message.drained * effectMultiplier(caster, spell, i));
                    if (gain > 0)
                    {
                        changeUnitPower(caster, caster.unit, power, gain);
                        caster.flush();
                    }
                }
            }
            break;
        default:
            break;
        }
    }


    package static void namedCreatureHit(UnitRef victim, const ref AreaDamage message, const(SpellInfo)* spell)
    {
        if (victim.creature.alive)
            victim.creature.ai.spellHitBy(message.caster, spell.id, 1u << spell.casting.school, victim.map);
    }

    package void areaDamageLanded(ushort peer, const ref AreaDamage message)
    {
        import dmangos.world.aurahandlers : ProcFlag;
        import dmangos.world.experience : grayLevel;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;
        import dmangos.world.replication : Replica;
        import dmangos.world.spellcast : healLog, nonMeleeDamageLog, spellMissLog, SpellMissInfo;
        import dmangos.world.spellids : SpellEffect;
        import dmangos.world.spelldamage : databaseSpellEffect;
        import dmangos.world.unit : UnitRef;

        if (peer)
        {
            if (message.sequence <= lastAreaDamageReply.get(peer, 0))
                return;
            lastAreaDamageReply[peer] = message.sequence;
        }
        if (message.groundTick && message.redirectOwner)
            return retryGroundTick(peer, message);
        if (message.playerProjectile && message.redirectOwner)
        {
            if (auto map_ = world.existingMap(message.map, message.instance))
                if (map_.unit(message.caster) && message.redirectOwner != peer)
                {
                    auto retry = cast(AreaDamage) message;
                    retry.reply = false;
                    retry.redirectOwner = peer;
                    if (message.redirectOwner == world.nodeId)
                        applyAreaDamage(0, map_, retry);
                    else if (const spell = world.data.spells.spell(message.spell))
                        sendReplicaSpell(map_, message.redirectOwner, spell, retry);
                }
            return;
        }
        if ((message.triggered || message.creatureCast || message.groundTick || message.namedCreature)
            && message.caster > uint.max)
            return creatureProcLanded(peer, message);
        auto caster = world.onlinePlayer(message.caster);
        if (caster is null || caster.player is null || caster.transferring
            || caster.currentMap.id != message.map || caster.currentMap.instanceId != message.instance)
            return;
        const spell = world.data.spells.spell(message.spell);
        if (spell is null || message.miss > SpellMissInfo.reflect)
            return;
        auto map_ = caster.currentMap;
        if (message.channelled)
        {
            if (message.namedCreature && !caster.namedChannelActiveAt(spell, message.target, message.channelToken))
                return;
            if (message.miss && caster.channelActiveAt(spell, message.target))
            {
                map_.sendToWatchers(caster, Opcode.SMSG_SPELLLOGMISS,
                    spellMissLog(message.spell, message.caster, message.target, cast(SpellMissInfo) message.miss), true);
                caster.endChannel(true);
            }
            else if (message.namedCreature && !message.miss)
                caster.remoteChannelAccepted(spell, message.target, peer);
            return;
        }
        if (message.namedCreature && !message.miss && message.effect < spell.effect.length)
        {
            caster.rewardPlayerAndGroupAtCast(message.target, spell.id, peer);
            if (spell.effect[message.effect] == SpellEffect.applyAura || databaseSpellEffect(spell.effect[message.effect]))
                return;
        }
        if (!message.miss && (message.triggered || message.namedCreature || message.playerProjectile)
            && message.effect < spell.effect.length
            && spell.effect[message.effect] == SpellEffect.heal)
            return map_.sendToWatchers(caster, Opcode.SMSG_SPELLHEALLOG,
                healLog(message.target, message.caster, message.spell, message.damage, message.critical), true);
        if (message.miss)
            return map_.sendToWatchers(caster, Opcode.SMSG_SPELLLOGMISS,
                spellMissLog(message.spell, message.caster, message.target, cast(SpellMissInfo) message.miss), true);
        if (message.playerProjectile && message.effect < spell.effect.length
            && spell.effect[message.effect] == SpellEffect.applyAura)
            return;
        if (caster.player.alive)
        {
            caster.enterCombatFor(Character.combatLinger);
            if (message.targetPvP)
                caster.attackedFlaggedPlayer();
            if (peer && message.damage && !message.groundTick)
                caster.wearOnHit();
        }
        if (peer && message.killed && message.target <= uint.max)
            caster.playerKilledByMe(HonorVictim(message.target, message.targetLevel, message.targetRace,
                message.targetRank, message.targetVisualRank, message.honorless, Position(message.x, message.y, message.z)));
        else if (peer && !message.triggered && !message.suppressProcs && message.killed
            && message.targetLevel > grayLevel(caster.player.data.level))
            caster.procAuras(ProcFlag.kill, UnitRef.init);
        map_.sendToWatchers(caster, Opcode.SMSG_SPELLNONMELEEDAMAGELOG,
            nonMeleeDamageLog(message.target, message.caster, message.spell, message.damage, spell.casting.school,
                message.absorbed, message.resisted, false, 0, message.critical), true);
        if (message.groundTick)
        {
            foreach (ref benefit; message.benefits)
                caster.applySpellBenefit(benefit);
            if (!message.killed)
                if (auto copy = cast(Replica) map_.findObject(message.target))
                    if (copy.owner == peer)
                    {
                        auto target = UnitRef.observed(copy, map_);
                        caster.procAuras(ProcFlag.dealHarmfulPeriodic, target,
                            ProcHit(spell, ProcEx.normalHit, message.damage, 0, message.damage != 0));
                        caster.classAreaTick(spell, target);
                    }
            return;
        }
        if (!message.triggered && !message.suppressProcs && !message.killed)
            if (auto other = spellImpactTarget(map_, peer, message.target))
            {
                caster.procAuras(spellProcFlags(*spell, false, false), other,
                    ProcHit(spell, message.critical ? ProcEx.criticalHit : ProcEx.normalHit, message.damage,
                        0, message.damage != 0));
                foreach (ref benefit; message.benefits)
                    caster.applySpellBenefit(benefit);
                caster.targetTriggers(spell, [message.target], other);
            }
    }

    package static UnitRef spellImpactTarget(Map map_, ushort peer, ulong guid)
    {
        import dmangos.world.replication : Replica;

        if (!peer)
            return map_.unit(guid);
        if (auto copy = cast(Replica) map_.findObject(guid))
            if (copy.owner == peer)
                return UnitRef.observed(copy, map_);
        return UnitRef.init;
    }

    package void creatureProcLanded(ushort peer, const ref AreaDamage message)
    {
        import dmangos.world.spellcast : healLog, nonMeleeDamageLog, spellGoPacket, spellMissLog, SpellMissInfo,
            SpellTargets, TargetFlags, TargetResult;
        import dmangos.world.spellids : SpellEffect;

        auto map_ = world.existingMap(message.map, message.instance);
        if (map_ is null || map_.id != message.map)
            return;
        auto caster = map_.creatureAt(message.caster);
        if (message.channelled)
        {
            if (message.miss && caster !is null && caster.ai !is null)
                caster.ai.namedCreatureChannelRejected(message.channelToken);
            return;
        }
        auto target = spellImpactTarget(map_, peer, message.target);
        const spell = world.data.spells.spell(message.spell);
        if (caster is null || !target || spell is null || message.effect >= spell.effect.length
            || message.miss > SpellMissInfo.reflect)
            return;
        if (message.creatureCast && !message.creatureArea && !message.namedCreature)
        {
            const targets = SpellTargets(TargetFlags.unit, message.target);
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELL_GO, spellGoPacket(message.caster, message.spell,
                [TargetResult(message.target, cast(SpellMissInfo) message.miss)], targets));
        }
        if (message.namedCreature && !message.miss && caster.ai !is null)
            caster.ai.remoteNamedSpellHit(message.target, spell);
        if (message.miss)
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELLLOGMISS,
                spellMissLog(message.spell, message.caster, message.target, cast(SpellMissInfo) message.miss));
        else if (spell.effect[message.effect] == SpellEffect.heal)
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELLHEALLOG,
                healLog(message.target, message.caster, message.spell, message.damage, message.critical));
        else if (spell.effect[message.effect] == SpellEffect.schoolDamage || message.groundTick)
        {
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(message.target,
                message.caster, message.spell, message.damage, spell.casting.school, message.absorbed,
                message.resisted, false, 0, message.critical));
            if ((message.creatureCast || message.groundTick) && caster.alive && caster.ai !is null)
                caster.ai.remoteSpellDamageDealt(spell, target, message.critical, message.damage,
                    message.killed);
        }
    }

    private ulong[ushort] lastPartyHeal, lastPartyHealReply;

    package bool sameAuraSubgroup(ulong controller, ulong recipient, uint groupId)
    {
        auto group = world.groups.of(recipient);
        return group !is null && group.id == groupId && group.isMember(controller)
            && group.subGroupOf(controller) == group.subGroupOf(recipient);
    }

    void partyAreaAuraArrived(ushort peer, const ref imported!"dmangos.cluster.protocol".PartyAreaAura renewal)
    {
        import dmangos.world.replication : Replica;
        import dmangos.world.updatefields : TypeId, UNIT_FIELD_HEALTH, UNIT_FIELD_SUMMONEDBY;

        if (!peer || !world.canWrite() || !sameAuraSubgroup(renewal.controller, renewal.target, renewal.group))
            return;
        auto member = world.onlinePlayer(renewal.target);
        if (member is null || member.player is null || !member.player.alive || member.transferring)
            return;
        auto map_ = member.currentMap;
        if (map_.id != renewal.map || map_.instanceId != renewal.instance)
            return;
        auto source = cast(Replica) map_.findObject(renewal.source);
        if (source is null || source.owner != peer || !source.fields.get!UNIT_FIELD_HEALTH)
            return;
        if (renewal.controller == renewal.source ? source.fields.type != TypeId.player
            : source.fields.type != TypeId.unit || source.fields.get!UNIT_FIELD_SUMMONEDBY != renewal.controller)
            return;
        if (const spell = world.data.spells.spell(renewal.spell))
            member.renewPartyAreaAura(spell, renewal);
    }



    void mindVisionTargetArrived(ushort peer, const ref MindVisionTarget message)
    {
        import dmangos.world.replication : encodePlayerState;
        import dmangos.world.spellids : AuraType;

        if (!peer || !message.sequence || !message.caster || !message.target || !world.canWrite())
            return;
        if (message.reply)
        {
            if (auto caster = world.onlinePlayer(message.caster))
                caster.mindVisionTargetFound(peer, message);
            return;
        }
        if (message.state.length || world.sendMindVisionTarget is null)
            return;
        auto reply = MindVisionTarget(message.caster, message.target, message.sequence, message.map, message.instance, true);
        if (auto target = world.onlinePlayer(message.target))
            if (target.player !is null && !target.transferring && target.player.alive && !target.player.gmInvisible
                && !target.player.auras.hasType(AuraType.modStealth) && !target.player.auras.hasType(AuraType.modInvisibility)
                && target.currentMap.id == message.map && target.currentMap.instanceId == message.instance)
                reply.state = encodePlayerState(target.player, 0).dup;
        world.sendMindVisionTarget(peer, reply);
    }

    void totemWeaponEnchantArrived(ushort peer, const ref TotemWeaponEnchant pulse)
    {
        import dmangos.world.replication : Replica;
        import dmangos.world.spellcast : radius;
        import dmangos.world.spellids : AuraType;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId, UNIT_FIELD_HEALTH, UNIT_FIELD_SUMMONEDBY;

        if (!peer || !world.canWrite() || pulse.auraEffect >= 3 || pulse.weaponEffect >= 3
            || !sameAuraSubgroup(pulse.controller, pulse.target, pulse.group))
            return;
        auto member = world.onlinePlayer(pulse.target);
        if (member is null || member.player is null || !member.player.alive || member.transferring
            || member.dueling.duelingWith(pulse.controller))
            return;
        auto map_ = member.currentMap;
        if (map_.id != pulse.map || map_.instanceId != pulse.instance)
            return;
        auto totem = cast(Replica) map_.findObject(pulse.totem);
        if (totem is null || totem.owner != peer || totem.fields.type != TypeId.unit
            || !totem.fields.get!UNIT_FIELD_HEALTH || totem.fields.get!UNIT_FIELD_SUMMONEDBY != pulse.controller)
            return;
        const totemSpells = totem.fields.get!OBJECT_FIELD_ENTRY in world.data.creatureControlSpells;
        if (totemSpells is null || (*totemSpells)[0] != pulse.aura)
            return;
        const aura = world.spellInfo(pulse.aura);
        if (aura is null || aura.casting.applyAuraName[pulse.auraEffect] != AuraType.periodicTriggerSpell)
            return;
        const spell = world.spellInfo(aura.triggerSpell[pulse.auraEffect]);
        if (spell is null || spell.effect[pulse.weaponEffect] != SpellEffect.enchantHeldItem)
            return;
        const duration = cast(int) (pulse.expires - world.fleet.transportNow());
        if (duration <= 0 || duration > aura.casting.amplitude[pulse.auraEffect] * 2)
            return;
        const reach = radius(*spell, pulse.weaponEffect, world.client);
        const at = totem.position, where = member.player.position;
        if ((at.x - where.x) ^^ 2 + (at.y - where.y) ^^ 2 + (at.z - where.z) ^^ 2 <= reach * reach)
            member.enchanting.enchantWeaponFromTotem(spell.miscValue[pulse.weaponEffect], duration);
    }

    void partyHealArrived(ushort peer, const ref PartyHeal message)
    {
        import std.algorithm.comparison : max;
        import dmangos.world.replication : Replica;
        import dmangos.world.spelldamage : applyHealAmount, isChainHealEffect, isPartyHealEffect, spellJumpRadius,
            withinPartyHealRadius;
        import dmangos.world.spellids : SpellEffect;
        import dmangos.world.unit : UnitRef;
        import dmangos.world.updatefields : TypeId;

        if (!peer || !message.sequence || !world.canWrite())
            return;
        if (message.landed)
            return partyHealLanded(peer, message);
        if (message.sequence <= lastPartyHeal.get(peer, 0))
            return;
        // Record refused deliveries too: a recipient moving or rejoining cannot revive an old heal.
        lastPartyHeal[peer] = message.sequence;
        auto target = world.onlinePlayer(message.target);
        if (target is null || target.player is null || !target.player.alive || target.transferring
            || target.currentMap.id != message.map || target.currentMap.instanceId != message.instance
            || !withinPartyHealRadius(message, target.player.position))
            return;
        auto group = world.groups.of(message.caster);
        if (group is null || group.id != message.group || !group.isMember(message.target)
            || message.caster == message.target)
            return;
        const spell = world.data.spells.spell(message.spell);
        if (spell is null || !message.amount)
            return;
        if (message.previous)
        {
            if (!isChainHealEffect(*spell, message.effect) || message.radius != spellJumpRadius
                || message.previous == message.target || !group.isMember(message.previous)
                || target.dueling.duelingWith(message.caster))
                return;
        }
        else if (!isPartyHealEffect(*spell, message.effect)
            || group.subGroupOf(message.caster) != group.subGroupOf(message.target))
            return;
        enum uint noImmunities = 0x20000000;
        const immune = target.unit.fighter.immune;
        if (!(spell.attributes & noImmunities) && immune.any && immune.toEffect(SpellEffect.heal,
            spell.casting.effectMechanic[message.effect], spell.casting.applyAuraName[message.effect]))
            return;
        PartyHeal result = message;
        uint restored;
        result.amount = applyHealAmount(spell, target.unit, message.amount, restored);
        target.flushPlayerChanges();
        if (auto copy = cast(Replica) target.currentMap.findObject(message.caster))
            if (copy.owner == peer && copy.fields.type == TypeId.player)
            {
                const helper = copy.playerRelations(world.client);
                const threat = cast(uint) max(0, restored * message.threatFactor + message.threatFlat);
                result.causedThreat = imported!"dmangos.world.creatureai".assistThreat(target.currentMap, target.threateners,
                    UnitRef.observed(copy, target.currentMap), threat, *spell, &helper);
            }
        result.landed = true;
        result.pvp = target.isPvP;
        result.contested = target.isPvPContested;
        result.inPvPCombat = target.inPvPCombat;
        if (world.sendPartyHeal !is null)
            world.sendPartyHeal(peer, result);
    }

    private void partyHealLanded(ushort peer, const ref PartyHeal message)
    {
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;
        import dmangos.world.replication : Replica;
        import dmangos.world.spellcast : healLog;
        import dmangos.world.unit : UnitRef;

        if (message.sequence <= lastPartyHealReply.get(peer, 0))
            return;
        lastPartyHealReply[peer] = message.sequence;
        auto caster = world.onlinePlayer(message.caster);
        if (caster is null || caster.player is null || caster.transferring
            || caster.currentMap.id != message.map || caster.currentMap.instanceId != message.instance)
            return;
        caster.pvpAssisted(message.pvp, message.contested, message.inPvPCombat);
        if (message.causedThreat && caster.player.alive)
            caster.enterCombatFor(Character.combatLinger);
        caster.flushPlayerChanges();
        caster.currentMap.sendToWatchers(caster, Opcode.SMSG_SPELLHEALLOG,
            healLog(message.target, message.caster, message.spell, message.amount, message.critical), true);
        if (message.suppressProcs)
            return;
        if (const spell = world.data.spells.spell(message.spell))
            if (auto copy = cast(Replica) caster.currentMap.findObject(message.target))
                if (copy.owner == peer)
                    caster.procAuras(spellProcFlags(*spell, true, false), UnitRef.observed(copy, caster.currentMap),
                        ProcHit(spell, message.critical ? ProcEx.criticalHit : ProcEx.normalHit, message.amount,
                            0, message.amount != 0));
    }
    package void applyRemoteSpellScript(ushort peer, const ref AreaDamage message, const(SpellInfo)* spell,
        UnitRef victim, bool hostile)
    {
        import dmangos.world.combat : Fighter;
        import dmangos.world.spellcast : rollSpellHit, SpellMissInfo;

        const i = message.effect;
        const school = spell.casting.school;
        const target = victim.fighter;
        enum uint noImmunities = 0x20000000;
        if (!(spell.attributes & noImmunities) && (target.immune.toSpell(school, spell.casting.dispel, spell.casting.mechanic)
            || target.immune.toEffect(spell.effect[i], spell.casting.effectMechanic[i], spell.casting.applyAuraName[i])))
            return world.remoteSpells.replyCreatureCast(peer, message, SpellMissInfo.immune);
        if (hostile && !message.alwaysHits)
        {
            const player = message.caster <= uint.max;
            const caster = Fighter(guid: message.caster, player: player, playerControlled: player, level: message.casterLevel);
            const miss = rollSpellHit(caster, target, *spell, victim.resistance(school), message.hitBonus, victim.map.random());
            if (miss)
                return world.remoteSpells.replyCreatureCast(peer, message, miss);
        }
        world.applyTargetSpellScript(spell.id, victim.map, message.caster, message.target);
        if (victim.map.creatureAt(message.target) is victim.creature)
            world.remoteSpells.namedCreatureHit(victim, message, spell);
        world.remoteSpells.replyCreatureCast(peer, message, SpellMissInfo.none);
    }

    package void remoteProcEffect(ushort peer, const ref AreaDamage message, const(SpellInfo)* spell,
        UnitRef victim, bool hostile, bool casterPvP)
    {
        import std.algorithm.comparison : max;
        import dmangos.world.combat : Fighter;
        import dmangos.world.spellcast : rollSpellHit, SpellMissInfo;
        import dmangos.world.spelldamage : applyHealAmount, remoteTargetAuraEffects, unblockedAuraEffects;
        import dmangos.world.spellids : SpellEffect;
        import dmangos.world.unit : UnitKind;

        const i = message.effect;
        const school = spell.casting.school;
        const immune = victim.fighter.immune;
        enum uint noImmunities = 0x20000000;
        const checksImmunity = !(spell.attributes & noImmunities);
        if (checksImmunity && immune.toSpell(school, spell.casting.dispel, spell.casting.mechanic))
            return world.remoteSpells.replyCreatureCast(peer, message, SpellMissInfo.immune);
        if (spell.effect[i] == SpellEffect.heal)
        {
            if (checksImmunity && immune.toEffect(SpellEffect.heal, spell.casting.effectMechanic[i],
                spell.casting.applyAuraName[i]))
                return;
            auto result = cast(AreaDamage) message;
            result.reply = true;
            uint restored;
            result.damage = applyHealAmount(spell, victim, cast(uint) max(0, message.amount), restored);
            if (victim.kind == UnitKind.player)
            {
                if (restored && (spell.implicitTargetA[i] == ImplicitTarget.friend
                    || (spell.implicitTargetA[i] == ImplicitTarget.unitFriendChainHeal && spell.casting.chainTarget[i] <= 1)))
                    victim.session.outsideQuestAid(message.caster);
                victim.session.flushPlayerChanges();
            }
            else
                victim.map.flushObjectChanges(victim.creature);
            if (message.namedCreature)
                world.remoteSpells.namedCreatureHit(victim, message, spell);
            world.remoteSpells.finishAreaDamage(peer, result);
            return;
        }
        if (hostile && !message.alwaysHits)
        {
            const isPlayer = message.caster <= uint.max;
            const caster = Fighter(guid: message.caster, player: isPlayer, playerControlled: isPlayer,
                level: message.casterLevel);
            if (school >= 7)
                return world.remoteSpells.replyCreatureCast(peer, message, SpellMissInfo.immune);
            const missed = rollSpellHit(caster, victim.fighter, *spell, victim.resistance(school),
                message.hitBonus, victim.map.random());
            if (missed)
                return world.remoteSpells.replyCreatureCast(peer, message, missed);
        }
        int lasts = message.auraMs;
        if (hostile && lasts > 0 && message.caster <= uint.max && victim.kind == UnitKind.player)
        {
            lasts = victim.session.diminishedDuration(spell, lasts);
            if (!lasts)
                return;
        }
        auto mask = remoteTargetAuraEffects(*spell, i);
        if (message.namedCreature)
            mask &= cast(ubyte) ~world.scriptTargetExclusions(spell.id, victim.creature.spawn.entry);
        const effects = unblockedAuraEffects(*spell, mask, immune);
        if (!effects)
            return world.remoteSpells.replyCreatureCast(peer, message, SpellMissInfo.immune);
        installRemoteAura(victim, message, spell, hostile, casterPvP, lasts, effects);
        if (message.namedCreature && spell.id == imported!"dmangos.world.spelldamage".crystalPrison
            && victim.kind == UnitKind.creature && !victim.creature.petOwner && message.amount > 0)
        {
            auto ai = victim.creature.ai;
            if (auto source = victim.map.unit(message.caster))
            {
                ai.attackedBy(source, victim.map);
                ai.addThreat(source, message.amount);
            }
            else if (auto mirror = cast(imported!"dmangos.world.replication".Replica) victim.map.findObject(message.caster))
            {
                ai.attackedBy(UnitRef.observed(mirror, victim.map), victim.map);
                ai.addRemoteThreat(message.caster, message.amount);
            }
            victim.map.wake(victim.creature.guid);
        }
        if (message.namedCreature)
            world.remoteSpells.namedCreatureHit(victim, message, spell);
        world.remoteSpells.replyCreatureCast(peer, message, SpellMissInfo.none);
    }

    package static void installRemoteAura(UnitRef victim, const ref AreaDamage message, const(SpellInfo)* spell,
        bool hostile, bool casterPvP, int lasts, ubyte effects)
    {
        import dmangos.world.auras : AuraType, makeAura;
        import dmangos.world.unit : UnitKind;

        auto aura = makeAura(spell, message.caster, message.casterLevel, lasts, !hostile, message.auraValues);
        aura.effects = effects;
        aura.detachedChannel = message.triggered;
        aura.channelToken = message.channelToken;
        if (aura.has(AuraType.periodicDamage) || aura.has(AuraType.periodicLeech))
        {
            aura.periodicThreat = message.threatFactor;
            aura.periodicResistanceMod = message.resistanceModifier;
            aura.periodicCasterPvP = casterPvP;
        }
        if (victim.kind == UnitKind.player)
        {
            if (message.creatureCast)
                victim.hostileSpellLanded();
            victim.session.addAura(aura);
        }
        else
        {
            bool added;
            victim.creature.receiveAura(aura, victim.map, added);
            victim.map.flushObjectChanges(victim.creature);
        }
    }
}
