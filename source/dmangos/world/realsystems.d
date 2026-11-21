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
