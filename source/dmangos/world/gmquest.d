/**
 * ArcEmu's `QuestCommands.cpp` that this server's quests support: `.quest status`, `.quest start`,
 * `.quest complete` (ArcEmu's `HandleQuestFinishCommand`), `.quest remove`, `.quest giver`,
 * `.quest finisher`, `.quest spawn` and `.quest reward`. ArcEmu's tables are CMaNGOS's here:
 * `creature_quest_starter` is `creature_questrelation`, `creature_quest_finisher`
 * `creature_involvedrelation`, the game object ones likewise, and `creature_spawns` is `creature`.
 * Mixed into `dmangos.world.session.Character`.
 */
module dmangos.world.gmquest;

/// See the module documentation.
mixin template QuestCommands()
{
    import std.format : format;
    import dmangos.world.commands;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.quests : Quest, QuestState, maxQuestLogSize, questXp;

private:

    /// ArcEmu's `getSelectedChar(m_session, true)`, else the GM itself ("Auto-targeting self.").
    auto questTarget()
    {
        auto plr = getSelectedChar(true);
        if (plr is null)
        {
            plr = this;
            systemMessage("Auto-targeting self.");
        }
        return plr;
    }

    /// `Player::HasFinishedQuest`
    static bool finished(typeof(this) plr, uint id)
    {
        const q = id in plr.player.questStatus;
        return q !is null && q.rewarded;
    }

    /// `Player::GetQuestLogForEntry`: in the log.
    static bool onQuest(typeof(this) plr, uint id)
    {
        return plr.questSlot(id) < maxQuestLogSize;
    }

    bool handleQuestStatusCommand(uint questId = 0)
    {
        if (questId == 0)
            return false;
        auto plr = questTarget();
        string recout = "|cff00ff00";
        if (context.data.quests.quest(questId) !is null)
        {
            if (finished(plr, questId))
                recout ~= "Player has already completed that quest.";
            else if (onQuest(plr, questId))
                recout ~= "Player is currently on that quest.";
            else
                recout ~= "Player has NOT finished that quest.";
        }
        else
            recout ~= format!"Quest Id [%s] was not found and unable to add it to the player's quest log."(questId);
        sendMultilineMessage(recout ~ "\n\n");
        return true;
    }

    bool handleQuestStartCommand(uint questId = 0)
    {
        if (questId == 0)
            return false;
        auto plr = questTarget();
        string recout = "|cff00ff00";
        const quest = context.data.quests.quest(questId);
        if (quest !is null)
        {
            if (finished(plr, questId))
                recout ~= "Player has already completed that quest.";
            else if (onQuest(plr, questId))
                recout ~= "Player is currently on that quest.";
            else if (plr.questSlot(0) >= maxQuestLogSize)
            {
                plr.deliver(Opcode.SMSG_QUESTLOG_FULL, null);
                recout ~= "Player's quest log is full.";
            }
            else
            {
                gmLog(format!"started quest %u [%s] for player %s"(quest.id, quest.title, plr.player.data.name));
                plr.addQuest(*quest); // its source item with it
                plr.flushInventory(true);
                plr.flushPlayerChanges();
                recout ~= "Quest has been added to the player's quest log.";
            }
        }
        else
            recout ~= format!"Quest Id [%s] was not found and unable to add it to the player's quest log."(questId);
        sendMultilineMessage(recout ~ "\n\n");
        return true;
    }

    bool handleQuestFinishCommand(uint questId = 0)
    {
        import dmangos.world.creature : Creature;

        if (questId == 0)
            return false;
        auto plr = questTarget();
        string recout = "|cff00ff00";
        const quest = context.data.quests.quest(questId);
        if (quest is null)
        {
            recout ~= format!"Quest Id [%s] was not found and unable to add it to the player's quest log."(questId);
            sendMultilineMessage(recout ~ "\n\n");
            return true;
        }
        if (finished(plr, questId))
        {
            sendMultilineMessage(recout ~ "Player has already completed that quest.\n\n\n\n");
            return true;
        }
        if (onQuest(plr, questId))
        {
            // The quest's giver: a creature (else a game object) that starts it, and one of its entry on the map.
            uint giverId;
            foreach (entry, list; context.data.quests.creatureStarts)
                foreach (q; list)
                    if (q == questId && !giverId)
                        giverId = entry;
            if (!giverId)
                foreach (entry, list; context.data.quests.gameObjectStarts)
                    foreach (q; list)
                        if (q == questId && !giverId)
                            giverId = entry;
            if (giverId == 0)
                systemMessage("Unable to find quest giver creature or object.");
            else
            {
                bool found;
                foreach (c; plr.map.creaturesNear(plr.player.position, 100_000))
                    if (c.template_.entry == giverId)
                        found = true;
                if (found)
                {
                    greenSystemMessage("Found a quest_giver creature.");
                    plr.rewardQuestReputation(*quest);
                }
                else
                    redSystemMessage("Unable to find quest_giver object.");
            }
            plr.gmFinishQuest(*quest);
            recout ~= "Player was on that quest, but has now completed it.";
        }
        else
            recout ~= "The quest has now been completed for that player.";
        gmLog(format!"completed quest %u [%s] for player %s"(questId, quest.title, plr.player.data.name));
        plr.markQuestFinished(questId);
        sendMultilineMessage(recout ~ "\n\n");
        return true;
    }

    bool handleQuestRemoveCommand(uint questId = 0)
    {
        if (questId == 0)
            return false;
        auto plr = questTarget();
        const quest = context.data.quests.quest(questId);
        string recout;
        if (quest !is null)
        {
            recout = "|cff00ff00";
            // ArcEmu's `RemoveQuestFromPlayer`.
            if (plr.player.questStatus.length)
            {
                if (finished(plr, questId))
                    recout ~= "Player has already completed that quest.\n\n";
                else if (onQuest(plr, questId))
                    plr.gmDropQuest(*quest);
                else
                    recout ~= "No quest log entry found for that player.";
            }
            else
                recout ~= "Player has no quests to remove.";
            recout ~= "\n\n";
            gmLog(format!"removed quest %u [%s] from player %s%%"(quest.id, quest.title, plr.player.data.name));
        }
        else
            recout = "Invalid quest selected, unable to remove.\n\n";
        systemMessage(recout);
        return true;
    }

    /// `.quest giver` and `.quest finisher`: the first creature and game object of `starts` (or ends) for the quest.
    void questRelation(uint questId, bool starts)
    {
        const word = starts ? "starter" : "finisher";
        const Word = starts ? "Starter" : "Finisher";
        uint creatureId, objectId;
        foreach (entry, list; starts ? context.data.quests.creatureStarts : context.data.quests.creatureEnds)
            foreach (q; list)
                if (q == questId && (!creatureId || entry < creatureId))
                    creatureId = entry;
        foreach (entry, list; starts ? context.data.quests.gameObjectStarts : context.data.quests.gameObjectEnds)
            foreach (q; list)
                if (q == questId && (!objectId || entry < objectId))
                    objectId = entry;

        if (creatureId)
        {
            if (const t = creatureId in context.data.creatureTemplates)
            {
                string spawn = "N/A";
                foreach (ref s; context.data.creatureSpawns)
                    if (s.entry == creatureId)
                    {
                        spawn = format!"%s"(s.guid);
                        break;
                    }
                sendMultilineMessage(format!"|cff00ccffQuest %s found: creature id, spawnid, name\n\n"(
                    starts ? "Starter" : Word));
                sendMultilineMessage(format!"|cff00ccff%s, %s, %s\n\n"(creatureId, spawn, t.name));
            }
            else
                sendMultilineMessage(format!"|cff00ccffNo creature quest %s info found.\n\n"(word));
        }
        else
            sendMultilineMessage(format!"|cff00ccffNo creature quest %ss found.\n\n"(word));

        if (objectId)
        {
            if (const t = objectId in context.data.gameObjectTemplates)
            {
                string spawn = "N/A";
                foreach (ref s; context.data.gameObjectSpawns)
                    if (s.entry == objectId)
                    {
                        spawn = format!"%s"(s.guid);
                        break;
                    }
                sendMultilineMessage(format!"|cff00ccffQuest %s found: object id, spawnid, name\n\n"(
                    starts ? "starter" : Word));
                sendMultilineMessage(format!"|cff00ccff%s, %s, %s\n\n"(objectId, spawn, t.name));
            }
            else
                sendMultilineMessage(format!"|cff00ccffNo object quest %s info found.\n\n"(word));
        }
        else
            sendMultilineMessage(format!"|cff00ccffNo object quest %ss found.\n\n"(word));
    }

    bool handleQuestItemCommand(uint questId)
    {
        // CMaNGOS keeps a quest's items in its own row (ArcEmu: `gameobject_quest_item_binding`).
        const quest = context.data.quests.quest(questId);
        uint count;
        if (quest !is null)
            foreach (i, item; quest.reqItemId)
            {
                if (item == 0)
                    continue;
                if (count == 0)
                    sendMultilineMessage("|cff00ff00Quest item matches: itemid: count -> Name\n\n");
                const proto = item in context.data.items;
                sendMultilineMessage(format!"|cff00ccff%s: %s -> %s\n"(item, quest.reqItemCount[i],
                    proto is null ? "" : proto.details.name));
                ++count;
                if (count == 25)
                {
                    redSystemMessage("More than 25 results returned. aborting.");
                    break;
                }
            }
        if (count == 0)
            sendMultilineMessage("|cff00ccffNo matches found.\n\n");
        return true;
    }

    bool handleQuestListCommand(uint questGiver = 0)
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.updatefields : PLAYER_QUEST_LOG_1_1, UNIT_FIELD_TARGET, UNIT_NPC_FLAGS;

        enum uint npcFlagQuestGiver = 0x02;
        if (questGiver == 0)
        {
            const guid = player.values.get!UNIT_FIELD_TARGET;
            if (guid == 0)
            {
                systemMessage("You must target an npc or specify an id.");
                return true;
            }
            if (auto unit = cast(Creature) map.findObject(guid))
            {
                if (!(unit.values.get!UNIT_NPC_FLAGS & npcFlagQuestGiver))
                {
                    systemMessage("Unit is not a valid quest giver.");
                    return true;
                }
                const entry = unit.spawn.entry;
                if (entry !in context.data.quests.creatureStarts && entry !in context.data.quests.creatureEnds)
                {
                    systemMessage("NPC does not have any quests.");
                    return true;
                }
                questGiver = entry;
            }
        }
        sendMultilineMessage("|cff00ff00Quest matches: id: title\n\n");
        uint count;
        bool line(uint id)
        {
            const quest = context.data.quests.quest(id);
            if (quest is null)
                return true;
            sendMultilineMessage(format!"|cff00ccff%s: %s\n"(id, quest.title));
            if (++count == 25)
            {
                redSystemMessage("More than 25 results returned. aborting.");
                return false;
            }
            return true;
        }

        if (questGiver == 0)
        {
            auto plr = questTarget();
            foreach (slot; 0 .. maxQuestLogSize)
                if (const id = plr.player.values[PLAYER_QUEST_LOG_1_1 + 3 * slot])
                    if (!line(id))
                        break;
        }
        else
        {
            const starts = questGiver in context.data.quests.creatureStarts;
            if (starts is null)
            {
                sendMultilineMessage("|cff00ccffNo quests found for the specified NPC id.\n\n");
                return true;
            }
            foreach (id; *starts)
                if (!line(id))
                    break;
        }
        if (count == 0)
            sendMultilineMessage("|cff00ccffNo matches found.\n\n");
        return true;
    }

    /**
     * ArcEmu's `.quest addstart` .. `.quest delfinish`: the selected quest giver's quests, in memory
     * and in `creature_questrelation` / `creature_involvedrelation`. Returns what ArcEmu's do.
     */
    bool questRelationCommand(uint questId, bool start, bool add)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : canFind, countUntil;
        import dmangos.world.creature : Creature;
        import dmangos.world.updatefields : UNIT_FIELD_TARGET, UNIT_NPC_FLAGS;

        enum uint npcFlagQuestGiver = 0x02;
        const guid = player.values.get!UNIT_FIELD_TARGET;
        auto unit = guid ? cast(Creature) map.findObject(guid) : null;
        if (unit is null)
        {
            systemMessage("You must target an npc.");
            return false;
        }
        if (!(unit.values.get!UNIT_NPC_FLAGS & npcFlagQuestGiver))
        {
            systemMessage("Unit is not a valid quest giver.");
            return false;
        }
        const quest = context.data.quests.quest(questId);
        if (quest is null)
        {
            systemMessage(add ? "Invalid quest selected, unable to add quest to the specified NPC." : "Invalid Quest selected.");
            return false;
        }
        const entry = unit.spawn.entry;
        auto relations = start ? &context.data.quests.creatureStarts : &context.data.quests.creatureEnds;
        auto list = &(*relations).require(entry, null);
        const known = (*list).canFind(questId);
        const which = start ? "starter" : "finisher";
        if (add)
        {
            if (known)
                systemMessage("Quest was already found for the specified NPC.");
            else
            {
                *list ~= questId;
                context.database.insertQuestRelation(start, entry, questId);
            }
            sendMultilineMessage(format!"|cff00ff00Added Quest to NPC as %s: |cff00ccff%s\n\n"(which, quest.title));
            gmLog(format!"added %s of quest %u [%s] to NPC %u [%s]"(which, quest.id, quest.title, entry, unit.template_.name));
            return true;
        }
        if (!known)
        {
            systemMessage("Quest was NOT found for the specified NPC.");
            return !start; // `.quest delstart` shows its help too
        }
        *list = (*list).remove((*list).countUntil(questId));
        context.database.deleteQuestRelation(start, entry, questId);
        sendMultilineMessage(format!"|cff00ff00Deleted Quest from NPC: |cff00ccff%s\n\n"(quest.title));
        gmLog(format!"deleted %s of quest %u [%s] to NPC %u [%s]"(which, quest.id, quest.title, entry, unit.template_.name));
        return true;
    }

    bool handleQuestAddStartCommand(uint questId) { return questRelationCommand(questId, true, true); }
    bool handleQuestAddFinishCommand(uint questId) { return questRelationCommand(questId, false, true); }
    bool handleQuestDelStartCommand(uint questId) { return questRelationCommand(questId, true, false); }
    bool handleQuestDelFinishCommand(uint questId) { return questRelationCommand(questId, false, false); }

    bool handleQuestAddBothCommand(uint questId)
    {
        if (questRelationCommand(questId, true, true))
            questRelationCommand(questId, false, true);
        return true;
    }

    bool handleQuestDelBothCommand(uint questId)
    {
        if (questRelationCommand(questId, true, false))
            questRelationCommand(questId, false, false);
        return true;
    }

    bool handleQuestGiverCommand(uint questId = 0)
    {
        if (questId == 0)
            return false;
        questRelation(questId, true);
        return true;
    }

    bool handleQuestFinisherCommand(uint questId = 0)
    {
        if (questId == 0)
            return false;
        questRelation(questId, false);
        return true;
    }

    bool handleQuestSpawnCommand(uint questId = 0)
    {
        import dmangos.world.movement : Position;

        if (questId == 0)
            return false;
        uint starterId;
        foreach (entry, list; context.data.quests.creatureStarts)
            foreach (q; list)
                if (q == questId && (!starterId || entry < starterId))
                    starterId = entry;
        if (!starterId)
        {
            sendMultilineMessage("|cff00ccffNo quest starters found.\n\n");
            return true;
        }
        const t = starterId in context.data.creatureTemplates;
        if (t is null)
        {
            sendMultilineMessage("|cff00ccffNo quest starter info found.\n\n");
            return true;
        }
        foreach (ref s; context.data.creatureSpawns)
            if (s.entry == starterId)
            {
                sendMultilineMessage("|cff00ccffPorting to Quest Starter/Giver: id, name\n\n");
                sendMultilineMessage(format!"|cff00ccff%s, %s\n\n"(starterId, t.name));
                commandTeleport(s.map, Position(s.x, s.y, s.z, 0));
                return true;
            }
        sendMultilineMessage("|cff00ccffNo spawn location for quest starter was found.\n\n");
        return true;
    }

    bool handleQuestRewardCommand(uint questId = 0)
    {
        if (questId == 0)
            return false;
        string recout;
        const q = context.data.quests.quest(questId);
        if (q !is null)
        {
            uint rewards, choices;
            foreach (i, item; q.rewItemId)
                if (item)
                {
                    ++rewards;
                    if (item !in context.data.items)
                        recout ~= format!"Unknown item id %%lu%s"(item);
                    else
                        recout ~= format!"Reward (%s): %s"(item, itemLink(item))
                            ~ (q.rewItemCount[i] == 1 ? "\n" : format!"[x%s]\n"(q.rewItemCount[i]));
                }
            foreach (i, item; q.rewChoiceItemId)
                if (item)
                {
                    ++choices;
                    if (item !in context.data.items)
                        recout ~= format!"Unknown item id %%lu%s"(item);
                    else
                        recout ~= format!"Reward choice (%s): %s"(item, itemLink(item))
                            ~ (q.rewChoiceItemCount[i] == 1 ? "\n" : format!"[x%s]\n"(q.rewChoiceItemCount[i]));
                }
            if (rewards == 0 && choices == 0)
                recout ~= format!"Quest %s has no item rewards."(questId);
        }
        else
            recout ~= format!"Quest ID %s not found.\n"(questId);
        sendMultilineMessage(recout);
        return true;
    }

package:
    /// `.quest complete` on a quest in the log: its experience, `SMSG_QUESTGIVER_QUEST_COMPLETE`, out of the log.
    void gmFinishQuest(const ref Quest quest)
    {
        import dmangos.bytes : ByteWriter;

        const xp = questXp(quest, player.data.level);
        if (player.data.level < context.config.maxPlayerLevel)
            giveXP(xp);
        ByteWriter w;
        w.put(quest.id);
        w.put(0x03u);
        w.put(player.data.level < context.config.maxPlayerLevel ? xp : 0u);
        w.put(0u);
        w.put(0u);
        deliver(Opcode.SMSG_QUESTGIVER_QUEST_COMPLETE, w.data);
        const slot = questSlot(quest.id);
        if (slot < maxQuestLogSize)
            setQuestSlot(slot, 0);
        flushPlayerChanges();
    }

    /// `Player::AddToFinishedQuests`
    void markQuestFinished(uint id)
    {
        auto q = &statusOf(id);
        q.status = QuestState.complete;
        q.rewarded = true;
        q.changed = true;
        saveQuests();
    }

    /// ArcEmu's `RemoveQuestFromPlayer` for a quest in the log: out of it, with what its giver gave.
    void gmDropQuest(const ref Quest quest)
    {
        const slot = questSlot(quest.id);
        if (slot < maxQuestLogSize)
            setQuestSlot(slot, 0);
        if (quest.srcItemId)
            player.inventory.destroyCount(quest.srcItemId, quest.srcItemCount ? quest.srcItemCount : 1);
        auto q = &statusOf(quest.id);
        q.status = QuestState.none;
        q.changed = true;
        saveQuests();
        flushInventory(true);
        flushPlayerChanges();
    }
}

/**
 * `.quest start`, `.quest status`, `.quest complete`, `.quest remove`, `.quest giver` and
 * `.quest reward` on a player, in ArcEmu's words.
 */
unittest
{
    import std.algorithm.searching : canFind, count;
    import std.format : format;
    import dmangos.auth.accounts : AccountLevel;
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
    assert(systemMessages(gm.read()) == ["|cff00ff00Player has NOT finished that quest.", ""], "ArcEmu's empty line too");
    gm.say(".quest start 9600");
    assert(systemMessages(gm.read()) == ["|cff00ff00Quest has been added to the player's quest log.", ""]);
    assert(me.values[PLAYER_QUEST_LOG_1_1] == 9600);
    gm.say(".quest status 9600");
    assert(systemMessages(gm.read()) == ["|cff00ff00Player is currently on that quest.", ""]);

    gm.say(".quest list");
    assert(systemMessages(gm.read()).canFind("|cff00ccff9600: Orders"), "the selected player's log");
    gm.say(format!".quest list %s"(creatureTrainer));
    assert(systemMessages(gm.read()).canFind("|cff00ccff9600: Orders"), "the trainer's quests");
    gm.say(".quest list 1");
    assert(systemMessages(gm.read()).canFind("|cff00ccffNo quests found for the specified NPC id."));
    gm.say(".quest item 9600");
    assert(systemMessages(gm.read()).canFind("|cff00ccffNo matches found."));

    // The trainer (a quest giver) takes the quest back too, then gives it no more.
    {
        import dmangos.world.creature : Creature;
        import dmangos.world.objects : HighGuid, makeGuid;

        auto trainer = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
        trainer.values.set!UNIT_NPC_FLAGS(trainer.values.get!UNIT_NPC_FLAGS | 0x02);
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(trainer.guid));
        gm.say(".quest addfinish 9600");
        assert(systemMessages(gm.read()).canFind("|cff00ff00Added Quest to NPC as finisher: |cff00ccffOrders"));
        assert(context.data.quests.creatureEnds[creatureTrainer].canFind(9600) && db.questRelationRows == [[0u, creatureTrainer, 9600]]);
        gm.say(".quest addstart 9600");
        assert(systemMessages(gm.read()).canFind("Quest was already found for the specified NPC."));
        gm.say(".quest delboth 9600");
        const gone = systemMessages(gm.read());
        assert(gone.count!(m => m.canFind("Deleted Quest from NPC")) == 2);
        assert(!context.data.quests.creatureStarts[creatureTrainer].canFind(9600) && db.questRelationRows.length == 0);
        gm.say(".quest delstart 9600");
        assert(systemMessages(gm.read())[0] == "Quest was NOT found for the specified NPC.");
        context.data.quests.creatureStarts[creatureTrainer] ~= 9600;
        gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(anduin.session.character.guid));
    }
    context.data.quests.quests[9600].reqItemId[0] = itemJerky;
    context.data.quests.quests[9600].reqItemCount[0] = 2;
    gm.say(".quest item 9600");
    assert(systemMessages(gm.read()).canFind("|cff00ccff117: 2 -> Tough Jerky"));
    context.data.quests.quests[9600].reqItemId[0] = 0;

    gm.say(".quest giver 9600");
    const giver = systemMessages(gm.read());
    assert(giver.canFind!(m => m.canFind("Llane Beshere")) && giver.canFind("|cff00ccffNo object quest starters found."));
    gm.say(".quest reward 9600");
    assert(systemMessages(gm.read()) == ["Reward (117): |cff9d9d9d|Hitem:117:0:0:0|h[Tough Jerky]|h|r[x5]"]);

    gm.say(".quest complete 9600");
    const done = systemMessages(gm.read());
    assert(done.canFind("|cff00ff00Player was on that quest, but has now completed it."));
    assert(me.questStatus[9600].rewarded && me.values[PLAYER_QUEST_LOG_1_1] == 0);
    gm.say(".quest remove 9600");
    assert(systemMessages(gm.read())[0].canFind("|cff00ff00Player has already completed that quest."), "one message");
    gm.say(".quest status 9601");
    assert(systemMessages(gm.read()) == ["|cff00ff00Quest Id [9601] was not found and unable to add it to the player's quest log.", ""]);
}
