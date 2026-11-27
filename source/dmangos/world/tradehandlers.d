/**
 * Trading between two players, mixed into
 * `dmangos.world.character.Character`.
 *
 * One player opens a trade with another of its faction within 11 yards; the other's client asks
 * it to begin, and both see the window. Each puts up to six items and some money on its side;
 * any change takes back both sides' acceptance. When both accept, the trade goes through if both
 * can pay and carry what they get: the items change hands (saved as their giver's rows gone and
 * their taker's new), so does the money, and both are saved.
 *
 * The seventh, "will not be traded" slot holds an item its owner keeps, for the other to enchant: a spell cast at it
 * (`TARGET_FLAG_TRADE_ITEM`, the slot's number for its guid) is not cast then but remembered for its side (`TradeData::
 * SetSpell`: both acceptances taken back, both windows showing it), and cast when the trade goes through, at once and
 * paying its costs (`TRIGGERED_FORCE_COSTS`), on the other's item, which stays with its owner. Changing that item
 * forgets the other's spell; a spell whose item (or the scroll it is cast from) is gone, or that cannot be cast as
 * the trade completes, is forgotten and the trade waits (`WorldSession::HandleAcceptTradeOpcode`).
 */
module dmangos.world.tradehandlers;

import dmangos.world.money : Copper;

/// The trade statuses the client knows (`SMSG_TRADE_STATUS`).
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

/// Trade slots: seven, of which six change hands (the last is "will not be traded").
enum uint tradeSlotCount = 7, tradeSlotTradedCount = 6;

/// How far apart two players may trade, in yards.
enum float tradeDistance = 11.11f;

/// One side of a trade.
final class TradeSide
{
    ulong trader;           /// the other player
    ulong[tradeSlotCount] items; /// the items put up, by their full guid; 0 empty
    uint money;
    bool accepted;
    uint spell;             /// cast at the other's "will not be traded" item when the trade goes through; 0: none
    ulong spellItem;        /// ... from this item of the caster's (a scroll); 0: none
    uint spellItemEntry;    /// ... its entry
}

/// See the module documentation.
mixin template TradeHandlers()
{
    import dmangos.world.money : Copper;
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
    TradeSide tradeSide; // this player's side of the trade under way; null if none

    /// The other side's session, while trading.
    typeof(this) tradePartner()
    {
        if (tradeSide is null)
            return null;
        auto other = context.onlinePlayer(tradeSide.trader);
        return other is null || other.tradeSide is null || other.player is null ? null : other;
    }

    /// Sends `SMSG_TRADE_STATUS`.
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
    package Item itemByGuid(ulong guid)
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

    /// Whether an item may be traded: not bound, not an equipped or non-empty bag, not worn.
    package bool canBeTraded(const Item item)
    {
        if (item.bound)
            return false;
        if (item.isBag && (item.bagSlot == inventorySlotBag0 && item.slot < inventorySlotItemStart || !item.isEmpty))
            return false;
        return !(item.bagSlot == inventorySlotBag0 && item.slot < inventorySlotBagEnd);
    }

    /// One side of the window (`traderSide`: the other's), for this player's client.
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
        w.put(side.spell); // the spell to be cast on the non-traded slot's item
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

    /// Both sides' acceptance taken back: something changed, so both look again.
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

    /// The trade ends, the other told (and this player if `tellMe`).
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

    /// This player asks another to trade.
    @Handles(Opcode.CMSG_INITIATE_TRADE, WorldState.inWorld)
    void handleInitiateTrade(ref ByteReader reader)
    {
        initiateTrade(reader.read!ulong, true);
    }

    void initiateTrade(ulong target, bool mayMigrate)
    {
        if (tradeSide !is null)
            return;
        if (player.deathState != DeathState.alive)
            return sendTradeStatus(TradeStatus.youDead);
        if (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.stunned)
            return sendTradeStatus(TradeStatus.youStunned);
        if (loggingOut)
            return sendTradeStatus(TradeStatus.youLogout);
        auto other = context.onlinePlayer(target);
        if (other is null && mayMigrate)
            return initiateTradeAtReplica(target);
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

    /// Check what the local replica can tell us before moving. The owner checks the live player.
    void initiateTradeAtReplica(ulong target)
    {
        import dmangos.world.inworld : ArrivalAction;
        import dmangos.world.replication : Replica;

        auto replica = cast(Replica) map.findObject(target);
        if (replica is null || replica.fields.type != TypeId.player)
            return sendTradeStatus(TradeStatus.noTarget);
        if (!replica.fields.get!UNIT_FIELD_HEALTH)
            return sendTradeStatus(TradeStatus.targetDead);
        if (replica.fields.get!UNIT_FIELD_FLAGS & UnitFlags.stunned)
            return sendTradeStatus(TradeStatus.targetStunned);
        if (context.client.teamForRace(player.data.race)
            != context.client.teamForRace(replica.fields.getByte!UNIT_FIELD_BYTES_0(0)))
            return sendTradeStatus(TradeStatus.wrongFaction);
        const a = player.position, b = replica.position;
        if ((a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 > tradeDistance ^^ 2)
            return sendTradeStatus(TradeStatus.targetTooFar);
        ArrivalAction action;
        action.tradeTarget = target;
        if (inCombat || taxi.flying || !actAtReplica(target, action))
            sendTradeStatus(TradeStatus.busy);
    }

    /// The asked one's client agrees; both windows open.
    @Handles(Opcode.CMSG_BEGIN_TRADE, WorldState.inWorld)
    void handleBeginTrade()
    {
        if (auto partner = tradePartner())
        {
            partner.sendTradeStatus(TradeStatus.openWindow);
            sendTradeStatus(TradeStatus.openWindow);
        }
    }

    /// The other player is busy, or ignores this one: the trade ends.
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

    /// This player cancels the trade.
    @Handles(Opcode.CMSG_CANCEL_TRADE, WorldState.inWorld)
    void handleCancelTrade()
    {
        cancelTrade(true);
    }

    /// An item of this player's in a trade slot.
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
        if (tradeSlot == tradeSlotTradedCount) // another item to enchant: the other's spell is forgotten
            if (auto partner = tradePartner())
                partner.setTradeSpell(0, 0, 0);
        tradeChanged();
    }

    /// A trade slot emptied.
    @Handles(Opcode.CMSG_CLEAR_TRADE_ITEM, WorldState.inWorld)
    void handleClearTradeItem(ref ByteReader reader)
    {
        const tradeSlot = reader.read!ubyte;
        if (tradeSide is null || tradeSlot >= tradeSlotCount)
            return;
        tradeSide.items[tradeSlot] = 0;
        if (tradeSlot == tradeSlotTradedCount)
            if (auto partner = tradePartner())
                partner.setTradeSpell(0, 0, 0);
        tradeChanged();
    }

    /// The money this side offers: checked when the trade goes through.
    @Handles(Opcode.CMSG_SET_TRADE_GOLD, WorldState.inWorld)
    void handleSetTradeGold(ref ByteReader reader)
    {
        const money = reader.read!uint;
        if (tradeSide is null || tradeSide.money == money)
            return;
        tradeSide.money = money;
        tradeChanged();
    }

    /// This side takes back its acceptance.
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

    /// This side accepts; when both have, the trade goes through.
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
        if (!player.canAfford(Copper(mine.money)))
        {
            sendTradeStatus(TradeStatus.closeWindow, 0, InventoryResult.notEnoughMoney);
            mine.accepted = false;
            return partner.sendTradeStatus(TradeStatus.backToTrade);
        }
        if (!partner.player.canAfford(Copper(his.money)))
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
        // The spells at the "will not be traded" items: still castable, or forgotten and the trade waits.
        if (!tradeSpellReady(partner) || !partner.tradeSpellReady(this))
            return;

        partner.sendTradeStatus(TradeStatus.tradeAccept);
        // Room for what each gets, counting what each gives away.
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
        // Each pays what it put up (checked above), then gets the other's.
        player.pay(Copper(mine.money));
        partner.player.pay(Copper(his.money));
        player.receive(Copper(his.money));
        partner.player.receive(Copper(mine.money));
        castTradeSpell(partner);
        partner.castTradeSpell(this);
        tradeSide = null;
        partner.tradeSide = null;
        flushInventory(true);
        partner.flushInventory(true);
        info!"%s: '%s' traded %s items and %s copper for %s items and %s copper with '%s'"(remoteAddress,
            player.data.name, myItems.length, mine.money, hisItems.length, his.money, partner.player.data.name);
        partner.sendTradeStatus(TradeStatus.tradeComplete);
        sendTradeStatus(TradeStatus.tradeComplete);
    }

    // -----------------------------------------------------------------------
    // Enchanting across the window (the "will not be traded" slot)
    // -----------------------------------------------------------------------

    package bool tradeSpellCompleting; /// the trade's spell is being cast as the trade goes through

    /// This side's spell at the other's "will not be traded" item (0: none), the item it is cast from; both sides see it.
    package void setTradeSpell(uint spell, ulong fromItem, uint fromEntry)
    {
        auto partner = tradePartner();
        if (partner is null || (tradeSide.spell == spell && tradeSide.spellItem == fromItem))
            return;
        tradeSide.spell = spell;
        tradeSide.spellItem = fromItem;
        tradeSide.spellItemEntry = fromEntry;
        tradeSide.accepted = false;
        partner.tradeSide.accepted = false;
        partner.sendUpdateTrade(true);
        sendUpdateTrade(false);
    }

    /**
     * A spell cast at the trade window (`Spell::CheckCast`, last): only while trading, at the "will not be traded"
     * slot; remembered for when the trade goes through (`dontReport`: nothing cast now).
     */
    package imported!"dmangos.world.spellcast".SpellCastResult tradeSpellCheck(
        const(imported!"dmangos.world.spells".SpellInfo)* spell, const ref imported!"dmangos.world.spellcast".SpellTargets targets,
        uint castItemEntry)
    {
        import dmangos.world.spellcast : SpellCastResult;

        if (tradeSpellCompleting)
            return SpellCastResult.ok;
        if (tradePartner() is null)
            return SpellCastResult.notTrading;
        if (targets.item != tradeSlotTradedCount)
            return SpellCastResult.itemNotReady;
        setTradeSpell(spell.id, castItemEntry ? usingItemGuid : 0, castItemEntry);
        return SpellCastResult.dontReport;
    }

    /// The trade's spell as the targets will have it: the other's "will not be traded" item, by its guid.
    private imported!"dmangos.world.spellcast".SpellTargets tradeSpellTargets(typeof(this) partner)
    {
        import dmangos.world.spellcast : SpellTargets, TargetFlags;

        auto t = SpellTargets(TargetFlags.tradeItem);
        t.item = partner.tradeSide.items[tradeSlotTradedCount];
        return t;
    }

    /// Whether this side's spell (if any) may be cast as the trade goes through; if not it is forgotten.
    private bool tradeSpellReady(typeof(this) partner)
    {
        import dmangos.world.spellcast : castResultPacket, SpellCastResult;

        if (!tradeSide.spell)
            return true;
        const spell = context.data.spells.spell(tradeSide.spell);
        auto targets = tradeSpellTargets(partner);
        bool ready = spell !is null && partner.itemByGuid(targets.item) !is null
            && (!tradeSide.spellItem || itemByGuid(tradeSide.spellItem) !is null);
        if (ready)
        {
            tradeSpellCompleting = true;
            scope (exit)
                tradeSpellCompleting = false;
            const result = checkCast(spell, targets, false, tradeSide.spellItemEntry, true);
            if (result != SpellCastResult.ok)
            {
                deliver(Opcode.SMSG_CAST_RESULT, castResultPacket(spell.id, result, spell));
                ready = false;
            }
        }
        if (!ready)
            setTradeSpell(0, 0, 0);
        return ready;
    }

    /// This side's spell, cast now at the other's item, at once and paying its costs.
    private void castTradeSpell(typeof(this) partner)
    {
        if (!tradeSide.spell)
            return;
        if (const spell = context.data.spells.spell(tradeSide.spell))
        {
            tradeSpellCompleting = true;
            scope (exit)
                tradeSpellCompleting = false;
            usingItemGuid = tradeSide.spellItem;
            castSpell(spell, tradeSpellTargets(partner), false, tradeSide.spellItemEntry);
            usingItemGuid = 0;
        }
    }

    /// An enchantment a spell puts on its item target: the caster's own, or (at the trade window) the other's.
    package void enchantTarget(const ref imported!"dmangos.world.spellcast".SpellTargets targets, uint enchantment,
        bool temporary, int durationSeconds)
    {
        import dmangos.world.spellcast : TargetFlags;

        if (!(targets.mask & TargetFlags.tradeItem))
            return enchantItem(targets.item, enchantment, temporary, durationSeconds);
        if (auto owner = tradePartner())
            owner.enchantItem(targets.item, enchantment, temporary, durationSeconds);
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
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : ImplicitTarget, SpellEffect;
    import dmangos.world.inventory : Item;
    import dmangos.world.updatefields : ITEM_FIELD_CREATOR;
    enum tailor = 96517;
    context.data.spells.spells[tailor] = testSpell(tailor, SpellEffect.createItem, ImplicitTarget.caster, 1);
    context.data.spells.spells.edit(tailor).itemType[0] = itemShirt;
    dest = null;
    assert(a.inventory.canStoreNew(nullBag, nullSlot, dest, itemShirt, 1) == InventoryResult.ok);
    anduin.session.inWorld.castTriggeredAt(tailor, a.guid);
    auto shirt = a.inventory[dest[0].pos];
    assert(shirt !is null && shirt.values.get!ITEM_FIELD_CREATOR == a.guid);
    anduin.read();
    jaina.read();
    a.receive(Copper(100));
    j.receive(Copper(100));

    ByteWriter target;
    target.put(j.guid);
    anduin.write(Opcode.CMSG_INITIATE_TRADE, target.data);
    assert(opcodesOf(jaina.read()) == [Opcode.SMSG_TRADE_STATUS], "Jaina is asked");
    jaina.write(Opcode.CMSG_BEGIN_TRADE, null);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_TRADE_STATUS));

    anduin.write(Opcode.CMSG_SET_TRADE_ITEM, [ubyte(0), jerky.bagSlot, jerky.slot]);
    anduin.write(Opcode.CMSG_SET_TRADE_ITEM, [ubyte(1), shirt.bagSlot, shirt.slot]);
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
    assert(a.money == Copper(70) && j.money == Copper(130));
    assert(jerky.guid in db.itemRows, "saved again under its taker");
    auto received = j.inventory.byGuid(shirt.fullGuid);
    assert(received !is null && received.values.get!ITEM_FIELD_CREATOR == a.guid);
    auto loaded = Item.load(db.itemRows[shirt.guid], shirt.proto, j.guid);
    assert(loaded.values.get!ITEM_FIELD_CREATOR == a.guid);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_TRADE_STATUS));
}

/// A trade requested across nodes uses the ordinary trade there, including cancellation and disconnect.
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.inventory : ItemRecord;
    import dmangos.world.player : Player;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto home = newCreationContext(db), owner = newCreationContext(db);
    auto now = MonoTime.currTime;
    home.clock = owner.clock = () => now;
    auto relay = new TestPlayerRelay(home, owner);
    const item = ItemRecord(0, 23, 500, itemJerky, 0, 0, 5);
    auto anduin = loggedIn(home, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f),
        setup: (ref c) { c.money = 100; c.items = [item]; });
    auto jaina = loggedIn(owner, db, 8, "Jaina", Position(-8945, -132, 83.5f),
        setup: (ref c) { c.money = 100; });
    auto j = cast(Player) jaina.session.character;
    home.map(0).replicaCreated(owner.nodeId, cellKeyAt(j.position.x, j.position.y), j.guid, encodePlayerState(j, 0));
    owner.regionOwnerAround = (uint, Position, float) => ushort(1);
    db.itemRows[item.guid] = item;
    db.itemOwners[item.guid] = 7;

    bool received(ref TestClient client, TradeStatus status)
    {
        foreach (packet; client.read())
            if (packet.opcode == Opcode.SMSG_TRADE_STATUS && ByteReader(packet.body_).read!uint == status)
                return true;
        return false;
    }

    ByteWriter target, fifty, twenty, accept;
    target.put(j.guid);
    fifty.put(50u);
    twenty.put(20u);
    accept.put(1u);
    anduin.write(Opcode.CMSG_INITIATE_TRADE, target.data);
    assert(relay.remote !is null && anduin.session.inWorld is null, "the requester moved");
    relay.remote.update(50.msecs);
    auto a = cast(Player) relay.remote.character;
    assert(received(jaina, TradeStatus.beginTrade));
    now += 11.seconds;
    assert(relay.remote.inWorld.migrationTarget() == 0 && jaina.session.inWorld.migrationTarget() == 0);
    jaina.write(Opcode.CMSG_BEGIN_TRADE, null);
    assert(received(anduin, TradeStatus.openWindow));
    anduin.write(Opcode.CMSG_SET_TRADE_ITEM, [ubyte(0), inventorySlotBag0, ubyte(23)]);
    anduin.write(Opcode.CMSG_SET_TRADE_GOLD, fifty.data);
    anduin.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    jaina.write(Opcode.CMSG_CANCEL_TRADE, null);
    assert(received(anduin, TradeStatus.tradeCanceled));
    assert(a.money == Copper(100) && j.money == Copper(100) && db.itemOwners[item.guid] == 7);
    assert(a.inventory.count(itemJerky) == 5 && j.inventory.count(itemJerky) == 0);
    assert(relay.remote.inWorld.migrationTarget() == home.nodeId);

    anduin.write(Opcode.CMSG_INITIATE_TRADE, target.data);
    assert(received(jaina, TradeStatus.beginTrade));
    jaina.write(Opcode.CMSG_BEGIN_TRADE, null);
    anduin.write(Opcode.CMSG_SET_TRADE_ITEM, [ubyte(0), inventorySlotBag0, ubyte(23)]);
    anduin.write(Opcode.CMSG_SET_TRADE_GOLD, fifty.data);
    jaina.write(Opcode.CMSG_SET_TRADE_GOLD, twenty.data);
    anduin.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    jaina.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    assert(received(anduin, TradeStatus.tradeComplete) && received(jaina, TradeStatus.tradeComplete));
    assert(a.inventory.count(itemJerky) == 0 && j.inventory.count(itemJerky) == 5);
    assert(a.money == Copper(70) && j.money == Copper(130));
    assert(db.itemOwners[item.guid] == 8 && db.moneySaves[7][0] == 70 && db.moneySaves[8][0] == 130);

    anduin.write(Opcode.CMSG_INITIATE_TRADE, target.data);
    assert(received(jaina, TradeStatus.beginTrade));
    jaina.write(Opcode.CMSG_BEGIN_TRADE, null);
    anduin.write(Opcode.CMSG_SET_TRADE_GOLD, fifty.data);
    anduin.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    jaina.session.clientGone();
    assert(received(anduin, TradeStatus.targetLogout));
    assert(a.money == Copper(70) && db.itemOwners[item.guid] == 8 && db.moneySaves[8][0] == 130);
}

/**
 * Anduin enchants Jaina's shirt in the "will not be traded" slot: the spell is kept and shown, not cast; it is cast
 * when the trade goes through, the reagent taken, and the shirt stays hers, enchanted. Not trading: refused.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.defines : nullBag, nullSlot;
    import dmangos.world.enchantments : EnchantmentEffect, EnchantmentType;
    import dmangos.world.inventory : InventoryResult, ItemPosCount;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : castResultPacket, SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : ITEM_FIELD_ENCHANTMENT;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint enchantShirt = 91_601, enchantment = 902;
    context.data.enchantmentEffects[enchantment] = [EnchantmentEffect(EnchantmentType.stat, 1, 7), EnchantmentEffect.init,
        EnchantmentEffect.init];
    context.data.spells.spells[enchantShirt] = testSpell(enchantShirt, SpellEffect.enchantItem, 0, 0);
    context.data.spells.spells.edit(enchantShirt).miscValue[0] = enchantment;
    context.data.spells.spells.edit(enchantShirt).reagents[0] = itemJerky;
    context.data.spells.spells.edit(enchantShirt).casting.reagentCount[0] = 1;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8945, -132, 83.5f));
    auto a = cast(Player) anduin.session.character, j = cast(Player) jaina.session.character;
    a.spells ~= enchantShirt;
    ItemPosCount[] dest;
    assert(a.inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 2) == InventoryResult.ok);
    a.inventory.storeNew(dest, itemJerky);
    dest = null;
    assert(j.inventory.canStoreNew(nullBag, nullSlot, dest, itemShirt, 1) == InventoryResult.ok);
    auto shirt = j.inventory.storeNew(dest, itemShirt);
    anduin.read();
    jaina.read();
    ubyte[] atTradeSlot()
    {
        ByteWriter w;
        w.put(enchantShirt);
        auto t = SpellTargets(TargetFlags.tradeItem);
        t.item = 6; // the "will not be traded" slot
        t.write(w);
        return w.data.dup;
    }

    // Not trading: "Tried to enchant a trade item, but not trading".
    anduin.write(Opcode.CMSG_CAST_SPELL, atTradeSlot());
    assert(bodyOf(anduin.read(), Opcode.SMSG_CAST_RESULT) == castResultPacket(enchantShirt, SpellCastResult.notTrading));

    ByteWriter target;
    target.put(j.guid);
    anduin.write(Opcode.CMSG_INITIATE_TRADE, target.data);
    jaina.write(Opcode.CMSG_BEGIN_TRADE, null);
    jaina.write(Opcode.CMSG_SET_TRADE_ITEM, [ubyte(6), shirt.bagSlot, shirt.slot]);
    anduin.read();
    jaina.read();

    // Cast at it: kept, not cast; both windows show it.
    anduin.write(Opcode.CMSG_CAST_SPELL, atTradeSlot());
    const mine = anduin.read();
    assert(bodyOf(mine, Opcode.SMSG_CAST_RESULT) == castResultPacket(enchantShirt, SpellCastResult.dontReport));
    assert(!opcodesOf(mine).canFind(Opcode.SMSG_SPELL_GO) && a.inventory.count(itemJerky) == 2);
    auto shown = ByteReader(bodyOf(jaina.read(), Opcode.SMSG_TRADE_STATUS_EXTENDED));
    assert(shown.read!ubyte == 1, "his side, as she sees it");
    shown.read!uint;
    shown.read!uint;
    shown.read!uint; // money
    assert(shown.read!uint == enchantShirt);

    // Both accept: cast now, the jerky taken, the shirt still hers and enchanted.
    ByteWriter accept;
    accept.put(1u);
    anduin.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    jaina.write(Opcode.CMSG_ACCEPT_TRADE, accept.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SPELL_GO));
    assert(a.inventory.count(itemJerky) == 1, "the reagent paid");
    assert(j.inventory.byGuid(shirt.fullGuid) is shirt && shirt.values.get!ITEM_FIELD_ENCHANTMENT(0) == enchantment);
}
