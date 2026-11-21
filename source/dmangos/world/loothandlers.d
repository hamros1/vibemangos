/**
 * Killing for experience and loot: tapping, the rewards of a kill, who may loot a corpse, and the
 * loot opcodes, mixed into `dmangos.world.character.Character`.
 *
 * The first player to hurt a creature taps it: it and its group get the experience and the loot.
 * A group shares the experience by level among its members near the kill (74 yards), with a bonus
 * for its size; a member more than the grey level above the creature gets none. The loot goes by
 * the group's loot method (`dmangos.world.loot`).
 */
module dmangos.world.loothandlers;

import dmangos.world.money : Copper;

/// See the module documentation.
mixin template LootHandlers()
{
    import dmangos.world.money : Copper;
    import std.algorithm.comparison : max;
    import dmangos.log : info;
    import dmangos.world.context : WorldContext;
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : ItemClass, nullBag, nullSlot, UnitFlags;
    import dmangos.world.experience;
    import dmangos.world.inventory : EquipError, InventoryResult, Item, ItemPosCount;
    import dmangos.world.loot;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.loothandlers : ClientLootMasterGive, ClientLootRoll, ClientLootSlot;
    import dmangos.cluster.protocol : GroupLootRoll;
    import dmangos.world.map : Map, packetBody;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid, ServerItemPushResult;
    import dmangos.world.player : DeathState;
    import dmangos.world.updatefields;

    package ulong lootTarget; // the loot whose window is open

private:

    /// The loot `guid` holds on this map (a creature's corpse, an open chest); null if none.
    package Loot lootOf(ulong guid)
    {
        import dmangos.world.gameobject : GameObject;

        if (auto creature = cast(Creature) map.findObject(guid))
            return creature.loot;
        if (auto bones = cast(imported!"dmangos.world.corpse".Corpse) map.findObject(guid))
            return bones.loot;
        if (auto go = cast(GameObject) map.findObject(guid))
            return go.loot;
        if (auto loot = guid in itemLoots)
            return *loot;
        return null;
    }

    /// The loot of the items this player opened and has not emptied, by item guid.
    Loot[ulong] itemLoots;

    /**
     * The client opens a lootable item in the bags (not locked, or unlocked, and the
     * player's level enough), its loot (`item_loot_template`, its money) shown; emptied, it is gone.
     */
    @Handles(Opcode.CMSG_OPEN_ITEM, WorldState.inWorld)
    void handleOpenItem(ref ByteReader reader)
    {
        import dmangos.world.inventory : itemDynFlagUnlocked;
        import dmangos.world.character : Character;

        const bag = reader.read!ubyte, slot = reader.read!ubyte;
        auto item = player.inventory[bag, slot];
        if (item is null)
            return sendEquipError(InventoryResult.itemNotFound);
        const proto = item.entry in context.data.items;
        if (proto is null)
            return sendEquipError(InventoryResult.itemNotFound);
        if (proto.requiredLevel > player.data.level)
            return sendEquipError(EquipError(InventoryResult.lootCantLootThatNow, item));
        // A lock that needs picking (a `Lock.dbc` skill) stays shut.
        if (proto.details.lockId && !(item.values[ITEM_FIELD_FLAGS] & itemDynFlagUnlocked))
        {
            const lock = context.client.locks.lookup(proto.details.lockId);
            if (lock is null || lock.skill[0] || lock.skill[1])
                return sendEquipError(EquipError(InventoryResult.itemLocked, item));
        }
        // A gift: unwrapped, what was in it (`character_gifts`) back as it was.
        {
            import dmangos.world.inventory : itemDynFlagWrapped, ItemState;

            if (item.values[ITEM_FIELD_FLAGS] & itemDynFlagWrapped)
            {
                uint entry, flags;
                const inside = context.database.loadGift(item.guid, entry, flags) ? entry in context.data.items : null;
                if (inside is null)
                {
                    player.inventory.destroy(item.bagSlot, item.slot); // nothing known inside
                    context.database.deleteGift(item.guid);
                    return flushInventory();
                }
                item.changeEntry(inside);
                item.values.set!ITEM_FIELD_GIFTCREATOR(0UL);
                item.values.set!ITEM_FIELD_FLAGS(flags);
                player.inventory.setState(item, ItemState.changed);
                context.database.deleteGift(item.guid);
                return flushInventory();
            }
        }
        showItemLoot(item);
    }

    /**
     * An item's own loot (`item_loot_template`, its money) shown to the player: an item opened, or a
     * lockbox picked open; emptied, the item is destroyed. `disenchanting`: what it disenchants into
     * (`disenchant_loot_template` by its `DisenchantID`) instead, which is temporary: released, what is left
     * goes into the bags (lost where it does not fit) and the item is destroyed all the same (CMaNGOS
     * `Loot::Release`, `LOOT_DISENCHANTING`).
     */
    package void showItemLoot(Item item, bool disenchanting = false)
    {
        const proto = item.proto;
        const guid = item.fullGuid;
        auto loot = itemLoots.get(guid, null);
        if (loot !is null && disenchanting)
        {
            loot.lootedForAll = null; // another kind of loot: made again
            itemLoots.remove(guid);
            loot = null;
        }
        if (loot is null)
        {
            auto self = this;
            loot = new Loot(guid, (ulong who) => who == self.player.guid ? cast(Looter) self : null);
            loot.clock = () => context.unixTime;
            loot.clientType = ClientLootType.pickpocketing;
            loot.owners[player.guid] = true;
            loot.currentLooter = player.guid;
            loot.rule = LootRule.notGroup;
            const lootTemplate = disenchanting ? context.data.loot.disenchant[proto.details.disenchantId]
                : context.data.loot.item[item.entry];
            if (const template_ = lootTemplate)
            {
                bool meets(uint condition)
                {
                    return conditionMet(condition);
                }

                bool allowed(ulong, const LootItem it)
                {
                    if (it.quest)
                        return hasQuestForItem(it.itemId);
                    return it.condition == 0 || conditionMet(it.condition);
                }

                loot.fill(template_, context.data.loot, context.data.items, map.random, &meets, &allowed);
            }
            if (disenchanting)
                loot.beforeRelease = (Looter looter) {
                    foreach (it; loot.items)
                        if (it.slotTypeFor(looter.looterGuid, loot) != LootSlotType.none)
                            looter.storeLoot(it.itemId, it.count, it.randomPropertyId, true);
                    loot.items = null; // what did not fit is lost
                };
            else
                loot.generateMoney(proto.details.minMoneyLoot, proto.details.maxMoneyLoot, map.random);
            // An item's loot released: emptied, the item is destroyed.
            loot.lootedForAll = () {
                itemLoots.remove(guid);
                if (auto still = itemByGuid(guid))
                {
                    player.inventory.destroy(still.bagSlot, still.slot);
                    flushInventory(true);
                }
            };
            itemLoots[guid] = loot;
        }
        if (lootTarget && lootTarget != guid)
            if (auto other = lootOf(lootTarget))
                other.release(this);
        loot.showContentTo(this);
    }

    /// `SMSG_LOOT_RESPONSE` with an error: the window does not open.
    void sendLootError(ulong guid, LootError error)
    {
        deliver(Opcode.SMSG_LOOT_RESPONSE, lootErrorPacket(guid, error));
    }

    /// The client loots: the window opens on a corpse in reach, if there is something for this player.
    @Handles(Opcode.CMSG_LOOT, WorldState.inWorld)
    void handleLoot(const ClientGuid request)
    {
        if (player.deathState != DeathState.alive || transferring)
            return;
        if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0)
            return sendLootError(request.guid, LootError.notStanding);
        // Bones whose insignia this player took (`removedInsignia`).
        if (auto bones = cast(imported!"dmangos.world.corpse".Corpse) map.findObject(request.guid))
        {
            const a = player.position, b = bones.position;
            if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 > 10.0f ^^ 2)
                return sendLootError(request.guid, LootError.tooFar);
            if (bones.loot is null)
            {
                ByteWriter w;
                w.put(request.guid);
                w.put(ubyte(1));
                return deliver(Opcode.SMSG_LOOT_RELEASE_RESPONSE, w.data);
            }
            if (lootTarget && lootTarget != request.guid)
                if (auto other = lootOf(lootTarget))
                    other.release(this);
            interruptAuras(AuraInterrupt.looting);
            return bones.loot.showContentTo(this);
        }
        auto creature = cast(Creature) map.findObject(request.guid);
        if (creature is null)
        {
            actAtReplica(request.guid, ArrivalAction(0, 0, 0, request.guid)); // the corpse is another node's
            return;
        }
        const range = max(5.0f, creature.values.get!UNIT_FIELD_COMBATREACH + 4.0f / 3
            + player.values.get!UNIT_FIELD_COMBATREACH);
        const a = player.position, b = creature.position;
        if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 > range ^^ 2)
            return sendLootError(request.guid, LootError.tooFar);
        if (creature.alive || creature.loot is null)
        {
            ByteWriter w;
            w.put(request.guid);
            w.put(ubyte(1));
            return deliver(Opcode.SMSG_LOOT_RELEASE_RESPONSE, w.data);
        }
        if (lootTarget && lootTarget != request.guid)
            if (auto other = lootOf(lootTarget))
                other.release(this);
        interruptAuras(AuraInterrupt.looting); // CMaNGOS's `DoLoot`
        recheckQuestLoot(creature.loot);
        recheckRemoteMasterLoot(creature.loot);
        creature.loot.showContentTo(this);
        creature.inspectingLoot();
    }

    /// The client takes the money from the open window.
    @Handles(Opcode.CMSG_LOOT_MONEY, WorldState.inWorld)
    void handleLootMoney()
    {
        if (auto loot = lootTarget ? lootOf(lootTarget) : null)
            loot.sendGold(this);
    }

    /// The client takes an item from the open window into the bags.
    @Handles(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, WorldState.inWorld)
    void handleAutostoreLootItem(const ClientLootSlot request)
    {
        auto loot = lootTarget ? lootOf(lootTarget) : null;
        if (loot is null)
            return;
        auto item = loot.itemInSlot(request.slot);
        if (item is null)
        {
            sendEquipError(InventoryResult.itemNotFound);
            return loot.release(this);
        }
        if (item.quest)
            recheckQuestLoot(loot);
        const type = item.slotTypeFor(player.guid, loot);
        if (item.blocked || type == LootSlotType.none
            || (type == LootSlotType.master && item.condition && !conditionMet(item.condition)))
            return loot.release(this);
        loot.sendItem(this, item);
    }

    /// At the corpse, the player's current quest log is authoritative, even after a handoff.
    void recheckQuestLoot(Loot loot)
    {
        import dmangos.world.character : Character;

        bool changed = loot.recheckQuestLooter(player.guid, (const LootItem item) => hasQuestForItem(item.itemId));
        if (loot.currentLooter && loot.currentLooter != player.guid)
            if (auto current = cast(Character) loot.find(loot.currentLooter))
                changed |= loot.recheckQuestLooter(current.looterGuid,
                    (const LootItem item) => current.hasQuestForItem(item.itemId));
        if (changed && loot.changed !is null)
            loot.changed();
    }

    /// The master's item conditions can be checked locally once their simulation arrives.
    void recheckRemoteMasterLoot(Loot loot)
    {
        if (loot.masterStartsRemote && player.guid == loot.masterLooter)
            loot.checkMasterConditions(&conditionMet);
    }

    /// The client closes the loot window.
    @Handles(Opcode.CMSG_LOOT_RELEASE, WorldState.inWorld)
    void handleLootRelease(const ClientGuid request)
    {
        if (auto loot = lootOf(request.guid))
            return loot.release(this);
        if (lootTarget == request.guid)
            lootWindow(request.guid, false);
    }

    /// The master looter hands an item to a member who may have it.
    @Handles(Opcode.CMSG_LOOT_MASTER_GIVE, WorldState.inWorld)
    void handleLootMasterGive(const ClientLootMasterGive request)
    {
        import dmangos.world.character : Character;

        auto loot = lootOf(request.loot);
        if (loot is null)
            return;
        if (loot.rule != LootRule.masterLoot || player.guid != loot.masterLooter)
            return sendLootError(request.loot, LootError.didntKill);
        auto item = loot.itemInSlot(request.slot);
        if (item is null)
            return sendEquipError(InventoryResult.itemNotFound);
        if (item.remoteAward || item.slotTypeFor(player.guid, loot) != LootSlotType.master
            || (item.condition && !conditionMet(item.condition)))
            return sendLootError(request.loot, LootError.masterOther);
        if (auto target = cast(Character) loot.find(request.target))
        {
            if ((request.target in item.allowed || request.target in loot.remoteMembers)
                && (!item.condition || target.conditionMet(item.condition)))
            {
                item.blocked = false;
                return loot.notifyMasterAwardError(loot.sendItem(target, item, false));
            }
            return sendLootError(request.loot, LootError.masterOther);
        }
        if (!loot.sendRemoteMasterAward(request.target, item))
            sendLootError(request.loot, LootError.masterOther);
    }

    /// The client rolls on an item: need, greed or pass.
    @Handles(Opcode.CMSG_LOOT_ROLL, WorldState.inWorld)
    void handleLootRoll(const ClientLootRoll request)
    {
        if (request.vote > RollVote.greed)
            return;
        if (auto loot = lootOf(request.loot))
        {
            loot.vote(this, request.slot, cast(RollVote) request.vote);
            return;
        }
        if (auto offer = RemoteLootKey(request.loot, request.slot) in remoteLootOffers)
            voteOnRemoteLoot(*offer, cast(RollVote) request.vote);
    }

    static struct RemoteLootKey
    {
        ulong target;
        uint slot;
    }

    static struct RemoteLootOffer
    {
        GroupLootRoll message;
        ushort node;
        long expires;
        bool voted;
        bool awardHandled;
    }

    RemoteLootOffer[RemoteLootKey] remoteLootOffers;

    void voteOnRemoteLoot(ref RemoteLootOffer offer, RollVote vote)
    {
        if (offer.voted || offer.expires < context.unixTime)
            return;
        if (offer.message.condition && !conditionMet(offer.message.condition))
            vote = RollVote.notValid;
        else if (offer.message.needBeforeGreed && vote != RollVote.pass && !canUseItem(offer.message.item))
            vote = RollVote.pass;
        auto message = offer.message;
        message.action = GroupLootRoll.Action.vote;
        message.choice = vote;
        offer.message.choice = vote;
        offer.voted = true; // an award can come back synchronously in memory
        if (!context.sendRemoteGroupLoot(offer.node, message))
            offer.voted = false;
    }

    package void offerRemoteLoot(ushort node, const ref GroupLootRoll message)
    {
        foreach (key; remoteLootOffers.keys)
            if (remoteLootOffers[key].expires < context.unixTime)
                remoteLootOffers.remove(key);
        const key = RemoteLootKey(message.loot, message.slot);
        if (auto previous = key in remoteLootOffers)
            if (previous.node == node && previous.message.roll >= message.roll)
                return;
        remoteLootOffers[key] = RemoteLootOffer(message, node, context.unixTime + lootRollSeconds + 30);
        if ((message.condition && !conditionMet(message.condition))
            || (message.needBeforeGreed && !canUseItem(message.item)))
            voteOnRemoteLoot(remoteLootOffers[key], RollVote.pass);
        else
            deliver(Opcode.SMSG_LOOT_START_ROLL, startRollPacket(message.loot, message.slot, message.item,
                message.randomProperty));
    }

    package void awardRemoteLoot(ushort node, const ref GroupLootRoll message)
    {
        auto offer = RemoteLootKey(message.loot, message.slot) in remoteLootOffers;
        if (offer is null || offer.node != node || offer.message.roll != message.roll || !offer.voted
            || (offer.message.choice != RollVote.need && offer.message.choice != RollVote.greed)
            || offer.awardHandled || offer.expires < context.unixTime
            || offer.message.item != message.item || offer.message.count != message.count
            || offer.message.randomProperty != message.randomProperty || !context.canWrite())
            return; // without the original offer, we cannot tell whether an award was already made
        offer.awardHandled = true;
        GroupLootRoll result = message;
        result.action = GroupLootRoll.Action.result;
        result.stored = storeLoot(message.item, message.count, message.randomProperty, true) == 0;
        if (!result.stored || context.settleWrites())
            context.sendRemoteGroupLoot(node, result);
    }

    // -----------------------------------------------------------------------
    // The kill
    // -----------------------------------------------------------------------

    /// The first player to hurt a creature taps it, for itself and its group.
    public void tapCreature(Creature victim)
    {
        if (victim.lootRecipient)
            return;
        auto group = context.groups.of(player.guid);
        victim.setLootRecipient(player.guid, group is null ? 0 : group.id);
    }

    /**
     * The rewards of a kill: the player who tapped the creature
     * (or this one) and its group get the experience, and the loot is made for them.
     */
    void rewardKill(Creature victim)
    {
        import dmangos.world.character : Character;

        if (victim.lootRecipient && context.onlinePlayer(victim.lootRecipient) is null
            && context.killShareElsewhere !is null)
        {
            import dmangos.world.replication : Replica;

            if (cast(Replica) map.findObject(victim.lootRecipient))
                return rewardCreatureKillFor(context, map, victim, victim.lootRecipient);
        }
        auto tapper = cast(Character) context.onlinePlayer(victim.lootRecipient);
        if (tapper is null || tapper.map !is map)
            tapper = this;
        if (victim.lootRecipient == 0)
            tapCreature(victim);
        // The killing blow, in the combat log (`PARTY_KILL`): to the killer and its group near the kill, when it
        // is the tapper's or of the tapper's group (CMaNGOS's `Unit::Kill`).
        {
            auto group = context.groups.of(player.guid);
            if (tapper is this || (group !is null && group is context.groups.of(tapper.player.guid)))
            {
                ByteWriter w;
                w.put(player.guid);
                w.put(victim.guid);
                deliver(Opcode.SMSG_PARTYKILLLOG, w.data);
                if (group !is null)
                    foreach (ref slot; group.members)
                        if (slot.guid != player.guid)
                            if (auto member = cast(Character) context.onlinePlayer(slot.guid))
                                if (member.map is map && member.atGroupRewardDistance(victim))
                                    member.deliver(Opcode.SMSG_PARTYKILLLOG, w.data);
            }
        }
        tapper.rewardAtKill(victim);
        tapper.prepareBodyLoot(victim);
        map.flushObjectChanges(victim);
        map.refreshViewers(victim);
    }

    /// The experience of a kill, for the player alone or shared by its group.
    package void rewardAtKill(Creature victim)
    {
        rewardCreatureExperience(context, map, victim, player.guid);
    }

    package static void rewardCreatureKillFor(WorldContext context, Map map, Creature victim, ulong tapper)
    {
        rewardCreatureExperience(context, map, victim, tapper);
        prepareBodyLootFor(context, map, victim, tapper);
        map.flushObjectChanges(victim);
        map.refreshViewers(victim);
    }

    private static void rewardCreatureExperience(WorldContext context, Map map, Creature victim, ulong tapper)
    {
        import dmangos.cluster.protocol : KillShare;
        import dmangos.world.replication : Replica;
        import dmangos.world.character : Character;

        const value = killValueAt(context, map, victim);
        auto group = context.groups.of(tapper);
        if (group is null)
        {
            if (auto local = cast(Character) context.onlinePlayer(tapper))
            {
                local.rewardKillReputation(victim, 1);
                local.rewardHonorForCreature(victim);
                local.killedMonster(victim.template_.entry, victim.guid);
                const xp = killGain(local.player.data.level, value);
                local.petGainsXp(xp); // the pet's share, before its owner perhaps passes its level
                return local.giveXP(xp, victim.guid, 1.0f);
            }
            if (context.killShareElsewhere !is null)
            {
                const owner = context.remoteKillRecipient(tapper, map);
                if (owner.node)
                {
                    const share = KillShare(tapper, victim.guid, victim.template_.entry, value.level,
                        killGain(owner.level, value), 1, 1);
                    context.killShareElsewhere(owner.node, share);
                }
            }
            return;
        }
        // The members near the kill: here, or (in a cluster) simulated by another node whose replica is here.
        static struct Near
        {
            Character here;  // null: on node `node`
            ulong guid;
            ushort node;
            uint level;
            bool alive;
            float reputationRate = 0;
            uint xp;
            float rate = 1;
        }
        Near[] members;
        foreach (ref slot; group.members)
        {
            if (auto member = cast(Character) context.onlinePlayer(slot.guid))
            {
                if (member.atGroupRewardDistance(victim))
                    members ~= Near(member, slot.guid, 0, member.player.data.level,
                        member.player.deathState == DeathState.alive);
            }
            else if (context.killShareElsewhere !is null)
                if (auto replica = cast(Replica) map.findObject(slot.guid))
                {
                    const p = replica.position, v = victim.position;
                    const dungeon_ = context.client.maps.lookup(map.id) !is null && context.client.maps.lookup(map.id).isDungeon;
                    if (dungeon_ || (p.x - v.x) ^^ 2 + (p.y - v.y) ^^ 2 + (p.z - v.z) ^^ 2 <= groupXpDistance ^^ 2)
                        members ~= Near(null, slot.guid, replica.owner, replica.fields().get!UNIT_FIELD_LEVEL,
                            replica.fields().get!UNIT_FIELD_HEALTH > 0);
                }
        }
        // The living members near the kill, their levels added up, the highest and the highest not grey.
        uint sumLevel, nearCount;
        Near* highest, highestNotGray;
        foreach (ref m; members)
        {
            if (!m.alive)
                continue;
            ++nearCount;
            sumLevel += m.level;
            if (highest is null || highest.level < m.level)
                highest = &m;
            if (!isGray(m.level, victim.values.get!UNIT_FIELD_LEVEL)
                && (highestNotGray is null || highestNotGray.level < m.level))
                highestNotGray = &m;
        }
        // The reputation: all of it to each, as alone (docs/FORMULAS.md, "Reputation").
        foreach (ref m; members)
            if (m.alive)
                m.reputationRate = 1;
        if (highest !is null && highestNotGray !is null)
        {
            import std.math : round;

            const xp = killGain(highestNotGray.level, value);
            const rate = groupRate(nearCount);
            // The experience: each a share by its level; members above the highest not grey get none.
            foreach (ref m; members)
            {
                if (!m.alive || m.level > highestNotGray.level)
                    continue;
                const share = rate * m.level / sumLevel;
                const memberXp = highest is highestNotGray ? xp * share : xp * share * 0.5f + 1.0f;
                m.xp = cast(uint) round(memberXp);
                m.rate = rate;
            }
        }
        const entry = victim.template_.entry, level = victim.values.get!UNIT_FIELD_LEVEL;
        // Every member near the kill gets the kill's quest credit, its reputation, its experience.
        foreach (ref m; members)
        {
            if (m.here !is null)
            {
                m.here.killedMonster(entry, victim.guid);
                if (m.alive)
                    m.here.rewardHonorForCreature(victim);
                if (m.reputationRate > 0)
                    m.here.rewardKillReputation(victim, m.reputationRate);
                if (m.xp)
                {
                    m.here.petGainsXp(m.xp / 2); // half for its pet
                    m.here.giveXP(m.xp, victim.guid, m.rate);
                }
            }
            else
            {
                KillShare share = {target: m.guid, victim: victim.guid, entry: entry, level: level, xp: m.xp,
                    rate: m.rate, reputationRate: m.reputationRate};
                context.killShareElsewhere(m.node, share);
            }
        }
    }

    /// Another node's kill, shared with this player in its group (`KillShare`).
    package void killShared(uint entry, ulong victim, uint level, uint xp, float rate, float reputationRate)
    {
        killedMonster(entry, victim);
        if (reputationRate > 0)
            rewardKillReputation(entry, level, reputationRate);
        if (xp)
            giveXP(xp, victim, rate);
        flushPlayerChanges();
    }

    /// What the experience of a kill needs to know of `victim`.
    KillValue killValue(const Creature victim)
    {
        return killValueAt(context, map, victim);
    }

    private static KillValue killValueAt(WorldContext context, Map map, const Creature victim)
    {
        enum uint critter = 8, noXp = 0x2; // the critter creature type; the static flag for no experience
        enum uint rankNormal = 0, rankRare = 4;
        const t = victim.template_;
        KillValue value;
        value.level = victim.values.get!UNIT_FIELD_LEVEL;
        value.elite = t.rank != rankNormal && t.rank != rankRare;
        if (const entry = context.client.maps.lookup(map.id))
            value.place = entry.isRaid ? KillPlace.raid : entry.isDungeon ? KillPlace.dungeon : KillPlace.world;
        value.multiplier = t.experienceMultiplier;
        value.noXp = t.creatureType == critter || (t.staticFlags1 & noXp) != 0;
        return value;
    }

    /// Whether this player shares a group kill: on the kill's map, and within 74 yards of it (anywhere in a dungeon).
    package bool atGroupRewardDistance(const Creature victim)
    {
        return atGroupRewardDistance(context.existingMap(victim.spawn.map, victim.instanceId), victim.position);
    }

    /// ditto, for a place on a map
    package bool atGroupRewardDistance(const Map there, Position b)
    {
        if (map !is there || transferring)
            return false;
        if (const entry = context.client.maps.lookup(map.id))
            if (entry.isDungeon)
                return true;
        const a = player.position;
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 <= groupXpDistance ^^ 2;
    }

    /**
     * A corpse's loot: who may
     * loot (this player, or its group's members near the kill or fighting it, by the group's method,
     * the round-robin turn moving on), and what there is.
     */
    package void prepareBodyLoot(Creature victim)
    {
        prepareBodyLootFor(context, map, victim, player.guid);
    }

    private static void prepareBodyLootFor(WorldContext context, Map map, Creature victim, ulong tapper)
    {
        import dmangos.world.character : Character;

        enum uint noLoot = 0x4; // the static flag for no loot
        const t = victim.template_;
        if (t.staticFlags1 & noLoot)
            return lootedOutNow(map, victim);
        auto theMap = map;
        auto loot = new Loot(victim.guid, (ulong guid) {
            auto session = cast(Character) context.onlinePlayer(guid);
            return session is null || session.map !is theMap ? null : cast(Looter) session;
        });
        loot.clock = () => context.unixTime;
        setLootRightsFor(context, map, tapper, loot, victim.position, (ulong guid) => victim.ai.threatOf(guid) > 0);

        const(LootTemplate) template_ = t.lootId ? context.data.loot.creature[t.lootId] : null;
        if (template_ is null && t.maxLootGold == 0)
            return lootedOutNow(map, victim);
        if (template_ !is null)
        {
            bool meets(uint condition)
            {
                return context.conditionMet(condition, tapper);
            }

            bool allowed(ulong guid, const LootItem item)
            {
                if (item.quest)
                {
                    // A quest item: only for one whose quest still asks for it.
                    auto owner = cast(Character) context.onlinePlayer(guid);
                    return owner !is null && owner.hasQuestForItem(item.itemId);
                }
                if (item.condition == 0)
                    return true;
                auto owner = cast(Character) context.onlinePlayer(guid);
                return owner !is null && owner.conditionMet(item.condition);
            }

            loot.fill(template_, context.data.loot, context.data.items, map.random, &meets, &allowed);
        }
        loot.generateMoney(t.minLootGold, t.maxLootGold, map.random);
        victim.loot = loot;
        loot.changed = () {
            theMap.refreshViewers(victim);
            if (loot.replicatesLootView)
                theMap.refreshReplicaLootView(victim);
        };
        loot.lootedForAll = () {
            victim.lootedOut();
            theMap.flushObjectChanges(victim);
            theMap.refreshViewers(victim);
        };
        loot.beginQuestLootChecks(theMap.id, &context.nextGameplaySequence, context.sendQuestLootCheck);
        if (victim.loot !is null && loot.lootedForEveryone())
            lootedOutNow(map, victim);
        else if (loot.replicatesLootView)
            theMap.refreshReplicaLootView(victim);
    }

    /// Nothing (more) to loot from `victim`: skinnable if it has a skin, its viewers told.
    static void lootedOutNow(Map map, Creature victim)
    {
        victim.lootedOut();
        map.flushObjectChanges(victim);
    }

    /// Who may loot: for loot at `at`; `fought` says who fought for it (a creature's threat list).
    package void setLootRights(Loot loot, Position at, scope bool delegate(ulong guid) fought)
    {
        setLootRightsFor(context, map, player.guid, loot, at, fought);
    }

    private static void setLootRightsFor(WorldContext context, Map map, ulong tapper, Loot loot,
        Position at, scope bool delegate(ulong guid) fought)
    {
        import dmangos.world.character : Character;
        import dmangos.cluster.protocol : LootCoinShare;
        import dmangos.world.groupservice : LootTurnHost, LootTurnReply, LootTurnRequest;
        import dmangos.world.replication : Replica;

        auto group = context.groups.of(tapper);
        if (group is null)
        {
            loot.owners[tapper] = true;
            loot.currentLooter = tapper;
            loot.rule = LootRule.notGroup;
            const owner = context.remoteKillRecipient(tapper, map).node;
            if (owner && owner != context.nodeId)
            {
                loot.remoteTapper = tapper;
                if (context.sendQuestLootCheck !is null)
                    loot.remoteMembers[tapper] = owner;
            }
            return;
        }
        loot.rule = cast(LootRule) group.lootMethod;
        loot.threshold = group.lootThreshold;
        const crossNodeRolls = context.sendRemoteGroupLoot !is null && context.deliverRemote !is null
            && (loot.rule == LootRule.groupLoot || loot.rule == LootRule.needBeforeGreed);
        const crossNodeMaster = loot.rule == LootRule.masterLoot && context.sendRemoteGroupLoot !is null;
        const crossNodeCoins = context.sendRemoteLootCoins !is null && context.canSendLootCoins !is null;
        const rotates = loot.rule == LootRule.roundRobin || loot.rule == LootRule.groupLoot
            || loot.rule == LootRule.needBeforeGreed;
        foreach (ref member; group.members)
        {
            const guid = member.guid;
            auto looter = cast(Character) context.onlinePlayer(guid);
            if (looter is null)
            {
                if (rotates || crossNodeCoins || crossNodeMaster || context.sendQuestLootCheck !is null)
                    if (auto remote = cast(Replica) map.findObject(guid))
                    {
                        const b = remote.position;
                        if (remote.fields.type == TypeId.player && remote.owner != context.nodeId
                            && ((at.x - b.x) ^^ 2 + (at.y - b.y) ^^ 2 + (at.z - b.z) ^^ 2 <= groupXpDistance ^^ 2
                                || fought(guid)))
                            loot.remoteMembers[guid] = remote.owner;
                    }
                continue;
            }
            if (looter.atGroupRewardDistance(map, at) || fought(guid))
                loot.owners[guid] = true;
        }
        if (loot.rule == LootRule.masterLoot)
        {
            loot.masterLooter = group.looter;
            loot.masterStartsRemote = crossNodeMaster && group.looter in loot.remoteMembers;
            if (loot.masterStartsRemote)
                loot.owners[group.looter] = true;
            if (group.looter !in loot.owners)
                loot.rule = LootRule.groupLoot;
        }
        const remoteMasterAwards = crossNodeMaster && loot.rule == LootRule.masterLoot && loot.remoteMembers.length;
        if (loot.remoteMembers.length && (crossNodeRolls || remoteMasterAwards))
        {
            loot.rollMap = map.id;
            loot.nextRoll = &context.nextGameplaySequence;
            loot.sendRemoteRoll = context.sendRemoteGroupLoot;
        }
        if (loot.remoteMembers.length && crossNodeRolls)
        {
            loot.tellRemoteRoller = (ushort node, ulong guid, Opcode opcode, const(ubyte)[] body_) {
                context.deliverRemote(node, guid, cast(ushort) opcode, body_);
            };
        }
        if (crossNodeCoins)
        {
            auto theMap = map;
            loot.coinNode = (ulong guid) {
                if (auto remote = cast(Replica) theMap.findObject(guid))
                    if (remote.fields.type == TypeId.player && remote.owner != context.nodeId
                        && context.canSendLootCoins(remote.owner))
                        return remote.owner;
                return ushort(0);
            };
            loot.payRemoteCoins = (ushort node, ulong guid, uint copper) {
                const message = LootCoinShare(context.nextGameplaySequence(), guid, theMap.id, copper);
                return context.sendRemoteLootCoins(node, message);
            };
        }
        if (rotates)
        {
            auto eligible = loot.owners.keys ~ loot.remoteMembers.keys;
            if (eligible.length > 1)
            {
                loot.remoteTurns = loot.remoteMembers.length != 0;
                loot.waitForTurn(tapper);
                context.services.call!(LootTurnHost.take)(LootTurnRequest(group.id, tapper, eligible),
                    (LootTurnReply turn) { loot.finishTurn(turn.looter); });
                return;
            }
        }
        else if (loot.owners.length > 1 && loot.rule != LootRule.freeForAll)
        {
            loot.currentLooter = group.takeLootTurn(loot.owners.keys);
            return;
        }
        else if (remoteMasterAwards)
        {
            loot.currentLooter = loot.masterLooter;
            return;
        }
        loot.currentLooter = tapper;
        loot.owners[tapper] = true;
        loot.rule = LootRule.notGroup;
    }

    /// Whether the condition `condition` holds for this player (no source).
    package bool conditionMet(uint condition)
    {
        import dmangos.world.conditions : ConditionSubject;

        auto subject = ConditionSubject(player, null);
        return context.data.npcs.conditions.satisfied(condition, subject, context.client);
    }

    // -----------------------------------------------------------------------
    // The looter
    // -----------------------------------------------------------------------

    /// See `Looter.storeLoot`: the item stored, everyone in the group told.
    public uint storeLoot(uint entry, uint count, int randomPropertyId, bool sendError)
    {
        ItemPosCount[] dest;
        const result = player.inventory.canStoreNew(nullBag, nullSlot, dest, entry, count);
        if (result != InventoryResult.ok)
        {
            if (sendError)
                sendEquipError(EquipError(result, null, null, 0, entry));
            return result;
        }
        auto item = player.inventory.storeNew(dest, entry, randomPropertyId > 0 ? randomPropertyId : 0);
        if (item is null)
            return InventoryResult.itemNotFound;
        const pushed = ServerItemPushResult(player.guid, 0, 0, 1, item.bagSlot, item.count == count ? item.slot
            : uint.max, item.entry, 0, cast(int) item.values[ITEM_FIELD_RANDOM_PROPERTIES_ID], count);
        if (auto group = context.groups.of(player.guid))
            group.broadcast(Opcode.SMSG_ITEM_PUSH_RESULT, packetBody(pushed));
        else
            send(pushed);
        flushInventory();
        return InventoryResult.ok;
    }

    /// See `Looter.receiveMoney`.
    public void receiveMoney(uint copper)
    {
        player.receive(Copper(copper));
        flushInventory(true);
    }

    /// See `Looter.canUseItem`.
    public bool canUseItem(uint entry)
    {
        import dmangos.world.inventory : itemSkill, itemSubclassWeaponFist, skillFistWeapons;

        // Need before greed's "can't use": the item's own requirements, and its weapon or armor skill (a mage
        // and mail; docs/FORMULAS.md "Group loot").
        const proto = entry in context.data.items;
        if (proto is null || player.inventory.canUse(proto) != InventoryResult.ok)
            return false;
        const skill = proto.itemClass == ItemClass.weapon && proto.subClass == itemSubclassWeaponFist
            ? skillFistWeapons : itemSkill(proto);
        return skill == 0 || player.skillRank(skill) != 0;
    }

    /// See `Looter.lootWindow`: the player starts looting (`UNIT_FLAG_LOOTING`), or stops.
    public void lootWindow(ulong target, bool open)
    {
        const flags = player.values.get!UNIT_FIELD_FLAGS;
        if (open)
        {
            lootTarget = target;
            player.values.set!UNIT_FIELD_FLAGS(flags | UnitFlags.looting);
        }
        else
        {
            if (lootTarget == target)
                lootTarget = 0;
            player.values.set!UNIT_FIELD_FLAGS(flags & ~UnitFlags.looting);
        }
        flushPlayerChanges();
    }

    /// Leaving the map (logging out, a far teleport): an open loot window is let go.
    void releaseLootOnLeave()
    {
        if (lootTarget == 0)
            return;
        if (auto loot = lootOf(lootTarget))
            loot.release(this);
        lootTarget = 0;
    }
}

/// `CMSG_AUTOSTORE_LOOT_ITEM`
struct ClientLootSlot
{
    ubyte slot;
}

/// `CMSG_LOOT_MASTER_GIVE`
struct ClientLootMasterGive
{
    ulong loot;
    ubyte slot;
    ulong target;
}

/// `CMSG_LOOT_ROLL`
struct ClientLootRoll
{
    ulong loot;
    uint slot;
    ubyte vote;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : MonoTime, msecs, seconds;
    import dmangos.world.creature : Creature;
    import dmangos.world.context : WorldContext;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.map : Map;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.replication : Replicator;
    import dmangos.world.teleport : moveTo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    /// Replicates loot sources from the owner (node 2) to the player's node.
    final class LootReplicaLink : Replicator
    {
        Map viewer;
        void create(ushort, uint, ulong cell, ulong guid, const(ubyte)[] state)
        {
            viewer.replicaCreated(2, cell, guid, state);
        }
        void values(ushort, uint, ulong guid, const(ubyte)[] slots) { viewer.replicaValues(2, guid, slots); }
        void move(ushort, uint, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion)
        {
            viewer.replicaMoved(2, guid, opcode, body_, motion);
        }
        void remove(ushort, uint, ulong guid) { viewer.replicaRemoved(2, guid); }
        void inRange(ushort, uint, Position, float, ushort, const(ubyte)[]) {}
    }

    /// The innkeeper made a level 1 creature of 30 health that drops 10 copper and jerky.
    Creature lootableInnkeeper(WorldContext context, uint condition = 0)
    {
        import dmangos.world.loot : lootRow, LootStore, LootStores;

        context.data.loot = LootStores.create();
        context.data.loot.creature.add(99, lootRow(itemJerky, 100, 0, 1, 1, condition));
        auto t = context.data.creatureTemplates.edit(creatureInnkeeper);
        t.lootId = 99;
        t.minLootGold = t.maxLootGold = 10;
        auto victim = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
        victim.values.set!UNIT_FIELD_LEVEL(1u);
        victim.values.set!UNIT_FIELD_HEALTH(30u);
        return victim;
    }

    /// Swings at `victim` until it dies.
    void killIt(ref TestClient client, Creature victim, ref MonoTime now)
    {
        client.write(Opcode.CMSG_ATTACKSWING, ClientGuid(victim.guid));
        foreach (_; 0 .. 200)
        {
            now += 2.seconds;
            client.session.update(2000.msecs);
            if (!victim.alive)
                break;
        }
        assert(!victim.alive);
    }
}

/**
 * Killing a creature: the experience, its corpse lootable by its killer only, the money and the item
 * taken; then nothing is left and it is no longer lootable.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.context : WorldContext;
    import dmangos.world.loot : LootStatus;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8945, -132, 83.5f));
    anduin.read();
    varian.read();
    auto victim = lootableInnkeeper(context);
    auto me = anduin.session.character;
    const money = me.money;

    (cast() me).setSkill(162, 1, 5); // unarmed, as a new character has it
    const unarmedBefore = me.skillValue(162)[0];
    killIt(anduin, victim, now);
    auto after = anduin.read();
    // The swings taught it: far below its maximum, a skill rises nearly every time.
    assert(me.skillValue(162)[0] > unarmedBefore && 162 in db.skillRows.get(7, null), "unarmed skill gained and saved");
    assert(opcodesOf(after).canFind(Opcode.SMSG_LOG_XPGAIN));
    assert(me.values[PLAYER_XP] == 50, "a level 1 creature is worth 50 to level 1");
    assert(victim.loot !is null && victim.lootRecipient == me.guid);
    // Its killer sees it lootable and not tapped; Varian, tapped and not lootable.
    const flags = victim.values.get!UNIT_DYNAMIC_FLAGS;
    assert(victim.fieldFor(7 | 0UL, 0, UNIT_DYNAMIC_FLAGS, flags) == Creature.dynLootable);
    assert(victim.fieldFor(varian.session.character.guid, 0, UNIT_DYNAMIC_FLAGS, flags) == Creature.dynTapped);

    // Varian, beside the corpse, may not loot it.
    varian.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(-8950, -131.5f, 83.5f)));
    varian.read();
    varian.write(Opcode.CMSG_LOOT, ClientGuid(victim.guid));
    assert(opcodesOf(varian.read()) == [Opcode.SMSG_LOOT_RELEASE_RESPONSE]);

    // Anduin opens it: 10 copper and the jerky.
    anduin.write(Opcode.CMSG_LOOT, ClientGuid(victim.guid));
    auto window = anduin.read();
    assert(opcodesOf(window).canFind(Opcode.SMSG_LOOT_RESPONSE));
    assert(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.looting);
    anduin.write(Opcode.CMSG_LOOT_MONEY, null);
    assert(me.money == money + Copper(10));
    anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
    const took = opcodesOf(anduin.read());
    assert(took.canFind(Opcode.SMSG_ITEM_PUSH_RESULT) && took.canFind(Opcode.SMSG_LOOT_REMOVED));
    assert(took.canFind(Opcode.SMSG_LOOT_RELEASE_RESPONSE), "nothing left: the window closes");
    assert(victim.loot is null && victim.fieldFor(me.guid, 0, UNIT_DYNAMIC_FLAGS, victim.values.get!UNIT_DYNAMIC_FLAGS) == 0);
    assert(!(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.looting));
    assert(victim.corpseTimer <= 2 * 60 * 1000, "looted: it goes within two minutes");
}

/// A group: the experience shared by level, with the bonus for its size only from three on; round robin's turn.
unittest
{
    import dmangos.world.context : WorldContext;
    import dmangos.world.group : LootMethod;
    import dmangos.world.loot : LootRule;
    import dmangos.world.packets : ClientGroupName;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8940, -132, 83.5f));
    anduin.read();
    jaina.read();
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    auto group = context.groups.of(7);
    assert(group !is null);
    group.lootMethod = LootMethod.roundRobin;
    anduin.read();
    jaina.read();
    auto victim = lootableInnkeeper(context);

    killIt(anduin, victim, now);
    // Two of level 1: 50 * 1/2 each.
    assert(anduin.session.character.values[PLAYER_XP] == 25 && jaina.session.character.values[PLAYER_XP] == 25);
    auto loot = victim.loot;
    assert(loot !is null && loot.rule == LootRule.roundRobin && loot.owners.length == 2);
    // The current looter alone may loot; the turn moves on to the other.
    import dmangos.world.loot : LootSlotType;

    const first = loot.currentLooter, other = first == 7 ? 8UL : 7UL;
    assert(loot.items[0].slotTypeFor(first, loot) == LootSlotType.normal);
    assert(loot.items[0].slotTypeFor(other, loot) == LootSlotType.none, "not its turn");
    assert(loot.canLoot(other), "the money is everyone's");
    assert(group.nextLooter == other);
}

/// An item with loot (a clam) opened: its loot shown as a pickpocket's; emptied, the item is gone.
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.world.inventory : Item;
    import dmangos.world.loot : lootRow;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.loot.item.add(itemJerky, lootRow(itemSword, 100, 0, 1, 1, 0)); // the "clam" holds a sword
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    anduin.session.inWorld.storeLoot(itemJerky, 1, 0, false);
    anduin.read();
    Item clam;
    foreach (item; me.inventory.all())
        if (item.entry == itemJerky)
            clam = item;
    ByteWriter open;
    open.put(clam.bagSlot);
    open.put(clam.slot);
    anduin.write(Opcode.CMSG_OPEN_ITEM, open.data);
    auto got = anduin.read();
    assert(got.length && got[$ - 1].opcode == Opcode.SMSG_LOOT_RESPONSE && got[$ - 1].body_[8] == 2, "a pickpocket's window");
    ByteWriter take;
    take.put(ubyte(0));
    anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, take.data);
    assert(me.inventory.count(itemSword) == 1 && me.inventory.count(itemJerky) == 0, "the sword, and no clam");
}

/**
 * A group member another node simulates (its replica here, near the kill) gets its share: the kill
 * is shared by the two, and that member's half goes to its node as a `KillShare`.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.cluster.protocol : KillShare;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.packets : ClientGroupName;
    import dmangos.world.player : Player;
    import dmangos.world.replication : encodePlayerState;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    ushort sentTo;
    KillShare[] shares;
    context.killShareElsewhere = (ushort node, const ref KillShare share) { sentTo = node; shares ~= share; };
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8945, -132, 83.5f));
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("varian"));
    varian.write(Opcode.CMSG_GROUP_ACCEPT, null);
    assert(context.groups.of(9) !is null);
    // Varian goes to node 2 (leaves this node's world); its replica stays near.
    auto map = context.map(0);
    const state = encodePlayerState(cast(Player) varian.session.character, 0);
    context.leaveWorldForMigration(varian.session.inWorld, 2);
    map.replicaCreated(owner: 2, cell: cellKeyAt(-8945, -132), guid: 9, state);
    assert(context.onlinePlayer(9) is null && map.findObject(9) !is null);
    anduin.read();

    auto victim = lootableInnkeeper(context);
    killIt(anduin, victim, now);
    const me = anduin.session.character;
    assert(shares.length == 1 && sentTo == 2, "Varian's share, to its node");
    const share = shares[0];
    assert(share.target == 9 && share.victim == victim.guid && share.entry == creatureInnkeeper);
    assert(share.xp > 0 && share.xp == me.values[PLAYER_XP], "halves of a level 1 creature, alike");
    assert(share.reputationRate == 1, "all of the reputation to each");
}

// Both clients vote on the corpse's node, but only the winner's inventory is changed.
unittest
{
    import dmangos.cluster.protocol : GroupLootRoll;
    import dmangos.world.character : Character;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : LootMethod;
    import dmangos.world.loot : RollVote;
    import dmangos.world.replication : encodePlayerState;

    foreach (scenario; 0 .. 5)
    {
        const conditioned = scenario >= 3;
        const method = scenario == 0 || conditioned ? LootMethod.groupLoot : LootMethod.needBeforeGreed;
        const remoteCanUse = scenario != 2;
        const remoteMeetsCondition = scenario != 3;
        const remoteWins = scenario == 0 || scenario == 4;
        auto db = newDatabase();
        GroupRecord party;
        party.id = 1;
        party.leader = 7;
        party.leaderName = "Anduin";
        party.lootMethod = method;
        party.lootThreshold = 2;
        party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina")];
        db.groups[party.id] = party;
        auto corpseNode = newCreationContext(db), otherNode = newCreationContext(db);
        corpseNode.nodeId = 1;
        otherNode.nodeId = 2;
        otherNode.ownsCell = (uint, ulong) => false;
        auto now = MonoTime.currTime;
        corpseNode.clock = otherNode.clock = () => now;
        auto anduin = loggedIn(corpseNode, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f),
            characterLevel: conditioned ? 10 : 1);
        auto jaina = loggedIn(otherNode, db, 8, "Jaina", Position(-8945, -132, 83.5f),
            characterLevel: conditioned && remoteMeetsCondition ? 10 : 1);
        const remote = jaina.session.character;
        const p = remote.position;
        corpseNode.map(0).replicaCreated(2, cellKeyAt(p.x, p.y), remote.guid, encodePlayerState(remote, 0));
        assert(corpseNode.onlinePlayer(remote.guid) is null && otherNode.onlinePlayer(7) is null);

        GroupLootRoll award;
        corpseNode.sendRemoteGroupLoot = (ushort node, const ref GroupLootRoll message) {
            assert(node == 2);
            if (message.action == GroupLootRoll.Action.award)
                award = message;
            otherNode.groupLootRollArrived(1, message);
            return true;
        };
        otherNode.sendRemoteGroupLoot = (ushort node, const ref GroupLootRoll message) {
            assert(node == 1);
            corpseNode.groupLootRollArrived(2, message);
            return true;
        };
        corpseNode.deliverRemote = (ushort node, ulong guid, ushort opcode, const(ubyte)[] body_) {
            assert(node == 2);
            if (auto player = cast(Character) otherNode.onlinePlayer(guid))
                player.deliver(cast(Opcode) opcode, body_);
        };

        corpseNode.data.items.edit(itemJerky).details.quality = 2;
        if (!remoteCanUse)
            otherNode.data.items.edit(itemJerky).requiredLevel = 10;
        auto victim = lootableInnkeeper(corpseNode, conditioned ? 50 : 0); // fixture condition: level 10+
        killIt(anduin, victim, now);
        auto loot = victim.loot;
        assert(loot.remoteMembers[8] == 2 && loot.itemInSlot(0).blocked);
        anduin.write(Opcode.CMSG_LOOT, ClientGuid(victim.guid));
        assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_START_ROLL));
        assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_LOOT_START_ROLL) == (remoteCanUse && remoteMeetsCondition),
            "the remote node checks the loot condition and Need Before Greed usability");

        jaina.write(Opcode.CMSG_LOOT_ROLL, ClientLootRoll(victim.guid, 0, remoteWins ? RollVote.need : RollVote.greed));
        jaina.write(Opcode.CMSG_LOOT_ROLL, ClientLootRoll(victim.guid, 0, RollVote.need));
        assert(loot.rolls.length == 1 && anduin.session.character.inventory.count(itemJerky) == 0
            && jaina.session.character.inventory.count(itemJerky) == 0, "no award before both players vote");

        anduin.write(Opcode.CMSG_LOOT_ROLL, ClientLootRoll(victim.guid, 0, remoteWins ? RollVote.greed : RollVote.need));
        assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_ROLL_WON));
        assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_LOOT_ROLL_WON) == remoteMeetsCondition);
        assert(loot.rolls.length == 0 && loot.itemInSlot(0).allowed.length == 0);
        assert(anduin.session.character.inventory.count(itemJerky) == (remoteWins ? 0 : 1));
        assert(jaina.session.character.inventory.count(itemJerky) == (remoteWins ? 1 : 0));

        if (remoteWins)
        {
            assert(award.player == 8);
            otherNode.groupLootRollArrived(1, award);
            assert(jaina.session.character.inventory.count(itemJerky) == 1, "a repeated award cannot grant a second item");
        }
        else
            assert(!award.roll, "a local win never issues a remote award");
        size_t saved;
        foreach (guid, ref row; db.itemRows)
            if (row.entry == itemJerky)
            {
                ++saved;
                assert(db.itemOwners[guid] == (remoteWins ? 8 : 7));
            }
        assert(saved == 1, "exactly one item is saved, for the winner");
    }
}

// Quest loot survives the player's handoff, with one claim for a shared slot or for each multi-drop recipient.
unittest
{
    import dmangos.cluster.protocol : QuestLootCheck;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : LootMethod;
    import dmangos.world.loot : itemFlagMultiDrop, lootRow, LootStores;
    import dmangos.world.quests : Quest, QuestState, QuestStatus;
    import dmangos.world.replication : encodePlayerState;

    enum Scenario { sharedTurn, sharedFallback, sharedAlreadyTaken, personal, noQuest, abandoned }
    foreach (scenario; [Scenario.sharedTurn, Scenario.sharedFallback, Scenario.sharedAlreadyTaken,
        Scenario.personal, Scenario.noQuest, Scenario.abandoned])
    {
        const localNeeds = scenario != Scenario.sharedFallback && scenario != Scenario.abandoned;
        auto db = newDatabase();
        GroupRecord party;
        party.id = 1;
        party.leader = 7;
        party.leaderName = "Anduin";
        party.lootMethod = LootMethod.roundRobin;
        party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina")];
        db.groups[party.id] = party;
        auto memberNode = newCreationContext(db), corpseNode = newCreationContext(db);
        auto relay = new TestPlayerRelay(memberNode, corpseNode);
        memberNode.ownsCell = (uint, ulong) => false;
        auto now = MonoTime.currTime;
        corpseNode.clock = memberNode.clock = () => now;
        Quest quest;
        quest.id = 9300;
        quest.reqItemId[0] = itemJerky;
        quest.reqItemCount[0] = 3; // taking one still leaves both players eligible for a different drop
        corpseNode.data.quests.quests[quest.id] = memberNode.data.quests.quests[quest.id] = quest;
        const start = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
        auto anduin = loggedIn(corpseNode, db, 7, "Anduin", start, setup: (ref c) {
            if (localNeeds)
                c.quests = [QuestStatus(quest.id, QuestState.incomplete)];
        });
        auto jaina = loggedIn(memberNode, db, 8, "Jaina", start, setup: (ref c) {
            if (scenario != Scenario.noQuest)
                c.quests = [QuestStatus(quest.id, QuestState.incomplete)];
        });
        auto source = corpseNode.map(0);
        source.replicaCreated(1, cellKeyAt(start.x, start.y), 8, encodePlayerState(jaina.session.character, 0));
        auto wire = new LootReplicaLink;
        wire.viewer = memberNode.map(0);
        source.replicator = wire;
        if (scenario == Scenario.sharedTurn)
            corpseNode.groups.of(7).nextLooter = 8;

        QuestLootCheck request, reply;
        corpseNode.sendQuestLootCheck = (ushort peer, const ref QuestLootCheck check) {
            assert(peer == 1 && !check.reply);
            request = QuestLootCheck(check.map, check.loot, check.player, check.sequence, false, 0, check.items.dup);
            return true;
        };
        memberNode.sendQuestLootCheck = (ushort peer, const ref QuestLootCheck check) {
            assert(peer == 2 && check.reply);
            reply = QuestLootCheck(check.map, check.loot, check.player, check.sequence, true, check.eligible);
            return true;
        };
        auto victim = lootableInnkeeper(corpseNode);
        corpseNode.data.loot = LootStores.create();
        corpseNode.data.loot.creature.add(99, lootRow(itemJerky, -100, 0, 1, 1, 0));
        if (scenario == Scenario.personal)
            corpseNode.data.items.edit(itemJerky).flags |= itemFlagMultiDrop;
        if (scenario != Scenario.sharedAlreadyTaken)
            corpseNode.data.creatureTemplates.edit(creatureInnkeeper).minLootGold =
                corpseNode.data.creatureTemplates.edit(creatureInnkeeper).maxLootGold = 0;
        const cell = cellKeyAt(victim.position.x, victim.position.y);
        source.peerInterest(1, [cell], null);
        jaina.read();

        killIt(anduin, victim, now);
        auto loot = victim.loot;
        assert(loot !is null && request.player == 8 && request.items[0] == itemJerky);
        assert(!loot.canLoot(8), "a pending quest check cannot expose a loot slot");
        if (scenario == Scenario.sharedTurn)
            assert(loot.currentLooter == 8 && !loot.canLoot(7), "the remote player's turn is reserved");

        const corpse = ClientGuid(victim.guid);
        if (scenario == Scenario.personal || scenario == Scenario.sharedAlreadyTaken)
        {
            anduin.write(Opcode.CMSG_LOOT, corpse);
            anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
            assert(anduin.session.character.inventory.count(itemJerky) == 1);
        }
        memberNode.questLootCheckArrived(2, request);
        assert(reply.eligible == (scenario == Scenario.noQuest ? 0 : 1));
        corpseNode.questLootCheckArrived(3, reply);
        assert(!loot.canLoot(8), "only the checked player's node can confirm eligibility");
        corpseNode.questLootCheckArrived(1, reply);
        const remoteCanOpen = scenario != Scenario.noQuest && scenario != Scenario.sharedAlreadyTaken;
        assert(loot.canLoot(8) == remoteCanOpen);
        jaina.read();
        assert(((jaina.view.fields[victim.guid].get(UNIT_DYNAMIC_FLAGS, 0) & Creature.dynLootable) != 0)
            == remoteCanOpen, "the replica shows the quest loot cursor to eligible players");

        jaina.write(Opcode.CMSG_LOOT, corpse);
        assert(relay.remote !is null && jaina.session.inWorld is null);
        relay.remote.update(50.msecs);
        assert((bodyOf(jaina.read(), Opcode.SMSG_LOOT_RESPONSE).length != 0) == remoteCanOpen);
        if (scenario == Scenario.abandoned)
            jaina.write(Opcode.CMSG_QUESTLOG_REMOVE_QUEST, [ubyte(0)]);
        jaina.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
        const expectedRemote = remoteCanOpen && scenario != Scenario.abandoned ? 1 : 0;
        assert(relay.remote.character.inventory.count(itemJerky) == expectedRemote);
        corpseNode.questLootCheckArrived(1, reply);
        jaina.write(Opcode.CMSG_LOOT, corpse);
        jaina.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
        assert(relay.remote.character.inventory.count(itemJerky) == expectedRemote);

        size_t[uint] saved;
        foreach (guid, ref row; db.itemRows)
            if (row.entry == itemJerky)
                saved[db.itemOwners[guid]] += row.count;
        assert(saved.get(7, 0) == ((scenario == Scenario.personal || scenario == Scenario.sharedAlreadyTaken) ? 1 : 0));
        assert(saved.get(8, 0) == expectedRemote);
    }
}

// The master sees the remote recipient and can assign a shared slot exactly once.
unittest
{
    import dmangos.bytes : ByteReader;
    import dmangos.cluster.protocol : GroupLootRoll;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.defines : inventorySlotBag0, inventorySlotItemStart, inventorySlotItemEnd;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : LootMethod;
    import dmangos.world.inventory : ItemRecord;
    import dmangos.world.loot : LootError, LootSlotType, lootErrorPacket;
    import dmangos.world.packets : ClientDestroyItem;
    import dmangos.world.replication : encodePlayerState;

    enum Case { success, full, conditioned, belowThreshold }
    foreach (scenario; [Case.success, Case.full, Case.conditioned, Case.belowThreshold])
    {
        auto db = newDatabase();
        GroupRecord party;
        party.id = 1;
        party.leader = party.looter = 7;
        party.leaderName = "Anduin";
        party.lootMethod = LootMethod.masterLoot;
        party.lootThreshold = 2;
        party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina")];
        db.groups[party.id] = party;
        auto corpseNode = newCreationContext(db), otherNode = newCreationContext(db);
        corpseNode.nodeId = 1;
        otherNode.nodeId = 2;
        otherNode.ownsCell = (uint, ulong) => false;
        auto now = MonoTime.currTime;
        corpseNode.clock = otherNode.clock = () => now;
        auto anduin = loggedIn(corpseNode, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f),
            characterLevel: scenario == Case.conditioned ? 10 : 1);
        const nearCorpse = Position(-8945, -132, 83.5f);
        auto jaina = loggedIn(otherNode, db, 8, "Jaina", nearCorpse, setup: (ref character) {
            if (scenario == Case.full)
                foreach (ubyte slot; inventorySlotItemStart .. inventorySlotItemEnd)
                    character.items ~= ItemRecord(0, slot, 100u + slot, itemShirt, 0, 0, 1);
        });
        corpseNode.map(0).replicaCreated(2, cellKeyAt(nearCorpse.x, nearCorpse.y), 8,
            encodePlayerState(jaina.session.character, 0));

        GroupLootRoll[] awards, results;
        corpseNode.sendRemoteGroupLoot = (ushort node, const ref GroupLootRoll message) {
            assert(node == 2 && message.action == GroupLootRoll.Action.masterAward);
            awards ~= message;
            return true;
        };
        otherNode.sendRemoteGroupLoot = (ushort node, const ref GroupLootRoll message) {
            assert(node == 1 && message.action == GroupLootRoll.Action.result);
            results ~= message;
            return true;
        };

        if (scenario != Case.belowThreshold)
            corpseNode.data.items.edit(itemJerky).details.quality = 2;
        auto victim = lootableInnkeeper(corpseNode, scenario == Case.conditioned ? 50 : 0);
        killIt(anduin, victim, now);
        auto loot = victim.loot;
        auto item = loot.itemInSlot(0);
        anduin.write(Opcode.CMSG_LOOT, ClientGuid(victim.guid));
        auto roster = ByteReader(bodyOf(anduin.read(), Opcode.SMSG_LOOT_MASTER_LIST));
        assert(roster.read!ubyte == 2 && roster.read!ulong == 7 && roster.read!ulong == 8);
        anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, ClientLootMasterGive(victim.guid, 0, 9));
        assert(awards.length == 0, "a non-member cannot receive the item");

        const assignment = ClientLootMasterGive(victim.guid, 0, 8);
        anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, assignment);
        if (scenario == Case.belowThreshold)
        {
            assert(awards.length == 0 && item.slotTypeFor(7, loot) == LootSlotType.normal);
            continue;
        }
        assert(awards.length == 1 && item.blocked && item.remoteMasterTarget == 8);
        anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, ClientLootMasterGive(victim.guid, 0, 7));
        anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, assignment);
        assert(awards.length == 1 && anduin.session.character.inventory.count(itemJerky) == 0,
            "the pending slot cannot be assigned again");
        anduin.read();

        otherNode.groupLootRollArrived(1, awards[0]);
        otherNode.groupLootRollArrived(1, awards[0]);
        assert(results.length == 1);
        corpseNode.groupLootRollArrived(3, results[0]);
        assert(item.blocked, "only the recipient's node can confirm the award");
        corpseNode.groupLootRollArrived(2, results[0]);
        assert(!item.remoteAward && !item.blocked);

        if (scenario == Case.full || scenario == Case.conditioned)
        {
            assert(!results[0].stored && jaina.session.character.inventory.count(itemJerky) == 0);
            assert(item.slotTypeFor(7, loot) == LootSlotType.master, "a failed award leaves the item assignable");
            const error = scenario == Case.full ? LootError.masterInvFull : LootError.masterOther;
            assert(bodyOf(anduin.read(), Opcode.SMSG_LOOT_RESPONSE) == lootErrorPacket(victim.guid, error));
            if (scenario == Case.full)
            {
                jaina.write(Opcode.CMSG_DESTROYITEM, ClientDestroyItem(inventorySlotBag0, inventorySlotItemStart,
                    0, [0, 0, 0]));
                otherNode.groupLootRollArrived(1, awards[0]);
                assert(results.length == 1 && jaina.session.character.inventory.count(itemJerky) == 0,
                    "replaying a rejected award after freeing a slot cannot grant an item");
                anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, assignment);
                assert(awards.length == 2 && awards[1].roll > awards[0].roll);
                corpseNode.groupLootRollArrived(2, results[0]);
                assert(item.blocked, "a previous rejection cannot unlock a new award");
                otherNode.groupLootRollArrived(1, awards[1]);
                assert(results.length == 2 && results[1].stored);
                corpseNode.groupLootRollArrived(2, results[1]);
            }
            else
                anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, ClientLootMasterGive(victim.guid, 0, 7));
        }

        anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, assignment);
        corpseNode.groupLootRollArrived(2, results[$ - 1]);
        assert(awards.length == (scenario == Case.full ? 2 : 1) && item.allowed.length == 0);
        const recipient = scenario == Case.conditioned ? 7 : 8;
        assert(anduin.session.character.inventory.count(itemJerky) == (recipient == 7 ? 1 : 0));
        assert(jaina.session.character.inventory.count(itemJerky) == (recipient == 8 ? 1 : 0));
        assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_REMOVED));
        size_t saved;
        foreach (guid, ref row; db.itemRows)
            if (row.entry == itemJerky)
            {
                ++saved;
                assert(db.itemOwners[guid] == recipient);
            }
        assert(saved == 1, "exactly one item is saved, for the chosen eligible recipient");
    }
}

// Master Loot survives the designated master's handoff, even if another member opened the loot first.
unittest
{
    import std.algorithm.sorting : sort;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.cluster.protocol : GroupLootRoll;
    import dmangos.dbc : buildDbc;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.clientdata : lockFormat;
    import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate, GameObjectType;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : LootMethod;
    import dmangos.world.loot : Loot, LootRule, LootSlotType, RollVote, lootRow;
    import dmangos.world.player : CharacterData;
    import dmangos.world.playercreate : NewSkill, NewSpell;
    import dmangos.world.replication : encodePlayerState, encodeState;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;

    enum Scenario { localRecipient, remoteRecipient, outOfRange, chest, masterFailsCondition }
    foreach (scenario; [Scenario.localRecipient, Scenario.remoteRecipient, Scenario.outOfRange,
        Scenario.chest, Scenario.masterFailsCondition])
    {
        auto db = newDatabase();
        GroupRecord party;
        party.id = 1;
        party.leader = 7;
        party.leaderName = "Anduin";
        party.looter = 8;
        party.lootMethod = LootMethod.masterLoot;
        party.lootThreshold = 2;
        party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina"),
            GroupMemberRecord(9, "Khadgar")];
        db.groups[party.id] = party;
        auto masterNode = newCreationContext(db), lootNode = newCreationContext(db);
        auto relay = new TestPlayerRelay(masterNode, lootNode);
        masterNode.ownsCell = (uint, ulong) => false;
        auto now = MonoTime.currTime;
        masterNode.clock = lootNode.clock = () => now;
        const start = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
        Position masterAt = start;
        if (scenario == Scenario.outOfRange)
            masterAt.x += 80;

        enum uint gather = 2366, herbalism = 182, lock = 99;
        if (scenario == Scenario.chest)
        {
            auto lockRow = new uint[lockFormat.length];
            lockRow[0] = lock;
            lockRow[1] = 2; // skill key
            lockRow[9] = 2; // herbalism
            lootNode.client.locks = typeof(lootNode.client.locks).parse(buildDbc(lockFormat, [lockRow]), "Lock.dbc");
            auto spell = testSpell(gather, 33, 26, 0);
            spell.miscValue[0] = 2;
            spell.casting.realPointsPerLevel[0] = 5;
            lootNode.data.spells.spells[gather] = spell;
            masterNode.data.spells.spells[gather] = spell;
        }
        void teachGathering(ref CharacterData c)
        {
            if (scenario == Scenario.chest)
            {
                c.skills = [NewSkill(herbalism, 1, 75)];
                c.spells = [NewSpell(gather, true)];
            }
        }
        auto anduin = loggedIn(lootNode, db, 7, "Anduin", start,
            characterLevel: scenario == Scenario.masterFailsCondition ? 10 : 1, setup: &teachGathering);
        auto jaina = loggedIn(masterNode, db, 8, "Jaina", masterAt, setup: &teachGathering);
        const recipientIsRemote = scenario == Scenario.remoteRecipient;
        auto khadgar = loggedIn(recipientIsRemote ? masterNode : lootNode, db, 9, "Khadgar", start);
        auto source = lootNode.map(0);
        source.replicaCreated(1, cellKeyAt(masterAt.x, masterAt.y), 8, encodePlayerState(jaina.session.character, 0));
        if (recipientIsRemote)
            source.replicaCreated(1, cellKeyAt(start.x, start.y), 9, encodePlayerState(khadgar.session.character, 0));
        auto wire = new LootReplicaLink;
        wire.viewer = masterNode.map(0);
        source.replicator = wire;

        GroupLootRoll award;
        lootNode.sendRemoteGroupLoot = (ushort peer, const ref GroupLootRoll message) {
            assert(peer == 1 && message.action == GroupLootRoll.Action.masterAward);
            award = message;
            masterNode.groupLootRollArrived(2, message);
            return true;
        };
        masterNode.sendRemoteGroupLoot = (ushort peer, const ref GroupLootRoll message) {
            assert(peer == 2 && message.action == GroupLootRoll.Action.result);
            lootNode.groupLootRollArrived(1, message);
            return true;
        };
        lootNode.data.items.edit(itemJerky).details.quality = 2;

        Loot loot;
        ulong target;
        ubyte[] openChest;
        if (scenario == Scenario.chest)
        {
            enum uint chestEntry = 9002, spawnId = 90002, lootId = 500;
            GameObjectTemplate template_ = {entry: chestEntry, type: GameObjectType.chest, displayId: 2, name: "Chest"};
            template_.data[0] = lock;
            template_.data[1] = lootId;
            lootNode.data.gameObjectTemplates[chestEntry] = template_;
            lootNode.data.gameObjectSpawns ~= GameObjectSpawn(spawnId, chestEntry, 0, start.x, start.y, start.z);
            lootNode.data.loot.gameObject.add(lootId, lootRow(itemJerky, 100, 0, 1, 1, 0));
            auto chest = lootNode.makeGameObject(&lootNode.data.gameObjectSpawns[$ - 1]);
            source.addObject(chest);
            target = chest.guid;
            wire.viewer.replicaCreated(2, cellKeyAt(start.x, start.y), target, encodeState(chest, 0));
            ByteWriter packet;
            packet.put(gather);
            auto targets = SpellTargets(TargetFlags.gameObject);
            targets.gameObject = target;
            targets.write(packet);
            openChest = packet.data.dup;
            anduin.write(Opcode.CMSG_CAST_SPELL, openChest);
            loot = chest.loot;
        }
        else
        {
            auto victim = lootableInnkeeper(lootNode, scenario == Scenario.masterFailsCondition ? 50 : 0);
            source.peerInterest(1, [cellKeyAt(victim.position.x, victim.position.y)], null);
            killIt(anduin, victim, now);
            target = victim.guid;
            loot = victim.loot;
            jaina.read();
            if (scenario != Scenario.outOfRange)
                assert(jaina.view.fields[target].get(UNIT_DYNAMIC_FLAGS, 0) & Creature.dynLootable,
                    "the master sees the cursor on the corpse replica");
            anduin.write(Opcode.CMSG_LOOT, ClientGuid(target));
        }
        assert(loot !is null);
        auto item = loot.itemInSlot(0);
        const localOpen = anduin.read();
        if (scenario == Scenario.outOfRange)
        {
            assert(loot.rule == LootRule.groupLoot && !loot.canLoot(8));
            assert(bodyOf(localOpen, Opcode.SMSG_LOOT_START_ROLL).length != 0);
            anduin.write(Opcode.CMSG_LOOT_ROLL, ClientLootRoll(target, 0, RollVote.greed));
            khadgar.write(Opcode.CMSG_LOOT_ROLL, ClientLootRoll(target, 0, RollVote.need));
            assert(khadgar.session.character.inventory.count(itemJerky) == 1 && award.roll == 0);
            continue;
        }
        assert(loot.rule == LootRule.masterLoot && loot.masterStartsRemote && loot.canLoot(8));
        assert(item.slotTypeFor(8, loot) == LootSlotType.master && loot.rolls.length == 0);
        assert(bodyOf(localOpen, Opcode.SMSG_LOOT_MASTER_LIST).length == 0);
        anduin.write(Opcode.CMSG_LOOT_MASTER_GIVE, ClientLootMasterGive(target, 0, 7));
        assert(anduin.session.character.inventory.count(itemJerky) == 0);
        if (scenario == Scenario.localRecipient || scenario == Scenario.remoteRecipient)
        {
            anduin.write(Opcode.CMSG_LOOT_MONEY, null);
            assert(!loot.gold && !loot.lootedForEveryone(), "the item waits for the master after the coins are taken");
        }

        if (scenario == Scenario.chest)
            jaina.write(Opcode.CMSG_CAST_SPELL, openChest);
        else
            jaina.write(Opcode.CMSG_LOOT, ClientGuid(target));
        assert(jaina.session.inWorld is null && relay.remote !is null);
        relay.remote.update(50.msecs);
        const packets = jaina.read();
        auto roster = ByteReader(bodyOf(packets, Opcode.SMSG_LOOT_MASTER_LIST));
        ulong[] recipients;
        foreach (_; 0 .. roster.read!ubyte)
            recipients ~= roster.read!ulong;
        recipients.sort();
        assert(recipients == [7UL, 8UL, 9UL], "the recipient list arrives on opening, with no duplicate master");
        const assignment = ClientLootMasterGive(target, 0, 9);
        jaina.write(Opcode.CMSG_LOOT_MASTER_GIVE, assignment);
        if (scenario == Scenario.masterFailsCondition)
        {
            assert(item.slotTypeFor(8, loot) == LootSlotType.none && item.blocked);
            assert(khadgar.session.character.inventory.count(itemJerky) == 0);
            continue;
        }
        jaina.write(Opcode.CMSG_LOOT_MASTER_GIVE, assignment);
        if (recipientIsRemote)
        {
            assert(award.player == 9);
            masterNode.groupLootRollArrived(2, award);
        }
        assert(item.allowed.length == 0);
        assert(anduin.session.character.inventory.count(itemJerky) == 0);
        assert(relay.remote.character.inventory.count(itemJerky) == 0);
        assert(khadgar.session.character.inventory.count(itemJerky) == 1);
        size_t saved;
        foreach (guid, ref row; db.itemRows)
            if (row.entry == itemJerky)
            {
                assert(db.itemOwners[guid] == 9);
                saved += row.count;
            }
        assert(saved == 1);
    }
}

// All the copper is allocated once, including an odd copper and a repeated remote credit.
unittest
{
    import dmangos.cluster.protocol : LootCoinShare;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : LootMethod;
    import dmangos.world.replication : encodePlayerState;

    enum Delivery { accepted, offline, refused }
    foreach (delivery; [Delivery.accepted, Delivery.offline, Delivery.refused])
    {
        auto db = newDatabase();
        GroupRecord party;
        party.id = 1;
        party.leader = 7;
        party.leaderName = "Anduin";
        party.lootMethod = LootMethod.roundRobin;
        party.lootThreshold = 2;
        party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina"),
            GroupMemberRecord(9, "Varian")];
        db.groups[party.id] = party;
        auto corpseNode = newCreationContext(db), memberNode = newCreationContext(db);
        corpseNode.nodeId = 1;
        memberNode.nodeId = 2;
        memberNode.ownsCell = (uint, ulong) => false;
        auto now = MonoTime.currTime;
        corpseNode.clock = memberNode.clock = () => now;
        auto anduin = loggedIn(corpseNode, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
        auto jaina = loggedIn(memberNode, db, 8, "Jaina", Position(-8945, -132, 83.5f));
        auto varian = loggedIn(memberNode, db, 9, "Varian", Position(-8868, -132, 83.5f));
        foreach (remote; [jaina.session.character, varian.session.character])
        {
            const p = remote.position;
            corpseNode.map(0).replicaCreated(2, cellKeyAt(p.x, p.y), remote.guid, encodePlayerState(remote, 0));
        }

        size_t sent;
        LootCoinShare paid;
        corpseNode.canSendLootCoins = (ushort node) => node == 2 && delivery != Delivery.offline;
        corpseNode.sendRemoteLootCoins = (ushort node, const ref LootCoinShare message) {
            assert(node == 2 && message.player == 8 && message.copper == 5);
            ++sent;
            if (delivery == Delivery.refused)
                return false;
            paid = message;
            memberNode.lootCoinShareArrived(1, message);
            memberNode.lootCoinShareArrived(1, message);
            return true;
        };
        auto victim = lootableInnkeeper(corpseNode);
        with (*corpseNode.data.creatureTemplates.edit(creatureInnkeeper))
            minLootGold = maxLootGold = 11;
        const before = anduin.session.character.money, otherBefore = jaina.session.character.money;
        const farBefore = varian.session.character.money;
        killIt(anduin, victim, now);
        assert(victim.loot.remoteMembers.keys == [8UL], "the distant member is outside the loot radius");
        anduin.write(Opcode.CMSG_LOOT, ClientGuid(victim.guid));
        anduin.read();
        jaina.read();
        anduin.write(Opcode.CMSG_LOOT_MONEY, null);
        anduin.write(Opcode.CMSG_LOOT_MONEY, null); // retrying the client request changes nothing
        assert(sent == (delivery == Delivery.offline ? 0 : 1));
        assert(anduin.session.character.money == before + Copper(delivery == Delivery.accepted ? 6 : 11));
        assert(jaina.session.character.money == otherBefore + Copper(delivery == Delivery.accepted ? 5 : 0));
        assert(varian.session.character.money == farBefore);
        assert(db.moneySaves[7][0] == anduin.session.character.money.amount);
        if (delivery == Delivery.accepted)
        {
            assert(db.moneySaves[8][0] == jaina.session.character.money.amount);
            auto packets = jaina.read();
            size_t notifications;
            foreach (packet; packets)
                if (packet.opcode == Opcode.SMSG_LOOT_MONEY_NOTIFY)
                {
                    ++notifications;
                    assert(ByteReader(packet.body_).read!uint == 5);
                }
            assert(notifications == 1, "a replay neither credits coins nor repeats the notification");
            memberNode.lootCoinShareArrived(1, paid);
            assert(jaina.session.character.money == otherBefore + Copper(5));
        }
    }
}

// Two corpses made on different nodes share the coordinator's rotation.
unittest
{
    import dmangos.cluster.protocol : ServiceCall, ServiceReply;
    import dmangos.cluster.services : ServiceKind;
    import dmangos.world.characterdb : GroupRecord, GroupMemberRecord;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.group : LootMethod;
    import dmangos.world.loot : LootSlotType;
    import dmangos.world.replication : encodePlayerState, encodeState;

    foreach (method; [LootMethod.roundRobin, LootMethod.groupLoot])
    {
        auto db = newDatabase();
        GroupRecord party;
        party.id = 1;
        party.leader = 7;
        party.leaderName = "Anduin";
        party.lootMethod = method;
        party.lootThreshold = 2;
        party.members = [GroupMemberRecord(7, "Anduin"), GroupMemberRecord(8, "Jaina")];
        db.groups[party.id] = party;
        auto coordinator = newCreationContext(db), member = newCreationContext(db);
        auto now = MonoTime.currTime;
        coordinator.clock = member.clock = () => now;
        auto relay = new TestPlayerRelay(coordinator, member);
        coordinator.services.self = 1;
        member.services.self = 2;
        ulong callerIncarnation = 1;
        coordinator.services.peerIncarnation = (ushort) => callerIncarnation;
        member.services.release(ServiceKind.lootTurns);
        member.services.placement = (ServiceKind kind) => kind == ServiceKind.lootTurns ? ushort(1) : ushort(0);
        ServiceCall[] pending;
        member.services.sendCall = (ushort node, const ref ServiceCall call) {
            assert(node == 1);
            pending ~= ServiceCall(call.kind, call.call, call.origin, call.sequence, call.request.dup);
            return true;
        };
        coordinator.services.sendReply = (ushort node, const ref ServiceReply reply) {
            assert(node == 2);
            member.services.receiveReply(1, reply);
            return true;
        };

        const start = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
        auto anduin = loggedIn(coordinator, db, 7, "Anduin", start);
        auto jaina = loggedIn(member, db, 8, "Jaina", start);
        const cell = cellKeyAt(start.x, start.y);
        coordinator.map(0).replicaCreated(2, cell, 8, encodePlayerState(jaina.session.character, 0));
        member.map(0).replicaCreated(1, cell, 7, encodePlayerState(anduin.session.character, 0));

        auto first = lootableInnkeeper(member);
        killIt(jaina, first, now);
        auto loot = first.loot;
        assert(pending.length == 1 && loot !is null);
        assert(loot.itemInSlot(0).slotTypeFor(7, loot) == LootSlotType.none
            && loot.itemInSlot(0).slotTypeFor(8, loot) == LootSlotType.none, "the item waits for the coordinator");
        // The local player can open for copper, but closing that window must not release the pending item.
        jaina.write(Opcode.CMSG_LOOT, ClientGuid(first.guid));
        jaina.write(Opcode.CMSG_LOOT_RELEASE, ClientGuid(first.guid));
        coordinator.services.receiveCall(2, pending[0]);
        coordinator.services.receiveCall(2, pending[0]); // a retry must not advance the cursor twice
        assert(loot.currentLooter == 7 && coordinator.groups.of(7).nextLooter == 8);
        assert(loot.itemInSlot(0).slotTypeFor(8, loot) == LootSlotType.none);

        // The next drop is made on the coordinator itself, with Jaina still simulated by node 2.
        lootableInnkeeper(coordinator); // gives the coordinator a loot template for the trainer too
        auto trainer = cast(Creature) coordinator.map(0).findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
        coordinator.data.creatureTemplates.edit(creatureTrainer).lootId = 99;
        trainer.values.set!UNIT_FIELD_HEALTH(0u);
        anduin.session.inWorld.prepareBodyLoot(trainer);
        assert(trainer.loot.currentLooter == 8 && coordinator.groups.of(7).nextLooter == 7);
        assert(trainer.loot.itemInSlot(0).slotTypeFor(7, trainer.loot) == LootSlotType.none);
        assert(trainer.loot.itemInSlot(0).slotTypeFor(8, trainer.loot) == LootSlotType.normal);

        // Jaina cannot put Anduin's first drop in her bag, even by sending its slot directly.
        jaina.write(Opcode.CMSG_LOOT, ClientGuid(first.guid));
        import dmangos.world.loothandlers : ClientLootSlot;
        jaina.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
        assert(jaina.session.character.inventory.count(itemJerky) == 0 && 7UL in loot.itemInSlot(0).allowed);

        // Anduin clicks the corpse replica and loots on its owner, via the normal migration path.
        auto homeMap = coordinator.map(0);
        homeMap.removeObject(first.guid);
        homeMap.replicaCreated(2, cell, first.guid, encodeState(first, 0));
        anduin.write(Opcode.CMSG_LOOT, ClientGuid(first.guid));
        assert(relay.remote !is null && anduin.session.inWorld is null);
        relay.remote.update(50.msecs);
        assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
        anduin.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
        assert(relay.remote.character.inventory.count(itemJerky) == 1);
        assert(jaina.session.character.inventory.count(itemJerky) == 0 && loot.itemInSlot(0).allowed.length == 0);
        size_t saved;
        foreach (guid, ref row; db.itemRows)
            if (row.entry == itemJerky)
            {
                ++saved;
                assert(db.itemOwners[guid] == 7);
            }
        assert(saved == 1);
        ++callerIncarnation;
        coordinator.services.receiveCall(2, pending[0]); // a restarted node can reuse a call number
        assert(coordinator.groups.of(7).nextLooter == 8);
    }
}
