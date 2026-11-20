/**
 * The scripts in the world (docs/SCRIPTING.md): Mr. Smite's fight driven by the real creature AI,
 * his script's state carried to another node with him, and the Deadmines' dungeon script opening a
 * door when its guardian falls, saved in `instance.data` and read back after a restart.
 */
module dmangos.world.scripttests;

import dmangos.world.spellids;

version (unittest):

import core.time : MonoTime, msecs, seconds;
import std.algorithm.searching : canFind;

import dmangos.auth.accounts : AccountLevel;
import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.creature : Creature, CreatureSpawn;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.testclient;
import dmangos.world.testdata;
import dmangos.world.updatefields;
import dmangos.script.api : ActionResult;
import dmangos.world.player : Player;

/// Mr. Smite's phases, by the real AI; his state goes with him to another node; it goes when he does.
unittest
{
    import dmangos.scripts.deadmines : MrSmite, mrSmite;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    // The test world's innkeeper plays Mr. Smite; his two weapons are items the test world has.
    auto smiteTemplate = cast() context.data.creatureTemplates[creatureInnkeeper];
    smiteTemplate.entry = mrSmite;
    context.data.creatureTemplates[mrSmite] = smiteTemplate;
    context.data.creatureScriptNames[mrSmite] = "boss_mr_smite";
    context.data.items[MrSmite.reaver] = context.data.items[itemSword];
    context.data.items[MrSmite.mightyHammer] = context.data.items[itemStaff];
    const before = context.scripts.liveScripts;

    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 30);
    hero.read();
    CreatureSpawn spawn = {guid: 79990, entry: mrSmite, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto smite = context.makeCreature(&spawn);
    map.addObject(smite);
    assert(smite.ai.scripted && smite.ai.behaviourName == "boss_mr_smite");
    assert(context.scripts.liveScripts == before + 1);

    const max = smite.values.get!UNIT_FIELD_MAXHEALTH;
    void hit(uint percent)
    {
        const damage = max * percent / 100;
        smite.ai.attackedBy(hero.session.inWorld.unit, map);
        smite.ai.damageTaken(hero.session.inWorld.unit, damage);
        smite.values.set!UNIT_FIELD_HEALTH(smite.values.get!UNIT_FIELD_HEALTH - damage);
    }

    hit(30); // 100% -> 70%: still phase one
    assert(smite.ai.inCombat && smite.values.getByte!UNIT_FIELD_BYTES_1(0) == 0);
    hit(10); // -> 60%: past two thirds: he kneels to rearm
    assert(smite.values.getByte!UNIT_FIELD_BYTES_1(0) == 8, "kneeling");
    smite.ai.update(map, 1000);
    assert(smite.values.getByte!UNIT_FIELD_BYTES_1(0) == 8, "not yet");
    smite.ai.update(map, 1600);
    const axe = context.data.items[MrSmite.reaver].displayId;
    assert(smite.values.getByte!UNIT_FIELD_BYTES_1(0) == 0, "up again");
    assert(smite.values.get!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(0) == axe && smite.values.get!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(1) == axe);

    // He moves to another node: made anew from his spawn there, his state (phase two) read into it.
    ByteWriter w;
    smite.saveState(w);
    auto elsewhere = newCreationContext(db);
    elsewhere.data.creatureTemplates[mrSmite] = smiteTemplate;
    elsewhere.data.creatureScriptNames[mrSmite] = "boss_mr_smite";
    elsewhere.data.items[MrSmite.mightyHammer] = elsewhere.data.items[itemStaff];
    auto moved = elsewhere.makeCreature(&spawn);
    auto r = ByteReader(w.data);
    moved.loadState(r);
    auto there = elsewhere.map(mapEasternKingdoms);
    there.addObject(moved);
    // Past one third there: his last change, the hammer (from phase two, so not the axes again).
    const movedMax = moved.values.get!UNIT_FIELD_MAXHEALTH;
    moved.values.set!UNIT_FIELD_HEALTH(movedMax * 40 / 100);
    moved.ai.damageTaken(hero.session.inWorld.unit, movedMax * 10 / 100);
    assert(moved.values.getByte!UNIT_FIELD_BYTES_1(0) == 8, "the phase came along");
    moved.ai.update(there, 2600);
    assert(moved.values.get!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(0) == elsewhere.data.items[MrSmite.mightyHammer].displayId);
    assert(moved.values.get!UNIT_VIRTUAL_ITEM_SLOT_DISPLAY(1) == 0, "one two-handed hammer");

    // Gone from the map: his script's state is freed.
    map.removeObject(smite.guid);
    assert(context.scripts.liveScripts == before);
}

/// The Deadmines: the Factory Door opens when Rhahk'Zor falls, stays open, and is open after a restart.
unittest
{
    import dmangos.scripts.deadmines : factoryDoor, rhahkZor;
    import dmangos.world.context : WorldContext;
    import dmangos.world.instancescripting : instanceDataPrefix;
    import dmangos.world.packets : ClientGuid;

    auto db = newDatabase();
    const doorAt = Position(-16, -383, 61), guardAt = Position(-20, -383, 61);
    void prepare(WorldContext context)
    {
        auto door = GameObjectTemplate.init;
        door.entry = factoryDoor;
        door.type = 0; // a door
        door.displayId = 411;
        door.name = "Factory Door";
        context.data.gameObjectTemplates[factoryDoor] = door;
        context.data.gameObjectSpawns ~= GameObjectSpawn(90001, factoryDoor, mapDeadmines, doorAt.x, doorAt.y, doorAt.z);
        context.data.gameObjectCells[mapDeadmines][cellKeyAt(doorAt.x, doorAt.y)] ~= context.data.gameObjectSpawns.length - 1;
        auto guard = cast() context.data.creatureTemplates[creatureInnkeeper];
        guard.entry = rhahkZor;
        context.data.creatureTemplates[rhahkZor] = guard;
        context.data.creatureSpawns ~= CreatureSpawn(90002, rhahkZor, mapDeadmines, guardAt.x, guardAt.y, guardAt.z);
        context.data.creatureCells[mapDeadmines][cellKeyAt(guardAt.x, guardAt.y)] ~= context.data.creatureSpawns.length - 1;
        context.data.instanceScriptNames[mapDeadmines] = "instance_deadmines";
    }

    auto context = newCreationContext(db);
    prepare(context);
    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.read();
    hero.say(".worldport 36 -16 -380 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const copy = hero.session.inWorld.instanceId;
    auto script = context.instanceScript(copy);
    assert(script !is null && script.name == "instance_deadmines");
    auto map = context.instanceMap(copy);
    auto door = cast(GameObject) map.findObject(makeDoorGuid(factoryDoor, 90001));
    assert(door !is null && door.goState == 1, "closed while Rhahk'Zor lives");

    auto guard = cast(Creature) map.findObject(makeCreatureGuid(rhahkZor, 90002));
    assert(guard !is null);
    guard.die(map, context.unixTime);
    context.creatureDied(guard);
    assert(door.goState == 0, "open");
    const saved = db.loadInstances().instances;
    assert(saved.length == 1 && saved[0].data.length > instanceDataPrefix.length
        && saved[0].data[0 .. instanceDataPrefix.length] == instanceDataPrefix, "saved in instance.data");

    // A restart: the copy, its dead and its script's state come back; the door loads open.
    hero.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    auto again = newCreationContext(db);
    prepare(again);
    db.moveOfflineCharacter(7, mapDeadmines, -16, -380, 61, 1581);
    auto back = loggedIn(again, db, 7, "Varian", Position(-16, -380, 61), AccountLevel.administrator, raceHuman,
        mapDeadmines, 60);
    assert(back.session.inWorld.instanceId == copy);
    auto reloaded = cast(GameObject) again.instanceMap(copy).findObject(makeDoorGuid(factoryDoor, 90001));
    assert(reloaded !is null && reloaded.goState == 0, "open when it loads");
    assert(again.instanceMap(copy).findObject(makeCreatureGuid(rhahkZor, 90002)) is null, "he stays dead");

    // The copy is shut down: its script goes from memory (its state stays saved).
    const live = again.scripts.liveScripts;
    back.say(format(".instance shutdown %s", copy));
    assert(again.instanceScript(copy) is null && again.scripts.liveScripts < live);
}

private ulong makeDoorGuid(uint entry, uint spawn)
{
    import dmangos.world.objects : HighGuid, makeGuid;

    return makeGuid(HighGuid.gameObject, entry, spawn);
}

private ulong makeCreatureGuid(uint entry, uint spawn)
{
    import dmangos.world.objects : HighGuid, makeGuid;

    return makeGuid(HighGuid.unit, entry, spawn);
}

private string format(Args...)(string spec, Args args)
{
    static import std.format;

    return std.format.format(spec, args);
}

/**
 * A player killed in a dungeon who logs out is taken off the copy it was in, though its saved place
 * is its graveyard on another map (the map's tick once found it there with no character, and crashed).
 */
unittest
{
    import dmangos.world.packets : ClientGuid;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -16 -380 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const copy = hero.session.inWorld.instanceId;
    auto inside = context.instanceMap(copy);
    const guid = hero.session.character.guid;
    assert(inside.find(guid) !is null);
    hero.write(Opcode.CMSG_SET_SELECTION, ClientGuid(guid));
    hero.say(".kill");
    {
        import dmangos.world.player : DeathState;

        assert(hero.session.character.deathState != DeathState.alive, "dead");
    }
    hero.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    assert(inside.find(guid) is null && inside.population == 0, "off the copy");
    context.update(MonoTime.currTime); // and its tick goes on
}

/// The Defias Cannon fired: the Iron Clad Door opens, and Mr. Smite raises the alarm.
unittest
{
    import dmangos.scripts.deadmines : ironCladDoor, mrSmite;
    import dmangos.world.npcdata : BroadcastText;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint cannonEntry = 16398;
    const cannonAt = Position(-16, -385, 61), doorAt = Position(-10, -390, 61), smiteAt = Position(-20, -390, 61);
    static struct Placed { uint entry, type; Position at; uint guid; }
    foreach (p; [Placed(cannonEntry, 10, cannonAt, 90010), Placed(ironCladDoor, 0, doorAt, 90011)])
    {
        const entry = p.entry, type = p.type, at = p.at, guid = p.guid;
        auto t = GameObjectTemplate.init;
        t.entry = entry;
        t.type = type;
        t.displayId = 411;
        t.name = entry == cannonEntry ? "Defias Cannon" : "Iron Clad Door";
        context.data.gameObjectTemplates[entry] = t;
        context.data.gameObjectSpawns ~= GameObjectSpawn(guid, entry, mapDeadmines, at.x, at.y, at.z);
        context.data.gameObjectCells[mapDeadmines][cellKeyAt(at.x, at.y)] ~= context.data.gameObjectSpawns.length - 1;
    }
    context.data.gameObjectScriptNames[cannonEntry] = "go_defias_cannon";
    auto smite = cast() context.data.creatureTemplates[creatureInnkeeper];
    smite.entry = mrSmite;
    context.data.creatureTemplates[mrSmite] = smite;
    context.data.creatureScriptNames[mrSmite] = "boss_mr_smite";
    context.data.creatureSpawns ~= CreatureSpawn(90012, mrSmite, mapDeadmines, smiteAt.x, smiteAt.y, smiteAt.z);
    context.data.creatureCells[mapDeadmines][cellKeyAt(smiteAt.x, smiteAt.y)] ~= context.data.creatureSpawns.length - 1;
    context.data.instanceScriptNames[mapDeadmines] = "instance_deadmines";
    BroadcastText alarm;
    alarm.maleText = "We're under attack!";
    alarm.chatType = 1;
    context.data.scriptTexts[-1036001] = alarm;

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -16 -383 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.read();
    auto map = context.instanceMap(hero.session.inWorld.instanceId);
    auto cannon = cast(GameObject) map.findObject(makeDoorGuid(cannonEntry, 90010));
    auto door = cast(GameObject) map.findObject(makeDoorGuid(ironCladDoor, 90011));
    assert(cannon !is null && cannon.behaviour && door.goState == 1);
    hero.session.inWorld.useGameObject(cannon);
    assert(door.goState == 0, "blown open");
    const heard = hero.read();
    assert(opcodesOf(heard).canFind(Opcode.SMSG_MESSAGECHAT), "the alarm");
    // Gone with its map: the cannon's script is freed with it.
    const live = context.scripts.liveScripts;
    hero.say(format(".instance shutdown %s", hero.session.inWorld.instanceId));
    assert(context.scripts.liveScripts < live);
}

/**
 * An escort: the Defias Traitor, his quest taken, walks his path with the player, waits at its end,
 * gives the quest's event, and goes back home.
 */
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.script.api : Location, Waypoint;
    import dmangos.world.quests : Quest;
    import dmangos.world.quests : QuestState;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint traitorEntry = 467, quest = 155;
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto traitor = cast() context.data.creatureTemplates[creatureInnkeeper];
    traitor.entry = traitorEntry;
    traitor.npcFlags = 2; // a quest giver
    context.data.creatureTemplates[traitorEntry] = traitor;
    context.data.creatureScriptNames[traitorEntry] = "npc_defias_traitor";
    context.data.escortPaths[traitorEntry] = [Waypoint(Location(at.x + 6, at.y, at.z)),
        Waypoint(Location(at.x + 6, at.y + 6, at.z)), Waypoint(Location(at.x + 3, at.y + 6, at.z), 2000)];
    Quest q = {id: quest, method: 2, maxLevel: 60, title: "The Defias Brotherhood"};
    q.specialFlags = 0x2; // an event
    context.data.quests.quests[quest] = q;
    context.data.quests.creatureStarts[traitorEntry] = [quest];

    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 20);
    hero.read();
    CreatureSpawn spawn = {guid: 90020, entry: traitorEntry, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto him = context.makeCreature(&spawn);
    map.addObject(him);

    ByteWriter accept;
    accept.put(him.guid);
    accept.put(quest);
    hero.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    assert(hero.session.character.questStatus[quest].status == QuestState.incomplete);
    assert(him.values.get!UNIT_NPC_FLAGS == 0, "nobody else takes him on his way");
    foreach (_; 0 .. 60)
    {
        now += 250.msecs;
        context.update(now);
    }
    assert(hero.session.character.questStatus[quest].status == QuestState.complete, "the hideout reached");
    foreach (_; 0 .. 40)
    {
        now += 250.msecs;
        context.update(now);
    }
    assert(map.findObject(him.guid) is null, "gone home (to come back at his spawn)");
}

/// Life Tap (`spell_life_tap`): the warlock's health becomes as much mana; a tap that would kill does nothing.
unittest
{
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto tap = SpellInfo(1454);
    tap.effect[0] = SpellEffect.dummy; // dummy
    tap.basePoints[0] = 19;
    tap.baseDice[0] = 1;
    tap.implicitTargetA[0] = ImplicitTarget.caster; // the caster
    context.data.spells.spells[1454] = tap;
    context.data.spellScriptNames[1454] = "spell_life_tap";

    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto warlock = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceOrc, mapEasternKingdoms, 10);
    warlock.read();
    auto v = &(cast(Player) warlock.session.character).values;
    v.set!UNIT_FIELD_POWER1(0u);
    const health = v.get!UNIT_FIELD_HEALTH;
    warlock.session.inWorld.castSpell((1454 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), true, 0);
    const paid = health - v.get!UNIT_FIELD_HEALTH;
    assert(paid >= 20 && v.get!UNIT_FIELD_POWER1 == paid, "health into as much mana");

    v.set!UNIT_FIELD_HEALTH(5u);
    warlock.session.inWorld.castSpell((1454 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), true, 0);
    assert(v.get!UNIT_FIELD_HEALTH == 5, "not to death");
}

/// A scent of Lar'korwi (`at_scent_larkorwi`): walked into on the quest, the mate comes out, once.
unittest
{
    import dmangos.scripts.ungoro : ScentOfLarkorwi;
    import dmangos.world.packets : ClientAreaTrigger;
    import dmangos.world.quests : Quest;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto mate = cast() context.data.creatureTemplates[creatureInnkeeper];
    mate.entry = ScentOfLarkorwi.larkorwiMate;
    context.data.creatureTemplates[mate.entry] = mate;
    context.data.areaTriggerScriptNames[triggerInn] = "at_scent_larkorwi";
    Quest q = {id: ScentOfLarkorwi.questScent, method: 2, maxLevel: 60, title: "The Scent of Lar'korwi"};
    context.data.quests.quests[q.id] = q;

    const inn = Position(innPosition[0], innPosition[1], innPosition[2]);
    auto hunter = loggedIn(context, db, 7, "Varian", inn, AccountLevel.player, raceHuman, mapEasternKingdoms, 50);
    hunter.read();
    auto map = context.map(mapEasternKingdoms);
    size_t mates()
    {
        size_t n;
        foreach (c; map.creaturesNear(inn, 30))
            n += c.spawn.entry == mate.entry;
        return n;
    }

    hunter.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(triggerInn));
    assert(mates == 0, "not on the quest");
    hunter.session.inWorld.addQuest(context.data.quests.quests[q.id]);
    hunter.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(triggerInn));
    assert(mates == 1, "it comes out");
    hunter.write(Opcode.CMSG_AREATRIGGER, ClientAreaTrigger(triggerInn));
    assert(mates == 1, "once");
}

/// Lady Katrana Prestor (`npc_lady_katrana_prestor`): a menu of the script's, three steps, the quest's event.
unittest
{
    import dmangos.scripts.stormwind : LadyKatranaPrestor;
    import dmangos.world.packets : ClientGossipSelectOption, ClientNpcGuid;
    import dmangos.world.quests : Quest, QuestState;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint katrana = 1749;
    auto lady = cast() context.data.creatureTemplates[creatureInnkeeper];
    lady.entry = katrana;
    lady.npcFlags = 1 | 2; // gossip, quest giver
    context.data.creatureTemplates[katrana] = lady;
    context.data.creatureScriptNames[katrana] = "npc_lady_katrana_prestor";
    Quest q = {id: LadyKatranaPrestor.questTrueMasters, method: 2, maxLevel: 60, title: "The True Masters"};
    q.specialFlags = 0x2; // an event
    context.data.quests.quests[q.id] = q;

    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 40);
    hero.read();
    CreatureSpawn spawn = {guid: 90030, entry: katrana, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto her = context.makeCreature(&spawn);
    map.addObject(her);
    hero.read();

    hero.session.inWorld.addQuest(context.data.quests.quests[q.id]);
    hero.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(her.guid));
    auto menu = hero.read();
    assert(opcodesOf(menu) == [Opcode.SMSG_GOSSIP_MESSAGE]);
    // Its text is the script's (2693), its one option the script's.
    assert(menu[0].body_[8 .. 12] == [0x85, 0x0A, 0, 0] && menu[0].body_[12] == 1);
    foreach (step; 0 .. 3)
    {
        hero.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(her.guid, 0));
        assert(opcodesOf(hero.read()).canFind(Opcode.SMSG_GOSSIP_MESSAGE));
    }
    assert(hero.session.character.questStatus[q.id].status == QuestState.complete, "her advice heard");
    // Done: her usual menu again (here: her quest giver's).
    hero.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(her.guid));
    assert(hero.read().length > 0);
}

/// A script's signal to a creature another node simulates: sent there, applied once though it is resent.
unittest
{
    import dmangos.cluster.protocol : ScriptSignal;
    import dmangos.script.api : CreatureContext, EntityRef, Signal;
    import dmangos.script.registry : describe, ScriptKind;
    import dmangos.world.replication : encodeState, Replica;

    static struct SignalCounter
    {
        uint count;

        void on(ref CreatureContext me, const ref Signal e)
        {
            me.npcFlags(++count);
        }
    }

    auto db = newDatabase();
    auto here = newCreationContext(db), there = newCreationContext(db);
    here.nodeId = 1;
    there.nodeId = 2;
    there.scripts.add(describe!(SignalCounter, ScriptKind.creature)("npc_signal_counter"));
    there.data.creatureScriptNames[creatureInnkeeper] = "npc_signal_counter";
    ScriptSignal[] sent;
    ushort sentTo;
    here.signalElsewhere = (ushort node, const ref ScriptSignal m) { sentTo = node; sent ~= m; };

    const at = Position(-8949.95f, -132.49f, 83.53f);
    CreatureSpawn spawn = {guid: 90040, entry: creatureInnkeeper, map: mapEasternKingdoms, x: at.x, y: at.y, z: at.z};
    auto creature = there.makeCreature(&spawn);
    auto thereMap = there.map(mapEasternKingdoms);
    thereMap.addObject(creature);
    auto hereMap = here.map(mapEasternKingdoms);
    hereMap.replicaCreated(owner: 2, cell: cellKeyAt(at.x, at.y), guid: creature.guid, encodeState(creature, 0));

    assert(here.signalCreature(hereMap, EntityRef(7), EntityRef(creature.guid), 5, 1) == ActionResult.ok);
    assert(sentTo == 2 && sent.length == 1 && sent[0].to == creature.guid && sent[0].origin == 1);
    there.scriptSignalArrived(sent[0]);
    there.scriptSignalArrived(sent[0]); // resent after a reconnect
    assert(creature.values.get!UNIT_NPC_FLAGS == 1, "applied once");
    here.signalCreature(hereMap, EntityRef(7), EntityRef(creature.guid), 5, 1);
    there.scriptSignalArrived(sent[1]);
    assert(creature.values.get!UNIT_NPC_FLAGS == 2, "the next one too");
    assert(here.signalCreature(hereMap, EntityRef(7), EntityRef(12345), 5, 1) == ActionResult.notHere);
}

/// Curse of Agony (`spell_curse_of_agony`): its ticks on a creature ramp up, half, whole, half again.
unittest
{
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.spells : SpellInfo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto agony = SpellInfo(980);
    agony.effect[0] = SpellEffect.applyAura; // an aura
    agony.casting.applyAuraName[0] = AuraType.periodicDamage;
    agony.casting.amplitude[0] = 2000;
    agony.casting.school = 1; // holy here: no resistance roll in the test
    context.data.spells.spells[980] = agony;
    context.data.spellScriptNames[980] = "spell_curse_of_agony";

    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto warlock = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceOrc, mapEasternKingdoms, 10);
    warlock.read();
    CreatureSpawn spawn = {guid: 90050, entry: creatureInnkeeper, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto victim = context.makeCreature(&spawn);
    map.addObject(victim);
    victim.values.set!UNIT_FIELD_MAXHEALTH(10_000u);
    victim.values.set!UNIT_FIELD_HEALTH(10_000u);

    auto aura = makeAura((980 in context.data.spells.spells), warlock.session.character.guid, 10, 24_000, false, [10, 0, 0]);
    uint[] dealt;
    foreach (tick; 1 .. 13)
    {
        aura.duration = 24_000 - tick * 2000;
        const before = victim.values.get!UNIT_FIELD_HEALTH;
        warlock.session.inWorld.auraTick(victim, aura, 0);
        dealt ~= before - victim.values.get!UNIT_FIELD_HEALTH;
    }
    assert(dealt == [5, 5, 5, 5, 10, 10, 10, 10, 15, 15, 15, 15], "a ramp");
}

/// Hate to Zero (`spell_hate_to_zero`), a creature's spell: its target's threat on it is gone.
unittest
{
    import dmangos.world.spells : SpellInfo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto hate = SpellInfo(9204);
    hate.effect[0] = SpellEffect.dummy; // dummy
    context.data.spells.spells[9204] = hate;
    context.data.spellScriptNames[9204] = "spell_hate_to_zero";

    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    hero.read();
    CreatureSpawn spawn = {guid: 90060, entry: creatureInnkeeper, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto boss = context.makeCreature(&spawn);
    map.addObject(boss);
    boss.ai.attackedBy(hero.session.inWorld.unit, map);
    boss.ai.damageTaken(hero.session.inWorld.unit, 50);
    const guid = hero.session.character.guid;
    assert(boss.ai.threatOf(guid) > 0);
    boss.ai.spellEffectScript((9204 in context.data.spells.spells), 0, guid, 0);
    assert(boss.ai.threatOf(guid) == 0, "its hate gone");
}

/**
 * Shadowfang Keep's prisoners (here in the test world's dungeon): no help before Rethilgore falls;
 * then Deathstalker Adamant offers to open the courtyard, walks there, opens its door, and leaves.
 */
unittest
{
    import dmangos.script.api : Location, Waypoint;
    import dmangos.scripts.shadowfang : adamant, courtyardDoor, rethilgore;
    import dmangos.world.packets : ClientGossipSelectOption, ClientNpcGuid;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const doorAt = Position(-10, -383, 61), prisonerAt = Position(-20, -383, 61), guardAt = Position(-25, -383, 61);
    auto door = GameObjectTemplate.init;
    door.entry = courtyardDoor;
    door.displayId = 411;
    door.name = "Courtyard Door";
    context.data.gameObjectTemplates[courtyardDoor] = door;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90070, courtyardDoor, mapDeadmines, doorAt.x, doorAt.y, doorAt.z);
    context.data.gameObjectCells[mapDeadmines][cellKeyAt(doorAt.x, doorAt.y)] ~= context.data.gameObjectSpawns.length - 1;
    static struct Who { uint entry; Position at; uint guid, flags; }
    foreach (w; [Who(adamant, prisonerAt, 90071, 1), Who(rethilgore, guardAt, 90072, 0)])
    {
        const entry = w.entry, at = w.at, guid = w.guid, flags = w.flags;
        auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
        t.entry = entry;
        t.npcFlags = flags;
        context.data.creatureTemplates[entry] = t;
        context.data.creatureSpawns ~= CreatureSpawn(guid, entry, mapDeadmines, at.x, at.y, at.z);
        context.data.creatureCells[mapDeadmines][cellKeyAt(at.x, at.y)] ~= context.data.creatureSpawns.length - 1;
    }
    context.data.creatureScriptNames[adamant] = "npc_shadowfang_prisoner";
    context.data.instanceScriptNames[mapDeadmines] = "instance_shadowfang_keep";
    context.data.escortPaths[adamant] = [Waypoint(Location(-15, -383, 61)), Waypoint(Location(-11, -383, 61))];

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -18 -381 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.read();
    auto map = context.instanceMap(hero.session.inWorld.instanceId);
    auto prisoner = cast(Creature) map.findObject(makeCreatureGuid(adamant, 90071));
    auto guard = cast(Creature) map.findObject(makeCreatureGuid(rethilgore, 90072));
    auto courtyard = cast(GameObject) map.findObject(makeDoorGuid(courtyardDoor, 90070));
    assert(prisoner !is null && guard !is null && courtyard !is null && courtyard.goState == 1);

    size_t options()
    {
        hero.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(prisoner.guid));
        const menu = hero.read();
        foreach (p; menu)
            if (p.opcode == Opcode.SMSG_GOSSIP_MESSAGE)
                return p.body_[12];
        return 0;
    }

    assert(options == 0, "locked in while Rethilgore lives");
    guard.die(map, context.unixTime);
    context.creatureDied(guard);
    assert(options == 1, "free: he offers to open the courtyard");
    hero.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(prisoner.guid, 0));
    foreach (_; 0 .. 80)
    {
        now += 250.msecs;
        context.update(now);
    }
    assert(courtyard.goState == 0, "the courtyard door is open");
    assert(map.findObject(prisoner.guid) is null, "and he is gone");
}

/**
 * The Disciple of Naralex (here in the test world's dungeon): silent until the four Fanglords are
 * slain; then he leads the way (two ambushes), performs the ritual at Naralex (three waves, Mutanus
 * last), and with Mutanus dead Naralex wakes and both go.
 */
unittest
{
    import dmangos.script.api : Location, Waypoint;
    import dmangos.scripts.wailingcaverns;
    import dmangos.world.packets : ClientGossipSelectOption, ClientNpcGuid;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const start = Position(-40, -383, 61);
    static struct Who { uint entry; float x; uint guid, flags; }
    uint nextGuid = 90100;
    foreach (w; [Who(disciple, start.x, 0, 1), Who(naralex, start.x + 36, 0, 0), Who(cobrahn, start.x - 10, 0, 0),
            Who(pythas, start.x - 11, 0, 0), Who(anacondra, start.x - 12, 0, 0), Who(serpentis, start.x - 13, 0, 0)])
    {
        auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
        t.entry = w.entry;
        t.npcFlags = w.flags;
        if (w.entry == disciple) // as the database has him: immune to players (no ambusher's ally in a fight with them)
            t.unitFlags |= 0x100;
        context.data.creatureTemplates[w.entry] = t;
        context.data.creatureSpawns ~= CreatureSpawn(nextGuid++, w.entry, mapDeadmines, w.x, start.y, start.z);
        context.data.creatureCells[mapDeadmines][cellKeyAt(w.x, start.y)] ~= context.data.creatureSpawns.length - 1;
    }
    foreach (entry; [ravager, viper, moccasin, ectoplasm, mutanus])
    {
        auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
        t.entry = entry;
        context.data.creatureTemplates[entry] = t;
    }
    context.data.creatureScriptNames[disciple] = "npc_disciple_of_naralex";
    context.data.instanceScriptNames[mapDeadmines] = "instance_wailing_caverns";
    Waypoint[] path;
    foreach (i; 0 .. 72)
        path ~= Waypoint(Location(start.x + 0.5f * (i + 1), start.y, start.z));
    context.data.escortPaths[disciple] = path;

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -38 -382 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.say(".cheat god");
    hero.read();
    auto map = context.instanceMap(hero.session.inWorld.instanceId);
    Creature find(uint entry)
    {
        foreach (c; map.creaturesNear(Position(start.x + 20, start.y, start.z), 80))
            if (c.spawn.entry == entry && c.alive)
                return c;
        return null;
    }
    size_t count(uint entry)
    {
        size_t n;
        foreach (c; map.creaturesNear(Position(start.x + 20, start.y, start.z), 80))
            n += c.spawn.entry == entry && c.alive;
        return n;
    }
    void run(int seconds)
    {
        foreach (_; 0 .. seconds * 4)
        {
            now += 250.msecs;
            context.update(now);
        }
    }

    auto guide = find(disciple);
    assert(guide !is null && find(naralex) !is null);
    size_t options()
    {
        hero.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(guide.guid));
        foreach (p; hero.read())
            if (p.opcode == Opcode.SMSG_GOSSIP_MESSAGE)
                return p.body_[12];
        return 0;
    }

    assert(options == 0, "the Fanglords live");
    foreach (lord; [cobrahn, pythas, anacondra, serpentis])
    {
        auto c = find(lord);
        c.die(map, context.unixTime);
        context.creatureDied(c);
    }
    assert(options == 1, "the event may begin");
    hero.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(guide.guid, 0));
    run(10);
    assert(count(ravager) == 2, "the first ambush");
    run(10);
    assert(count(viper) == 3, "the second");
    run(30);
    assert(count(moccasin) == 3, "the ritual: the first nightmares");
    run(35);
    assert(count(ectoplasm) == 5);
    run(35);
    auto devourer = find(mutanus);
    assert(devourer !is null, "Mutanus");
    devourer.die(map, context.unixTime);
    context.creatureDied(devourer);
    run(25);
    assert(find(naralex) is null && find(disciple) is null, "awake, and gone");
    const saved = db.loadInstances().instances;
    assert(saved.length == 1 && saved[0].data.length > 30, "the caverns remember");
}

/**
 * Kalimdor scripts in the world (`npc_twiggy_flathead`, `npc_mist`): summons made friendly, one set
 * on the player with a hostile faction, its death told to its summoner (the next comes sooner); a
 * follower following its player; an item given.
 */
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.script.api : EntityRef;
    import dmangos.scripts.barrens : TwiggyFlathead;
    import dmangos.scripts.teldrassil : Mist;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.motion : FollowMovement;
    import dmangos.world.quests : Quest, QuestState;
    import dmangos.world.teleport : moveTo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint mist = 3568;
    foreach (entry; [TwiggyFlathead.twiggy, TwiggyFlathead.challenger, TwiggyFlathead.bigWill, mist])
    {
        auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
        t.entry = entry;
        context.data.creatureTemplates[entry] = t;
    }
    context.data.creatureScriptNames[TwiggyFlathead.twiggy] = "npc_twiggy_flathead";
    context.data.creatureScriptNames[mist] = "npc_mist";
    (cast() context.data.creatureTemplates[mist]).npcFlags = 2; // a quest giver
    Quest q = {id: Mist.questMist, method: 2, maxLevel: 60, title: "Mist"};
    q.specialFlags = 0x2;
    context.data.quests.quests[q.id] = q;
    context.data.quests.creatureStarts[mist] = [q.id];

    const at = Position(-1690, -4330, 2.79f); // by the arena (on the test world's one map)
    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 30);
    hero.read();
    enum uint players = 1, monsters = 8;
    const humans = hero.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0],
        [14u, 14, 0, monsters, 0, players, 0, 0, 0, 0, 0, 0, 0, 0],
        [35u, 35, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        [79u, 79, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    auto map = context.map(mapEasternKingdoms);
    void run(int ms)
    {
        for (; ms > 0; ms -= 250)
        {
            now += 250.msecs;
            context.update(now);
        }
    }

    // Twiggy: six challengers come, friendly; the first is set on the player.
    CreatureSpawn spawn = {guid: 90040, entry: TwiggyFlathead.twiggy, map: mapEasternKingdoms, x: at.x + 3, y: at.y, z: at.z};
    auto twiggy = context.makeCreature(&spawn);
    map.addObject(twiggy);
    twiggy.ai.signalled(EntityRef(hero.session.character.guid), TwiggyFlathead.signalStart, 0, map);
    run(1500);
    Creature[] challengers;
    foreach (c; map.creaturesNear(Position(-1680, -4330, 2.79f), 30)) // the arena's places
        if (c.spawn.entry == TwiggyFlathead.challenger)
            challengers ~= c;
    assert(challengers.length == 6, "the challengers come");
    foreach (c; challengers)
        assert(c.values.get!UNIT_FIELD_FACTIONTEMPLATE == 35 && c.summon.summoner == twiggy.guid);
    run(5000);
    Creature[] fighting()
    {
        Creature[] found;
        foreach (c; challengers)
            if (c.alive && c.ai.inCombat)
                found ~= c;
        return found;
    }
    assert(fighting.length == 1 && fighting[0].ai.currentVictim == hero.session.character.guid
        && fighting[0].values.get!UNIT_FIELD_FACTIONTEMPLATE == 14, "the first steps up");
    // It falls: Twiggy hears of it, and the next steps up fifteen seconds later (not twenty-five).
    fighting[0].die(map, context.unixTime);
    run(16_000);
    assert(fighting.length == 1, "the next, sooner");

    // Mist: her quest taken, she follows the player with her faction.
    CreatureSpawn mistSpawn = {guid: 90041, entry: mist, map: mapEasternKingdoms, x: at.x - 3, y: at.y, z: at.z};
    auto cub = context.makeCreature(&mistSpawn);
    map.addObject(cub);
    ByteWriter accept;
    accept.put(cub.guid);
    accept.put(q.id);
    hero.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    assert(hero.session.character.questStatus[q.id].status == QuestState.incomplete);
    assert(cast(FollowMovement) cub.generator !is null && cub.values.get!UNIT_FIELD_FACTIONTEMPLATE == 79);
    assert(cub.values.get!UNIT_NPC_FLAGS == 0, "nobody else takes her");
    // The player gone far away: she goes, and the quest fails.
    hero.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(at.x + 150, at.y, at.z)));
    run(2000);
    assert(hero.session.character.questStatus[q.id].status == QuestState.failed && map.findObject(cub.guid) is null);
}

/**
 * Dungeon scripts' own hooks in the world: Tuten'kash's gong (here in the test world's dungeon) is a
 * goober whose event reaches the copy's script; it summons the first wave on the one who rang it and
 * the gong cannot be rung again while the wave lives.
 */
unittest
{
    import dmangos.scripts.razorfendowns : gong, gongEvent, tombFiend;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const gongAt = Position(-16, -385, 61);
    auto t = GameObjectTemplate.init;
    t.entry = gong;
    t.type = 10; // a goober
    t.displayId = 411;
    t.name = "Gong";
    t.data[2] = gongEvent;
    context.data.gameObjectTemplates[gong] = t;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90200, gong, mapDeadmines, gongAt.x, gongAt.y, gongAt.z);
    context.data.gameObjectCells[mapDeadmines][cellKeyAt(gongAt.x, gongAt.y)] ~= context.data.gameObjectSpawns.length - 1;
    auto fiend = cast() context.data.creatureTemplates[creatureInnkeeper];
    fiend.entry = tombFiend;
    context.data.creatureTemplates[tombFiend] = fiend;
    context.data.instanceScriptNames[mapDeadmines] = "instance_razorfen_downs";

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -16 -383 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.read();
    auto map = context.instanceMap(hero.session.inWorld.instanceId);
    auto theGong = cast(GameObject) map.findObject(makeDoorGuid(gong, 90200));
    assert(theGong !is null);
    size_t fiends()
    {
        size_t n;
        foreach (c; map.creaturesNear(Position(2500, 850, 45), 200))
            n += c.spawn.entry == tombFiend && c.alive;
        return n;
    }

    hero.session.inWorld.useGameObject(theGong);
    assert(fiends == 8, "the first wave");
    assert(theGong.values.get!GAMEOBJECT_FLAGS & 0x10, "the gong is silent while they live");
}

/**
 * A dungeon script's own timer and its actions on the copy's creatures, in the world: the Altar of
 * the Keepers (here in the test world's dungeon) is used; five seconds later the first Stone Keeper
 * is woken by the copy's script and attacks the one who used it.
 */
unittest
{
    import dmangos.scripts.uldaman : keepersAltar, stoneKeeper;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const at = Position(-20, -383, 61);
    auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
    t.entry = stoneKeeper;
    t.npcFlags = 0;
    context.data.creatureTemplates[stoneKeeper] = t;
    context.data.creatureSpawns ~= CreatureSpawn(90300, stoneKeeper, mapDeadmines, at.x, at.y, at.z);
    context.data.creatureCells[mapDeadmines][cellKeyAt(at.x, at.y)] ~= context.data.creatureSpawns.length - 1;
    context.data.instanceScriptNames[mapDeadmines] = "instance_uldaman";

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -16 -383 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.say(".cheat god");
    hero.read();
    auto map = context.instanceMap(hero.session.inWorld.instanceId);
    auto keeper = cast(Creature) map.findObject(makeCreatureGuid(stoneKeeper, 90300));
    assert(keeper !is null && !keeper.ai.inCombat);

    context.scriptedEvent(keepersAltar, map, hero.session.character.guid, 0);
    foreach (_; 0 .. 12) // three seconds: not yet
    {
        now += 250.msecs;
        context.update(now);
    }
    assert(!keeper.ai.inCombat);
    foreach (_; 0 .. 12)
    {
        now += 250.msecs;
        context.update(now);
    }
    assert(keeper.ai.inCombat, "the keeper wakes and attacks");
}

/**
 * Signals between a dungeon's script and its objects' scripts, in the world: a Fire of Aku'mai (here
 * in the test world's dungeon) cannot be lit while Kelris lives; his death is told to the fire by the
 * copy's script, and lit then, it calls the first wave.
 */
unittest
{
    import dmangos.scripts.blackfathomdeeps : akumaiSnapjaw, kelris, shrine1;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const fireAt = Position(-16, -385, 61), kelrisAt = Position(-24, -383, 61);
    auto fire = GameObjectTemplate.init;
    fire.entry = shrine1;
    fire.type = 1; // a button
    fire.displayId = 411;
    fire.name = "Fire of Aku'mai";
    context.data.gameObjectTemplates[shrine1] = fire;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90400, shrine1, mapDeadmines, fireAt.x, fireAt.y, fireAt.z);
    context.data.gameObjectCells[mapDeadmines][cellKeyAt(fireAt.x, fireAt.y)] ~= context.data.gameObjectSpawns.length - 1;
    context.data.gameObjectScriptNames[shrine1] = "go_fire_of_akumai";
    foreach (entry; [kelris, akumaiSnapjaw])
    {
        auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
        t.entry = entry;
        t.npcFlags = 0;
        context.data.creatureTemplates[entry] = t;
    }
    context.data.creatureSpawns ~= CreatureSpawn(90401, kelris, mapDeadmines, kelrisAt.x, kelrisAt.y, kelrisAt.z);
    context.data.creatureCells[mapDeadmines][cellKeyAt(kelrisAt.x, kelrisAt.y)] ~= context.data.creatureSpawns.length - 1;
    context.data.instanceScriptNames[mapDeadmines] = "instance_blackfathom_deeps";

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -16 -383 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.say(".cheat god");
    hero.read();
    auto map = context.instanceMap(hero.session.inWorld.instanceId);
    auto theFire = cast(GameObject) map.findObject(makeDoorGuid(shrine1, 90400));
    auto boss = cast(Creature) map.findObject(makeCreatureGuid(kelris, 90401));
    assert(theFire !is null && boss !is null && theFire.goState == 1);
    size_t snapjaws()
    {
        size_t n;
        foreach (c; map.creaturesNear(Position(-818, -160, -26), 100))
            n += c.spawn.entry == akumaiSnapjaw && c.alive;
        return n;
    }
    void run(int seconds)
    {
        foreach (_; 0 .. seconds * 4)
        {
            now += 250.msecs;
            context.update(now);
        }
    }

    hero.session.inWorld.useGameObject(theFire);
    run(5);
    assert(theFire.goState == 1 && snapjaws == 0, "not while Kelris lives");
    boss.die(map, context.unixTime);
    context.creatureDied(boss);
    hero.session.inWorld.useGameObject(theFire);
    run(5);
    assert(theFire.goState == 0 && snapjaws == 3, "lit: the first wave comes");
}

/**
 * A dungeon script hears its creatures' fights, in the world: Kirtonos the Herald (here in the test
 * world's dungeon) attacked, his gate shuts; he gives up, and it opens again.
 */
unittest
{
    import dmangos.scripts.scholomance : gateKirtonos, kirtonos;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const gateAt = Position(-16, -385, 61), bossAt = Position(-20, -383, 61);
    auto gate = GameObjectTemplate.init;
    gate.entry = gateKirtonos;
    gate.displayId = 411;
    gate.name = "Gate";
    gate.data[0] = 1; // open until a fight shuts it
    context.data.gameObjectTemplates[gateKirtonos] = gate;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90500, gateKirtonos, mapDeadmines, gateAt.x, gateAt.y, gateAt.z);
    context.data.gameObjectCells[mapDeadmines][cellKeyAt(gateAt.x, gateAt.y)] ~= context.data.gameObjectSpawns.length - 1;
    auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
    t.entry = kirtonos;
    t.npcFlags = 0;
    context.data.creatureTemplates[kirtonos] = t;
    context.data.creatureSpawns ~= CreatureSpawn(90501, kirtonos, mapDeadmines, bossAt.x, bossAt.y, bossAt.z);
    context.data.creatureCells[mapDeadmines][cellKeyAt(bossAt.x, bossAt.y)] ~= context.data.creatureSpawns.length - 1;
    context.data.instanceScriptNames[mapDeadmines] = "instance_scholomance";

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -16 -383 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.read();
    auto map = context.instanceMap(hero.session.inWorld.instanceId);
    auto theGate = cast(GameObject) map.findObject(makeDoorGuid(gateKirtonos, 90500));
    auto boss = cast(Creature) map.findObject(makeCreatureGuid(kirtonos, 90501));
    assert(theGate !is null && boss !is null);
    boss.ai.attackedBy(hero.session.inWorld.unit, map);
    assert(boss.ai.inCombat && theGate.goState == 1, "the fight shuts the gate");
    // The fight given up (as `enterEvadeMode` tells it).
    import dmangos.script.api : EntityRef;

    context.dungeonFight(map.instanceId, EntityRef(boss.guid), EntityRef.init);
    assert(theGate.goState == 0, "given up: open again");
}

/**
 * A raid's copy script in the real world (Molten Core's, here on the test world's dungeon): a player
 * entering is told to it; the runes doused, Majordomo and his eight guards are summoned onto the copy's
 * map (each summon told to the script as it loads), and the copy answers its creatures' questions.
 */
unittest
{
    import dmangos.script.api : EncounterState, EntityRef;
    import dmangos.scripts.moltencore;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    foreach (entry; [npcMajordomo, npcFlamewakerHealer, npcFlamewakerElite])
    {
        auto t = cast() context.data.creatureTemplates[creatureInnkeeper];
        t.entry = entry;
        context.data.creatureTemplates[entry] = t;
    }
    context.data.creatureScriptNames[npcMajordomo] = "boss_majordomo";
    context.data.instanceScriptNames[mapDeadmines] = "instance_molten_core";

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -16 -380 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    const copy = hero.session.inWorld.instanceId;
    auto map = context.instanceMap(copy);
    size_t count(uint entry)
    {
        size_t n;
        map.forEachObject((o) {
            if (auto c = cast(Creature) o)
                n += c.spawn.entry == entry && c.alive;
        });
        return n;
    }

    assert(count(npcMajordomo) == 0, "the runes burn");
    foreach (which; Encounter.magmadar .. Encounter.majordomo)
    {
        context.signalDungeon(copy, EntityRef.init, which, EncounterState.done);
        context.signalDungeon(copy, EntityRef.init, which, EncounterState.special);
    }
    assert(count(npcMajordomo) == 1 && count(npcFlamewakerHealer) == 4 && count(npcFlamewakerElite) == 4);
    assert(context.askDungeon(copy, EntityRef.init, Encounter.sulfuron) == EncounterState.special);
    foreach (_; 0 .. 8)
    {
        now += 250.msecs;
        context.update(now);
    }
    assert(count(npcMajordomo) == 1, "summoned once");
}

/// Instance round 2: a creature's SEND_EVENT spell starts its event as a player's does: the event's script runs,
/// around the player it was cast at (`event_test_summon` puts a creature beside them).
unittest
{
    import dmangos.world.map : MapObject;
    import dmangos.world.spells : SpellInfo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto call = SpellInfo(99_001);
    call.effect[0] = SpellEffect.sendEvent;
    call.implicitTargetA[0] = ImplicitTarget.enemy;
    call.miscValue[0] = 7777;
    context.data.spells.spells[99_001] = call;
    context.data.eventScriptNames[7777] = "event_test_summon";

    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    hero.read();
    CreatureSpawn spawn = {guid: 90090, entry: creatureInnkeeper, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto caller = context.makeCreature(&spawn);
    map.addObject(caller);
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
    const before = trainers();
    assert(caller.ai.castFor(map, 99_001, hero.session.character.guid, true) == ActionResult.ok);
    assert(trainers() == before + 1, "the event's script ran");
}

/// Instance round 2: a creature's script hears its aura go when it runs out (`AuraRemoved`).
unittest
{
    import dmangos.world.auras : makeAura;
    import dmangos.world.map : MapObject;
    import dmangos.world.spells : SpellInfo;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto mark = SpellInfo(99_002);
    mark.effect[0] = SpellEffect.applyAura;
    context.data.spells.spells[99_002] = mark;
    context.data.creatureScriptNames[creatureInnkeeper] = "npc_test_aura_removed";

    const at = Position(-8949.95f, -132.49f, 83.53f);
    CreatureSpawn spawn = {guid: 90091, entry: creatureInnkeeper, map: mapEasternKingdoms, x: at.x, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto marked = context.makeCreature(&spawn);
    map.addObject(marked);
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
    const before = trainers();
    bool isNew;
    marked.auras.apply(makeAura(99_002 in context.data.spells.spells, 7, 10, 100, false, [0, 0, 0]), marked.values, isNew);
    marked.updateAuras(map, 50);
    assert(trainers() == before, "still on");
    marked.updateAuras(map, 100);
    assert(marked.auras.find(99_002) is null && trainers() == before + 1, "it ran out, and the script heard");
}
