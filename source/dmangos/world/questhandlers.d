/**
 * Quests for players: the quest packets, who may take and turn in what, the quest log, kill and
 * item credit and rewards, mixed into `dmangos.world.character.Character`.
 *
 * Quest givers show what they have for the player (`SMSG_QUESTGIVER_STATUS`), list their quests in
 * their gossip, and give them (details, accept). The quest log is the player's 20
 * `PLAYER_QUEST_LOG_*` slots: the quest, its kill counters and its state. Kills of the creatures a
 * quest asks for count (for the group near the kill too); the items it asks for count as the
 * player carries them; a quest whose objectives are met is complete, and its ender takes it back:
 * the items it asked for, then its experience, money, items (one chosen) and spell. Progress is
 * saved in `character_queststatus`.
 *
 * Not yet: quests from game objects and items, sharing with the group, timed quests' failing,
 * exploration and event objectives, reputation rewards and requirements, `questgiver_greeting`.
 */
module dmangos.world.questhandlers;

import dmangos.world.money : Copper;

/// See the module documentation.
mixin template QuestHandlers()
{
    import dmangos.world.money : Copper;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info;
    import dmangos.world.creature : Npc;
    import dmangos.world.defines : nullBag, nullSlot;
    import dmangos.world.inventory : InventoryResult, ItemPosCount;
    import dmangos.world.opcodes;
    import dmangos.world.packets : GossipQuestItem;
    import dmangos.world.quests;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.updatefields;

private:
    GossipQuestItem[] questMenu; // what the last quest giver offered

    // -----------------------------------------------------------------------
    // The status and the log
    // -----------------------------------------------------------------------

    /// The state of quest `id` for this player; `none` if it never took it.
    QuestState questState(uint id)
    {
        if (auto q = id in player.questStatus)
            return q.status;
        return QuestState.none;
    }

    /// Whether this player has turned quest `id` in.
    bool questRewarded(uint id)
    {
        if (auto q = id in player.questStatus)
            return q.rewarded;
        return false;
    }

    /// The quest log slot holding `id`; `maxQuestLogSize` if none (0: a free slot).
    uint questSlot(uint id)
    {
        foreach (slot; 0 .. maxQuestLogSize)
            if (player.values[PLAYER_QUEST_LOG_1_1 + 3 * slot] == id)
                return slot;
        return maxQuestLogSize;
    }

    /// Puts quest `id` in log slot `slot`, its counters and state cleared, with its timer.
    void setQuestSlot(uint slot, uint id, uint timer = 0)
    {
        player.values.setSlot(PLAYER_QUEST_LOG_1_1 + 3 * slot, id);
        player.values.setSlot(PLAYER_QUEST_LOG_1_1 + 3 * slot + 1, 0);
        player.values.setSlot(PLAYER_QUEST_LOG_1_1 + 3 * slot + 2, timer);
    }

    /// Sets an objective's count in a log slot, 6 bits each.
    void setQuestSlotCounter(uint slot, uint counter, uint count)
    {
        const index = PLAYER_QUEST_LOG_1_1 + 3 * slot + 1;
        uint value = player.values[index];
        value &= ~(0x3Fu << (counter * 6));
        value |= (count & 0x3F) << (counter * 6);
        player.values.setSlot(index, value);
    }

    /// A log slot's state: the high byte's complete (1) and failed (2) bits.
    void setQuestSlotState(uint slot, uint state, bool on)
    {
        const index = PLAYER_QUEST_LOG_1_1 + 3 * slot + 1;
        const value = player.values[index];
        player.values.setSlot(index, on ? value | (state << 24) : value & ~(state << 24));
    }

    /// The status of `id`, made if there is none.
    ref QuestStatus statusOf(uint id)
    {
        return player.questStatus.require(id, QuestStatus(id));
    }

    /// `_SaveQuestStatus`: the quests whose progress changed.
    package void saveQuests()
    {
        QuestStatus[] changed;
        foreach (ref q; player.questStatus)
            if (q.changed)
            {
                changed ~= q;
                q.changed = false;
            }
        if (changed.length)
            context.database.saveQuestStatus(player.data.guid, changed);
    }

    // -----------------------------------------------------------------------
    // Who may take what
    // -----------------------------------------------------------------------

    bool satisfyClassRaceLevel(const ref Quest quest, bool levelToo)
    {
        if (quest.requiredClasses && !(quest.requiredClasses & (1u << (player.data.classId - 1))))
            return false;
        if (quest.requiredRaces && !(quest.requiredRaces & (1u << (player.data.race - 1))))
            return false;
        if (levelToo && (player.data.level < quest.minLevel || player.data.level > quest.maxLevel))
            return false;
        if (quest.requiredSkill && player.skillValue(quest.requiredSkill)[0] < quest.requiredSkillValue)
            return false;
        if (quest.requiredCondition && !conditionMet(quest.requiredCondition))
            return false;
        return true;
    }

    /// One of the quests before it done (positive) or taken (negative).
    bool satisfyPrevious(const ref Quest quest)
    {
        if (quest.prevQuests.length == 0)
            return true;
        foreach (prev; quest.prevQuests)
        {
            if (prev > 0 && questRewarded(prev))
                return true;
            if (prev < 0 && questState(-prev) == QuestState.incomplete)
                return true;
        }
        return false;
    }

    /// None of its exclusive group taken or (unless repeatable) done.
    bool satisfyExclusiveGroup(const ref Quest quest)
    {
        if (quest.exclusiveGroup <= 0)
            return true;
        foreach (other; context.data.quests.exclusiveGroups.get(quest.exclusiveGroup, null))
        {
            if (other == quest.id)
                continue;
            const otherQuest = context.data.quests.quest(other);
            if (otherQuest is null)
                continue;
            if (questState(other) != QuestState.none || (!otherQuest.repeatable && questRewarded(other)))
                return false;
        }
        return true;
    }

    /// Not taken, and not done unless repeatable.
    bool satisfyStatus(const ref Quest quest)
    {
        return questState(quest.id) == QuestState.none && (quest.repeatable || !questRewarded(quest.id));
    }

    /// Whether this player may take `quest` now: every requirement met.
    package bool canTakeQuest(const ref Quest quest)
    {
        return satisfyStatus(quest) && satisfyExclusiveGroup(quest) && satisfyClassRaceLevel(quest, true)
            && satisfyPrevious(quest) && satisfyQuestReputation(quest) && satisfyQuestTimed(quest)
            && questInSeason(quest);
    }

    /// A quest of game events (`game_event_quest`) is given only while one of them is on.
    bool questInSeason(const ref Quest quest)
    {
        const events = quest.id in context.data.questGameEvents;
        if (events is null)
            return true;
        foreach (e; *events)
            if (context.gameEvents.isActive(e))
                return true;
        return false;
    }

    /// One timed quest at a time.
    bool satisfyQuestTimed(const ref Quest quest)
    {
        if (!(quest.specialFlags & specialTimed))
            return true;
        foreach (ref q; player.questStatus)
            if (q.status == QuestState.incomplete && q.timer)
                return false;
        return true;
    }

    /// Timed quests: one whose time is up fails.
    package void updateTimedQuests()
    {
        const now = context.unixTime;
        uint[] due;
        foreach (ref q; player.questStatus)
            if (q.timer && q.status == QuestState.incomplete && q.timer <= now)
                due ~= q.quest;
        foreach (id; due)
            failQuest(id);
    }

    /// Whether a giver shows `quest` as available: everything but the level, and not far above the player.
    bool canSeeStartQuest(const ref Quest quest)
    {
        enum int highLevelHideDiff = 7; // levels above the player a quest is still shown
        return satisfyClassRaceLevel(quest, false) && satisfyExclusiveGroup(quest) && satisfyPrevious(quest)
            && satisfyQuestReputation(quest) && player.data.level + highLevelHideDiff >= quest.minLevel
            && player.data.level <= quest.maxLevel && questInSeason(quest);
    }

    /// Whether `quest` is complete: taken, and every objective met (kills, items, money).
    package bool canCompleteQuest(uint id)
    {
        const quest = context.data.quests.quest(id);
        if (quest is null)
            return false;
        const status = questState(id);
        if (status == QuestState.complete)
            return false;
        if (quest.autoComplete && canTakeQuest(*quest))
            return true;
        if (status != QuestState.incomplete)
            return false;
        const q = id in player.questStatus;
        foreach (i; 0 .. questObjectives)
        {
            if (quest.reqItemCount[i] && q.itemCount[i] < quest.reqItemCount[i])
                return false;
            if (quest.reqCreatureOrGoId[i] && quest.reqCreatureOrGoCount[i] && q.mobCount[i] < quest.reqCreatureOrGoCount[i])
                return false;
        }
        if ((quest.specialFlags & specialExplorationOrEvent) && !q.explored)
            return false;
        if ((quest.specialFlags & specialTimed) && q.timer == 0)
            return false;
        if (quest.rewOrReqMoney < 0 && !player.canAfford(Copper(-quest.rewOrReqMoney)))
            return false;
        if (quest.repObjectiveFaction && player.reputation !is null
            && player.reputation.standingWith(quest.repObjectiveFaction) < quest.repObjectiveValue)
            return false;
        return true;
    }

    /// Whether `quest` may be turned in: complete (or completing itself), not rewarded, the items carried.
    bool canRewardQuest(const ref Quest quest)
    {
        if (!quest.autoComplete && questState(quest.id) != QuestState.complete)
            return false;
        if (questRewarded(quest.id) && !quest.repeatable)
            return false;
        foreach (i; 0 .. questObjectives)
            if (quest.reqItemCount[i] && player.inventory.count(quest.reqItemId[i]) < quest.reqItemCount[i])
                return false;
        return quest.rewOrReqMoney >= 0 || player.canAfford(Copper(-quest.rewOrReqMoney));
    }

    // -----------------------------------------------------------------------
    // Quest givers
    // -----------------------------------------------------------------------

    /// A quest giver as the dialogs need it: a creature's or a game object's guid and quests.
    struct QuestGiver
    {
        ulong guid;
        const(uint)[] starts, ends;
        uint itemEntry;          /// an item in the bags that begins a quest (`startquest`); 0 otherwise
    }

    /// A creature as a quest giver.
    package QuestGiver giverOf(Npc npc)
    {
        const entry = npc.npcTemplate.entry;
        return QuestGiver(npc.guid, context.data.quests.creatureStarts.get(entry, null),
            context.data.quests.creatureEnds.get(entry, null));
    }

    /**
     * The quest giver `guid` this player may talk to: a creature it can interact with that has
     * `npcFlags`, or a game object within reach; false if none.
     */
    package bool questGiverNear(ulong guid, uint npcFlags, out QuestGiver giver)
    {
        import dmangos.world.gameobject : GameObject;

        if (auto npc = interactableNpc(guid, npcFlags))
        {
            giver = giverOf(npc);
            return true;
        }
        // An item in the bags that begins a quest.
        if (auto item = itemByGuid(guid))
        {
            const proto = item.entry in context.data.items;
            if (proto is null || !proto.details.startQuest)
                return false;
            giver = QuestGiver(guid, [proto.details.startQuest], null, item.entry);
            return true;
        }
        auto go = cast(GameObject) map.findObject(guid);
        if (go is null || transferring || player.deathState != DeathState.alive || !withinInteraction(go, 2))
            return false;
        const entry = go.template_.entry;
        giver = QuestGiver(go.guid, context.data.quests.gameObjectStarts.get(entry, null),
            context.data.quests.gameObjectEnds.get(entry, null));
        return true;
    }

    /// The mark over a quest giver for this player.
    DialogStatus dialogStatus(const QuestGiver giver)
    {
        DialogStatus result = DialogStatus.none;
        foreach (id; giver.ends)
        {
            const quest = context.data.quests.quest(id);
            if (quest is null)
                continue;
            const status = questState(id);
            DialogStatus next = DialogStatus.none;
            if (status == QuestState.complete && !questRewarded(id))
                next = quest.repeatable ? DialogStatus.rewardRep : DialogStatus.reward2;
            else if (quest.autoComplete && canTakeQuest(*quest))
                next = quest.repeatable ? DialogStatus.rewardRep : DialogStatus.available;
            else if (status == QuestState.incomplete)
                next = DialogStatus.incomplete;
            if (next > result)
                result = next;
        }
        foreach (id; giver.starts)
        {
            const quest = context.data.quests.quest(id);
            if (quest is null || questState(id) != QuestState.none || !canSeeStartQuest(*quest))
                continue;
            if (!satisfyStatus(*quest))
                continue;
            DialogStatus next;
            if (player.data.level >= quest.minLevel)
            {
                enum uint lowLevelHideDiff = 4; // levels below the player a quest still shows as available
                if (quest.autoComplete)
                    next = DialogStatus.rewardRep;
                else if (player.data.level <= quest.levelFor(player.data.level) + lowLevelHideDiff)
                    next = DialogStatus.available;
                else
                    next = DialogStatus.chat;
            }
            else
                next = DialogStatus.unavailable;
            if (next > result)
                result = next;
        }
        return result;
    }

    /// The client asks for the mark over a quest giver.
    @Handles(Opcode.CMSG_QUESTGIVER_STATUS_QUERY, WorldState.inWorld)
    void handleQuestgiverStatusQuery(const ClientGuid request)
    {
        import dmangos.world.gameobject : GameObject;

        QuestGiver giver;
        if (auto npc = context.npcFor(map.findObject(request.guid)))
            giver = giverOf(npc);
        else if (auto go = cast(GameObject) map.findObject(request.guid))
            giver = QuestGiver(go.guid, context.data.quests.gameObjectStarts.get(go.template_.entry, null),
                context.data.quests.gameObjectEnds.get(go.template_.entry, null));
        else
            return;
        ByteWriter w;
        w.put(request.guid);
        w.put(cast(uint) dialogStatus(giver));
        deliver(Opcode.SMSG_QUESTGIVER_STATUS, w.data);
    }

    /// The player talks to a quest giver: as gossip hello.
    @Handles(Opcode.CMSG_QUESTGIVER_HELLO, WorldState.inWorld)
    void handleQuestgiverHello(const ClientNpcGuid request)
    {
        handleGossipHello(request);
    }

    /// The quests the giver takes back or gives, for this player.
    package void prepareQuestMenu(const QuestGiver giver)
    {
        questMenu = null;
        foreach (id; giver.ends)
        {
            const quest = context.data.quests.quest(id);
            if (quest is null)
                continue;
            const status = questState(id);
            if (status == QuestState.complete && !questRewarded(id))
                questMenu ~= GossipQuestItem(id, DialogStatus.rewardRep, quest.levelFor(player.data.level), quest.title);
            else if (status == QuestState.incomplete)
                questMenu ~= GossipQuestItem(id, DialogStatus.incomplete, quest.levelFor(player.data.level), quest.title);
        }
        foreach (id; giver.starts)
        {
            const quest = context.data.quests.quest(id);
            if (quest is null || !canTakeQuest(*quest))
                continue;
            questMenu ~= GossipQuestItem(id, quest.autoComplete ? DialogStatus.rewardRep : DialogStatus.available,
                quest.levelFor(player.data.level), quest.title);
        }
    }

    /// Shows the quest menu: one quest opens at once; several are listed.
    package void sendPreparedQuest(const QuestGiver giver)
    {
        import dmangos.world.objects : HighGuid, highGuidOf;

        if (questMenu.length == 0)
            return;
        // `questgiver_greeting`: a list of several quests is headed by the giver's own words.
        const greeting = context.data.quests.greetingOf(cast(uint)((giver.guid >> 24) & 0xFF_FFFF),
            highGuidOf(giver.guid) == HighGuid.gameObject);
        if (questMenu.length == 1)
        {
            const item = questMenu[0];
            const quest = context.data.quests.quest(item.quest);
            if (item.icon == DialogStatus.rewardRep && !questRewarded(item.quest))
                return sendRequestItems(*quest, giver.guid, canRewardQuest(*quest), true);
            if (item.icon == DialogStatus.incomplete)
                return sendRequestItems(*quest, giver.guid, false, true);
            return sendQuestDetails(*quest, giver.guid, true);
        }
        ByteWriter w;
        w.put(giver.guid);
        w.putCString(greeting is null ? "" : greeting.text);
        w.put(greeting is null ? 0u : greeting.emoteDelay);
        w.put(greeting is null ? 0u : greeting.emote);
        w.put(cast(ubyte) questMenu.length);
        foreach (item; questMenu)
        {
            w.put(item.quest);
            w.put(item.icon);
            w.put(cast(uint) item.level);
            w.putCString(item.title);
        }
        deliver(Opcode.SMSG_QUESTGIVER_QUEST_LIST, w.data);
    }

    /// Whether `giver` gives (`starts`) or takes back the quest.
    bool involves(const QuestGiver giver, uint id, bool starts, bool ends)
    {
        import std.algorithm.searching : canFind;

        return (starts && giver.starts.canFind(id)) || (ends && giver.ends.canFind(id));
    }

    /// The reward items for packets: id, count, display.
    void putRewardItems(ref ByteWriter w, const(uint)[] ids, const(uint)[] counts)
    {
        uint n;
        foreach (id; ids)
            if (id)
                ++n;
        w.put(n);
        foreach (i, id; ids)
            if (id)
            {
                w.put(id);
                w.put(counts[i]);
                const proto = id in context.data.items;
                w.put(proto is null ? 0u : proto.displayId);
            }
    }

    /// A quest's details, with the accept button if `activateAccept`.
    void sendQuestDetails(const ref Quest quest, ulong giver, bool activateAccept)
    {
        ByteWriter w;
        w.put(giver);
        w.put(quest.id);
        w.putCString(quest.title);
        w.putCString(quest.details);
        w.putCString(quest.objectives);
        w.put(uint(activateAccept));
        if (quest.questFlags & questFlagHiddenRewards)
        {
            w.put(0u);
            w.put(0u);
            w.put(0u);
        }
        else
        {
            putRewardItems(w, quest.rewChoiceItemId[], quest.rewChoiceItemCount[]);
            putRewardItems(w, quest.rewItemId[], quest.rewItemCount[]);
            w.put(cast(uint) quest.rewOrReqMoney);
        }
        w.put(quest.rewSpell);
        uint emotes;
        foreach (e; quest.detailsEmote)
            if (e)
                ++emotes;
        w.put(emotes);
        foreach (i; 0 .. emotes)
        {
            w.put(quest.detailsEmote[i]);
            w.put(quest.detailsEmoteDelay[i]);
        }
        deliver(Opcode.SMSG_QUESTGIVER_QUEST_DETAILS, w.data);
    }

    /// What the ender asks for (or, with nothing to ask for, the reward at once).
    void sendRequestItems(const ref Quest quest, ulong giver, bool completable, bool closeOnCancel)
    {
        if (quest.requestItemsText.length == 0 || (quest.reqItemsCount == 0 && completable))
            return sendOfferReward(quest, giver, true);
        ByteWriter w;
        w.put(giver);
        w.put(quest.id);
        w.putCString(quest.title);
        w.putCString(quest.requestItemsText);
        w.put(completable ? quest.completeEmoteDelay : quest.incompleteEmoteDelay);
        w.put(completable ? quest.completeEmote : quest.incompleteEmote);
        w.put(uint(closeOnCancel));
        w.put(quest.rewOrReqMoney < 0 ? cast(uint) -quest.rewOrReqMoney : 0u);
        w.put(quest.reqItemsCount);
        foreach (i; 0 .. questObjectives)
            if (quest.reqItemId[i])
            {
                w.put(quest.reqItemId[i]);
                w.put(quest.reqItemCount[i]);
                const proto = quest.reqItemId[i] in context.data.items;
                w.put(proto is null ? 0u : proto.displayId);
            }
        w.put(0x02u);
        w.put(completable ? 0x03u : 0u);
        w.put(0x04u);
        w.put(0x08u);
        w.put(0x10u);
        deliver(Opcode.SMSG_QUESTGIVER_REQUEST_ITEMS, w.data);
    }

    /// The reward the ender offers.
    void sendOfferReward(const ref Quest quest, ulong giver, bool enableNext)
    {
        ByteWriter w;
        w.put(giver);
        w.put(quest.id);
        w.putCString(quest.title);
        w.putCString(quest.offerRewardText);
        w.put(uint(enableNext));
        uint emotes;
        foreach (e; quest.offerRewardEmote)
        {
            if (e == 0)
                break;
            ++emotes;
        }
        w.put(emotes);
        foreach (i; 0 .. emotes)
        {
            w.put(quest.offerRewardEmoteDelay[i]);
            w.put(quest.offerRewardEmote[i]);
        }
        putRewardItems(w, quest.rewChoiceItemId[], quest.rewChoiceItemCount[]);
        putRewardItems(w, quest.rewItemId[], quest.rewItemCount[]);
        w.put(cast(uint) quest.rewOrReqMoney);
        w.put(quest.rewSpell);
        w.put(quest.rewSpellCast);
        deliver(Opcode.SMSG_QUESTGIVER_OFFER_REWARD, w.data);
    }

    /// The client asks for a quest's details from a giver that has it.
    @Handles(Opcode.CMSG_QUESTGIVER_QUERY_QUEST, WorldState.inWorld)
    void handleQuestgiverQueryQuest(ref ByteReader reader)
    {
        const guid = reader.read!ulong, id = reader.read!uint;
        QuestGiver giver;
        const near = questGiverNear(guid, 0, giver);
        const quest = context.data.quests.quest(id);
        if (!near || quest is null || !involves(giver, id, true, true))
            return deliver(Opcode.SMSG_GOSSIP_COMPLETE, null);
        sendQuestDetails(*quest, guid, true);
    }

    /// The client asks for the quest as the log shows it.
    @Handles(Opcode.CMSG_QUEST_QUERY, WorldState.inWorld)
    void handleQuestQuery(ref ByteReader reader)
    {
        const id = reader.read!uint;
        const quest = context.data.quests.quest(id);
        if (quest is null)
            return;
        ByteWriter w;
        w.put(quest.id);
        w.put(quest.method);
        w.put(cast(uint) quest.questLevel);
        w.put(cast(uint) quest.zoneOrSort);
        w.put(quest.type);
        w.put(quest.repObjectiveFaction);
        w.put(quest.repObjectiveValue);
        w.put(0u);
        w.put(0u);
        w.put(quest.nextQuestInChain);
        const hidden = (quest.questFlags & questFlagHiddenRewards) != 0;
        w.put(hidden ? 0u : cast(uint) quest.rewOrReqMoney);
        w.put(quest.rewMoneyMaxLevel);
        w.put(quest.rewSpell);
        w.put(quest.srcItemId);
        w.put(quest.questFlags);
        foreach (i; 0 .. questRewards)
        {
            w.put(hidden ? 0u : quest.rewItemId[i]);
            w.put(hidden ? 0u : quest.rewItemCount[i]);
        }
        foreach (i; 0 .. questRewardChoices)
        {
            w.put(hidden ? 0u : quest.rewChoiceItemId[i]);
            w.put(hidden ? 0u : quest.rewChoiceItemCount[i]);
        }
        w.put(quest.pointMapId);
        w.put(quest.pointX);
        w.put(quest.pointY);
        w.put(quest.pointOpt);
        w.putCString(quest.title);
        w.putCString(quest.objectives);
        w.putCString(quest.details);
        w.putCString(quest.endText);
        foreach (i; 0 .. questObjectives)
        {
            const target = quest.reqCreatureOrGoId[i];
            w.put(target < 0 ? (cast(uint) -target) | 0x80000000 : cast(uint) target);
            w.put(quest.reqCreatureOrGoCount[i]);
            w.put(quest.reqItemId[i]);
            w.put(quest.reqItemCount[i]);
        }
        foreach (i; 0 .. questObjectives)
            w.putCString(quest.objectiveText[i]);
        deliver(Opcode.SMSG_QUEST_QUERY_RESPONSE, w.data);
    }

    /// The player accepts a quest from a giver, an item or a group member who shared it.
    @Handles(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, WorldState.inWorld)
    void handleQuestgiverAcceptQuest(ref ByteReader reader)
    {
        import dmangos.world.character : Character;

        const guid = reader.read!ulong, id = reader.read!uint;
        QuestGiver giver;
        bool near = questGiverNear(guid, 0x2, giver);
        // A quest a group member shared (checked as sharable on its side).
        auto sharer = near ? null : cast(Character) context.onlinePlayer(guid);
        if (sharer !is null && sharer !is this && sharer.player !is null && sharer.canShareQuest(id))
        {
            giver = QuestGiver(guid, [id], null);
            near = true;
        }
        const quest = context.data.quests.quest(id);
        deliver(Opcode.SMSG_GOSSIP_COMPLETE, null);
        if (!near || quest is null || !involves(giver, id, true, false))
            return;
        if (!canTakeQuest(*quest))
        {
            ByteWriter w;
            w.put(questState(id) != QuestState.none ? invalidAlreadyOn : invalidDontHaveReq);
            return deliver(Opcode.SMSG_QUESTGIVER_QUEST_INVALID, w.data);
        }
        if (questSlot(0) >= maxQuestLogSize)
            return deliver(Opcode.SMSG_QUESTLOG_FULL, null);
        addQuest(*quest);
        // The quest's start script, the giver the source and the player the target.
        if (quest.startScript)
        {
            import dmangos.world.dbscripts : DbScriptType;

            context.startScript(DbScriptType.questStart, quest.startScript, map, giver.guid, player.guid);
        }
        // The giver's script hears of it: an escort sets off, say.
        if (auto creature = cast(Creature) map.findObject(giver.guid))
        {
            import dmangos.script.api : EntityRef, QuestAccepted;

            creature.ai.raiseFrom(map, QuestAccepted(EntityRef(player.guid), id));
        }
        // Open-world round 2: a game object giver's script too (the Crystalline Tear).
        else if (auto go = cast(imported!"dmangos.world.gameobject".GameObject) map.findObject(giver.guid))
        {
            import dmangos.script.api : EntityRef;

            context.gameObjectQuestAccepted(go, map, EntityRef(player.guid), id);
        }
        if (auto divider = cast(Character) context.onlinePlayer(questDivider))
            divider.pushToPartyResponse(player.guid, QuestShare.accepted);
        questDivider = 0;
        // An escort for the party: each member who could take it is asked to (`SMSG_QUEST_CONFIRM_ACCEPT`).
        if (quest.questFlags & questFlagPartyAccept)
            offerToParty(*quest);
        // The item that began it goes, unless the quest asks for it or gives it.
        if (giver.itemEntry && quest.srcItemId != giver.itemEntry)
        {
            import std.algorithm.searching : canFind;

            if (!quest.reqItemId[].canFind(giver.itemEntry))
                if (auto item = itemByGuid(guid))
                {
                    player.inventory.destroy(item.bagSlot, item.slot);
                    flushInventory(true);
                }
        }
        if (canCompleteQuest(id))
            completeQuest(id);
        if (quest.srcSpell)
            if (const spell = context.data.spells.spell(quest.srcSpell))
                castSpell(spell, SpellTargets(TargetFlags.self, player.guid), true, 0);
        flushPlayerChanges();
    }

    /// Adds the quest to the log, its objectives at zero (items: what is carried), its starting item given.
    package void addQuest(const ref Quest quest)
    {
        const slot = questSlot(0);
        auto q = &statusOf(quest.id);
        q.status = QuestState.incomplete;
        q.explored = false;
        q.mobCount = 0;
        q.itemCount = 0;
        q.changed = true;
        // A timed quest: its end, in the log and saved.
        q.timer = (quest.specialFlags & specialTimed) ? context.unixTime + quest.limitTime : 0;
        setQuestSlot(slot, quest.id, cast(uint) q.timer);
        if (quest.srcItemId && player.inventory.count(quest.srcItemId) == 0)
            giveItem(quest.srcItemId, quest.srcItemCount ? quest.srcItemCount : 1);
        foreach (i; 0 .. questObjectives)
            if (quest.reqItemId[i])
            {
                const have = player.inventory.count(quest.reqItemId[i]);
                q.itemCount[i] = have < quest.reqItemCount[i] ? have : quest.reqItemCount[i];
            }
        info!"%s: '%s' took quest %s (%s)"(remoteAddress, player.data.name, quest.id, quest.title);
    }

    /// The quest's objectives met; the log shows it complete.
    void completeQuest(uint id)
    {
        auto q = &statusOf(id);
        q.status = QuestState.complete;
        q.changed = true;
        const slot = questSlot(id);
        if (slot < maxQuestLogSize)
            setQuestSlotState(slot, 1, true);
        ByteWriter w;
        w.put(id);
        deliver(Opcode.SMSG_QUESTUPDATE_COMPLETE, w.data);
    }

    /// The quest's place found (or its event happened); complete if that was all.
    package void areaExploredOrEventHappens(uint id)
    {
        const slot = questSlot(id);
        if (slot < maxQuestLogSize)
        {
            auto q = &statusOf(id);
            if (!q.explored)
            {
                setQuestSlotState(slot, 1, true);
                ByteWriter w;
                w.put(id);
                deliver(Opcode.SMSG_QUESTUPDATE_COMPLETE, w.data);
                q.explored = true;
                q.changed = true;
            }
        }
        if (canCompleteQuest(id))
            completeQuest(id);
        flushPlayerChanges();
    }

    /// A script's kill credit, sent.
    package void scriptKillCredit(uint entry, ulong guid)
    {
        killedMonster(entry, guid);
        flushPlayerChanges();
    }

    /// A quest under way failed (a script found the player too far, or its creature dead).
    package void failQuest(uint id)
    {
        auto q = id in player.questStatus;
        if (q is null || q.status != QuestState.incomplete)
            return;
        q.status = QuestState.failed;
        q.changed = true;
        const slot = questSlot(id);
        if (slot < maxQuestLogSize)
            setQuestSlotState(slot, 2, true); // failed
        const quest = context.data.quests.quest(id);
        const timed = quest !is null && (quest.specialFlags & specialTimed);
        ByteWriter w;
        w.put(id);
        if (timed)
            q.timer = 0; // its time is gone
        deliver(timed ? Opcode.SMSG_QUESTUPDATE_FAILEDTIMER : Opcode.SMSG_QUESTUPDATE_FAILED, w.data);
        flushPlayerChanges();
    }

    /// An objective no longer met (an item given away).
    void incompleteQuest(uint id)
    {
        auto q = &statusOf(id);
        q.status = QuestState.incomplete;
        q.changed = true;
        const slot = questSlot(id);
        if (slot < maxQuestLogSize)
            setQuestSlotState(slot, 1, false);
    }

    /// The player turns to a quest's ender: what it asks for.
    @Handles(Opcode.CMSG_QUESTGIVER_COMPLETE_QUEST, WorldState.inWorld)
    void handleQuestgiverCompleteQuest(ref ByteReader reader)
    {
        const guid = reader.read!ulong, id = reader.read!uint;
        QuestGiver giver;
        const near = questGiverNear(guid, 0x2, giver);
        const quest = context.data.quests.quest(id);
        if (!near || quest is null || !involves(giver, id, false, true))
            return;
        sendRequestItems(*quest, guid, canRewardQuest(*quest), false);
    }

    /// The client asks for the rewards to choose from.
    @Handles(Opcode.CMSG_QUESTGIVER_REQUEST_REWARD, WorldState.inWorld)
    void handleQuestgiverRequestReward(ref ByteReader reader)
    {
        const guid = reader.read!ulong, id = reader.read!uint;
        QuestGiver giver;
        const near = questGiverNear(guid, 0x2, giver);
        const quest = context.data.quests.quest(id);
        if (!near || quest is null || !involves(giver, id, false, true))
            return;
        if (canCompleteQuest(id))
            completeQuest(id);
        if (questState(id) != QuestState.complete && !quest.autoComplete)
            return;
        sendOfferReward(*quest, guid, true);
    }

    /// The player chose a reward: the quest turned in; the next quest of the chain offered.
    @Handles(Opcode.CMSG_QUESTGIVER_CHOOSE_REWARD, WorldState.inWorld)
    void handleQuestgiverChooseReward(ref ByteReader reader)
    {
        const guid = reader.read!ulong, id = reader.read!uint, reward = reader.read!uint;
        if (reward >= questRewardChoices)
            return;
        QuestGiver giver;
        const near = questGiverNear(guid, 0x2, giver);
        const quest = context.data.quests.quest(id);
        if (!near || quest is null || !involves(giver, id, false, true))
            return;
        if (!canRewardQuest(*quest) || !roomForRewards(*quest, reward))
            return sendOfferReward(*quest, guid, true);
        rewardQuest(*quest, reward);
        if (quest.rewMailTemplateId)
            sendQuestMail(*quest, guid);
        // The quest's complete script, the ender the source and the player the target.
        if (quest.completeScript)
        {
            import dmangos.world.dbscripts : DbScriptType;

            context.startScript(DbScriptType.questEnd, quest.completeScript, map, guid, player.guid);
        }
        if (auto creature = cast(Creature) map.findObject(guid))
        {
            import dmangos.script.api : EntityRef, QuestRewarded;

            creature.ai.raiseFrom(map, QuestRewarded(EntityRef(player.guid), id));
        }
        if (quest.nextQuestInChain)
            if (const next = context.data.quests.quest(quest.nextQuestInChain))
                if (involves(giver, next.id, true, false) && canTakeQuest(*next))
                    sendQuestDetails(*next, guid, true);
    }

    /// Whether there is room for the chosen item and the others.
    bool roomForRewards(const ref Quest quest, uint reward)
    {
        ItemPosCount[] dest;
        bool full;
        if (quest.rewChoiceCount && quest.rewChoiceItemId[reward])
            full |= player.inventory.canStoreNew(nullBag, nullSlot, dest, quest.rewChoiceItemId[reward],
                quest.rewChoiceItemCount[reward]) != InventoryResult.ok;
        foreach (i; 0 .. questRewards)
            if (quest.rewItemId[i])
                full |= player.inventory.canStoreNew(nullBag, nullSlot, dest, quest.rewItemId[i], quest.rewItemCount[i])
                    != InventoryResult.ok;
        if (full)
            sendEquipError(InventoryResult.inventoryFull);
        return !full;
    }

    /**
     * Turns the quest in: the items asked for taken, the rewards given (the chosen item, the others,
     * experience or at the top level money, money, the spell), the log slot freed, the quest done.
     */
    /**
     * The letter a quest sends once rewarded: from its ender (a creature), with its template's text and
     * the first item its template's loot gives, after the quest's delay.
     */
    void sendQuestMail(const ref Quest quest, ulong ender)
    {
        import dmangos.world.database : MailRecord;
        import dmangos.world.loot : Loot;
        import dmangos.world.objects : HighGuid, highGuidOf;

        enum ubyte mailCreature = 3, mailGameObject = 4;
        MailRecord m;
        m.messageType = highGuidOf(ender) == HighGuid.gameObject ? mailGameObject : mailCreature;
        m.sender = cast(uint)((ender >> 24) & 0xFF_FFFF); // the ender's entry
        m.receiver = player.data.guid;
        m.templateId = quest.rewMailTemplateId;
        if (const template_ = context.data.loot.mail[quest.rewMailTemplateId])
        {
            auto loot = new Loot(0, null);
            loot.owners[player.guid] = true;
            loot.fill(template_, context.data.loot, context.data.items, map.random, (uint c) => conditionMet(c), null);
            foreach (lootItem; loot.items)
                if (auto item = player.inventory.create(lootItem.itemId, lootItem.count, lootItem.randomPropertyId > 0
                        ? lootItem.randomPropertyId : 0))
                {
                    const record = item.record;
                    context.database.saveLooseItem(record, player.data.guid);
                    m.itemGuid = record.guid;
                    m.itemEntry = record.entry;
                    break; // a letter holds one item
                }
        }
        context.postMail(m, quest.rewMailDelaySecs);
    }

    void rewardQuest(const ref Quest quest, uint reward)
    {
        foreach (i; 0 .. questObjectives)
            if (quest.reqItemId[i])
                player.inventory.destroyCount(quest.reqItemId[i], quest.reqItemCount[i]);
        if (quest.rewChoiceCount && quest.rewChoiceItemId[reward])
            giveItem(quest.rewChoiceItemId[reward], quest.rewChoiceItemCount[reward]);
        foreach (i; 0 .. questRewards)
            if (quest.rewItemId[i])
                giveItem(quest.rewItemId[i], quest.rewItemCount[i]);
        const slot = questSlot(quest.id);
        if (slot < maxQuestLogSize)
            setQuestSlot(slot, 0);
        const xp = questXp(quest, player.data.level);
        uint maxLevelMoney;
        if (player.data.level < context.config.maxPlayerLevel)
            giveXP(xp);
        else
            maxLevelMoney = quest.rewMoneyMaxLevel;
        // A quest pays (rewOrReqMoney > 0), or costs what canRewardQuest saw the purse hold (< 0).
        if (quest.rewOrReqMoney >= 0)
            player.receive(Copper(quest.rewOrReqMoney) + Copper(maxLevelMoney));
        else
        {
            player.pay(Copper(-quest.rewOrReqMoney));
            player.receive(Copper(maxLevelMoney));
        }
        rewardQuestReputation(quest);
        auto q = &statusOf(quest.id);
        q.status = quest.repeatable ? QuestState.none : QuestState.complete;
        q.rewarded = true;
        q.changed = true;
        ByteWriter w;
        w.put(quest.id);
        w.put(0x03u);
        w.put(player.data.level < context.config.maxPlayerLevel ? xp : 0u);
        w.put(cast(uint)(quest.rewOrReqMoney + maxLevelMoney));
        w.put(quest.rewItemsCount);
        foreach (i; 0 .. questRewards)
            if (quest.rewItemId[i])
            {
                w.put(quest.rewItemId[i]);
                w.put(quest.rewItemCount[i]);
            }
        deliver(Opcode.SMSG_QUESTGIVER_QUEST_COMPLETE, w.data);
        // `RewSpellCast` is cast on the player; else `RewSpell`.
        const spellId = quest.rewSpellCast ? quest.rewSpellCast : quest.rewSpell;
        if (spellId)
            if (const spell = context.data.spells.spell(spellId))
                castSpell(spell, SpellTargets(TargetFlags.self, player.guid), true, 0);
        flushInventory(true);
        saveQuests();
        info!"%s: '%s' turned in quest %s (%s xp)"(remoteAddress, player.data.name, quest.id, xp);
    }

    // -----------------------------------------------------------------------
    // Sharing
    // -----------------------------------------------------------------------

    package ulong questDivider; // who shared the quest this player is offered

    /// The members of the player's group in the world who could take `quest` are asked to: `SMSG_QUEST_CONFIRM_ACCEPT`.
    private void offerToParty(const ref Quest quest)
    {
        auto group = context.groups.of(player.guid);
        if (group is null)
            return;
        foreach (ref m; group.members)
        {
            if (m.guid == player.guid)
                continue;
            auto member = cast(typeof(this)) context.onlinePlayer(m.guid);
            if (member is null || member.player is null || !member.canTakeQuest(quest))
                continue;
            member.questDivider = player.guid;
            member.closeGossip();
            ByteWriter w;
            w.put(quest.id);
            w.putCString(quest.title);
            w.put(player.guid);
            member.deliver(Opcode.SMSG_QUEST_CONFIRM_ACCEPT, w.data);
        }
    }

    /**
     * A member takes the escort it was offered: the one who offered it is in its group (its party, for a
     * quest not for raids), and it may take the quest.
     */
    @Handles(Opcode.CMSG_QUEST_CONFIRM_ACCEPT, WorldState.inWorld)
    void handleQuestConfirmAccept(ref ByteReader reader)
    {
        const id = reader.read!uint;
        const quest = id in context.data.quests.quests;
        if (quest is null || !(quest.questFlags & questFlagPartyAccept) || !questDivider)
            return;
        auto group = context.groups.of(player.guid);
        if (group is null || context.groups.of(questDivider) !is group)
            return;
        questDivider = 0;
        if (canTakeQuest(*quest))
        {
            addQuest(*quest);
            flushInventory(true); // its source item
            flushPlayerChanges();
        }
    }

    /// What became of a quest shared with a group member (`MSG_QUEST_PUSH_RESULT`).
    enum QuestShare : ubyte
    {
        sharing = 0,
        cantTake = 1,
        accepted = 2,
        declined = 3,
        tooFar = 4,
        busy = 5,
        logFull = 6,
        haveQuest = 7,
        finished = 8,
    }

    /// Whether the player may share quest `id`: a sharable quest under way.
    package bool canShareQuest(uint id)
    {
        const quest = context.data.quests.quest(id);
        if (quest is null || !(quest.questFlags & questFlagSharable))
            return false;
        const q = id in player.questStatus;
        return q !is null && (q.status == QuestState.incomplete || (q.status == QuestState.complete && !q.rewarded));
    }

    /// Tells this player what became of the sharing with `member`.
    package void pushToPartyResponse(ulong member, QuestShare message)
    {
        ByteWriter w;
        w.put(member);
        w.put(cast(ubyte) message);
        deliver(Opcode.MSG_QUEST_PUSH_RESULT, w.data);
    }

    /// The quest offered to the group's members near (10 yards) who may take it.
    @Handles(Opcode.CMSG_PUSHQUESTTOPARTY, WorldState.inWorld)
    void handlePushQuestToParty(ref ByteReader reader)
    {
        import dmangos.world.character : Character;

        const id = reader.read!uint;
        if (!canShareQuest(id))
            return;
        const quest = context.data.quests.quest(id);
        auto group = context.groups.of(player.guid);
        if (group is null)
            return;
        foreach (ref slot; group.members)
        {
            auto member = cast(Character) context.onlinePlayer(slot.guid);
            if (member is null || member is this || member.player is null || member.map !is map)
                continue;
            pushToPartyResponse(member.player.guid, QuestShare.sharing);
            const a = player.position, b = member.player.position;
            if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 > 10 * 10)
            {
                pushToPartyResponse(member.player.guid, QuestShare.tooFar);
                continue;
            }
            if (!member.satisfyStatus(*quest))
            {
                pushToPartyResponse(member.player.guid, QuestShare.haveQuest);
                continue;
            }
            if (member.questState(id) == QuestState.complete)
            {
                pushToPartyResponse(member.player.guid, QuestShare.finished);
                continue;
            }
            if (!member.canTakeQuest(*quest))
            {
                pushToPartyResponse(member.player.guid, QuestShare.cantTake);
                continue;
            }
            if (member.questSlot(0) >= maxQuestLogSize)
            {
                pushToPartyResponse(member.player.guid, QuestShare.logFull);
                continue;
            }
            if (member.questDivider)
            {
                pushToPartyResponse(member.player.guid, QuestShare.busy);
                continue;
            }
            member.sendQuestDetails(*quest, player.guid, true);
            member.questDivider = player.guid;
        }
    }

    /// The member's answer, for the one who shared.
    @Handles(Opcode.MSG_QUEST_PUSH_RESULT, WorldState.inWorld)
    void handleQuestPushResult(ref ByteReader reader)
    {
        import dmangos.world.character : Character;

        const guid = reader.read!ulong;
        const message = reader.read!ubyte;
        if (auto sharer = cast(Character) context.onlinePlayer(questDivider))
        {
            ByteWriter w;
            w.put(guid);
            w.put(uint(message));
            w.put(ubyte(0));
            sharer.deliver(Opcode.MSG_QUEST_PUSH_RESULT, w.data);
        }
        questDivider = 0;
    }

    /// The player closed the quest giver's window.
    @Handles(Opcode.CMSG_QUESTGIVER_CANCEL, WorldState.inWorld)
    void handleQuestgiverCancel()
    {
        deliver(Opcode.SMSG_GOSSIP_COMPLETE, null);
    }

    /// The player swapped two quest log slots.
    @Handles(Opcode.CMSG_QUESTLOG_SWAP_QUEST, WorldState.inWorld)
    void handleQuestLogSwapQuest(ref ByteReader reader)
    {
        const a = reader.read!ubyte, b = reader.read!ubyte;
        if (a == b || a >= maxQuestLogSize || b >= maxQuestLogSize)
            return;
        foreach (i; 0 .. 3)
        {
            const first = player.values[PLAYER_QUEST_LOG_1_1 + 3 * a + i];
            player.values.setSlot(PLAYER_QUEST_LOG_1_1 + 3 * a + i, player.values[PLAYER_QUEST_LOG_1_1 + 3 * b + i]);
            player.values.setSlot(PLAYER_QUEST_LOG_1_1 + 3 * b + i, first);
        }
        flushPlayerChanges();
    }

    /// The player abandoned a quest.
    @Handles(Opcode.CMSG_QUESTLOG_REMOVE_QUEST, WorldState.inWorld)
    void handleQuestLogRemoveQuest(ref ByteReader reader)
    {
        const slot = reader.read!ubyte;
        if (slot >= maxQuestLogSize)
            return;
        const id = player.values[PLAYER_QUEST_LOG_1_1 + 3 * slot];
        if (id)
        {
            auto q = &statusOf(id);
            q.status = QuestState.none;
            q.mobCount = 0;
            q.itemCount = 0;
            q.changed = true;
        }
        setQuestSlot(slot, 0);
        flushPlayerChanges();
        saveQuests();
    }

    // -----------------------------------------------------------------------
    // Objectives
    // -----------------------------------------------------------------------

    /// A creature of `entry` killed counts for the quests that ask for it.
    package void killedMonster(uint entry, ulong guid)
    {
        creditCreatureOrGo(cast(int) entry, 0, guid);
    }

    /**
     * Credit for a kill, or a spell cast on a creature or game object: `target` (a creature's entry, or minus a game
     * object's) counts for the objectives that ask for it with `spell` (0: killed, or used).
     */
    package void creditCreatureOrGo(int target, uint spell, ulong guid)
    {
        foreach (slot; 0 .. maxQuestLogSize)
        {
            const id = player.values[PLAYER_QUEST_LOG_1_1 + 3 * slot];
            if (id == 0)
                continue;
            const quest = context.data.quests.quest(id);
            auto q = id in player.questStatus;
            if (quest is null || q is null || q.status != QuestState.incomplete || !quest.killOrCast)
                continue;
            foreach (i; 0 .. questObjectives)
            {
                if (quest.reqCreatureOrGoId[i] != target || quest.reqSpellCast[i] != spell)
                    continue;
                if (q.mobCount[i] >= quest.reqCreatureOrGoCount[i])
                    continue;
                ++q.mobCount[i];
                q.changed = true;
                ByteWriter w;
                w.put(id);
                // A game object's entry as the client expects it: with the high bit.
                w.put(target < 0 ? cast(uint)(-target) | 0x8000_0000 : cast(uint) target);
                w.put(q.mobCount[i]);
                w.put(quest.reqCreatureOrGoCount[i]);
                w.put(guid);
                deliver(Opcode.SMSG_QUESTUPDATE_ADD_KILL, w.data);
                setQuestSlotCounter(slot, i, q.mobCount[i]);
                if (canCompleteQuest(id))
                    completeQuest(id);
            }
        }
        flushPlayerChanges();
    }

    /// Whether a quest under way still needs `target` (as `creditCreatureOrGo` counts it).
    package bool needsCreatureOrGo(int target)
    {
        foreach (id, ref q; player.questStatus)
        {
            if (q.status != QuestState.incomplete)
                continue;
            if (const quest = context.data.quests.quest(id))
                foreach (i; 0 .. questObjectives)
                    if (quest.reqCreatureOrGoId[i] == target && q.mobCount[i] < quest.reqCreatureOrGoCount[i])
                        return true;
        }
        return false;
    }

    /**
     * After items were added or removed: what the player carries of each item
     * its quests ask for, as their counts; a quest whose items are all there is complete, and one that
     * lost some is not.
     */
    package void questItemsChanged()
    {
        if (player is null)
            return;
        foreach (slot; 0 .. maxQuestLogSize)
        {
            const id = player.values[PLAYER_QUEST_LOG_1_1 + 3 * slot];
            if (id == 0)
                continue;
            const quest = context.data.quests.quest(id);
            auto q = id in player.questStatus;
            if (quest is null || q is null || !quest.deliver)
                continue;
            if (q.status != QuestState.incomplete && q.status != QuestState.complete)
                continue;
            foreach (i; 0 .. questObjectives)
            {
                if (!quest.reqItemId[i])
                    continue;
                const have = player.inventory.count(quest.reqItemId[i]);
                const counted = have < quest.reqItemCount[i] ? have : quest.reqItemCount[i];
                if (counted == q.itemCount[i])
                    continue;
                if (counted > q.itemCount[i])
                {
                    ByteWriter w;
                    w.put(quest.reqItemId[i]);
                    w.put(counted - q.itemCount[i]);
                    deliver(Opcode.SMSG_QUESTUPDATE_ADD_ITEM, w.data);
                }
                q.itemCount[i] = counted;
                q.changed = true;
            }
            if (q.status == QuestState.incomplete && canCompleteQuest(id))
                completeQuest(id);
            else if (q.status == QuestState.complete)
                foreach (i; 0 .. questObjectives)
                    if (quest.reqItemId[i] && q.itemCount[i] < quest.reqItemCount[i])
                    {
                        incompleteQuest(id);
                        break;
                    }
        }
    }

    /// Whether a quest taken still asks for the item (a quest drop it may loot).
    package bool hasQuestForItem(uint item)
    {
        foreach (slot; 0 .. maxQuestLogSize)
        {
            const id = player.values[PLAYER_QUEST_LOG_1_1 + 3 * slot];
            if (id == 0)
                continue;
            const quest = context.data.quests.quest(id);
            auto q = id in player.questStatus;
            if (quest is null || q is null || q.status != QuestState.incomplete)
                continue;
            foreach (i; 0 .. questObjectives)
            {
                if (quest.reqItemId[i] == item && q.itemCount[i] < quest.reqItemCount[i])
                    return true;
                if (quest.reqSourceId[i] == item && player.inventory.count(item) < quest.reqSourceCount[i])
                    return true;
            }
        }
        return false;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A whole quest: the trainer offers it, Anduin takes it, kills the innkeeper and loots the jerky it
 * asks for (both count), and turns it in for its money, experience and item.
 */
unittest
{
    import core.time : MonoTime;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.creature : Creature;
    import dmangos.world.loothandlers : ClientLootSlot, killIt, lootableInnkeeper;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid, ClientNpcGuid;
    import dmangos.world.player : Player;
    import dmangos.world.quests;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    Quest q;
    q.id = 5001;
    q.method = 2;
    q.minLevel = 1;
    q.maxLevel = 255;
    q.questLevel = 1;
    q.title = "Mischief at the Inn";
    q.requestItemsText = "Well?";
    q.reqCreatureOrGoId[0] = creatureInnkeeper;
    q.reqCreatureOrGoCount[0] = 1;
    q.reqItemId[0] = itemJerky;
    q.reqItemCount[0] = 1;
    q.rewOrReqMoney = 35;
    q.rewMoneyMaxLevel = 60;
    q.rewMailTemplateId = 103; // a letter a day later, with jerky
    q.rewMailDelaySecs = 86_400;
    q.rewItemId[0] = itemShirt;
    q.rewItemCount[0] = 1;
    context.data.quests.quests[q.id] = q;
    context.data.quests.creatureStarts[creatureTrainer] = [q.id];
    context.data.quests.creatureEnds[creatureTrainer] = [q.id];
    context.data.quests.link();

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.values.set!PLAYER_NEXT_LEVEL_XP(400u); // the test data has no experience table
    auto trainer = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    trainer.values.set!UNIT_NPC_FLAGS(trainer.values.get!UNIT_NPC_FLAGS | 0x2);
    trainer.movement.position = Position(-8948.5f, -132.49f, 83.53f, 0);
    auto victim = lootableInnkeeper(context);

    uint statusOfTrainer()
    {
        anduin.write(Opcode.CMSG_QUESTGIVER_STATUS_QUERY, ClientGuid(trainer.guid));
        auto reply = anduin.read();
        assert(reply.length && reply[$ - 1].opcode == Opcode.SMSG_QUESTGIVER_STATUS);
        auto r = ByteReader(reply[$ - 1].body_);
        r.read!ulong;
        return r.read!uint;
    }

    assert(statusOfTrainer() == DialogStatus.available, "a quest to give: the exclamation mark");
    anduin.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(trainer.guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_GOSSIP_MESSAGE));

    ByteWriter accept;
    accept.put(trainer.guid);
    accept.put(q.id);
    anduin.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    anduin.read();
    assert(me.values[PLAYER_QUEST_LOG_1_1] == q.id && me.questStatus[q.id].status == QuestState.incomplete);
    assertSeesItself(anduin); // the quest is in the client's log too
    assert(statusOfTrainer() == DialogStatus.incomplete);

    // The kill counts; its jerky (a quest drop as well as a plain one here) counts as it is looted.
    killIt(anduin, victim, now);
    auto killed = opcodesOf(anduin.read());
    assert(killed.canFind(Opcode.SMSG_QUESTUPDATE_ADD_KILL) && me.questStatus[q.id].mobCount[0] == 1);
    anduin.write(Opcode.CMSG_LOOT, ClientGuid(victim.guid));
    anduin.read();
    anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
    const looted = opcodesOf(anduin.read());
    assert(looted.canFind(Opcode.SMSG_QUESTUPDATE_ADD_ITEM) && looted.canFind(Opcode.SMSG_QUESTUPDATE_COMPLETE));
    assert(me.questStatus[q.id].status == QuestState.complete);
    assertSeesItself(anduin); // its counts and its state
    assert(statusOfTrainer() == DialogStatus.reward2, "the question mark");

    // Turned in: the jerky taken, 35 copper and the shirt given, 100 experience.
    const money = me.money, xp = me.values[PLAYER_XP];
    ByteWriter request;
    request.put(trainer.guid);
    request.put(q.id);
    anduin.write(Opcode.CMSG_QUESTGIVER_COMPLETE_QUEST, request.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTGIVER_REQUEST_ITEMS));
    ByteWriter choose;
    choose.put(trainer.guid);
    choose.put(q.id);
    choose.put(0u);
    {
        import dmangos.world.loot : lootRow;

        context.data.loot.mail.add(103, lootRow(itemJerky, 100, 0, 1, 1, 0)); // the letter's jerky (after the kill's loot)
    }
    anduin.write(Opcode.CMSG_QUESTGIVER_CHOOSE_REWARD, choose.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTGIVER_QUEST_COMPLETE));
    assertSeesItself(anduin); // out of the log; the money, the experience, the shirt
    assert(me.inventory.count(itemJerky) == 0 && me.inventory.count(itemShirt) == 1);
    assert(me.money == money + Copper(35) && me.values[PLAYER_XP] == xp + questXp(q, 1)); // 60 / 0.6f
    assert(me.questStatus[q.id].rewarded && me.values[PLAYER_QUEST_LOG_1_1] == 0);
    assert(db.questRows[7][q.id].rewarded, "saved");
    assert(statusOfTrainer() == DialogStatus.none, "nothing more");
    // The quest's letter: from the trainer, its template's, the jerky in it, a day from now.
    bool letter;
    foreach (ref m; db.mails)
        if (m.receiver == 7 && m.templateId == 103)
            letter = m.messageType == 3 && m.sender == creatureTrainer && m.itemEntry == itemJerky
                && m.deliverTime >= context.unixTime + 86_400 - 5;
    assert(letter, "the quest's letter is on its way");
}

/**
 * A sharable quest shared with the group: the member near is offered it, takes it from the one who
 * shared it, and that one hears it was accepted. An item that begins a quest gives it, and goes.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGroupName;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState, QuestStatus, questFlagSharable;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    Quest q = {id: 9300, method: 2, maxLevel: 60, questFlags: questFlagSharable, title: "Shared"};
    q.reqCreatureOrGoId[0] = 6;
    q.reqCreatureOrGoCount[0] = 3;
    q.specialFlags = 0x20;
    context.data.quests.quests[9300] = q;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8945, -132, 83.5f));
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    auto me = cast(Player) anduin.session.character, her = cast(Player) jaina.session.character;
    me.questStatus[9300] = QuestStatus(9300, QuestState.incomplete);
    anduin.read();
    jaina.read();

    ByteWriter push;
    push.put(9300u);
    anduin.write(Opcode.CMSG_PUSHQUESTTOPARTY, push.data);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_QUESTGIVER_QUEST_DETAILS), "offered");
    ByteWriter accept;
    accept.put(me.guid);
    accept.put(9300u);
    jaina.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    assert(her.questStatus.get(9300, QuestStatus.init).status == QuestState.incomplete, "taken");
    // Anduin hears: sharing, then accepted.
    ubyte[] answers;
    foreach (packet; anduin.read())
        if (packet.opcode == Opcode.MSG_QUEST_PUSH_RESULT)
            answers ~= packet.body_[8];
    assert(answers == [0, 2]);

    // An item that begins a quest (its `startquest`): its quest's details for its guid, then taken, the item gone.
    context.data.items.edit(itemJerky).details.startQuest = 9301;
    Quest found = {id: 9301, method: 2, maxLevel: 60, title: "A note"};
    found.reqCreatureOrGoId[0] = 6;
    found.reqCreatureOrGoCount[0] = 1;
    found.specialFlags = 0x20;
    context.data.quests.quests[9301] = found;
    anduin.session.inWorld.storeLoot(itemJerky, 1, 0, false);
    ulong noteGuid;
    foreach (item; me.inventory.all())
        if (item.entry == itemJerky)
            noteGuid = item.fullGuid;
    ByteWriter query;
    query.put(noteGuid);
    query.put(9301u);
    anduin.read();
    anduin.write(Opcode.CMSG_QUESTGIVER_QUERY_QUEST, query.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTGIVER_QUEST_DETAILS));
    ByteWriter take;
    take.put(noteGuid);
    take.put(9301u);
    anduin.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, take.data);
    assert(me.questStatus.get(9301, QuestStatus.init).status == QuestState.incomplete && me.inventory.count(itemJerky) == 0);
}

/// A timed quest: its end in the log; one at a time; failed with the timer's notice when its time is up.
unittest
{
    import core.time : msecs, MonoTime, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState, specialTimed;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    Quest q = {id: 9500, method: 2, maxLevel: 60, title: "Hurry", specialFlags: specialTimed | 0x02, limitTime: 60};
    context.data.quests.quests[9500] = q;
    Quest other = {id: 9501, method: 2, maxLevel: 60, title: "Hurry too", specialFlags: specialTimed, limitTime: 60};
    context.data.quests.quests[9501] = other;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    const start = context.unixTime;
    anduin.session.inWorld.addQuest(context.data.quests.quests[9500]);
    assert(me.values[PLAYER_QUEST_LOG_1_1 + 2] == start + 60, "its end in the log");
    assert(!anduin.session.inWorld.canTakeQuest(context.data.quests.quests[9501]), "one timed quest at a time");
    now += 30.seconds;
    anduin.session.update(30_000.msecs);
    assert(me.questStatus[9500].status == QuestState.incomplete);
    anduin.read();
    now += 31.seconds;
    anduin.session.update(31_000.msecs);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTUPDATE_FAILEDTIMER));
    assert(me.questStatus[9500].status == QuestState.failed && me.questStatus[9500].timer == 0);
    assert(!anduin.session.inWorld.canCompleteQuest(9500));
}

/// `questgiver_greeting`: a giver's list of several quests is headed by its words and emote.
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.quests : Quest, QuestGreeting;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    foreach (uint id; [9700, 9701])
    {
        Quest q = {id: id, method: 2, maxLevel: 60, title: "Errand"};
        q.reqCreatureOrGoId[0] = 6;
        q.reqCreatureOrGoCount[0] = 1;
        q.specialFlags = 0x20;
        context.data.quests.quests[id] = q;
        context.data.quests.creatureStarts[creatureTrainer] ~= id;
    }
    context.data.quests.greetings[creatureTrainer] = QuestGreeting("Hail, citizen.", 2, 0);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const trainer = makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn);
    import dmangos.world.creature : Creature;
    import dmangos.world.updatefields : UNIT_NPC_FLAGS;

    (cast(Creature) context.map(0).findObject(trainer)).values.set!UNIT_NPC_FLAGS(2u); // a quest giver only: no gossip
    ByteWriter hello;
    hello.put(trainer);
    anduin.write(Opcode.CMSG_QUESTGIVER_HELLO, hello.data);
    bool seen;
    foreach (packet; anduin.read())
        if (packet.opcode == Opcode.SMSG_QUESTGIVER_QUEST_LIST)
        {
            auto r = ByteReader(packet.body_);
            assert(r.read!ulong == trainer && r.readCString == "Hail, citizen.");
            r.read!uint;
            assert(r.read!uint == 2, "its emote");
            seen = true;
        }
    assert(seen);
}

/// An escort for the party: a member who takes it has the rest of the group asked to, and one who confirms has it too.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGroupName;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState, QuestStatus, questFlagPartyAccept, questFlagSharable;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    Quest q = {id: 9310, method: 2, maxLevel: 60, questFlags: questFlagSharable | questFlagPartyAccept, title: "Escort"};
    q.specialFlags = 0x20;
    context.data.quests.quests[9310] = q;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8945, -132, 83.5f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8946, -133, 83.5f));
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("varian"));
    varian.write(Opcode.CMSG_GROUP_ACCEPT, null);
    auto me = cast(Player) anduin.session.character, him = cast(Player) varian.session.character;
    me.questStatus[9310] = QuestStatus(9310, QuestState.incomplete);
    anduin.read();
    jaina.read();
    varian.read();

    // Shared with Jaina, who takes it: Varian is asked to take it as well.
    ByteWriter push;
    push.put(9310u);
    anduin.write(Opcode.CMSG_PUSHQUESTTOPARTY, push.data);
    varian.read();
    ByteWriter accept;
    accept.put(me.guid);
    accept.put(9310u);
    jaina.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    assert(opcodesOf(varian.read()).canFind(Opcode.SMSG_QUEST_CONFIRM_ACCEPT), "asked");
    ByteWriter confirm;
    confirm.put(9310u);
    varian.write(Opcode.CMSG_QUEST_CONFIRM_ACCEPT, confirm.data);
    assert(him.questStatus.get(9310, QuestStatus.init).status == QuestState.incomplete, "taken");
}
