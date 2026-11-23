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
        source.context.clock = () => source.now;
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
            successor.context.regionsChanged([region], null, [region.id: bundle], unused);
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
    owner.context.regionsChanged([region], null, [region.id: bundle], unused);
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
        owner.context.regionsChanged([region], null, [region.id: bundle], unused);
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
        successor.context.regionsChanged([gained], null, [gained.id: bundle], unused);
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
        owner.context.regionsChanged([gainedCaster], null, [gainedCaster.id: casterBundle], unused);
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
        successor.context.regionsChanged([gained], null, [gained.id: bundle], unused);
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
