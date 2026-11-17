/**
 * Trading between two players (CMaNGOS `Trade/TradeHandler.cpp` and `TradeData`), mixed into
 * `dmangos.world.character.Character`.
 *
 * One player opens a trade with another of its faction within 11 yards; the other's client asks
 * it to begin, and both see the window. Each puts up to six items and some money on its side;
 * any change takes back both sides' acceptance. When both accept, the trade goes through if both
 * can pay and carry what they get: the items change hands (saved as their giver's rows gone and
 * their taker's new), so does the money, and both are saved. The seventh, "will not be traded"
 * slot (for enchanting another's item) is shown but its spell is not cast yet.
 */
module dmangos.world.tradehandlers;

/// `TradeStatus`
enum TradeStatus : uint
{
    busy = 0,
    beginTrade = 1,
    openWindow = 2,
    tradeCanceled = 3,
    tradeAccept = 4,
    busy2 = 5,
    noTarget = 6,
    backToTrade = 7,
    tradeComplete = 8,
    tradeRejected = 9,
    targetTooFar = 10,
    wrongFaction = 11,
    closeWindow = 12,
    ignoreYou = 14,
    youStunned = 15,
    targetStunned = 16,
    youDead = 17,
    targetDead = 18,
    youLogout = 19,
    targetLogout = 20,
}

/// `TRADE_SLOT_COUNT`, `TRADE_SLOT_TRADED_COUNT`
enum uint tradeSlotCount = 7, tradeSlotTradedCount = 6;

/// `TRADE_DISTANCE`
enum float tradeDistance = 11.11f;

/// `TradeData`: one side of a trade.
final class TradeSide
{
    ulong trader;           /// the other player
    ulong[tradeSlotCount] items; /// the items put up, by their full guid; 0 empty
    uint money;
    bool accepted;
}

/// See the module documentation.
mixin template TradeHandlers()
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info;
    import dmangos.world.clientdata : Team;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.defines : inventorySlotBag0, inventorySlotBagEnd, inventorySlotBagStart,
        inventorySlotItemEnd, inventorySlotItemStart, nullBag, nullSlot;
    import dmangos.world.inventory : InventoryResult, Item, ItemPosCount;
    import dmangos.world.opcodes;
    import dmangos.world.player : DeathState;
    import dmangos.world.tradehandlers;
    import dmangos.world.updatefields;

private:
    TradeSide tradeSide; // `m_trade`

    /// The other side's session, while trading.
    typeof(this) tradePartner()
    {
        if (tradeSide is null)
            return null;
        auto other = cast(typeof(this)) context.onlinePlayer(tradeSide.trader);
        return other is null || other.tradeSide is null || other.player is null ? null : other;
    }

    /// `SendTradeStatus`
    void sendTradeStatus(TradeStatus status, ulong trader = 0, uint result = 0, bool targetResult = false)
    {
        ByteWriter w;
        w.put(cast(uint) status);
        if (status == TradeStatus.beginTrade)
            w.put(trader);
        else if (status == TradeStatus.closeWindow)
        {
            w.put(result);
            w.put(ubyte(targetResult));
            w.put(0u);
        }
        deliver(Opcode.SMSG_TRADE_STATUS, w.data);
    }

    /// The item at `guid` in this player's inventory; null if it is not there.
    Item itemByGuid(ulong guid)
    {
        if (guid == 0)
            return null;
        foreach (ubyte slot; 0 .. inventorySlotItemEnd)
            if (auto item = player.inventory[inventorySlotBag0, slot])
            {
                if (item.fullGuid == guid)
                    return item;
                if (item.isBag && slot >= inventorySlotBagStart && slot < inventorySlotBagEnd)
                    foreach (ubyte i; 0 .. cast(ubyte) item.contents.length)
                        if (auto inner = player.inventory[slot, i])
                            if (inner.fullGuid == guid)
                                return inner;
            }
        return null;
    }

    /// `Item::CanBeTraded`: not bound, not an equipped or non-empty bag, not worn.
    bool canBeTraded(const Item item)
    {
        if (item.bound)
            return false;
        if (item.isBag && (item.bagSlot == inventorySlotBag0 && item.slot < inventorySlotItemStart || !item.isEmpty))
            return false;
        return !(item.bagSlot == inventorySlotBag0 && item.slot < inventorySlotBagEnd);
    }

    /// `SendUpdateTrade`: one side of the window (`traderSide`: the other's), for this player's client.
    void sendUpdateTrade(bool traderSide)
    {
        auto partner = tradePartner();
        if (partner is null)
            return;
        auto side = traderSide ? partner.tradeSide : tradeSide;
        auto owner = traderSide ? partner : this;
        ByteWriter w;
        w.put(ubyte(traderSide));
        w.put(tradeSlotCount);
        w.put(tradeSlotCount);
        w.put(side.money);
        w.put(0u); // spell cast on the non-traded slot's item
        foreach (ubyte i; 0 .. tradeSlotCount)
        {
            w.put(i);
            if (auto item = owner.itemByGuid(side.items[i]))
            {
                w.put(item.entry);
                w.put(item.proto.displayId);
                w.put(item.count);
                w.put(0u); // wrapped
                w.put(item.values.get!ITEM_FIELD_GIFTCREATOR);
                w.put(item.values.get!ITEM_FIELD_ENCHANTMENT(0));
                w.put(item.values.get!ITEM_FIELD_CREATOR);
                w.put(cast(uint) item.values.get!ITEM_FIELD_SPELL_CHARGES(0));
                w.put(0u); // suffix factor
                w.put(item.values[ITEM_FIELD_RANDOM_PROPERTIES_ID]);
                w.put(item.proto.details.lockId);
                w.put(item.maxDurability);
                w.put(item.durability);
            }
            else
                foreach (_; 0 .. 15)
                    w.put(0u);
        }
        deliver(Opcode.SMSG_TRADE_STATUS_EXTENDED, w.data);
    }

    /// `TradeData::SetAccepted(false)` for both sides: something changed, so both look again.
    void tradeChanged()
    {
        auto partner = tradePartner();
        if (partner is null)
            return;
        foreach (side; [this, partner])
            if (side.tradeSide.accepted)
            {
                side.tradeSide.accepted = false;
                side.sendTradeStatus(TradeStatus.backToTrade);
            }
        partner.sendUpdateTrade(true);
    }

    /// `Player::TradeCancel`: the trade ends, the other told (and this player if `tellMe`).
    package void cancelTrade(bool tellMe, TradeStatus status = TradeStatus.tradeCanceled)
    {
        if (tradeSide is null)
            return;
        if (auto partner = tradePartner())
        {
            partner.sendTradeStatus(status);
            partner.tradeSide = null;
        }
        if (tellMe)
            sendTradeStatus(status);
        tradeSide = null;
    }

    /// `HandleInitiateTradeOpcode`: this player asks another to trade.
    @Handles(Opcode.CMSG_INITIATE_TRADE, WorldState.inWorld)
    void handleInitiateTrade(ref ByteReader reader)
    {
        const target = reader.read!ulong;
        if (tradeSide !is null)
            return;
        if (player.deathState != DeathState.alive)
            return sendTradeStatus(TradeStatus.youDead);
        if (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.stunned)
            return sendTradeStatus(TradeStatus.youStunned);
        if (loggingOut)
            return sendTradeStatus(TradeStatus.youLogout);
        auto other = cast(typeof(this)) context.onlinePlayer(target);
        if (other is null || other.player is null || other.map !is map)
            return sendTradeStatus(TradeStatus.noTarget);
        if (other is this || other.tradeSide !is null)
            return sendTradeStatus(TradeStatus.busy);
        if (other.player.deathState != DeathState.alive)
            return sendTradeStatus(TradeStatus.targetDead);
        if (other.player.values.get!UNIT_FIELD_FLAGS & UnitFlags.stunned)
            return sendTradeStatus(TradeStatus.targetStunned);
        if (other.loggingOut)
            return sendTradeStatus(TradeStatus.targetLogout);
        if (context.client.teamForRace(player.data.race) != context.client.teamForRace(other.player.data.race))
            return sendTradeStatus(TradeStatus.wrongFaction);
        const a = player.position, b = other.player.position;
        if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 > tradeDistance ^^ 2)
            return sendTradeStatus(TradeStatus.targetTooFar);
        tradeSide = new TradeSide;
        tradeSide.trader = other.player.guid;
        other.tradeSide = new TradeSide;
        other.tradeSide.trader = player.guid;
        other.sendTradeStatus(TradeStatus.beginTrade, player.guid);
    }

    /// `HandleBeginTradeOpcode`: the asked one's client agrees; both windows open.
    @Handles(Opcode.CMSG_BEGIN_TRADE, WorldState.inWorld)
    void handleBeginTrade()
    {
        if (auto partner = tradePartner())
        {
            partner.sendTradeStatus(TradeStatus.openWindow);
            sendTradeStatus(TradeStatus.openWindow);
        }
    }

    /// `HandleBusyTradeOpcode`, `HandleIgnoreTradeOpcode`
    @Handles(Opcode.CMSG_BUSY_TRADE, WorldState.inWorld)
    void handleBusyTrade()
    {
        cancelTrade(true, TradeStatus.busy);
    }

    /// ditto
    @Handles(Opcode.CMSG_IGNORE_TRADE, WorldState.inWorld)
    void handleIgnoreTrade()
    {
        cancelTrade(true, TradeStatus.ignoreYou);
    }

    /// `HandleCancelTradeOpcode`
    @Handles(Opcode.CMSG_CANCEL_TRADE, WorldState.inWorld)
    void handleCancelTrade()
    {
        cancelTrade(true);
    }

    /// `HandleSetTradeItemOpcode`: an item of this player's in a trade slot.
    @Handles(Opcode.CMSG_SET_TRADE_ITEM, WorldState.inWorld)
    void handleSetTradeItem(ref ByteReader reader)
    {
        const tradeSlot = reader.read!ubyte, bag = reader.read!ubyte, slot = reader.read!ubyte;
        if (tradeSide is null)
            return;
        auto item = tradeSlot < tradeSlotCount ? player.inventory[bag, slot] : null;
        if (item is null || (tradeSlot != tradeSlotTradedCount && !canBeTraded(item)))
            return sendTradeStatus(TradeStatus.tradeCanceled);
        foreach (put; tradeSide.items)
            if (put == item.fullGuid)
                return sendTradeStatus(TradeStatus.tradeCanceled);
        tradeSide.items[tradeSlot] = item.fullGuid;
        tradeChanged();
    }

    /// `HandleClearTradeItemOpcode`
    @Handles(Opcode.CMSG_CLEAR_TRADE_ITEM, WorldState.inWorld)
    void handleClearTradeItem(ref ByteReader reader)
    {
        const tradeSlot = reader.read!ubyte;
        if (tradeSide is null || tradeSlot >= tradeSlotCount)
            return;
        tradeSide.items[tradeSlot] = 0;
        tradeChanged();
    }

    /// `HandleSetTradeGoldOpcode`: checked when the trade goes through.
    @Handles(Opcode.CMSG_SET_TRADE_GOLD, WorldState.inWorld)
    void handleSetTradeGold(ref ByteReader reader)
    {
        const money = reader.read!uint;
        if (tradeSide is null || tradeSide.money == money)
            return;
        tradeSide.money = money;
        tradeChanged();
    }

    /// `HandleUnacceptTradeOpcode`
    @Handles(Opcode.CMSG_UNACCEPT_TRADE, WorldState.inWorld)
    void handleUnacceptTrade()
    {
        auto partner = tradePartner();
        if (partner is null)
            return;
        tradeSide.accepted = false;
        partner.sendTradeStatus(TradeStatus.backToTrade);
    }

    /// How many items (not stacking) this player could still carry: free backpack and bag slots.
    uint freeSlots()
    {
        uint free;
        foreach (ubyte slot; inventorySlotItemStart .. inventorySlotItemEnd)
            if (player.inventory[inventorySlotBag0, slot] is null)
                ++free;
        foreach (ubyte bag; inventorySlotBagStart .. inventorySlotBagEnd)
            if (auto container = player.inventory[inventorySlotBag0, bag])
                if (container.isBag && container.proto.bagFamily == 0)
                    foreach (ubyte i; 0 .. cast(ubyte) container.contents.length)
                        if (player.inventory[bag, i] is null)
                            ++free;
        return free;
    }

    /// `HandleAcceptTradeOpcode`: this side accepts; when both have, the trade goes through.
    @Handles(Opcode.CMSG_ACCEPT_TRADE, WorldState.inWorld)
    void handleAcceptTrade(ref ByteReader reader)
    {
        auto partner = tradePartner();
        if (partner is null)
            return;
        auto mine = tradeSide, his = partner.tradeSide;
        mine.accepted = true;
        const a = player.position, b = partner.player.position;
        if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 > tradeDistance ^^ 2)
        {
            sendTradeStatus(TradeStatus.targetTooFar);
            mine.accepted = false;
            return;
        }
        if (mine.money > player.money)
        {
            sendTradeStatus(TradeStatus.closeWindow, 0, InventoryResult.notEnoughMoney);
            mine.accepted = false;
            return partner.sendTradeStatus(TradeStatus.backToTrade);
        }
        if (his.money > partner.player.money)
        {
            partner.sendTradeStatus(TradeStatus.closeWindow, 0, InventoryResult.notEnoughMoney);
            his.accepted = false;
            return sendTradeStatus(TradeStatus.backToTrade);
        }
        Item[] myItems, hisItems;
        foreach (i; 0 .. tradeSlotTradedCount)
        {
            if (auto item = itemByGuid(mine.items[i]))
            {
                if (!canBeTraded(item))
                    return sendTradeStatus(TradeStatus.tradeCanceled);
                myItems ~= item;
            }
            if (auto item = partner.itemByGuid(his.items[i]))
            {
                if (!partner.canBeTraded(item))
                    return sendTradeStatus(TradeStatus.tradeCanceled);
                hisItems ~= item;
            }
        }
        if (!his.accepted)
            return partner.sendTradeStatus(TradeStatus.tradeAccept);

        partner.sendTradeStatus(TradeStatus.tradeAccept);
        // `CanStoreItems`: room for what each gets, counting what each gives away.
        if (hisItems.length > freeSlots() + myItems.length)
        {
            partner.sendTradeStatus(TradeStatus.closeWindow, 0, InventoryResult.inventoryFull);
            sendTradeStatus(TradeStatus.closeWindow, 0, InventoryResult.inventoryFull, true);
            mine.accepted = his.accepted = false;
            return;
        }
        if (myItems.length > partner.freeSlots() + hisItems.length)
        {
            sendTradeStatus(TradeStatus.closeWindow, 0, InventoryResult.inventoryFull);
            partner.sendTradeStatus(TradeStatus.closeWindow, 0, InventoryResult.inventoryFull, true);
            mine.accepted = his.accepted = false;
            return;
        }

        // The items change hands: gone from the giver (its rows deleted), new to the taker (rows inserted).
        auto mineGiven = giveAway(myItems, partner.player.guid);
        auto hisGiven = partner.giveAway(hisItems, player.guid);
        flushInventory();
        partner.flushInventory();
        receiveTraded(hisGiven);
        partner.receiveTraded(mineGiven);
        player.modifyMoney(cast(long) his.money - cast(long) mine.money);
        partner.player.modifyMoney(cast(long) mine.money - cast(long) his.money);
        tradeSide = null;
        partner.tradeSide = null;
        flushInventory(true);
        partner.flushInventory(true);
        info!"%s: '%s' traded %s items and %s copper for %s items and %s copper with '%s'"(remoteAddress,
            player.data.name, myItems.length, mine.money, hisItems.length, his.money, partner.player.data.name);
        partner.sendTradeStatus(TradeStatus.tradeComplete);
        sendTradeStatus(TradeStatus.tradeComplete);
    }

    /// The items leave this player's inventory for `taker`: copies of them (same guids) are returned.
    package Item[] giveAway(Item[] items, ulong taker)
    {
        Item[] copies;
        foreach (item; items)
        {
            auto record = item.record;
            record.giftCreator = player.data.guid; // `ITEM_FIELD_GIFTCREATOR`: who gave it
            copies ~= Item.load(record, item.proto, taker);
            player.inventory.destroy(item.bagSlot, item.slot);
        }
        return copies;
    }

    /// The items come into this player's bags.
    package void receiveTraded(Item[] items)
    {
        foreach (item; items)
        {
            ItemPosCount[] dest;
            ubyte bagSlot;
            if (player.inventory.canStore(nullBag, nullSlot, dest, item, false, bagSlot) == InventoryResult.ok)
                player.inventory.store(dest, item);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Anduin gives Jaina jerky and 50 copper for 20 of hers: asked, begun, set up, accepted by both, done.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.defines : inventorySlotBag0, nullBag, nullSlot;
    import dmangos.world.inventory : InventoryResult, ItemPosCount;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8945, -132, 83.5f));
    anduin.read();
    jaina.read();
    auto a = cast(Player) anduin.session.character, j = cast(Player) jaina.session.character;
    ItemPosCount[] dest;
    assert(a.inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 5) == InventoryResult.ok);
    auto jerky = a.inventory.storeNew(dest, itemJerky);
    a.modifyMoney(100);
    j.modifyMoney(100);

    ByteWriter target;
    target.put(j.guid);
    anduin.write(Opcode.CMSG_INITIATE_TRADE, target.data);
    assert(opcodesOf(jaina.read()) == [Opcode.SMSG_TRADE_STATUS], "Jaina is asked");
    jaina.write(Opcode.CMSG_BEGIN_TRADE, null);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_TRADE_STATUS));

    anduin.write(Opcode.CMSG_SET_TRADE_ITEM, [ubyte(0), jerky.bagSlot, jerky.slot]);
    ByteWriter fifty;
    fifty.put(50u);
    anduin.write(Opcode.CMSG_SET_TRADE_GOLD, fifty.data);
    ByteWriter twenty;
    twenty.put(20u);
    jaina.write(Opcode.CMSG_SET_TRADE_GOLD, twenty.data);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_TRADE_STATUS_EXTENDED), "she sees what he puts up");
    anduin.read();

    ByteWriter accept;
    accept.put(1u);
    anduin.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    assert(a.inventory[jerky.bagSlot, jerky.slot] is jerky, "not before both accept");
    jaina.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    assert(a.inventory[jerky.bagSlot, jerky.slot] is null, "gone from Anduin");
    assert(a.inventory.count(itemJerky) == 0 && j.inventory.count(itemJerky) == 5, "now Jaina's");
    assert(a.money == 70 && j.money == 130);
    assert(jerky.guid in db.itemRows, "saved again under its taker");
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_TRADE_STATUS));
}
