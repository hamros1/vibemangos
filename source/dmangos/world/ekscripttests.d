/**
 * The Eastern Kingdoms scripts in the world, with the real creature AI: an escort that stops for an
 * ambush until its summoned ambushers are dead (`SummonedDied`), and a creature that fights a player
 * on a quest until it gives up (its faction, death prevention and evading).
 */
module dmangos.world.ekscripttests;

version (unittest):

import core.time : MonoTime, msecs;

import dmangos.auth.accounts : AccountLevel;
import dmangos.bytes : ByteWriter;
import dmangos.script.api : Location, Waypoint;
import dmangos.world.creature : Creature, CreatureSpawn;
import dmangos.world.movement : Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.quests : Quest, QuestState;
import dmangos.world.testclient;
import dmangos.world.testdata;
import dmangos.world.updatefields;

/// Miran: walks, stops for the Dark Iron ambush, goes on when both raiders are dead, and completes the quest.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint miranEntry = 1379, raiderEntry = 2149, quest = 309;
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto miran = cast() context.data.creatureTemplates[creatureInnkeeper];
    miran.entry = miranEntry;
    miran.npcFlags = 2;
    context.data.creatureTemplates[miranEntry] = miran;
    auto raider = cast() context.data.creatureTemplates[creatureInnkeeper];
    raider.entry = raiderEntry;
    raider.npcFlags = 0;
    context.data.creatureTemplates[raiderEntry] = raider;
    context.data.creatureScriptNames[miranEntry] = "npc_miran";
    Waypoint[] path;
    foreach (i; 0 .. 24)
        path ~= Waypoint(Location(at.x + 4 + (i % 2) * 2, at.y + (i % 3) * 2, at.z));
    context.data.escortPaths[miranEntry] = path;
    Quest q = {id: quest, method: 2, maxLevel: 60, title: "Protecting the Shipment"};
    q.specialFlags = 0x2;
    context.data.quests.quests[quest] = q;
    context.data.quests.creatureStarts[miranEntry] = [quest];

    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 20);
    hero.read();
    CreatureSpawn spawn = {guid: 90030, entry: miranEntry, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto him = context.makeCreature(&spawn);
    map.addObject(him);

    void run(int ticks)
    {
        foreach (_; 0 .. ticks)
        {
            now += 250.msecs;
            context.update(now);
        }
    }

    Creature[] raiders()
    {
        Creature[] found;
        foreach (c; map.creaturesNear(Position(-5700, -3736, 318), 50)) // the ambush's spot, in Loch Modan
            if (c.spawn.entry == raiderEntry && c.alive)
                found ~= c;
        return found;
    }

    ByteWriter accept;
    accept.put(him.guid);
    accept.put(quest);
    hero.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    assert(hero.session.character.questStatus[quest].status == QuestState.incomplete);
    run(120);
    auto ambush = raiders();
    assert(ambush.length == 2, "the ambush came");
    assert(ambush[0].summon.summoner == him.guid);
    run(40);
    assert(hero.session.character.questStatus[quest].status == QuestState.incomplete, "he waits for the raiders");
    foreach (r; ambush)
        map.unitOf(r).spellHitBy(0, r.values.get!UNIT_FIELD_HEALTH);
    assert(raiders().length == 0);
    run(120);
    assert(hero.session.character.questStatus[quest].status == QuestState.complete, "on to the end");
}

/// Bartleby: taken on his quest he turns hostile and fights; below 15% he cannot die, gives up and is friendly again.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint bartlebyEntry = 6090, quest = 1640;
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto bartleby = cast() context.data.creatureTemplates[creatureInnkeeper];
    bartleby.entry = bartlebyEntry;
    bartleby.npcFlags = 2;
    context.data.creatureTemplates[bartlebyEntry] = bartleby;
    context.data.creatureScriptNames[bartlebyEntry] = "npc_bartleby";
    Quest q = {id: quest, method: 2, maxLevel: 60, title: "Beat Bartleby"};
    q.specialFlags = 0x2;
    context.data.quests.quests[quest] = q;
    context.data.quests.creatureStarts[bartlebyEntry] = [quest];

    auto hero = loggedIn(context, db, 7, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 20);
    hero.read();
    CreatureSpawn spawn = {guid: 90031, entry: bartlebyEntry, map: mapEasternKingdoms, x: at.x + 2, y: at.y, z: at.z};
    auto map = context.map(mapEasternKingdoms);
    auto him = context.makeCreature(&spawn);
    map.addObject(him);
    const faction = him.values.get!UNIT_FIELD_FACTIONTEMPLATE;

    ByteWriter accept;
    accept.put(him.guid);
    accept.put(quest);
    hero.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    assert(him.values.get!UNIT_FIELD_FACTIONTEMPLATE == 168 && him.ai.inCombat, "he turns on the player");
    const max = him.values.get!UNIT_FIELD_MAXHEALTH;
    auto player = hero.session.inWorld.unit;
    him.ai.damageTaken(player, max * 9 / 10);
    him.values.set!UNIT_FIELD_HEALTH(max / 10);
    assert(hero.session.character.questStatus[quest].status == QuestState.complete, "beaten");
    assert(him.values.get!UNIT_FIELD_FACTIONTEMPLATE == faction && !him.ai.inCombat, "friendly again");
    assert(him.alive);
}
