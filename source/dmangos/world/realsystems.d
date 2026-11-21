/**
 * The smaller systems tested on the real data (the client's DBC files and the world database): the auction houses'
 * rates, battleground scoreboards, Alterac Valley's turn-ins, forced reactions and Silithus' texts. Run only where
 * `DMANGOS_REAL_DATA` names the data (`dmangos.world.realspelltests`).
 */
module dmangos.world.realsystems;

version (unittest):

import dmangos.world.realspelltests : haveRealData, RealWorld;

/// The auction houses' rates are AuctionHouse.dbc's: the factions' houses 5% deposit (for each 2 hours) and 5% cut,
/// the goblins' (Blackwater, 7) 25% and 15%; so 2, 8 and 24 hours cost 5%, 20% and 60% of the sell price at a
/// faction's house, five times that at the goblins'. docs/FORMULAS.md, "Auction houses".
unittest
{
    import dmangos.world.auctionhouse : AuctionRecord, auctionDeposit, minAuctionTime;

    if (!haveRealData())
        return;
    auto w = RealWorld.make();
    foreach (id; [1u, 2, 3, 4, 5, 6])
    {
        const house = w.context.client.auctionHouses.lookup(id);
        assert(house !is null && house.depositPercent == 5 && house.cutPercent == 5, "a faction's house: 5% and 5%");
    }
    const goblins = w.context.client.auctionHouses.lookup(7);
    assert(goblins !is null && goblins.depositPercent == 25 && goblins.cutPercent == 15, "the goblins': 25% and 15%");
    const stormwind = w.context.client.auctionHouses.lookup(1);
    // An item sold to a vendor for 1 gold (10000 copper), for 2, 8 and 24 hours.
    assert(auctionDeposit(*stormwind, minAuctionTime, 10_000, 1) == 500);
    assert(auctionDeposit(*stormwind, 4 * minAuctionTime, 10_000, 1) == 2000);
    assert(auctionDeposit(*stormwind, 12 * minAuctionTime, 10_000, 1) == 6000);
    assert(auctionDeposit(*goblins, minAuctionTime, 10_000, 1) == 2500);
    assert(auctionDeposit(*goblins, 12 * minAuctionTime, 10_000, 1) == 30_000);
    AuctionRecord a = {bid: 10_000};
    assert(a.cut(*stormwind) == 500 && a.cut(*goblins) == 1500);
}

/**
 * The Corrupted Ashbringer (22691), wielded: its equip aura (28282, `spell_ashbringer_item`) casts AB Effect 001
 * (28442: `SPELL_AURA_FORCE_REACTION`, faction 56) as friendly; the Scarlet Crusade's reaction is forced and the
 * client told (`SMSG_SET_FORCED_REACTIONS`). Put away, it is not.
 */
unittest
{
    import dmangos.bytes : ByteReader;
    import dmangos.world.defines : inventorySlotBag0;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientItemPos;
    import dmangos.world.relations : ReputationRank;
    import dmangos.world.testclient : bodyOf;

    if (!haveRealData())
        return;
    enum uint ashbringer = 22691, itemAura = 28282, effect001 = 28442, scarletCrusade = 56;
    enum ubyte classPaladin = 2;
    auto w = RealWorld.make();
    auto c = w.character(30, "Mograine", classPaladin, 60, [202]); // Two-Handed Swords
    auto me = c.session.inWorld;
    me.player.setSkill(55, 300, 300); // ditto, the skill
    me.storeLoot(ashbringer, 1, 0, false);
    c.read();
    ubyte slot;
    foreach (ubyte s; 23 .. 39)
        if (const item = me.player.inventory[inventorySlotBag0, s])
            if (item.entry == ashbringer)
                slot = s;
    assert(slot, "the Ashbringer carried");
    c.write(Opcode.CMSG_AUTOEQUIP_ITEM, ClientItemPos(inventorySlotBag0, slot));
    const packets = c.read();
    assert(me.player.inventory.equipped(15) !is null, "wielded");
    assert(me.player.auras.find(itemAura) !is null, "its equip aura");
    assert(me.player.auras.find(effect001) !is null, "AB Effect 001, cast by the aura's script");
    assert(me.forcedReactions.get(scarletCrusade, ReputationRank.hated) == ReputationRank.friendly);
    // The client told, last of all both forced: the Argent Dawn's (529) by the item's own aura, then the Crusade's.
    const(ubyte)[] told;
    foreach (p; packets)
        if (p.opcode == Opcode.SMSG_SET_FORCED_REACTIONS)
            told = p.body_;
    assert(told !is null, "the client told");
    auto r = ByteReader(told);
    uint[uint] listed;
    foreach (i; 0 .. r.read!uint)
    {
        const faction = r.read!uint;
        listed[faction] = r.read!uint;
    }
    assert(listed.get(scarletCrusade, 99) == ReputationRank.friendly && 529 in listed);

    // Into the backpack again: the reaction is the Crusade's own.
    c.write(Opcode.CMSG_AUTOSTORE_BAG_ITEM, cast(const(ubyte)[]) [inventorySlotBag0, ubyte(15), inventorySlotBag0]);
    c.read();
    assert(me.player.inventory.equipped(15) is null, "put away");
    assert(me.player.auras.find(effect001) is null && scarletCrusade !in me.forcedReactions);
}
