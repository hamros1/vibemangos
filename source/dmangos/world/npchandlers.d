/**
 * Talking to NPCs (CMaNGOS `Entities/NPCHandler.cpp`, `GossipDef.cpp`, the gossip half of
 * `Player.cpp` and `QueryHandler.cpp`'s NPC texts): gossip menus with their conditions, the texts
 * they show, trainers' lists and lessons, innkeepers' hearthstone binding, bankers, and vendors'
 * lists. Mixed into `dmangos.world.session.WorldSession`.
 *
 * A gossip menu is prepared from `gossip_menu_option` (`PrepareGossipMenu`), shown with its
 * `npc_text` (`SendPreparedGossip`), and its options run when selected (`OnGossipSelect`). Options
 * for services this server does not offer yet (flight masters, auctioneers, stable masters, guild
 * petitions and tabards, battlemasters, talent resets, spirit healers and guides) are left out of
 * the menu rather than shown and doing nothing. Quests do not exist yet, so no quest is listed.
 *
 * A trainer's lesson goes through `CharacterBuilder.learnInWorld`, the port of `Player::learnSpell`
 * that character creation uses, so a lesson teaches what CMaNGOS teaches: the spell, the ranks and
 * spells that come with it, and the skill of a profession.
 */
module dmangos.world.npchandlers;

/// `NPCFlags` (`UNIT_NPC_FLAGS`)
enum NpcFlag : uint
{
    gossip = 0x1,
    questGiver = 0x2,
    vendor = 0x4,
    flightMaster = 0x8,
    trainer = 0x10,
    spiritHealer = 0x20,
    spiritGuide = 0x40,
    innkeeper = 0x80,
    banker = 0x100,
    petitioner = 0x200,
    tabardDesigner = 0x400,
    battlemaster = 0x800,
    auctioneer = 0x1000,
    stableMaster = 0x2000,
    repair = 0x4000,
}

/// `TrainerType`
enum TrainerType : uint
{
    classes = 0,
    mounts = 1,
    tradeskills = 2,
    pets = 3,
}

/// `TrainerSpellState`; `greenDisabled` is sent as green.
enum TrainerSpellState : ubyte
{
    green = 0,
    red = 1,
    gray = 2,
    greenDisabled = 10,
}

/// See the module documentation.
mixin template NpcHandlers()
{
    import dmangos.world.player : DeathState;
    import std.algorithm.comparison : max;
    import std.algorithm.searching : any, canFind;
    import std.math : floor, sqrt;
    import dmangos.log;
    import dmangos.world.conditions : ConditionSubject;
    import dmangos.world.creature : Creature, Npc;
    import dmangos.world.defines : PlayerClass, SkillCategory;
    import dmangos.world.npcdata;
    import dmangos.world.npchandlers : NpcFlag, TrainerSpellState, TrainerType;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : HomeBind;
    import dmangos.world.playercreate : CharacterBuilder, KnownAbilities, LearnEvent, NewSkill;
    import dmangos.world.spells : SpellEffect;
    import dmangos.world.updatefields;
    import dmangos.world.worlddata : ItemTemplate;

private:
    /// `INTERACTION_DISTANCE`, in yards, to which both units' combat reach is added.
    enum float interactionDistance = 5;

    /// `DEFAULT_GOSSIP_MESSAGE`: the client's own "Greetings" text.
    enum uint defaultGossipMessage = 0xFF_FFFF;

    /// The spell an innkeeper casts to bind the hearthstone (`Bind`).
    enum uint bindSpell = 3286;

    /// One line of the prepared gossip menu (`GossipMenuItem` and its `GossipMenuItemData`).
    struct GossipItem
    {
        uint icon;
        string message;
        uint optionId;
        string boxMessage;
        bool coded;
        int actionMenu;
        uint actionPoi;
        uint actionScript;
    }

    // The menu last sent (`PlayerMenu`).
    uint gossipMenuId;
    GossipItem[] gossipItems;
    uint[] scriptGossipActions; // the menu shown is a script's: its options' actions
    bool scriptGossipShown;

    // -----------------------------------------------------------------------
    // Finding the NPC (Player::GetNPCIfCanInteractWith)
    // -----------------------------------------------------------------------

    /// The creature `guid` on the player's map, if it has one of `npcFlags` (0: any) and is close enough.
    Npc interactableNpc(ulong guid, uint npcFlags)
    {
        if (transferring)
            return null;
        auto creature = context.npcFor(map.findObject(guid)); // a creature, or another node's (phase 5)
        if (creature is null)
            return null;
        if (npcFlags && !(creature.npcValues.get!UNIT_NPC_FLAGS & npcFlags))
            return null;
        // `GetNPCIfCanInteractWith`: the dead talk only to spirit healers and guides.
        enum uint spiritServices = 0x20 | 0x40; // UNIT_NPC_FLAG_SPIRITHEALER, _SPIRITGUIDE
        if (player.deathState != DeathState.alive && !(creature.npcValues.get!UNIT_NPC_FLAGS & spiritServices))
            return null;
        // WorldObject::IsWithinDistInMap: the distance plus both combat reaches.
        const a = player.position, b = creature.position;
        const reach = interactionDistance + player.values.get!UNIT_FIELD_COMBATREACH
            + creature.npcValues.get!UNIT_FIELD_COMBATREACH;
        if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 >= reach ^^ 2)
            return null;
        return creature;
    }

    /// What conditions are checked for: this player, next to `source`.
    ConditionSubject conditionSubject(Npc source)
    {
        bool creatureInRange(uint entry, float range)
        {
            foreach (object; map.objectsNear(source.position, range))
                if (auto other = context.npcFor(object))
                    if (other.npcTemplate.entry == entry && other.guid != source.guid)
                        return true;
            return false;
        }

        return ConditionSubject(player, source is null ? null : &creatureInRange);
    }

    bool conditionMet(uint conditionId, Npc source)
    {
        const subject = conditionSubject(source);
        return context.data.npcs.conditions.satisfied(conditionId, subject, context.client);
    }

    static bool isFemale(Npc creature)
    {
        return creature.npcValues.getByte!UNIT_FIELD_BYTES_0(2) == 1;
    }

    // -----------------------------------------------------------------------
    // Gossip (Player::PrepareGossipMenu, SendPreparedGossip, OnGossipSelect)
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_GOSSIP_HELLO, WorldState.inWorld)
    void handleGossipHello(const ClientNpcGuid request)
    {
        auto creature = interactableNpc(request.guid, 0);
        if (creature is null)
            return;
        scriptGossipShown = false;
        // Its script first (`GossipHello`): it may show its own menu.
        if (auto scripted = cast(Creature) map.findObject(request.guid))
        {
            import dmangos.script.api : EntityRef, GossipHello;

            if (scripted.ai.raiseFrom(map, GossipHello(EntityRef(player.guid))))
                return;
        }
        prepareGossipMenu(creature, creature.npcTemplate.gossipMenuId);
        // `PrepareGossipMenu`'s quests; without gossip of its own a quest giver shows them alone.
        enum uint gossipFlag = 0x1;
        questMenu = null;
        const flags = creature.npcValues.get!UNIT_NPC_FLAGS;
        if (flags & NpcFlag.questGiver)
            prepareQuestMenu(giverOf(creature));
        if (!(flags & gossipFlag) && questMenu.length)
            return sendPreparedQuest(giverOf(creature));
        sendPreparedGossip(creature);
    }

    @Handles(Opcode.CMSG_GOSSIP_SELECT_OPTION, WorldState.inWorld)
    void handleGossipSelectOption(const ClientGossipSelectOption request)
    {
        if (auto creature = interactableNpc(request.guid, 0))
        {
            if (auto scripted = cast(Creature) map.findObject(request.guid))
            {
                import dmangos.script.api : EntityRef, GossipSelect;

                // A menu the script built: the option's action is the script's to act on.
                if (scriptGossipShown)
                {
                    if (request.option < scriptGossipActions.length)
                        scripted.ai.raiseFrom(map, GossipSelect(EntityRef(player.guid), 0, request.option,
                            scriptGossipActions[request.option]));
                    return;
                }
                if (scripted.ai.raiseFrom(map, GossipSelect(EntityRef(player.guid), gossipMenuId, request.option)))
                    return;
            }
            onGossipSelect(creature, request.option);
        }
    }

    /// `Player::PrepareGossipMenu`
    void prepareGossipMenu(Npc creature, uint menuId)
    {
        const npcs = context.data.npcs;
        gossipMenuId = menuId;
        gossipItems = null;
        const(GossipMenuOption)[] options = npcs.options.get(menuId, null);
        // The NPC's top menu without options of its own uses the default ones (menu 0).
        if (options.length == 0 && menuId == creature.npcTemplate.gossipMenuId)
            options = npcs.options.get(0, null);

        const female = isFemale(creature);
        const npcFlags = creature.npcValues.get!UNIT_NPC_FLAGS;
        foreach (ref option; options)
        {
            if (option.conditionId && !conditionMet(option.conditionId, creature))
                continue;
            if (!(option.npcFlag & npcFlags) || !offersOption(creature, option.optionId))
                continue;
            string text = option.text, box = option.boxText;
            if (option.broadcastText || option.boxBroadcastText)
            {
                if (const broadcast = option.broadcastText in npcs.broadcastTexts)
                    text = broadcast.text(female);
                if (const broadcast = option.boxBroadcastText in npcs.broadcastTexts)
                    box = broadcast.text(female);
            }
            gossipItems ~= GossipItem(option.icon, text, option.optionId, box, option.boxCoded, option.actionMenuId,
                option.actionPoiId, option.actionScriptId);
        }
    }

    /// The option checks of `PrepareGossipMenu`, and the services this server has.
    bool offersOption(Npc creature, uint optionId)
    {
        switch (optionId)
        {
        case GossipOption.gossip, GossipOption.innkeeper, GossipOption.banker:
            return true;
        case GossipOption.vendor:
            return vendorItems(creature).length > 0;
        case GossipOption.trainer:
            return isTrainerOf(creature, false);
        case GossipOption.unlearnTalents:
            // A class trainer of the player's own class, from the level talents begin.
            return creature.npcTemplate.trainerType == TrainerType.classes
                && creature.npcTemplate.trainerClass == player.data.classId && player.data.level >= 10;
        default:
            return false; // quests, flight masters, auctions, stables, ... come later
        }
    }

    /// `Player::SendPreparedGossip`
    void sendPreparedGossip(Npc creature)
    {
        ServerGossipMessage message;
        message.guid = creature.guid;
        message.textId = gossipMenuId ? gossipTextId(gossipMenuId, creature)
            : context.data.npcs.npcGossip.get(creature.spawnId, defaultGossipMessage);
        foreach (i, ref item; gossipItems)
            message.items ~= GossipMessageItem(cast(uint) i, cast(ubyte) item.icon, item.coded, item.message);
        message.quests = questMenu.dup;
        send(message);
    }

    import dmangos.script.api : MenuOption;

    /// A menu a creature's script built (`SEND_GOSSIP_MENU` after `ADD_GOSSIP_ITEM`s), under `npc_text` `textId`.
    package void sendScriptGossip(ulong npc, uint textId, const(MenuOption)[] options, bool withQuests)
    {
        auto creature = context.npcFor(map.findObject(npc));
        if (creature is null)
            return;
        gossipMenuId = 0;
        gossipItems = null;
        scriptGossipActions = null;
        foreach (ref o; options)
        {
            GossipItem item;
            item.icon = o.icon;
            item.message = o.text;
            gossipItems ~= item;
            scriptGossipActions ~= o.action;
        }
        scriptGossipShown = true;
        questMenu = null;
        if (withQuests && (creature.npcValues.get!UNIT_NPC_FLAGS & NpcFlag.questGiver))
            prepareQuestMenu(giverOf(creature));
        ServerGossipMessage message;
        message.guid = creature.guid;
        message.textId = textId ? textId : creature.npcTemplate.gossipMenuId
            ? gossipTextId(creature.npcTemplate.gossipMenuId, creature)
            : context.data.npcs.npcGossip.get(creature.spawnId, defaultGossipMessage);
        foreach (i, ref item; gossipItems)
            message.items ~= GossipMessageItem(cast(uint) i, cast(ubyte) item.icon, item.coded, item.message);
        message.quests = questMenu.dup;
        send(message);
    }

    /// `Player::GetGossipTextId(menuId, source)`: the text whose condition is the highest one met.
    uint gossipTextId(uint menuId, Npc creature)
    {
        uint textId = defaultGossipMessage, lastCondition;
        foreach (ref text; context.data.npcs.menus.get(menuId, null))
            if ((!text.conditionId && !lastCondition)
                || (text.conditionId > lastCondition && conditionMet(text.conditionId, creature)))
            {
                lastCondition = text.conditionId;
                textId = text.textId;
            }
        return textId;
    }

    /// `Player::OnGossipSelect`
    void onGossipSelect(Npc creature, uint index)
    {
        if (index >= gossipItems.length)
            return;
        const item = gossipItems[index];
        // `OnGossipSelect`: the option's script, the NPC the source and the player the target.
        if (item.actionScript)
        {
            import dmangos.world.dbscripts : DbScriptType;

            context.startScript(DbScriptType.gossip, item.actionScript, map, creature.guid, player.guid);
        }
        switch (item.optionId)
        {
        case GossipOption.gossip:
            if (item.actionPoi)
                sendPointOfInterest(item.actionPoi);
            if (item.actionMenu > 0)
            {
                prepareGossipMenu(creature, item.actionMenu);
                sendPreparedGossip(creature);
            }
            else if (item.actionMenu < 0)
                closeGossip();
            break;
        case GossipOption.vendor:
            sendListInventory(creature.guid);
            break;
        case GossipOption.trainer:
            sendTrainerList(creature.guid);
            break;
        case GossipOption.unlearnTalents:
            closeGossip();
            offerTalentWipe(creature.guid);
            break;
        case GossipOption.innkeeper:
            closeGossip();
            send(ServerBinderConfirm(creature.guid)); // Player::SetBindPoint: the client asks to be sure
            break;
        case GossipOption.banker:
            send(ServerShowBank(creature.guid));
            break;
        default:
            break;
        }
    }

    /// `PlayerMenu::CloseGossip`
    void closeGossip()
    {
        send(ServerGossipComplete());
    }

    /// `PlayerMenu::SendPointOfInterest`
    void sendPointOfInterest(uint id)
    {
        const poi = id in context.data.npcs.pointsOfInterest;
        if (poi is null)
        {
            warning!"points_of_interest %s does not exist"(id);
            return;
        }
        send(ServerGossipPoi(poi.flags, poi.x, poi.y, poi.icon, poi.data, poi.name));
    }

    /// `WorldSession::HandleNpcTextQueryOpcode`: the eight options of an `npc_text`, or the client's default.
    @Handles(Opcode.CMSG_NPC_TEXT_QUERY, WorldState.inWorld)
    void handleNpcTextQuery(const ClientNpcTextQuery request)
    {
        ServerNpcTextUpdate update;
        update.textId = request.textId;
        const npcs = context.data.npcs;
        if (const text = request.textId in npcs.texts)
            foreach (i, ref option; text.options)
            {
                string male = option.text0, female = option.text1;
                if (const broadcast = option.broadcastText in npcs.broadcastTexts)
                {
                    male = broadcast.text(false);
                    female = broadcast.text(true);
                }
                auto sent = &update.options[i];
                sent.probability = option.probability;
                sent.text0 = male.length ? male : female;
                sent.text1 = female.length ? female : male;
                sent.language = option.language;
                foreach (j, emote; option.emotes)
                    sent.emotes[j] = NpcTextEmote(emote.delay, emote.emote);
            }
        else
            foreach (ref option; update.options)
            {
                option.text0 = "Greetings $N";
                option.text1 = "Greetings $N";
            }
        send(update);
    }

    // -----------------------------------------------------------------------
    // Innkeepers and bankers
    // -----------------------------------------------------------------------

    /// `WorldSession::HandleBinderActivateOpcode` and `SendBindPoint`: the hearthstone is bound here.
    @Handles(Opcode.CMSG_BINDER_ACTIVATE, WorldState.inWorld)
    void handleBinderActivate(const ClientNpcGuid request)
    {
        auto innkeeper = interactableNpc(request.guid, NpcFlag.innkeeper);
        if (innkeeper is null)
            return;
        const mapEntry = context.client.maps.lookup(player.data.map);
        if (mapEntry is null || mapEntry.isDungeon || mapEntry.isBattleground)
            return;
        // The Bind spell's effect (Spell::EffectBind). Without map data, the zone stands for the area.
        const at = player.position;
        const bind = HomeBind(player.data.map, player.data.zone, at.x, at.y, at.z);
        player.data.homeBind = bind;
        context.database.updateHomeBind(player.data.guid, bind);
        send(ServerBindPointUpdate(bind.x, bind.y, bind.z, bind.map, bind.zone));
        send(ServerPlayerBound(innkeeper.guid, bind.zone));
        send(ServerTrainerBuySucceeded(innkeeper.guid, bindSpell));
        closeGossip();
    }

    @Handles(Opcode.CMSG_BANKER_ACTIVATE, WorldState.inWorld)
    void handleBankerActivate(const ClientNpcGuid request)
    {
        if (interactableNpc(request.guid, NpcFlag.banker) !is null)
            send(ServerShowBank(request.guid));
    }

    // -----------------------------------------------------------------------
    // Trainers (NPCHandler.cpp, Creature::IsTrainerOf, Player::GetTrainerSpellState)
    // -----------------------------------------------------------------------

    @Handles(Opcode.CMSG_TRAINER_LIST, WorldState.inWorld)
    void handleTrainerList(const ClientNpcGuid request)
    {
        sendTrainerList(request.guid);
    }

    /// A trainer's spells: its own (`npc_trainer`), then its template's.
    const(TrainerSpell)[] trainerSpells(Npc trainer)
    {
        const npcs = context.data.npcs;
        return npcs.trainers.get(trainer.npcTemplate.entry, null)
            ~ npcs.trainerTemplates.get(trainer.npcTemplate.trainerTemplateId, null);
    }

    /**
     * `Creature::IsTrainerOf`: whether this trainer teaches the player. With `tell`, the trainer says why
     * not, with the text CMaNGOS shows.
     */
    bool isTrainerOf(Npc trainer, bool tell)
    {
        if (!(trainer.npcValues.get!UNIT_NPC_FLAGS & NpcFlag.trainer) || trainerSpells(trainer).length == 0)
            return false;
        const t = trainer.npcTemplate;
        uint refusal;
        switch (t.trainerType)
        {
        case TrainerType.classes:
            if (player.data.classId != t.trainerClass)
            {
                static immutable uint[12] texts = [0, 4985, 1635, 10090, 4797, 4436, 0, 5003, 328, 5836, 0, 4913];
                refusal = t.trainerClass < texts.length ? texts[t.trainerClass] : 0;
                if (refusal == 0)
                    return false;
            }
            break;
        case TrainerType.pets:
            if (player.data.classId != PlayerClass.hunter)
                refusal = 3620;
            break;
        case TrainerType.mounts:
            if (t.trainerRace && player.data.race != t.trainerRace)
            {
                // CMaNGOS picks the text by `TrainerClass` here, which holds the race for these trainers.
                static immutable uint[9] texts = [0, 5861, 5863, 5865, 5862, 624, 5864, 4881, 5816];
                refusal = t.trainerClass < texts.length ? texts[t.trainerClass] : 0;
                if (refusal == 0)
                    return false;
            }
            break;
        case TrainerType.tradeskills:
            if (t.trainerSpell && !player.hasSpell(t.trainerSpell))
                refusal = 11031;
            break;
        default:
            return false; // CMaNGOS reports these at load
        }
        if (refusal == 0)
            return true;
        if (tell)
        {
            gossipMenuId = 0;
            gossipItems = null;
            send(ServerGossipMessage(trainer.guid, refusal));
        }
        return false;
    }

    /// `Player::IsSpellFitByClassAndRace`: whether the race and class may learn the spell, and from what level.
    bool spellFitsClassAndRace(uint spell, out uint requiredLevel)
    {
        const raceMask = 1u << (player.data.race - 1), classMask = 1u << (player.data.classId - 1);
        const abilities = context.client.abilitiesForSpell(spell);
        if (abilities.length == 0)
            return true;
        foreach (ability; abilities)
        {
            if ((ability.raceMask && !(ability.raceMask & raceMask))
                || (ability.classMask && !(ability.classMask & classMask)))
                continue;
            foreach (entry; context.client.raceClassInfo(ability.skillId))
                if ((entry.raceMask & raceMask) && (entry.classMask & classMask))
                {
                    enum uint skillFlagNotTrainable = 0x100;
                    if (entry.flags & skillFlagNotTrainable)
                        return false;
                    if (entry.reqLevel)
                    {
                        requiredLevel = entry.reqLevel;
                        return true;
                    }
                }
            return true;
        }
        return false;
    }

    /// `SpellMgr::IsProfessionSpell` and `IsPrimaryProfessionSpell`: the spell's second effect teaches a profession.
    bool isProfessionSpell(uint id, bool primaryOnly)
    {
        enum uint skillFishing = 356, skillCooking = 185, skillFirstAid = 129;
        const spell = context.data.spells.spell(id);
        if (spell is null || spell.effect[1] != SpellEffect.skill)
            return false;
        const skill = cast(uint) spell.miscValue[1];
        const line = context.client.skillLines.lookup(skill);
        const primary = line !is null && line.categoryId == SkillCategory.profession;
        return primary || (!primaryOnly && (skill == skillFishing || skill == skillCooking || skill == skillFirstAid));
    }

    /// `SpellMgr::IsPrimaryProfessionFirstRankSpell`
    bool isPrimaryProfessionFirstRank(uint id)
    {
        return isProfessionSpell(id, true) && context.data.spells.rank(id) == 1;
    }

    /// `Player::GetTrainerSpellState`
    TrainerSpellState trainerSpellState(const ref TrainerSpell trainerSpell, uint requiredLevel)
    {
        const learned = trainerSpell.learnedSpell;
        if (!learned)
            return TrainerSpellState.red;
        if (player.hasSpell(learned))
            return TrainerSpellState.gray;
        uint ignored;
        if (!spellFitsClassAndRace(learned, ignored) || player.data.level < requiredLevel)
            return TrainerSpellState.red;
        if (const chain = learned in context.data.spells.chains)
            if ((chain.prev && !player.hasSpell(chain.prev)) || (chain.req && !player.hasSpell(chain.req)))
                return TrainerSpellState.red;
        if (trainerSpell.reqSkill && player.skillValue(trainerSpell.reqSkill)[0] < trainerSpell.reqSkillValue)
            return TrainerSpellState.red;
        foreach (required; trainerSpell.reqAbility)
            if (required && !player.hasSpell(required))
                return TrainerSpellState.red;
        if (!isProfessionSpell(learned, true))
            return TrainerSpellState.green;
        if (isPrimaryProfessionFirstRank(learned) && player.values.get!PLAYER_CHARACTER_POINTS2 == 0)
            return TrainerSpellState.greenDisabled;
        return TrainerSpellState.green;
    }

    /// The level a trainer asks for a spell: the row's, or the higher of the spell's and the race and class's.
    uint trainerRequiredLevel(const ref TrainerSpell trainerSpell, uint fitLevel)
    {
        return trainerSpell.providedReqLevel ? trainerSpell.reqLevel : max(fitLevel, trainerSpell.reqLevel);
    }

    /// `WorldSession::SendTrainerList`
    void sendTrainerList(ulong guid)
    {
        auto trainer = interactableNpc(guid, NpcFlag.trainer);
        if (trainer is null || !isTrainerOf(trainer, true))
            return;
        ServerTrainerList list;
        list.trainer = guid;
        const discount = reputationPriceDiscount(trainer.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE);
        const spells = context.data.spells;
        foreach (ref trainerSpell; trainerSpells(trainer))
        {
            uint fitLevel;
            if (!spellFitsClassAndRace(trainerSpell.learnedSpell, fitLevel))
                continue;
            if (trainerSpell.conditionId && !conditionMet(trainerSpell.conditionId, trainer))
                continue;
            const requiredLevel = trainerRequiredLevel(trainerSpell, fitLevel);
            const state = trainerSpellState(trainerSpell, requiredLevel);
            const triggerSpell = spells.spell(trainerSpell.spell).triggerSpell[0];
            const chain = triggerSpell in spells.chains;
            // SendTrainerSpellHelper
            TrainerListSpell sent;
            sent.spell = trainerSpell.spell;
            sent.state = state == TrainerSpellState.greenDisabled ? TrainerSpellState.green : state;
            sent.cost = cast(uint) floor(trainerSpell.cost * discount); // the reputation's discount
            sent.primaryProfessionFirstRank = isPrimaryProfessionFirstRank(triggerSpell) ? 1 : 0;
            sent.requiredLevel = cast(ubyte) requiredLevel;
            sent.requiredSkill = trainerSpell.reqSkill;
            sent.requiredSkillValue = trainerSpell.reqSkillValue;
            sent.requiredSpells[0] = trainerSpell.reqAbility[0] ? trainerSpell.reqAbility[0]
                : chain is null ? 0 : chain.req ? chain.req : chain.prev;
            sent.requiredSpells[1] = trainerSpell.reqAbility[1] ? trainerSpell.reqAbility[1]
                : chain !is null && chain.req ? chain.prev : 0;
            sent.requiredSpells[2] = trainerSpell.reqAbility[2];
            list.spells ~= sent;
            if (isProfessionSpell(trainerSpell.learnedSpell, false))
                list.trainerType = TrainerType.tradeskills; // ObjectMgr::LoadTrainers
        }
        list.greeting = context.data.npcs.trainerGreetings.get(trainer.npcTemplate.entry,
            "Hello! Ready for some training?");
        send(list);
    }

    /// `WorldSession::HandleTrainerBuySpellOpcode`
    @Handles(Opcode.CMSG_TRAINER_BUY_SPELL, WorldState.inWorld)
    void handleTrainerBuySpell(const ClientTrainerBuySpell request)
    {
        auto trainer = interactableNpc(request.trainer, NpcFlag.trainer);
        if (trainer is null || !isTrainerOf(trainer, true))
            return;
        const(TrainerSpell)* found;
        foreach (ref trainerSpell; trainerSpells(trainer))
            if (trainerSpell.spell == request.spell)
            {
                found = &trainerSpell;
                break;
            }
        uint fitLevel;
        if (found is null || !spellFitsClassAndRace(found.learnedSpell, fitLevel))
            return;
        if (trainerSpellState(*found, trainerRequiredLevel(*found, fitLevel)) != TrainerSpellState.green)
            return;
        const money = player.values.get!PLAYER_FIELD_COINAGE;
        const cost = cast(uint) floor(found.cost * reputationPriceDiscount(trainer.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE));
        if (money < cost)
            return;
        player.values.set!PLAYER_FIELD_COINAGE(money - cost);
        send(ServerPlaySpellVisual(trainer.guid, 0xB3));      // on the trainer
        send(ServerPlaySpellImpact(player.guid, 0x016A));     // on the player
        send(ServerTrainerBuySucceeded(trainer.guid, request.spell));
        // The trainer casts its spell on the player, whose effect teaches the spell (Spell::EffectLearnSpell).
        learnSpellInWorld(found.learnedSpell);
    }

    /**
     * `Player::learnSpell` while in the world: the spell and what comes with it are learned, the client
     * is told, and the spells and skills saved.
     */
    void learnSpellInWorld(uint spell)
    {
        NewSkill[] currentSkills;
        foreach (skill; player.skillList)
            currentSkills ~= NewSkill(skill[0], skill[1], skill[2]);
        KnownAbilities loaded;
        auto builder = new CharacterBuilder(context.data, context.client, context.creationSettings,
            &context.nextItemGuid);
        if (!builder.loadAbilities(player.data.race, player.data.classId, player.data.level, account.level,
            currentSkills, player.data.spells, loaded))
            return;
        const result = builder.learnInWorld(spell);

        foreach (event; result.events)
            final switch (event.kind)
            {
            case LearnEvent.Kind.learned:
                send(ServerLearnedSpell(event.spell));
                break;
            case LearnEvent.Kind.superseded:
                send(ServerSupercededSpell(cast(ushort) event.spell, cast(ushort) event.newSpell));
                break;
            }
        const guid = player.data.guid;
        foreach (row; result.savedSpells)
        {
            context.database.saveSpell(guid, row.spell, row.active, row.disabled);
            player.recordSpellRow(row);
        }
        foreach (id; result.removedSpells)
        {
            context.database.deleteSpell(guid, id);
            player.forgetSpellRow(id);
        }
        foreach (row; result.savedSkills)
        {
            context.database.saveSkill(guid, row.skill, row.value, row.max);
            player.recordSkillRow(row);
        }
        if (player.applyAbilities(result.abilities, context.data, context.client))
        {
            send(ServerSetProficiency(2, player.proficiency[0])); // ITEM_CLASS_WEAPON
            send(ServerSetProficiency(4, player.proficiency[1])); // ITEM_CLASS_ARMOR
        }
        flushPlayerChanges();
    }

    // -----------------------------------------------------------------------
    // Vendors (ItemHandler.cpp)
    // -----------------------------------------------------------------------

    /// A vendor's items: its own (`npc_vendor`), then its template's, as the slots number them.
    const(VendorItem)[] vendorItems(Npc vendor)
    {
        const npcs = context.data.npcs;
        return npcs.vendors.get(vendor.npcTemplate.entry, null)
            ~ npcs.vendorTemplates.get(vendor.npcTemplate.vendorTemplateId, null);
    }

    @Handles(Opcode.CMSG_LIST_INVENTORY, WorldState.inWorld)
    void handleListInventory(const ClientNpcGuid request)
    {
        sendListInventory(request.guid);
    }

    /// `Player::CanSeeVendorItem`
    bool canSeeVendorItem(Npc vendor, const ref VendorItem vendorItem, const ref ItemTemplate proto)
    {
        enum uint bindWhenPickedUp = 1;
        enum uint rankNeutral = 3; // no reputation yet: every faction is neutral
        const classMask = 1u << (player.data.classId - 1), raceMask = 1u << (player.data.race - 1);
        if (!(proto.allowableClass & classMask) && proto.bonding == bindWhenPickedUp)
            return false;
        if (!(proto.allowableRace & raceMask))
            return false;
        if (!proto.requiredReputationFaction && proto.requiredReputationRank > rankNeutral)
            return false;
        return !vendorItem.conditionId || conditionMet(vendorItem.conditionId, vendor);
    }

    /// `WorldSession::SendListInventory`
    void sendListInventory(ulong guid)
    {
        enum maxVendorItems = 128; // MAX_VENDOR_ITEMS
        auto vendor = interactableNpc(guid, NpcFlag.vendor);
        if (vendor is null)
            return;
        ServerListInventory list;
        list.vendor = guid;
        const discount = reputationPriceDiscount(vendor.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE);
        foreach (i, ref vendorItem; vendorItems(vendor))
        {
            const proto = vendorItem.item in context.data.items;
            if (proto is null || !canSeeVendorItem(vendor, vendorItem, *proto))
                continue;
            const available = vendorItem.maxCount == 0 ? uint.max : vendor.vendorItemCount(vendorItem.item,
                vendorItem.maxCount, vendorItem.incrTime, proto.buyCount, context.unixTime);
            list.items ~= VendorListItem(cast(uint) i + 1, vendorItem.item, proto.displayId, available,
                cast(uint) floor(proto.details.buyPrice * discount), proto.maxDurability, proto.buyCount);
            if (list.items.length >= maxVendorItems)
                break;
        }
        if (list.items.length == 0)
            list.error = [0]; // "Vendor has no inventory"
        send(list);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader;
    import dmangos.serialization : deserialize;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    T packet(T)(const(ServerPacketRead)[] packets)
    {
        auto reader = ByteReader(bodyOf(packets, T.opcode));
        return deserialize!T(reader);
    }
}

/// Gossip: the menu with its conditions, a submenu with a map flag, and the texts.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const trainer = makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn);

    anduin.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(trainer));
    const menu = packet!ServerGossipMessage(anduin.read());
    assert(menu.guid == trainer && menu.textId == 1001, "the level 10 text's condition is not met");
    assert(menu.items.length == 2 && menu.items[0].message == "I require training." && menu.items[0].icon == 3,
        "the orcs' option is left out");

    anduin.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(trainer, 1));
    const more = anduin.read();
    assert(opcodesOf(more) == [Opcode.SMSG_GOSSIP_POI, Opcode.SMSG_GOSSIP_MESSAGE]);
    assert(packet!ServerGossipPoi(more).name == "Northshire Abbey" && packet!ServerGossipMessage(more).textId == 1003);

    anduin.write(Opcode.CMSG_NPC_TEXT_QUERY, ClientNpcTextQuery(1001, trainer));
    const text = packet!ServerNpcTextUpdate(anduin.read());
    assert(text.options[0].text0 == "Hail, $c." && text.options[0].text1 == "Hail, $c.");
    assert(text.options[1].text0 == "Make this inn your home.", "an option from broadcast_text");
    anduin.write(Opcode.CMSG_NPC_TEXT_QUERY, ClientNpcTextQuery(5, trainer));
    assert(packet!ServerNpcTextUpdate(anduin.read()).options[7].text1 == "Greetings $N", "the default");

    // Deputy Willem is 17 yards away: too far to talk to.
    anduin.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(makeGuid(HighGuid.unit, creatureWillem, 79942)));
    assert(anduin.read().length == 0);
}

/// Trainers: the list with each spell's state, a lesson bought, and what it teaches.
unittest
{
    import dmangos.auth.accounts : AccountLevel;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    // A game master, to give itself money; a trainer treats it like anyone.
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    anduin.read();
    const trainer = makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn);

    anduin.write(Opcode.CMSG_TRAINER_LIST, ClientNpcGuid(trainer));
    auto list = packet!ServerTrainerList(anduin.read());
    assert(list.greeting == "Hello! Ready for some training?" && list.spells.length == 2);
    assert(list.spells[0].spell == spellTeachHeroicStrike && list.spells[0].state == TrainerSpellState.green);
    assert(list.spells[0].cost == 10 && list.spells[0].requiredLevel == 0);
    assert(list.spells[1].state == TrainerSpellState.red && list.spells[1].requiredLevel == 8
        && list.spells[1].requiredSpells[0] == spellHeroicStrike, "rank 2 needs level 8 and rank 1");

    // Too poor, then paid for.
    anduin.write(Opcode.CMSG_TRAINER_BUY_SPELL, ClientTrainerBuySpell(trainer, spellTeachHeroicStrike));
    assert(anduin.read().length == 0);
    const me = anduin.session.character;
    anduin.say(".modify gold 25");
    anduin.read();
    anduin.write(Opcode.CMSG_TRAINER_BUY_SPELL, ClientTrainerBuySpell(trainer, spellTeachHeroicStrike));
    const bought = anduin.read();
    assert(opcodesOf(bought)[0 .. 4] == [Opcode.SMSG_PLAY_SPELL_VISUAL, Opcode.SMSG_PLAY_SPELL_IMPACT,
        Opcode.SMSG_TRAINER_BUY_SUCCEEDED, Opcode.SMSG_LEARNED_SPELL]);
    assert(packet!ServerLearnedSpell(bought).spell == spellHeroicStrike);
    assert(me.knowsSpell(spellHeroicStrike) && me.values.get!PLAYER_FIELD_COINAGE == 15);
    assert(spellHeroicStrike in db.spellRows[7], "saved");

    anduin.write(Opcode.CMSG_TRAINER_LIST, ClientNpcGuid(trainer));
    list = packet!ServerTrainerList(anduin.read());
    assert(list.spells[0].state == TrainerSpellState.gray && list.spells[1].state == TrainerSpellState.red);

    // A hunter is turned away with the warrior trainer's text.
    auto thrall = loggedIn(context, db, 8, "Garrosh", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceOrc);
    thrall.read();
    thrall.write(Opcode.CMSG_TRAINER_LIST, ClientNpcGuid(trainer));
    const refusal = packet!ServerGossipMessage(thrall.read());
    assert(refusal.textId == 4985 && refusal.items.length == 0);
}

/// The innkeeper binds the hearthstone and sells; the banker shows the bank.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);

    // No menu of its own: the default options for its flags, in their order.
    anduin.write(Opcode.CMSG_GOSSIP_HELLO, ClientNpcGuid(innkeeper));
    const menu = packet!ServerGossipMessage(anduin.read());
    assert(menu.items.length == 2 && menu.items[0].icon == 1 && menu.items[1].message == "Make this inn your home.");
    assert(menu.textId == 0xFF_FFFF);

    anduin.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(innkeeper, 1));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_GOSSIP_COMPLETE, Opcode.SMSG_BINDER_CONFIRM]);
    anduin.write(Opcode.CMSG_BINDER_ACTIVATE, ClientNpcGuid(innkeeper));
    const bound = anduin.read();
    assert(opcodesOf(bound) == [Opcode.SMSG_BINDPOINTUPDATE, Opcode.SMSG_PLAYERBOUND,
        Opcode.SMSG_TRAINER_BUY_SUCCEEDED, Opcode.SMSG_GOSSIP_COMPLETE]);
    assert(db.homeBinds[7].x == -8949.95f && anduin.session.character.data.homeBind.x == -8949.95f);

    // The jerky, not the sword, whose condition is for orcs.
    anduin.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(innkeeper, 0));
    const wares = packet!ServerListInventory(anduin.read());
    assert(wares.items.length == 1 && wares.items[0].item == itemJerky && wares.items[0].slot == 1);
    assert(wares.items[0].available == uint.max && wares.error.length == 0);

    anduin.write(Opcode.CMSG_BANKER_ACTIVATE, ClientNpcGuid(makeGuid(HighGuid.unit, creatureBanker, bankerSpawn)));
    assert(opcodesOf(anduin.read()) == [Opcode.SMSG_SHOW_BANK]);
    anduin.write(Opcode.CMSG_BANKER_ACTIVATE, ClientNpcGuid(innkeeper));
    assert(anduin.read().length == 0, "not a banker");
}
