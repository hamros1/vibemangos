/**
 * What a group does across the cluster's nodes (`WorldContext.groupRelay`): a group loot roll and its award, coins
 * shared from a kill, a quest shared or completed by a member, a summons to a member, a quest item's check, each sent
 * to the node that simulates the member; and the coins and battleground rewards owed to players, paid as they are
 * online. The links (`sendPartyQuest` and the like) stay on the context, set by the cluster bridge.
 */
module dmangos.world.grouprelay;

import dmangos.cluster.protocol : PartyQuest;
import core.time : Duration, minutes, MonoTime, msecs, seconds;
import dmangos.world.creature : Creature, CreatureParts, CreatureSpawn, CreatureTemplate, Npc, NpcStandIn, TempSpawn, TempSpawnType, VirtualItem;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType, GoLootState;
import dmangos.cluster.protocol : AreaDamage, CreatureLoan, CreatureSwing, GameObjectSpell, GmRemote, GroupCommand, GroupLootRoll,
    KillShare, LootCoinShare, PartyHeal, PeriodicResult, QuestLootCheck, ScriptSignal, SwingRetaliation;
import dmangos.world.loot : Loot, LootItem, maxLootItems;
import dmangos.cluster.protocol : PartySummon;
import dmangos.world.context : IdsExhausted, WorldContext;

/// See the module documentation.
final class GroupRelay
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    package MonoTime nextLootCoinPoll;
    package MonoTime nextBattlegroundRewardPoll;
    package bool[uint] retryLootCoinRedemption;

    void groupLootRollArrived(ushort peer, const ref GroupLootRoll message)
    {
        if (!peer || !message.roll || message.slot >= maxLootItems || !world.canWrite())
            return;
        final switch (message.action)
        {
        case GroupLootRoll.Action.offer:
            if (auto player = world.onlinePlayer(message.player))
                if (player.character !is null && player.currentMap.id == message.map)
                    player.offerRemoteLoot(peer, message);
            return;
        case GroupLootRoll.Action.award:
        case GroupLootRoll.Action.masterAward:
            receiveGroupLootAward(peer, message);
            return;
        case GroupLootRoll.Action.vote:
        case GroupLootRoll.Action.result:
            auto loot = lootOnMap(message.map, message.loot);
            if (loot is null)
                return;
            if (message.action == GroupLootRoll.Action.vote)
                loot.remoteVote(peer, message);
            else
                loot.remoteAwardResult(peer, message);
            return;
        }
    }

    package Loot lootOnMap(uint mapId, ulong target)
    {
        auto map_ = world.existingMap(mapId);
        if (map_ is null)
            return null;
        auto object = map_.findObject(target);
        if (auto creature = cast(Creature) object)
            return creature.loot;
        if (auto go = cast(GameObject) object)
            return go.loot;
        return null;
    }


    void routePartyQuest(const ref PartyQuest message)
    {
        const guid = message.action == PartyQuest.Action.confirm ? message.sharer : message.member;
        if (world.onlinePlayer(guid) !is null)
            receivePartyQuest(message);
        else if (world.sendPartyQuest !is null && world.canWrite())
            if (const remote = world.remotePlayer(guid))
                world.sendPartyQuest(remote.node, message);
    }

    void receivePartyQuest(const ref PartyQuest message)
    {
        const guid = message.action == PartyQuest.Action.confirm ? message.sharer : message.member;
        auto session = world.onlinePlayer(guid);
        if (session !is null && !session.transferring)
            session.receivePartyQuest(message);
    }


    package void routePartySummon(const ref PartySummon message, ushort peer = 0)
    {
        import dmangos.world.rituals : summonAcceptSeconds;

        const now = world.unixTime;
        if (!world.canWrite() || !message.sequence || !message.summoner || message.summoner == message.target
            || message.expires <= now || message.expires > now + summonAcceptSeconds + 5
            || !world.client.isValidMapCoord(message.map, message.x, message.y, message.z)
            || (message.instance && !world.dungeons.instanceable(message.map)))
            return;
        auto group = world.groups.of(message.target);
        if (group is null || group.id != message.group || !group.isMember(message.summoner))
            return;
        if (auto member = world.onlinePlayer(message.target))
            if (member.player !is null && !member.transferring)
                return member.offerPartySummon(message);
        if (world.sendPartySummon is null || message.forwarded)
            return;
        ushort owner;
        if (const hint = world.recentHandoff(message.target))
            owner = hint.node;
        else if (const presence = world.remotePlayer(message.target))
            owner = presence.node;
        if (owner && owner != peer && owner != world.nodeId)
        {
            PartySummon onward = message;
            onward.forwarded = peer != 0;
            world.sendPartySummon(owner, onward);
        }
    }

    void questLootCheckArrived(ushort peer, const ref QuestLootCheck message)
    {
        if (!peer || !message.sequence || !world.canWrite())
            return;
        if (message.reply)
        {
            if (auto loot = lootOnMap(message.map, message.loot))
                loot.acceptQuestLootCheck(peer, message);
            return;
        }
        if (world.sendQuestLootCheck is null || message.items.length == 0 || message.items.length > maxLootItems)
            return;
        auto player = world.onlinePlayer(message.player);
        if (player is null || player.character is null || player.transferring || player.currentMap.id != message.map)
            return;
        auto reply = QuestLootCheck(message.map, message.loot, message.player, message.sequence, true);
        foreach (slot, entry; message.items)
            if (entry && player.hasQuestForItem(entry))
                reply.eligible |= cast(ushort)(1u << slot);
        world.sendQuestLootCheck(peer, reply);
    }

    package void receiveGroupLootAward(ushort peer, const ref GroupLootRoll message)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.inventory : InventoryResult;
        import dmangos.world.loot : lootAwardKey;

        const key = lootAwardKey(message);
        if (world.sendRemoteGroupLoot is null || !key.player || world.playerGuid(key.player) != message.player
            || !message.loot || !message.item || !message.count)
            return;
        auto player = world.onlinePlayer(message.player);
        if (player is null || player.character is null || player.transferring || player.currentMap.id != message.map
            || !world.settleWrites())
            return;
        try
        {
            const earlier = world.database.loadLootAward(key);
            if (earlier.decided)
                return; // the loot owner can read the original result even after both workers change
            const master = message.action == GroupLootRoll.Action.masterAward;
            auto localLoot = peer == world.nodeId ? lootOnMap(message.map, message.loot) : null;
            const localDrop = localLoot !is null && localLoot.hasPendingRemoteAward(message);
            if (peer == world.nodeId && !localDrop)
                return;
            if (!master && !player.acceptRemoteLootAward(peer, message, localDrop))
                return;

            GroupLootRoll result = message;
            result.action = GroupLootRoll.Action.result;
            result.inventoryError = InventoryResult.itemNotFound;
            // A master award is for a group member: the loot's node checks the drop's members, and this node
            // refuses a player who is in no group at all.
            if (!master || (world.groups.of(message.player) !is null
                && (!message.condition || player.conditionMet(message.condition))))
                result.inventoryError = cast(ubyte) player.lootItemFits(message.item, message.count, !master);
            // The token is claimed before the item exists: the loot's node may expire the award at any moment,
            // and only one of the two can record it. Its refusal first: nothing is stored. The claim is not the
            // result: the item's rows turn it into stored (`saveLootAward`), so a claim whose item was never written
            // (this worker crashed, or its lease lapsed, before the write) is this recipient's to store again.
            if (result.inventoryError == InventoryResult.ok)
            {
                if (earlier.claimed || world.database.claimLootAward(key, world.unixTime))
                    result.inventoryError = cast(ubyte) player.storeLootItem(message.item, message.count,
                        message.randomProperty, !master, award: key);
                else
                {
                    const recorded = world.database.loadLootAward(key);
                    if (!recorded.decided)
                        return; // the claim was not written (the lease lapsed): the loot's node asks again
                    result.inventoryError = recorded.error;
                }
            }
            result.stored = result.inventoryError == InventoryResult.ok;
            if (!result.stored)
                world.database.saveLootAward(key, result.inventoryError, world.unixTime, 0, 0, null);
            if (!world.settleWrites())
                return; // the loot's node asks again; the token's row answers once the write is in
            // The row, not this worker's view, is the outcome: the item's write is what turned the claim into stored.
            const outcome = world.database.loadLootAward(key);
            if (!outcome.decided)
                return;
            result.stored = !outcome.error;
            result.inventoryError = outcome.error;
            if (localDrop)
                localLoot.remoteAwardResult(peer, result);
            else
                world.sendRemoteGroupLoot(peer, result);
        }
        catch (DatabaseException error)
            warning!"group loot award %s could not be completed yet: %s"(key.token, error.msg);
    }

    /// The link only speeds up delivery. The database holds the credit if this player moves.
    void lootCoinShareArrived(ushort peer, const ref LootCoinShare message)
    {
        import dmangos.world.objects : lowGuid;

        if (!peer || !message.sequence || !message.copper || world.playerGuid(lowGuid(message.player)) != message.player)
            return;
        redeemLootCoinShare(lowGuid(message.player));
    }

    package void redeemLootCoinShare(uint guid)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.loot : tellLootCoinShare;
        import dmangos.world.updatefields : PLAYER_FIELD_COINAGE;

        auto player = world.onlinePlayer(world.playerGuid(guid));
        if (player is null || player.player is null || player.transferring || !world.canWrite())
            return;
        if (!world.settleWrites())
        {
            retryLootCoinRedemption[guid] = true;
            return;
        }
        try
        {
            // The database adds the credits to the live purse, not to its own older copy of the money, and nothing
            // runs between reading the purse and setting it to that sum: unsaved spending is not refunded, and the
            // session and the database hold the same money afterwards.
            const paid = world.database.redeemLootCoins(guid, player.player.money.amount, world.unixTime);
            if (!paid.valid)
                return;
            retryLootCoinRedemption.remove(guid);
            if (!paid.copper)
                return;
            player.player.values.set!PLAYER_FIELD_COINAGE(paid.wallet);
            player.flushPlayerChanges();
            tellLootCoinShare(player, paid.copper);
        }
        catch (DatabaseException error)
        {
            retryLootCoinRedemption[guid] = true;
            warning!"could not redeem group coins for character %s: %s"(guid, error.msg);
        }
    }

    package void pollBattlegroundRewards(MonoTime now)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!world.battlegrounds.durable || !world.online.length || now < nextBattlegroundRewardPoll || !world.canWrite())
            return;
        nextBattlegroundRewardPoll = now + 1.seconds;
        try
        {
            foreach (ref reward; world.database.pendingBattlegroundRewards())
                if (auto who = world.onlinePlayer(world.playerGuid(reward.player)))
                    if (who.player !is null && !who.transferring)
                        who.payBattlegroundReward(reward);
            // Objectives' rewards during matches, to the players here: those online, and crash-offline ones back.
            foreach (ref event; world.database.pendingBattlegroundEventRewards())
                if (auto who = world.onlinePlayer(world.playerGuid(event.reward.player)))
                    if (who.player !is null && !who.transferring)
                        who.payBattlegroundEventReward(event);
        }
        catch (DatabaseException error)
            warning!"could not deliver battleground rewards: %s"(error.msg);
        catch (IdsExhausted error) // nothing was paid: the reward waits for the next poll, the tick goes on
            warning!"could not deliver battleground rewards yet: %s"(error.msg);
    }

    package void pollLootCoinCredits(MonoTime now)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if ((world.sendRemoteLootCoins is null && !retryLootCoinRedemption.length) || !world.online.length
            || now < nextLootCoinPoll || !world.canWrite())
            return;
        nextLootCoinPoll = now + 1.seconds;
        try
        {
            foreach (guid; world.database.pendingLootCoinPlayers())
                redeemLootCoinShare(guid);
            foreach (guid; retryLootCoinRedemption.keys)
                if (world.onlinePlayer(world.playerGuid(guid)) is null)
                    retryLootCoinRedemption.remove(guid);
                else
                    redeemLootCoinShare(guid);
        }
        catch (DatabaseException error)
            warning!"could not look up pending group coins: %s"(error.msg);
    }
}
