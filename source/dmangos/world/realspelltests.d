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
    import dmangos.world.replication : encodeState, Replicator;
    import dmangos.world.updatefields : OBJECT_FIELD_SCALE_X, UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT,
        UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    if (!haveRealData())
        return;

    static final class CasterReplicas : Replicator
    {
        Map[ushort] peers;
        void create(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state)
        {
            peers[peer].replicaCreated(1, cell, guid, state);
        }
        void values(ushort peer, uint map, ulong guid, const(ubyte)[] fields)
        {
            peers[peer].replicaValues(1, guid, fields);
        }
        void move(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] packet, const(ubyte)[] motion) {}
        void remove(ushort peer, uint map, ulong guid) { peers[peer].replicaRemoved(1, guid); }
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
        if (period > 0)
        {
            migrated.updateAuras(destination, period - beforeHandoff - 1);
            assert(migrated.values.get!UNIT_FIELD_HEALTH == 3000, "the next tick waits for its original deadline");
            migrated.updateAuras(destination, 1);
            assert(migrated.values.get!UNIT_FIELD_HEALTH == 3000 + movedAura.amount[0]);
        }
        caster.ai.interruptCast();
        assert(interruptions == 1 && !caster.values.get!UNIT_CHANNEL_SPELL && !migrated.auras.find(expectedSpell, caster.guid));
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

    foreach (cancelled; [false, true])
    {
        auto source = RealWorld.make(), owner = RealWorld.make(), successor = RealWorld.make();
        source.context.nodeId = 1;
        owner.context.nodeId = 2;
        successor.context.nodeId = 3;
        source.context.clock = () => source.now;
        auto from = source.context.map(0), to = owner.context.map(0), destination = successor.context.map(0);
        auto hero = loggedIn(source.context, source.db, 112, "Keepsake", origin, AccountLevel.player, raceHuman, 0, 60);
        auto player = cast(Player) hero.session.character;
        hero.session.inWorld.storeLoot(keepsake, 1, 0, false);
        auto boss = owner.context.summonCreature(to, ras, at, TempSpawnType.manual, 0, 0);
        assert(boss !is null);
        from.replicaCreated(2, cell, boss.guid, encodeState(boss, 0));
        const oldFaction = boss.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        AreaDamage delivered;
        uint completions;
        source.context.sendAreaDamage = (ushort peer, const ref AreaDamage message) {
            auto world = peer == 2 ? owner.context : successor.context;
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
