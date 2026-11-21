/// Select the living creatures named by spell_script_target.
module dmangos.world.spellselection;

import std.algorithm.comparison : max;
import std.algorithm.searching : canFind;
import dmangos.world.clientdata : ClientData;
import dmangos.world.creatureai : CombatWorld;
import dmangos.world.map : Map;
import dmangos.world.movement : Position;
import dmangos.world.spellcast : range;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitRef;

package float namedCreatureRange(const ref SpellInfo spell, const ClientData client)
{
    return max(5.0f, range(spell, client)[1]);
}

/// Compare owned and observed creatures by distance, with a stable tie break.
package UnitRef nearestNamedCreature(CombatWorld world, Position center, float radius, const(uint)[] entries,
    ulong caster, bool acrossNodes)
{
    import dmangos.world.replication : Replica;
    import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

    UnitRef nearest;
    if (!entries.length)
        return nearest;
    float best = radius ^^ 2;
    void consider(UnitRef candidate, uint entry)
    {
        if (candidate.combatGuid == caster || !candidate.alive || !entries.canFind(entry))
            return;
        const p = candidate.position;
        const dist = (p.x - center.x) ^^ 2 + (p.y - center.y) ^^ 2 + (p.z - center.z) ^^ 2;
        if (dist < best || (dist == best && (!nearest || candidate.combatGuid < nearest.combatGuid)))
        {
            best = dist;
            nearest = candidate;
        }
    }
    foreach (creature; world.creaturesNear(center, radius))
        consider(world.unitOf(creature), creature.spawn.entry);
    if (acrossNodes)
        if (auto map = cast(Map) world)
            foreach (object; map.objectsNear(center, radius))
                if (auto copy = cast(Replica) object)
                    if (copy.fields.type == TypeId.unit)
                        consider(UnitRef.observed(copy, map), copy.fields.get!OBJECT_FIELD_ENTRY);
    return nearest;
}

/// A player and an NPC choose a nearby named replica, with the effects applied only by its owner.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.cluster.protocol : AreaDamage, decode;
    import dmangos.dbc : buildDbc;
    import dmangos.serialization : serialize;
    import dmangos.world.clientdata : spellDurationFormat;
    import dmangos.world.context : WorldContext;
    import dmangos.world.creature : Creature, CreatureSpawn;
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.player : Player;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.spellcast : SpellMissInfo, SpellTargets, TargetFlags, spellAttrEx2CantCrit,
        spellAttrEx3AlwaysHit;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, ImplicitTarget, SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    auto db = newDatabase();
    auto source = newCreationContext(db), owner = newCreationContext(db);
    source.nodeId = 1;
    owner.nodeId = 2;
    enum uint ward = 55060, heal = 55061;
    foreach (node; [source, owner])
    {
        node.client.spellDurations = typeof(node.client.spellDurations).parse(buildDbc(spellDurationFormat,
            [[1u, 10_000, 0, 10_000]]), "SpellDuration.dbc");
        auto aura = testSpell(ward, SpellEffect.applyAura, ImplicitTarget.unitScriptNearCaster, 10);
        aura.effect[1] = SpellEffect.applyAura;
        aura.implicitTargetA[1] = ImplicitTarget.unitScriptNearCaster;
        aura.basePoints[1] = 19;
        aura.baseDice[1] = 1;
        aura.casting.applyAuraName[0] = AuraType.modResistance;
        aura.casting.applyAuraName[1] = AuraType.modStat;
        aura.casting.durationIndex = 1;
        aura.casting.stackAmount = 3;
        aura.casting.school = 1;
        aura.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
        node.data.spells.spells[ward] = aura;
        auto healing = testSpell(heal, SpellEffect.heal, ImplicitTarget.unitScriptNearCaster, 20);
        healing.attributesEx2 |= spellAttrEx2CantCrit;
        healing.casting.school = 1;
        node.data.spells.spells[heal] = healing;
        node.data.spellScriptTargets[ward] = node.data.spellScriptTargets[heal] = [creatureInnkeeper];
    }

    const at = Position(100, 100, 40);
    auto caster = loggedIn(source, db, 7, "Anduin", at);
    auto player = cast(Player) caster.session.character;
    player.spells ~= ward;
    Creature npc(WorldContext context, uint id, uint entry, float dx)
    {
        const spawn = CreatureSpawn(id, entry, 0, at.x + dx, at.y, at.z);
        auto creature = context.makeCreature(&spawn);
        context.map(0).addObject(creature);
        return creature;
    }

    auto farther = npc(source, 91000, creatureInnkeeper, 4);
    auto remote = npc(owner, 91001, creatureInnkeeper, 3);
    auto wrong = npc(owner, 91002, creatureTrainer, 1);
    auto npcCaster = npc(source, 91003, creatureTrainer, 0);
    auto from = source.map(0), to = owner.map(0);
    to.replicaCreated(1, cellKeyAt(at.x, at.y), player.guid, encodePlayerState(player, 0));
    to.replicaCreated(1, cellKeyAt(at.x, at.y), npcCaster.guid, encodeState(npcCaster, 0));
    foreach (creature; [wrong, remote])
        from.replicaCreated(2, cellKeyAt(creature.position.x, creature.position.y), creature.guid,
            encodeState(creature, 0));

    AreaDamage[] requests, results;
    source.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
        assert(peer == 2 && request.namedCreature && !request.reply);
        ByteWriter bytes;
        serialize(bytes, request);
        requests ~= decode!AreaDamage(bytes.data);
        return true;
    };
    owner.sendAreaDamage = (ushort peer, const ref AreaDamage result) {
        assert(peer == 1 && result.reply);
        results ~= cast(AreaDamage) result;
        return true;
    };
    ByteWriter castPacket;
    castPacket.put(ward);
    SpellTargets(TargetFlags.self, 0).write(castPacket);
    caster.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    assert(requests.length == 1 && requests[0].target == remote.guid && !farther.auras.find(ward));
    owner.areaDamageArrived(1, requests[0]);
    owner.areaDamageArrived(1, requests[0]);
    auto aura = remote.auras.find(ward);
    assert(aura && aura.caster == player.guid && aura.effects == 3 && aura.stacks == 1);
    assert(results.length == 1 && results[0].miss == SpellMissInfo.none);
    assert(!wrong.auras.find(ward));

    auto wrongEntry = requests[0];
    wrongEntry.target = wrong.guid;
    wrongEntry.sequence = source.nextGameplaySequence();
    owner.areaDamageArrived(1, wrongEntry);
    assert(!wrong.auras.find(ward) && results.length == 2 && results[1].miss == SpellMissInfo.evade);

    assert(npcCaster.ai.spellCaster(from));
    remote.values.set!UNIT_FIELD_MAXHEALTH(100u);
    remote.values.set!UNIT_FIELD_HEALTH(40u);
    assert(npcCaster.ai.castSpell(source.data.spells.spell(heal), npcCaster.guid, castTriggered));
    assert(requests.length == 2 && requests[1].target == remote.guid && requests[1].caster == npcCaster.guid);
    remote.movement.position.x = at.x + 10;
    owner.areaDamageArrived(1, requests[1]);
    assert(remote.values.get!UNIT_FIELD_HEALTH == 40u && results.length == 2, "owner checks current range");
    remote.movement.position.x = at.x + 3;
    assert(npcCaster.ai.castSpell(source.data.spells.spell(heal), npcCaster.guid, castTriggered));
    assert(requests.length == 3);
    owner.areaDamageArrived(1, requests[2]);
    owner.areaDamageArrived(1, requests[2]);
    assert(remote.values.get!UNIT_FIELD_HEALTH == 60u && results.length == 3);
}
