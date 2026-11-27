/// Select the creatures and game objects named by spell_script_target.
module dmangos.world.spellselection;

import std.algorithm.comparison : max;
import std.algorithm.searching : canFind;
import dmangos.world.clientdata : ClientData;
import dmangos.world.map : Map;
import dmangos.world.gameobject : GameObjectAction;
import dmangos.world.map : Map, MapObject;
import dmangos.world.movement : Position;
import dmangos.world.spellcast : radius, range, SpellTargets, TargetFlags;
import dmangos.world.spelldamage : namedCreatureShape;
import dmangos.world.spellids : ImplicitTarget, SpellEffect;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitRef;
import dmangos.world.worlddata : SpellScriptObject, SpellTarget, WorldData;

/// Intimidating Shout's selected enemy cowers; only the surrounding enemies flee.
package ulong excludedAreaTarget(uint spell, size_t effect, ulong primary) pure nothrow @nogc @safe
{
    return spell == 5246 && effect != 0 ? primary : 0;
}

/// Activate-object animation slots 0 through 3 are encoded as actions 1 through 4.
private enum uint firstObjectAnimation = 1, lastObjectAnimation = 4;

/// Onyxia's Eruption uses the disturb action to animate a crack in the floor.
package int namedGameObjectAnimation(const ref SpellInfo spell, size_t effect) pure nothrow @nogc @safe
{
    const action = spell.miscValue[effect];
    if (action >= firstObjectAnimation && action <= lastObjectAnimation)
        return cast(int)(action - firstObjectAnimation);
    return spell.id == 17731 && action == 5 ? 0 : -1;
}

package ImplicitTarget namedGameObjectShape(const ref SpellInfo spell, size_t effect) pure nothrow @nogc @safe
{
    import std.algorithm.comparison : among;

    enum uint channels = 0x04 | 0x40;
    if (effect >= spell.effect.length || spell.effect[effect] != SpellEffect.activateObject
        || (spell.casting.speed > 0 && namedGameObjectAnimation(spell, effect) < 0) || (spell.attributesEx & channels))
        return ImplicitTarget.none;
    const action = cast(GameObjectAction) spell.miscValue[effect];
    // Disturb sets off a trap (or uses a button); open uses a door, a button or a goober; despawn takes it away.
    if (namedGameObjectAnimation(spell, effect) < 0
        && !action.among(GameObjectAction.disturb, GameObjectAction.unlock, GameObjectAction.lock, GameObjectAction.open,
            GameObjectAction.openAndUnlock, GameObjectAction.close, GameObjectAction.destroy, GameObjectAction.rebuild,
            GameObjectAction.despawn, GameObjectAction.closeAndLock))
        return ImplicitTarget.none;
    const a = spell.implicitTargetA[effect], b = spell.casting.implicitTargetB[effect];
    if (a == ImplicitTarget.gameobjectScriptNearCaster && b == ImplicitTarget.none)
        return a;
    if (a == ImplicitTarget.casterSource && b == ImplicitTarget.enumGameobjectsScriptAoeAtSrcLoc)
        return b;
    if ((a == ImplicitTarget.locationCasterDest || a == ImplicitTarget.database)
        && b == ImplicitTarget.enumGameobjectsScriptAoeAtDestLoc)
        return b;
    return ImplicitTarget.none;
}

package bool namedGameObjectEntry(const(SpellScriptObject)[] entries, size_t effect, uint entry)
{
    foreach (ref row; entries)
        if (row.entry == entry && !(row.inverseEffectMask & (1U << effect)))
            return true;
    return false;
}

package MapObject nearestNamedGameObject(Map map, Position center, float reach, size_t effect,
    const(SpellScriptObject)[] entries, bool acrossNodes, scope bool delegate(ulong) visible = null)
{
    import std.math : isFinite;
    import dmangos.world.replication : Replica;
    import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

    MapObject nearest;
    if (!entries.length || !isFinite(reach) || reach <= 0)
        return nearest;
    float best = reach ^^ 2;
    foreach (object; map.objectsNear(center, reach))
    {
        if (object.fields.type != TypeId.gameObject || (!acrossNodes && (cast(Replica) object) !is null)
            || !namedGameObjectEntry(entries, effect, object.fields.get!OBJECT_FIELD_ENTRY)
            || (visible !is null && !visible(object.guid)))
            continue;
        const squared = distanceSquared(center, object.position);
        if (squared < best || (squared == best && (nearest is null || object.guid < nearest.guid)))
        {
            best = squared;
            nearest = object;
        }
    }
    return nearest;
}

package ulong[] namedGameObjectsInArea(Map map, Position center, float reach, size_t effect,
    const(SpellScriptObject)[] entries, bool acrossNodes, uint maxTargets, scope bool delegate(ulong) visible = null)
{
    import std.algorithm.sorting : sort;
    import std.math : isFinite;
    import dmangos.world.replication : Replica;
    import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

    ulong[] targets;
    if (!entries.length || !isFinite(reach) || reach <= 0)
        return targets;
    MapObject[] found;
    foreach (object; map.objectsNear(center, reach))
        if (object.fields.type == TypeId.gameObject && (acrossNodes || (cast(Replica) object) is null)
            && namedGameObjectEntry(entries, effect, object.fields.get!OBJECT_FIELD_ENTRY)
            && (visible is null || visible(object.guid))
            && distanceSquared(center, object.position) <= reach ^^ 2)
            found ~= object;
    if (maxTargets && found.length > maxTargets)
    {
        found.sort!((a, b) {
            const left = distanceSquared(center, a.position), right = distanceSquared(center, b.position);
            return left < right || (left == right && a.guid < b.guid);
        });
        found = found[0 .. maxTargets];
    }
    foreach (object; found)
        targets ~= object.guid;
    return targets;
}

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

/**
 * How wide spell `spell`'s cone is, in degrees (`spell_cone`, by its first rank; negative: behind the caster): every
 * cone a spell targets, a player's (Cone of Cold) or a creature's (a breath), is this wide. Classic's default is a
 * 60-degree cone in front.
 */
package int spellCone(const WorldData data, uint spell)
{
    if (data is null)
        return 60;
    const rank = spell in data.spells.chains;
    const degrees = data.spellConeDegrees.get(rank is null || !rank.first ? spell : rank.first, 60);
    return degrees >= -360 && degrees <= 360 ? degrees : 60;
}

/// Whether `target` is in the cone of `degrees` (`spellCone`) the caster at `origin` faces.
package bool inSpellCone(Position origin, Position target, int degrees)
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

/// The template used to select and validate a named creature.
package uint namedCreatureEntry(UnitRef candidate)
{
    import dmangos.world.updatefields : OBJECT_FIELD_ENTRY;

    return candidate.replica is null ? candidate.creature.spawn.entry : candidate.replica.fields.get!OBJECT_FIELD_ENTRY;
}

/// Select across the caster's owned and observed creatures, sharing any target limit between them.
package UnitRef[] namedCreaturesInArea(Map world, Position center, float reach, const(uint)[] entries,
    bool acrossNodes, uint maxTargets, ImplicitTarget shape, int cone, scope bool delegate(ulong) visible = null)
{
    import std.algorithm.sorting : sort;

    UnitRef[] targets;
    visitNamedCreatures(world, center, reach, entries, 0, acrossNodes, (UnitRef candidate, float) {
        if ((visible is null || visible(candidate.combatGuid))
            && (shape != ImplicitTarget.enumUnitsScriptInCone60 || inSpellCone(center, candidate.position, cone)))
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
package UnitRef nearestNamedCreature(Map world, Position center, float reach, const(uint)[] entries,
    ulong caster, bool acrossNodes, scope bool delegate(ulong) visible = null)
{
    UnitRef nearest;
    float best = reach ^^ 2;
    visitNamedCreatures(world, center, reach, entries, caster, acrossNodes, (UnitRef candidate, float dist) {
        if ((visible is null || visible(candidate.combatGuid))
            && (dist < best || (dist == best && (!nearest || candidate.combatGuid < nearest.combatGuid))))
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

private void visitNamedCreatures(Map world, Position center, float reach, const(uint)[] entries, ulong exclude,
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
        if (auto map = world)
            foreach (object; map.objectsNear(center, reach))
                if (auto copy = cast(Replica) object)
                    if (copy.fields.type == TypeId.unit)
                        consider(UnitRef.observed(copy, map), copy.fields.get!OBJECT_FIELD_ENTRY);
}

/// Players and creatures cast a recorded animation on the nearest eligible game object.
/**
 * The units of an area, any caster's: the players and then the creatures on `map` within `r` yards of `center` (and,
 * for a cone, in the cone of `coneDegrees` the caster at `coneFrom` faces), not `excluded`, that `takes` (who the
 * caster's spell is for: its enemies, its friends). The caller limits them (`mostAffected`).
 */
package ulong[] unitsInArea(Map map, Position center, float r, bool cone, int coneDegrees, Position coneFrom,
    ulong excluded, scope bool delegate(UnitRef) takes)
{
    bool inside(Position p)
    {
        return (p.x - center.x) ^^ 2 + (p.y - center.y) ^^ 2 + (p.z - center.z) ^^ 2 <= r * r
            && (!cone || inSpellCone(coneFrom, p, coneDegrees));
    }
    ulong[] found;
    foreach (unit; map.playersNear(center, r))
        if (unit.combatGuid != excluded && inside(unit.position) && takes(unit))
            found ~= unit.combatGuid;
    foreach (creature; map.creaturesNear(center, r))
        if (creature.guid != excluded && inside(creature.position) && takes(map.unitOf(creature)))
            found ~= creature.guid;
    return found;
}

/**
 * At most `most` of an area's targets `found` (the spell's `MaxAffectedTargets`: "up to 5 total nearby enemies",
 * Thunder Clap's "up to 4 targets"; 0: no limit), any caster's: the one aimed at (`aimed`) among them, then the
 * nearest to `center`, the same for each of its effects.
 */
package ulong[] mostAffected(Map map, ulong[] found, uint most, ulong aimed, Position center)
{
    import std.algorithm.sorting : sort;

    if (!most || found.length <= most)
        return found;
    double away(ulong guid)
    {
        if (guid == aimed)
            return -1;
        const u = map.unit(guid);
        const object = u ? null : map.findObject(guid);
        if (!u && object is null)
            return double.infinity;
        const p = u ? u.position : object.position;
        return (p.x - center.x) ^^ 2 + (p.y - center.y) ^^ 2 + (p.z - center.z) ^^ 2;
    }
    found.sort!((x, y) => away(x) < away(y) || (away(x) == away(y) && x < y));
    return found[0 .. most];
}

unittest
{
    import dmangos.bytes : ByteReader, ByteWriter, floatBits;
    import dmangos.cluster.protocol : GameObjectSpell, decode;
    import dmangos.dbc : buildDbc;
    import dmangos.serialization : serialize;
    import dmangos.world.clientdata : spellRadiusFormat;
    import dmangos.world.creature : CreatureSpawn;
    import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType,
        goFlagLocked, goStateActiveAlternative, goStateReady;
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState, QuestStatus, specialKillOrCast;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : GAMEOBJECT_FLAGS, PLAYER_QUEST_LOG_1_1, UNIT_FIELD_HEALTH;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto map = context.map(0);
    const origin = Position(100, 100, 40);
    enum uint animation = 55075, eligible = 90001, excluded = 90002;
    auto spell = testSpell(animation, SpellEffect.activateObject, ImplicitTarget.gameobjectScriptNearCaster, 0);
    spell.miscValue[0] = 3; // custom animation slot 2
    context.data.spells.spells[animation] = spell;
    context.data.spellScriptObjects[animation] = [SpellScriptObject(eligible, 0), SpellScriptObject(excluded, 1)];
    foreach (entry; [eligible, excluded])
        context.data.gameObjectTemplates[entry] = GameObjectTemplate(entry: entry, type: GameObjectType.door);
    GameObject spawn(uint guid, uint entry, float x)
    {
        const row = GameObjectSpawn(guid: guid, entry: entry, x: x, y: origin.y, z: origin.z);
        auto object = context.makeGameObject(row);
        map.addObject(object);
        return object;
    }
    spawn(9, eligible, 102);
    const chosen = spawn(8, eligible, 98);
    spawn(7, excluded, 101);

    auto client = loggedIn(context, db, 7, "Anduin", origin);
    auto player = cast(Player) client.session.character;
    player.spells ~= animation;
    ByteWriter packet;
    packet.put(animation);
    SpellTargets(TargetFlags.self, 0).write(packet);
    client.write(Opcode.CMSG_CAST_SPELL, packet.data);
    void checkAnimation()
    {
        uint played;
        foreach (message; client.read())
            if (message.opcode == Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM)
            {
                auto reader = ByteReader(message.body_);
                assert(reader.read!ulong == chosen.guid && reader.read!uint == 2 && reader.empty);
                ++played;
            }
        assert(played == 1, "one animation on the eligible object with the lower GUID");
    }
    checkAnimation();

    const row = CreatureSpawn(91021, creatureTrainer, 0, origin.x, origin.y, origin.z);
    auto npc = context.makeCreature(&row);
    map.addObject(npc);
    assert(npc.ai.spellCaster(map));
    assert(npc.ai.castSpell(context.data.spells.spell(animation), npc.guid, castTriggered));
    checkAnimation();

    auto owner = newCreationContext(db);
    context.nodeId = 1;
    owner.nodeId = 2;
    owner.data.spells.spells[animation] = spell;
    owner.data.spellScriptObjects[animation] = context.data.spellScriptObjects[animation];
    owner.data.gameObjectTemplates[eligible] = context.data.gameObjectTemplates[eligible];
    const remoteSpawn = GameObjectSpawn(guid: 10, entry: eligible, x: 101, y: origin.y, z: origin.z);
    auto remote = owner.makeGameObject(remoteSpawn);
    auto to = owner.map(0);
    to.addObject(remote);
    const cell = cellKeyAt(origin.x, origin.y);
    map.replicaCreated(2, cell, remote.guid, encodeState(remote, 0));
    to.replicaCreated(1, cell, player.guid, encodePlayerState(player, 0));
    to.replicaCreated(1, cell, npc.guid, encodeState(npc, 0));
    auto witness = loggedIn(owner, db, 8, "Jaina", Position(100, 101, 40));
    GameObjectSpell[] requests, replies;
    context.sendGameObjectSpell = (ushort peer, const ref GameObjectSpell message) {
        assert(peer == 2 && !message.reply);
        ByteWriter wire;
        serialize(wire, message);
        requests ~= decode!GameObjectSpell(wire.data);
        return true;
    };
    owner.sendGameObjectSpell = (ushort peer, const ref GameObjectSpell message) {
        assert(peer == 1 && message.reply);
        replies ~= cast(GameObjectSpell) message;
        return true;
    };
    Quest quest;
    quest.id = 55701;
    quest.specialFlags = specialKillOrCast;
    quest.reqCreatureOrGoId[0] = -cast(int) eligible;
    quest.reqCreatureOrGoCount[0] = 2;
    quest.reqSpellCast[0] = animation;
    context.data.quests.quests[quest.id] = quest;
    player.values.set!PLAYER_QUEST_LOG_1_1(quest.id);
    player.questStatus[quest.id] = QuestStatus(quest.id, QuestState.incomplete);
    client.write(Opcode.CMSG_CAST_SPELL, packet.data);
    assert(requests.length == 1 && requests[0].target == remote.guid && requests[0].caster == player.guid);
    assert(player.questStatus[quest.id].mobCount[0] == 0);
    owner.gameObjectSpellArrived(3, requests[0]);
    assert(witness.read().length == 0);
    owner.gameObjectSpellArrived(1, requests[0]);
    owner.gameObjectSpellArrived(1, requests[0]);
    void checkRemoteAnimation(uint slot = 2)
    {
        uint played;
        foreach (message; witness.read())
            if (message.opcode == Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM)
            {
                auto reader = ByteReader(message.body_);
                assert(reader.read!ulong == remote.guid && reader.read!uint == slot && reader.empty);
                ++played;
            }
        assert(played == 1);
    }
    checkRemoteAnimation();
    assert(replies.length == 1);
    context.gameObjectSpellArrived(2, replies[0]);
    context.gameObjectSpellArrived(2, replies[0]);
    assert(player.questStatus[quest.id].mobCount[0] == 1, "confirmed remote animation credits the objective once");

    auto tooFar = requests[0];
    tooFar.sequence = context.nextGameplaySequence();
    tooFar.x += 10;
    owner.gameObjectSpellArrived(1, tooFar);
    assert(witness.read().length == 0 && replies.length == 1, "the owner checks current range");
    assert(npc.ai.castSpell(context.data.spells.spell(animation), npc.guid, castTriggered));
    assert(requests.length == 2 && requests[1].triggered && requests[1].caster == npc.guid);
    owner.gameObjectSpellArrived(1, requests[1]);
    checkRemoteAnimation();
    assert(replies.length == 1, "only a player's cast needs credit returned");

    // The Eruption animation can run beside a unit effect and shares its target cap across both nodes.
    enum uint eruption = 17731;
    auto mixed = testSpell(eruption, SpellEffect.heal, ImplicitTarget.caster, 10);
    mixed.effect[1] = SpellEffect.activateObject;
    mixed.implicitTargetA[1] = ImplicitTarget.locationCasterDest;
    mixed.casting.implicitTargetB[1] = ImplicitTarget.enumGameobjectsScriptAoeAtDestLoc;
    mixed.casting.radiusIndex[1] = 1;
    mixed.casting.maxAffectedTargets = 2;
    mixed.miscValue[1] = 5;
    foreach (node; [context, owner])
    {
        node.client.spellRadii = typeof(node.client.spellRadii).parse(buildDbc(spellRadiusFormat,
            [[1u, floatBits(4), 0, 0]]), "SpellRadius.dbc");
        node.data.spells.spells[eruption] = mixed;
        node.data.spellScriptObjects[eruption] = [SpellScriptObject(eligible, 0), SpellScriptObject(excluded, 2)];
    }
    player.spells ~= eruption;
    player.values.set!UNIT_FIELD_HEALTH(10);
    client.read();
    ByteWriter eruptionCast;
    eruptionCast.put(eruption);
    SpellTargets(TargetFlags.self, 0).write(eruptionCast);
    client.write(Opcode.CMSG_CAST_SPELL, eruptionCast.data);
    assert(player.values.get!UNIT_FIELD_HEALTH > 10, "the companion effect also runs");
    uint localAnimations;
    foreach (message; client.read())
        if (message.opcode == Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM)
        {
            auto reader = ByteReader(message.body_);
            assert(reader.read!ulong == chosen.guid && reader.read!uint == 0 && reader.empty);
            ++localAnimations;
        }
    assert(localAnimations == 1 && requests.length == 3 && requests[2].target == remote.guid
        && requests[2].effect == 1 && requests[2].spell == eruption);
    owner.gameObjectSpellArrived(1, requests[2]);
    checkRemoteAnimation(0);

    // A node with only idle objects need not observe the caster's cell.
    to.replicaRemoved(1, player.guid);
    assert(to.findObject(player.guid) is null);
    client.write(Opcode.CMSG_CAST_SPELL, packet.data);
    assert(requests.length == 4);
    owner.gameObjectSpellArrived(1, requests[3]);
    checkRemoteAnimation();
    assert(replies.length == 3, "the idle owner can confirm the cast without a caster replica");

    // The same owner route applies state changes, including an alternate state and a locked reset.
    enum uint blast = 11195, reset = 55079;
    void changeDoor(uint id, GameObjectAction action)
    {
        auto state = spell;
        state.id = id;
        state.miscValue[0] = cast(int) action;
        foreach (node; [context, owner])
        {
            node.data.spells.spells[id] = state;
            node.data.spellScriptObjects[id] = [SpellScriptObject(eligible, 0)];
        }
        player.spells ~= id;
        const before = requests.length;
        ByteWriter castPacket;
        castPacket.put(id);
        SpellTargets(TargetFlags.self, 0).write(castPacket);
        client.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
        assert(requests.length == before + 1 && requests[$ - 1].target == remote.guid);
        owner.gameObjectSpellArrived(1, requests[$ - 1]);
    }
    changeDoor(blast, GameObjectAction.destroy);
    assert(remote.goState == goStateActiveAlternative && chosen.goState == goStateReady);
    changeDoor(reset, GameObjectAction.closeAndLock);
    assert(remote.goState == goStateReady && remote.values.get!GAMEOBJECT_FLAGS & goFlagLocked);
    ByteWriter click;
    click.put(remote.guid);
    witness.write(Opcode.CMSG_GAMEOBJ_USE, click.data);
    assert(remote.goState == goStateReady, "a locked door cannot be opened by a normal click");
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
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.player : Player;
    import dmangos.world.replication : encodeState, Replicator;
    import dmangos.world.spellcast : SpellMissInfo, SpellTargets, TargetFlags, spellAttrEx2CantCrit,
        spellAttrEx3AlwaysHit;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    static final class Wire : Replicator
    {
        Map receiver;
        this(Map receiver) { this.receiver = receiver; }
        void create(ushort peer, uint, ulong cell, ulong guid, const(ubyte)[] state)
        {
            assert(peer == 2);
            receiver.replicaCreated(1, cell, guid, state);
        }
        void values(ushort, uint, ulong guid, const(ubyte)[] slots) { receiver.replicaValues(1, guid, slots); }
        void move(ushort, uint, ulong guid, ushort op, const(ubyte)[] body_, const(ubyte)[] motion)
        {
            receiver.replicaMoved(1, guid, op, body_, motion);
        }
        void remove(ushort, uint, ulong guid) { receiver.replicaRemoved(1, guid); }
        void inRange(ushort, uint, Position, float, ushort, const(ubyte)[]) {}
    }

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
    from.replicator = new Wire(to);
    assert(to.findObject(player.guid) is null && to.findObject(npcCaster.guid) is null);
    foreach (creature; [wrong, remote])
        from.replicaCreated(2, cellKeyAt(creature.position.x, creature.position.y), creature.guid,
            encodeState(creature, 0));

    AreaDamage[] requests, results;
    source.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
        assert(peer == 2 && request.namedCreature && !request.reply);
        assert(to.isReplica(request.caster), "the owner's link receives combat state before the cast");
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

    caster.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    to.removeObject(atImpact.guid);
    from.replicaRemoved(2, atImpact.guid);
    from.addObject(atImpact);
    now += 1.seconds;
    source.update(now);
    assert(atImpact.auras.find(groundWard).stacks == 1, "ownership changes during flight");
    now += 2.seconds;
    source.update(now);
    aura = atImpact.auras.find(groundWard);
    assert(aura && aura.effects == 3 && aura.stacks == 2 && requests.length == 6,
        "the pending projectile resolves once on the target that became local");
    now += 1.seconds;
    source.update(now);
    assert(atImpact.auras.find(groundWard).stacks == 2);

    enum uint bolt = 55069;
    auto damageSpell = testSpell(bolt, SpellEffect.schoolDamage, ImplicitTarget.unitScriptNearCaster, 20);
    damageSpell.casting.school = 1;
    damageSpell.casting.speed = 2;
    damageSpell.casting.attributesEx3 |= spellAttrEx3AlwaysHit;
    damageSpell.attributesEx2 |= spellAttrEx2CantCrit;
    source.data.spells.spells[bolt] = damageSpell;
    source.data.spellScriptTargets[bolt] = [creatureInnkeeper];
    player.spells ~= bolt;
    player.damageMods.threat[1] = 2;
    auto blocker = npc(owner, 91006, creatureInnkeeper, 2);
    const health = blocker.values.get!UNIT_FIELD_HEALTH;
    from.replicaCreated(2, cellKeyAt(blocker.position.x, blocker.position.y), blocker.guid, encodeState(blocker, 0));
    castPacket = ByteWriter.init;
    castPacket.put(bolt);
    SpellTargets(TargetFlags.self, 0).write(castPacket);
    caster.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    to.removeObject(blocker.guid);
    from.replicaRemoved(2, blocker.guid);
    from.addObject(blocker);
    now += 2.seconds;
    source.update(now);
    assert(blocker.values.get!UNIT_FIELD_HEALTH == health - 20 && requests.length == 6);
    assert(blocker.ai.threatOf(player.guid) == 40, "use the prepared caster threat multiplier once");
    assert(to.findObject(npcCaster.guid) is null, "the idle owner forgets the caster after the spell hold");

    const playerGuid = player.guid;
    from.removeObject(atImpact.guid);
    auto carried = npc(owner, 91007, creatureInnkeeper, 26);
    auto late = npc(owner, 91008, creatureInnkeeper, 24);
    const lateState = encodeState(late, 0);
    to.removeObject(late.guid);
    const impactCell = cellKeyAt(carried.position.x, carried.position.y);
    from.replicaCreated(2, impactCell, carried.guid, encodeState(carried, 0));
    from.replicaCreated(3, impactCell, late.guid, lateState);
    AreaDamage[] forwarded;
    owner.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
        assert(peer == 3 && request.caster == playerGuid && request.target == late.guid && !request.reply);
        forwarded ~= cast(AreaDamage) request;
        return true;
    };

    auto relay = new TestPlayerRelay(source, owner);
    castPacket = ByteWriter.init;
    castPacket.put(groundWard);
    SpellTargets(TargetFlags.self, 0).write(castPacket);
    caster.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    now += 1.seconds;
    source.update(now);
    assert(caster.session.inWorld.actAtReplica(carried.guid, ArrivalAction.init));
    assert(relay.remote !is null && relay.remote.character.guid == playerGuid);
    now += 1.seconds;
    owner.update(now);
    assert(!carried.auras.find(groundWard), "handoff does not land an in-flight spell early");
    now += 1.seconds;
    owner.update(now);
    source.update(now);
    assert(carried.auras.find(groundWard).stacks == 1, "the caster's new node keeps the original impact time");
    assert(requests.length == 6 && forwarded.length == 0);
    to.replicaCreated(3, impactCell, late.guid, lateState);
    now += 1.seconds;
    owner.update(now);
    assert(forwarded.length == 1 && carried.auras.find(groundWard).stacks == 1,
        "a late replica is routed once after it reaches the caster's new node");
    now += 1.seconds;
    owner.update(now);
    assert(forwarded.length == 1);
}

/// A named channel carries one aura across owners. The allowed effects tick once and end on interruption.
unittest
{
    import core.time : msecs, seconds;
    import std.math : abs;
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.bytes : ByteWriter;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : makeAura;
    import dmangos.world.clientdata : spellDurationFormat;
    import dmangos.world.creature : Creature, CreatureSpawn;
    import dmangos.world.grid : cellCoordinate, cellKeyAt;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState, QuestStatus, specialKillOrCast;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X, PLAYER_QUEST_LOG_1_1, UNIT_CHANNEL_SPELL,
        UNIT_FIELD_CHANNEL_OBJECT, UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    auto db = newDatabase();
    auto source = newCreationContext(db), owner = newCreationContext(db);
    source.nodeId = 1;
    owner.nodeId = 2;
    const origin = Position(100, 100, 40);
    enum uint mend = 16637;
    auto spell = testSpell(mend, SpellEffect.applyAura, ImplicitTarget.unitScriptNearCaster, 10);
    spell.attributesEx = 0x04;
    spell.effect[1 .. 3] = SpellEffect.applyAura;
    spell.implicitTargetA[1 .. 3] = ImplicitTarget.unitScriptNearCaster;
    spell.casting.applyAuraName = [AuraType.modDamageDone, AuraType.periodicHeal, AuraType.modScale];
    spell.basePoints[1 .. 3] = 9;
    spell.baseDice[1 .. 3] = 1;
    spell.casting.amplitude[1] = 1000;
    spell.casting.durationIndex = 1;
    foreach (node; [source, owner])
    {
        node.client.spellDurations = typeof(node.client.spellDurations).parse(buildDbc(spellDurationFormat,
            [[1u, 3000, 0, 3000]]), "SpellDuration.dbc");
        node.data.spells.spells[mend] = spell;
        node.data.spellScriptTargets[mend] = [creatureTrainer];
        node.data.spellScriptTargetMasks[mend][creatureTrainer] = 0b001;
    }
    auto client = loggedIn(source, db, 7, "Anduin", origin);
    auto player = cast(Player) client.session.character;
    player.spells ~= mend;
    auto from = source.map(0), to = owner.map(0);
    const row = CreatureSpawn(91025, creatureTrainer, 0, 102, origin.y, origin.z);
    auto target = owner.makeCreature(&row);
    target.values.set!UNIT_FIELD_MAXHEALTH(100);
    target.values.set!UNIT_FIELD_HEALTH(20);
    to.addObject(target);
    const baseScale = target.values.get!OBJECT_FIELD_SCALE_X;
    const cell = cellKeyAt(origin.x, origin.y);
    from.replicaCreated(2, cell, target.guid, encodeState(target, 0));
    const healerSpawn = CreatureSpawn(91026, creatureInnkeeper, 0, origin.x, origin.y, origin.z);
    auto healer = source.makeCreature(&healerSpawn);
    from.addObject(healer);
    healer.ai.spellCaster(from);

    Quest quest;
    quest.id = 55703;
    quest.specialFlags = specialKillOrCast;
    quest.reqCreatureOrGoId[0] = creatureTrainer;
    quest.reqCreatureOrGoCount[0] = 2;
    quest.reqSpellCast[0] = mend;
    source.data.quests.quests[quest.id] = quest;
    player.values.set!PLAYER_QUEST_LOG_1_1(quest.id);
    player.questStatus[quest.id] = QuestStatus(quest.id, QuestState.incomplete);

    source.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
        assert(peer == 2 && request.namedCreature && request.channelled && request.target == target.guid);
        assert(request.channelUpdate || request.effect == 1, "the excluded first effect is not sent as the lead");
        if (request.creatureCast)
            to.replicaCreated(1, cell, healer.guid, encodeState(healer, 0));
        else
            to.replicaCreated(1, cell, player.guid, encodePlayerState(player, 0));
        owner.areaDamageArrived(1, request);
        return true;
    };
    owner.sendAreaDamage = (ushort peer, const ref AreaDamage reply) {
        assert(peer == 1 && reply.reply);
        source.areaDamageArrived(2, reply);
        return true;
    };
    bool added;
    target.receiveAura(makeAura(owner.data.spells.spell(mend), 900, 1, 3000, true, [10, 0, 0]), to, added);
    ByteWriter castPacket;
    castPacket.put(mend);
    SpellTargets(TargetFlags.self, 0).write(castPacket);
    assert(source.namedCreatureChannel(source.data.spells.spell(mend)) == 0);
    client.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    assert(player.values.get!UNIT_FIELD_CHANNEL_OBJECT == target.guid, "the caster starts on its selected creature");
    assert(target.auras.find(mend, player.guid), "the selected creature's owner installs the aura");
    assert(target.auras.find(mend, player.guid).effects == 0b110);
    target.updateAuras(to, 1000);
    assert(target.values.get!UNIT_FIELD_HEALTH == 30);
    ByteWriter cancel;
    cancel.put(mend);
    client.write(Opcode.CMSG_CANCEL_CHANNELLING, cancel.data);
    assert(!target.auras.find(mend, player.guid) && target.auras.find(mend, 900));
    target.updateAuras(to, 2000);
    assert(target.values.get!UNIT_FIELD_HEALTH == 30 && player.questStatus[quest.id].mobCount[0] == 0);

    client.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    target.updateAuras(to, 2000);
    client.session.update(3.seconds);
    assert(!player.values.get!UNIT_CHANNEL_SPELL);
    to.replicaCreated(1, cell, player.guid, encodePlayerState(player, 0));
    target.updateAuras(to, 1000);
    assert(target.values.get!UNIT_FIELD_HEALTH == 60 && !target.auras.find(mend, player.guid));
    assert(player.questStatus[quest.id].mobCount[0] == 1, "only a confirmed channel completed naturally counts");

    client.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    assert(target.auras.find(mend, player.guid));
    from.replicaRemoved(2, target.guid);
    client.session.update(50.msecs);
    assert(player.values.get!UNIT_CHANNEL_SPELL == mend, "a replica can be absent briefly during a region handoff");
    const inRange = target.position;
    target.movement.position.x += 200;
    from.replicaCreated(2, cellKeyAt(target.position.x, target.position.y), target.guid, encodeState(target, 0));
    client.session.update(50.msecs);
    assert(!player.values.get!UNIT_CHANNEL_SPELL && !target.auras.find(mend, player.guid),
        "the channel ends when the named creature runs out of range");
    assert(player.questStatus[quest.id].mobCount[0] == 1, "leaving range awards no credit");
    target.movement.position = inRange;
    from.replicaCreated(2, cell, target.guid, encodeState(target, 0));

    assert(healer.ai.castSpell(source.data.spells.spell(mend), healer.guid, 0));
    assert(healer.values.get!UNIT_FIELD_CHANNEL_OBJECT == target.guid && target.auras.find(mend, healer.guid));
    assert(target.auras.find(mend, healer.guid).effects == 0b110);
    target.updateAuras(to, 1000);
    assert(target.values.get!UNIT_FIELD_HEALTH == 70);
    healer.ai.interruptCast();
    assert(!target.auras.find(mend, healer.guid) && !healer.values.get!UNIT_CHANNEL_SPELL);

    // This time the aura's creature moves, with the current channel still running.
    client.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    const token = target.auras.find(mend, player.guid).channelToken;
    assert(token);
    target.updateAuras(to, 1400);
    client.session.update(1400.msecs);
    assert(target.values.get!UNIT_FIELD_HEALTH == 80);
    auto successor = newCreationContext(db);
    successor.nodeId = 3;
    successor.data.spells.spells[mend] = spell;
    successor.data.spellScriptTargets[mend] = [creatureTrainer];
    successor.data.spellScriptTargetMasks[mend][creatureTrainer] = 0b001;
    successor.client.spellDurations = owner.client.spellDurations;
    db.insertCreatureSpawn(row);
    auto destination = successor.map(0);
    const x = cellCoordinate(row.x), y = cellCoordinate(row.y);
    const gained = Region(7, 0, CellRect(x, y, x + 1, y + 1), 3, 2, RegionState.granted);
    const bundle = to.migrateOut(key => key == cell, 3, &owner.saveMigrant);
    ubyte[][uint] unused;
    successor.regionsChanged([gained], null, [gained.id: bundle], unused);
    auto migrated = cast(Creature) destination.findObject(target.guid);
    assert(migrated !is null && migrated.auras.find(mend, player.guid).channelToken == token);
    assert(migrated.auras.find(mend, player.guid).effects == 0b110);
    assert(abs(migrated.values.get!OBJECT_FIELD_SCALE_X - baseScale * 1.1f) < 0.001f);
    from.replicaCreated(3, cell, migrated.guid, encodeState(migrated, 0));
    uint rebinds, interrupts, applications;
    source.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
        assert(peer == 3 && request.channelled && request.namedCreature);
        if (request.channelUpdate)
        {
            assert(request.channelToken == token);
            if (request.auraMs)
                ++rebinds;
            else
                ++interrupts;
        }
        else
            ++applications;
        destination.replicaCreated(1, cell, player.guid, encodePlayerState(player, 0));
        successor.areaDamageArrived(1, request);
        return true;
    };
    successor.sendAreaDamage = (ushort peer, const ref AreaDamage reply) {
        assert(peer == 1 && reply.reply);
        source.areaDamageArrived(3, reply);
        return true;
    };
    client.session.update(50.msecs);
    assert(rebinds == 1 && player.values.get!UNIT_CHANNEL_SPELL == mend);
    const late = AreaDamage(sequence: source.nextGameplaySequence(), caster: player.guid, target: migrated.guid,
        spell: mend, map: 0, namedCreature: true, channelled: true, channelUpdate: true, channelToken: token - 1);
    successor.areaDamageArrived(1, late);
    assert(migrated.auras.find(mend, player.guid), "a cancellation from an earlier cast leaves this aura in place");
    migrated.updateAuras(destination, 599);
    assert(migrated.values.get!UNIT_FIELD_HEALTH == 80, "ownership change preserves the pending tick");
    migrated.updateAuras(destination, 1);
    assert(migrated.values.get!UNIT_FIELD_HEALTH == 90 && target.values.get!UNIT_FIELD_HEALTH == 80);
    assert(to.creatureAt(target.guid) is null && applications == 0, "a rebind never applies a second aura");
    client.write(Opcode.CMSG_CANCEL_CHANNELLING, cancel.data);
    assert(interrupts == 1 && !migrated.auras.find(mend, player.guid) && !player.values.get!UNIT_CHANNEL_SPELL);
    assert(abs(migrated.values.get!OBJECT_FIELD_SCALE_X - baseScale) < 0.001f);
    migrated.updateAuras(destination, 2000);
    assert(migrated.values.get!UNIT_FIELD_HEALTH == 90 && player.questStatus[quest.id].mobCount[0] == 1);

    client.write(Opcode.CMSG_CAST_SPELL, castPacket.data);
    assert(applications == 1 && migrated.auras.find(mend, player.guid).effects == 0b110);
    client.session.update(3.seconds);
    assert(!player.values.get!UNIT_CHANNEL_SPELL && player.questStatus[quest.id].mobCount[0] == 2,
        "only a completed channel confirmed by the current owner grants credit");
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
    auto aura = target.auras.find(strike);
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

    target.auras.remove(aura, target.values);
    foreach (node; [source, owner])
        node.data.spellScriptTargetMasks[strike][creatureInnkeeper] = 0b110;
    assert(caster.ai.castSpell(source.data.spells.spell(strike), caster.guid, castTriggered));
    assert(requests.length == 4 && requests[3].effect == 0);
    owner.areaDamageArrived(1, requests[3]);
    assert(target.values.get!UNIT_FIELD_HEALTH == health - 40 && target.auras.find(strike) is null,
        "the database can exclude all attached auras while retaining damage");

    foreach (node; [source, owner])
        node.data.spellScriptTargetMasks[strike][creatureInnkeeper] = 0b101;
    assert(caster.ai.castSpell(source.data.spells.spell(strike), caster.guid, castTriggered));
    assert(requests.length == 5 && requests[4].effect == 1, "the allowed aura becomes the routed effect");
    owner.areaDamageArrived(1, requests[4]);
    owner.areaDamageArrived(1, requests[4]);
    assert(target.values.get!UNIT_FIELD_HEALTH == health - 40);
    const allowed = target.auras.find(strike);
    assert(allowed && allowed.effects == 0b010 && allowed.stacks == 1);
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
