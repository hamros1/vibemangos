/**
 * Enchanting a player's items, and crafting's skill gains.
 *
 * A permanent enchantment (the enchanting profession's: spell effect 53) goes into an item's
 * permanent slot; a temporary one (sharpening stones, weightstones, oils, poisons: effect 54) into its
 * temporary slot for the spell's duration in seconds (an hour if it gives none). Either replaces what
 * was in that slot. A worn item's stats change at once (`dmangos.world.enchantments` says what counts).
 *
 * Temporary enchantments run down while their item is carried, worn or in a bag, and are taken off when
 * their time is up; the client is told the time left (`SMSG_ITEM_ENCHANT_TIME_UPDATE`). The time left is
 * written into the item's duration field every half minute and when the character is saved, so it
 * survives a logout.
 *
 * Crafting (an item made by a spell, an enchantment) may raise the spell's profession by one, by how
 * the player's skill compares with the recipe's levels in `SkillLineAbility.dbc`: always below its yellow
 * level, never from its grey one, and between the two a chance falling evenly from all to none
 * (docs/FORMULAS.md, "Crafting skill-ups").
 */
module dmangos.world.enchanting;

/// The chance in a thousand that crafting a recipe raises its skill: by the skill against the recipe's
/// yellow (`minValue`) and grey (`maxValue`) levels, (grey - skill) / (grey - yellow) between the two.
int craftSkillChance(uint skill, uint grey, uint yellow) pure nothrow @nogc @safe
{
    if (skill >= grey)
        return 0;
    if (skill < yellow || grey <= yellow)
        return 1000;
    return cast(int)(1000 * (grey - skill) / (grey - yellow));
}

unittest
{
    // Linen Bandage (3275): yellow 30, (green 45,) grey 60.
    assert(craftSkillChance(1, 60, 30) == 1000 && craftSkillChance(29, 60, 30) == 1000);
    assert(craftSkillChance(30, 60, 30) == 1000 && craftSkillChance(45, 60, 30) == 500);
    assert(craftSkillChance(54, 60, 30) == 200 && craftSkillChance(59, 60, 30) == 33 && craftSkillChance(60, 60, 30) == 0);
}

/// See the module documentation.
final class Enchanting
{
    import dmangos.world.character : Character, Handles;
    import dmangos.world.session : WorldState;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import core.time : Duration, msecs, seconds;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.enchantments : EnchantmentSlot, enchantmentSlots, fieldsPerSlot;
    import dmangos.world.enchanting : craftSkillChance;
    import dmangos.world.inventory : Item, ItemState;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.updatefields;

    /// Temporary enchantments' time left, by item guid (items carried with one).
    package Duration[ulong] enchantmentsLeft;
    private Duration sinceEnchantWrite;

    /**
     * Spell effect 53 or 54 on item `itemGuid` (one of the player's own): enchantment `enchantment`
     * in its permanent slot, or (`temporary`) in its temporary slot for `durationSeconds`.
     */
    package void enchantItem(ulong itemGuid, uint enchantment, bool temporary, int durationSeconds)
    {
        auto item = me.player.inventory.byGuid(itemGuid);
        if (item is null || enchantment == 0 || enchantment !in me.context.data.enchantmentEffects)
            return;
        if (temporary)
            keepTemporaryEnchantment(item, enchantment, (durationSeconds > 0 ? durationSeconds : 3600) * 1000);
        else
            setEnchantment(item, EnchantmentSlot.permanent, enchantment, 0);
    }

    private void keepTemporaryEnchantment(Item item, uint enchantment, uint ms)
    {
        setEnchantment(item, EnchantmentSlot.temporary, enchantment, ms);
        enchantmentsLeft[item.fullGuid] = ms.msecs;
        sendEnchantTime(item, EnchantmentSlot.temporary, ms / 1000);
    }

    /// A totem can refresh its own temporary imbue and leaves another temporary enchantment in place.
    package void enchantWeaponFromTotem(uint enchantment, uint ms)
    {
        import dmangos.world.defines : equipmentSlotMainhand;

        auto weapon = me.player.inventory.equipped(equipmentSlotMainhand);
        if (weapon is null || weapon.proto is null || weapon.proto.itemClass != 2
            || !enchantment || enchantment !in me.context.data.enchantmentEffects)
            return;
        const previous = weapon.enchantment(EnchantmentSlot.temporary);
        if (previous && (previous != enchantment || enchantmentsLeft.get(weapon.fullGuid, Duration.zero) >= ms.msecs))
            return;
        keepTemporaryEnchantment(weapon, enchantment, ms);
    }

    /// An enchantment in an item's slot (0 clears it), its fields set, saved, and a worn item's bonuses redone.
    package void setEnchantment(Item item, size_t slot, uint enchantment, uint durationMs)
    {
        item.values.set!ITEM_FIELD_ENCHANTMENT(slot * fieldsPerSlot, enchantment);
        item.values.set!ITEM_FIELD_ENCHANTMENT(slot * fieldsPerSlot + 1, durationMs);
        item.values.set!ITEM_FIELD_ENCHANTMENT(slot * fieldsPerSlot + 2, 0u);
        me.player.inventory.setState(item, ItemState.changed);
        if (item.isEquipped)
            me.player.inventory.equipmentChanged = true;
        me.flushInventory();
    }

    /// `SMSG_ITEM_ENCHANT_TIME_UPDATE`: the time a temporary enchantment has left, in seconds.
    void sendEnchantTime(const Item item, size_t slot, uint secondsLeft)
    {
        ByteWriter w;
        w.put(item.fullGuid);
        w.put(cast(uint) slot);
        w.put(secondsLeft);
        w.put(me.player.guid);
        me.deliver(Opcode.SMSG_ITEM_ENCHANT_TIME_UPDATE, w.data);
    }

    /// At login: the temporary enchantments the items came with, from their saved durations.
    package void loadEnchantmentTimers()
    {
        enchantmentsLeft = null;
        foreach (item; me.player.inventory.all())
        {
            if (item.enchantment(EnchantmentSlot.temporary) == 0)
                continue;
            const ms = item.values.get!ITEM_FIELD_ENCHANTMENT(EnchantmentSlot.temporary * fieldsPerSlot + 1);
            if (ms == 0)
                continue;
            enchantmentsLeft[item.fullGuid] = ms.msecs;
            sendEnchantTime(item, EnchantmentSlot.temporary, ms / 1000);
        }
    }

    /// Each tick: temporary enchantments run down, and go when their time is up.
    package void updateEnchantments(Duration elapsed)
    {
        if (enchantmentsLeft.length == 0)
            return;
        sinceEnchantWrite += elapsed;
        const write = sinceEnchantWrite >= 30.seconds;
        if (write)
            sinceEnchantWrite = Duration.zero;
        foreach (guid; enchantmentsLeft.keys)
        {
            auto item = me.player.inventory.byGuid(guid);
            if (item is null || item.enchantment(EnchantmentSlot.temporary) == 0)
            {
                enchantmentsLeft.remove(guid);
                continue;
            }
            auto left = &enchantmentsLeft[guid];
            *left -= elapsed;
            if (*left <= Duration.zero)
            {
                enchantmentsLeft.remove(guid);
                setEnchantment(item, EnchantmentSlot.temporary, 0, 0);
                sendEnchantTime(item, EnchantmentSlot.temporary, 0);
            }
            else if (write)
                writeEnchantmentTime(item, *left);
        }
        if (write)
            me.flushInventory();
    }

    /// Before a save: every temporary enchantment's time left into its item's duration field.
    package void saveEnchantmentTimes()
    {
        foreach (guid, left; enchantmentsLeft)
            if (auto item = me.player.inventory.byGuid(guid))
                writeEnchantmentTime(item, left);
        if (enchantmentsLeft.length)
            me.flushInventory();
    }

    private void writeEnchantmentTime(Item item, Duration left)
    {
        item.values.set!ITEM_FIELD_ENCHANTMENT(EnchantmentSlot.temporary * fieldsPerSlot + 1,
            cast(uint) left.total!"msecs");
        me.player.inventory.setState(item, ItemState.changed);
    }

    /// Crafting with `spell` may raise its profession (see the module documentation).
    package void updateCraftSkill(uint spell)
    {
        foreach (ability; me.context.client.abilitiesForSpell(spell))
            if (ability.skillId)
            {
                const skill = me.player.skillValue(ability.skillId);
                if (skill[1] == 0)
                    return; // not known
                me.updateSkillPro(ability.skillId, craftSkillChance(skill[0], ability.maxValue, ability.minValue), 1);
                return;
            }
    }
}
