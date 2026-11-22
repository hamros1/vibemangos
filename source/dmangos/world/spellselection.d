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
import dmangos.world.worlddata : SpellTarget, WorldData;

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

/// The first rank can set a signed cone angle. Classic defaults to a 60-degree forward cone.
package int namedCreatureCone(const WorldData data, uint spell)
{
    if (data is null)
        return 60;
    const rank = spell in data.spells.chains;
    const degrees = data.spellConeDegrees.get(rank is null || !rank.first ? spell : rank.first, 60);
    return degrees >= -360 && degrees <= 360 ? degrees : 60;
}

package bool inNamedCreatureCone(Position origin, Position target, int degrees)
{
    import std.math : PI;
    import dmangos.world.combat : hasInArc;

    if (!origin.isFinite)
        return false;
    if (degrees < 0)
    {
        origin.orientation += PI;
        degrees = -degrees;
    }
    return degrees >= 360 || hasInArc(origin, target, degrees * PI / 180);
}

/// Select across the caster's owned and observed creatures, sharing any target limit between them.
package UnitRef[] namedCreaturesInArea(CombatWorld world, Position center, float reach, const(uint)[] entries,
    bool acrossNodes, uint maxTargets, ImplicitTarget shape, int cone)
{
    import std.algorithm.sorting : sort;

    UnitRef[] targets;
    visitNamedCreatures(world, center, reach, entries, 0, acrossNodes, (UnitRef candidate, float) {
        if (shape != ImplicitTarget.enumUnitsScriptInCone60 || inNamedCreatureCone(center, candidate.position, cone))
            targets ~= candidate;
    });
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

/// Direct damage and aura effects share one hit on the named creature's node.
unittest
{
    import dmangos.bytes : floatBits;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat, spellDurationFormat, spellRadiusFormat;
    import dmangos.world.context : WorldContext;
    import dmangos.world.creature : Creature, CreatureSpawn;
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.replication : encodeState;
    import dmangos.world.spellcast : SpellMissInfo, spellAttrEx2CantCrit, spellAttrEx3AlwaysHit;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.spells : SpellChainNode;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto db = newDatabase();
    auto source = newCreationContext(db), owner = newCreationContext(db);
    source.nodeId = 1;
    owner.nodeId = 2;
    enum uint strike = 55064, cone = 55065, stunMechanic = 12;
    const at = Position(100, 100, 40);
    foreach (node; [source, owner])
    {
        node.client.factionTemplates = typeof(node.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[12u, 12, 0, 1, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0]]),
            "FactionTemplate.dbc");
        node.client.spellDurations = typeof(node.client.spellDurations).parse(buildDbc(spellDurationFormat,
            [[1u, 10_000, 0, 10_000]]), "SpellDuration.dbc");
        node.client.spellRadii = typeof(node.client.spellRadii).parse(buildDbc(spellRadiusFormat,
            [[1u, floatBits(6), 0, 0]]), "SpellRadius.dbc");
        node.data.creatureTemplates.edit(creatureTrainer).faction = 14;
        node.data.creatureTemplates.edit(creatureInnkeeper).mechanicImmuneMask = 1u << (stunMechanic - 1);
        auto spell = testSpell(strike, SpellEffect.schoolDamage, ImplicitTarget.unitScriptNearCaster, 20);
        spell.effect[1 .. 3] = SpellEffect.applyAura;
        spell.implicitTargetA[1 .. 3] = ImplicitTarget.unitScriptNearCaster;
        spell.basePoints[1 .. 3] = 9;
        spell.baseDice[1 .. 3] = 1;
        spell.casting.applyAuraName[1] = AuraType.modStat;
        spell.casting.applyAuraName[2] = AuraType.modStun;
        spell.casting.effectMechanic[2] = stunMechanic;
        spell.casting.durationIndex = 1;
        spell.casting.stackAmount = 3;
        spell.casting.school = 1;
        spell.attributesEx2 |= spellAttrEx2CantCrit;
        spell.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
        node.data.spells.spells[strike] = spell;
        node.data.spellScriptTargets[strike] = [creatureInnkeeper];
        spell.id = cone;
        spell.implicitTargetA[] = ImplicitTarget.enumUnitsScriptInCone60;
        spell.casting.radiusIndex[] = 1;
        node.data.spells.spells[cone] = spell;
        node.data.spellScriptTargets[cone] = [creatureInnkeeper];
        node.data.spells.chains[cone] = SpellChainNode(strike, strike, 2, 0);
        node.data.spellConeDegrees[strike] = -50;
    }
    Creature npc(WorldContext world, uint id, uint entry, float x)
    {
        const spawn = CreatureSpawn(id, entry, 0, x, at.y, at.z);
        auto creature = world.makeCreature(&spawn);
        world.map(0).addObject(creature);
        return creature;
    }
    auto caster = npc(source, 91010, creatureTrainer, at.x);
    auto target = npc(owner, 91011, creatureInnkeeper, at.x + 3);
    const health = target.values.get!UNIT_FIELD_HEALTH;
    source.map(0).replicaCreated(2, cellKeyAt(at.x + 3, at.y), target.guid, encodeState(target, 0));
    owner.map(0).replicaCreated(1, cellKeyAt(at.x, at.y), caster.guid, encodeState(caster, 0));

    AreaDamage[] requests, replies;
    source.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
        assert(peer == 2 && request.namedCreature && !request.reply);
        requests ~= cast(AreaDamage) request;
        return true;
    };
    owner.sendAreaDamage = (ushort peer, const ref AreaDamage reply) {
        assert(peer == 1 && reply.reply);
        replies ~= cast(AreaDamage) reply;
        return true;
    };
    assert(caster.ai.spellCaster(source.map(0)));
    assert(caster.ai.castSpell(source.data.spells.spell(strike), caster.guid, castTriggered));
    assert(requests.length == 1 && requests[0].effect == 0 && requests[0].auraMs == 10_000);
    owner.areaDamageArrived(1, requests[0]);
    owner.areaDamageArrived(1, requests[0]);
    const aura = target.auras.find(strike);
    assert(aura && aura.stacks == 1 && aura.effects == 2, "the stun-immunity filters only that aura effect");
    assert(target.values.get!UNIT_FIELD_HEALTH == health - 20);
    assert(replies.length == 1 && replies[0].miss == SpellMissInfo.none && replies[0].damage == 20);

    auto rear = npc(owner, 91012, creatureInnkeeper, at.x - 3);
    source.map(0).replicaCreated(2, cellKeyAt(at.x - 3, at.y), rear.guid, encodeState(rear, 0));
    assert(caster.ai.castSpell(source.data.spells.spell(cone), caster.guid, castTriggered));
    assert(requests.length == 2 && requests[1].target == rear.guid, "the first rank sets the rear-facing cone");
    rear.movement.position.x = at.x + 3; // still within the radius, but now outside the cone
    owner.areaDamageArrived(1, requests[1]);
    assert(rear.values.get!UNIT_FIELD_HEALTH == health && !rear.auras.find(cone));
    assert(replies.length == 2 && replies[1].miss == SpellMissInfo.evade);
    rear.movement.position.x = at.x - 3;
    assert(caster.ai.castSpell(source.data.spells.spell(cone), caster.guid, castTriggered));
    assert(requests.length == 3 && requests[2].target == rear.guid);
    owner.areaDamageArrived(1, requests[2]);
    assert(rear.values.get!UNIT_FIELD_HEALTH == health - 20 && rear.auras.find(cone));
}

/// A named database script runs where the creature it acts on is simulated.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellDurationFormat;
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.dbscripts : DbScriptStep, DbScriptType, ScriptCommand, ScriptFlag;
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.player : Player;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.spellcast : SpellMissInfo, spellAttrEx3AlwaysHit;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto source = newCreationContext(db), owner = newCreationContext(db);
    source.nodeId = 1;
    owner.nodeId = 2;
    enum uint scripted = 55066, buff = 55067, casterOnly = 55068;
    foreach (node; [source, owner])
    {
        node.client.spellDurations = typeof(node.client.spellDurations).parse(buildDbc(spellDurationFormat,
            [[1u, 10_000, 0, 10_000]]), "SpellDuration.dbc");
        auto mark = testSpell(buff, SpellEffect.applyAura, ImplicitTarget.caster, 10);
        mark.casting.durationIndex = 1;
        mark.casting.stackAmount = 3;
        mark.casting.applyAuraName[0] = AuraType.modStat;
        node.data.spells.spells[buff] = mark;
        auto command = testSpell(scripted, SpellEffect.scriptEffect, ImplicitTarget.unitScriptNearCaster, 0);
        command.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
        node.data.spells.spells[scripted] = command;
        node.data.spellScriptTargets[scripted] = [creatureInnkeeper];
        node.data.dbScripts.add(DbScriptType.spell, DbScriptStep(id: scripted, command: ScriptCommand.castSpell,
            datalong: buff, dataFlags: ScriptFlag.reverseDirection | ScriptFlag.sourceTargetsSelf));
        node.data.spells.spells[casterOnly] = testSpell(casterOnly, SpellEffect.scriptEffect, ImplicitTarget.unitScriptNearCaster, 0);
        node.data.spellScriptTargets[casterOnly] = [creatureInnkeeper];
        node.data.dbScripts.add(DbScriptType.spell, DbScriptStep(id: casterOnly, command: ScriptCommand.castSpell,
            datalong: buff, dataFlags: ScriptFlag.sourceTargetsSelf));
    }

    const at = Position(100, 100, 40);
    auto caster = loggedIn(source, db, 7, "Anduin", at);
    auto player = cast(Player) caster.session.character;
    player.spells ~= [scripted, casterOnly];
    const spawn = CreatureSpawn(91013, creatureInnkeeper, 0, at.x + 3, at.y, at.z);
    auto target = owner.makeCreature(&spawn);
    owner.map(0).addObject(target);
    const triggerSpawn = CreatureSpawn(91014, creatureTrainer, 0, at.x, at.y, at.z);
    auto npc = source.makeCreature(&triggerSpawn);
    source.map(0).addObject(npc);
    const cell = cellKeyAt(at.x, at.y);
    source.map(0).replicaCreated(2, cell, target.guid, encodeState(target, 0));
    owner.map(0).replicaCreated(1, cell, player.guid, encodePlayerState(player, 0));
    owner.map(0).replicaCreated(1, cell, npc.guid, encodeState(npc, 0));

    AreaDamage[] requests, replies;
    source.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
        assert(peer == 2 && request.namedCreature && !request.reply);
        requests ~= cast(AreaDamage) request;
        return true;
    };
    owner.sendAreaDamage = (ushort peer, const ref AreaDamage reply) {
        assert(peer == 1 && reply.reply);
        replies ~= cast(AreaDamage) reply;
        return true;
    };
    void castFromPlayer(uint spell)
    {
        ByteWriter packet;
        packet.put(spell);
        SpellTargets(TargetFlags.self, 0).write(packet);
        caster.write(Opcode.CMSG_CAST_SPELL, packet.data);
    }
    castFromPlayer(scripted);
    assert(requests.length == 1 && requests[0].target == target.guid);
    owner.areaDamageArrived(1, requests[0]);
    owner.areaDamageArrived(1, requests[0]);
    assert(replies.length == 1 && replies[0].miss == SpellMissInfo.none, "the named script hit once");
    auto aura = target.auras.find(buff);
    assert(aura, "the target executed its self-cast step");
    assert(aura.caster == target.guid && aura.stacks == 1, "the creature cast the step on itself once");
    castFromPlayer(casterOnly);
    assert(requests.length == 1, "an action that needs the caster stays on the caster's node");
    source.updateScripts(0);
    assert(player.auras.find(buff), "the caster can still run its own steps");

    assert(npc.ai.spellCaster(source.map(0)));
    assert(npc.ai.castSpell(source.data.spells.spell(scripted), npc.guid, castTriggered));
    assert(requests.length == 2 && requests[1].caster == npc.guid && requests[1].target == target.guid);
    owner.areaDamageArrived(1, requests[1]);
    aura = target.auras.find(buff);
    assert(aura && aura.caster == target.guid && aura.stacks == 2 && replies.length == 2);
    source.map(0).replicaRemoved(2, target.guid);
    castFromPlayer(scripted);
    assert(requests.length == 2 && source.runningScripts == 0, "a missing named creature leaves no script to run");
}
