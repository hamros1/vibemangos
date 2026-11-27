/**
 * Spells tested on the real data: the client's DBC files and the world database the server runs on, not spells made
 * up for a test. A test with invented fields agrees with the code's own assumptions (Cold Snap passed while Ice
 * Block, whose cooldown is its category's, was never reset); one with the real rows does not.
 *
 * These run only where `DMANGOS_REAL_DATA` names the data, as `dataDir|mysqlLibrary|worldConnection` (the
 * connection as `world_database` has it): the full check (tools/harness/check.sh) sets it, with the harness's
 * database; elsewhere they do nothing. The data is loaded once for all of them.
 */
module dmangos.world.realspelltests;

version (unittest):

import core.time : MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;
import dmangos.auth.accounts : AccountLevel;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : WorldConfig;
import dmangos.world.context : WorldContext;
import dmangos.world.database : MemoryWorldDatabase;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.player : CharacterData, Player;
import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
import dmangos.world.testclient;
import dmangos.world.testdata : raceHuman, raceOrc;
import dmangos.world.worlddata : WorldData;

private __gshared ClientData realClient;
private __gshared WorldData realWorldData;
private __gshared string realDataDir;
private __gshared bool realLoaded, realTried;

/// The real data, loaded at the first call; false (nothing to test against) without `DMANGOS_REAL_DATA`.
bool haveRealData()
{
    import std.array : split;
    import std.process : environment;
    import dmangos.mysql : ConnectionInfo, MySqlConnection;

    if (realTried)
        return realLoaded;
    realTried = true;
    const named = environment.get("DMANGOS_REAL_DATA");
    if (named is null)
        return false;
    const parts = named.split("|");
    assert(parts.length == 3, "DMANGOS_REAL_DATA: dataDir|mysqlLibrary|worldConnection");
    realDataDir = parts[0];
    realClient = ClientData.load(realDataDir);
    auto world = new MySqlConnection(ConnectionInfo.parse(parts[2]), parts[1]);
    scope (exit)
        world.close();
    realWorldData = WorldData.load(world, realClient);
    realLoaded = true;
    return true;
}

/// A world on the real data, characters in memory, its clock the test's.
struct RealWorld
{
    MemoryWorldDatabase db;
    WorldContext context;
    MonoTime now;

    static RealWorld make(uint seed = 20_261_120)
    {
        return make(seed, false);
    }

    static RealWorld make(uint seed, bool withTerrain)
    {
        RealWorld w;
        w.db = newDatabase();
        WorldConfig config;
        config.logoutDelay = 0;
        if (withTerrain)
            config.dataDir = realDataDir;
        w.context = new WorldContext(config, w.db, realWorldData, realClient);
        w.now = MonoTime.currTime;
        // The same rolls at every run: a test passes or fails for good, not one run in twenty.
        {
            import std.random : rndGen;

            w.context.map(0).random.seed(seed);
            rndGen.seed(seed);
        }
        return w;
    }

    /// A character of `classId` and `level` (a human, else of `race`) in Stormwind's Trade District, logged in,
    /// knowing `spells`.
    TestClient character(uint guid, string name, ubyte classId, uint level, const(uint)[] spells,
        ubyte race = raceHuman)
    {
        auto clock = &now;
        context.clock = () => *clock;
        auto client = loggedIn(context, db, guid, name, Position(-8835, 615, 93), AccountLevel.player, race, 0,
            level, (ref CharacterData c) { c.classId = classId; });
        auto me = cast(Player) client.session.character;
        {
            import dmangos.world.updatefields : UNIT_FIELD_MAXPOWER1, UNIT_FIELD_POWER1;

            foreach (power; 0 .. 5) // full, as a rested character is (the record in memory saved none)
                me.values.set!UNIT_FIELD_POWER1(power, me.values.get!UNIT_FIELD_MAXPOWER1(power));
        }
        foreach (spell; spells)
            if (!me.knowsSpell(spell))
                me.spells ~= spell;
        client.read();
        return client;
    }

    /// A hostile creature of `entry` (6: a Kobold Vermin) two yards in front of `who`, its guid.
    ulong enemy(ref TestClient who, uint entry = 6)
    {
        import dmangos.world.creature : TempSpawnType;

        auto me = cast(Player) who.session.character;
        auto at = me.position;
        at.x += 2;
        auto creature = context.summonCreature(context.map(0), entry, at, TempSpawnType.manual, 0, 0);
        assert(creature !is null, "no such creature in the world database");
        who.read();
        return creature.guid;
    }

    /// Casts `spell` at `target`.
    SpellCastResult castAt(ref TestClient who, uint spell, ulong target)
    {
        const info = context.data.spells.spell(spell);
        assert(info !is null, "no such spell in the world database");
        return who.session.inWorld.castSpell(info, SpellTargets(TargetFlags.unit, target), false, 0);
    }

    /// Casts `spell` (from the real data) on oneself.
    SpellCastResult cast_(ref TestClient who, uint spell)
    {
        const info = context.data.spells.spell(spell);
        assert(info !is null, "no such spell in the world database");
        return who.session.inWorld.castSpell(info, SpellTargets(TargetFlags.self, 0), false, 0);
    }
}

enum ubyte classMageId = 8, classRogueId = 4, classWarriorId = 1;

/// Devotion Aura follows its raid subgroup across nodes and leaves when its renewal expires.
unittest
{
    import dmangos.cluster.protocol : GroupMemberState, GroupState, PartyAreaAura;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : GroupType;
    import dmangos.world.replication : encodePlayerState;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    source.context.nodeId = 1;
    owner.context.nodeId = 2;
    enum uint devotion = 465;
    auto paladin = source.character(7, "Uther", 2, 60, [devotion]);
    auto knight = owner.character(8, "Anduin", classWarriorId, 60, []);
    auto caster = paladin.session.inWorld, member = knight.session.inWorld;
    auto from = source.context.map(0), to = owner.context.map(0);
    const at = caster.player.position, there = member.player.position;
    from.replicaCreated(2, cellKeyAt(there.x, there.y), member.player.guid, encodePlayerState(member.player, 0));
    to.replicaCreated(1, cellKeyAt(at.x, at.y), caster.player.guid, encodePlayerState(caster.player, 0));
    GroupState raid;
    raid.id = 100;
    raid.leader = 7;
    raid.leaderName = "Uther";
    raid.groupType = GroupType.raid;
    raid.members = [GroupMemberState(7, "Uther", 0), GroupMemberState(8, "Anduin", 0)];
    source.context.groups.mirror(raid);
    raid.members[1].subGroup = 1;
    owner.context.groups.mirror(raid);
    size_t renewals;
    source.context.sendPartyAreaAura = (ushort peer, const ref PartyAreaAura renewal) {
        assert(peer == 2 && renewal.spell == devotion && renewal.target == 8);
        ++renewals;
        owner.context.partyAreaAuraArrived(1, renewal);
        return true;
    };
    assert(source.cast_(paladin, devotion) == SpellCastResult.ok);

    void refresh()
    {
        source.now += 1.seconds;
        owner.now += 1.seconds;
        caster.updateAreaAuras(1.seconds);
    }

    refresh();
    assert(renewals == 1 && member.player.auras.find(devotion) is null, "the recipient checks its own subgroup");
    raid.members[1].subGroup = 0;
    owner.context.groups.mirror(raid);
    refresh();
    auto aura = member.player.auras.find(devotion, 7);
    assert(aura !is null && aura.amount == caster.player.auras.find(devotion).amount);
    refresh();
    assert(member.player.auras.find(devotion, 7) is aura, "renewal keeps the same aura instance");
    member.saveAuras();
    assert(!owner.db.auraRows.get(8, null).length, "an inherited party aura is recalculated after login");

    member.player.movement.position.x += 1000;
    refresh();
    member.updateAreaAuras(1.seconds);
    assert(member.player.auras.find(devotion) is null, "the real recipient position decides distance");
    member.player.movement.position = there;
    refresh();
    assert(member.player.auras.find(devotion, 7) !is null);
    owner.now += 3.seconds;
    member.updateAreaAuras(3.seconds);
    assert(member.player.auras.find(devotion) is null, "without a renewal it cannot persist after owner loss");
}

/// Fire Blossom's real periodic aura can hit both the tank and a lower-threat raider.
unittest
{
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;

    auto w = RealWorld.make();
    auto tank = w.character(111, "Tank", classWarriorId, 60, []);
    auto raider = w.character(112, "Raider", classMageId, 60, []);
    foreach (client; [tank, raider])
    {
        auto player = cast(Player) client.session.character;
        player.values.set!UNIT_FIELD_MAXHEALTH(100_000);
        player.values.set!UNIT_FIELD_HEALTH(100_000);
    }
    auto map = w.context.map(0);
    auto firewalker = map.creatureAt(w.enemy(tank, 11666));
    auto tankUnit = map.unit(tank.session.character.guid), raiderUnit = map.unit(raider.session.character.guid);
    firewalker.ai.attackedBy(tankUnit, map);
    firewalker.ai.addThreat(tankUnit, 1000);
    firewalker.ai.addThreat(raiderUnit, 1);
    auto blossom = w.context.data.spells.spell(19636);
    assert(blossom !is null);
    foreach (_; 0 .. 3)
    {
        assert(firewalker.ai.castSpell(blossom, firewalker.guid, castTriggered));
        foreach (pulse; 0 .. 6)
            firewalker.updateAuras(map, 1000);
    }
    assert(tankUnit.health < 100_000 && raiderUnit.health < 100_000, "Fire Blossom pulses beyond the tank");
}

/// Baron Rivendare's Unholy Aura deals damage without pulling him or placing the player in combat.
unittest
{
    if (!haveRealData())
        return;

    auto w = RealWorld.make();
    auto raider = w.character(113, "Scout", classWarriorId, 60, []);
    auto map = w.context.map(0);
    auto baron = map.creatureAt(w.enemy(raider, 10440));
    auto player = raider.session.inWorld;
    baron.ai.update(map, 1000);
    assert(baron.auras.find(17467) !is null, "the real idle EventAI rule supplies Unholy Aura");
    assert(!baron.ai.inCombat && !player.inCombat);
    const health = player.unit.health;
    foreach (_; 0 .. 3)
        baron.updateAuras(map, 2000);
    assert(player.unit.health < health, "Unholy Aura damages nearby players");
    assert(!baron.ai.inCombat && !player.inCombat, "the aura alone does not start combat");
}

/// The creature's Arcane Missiles remain on the original target and stop when interrupted.
unittest
{
    import dmangos.bytes : ByteReader;
    import dmangos.script.api : ActionResult;
    import std.format : format;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT, UNIT_FIELD_MAXPOWER1,
        UNIT_FIELD_POWER1;

    if (!haveRealData())
        return;

    auto w = RealWorld.make();
    auto first = w.character(114, "Missiletarget", classWarriorId, 38, []);
    auto second = w.character(115, "Missiledecoy", classWarriorId, 38, []);
    auto map = w.context.map(0);
    auto invoker = map.creatureAt(w.enemy(first, 1835));
    auto target = map.unit(first.session.character.guid), decoy = map.unit(second.session.character.guid);
    invoker.ai.setScript(null, w.context.data.eventAi); // isolate the tested cast from the Invoker's recast timer
    invoker.ai.attackedBy(target, map);
    invoker.ai.scriptMelee(false);
    invoker.ai.scriptCombatMovement(false);
    const targetHealth = target.health, decoyHealth = decoy.health;
    auto pulses(uint pulse, ulong expected)
    {
        uint count;
        foreach (packet; first.read())
            if (packet.opcode == Opcode.SMSG_SPELL_GO)
            {
                auto r = ByteReader(packet.body_);
                r.readPackedGuid();
                if (r.readPackedGuid() != invoker.guid || r.read!uint != pulse)
                    continue;
                r.read!ushort;
                const hitCount = r.read!ubyte;
                assert(hitCount <= 1);
                if (hitCount)
                    assert(r.read!ulong == expected);
                else
                {
                    assert(r.read!ubyte == 1);
                    assert(r.read!ulong == expected);
                }
                ++count;
            }
        return count;
    }

    enum uint channel = 15735, missile = 15736;
    assert(invoker.ai.castFor(map, channel, target.combatGuid, false) == ActionResult.ok);
    assert(invoker.values.get!UNIT_CHANNEL_SPELL == channel && invoker.values.get!UNIT_FIELD_CHANNEL_OBJECT == target.combatGuid);
    invoker.tick(map, 1000);
    assert(pulses(missile, target.combatGuid) == 1);
    invoker.ai.taunt(decoy, map);
    assert(invoker.values.get!UNIT_FIELD_CHANNEL_OBJECT == target.combatGuid);
    invoker.tick(map, 1000);
    assert(pulses(missile, target.combatGuid) == 1);
    invoker.ai.interruptedBySpell(3000);
    assert(!invoker.ai.castingNow && !invoker.values.get!UNIT_CHANNEL_SPELL && !invoker.auras.find(channel));
    assert(invoker.ai.castFor(map, channel, target.combatGuid, false) != ActionResult.ok, "Arcane school locked out");
    invoker.tick(map, 5000);
    assert(pulses(missile, target.combatGuid) == 0);
    assert(target.health < targetHealth && decoy.health == decoyHealth);

    first.session.inWorld.godModeCheat = true;
    foreach (variant; [15735u, 15790u, 22272u])
    {
        invoker.values.set!UNIT_FIELD_POWER1(invoker.values.get!UNIT_FIELD_MAXPOWER1);
        assert(invoker.ai.castFor(map, variant, target.combatGuid, false) == ActionResult.ok);
        invoker.tick(map, 7000); // A coarse tick must stop at the end of the channel.
        const child = w.context.data.spells.spell(variant).triggerSpell[0];
        const count = pulses(child, target.combatGuid);
        assert(count == 5, format!"Arcane Missiles %s: %s pulses, %s target health"(variant, count, target.health));
        assert(!invoker.ai.castingNow && !invoker.auras.find(variant));
    }
    assert(decoy.health == decoyHealth);
}

/// A missile lands once even when its NPC caster moves to a third node before impact.
unittest
{
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.grid : cellCoordinate, cellKeyAt, cellSize;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.updatefields : UNIT_FIELD_CHANNEL_OBJECT;

    if (!haveRealData())
        return;

    foreach (moves; [false, true])
    {
        auto source = RealWorld.make(), owner = RealWorld.make(), successor = RealWorld.make();
        source.context.nodeId = 1;
        owner.context.nodeId = 2;
        successor.context.nodeId = 3;
        // All three workers observe the same instant, independent of fixture construction time.
        source.now = owner.now = successor.now;
        source.context.clock = () => source.now;
        owner.context.clock = () => owner.now;
        successor.context.clock = () => successor.now;
        const origin = Position(2 * cellSize - 2, 100, 40), at = Position(2 * cellSize + 2, 100, 40);
        const originCell = cellKeyAt(origin.x, origin.y), targetCell = cellKeyAt(at.x, at.y);
        auto from = source.context.map(0), to = owner.context.map(0);
        auto caster = source.context.summonCreature(from, 1835, origin, TempSpawnType.manual, 0, 0);
        auto target = loggedIn(owner.context, owner.db, 116, "Remotevictim", at, AccountLevel.player, raceHuman, 0, 38);
        auto player = cast(Player) target.session.character;
        from.replicaCreated(2, targetCell, player.guid, encodePlayerState(player, 0));
        to.replicaCreated(1, originCell, caster.guid, encodeState(caster, 0));
        caster.ai.setScript(null, source.context.data.eventAi);
        caster.ai.bind(from);

        uint impacts;
        ushort expectedOwner = 1;
        bool dispatch(ushort sender, ushort peer, const ref AreaDamage hit)
        {
            assert(peer == 2 && sender == expectedOwner && hit.caster == caster.guid
                && hit.target == player.guid && hit.spell == 15736);
            ++impacts;
            owner.context.areaDamageArrived(sender, hit);
            return true;
        }
        source.context.sendAreaDamage = (ushort peer, const ref AreaDamage hit) => dispatch(1, peer, hit);
        successor.context.sendAreaDamage = (ushort peer, const ref AreaDamage hit) => dispatch(3, peer, hit);
        const health = target.session.inWorld.unit.health;
        assert(caster.ai.castSpell(source.context.data.spells.spell(15735), player.guid, 0) && caster.ai.castingNow);
        caster.tick(from, 1000);
        assert(impacts == 0, "the missile is still travelling");
        source.now += 100.msecs;
        successor.now += 100.msecs;
        if (moves)
        {
            const x = cellCoordinate(origin.x), y = cellCoordinate(origin.y);
            const region = Region(7, 0, CellRect(x, y, x + 1, y + 1), 3, 1, RegionState.granted);
            const bundle = from.migrateOut(cell => cell == originCell, 3, &source.context.saveMigrant);
            ubyte[][uint] unused;
            successor.context.recovery.regionsChanged([region], null, [region.id: bundle], unused);
            from = successor.context.map(0);
            caster = from.creatureAt(caster.guid);
            assert(caster !is null && caster.ai.castingNow
                && caster.values.get!UNIT_FIELD_CHANNEL_OBJECT == player.guid,
                "the moved channel keeps its original target");
            from.replicaCreated(2, targetCell, player.guid, encodePlayerState(player, 0));
            to.replicaCreated(3, originCell, caster.guid, encodeState(caster, 0));
            expectedOwner = 3;
        }
        source.now += 50.msecs;
        successor.now += 50.msecs;
        source.context.update(source.now);
        successor.context.update(successor.now);
        assert(impacts == 0 && target.session.inWorld.unit.health == health, "handoff preserves flight time");
        source.now += 125.msecs;
        successor.now += 125.msecs;
        source.context.update(source.now);
        successor.context.update(successor.now);
        assert(impacts == 1 && target.session.inWorld.unit.health < health, "an in-flight missile follows its caster");
        if (moves)
        {
            caster.tick(from, 1000);
            assert(impacts == 1, "the next pulse is also in flight");
        }
        caster.ai.interruptedBySpell(3000);
        caster.tick(from, 5000);
        source.now += 3.seconds;
        successor.now += 3.seconds;
        source.context.update(source.now);
        successor.context.update(successor.now);
        assert(impacts == (moves ? 2 : 1) && !caster.ai.castingNow,
            "only already launched missiles land after the interruption");
    }
}

/// Krakle's Thermometer starts its database script even when the implicitly selected creature is remote.
unittest
{
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.gameobject : GameObjectSpawn;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.replication : encodeState;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    owner.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, owner.context);
    const origin = Position(-8950, -132, 83.53f), at = Position(origin.x + 3, origin.y, origin.z);
    auto client = loggedIn(source.context, source.db, 7, "Anduin", origin);
    enum uint thermometer = 12472, targetEntry = 10541;
    client.session.inWorld.storeLoot(thermometer, 1, 0, false);
    client.read();
    auto player = cast(Player) client.session.character;
    auto item = player.inventory[inventorySlotBag0, backpackSlot(player, thermometer)];
    assert(item !is null);
    source.db.loadable[7].items = [source.db.itemRows[item.guid]];
    auto targetMap = owner.context.map(0);
    auto target = owner.context.summonCreature(targetMap, targetEntry, at, TempSpawnType.manual, 0, 0);
    const focus = GameObjectSpawn(5000, 148503, 0, at.x, at.y, at.z);
    targetMap.addObject(owner.context.makeGameObject(focus));
    source.context.map(0).replicaCreated(2, cellKeyAt(at.x, at.y), target.guid, encodeState(target, 0));

    ByteWriter use;
    use.put(item.bagSlot);
    use.put(item.slot);
    use.put(ubyte(1));
    SpellTargets(TargetFlags.self).write(use);
    client.write(Opcode.CMSG_USE_ITEM, use.data);
    assert(relay.remote !is null && source.context.runningScripts == 0 && owner.context.runningScripts == 0,
        "move to the thermometer's target before casting");
    relay.remote.update(50.msecs);
    relay.remote.update(10.seconds);
    assert(source.context.runningScripts == 0 && owner.context.runningScripts == 1,
        "the target owner starts the original database script once");
}

/// A ground channel follows the caster and keeps its next damage tick and original ground object.
unittest
{
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.dynobject : DynamicObject;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.replication : encodeState;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_HEALTH;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    owner.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, owner.context);
    enum uint rain = 5740;
    auto client = source.character(7, "Anduin", 9, 30, [rain]);
    auto caster = cast(Player) client.session.character;
    const origin = caster.position, at = Position(origin.x + 3, origin.y, origin.z);
    auto from = source.context.map(0), to = owner.context.map(0);
    auto target = owner.context.summonCreature(to, 6, at, TempSpawnType.manual, 0, 0);
    from.replicaCreated(2, cellKeyAt(at.x, at.y), target.guid, encodeState(target, 0));
    ByteWriter spell;
    spell.put(rain);
    auto targets = SpellTargets(TargetFlags.destLocation);
    targets.dest = [at.x, at.y, at.z];
    targets.write(spell);
    client.write(Opcode.CMSG_CAST_SPELL, spell.data);
    assert(caster.values.get!UNIT_CHANNEL_SPELL == rain);
    ulong spot;
    foreach (object; from.objectsNear(at, 6))
        if (cast(DynamicObject) object !is null)
            spot = object.guid;
    assert(spot);

    const period = source.context.data.spells.spell(rain).casting.amplitude[0];
    assert(period > 1);
    client.session.update((period / 2).msecs);
    assert(client.session.inWorld.actAtReplica(target.guid, ArrivalAction.init));
    assert(relay.remote !is null && relay.remote.character.values.get!UNIT_CHANNEL_SPELL == rain);
    assert(from.findObject(spot) is null && cast(DynamicObject) to.findObject(spot) !is null);
    const health = target.values.get!UNIT_FIELD_HEALTH;
    relay.remote.update((period - period / 2 - 1).msecs);
    assert(target.values.get!UNIT_FIELD_HEALTH == health);
    relay.remote.update(1.msecs);
    assert(target.values.get!UNIT_FIELD_HEALTH < health);
    ByteWriter cancel;
    cancel.put(rain);
    client.write(Opcode.CMSG_CANCEL_CHANNELLING, cancel.data);
    const after = target.values.get!UNIT_FIELD_HEALTH;
    relay.remote.update(period.msecs);
    assert(target.values.get!UNIT_FIELD_HEALTH == after && to.findObject(spot) is null);
}

/// Smokey's compound runs its real script with the charge, focus, and fires on their owning nodes.
unittest
{
    import dmangos.cluster.protocol : ScriptGameObject;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.grid : cellCoordinate, cellKeyAt;
    import dmangos.world.objects : makeGuid, HighGuid;
    import dmangos.world.replication : encodeState;
    import dmangos.world.spellselection : namedCreatureRange, nearestNamedCreature;

    if (!haveRealData())
        return;

    auto database = newDatabase();
    WorldConfig conf;
    auto source = new WorldContext(conf, database, realWorldData, realClient);
    auto owner = new WorldContext(conf, database, realWorldData, realClient);
    auto relay = new TestPlayerRelay(source, owner);
    enum uint compound = 15736, charge = 177672;
    const origin = Position(2798.5f, -3759.5f, 126.2f, 0);
    const targetCell = cellKeyAt(2803.14f, -3759.45f);
    const fence = cellCoordinate(2803.14f);
    auto ownerOf = (uint, Position at, float) => cellCoordinate(at.x) >= fence ? ushort(2) : ushort(1);
    source.ownsCell = (uint, ulong key) => cast(int)(key >> 32) < fence;
    owner.ownsCell = (uint, ulong key) => cast(int)(key >> 32) >= fence;
    source.regionOwnerAround = owner.regionOwnerAround = ownerOf;
    auto from = source.map(0), to = owner.map(0);
    to.loadCell(targetCell);
    const focusGuid = makeGuid(HighGuid.gameObject, 177668, 45697);
    const nearFire = makeGuid(HighGuid.gameObject, 177669, 573684);
    const farFire = makeGuid(HighGuid.gameObject, 177670, 573693);
    const targetGuid = makeGuid(HighGuid.unit, 12247, 54271);
    auto focus = to.gameObjectAt(focusGuid);
    auto target = to.creatureAt(targetGuid);
    assert(focus !is null && target !is null, "the real Classic-DB structure and focus");
    from.replicaCreated(2, targetCell, focus.guid, encodeState(focus, 0));
    from.replicaCreated(2, targetCell, target.guid, encodeState(target, 0));
    ScriptGameObject[] commands;
    owner.sendScriptGameObject = (ushort peer, const ref ScriptGameObject request) {
        assert(peer == 1);
        commands ~= request;
        source.scriptGameObjectArrived(2, request);
        return true;
    };

    auto client = loggedIn(source, database, 7, "Anduin", origin, AccountLevel.player, raceHuman, 0, 60);
    client.session.inWorld.storeLoot(compound, 1, 0, false);
    client.read();
    const player = client.session.character;
    const spell = source.spellInfo(19250);
    const entries = source.spellScriptTargets(spell.id, 0);
    assert(entries == [12247]);
    assert(source.spellScriptTargets(spell.id, 2).length == 0);
    const range = namedCreatureRange(*spell, source.client);
    const nearest = nearestNamedCreature(from, player.position, range, entries, 0, true);
    assert(nearest.replica !is null && nearest.combatGuid == targetGuid && nearest.replica.owner == 2,
        "the caster must see the remote structure");
    auto item = player.inventory[inventorySlotBag0, backpackSlot(cast(Player) player, compound)];
    assert(item !is null);
    database.loadable[7].items = [database.itemRows[item.guid]];
    ByteWriter use;
    use.put(item.bagSlot);
    use.put(item.slot);
    use.put(ubyte(1));
    SpellTargets(TargetFlags.self).write(use);
    client.write(Opcode.CMSG_USE_ITEM, use.data);
    assert(relay.remote !is null && !source.runningScripts && !owner.runningScripts,
        "the item must move to the original target before casting");
    relay.remote.update(50.msecs);
    relay.remote.update(10.seconds);
    assert(owner.runningScripts == 1 && !source.runningScripts);
    assert(commands.length == 1 && commands[0].action == ScriptGameObject.Action.summon && commands[0].entry == charge);
    assert(!from.gameObjectAt(nearFire) && !from.gameObjectAt(farFire) && !to.gameObjectAt(nearFire));
    owner.updateScripts(0);
    assert(to.gameObjectAt(focusGuid) is null, "the real script despawns the original focus");
    owner.updateScripts(1000);
    assert(to.gameObjectAt(nearFire) !is null && from.gameObjectAt(farFire) !is null);
    assert(commands.length == 2 && commands[$ - 1].action == ScriptGameObject.Action.respawn
        && commands[$ - 1].target == farFire);
}

/// The Ahn'Qiraj gate event closes its exact door even if the script starts on another node.
unittest
{
    import dmangos.cluster.protocol : ScriptGameObject;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.dbscripts : DbScriptType;
    import dmangos.world.gameobject : goStateActive, goStateReady;
    import dmangos.world.grid : cellKeyAt, cellSize;
    import dmangos.world.objects : makeGuid, HighGuid;
    import std.algorithm.searching : find;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    source.context.nodeId = 1;
    owner.context.nodeId = 2;
    enum uint spawn = 66334, entry = 176146, closeGate = 9425, zoneMap = 1;
    const rows = source.context.data.gameObjectSpawns.find!(row => row.guid == spawn);
    assert(rows.length && rows[0].entry == entry && rows[0].map == zoneMap);
    const at = Position(rows[0].x, rows[0].y, rows[0].z, rows[0].orientation);
    const cell = cellKeyAt(at.x, at.y);
    source.context.ownsCell = (uint, ulong key) => key != cell;
    owner.context.ownsCell = (uint, ulong key) => key == cell;
    source.context.regionOwnerAround = owner.context.regionOwnerAround =
        (uint, Position pos, float) => cellKeyAt(pos.x, pos.y) == cell ? ushort(2) : ushort(1);
    auto from = source.context.map(zoneMap), to = owner.context.map(zoneMap);
    const guid = makeGuid(HighGuid.gameObject, entry, spawn);
    to.loadCell(cell);
    auto gate = to.gameObjectAt(guid);
    if (gate is null)
    {
        gate = owner.context.makeGameObject(rows[0]);
        to.addObject(gate);
    }
    gate.setDoorOpen(true);
    const actorAt = Position(at.x + 2 * cellSize, at.y, at.z);
    auto actor = source.context.summonCreature(from, 6, actorAt, TempSpawnType.manual, 0, 0);
    uint commands;
    source.context.sendScriptGameObject = (ushort peer, const ref ScriptGameObject request) {
        assert(peer == 2 && request.target == guid && request.action == ScriptGameObject.Action.close
            && request.delay == 76);
        ++commands;
        owner.context.scriptGameObjectArrived(1, request);
        owner.context.scriptGameObjectArrived(1, request);
        return true;
    };

    assert(source.context.startScript(DbScriptType.event, closeGate, from, actor.guid, 0));
    source.context.updateScripts(1_999);
    assert(gate.goState == goStateActive && commands == 0);
    source.context.updateScripts(1);
    assert(gate.goState == goStateReady && commands == 1 && from.gameObjectAt(guid) is null);
    gate.tick(to, 75_999);
    assert(gate.goState == goStateReady);
    gate.tick(to, 1);
    assert(gate.goState == goStateActive);
}

/// Highlord Demitrian's actual quest step summons Thunderaan at his distant spawn point.
unittest
{
    import std.algorithm.comparison : max;
    import std.algorithm.searching : find;
    import dmangos.cluster.protocol : ScriptCreatureStep;
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.dbscripts : DbScriptType, ScriptCommand;
    import dmangos.world.grid : cellCoordinate, cellKeyAt;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    if (!haveRealData())
        return;

    enum uint quest = 7786, demitrian = 14347, spawn = 42744, thunderaan = 14435, kalimdor = 1;
    auto source = RealWorld.make(), owner = RealWorld.make(), next = RealWorld.make();
    source.context.nodeId = 1;
    owner.context.nodeId = 2;
    next.context.nodeId = 3;
    const frozen = MonoTime.currTime;
    source.context.clock = owner.context.clock = next.context.clock = () => frozen;
    const rows = source.context.data.creatureSpawns.find!(row => row.guid == spawn);
    assert(rows.length && rows[0].entry == demitrian && rows[0].map == kalimdor);
    const step = source.context.data.dbScripts.steps(DbScriptType.questEnd, quest)[0];
    assert(step.command == ScriptCommand.tempSpawnCreature && step.datalong == thunderaan && step.datalong2 == 180_000);
    const at = Position(step.x, step.y, step.z, step.o);
    const home = cellKeyAt(rows[0].x, rows[0].y), cell = cellKeyAt(at.x, at.y);
    assert(home != cell);
    ushort destination = 2;
    source.context.regionOwnerAround = owner.context.regionOwnerAround =
        (uint, Position pos, float) => cellKeyAt(pos.x, pos.y) == cell ? destination : ushort(1);
    source.context.ownsCell = (uint, ulong key) => key != cell;
    owner.context.ownsCell = (uint, ulong key) => destination == 2 && key == cell;
    next.context.ownsCell = (uint, ulong key) => destination == 3 && key == cell;
    auto from = source.context.map(kalimdor);
    from.loadCell(home);
    const speaker = makeGuid(HighGuid.unit, demitrian, spawn);
    assert(from.creatureAt(speaker) !is null);
    ScriptCreatureStep sent;
    source.context.sendScriptCreatureStep = (ushort peer, const ref ScriptCreatureStep request) {
        assert(peer == 2 && request.source == speaker && !sent.sequence);
        sent = request;
        owner.context.scriptCreatureStepArrived(1, request);
        owner.context.scriptCreatureStepArrived(1, request);
        return true;
    };

    assert(source.context.startScript(DbScriptType.questEnd, quest, from, speaker, 0));
    source.context.updateScripts(0);
    auto to = owner.context.map(kalimdor);
    assert(sent.sequence && !from.creaturesNear(at, 1).length);
    auto summons = to.creaturesNear(at, 1);
    assert(summons.length == 1);
    auto boss = summons[0];
    assert(boss.spawn.entry == thunderaan && boss.summon.summoner == speaker && boss.summon.timer == 180_000);
    boss.tick(to, 50_000);
    assert(boss.summon.timer == 130_000);
    const guid = boss.guid;

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(42, kalimdor, CellRect(x, y, x + 1, y + 1), 2, 5, RegionState.revoking, 3);
    ubyte[][uint] leaving, unused;
    owner.context.recovery.regionsChanged(null, [region], null, leaving);
    destination = 3;
    region.owner = destination;
    region.state = RegionState.granted;
    region.next = 0;
    next.context.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto current = next.context.map(kalimdor);
    auto resumed = current.creatureAt(guid);
    assert(to.creatureAt(guid) is null && resumed !is null);
    const transit = max(0, cast(int)(next.context.fleet.transportNow() - owner.context.fleet.transportNow()));
    assert(resumed.summon.timer == 130_000 - transit);
    assert(current.creaturesNear(at, 1).length == 1, "the same temporary boss keeps its remaining lifetime");

    next.context.config.cluster.nodeId = 3;
    auto witness = loggedIn(next.context, next.db, 7, "Anduin", at, AccountLevel.player, raceHuman, kalimdor, 60,
        (ref c) { c.rewardedQuests[quest] = true; });
    resumed.values.set!UNIT_FIELD_HEALTH(0u);
    witness.session.inWorld.killedCreature(resumed);
    assert(resumed.loot !is null && resumed.loot.items.length == 1 && resumed.loot.items[0].itemId == 19018);
    const gold = resumed.loot.gold;

    auto replacement = RealWorld.make();
    replacement.context.config.cluster.nodeId = 4;
    replacement.context.database = next.db;
    replacement.context.clock = () => frozen;
    region.owner = 4;
    replacement.context.recovery.regionsChanged([region], null, null, unused);
    auto fresh = replacement.context.map(kalimdor);
    auto corpse = fresh.creatureAt(guid);
    assert(corpse !is null && !corpse.alive && corpse.loot.gold == gold);
    assert(corpse.loot.items[0].itemId == 19018 && corpse.loot.items[0].allowed[7]);
    assert(fresh.creaturesNear(at, 1).length == 1, "the same defeated Thunderaan and his loot survived");
}

/// The Binding sends each acolyte the real ritual steps that affect it.
unittest
{
    import dmangos.bytes : ByteReader;
    import dmangos.cluster.protocol : ScriptCreatureStep;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.dbscripts : DbScriptType;
    import dmangos.world.dynobject : DynamicObject;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.replication : encodeState;
    import dmangos.world.updatefields : DYNAMICOBJECT_CASTER, DYNAMICOBJECT_SPELLID, UNIT_NPC_FLAGS;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    source.context.nodeId = 1;
    owner.context.nodeId = 2;
    auto observer = owner.character(8, "Anduin", 1, 60, []);
    const at = observer.session.character.position;
    auto from = source.context.map(0), to = owner.context.map(0);
    auto warlock = source.context.summonCreature(from, 6251, at, TempSpawnType.manual, 0, 0);
    auto magaz = source.context.summonCreature(from, 6252, at, TempSpawnType.manual, 0, 0);
    auto wytula = owner.context.summonCreature(to, 6254, at, TempSpawnType.manual, 0, 0);
    const cell = cellKeyAt(at.x, at.y);
    from.replicaCreated(2, cell, wytula.guid, encodeState(wytula, 0));
    to.replicaCreated(1, cell, warlock.guid, encodeState(warlock, 0));
    assert(magaz.values.get!UNIT_NPC_FLAGS & 2 && wytula.values.get!UNIT_NPC_FLAGS & 2);
    observer.read();

    ScriptCreatureStep[] routed;
    source.context.sendScriptCreatureStep = (ushort peer, const ref ScriptCreatureStep message) {
        assert(peer == 2 && message.actor == wytula.guid && message.script == 1428);
        routed ~= message;
        owner.context.scriptCreatureStepArrived(1, message);
        owner.context.scriptCreatureStepArrived(1, message);
        return true;
    };
    assert(source.context.startScript(DbScriptType.event, 1428, from, warlock.guid, 0));
    source.context.updateScripts(2000);
    assert(routed.length == 2, "Wytula's flag removal and emote go to its owner");
    assert(!(magaz.values.get!UNIT_NPC_FLAGS & 2) && !(wytula.values.get!UNIT_NPC_FLAGS & 2));
    uint bows;
    foreach (packet; observer.read())
        if (packet.opcode == Opcode.SMSG_EMOTE)
        {
            auto event = ByteReader(packet.body_);
            if (event.read!uint == 2 && event.read!ulong == wytula.guid)
                ++bows;
        }
    assert(bows == 1, "a repeated delivery cannot replay the remote ritual emote");
    source.context.updateScripts(3000);
    assert(routed.length == 3, "the remote acolyte also runs its channel cast");
    bool visual;
    foreach (object; to.objectsNear(at, 10))
        if (auto area = cast(DynamicObject) object)
            if (area.values.get!DYNAMICOBJECT_SPELLID == 8675 && area.values.get!DYNAMICOBJECT_CASTER == wytula.guid)
                visual = true;
    assert(visual, "the real Warlock Channeling ground visual spawned on the acolyte's node");
}

/// A Cultist Engineer renews Buttress Channel on its original shard across the boundary.
unittest
{
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.eventai : castTriggered;
    import dmangos.world.grid : cellKeyAt, cellSize;
    import dmangos.world.replication : encodeState;
    import dmangos.world.spelldamage : namedVisualLifetimeMs;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    source.context.nodeId = 1;
    owner.context.nodeId = 2;
    auto from = source.context.map(0), to = owner.context.map(0);
    const here = Position(2 * cellSize - 2, 100, 40), there = Position(2 * cellSize + 2, 100, 40);
    const casterCell = cellKeyAt(here.x, here.y), targetCell = cellKeyAt(there.x, there.y);
    assert(casterCell != targetCell);

    enum uint buttress = 28078;
    auto shard = owner.context.summonCreature(to, 16172, there, TempSpawnType.manual, 0, 0);
    auto cultist = source.context.summonCreature(from, 16230, here, TempSpawnType.manual, 0, 0);
    from.replicaCreated(2, targetCell, shard.guid, encodeState(shard, 0));
    uint applications, renewals, interruptions;
    source.context.sendAreaDamage = (ushort peer, const ref AreaDamage effect) {
        assert(peer == 2 && effect.target == shard.guid && effect.channelled && effect.namedCreature);
        if (!effect.channelUpdate)
            ++applications;
        else if (effect.auraMs)
            ++renewals;
        else
            ++interruptions;
        to.replicaCreated(1, casterCell, cultist.guid, encodeState(cultist, 0));
        owner.context.areaDamageArrived(1, effect);
        return true;
    };

    cultist.ai.update(from, 50); // the real Cultist Engineer's Spawned script starts the channel
    assert(cultist.values.get!UNIT_CHANNEL_SPELL == buttress
        && cultist.values.get!UNIT_FIELD_CHANNEL_OBJECT == shard.guid);
    auto visual = shard.auras.find(buttress, cultist.guid);
    assert(visual !is null && visual.duration == namedVisualLifetimeMs && applications == 1);
    foreach (_; 0 .. 4)
    {
        shard.updateAuras(to, 1_000);
        cultist.ai.update(from, 1_000);
        assert(shard.auras.find(buttress, cultist.guid) is visual && visual.duration == namedVisualLifetimeMs);
    }
    assert(renewals >= 4 && applications == 1);
    cultist.ai.finishCreatureChannel(true);
    assert(interruptions == 1 && shard.auras.find(buttress, cultist.guid) is null);

    assert(cultist.ai.scriptCast(buttress, cultist.guid, castTriggered));
    assert(shard.auras.find(buttress, cultist.guid) !is null);
    shard.updateAuras(to, namedVisualLifetimeMs + 1); // the caster's worker stopped renewing
    assert(shard.auras.find(buttress, cultist.guid) is null);
}

/// A creature's existing ground effect follows its region and expires on the new owner.
unittest
{
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.dynobject : DynamicObject;
    import dmangos.world.grid : cellCoordinate, cellKeyAt;
    import dmangos.world.spellcast : castTime;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_LEVEL, UNIT_FIELD_MAXHEALTH, UNIT_FIELD_POWER1,
        UNIT_FIELD_MAXPOWER1;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    source.context.nodeId = 1;
    owner.context.nodeId = 2;
    const at = Position(-8950, -132, 83.53f);
    auto from = source.context.map(0), to = owner.context.map(0);
    auto caster = source.context.summonCreature(from, 1835, at, TempSpawnType.manual, 0, 0);
    caster.ai.bind(from);
    const targets = SpellTargets.init;
    caster.ai.makePersistentArea(source.context.spellInfo(5740), 0, targets, 25);
    const heal = source.context.spellInfo(5187);
    const castMs = castTime(*heal, source.context.client, caster.values.get!UNIT_FIELD_LEVEL);
    caster.values.set!UNIT_FIELD_MAXHEALTH(1000u);
    caster.values.set!UNIT_FIELD_HEALTH(10u);
    caster.values.set!UNIT_FIELD_POWER1(caster.values.get!UNIT_FIELD_MAXPOWER1);
    assert(castMs > 500 && caster.ai.castSpell(heal, caster.guid, 0) && caster.ai.castingNow);
    caster.tick(from, 500);
    ulong spot;
    foreach (object; from.objectsNear(at, 4))
        if (cast(DynamicObject) object !is null)
            spot = object.guid;
    assert(spot);

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    const region = Region(7, 0, CellRect(x, y, x + 1, y + 1), 2, 1, RegionState.granted);
    const home = cellKeyAt(at.x, at.y);
    const bundle = from.migrateOut(cell => cell == home, 2, &source.context.saveMigrant);
    ubyte[][uint] unused;
    owner.context.recovery.regionsChanged([region], null, [region.id: bundle], unused);
    assert(from.findObject(spot) is null && cast(DynamicObject) to.findObject(spot) !is null);
    auto moved = to.creatureAt(caster.guid);
    assert(moved !is null);
    assert(moved.ai.castingNow && moved.values.get!UNIT_FIELD_HEALTH == 10);
    moved.tick(to, castMs - 501);
    assert(moved.ai.castingNow && moved.values.get!UNIT_FIELD_HEALTH == 10);
    moved.tick(to, 1);
    assert(!moved.ai.castingNow && moved.values.get!UNIT_FIELD_HEALTH > 10);
    moved.tick(to, 30_000);
    assert(to.findObject(spot) is null);
}

/// A player's pending cast completes once on the destination, using the time already spent casting.
unittest
{
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.replication : encodeState;
    import dmangos.world.spellcast : castTime;
    import dmangos.world.updatefields : UNIT_FIELD_POWER1;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    owner.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, owner.context);
    enum uint conjure = 5504, water = 5350, level = 30;
    auto client = source.character(7, "Jaina", classMageId, level, [conjure]);
    auto player = cast(Player) client.session.character;
    source.db.loadable[7].power[0] = player.values.get!UNIT_FIELD_POWER1;
    auto from = source.context.map(0), to = owner.context.map(0);
    const at = player.position;
    auto nearby = owner.context.summonCreature(to, 1835, at, TempSpawnType.manual, 0, 0);
    from.replicaCreated(2, cellKeyAt(at.x, at.y), nearby.guid, encodeState(nearby, 0));

    ByteWriter cast_;
    cast_.put(conjure);
    SpellTargets.init.write(cast_);
    client.write(Opcode.CMSG_CAST_SPELL, cast_.data);
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_SPELL_START));
    const ms = castTime(*source.context.spellInfo(conjure), source.context.client, level);
    assert(ms > 500 && player.inventory.count(water) == 0);
    client.session.update(500.msecs);
    assert(client.session.inWorld.actAtReplica(nearby.guid, ArrivalAction.init));
    auto moved = cast(Player) relay.remote.character;
    relay.remote.update((ms - 501).msecs);
    assert(moved.inventory.count(water) == 0);
    relay.remote.update(1.msecs);
    const conjured = moved.inventory.count(water);
    assert(conjured && opcodesOf(client.read()).canFind(Opcode.SMSG_SPELL_GO));
    relay.remote.update(5.seconds);
    assert(moved.inventory.count(water) == conjured);
}

/// Eagle Eye keeps the original spot and remote visibility when the hunter changes nodes.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.dynobject : DynamicObject;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.replication : encodeState;
    import dmangos.world.updatefields : PLAYER_FARSIGHT, UNIT_CHANNEL_SPELL;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make(), land = RealWorld.make();
    owner.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, owner.context);
    enum uint eyeSpell = 6197;
    auto client = source.character(7, "Ranger", 3, 60, [eyeSpell], raceOrc);
    auto caster = client.session.inWorld;
    const body = caster.player.position, lens = Position(body.x + 450, body.y, body.z);
    const originCell = cellKeyAt(body.x, body.y), eyeCell = cellKeyAt(lens.x, lens.y);
    auto from = source.context.map(0), to = owner.context.map(0);
    auto near = owner.context.summonCreature(to, 6, body, TempSpawnType.manual, 0, 0);
    auto far = land.context.summonCreature(land.context.map(0), 1835, lens, TempSpawnType.manual, 0, 0);
    from.replicaCreated(2, originCell, near.guid, encodeState(near, 0));

    ByteWriter cast_;
    cast_.put(eyeSpell);
    auto targets = SpellTargets(TargetFlags.destLocation);
    targets.dest = [lens.x, lens.y, lens.z];
    targets.write(cast_);
    client.write(Opcode.CMSG_CAST_SPELL, cast_.data);
    const eye = caster.player.values.get!PLAYER_FARSIGHT;
    assert(eye && caster.player.values.get!UNIT_CHANNEL_SPELL == eyeSpell);
    assert(from.interestCells.canFind(originCell) && from.interestCells.canFind(eyeCell));
    assert(caster.actAtReplica(near.guid, ArrivalAction.init));
    assert(relay.remote !is null && from.findObject(eye) is null);
    auto moved = relay.remote.inWorld;
    assert(moved.player.values.get!PLAYER_FARSIGHT == eye && moved.player.values.get!UNIT_CHANNEL_SPELL == eyeSpell);
    auto spot = cast(DynamicObject) to.findObject(eye);
    assert(spot !is null && spot.position == lens);
    assert(to.interestCells.canFind(originCell) && to.interestCells.canFind(eyeCell));
    to.replicaCreated(3, eyeCell, far.guid, encodeState(far, 0));
    to.update(1.seconds);
    assert(to.seesObject(moved.player.guid, far.guid), "the new owner shows objects at the camera");

    ByteWriter cancel;
    cancel.put(eyeSpell);
    client.write(Opcode.CMSG_CANCEL_CHANNELLING, cancel.data);
    assert(!moved.player.values.get!PLAYER_FARSIGHT && to.findObject(eye) is null);
    assert(to.interestCells.canFind(originCell) && !to.interestCells.canFind(eyeCell));
}

/// Rank two of Mind Vision finds a player beyond normal replica distance without spending mana on a refusal.
unittest
{
    import std.format : format;
    import dmangos.cluster.protocol : MindVisionTarget, PresenceEntry;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.updatefields : PLAYER_FARSIGHT, UNIT_CHANNEL_SPELL, UNIT_FIELD_POWER1;

    if (!haveRealData())
        return;

    enum uint shortSight = 2096, longSight = 10909;
    auto source = RealWorld.make(), owner = RealWorld.make();
    auto watcher = source.character(7, "Priest", 5, 60, [shortSight, longSight]);
    auto observed = owner.character(8, "Scout", 1, 60, []);
    auto caster = watcher.session.inWorld, target = observed.session.inWorld;
    const body = caster.player.position;
    target.player.movement.position.x = body.x + 400;
    target.player.movement.position.y = body.y;
    target.player.movement.position.z = body.z;
    auto from = source.context.map(0), to = owner.context.map(0);
    to.relocated(target);
    owner.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, owner.context);
    source.context.presence(2, true, [PresenceEntry(8, "Scout")], null);
    assert(from.findObject(8) is null);
    const mana = caster.player.values.get!UNIT_FIELD_POWER1;
    source.db.loadable[7].power[0] = mana;
    foreach (spell; [shortSight, longSight])
        source.db.loadable[7].spells ~= NewSpell(spell, true, false);

    MindVisionTarget request;
    uint queries;
    source.context.sendMindVisionTarget = (ushort peer, const ref MindVisionTarget message) {
        assert(peer == 2 && message.target == 8 && !message.reply && !message.state.length);
        request = MindVisionTarget(message.caster, message.target, message.sequence, message.map, message.instance);
        ++queries;
        return true;
    };
    owner.context.sendMindVisionTarget = (ushort peer, const ref MindVisionTarget message) {
        assert(peer == 1 && message.reply && message.state.length);
        source.context.mindVisionTargetArrived(3, message); // another peer cannot answer it
        source.context.mindVisionTargetArrived(2, message);
        source.context.mindVisionTargetArrived(2, message);
        return true;
    };
    void castSight(uint id)
    {
        ByteWriter cast_;
        cast_.put(id);
        SpellTargets(TargetFlags.unit, 8).write(cast_);
        watcher.write(Opcode.CMSG_CAST_SPELL, cast_.data);
    }

    castSight(shortSight);
    assert(queries == 1 && relay.remote is null);
    owner.context.mindVisionTargetArrived(1, request);
    assert(relay.remote is null && caster.player.values.get!UNIT_FIELD_POWER1 == mana);
    assert(!caster.player.values.get!PLAYER_FARSIGHT);
    castSight(longSight);
    ByteWriter cancel;
    cancel.put(longSight);
    watcher.write(Opcode.CMSG_CANCEL_CAST, cancel.data);
    owner.context.mindVisionTargetArrived(1, request);
    assert(queries == 2 && relay.remote is null && caster.player.values.get!UNIT_FIELD_POWER1 == mana);

    castSight(longSight);
    owner.context.mindVisionTargetArrived(1, request);
    assert(queries == 3 && relay.remote !is null);
    relay.remote.update(1.msecs);
    auto moved = relay.remote.inWorld;
    assert(moved.player.position == body, format!"the caster's body moved from %s to %s"(body, moved.player.position));
    const eye = moved.player.values.get!PLAYER_FARSIGHT;
    assert(eye == 8, format!"camera %s, channel %s, spells %s"(eye,
        moved.player.values.get!UNIT_CHANNEL_SPELL, moved.player.spells));
    assert(moved.player.values.get!UNIT_CHANNEL_SPELL == longSight && moved.player.values.get!UNIT_FIELD_POWER1 < mana);
    assert(to.interestCells.canFind(cellKeyAt(target.player.position.x, target.player.position.y)));
}

/// Windfury Totem imbues a remote subgroup member's weapon and respects its existing enchantment.
unittest
{
    import dmangos.cluster.protocol : GroupMemberState, GroupState, TotemWeaponEnchant;
    import dmangos.world.defines : equipmentSlotMainhand, inventorySlotBag0;
    import dmangos.world.enchantments : EnchantmentSlot;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : GroupType;
    import dmangos.world.replication : encodePlayerState, encodeState;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    source.context.nodeId = 1;
    owner.context.nodeId = 2;
    auto shaman = source.character(7, "Thrall", 7, 60, [], raceOrc);
    auto warrior = owner.character(8, "Garrosh", 1, 60, [], raceOrc);
    auto caster = shaman.session.inWorld, ally = warrior.session.inWorld;
    auto from = source.context.map(0), to = owner.context.map(0);
    const at = caster.player.position, cell = cellKeyAt(at.x, at.y);
    from.replicaCreated(2, cell, ally.player.guid, encodePlayerState(ally.player, 0));

    enum uint windfury = 8512, related = 1783, flametongue = 124, axe = 37;
    ally.storeLoot(axe, 1, 0, false);
    warrior.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, backpackSlot(ally.player, axe)));
    auto weapon = ally.player.inventory.equipped(equipmentSlotMainhand);
    assert(weapon !is null && weapon.entry == axe);
    auto group = GroupState(id: 6, groupType: GroupType.raid, leader: 7, leaderName: "Thrall",
        members: [GroupMemberState(7, "Thrall"), GroupMemberState(8, "Garrosh")]);
    source.context.groups.mirror(group);
    group.members[1].subGroup = 1;
    owner.context.groups.mirror(group);

    caster.castTriggeredAt(windfury, caster.player.guid);
    assert(caster.ownTotems().length == 1);
    auto totem = caster.ownTotems()[0];
    uint pulses;
    source.context.sendTotemWeaponEnchant = (ushort peer, const ref TotemWeaponEnchant pulse) {
        assert(peer == 2 && pulse.totem == totem.guid && pulse.controller == 7 && pulse.target == 8);
        ++pulses;
        to.replicaCreated(1, cellKeyAt(totem.position.x, totem.position.y), totem.guid, encodeState(totem, 0));
        owner.context.totemWeaponEnchantArrived(1, pulse);
        owner.context.totemWeaponEnchantArrived(1, pulse);
        return true;
    };
    caster.updateTotemEnchants();
    assert(pulses == 1 && !weapon.enchantment(EnchantmentSlot.temporary), "a different subgroup is rejected");

    group.members[1].subGroup = 0;
    owner.context.groups.mirror(group);
    ally.enchantItem(weapon.fullGuid, flametongue, true, 15);
    source.now += 5.seconds;
    owner.now += 5.seconds;
    caster.updateTotemEnchants();
    assert(pulses == 2 && weapon.enchantment(EnchantmentSlot.temporary) == flametongue);
    ally.setEnchantment(weapon, EnchantmentSlot.temporary, 0, 0);

    source.now += 5.seconds;
    owner.now += 5.seconds;
    caster.updateTotemEnchants();
    assert(pulses == 3 && weapon.enchantment(EnchantmentSlot.temporary) == related);
    ally.player.movement.position.x += 80; // The sender still sees the old position.
    source.now += 5.seconds;
    owner.now += 5.seconds;
    ally.updateEnchantments(5.seconds);
    caster.updateTotemEnchants();
    assert(pulses == 4);
    ally.updateEnchantments(5.seconds);
    assert(!weapon.enchantment(EnchantmentSlot.temporary), "an out-of-range pulse cannot renew Windfury");
}

/// A totem and guardian retain their GUIDs, lifetime and controller in the player's handoff.
unittest
{
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.replication : encodeState;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    owner.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, owner.context);
    enum uint stoneskin = 8071, dragonling = 4073;
    auto client = source.character(7, "Thrall", 7, 60, [], raceOrc);
    auto caster = client.session.inWorld;
    const at = caster.player.position;
    auto from = source.context.map(0), to = owner.context.map(0);
    caster.castTriggeredAt(stoneskin, caster.player.guid);
    caster.castTriggeredAt(dragonling, caster.player.guid);
    assert(caster.ownTotems().length == 1 && caster.ownGuardians().length == 1);
    auto totem = caster.ownTotems()[0], guardian = caster.ownGuardians()[0];
    const totemGuid = totem.guid, guardianGuid = guardian.guid;
    const totemSpell = totem.totemSpell;
    const position = totem.position;
    enum uint health = 25;
    guardian.values.set!UNIT_FIELD_MAXHEALTH(100);
    guardian.values.set!UNIT_FIELD_HEALTH(health);
    totem.summon.timer = 4_000;
    guardian.summon.timer = 2_000;
    auto actor = owner.context.summonCreature(to, 6, at, TempSpawnType.manual, 0, 0);
    from.replicaCreated(2, cellKeyAt(at.x, at.y), actor.guid, encodeState(actor, 0));

    assert(caster.actAtReplica(actor.guid, ArrivalAction.init));
    assert(relay.remote !is null && !from.creatureAt(totemGuid) && !from.creatureAt(guardianGuid));
    auto moved = relay.remote.inWorld;
    assert(moved.ownTotems().length == 1, "the totem is still in its slot");
    assert(moved.ownGuardians().length == 1, "the guardian is still owned and alive");
    auto nextTotem = moved.ownTotems()[0], nextGuardian = moved.ownGuardians()[0];
    assert(nextTotem.guid == totemGuid && nextTotem.position == position && nextTotem.totemOwner == 7);
    assert(nextTotem.totemSpell == totemSpell && nextTotem.auras.find(totemSpell, totemGuid) !is null);
    assert(nextGuardian.guid == guardianGuid && nextGuardian.guardianOwner == 7
        && nextGuardian.values.get!UNIT_FIELD_HEALTH == health);
    nextGuardian.tick(to, 2_010);
    assert(to.creatureAt(guardianGuid) is null && to.creatureAt(totemGuid) is nextTotem);
    nextTotem.tick(to, 4_010);
    assert(to.creatureAt(totemGuid) is null, "the old lifetime decides when both summons disappear");
}

/// The player keeps the active channel and its next missile when both actors change owners.
unittest
{
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.auras : AuraType;
    import dmangos.world.grid : cellCoordinate, cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), owner = RealWorld.make();
    owner.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, owner.context);
    enum uint missiles = 5143;
    auto client = source.character(7, "Jaina", classMageId, 60, [missiles]);
    auto caster = client.session.inWorld;
    caster.player.movement.position.orientation = 0;
    auto from = source.context.map(0), to = owner.context.map(0);
    const guid = source.enemy(client);
    auto target = from.creatureAt(guid);
    target.values.set!UNIT_FIELD_MAXHEALTH(1000u);
    target.values.set!UNIT_FIELD_HEALTH(1000u);
    assert(source.castAt(client, missiles, guid) == SpellCastResult.ok);
    auto aura = caster.player.auras.find(missiles);
    assert(aura !is null && caster.player.values.get!UNIT_CHANNEL_SPELL == missiles);
    size_t pulse;
    while (pulse < aura.period.length && aura.type(pulse) != AuraType.periodicTriggerSpell)
        ++pulse;
    assert(pulse < aura.period.length && aura.periodTimer[pulse] > 1);
    const child = source.context.spellInfo(aura.spell.triggerSpell[pulse]);
    client.session.update((aura.periodTimer[pulse] / 2).msecs);
    const remaining = aura.periodTimer[pulse];
    assert(remaining > 1);

    const at = target.position;
    const x = cellCoordinate(at.x), y = cellCoordinate(at.y), home = cellKeyAt(at.x, at.y);
    const region = Region(11, 0, CellRect(x, y, x + 1, y + 1), 2, 1, RegionState.granted);
    const state = from.migrateOut(cell => cell == home, 2, &source.context.saveMigrant);
    ubyte[][uint] unused;
    owner.context.recovery.regionsChanged([region], null, [region.id: state], unused);
    assert(caster.actAtReplica(guid, ArrivalAction.init));
    assert(relay.remote !is null && relay.remote.inWorld.player.values.get!UNIT_CHANNEL_SPELL == missiles);
    auto moved = relay.remote.inWorld.player.auras.find(missiles);
    assert(moved !is null && moved.periodTimer[pulse] == remaining);
    relay.remote.update((remaining - 1).msecs);
    assert(!relay.remote.inWorld.missileOnTheWay(child, guid));
    relay.remote.update(1.msecs);
    assert(relay.remote.inWorld.missileOnTheWay(child, guid));

    ByteWriter cancel;
    cancel.put(missiles);
    client.write(Opcode.CMSG_CANCEL_CHANNELLING, cancel.data);
    relay.remote.update(1.seconds);
    auto receiver = to.creatureAt(guid);
    const after = receiver.values.get!UNIT_FIELD_HEALTH;
    assert(after < 1000 && relay.remote.inWorld.player.values.get!UNIT_CHANNEL_SPELL == 0);
    relay.remote.update(5.seconds);
    assert(receiver.values.get!UNIT_FIELD_HEALTH == after);
}

/// A missile already launched at a replica follows the player when it becomes local to the caster.
unittest
{
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.grid : cellKeyAt, cellSize;
    import dmangos.world.replication : encodePlayerState;

    if (!haveRealData())
        return;

    foreach (arrivalDelay; [0.msecs, 300.msecs, 2500.msecs])
    {
        auto source = RealWorld.make(), home = RealWorld.make();
        source.context.database = home.db;
        source.context.clock = () => source.now;
        auto relay = new TestPlayerRelay(home.context, source.context);
        const origin = Position(2 * cellSize - 2, 100, 40), at = Position(2 * cellSize + 2, 100, 40);
        auto map = source.context.map(0);
        auto caster = source.context.summonCreature(map, 1835, origin, TempSpawnType.manual, 0, 0);
        enum uint guid = 116, channel = 15735, missile = 15736;
        auto client = loggedIn(home.context, home.db, guid, "Remotevictim", at, AccountLevel.player, raceHuman, 0, 38);
        auto player = client.session.character;
        map.replicaCreated(home.context.nodeId, cellKeyAt(at.x, at.y), guid, encodePlayerState(player, 0));
        caster.ai.setScript(null, source.context.data.eventAi);
        caster.ai.bind(map);
        source.context.sendAreaDamage = (ushort, const ref AreaDamage) {
            assert(false, "the missile must resolve at the player's new authority");
        };

        const health = client.session.inWorld.unit.health;
        assert(caster.ai.castSpell(source.context.data.spells.spell(channel), guid, 0));
        caster.tick(map, 1000);
        caster.ai.interruptedBySpell(3000);
        if (arrivalDelay > 0.msecs)
        {
            map.replicaRemoved(home.context.nodeId, guid);
            source.now += 300.msecs;
            source.context.update(source.now); // at impact time neither the player nor its replica is here
            source.now += arrivalDelay;
        }
        home.context.regionOwnerAround = (uint, Position, float) => source.context.nodeId;
        client.session.update(1.seconds);
        assert(!home.context.map(0).unit(guid) && map.unit(guid).health == health);
        source.now += 300.msecs;
        source.context.update(source.now);
        const after = map.unit(guid).health;
        const expired = arrivalDelay == 2500.msecs;
        assert(expired ? after == health : after < health, "only a pending missile should hit the migrated player");
        source.now += 3.seconds;
        source.context.update(source.now);
        assert(map.unit(guid).health == after);

        uint impacts;
        foreach (packet; client.read())
            if (packet.opcode == Opcode.SMSG_SPELLNONMELEEDAMAGELOG)
            {
                auto r = ByteReader(packet.body_);
                const target = r.readPackedGuid(), attacker = r.readPackedGuid();
                if (r.read!uint == missile)
                {
                    assert(target == guid && attacker == caster.guid && r.read!uint == health - after);
                    ++impacts;
                }
            }
        assert(impacts == (expired ? 0 : 1));
    }
}

/// A real Frostbolt fired at a local target survives clean caster and target handoffs.
unittest
{
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.classspells : CustomValues;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.grid : cellCoordinate, cellKeyAt;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;

    enum Handoff { both, target, redirected }
    foreach (path; [Handoff.both, Handoff.target, Handoff.redirected])
    {
        auto source = RealWorld.make(), owner = RealWorld.make();
        owner.context.database = source.db;
        auto relay = new TestPlayerRelay(source.context, owner.context);
        owner.context.clock = () => source.now;
        enum uint frostbolt = 116;
        auto client = source.character(7, "Jaina", classMageId, 60, [frostbolt]);
        auto caster = client.session.inWorld;
        caster.player.movement.position.orientation = 0;
        auto at = caster.player.position;
        at.x += 18;
        auto from = source.context.map(0), to = owner.context.map(0);
        auto target = source.context.summonCreature(from, 6, at, TempSpawnType.manual, 0, 0);
        const guid = target.guid;
        target.values.set!UNIT_FIELD_MAXHEALTH(1000u);
        target.values.set!UNIT_FIELD_HEALTH(1000u);
        const spell = source.context.spellInfo(frostbolt);
        const flight = cast(int)(18_000 / spell.casting.speed);
        const castResult = caster.castCustom(frostbolt, guid, CustomValues(alwaysHits: true));
        assert(flight > 100 && castResult == SpellCastResult.ok && caster.missileOnTheWay(spell, guid));
        client.session.update((flight / 2).msecs);

        const x = cellCoordinate(at.x), y = cellCoordinate(at.y), home = cellKeyAt(at.x, at.y);
        const region = Region(8, 0, CellRect(x, y, x + 1, y + 1), 2, 1, RegionState.granted);
        const bundle = from.migrateOut(cell => cell == home, 2, &source.context.saveMigrant);
        ubyte[][uint] unused;
        owner.context.recovery.regionsChanged([region], null, [region.id: bundle], unused);
        auto spellSession = client.session;
        auto receiver = to.creatureAt(guid);
        assert(receiver !is null && receiver.values.get!UNIT_FIELD_HEALTH == 1000);
        if (path == Handoff.both)
        {
            assert(caster.actAtReplica(guid, ArrivalAction.init));
            spellSession = relay.remote;
            assert(spellSession !is null && spellSession.inWorld.missileOnTheWay(spell, guid));
        }
        else
        {
            const origin = caster.player.position;
            to.replicaCreated(1, cellKeyAt(origin.x, origin.y), caster.player.guid, encodePlayerState(caster.player, 0));
            WorldContext formerOwner;
            if (path == Handoff.redirected)
            {
                formerOwner = RealWorld.make().context;
                formerOwner.nodeId = 3;
                const view = encodeState(receiver, 0);
                from.replicaCreated(3, home, guid, view);
                formerOwner.map(0).replicaCreated(2, home, guid, view);
                formerOwner.sendAreaDamage = (ushort peer, const ref AreaDamage reply) {
                    assert(peer == 1 && reply.reply && reply.redirectOwner == 2);
                    source.context.areaDamageArrived(3, reply);
                    return true;
                };
            }
            source.context.sendAreaDamage = (ushort peer, const ref AreaDamage hit) {
                assert(hit.playerProjectile && hit.target == guid);
                if (peer == 3 && formerOwner !is null)
                    formerOwner.areaDamageArrived(1, hit);
                else
                {
                    assert(peer == 2);
                    owner.context.areaDamageArrived(1, hit);
                }
                return true;
            };
        }
        spellSession.update((flight - flight / 2 - 25).msecs);
        assert(receiver.values.get!UNIT_FIELD_HEALTH == 1000);
        spellSession.update(50.msecs);
        const after = receiver.values.get!UNIT_FIELD_HEALTH;
        assert(after < 1000 && receiver.auras.find(frostbolt, 7) !is null);
        spellSession.update(2.seconds);
        assert(receiver.values.get!UNIT_FIELD_HEALTH == after, "the same projectile cannot land twice");
    }
}

/// The technician's unmodified EventAI row selects a wounded mechanical ally across a region boundary.
unittest
{
    import std.algorithm.searching : find;
    import std.format : format;
    import std.math : abs;
    import std.random : rndGen;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.grid : cellCoordinate, cellKeyAt, cellSize;
    import dmangos.world.map : Map;
    import dmangos.world.replication : encodePlayerState, encodeState, Replica, Replicator;
    import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X, UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT,
        UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;

    static final class CasterReplicas : Replicator
    {
        ushort owner;
        Map[ushort] peers;
        void create(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state)
        {
            peers[peer].replicaCreated(owner, cell, guid, state);
        }
        void values(ushort peer, uint map, ulong guid, const(ubyte)[] fields)
        {
            peers[peer].replicaValues(owner, guid, fields);
        }
        void move(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] packet, const(ubyte)[] motion) {}
        void remove(ushort peer, uint map, ulong guid) { peers[peer].replicaRemoved(owner, guid); }
        void inRange(ushort peer, uint map, Position where, float radius, ushort opcode, const(ubyte)[] packet) {}
    }

    enum uint supercharge = 10732, rebuild = 10345, technician = 6222, mechanoTank = 6225;
    enum uint woundedRule = 622205;
    const origin = Position(2 * cellSize - 2, 100, 40), at = Position(2 * cellSize + 2, 100, 40);
    const cell = cellKeyAt(at.x, at.y);
    assert(cell != cellKeyAt(origin.x, origin.y));

    foreach (testCase, expectedSpell; [supercharge, rebuild])
    {
        auto source = RealWorld.make(), owner = RealWorld.make(), successor = RealWorld.make();
        source.context.nodeId = 1;
        owner.context.nodeId = 2;
        successor.context.nodeId = 3;
        auto from = source.context.map(0), to = owner.context.map(0), destination = successor.context.map(0);
        auto wire = new CasterReplicas;
        wire.owner = 1;
        wire.peers[2] = to;
        wire.peers[3] = destination;
        from.replicator = wire;
        auto caster = source.context.summonCreature(from, technician, origin, TempSpawnType.manual, 0, 0);
        auto decoy = source.context.summonCreature(from, mechanoTank,
            Position(origin.x + 1, origin.y, origin.z), TempSpawnType.manual, 0, 0);
        auto target = owner.context.summonCreature(to, mechanoTank, at, TempSpawnType.manual, 0, 0);
        assert(caster !is null && decoy !is null && target !is null);
        auto data = source.context.data.eventAi;
        const rule = data.eventsOf(technician, caster.spawn.guid).find!(e => e.id == woundedRule);
        assert(rule.length, "the real wounded-ally rule is loaded");
        caster.ai.setScript(rule[0 .. 1], data);
        auto attacker = loggedIn(source.context, source.db, 110, "Engineer", origin);
        const attackerGuid = attacker.session.character.guid;
        caster.ai.attackedBy(from.unit(attackerGuid), from);
        caster.ai.scriptMelee(false);
        caster.ai.scriptCombatMovement(false);
        decoy.ai.attackedBy(from.unit(attackerGuid), from);
        target.values.set!UNIT_FIELD_MAXHEALTH(5000);
        target.values.set!UNIT_FIELD_HEALTH(5000);
        from.replicaCreated(2, cell, target.guid, encodeState(target, 0));

        uint applications, interruptions;
        WorldContext[ushort] targets = [cast(ushort) 2: owner.context, cast(ushort) 3: successor.context];
        source.context.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
            assert(request.namedCreature && request.channelled && request.target == target.guid);
            if (request.channelUpdate)
            {
                assert(peer == 3 && request.auraMs == 0);
                ++interruptions;
            }
            else
            {
                assert(peer == 2);
                ++applications;
            }
            targets[peer].areaDamageArrived(1, request);
            return true;
        };
        for (int elapsed; elapsed < 29_000; elapsed += 500)
            caster.ai.update(from, 500);
        assert(!applications, "the rule does not fire on a healthy replica");
        target.values.set!UNIT_FIELD_HEALTH(3000);
        from.replicaCreated(2, cell, target.guid, encodeState(target, 0));
        caster.ai.update(from, 500);
        assert(!applications, "the rule ignores a wounded replica outside combat");
        target.ai.remoteDamageTaken(attackerGuid, 1, 1.0f, to);
        from.replicaCreated(2, cell, target.guid, encodeState(target, 0));
        assert(caster.ai.inCombat && target.ai.inCombat, "the technician and the wounded tank are fighting");
        bool selected;
        assert(caster.ai.lowestHpFriendly(15, 1200, false, rule[0].actions, selected) == target.guid && selected,
            "both alternatives accept the wounded remote tank");

        // Both alternatives in the real random-action row run through EventAI.
        rndGen.seed(testCase == 0 ? 1 : 2);
        caster.ai.update(from, 500);
        assert(applications == 1 && caster.values.get!UNIT_CHANNEL_SPELL == expectedSpell,
            format!"expected %s, channeling %s, applications %s, cast result %s"(expectedSpell,
                caster.values.get!UNIT_CHANNEL_SPELL, applications, caster.ai.castRefusal));
        assert(caster.values.get!UNIT_FIELD_CHANNEL_OBJECT == target.guid, "a closer healthy tank is not selected");
        auto aura = target.auras.find(expectedSpell, caster.guid);
        assert(aura !is null && aura.channelToken && !decoy.auras.find(expectedSpell));
        const token = aura.channelToken;
        const scale = target.values.get!OBJECT_FIELD_SCALE_X;
        const period = aura.period[0];
        const beforeHandoff = period > 0 ? period / 2 : 500;
        if (expectedSpell == supercharge)
        {
            const spell = source.context.data.spells.spell(supercharge);
            assert(aura.effects == 0b111 && aura.amount == [caster.ai.effectAmount(spell, 0), 25, 25]);
            assert(abs(target.auras.attackTimeFactor(0) - 0.8f) < 0.001f);
        }
        else
            assert(period > 0 && aura.amount[0] > 0);
        target.updateAuras(to, beforeHandoff);
        caster.ai.update(from, beforeHandoff);
        const remaining = aura.duration;

        const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
        const gained = Region(7, 0, CellRect(x, y, x + 1, y + 1), 3, 2, RegionState.granted);
        const bundle = to.migrateOut(key => key == cell, 3, &owner.context.saveMigrant);
        ubyte[][uint] unused;
        successor.context.recovery.regionsChanged([gained], null, [gained.id: bundle], unused);
        auto migrated = destination.creatureAt(target.guid);
        assert(migrated !is null && to.creatureAt(target.guid) is null);
        auto movedAura = migrated.auras.find(expectedSpell, caster.guid);
        assert(movedAura !is null && movedAura.channelToken == token && movedAura.duration == remaining);
        assert(migrated.values.get!OBJECT_FIELD_SCALE_X == scale);

        from.replicaRemoved(2, target.guid);
        caster.ai.update(from, 50);
        assert(caster.values.get!UNIT_CHANNEL_SPELL == expectedSpell);
        from.replicaCreated(3, cell, target.guid, encodeState(migrated, 0));
        caster.ai.update(from, 50);
        assert(destination.isReplica(caster.guid), "the channel publishes its caster to the new owner");
        assert(applications == 1, "ownership change preserves the aura without applying it again");

        // The caster's region now moves too. The new caster owner has no observers around the tank yet.
        auto nextWire = new CasterReplicas;
        nextWire.owner = 2;
        nextWire.peers[3] = destination;
        to.replicator = nextWire;
        owner.context.sendAreaDamage = (ushort peer, const ref AreaDamage request) {
            assert(peer == 3 && request.channelUpdate && request.channelToken == token && request.auraMs == 0);
            ++interruptions;
            successor.context.areaDamageArrived(2, request);
            return true;
        };
        const casterCell = cellKeyAt(origin.x, origin.y);
        const casterX = cellCoordinate(origin.x), casterY = cellCoordinate(origin.y);
        const gainedCaster = Region(8, 0, CellRect(casterX, casterY, casterX + 1, casterY + 1), 2, 1, RegionState.granted);
        const casterBundle = from.migrateOut(key => key == casterCell, 2, &source.context.saveMigrant);
        owner.context.recovery.regionsChanged([gainedCaster], null, [gainedCaster.id: casterBundle], unused);
        auto movedCaster = to.creatureAt(caster.guid);
        assert(movedCaster !is null && from.creatureAt(caster.guid) is null);
        assert(movedCaster.ai.castingNow && movedCaster.values.get!UNIT_CHANNEL_SPELL == expectedSpell
            && movedCaster.values.get!UNIT_FIELD_CHANNEL_OBJECT == migrated.guid, "caster handoff preserves the active channel");
        auto remoteCaster = cast(Replica) destination.findObject(caster.guid);
        assert(remoteCaster !is null && remoteCaster.owner == 2, "the new caster owner pins its replica at the target");
        assert(migrated.auras.find(expectedSpell, caster.guid) is movedAura && movedAura.duration == remaining);
        if (period > 0)
        {
            migrated.updateAuras(destination, period - beforeHandoff - 1);
            assert(migrated.values.get!UNIT_FIELD_HEALTH == 3000, "the next tick waits for its original deadline");
            migrated.updateAuras(destination, 1);
            assert(migrated.values.get!UNIT_FIELD_HEALTH == 3000 + movedAura.amount[0]);
        }
        if (expectedSpell == supercharge)
        {
            // The original deadline is earlier than a newly started channel's deadline.
            movedCaster.ai.setScript(null, data);
            to.replicaCreated(3, cell, migrated.guid, encodeState(migrated, 0));
            to.replicaCreated(1, casterCell, attackerGuid, encodePlayerState(attacker.session.character, 0));
            movedCaster.ai.update(to, remaining / 2);
            assert(movedCaster.ai.castingNow);
            movedCaster.ai.update(to, remaining - remaining / 2);
            migrated.updateAuras(destination, remaining);
            assert(interruptions == 0);
        }
        else
        {
            movedCaster.ai.interruptCast();
            assert(interruptions == 1);
        }
        assert(!movedCaster.values.get!UNIT_CHANNEL_SPELL && !migrated.auras.find(expectedSpell, caster.guid));
        assert(migrated.auras.attackTimeFactor(0) == 1);
        if (expectedSpell == supercharge)
            assert(abs(migrated.values.get!OBJECT_FIELD_SCALE_X * 1.25f - scale) < 0.001f);
        const health = migrated.values.get!UNIT_FIELD_HEALTH;
        migrated.updateAuras(destination, 4000);
        assert(migrated.values.get!UNIT_FIELD_HEALTH == health, "interruption stops future healing");
    }
}

/// The Soulbound Keepsake triggers Ras's relay only after the caster completes Boon of Life.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.grid : cellCoordinate, cellKeyAt, cellSize;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT, UNIT_FIELD_FACTIONTEMPLATE;

    if (!haveRealData())
        return;

    enum uint keepsake = 13752, boon = 17179, ras = 10508;
    const origin = Position(2 * cellSize - 2, 100, 40), at = Position(2 * cellSize + 2, 100, 40);
    const cell = cellKeyAt(at.x, at.y), casterCell = cellKeyAt(origin.x, origin.y);
    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    const gained = Region(7, 0, CellRect(x, y, x + 1, y + 1), 3, 2, RegionState.granted);

    foreach (scenario; 0 .. 3)
    {
        const cancelled = scenario == 1, casterMoves = scenario == 2;
        auto source = RealWorld.make(), owner = RealWorld.make(), successor = RealWorld.make();
        source.context.nodeId = 1;
        owner.context.nodeId = casterMoves ? 3 : 2;
        successor.context.nodeId = casterMoves ? 2 : 3;
        source.context.clock = () => source.now;
        auto from = source.context.map(0), to = owner.context.map(0), destination = successor.context.map(0);
        auto hero = loggedIn(source.context, source.db, 112, "Keepsake", origin, AccountLevel.player, raceHuman, 0, 60);
        auto player = cast(Player) hero.session.character;
        hero.session.inWorld.storeLoot(keepsake, 1, 0, false);
        auto boss = owner.context.summonCreature(to, ras, at, TempSpawnType.manual, 0, 0);
        assert(boss !is null);
        from.replicaCreated(owner.context.nodeId, cell, boss.guid, encodeState(boss, 0));
        const oldFaction = boss.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        AreaDamage delivered;
        uint completions;
        source.context.sendAreaDamage = (ushort peer, const ref AreaDamage message) {
            auto world = peer == owner.context.nodeId ? owner.context : successor.context;
            world.map(0).replicaCreated(1, casterCell, player.guid, encodePlayerState(player, 0));
            if (message.channelUpdate && message.auraMs == AreaDamage.completedChannel)
            {
                ++completions;
                delivered = cast(AreaDamage) message;
            }
            world.areaDamageArrived(1, message);
            return true;
        };
        ByteWriter use;
        use.put(inventorySlotBag0);
        use.put(backpackSlot(player, keepsake));
        use.put(ubyte(1));
        SpellTargets(TargetFlags.unit, boss.guid).write(use);
        hero.write(Opcode.CMSG_USE_ITEM, use.data);
        assert(player.values.get!UNIT_CHANNEL_SPELL == boon && player.values.get!UNIT_FIELD_CHANNEL_OBJECT == boss.guid);
        auto aura = boss.auras.find(boon, player.guid);
        assert(aura !is null && aura.channelToken && aura.duration == 20_000);

        hero.session.update(19_999.msecs);
        boss.updateAuras(to, 19_999);
        assert(player.values.get!UNIT_CHANNEL_SPELL == boon && aura.duration == 1);
        if (!cancelled)
        {
            boss.updateAuras(to, 1);
            assert(!boss.auras.find(boon, player.guid), "the aura expires on the target's own clock");
        }
        assert(owner.context.runningScripts == 0, "the target's timer cannot start the relay");
        if (casterMoves)
        {
            successor.context.database = source.db;
            successor.context.clock = () => source.now;
            auto relay = new TestPlayerRelay(source.context, successor.context);
            auto nearby = successor.context.summonCreature(destination, 1835, origin, TempSpawnType.manual, 0, 0);
            from.replicaCreated(2, casterCell, nearby.guid, encodeState(nearby, 0));
            destination.replicaCreated(3, cell, boss.guid, encodeState(boss, 0));
            assert(hero.session.inWorld.actAtReplica(nearby.guid, ArrivalAction.init));
            assert(relay.remote.character.values.get!UNIT_CHANNEL_SPELL == boon
                && relay.remote.character.values.get!UNIT_FIELD_CHANNEL_OBJECT == boss.guid);
            successor.context.sendAreaDamage = (ushort peer, const ref AreaDamage message) {
                assert(peer == 3 && message.auraMs == AreaDamage.completedChannel);
                to.replicaCreated(2, casterCell, player.guid, encodePlayerState(relay.remote.character, 0));
                owner.context.areaDamageArrived(2, message);
                ++completions;
                return true;
            };
            relay.remote.update(1.msecs);
            successor.context.update(source.now);
            assert(completions == 1 && owner.context.runningScripts == 1 && !successor.context.runningScripts);
            continue;
        }
        const bundle = to.migrateOut(key => key == cell, 3, &owner.context.saveMigrant);
        ubyte[][uint] unused;
        successor.context.recovery.regionsChanged([gained], null, [gained.id: bundle], unused);
        auto moved = destination.creatureAt(boss.guid);
        assert(moved !is null && to.creatureAt(boss.guid) is null);

        if (cancelled)
        {
            from.replicaCreated(3, cell, boss.guid, encodeState(moved, 0));
            ByteWriter stop;
            stop.put(boon);
            hero.write(Opcode.CMSG_CANCEL_CHANNELLING, stop.data);
            hero.session.update(100.msecs);
            moved.updateAuras(destination, 100);
            source.context.update(source.now);
            assert(!completions && !moved.auras.find(boon, player.guid) && !successor.context.runningScripts);
            assert(moved.values.get!UNIT_FIELD_FACTIONTEMPLATE == oldFaction);
            continue;
        }

        hero.session.update(1.msecs);
        source.context.update(source.now);
        assert(!player.values.get!UNIT_CHANNEL_SPELL && completions == 1 && !owner.context.runningScripts,
            "the former owner cannot apply the completion");
        from.replicaCreated(3, cell, boss.guid, encodeState(moved, 0));
        source.now += 50.msecs;
        source.context.update(source.now);
        assert(completions == 2 && successor.context.runningScripts == 1,
            "only the current owner starts the real EventAI relay");
        delivered.sequence = source.context.nextGameplaySequence();
        successor.context.areaDamageArrived(1, delivered);
        assert(successor.context.runningScripts == 1, "a replay cannot start the relay again");
        successor.context.updateScripts(1);
        assert(moved.values.get!UNIT_FIELD_FACTIONTEMPLATE == 7, "the actual relay changes Ras's faction");
    }
}

/// The Orb of Draconic Energy checks and controls the same Emberstrife after changing nodes.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.grid : cellCoordinate, cellKeyAt, cellSize;
    import dmangos.world.replication : encodeState;
    import dmangos.world.spellcast : castTime;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHARM, UNIT_FIELD_CHARMEDBY,
        UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;

    enum uint orb = 12300, dominion = 16053, emberstrife = 10321;
    const origin = Position(2 * cellSize - 2, 100, 40), targetAt = Position(2 * cellSize + 2, 100, 40);
    const cell = cellKeyAt(targetAt.x, targetAt.y);
    foreach (wounded; [false, true])
    {
        auto source = RealWorld.make(), owner = RealWorld.make();
        owner.context.database = source.db;
        auto relay = new TestPlayerRelay(source.context, owner.context);
        auto from = source.context.map(1), to = owner.context.map(1);
        to.random.seed(20_261_120); // RealWorld.make seeds map 0, while this cast lands on Kalimdor.
        auto dragon = owner.context.summonCreature(to, emberstrife, targetAt, TempSpawnType.manual, 0, 0);
        assert(dragon !is null);
        if (wounded)
            dragon.values.set!UNIT_FIELD_HEALTH(dragon.values.get!UNIT_FIELD_MAXHEALTH / 12);
        from.replicaCreated(2, cell, dragon.guid, encodeState(dragon, 0));
        auto client = loggedIn(source.context, source.db, 112, "Keeper", origin, AccountLevel.player, raceHuman, 0, 60,
            (ref CharacterData c) { c.map = 1; });
        auto hero = client.session.inWorld;
        hero.storeLoot(orb, 1, 0, false);
        const slot = backpackSlot(hero.player, orb);
        auto item = hero.player.inventory[inventorySlotBag0, slot];
        assert(item !is null);
        source.db.loadable[112].items = [source.db.itemRows[item.guid]];
        ByteWriter use;
        use.put(inventorySlotBag0);
        use.put(slot);
        use.put(ubyte(1));
        SpellTargets(TargetFlags.self).write(use);
        client.write(Opcode.CMSG_USE_ITEM, use.data);
        assert(relay.remote !is null, "the orb first moves to the actual dragon's node");
        relay.remote.update(50.msecs);
        const spell = owner.context.spellInfo(dominion);
        const wait = castTime(*spell, owner.context.client, 60);
        relay.remote.update(wait.msecs);
        auto moved = relay.remote.inWorld;
        if (wounded)
        {
            assert(moved.player.values.get!UNIT_CHANNEL_SPELL == dominion);
            assert(moved.player.values.get!UNIT_FIELD_CHARM == dragon.guid
                && dragon.values.get!UNIT_FIELD_CHARMEDBY == moved.player.guid);

            const later = owner.context.clock() + 11.seconds;
            owner.context.clock = () => later;
            owner.context.regionOwnerAround = (uint, Position, float) => ushort(1);
            assert(!moved.inCombat && moved.migrationTarget() == 0,
                "ordinary balancing waits for creature control to end");

            auto successor = RealWorld.make();
            successor.context.nodeId = 3;
            const guid = dragon.guid, woundedHealth = dragon.values.get!UNIT_FIELD_HEALTH;
            const x = cellCoordinate(targetAt.x), y = cellCoordinate(targetAt.y);
            auto region = Region(82, 1, CellRect(x, y, x + 1, y + 1), 2, 1, RegionState.revoking, 3);
            ubyte[][uint] leaving, unused;
            owner.context.recovery.regionsChanged(null, [region], null, leaving);
            assert(moved.charmed is null && !moved.player.values.get!UNIT_CHANNEL_SPELL);
            assert(to.creatureAt(guid) is null && leaving.get(region.id, null).length,
                "release must include the original creature in the region handoff");

            region.owner = 3;
            region.state = RegionState.granted;
            region.next = 0;
            successor.context.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
            auto destination = successor.context.map(1);
            auto restored = destination.creatureAt(guid);
            assert(restored !is null && restored.values.get!UNIT_FIELD_HEALTH == woundedHealth);
            assert(!restored.values.get!UNIT_FIELD_CHARMEDBY && destination.creaturesNear(targetAt, 1).length == 1);
        }
        else
            assert(!moved.player.values.get!UNIT_CHANNEL_SPELL && !dragon.values.get!UNIT_FIELD_CHARMEDBY,
                "the item script refuses a dragon above ten percent health");
    }
}

/// A move to another node whose own saves do not settle leaves the hunter where it was, its pet out again.
unittest
{
    import dmangos.world.database : PetRecord;
    import dmangos.world.pet : PetType;
    import dmangos.world.testclient : TestPlayerRelay;
    import dmangos.world.testdata : classHunter;
    import dmangos.world.writebehind : WriteBehind, Writer;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), destination = RealWorld.make();
    destination.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, destination.context);
    PetRecord saved;
    saved.id = 12;
    saved.entry = 3099; // a boar
    saved.owner = 7;
    saved.type = PetType.hunter;
    saved.name = "Bristle";
    saved.level = 60;
    saved.health = 150;
    source.db.savePet(saved);
    auto client = source.character(7, "Tracker", classHunter, 60, null, raceOrc);
    auto hunter = client.session.inWorld;
    assert(hunter.ownPet !is null);

    // Nothing waits before the move, so it begins; the saves it queues are not written (the writer is not
    // started), so it does not go on.
    auto writer = new Writer(source.db, null, false);
    scope (exit)
        writer.stop();
    writer.stalledWaitMs = 0;
    source.context.writer = writer;
    source.context.database = new WriteBehind(source.db, writer, null);
    assert(!hunter.migrateTo(destination.context.nodeId), "its saves do not settle: the move does not go on");
    assert(relay.remote is null && client.session.inWorld is hunter);
    assert(hunter.ownPet !is null && hunter.ownPet.spawn.entry == 3099, "the pet set aside for the move is back");
}

/// Eyes of the Beast keeps the hunter's pet and its original mover through a clean handoff.
unittest
{
    import dmangos.bytes : ByteWriter;
    import std.format : format;
    import dmangos.world.database : PetRecord;
    import dmangos.world.pet : PetType;
    import dmangos.world.pethandlers : spellEyesOfTheBeast;
    import dmangos.world.spellcast : castTime;
    import dmangos.world.testdata : classHunter;
    import dmangos.world.updatefields : PLAYER_FARSIGHT, UNIT_CHANNEL_SPELL, UNIT_FIELD_CHARMEDBY, UNIT_FIELD_HEALTH;

    if (!haveRealData())
        return;

    auto source = RealWorld.make(), destination = RealWorld.make();
    destination.context.database = source.db;
    auto relay = new TestPlayerRelay(source.context, destination.context);
    enum uint eyes = spellEyesOfTheBeast, boar = 3099;
    PetRecord saved;
    saved.id = 12;
    saved.entry = boar;
    saved.owner = 7;
    saved.type = PetType.hunter;
    saved.name = "Bristle";
    saved.level = 60;
    saved.health = 150;
    saved.mana = 70;
    source.db.savePet(saved);
    auto client = source.character(7, "Tracker", classHunter, 60, [eyes], raceOrc);
    auto hunter = client.session.inWorld;
    auto pet = hunter.ownPet;
    assert(pet !is null && pet.spawn.entry == boar);
    assert(source.cast_(client, eyes) == SpellCastResult.ok);
    const spell = source.context.spellInfo(eyes);
    client.session.update(castTime(*spell, source.context.client, 60).msecs);
    assert(hunter.charmed is pet && hunter.activeMover == pet.guid);
    assert(hunter.player.values.get!UNIT_CHANNEL_SPELL == eyes && hunter.player.values.get!PLAYER_FARSIGHT == pet.guid);
    assert(hunter.channelledAt(spell) == pet.guid, format!"channel target %s, pet %s"(hunter.channelledAt(spell), pet.guid));

    auto motion = pet.movement;
    motion.position.x += 70;
    ByteWriter input;
    motion.write(input);
    client.write(Opcode.MSG_MOVE_HEARTBEAT, input.data);
    assert(pet.position == motion.position);
    const guid = pet.guid, health = pet.values.get!UNIT_FIELD_HEALTH;
    const position = pet.position, duration = pet.auras.find(eyes, hunter.player.guid).duration;
    client.read();

    hunter.migrateTo(destination.context.nodeId);
    assert(relay.remote !is null && source.context.map(0).creatureAt(guid) is null);
    auto current = relay.remote.inWorld;
    auto moved = current.ownPet;
    assert(moved !is null && moved.guid == guid && moved.position == position,
        format!"expected pet %s at %s, got %s at %s"(guid, position, moved is null ? 0 : moved.guid,
            moved is null ? Position.init : moved.position));
    assert(current.charmed is moved && current.activeMover == guid && current.player.values.get!PLAYER_FARSIGHT == guid);
    assert(current.player.values.get!UNIT_CHANNEL_SPELL == eyes && moved.values.get!UNIT_FIELD_HEALTH == health);
    assert(moved.values.get!UNIT_FIELD_CHARMEDBY == current.player.guid);
    assert(moved.auras.find(eyes, current.player.guid).duration == duration);
    assert(!opcodesOf(client.read()).canFind(Opcode.SMSG_SPELL_START), "the handoff did not cast the spell again");

    ByteWriter nextMove;
    motion.position.y += 5;
    motion.write(nextMove);
    client.write(Opcode.MSG_MOVE_HEARTBEAT, nextMove.data);
    assert(moved.position == motion.position, "the original connection still moves the pet");

    ByteWriter cancel;
    cancel.put(eyes);
    client.write(Opcode.CMSG_CANCEL_CHANNELLING, cancel.data);
    assert(current.ownPet is moved && current.charmed is null && !current.activeMover);
    assert(!current.player.values.get!PLAYER_FARSIGHT && !current.player.values.get!UNIT_CHANNEL_SPELL);
    assert(!moved.values.get!UNIT_FIELD_CHARMEDBY && !moved.auras.find(eyes, current.player.guid));
}

/// The Glowing Crystal Prison can capture its real target on another node exactly once.
unittest
{
    import dmangos.bytes : ByteWriter;
    import std.format : format;
    import dmangos.cluster.protocol : AreaDamage;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.grid : cellKeyAt, cellSize;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT;

    if (!haveRealData())
        return;

    enum uint item = 18601, prison = 23015, doomguard = 12396, crystal = 179644;
    const origin = Position(2 * cellSize - 2, 100, 40), at = Position(2 * cellSize + 2, 100, 40);
    const casterCell = cellKeyAt(origin.x, origin.y), targetCell = cellKeyAt(at.x, at.y);
    foreach (interrupt; [true, false])
    {
        auto source = RealWorld.make(), owner = RealWorld.make();
        source.context.nodeId = 1;
        owner.context.nodeId = 2;
        source.context.clock = () => source.now;
        auto from = source.context.map(0), to = owner.context.map(0);
        auto client = loggedIn(source.context, source.db, 112, "Keeper", origin, AccountLevel.player,
            raceHuman, 0, 60, (ref CharacterData c) { c.classId = 9; });
        auto hero = client.session.inWorld;
        hero.storeLoot(item, 1, 0, false);
        auto creature = owner.context.summonCreature(to, doomguard, at, TempSpawnType.manual, 0, 0);
        from.replicaCreated(2, targetCell, creature.guid, encodeState(creature, 0));
        assert(source.context.namedCreatureChannel(source.context.spellInfo(prison)) == 1, "the real prison row routes");
        AreaDamage completion;
        uint sent;
        import dmangos.world.spellcast : SpellMissInfo;
        SpellMissInfo rejected;
        source.context.sendAreaDamage = (ushort peer, const ref AreaDamage effect) {
            assert(peer == 2 && effect.target == creature.guid && effect.channelled && effect.namedCreature);
            ++sent;
            to.replicaCreated(1, casterCell, hero.player.guid, encodePlayerState(hero.player, 0));
            if (effect.auraMs == AreaDamage.completedChannel)
                completion = cast(AreaDamage) effect;
            owner.context.areaDamageArrived(1, effect);
            return true;
        };
        owner.context.sendAreaDamage = (ushort peer, const ref AreaDamage response) {
            assert(peer == 1 && response.reply);
            rejected = cast(SpellMissInfo) response.miss;
            source.context.areaDamageArrived(2, response);
            return true;
        };
        ByteWriter use;
        use.put(inventorySlotBag0);
        use.put(backpackSlot(hero.player, item));
        use.put(ubyte(1));
        SpellTargets(TargetFlags.self).write(use);
        client.write(Opcode.CMSG_USE_ITEM, use.data);
        const caster = hero.player.guid;
        const castResult = bodyOf(client.read(), Opcode.SMSG_CAST_RESULT);
        assert(hero.player.values.get!UNIT_CHANNEL_SPELL == prison
            && hero.player.values.get!UNIT_FIELD_CHANNEL_OBJECT == creature.guid,
            format!"prison channel %s, sent %s, target miss %s, cast result %s"(
                hero.player.values.get!UNIT_CHANNEL_SPELL, sent, rejected, castResult));
        auto aura = creature.auras.find(prison, caster);
        assert(aura !is null && aura.channelToken && aura.duration == 18_000 && aura.effects == 0b110
            && !aura.positive);
        assert(creature.ai.threatOf(caster) >= 50_000);

        size_t crystals()
        {
            size_t count;
            foreach (object; to.objectsNear(at, 10))
                if (auto go = cast(GameObject) object)
                    if (go.spawn.entry == crystal)
                        ++count;
            return count;
        }

        client.session.update(17_999.msecs);
        creature.updateAuras(to, 17_999);
        assert(!crystals() && aura.duration == 1);
        if (interrupt)
        {
            ByteWriter stop;
            stop.put(prison);
            client.write(Opcode.CMSG_CANCEL_CHANNELLING, stop.data);
            client.session.update(100.msecs);
            creature.updateAuras(to, 100);
            source.context.update(source.now);
            assert(!completion.sequence && !crystals() && creature.alive && !creature.auras.find(prison, caster));
            continue;
        }

        creature.updateAuras(to, 1);
        client.session.update(1.msecs);
        source.now += 499.msecs;
        source.context.update(source.now);
        assert(!completion.sequence && !crystals(), "the capture spell still has one millisecond of travel");
        source.now += 1.msecs;
        source.context.update(source.now);
        assert(completion.sequence && crystals() == 1 && !creature.auras.find(prison, caster));
        completion.sequence = source.context.nextGameplaySequence();
        owner.context.areaDamageArrived(1, completion);
        assert(crystals() == 1, "replaying the completion does not conjure another prison");
        creature.tick(to, 10);
        assert(to.creatureAt(creature.guid) is null);
    }
}

/// Cold Snap (12472) makes Ice Block (11958) ready again: its cooldown is its category's (37), not its own.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint iceBlock = 11958, coldSnap = 12472;
    auto mage = w.character(1, "Jaina", classMageId, 60, [iceBlock, coldSnap]);
    auto me = mage.session.inWorld;
    {
        const r = w.cast_(mage, iceBlock);
        import std.format : format;
        assert(r == SpellCastResult.ok, format!"Ice Block refused: %s"(r));
    }
    assert(!me.spellIsReady(iceBlock), "Ice Block cooling down");
    // Out of the block (it stuns its mage: no Cold Snap inside it), past the global cooldown.
    if (auto aura = me.player.auras.find(iceBlock))
        me.removeAura(aura);
    w.now += 2.seconds;
    mage.read();
    assert(w.cast_(mage, coldSnap) == SpellCastResult.ok);
    assert(me.spellIsReady(iceBlock), "Cold Snap made Ice Block ready");
    assert(mage.read().canFind!(p => p.opcode == Opcode.SMSG_CLEAR_COOLDOWN), "the client told");
}

/// Presence of Mind (12043): its cooldown waits for its aura to end, then starts and the client is told.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint presenceOfMind = 12043, frostbolt = 116;
    auto mage = w.character(2, "Antonidas", classMageId, 60, [presenceOfMind, frostbolt]);
    auto me = mage.session.inWorld;
    assert(w.cast_(mage, presenceOfMind) == SpellCastResult.ok);
    assert(me.player.auras.find(presenceOfMind) !is null, "its aura on");
    assert(!me.spellIsReady(presenceOfMind), "held while its aura lasts");
    mage.read();
    w.now += 2.seconds;
    // Its charge spent by the next spell with a cast time: the aura goes, the cooldown starts.
    const kobold = w.enemy(mage);
    me.player.movement.position.orientation = 0; // facing it (east)
    assert(w.castAt(mage, frostbolt, kobold) == SpellCastResult.ok);
    assert(me.player.auras.find(presenceOfMind) is null, "spent by Frostbolt");
    assert(mage.read().canFind!(p => p.opcode == Opcode.SMSG_COOLDOWN_EVENT), "the client's cooldown starts");
    assert(!me.spellIsReady(presenceOfMind));
}

/// The first backpack slot holding item `entry`.
private ubyte backpackSlot(Player me, uint entry)
{
    import dmangos.world.defines : inventorySlotBag0;

    foreach (ubyte s; 23 .. 39)
        if (const item = me.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
                return s;
    assert(false, "not in the backpack");
}

/**
 * An item's own cooldown category: the Swiftness Potion (2459, spell 2379 of no category; the item's
 * spellcategory_1 4) waits on the Major Healing Potion (13446, category 4, two minutes).
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto w = RealWorld.make();
    enum uint majorHealing = 13446, swiftness = 2459, speed = 2379;
    auto hero = w.character(3, "Drinker", classWarriorId, 60, []);
    auto me = cast(Player) hero.session.character;
    hero.session.inWorld.storeLoot(majorHealing, 1, 0, false);
    hero.session.inWorld.storeLoot(swiftness, 1, 0, false);
    me.values.set!UNIT_FIELD_HEALTH(1u); // hurt: the potion has something to heal
    hero.read();
    void use(uint entry)
    {
        ByteWriter b;
        b.put(inventorySlotBag0);
        b.put(backpackSlot(me, entry));
        b.put(ubyte(1));
        SpellTargets(TargetFlags.self).write(b);
        hero.write(Opcode.CMSG_USE_ITEM, b.data.dup);
        hero.read();
    }
    use(majorHealing);
    assert(me.inventory.count(majorHealing) == 0, "drunk");
    w.now += 2.seconds;
    use(swiftness);
    assert(me.inventory.count(swiftness) == 1 && me.auras.find(speed) is null, "the potions' category 4 waits");
    w.now += 120.seconds;
    use(swiftness);
    assert(me.inventory.count(swiftness) == 0 && me.auras.find(speed) !is null, "two minutes on");
}

/**
 * Pick Lock (1804) by a level 60 rogue: its lockpicking skill counts, not its level. A Heavy Junkbox (16885: Lock.dbc
 * 599, lockpicking 250) is beyond lockpicking 10, within 300.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.defines : inventorySlotBag0;

    auto w = RealWorld.make();
    enum uint pickLock = 1804, junkbox = 16885, lockpicking = 633;
    auto rogue = w.character(4, "Picker", classRogueId, 60, [pickLock]);
    auto me = cast(Player) rogue.session.character;
    rogue.session.inWorld.storeLoot(junkbox, 1, 0, false);
    rogue.session.inWorld.storeLoot(5060, 1, 0, false); // Thieves' Tools, its Totem1
    rogue.read();
    SpellTargets t;
    t.mask = TargetFlags.item;
    t.item = me.inventory[inventorySlotBag0, backpackSlot(me, junkbox)].fullGuid;
    const info = w.context.data.spells.spell(pickLock);
    me.setSkill(lockpicking, 10, 300);
    assert(rogue.session.inWorld.castSpell(info, t, false, 0) == SpellCastResult.lowCastLevel, "10 against 250");
    me.setSkill(lockpicking, 300, 300);
    {
        import std.format : format;

        const r = rogue.session.inWorld.castSpell(info, t, false, 0);
        assert(r == SpellCastResult.ok, format!"300 against 250: %s"(r));
    }
}

/**
 * Invisibility detection takes the strongest of a type: Detect Lesser Invisibility (132) and Detect Invisibility
 * (2970) together do not see through Greater Invisibility (10228); Detect Greater Invisibility (11743) does.
 */
unittest
{
    if (!haveRealData())
        return;
    import dmangos.world.auras : AuraSet, makeAura;
    import dmangos.world.spellcast : effectValue;
    import dmangos.world.objects : UpdateValues;
    import dmangos.world.updatefields : TypeId;

    auto w = RealWorld.make();
    auto hiddenValues = UpdateValues(TypeId.unit), seeingValues = UpdateValues(TypeId.unit);
    AuraSet hidden, seeing;
    void put(ref AuraSet set, ref UpdateValues values, uint id)
    {
        const info = w.context.data.spells.spell(id);
        assert(info !is null);
        bool isNew;
        set.apply(makeAura(info, 1, 60, 60_000, true, [effectValue(*info, 0, 60, 0), 0, 0]), values, isNew);
    }
    put(hidden, hiddenValues, 10228);
    put(seeing, seeingValues, 132);
    put(seeing, seeingValues, 2970);
    assert(!seeing.seesThroughInvisibility(hidden), "100 and 200 are not 300");
    put(seeing, seeingValues, 11743);
    assert(seeing.seesThroughInvisibility(hidden));
}

enum ubyte classShamanId = 7;

/// Fire Power rank 2 (12378): 4% more Fireball (133) damage, by its first rank's `spell_affect` mask (0x8C20017).
unittest
{
    import dmangos.world.spellmods : applySpellMod, SpellModOp;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint firePower = 12378, fireball = 133;
    auto mage = w.character(10, "Kaelthas", classMageId, 60, [firePower]);
    auto me = mage.session.inWorld;
    me.applyPassive(w.context.data.spells.spell(firePower));
    assert(me.player.auras.find(firePower) !is null);
    assert(applySpellMod(me.player.auras.list, SpellModOp.damage, *w.context.data.spells.spell(fireball), 1000) == 1040,
        "4% more");
}

/// `who` takes the weapon `entry` and wields it (Kidney Shot and Sunder Armor need one: `EquippedItemClass` 2).
private void wield(ref TestClient who, uint entry)
{
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.packets : ClientItemPos;

    auto me = who.session.inWorld;
    me.storeLoot(entry, 1, 0, false);
    foreach (ubyte s; 23 .. 39)
        if (const item = me.player.inventory[inventorySlotBag0, s])
            if (item.entry == entry)
            {
                who.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, s));
                break;
            }
    who.read();
    assert(me.player.inventory.equipped(15) !is null && me.player.inventory.equipped(15).entry == entry, "wielded");
}

/**
 * Reincarnation (21169): its hour is its category's (1161; RecoveryTime 0), less Improved Reincarnation rank 2's
 * twenty minutes (16209, whose mask is its first rank's `spell_affect` row).
 */
unittest
{
    import dmangos.world.player : DeathState;
    import dmangos.world.unit : Blow, UnitRef;
    import dmangos.world.updatefields : PLAYER_SELF_RES_SPELL;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint passive = 20608, reincarnation = 21169, improved = 16209, ankh = 17030;
    auto thrall = w.character(3, "Thrall", classShamanId, 60, [passive, improved], raceOrc);
    auto me = thrall.session.inWorld;
    me.applyPassive(w.context.data.spells.spell(improved));
    assert(me.player.auras.find(improved) !is null, "the talent's aura");
    me.storeLoot(ankh, 1, 0, false);
    thrall.read();
    me.sufferDamage(UnitRef.init, 1_000_000, Blow.spell());
    assert(me.player.values.get!PLAYER_SELF_RES_SPELL == reincarnation, "offered");
    thrall.write(Opcode.CMSG_SELF_RES, null);
    assert(me.player.deathState == DeathState.alive, "back");
    assert(!me.spellIsReady(reincarnation), "its category's cooldown started");
    w.now += 39 * 60.seconds;
    assert(!me.spellIsReady(reincarnation), "forty minutes with the talent");
    w.now += 2 * 60.seconds;
    assert(me.spellIsReady(reincarnation), "not the hour: the talent's rank 2 counts");
}

/**
 * Items of one cooldown category of their own share it though their spells have none: Restoring Balm (1970) is not
 * ready right after a Crystal Basilisk Spine (1703); both `spellcategory_1` 1153, two minutes.
 */
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.defines : inventorySlotBag0;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint spine = 1703, balm = 1970;
    auto user = w.character(4, "Brann", classWarriorId, 60, []);
    auto me = user.session.inWorld;
    me.storeLoot(spine, 1, 0, false);
    me.storeLoot(balm, 1, 0, false);
    user.read();
    ubyte slotOf(uint entry)
    {
        foreach (ubyte s; 23 .. 39)
            if (const item = me.player.inventory[inventorySlotBag0, s])
                if (item.entry == entry)
                    return s;
        assert(false, "not in the backpack");
    }
    // The cast result of using `entry` at oneself.
    ubyte use(uint entry)
    {
        ByteWriter w;
        w.put(ubyte(inventorySlotBag0));
        w.put(slotOf(entry));
        w.put(ubyte(1));
        SpellTargets(TargetFlags.self).write(w);
        user.write(Opcode.CMSG_USE_ITEM, w.data);
        foreach (p; user.read())
            if (p.opcode == Opcode.SMSG_CAST_RESULT)
            {
                auto r = ByteReader(p.body_);
                r.read!uint;
                return r.read!ubyte == 0 ? 0 : r.read!ubyte;
            }
        assert(false, "no cast result");
    }
    assert(use(spine) == 0, "the spine used");
    w.now += 2.seconds;
    assert(use(balm) == SpellCastResult.notReady, "the balm shares its category's two minutes");
    w.now += 119.seconds;
    assert(use(balm) == 0);
}

/// Bloodrage (2687) costs a fifth of the base health (`PowerType` -2, `ManaCostPercentage` 20), taken as health.
unittest
{
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint bloodrage = 2687;
    auto warrior = w.character(5, "Varian", classWarriorId, 60, [bloodrage]);
    auto me = warrior.session.inWorld;
    const health = me.player.values.get!UNIT_FIELD_HEALTH, cost = me.player.stats.baseHealth * 20 / 100;
    assert(w.cast_(warrior, bloodrage) == SpellCastResult.ok);
    assert(me.player.values.get!UNIT_FIELD_HEALTH == health - cost, "a fifth of the base health");
}

/// An interrupt stops a channel too, and locks its school out: Arcane Missiles (5143) channelled at a kobold.
unittest
{
    import dmangos.world.updatefields : UNIT_CHANNEL_SPELL;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint missiles = 5143;
    auto mage = w.character(6, "Aegwynn", classMageId, 60, [missiles]);
    auto me = mage.session.inWorld;
    const kobold = w.enemy(mage);
    me.player.movement.position.orientation = 0; // facing it (east)
    assert(w.castAt(mage, missiles, kobold) == SpellCastResult.ok);
    assert(me.player.values.get!UNIT_CHANNEL_SPELL == missiles, "channelling");
    me.castInterruptedBy(kobold, 4000); // a Kick, a Pummel
    assert(me.player.values.get!UNIT_CHANNEL_SPELL == 0, "the channel interrupted");
    w.now += 2.seconds;
    assert(w.castAt(mage, missiles, kobold) == SpellCastResult.notReady, "arcane locked out");
}

/**
 * Kidney Shot rank 1 (408) lasts nothing at no combo point and a second a point (`SpellDuration` 187: 0 to 5000):
 * two points, two seconds.
 */
unittest
{
    import dmangos.world.creature : Creature;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint kidneyShot = 408;
    auto rogue = w.character(7, "Garona", classRogueId, 60, [kidneyShot]);
    auto me = rogue.session.inWorld;
    wield(rogue, 2092); // a Worn Dagger
    me.player.movement.position.orientation = 0; // facing east, where each kobold stands
    foreach (attempt; 0 .. 20) // a kobold may dodge it: another (no diminishing) until one is stunned
    {
        const kobold = w.enemy(rogue);
        me.addComboPoints(kobold, 2);
        w.now += 21.seconds; // its cooldown, the global one
        const result = w.castAt(rogue, kidneyShot, kobold);
        import std.format : format;
        assert(result == SpellCastResult.ok, format!"Kidney Shot refused: %s"(result));
        auto creature = w.context.map(0).creatureAt(kobold);
        if (auto stun = creature.auras.find(kidneyShot))
        {
            assert(stun.maxDuration == 2000, "two points, two seconds");
            return;
        }
    }
    assert(false, "never stunned");
}

/// Two warriors' Sunder Armor (11597) on one kobold: one stack of the two, not a stack each.
unittest
{
    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    enum uint sunder = 11597;
    auto first = w.character(8, "Lothar", classWarriorId, 60, [sunder]);
    auto second = w.character(9, "Danath", classWarriorId, 60, [sunder]);
    wield(first, 25); // a Worn Shortsword each
    wield(second, 25);
    const kobold = w.enemy(first);
    foreach (who; [first, second])
        who.session.inWorld.player.movement.position.orientation = 0; // facing it (east)
    auto creature = w.context.map(0).creatureAt(kobold);
    uint sunders()
    {
        uint n;
        foreach (aura; creature.auras.list)
            n += aura.spell.id == sunder;
        return n;
    }
    // Each sunders until one lands (a kobold may dodge).
    foreach (who; [first, second])
    {
        const before = creature.auras.find(sunder) is null ? 0 : creature.auras.find(sunder).stacks;
        foreach (attempt; 0 .. 20)
        {
            w.now += 2.seconds;
            w.castAt(who, sunder, kobold);
            const now = creature.auras.find(sunder) is null ? 0 : creature.auras.find(sunder).stacks;
            if (now > before || sunders() > 1)
                break;
        }
    }
    assert(sunders() == 1, "one Sunder Armor");
    assert(creature.auras.find(sunder).stacks == 2, "of both warriors' stacks");
}
