/**
 * Talents and passive spells: learning talents, resetting them at a trainer, the auras of passive
 * spells, and the on-equip spells and set bonuses of the items worn. Mixed into
 * `dmangos.world.character.Character`.
 *
 * From level 10 a player gets a talent point a level (`PLAYER_CHARACTER_POINTS1` holds those not
 * spent). A talent of its class may be learned, a rank at a time, if its tree has 5 points spent for
 * each row above it, and what it depends on is known; the rank's spell replaces the rank before.
 * Passive spells (talents, racials) put their aura effects on the player for good: at login, on
 * arrival from another node, and when learned.
 */
module dmangos.world.talenthandlers;

import dmangos.world.money : Copper;

/// See the module documentation.
mixin template TalentHandlers()
{
    import dmangos.world.money : Copper;
    import dmangos.bytes : ByteReader;
    import dmangos.log : info;
    import dmangos.world.auras : Aura, makeAura;
    import dmangos.world.clientdata : maxTalentRank;
    import dmangos.world.opcodes;
    import dmangos.world.spellcast : effectValue;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

private:
    /// The client learns a talent rank: checked, then learned.
    @Handles(Opcode.CMSG_LEARN_TALENT, WorldState.inWorld)
    void handleLearnTalent(ref ByteReader reader)
    {
        const talentId = reader.read!uint, rank = reader.read!uint;
        const free = player.values.get!PLAYER_CHARACTER_POINTS1;
        if (free == 0 || rank >= maxTalentRank)
            return;
        const talent = context.client.talents.lookup(talentId);
        if (talent is null)
            return;
        const tab = context.client.talentTabs.lookup(talent.talentTab);
        if (tab is null || !(tab.classMask & (1u << (player.data.classId - 1))))
            return;
        // The highest rank known.
        uint known;
        foreach_reverse (k; 0 .. maxTalentRank)
            if (talent.rankId[k] && player.knowsSpell(talent.rankId[k]))
            {
                known = k + 1;
                break;
            }
        if (known >= rank + 1 || free < rank + 1 - known)
            return;
        // What it depends on.
        if (talent.dependsOn)
            if (const needed = context.client.talents.lookup(talent.dependsOn))
            {
                bool enough;
                foreach (i; talent.dependsOnRank .. maxTalentRank)
                    if (needed.rankId[i] && player.knowsSpell(needed.rankId[i]))
                        enough = true;
                if (!enough)
                    return;
            }
        if (talent.dependsOnSpell && !player.knowsSpell(talent.dependsOnSpell))
            return;
        // 5 points in the tree for each row above.
        if (talent.row > 0)
        {
            uint spent;
            foreach (id; 0 .. context.client.talents.idLimit)
                if (const other = context.client.talents.lookup(id))
                    if (other.talentTab == talent.talentTab)
                        foreach (j; 0 .. maxTalentRank)
                            if (other.rankId[j] && player.knowsSpell(other.rankId[j]))
                                spent += j + 1;
            if (spent < talent.row * maxTalentRank)
                return;
        }
        const spellId = talent.rankId[rank];
        if (spellId == 0 || player.knowsSpell(spellId))
            return;
        // The rank before goes (`learnSpell` of a talent), and its passive aura with it.
        foreach (k; 0 .. rank)
            if (talent.rankId[k] && player.knowsSpell(talent.rankId[k]))
            {
                if (auto aura = player.auras.find(talent.rankId[k]))
                    removeAura(aura);
                unlearn(talent.rankId[k]);
            }
        learn(spellId);
        player.values.set!PLAYER_CHARACTER_POINTS1(free - (rank + 1 - known));
        if (const spell = context.data.spells.spell(spellId))
            applyPassive(spell);
        refreshEquipBoundPassives();
        flushPlayerChanges();
        info!"%s: '%s' learned talent %s rank %s (spell %s)"(remoteAddress, player.data.name, talentId, rank + 1,
            spellId);
    }

    /**
     * Every talent rank known forgotten (its passive aura gone with it), and
     * the talent points of the level back.
     */
    package void resetTalents()
    {
        import dmangos.world.player : talentPointsForLevel;

        foreach (id; 0 .. context.client.talents.idLimit)
            if (const talent = context.client.talents.lookup(id))
                foreach (spell; talent.rankId)
                    if (spell && player.knowsSpell(spell))
                    {
                        if (auto aura = player.auras.find(spell))
                            removeAura(aura);
                        unlearn(spell);
                    }
        player.values.set!PLAYER_CHARACTER_POINTS1(talentPointsForLevel(player.data.level));
        flushPlayerChanges();
    }

    private uint talentResetCost_; // what the last reset cost (copper)
    private long talentResetTime_; // when (Unix time)

    /// Loads `resettalents_cost` and `resettalents_time`.
    package void loadTalentReset()
    {
        context.database.loadTalentReset(player.data.guid, talentResetCost_, talentResetTime_);
    }

    /// The next reset's price: 1 gold the first time, then 5, then 10; after that 5 more each time up
    /// to 50, and 5 less for each month without a reset, down to 10.
    package uint talentResetCost()
    {
        enum uint gold = 10_000;
        enum long month = 30 * 24 * 3600;
        if (talentResetCost_ < 1 * gold)
            return 1 * gold;
        if (talentResetCost_ < 5 * gold)
            return 5 * gold;
        if (talentResetCost_ < 10 * gold)
            return 10 * gold;
        const months = (context.unixTime - talentResetTime_) / month;
        if (months > 0)
        {
            const cost = cast(long) talentResetCost_ - 5 * gold * months;
            return cast(uint)(cost < 10 * gold ? 10 * gold : cost);
        }
        const cost = talentResetCost_ + 5 * gold;
        return cost > 50 * gold ? 50 * gold : cost;
    }

    /// How many talent ranks the player knows.
    package uint talentRanksKnown()
    {
        uint count;
        foreach (id; 0 .. context.client.talents.idLimit)
            if (const talent = context.client.talents.lookup(id))
                foreach (rank, spell; talent.rankId)
                    if (spell && player.knowsSpell(spell))
                        count = count + 1;
        return count;
    }

    /// The player agreed to the price at its class trainer: its talents
    /// go for it; without the money, or the trainer, an empty answer.
    @Handles(Opcode.MSG_TALENT_WIPE_CONFIRM, WorldState.inWorld)
    void handleTalentWipeConfirm(const ClientGuid request)
    {
        import dmangos.world.npchandlers : NpcFlag;

        void refuse()
        {
            ByteWriter w;
            w.put(ulong(0));
            w.put(uint(0));
            deliver(Opcode.MSG_TALENT_WIPE_CONFIRM, w.data);
        }

        auto trainer = interactableNpc(request.guid, NpcFlag.trainer);
        if (trainer is null || !isTrainerOf(trainer, false))
            return refuse();
        if (talentRanksKnown() == 0)
        {
            resetTalents(); // nothing to pay for: the points of the level, as they are
            return;
        }
        const cost = talentResetCost();
        if (!player.canAfford(Copper(cost)))
            return refuse();
        player.pay(Copper(cost));
        resetTalents();
        talentResetCost_ = cost;
        talentResetTime_ = context.unixTime;
        context.database.saveTalentReset(player.data.guid, cost, talentResetTime_);
        // Spell 14867, "Untalent Visual Effect", on the player, where the server has it.
        if (const visual = context.data.spells.spell(14_867))
        {
            import dmangos.world.spellcast : SpellTargets, TargetFlags;

            castSpell(visual, SpellTargets(TargetFlags.self, player.guid), true, 0);
        }
        flushPlayerChanges();
    }

    /// The trainer's "unlearn talents" option: the price, for the client to ask the player.
    package void offerTalentWipe(ulong trainer)
    {
        ByteWriter w;
        w.put(trainer);
        w.put(talentResetCost());
        deliver(Opcode.MSG_TALENT_WIPE_CONFIRM, w.data);
    }

    /// A passive spell's aura effects on the player for good (no slot, never ending).
    package void applyPassive(const(SpellInfo)* spell)
    {
        enum uint applyAura = 6;
        if (!spell.isPassive || player.auras.find(spell.id) !is null)
            return;
        // Those bound to a kind of weapon or armour are not applied yet.
        if (spell.equippedItemClass >= 0)
            return;
        int[3] values;
        bool any;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == applyAura)
            {
                values[i] = effectValue(*spell, i, player.data.level, 0);
                any = true;
            }
        if (!any)
            return;
        auto aura = makeAura(spell, player.guid, player.data.level, -1, true, values);
        aura.passive = true;
        addAura(aura);
    }

    /// Every passive spell known puts its auras on.
    package uint[uint] equipSpells; // the item spells on equip applied now (`spelltrigger` 1), and how many items give each

    /**
     * For every item worn: the on-equip spells of the unbroken items
     * worn are on as auras (lasting while worn), and the bonuses of the item sets they make up;
     * those of items taken off (or broken) go. The bags in the bag slots count as worn (CMaNGOS
     * `_ApplyAllItemMods` goes up to `INVENTORY_SLOT_BAG_END`): a quiver's or ammo pouch's ranged haste.
     */
    package void refreshEquipSpells()
    {
        import dmangos.world.defines : inventorySlotBag0, inventorySlotBagEnd;

        import dmangos.world.enchantments : EnchantmentType;

        enum uint onEquip = 1, applyAura = 6;
        uint[uint] wanted; // spell -> how many worn items give it
        uint[uint] worn; // item set -> items of it worn
        foreach (ubyte slot; 0 .. inventorySlotBagEnd)
        {
            const item = player.inventory[inventorySlotBag0, slot];
            if (item is null || item.proto is null || (item.maxDurability && item.durability == 0))
                continue;
            foreach (ref s; item.proto.details.spells)
                if (s.id && s.trigger == onEquip)
                    ++wanted[s.id];
            // Its enchantments' equip spells (most of a random property's stats are these).
            foreach (enchantSlot; [0, 1, 3, 4, 5])
                if (const effects = item.enchantment(enchantSlot) in context.data.enchantmentEffects)
                    foreach (ref e; *effects)
                        if (e.type == EnchantmentType.equipSpell && e.arg)
                            ++wanted[e.arg];
            if (const set = item.proto.details.itemSet)
                worn[set]++;
        }
        // A set's bonuses for as many of its items as are worn (and its skill).
        foreach (set, count; worn)
            if (const entry = context.client.itemSets.lookup(set))
            {
                if (entry.requiredSkill && player.skillValue(entry.requiredSkill)[0] < entry.requiredSkillValue)
                    continue;
                foreach (k; 0 .. 8)
                    if (entry.spells[k] && entry.thresholds[k] && count >= entry.thresholds[k])
                        wanted[entry.spells[k]] = 1;
            }
        // Gone, or given by another number of items now: off (and on again below, as many times over).
        foreach (id, count; equipSpells.dup)
            if (wanted.get(id, 0) != count)
            {
                if (auto aura = player.auras.find(id))
                    removeAura(aura);
                equipSpells.remove(id);
            }
        foreach (id, count; wanted)
        {
            if (id in equipSpells)
                continue;
            const spell = context.data.spells.spell(id);
            if (spell is null || player.auras.find(id) !is null)
                continue;
            int[3] values;
            bool any;
            foreach (i; 0 .. 3)
                if (spell.effect[i] == applyAura)
                {
                    // (with the player's talents: Elemental Weapons on Rockbiter Weapon's attack power)
                    values[i] = effectMod(spell, i, effectValue(*spell, i, player.data.level, 0)) * cast(int) count;
                    any = true;
                }
            if (!any)
                continue;
            auto aura = makeAura(spell, player.guid, player.data.level, -1, true, values);
            aura.passive = true;
            addAura(aura);
            equipSpells[id] = count;
        }
    }

    package void applyPassiveSpells()
    {
        refreshEquipSpells();
        foreach (id; player.spells)
            if (const spell = context.data.spells.spell(id))
                if (spell.isPassive)
                    applyPassive(spell);
        refreshEquipBoundPassives();
    }

    /**
     * The passive spells bound to a kind of weapon or armour (their `EquippedItemClass`: Redoubt to a shield, One-Handed
     * Weapon Specialization to a one-handed weapon, Weapon Mastery to any): on while one is worn (a weapon in either
     * hand, a shield in the off hand), off when none is.
     */
    package void refreshEquipBoundPassives()
    {
        import dmangos.world.defines : equipmentSlotMainhand, equipmentSlotOffhand, ItemClass;

        enum uint applyAura = 6;
        bool worn(const(SpellInfo)* spell)
        {
            const slots = spell.equippedItemClass == ItemClass.armor ? [equipmentSlotOffhand]
                : [equipmentSlotMainhand, equipmentSlotOffhand];
            foreach (slot; slots)
                if (const item = player.inventory.equipped(cast(ubyte) slot))
                    if (item.proto !is null && item.proto.itemClass == spell.equippedItemClass
                            && (item.durability != 0 || item.maxDurability == 0)
                            && (spell.equippedItemSubClassMask <= 0 || (spell.equippedItemSubClassMask & (1 << item.proto.subClass))))
                        return true;
            return false;
        }
        foreach (id; player.spells)
        {
            const spell = context.data.spells.spell(id);
            if (spell is null || !spell.isPassive || spell.equippedItemClass < 0)
                continue;
            auto on = player.auras.find(id);
            const wanted = worn(spell);
            if (on !is null && !wanted)
                removeAura(on);
            else if (on is null && wanted)
            {
                int[3] values;
                bool any;
                foreach (i; 0 .. 3)
                    if (spell.effect[i] == applyAura)
                    {
                        values[i] = effectValue(*spell, i, player.data.level, 0);
                        any = true;
                    }
                if (!any)
                    continue;
                auto aura = makeAura(spell, player.guid, player.data.level, -1, true, values);
                aura.passive = true;
                addAura(aura);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A level 12 warrior's 3 points: a rank of a talent (its passive aura on), the next rank instead of
 * it, and a talent of the second row refused with only 2 points in the tree.
 */
unittest
{
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.auras : AuraType;
    import dmangos.world.clientdata : talentFormat, talentTabFormat;
    import dmangos.world.defines : Stat;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint arms = 161;
    context.client.talentTabs = typeof(context.client.talentTabs).parse(buildDbc(talentTabFormat,
        [[arms, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0]]), "TalentTab.dbc");
    context.client.talents = typeof(context.client.talents).parse(buildDbc(talentFormat,
        [[1u, arms, 0, 0, 92001, 92002, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
         [2u, arms, 1, 0, 92003, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "Talent.dbc");
    foreach (rank, id; [92001u, 92002u, 92003u])
    {
        auto s = testSpell(id, 6, 1, cast(int) rank + 1);
        s.attributes = 0x40; // passive
        s.casting.applyAuraName[0] = AuraType.modStat;
        s.miscValue[0] = Stat.strength;
        context.data.spells.spells[id] = s;
    }
    auto garrosh = loggedIn(context, db, 7, "Garrosh", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player,
        raceHuman, 0, 12);
    garrosh.read();
    auto me = cast(Player) garrosh.session.character;
    assert(me.values.get!PLAYER_CHARACTER_POINTS1 == 3);
    const strength = me.values.get!UNIT_FIELD_STAT0(Stat.strength);

    ubyte[] learnPacket(uint talent, uint rank)
    {
        ByteWriter w;
        w.put(talent);
        w.put(rank);
        return w.data.dup;
    }

    garrosh.write(Opcode.CMSG_LEARN_TALENT, learnPacket(1, 0));
    assert(me.knowsSpell(92001) && me.values.get!PLAYER_CHARACTER_POINTS1 == 2);
    assert(me.values.get!UNIT_FIELD_STAT0(Stat.strength) == strength + 1, "its passive aura is on");
    garrosh.write(Opcode.CMSG_LEARN_TALENT, learnPacket(1, 1));
    assert(me.knowsSpell(92002) && !me.knowsSpell(92001) && me.values.get!PLAYER_CHARACTER_POINTS1 == 1);
    assert(me.values.get!UNIT_FIELD_STAT0(Stat.strength) == strength + 2, "the new rank's, not both");
    garrosh.write(Opcode.CMSG_LEARN_TALENT, learnPacket(2, 0));
    assert(!me.knowsSpell(92003) && me.values.get!PLAYER_CHARACTER_POINTS1 == 1, "the second row needs 5 points");

    // At the warrior's trainer: 1 gold to forget them (its points back), 5 the next time; too poor, nothing.
    {
        import dmangos.world.objects : HighGuid, makeGuid;

        ByteWriter w;
        w.put(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
        const wipe = w.data.dup;
        me.values.set!PLAYER_FIELD_COINAGE(60_000u); // exactly this much
        garrosh.read();
        garrosh.write(Opcode.MSG_TALENT_WIPE_CONFIRM, wipe);
        assert(!me.knowsSpell(92002) && me.values.get!PLAYER_CHARACTER_POINTS1 == 3, "forgotten, the points back");
        assert(me.values.get!UNIT_FIELD_STAT0(Stat.strength) == strength, "their aura gone");
        assert(me.money == Copper(50_000), "one gold");
        garrosh.write(Opcode.CMSG_LEARN_TALENT, learnPacket(1, 0));
        garrosh.write(Opcode.MSG_TALENT_WIPE_CONFIRM, wipe);
        assert(!me.knowsSpell(92001) && me.money == Copper(0), "five gold the second time");
        garrosh.write(Opcode.CMSG_LEARN_TALENT, learnPacket(1, 0));
        garrosh.read();
        garrosh.write(Opcode.MSG_TALENT_WIPE_CONFIRM, wipe);
        assert(me.knowsSpell(92001), "ten gold the next: too poor");
        assert(opcodesOf(garrosh.read()).canFind(Opcode.MSG_TALENT_WIPE_CONFIRM), "told so");
        uint cost;
        long when;
        db.loadTalentReset(7, cost, when);
        assert(cost == 50_000 && when > 0, "saved");
    }
}

/// An item's spell on equip: its aura while the item is worn, gone when it is taken off.
unittest
{
    import dmangos.world.auras : AuraType;
    import dmangos.world.defines : equipmentSlotMainhand, inventorySlotBag0, Stat;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientItemPos, ClientSwapInvItem;
    import dmangos.world.player : Player;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint might = 95800;
    context.data.spells.spells[might] = testSpell(might, 6, 1, 5); // +5 strength
    context.data.spells.spells.edit(might).casting.applyAuraName[0] = AuraType.modStat;
    context.data.spells.spells.edit(might).miscValue[0] = Stat.strength;
    context.data.items.edit(itemSword).details.spells[0].id = might;
    context.data.items.edit(itemSword).details.spells[0].trigger = 1; // on equip
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    anduin.session.inWorld.storeLoot(itemSword, 1, 0, false);
    anduin.read();
    ubyte slot;
    foreach (s; ubyte(23) .. ubyte(39))
        if (const item = me.inventory[inventorySlotBag0, s])
            if (item.entry == itemSword)
                slot = s;
    const before = me.values.get!UNIT_FIELD_STAT0;
    anduin.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
    anduin.read();
    assert(me.inventory.equipped(equipmentSlotMainhand) !is null && me.auras.find(might) !is null, "worn: its aura");
    assert(me.values.get!UNIT_FIELD_STAT0 == before + 5);
    anduin.write(Opcode.CMSG_SWAP_INV_ITEM, ClientSwapInvItem(equipmentSlotMainhand, slot));
    anduin.read();
    assert(me.auras.find(might) is null && me.values.get!UNIT_FIELD_STAT0 == before, "taken off: gone");

    // A set of one item (the sword) whose bonus needs one worn: on with it, off without it.
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : itemSetFormat;

    enum uint setBonus = 95801, setId = 77;
    context.data.spells.spells[setBonus] = testSpell(setBonus, 6, 1, 3);
    context.data.spells.spells.edit(setBonus).casting.applyAuraName[0] = AuraType.modStat;
    context.data.spells.spells.edit(setBonus).miscValue[0] = Stat.strength;
    context.data.items.edit(itemSword).details.spells[0].id = 0;
    context.data.items.edit(itemSword).details.itemSet = setId;
    uint[45] row;
    row[0] = setId;
    row[27] = setBonus; // its first spell
    row[35] = 1;        // for one item
    context.client.itemSets = typeof(context.client.itemSets).parse(buildDbc(itemSetFormat, [row[]]), "ItemSet.dbc");
    anduin.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
    anduin.read();
    assert(me.auras.find(setBonus) !is null && me.values.get!UNIT_FIELD_STAT0 == before + 3, "the set's bonus");
    anduin.write(Opcode.CMSG_SWAP_INV_ITEM, ClientSwapInvItem(equipmentSlotMainhand, slot));
    anduin.read();
    assert(me.auras.find(setBonus) is null, "gone with the item");
}
