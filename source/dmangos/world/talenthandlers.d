/**
 * Talents and passive spells (CMaNGOS `Player::LearnTalent`, `learnSpell`'s passive part and
 * `_LoadSpells`' casting of passives), mixed into `dmangos.world.session.WorldSession`.
 *
 * From level 10 a player gets a talent point a level (`PLAYER_CHARACTER_POINTS1` holds those not
 * spent). A talent of its class may be learned, a rank at a time, if its tree has 5 points spent for
 * each row above it, and what it depends on is known; the rank's spell replaces the rank before.
 * Passive spells (talents, racials) put their aura effects on the player for good: at login, on
 * arrival from another node, and when learned.
 */
module dmangos.world.talenthandlers;

/// See the module documentation.
mixin template TalentHandlers()
{
    import dmangos.bytes : ByteReader;
    import dmangos.log : info;
    import dmangos.world.auras : Aura, makeAura;
    import dmangos.world.clientdata : maxTalentRank;
    import dmangos.world.opcodes;
    import dmangos.world.spellcast : effectValue;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.updatefields;

private:
    /// `HandleLearnTalentOpcode` and `Player::LearnTalent`
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
        flushPlayerChanges();
        info!"%s: '%s' learned talent %s rank %s (spell %s)"(remoteAddress, player.data.name, talentId, rank + 1,
            spellId);
    }

    /**
     * `Player::Reset_Talents`: every talent rank known forgotten (its passive aura gone with it), and
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

    /// A passive spell's aura effects on the player for good (no slot, never ending).
    package void applyPassive(const(SpellInfo)* spell)
    {
        enum uint applyAura = 6;
        if (!spell.isPassive || player.auras.find(spell.id) !is null)
            return;
        // Those bound to a kind of weapon or armour (`IsFitToSpellRequirements`) are not applied yet.
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

    /// `_LoadSpells`' passives: every passive spell known puts its auras on.
    package bool[uint] equipSpells; // the item spells on equip applied now (`ITEM_SPELLTRIGGER_ON_EQUIP`)

    /**
     * `Player::ApplyItemEquipSpell` for every item worn: the on-equip spells of the unbroken items
     * worn are on as auras (lasting while worn); those of items taken off (or broken) go.
     */
    package void refreshEquipSpells()
    {
        import dmangos.world.defines : equipmentSlotEnd;

        enum uint onEquip = 1, applyAura = 6;
        bool[uint] wanted;
        foreach (ubyte slot; 0 .. equipmentSlotEnd)
        {
            const item = player.inventory.equipped(slot);
            if (item is null || item.proto is null || (item.maxDurability && item.durability == 0))
                continue;
            foreach (ref s; item.proto.details.spells)
                if (s.id && s.trigger == onEquip)
                    wanted[s.id] = true;
        }
        foreach (id, _; equipSpells.dup)
            if (id !in wanted)
            {
                if (auto aura = player.auras.find(id))
                    removeAura(aura);
                equipSpells.remove(id);
            }
        foreach (id, _; wanted)
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
                    values[i] = effectValue(*spell, i, player.data.level, 0);
                    any = true;
                }
            if (!any)
                continue;
            auto aura = makeAura(spell, player.guid, player.data.level, -1, true, values);
            aura.passive = true;
            addAura(aura);
            equipSpells[id] = true;
        }
    }

    package void applyPassiveSpells()
    {
        refreshEquipSpells();
        foreach (id; player.spells)
            if (const spell = context.data.spells.spell(id))
                if (spell.isPassive)
                    applyPassive(spell);
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
    context.data.spells.spells[might].casting.applyAuraName[0] = AuraType.modStat;
    context.data.spells.spells[might].miscValue[0] = Stat.strength;
    context.data.items[itemSword].details.spells[0].id = might;
    context.data.items[itemSword].details.spells[0].trigger = 1; // on equip
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto me = cast(Player) anduin.session.character;
    anduin.session.lootStore(itemSword, 1, 0, false);
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
}
