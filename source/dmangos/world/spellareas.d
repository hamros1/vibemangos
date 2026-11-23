/**
 * Persistent area auras (`SPELL_EFFECT_PERSISTENT_AREA_AURA`: Blizzard, Rain of Fire, Flamestrike's burning ground,
 * a boss's poison cloud), whoever casts them (docs/SPELLS.md, step 4).
 *
 * The spot is a `DynamicObject` the clients see; its caster keeps the list of its spots (a player's
 * `SpellHandlers`, a creature's `CreatureCasting`) and ticks them through `updatePersistentAreas`: each period the
 * enemies of the caster inside take the tick's damage, or (another aura: Flare's, a slow) have its aura for as long
 * as they stay (CMaNGOS's `PersistentAreaAura`).
 */
module dmangos.world.spellareas;

import dmangos.world.caster : Caster;
import dmangos.world.dynobject : DynamicObject;
import dmangos.world.movement : Position;
import dmangos.world.spellcast : SpellTargets;
import dmangos.world.spells : SpellInfo;
import dmangos.world.unit : UnitRef;

/// Persistent effects that strike directly on each area tick.
bool damagingGroundEffect(const ref SpellInfo spell, size_t effect)
{
    import dmangos.world.auras : AuraType;

    const type = spell.casting.applyAuraName[effect];
    return type == 0 || type == AuraType.periodicDamage;
}

bool withinGroundArea(Position target, Position center, float radius)
{
    return radius > 0 && (target.x - center.x) ^^ 2 + (target.y - center.y) ^^ 2
        + (target.z - center.z) ^^ 2 <= radius ^^ 2;
}

void hitGroundTarget(ref Caster caster, const(SpellInfo)* spell, UnitRef target, uint damage)
{
    import dmangos.world.spelldamage : spellDamage, SpellDamage;

    spellDamage(caster, spell, target, damage, spell.casting.school, SpellDamage(false, -1, true));
    if (auto player = caster.character)
        player.classAreaTick(spell, target);
}

/// Damage is delivered by the ground timer. Its hidden target aura occupies one
/// debuff slot without scheduling a second damage tick.
bool admitGroundDamage(UnitRef target, const(SpellInfo)* spell, ulong caster, uint level, int remaining)
{
    import dmangos.world.auras : hiddenTargetDebuff, makeAura;
    import dmangos.world.unit : UnitKind;

    if (!hiddenTargetDebuff(*spell))
        return true;
    if (auto active = target.auraSet.find(spell.id, caster))
    {
        active.duration = remaining;
        return true;
    }
    auto marker = makeAura(spell, caster, level, remaining, false, [0, 0, 0]);
    marker.detachedChannel = true;
    marker.effects = 0;
    if (target.kind == UnitKind.player)
        return target.session.addAura(marker);
    bool added;
    return target.creature.receiveAura(marker, target.map, added) !is null;
}

/// A remote ground aura is renewed without adding stacks or rerunning application effects.
bool refreshGroundAura(UnitRef victim, const(SpellInfo)* spell, size_t effect, ulong caster, uint level,
    int remaining, const int[3] values)
{
    import dmangos.world.unit : UnitKind;

    if (remaining <= 0)
        return false;
    foreach (aura; victim.auraSet.list)
        if (aura.spell is spell && aura.caster == caster && (aura.effects & (1 << effect)))
        {
            aura.duration = remaining;
            if (victim.kind == UnitKind.player)
                victim.session.sendAuraDuration(aura);
            return false;
        }
    auto aura = makeGroundAura(spell, effect, caster, level, remaining, values);
    if (victim.kind == UnitKind.player)
    {
        return victim.session.addAura(aura);
    }
    else
    {
        bool added;
        victim.creature.receiveAura(aura, victim.map, added);
        victim.map.flushObjectChanges(victim.creature);
        return added;
    }
}

private auto makeGroundAura(const(SpellInfo)* spell, size_t effect, ulong caster, uint level,
    int remaining, const int[3] values)
{
    import dmangos.world.auras : enableAuraEffect, makeAura;
    import dmangos.world.spellids : SpellEffect;

    auto aura = makeAura(spell, caster, level, remaining, false, values);
    aura.effects = 0;
    foreach (i, kind; spell.effect)
        if (kind == SpellEffect.persistentAreaAura && !damagingGroundEffect(*spell, i)
            && spell.casting.radiusIndex[i] == spell.casting.radiusIndex[effect])
            enableAuraEffect(aura, i, values[i]);
    aura.detachedChannel = true;
    return aura;
}

/// A persistent area aura's spot under way.
struct PersistentArea
{
    DynamicObject spot;
    const(SpellInfo)* spell;
    size_t effect;
    int value;      /// each tick's damage
    int amplitude;  /// ms between ticks
    int timer;      /// ms to the next tick
    int left;       /// ms it lasts yet
    bool[ulong] holding; /// those its aura is on: till they leave it, or it ends
}

/// Record active ground objects and their timers for their caster's next owner.
package void writeGroundAreas(const(PersistentArea)[] areas, ref imported!"dmangos.bytes".ByteWriter writer)
{
    import dmangos.serialization : serialize;
    import dmangos.world.objects : counterOf;

    writer.put(cast(uint) areas.length);
    foreach (ref area; areas)
    {
        writer.put(counterOf(area.spot.guid));
        writer.put(area.spell.id);
        writer.put(cast(ubyte) area.effect);
        writer.put(area.spot.radius);
        serialize(writer, area.spot.position);
        writer.put(area.value);
        writer.put(area.amplitude);
        writer.put(area.timer);
        writer.put(area.left);
        writer.put(cast(uint) area.holding.length);
        foreach (guid, _; area.holding)
            writer.put(guid);
    }
}

/// Remove the old caster's objects while their effects continue under the new owner.
package void detachGroundAreas(imported!"dmangos.world.map".Map map, ref PersistentArea[] areas)
{
    foreach (ref area; areas)
        map.removeObject(area.spot.guid);
    areas = null;
}

/// Recreate ground objects with their original GUID, duration and next tick time.
package PersistentArea[] readGroundAreas(ref Caster caster, ref imported!"dmangos.bytes".ByteReader reader)
{
    import dmangos.serialization : deserialize;
    import dmangos.world.spellids : SpellEffect;

    PersistentArea[] areas;
    foreach (_; 0 .. reader.read!uint)
    {
        const counter = reader.read!uint;
        const spell = caster.context.spellInfo(reader.read!uint);
        const effect = reader.read!ubyte;
        const radius = reader.read!float;
        const at = deserialize!Position(reader);
        const value = reader.read!int, amplitude = reader.read!int, timer = reader.read!int, left = reader.read!int;
        const holders = reader.read!uint;
        reader.ensureAvailable(cast(size_t) holders * ulong.sizeof);
        if (spell is null || effect >= spell.effect.length || spell.effect[effect] != SpellEffect.persistentAreaAura
            || amplitude <= 0 || timer <= 0 || left <= 0 || !(radius > 0))
        {
            reader.readBytes(cast(size_t) holders * ulong.sizeof);
            continue;
        }
        auto spot = new DynamicObject(counter, caster.guid, spell.id, effect, radius, at);
        auto area = PersistentArea(spot, spell, effect, value, amplitude, timer, left);
        foreach (j; 0 .. holders)
            area.holding[reader.read!ulong] = true;
        caster.map.addObject(spot);
        caster.map.observeGroundArea(spot, radius);
        areas ~= area;
    }
    return areas;
}

/**
 * The spot of effect `i` of `spell` (its radius and duration by the caster's modifiers) at the cast's destination,
 * or where the caster stands; added to `areas`.
 */
void makePersistentArea(ref Caster caster, ref PersistentArea[] areas, const(SpellInfo)* spell, size_t i,
    const ref SpellTargets targets, int value)
{
    import dmangos.world.spellcast : duration, radius, TargetFlags;
    import dmangos.world.spellmods : SpellModOp;

    auto context = caster.context;
    const r = caster.spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client)),
        ms = caster.modDuration(spell, duration(*spell, context.client, caster.level));
    if (r <= 0 || ms <= 0)
        return;
    Position at = caster.position;
    if (targets.mask & TargetFlags.destLocation)
        at = Position(targets.dest[0], targets.dest[1], targets.dest[2], at.orientation);
    auto spot = new DynamicObject(context.nextTemporaryCounter(), caster.guid, spell.id, i, r, at);
    caster.map.addObject(spot);
    caster.map.observeGroundArea(spot, r);
    const amplitude = spell.casting.amplitude[i] > 0 ? spell.casting.amplitude[i] : 1000;
    areas ~= PersistentArea(spot, spell, i, value, amplitude, amplitude, ms);
}

/// A persistent area's aura amounts: its own effect's (the spot's value), the others' as cast.
private int[3] areaAuraValues(ref Caster caster, const ref PersistentArea area)
{
    import std.random : uniform01;
    import dmangos.world.spellcast : effectValue;

    int[3] values;
    foreach (j; 0 .. 3)
        values[j] = j == area.effect ? area.value
            : effectValue(*area.spell, j, caster.level, uniform01(caster.map.random));
    return values;
}

/**
 * A persistent area's tick of damage (Blizzard's, Rain of Fire's): its value, the caster's spell power by the
 * tick's coefficient (`bonusCoefficient`), the damage over time modifiers on both (`SPELLMOD_DOT`: Piercing Ice).
 */
private uint areaTick(ref Caster caster, const ref PersistentArea area)
{
    import dmangos.world.spellcast : bonusCoefficient;
    import dmangos.world.spellmods : SpellModOp;

    int tick = area.value;
    const school = area.spell.casting.school;
    if (school != 0)
        if (const done = caster.spellPower(1 << school))
            if (done > 0)
                tick += cast(int)(done * bonusCoefficient(*area.spell, area.effect, caster.context.client, caster.level));
    tick = caster.spellMod(SpellModOp.dot, area.spell, tick);
    return tick > 0 ? tick : 0;
}

private void tickReplicas(ref Caster caster, const ref PersistentArea area, bool hurts, uint damage, int holdMs)
{
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.world.auras : AuraType;
    import dmangos.world.combat : creatureTypeHumanoid, creatureTypes;
    import dmangos.world.relations : canAttack;
    import dmangos.world.replication : Replica;
    import dmangos.world.spellmods : SpellModOp;
    import dmangos.world.unit : UnitRef, combatRelations;
    import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

    auto context = caster.context;
    const at = area.spot.position;
    const spell = area.spell;
    const school = spell.casting.school;
    if (!context.canWrite() || school >= 7 || (!hurts && holdMs <= 0))
        return;
    AreaDamage tick = AreaDamage(caster: caster.guid, spell: spell.id, effect: cast(ubyte) area.effect,
        map: caster.map.id, instance: caster.map.instanceId, x: at.x, y: at.y, z: at.z,
        radius: area.spot.radius, casterLevel: caster.level, amount: 0, groundTick: true, groundAmount: damage, auraMs: holdMs);
    if (hurts)
    {
        tick.threatFactor = caster.spellMod(SpellModOp.threat, spell, 1.0f);
        tick.resistanceModifier = school == 0 ? cast(int) caster.fighter.armorIgnored
            : caster.auras.totalByMiscMask(AuraType.modTargetResistance, 1 << school);
    }
    else
    {
        tick.auraValues = areaAuraValues(caster, area);
    }
    const from = caster.relating();
    foreach (object; caster.map.objectsNear(at, tick.radius))
    {
        auto copy = cast(Replica) object;
        if (copy is null || copy.owner == context.nodeId
            || (copy.fields.type != TypeId.unit && copy.fields.type != TypeId.player))
            continue;
        auto other = UnitRef.observed(copy, caster.map);
        if (!other.alive || !canAttack(from, other.combatRelations(context.client), context.client))
            continue;
        if (hurts)
        {
            if (auto player = caster.character)
            {
                uint type = creatureTypeHumanoid;
                if (copy.fields.type == TypeId.unit)
                    if (const proto = copy.fields.get!OBJECT_FIELD_ENTRY in context.data.creatureTemplates)
                        type = proto.creatureType;
                const mods = &player.player.damageMods;
                tick.amount = damage * mods.school[school] * (type < creatureTypes ? mods.versus[type] : 1);
            }
            else
                tick.amount = damage * caster.auras.multiplier(AuraType.modDamagePercentDone,
                    (int mask) => (mask & (1 << school)) != 0, -1);
        }
        tick.target = copy.guid;
        tick.sequence = context.nextGameplaySequence();
        caster.map.holdCasterReplica(caster.guid, copy.owner, cast(uint) area.amplitude + 5_000);
        context.sendAreaDamage(copy.owner, tick);
    }
}

/// The spots' ticks and ends.
void updatePersistentAreas(ref Caster caster, ref PersistentArea[] areas, int diff)
{
    import std.algorithm.comparison : min;
    import dmangos.world.unit : Blow, dealDamage, UnitKind;

    auto map = caster.map;
    const clustered = caster.context.sendAreaDamage !is null;
    foreach_reverse (k, ref area; areas)
    {
        area.timer -= min(diff, area.left);
        area.left -= diff;
        while (area.timer <= 0)
        {
            area.timer += area.amplitude;
            const r = area.spot.radius;
            const at = area.spot.position;
            // Damage over time hurts; another aura (Flare's, a slow) is on those inside for what the area has
            // left, until they leave it.
            const hurts = damagingGroundEffect(*area.spell, area.effect);
            const damage = hurts ? areaTick(caster, area) : 0;
            // Renewal tolerates two world updates of delivery jitter. Expiry bounds the aura even
            // if the victim moves to a node outside the caster's view, or the caster vanishes.
            const grace = 2 * cast(long) caster.context.config.updateIntervalMs;
            const holdMs = clustered ? cast(int) min(area.left, area.amplitude + grace)
                : area.left > area.amplitude ? area.left : area.amplitude;
            bool[ulong] inArea;
            void reach(UnitRef unit)
            {
                if (!unit.alive || !withinGroundArea(unit.position, at, r) || !caster.hostileTo(unit))
                    return;
                if (hurts)
                {
                    import dmangos.world.auras : hiddenTargetDebuff;

                    if (hiddenTargetDebuff(*area.spell))
                    {
                        if (!admitGroundDamage(unit, area.spell, caster.guid, caster.level, holdMs > 0 ? holdMs : 1))
                            return;
                        area.holding[unit.combatGuid] = true;
                        inArea[unit.combatGuid] = true;
                    }
                    hitGroundTarget(caster, area.spell, unit, damage);
                    return;
                }
                const guid = unit.combatGuid;
                inArea[guid] = true;
                if (clustered)
                {
                    area.holding[guid] = true;
                    if (refreshGroundAura(unit, area.spell, area.effect, caster.guid, caster.level, holdMs,
                        areaAuraValues(caster, area)) && unit.kind == UnitKind.creature)
                    {
                        caster.enteredCombat(0);
                        dealDamage(caster.unit, unit, 0, Blow.spell());
                    }
                    return;
                }
                if (guid in area.holding)
                    return;
                area.holding[guid] = true;
                auto aura = makeGroundAura(area.spell, area.effect, caster.guid, caster.level, holdMs,
                    areaAuraValues(caster, area));
                final switch (unit.kind)
                {
                case UnitKind.none:
                    break;
                case UnitKind.creature:
                    bool isNew;
                    unit.creature.receiveAura(aura, map, isNew);
                    map.flushObjectChanges(unit.creature);
                    if (isNew) // an attack: it fights back
                    {
                        caster.enteredCombat(0);
                        dealDamage(caster.unit, unit, 0, Blow.spell());
                    }
                    break;
                case UnitKind.player:
                    unit.session.addAura(aura);
                    break;
                }
            }
            foreach (creature; map.creaturesNear(at, r))
                if (creature.guid != caster.guid && creature.ai !is null)
                    reach(map.unitOf(creature));
            foreach (u; map.playersNear(at, r)) // players it may fight (a duel's opponent, world PvP, a creature's foes)
                reach(u);
            if (clustered)
                tickReplicas(caster, area, hurts, damage, holdMs);
            foreach (guid; area.holding.keys) // those who left it lose it
                if (guid !in inArea)
                {
                    loseAreaAura(caster, guid, area.spell);
                    area.holding.remove(guid);
                }
        }
        if (area.left <= 0)
        {
            foreach (guid; area.holding.keys)
                loseAreaAura(caster, guid, area.spell);
            map.removeObject(area.spot.guid);
            areas = areas[0 .. k] ~ areas[k + 1 .. $];
        }
    }
}

/// `guid` loses `caster`'s aura of the persistent area of `spell`.
private void loseAreaAura(ref Caster caster, ulong guid, const(SpellInfo)* spell)
{
    import dmangos.world.unit : UnitKind;

    auto unit = caster.map.unit(guid);
    final switch (unit.kind)
    {
    case UnitKind.none:
        return;
    case UnitKind.creature:
        if (auto aura = unit.creature.auras.find(spell.id, caster.guid))
        {
            unit.creature.loseAura(aura, caster.map);
            caster.map.flushCreature(unit.creature);
        }
        return;
    case UnitKind.player:
        if (auto aura = unit.session.player.auras.find(spell.id, caster.guid))
            unit.session.removeAura(aura);
        return;
    }
}

/// Every spot of `areas` goes (its caster left, died, or stopped channelling them: `spell`, if not null).
void endPersistentAreas(ref Caster caster, ref PersistentArea[] areas, const(SpellInfo)* spell = null)
{
    foreach_reverse (k, ref area; areas)
        if (spell is null || area.spell is spell)
        {
            foreach (guid; area.holding.keys)
                loseAreaAura(caster, guid, area.spell);
            caster.map.removeObject(area.spot.guid);
            areas = areas[0 .. k] ~ areas[k + 1 .. $];
        }
}

/// A ground channel keeps its tick count when its victim changes owners, including a tick already on the wire.
unittest
{
    import core.time : MonoTime, msecs;
    import std.format : format;
    import dmangos.bytes : ByteWriter, floatBits;
    import dmangos.cluster.protocol : AreaDamage, decode;
    import dmangos.dbc : buildDbc;
    import dmangos.serialization : serialize;
    import dmangos.world.clientdata : chrRacesFormat, factionTemplateFormat, spellDurationFormat, spellRadiusFormat;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.spellcast : TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : AuraType, ImplicitTarget, SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    auto db = newDatabase();
    auto oldOwner = newCreationContext(db), casterNode = newCreationContext(db);
    auto relay = new TestPlayerRelay(oldOwner, casterNode);
    auto now = MonoTime.currTime;
    oldOwner.clock = casterNode.clock = () => now;
    enum uint rain = 95710, slow = 95711, amplitude = 1000, duration = 5000;
    uint[chrRacesFormat.length] human, orc;
    human[0] = raceHuman;
    human[2] = human[8] = 7;
    orc[0] = raceOrc;
    orc[2] = orc[8] = 1;
    foreach (node; [oldOwner, casterNode])
    {
        node.client.races = typeof(node.client.races).parse(buildDbc(chrRacesFormat, [human[], orc[]]), "ChrRaces.dbc");
        node.client.factionTemplates = typeof(node.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
            [[7u, 1, 0, 2, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0], [1u, 2, 0, 4, 4, 2, 0, 0, 0, 0, 0, 0, 0, 0]]),
            "FactionTemplate.dbc");
        node.client.spellRadii = typeof(node.client.spellRadii).parse(buildDbc(spellRadiusFormat,
            [[1u, floatBits(12), 0, 0]]), "SpellRadius.dbc");
        node.client.spellDurations = typeof(node.client.spellDurations).parse(buildDbc(spellDurationFormat,
            [[1u, duration, 0, duration]]), "SpellDuration.dbc");
        auto damage = testSpell(rain, SpellEffect.persistentAreaAura, ImplicitTarget.caster, 10);
        damage.attributesEx |= 0x04; // channeled
        damage.casting.school = 1; // holy here so resistance cannot make tick counts ambiguous
        damage.casting.durationIndex = 1;
        damage.casting.radiusIndex[0] = 1;
        damage.casting.amplitude[0] = amplitude;
        damage.casting.applyAuraName[0] = AuraType.periodicDamage;
        node.data.spells.spells[rain] = damage;
        auto chill = damage;
        chill.id = slow;
        chill.basePoints[0] = -41;
        chill.casting.applyAuraName[0] = AuraType.modDecreaseSpeed;
        chill.casting.stackAmount = 3;
        node.data.spells.spells[slow] = chill;
    }
    const center = Position(100, 100, 40);
    const inside = Position(105, 100, 40), outside = Position(120, 100, 40);
    auto caster = loggedIn(casterNode, db, 7, "Anduin", center, characterLevel: 20, setup: (ref c) {
        c.spells = [NewSpell(rain, true), NewSpell(slow, true)];
    });
    auto target = loggedIn(oldOwner, db, 8, "Thrall", inside, race: raceOrc, characterLevel: 20);
    auto victim = cast(Player) target.session.character;
    const startingHealth = victim.values.get!UNIT_FIELD_MAXHEALTH;
    victim.values.set!UNIT_FIELD_HEALTH(startingHealth);
    target.write(Opcode.CMSG_TOGGLE_PVP, [ubyte(1)]);
    auto source = cast(Player) caster.session.character;
    oldOwner.map(0).replicaCreated(casterNode.nodeId, cellKeyAt(center.x, center.y), source.guid,
        encodePlayerState(source, 0));
    casterNode.map(0).replicaCreated(oldOwner.nodeId, cellKeyAt(inside.x, inside.y), victim.guid,
        encodePlayerState(victim, 0));

    AreaDamage[] requests, replies;
    AreaDamage throughWire(const ref AreaDamage tick)
    {
        ByteWriter payload;
        serialize(payload, tick);
        return decode!AreaDamage(payload.data);
    }
    casterNode.sendAreaDamage = (ushort peer, const ref AreaDamage message) {
        assert(peer == oldOwner.nodeId && message.groundTick && !message.reply);
        requests ~= throughWire(message);
        return true;
    };
    oldOwner.sendAreaDamage = (ushort peer, const ref AreaDamage message) {
        assert(peer == casterNode.nodeId && message.groundTick && message.reply);
        replies ~= throughWire(message);
        return true;
    };
    void castGround(uint spell)
    {
        ByteWriter w;
        w.put(spell);
        SpellTargets(TargetFlags.self, 0).write(w);
        caster.write(Opcode.CMSG_CAST_SPELL, w.data);
        assert(source.values.get!UNIT_CHANNEL_SPELL == spell);
    }
    void tick()
    {
        now += amplitude.msecs;
        caster.session.update(amplitude.msecs);
    }
    void cancelGround(uint spell)
    {
        ByteWriter w;
        w.put(spell);
        caster.write(Opcode.CMSG_CANCEL_CHANNELLING, w.data);
    }
    castGround(slow);
    tick();
    assert(requests.length == 1);
    oldOwner.areaDamageArrived(casterNode.nodeId, requests[$ - 1]);
    auto aura = victim.auras.find(slow);
    assert(aura !is null, format!"the remote aura landed: %s"(requests[$ - 1]));
    assert(aura.amount[0] < 0 && aura.stacks == 1, format!"slow amount %s, stack count %s"(aura.amount[0], aura.stacks));
    tick();
    oldOwner.areaDamageArrived(casterNode.nodeId, requests[$ - 1]);
    assert(victim.auras.find(slow) is aura && aura.stacks == 1, "renewal keeps the same aura and stack count");
    victim.movement.position = outside;
    tick();
    oldOwner.areaDamageArrived(casterNode.nodeId, requests[$ - 1]); // the caster still sees the older position
    target.session.update((amplitude + 200).msecs);
    assert(victim.auras.find(slow) is null, "a departed target is never renewed");
    cancelGround(slow);
    victim.movement.position = inside;
    requests = null;

    castGround(rain);
    tick();
    assert(requests.length == 1);
    foreach (_; 0 .. 2)
        oldOwner.areaDamageArrived(casterNode.nodeId, requests[0]);
    assert(victim.values.get!UNIT_FIELD_HEALTH == startingHealth - 10 && replies.length == 1);
    casterNode.areaDamageArrived(oldOwner.nodeId, replies[0]);

    tick();
    assert(requests.length == 2);
    // The in-memory database records progress writes separately from its login fixtures.
    db.loadable[8].health = startingHealth - 10;
    assert(target.session.inWorld.actAtReplica(source.guid, ArrivalAction.init));
    assert(db.progressSaves[$ - 1].health == startingHealth - 10);
    assert(relay.remote !is null && relay.remote.character !is null);
    auto migrated = cast(Player) relay.remote.character;
    assert(migrated.values.get!UNIT_FIELD_HEALTH == startingHealth - 10, "handoff keeps damage already applied");
    foreach (_; 0 .. 2)
        oldOwner.areaDamageArrived(casterNode.nodeId, requests[1]);
    assert(replies.length == 2 && replies[1].groundRedirect == casterNode.nodeId);
    foreach (_; 0 .. 2)
        casterNode.areaDamageArrived(oldOwner.nodeId, replies[1]);
    assert(migrated.values.get!UNIT_FIELD_HEALTH == startingHealth - 20, "the in-flight tick follows its victim exactly once");
    tick();
    assert(migrated.values.get!UNIT_FIELD_HEALTH == startingHealth - 30 && requests.length == 2, "the next tick is local only");
    cancelGround(rain);
    tick();
    assert(migrated.values.get!UNIT_FIELD_HEALTH == startingHealth - 30 && requests.length == 2, "cancelling stops ticking");
}
