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
    import dmangos.world.creature : Creature;
    import dmangos.world.defines : nullBag, nullSlot, UnitFlags;
    import dmangos.world.experience;
    import dmangos.world.inventory : EquipError, InventoryResult, ItemPosCount;
    import dmangos.world.loot;
    import dmangos.world.inworld : ArrivalAction;
    import dmangos.world.loothandlers : ClientLootMasterGive, ClientLootRoll, ClientLootSlot;
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
        const guid = item.fullGuid;
        auto loot = itemLoots.get(guid, null);
        if (loot is null)
        {
            auto self = this;
            loot = new Loot(guid, (ulong who) => who == self.player.guid ? cast(Looter) self : null);
            loot.clock = () => context.unixTime;
            loot.clientType = ClientLootType.pickpocketing;
            loot.owners[player.guid] = true;
            loot.currentLooter = player.guid;
            loot.rule = LootRule.notGroup;
            if (const template_ = context.data.loot.item[item.entry])
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
        ByteWriter w;
        w.put(guid);
        w.put(ubyte(0));
        w.put(cast(ubyte) error);
        deliver(Opcode.SMSG_LOOT_RESPONSE, w.data);
    }

    /// The client loots: the window opens on a corpse in reach, if there is something for this player.
    @Handles(Opcode.CMSG_LOOT, WorldState.inWorld)
    void handleLoot(const ClientGuid request)
    {
        if (player.deathState != DeathState.alive || transferring)
            return;
        if (player.values.getByte!UNIT_FIELD_BYTES_1(0) != 0)
            return sendLootError(request.guid, LootError.notStanding);
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
        if (item.blocked || item.slotTypeFor(player.guid, loot) == LootSlotType.none)
            return loot.release(this);
        loot.sendItem(this, item);
    }

    /// The client closes the loot window.
    @Handles(Opcode.CMSG_LOOT_RELEASE, WorldState.inWorld)
    void handleLootRelease(const ClientGuid request)
    {
        if (auto loot = lootOf(request.guid))
            return loot.release(this);
        if (lootTarget == request.guid)
            setLootWindow(request.guid, false);
    }

    /// The master looter hands an item to a member who may have it.
    @Handles(Opcode.CMSG_LOOT_MASTER_GIVE, WorldState.inWorld)
    void handleLootMasterGive(const ClientLootMasterGive request)
    {
        auto loot = lootOf(request.loot);
        if (loot is null)
            return;
        if (player.guid != loot.masterLooter)
            return sendLootError(request.loot, LootError.didntKill);
        auto target = loot.find(request.target);
        if (target is null || request.target !in loot.owners)
            return sendLootError(request.loot, LootError.masterOther);
        auto item = loot.itemInSlot(request.slot);
        if (item is null)
            return sendEquipError(InventoryResult.itemNotFound);
        if (item.slotTypeFor(player.guid, loot) == LootSlotType.none || request.target !in item.allowed)
            return sendLootError(request.loot, LootError.masterOther);
        item.blocked = false; // the master's to give
        const result = loot.sendItem(target, item, false);
        if (result == InventoryResult.cantCarryMoreOfThis)
            sendLootError(request.loot, LootError.masterUniqueItem);
        else if (result == InventoryResult.inventoryFull)
            sendLootError(request.loot, LootError.masterInvFull);
        else if (result != 0)
            sendLootError(request.loot, LootError.masterOther);
    }

    /// The client rolls on an item: need, greed or pass.
    @Handles(Opcode.CMSG_LOOT_ROLL, WorldState.inWorld)
    void handleLootRoll(const ClientLootRoll request)
    {
        if (request.vote > RollVote.greed)
            return;
        if (auto loot = lootOf(request.loot))
            loot.vote(this, request.slot, cast(RollVote) request.vote);
    }

    // -----------------------------------------------------------------------
    // The kill
    // -----------------------------------------------------------------------

    /// The first player to hurt a creature taps it, for itself and its group.
    void tap(Creature victim)
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

        auto tapper = cast(Character) context.onlinePlayer(victim.lootRecipient);
        if (tapper is null || tapper.map !is map)
            tapper = this;
        if (victim.lootRecipient == 0)
            tap(victim);
        tapper.rewardAtKill(victim);
        tapper.prepareBodyLoot(victim);
        map.flushObjectChanges(victim);
        map.refreshViewers(victim);
    }

    /// The experience of a kill, for the player alone or shared by its group.
    package void rewardAtKill(Creature victim)
    {
        import dmangos.cluster.protocol : KillShare;
        import dmangos.world.replication : Replica;
        import dmangos.world.character : Character;

        // `SMSG_PARTYKILLLOG` is for the killing blow of another; the tapper's own is not shown.
        const value = killValue(victim);
        auto group = context.groups.of(player.guid);
        if (group is null)
        {
            rewardKillReputation(victim, 1);
            rewardHonorForCreature(victim);
            killedMonster(victim.template_.entry, victim.guid);
            const xp = killGain(player.data.level, value);
            petGainsXp(xp); // the pet's share, before its owner perhaps passes its level
            return giveXP(xp, victim.guid, 1.0f);
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
            if (!isTrivialLevelDifference(m.level, victim.values.get!UNIT_FIELD_LEVEL)
                && (highestNotGray is null || highestNotGray.level < m.level))
                highestNotGray = &m;
        }
        // The reputation: a share each (all of it in a dungeon).
        const dungeon = context.client.maps.lookup(map.id) !is null && context.client.maps.lookup(map.id).isDungeon;
        foreach (ref m; members)
            if (m.alive)
                m.reputationRate = dungeon ? 1.0f : 1.0f / nearCount;
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
        enum uint critter = 8, noXp = 0x2; // the critter creature type; the static flag for no experience
        enum uint rankNormal = 0, rankRare = 4;
        const t = victim.template_;
        KillValue value;
        value.level = victim.values.get!UNIT_FIELD_LEVEL;
        value.elite = t.rank != rankNormal && t.rank != rankRare;
        const entry = context.client.maps.lookup(map.id);
        value.raidMap = entry !is null && entry.isRaid;
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
        import dmangos.world.character : Character;

        enum uint noLoot = 0x4; // the static flag for no loot
        const t = victim.template_;
        if (t.staticFlags1 & noLoot)
            return lootedOutNow(victim);
        auto theMap = map;
        auto loot = new Loot(victim.guid, (ulong guid) {
            auto session = cast(Character) context.onlinePlayer(guid);
            return session is null || session.map !is theMap ? null : cast(Looter) session;
        });
        loot.clock = () => context.unixTime;
        setLootRights(loot, victim.position, (ulong guid) => victim.ai.threatOf(guid) > 0);

        const(LootTemplate) template_ = t.lootId ? context.data.loot.creature[t.lootId] : null;
        if (template_ is null && t.maxLootGold == 0)
            return lootedOutNow(victim);
        if (template_ !is null)
        {
            bool meets(uint condition)
            {
                return conditionMet(condition);
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
        if (loot.lootedForEveryone())
            return lootedOutNow(victim);
        victim.loot = loot;
        loot.changed = () => map.refreshViewers(victim);
        loot.lootedForAll = () {
            victim.lootedOut();
            map.flushObjectChanges(victim);
            map.refreshViewers(victim);
        };
    }

    /// Nothing (more) to loot from `victim`: skinnable if it has a skin, its viewers told.
    void lootedOutNow(Creature victim)
    {
        victim.lootedOut();
        map.flushObjectChanges(victim);
    }

    /// Who may loot: for loot at `at`; `fought` says who fought for it (a creature's threat list).
    package void setLootRights(Loot loot, Position at, scope bool delegate(ulong guid) fought)
    {
        import dmangos.world.character : Character;

        auto group = context.groups.of(player.guid);
        if (group is null)
        {
            loot.owners[player.guid] = true;
            loot.currentLooter = player.guid;
            loot.rule = LootRule.notGroup;
            return;
        }
        loot.rule = cast(LootRule) group.lootMethod;
        loot.threshold = group.lootThreshold;
        const members = group.members;
        // From the member after the current looter around: the next looter is the first eligible.
        size_t current = members.length;
        foreach (i, ref slot; members)
            if (slot.guid == group.nextLooter)
                current = i;
        if (current == members.length)
        {
            current = 0;
            group.nextLooter = members[0].guid;
        }
        const currentGuid = group.nextLooter;
        ulong[] ordered;
        foreach (step; 1 .. members.length + 1)
        {
            const guid = members[(current + step) % members.length].guid;
            auto looter = cast(Character) context.onlinePlayer(guid);
            if (looter is null)
                continue;
            if (looter.atGroupRewardDistance(map, at) || fought(guid))
            {
                loot.owners[guid] = true;
                ordered ~= guid;
            }
        }
        if (loot.rule == LootRule.masterLoot)
        {
            loot.masterLooter = group.looter;
            if (group.looter !in loot.owners)
                loot.rule = LootRule.groupLoot;
        }
        if (ordered.length > 1 && loot.rule != LootRule.freeForAll)
        {
            if (currentGuid !in loot.owners)
            {
                loot.currentLooter = ordered[0];
                group.nextLooter = ordered[1];
            }
            else
            {
                loot.currentLooter = currentGuid;
                group.nextLooter = ordered[0];
            }
            return;
        }
        loot.currentLooter = player.guid;
        loot.owners[player.guid] = true;
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
    package uint lootStore(uint entry, uint count, int randomPropertyId, bool sendError)
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
    package void lootMoney(uint copper)
    {
        player.receive(Copper(copper));
        flushPlayerChanges();
    }

    /// See `Looter.canUseItem`.
    package bool lootCanUse(uint entry)
    {
        const proto = entry in context.data.items;
        return proto !is null && player.inventory.canUse(proto) == InventoryResult.ok;
    }

    /// See `Looter.lootWindow`: the player starts looting (`UNIT_FLAG_LOOTING`), or stops.
    package void setLootWindow(ulong target, bool open)
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
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.teleport : moveTo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    /// The innkeeper made a level 1 creature of 30 health that drops 10 copper and jerky.
    Creature lootableInnkeeper(WorldContext context)
    {
        import dmangos.world.loot : lootRow, LootStore, LootStores;

        context.data.loot = LootStores.create();
        context.data.loot.creature.add(99, lootRow(itemJerky, 100, 0, 1, 1, 0));
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
    anduin.session.inWorld.lootStore(itemJerky, 1, 0, false);
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
    assert(share.reputationRate == 0.5f);
}
