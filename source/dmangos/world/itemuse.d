/**
 * What using, wearing and carrying an item does to it, mixed into `dmangos.world.character.Character`,
 * as CMaNGOS does it:
 *
 * $(UL
 * $(LI Using an item (`CMSG_USE_ITEM`): one that is worn must be worn, the player must be able to use it
 *   (`Inventory.canUse`: class, skill, reputation, ...), and one whose spells may not be cast in combat is
 *   refused in combat (`EQUIP_ERR_NOT_IN_COMBAT`). Used, an item that binds on use (and one that binds on
 *   pickup or is a quest item, given by a game master unbound) is bound (`HandleUseItemOpcode`).)
 * $(LI Its spell charges (`ITEM_FIELD_SPELL_CHARGES`): each use takes one off the spell's charges (towards 0
 *   from either side; an item that stacks keeps its template's). Out of charges, an item whose charges are
 *   negative (it is used up) is destroyed; one with positive charges stays, and using it again fails with
 *   `SPELL_FAILED_NO_CHARGES_REMAIN` (`Spell::TakeCastItem`, `Spell::CheckItems`).)
 * $(LI The equip cooldown: putting on an item with an on-use spell (trigger 0) starts that spell's cooldown for
 *   30 seconds (and its category's), and the client is told (`SMSG_ITEM_COOLDOWN`), unless the item has
 *   `ITEM_FLAG_NO_EQUIPCOOLDOWN` (`Player::ApplyEquipCooldown`). A cooldown already running is kept.)
 * $(LI Timed items (`Duration`, in seconds in `ITEM_FIELD_DURATION`): their time runs down while the item is
 *   carried (worn, in the bags or the bank) and the player is in the world; at 0 the item is destroyed. One
 *   with `ITEM_EXTRA_REAL_TIME_DURATION` loses the time logged out as well, at login. The client is told
 *   the time left (`SMSG_ITEM_TIME_UPDATE`) at login and when such an item comes into the inventory; the
 *   field counts down each second, and is saved every half minute and when the character is saved
 *   (`Player::UpdateItemDuration`, `Item::UpdateDuration`).)
 * $(LI Wear: each blow dealt or taken has a 0.5% chance to take a point of durability from a random worn item
 *   (`Unit::DealDamage`); a thrown weapon that does not stack loses one a throw.)
 * )
 */
module dmangos.world.itemuse;

/// Charges after one use: one nearer 0, from either side (`Spell::TakeCastItem`).
int chargesAfterUse(int charges) pure nothrow @nogc @safe
{
    return charges > 0 ? charges - 1 : charges < 0 ? charges + 1 : 0;
}

unittest
{
    assert(chargesAfterUse(3) == 2 && chargesAfterUse(-1) == 0 && chargesAfterUse(-3) == -2 && chargesAfterUse(0) == 0);
}

/// A timed item's seconds left after `elapsed` more seconds; 0: it is gone.
uint secondsLeftAfter(uint left, ulong elapsed) pure nothrow @nogc @safe
{
    return left <= elapsed ? 0 : cast(uint)(left - elapsed);
}

unittest
{
    assert(secondsLeftAfter(1800, 1) == 1799 && secondsLeftAfter(1, 1) == 0 && secondsLeftAfter(5, 3600) == 0);
}

/// See the module documentation.
mixin template ItemUseHandlers()
{
    import core.time : Duration, msecs, seconds;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.inventory : EquipError, InventoryResult, Item, ItemState;
    import dmangos.world.itemuse : chargesAfterUse, secondsLeftAfter;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spellcast : castResultPacket, SpellCastResult;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

    /// The item being used while its spell is cast (`CMSG_USE_ITEM`): the cast takes its charges.
    package ulong usingItemGuid;
    private bool[ulong] timedItems;      // items with a duration the player carries, by guid
    private Duration durationClock;      // time not yet counted off them (under a second)
    private Duration sinceDurationWrite; // since their time left was last saved

    // -----------------------------------------------------------------------
    // Using
    // -----------------------------------------------------------------------

    /**
     * Whether `item` may be used now (CMaNGOS `HandleUseItemOpcode`): worn if it is to be worn, usable by the
     * player, and no spell of it out of combat only while in combat. The error to send, or `ok`.
     */
    package EquipError useItemError(Item item)
    {
        import dmangos.world.defines : InventoryType;
        import dmangos.world.spellcast : spellAttrNotInCombat;

        if (item.proto.inventoryType != InventoryType.nonEquip && !item.isEquipped)
            return EquipError(InventoryResult.itemNotFound, item);
        if (const result = player.inventory.canUse(item))
            return EquipError(result, item);
        if (inCombat)
            foreach (ref use; item.proto.details.spells)
                if (const spell = context.data.spells.spell(use.id))
                    if (spell.attributes & spellAttrNotInCombat)
                        return EquipError(InventoryResult.notInCombat, item);
        return EquipError.init;
    }

    /// An item used is bound if it binds on use (or on pickup, or is a quest item, and is not yet bound).
    package void bindOnUse(Item item)
    {
        enum uint bindWhenPickedUp = 1, bindWhenUse = 3, bindQuestItem = 4;
        const bonding = item.proto.bonding;
        if ((bonding == bindWhenPickedUp || bonding == bindWhenUse || bonding == bindQuestItem) && !item.bound)
        {
            item.bind();
            player.inventory.setState(item, ItemState.changed);
            flushInventory();
        }
    }

    /// Whether every spell with charges of `item` has some left; if not, the use fails (`NO_CHARGES_REMAIN`).
    package bool hasChargesLeft(const Item item)
    {
        foreach (i, charges; item.proto.spellCharges)
            if (charges && item.proto.details.spells[i].id && item.values.get!ITEM_FIELD_SPELL_CHARGES(i) == 0)
                return false;
        return true;
    }

    /**
     * A cast from item `entry` (`guid`, if known) took place: each of its spells with charges loses one, and the
     * item is destroyed when one with negative charges has none left (CMaNGOS `Spell::TakeCastItem`). Without
     * the item itself (a script's cast), one of `entry` with negative charges is used up.
     */
    package void takeCastItem(uint entry, ulong guid)
    {
        auto item = guid ? player.inventory.byGuid(guid) : null;
        if (item is null || item.entry != entry)
        {
            if (const proto = entry in context.data.items)
                foreach (i, ref use; proto.details.spells)
                    if (use.id && proto.spellCharges[i] < 0)
                    {
                        player.inventory.destroyCount(entry, 1);
                        return;
                    }
            return;
        }
        bool expendable, withoutCharges;
        foreach (i, ref use; item.proto.details.spells)
        {
            if (!use.id || !item.proto.spellCharges[i])
                continue;
            if (item.proto.spellCharges[i] < 0)
                expendable = true;
            int charges = cast(int) item.values.get!ITEM_FIELD_SPELL_CHARGES(i);
            if (charges)
            {
                charges = chargesAfterUse(charges);
                if (item.proto.stackable == 1)
                    item.values.set!ITEM_FIELD_SPELL_CHARGES(i, charges);
                player.inventory.setState(item, ItemState.changed);
            }
            withoutCharges = charges == 0;
        }
        if (expendable && withoutCharges)
        {
            uint one = 1;
            player.inventory.destroyCount(item, one);
        }
    }

    /**
     * The cooldown category of a cast of `spell` from item `itemEntry` (0: none): the item's `spellcategory_N`
     * for that spell if it names one, else the spell's (`Player::AddCooldown`, `IsSpellReady`). 456 items name
     * one their spell lacks or differs from, as the Swiftness Potion (2379: none; the item: 4, the healing
     * potions') and the Minor Healthstone (6262: 30; the item: 1153).
     */
    package uint cooldownCategoryOf(const(SpellInfo)* spell, uint itemEntry)
    {
        if (itemEntry)
            if (const proto = itemEntry in context.data.items)
                foreach (i, ref use; proto.details.spells)
                    if (use.id == spell.id)
                        return proto.spellCategory[i] ? proto.spellCategory[i] : spell.category;
        return spell.category;
    }

    // -----------------------------------------------------------------------
    // Wear
    // -----------------------------------------------------------------------

    /**
     * Damage dealt or taken: a chance in two hundred (`DurabilityLossChance.Damage`, 0.5%) that a worn item of a
     * random equipment slot loses a point of durability; broken, its stats go (CMaNGOS `Unit::DealDamage`,
     * `Player::DurabilityPointLossForEquipSlot`).
     */
    package void wearOnHit()
    {
        import std.random : uniform, uniform01;
        import dmangos.world.defines : equipmentSlotEnd;

        enum float chancePercent = 0.5f;
        if (player is null || uniform01(map.random) * 100 >= chancePercent)
            return;
        loseDurability(cast(ubyte) uniform(0, equipmentSlotEnd, map.random), 1);
    }

    /// The worn item in `slot` loses `points` of durability (not below 0); broken, its stats go.
    package void loseDurability(ubyte slot, uint points)
    {
        auto item = player.inventory[inventorySlotBag0, slot];
        if (item is null || !item.maxDurability || !item.durability)
            return;
        const now = item.durability > points ? item.durability - points : 0;
        item.values.set!ITEM_FIELD_DURABILITY(now);
        if (now == 0)
            player.inventory.equipmentChanged = true; // broken: its stats go
        player.inventory.setState(item, ItemState.changed);
        flushInventory();
    }

    // -----------------------------------------------------------------------
    // The equip cooldown
    // -----------------------------------------------------------------------

    /// The items just put on: each on-use spell's 30-second equip cooldown (see the module documentation).
    package void applyEquipCooldowns()
    {
        import core.time : MonoTime;

        enum uint noEquipCooldown = 0x80, onUse = 0;
        auto items = player.inventory.justEquipped;
        player.inventory.justEquipped = null;
        const now = context.clock();
        foreach (item; items)
        {
            if (item.proto is null || (item.proto.flags & noEquipCooldown) || !item.isEquipped)
                continue;
            foreach (ref use; item.proto.details.spells)
            {
                if (!use.id || use.trigger != onUse)
                    continue;
                const spell = context.data.spells.spell(use.id);
                if (spell is null)
                    continue;
                // `Player::AddCooldown` with a forced duration: the spell's 30 s, its category's own time, and
                // nothing if either is still running.
                const running = (spell.id in spellReadyAt && spellReadyAt[spell.id] > now)
                    || (spell.category && spell.category in categoryReadyAt && categoryReadyAt[spell.category] > now);
                if (!running && !cooldownCheat)
                {
                    spellReadyAt[spell.id] = now + 30.seconds;
                    const categoryMs = spell.category ? spell.categoryRecoveryTime : 0;
                    if (categoryMs)
                        categoryReadyAt[spell.category] = now + (cast(long) categoryMs).msecs;
                    cooldownCategory[spell.id] = categoryMs ? spell.category : 0;
                    cooldownItem[spell.id] = 0;
                }
                ByteWriter w;
                w.put(item.fullGuid);
                w.put(use.id);
                deliver(Opcode.SMSG_ITEM_COOLDOWN, w.data);
            }
        }
    }

    // -----------------------------------------------------------------------
    // Timed items
    // -----------------------------------------------------------------------

    /// `SMSG_ITEM_TIME_UPDATE`: the seconds a timed item has left.
    private void sendItemTime(const Item item)
    {
        ByteWriter w;
        w.put(item.fullGuid);
        w.put(item.values[ITEM_FIELD_DURATION]);
        deliver(Opcode.SMSG_ITEM_TIME_UPDATE, w.data);
    }

    /**
     * At login (or arriving from another node): the timed items carried; those that run in real time lose
     * the `offlineSeconds` logged out (and may be gone); the client is told each one's time left.
     */
    package void loadItemDurations(long offlineSeconds)
    {
        enum uint realTimeDuration = 0x01; // ITEM_EXTRA_REAL_TIME_DURATION
        timedItems = null;
        player.inventory.newlyTimed = null;
        bool destroyed;
        foreach (item; player.inventory.all())
        {
            const left = item.values[ITEM_FIELD_DURATION];
            if (!left || player.inventory.byGuid(item.fullGuid) !is item)
                continue; // none, or in a buyback slot
            if (offlineSeconds > 0 && (item.proto.details.extraFlags & realTimeDuration))
            {
                const now = secondsLeftAfter(left, offlineSeconds);
                if (now == 0)
                {
                    player.inventory.destroy(item.bagSlot, item.slot);
                    destroyed = true;
                    continue;
                }
                item.values.set!ITEM_FIELD_DURATION(now);
                player.inventory.setState(item, ItemState.changed);
            }
            timedItems[item.fullGuid] = true;
            sendItemTime(item);
        }
        if (destroyed || timedItems.length)
            flushInventory();
    }

    /// Each tick: new timed items are told of; each second, every timed item's time runs down (see the module documentation).
    package void updateItemDurations(Duration elapsed)
    {
        if (player.inventory.newlyTimed.length)
        {
            foreach (item; player.inventory.newlyTimed)
                if (item.fullGuid !in timedItems && player.inventory.byGuid(item.fullGuid) is item)
                {
                    timedItems[item.fullGuid] = true;
                    sendItemTime(item);
                }
            player.inventory.newlyTimed = null;
        }
        if (timedItems.length == 0)
        {
            durationClock = Duration.zero;
            return;
        }
        durationClock += elapsed;
        const secondsPassed = durationClock.total!"seconds";
        if (secondsPassed == 0)
            return;
        durationClock -= secondsPassed.seconds;
        sinceDurationWrite += secondsPassed.seconds;
        const write = sinceDurationWrite >= 30.seconds;
        if (write)
            sinceDurationWrite = Duration.zero;
        bool changed;
        foreach (guid; timedItems.keys)
        {
            auto item = player.inventory.byGuid(guid);
            if (item is null || !item.values[ITEM_FIELD_DURATION])
            {
                timedItems.remove(guid);
                continue;
            }
            const left = secondsLeftAfter(item.values[ITEM_FIELD_DURATION], secondsPassed);
            if (left == 0)
            {
                timedItems.remove(guid);
                player.inventory.destroy(item.bagSlot, item.slot);
            }
            else
            {
                item.values.set!ITEM_FIELD_DURATION(left);
                if (write)
                    player.inventory.setState(item, ItemState.changed);
            }
            changed = true;
        }
        if (changed)
            flushInventory();
    }

    /// Before a save: each timed item's time left goes into the database with it.
    package void saveItemDurations()
    {
        foreach (guid, _; timedItems)
            if (auto item = player.inventory.byGuid(guid))
                player.inventory.setState(item, ItemState.changed);
        if (timedItems.length)
            flushInventory();
    }
}
