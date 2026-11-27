/**
 * The client's item requests, with vendor purchases, repairs and equip errors: moving, splitting,
 * equipping, destroying and banking items, setting ammo and buying bank bag slots; buying from
 * vendors, selling to them, buying back and repairing. Mixed into
 * `dmangos.world.character.Character`; the rules themselves are `dmangos.world.inventory`'s.
 *
 * Each request ends with `flushInventory`: the client is sent the items and fields that changed,
 * and the changed `character_inventory` and `item_instance` rows are saved at once, with the money
 * that paid for them. Saving each change at once, rather than with the character every few minutes,
 * keeps a crash from undoing a purchase or bringing a sold item back.
 *
 * Prices have the reputation's discount and the honor rank's.
 */
module dmangos.world.itemhandlers;

import dmangos.world.money : Copper;

/// See the module documentation.
mixin template ItemHandlers()
{
    import dmangos.world.money : Copper;
    import dmangos.world.database : LootAwardKey;
    import std.algorithm.searching : countUntil;
    import dmangos.log;
    import dmangos.world.creature : Creature, Npc;
    import dmangos.world.defines;
    import dmangos.world.inventory;
    import dmangos.world.npcdata : VendorItem;
    import dmangos.world.npchandlers : NpcFlag;
    import dmangos.world.objects : UpdateData;
    import dmangos.world.opcodes;
    import dmangos.world.player : Viewer;
    import dmangos.world.packets;
    import dmangos.world.updatefields;

private:
    /// `ERR_BANKSLOT_*`
    enum : uint
    {
        bankSlotFailedTooMany = 0,
        bankSlotInsufficientFunds = 1,
    }

    @property Inventory inventory()
    {
        return player.inventory;
    }

    /// Sends `SMSG_INVENTORY_CHANGE_FAILURE` for an error; `ok` sends nothing.
    void sendEquipError(const EquipError error)
    {
        if (!error)
            return;
        const levelError = error.result == InventoryResult.cantEquipLevel;
        uint requiredLevel;
        if (levelError)
        {
            const proto = error.item !is null ? error.item.proto : error.itemId in context.data.items;
            requiredLevel = proto is null ? 0 : proto.requiredLevel;
        }
        send(inventoryChangeFailure(error.result, levelError, requiredLevel,
            error.item is null ? 0 : error.item.fullGuid, error.other is null ? 0 : error.other.fullGuid,
            error.bagSlot));
    }

    /// ditto
    void sendEquipError(InventoryResult result, const Item item = null, const Item other = null, ubyte bagSlot = 0)
    {
        sendEquipError(EquipError(result, item, other, bagSlot));
    }

    /// Sends `SMSG_BUY_FAILED`.
    void sendBuyError(BuyResult result, const Npc vendor, size_t vendorSlot)
    {
        send(ServerBuyFailed(vendor is null ? 0 : vendor.guid, cast(uint) vendorSlot + 1, result));
    }

    /// Sends `SMSG_SELL_ITEM` with an error.
    void sendSellError(SellResult result, const Npc vendor, ulong item)
    {
        send(ServerSellItem(vendor is null ? 0 : vendor.guid, item, result));
    }

    /// "You receive item: ...". `received`: from an NPC; `created`: made ("You create: ..."); `showInChat`: a chat line.
    void sendNewItem(const Item item, uint count, bool received, bool created, bool showInChat = true)
    {
        send(ServerItemPushResult(player.guid, received, created, showInChat, item.bagSlot,
            item.count == count ? item.slot : uint.max, item.entry, 0,
            cast(int) item.values[ITEM_FIELD_RANDOM_PROPERTIES_ID], count));
    }

    /**
     * Sends what the request changed and saves it; see the module documentation. One
     * update carries it all: new and changed items, then the player's fields that point at them, then
     * the items gone.
     */
    package void flushInventory(bool moneyChanged = false,
        const imported!"dmangos.world.database".InstanceChestRecord chest = imported!"dmangos.world.database".InstanceChestRecord.init,
        const LootAwardKey award = LootAwardKey.init, bool alreadySaved = false,
        const imported!"dmangos.world.database".InstanceCorpseRecord corpse = imported!"dmangos.world.database".InstanceCorpseRecord.init,
        const imported!"dmangos.world.database".PickpocketRecord pocket = imported!"dmangos.world.database".PickpocketRecord.init)
    {
        if (inventory.equipmentChanged)
        {
            refreshEquipSpells(); // their equip spells on or off
            refreshEquipBoundPassives(); // the talents bound to a weapon or a shield
            player.refreshEquipmentStats(context.data);
        }
        if (inventory.justEquipped.length)
            applyEquipCooldowns();
        // Quest objectives that count items, first: a quest they complete changes the log's fields, which go
        // out in the same update as the items.
        if (inventory.hasChanges)
            questItemsChanged();
        UpdateData update;
        inventory.writeUpdates(update);
        player.addChanges(update, Viewer.self);
        inventory.writeForgotten(update);
        if (update.blockCount)
            sendUpdate(update);
        const changes = inventory.takeChanges();
        flushPlayerChanges(false);
        if (chest.spawn)
            context.database.saveChestAward(player.data.guid, player.money.amount, player.values[PLAYER_BYTES_2], changes, chest);
        else if (corpse.spawn)
            context.database.saveCorpseAward(player.data.guid, player.money.amount, player.values[PLAYER_BYTES_2], changes, corpse);
        else if (pocket.spawn)
            context.database.savePickpocketAward(player.data.guid, player.money.amount, player.values[PLAYER_BYTES_2], changes,
                pocket);
        else if (award.token)
            context.database.saveLootAward(award, 0, context.unixTime, player.money.amount, player.values[PLAYER_BYTES_2],
                changes);
        else if (!alreadySaved && (changes.length || moneyChanged))
            context.database.saveInventory(player.data.guid, player.money.amount, player.values[PLAYER_BYTES_2], changes);
        mailItemsAway();
    }

    /**
     * Items the inventory had no room for (`Inventory.toMail`: the off hand next to a two-hander), their rows now
     * deleted, are mailed to the player by itself, as CMaNGOS's `AutoUnequipOffhandIfNeed` does: "This item(s) has
     * problems with equipping/storing to inventory." (`mangos_string` 706), on the GM's stationery, at once.
     */
    void mailItemsAway()
    {
        import dmangos.log : info;
        import dmangos.world.database : MailRecord;

        enum uint stringNotEquipped = 706;
        enum ubyte stationeryGm = 61;
        enum uint mailCopied = 0x04;
        auto pending = inventory.toMail;
        inventory.toMail = null;
        foreach (record; pending)
        {
            context.database.saveLooseItem(record, player.data.guid);
            MailRecord mail;
            mail.stationery = stationeryGm;
            mail.sender = player.data.guid;
            mail.receiver = player.data.guid;
            mail.subject = context.data.serverStrings.get(stringNotEquipped, "");
            mail.checked = mailCopied;
            mail.itemGuid = record.guid;
            mail.itemEntry = record.entry;
            context.postOffice.postMail(mail, 0);
            info!"%s: '%s' had no room for item %s (guid %s); it was mailed"(remoteAddress, player.data.name,
                record.entry, record.guid);
        }
    }

    // -----------------------------------------------------------------------
    // Moving items
    // -----------------------------------------------------------------------

    /// Moves some of a stack to another slot.
    @Handles(Opcode.CMSG_SPLIT_ITEM, WorldState.inWorld)
    void handleSplitItem(const ClientSplitItem request)
    {
        const src = itemPos(request.srcBag, request.srcSlot), dst = itemPos(request.dstBag, request.dstSlot);
        if (src == dst || request.count == 0)
            return;
        if (!inventory.isValidPos(request.srcBag, request.srcSlot, true))
            return sendEquipError(InventoryResult.itemNotFound);
        if (!inventory.isValidPos(request.dstBag, request.dstSlot, false)) // may mean "anywhere"
            return sendEquipError(InventoryResult.itemDoesntGoToSlot);
        sendEquipError(inventory.split(src, dst, request.count));
        flushInventory();
    }

    /**
     * `CMSG_WRAP_ITEM`: an item wrapped in gift paper (a stack of `ITEM_FLAG_WRAPPER` paper, one used): it
     * becomes the wrapped gift (the paper's own wrapped kind), its own entry and flags kept in `character_gifts`
     * till it is opened. Not a bag, an equipped, bound, stackable, unique or already wrapped item, nor while
     * casting.
     */
    @Handles(Opcode.CMSG_WRAP_ITEM, WorldState.inWorld)
    void handleWrapItem(ref ByteReader reader)
    {
        import dmangos.world.inventory : itemDynFlagWrapped;

        enum uint itemFlagWrapper = 0x200;
        const giftBag = reader.read!ubyte, giftSlot = reader.read!ubyte;
        const itemBag = reader.read!ubyte, itemSlot = reader.read!ubyte;
        auto gift = inventory[giftBag, giftSlot];
        if (gift is null || !(gift.proto.flags & itemFlagWrapper) || gift.proto.stackable == 1)
            return sendEquipError(InventoryResult.itemNotFound);
        auto item = inventory[itemBag, itemSlot];
        if (item is null)
            return sendEquipError(InventoryResult.itemNotFound);
        if (item is gift || item.values.get!ITEM_FIELD_GIFTCREATOR)
            return sendEquipError(InventoryResult.wrappedCantBeWrapped);
        if (isEquipmentPos(item.pos))
            return sendEquipError(InventoryResult.equippedCantBeWrapped);
        if (item.contents.length)
            return sendEquipError(InventoryResult.bagsCantBeWrapped);
        if (item.bound)
            return sendEquipError(InventoryResult.boundCantBeWrapped);
        if (item.proto.stackable != 1)
            return sendEquipError(InventoryResult.stackableCantBeWrapped);
        if (item.proto.maxCount > 0)
            return sendEquipError(InventoryResult.uniqueCantBeWrapped);
        if (generic.active)
            return sendEquipError(InventoryResult.cantDoRightNow);
        // The paper's wrapped kind.
        uint wrapped = gift.entry;
        switch (wrapped)
        {
        case 5042: wrapped = 5043; break;
        case 5048: wrapped = 5044; break;
        case 17303: wrapped = 17302; break;
        case 17304: wrapped = 17305; break;
        case 17307: wrapped = 17308; break;
        case 21830: wrapped = 21831; break;
        default: break;
        }
        const to = wrapped in context.data.items;
        if (to is null)
            return sendEquipError(InventoryResult.itemNotFound);
        context.database.saveGift(player.data.guid, item.guid, item.entry, item.values[ITEM_FIELD_FLAGS]);
        item.changeEntry(to);
        item.values.set!ITEM_FIELD_GIFTCREATOR(player.guid);
        item.values.set!ITEM_FIELD_FLAGS(itemDynFlagWrapped);
        inventory.setState(item, ItemState.changed);
        uint one = 1;
        inventory.destroyCount(gift, one);
        flushInventory();
    }

    /// Between two of the character's own slots.
    @Handles(Opcode.CMSG_SWAP_INV_ITEM, WorldState.inWorld)
    void handleSwapInvItem(const ClientSwapInvItem request)
    {
        if (request.srcSlot == request.dstSlot)
            return;
        if (!inventory.isValidPos(inventorySlotBag0, request.srcSlot, true))
            return sendEquipError(InventoryResult.itemNotFound);
        if (!inventory.isValidPos(inventorySlotBag0, request.dstSlot, true))
            return sendEquipError(InventoryResult.itemDoesntGoToSlot);
        sendEquipError(inventory.swap(itemPos(inventorySlotBag0, request.srcSlot),
            itemPos(inventorySlotBag0, request.dstSlot)));
        flushInventory();
    }

    /// Moves an item between any two slots, bags included.
    @Handles(Opcode.CMSG_SWAP_ITEM, WorldState.inWorld)
    void handleSwapItem(const ClientSwapItem request)
    {
        const src = itemPos(request.srcBag, request.srcSlot), dst = itemPos(request.dstBag, request.dstSlot);
        if (src == dst)
            return;
        if (!inventory.isValidPos(request.srcBag, request.srcSlot, true))
            return sendEquipError(InventoryResult.itemNotFound);
        if (!inventory.isValidPos(request.dstBag, request.dstSlot, true))
            return sendEquipError(InventoryResult.itemDoesntGoToSlot);
        sendEquipError(inventory.swap(src, dst));
        flushInventory();
    }

    /// An item dragged onto an equipment slot.
    @Handles(Opcode.CMSG_AUTOEQUIP_ITEM_SLOT, WorldState.inWorld)
    void handleAutoEquipItemSlot(const ClientAutoEquipItemSlot request)
    {
        if (!isEquipmentPos(inventorySlotBag0, request.dstSlot))
            return;
        auto item = inventory.byGuid(request.item);
        const dst = itemPos(inventorySlotBag0, request.dstSlot);
        if (item is null || item.pos == dst)
            return;
        sendEquipError(inventory.swap(item.pos, dst));
        flushInventory();
    }

    /// Right-clicking an item to wear it.
    @Handles(Opcode.CMSG_AUTOEQUIP_ITEM, WorldState.inWorld)
    void handleAutoEquipItem(const ClientItemPos request)
    {
        auto source = inventory[request.bag, request.slot];
        if (source is null)
            return;
        ushort dest;
        if (const result = inventory.canEquip(nullSlot, dest, source, !source.isBag))
            return sendEquipError(result, source);
        const src = source.pos;
        if (dest == src)
            return;

        auto worn = inventory[dest];
        if (worn is null)
        {
            inventory.remove(request.bag, request.slot);
            inventory.equip(dest, source);
            inventory.autoUnequipOffhand(request.bag);
        }
        else
        {
            // What is worn goes where the new item was: that slot, that bag, or anywhere.
            const wornBag = worn.bagSlot, wornSlot = worn.slot;
            if (const result = inventory.canUnequip(dest, !source.isBag))
                return sendEquipError(result, worn);
            ItemPosCount[] storeDest;
            ushort equipDest;
            ubyte bagSlot;
            InventoryResult result;
            if (isInventoryPos(src) || isBankPos(src))
            {
                // Each try starts afresh, without the positions a failed try found.
                const ubyte[2][3] tries = [[request.bag, request.slot], [request.bag, nullSlot], [nullBag, nullSlot]];
                foreach (attempt; tries)
                {
                    storeDest = null;
                    result = isInventoryPos(src) ? inventory.canStore(attempt[0], attempt[1], storeDest, worn, true, bagSlot)
                        : inventory.canBank(attempt[0], attempt[1], storeDest, worn, true, bagSlot);
                    if (result == InventoryResult.ok)
                        break;
                }
            }
            else if (isEquipmentPos(src))
            {
                result = inventory.canEquip(request.slot, equipDest, worn, true);
                if (result == InventoryResult.ok)
                    result = inventory.canUnequip(equipDest, true);
            }
            if (result != InventoryResult.ok)
                return sendEquipError(result, worn, source, bagSlot);

            inventory.remove(wornBag, wornSlot);
            inventory.remove(request.bag, request.slot);
            inventory.equip(dest, source);
            if (isInventoryPos(src) || isBankPos(src))
                inventory.store(storeDest, worn);
            else if (isEquipmentPos(src))
                inventory.equip(equipDest, worn);
            inventory.autoUnequipOffhand(request.bag);
        }
        flushInventory();
        if (isBagPos(dest))
            send(ServerOpenContainer(source.fullGuid));
    }

    /// Destroys an item, or `count` of its stack.
    @Handles(Opcode.CMSG_DESTROYITEM, WorldState.inWorld)
    void handleDestroyItem(const ClientDestroyItem request)
    {
        const pos = itemPos(request.bag, request.slot);
        if (isEquipmentPos(pos) || isBagPos(pos))
            if (const result = inventory.canUnequip(pos, false))
                return sendEquipError(result, inventory[pos]);
        auto item = inventory[request.bag, request.slot];
        if (item is null)
            return sendEquipError(InventoryResult.itemNotFound);
        if (item.proto.flags & itemFlagNoUserDestroy)
            return sendEquipError(InventoryResult.cantDropSoulbound);
        if (request.count)
        {
            uint count = request.count;
            inventory.destroyCount(item, count);
        }
        else
            inventory.destroy(request.bag, request.slot);
        flushInventory();
    }

    /// An item dropped onto a bag.
    @Handles(Opcode.CMSG_AUTOSTORE_BAG_ITEM, WorldState.inWorld)
    void handleAutoStoreBagItem(const ClientAutoStoreBagItem request)
    {
        auto item = inventory[request.srcBag, request.srcSlot];
        if (item is null)
            return;
        if (!inventory.isValidPos(request.dstBag, nullSlot, false))
            return sendEquipError(InventoryResult.itemDoesntGoToSlot);
        const src = item.pos;
        if (isEquipmentPos(src) || isBagPos(src))
            if (const result = inventory.canUnequip(src, !isBagPos(src)))
                return sendEquipError(result, item);
        ItemPosCount[] dest;
        ubyte bagSlot;
        if (const result = inventory.canStore(request.dstBag, nullSlot, dest, item, false, bagSlot))
            return sendEquipError(result, item, null, bagSlot);
        if (dest.length == 1 && dest[0].pos == src) // already there
            return sendEquipError(InventoryResult.none, item);
        inventory.remove(request.srcBag, request.srcSlot);
        inventory.store(dest, item);
        flushInventory();
    }

    /// Right-clicking a carried item at the bank.
    @Handles(Opcode.CMSG_AUTOBANK_ITEM, WorldState.inWorld)
    void handleAutoBankItem(const ClientItemPos request)
    {
        auto item = inventory[request.bag, request.slot];
        if (item is null)
            return;
        ItemPosCount[] dest;
        ubyte bagSlot;
        if (const result = inventory.canBank(nullBag, nullSlot, dest, item, false, bagSlot))
            return sendEquipError(result, item, null, bagSlot);
        if (dest.length == 1 && dest[0].pos == item.pos)
            return sendEquipError(InventoryResult.none, item);
        inventory.remove(request.bag, request.slot);
        inventory.store(dest, item);
        flushInventory();
    }

    /// Right-clicking a banked item, or a carried one.
    @Handles(Opcode.CMSG_AUTOSTORE_BANK_ITEM, WorldState.inWorld)
    void handleAutoStoreBankItem(const ClientItemPos request)
    {
        auto item = inventory[request.bag, request.slot];
        if (item is null)
            return;
        ItemPosCount[] dest;
        ubyte bagSlot;
        const result = isBankPos(request.bag, request.slot)
            ? inventory.canStore(nullBag, nullSlot, dest, item, false, bagSlot)
            : inventory.canBank(nullBag, nullSlot, dest, item, false, bagSlot);
        if (result != InventoryResult.ok)
            return sendEquipError(result, item, null, bagSlot);
        inventory.remove(request.bag, request.slot);
        inventory.store(dest, item);
        flushInventory();
    }

    /// Sets the ammo the character shoots (0: none).
    @Handles(Opcode.CMSG_SET_AMMO, WorldState.inWorld)
    void handleSetAmmo(const ClientSetAmmo request)
    {
        if (!player.alive)
            return sendEquipError(InventoryResult.youAreDead);
        if (request.item == 0)
            player.values.set!PLAYER_AMMO_ID(0u);
        else
        {
            if (player.values[PLAYER_AMMO_ID] == request.item)
                return;
            if (const result = inventory.canUseAmmo(request.item))
                return sendEquipError(EquipError(result, null, null, 0, request.item));
            player.values.set!PLAYER_AMMO_ID(request.item);
        }
        player.refreshEquipmentStats(context.data); // the ammunition's damage in the ranged damage
        flushPlayerChanges();
    }

    /// Buys the next bank bag slot.
    @Handles(Opcode.CMSG_BUY_BANK_SLOT, WorldState.inWorld)
    void handleBuyBankSlot(const ClientNpcGuid request)
    {
        // The banker must be near. No GM command opens the bank from afar, so the player's own guid is not accepted.
        if (interactableNpc(request.guid, NpcFlag.banker) is null)
            return;
        const slot = inventory.bankBagSlots + 1;
        if (slot > bankBagSlotEnd - bankBagSlotStart)
            return;
        const price = context.client.bankBagSlotPrices.lookup(slot);
        if (price is null)
            return send(ServerBuyBankSlotResult(bankSlotFailedTooMany));
        if (!player.canAfford(Copper(price.price)))
            return send(ServerBuyBankSlotResult(bankSlotInsufficientFunds));
        inventory.bankBagSlots = cast(ubyte) slot;
        player.pay(Copper(price.price));
        flushInventory(true);
    }

    // -----------------------------------------------------------------------
    // Vendors
    // -----------------------------------------------------------------------

    /// Sells an item, or `count` of its stack, to a vendor; it waits in a buyback slot.
    @Handles(Opcode.CMSG_SELL_ITEM, WorldState.inWorld)
    void handleSellItem(const ClientSellItem request)
    {
        if (request.item == 0)
            return;
        auto vendor = interactableNpc(request.vendor, NpcFlag.vendor);
        if (vendor is null)
            return sendSellError(SellResult.cantFindVendor, null, request.item);
        auto item = inventory.byGuid(request.item);
        if (item is null)
            return;
        if (item.owner != player.guid)
            return sendSellError(SellResult.youDontOwnThatItem, vendor, request.item);
        if (item.isBag && !item.isEmpty) // dragged onto the vendor's list
            return sendSellError(SellResult.onlyEmptyBag, vendor, request.item);
        uint count = request.count;
        if (count == 0) // "sell all"
            count = item.count;
        else if (count > item.count)
            return sendSellError(SellResult.cantSellItem, vendor, request.item);
        if (item.proto.details.sellPrice == 0)
            return sendSellError(SellResult.cantSellItem, vendor, request.item);

        const money = item.sellPrice(baseRepairCost(item, context.client)) * count;
        if (count < item.count)
        {
            auto sold = inventory.cloneOf(item, count);
            if (sold is null)
            {
                error!"could not copy item %s to sell %s of them"(item.entry, count);
                return sendSellError(SellResult.cantSellItem, vendor, request.item);
            }
            item.count = item.count - count;
            inventory.setState(item, ItemState.changed);
            inventory.addToBuyback(sold, money, secondsInWorld);
        }
        else
        {
            inventory.remove(item.bagSlot, item.slot);
            inventory.addToBuyback(item, money, secondsInWorld);
        }
        player.receive(Copper(money));
        flushInventory(true);
    }

    /// Buys back an item sold.
    @Handles(Opcode.CMSG_BUYBACK_ITEM, WorldState.inWorld)
    void handleBuybackItem(const ClientBuybackItem request)
    {
        auto vendor = interactableNpc(request.vendor, NpcFlag.vendor);
        if (vendor is null)
            return sendSellError(SellResult.cantFindVendor, null, 0);
        auto item = inventory.buyback(request.slot);
        if (item is null)
            return sendBuyError(BuyResult.cantFindItem, vendor, 0);
        const price = Copper(inventory.buybackPrice(request.slot));
        if (!player.canAfford(price))
            return sendBuyError(BuyResult.notEnoughMoney, vendor, request.slot);
        ItemPosCount[] dest;
        ubyte bagSlot;
        if (const result = inventory.canStore(nullBag, nullSlot, dest, item, false, bagSlot))
            return sendEquipError(result, item, null, bagSlot);
        player.pay(price);
        inventory.removeFromBuyback(request.slot, false);
        inventory.store(dest, item);
        flushInventory(true);
    }

    /// Buys into the first place that holds it.
    @Handles(Opcode.CMSG_BUY_ITEM, WorldState.inWorld)
    void handleBuyItem(const ClientBuyItem request)
    {
        buyItemFromVendor(request.vendor, request.item, request.count, nullBag, nullSlot);
    }

    /// Buys an item dragged from the vendor into a slot.
    @Handles(Opcode.CMSG_BUY_ITEM_IN_SLOT, WorldState.inWorld)
    void handleBuyItemInSlot(const ClientBuyItemInSlot request)
    {
        ubyte bag = nullBag; // an unknown bag guid
        if (request.bag == player.guid)
            bag = inventorySlotBag0;
        else
            foreach (ubyte i; inventorySlotBagStart .. inventorySlotBagEnd)
                if (const container = inventory[inventorySlotBag0, i])
                    if (container.fullGuid == request.bag)
                    {
                        bag = i;
                        break;
                    }
        if (bag == nullBag)
            return;
        buyItemFromVendor(request.vendor, request.item, request.count, bag, request.slot);
    }

    /// Limited stock reserved on the node simulating a vendor this node serves through a stand-in.
    static struct StockReservation
    {
        bool held;
        ushort owner;      /// the node simulating the vendor
        uint map;
        uint maxCount;     /// the item's limit, and how many were reserved: what goes back if unused
        uint count;
        uint left;         /// what the vendor has left
    }

    /**
     * Buys `count` times the item's buy count, into `bag` and `slot` if given.
     * A limited item of a vendor another node simulates is reserved there first, and the purchase goes
     * on when the answer comes (`reserved`); stock it reserved but did not use goes back.
     */
    void buyItemFromVendor(ulong vendorGuid, uint entry, ubyte count, ubyte bag, ubyte slot,
        StockReservation reserved = StockReservation.init)
    {
        import dmangos.world.creature : NpcStandIn;

        bool used;
        scope (exit)
            if (reserved.held && !used && context.releaseStock !is null)
                context.releaseStock(reserved.owner, reserved.map, vendorGuid, entry, reserved.maxCount, reserved.count);
        if (count < 1)
            count = 1;
        if (player is null || !player.alive)
            return;
        const proto = entry in context.data.items;
        if (proto is null)
            return sendBuyError(BuyResult.cantFindItem, null, 0);
        auto vendor = interactableNpc(vendorGuid, NpcFlag.vendor);
        if (vendor is null)
            return sendBuyError(BuyResult.distanceTooFar, null, 0);
        const wares = vendorItems(vendor);
        if (wares.length == 0)
            return sendBuyError(BuyResult.cantFindItem, vendor, 0);
        const vendorSlot = wares.countUntil!(ware => ware.item == entry);
        if (vendorSlot < 0)
            return sendBuyError(BuyResult.cantFindItem, vendor, 0);
        const ware = wares[vendorSlot];
        if (!canSeeVendorItem(vendor, ware, *proto))
            return sendBuyError(BuyResult.cantFindItem, vendor, vendorSlot);

        const totalCount = proto.buyCount * count;
        const now = context.unixTime;
        auto standIn = cast(NpcStandIn) vendor;
        if (ware.maxCount != 0 && standIn !is null && context.reserveStock !is null && !reserved.held)
        {
            // The stock is the creature's node's to count: ask it, and buy when it answers.
            auto reservation = StockReservation(true, standIn.owner, player.data.map, ware.maxCount, totalCount);
            context.reserveStock(reservation.owner, reservation.map, vendorGuid, entry, ware.maxCount, ware.incrTime,
                proto.buyCount, totalCount, (bool ok, uint left) {
                    if (!ok)
                    {
                        if (player !is null)
                            sendBuyError(BuyResult.itemAlreadySold, null, 0);
                        return;
                    }
                    reservation.left = left;
                    buyItemFromVendor(vendorGuid, entry, count, bag, slot, reservation);
                });
            return;
        }
        if (ware.maxCount != 0 && !reserved.held
            && vendor.vendorItemCount(entry, ware.maxCount, ware.incrTime, proto.buyCount, now) < totalCount)
            return sendBuyError(BuyResult.itemAlreadySold, vendor, vendorSlot);
        // The reputation it needs, and the honor rank (the highest reached, and the level too).
        if (proto.requiredReputationFaction && player.reputation !is null
            && player.reputation.rankWith(proto.requiredReputationFaction) < proto.requiredReputationRank)
            return sendBuyError(BuyResult.reputationRequired, vendor, vendorSlot);
        if (proto.requiredHonorRank && (player.highestHonorRank < proto.requiredHonorRank
            || player.data.level < proto.requiredLevel))
            return sendBuyError(BuyResult.rankRequired, vendor, vendorSlot);
        import std.math : floor;

        const price = Copper(cast(uint) floor(proto.details.buyPrice * count * buyPriceDiscount(vendor.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE)));
        if (!player.canAfford(price))
            return sendBuyError(BuyResult.notEnoughMoney, vendor, vendorSlot);

        Item item;
        if ((bag == nullBag && slot == nullSlot) || isInventoryPos(bag, slot))
        {
            ItemPosCount[] dest;
            if (const result = inventory.canStoreNew(bag, slot, dest, entry, totalCount))
                return sendEquipError(EquipError(result, null, null, 0, entry));
            player.pay(price);
            item = inventory.storeNew(dest, entry);
        }
        else if (isEquipmentPos(bag, slot))
        {
            if (totalCount != 1)
                return sendEquipError(InventoryResult.itemCantBeEquipped);
            ushort dest;
            if (const result = inventory.canEquipNew(slot, dest, entry, false))
                return sendEquipError(EquipError(result, null, null, 0, entry));
            player.pay(price);
            item = inventory.equipNew(dest, entry);
            if (item !is null)
                inventory.autoUnequipOffhand();
        }
        else
            return sendEquipError(InventoryResult.itemDoesntGoToSlot);
        if (item is null)
            return flushInventory(true);

        used = true;
        const left = reserved.held ? reserved.left
            : vendor.takeVendorItems(entry, ware.maxCount, ware.incrTime, proto.buyCount, totalCount, now);
        send(ServerBuyItem(vendor.guid, cast(uint) vendorSlot + 1, ware.maxCount > 0 ? left : uint.max, totalCount));
        sendNewItem(item, totalCount, true, false);
        flushInventory(true);
    }

    // -----------------------------------------------------------------------
    // Repairs
    // -----------------------------------------------------------------------

    /// Repairs one item, or everything carried and worn.
    @Handles(Opcode.CMSG_REPAIR_ITEM, WorldState.inWorld)
    void handleRepairItem(const ClientRepairItem request)
    {
        auto npc = interactableNpc(request.npc, NpcFlag.repair);
        if (npc is null)
            return;
        const discount = repairDiscount(npc.npcValues.get!UNIT_FIELD_FACTIONTEMPLATE,
            (npc.npcValues.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0);
        if (request.item)
        {
            if (auto item = inventory.byGuid(request.item))
                durabilityRepair(item.pos, true, discount);
        }
        else
            durabilityRepairAll(true, discount);
        flushInventory(true);
    }

    /// Repairs what is worn, in the backpack, the bags themselves and what is in them.
    void durabilityRepairAll(bool cost, float discount)
    {
        foreach (ubyte i; 0 .. inventorySlotItemEnd)
            durabilityRepair(itemPos(inventorySlotBag0, i), cost, discount);
        foreach (ubyte bag; inventorySlotBagStart .. inventorySlotBagEnd)
            foreach (ubyte i; 0 .. maxBagSize)
                durabilityRepair(itemPos(bag, i), cost, discount);
    }

    /// Back to full durability, paid for if `cost` and the player has the money.
    void durabilityRepair(ushort pos, bool cost, float discount)
    {
        auto item = inventory[pos];
        if (item is null || (item.values[ITEM_FIELD_FLAGS] & itemDynFlagWrapped) || item.maxDurability == 0)
            return;
        const wasBroken = item.durability == 0;
        if (cost)
        {
            const price = repairCost(item, context.client, discount);
            if (price > 0)
            {
                if (!player.canAfford(Copper(price)))
                    return;
                player.pay(Copper(price));
            }
        }
        item.values.set!ITEM_FIELD_DURABILITY(item.maxDurability);
        inventory.setState(item, ItemState.changed);
        if (isEquipmentPos(pos) && wasBroken) // a broken worn item gives its stats again
            inventory.equipmentChanged = true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.bytes : ByteReader;
    import dmangos.serialization : deserialize;
    import dmangos.world.defines;
    import dmangos.world.inventory;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.packets;
    import dmangos.world.player : CharacterData;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;
    import dmangos.auth.accounts : AccountLevel;

    private T packet(T)(const(ServerPacketRead)[] packets)
    {
        auto reader = ByteReader(bodyOf(packets, T.opcode));
        return deserialize!T(reader);
    }
}

/// Buying, wearing, splitting, selling, buying back and destroying, each saved as it happens.
unittest
{
    import std.algorithm.searching : canFind;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    void setup(ref CharacterData c)
    {
        c.money = 1000;
        c.items = [ItemRecord(0, 23, 500, itemSword, 0, 0, 1, 0, "", 0, "", 0, 20)];
    }

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 1, &setup);
    anduin.read();
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    const character = anduin.session.character;
    const inventory = character.inventory;
    enum ubyte bag0 = inventorySlotBag0;

    // Two lots of five jerky, 25 copper a lot.
    anduin.write(Opcode.CMSG_BUY_ITEM, ClientBuyItem(innkeeper, itemJerky, 2, 1));
    const bought = anduin.read();
    const receipt = packet!ServerBuyItem(bought);
    assert(receipt.vendorSlot == 1 && receipt.newCount == uint.max && receipt.count == 10);
    const pushed = packet!ServerItemPushResult(bought);
    assert(pushed.entry == itemJerky && pushed.count == 10 && pushed.slot == 24 && pushed.bag == bag0);
    auto jerky = inventory[bag0, 24];
    assert(jerky.count == 10 && character.money == Copper(950));
    assert(db.itemRows[jerky.guid].count == 10 && db.itemOwners[jerky.guid] == 7 && db.moneySaves[7][0] == 950);

    // The sword, right-clicked, is worn; its row follows it.
    anduin.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(bag0, 23));
    anduin.read();
    assert(inventory.equipped(equipmentSlotMainhand).guid == 500 && inventory[bag0, 23] is null);
    assert(db.itemRows[500].slot == equipmentSlotMainhand);
    assert(character.values[PLAYER_VISIBLE_ITEM_1_0 + equipmentSlotMainhand * visibleItemStride] == itemSword);

    // Jerky cannot be worn on the head.
    anduin.write(Opcode.CMSG_SWAP_INV_ITEM, ClientSwapInvItem(24, equipmentSlotHead));
    const refused = packet!ServerInventoryChangeFailure(anduin.read());
    assert(refused.result == InventoryResult.itemCantBeEquipped && refused.details.length == 17);

    // Four of the ten split off to the last backpack slot.
    anduin.write(Opcode.CMSG_SPLIT_ITEM, ClientSplitItem(bag0, 24, bag0, 38, 4));
    anduin.read();
    auto four = inventory[bag0, 38];
    assert(jerky.count == 6 && four.count == 4);
    assert(db.itemRows[jerky.guid].count == 6 && db.itemRows[four.guid].count == 4 && db.itemRows[four.guid].slot == 38);

    // Sold for a copper each; its rows go until it is bought back.
    const fourGuid = four.guid;
    anduin.write(Opcode.CMSG_SELL_ITEM, ClientSellItem(innkeeper, four.fullGuid, 0));
    anduin.read();
    assert(inventory[bag0, 38] is null && inventory.buyback(buybackSlotStart).guid == fourGuid);
    assert(character.money == Copper(954) && fourGuid !in db.itemRows && db.moneySaves[7][0] == 954);
    anduin.write(Opcode.CMSG_BUYBACK_ITEM, ClientBuybackItem(innkeeper, buybackSlotStart));
    anduin.read();
    assert(character.money == Copper(950) && inventory.buyback(buybackSlotStart) is null);
    assert(jerky.count == 10 && db.itemRows[jerky.guid].count == 10, "bought back onto the stack it came from");

    // Three thrown away, then the rest.
    const jerkyGuid = jerky.guid;
    anduin.write(Opcode.CMSG_DESTROYITEM, ClientDestroyItem(bag0, 24, 3, [0, 0, 0]));
    anduin.read();
    assert(jerky.count == 7 && db.itemRows[jerkyGuid].count == 7);
    anduin.write(Opcode.CMSG_DESTROYITEM, ClientDestroyItem(bag0, 24, 0, [0, 0, 0]));
    const destroyed = anduin.read();
    assert(inventory[bag0, 24] is null && jerkyGuid !in db.itemRows);
    assert(opcodesOf(destroyed).canFind!(op => op == Opcode.SMSG_UPDATE_OBJECT
        || op == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT), "one update: the slot cleared, the item forgotten");

    // Too far from the vendor, and too poor.
    anduin.write(Opcode.CMSG_BUY_ITEM, ClientBuyItem(innkeeper, itemJerky, 255, 1));
    assert(packet!ServerBuyFailed(anduin.read()).result == BuyResult.notEnoughMoney);
    anduin.write(Opcode.CMSG_BUY_ITEM, ClientBuyItem(makeGuid(HighGuid.unit, creatureWillem, 79942), itemJerky, 1, 1));
    assert(packet!ServerBuyFailed(anduin.read()).result == BuyResult.distanceTooFar);

    // The bank's bag slots have no prices in the test data: none can be bought.
    anduin.write(Opcode.CMSG_BUY_BANK_SLOT, ClientNpcGuid(makeGuid(HighGuid.unit, creatureBanker, bankerSpawn)));
    assert(packet!ServerBuyBankSlotResult(anduin.read()).result == 0);
}

/// Limited stock of a vendor another node simulates: reserved there, used, refused or given back.
unittest
{
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.npcdata : VendorItem;
    import dmangos.world.replication : encodeState, Replicable;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.npcs.vendors[creatureInnkeeper] = [VendorItem(itemJerky, 3, 600, 0, 0)]; // three lots, then sold out
    void setup(ref CharacterData c)
    {
        c.money = 60;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 1, &setup);
    anduin.read();

    // The innkeeper is node 2's now: this node holds a replica of it.
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto map = context.map(0);
    auto spawned = cast(Replicable) map.findObject(innkeeper);
    const state = encodeState(spawned, 0);
    const home = cellKeyAt(-8951, -130);
    map.release((ulong cell) => cell == home);
    map.replicaCreated(owner: 2, cell: home, guid: innkeeper, state);
    anduin.read();

    // Node 2 has two lots left: it reserves one, and the purchase goes on with what it says is left.
    struct Asked { ushort owner; uint wanted; void delegate(bool, uint) then; }
    Asked asked;
    uint[] released;
    context.reserveStock = (ushort owner, uint, ulong, uint, uint, uint, uint, uint wanted, void delegate(bool, uint) then) {
        asked = Asked(owner, wanted, then);
    };
    context.releaseStock = (ushort, uint, ulong, uint, uint, uint count) { released ~= count; };
    anduin.write(Opcode.CMSG_LIST_INVENTORY, ClientNpcGuid(innkeeper));
    assert(!anduin.read().length && asked.owner == 2 && asked.wanted == 0);
    auto earlierList = asked.then;
    anduin.write(Opcode.CMSG_LIST_INVENTORY, ClientNpcGuid(innkeeper));
    earlierList(true, 2);
    assert(!anduin.read().length, "an old stock reply cannot replace a later list");
    asked.then(true, 1);
    const list = packet!ServerListInventory(anduin.read());
    assert(list.items.length == 1 && list.items[0].available == 1 && !released.length);

    anduin.write(Opcode.CMSG_BUY_ITEM, ClientBuyItem(innkeeper, itemJerky, 1, 1));
    assert(anduin.read().length == 0 && asked.owner == 2 && asked.wanted == 5, "nothing until node 2 answers");
    asked.then(true, 1);
    const receipt = packet!ServerBuyItem(anduin.read());
    assert(receipt.newCount == 1 && anduin.session.character.money == Copper(35));

    // Sold out there: refused.
    anduin.write(Opcode.CMSG_BUY_ITEM, ClientBuyItem(innkeeper, itemJerky, 1, 1));
    asked.then(false, 0);
    assert(packet!ServerBuyFailed(anduin.read()).result == BuyResult.itemAlreadySold && released.length == 0);

    // Two lots reserved, but 35 copper does not pay for them (50): the reservation goes back.
    anduin.write(Opcode.CMSG_BUY_ITEM, ClientBuyItem(innkeeper, itemJerky, 2, 1));
    asked.then(true, 0);
    assert(packet!ServerBuyFailed(anduin.read()).result == BuyResult.notEnoughMoney);
    assert(released == [10], "two lots of five back to node 2");
}

/// Gift wrapping: an item wrapped in paper becomes the gift (the paper used); opened, it is itself again.
unittest
{
    import dmangos.world.inventory : itemDynFlagWrapped;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    import dmangos.world.worlddata : ItemTemplate;

    ItemTemplate paper = cast() context.data.items[itemJerky];
    paper.entry = 5042;
    paper.flags = 0x200;
    paper.stackable = 20;
    context.data.items[5042] = paper;
    ItemTemplate gift = paper;
    gift.entry = 5043;
    gift.flags = 0;
    gift.stackable = 1;
    context.data.items[5043] = gift;
    void setup(ref CharacterData c)
    {
        c.items = [ItemRecord(0, 23, 500, itemSword, 0, 0, 1, 0, "", 0, "", 0, 20),
            ItemRecord(0, 24, 501, 5042, 0, 0, 3, 0, "", 0, "", 0, 0)];
    }

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 1, &setup);
    anduin.read();
    enum ubyte bag0 = inventorySlotBag0;
    const inventory = anduin.session.character.inventory;

    // Paper cannot wrap itself.
    anduin.write(Opcode.CMSG_WRAP_ITEM, cast(const(ubyte)[]) [bag0, ubyte(24), bag0, ubyte(24)]);
    assert(packet!ServerInventoryChangeFailure(anduin.read()).result == InventoryResult.wrappedCantBeWrapped);

    anduin.write(Opcode.CMSG_WRAP_ITEM, cast(const(ubyte)[]) [bag0, ubyte(24), bag0, ubyte(23)]);
    anduin.read();
    auto wrapped = inventory[bag0, 23];
    assert(wrapped.guid == 500 && wrapped.entry == 5043 && (wrapped.values[ITEM_FIELD_FLAGS] & itemDynFlagWrapped));
    assert(inventory[bag0, 24].count == 2, "a sheet of paper used");
    assert(db.giftRows[500] == [itemSword, 0], "what is inside, kept");

    // Wrapped, it cannot be wrapped again.
    anduin.write(Opcode.CMSG_WRAP_ITEM, cast(const(ubyte)[]) [bag0, ubyte(24), bag0, ubyte(23)]);
    assert(packet!ServerInventoryChangeFailure(anduin.read()).result == InventoryResult.wrappedCantBeWrapped);

    // Opened: the sword again.
    anduin.write(Opcode.CMSG_OPEN_ITEM, cast(const(ubyte)[]) [bag0, ubyte(23)]);
    anduin.read();
    assert(inventory[bag0, 23].entry == itemSword && !inventory[bag0, 23].values.get!ITEM_FIELD_GIFTCREATOR);
    assert(500 !in db.giftRows && db.itemRows[500].entry == itemSword);
}
