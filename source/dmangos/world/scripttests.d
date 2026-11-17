/**
 * The scripts in the world (docs/SCRIPTING.md): Mr. Smite's fight driven by the real creature AI,
 * his script's state carried to another node with him, and the Deadmines' dungeon script opening a
 * door when its guardian falls, saved in `instance.data` and read back after a restart.
 */
module dmangos.world.scripttests;

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

/// Mr. Smite's phases, by the real AI; his state goes with him to another node; it goes when he does.
unittest
{
    import dmangos.scripts.deadmines : MrSmite, mrSmite;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    // The test world's innkeeper plays Mr. Smite; his two weapons are items the test world has.
    auto smiteTemplate = context.data.creatureTemplates[creatureInnkeeper];
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
        smite.ai.attackedBy(hero.session, map);
        smite.ai.damageTaken(hero.session, damage);
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
    moved.ai.damageTaken(hero.session, movedMax * 10 / 100);
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
        auto guard = context.data.creatureTemplates[creatureInnkeeper];
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
    const copy = hero.session.instanceId;
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
    assert(back.session.instanceId == copy);
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
    const copy = hero.session.instanceId;
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
    auto smite = context.data.creatureTemplates[creatureInnkeeper];
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
    auto map = context.instanceMap(hero.session.instanceId);
    auto cannon = cast(GameObject) map.findObject(makeDoorGuid(cannonEntry, 90010));
    auto door = cast(GameObject) map.findObject(makeDoorGuid(ironCladDoor, 90011));
    assert(cannon !is null && cannon.behaviour && door.goState == 1);
    hero.session.useGameObject(cannon);
    assert(door.goState == 0, "blown open");
    const heard = hero.read();
    assert(opcodesOf(heard).canFind(Opcode.SMSG_MESSAGECHAT), "the alarm");
    // Gone with its map: the cannon's script is freed with it.
    const live = context.scripts.liveScripts;
    hero.say(format(".instance shutdown %s", hero.session.instanceId));
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
    auto traitor = context.data.creatureTemplates[creatureInnkeeper];
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
