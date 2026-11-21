/**
 * Auction houses: what an auction is, the house an
 * auctioneer belongs to, deposits, cuts and bid increments, and the auction's line in the lists.
 *
 * The `auction` table is the auctions' one place (with their items in `item_instance`, as mail
 * keeps its items): every node of a cluster reads it for its players' searches, and changes rows
 * only when they are still as it saw them (a bid where the bid was, a removal where the bid was),
 * so that two nodes cannot both sell one auction. Expired auctions are settled by one node, the
 * coordinator (or the lone server). `dmangos.world.auctionhandlers` is the session's side.
 */
module dmangos.world.auctionhouse;

import dmangos.bytes : ByteWriter;

/// The shortest auction: 2 hours; an auction lasts 1, 4 or 12 times as long.
enum uint minAuctionTime = 2 * 60 * 60;

/// Auctions on one page of the client's list.
enum uint auctionPageSize = 50;

/// `AuctionError`
enum AuctionError : uint
{
    ok = 0,
    inventory = 1,
    database = 2,
    notEnoughMoney = 3,
    itemNotFound = 4,
    higherBid = 5,
    bidIncrement = 7,
    bidOwn = 10,
}

/// `AuctionAction`
enum AuctionAction : uint
{
    started = 0,
    removed = 1,
    bidPlaced = 2,
}

/// What an auction mail's subject says happened.
enum AuctionMail : uint
{
    outbidded = 0,
    won = 1,
    successful = 2,
    expired = 3,
    cancelledToBidder = 4,
    cancelled = 5,
}

/// An `AuctionHouse.dbc` row.
struct AuctionHouseEntry
{
    uint houseId;
    uint faction;
    uint depositPercent;
    uint cutPercent;
}

enum auctionHouseFormat = "niiixxxxxxxxx"; ///

/// An `auction` row.
struct AuctionRecord
{
    uint id;
    uint houseId;
    uint itemGuid;
    uint itemEntry;
    uint itemCount;
    int randomPropertyId;
    uint owner;        /// the seller's character guid
    uint buyout;       /// 0: none
    long expireTime;   /// Unix time
    uint bidder;       /// 0: no bid yet
    uint bid;
    uint startBid;
    uint deposit;

    /// The least a new bid adds, 5% of the bid (1 copper at least).
    uint outBid() const pure nothrow @nogc @safe
    {
        const outbid = (bid / 100) * 5;
        return outbid ? outbid : 1;
    }

    /// The house's share of the bid.
    uint cut(const ref AuctionHouseEntry house) const pure nothrow @nogc @safe
    {
        return cast(uint)(house.cutPercent * cast(ulong) bid / 100.0f);
    }

    /**
     * The auction's line in `SMSG_AUCTION_*_LIST_RESULT`, with the time left in
     * milliseconds from `now`.
     */
    void write(ref ByteWriter w, long now) const
    {
        w.put(id);
        w.put(itemEntry);
        w.put(0u); // permanent enchantment
        w.put(randomPropertyId);
        w.put(0u); // suffix factor
        w.put(itemCount);
        w.put(0u); // charges
        w.put(ulong(owner));
        w.put(startBid);
        w.put(bid ? outBid : 0u);
        w.put(buyout);
        w.put(cast(uint)((expireTime > now ? expireTime - now : 0) * 1000));
        w.put(ulong(bidder));
        w.put(bid);
    }
}

/// The deposit: the sell price of the stack for each 2 hours, the house's percentage of it.
uint auctionDeposit(const ref AuctionHouseEntry house, uint seconds, uint sellPrice, uint count) pure nothrow @nogc @safe
{
    // "the base deposit is rounded first, and then multiplied" (WoWWiki "Auction House", 2006-10): the two hours'
    // whole copper, times the two-hour spans (docs/FORMULAS.md "Auctions").
    const base = cast(ulong) sellPrice * count * house.depositPercent / 100;
    return cast(uint)(base * (seconds / minAuctionTime));
}

/**
 * The auction house of an auctioneer of faction template `factionTemplate`:
 * the city's house (Stormwind's, Ironforge's, Darnassus', Undercity's, Thunder Bluff's,
 * Orgrimmar's) or the goblins' neutral one; by the template's faction groups for others.
 */
uint auctionHouseFor(uint factionTemplate, uint factionGroupMask) pure nothrow @nogc @safe
{
    enum uint groupAlliance = 2, groupHorde = 4; // faction group masks
    switch (factionTemplate)
    {
    case 12: return 1;   // human
    case 29: return 6;   // orc, and generic for horde
    case 55: return 2;   // dwarf/gnome, and generic for alliance
    case 68: return 4;   // undead
    case 80: return 3;   // night elf
    case 104: return 5;  // trolls
    case 120: return 7;  // Booty Bay, neutral
    case 474: return 7;  // Gadgetzan, neutral
    case 534: return 2;  // Alliance generic
    case 855: return 7;  // Everlook, neutral
    default:
        if (factionGroupMask & groupAlliance)
            return 1;
        if (factionGroupMask & groupHorde)
            return 6;
        return 7;
    }
}

/// `SMSG_AUCTION_BIDDER_NOTIFICATION`: won it (`won`), or outbid on it.
ubyte[] bidderNotification(const ref AuctionRecord a, bool won)
{
    ByteWriter w;
    w.put(a.houseId);
    w.put(a.id);
    w.put(ulong(a.bidder));
    w.put(won ? 0u : a.bid);
    w.put(a.outBid);
    w.put(a.itemEntry);
    w.put(a.randomPropertyId);
    return w.data.dup;
}

/// `SMSG_AUCTION_OWNER_NOTIFICATION`: sold (`sold`), a new bid on it (with its bidder), or expired (no bid).
ubyte[] ownerNotification(const ref AuctionRecord a, bool sold)
{
    ByteWriter w;
    w.put(a.id);
    w.put(a.bid);
    w.put(a.outBid);
    w.put(sold ? 0UL : ulong(a.bidder));
    w.put(a.itemEntry);
    w.put(a.randomPropertyId);
    return w.data.dup;
}

/// `SMSG_AUCTION_REMOVED_NOTIFICATION`: the auction bid on was cancelled.
ubyte[] removedNotification(const ref AuctionRecord a)
{
    ByteWriter w;
    w.put(a.id);
    w.put(a.itemEntry);
    w.put(a.randomPropertyId);
    return w.data.dup;
}

/// The subject of an auction mail: `item:randomProperty:what`.
string auctionMailSubject(const ref AuctionRecord a, AuctionMail what)
{
    import std.format : format;

    return format!"%s:%s:%s"(a.itemEntry, a.randomPropertyId, cast(uint) what);
}

unittest
{
    const stormwind = AuctionHouseEntry(1, 12, 5, 5); // AuctionHouse.dbc: 5% deposit, 5% cut
    AuctionRecord a = {itemEntry: 2589, itemCount: 20, bid: 1000, buyout: 5000};
    assert(a.outBid == 50 && a.cut(stormwind) == 50);
    a.bid = 10;
    assert(a.outBid == 1, "a copper at least");
    // 20 linen at 13 copper for 8 hours: 5% of 260 for each 2 hours.
    assert(auctionDeposit(stormwind, 8 * 60 * 60, 13, 20) == 52);
    // One fish at 4 copper: 0.2 copper for two hours is none, so none for 24 (WoWWiki's example).
    assert(auctionDeposit(stormwind, 24 * 60 * 60, 4, 1) == 0 && auctionDeposit(stormwind, 24 * 60 * 60, 4, 20) == 48);
    assert(auctionHouseFor(12, 0) == 1 && auctionHouseFor(29, 0) == 6 && auctionHouseFor(120, 0) == 7);
    assert(auctionHouseFor(1, 2) == 1 && auctionHouseFor(2, 4) == 6 && auctionHouseFor(3, 0) == 7);
    assert(auctionMailSubject(a, AuctionMail.won) == "2589:0:1");
}
