/**
 * Mail and auctions settled outside a session: mail posted (by the game, a script, the auction house), auctions
 * over settled once a minute, old mail returned or deleted once an hour, by one node of the cluster
 * (`WorldContext.postOffice`).
 */
module dmangos.world.postoffice;

import core.time : MonoTime;
import dmangos.world.auctionhouse;
import dmangos.world.database : MailRecord;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class PostOffice
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /**
     * Posts a letter: into the database, delivered after `delay` seconds; the
     * receiver, if online on any node and it is delivered now, hears of it.
     */
    void postMail(MailRecord mail, uint delay)
    {
        import dmangos.world.opcodes : Opcode;

        const now = world.unixTime;
        mail.id = world.nextMailId();
        mail.deliverTime = now + delay;
        mail.expireTime = mail.deliverTime + (mail.cod ? 3 : 30) * 24 * 60 * 60;
        world.database.sendMail(mail);
        if (delay == 0)
            world.deliverTo(mail.receiver, Opcode.SMSG_RECEIVED_MAIL, [ubyte(0), 0, 0, 0]);
    }

    /**
     * A mail from the auction house of `a` (the house as its sender): its subject
     * says what happened; `money`, the auctioned item (handed to the receiver) and a body as given.
     * A note with neither money nor item comes an hour later.
     */
    void auctionMail(uint receiver, const ref AuctionRecord a, AuctionMail what, uint money, bool withItem,
        string body = null)
    {
        enum ubyte mailAuction = 2, stationeryAuction = 62;
        enum uint checkCopied = 0x04;
        MailRecord m;
        m.messageType = mailAuction;
        m.stationery = stationeryAuction;
        m.sender = a.houseId;
        m.receiver = receiver;
        m.subject = auctionMailSubject(a, what);
        m.money = money;
        m.checked = checkCopied;
        if (body.length)
        {
            m.itemTextId = world.nextMailId();
            world.database.saveItemText(m.itemTextId, body);
        }
        if (withItem && a.itemGuid)
        {
            m.itemGuid = a.itemGuid;
            m.itemEntry = a.itemEntry;
            auto item = world.database.looseItem(a.itemGuid);
            if (!item.isNull)
                world.database.saveLooseItem(item.get, receiver); // now the receiver's
        }
        postMail(m, !withItem && !money ? 60 * 60 : 0);
    }

    /// The house of an auction (Stormwind's if it is not known).
    const(AuctionHouseEntry)* auctionHouse(uint houseId)
    {
        auto house = world.client.auctionHouses.lookup(houseId);
        return house !is null ? house : world.client.auctionHouses.lookup(1);
    }

    /**
     * An auction won, once it is out of the table: the seller gets the bid and its
     * deposit back less the house's cut, the buyer the item, and both hear of it if they are
     * online.
     */
    void auctionSold(const ref AuctionRecord a)
    {
        import std.format : format;
        import dmangos.world.opcodes : Opcode;

        const house = auctionHouse(a.houseId);
        const cut = house is null ? 0 : a.cut(*house, world.config.rateAuctionCut);
        world.deliverTo(a.owner, Opcode.SMSG_AUCTION_OWNER_NOTIFICATION, ownerNotification(a, true));
        auctionMail(a.owner, a, AuctionMail.successful, a.bid + a.deposit - cut, false,
            format!"%16x:%s:%s:%s:%s"(a.bidder, a.bid, a.buyout, a.deposit, cut));
        world.deliverTo(a.bidder, Opcode.SMSG_AUCTION_BIDDER_NOTIFICATION, bidderNotification(a, true));
        auctionMail(a.bidder, a, AuctionMail.won, 0, true, format!"%16x:%s:%s"(a.owner, a.bid, a.buyout));
    }

    /// An auction expired: nobody bid; the item goes back to the seller.
    void auctionExpired(const ref AuctionRecord a)
    {
        import dmangos.world.opcodes : Opcode;

        world.deliverTo(a.owner, Opcode.SMSG_AUCTION_OWNER_NOTIFICATION, ownerNotification(a, false));
        auctionMail(a.owner, a, AuctionMail.expired, 0, true);
    }

    /// Outbid: the bid of `old` (the auction as it was) back to its bidder.
    void auctionOutbid(const ref AuctionRecord old)
    {
        import dmangos.world.opcodes : Opcode;

        world.deliverTo(old.bidder, Opcode.SMSG_AUCTION_BIDDER_NOTIFICATION, bidderNotification(old, false));
        auctionMail(old.bidder, old, AuctionMail.outbidded, old.bid, false);
    }

    /// The auctions over are settled (here only on the coordinator, or alone).
    package void settleAuctions()
    {
        foreach (ref a; world.database.expiredAuctions(world.unixTime))
        {
            if (!world.database.deleteAuction(a.id, a.bid))
                continue; // settled meanwhile (bought out)
            if (a.bid)
                auctionSold(a);
            else
                auctionExpired(a);
        }
    }

    package MonoTime lastAuctionCheck, lastMailCheck;

    /**
     * Each tick, on one node: auctions over are settled once a minute, first at the first tick, and old mail once an
     * hour. (Not `now - init`: MonoTime counts from the machine's start, so that is its uptime, and an hour's check
     * would wait for the first hour after a reboot.)
     */
    void update(MonoTime now)
    {
        import core.time : minutes, seconds;

        if (lastAuctionCheck == MonoTime.init || now - lastAuctionCheck >= 60.seconds)
        {
            lastAuctionCheck = now;
            settleAuctions();
        }
        if (lastMailCheck == MonoTime.init || now - lastMailCheck >= 60.minutes)
        {
            lastMailCheck = now;
            settleOldMail();
        }
    }

    /**
     * Old mail: a player's letter with an item, not returned or paid for
     * before, goes back to its sender for 30 days more; every other one whose time is up is deleted,
     * with its item and its body.
     */
    package void settleOldMail()
    {
        enum uint checkReturned = 0x02, checkCodPayment = 0x08;
        foreach (ref m; world.database.expiredMail(world.unixTime))
        {
            world.database.deleteMail(m.id);
            // "After the expiry period the mail is returned to the sender" with its item or money; the auction
            // house's and NPCs' is discarded (WoWWiki "Mail", 2006-11; docs/FORMULAS.md "Mail").
            if ((m.itemGuid || m.money) && m.messageType == 0 && m.sender
                && !(m.checked & (checkReturned | checkCodPayment)))
            {
                MailRecord back;
                back.money = m.money;
                back.sender = m.receiver;
                back.receiver = m.sender;
                back.subject = m.subject;
                back.itemTextId = m.itemTextId;
                back.itemGuid = m.itemGuid;
                back.itemEntry = m.itemEntry;
                back.checked = checkReturned;
                if (back.itemGuid)
                    if (auto item = world.database.looseItem(back.itemGuid))
                        world.database.saveLooseItem(item.get, back.receiver);
                postMail(back, 0);
                continue;
            }
            if (m.itemGuid)
                world.database.deleteLooseItem(m.itemGuid);
        }
    }
}
