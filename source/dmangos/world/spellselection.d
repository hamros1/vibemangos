/// Select the living creatures named by spell_script_target.
module dmangos.world.spellselection;

import std.algorithm.comparison : max;
import std.algorithm.searching : canFind;
import dmangos.world.clientdata : ClientData;
import dmangos.world.creatureai : CombatWorld;
import dmangos.world.map : Map;
import dmangos.world.movement : Position;
import dmangos.world.spellcast : radius, range, SpellTargets, TargetFlags;
import dmangos.world.spelldamage : namedCreatureShape;
import dmangos.world.spellids : ImplicitTarget;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitRef;
import dmangos.world.worlddata : SpellTarget;

package float namedCreatureRange(const ref SpellInfo spell, const ClientData client)
{
    return max(5.0f, range(spell, client)[1]);
}

/// A nearest target uses the spell's range, an area uses the effect's radius.
package float namedCreatureRadius(const ref SpellInfo spell, size_t effect, const ClientData client)
{
    return namedCreatureShape(spell, effect) == ImplicitTarget.unitScriptNearCaster
        ? namedCreatureRange(spell, client) : radius(spell, effect, client);
}

/// The center of a named area, including any destination specified by the spell or its cast.
package bool namedCreatureCenter(const ref SpellInfo spell, size_t effect, const ClientData client, uint map,
    Position caster, const(SpellTarget)* database, const(SpellTargets)* targets, out Position center)
{
    center = caster;
    if (namedCreatureShape(spell, effect) != ImplicitTarget.enumUnitsScriptAoeAtDestLoc)
        return true;
    if (spell.implicitTargetA[effect] == ImplicitTarget.database)
    {
        if (database is null || database.map != map)
            return false;
        center = database.at;
    }
    else if (targets !is null && targets.mask & TargetFlags.destLocation)
    {
        center = Position(targets.dest[0], targets.dest[1], targets.dest[2], caster.orientation);
        const dist = distanceSquared(center, caster);
        const reach = range(spell, client);
        if (!(dist >= reach[0] ^^ 2 && dist <= reach[1] ^^ 2))
            return false;
    }
    return client.isValidMapCoord(map, center.x, center.y, center.z, center.orientation);
}

/// Select across the caster's owned and observed creatures, sharing any target limit between them.
package UnitRef[] namedCreaturesInArea(CombatWorld world, Position center, float reach, const(uint)[] entries,
    bool acrossNodes, uint maxTargets)
{
    import std.algorithm.sorting : sort;

    UnitRef[] targets;
    visitNamedCreatures(world, center, reach, entries, 0, acrossNodes,
        (UnitRef candidate, float) { targets ~= candidate; });
    if (maxTargets && targets.length > maxTargets)
    {
        targets.sort!((a, b) {
            const left = distanceSquared(a.position, center), right = distanceSquared(b.position, center);
            return left < right || (left == right && a.combatGuid < b.combatGuid);
        });
        targets = targets[0 .. maxTargets];
    }
    return targets;
}

/// Compare owned and observed creatures by distance, with a stable tie break.
package UnitRef nearestNamedCreature(CombatWorld world, Position center, float reach, const(uint)[] entries,
    ulong caster, bool acrossNodes)
{
    UnitRef nearest;
    float best = reach ^^ 2;
    visitNamedCreatures(world, center, reach, entries, caster, acrossNodes, (UnitRef candidate, float dist) {
        if (dist < best || (dist == best && (!nearest || candidate.combatGuid < nearest.combatGuid)))
        {
            best = dist;
            nearest = candidate;
        }
    });
    return nearest;
}

private float distanceSquared(Position a, Position b)
{
    return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2;
}

private void visitNamedCreatures(CombatWorld world, Position center, float reach, const(uint)[] entries, ulong exclude,
    bool acrossNodes, scope void delegate(UnitRef, float) visit)
{
    import std.math : isFinite;
    import dmangos.world.replication : Replica;
    import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

    if (!entries.length || !isFinite(reach) || reach <= 0)
        return;
    const limit = reach ^^ 2;
    void consider(UnitRef candidate, uint entry)
    {
        if (candidate.combatGuid == exclude || !candidate.alive || !entries.canFind(entry))
            return;
        const dist = distanceSquared(candidate.position, center);
        if (dist <= limit)
            visit(candidate, dist);
    }
    foreach (creature; world.creaturesNear(center, reach))
        consider(world.unitOf(creature), creature.spawn.entry);
    if (acrossNodes)
        if (auto map = cast(Map) world)
            foreach (object; map.objectsNear(center, reach))
                if (auto copy = cast(Replica) object)
                    if (copy.fields.type == TypeId.unit)
                        consider(UnitRef.observed(copy, map), copy.fields.get!OBJECT_FIELD_ENTRY);
}

/// A player and an NPC choose a nearby named replica, with the effects applied only by its owner.
unittest
{
    import core.time : MonoTime, seconds;
    import dmangos.bytes : ByteWriter, floatBits;
    import dmangos.cluster.protocol : AreaDamage, decode;
    import dmangos.dbc : buildDbc;
    import dmangos.serialization : serialize;
    import dmangos.world.clientdata : spellDurationFormat, spellRadiusFormat, spellRangeFormat;
    import dmangos.world.context : WorldContext;
    import dmangos.world.creature : Creature, CreatureSpawn;
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.player : Player;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.spellcast : SpellMissInfo, SpellTargets, TargetFlags, spellAttrEx2CantCrit,
        spellAttrEx3AlwaysHit;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    auto db = newDatabase();
    auto source = newCreationContext(db), owner = newCreationContext(db);
    auto now = MonoTime.currTime;
    source.clock = owner.clock = () => now;
    source.nodeId = 1;
    owner.nodeId = 2;
    enum uint ward = 55060, heal = 55061, groupWard = 55062, groundWard = 55063;
    const at = Position(100, 100, 40), ground = Position(125, 100, 40);
    foreach (node; [source, owner])
    {
        node.client.spellDurations = typeof(node.client.spellDurations).parse(buildDbc(spellDurationFormat,
            [[1u, 10_000, 0, 10_000]]), "SpellDuration.dbc");
        node.client.spellRadii = typeof(node.client.spellRadii).parse(buildDbc(spellRadiusFormat,
            [[1u, floatBits(6), 0, 0]]), "SpellRadius.dbc");
        uint[spellRangeFormat.length] rangeRow;
        rangeRow[0] = 2;
        rangeRow[2] = floatBits(20);
        node.client.spellRanges = typeof(node.client.spellRanges).parse(buildDbc(spellRangeFormat,
            [rangeRow[]]), "SpellRange.dbc");
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
        aura.id = groupWard;
        aura.implicitTargetA[0 .. 2] = ImplicitTarget.casterSource;
        aura.casting.implicitTargetB[0 .. 2] = ImplicitTarget.enumUnitsScriptAoeAtSrcLoc;
        aura.casting.radiusIndex[0 .. 2] = 1;
        aura.casting.maxAffectedTargets = 2;
        node.data.spells.spells[groupWard] = aura;
        node.data.spellScriptTargets[groupWard] = [creatureInnkeeper];
        aura.id = groundWard;
        aura.implicitTargetA[0 .. 2] = ImplicitTarget.database;
        aura.casting.implicitTargetB[0 .. 2] = ImplicitTarget.enumUnitsScriptAoeAtDestLoc;
        aura.casting.speed = 10;
        node.data.spells.spells[groundWard] = aura;
        node.data.spellScriptTargets[groundWard] = [creatureInnkeeper];
        node.data.spellTargets[groundWard] = SpellTarget(0, ground);
    }

    auto caster = loggedIn(source, db, 7, "Anduin", at);
    auto player = cast(Player) caster.session.character;
    player.spells ~= [ward, groupWard, groundWard];
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

    auto overTargetLimit = npc(source, 91004, creatureInnkeeper, 5);
    assert(npcCaster.ai.castSpell(source.data.spells.spell(groupWard), wrong.guid, 0));
    assert(requests.length == 4 && requests[3].creatureCast && requests[3].target == remote.guid);
    assert(farther.auras.find(groupWard) && !overTargetLimit.auras.find(groupWard), "one cap across both nodes");
    remote.movement.position.z += 15;
    owner.areaDamageArrived(1, requests[3]);
    assert(!remote.auras.find(groupWard), "a normal creature cast also rechecks the recipient's position");
    remote.movement.position.z -= 15;

    castPacket = ByteWriter.init;
    castPacket.put(groupWard);
    SpellTargets(TargetFlags.self, 0).write(castPacket);
    caster.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    assert(requests.length == 5 && requests[4].target == remote.guid && requests[4].radius == 6);
    owner.areaDamageArrived(1, requests[4]);
    owner.areaDamageArrived(1, requests[4]);
    aura = remote.auras.find(groupWard);
    assert(aura && aura.caster == player.guid && aura.stacks == 1 && aura.effects == 3);
    assert(results.length == 4 && !wrong.auras.find(groupWard) && !overTargetLimit.auras.find(groupWard));

    auto atImpact = npc(owner, 91005, creatureInnkeeper, 26);
    from.replicaCreated(2, cellKeyAt(atImpact.position.x, atImpact.position.y), atImpact.guid, encodeState(atImpact, 0));
    castPacket = ByteWriter.init;
    castPacket.put(groundWard);
    SpellTargets(TargetFlags.self, 0).write(castPacket);
    caster.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    now += 1.seconds;
    source.update(now);
    assert(requests.length == 5, "the projectile travels to the destination, 25 yards away at 10 yards per second");
    now += 2.seconds;
    source.update(now);
    assert(requests.length == 6 && requests[5].target == atImpact.guid && requests[5].x == ground.x);
    auto misdirected = requests[5];
    misdirected.x += 1;
    owner.areaDamageArrived(1, misdirected);
    assert(!atImpact.auras.find(groundWard), "the receiving node checks the database's actual center");
    auto correct = requests[5];
    correct.sequence = source.nextGameplaySequence();
    owner.areaDamageArrived(1, correct);
    owner.areaDamageArrived(1, correct);
    aura = atImpact.auras.find(groundWard);
    assert(aura && aura.effects == 3 && aura.stacks == 1 && !farther.auras.find(groundWard));

    auto aimed = cast(SpellInfo) *source.data.spells.spell(groundWard);
    aimed.implicitTargetA[0 .. 2] = ImplicitTarget.locationCasterDest;
    aimed.casting.rangeIndex = 2;
    auto target = SpellTargets(TargetFlags.destLocation, 0);
    target.dest = [at.x + 10, at.y, at.z];
    Position selected;
    assert(namedCreatureCenter(aimed, 0, source.client, 0, at, null, &target, selected) && selected.x == at.x + 10);
    target.dest[0] = ground.x;
    assert(!namedCreatureCenter(aimed, 0, source.client, 0, at, null, &target, selected), "range ends at 20 yards");
}
