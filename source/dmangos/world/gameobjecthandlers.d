/**
 * Using game objects: what each type does when used, opening locks with spells, a chest's loot,
 * and gathering skill-ups. Mixed into `dmangos.world.character.Character`.
 *
 * A door or button opens (or closes) for its time; a chair seats the player in its nearest slot; a
 * goober is in use for its time, shows its page, counts for the quest that needs it (for the
 * player and its group near it) and casts its spell on the player; a camera plays its cinematic.
 * A lock (`Lock.dbc`) is opened by a spell: with its key item, or the lock type the spell opens
 * and the skill it needs (lockpicking, herbalism, mining). Opening a chest (herbs and veins
 * included) shows its loot (`gameobject_loot_template`), with the loot rights of a group as a
 * corpse has them and its quest items for those whose quests need them; the first opening until
 * it respawns may raise the gathering skill. A chest is gone once emptied (or 5 minutes after it
 * was opened) if consumable. Quest givers among game objects, traps and fishing come later.
 */
module dmangos.world.gameobjecthandlers;

import dmangos.world.spellids;
import dmangos.world.context : WorldContext;
import dmangos.world.gameobject : GameObject;
import dmangos.world.loot : Loot, Looter;
import dmangos.world.map : Map;

/// Bind the chest's loot to the map that owns it, including when it changed owners.
package void bindChestLoot(WorldContext context, Map map, GameObject chest, Loot loot)
{
    import dmangos.world.character : Character;
    import dmangos.world.gameobject : GoLootState;

    loot.find = (ulong guid) {
        auto session = cast(Character) context.onlinePlayer(guid);
        return session is null || session.currentMap !is map ? null : cast(Looter) session;
    };
    loot.clock = () => context.unixTime;
    if (context.isInstanceReward(chest))
        loot.storeReward = (Looter looter, imported!"dmangos.world.loot".LootItem item, bool sendError) {
            auto player = cast(Character) looter;
            return player.storeLootItem(item.itemId, item.count, item.randomPropertyId, sendError,
                () => context.checkpointReward(map, chest, item, looter.looterGuid));
        };
    loot.changed = () => map.flushGameObject(chest);
    loot.lootedForAll = () {
        if (refillVein(context, map, chest))
        {
            chest.loot = null;
            chest.lootState = GoLootState.ready;
            chest.despawnTimer = 0;
            return;
        }
        chest.lootState = GoLootState.justDeactivated;
        map.wake(chest.guid);
    };
}

/// A vein refills until its minimum uses, then with a chance based on its uses and the opener's skill.
private bool refillVein(WorldContext context, Map map, GameObject chest)
{
    import std.math : pow;
    import std.random : uniform;

    const least = chest.template_.data[4], most = chest.template_.data[5];
    if (least == 0 || most <= least)
        return false;
    const uses = ++chest.gatherUses;
    if (uses >= most)
        return false;
    if (uses < least)
        return true;
    int required = 175;
    if (const lock = context.client.locks.lookup(chest.template_.data[0]))
        required = lock.skill[0];
    const skill = float(chest.gatherSkill) / (required + 25);
    const chance = pow(0.8, 4.0 * uses / most);
    return uniform(0.0f, 100.0f, map.random) < 100 * chance + skill;
}

/// See the module documentation.
mixin template GameObjectHandlers()
{
    import dmangos.world.spellids;
    import std.random : uniform;
    import dmangos.log : info;
    import dmangos.world.clientdata : LockEntry;
    import dmangos.world.gameobject : GameObject, GameObjectType, goFlagLocked, goStateReady, GoLootState;
    import dmangos.world.loot : Loot, LootItem, Looter, questItems;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : DeathState;
    import dmangos.world.quests : QuestState;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

    /// How near (yards) a player must be to use most things.
    enum float interactionDistance = 5;

    /// A lock's key kinds, the lock types (`Lock.dbc`), and the skills of the lock types.
    enum uint lockKeyItem = 1, lockKeySkill = 2;
    enum uint lockPicklock = 1, lockHerbalism = 2, lockMining = 3, lockFishing = 19;
    enum uint skillLockpicking = 633, skillHerbalism = 182, skillMining = 186, skillFishing = 356;

    /// The skill that opens a lock type; 0 for none.
    static uint skillByLockType(uint lockType) pure nothrow @nogc @safe
    {
        switch (lockType)
        {
        case lockPicklock: return skillLockpicking;
        case lockHerbalism: return skillHerbalism;
        case lockMining: return skillMining;
        case lockFishing: return skillFishing;
        default: return 0;
        }
    }

    /// Within `interactionDistance` of the object (a little more for its size).
    bool withinInteraction(const GameObject go, float more = 0)
    {
        if (!map.questSpawnVisible(player, go.guid))
            return false;
        const a = player.position, b = go.position;
        // A fishing bobber (and a chair) may be used from a hundred yards.
        const base = go.type == GameObjectType.fishingNode || go.type == GameObjectType.chair ? 100.0f
            : interactionDistance;
        const reach = base + more + go.template_.size;
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 <= reach * reach;
    }

    /// The client uses a game object: checked (near, usable), then used.
    @Handles(Opcode.CMSG_GAMEOBJ_USE, WorldState.inWorld)
    void handleGameObjectUse(const ClientGuid request)
    {
        enum uint goFlagNoInteract = 0x10;
        if (player.deathState != DeathState.alive || transferring || npcCharmer
            || !map.questSpawnVisible(player, request.guid))
            return;
        auto go = cast(GameObject) map.findObject(request.guid);
        if (go is null)
        {
            // Another node's object (its replica here): used there.
            import dmangos.world.inworld : ArrivalAction;

            ArrivalAction action;
            action.useObject = request.guid;
            actAtReplica(request.guid, action);
            return;
        }
        interruptAuras(AuraInterrupt.interacting); // using it (CMaNGOS's `DoInteraction`)
        if (!withinInteraction(go, 2))
            return;
        // Never for these: generic objects are used by spells, and some may not be touched.
        const flags = go.values.get!GAMEOBJECT_FLAGS;
        if (go.type == GameObjectType.generic || (flags & goFlagNoInteract) || (go.doorOrButton && (flags & goFlagLocked)))
            return;
        dismountToUse(go); // by hand, off the mount unless usable mounted (`dmangos.world.mounting`)
        import dmangos.world.alterac : AlteracRules;
        if (auto copy = currentBattleground())
            if (auto valley = cast(AlteracRules) copy.rules)
                if (valley.beginBeaconUse(copy, this, go))
                    return;
        useGameObject(go);
    }

    /// At a meeting stone: this player, or its party, waits for the stone's dungeon (`dmangos.world.meetingstone`).
    @Handles(Opcode.CMSG_MEETINGSTONE_JOIN, WorldState.inWorld)
    void handleMeetingStoneJoin(const ClientGuid request)
    {
        import dmangos.world.groupservice : GroupOp;

        auto go = cast(GameObject) map.findObject(request.guid);
        if (go is null || go.type != GameObjectType.meetingStone || !withinInteraction(go, 2))
            return;
        groupCommand(GroupOp.meetingStoneJoin, 0, null, null, go.template_.data[2], player.data.classId);
    }

    /// Out of the meeting stone's queue.
    @Handles(Opcode.CMSG_MEETINGSTONE_LEAVE, WorldState.inWorld)
    void handleMeetingStoneLeave()
    {
        import dmangos.world.groupservice : GroupOp;

        groupCommand(GroupOp.meetingStoneLeave);
    }

    /// The stone's window asks how this player stands in the queue.
    @Handles(Opcode.CMSG_MEETINGSTONE_INFO, WorldState.inWorld)
    void handleMeetingStoneInfo()
    {
        import dmangos.world.groupservice : GroupOp;

        groupCommand(GroupOp.meetingStoneInfo);
    }

    /// This player uses a game object: what happens depends on its type.
    package void useGameObject(GameObject go)
    {
        if (go.type == GameObjectType.fishingNode)
            return useBobber(go);
        // A battleground's objective (a flag, a banner): its rules first.
        if (auto copy = currentBattleground())
            if (copy.rules.objectUsed(copy, player.guid, go))
                return copy.pvpActive(player.guid);
        // World PvP's (Silithyst, Northpass's shrines).
        if (worldPvpObjectUsed(go))
            return;
        // Its script first: it may handle the use itself.
        if (context.gameObjectUsed(go, map, player.guid))
            return;
        import dmangos.world.dbscripts : DbScriptType;

        // Its scripts: the template's, and (doors, buttons, goobers) the spawn's; the user the source.
        context.startScript(DbScriptType.goTemplateUse, go.spawn.entry, map, player.guid, go.guid);
        if (go.type == GameObjectType.door || go.type == GameObjectType.button || go.type == GameObjectType.goober)
            context.startScript(DbScriptType.goUse, go.spawn.guid, map, player.guid, go.guid);
        springLinkedTrap(go);
        uint spellId;
        switch (go.type)
        {
        case GameObjectType.door, GameObjectType.button:
            go.useDoorOrButton(map);
            map.wake(go.guid);
            return;
        case GameObjectType.chest:
            // Its loot comes with the spell that opens it (`sendGameObjectLoot`); one without a lock is just done.
            if (!go.lockId && go.lootState == GoLootState.ready)
            {
                go.lootState = GoLootState.justDeactivated;
                map.wake(go.guid);
            }
            return;
        case GameObjectType.generic:
            go.lootState = GoLootState.justDeactivated;
            map.wake(go.guid);
            return;
        case GameObjectType.chair:
            return sitOnChair(go);
        case GameObjectType.summoningRitual: // `dmangos.world.rituals`
            return joinRitual(go);
        case GameObjectType.meetingStone:
            return useMeetingStoneToSummon(go);
        case GameObjectType.questGiver:
        {
            // Its own gossip menu (`gossipID`, data 3) with its quests; without one, its quests alone.
            QuestGiver giver;
            const hasQuests = questGiverNear(go.guid, 0, giver);
            if (const menu = go.template_.data[3])
                return sendGameObjectGossip(go, menu, hasQuests ? &giver : null);
            if (hasQuests)
            {
                prepareQuestMenu(giver);
                sendPreparedQuest(giver);
            }
            return;
        }
        case GameObjectType.goober:
        {
            const t = go.template_;
            go.activateGoober(map);
            map.wake(go.guid);
            if (const event = t.data[2]) // its event (`eventId`): the dungeon's script, the event's database script
                context.scriptedEvent(event, map, player.guid, go.guid);
            if (const page = t.data[7]) // show the page
            {
                ByteWriter w;
                w.put(go.guid);
                deliver(Opcode.SMSG_GAMEOBJECT_PAGETEXT, w.data);
            }
            // A quest objective: only while the quest it is for is under way.
            const questId = t.data[1];
            if (questId > 0 && context.data.quests.quest(questId) !is null
                && questState(questId) != QuestState.incomplete)
                return;
            rewardAtCast(go);
            spellId = t.data[10];
            break;
        }
        case GameObjectType.spellCaster:
        {
            // A mage's portal, a Lightwell: its spell on its user, of its owner's party if it says (CMaNGOS's
            // `GAMEOBJECT_TYPE_SPELLCASTER` use); its charges spent, it is locked.
            const t = go.template_;
            if (go.values.get!GAMEOBJECT_FLAGS & goFlagLocked)
                return;
            if (t.data[2] && go.owner != player.guid && !context.sameGroup(go.owner, player.guid))
                return;
            spellId = t.data[0];
            if (t.data[1] > 0 && ++go.casterUses >= t.data[1])
            {
                go.values.set!GAMEOBJECT_FLAGS(go.values.get!GAMEOBJECT_FLAGS | goFlagLocked);
                map.flushGameObject(go);
            }
            break;
        }
        case GameObjectType.camera:
            if (const cinematic = go.template_.data[1])
            {
                ByteWriter w;
                w.put(cinematic);
                deliver(Opcode.SMSG_TRIGGER_CINEMATIC, w.data);
            }
            return;
        default:
            return;
        }
        // The spell it casts on its user.
        if (spellId)
            if (const spell = context.data.spells.spell(spellId))
                castSpell(spell, SpellTargets(TargetFlags.unit, player.guid), true, 0);
    }

    /// A game object used counts for its quest objective, for the group near it too.
    void rewardAtCast(GameObject go)
    {
        rewardPlayerAndGroupAtCast(go.guid, 0);
    }

    /// A chair (`GAMEOBJECT_TYPE_CHAIR`): to the nearest of its slots, sitting at its height.
    void sitOnChair(GameObject go)
    {
        import std.math : cos, sin, PI;

        enum ubyte standStateSitLowChair = 4;
        const t = go.template_;
        const slots = t.data[0] > 0 ? t.data[0] : 1;
        // The nearest slot: the slots side by side across its width (its size).
        const at = go.position;
        const width = t.size;
        float bestX = at.x, bestY = at.y, best = float.max;
        foreach (i; 0 .. slots)
        {
            const offset = slots == 1 ? 0 : (i - (slots - 1) / 2.0f) * width / slots;
            const x = at.x + offset * cos(at.orientation + PI / 2), y = at.y + offset * sin(at.orientation + PI / 2);
            const d = (player.position.x - x) ^^ 2 + (player.position.y - y) ^^ 2;
            if (d < best)
            {
                best = d;
                bestX = x;
                bestY = y;
            }
        }
        import dmangos.world.movement : Position;

        teleportTo(player.data.map, Position(bestX, bestY, at.z, at.orientation)); // a teleport on the same map
        const state = cast(ubyte)(standStateSitLowChair + t.data[1]);
        player.values.setByte!UNIT_FIELD_BYTES_1(0, state);
        deliver(Opcode.SMSG_STANDSTATE_UPDATE, [state]);
        flushPlayerChanges();
    }

    // -----------------------------------------------------------------------
    // Locks: whether a spell opens one, and opening it
    // -----------------------------------------------------------------------

    /**
     * Whether effect `i` of `spell` opens lock `lockId`: the key item it was cast with,
     * or the lock type the effect opens and enough of its skill (the effect's points at the skill's rank). Gives the
     * skill and the values the skill-up needs.
     */
    SpellCastResult canOpenLock(const(SpellInfo)* spell, size_t i, uint lockId, uint castItem, out uint skillId,
        out int required, out int skillValue)
    {
        import dmangos.world.spellcast : effectValue;

        if (!lockId)
            return SpellCastResult.ok;
        const lock = context.client.locks.lookup(lockId);
        if (lock is null)
            return SpellCastResult.badTargets;
        bool needsKey;
        foreach (j; 0 .. 8)
            switch (lock.type[j])
            {
            case lockKeyItem:
                if (lock.index[j] && castItem == lock.index[j])
                    return SpellCastResult.ok;
                needsKey = true;
                break;
            case lockKeySkill:
                needsKey = true;
                if (cast(uint) spell.miscValue[i] != lock.index[j])
                    continue;
                skillId = skillByLockType(lock.index[j]);
                if (skillId)
                {
                    required = lock.skill[j];
                    // The effect's value at the player's rank in the skill, as five "levels" a point
                    // (`Player::GetSpellRank`): about the skill itself. Pick Lock (1804: 4 + 5 a level from 1) at
                    // lockpicking 150 is 150, Mining (2575: 0 + 5 a level) at mining 1 is 0, not the character's
                    // level's 300. A key (an item's cast) is its own value alone.
                    const rank = castItem ? 0 : player.skillValue(skillId)[0];
                    skillValue = effectValue(*spell, i, rank / 5, 0);
                    if (skillValue < required)
                        return SpellCastResult.lowCastLevel;
                }
                return SpellCastResult.ok;
            default:
                break;
            }
        return needsKey ? SpellCastResult.badTargets : SpellCastResult.ok;
    }

    /// Whether a spell may be cast at a game object: there, near, not in use, and its lock opened.
    package SpellCastResult checkGameObjectTarget(const(SpellInfo)* spell, const ref SpellTargets targets,
        uint castItem)
    {
        enum uint openLock = 33, openLockItem = 59;
        if (!targets.gameObject)
            return SpellCastResult.ok;
        auto go = cast(GameObject) map.findObject(targets.gameObject);
        if (go is null)
            return SpellCastResult.badTargets;
        import dmangos.script.api : ObjectFlag;

        if (go.type == GameObjectType.trap && ((go.values.get!GAMEOBJECT_FLAGS & ObjectFlag.noInteract)
            || !map.seesTrap(player, go.guid, go.position)))
            return SpellCastResult.badTargets;
        if (!withinInteraction(go, 5))
            return SpellCastResult.outOfRange;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == openLock || spell.effect[i] == openLockItem)
            {
                if (go.type == GameObjectType.chest && go.lootState != GoLootState.ready && go.loot is null)
                    return SpellCastResult.chestInUse;
                uint skill;
                int required, value;
                const result = canOpenLock(spell, i, go.lockId, castItem, skill, required, value);
                if (result != SpellCastResult.ok)
                    return result;
            }
        return SpellCastResult.ok;
    }

    /// A spell opens a game object's lock: a skill-up the first time, then `sendGameObjectLoot`.
    package void openLock(const(SpellInfo)* spell, size_t i, ulong target, uint castItem)
    {
        auto go = cast(GameObject) map.findObject(target);
        if (go is null || !map.questSpawnVisible(player, target))
            return;
        uint skillId;
        int required, value;
        if (canOpenLock(spell, i, go.lockId, castItem, skillId, required, value) != SpellCastResult.ok)
            return;
        if (skillId && go.loot is null && player.guid !in go.skilledUp)
            if (const pure_ = player.skillValue(skillId)[0])
            {
                updateGatherSkill(skillId, pure_, required);
                go.skilledUp[player.guid] = true;
            }
        enum disarmTrap = 4; // LockType from Lock.dbc
        if (go.type == GameObjectType.trap && spell.miscValue[i] == disarmTrap)
        {
            import dmangos.script.api : ObjectFlag;

            if ((go.values.get!GAMEOBJECT_FLAGS & ObjectFlag.noInteract) || !map.seesTrap(player, go.guid, go.position)
                || context.gameObjectTrapDisarmed(go, map, player.guid))
                return;
            if (go.owner)
                map.removeObject(go.guid);
            else
                map.gameObjectUsedUp(go);
            return;
        }
        sendGameObjectLoot(go);
    }

    /// After its lock opened: doors, buttons and goobers are used; a chest's loot opens.
    void sendGameObjectLoot(GameObject go)
    {
        switch (go.type)
        {
        case GameObjectType.door, GameObjectType.button, GameObjectType.questGiver, GameObjectType.spellFocus,
                GameObjectType.goober:
            return useGameObject(go);
        case GameObjectType.chest:
            useGameObject(go);
            break;
        default:
            return;
        }
        if (go.loot is null)
        {
            if (go.lootState != GoLootState.ready)
                return;
            go.loot = makeGameObjectLoot(go);
            go.lootState = GoLootState.activated;
            if (context.isInstanceReward(go))
                context.database.saveInstanceChest(context.checkpointReward(map, go));
            map.wake(go.guid);
            go.loot.beginQuestLootChecks(map.id, &context.nextGameplaySequence, context.sendQuestLootCheck);
            if (go.loot is null)
                return;
        }
        if (lootTarget && lootTarget != go.guid)
            if (auto other = lootOf(lootTarget))
                other.release(this);
        recheckQuestLoot(go.loot);
        recheckRemoteMasterLoot(go.loot);
        go.loot.showContentTo(this);
    }

    /**
     * A game object's gossip menu `menuId` (a quest giver's `gossipID`): its text (by its conditions), the
     * options whose conditions are met (only talk and quest options serve a game object), and its quests.
     */
    package void sendGameObjectGossip(GameObject go, uint menuId, const(QuestGiver)* giver)
    {
        import dmangos.world.npcdata : GossipOption;
        import dmangos.world.packets : GossipMessageItem, ServerGossipMessage;

        const npcs = context.data.npcs;
        gossipMenuId = menuId;
        gossipItems = null;
        scriptGossipShown = false;
        foreach (ref option; npcs.options.get(menuId, null))
        {
            if (option.optionId != GossipOption.gossip && option.optionId != GossipOption.questGiver)
                continue;
            if (option.conditionId && !conditionMet(option.conditionId, null))
                continue;
            string text = option.text, box = option.boxText;
            if (const broadcast = option.broadcastText in npcs.broadcastTexts)
                text = broadcast.text(false);
            if (const broadcast = option.boxBroadcastText in npcs.broadcastTexts)
                box = broadcast.text(false);
            gossipItems ~= GossipItem(option.icon, text, option.optionId, box, option.boxCoded, option.actionMenuId,
                option.actionPoiId, option.actionScriptId);
        }
        questMenu = null;
        if (giver !is null)
            prepareQuestMenu(*giver);
        ServerGossipMessage message;
        message.guid = go.guid;
        message.textId = gossipTextId(menuId, null, go.guid);
        foreach (i, ref item; gossipItems)
            message.items ~= GossipMessageItem(cast(uint) i, cast(ubyte) item.icon, item.coded, item.message);
        message.quests = questMenu.dup;
        send(message);
    }

    /// The player picked option `index` of a game object's menu: its script, its next menu or point of interest.
    package void onGameObjectGossipSelect(GameObject go, uint index)
    {
        import dmangos.world.dbscripts : DbScriptType, ScriptUnique;
        import dmangos.world.npcdata : GossipOption;

        if (index >= gossipItems.length)
            return;
        const item = gossipItems[index];
        // The player the source, the object the target (`Player::OnGossipSelect`).
        if (item.actionScript)
            context.startScript(DbScriptType.gossip, item.actionScript, map, player.guid, go.guid,
                ScriptUnique.byTarget);
        if (item.optionId == GossipOption.questGiver)
        {
            QuestGiver giver;
            if (questGiverNear(go.guid, 0, giver))
            {
                prepareQuestMenu(giver);
                sendPreparedQuest(giver);
            }
            return;
        }
        if (item.actionPoi)
            sendPointOfInterest(item.actionPoi);
        if (item.actionMenu > 0)
        {
            QuestGiver giver;
            const hasQuests = go.type == GameObjectType.questGiver && questGiverNear(go.guid, 0, giver);
            sendGameObjectGossip(go, item.actionMenu, hasQuests ? &giver : null);
        }
        else if (item.actionMenu < 0)
        {
            closeGossip();
            talkedToCreature(go.template_.entry, go.guid); // as CMaNGOS does for any gossip source
        }
    }

    /**
     * A button, chest, spell focus or goober with a linked trap (`linkedTrapId`): used, its trap springs on
     * the user, the trap of that entry standing at it (half a yard) if there is one, else its spell directly.
     */
    private void springLinkedTrap(GameObject go)
    {
        import dmangos.world.objects : HighGuid;

        uint trapEntry;
        switch (go.type)
        {
        case GameObjectType.button: trapEntry = go.template_.data[3]; break;
        case GameObjectType.chest: trapEntry = go.template_.data[7]; break;
        case GameObjectType.spellFocus: trapEntry = go.template_.data[2]; break;
        case GameObjectType.goober: trapEntry = go.template_.data[12]; break;
        default: return;
        }
        const trapTemplate = trapEntry ? trapEntry in context.data.gameObjectTemplates : null;
        if (trapTemplate is null || trapTemplate.type != GameObjectType.trap)
            return;
        GameObject trap;
        const at = go.position;
        foreach (o; map.objectsNear(at, 1))
            if (auto other = cast(GameObject) o)
                if (other !is go && other.spawn.entry == trapEntry)
                {
                    const p = other.position;
                    if ((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2 <= 0.25f)
                    {
                        trap = other;
                        break;
                    }
                }
        if (trap !is null)
            return context.trapSprung(map, this, trap);
        if (const spell = trapTemplate.data[3])
            castTriggeredAt(spell, player.guid);
    }

    /// A chest's loot: its template's items, with the loot rights of a group as a corpse has them.
    Loot makeGameObjectLoot(GameObject go)
    {
        import dmangos.world.character : Character;
        import dmangos.world.gameobjecthandlers : bindChestLoot;

        auto loot = new Loot(go.guid, null);
        go.gatherSkill = player.skillValue(skillMining)[0];
        bindChestLoot(context, map, go, loot);
        setLootRights(loot, go.position, (ulong) => false);
        if (const id = go.lootId)
            if (const template_ = context.data.loot.gameObject[id])
            {
                bool meets(uint condition)
                {
                    return conditionMet(condition);
                }

                bool allowed(ulong guid, const LootItem item)
                {
                    auto owner = cast(Character) context.onlinePlayer(guid);
                    if (item.quest)
                        return owner !is null && owner.hasQuestForItem(item.itemId);
                    return item.condition == 0 || (owner !is null && owner.conditionMet(item.condition));
                }

                loot.fill(template_, context.data.loot, context.data.items, map.random, &meets, &allowed);
            }
        go.despawnTimer = 5 * 60 * 1000; // gone 5 minutes after opening even if not emptied
        return loot;
    }

    /**
     * Herbalism, lockpicking and mining may rise by one, likelier the
     * nearer the skill is to the lock's (with the grey, green and yellow levels
     * 100, 50 and 25 above it).
     */
    void updateGatherSkill(uint skill, uint value, int redLevel, int multiplier = 1)
    {
        enum uint skillSkinning = 393;
        if (skill != skillHerbalism && skill != skillLockpicking && skill != skillMining && skill != skillSkinning)
            return;
        if (redLevel == 1)
            redLevel = 5; // what starts at 1 stops at 105, not 101
        // The chance in percent: grey 0, green 25, yellow 75, orange 100.
        int chance;
        if (value >= redLevel + 100)
            chance = 0;
        else if (value >= redLevel + 50)
            chance = 250;
        else if (value >= redLevel + 25)
            chance = 750;
        else
            chance = 1000;
        updateSkillPro(skill, chance * multiplier, 1);
    }

    /// A skill-up: by `chance` in a thousand, `step` more up to its maximum (and saved).
    package bool updateSkillPro(uint skill, int chance, uint step)
    {
        if (chance <= 0)
            return false;
        const current = player.skillValue(skill);
        if (!current[1] || !current[0] || current[0] >= current[1])
            return false;
        if (uniform!"[]"(1, 1000, map.random) > chance)
            return false;
        const value = cast(ushort)(current[0] + step > current[1] ? current[1] : current[0] + step);
        applySkill(skill, value, current[1]);
        return true;
    }

    // -----------------------------------------------------------------------
    // Quests
    // -----------------------------------------------------------------------

    /**
     * Whether a game object is active for this player's quests: a chest with loot one of them asks for, or a
     * goober whose quest is under way (or one that counts for a quest's objective).
     */
    package bool gameObjectActivatesForQuest(const GameObject go)
    {
        if (player is null)
            return false;
        const t = go.template_;
        switch (go.type)
        {
        case GameObjectType.chest:
            if (const id = go.lootId)
                if (const template_ = context.data.loot.gameObject[id])
                    foreach (item; questItems(template_))
                        if (hasQuestForItem(item))
                            return true;
            return false;
        case GameObjectType.goober:
            if (t.data[1] > 0 && questState(t.data[1]) == QuestState.incomplete)
                return true;
            return needsCreatureOrGo(-cast(int) t.entry);
        default:
            return false;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A door used opens and closes again after its time. An herb (a consumable chest locked for
 * herbalism) opened by the herb gathering spell: the skill checked, raised the first time, the
 * loot shown and taken; emptied, it is gone, and comes back after its respawn time. A goober
 * counts for the quest that needs it.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : lockFormat;
    import dmangos.world.gameobject;
    import dmangos.world.loot : lootRow;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : Player;
    import dmangos.world.quests : Quest, QuestState, QuestStatus, specialKillOrCast;
    import dmangos.world.spellcast : castResultPacket, SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    enum uint herbLock = 99, herbLoot = 500, gather = 2366, herbalism = 182, thoriumLock = 400, mine = 2575, mining = 186,
        blackwoodLock = 93, opening = 6477;
    // Lock: id, 8 types, 8 indexes, 8 skills, 8 skipped. Peacebloom's (Lock.dbc 29): herbalism (type 2) at 0; and
    // Small Thorium Vein's (400): mining (3) at 245.
    auto lockRow = new uint[lockFormat.length], thoriumRow = new uint[lockFormat.length], blackwoodRow = new uint[lockFormat.length];
    lockRow[0] = herbLock;
    lockRow[1] = 2;
    lockRow[9] = 2;
    lockRow[17] = 0;
    thoriumRow[0] = thoriumLock;
    thoriumRow[1] = 2;
    thoriumRow[9] = 3;
    thoriumRow[17] = 245;
    blackwoodRow[0] = blackwoodLock;
    blackwoodRow[2] = 2;
    blackwoodRow[10] = 12;
    context.client.locks = typeof(context.client.locks).parse(buildDbc(lockFormat, [lockRow, thoriumRow, blackwoodRow]), "Lock.dbc");
    // Herb Gathering and Mining as spell_template has them (2366, 2575: base points -1, dice 1, 5 points a level).
    foreach (id, lockType; [gather: 2, mine: 3])
    {
        context.data.spells.spells[id] = testSpell(id, 33, 26, 0);
        with (*context.data.spells.spells.edit(id))
        {
            miscValue[0] = lockType;
            casting.realPointsPerLevel[0] = 5;
            casting.dmgClass = DamageClass.none;
        }
    }
    context.data.spells.spells[opening] = testSpell(opening, 33, 23, 0);
    context.data.spells.spells.edit(opening).miscValue[0] = 12;
    context.data.loot.gameObject.add(herbLoot, lootRow(itemJerky, 100, 0, 1, 1, 0));

    GameObjectTemplate door = {entry: 9001, type: GameObjectType.door, displayId: 1, name: "Door"};
    door.data[2] = 2 * 0x10000; // closes after 2 s
    GameObjectTemplate herb = {entry: 9002, type: GameObjectType.chest, displayId: 2, name: "Peacebloom"};
    herb.data[0] = herbLock;
    herb.data[1] = herbLoot;
    herb.data[3] = 1; // consumable
    GameObjectTemplate idol = {entry: 9003, type: GameObjectType.goober, displayId: 3, name: "Idol"};
    idol.data[3] = 1 * 0x10000;
    context.data.gameObjectTemplates[9001] = door;
    context.data.gameObjectTemplates[9002] = herb;
    context.data.gameObjectTemplates[9003] = idol;
    context.data.gameObjectSpawns ~= [GameObjectSpawn(90001, 9001, 0, -8949, -131, 83.53f),
        GameObjectSpawn(90002, 9002, 0, -8950, -133, 83.53f, 0, [0, 0, 0, 0], 60),
        GameObjectSpawn(90003, 9003, 0, -8951, -131, 83.53f)];

    // At level 60: the skill counts, not the level.
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 60);
    anduin.read();
    auto me = cast(Player) anduin.session.character;
    me.spells ~= [gather, mine, opening];
    auto map = context.map(0);
    GameObject[3] gos;
    foreach (i; 0 .. 3)
    {
        gos[i] = context.makeGameObject(context.data.gameObjectSpawns[$ - 3 + i]);
        map.addObject(gos[i]);
    }
    anduin.read();
    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
        context.update(now);
    }

    // The door: open, then closed after its 2 seconds.
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(gos[0].guid));
    assert(gos[0].goState == goStateActive && gos[0].lootState == GoLootState.activated);
    tick(1000);
    assert(gos[0].goState == goStateActive);
    tick(1500);
    assert(gos[0].goState == goStateReady && gos[0].lootState == GoLootState.ready, "closed again");

    // A script opens it by its spawn for 20 seconds (`ScriptCommand.openDoor`); opening it again does nothing.
    {
        import dmangos.world.dbscripts : DbScriptStep, DbScriptType, ScriptCommand;

        DbScriptStep open = {id: 600, command: ScriptCommand.openDoor, datalong: 90001, datalong2: 20};
        DbScriptStep again = {id: 600, delay: 100, command: ScriptCommand.openDoor, datalong: 90001, datalong2: 20};
        context.data.dbScripts.add(DbScriptType.relay, open);
        context.data.dbScripts.add(DbScriptType.relay, again);
        context.startScript(DbScriptType.relay, 600, map, me.guid, 0);
        context.updateScripts(0);
        assert(gos[0].goState == goStateActive);
        map.update(10.msecs); // ticking from the next update on
        context.updateScripts(100);
        map.update(19_000.msecs);
        assert(gos[0].goState == goStateActive, "open for its 20 seconds");
        map.update(1500.msecs);
        assert(gos[0].goState == goStateReady, "and closed after them");
    }

    // The herb: no herbalism, no picking.
    ubyte[] gatherAt(ulong go, uint spell = gather)
    {
        ByteWriter w;
        w.put(spell);
        SpellTargets t;
        t.mask = TargetFlags.gameObject;
        t.gameObject = go;
        t.write(w);
        return w.data.dup;
    }
    anduin.read();
    // A thorium vein (a chest with its lock stands in) at mining 1, level 60: "requires 245", the skill's 0 against it
    // (not the level's 300).
    {
        GameObjectTemplate vein = {entry: 9004, type: GameObjectType.chest, displayId: 4, name: "Small Thorium Vein"};
        vein.data[0] = thoriumLock;
        context.data.gameObjectTemplates[9004] = vein;
        context.data.gameObjectSpawns ~= GameObjectSpawn(90004, 9004, 0, -8950, -132, 83.53f);
        auto go = context.makeGameObject(context.data.gameObjectSpawns[$ - 1]);
        map.addObject(go);
        anduin.read();
        me.setSkill(mining, 1, 75);
        anduin.write(Opcode.CMSG_CAST_SPELL, gatherAt(go.guid, mine));
        const refused = anduin.read();
        assert(!opcodesOf(refused).canFind(Opcode.SMSG_LOOT_RESPONSE)
            && bodyOf(refused, Opcode.SMSG_CAST_RESULT) == castResultPacket(mine, SpellCastResult.lowCastLevel),
            "mining 1 against 245");
    }
    // With herbalism 1: the loot, and a skill-up (sure at that level).
    me.setSkill(herbalism, 1, 75);
    anduin.write(Opcode.CMSG_CAST_SPELL, gatherAt(gos[1].guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
    assert(me.skillValue(herbalism) == [2, 75], "a skill-up");
    ByteWriter slot;
    slot.put(ubyte(0));
    anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, slot.data);
    anduin.write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(gos[1].guid));
    assert(me.inventory.count(itemJerky) >= 1);
    tick(100);
    assert(map.findObject(gos[1].guid) is null && context.gameObjectAwaitingRespawn(90002), "picked: gone");
    now += 61.seconds;
    tick(1000);
    assert(map.findObject(gos[1].guid) !is null, "back after its minute");

    // A herb that may be gathered two or three times (its least and most opens): full again after the first.
    {
        auto again = cast(GameObject) map.findObject(gos[1].guid);
        GameObjectTemplate t = cast() *again.template_;
        t.data[4] = 2;
        t.data[5] = 3;
        context.data.gameObjectTemplates[9002] = t;
        again.template_ = 9002 in context.data.gameObjectTemplates;
        uint picks;
        while (map.findObject(gos[1].guid) !is null && picks < 5)
        {
            anduin.write(Opcode.CMSG_CAST_SPELL, gatherAt(gos[1].guid));
            assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_RESPONSE), "full");
            anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, slot.data);
            anduin.write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(gos[1].guid));
            tick(100);
            ++picks;
            if (picks == 1)
                assert(map.findObject(gos[1].guid) !is null && again.lootState == GoLootState.ready, "filled again");
        }
        assert(picks >= 2 && picks <= 3, "two or three times");
    }

    // Blackwood food stores use ordinary quest loot even with their old Classic-DB script name.
    {
        enum uint nutStores = 175329, quest = 4763, foodLoot = 12811;
        GameObjectTemplate chest = {entry: nutStores, type: GameObjectType.chest, displayId: 2};
        chest.data[0] = blackwoodLock;
        chest.data[1] = foodLoot;
        context.data.gameObjectTemplates[nutStores] = chest;
        context.data.gameObjectScriptNames[nutStores] = "go_furbolg_food";
        context.data.loot.gameObject.add(foodLoot, lootRow(itemJerky, -100, 0, 1, 1, 0));
        const spawn = GameObjectSpawn(90006, nutStores, 0, -8950, -133, 83.53f);
        auto food = context.makeGameObject(spawn);
        map.addObject(food);
        assert(!food.behaviour, "food stores have no script to summon a warrior");

        const before = me.inventory.count(itemJerky);
        Quest needsFood = {id: quest, method: 2, reqItemId: [itemJerky, 0, 0, 0], reqItemCount: [before + 1, 0, 0, 0]};
        context.data.quests.quests[quest] = needsFood;
        anduin.session.inWorld.addQuest(context.data.quests.quests[quest]);
        anduin.read();
        anduin.write(Opcode.CMSG_CAST_SPELL, gatherAt(food.guid, opening));
        assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
        anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, slot.data);
        anduin.write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(food.guid));
        assert(me.inventory.count(itemJerky) == before + 1);
    }

    // The idol: a quest asks for it to be used; its use counts, and it sparkles while it does.
    Quest q = {id: 9100, method: 2, specialFlags: specialKillOrCast};
    q.reqCreatureOrGoId[0] = -9003;
    q.reqCreatureOrGoCount[0] = 1;
    context.data.quests.quests[9100] = q;
    me.questStatus[9100] = QuestStatus(9100, QuestState.incomplete);
    me.values.set!PLAYER_QUEST_LOG_1_1(9100u);
    assert(anduin.session.inWorld.gameObjectActivatesForQuest(gos[2]));
    anduin.read();
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(gos[2].guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTUPDATE_ADD_KILL));
    assert(me.questStatus[9100].mobCount[0] == 1 && !anduin.session.inWorld.gameObjectActivatesForQuest(gos[2]));

    // A wanted poster: it gives its quest, which is taken from it.
    GameObjectTemplate poster = {entry: 9004, type: GameObjectType.questGiver, displayId: 4, name: "Wanted!"};
    context.data.gameObjectTemplates[9004] = poster;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90004, 9004, 0, -8950, -131, 83.53f);
    auto board = context.makeGameObject(context.data.gameObjectSpawns[$ - 1]);
    map.addObject(board);
    Quest bounty = {id: 9200, method: 2, maxLevel: 60, title: "Bounty"};
    context.data.quests.quests[9200] = bounty;
    context.data.quests.gameObjectStarts[9004] = [9200];
    anduin.read();
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(board.guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTGIVER_QUEST_DETAILS), "its quest offered");
    ByteWriter accept;
    accept.put(board.guid);
    accept.put(9200u);
    anduin.write(Opcode.CMSG_QUESTGIVER_ACCEPT_QUEST, accept.data);
    assert(9200 in me.questStatus && me.questStatus[9200].status != QuestState.none, "taken (and done: it asks nothing)");

    // A plaque with its own gossip: its text, an option to read on (another menu), and a vendor option it cannot serve.
    {
        import dmangos.world.npcdata : GossipMenuOption, GossipMenuText, GossipOption;
        import dmangos.world.packets : ClientGossipSelectOption, ServerGossipMessage;

        GossipMenuOption readOn = {menuId: 9300, id: 0, text: "Read on.", optionId: GossipOption.gossip, actionMenuId: 9301};
        GossipMenuOption sell = {menuId: 9300, id: 1, text: "Sell.", optionId: GossipOption.vendor};
        context.data.npcs.options[9300] = [readOn, sell];
        context.data.npcs.menus[9300] = [GossipMenuText(9300, 77001, 0, 0)];
        context.data.npcs.menus[9301] = [GossipMenuText(9301, 77002, 0, 0)];
        GameObjectTemplate plaque = {entry: 9005, type: GameObjectType.questGiver, displayId: 4, name: "Plaque"};
        plaque.data[3] = 9300;
        context.data.gameObjectTemplates[9005] = plaque;
        context.data.gameObjectSpawns ~= GameObjectSpawn(90005, 9005, 0, -8949, -133, 83.53f);
        auto stone = context.makeGameObject(context.data.gameObjectSpawns[$ - 1]);
        map.addObject(stone);
        anduin.read();
        anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(stone.guid));
        ServerGossipMessage gossipOf(const(ServerPacketRead)[] got)
        {
            import dmangos.serialization : deserialize;

            auto r = ByteReader(bodyOf(got, Opcode.SMSG_GOSSIP_MESSAGE));
            return deserialize!ServerGossipMessage(r);
        }

        auto shown = gossipOf(anduin.read());
        assert(shown.guid == stone.guid && shown.textId == 77001 && shown.items.length == 1, "its text and one option");
        anduin.write(Opcode.CMSG_GOSSIP_SELECT_OPTION, ClientGossipSelectOption(stone.guid, 0));
        shown = gossipOf(anduin.read());
        assert(shown.textId == 77002 && shown.items.length == 0, "the next page");
    }
}

/// A trap: a player stepping within its radius springs it (its spell, at the player); with one charge it is used up.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint sting = 95300;
    context.data.spells.spells[sting] = testSpell(sting, 3, 1, 0); // a dummy, at the target
    context.data.spells.spells.edit(sting).casting.dmgClass = DamageClass.none;
    GameObjectTemplate trap = {entry: 9020, type: GameObjectType.trap, displayId: 1, name: "Trap"};
    trap.data[2] = 4;      // diameter: 2 yards around it
    trap.data[3] = sting;
    trap.data[4] = 1;      // one charge
    context.data.gameObjectTemplates[9020] = trap;
    context.data.gameObjectSpawns ~= GameObjectSpawn(90020, 9020, 0, -8945, -132, 83.53f, 0, [0, 0, 0, 0], 60);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto map = context.map(0);
    auto go = context.makeGameObject(context.data.gameObjectSpawns[$ - 1]);
    map.addObject(go);
    anduin.read();

    map.relocated(anduin.session.inWorld);
    assert(!opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO), "five yards off: nothing");
    (cast(Player) anduin.session.character).movement.position = Position(-8945.5f, -132, 83.53f);
    map.relocated(anduin.session.inWorld);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO), "sprung");
    assert(map.findObject(go.guid) is null && context.gameObjectAwaitingRespawn(90020), "its one charge used");

    // Linked traps: a button standing on its trap springs it when used; a goober with none casts the trap's spell.
    import dmangos.world.packets : ClientGuid;

    GameObjectTemplate hidden = {entry: 9023, type: GameObjectType.trap, displayId: 1, name: "Hidden trap"};
    hidden.data[3] = sting; // no radius: only its link springs it
    GameObjectTemplate lever = {entry: 9024, type: GameObjectType.button, displayId: 1, name: "Lever"};
    lever.data[3] = 9023;
    GameObjectTemplate urn = {entry: 9025, type: GameObjectType.goober, displayId: 1, name: "Urn"};
    urn.data[12] = 9023;
    context.data.gameObjectTemplates[9023] = hidden;
    context.data.gameObjectTemplates[9024] = lever;
    context.data.gameObjectTemplates[9025] = urn;
    context.data.gameObjectSpawns ~= [GameObjectSpawn(90023, 9023, 0, -8946, -130, 83.53f),
        GameObjectSpawn(90024, 9024, 0, -8946, -130, 83.53f), GameObjectSpawn(90025, 9025, 0, -8946, -134, 83.53f)];
    GameObject[3] linked;
    foreach (i; 0 .. 3)
    {
        linked[i] = context.makeGameObject(context.data.gameObjectSpawns[$ - 3 + i]);
        map.addObject(linked[i]);
    }
    anduin.read();
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(linked[1].guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO) && linked[0].trapReadyAt > 0, "the lever's trap");
    anduin.write(Opcode.CMSG_GAMEOBJ_USE, ClientGuid(linked[2].guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO), "the urn's trap spell");
}
