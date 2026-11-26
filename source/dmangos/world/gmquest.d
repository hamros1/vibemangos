/**
 * The quest commands this server's quests support: `.quest status`, `.quest start`,
 * `.quest complete` (`handleQuestFinishCommand`), `.quest remove`, `.quest giver`,
 * `.quest finisher`, `.quest spawn` and `.quest reward`. Quest givers are read from
 * `creature_questrelation`, finishers from `creature_involvedrelation`, the game object ones
 * likewise, and spawns from `creature`.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmquest;

import dmangos.world.character : Character;
import dmangos.world.gmstaff : itemLink;

import std.algorithm.searching : canFind;
import std.format : format;
import dmangos.world.commands;
import dmangos.world.creature : Creature;
import dmangos.world.npchandlers : NpcFlag;
import dmangos.world.opcodes : Opcode;
import dmangos.world.quests : Quest, QuestState, maxQuestLogSize, questXp;
import dmangos.world.updatefields : PLAYER_QUEST_LOG_1_1, UNIT_FIELD_TARGET, UNIT_NPC_FLAGS;


/// `.quest load`: the quest catalog read again from the world database.
bool handleQuestLoadCommand(Character gm)
{
    import dmangos.mysql : DatabaseException;

    try
    {
        auto catalog = gm.context.canWrite() ? gm.context.database.reloadQuestCatalog() : null;
        if (catalog is null)
        {
            gm.redSystemMessage("The quest catalog could not be reloaded.");
            return true;
        }
        gm.context.data.quests = catalog;
        gm.gmLog(format!"reloaded %s quest definitions"(catalog.quests.length));
        gm.greenSystemMessage(format!"Reloaded %s quests. Other workers will refresh automatically."
            (catalog.quests.length));
    }
    catch (DatabaseException)
        gm.redSystemMessage("The world database could not reload the quest catalog.");
    return true;
}

/// The selected player, else the GM itself ("Targeting yourself.").
auto questTarget(Character gm)
{
    auto target = gm.selectedCharacter(true);
    if (target is null)
    {
        target = gm;
        gm.systemMessage("Targeting yourself.");
    }
    return target;
}

/// The quest `questId`; null after "Quest ... was not found.".
const(Quest)* knownQuest(Character gm, uint questId)
{
    const quest = gm.context.data.quests.quest(questId);
    if (quest is null)
        gm.redSystemMessage(format!"Quest %s was not found."(questId));
    return quest;
}

/// Whether `character` has finished (been rewarded for) the quest `id`.
bool finished(Character character, uint id)
{
    const status = id in character.player.questStatus;
    return status !is null && status.rewarded;
}

/// Whether the quest `id` is in `character`'s log.
bool onQuest(Character character, uint id)
{
    return character.questSlot(id) < maxQuestLogSize;
}

/// The lowest entry of `relations` that has the quest; 0 if none.
uint lowestEntryWith(const uint[][uint] relations, uint questId)
{
    uint lowest;
    foreach (entry, quests; relations)
        if (quests.canFind(questId) && (!lowest || entry < lowest))
            lowest = entry;
    return lowest;
}

/// `.quest status`: whether the target has finished the quest, is on it, or neither.
bool handleQuestStatusCommand(Character gm, uint questId = 0)
{
    if (questId == 0)
        return false;
    auto target = gm.questTarget();
    if (gm.knownQuest(questId) is null)
        return true;
    if (finished(target, questId))
        gm.systemMessage("Player has already completed that quest.");
    else if (onQuest(target, questId))
        gm.systemMessage("Player is currently on that quest.");
    else
        gm.systemMessage("Player has not finished that quest.");
    return true;
}

/// `.quest start`: the quest put in the target's log, with its source item.
bool handleQuestStartCommand(Character gm, uint questId = 0)
{
    if (questId == 0)
        return false;
    auto target = gm.questTarget();
    const quest = gm.knownQuest(questId);
    if (quest is null)
        return true;
    if (finished(target, questId))
        gm.redSystemMessage("Player has already completed that quest.");
    else if (onQuest(target, questId))
        gm.redSystemMessage("Player is currently on that quest.");
    else if (target.questSlot(0) >= maxQuestLogSize)
    {
        target.deliver(Opcode.SMSG_QUESTLOG_FULL, null);
        gm.redSystemMessage("Player's quest log is full.");
    }
    else
    {
        gm.gmLog(format!"started quest %u [%s] for player %s"(quest.id, quest.title, target.player.data.name));
        target.addQuest(*quest); // its source item with it
        target.flushInventory(true);
        target.flushPlayerChanges();
        gm.greenSystemMessage("Quest has been added to the player's quest log.");
    }
    return true;
}

/// `.quest complete`: the quest finished and rewarded for the target; one in the log also gives its
/// experience, and its giver's reputation if one stands on the map.
bool handleQuestFinishCommand(Character gm, uint questId = 0)
{
    if (questId == 0)
        return false;
    auto target = gm.questTarget();
    const quest = gm.knownQuest(questId);
    if (quest is null)
        return true;
    if (finished(target, questId))
    {
        gm.redSystemMessage("Player has already completed that quest.");
        return true;
    }
    string feedback = "The quest has now been completed for that player.";
    if (onQuest(target, questId))
    {
        // The quest's giver: a creature (else a game object) that starts it, and one of its entry on the map.
        uint giverId = lowestEntryWith(gm.context.data.quests.creatureStarts, questId);
        if (!giverId)
            giverId = lowestEntryWith(gm.context.data.quests.gameObjectStarts, questId);
        if (giverId == 0)
            gm.redSystemMessage("Unable to find quest giver creature or object.");
        else if (target.map.creaturesNear(target.player.position, 100_000)
            .canFind!(creature => creature.template_.entry == giverId))
        {
            gm.greenSystemMessage("Found a quest_giver creature.");
            target.rewardQuestReputation(*quest);
        }
        else
            gm.redSystemMessage("Unable to find quest_giver object.");
        target.gmFinishQuest(*quest);
        feedback = "Player was on that quest, but has now completed it.";
    }
    gm.gmLog(format!"completed quest %u [%s] for player %s"(questId, quest.title, target.player.data.name));
    target.markQuestFinished(questId);
    gm.greenSystemMessage(feedback);
    return true;
}

/// `.quest remove`: the quest taken out of the target's log.
bool handleQuestRemoveCommand(Character gm, uint questId = 0)
{
    if (questId == 0)
        return false;
    auto target = gm.questTarget();
    const quest = gm.context.data.quests.quest(questId);
    if (quest is null)
    {
        gm.redSystemMessage("That quest could not be found.");
        return true;
    }
    if (target.player.questStatus.length == 0)
        gm.redSystemMessage("Player has no quests to remove.");
    else if (finished(target, questId))
        gm.redSystemMessage("Player has already completed that quest.");
    else if (onQuest(target, questId))
    {
        target.gmDropQuest(*quest);
        gm.greenSystemMessage("Quest removed from the player’s log.");
    }
    else
        gm.redSystemMessage("No quest log entry found for that player.");
    gm.gmLog(format!"removed quest %u [%s] from player %s%%"(quest.id, quest.title, target.player.data.name));
    return true;
}

/// `.quest giver` and `.quest finisher`: the first creature and game object of `starts` (or ends) for the quest.
void questRelation(Character gm, uint questId, bool starts)
{
    const word = starts ? "starter" : "finisher";
    const title = starts ? "Starter" : "Finisher";
    const quests = &gm.context.data.quests;
    const creatureId = lowestEntryWith(starts ? quests.creatureStarts : quests.creatureEnds, questId);
    const objectId = lowestEntryWith(starts ? quests.gameObjectStarts : quests.gameObjectEnds, questId);
    gm.showQuestRelation("creature", title, word, creatureId, creatureId in gm.context.data.creatureTemplates,
        gm.context.data.creatureSpawns);
    gm.showQuestRelation("object", starts ? "starter" : title, word, objectId,
        objectId in gm.context.data.gameObjectTemplates, gm.context.data.gameObjectSpawns);
}

/// `questRelation`'s lines for one kind of giver: its entry, first spawn and name, or that there is none.
void showQuestRelation(Template, Spawns)(Character gm, string kind, string title, string word, uint entry, Template found,
    Spawns spawns)
{
    import std.algorithm.searching : find;

    if (!entry)
        return gm.blueSystemMessage(format!"No %s quest %ss found."(kind, word));
    if (found is null)
        return gm.blueSystemMessage(format!"No %s quest %s info found."(kind, word));
    const spawned = spawns.find!(spawn => spawn.entry == entry);
    const spawn = spawned.length ? format!"%s"(spawned[0].guid) : "N/A";
    gm.blueSystemMessage(format!"Quest %s found: %s id, spawnid, name"(title, kind));
    gm.blueSystemMessage(format!"%s, %s, %s"(entry, spawn, found.name));
}

/// `.quest item`: the items the quest asks for, up to 25.
bool handleQuestItemCommand(Character gm, uint questId)
{
    // A quest's items are in its own row (`reqItemId`, `reqItemCount`).
    const quest = gm.context.data.quests.quest(questId);
    uint count;
    if (quest !is null)
        foreach (i, item; quest.reqItemId)
        {
            if (item == 0)
                continue;
            if (count == 0)
                gm.greenSystemMessage("Quest items · ID, count, name");
            const proto = item in gm.context.data.items;
            gm.blueSystemMessage(format!"%s: %s -> %s"(item, quest.reqItemCount[i],
                proto is null ? "" : proto.details.name));
            if (++count == 25)
            {
                gm.redSystemMessage("Showing the first 25 matches.");
                break;
            }
        }
    if (count == 0)
        gm.blueSystemMessage("No matches found.");
    return true;
}

/// `.quest list`: the quests a creature entry gives (the selected quest giver's without one), or those
/// in the target's log, up to 25.
bool handleQuestListCommand(Character gm, uint questGiver = 0)
{
    if (questGiver == 0)
    {
        const guid = gm.player.values.get!UNIT_FIELD_TARGET;
        if (guid == 0)
        {
            gm.redSystemMessage("You must target an npc or specify an id.");
            return true;
        }
        if (auto creature = cast(Creature) gm.map.findObject(guid))
        {
            if (!(creature.values.get!UNIT_NPC_FLAGS & NpcFlag.questGiver))
            {
                gm.redSystemMessage("Unit is not a valid quest giver.");
                return true;
            }
            const entry = creature.spawn.entry;
            if (entry !in gm.context.data.quests.creatureStarts && entry !in gm.context.data.quests.creatureEnds)
            {
                gm.redSystemMessage("NPC does not have any quests.");
                return true;
            }
            questGiver = entry;
        }
    }
    gm.greenSystemMessage("Quests · ID, title");
    uint count;
    bool line(uint id)
    {
        const quest = gm.context.data.quests.quest(id);
        if (quest is null)
            return true;
        gm.blueSystemMessage(format!"%s: %s"(id, quest.title));
        if (++count == 25)
        {
            gm.redSystemMessage("Showing the first 25 matches.");
            return false;
        }
        return true;
    }

    if (questGiver == 0)
    {
        auto target = gm.questTarget();
        foreach (slot; 0 .. maxQuestLogSize)
            if (const id = target.player.values[PLAYER_QUEST_LOG_1_1 + 3 * slot])
                if (!line(id))
                    break;
    }
    else
    {
        const starts = questGiver in gm.context.data.quests.creatureStarts;
        if (starts is null)
        {
            gm.blueSystemMessage("No quests found for the specified NPC id.");
            return true;
        }
        foreach (id; *starts)
            if (!line(id))
                break;
    }
    if (count == 0)
        gm.blueSystemMessage("No matches found.");
    return true;
}

/**
 * `.quest addstart` .. `.quest delfinish`: the selected quest giver's quests, in memory and in
 * `creature_questrelation` / `creature_involvedrelation`. False after its message for a wrong target or quest,
 * or a quest to remove that the creature does not have.
 */
bool questRelationCommand(Character gm, uint questId, bool start, bool add)
{
    import std.algorithm.mutation : remove;
    import std.algorithm.searching : countUntil;

    const guid = gm.player.values.get!UNIT_FIELD_TARGET;
    auto creature = guid ? cast(Creature) gm.map.findObject(guid) : null;
    if (creature is null)
    {
        gm.redSystemMessage("You must target an npc.");
        return false;
    }
    if (!(creature.values.get!UNIT_NPC_FLAGS & NpcFlag.questGiver))
    {
        gm.redSystemMessage("Unit is not a valid quest giver.");
        return false;
    }
    const quest = gm.context.data.quests.quest(questId);
    if (quest is null)
    {
        gm.redSystemMessage(add ? "Invalid quest selected, unable to add quest to the specified NPC."
            : "Invalid Quest selected.");
        return false;
    }
    const entry = creature.spawn.entry;
    auto relations = start ? &gm.context.data.quests.creatureStarts : &gm.context.data.quests.creatureEnds;
    auto list = &(*relations).require(entry, null);
    const known = (*list).canFind(questId);
    const which = start ? "starter" : "finisher";
    if (add)
    {
        if (known)
            gm.redSystemMessage("Quest was already found for the specified NPC.");
        else
        {
            *list ~= questId;
            gm.context.database.insertQuestRelation(start, entry, questId);
        }
        gm.systemMessage(colored(ChatColor.green, format!"Added quest %s to NPC. "(which))
            ~ colored(ChatColor.sky, quest.title));
        gm.gmLog(format!"added %s of quest %u [%s] to NPC %u [%s]"(which, quest.id, quest.title, entry,
            creature.template_.name));
        return true;
    }
    if (!known)
    {
        gm.redSystemMessage("Quest was NOT found for the specified NPC.");
        return false;
    }
    *list = (*list).remove((*list).countUntil(questId));
    gm.context.database.deleteQuestRelation(start, entry, questId);
    gm.systemMessage(colored(ChatColor.green, "Removed quest from NPC. ") ~ colored(ChatColor.sky, quest.title));
    gm.gmLog(format!"deleted %s of quest %u [%s] to NPC %u [%s]"(which, quest.id, quest.title, entry,
        creature.template_.name));
    return true;
}

/// `.quest addstart`, `.quest addfinish`, `.quest delstart` and `.quest delfinish`.
bool handleQuestAddStartCommand(Character gm, uint questId) { gm.questRelationCommand(questId, true, true); return true; }
/// ditto
bool handleQuestAddFinishCommand(Character gm, uint questId) { gm.questRelationCommand(questId, false, true); return true; }
/// ditto
bool handleQuestDelStartCommand(Character gm, uint questId) { gm.questRelationCommand(questId, true, false); return true; }
/// ditto
bool handleQuestDelFinishCommand(Character gm, uint questId) { gm.questRelationCommand(questId, false, false); return true; }

/// `.quest addboth`: the quest given and taken back by the selected creature.
bool handleQuestAddBothCommand(Character gm, uint questId)
{
    if (gm.questRelationCommand(questId, true, true))
        gm.questRelationCommand(questId, false, true);
    return true;
}

/// `.quest delboth`: the quest neither given nor taken back by the selected creature.
bool handleQuestDelBothCommand(Character gm, uint questId)
{
    if (gm.questRelationCommand(questId, true, false))
        gm.questRelationCommand(questId, false, false);
    return true;
}

/// `.quest giver`.
bool handleQuestGiverCommand(Character gm, uint questId = 0)
{
    if (questId == 0)
        return false;
    gm.questRelation(questId, true);
    return true;
}

/// `.quest finisher`.
bool handleQuestFinisherCommand(Character gm, uint questId = 0)
{
    if (questId == 0)
        return false;
    gm.questRelation(questId, false);
    return true;
}

/// `.quest spawn`: to the first spawn of the quest's lowest-entry starter creature.
bool handleQuestSpawnCommand(Character gm, uint questId = 0)
{
    import dmangos.world.movement : Position;

    if (questId == 0)
        return false;
    const starterId = lowestEntryWith(gm.context.data.quests.creatureStarts, questId);
    if (!starterId)
    {
        gm.blueSystemMessage("No quest starters found.");
        return true;
    }
    const starter = starterId in gm.context.data.creatureTemplates;
    if (starter is null)
    {
        gm.blueSystemMessage("No quest starter info found.");
        return true;
    }
    foreach (const ref spawn; gm.context.data.creatureSpawns)
        if (spawn.entry == starterId)
        {
            gm.blueSystemMessage("Porting to Quest Starter/Giver: id, name");
            gm.blueSystemMessage(format!"%s, %s"(starterId, starter.name));
            gm.commandTeleport(spawn.map, Position(spawn.x, spawn.y, spawn.z, 0));
            return true;
        }
    gm.blueSystemMessage("No spawn location for quest starter was found.");
    return true;
}

/// `.quest reward`: the quest's item rewards and choices, as links.
bool handleQuestRewardCommand(Character gm, uint questId = 0)
{
    if (questId == 0)
        return false;
    const quest = gm.knownQuest(questId);
    if (quest is null)
        return true;
    uint count;
    void showRewards(string label, scope const(uint)[] items, scope const(uint)[] quantities)
    {
        foreach (i, entry; items)
            if (entry)
            {
                ++count;
                const quantity = quantities[i] > 1 ? format!"[x%s]"(quantities[i]) : "";
                gm.systemMessage(format!"%s (%s): %s%s"(label, entry, gm.itemLink(entry), quantity));
            }
    }
    showRewards("Reward", quest.rewItemId[], quest.rewItemCount[]);
    showRewards("Reward choice", quest.rewChoiceItemId[], quest.rewChoiceItemCount[]);
    if (!count)
        gm.systemMessage(format!"Quest %s has no item rewards."(questId));
    return true;
}

/// `.quest complete` on a quest in the log: its experience, `SMSG_QUESTGIVER_QUEST_COMPLETE`, out of the log.
void gmFinishQuest(Character gm, const ref Quest quest)
{
    import dmangos.bytes : ByteWriter;

    const xp = questXp(quest, gm.player.data.level);
    if (gm.player.data.level < gm.context.config.maxPlayerLevel)
        gm.giveXP(xp);
    ByteWriter w;
    w.put(quest.id);
    w.put(0x03u);
    w.put(gm.player.data.level < gm.context.config.maxPlayerLevel ? xp : 0u);
    w.put(0u);
    w.put(0u);
    gm.deliver(Opcode.SMSG_QUESTGIVER_QUEST_COMPLETE, w.data);
    const slot = gm.questSlot(quest.id);
    if (slot < maxQuestLogSize)
        gm.setQuestSlot(slot, 0);
    gm.flushPlayerChanges();
}

/// The quest `id` marked complete and rewarded, and saved.
void markQuestFinished(Character gm, uint id)
{
    auto progress = &gm.statusOf(id);
    progress.status = QuestState.complete;
    progress.rewarded = true;
    progress.changed = true;
    gm.saveQuests();
}

/// A quest dropped by a GM: out of the log, with what its giver gave.
void gmDropQuest(Character gm, const ref Quest quest)
{
    const slot = gm.questSlot(quest.id);
    if (slot < maxQuestLogSize)
        gm.setQuestSlot(slot, 0);
    if (quest.srcItemId)
        gm.player.inventory.destroyCount(quest.srcItemId, quest.srcItemCount ? quest.srcItemCount : 1);
    auto progress = &gm.statusOf(quest.id);
    progress.status = QuestState.none;
    progress.changed = true;
    gm.saveQuests();
    gm.flushInventory(true);
    gm.flushPlayerChanges();
}


/**
 * `.quest start`, `.quest status`, `.quest complete`, `.quest remove`, `.quest giver` and
 * `.quest reward` on a player, with their exact messages.
 */
unittest
{
    import std.algorithm.searching : canFind, count;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.chatstyle : ChatColor, colored;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    Quest q = {id: 9600, method: 2, maxLevel: 60, title: "Orders", rewOrReqMoney: 100};
    q.reqCreatureOrGoId[0] = 6;
    q.reqCreatureOrGoCount[0] = 3;
    q.specialFlags = 0x20;
    q.rewItemId[0] = itemJerky;
    q.rewItemCount[0] = 5;
    context.data.quests.quests[9600] = q;
    context.data.quests.creatureStarts[creatureTrainer] ~= 9600;
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.administrator);
    auto anduin = loggedIn(context, db, 8, "Anduin", Position(-8948, -132, 83.53f));
    gm.read();
    anduin.read();
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(anduin.session.character.guid));
    const me = cast(Player) anduin.session.character;

    gm.say(".quest status 9600");
    assert(systemMessages(gm.read()) == ["Player has not finished that quest."], "one status message");
    gm.say(".quest start 9600");
    assert(systemMessages(gm.read()) == [colored(ChatColor.green, "Quest has been added to the player's quest log.")]);
    assert(me.values[PLAYER_QUEST_LOG_1_1] == 9600);
    gm.say(".quest status 9600");
    assert(systemMessages(gm.read()) == ["Player is currently on that quest."]);

    gm.say(".quest list");
    assert(systemMessages(gm.read()).canFind(colored(ChatColor.sky, "9600: Orders")), "the selected player's log");
    gm.say(format!".quest list %s"(creatureTrainer));
    assert(systemMessages(gm.read()).canFind(colored(ChatColor.sky, "9600: Orders")), "the trainer's quests");
    gm.say(".quest list 1");
    assert(systemMessages(gm.read()).canFind(colored(ChatColor.sky, "No quests found for the specified NPC id.")));
    gm.say(".quest item 9600");
    assert(systemMessages(gm.read()).canFind(colored(ChatColor.sky, "No matches found.")));

    // The trainer (a quest giver) takes the quest back too, then gives it no more.
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.objects : HighGuid, makeGuid;

        auto trainer = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
        trainer.values.set!UNIT_NPC_FLAGS(trainer.values.get!UNIT_NPC_FLAGS | 0x02);
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(trainer.guid));
        gm.say(".quest addfinish 9600");
        assert(systemMessages(gm.read()).canFind(colored(ChatColor.green, "Added quest finisher to NPC. ")
            ~ colored(ChatColor.sky, "Orders")));
        assert(context.data.quests.creatureEnds[creatureTrainer].canFind(9600)
            && db.questRelationRows == [[0u, creatureTrainer, 9600]]);
        gm.say(".quest addstart 9600");
        assert(systemMessages(gm.read())
            .canFind(colored(ChatColor.softRed, "Quest was already found for the specified NPC.")));
        gm.say(".quest delboth 9600");
        const gone = systemMessages(gm.read());
        assert(gone.count!(m => m.canFind("Removed quest from NPC.")) == 2);
        assert(!context.data.quests.creatureStarts[creatureTrainer].canFind(9600) && db.questRelationRows.length == 0);
        gm.say(".quest delstart 9600");
        assert(systemMessages(gm.read()) == [colored(ChatColor.softRed, "Quest was NOT found for the specified NPC.")],
            "its own message, not the usage too");
        context.data.quests.creatureStarts[creatureTrainer] ~= 9600;
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(anduin.session.character.guid));
    }
    context.data.quests.quests[9600].reqItemId[0] = itemJerky;
    context.data.quests.quests[9600].reqItemCount[0] = 2;
    gm.say(".quest item 9600");
    assert(systemMessages(gm.read()).canFind(colored(ChatColor.sky, "117: 2 -> Tough Jerky")));
    context.data.quests.quests[9600].reqItemId[0] = 0;

    gm.say(".quest giver 9600");
    const giver = systemMessages(gm.read());
    assert(giver.canFind!(m => m.canFind("Llane Beshere"))
        && giver.canFind(colored(ChatColor.sky, "No object quest starters found.")));
    context.data.quests.quests[9600].rewChoiceItemId[0] = itemJerky;
    context.data.quests.quests[9600].rewChoiceItemCount[0] = 1;
    gm.say(".quest reward 9600");
    const jerky = "|cff9d9d9d|Hitem:117:0:0:0|h[Tough Jerky]|h|r";
    assert(systemMessages(gm.read()) == ["Reward (117): " ~ jerky ~ "[x5]", "Reward choice (117): " ~ jerky]);

    gm.say(".quest complete 9600");
    const done = systemMessages(gm.read());
    assert(done.canFind(colored(ChatColor.green, "Player was on that quest, but has now completed it.")));
    assert(me.questStatus[9600].rewarded && me.values[PLAYER_QUEST_LOG_1_1] == 0);
    gm.say(".quest remove 9600");
    assert(systemMessages(gm.read())[0].canFind(colored(ChatColor.softRed, "Player has already completed that quest.")),
        "one message");
    gm.say(".quest status 9601");
    assert(systemMessages(gm.read()) == [colored(ChatColor.softRed, "Quest 9601 was not found.")]);
}
