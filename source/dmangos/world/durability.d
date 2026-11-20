/**
 * Wear by spells and death (CMaNGOS's `Player::DurabilityLossAll`, `DurabilityPointsLossAll`, `DurabilityLoss`,
 * `DurabilityPointsLoss`, and the spell effects `SPELL_EFFECT_DURABILITY_DAMAGE` and `_DURABILITY_DAMAGE_PCT`).
 *
 * An item loses points of durability, never below none nor (a negative loss mends it) above its most; a share of
 * it is at least one point. Broken, a worn item's stats go; mended from broken, they come back. "All" is what is
 * worn, and with the inventory also what is in the backpack and in each bag (a death's tenth only what is worn, the
 * spirit healer's quarter all of it; bags and keys have no durability).
 *
 * `SPELL_EFFECT_DURABILITY_DAMAGE` takes the effect's value from the equipment slot of its misc value, or from
 * everything worn (-1) or carried as well (-2), and tells the combat log (`SMSG_SPELLLOGEXECUTE`: the target, the
 * item's entry or -1, the points); `_PCT` takes the value as a percentage, silently. Only players wear.
 */
module dmangos.world.durability;

/// An item's durability after losing `points` (negative: mended): between none and `max`.
uint durabilityAfter(uint now, uint max, int points) pure nothrow @nogc @safe
{
    const left = cast(long) now - points;
    return left < 0 ? 0 : left > max ? max : cast(uint) left;
}

/// The points a loss of `percent` (0.25: a quarter) of `max` takes: at least one.
int durabilityShare(uint max, double percent) pure nothrow @nogc @safe
{
    const points = cast(uint)(max * percent);
    return points < 1 ? 1 : points;
}

unittest
{
    assert(durabilityAfter(50, 60, 10) == 40 && durabilityAfter(5, 60, 10) == 0);
    assert(durabilityAfter(50, 60, -20) == 60, "mended, up to its most");
    assert(durabilityShare(60, 0.25) == 15 && durabilityShare(3, 0.10) == 1);
}

/// See the module documentation.
mixin template DurabilityRules()
{
    import dmangos.world.defines : equipmentSlotEnd, inventorySlotBag0, inventorySlotBagEnd, inventorySlotBagStart,
        inventorySlotItemEnd, inventorySlotItemStart;
    import dmangos.world.durability : durabilityAfter, durabilityShare;
    import dmangos.world.inventory : Item, ItemState;
    import dmangos.world.updatefields : ITEM_FIELD_DURABILITY, maxBagSize;

    /// `item` loses `points` (negative: mended); broken or mended, a worn item's stats follow.
    package void durabilityPointsLoss(Item item, int points)
    {
        if (item is null)
            return;
        const old = item.durability, now = durabilityAfter(old, item.maxDurability, points);
        if (now == old)
            return;
        item.values.set!ITEM_FIELD_DURABILITY(now);
        if ((now == 0 || old == 0) && item.isEquipped)
            player.inventory.equipmentChanged = true; // broken, or whole again: its stats go or come back
        player.inventory.setState(item, ItemState.changed);
    }

    /// `item` loses `percent` of its most durability (at least a point; none without durability).
    package void durabilityLoss(Item item, double percent)
    {
        if (item !is null && item.maxDurability)
            durabilityPointsLoss(item, durabilityShare(item.maxDurability, percent));
    }

    /// Each item worn, and with `inventory` each carried (the backpack, the bags' contents).
    private void forEachWornOrCarried(bool inventory, scope void delegate(Item) dg)
    {
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
            dg(player.inventory[inventorySlotBag0, slot]);
        if (!inventory)
            return;
        foreach (ubyte slot; inventorySlotItemStart .. inventorySlotItemEnd)
            dg(player.inventory[inventorySlotBag0, slot]);
        foreach (ubyte bag; inventorySlotBagStart .. inventorySlotBagEnd)
            if (player.inventory[inventorySlotBag0, bag] !is null)
                foreach (ubyte slot; 0 .. maxBagSize)
                    dg(player.inventory[bag, slot]);
    }

    /// What it wears (and with `inventory` what it carries) loses `percent` of its durability.
    package void durabilityLossAll(double percent, bool inventory)
    {
        forEachWornOrCarried(inventory, (Item item) { durabilityLoss(item, percent); });
        flushInventory(true);
    }

    /// What it wears (and with `inventory` what it carries) loses `points` of durability.
    package void durabilityPointsLossAll(int points, bool inventory)
    {
        forEachWornOrCarried(inventory, (Item item) { durabilityPointsLoss(item, points); });
        flushInventory(true);
    }

    /**
     * `SPELL_EFFECT_DURABILITY_DAMAGE` (`percent`: `_PCT`) of effect `i` of `spell` on this player: `value` points
     * (or percent) from the equipment slot of its misc value, or from all it wears (-1) or carries (-2).
     */
    package void durabilityDamageEffect(const(imported!"dmangos.world.spells".SpellInfo)* spell, size_t i,
        int value, bool percent, ulong caster)
    {
        import dmangos.world.opcodes : Opcode;
        import dmangos.world.spellcast : executeLog, executeTarget;

        const slot = spell.miscValue[i];
        void log(int entry)
        {
            if (!percent)
                map.sendToWatchers(this, Opcode.SMSG_SPELLLOGEXECUTE, executeLog(caster, spell.id,
                    cast(uint) spell.effect[i], executeTarget(player.guid, entry, value)), true);
        }

        if (slot < 0)
        {
            if (percent)
                durabilityLossAll(value / 100.0, slot < -1);
            else
                durabilityPointsLossAll(value, slot < -1);
            return log(-1);
        }
        if (slot >= inventorySlotBagEnd || (percent && value <= 0))
            return;
        auto item = player.inventory[inventorySlotBag0, cast(ubyte) slot];
        if (item is null)
            return;
        log(cast(int) item.proto.entry);
        if (percent)
            durabilityLoss(item, value / 100.0);
        else
            durabilityPointsLoss(item, value);
        flushInventory();
    }
}

/**
 * The spell effects on a warrior's sword (worn) and a second one in a bag: points from everything carried, logged;
 * a share from the main hand; and the spirit healer's quarter reaching into the bag.
 */
unittest
{
    import dmangos.world.defines : equipmentSlotMainhand, inventorySlotBag0;
    import dmangos.world.inventory : InventoryResult, ItemPosCount, itemPos;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint bagEntry = 91_401, wearAll = 91_402, wearHand = 91_403;
    context.data.items[bagEntry] = context.data.items[itemQuiver];
    context.data.items.edit(bagEntry).entry = bagEntry;
    context.data.items.edit(bagEntry).itemClass = 1; // a container, for anything
    context.data.items.edit(bagEntry).subClass = 0;
    with (context.data.spells)
    {
        spells[wearAll] = testSpell(wearAll, SpellEffect.durabilityDamage, 1, 5);
        spells.edit(wearAll).miscValue[0] = -2; // all worn and carried
        spells[wearHand] = testSpell(wearHand, SpellEffect.durabilityDamagePct, 1, 50);
        spells.edit(wearHand).miscValue[0] = equipmentSlotMainhand;
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = anduin.session.inWorld;
    auto inv = me.player.inventory;
    auto worn = inv.equipNew(itemPos(inventorySlotBag0, equipmentSlotMainhand), itemSword);
    assert(worn !is null && worn.proto.entry == itemSword && worn.durability == 20);
    assert(inv.equipNew(itemPos(inventorySlotBag0, 19), bagEntry) !is null);
    ItemPosCount[] dest;
    assert(inv.canStoreNew(19, 0, dest, itemSword, 1) == InventoryResult.ok);
    auto carried = inv.storeNew(dest, itemSword);
    assert(carried !is null && carried.durability == 20);
    anduin.read();

    me.castSpell(context.data.spells.spell(wearAll), SpellTargets(TargetFlags.self, 0), true, 0);
    assert(worn.durability == 15 && carried.durability == 15, "worn and in the bag");
    auto r = ByteReader(bodyOf(anduin.read(), Opcode.SMSG_SPELLLOGEXECUTE));
    assert(r.readPackedGuid == me.player.guid && r.read!uint == wearAll && r.read!uint == 1
        && r.read!uint == SpellEffect.durabilityDamage && r.read!uint == 1);
    assert(r.read!ulong == me.player.guid && r.read!int == -1 && r.read!int == 5 && r.empty);

    me.castSpell(context.data.spells.spell(wearHand), SpellTargets(TargetFlags.self, 0), true, 0);
    assert(worn.durability == 5 && carried.durability == 15, "half of its most, the main hand only");

    // The spirit healer's quarter: what is in the bag too (five points of twenty).
    me.durabilityLossAll(0.25, true);
    assert(worn.durability == 0 && carried.durability == 10);
}
