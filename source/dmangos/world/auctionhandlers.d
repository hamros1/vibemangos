/**
 * Auctions at an auctioneer: the client's auction requests, mixed into
 * `dmangos.world.character.Character`.
 *
 * An item put up (not bound, conjured or temporary) for 2, 8 or 24 hours costs a deposit, and
 * waits in its house (`dmangos.world.auctionhouse`) for bids of at least the start bid and 5% more
 * than the last; a bid at the buyout price, or the highest bid when the time is up, buys it: the
 * buyer gets the item by mail, the seller the price and the deposit less the house's cut. A
 * bidder outbid gets the bid back by mail. A seller may take the auction back (paying the cut of a
 * bid, which goes back to its bidder): the item comes back by mail. The lists (search, own
 * auctions, bids) show 50 at a time.
 */
module dmangos.world.auctionhandlers;

import dmangos.world.money : Copper;

/// See the module documentation.
mixin template AuctionHandlers()
{
    import dmangos.world.money : Copper;
    import std.algorithm.searching : canFind;
    import std.uni : toLower;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info;
    import dmangos.world.auctionhouse;
    import dmangos.world.inventory : InventoryResult, Item;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.opcodes;
    import dmangos.world.updatefields;

    /// The house of an auctioneer near; null if none.
    const(AuctionHouseEntry)* auctionHouseOf(ulong auctioneer)
    {
        auto npc = interactableNpc(auctioneer, NpcFlag.auctioneer);
        if (npc is null)
            return null;
        const factionTemplate = npc.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE;
        uint houseId = 1;
        if (!context.config.allowTwoSideInteractionAuction)
        {
            const t = context.client.factionTemplates.lookup(factionTemplate);
            houseId = auctionHouseFor(factionTemplate, t is null ? 0 : t.groupMask);
        }
        return context.auctionHouse(houseId);
    }

    /// Tells the client how an auction command went (`SMSG_AUCTION_COMMAND_RESULT`).
    void sendAuctionResult(uint id, AuctionAction action, AuctionError error, uint inventoryError = 0,
        const(AuctionRecord)* auction = null)
    {
        ByteWriter w;
        w.put(id);
        w.put(cast(uint) action);
        w.put(cast(uint) error);
        if (error == AuctionError.ok && action == AuctionAction.bidPlaced && auction !is null)
            w.put(auction.outBid);
        else if (error == AuctionError.inventory)
            w.put(inventoryError);
        else if (error == AuctionError.higherBid && auction !is null)
        {
            w.put(ulong(auction.bidder));
            w.put(auction.bid);
            w.put(auction.outBid);
        }
        deliver(Opcode.SMSG_AUCTION_COMMAND_RESULT, w.data);
    }

    /// The player talks to an auctioneer: the auction window, with its house.
    @Handles(Opcode.MSG_AUCTION_HELLO, WorldState.inWorld)
    void handleAuctionHello(ref ByteReader reader)
    {
        sendAuctionHello(reader.read!ulong);
    }

    /// The auction window of auctioneer `guid`, with its house.
    package void sendAuctionHello(ulong guid)
    {
        const house = auctionHouseOf(guid);
        if (house is null)
            return;
        ByteWriter w;
        w.put(guid);
        w.put(house.houseId);
        deliver(Opcode.MSG_AUCTION_HELLO, w.data);
    }

    /// The player puts an item up for auction.
    @Handles(Opcode.CMSG_AUCTION_SELL_ITEM, WorldState.inWorld)
    void handleAuctionSellItem(ref ByteReader reader)
    {
        enum uint itemFlagConjured = 0x2;
        enum uint maxMoney = 0x7FFF_FFFF;
        const auctioneer = reader.read!ulong, itemGuid = reader.read!ulong;
        const bid = reader.read!uint, buyout = reader.read!uint, minutes = reader.read!uint;
        if (!bid || !minutes)
            return;
        const house = auctionHouseOf(auctioneer);
        if (house is null)
            return;
        const seconds = minutes * 60;
        if (seconds != minAuctionTime && seconds != 4 * minAuctionTime && seconds != 12 * minAuctionTime)
            return;
        if (!itemGuid)
            return;
        if (bid > maxMoney || buyout > maxMoney)
            return sendAuctionResult(0, AuctionAction.started, AuctionError.database);
        auto item = itemByGuid(itemGuid);
        if (item is null || !canBeTraded(item))
            return sendAuctionResult(0, AuctionAction.started, AuctionError.inventory, InventoryResult.itemNotFound);
        const proto = item.entry in context.data.items;
        if (proto is null || (proto.flags & itemFlagConjured) || item.values[ITEM_FIELD_DURATION])
            return sendAuctionResult(0, AuctionAction.started, AuctionError.inventory, InventoryResult.itemNotFound);
        const deposit = Copper(auctionDeposit(*house, seconds, proto.details.sellPrice, item.count,
            context.config.auctionRates));
        if (!player.canAfford(deposit))
            return sendAuctionResult(0, AuctionAction.started, AuctionError.notEnoughMoney);

        // Out of the bags into the house, the deposit paid.
        player.pay(deposit);
        auto record = item.record;
        AuctionRecord a;
        a.id = context.nextMailId();
        a.houseId = house.houseId;
        a.itemGuid = record.guid;
        a.itemEntry = record.entry;
        a.itemCount = record.count;
        a.randomPropertyId = record.randomPropertyId;
        a.owner = player.data.guid;
        a.startBid = bid;
        a.buyout = buyout;
        a.expireTime = context.unixTime + auctionDuration(seconds, context.config.auctionRates);
        a.deposit = deposit.amount; // the row keeps the plain number
        player.inventory.destroy(item.bagSlot, item.slot);
        flushInventory(true);
        record.bag = 0;
        context.database.saveLooseItem(record, player.data.guid);
        context.database.insertAuction(a);
        sendAuctionResult(a.id, AuctionAction.started, AuctionError.ok);
        info!"%s: '%s' put up %s x%s for auction %s (%s to %s, deposit %s)"(remoteAddress, player.data.name,
            a.itemEntry, a.itemCount, a.id, bid, buyout, deposit);
    }

    /// The player bids on an auction, or buys it out.
    @Handles(Opcode.CMSG_AUCTION_PLACE_BID, WorldState.inWorld)
    void handleAuctionPlaceBid(ref ByteReader reader)
    {
        const auctioneer = reader.read!ulong, id = reader.read!uint;
        uint price = reader.read!uint;
        if (!id || !price)
            return;
        const house = auctionHouseOf(auctioneer);
        if (house is null)
            return;
        auto found = context.database.auctionById(id);
        if (found.isNull || found.get.houseId != house.houseId || found.get.owner == player.data.guid)
            return sendAuctionResult(0, AuctionAction.bidPlaced, AuctionError.bidOwn);
        const a = found.get;
        // Not on an auction of another character of this account.
        if (context.database.characterRaceAccount(a.owner)[1] == account.id)
            return sendAuctionResult(0, AuctionAction.bidPlaced, AuctionError.bidOwn);
        if (price <= a.bid)
            return sendAuctionResult(a.id, AuctionAction.bidPlaced, AuctionError.higherBid, 0, &a);
        if ((price < a.buyout || a.buyout == 0) && price < a.bid + a.outBid)
            return sendAuctionResult(a.id, AuctionAction.bidPlaced, AuctionError.bidIncrement);
        if (price < a.startBid)
            return;
        // No more than the buyout; the same bidder pays only what it adds.
        if (a.buyout && price > a.buyout)
            price = a.buyout;
        const ownBid = a.bidder == player.data.guid;
        const pays = Copper(price) - Copper(ownBid ? a.bid : 0);
        if (!player.canAfford(pays))
            return;
        const buyout = a.buyout && price >= a.buyout;
        // The table decides: the bid is placed only if the auction is still as it was seen.
        const placed = buyout ? context.database.deleteAuction(a.id, a.bid)
            : context.database.bidOnAuction(a.id, a.bidder, a.bid, player.data.guid, price);
        if (!placed)
        {
            auto now = context.database.auctionById(id);
            if (now.isNull)
                return sendAuctionResult(0, AuctionAction.bidPlaced, AuctionError.database);
            return sendAuctionResult(id, AuctionAction.bidPlaced, AuctionError.higherBid, 0, &now.get());
        }
        player.pay(pays);
        flushPlayerChanges();
        if (a.bidder && !ownBid)
            context.auctionOutbid(a); // the old bidder's money back
        AuctionRecord after = a;
        after.bidder = player.data.guid;
        after.bid = price;
        sendAuctionResult(a.id, AuctionAction.bidPlaced, AuctionError.ok, 0, &after);
        if (buyout)
        {
            context.auctionSold(after);
            info!"%s: '%s' bought out auction %s for %s"(remoteAddress, player.data.name, a.id, price);
        }
        else
            context.deliverTo(a.owner, Opcode.SMSG_AUCTION_OWNER_NOTIFICATION, ownerNotification(after, false));
    }

    /// The seller takes an auction back; the item comes by mail.
    @Handles(Opcode.CMSG_AUCTION_REMOVE_ITEM, WorldState.inWorld)
    void handleAuctionRemoveItem(ref ByteReader reader)
    {
        const auctioneer = reader.read!ulong, id = reader.read!uint;
        const house = auctionHouseOf(auctioneer);
        if (house is null)
            return;
        auto found = context.database.auctionById(id);
        if (found.isNull || found.get.owner != player.data.guid)
            return sendAuctionResult(0, AuctionAction.removed, AuctionError.database);
        const a = found.get;
        const cut = Copper(a.bid ? a.cut(*house, context.config.rateAuctionCut) : 0);
        if (!player.canAfford(cut))
            return;
        if (!context.database.deleteAuction(a.id, a.bid))
            return sendAuctionResult(0, AuctionAction.removed, AuctionError.database); // bid on meanwhile
        if (a.bidder)
        {
            // The bidder is told, and gets the bid back by mail.
            context.deliverTo(a.bidder, Opcode.SMSG_AUCTION_REMOVED_NOTIFICATION, removedNotification(a));
            context.auctionMail(a.bidder, a, AuctionMail.cancelledToBidder, a.bid, false);
        }
        player.pay(cut);
        flushPlayerChanges();
        context.auctionMail(player.data.guid, a, AuctionMail.cancelled, 0, true);
        sendAuctionResult(a.id, AuctionAction.removed, AuctionError.ok);
    }

    /// The auctions' lines from `listFrom` on (50 at most): the count shown, the lines, and the total.
    void sendAuctionList(Opcode opcode, const(AuctionRecord)[] auctions, uint listFrom)
    {
        ByteWriter lines;
        uint count;
        const now = context.unixTime;
        foreach (i, ref a; auctions)
            if (i >= listFrom && count < auctionPageSize)
            {
                a.write(lines, now);
                ++count;
            }
        ByteWriter w;
        w.put(count);
        w.putBytes(lines.data);
        w.put(cast(uint) auctions.length);
        deliver(opcode, w.data);
    }

    /// The list of the player's own auctions.
    @Handles(Opcode.CMSG_AUCTION_LIST_OWNER_ITEMS, WorldState.inWorld)
    void handleAuctionListOwnerItems(ref ByteReader reader)
    {
        const house = auctionHouseOf(reader.read!ulong);
        const listFrom = reader.read!uint;
        if (house is null)
            return;
        AuctionRecord[] mine;
        foreach (ref a; context.database.loadAuctions(house.houseId))
            if (a.owner == player.data.guid)
                mine ~= a;
        sendAuctionList(Opcode.SMSG_AUCTION_OWNER_LIST_RESULT, mine, listFrom);
    }

    /// The auctions this player bid on (the outbid ones asked for first).
    @Handles(Opcode.CMSG_AUCTION_LIST_BIDDER_ITEMS, WorldState.inWorld)
    void handleAuctionListBidderItems(ref ByteReader reader)
    {
        const house = auctionHouseOf(reader.read!ulong);
        const listFrom = reader.read!uint;
        const outbidCount = reader.read!uint;
        uint[] outbid;
        foreach (_; 0 .. outbidCount)
        {
            if (reader.remaining < 4)
                break;
            outbid ~= reader.read!uint;
        }
        if (house is null)
            return;
        AuctionRecord[] wanted, mine;
        foreach (ref a; context.database.loadAuctions(house.houseId))
        {
            if (outbid.canFind(a.id))
                wanted ~= a;
            if (a.bidder == player.data.guid)
                mine ~= a;
        }
        // After the outbid ones: all of those are shown, then the page of bids.
        ByteWriter lines;
        uint count;
        const now = context.unixTime;
        foreach (ref a; wanted)
        {
            a.write(lines, now);
            ++count;
        }
        uint total = count;
        foreach (i, ref a; mine)
        {
            if (count < auctionPageSize && total >= listFrom)
            {
                a.write(lines, now);
                ++count;
            }
            ++total;
        }
        ByteWriter w;
        w.put(count);
        w.putBytes(lines.data);
        w.put(total);
        deliver(Opcode.SMSG_AUCTION_BIDDER_LIST_RESULT, w.data);
    }

    /// The search.
    @Handles(Opcode.CMSG_AUCTION_LIST_ITEMS, WorldState.inWorld)
    void handleAuctionListItems(ref ByteReader reader)
    {
        enum uint invTypeChest = 5, invTypeRobe = 20, any = uint.max;
        const house = auctionHouseOf(reader.read!ulong);
        const listFrom = reader.read!uint;
        const name = reader.readCString().toLower;
        const levelMin = reader.read!ubyte, levelMax = reader.read!ubyte;
        const slot = reader.read!uint, itemClass = reader.read!uint, subClass = reader.read!uint,
            quality = reader.read!uint;
        const usable = reader.read!ubyte;
        if (house is null)
            return;
        AuctionRecord[] found;
        foreach (ref a; context.database.loadAuctions(house.houseId))
        {
            const proto = a.itemEntry in context.data.items;
            if (proto is null)
                continue;
            if (itemClass != any && proto.itemClass != itemClass)
                continue;
            if (subClass != any && proto.subClass != subClass)
                continue;
            if (slot != any && proto.inventoryType != slot && (slot != invTypeChest || proto.inventoryType != invTypeRobe))
                continue;
            if (quality != any && proto.details.quality < quality)
                continue;
            if (levelMin && (proto.requiredLevel < levelMin || (levelMax && proto.requiredLevel > levelMax)))
                continue;
            if (usable && !canUseItem(a.itemEntry))
                continue;
            if (name.length && !proto.details.name.toLower.canFind(name))
                continue;
            found ~= a;
        }
        sendAuctionList(Opcode.SMSG_AUCTION_LIST_RESULT, found, listFrom);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * Anduin puts his sword up; Jaina finds it and bids, Varian outbids her (her money comes back by
 * mail) and buys it out: he gets the sword by mail, Anduin the price and his deposit less the cut.
 * Another auction nobody bids on goes back to its seller when its time is up.
 */
unittest
{
    import core.time : MonoTime, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auctionhouse;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // Every house: 15% deposit, 5% cut.
    uint[] house(uint id)
    {
        auto row = new uint[auctionHouseFormat.length];
        row[0] = id;
        row[2] = 15;
        row[3] = 5;
        return row;
    }
    context.client.auctionHouses = typeof(context.client.auctionHouses).parse(buildDbc(auctionHouseFormat,
        [house(1), house(6), house(7)]), "AuctionHouse.dbc");
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8949.5f, -132, 83.53f));
    auto varian = loggedIn(context, db, 9, "Varian", Position(-8949.5f, -133, 83.53f));
    auto keeper = cast(Creature) context.map(0).findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    keeper.values.set!UNIT_NPC_FLAGS(keeper.values.get!UNIT_NPC_FLAGS | NpcFlag.auctioneer);
    auto seller = cast(Player) anduin.session.character, first = cast(Player) jaina.session.character,
        second = cast(Player) varian.session.character;
    seller.receive(Copper(1000));
    anduin.session.inWorld.storeLoot(itemSword, 1, 0, false);
    jaina.session.inWorld.storeLoot(itemJerky, 1, 0, false);
    first.receive(Copper(1000));
    second.receive(Copper(1000));
    foreach (c; [&anduin, &jaina, &varian])
        c.read();

    // The window opens on the auctioneer's house.
    ByteWriter hello;
    hello.put(keeper.guid);
    anduin.write(Opcode.MSG_AUCTION_HELLO, hello.data);
    assert(opcodesOf(anduin.read()) == [Opcode.MSG_AUCTION_HELLO]);

    // The sword (sold for 7) for 8 hours: 15% of 7, 1 copper rounded down, for each 2 hours (4 copper).
    import dmangos.world.inventory : Item;

    Item sword;
    foreach (item; seller.inventory.all())
        if (item.entry == itemSword)
            sword = item;
    assert(sword !is null);
    ByteWriter sell;
    sell.put(keeper.guid);
    sell.put(sword.fullGuid);
    sell.put(100u);
    sell.put(500u);
    sell.put(8u * 60);
    anduin.write(Opcode.CMSG_AUCTION_SELL_ITEM, sell.data);
    assert(seller.inventory.count(itemSword) == 0 && seller.money == Copper(1000 - 4), "up, the deposit paid");
    const auctions = db.loadAuctions(0);
    assert(auctions.length == 1 && auctions[0].itemEntry == itemSword && auctions[0].deposit == 4);
    const id = auctions[0].id;

    // Jaina's search finds it.
    ByteWriter search;
    search.put(keeper.guid);
    search.put(0u);
    search.putCString("");
    search.put(ubyte(0));
    search.put(ubyte(0));
    foreach (_; 0 .. 4)
        search.put(uint.max);
    search.put(ubyte(0));
    jaina.read();
    jaina.write(Opcode.CMSG_AUCTION_LIST_ITEMS, search.data);
    auto got = jaina.read();
    assert(got.length == 1 && got[0].opcode == Opcode.SMSG_AUCTION_LIST_RESULT);
    auto r = ByteReader(got[0].body_);
    assert(r.read!uint == 1 && r.read!uint == id && r.read!uint == itemSword);

    ubyte[] bid(uint price)
    {
        ByteWriter w;
        w.put(keeper.guid);
        w.put(id);
        w.put(price);
        return w.data.dup;
    }

    // Anduin may not bid on his own; Jaina bids 100.
    anduin.write(Opcode.CMSG_AUCTION_PLACE_BID, bid(150));
    jaina.write(Opcode.CMSG_AUCTION_PLACE_BID, bid(100));
    assert(first.money == Copper(900) && db.auctionById(id).get.bidder == first.data.guid);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_AUCTION_OWNER_NOTIFICATION), "the seller hears of the bid");
    // Varian's 104 is not 5% more; 200 is, and Jaina's 100 comes back by mail.
    varian.write(Opcode.CMSG_AUCTION_PLACE_BID, bid(104));
    assert(second.money == Copper(1000));
    varian.write(Opcode.CMSG_AUCTION_PLACE_BID, bid(200));
    assert(second.money == Copper(800) && db.auctionById(id).get.bid == 200);
    assert(db.loadMail(first.data.guid).canFind!(m => m.money == 100 && m.messageType == 2
        && m.subject == auctionMailSubject(db.auctionById(id).get, AuctionMail.outbidded)));
    // Then he buys it out at 500, paying the 300 more.
    varian.write(Opcode.CMSG_AUCTION_PLACE_BID, bid(500));
    assert(second.money == Copper(500) && db.auctionById(id).isNull, "bought out");
    assert(db.loadMail(second.data.guid).canFind!(m => m.itemEntry == itemSword), "the sword by mail");
    // 500 and the deposit, less the 5% cut: 479.
    assert(db.loadMail(seller.data.guid).canFind!(m => m.money == 500 + 4 - 25), "the price by mail");

    // Jaina's jerky for 2 hours: nobody bids, and it comes back.
    Item jerky;
    foreach (item; first.inventory.all())
        if (item.entry == itemJerky)
            jerky = item;
    ByteWriter sell2;
    sell2.put(keeper.guid);
    sell2.put(jerky.fullGuid);
    sell2.put(10u);
    sell2.put(0u);
    sell2.put(2u * 60);
    jaina.write(Opcode.CMSG_AUCTION_SELL_ITEM, sell2.data);
    assert(db.loadAuctions(0).length == 1);
    now += (2 * 60 * 60 + 61).seconds;
    context.update(now);
    assert(db.loadAuctions(0).length == 0 && db.loadMail(first.data.guid).canFind!(m => m.itemEntry == itemJerky),
        "expired: back by mail");
}
