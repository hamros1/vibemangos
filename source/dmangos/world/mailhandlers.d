/**
 * Mail (CMaNGOS `Mails/MailHandler.cpp` and `MailDraft`), mixed into `dmangos.world.character.Character`.
 *
 * At a mailbox a player sends a letter to a character of its faction (30 copper), with an item,
 * money or cash on delivery; reads its letters (`mail`, newest last, 50 at most); takes their money
 * and items (paying what is due on delivery, which goes back to the sender by mail); copies a body
 * as a letter item; returns or deletes them. A letter with an item or money to another account
 * arrives an hour later (`mail_delivery_delay`); others at once, with "you have new mail" if the
 * receiver is online here. The database holds it all and is read each time, so a player sees its
 * mail whichever node simulates it.
 *
 * Not yet: letters expiring after their 30 days (or 3 with cash on delivery), mail from NPCs and
 * auctions, `.send mail` commands.
 */
module dmangos.world.mailhandlers;

/// `MailResponseType`
enum MailAction : uint
{
    send = 0,
    moneyTaken = 1,
    itemTaken = 2,
    returnedToSender = 3,
    deleted = 4,
    madePermanent = 5,
}

/// `MailResponseResult`
enum MailError : uint
{
    ok = 0,
    equipError = 1,
    cannotSendToSelf = 2,
    notEnoughMoney = 3,
    recipientNotFound = 4,
    notYourTeam = 5,
    internalError = 6,
    recipientCapReached = 15,
    attachmentInvalid = 19,
}

/// `MailCheckMask`
enum uint mailRead = 0x01, mailReturned = 0x02, mailCopied = 0x04, mailCodPayment = 0x08, mailHasBody = 0x10;

/// `MAIL_BODY_ITEM_TEMPLATE`: the Plain Letter a body is copied to.
enum uint mailBodyItem = 8383;

/// The postage of a letter (`HandleSendMail`'s 30 copper).
enum uint postage = 30;

/// See the module documentation.
mixin template MailHandlers()
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info;
    import dmangos.world.clientdata : Team;
    import dmangos.world.database : MailRecord;
    import dmangos.world.defines : nullBag, nullSlot;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.inventory : InventoryResult, Item, ItemPosCount;
    import dmangos.world.mailhandlers;
    import dmangos.world.names : normalizePlayerName;
    import dmangos.world.opcodes;
    import dmangos.world.updatefields;

private:
    /// `CheckMailBox`: a mailbox (game object type 19) within reach.
    bool nearMailbox(ulong guid)
    {
        enum uint typeMailbox = 19;
        auto box = cast(GameObject) map.findObject(guid);
        if (box is null || box.template_.type != typeMailbox)
            return false;
        const a = player.position, b = box.position;
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2 <= 10.0f ^^ 2;
    }

    /// `Player::SendMailResult`
    void sendMailResult(uint mailId, MailAction action, MailError error, uint equipError = 0, uint itemGuid = 0,
        uint itemCount = 0)
    {
        ByteWriter w;
        w.put(mailId);
        w.put(cast(uint) action);
        w.put(cast(uint) error);
        if (error == MailError.equipError)
            w.put(equipError);
        else if (action == MailAction.itemTaken)
        {
            w.put(itemGuid);
            w.put(itemCount);
        }
        deliver(Opcode.SMSG_SEND_MAIL_RESULT, w.data);
    }

    /**
     * `MailDraft::SendMailTo`: a letter into the database, delivered after `delay` seconds; the
     * receiver, if online here and it is delivered now, hears of it.
     */
    package void postMail(MailRecord mail, uint delay)
    {
        context.postMail(mail, delay);
    }

    /// `HandleSendMail`
    @Handles(Opcode.CMSG_SEND_MAIL, WorldState.inWorld)
    void handleSendMail(ref ByteReader reader)
    {
        const mailbox = reader.read!ulong;
        string receiverName = reader.readCString();
        const subject = reader.readCString(), body = reader.readCString(512 * 8);
        reader.read!uint; // stationery
        reader.read!uint;
        const itemGuid = reader.read!ulong;
        const money = reader.read!uint, cod = reader.read!uint;
        if (!nearMailbox(mailbox) || receiverName.length == 0)
            return;
        const receiver = normalizePlayerName(receiverName) ? context.database.characterGuid(receiverName) : 0;
        if (receiver == 0)
            return sendMailResult(0, MailAction.send, MailError.recipientNotFound);
        if (receiver == player.data.guid)
            return sendMailResult(0, MailAction.send, MailError.cannotSendToSelf);
        if (player.money < money + postage)
            return sendMailResult(0, MailAction.send, MailError.notEnoughMoney);
        const raceAccount = context.database.characterRaceAccount(receiver);
        if (context.client.teamForRace(cast(ubyte) raceAccount[0]) != context.client.teamForRace(player.data.race)
            && !hasPermissions)
            return sendMailResult(0, MailAction.send, MailError.notYourTeam);
        if (context.database.loadMail(receiver).length > 100)
            return sendMailResult(0, MailAction.send, MailError.recipientCapReached);
        Item item;
        if (itemGuid)
        {
            item = itemByGuid(itemGuid);
            if (item is null || !canBeTraded(item) || item.values[ITEM_FIELD_DURATION])
                return sendMailResult(0, MailAction.send, MailError.attachmentInvalid);
        }
        sendMailResult(0, MailAction.send, MailError.ok);
        player.modifyMoney(-cast(long)(money + postage));
        MailRecord mail;
        mail.sender = player.data.guid;
        mail.receiver = receiver;
        mail.subject = subject;
        mail.money = money;
        mail.cod = item is null ? 0 : cod;
        mail.checked = body.length ? mailHasBody : mailCopied;
        if (body.length)
        {
            mail.itemTextId = context.nextMailId();
            context.database.saveItemText(mail.itemTextId, body);
        }
        if (item !is null)
        {
            // Out of the sender's bags (its rows deleted), kept for the receiver until it takes it.
            auto record = item.record;
            mail.itemGuid = record.guid;
            mail.itemEntry = record.entry;
            player.inventory.destroy(item.bagSlot, item.slot);
            flushInventory(true);
            record.bag = 0;
            context.database.saveLooseItem(record, receiver);
        }
        else
            flushInventory(true);
        const delay = (item !is null || money) && raceAccount[1] != account.id ? context.config.mailDeliveryDelay : 0;
        postMail(mail, delay);
        info!"%s: '%s' mailed %s (item %s, %s copper, %s on delivery)"(remoteAddress, player.data.name, receiverName,
            mail.itemEntry, money, mail.cod);
    }

    /// The player's letter `id`, delivered; null otherwise.
    MailRecord* deliveredMail(uint id)
    {
        auto found = context.database.mailById(id);
        if (found.isNull || found.get.receiver != player.data.guid || found.get.deliverTime > context.unixTime)
            return null;
        auto mail = new MailRecord;
        *mail = found.get;
        return mail;
    }

    /// `HandleGetMailList`: the delivered letters, 50 at most.
    @Handles(Opcode.CMSG_GET_MAIL_LIST, WorldState.inWorld)
    void handleGetMailList(ref ByteReader reader)
    {
        if (!nearMailbox(reader.read!ulong))
            return;
        const now = context.unixTime;
        ByteWriter list;
        ubyte count;
        foreach (ref m; context.database.loadMail(player.data.guid))
        {
            if (count >= 50)
                break;
            if (m.deliverTime > now)
                continue;
            list.put(m.id);
            list.put(m.messageType);
            if (m.messageType == 0)
                list.put(ulong(m.sender));
            else
                list.put(m.sender);
            list.putCString(m.subject);
            list.put(m.itemTextId);
            list.put(0u);
            list.put(uint(m.stationery));
            auto item = m.itemGuid ? context.database.looseItem(m.itemGuid) : typeof(context.database.looseItem(0)).init;
            const has = !item.isNull;
            list.put(has ? item.get.entry : 0u);
            list.put(0u); // permanent enchantment
            list.put(has ? cast(uint) item.get.randomPropertyId : 0u);
            list.put(0u); // suffix factor
            list.put(cast(ubyte)(has ? item.get.count : 0));
            list.put(0u); // charges
            const proto = has ? item.get.entry in context.data.items : null;
            list.put(proto is null ? 0u : proto.maxDurability);
            list.put(has ? item.get.durability : 0u);
            list.put(m.money);
            list.put(m.cod);
            list.put(m.checked);
            list.put(cast(float)(m.expireTime - now) / (24 * 60 * 60));
            list.put(m.templateId);
            ++count;
        }
        ByteWriter w;
        w.put(count);
        w.putBytes(list.data);
        deliver(Opcode.SMSG_MAIL_LIST_RESULT, w.data);
    }

    /// `HandleMailTakeMoney`
    @Handles(Opcode.CMSG_MAIL_TAKE_MONEY, WorldState.inWorld)
    void handleMailTakeMoney(ref ByteReader reader)
    {
        const mailbox = reader.read!ulong, id = reader.read!uint;
        if (!nearMailbox(mailbox))
            return;
        auto mail = deliveredMail(id);
        if (mail is null)
            return sendMailResult(id, MailAction.moneyTaken, MailError.internalError);
        sendMailResult(id, MailAction.moneyTaken, MailError.ok);
        player.modifyMoney(mail.money);
        mail.money = 0;
        context.database.updateMail(*mail);
        flushInventory(true);
    }

    /// `HandleMailTakeItem`: into the bags; cash on delivery paid, and mailed to the sender.
    @Handles(Opcode.CMSG_MAIL_TAKE_ITEM, WorldState.inWorld)
    void handleMailTakeItem(ref ByteReader reader)
    {
        const mailbox = reader.read!ulong, id = reader.read!uint;
        if (!nearMailbox(mailbox))
            return;
        auto mail = deliveredMail(id);
        if (mail is null || mail.itemGuid == 0)
            return sendMailResult(id, MailAction.itemTaken, MailError.internalError);
        if (player.money < mail.cod)
            return sendMailResult(id, MailAction.itemTaken, MailError.notEnoughMoney);
        const record = context.database.looseItem(mail.itemGuid);
        const proto = record.isNull ? null : record.get.entry in context.data.items;
        if (proto is null)
            return sendMailResult(id, MailAction.itemTaken, MailError.internalError);
        auto item = Item.load(record.get, proto, player.guid);
        ItemPosCount[] dest;
        ubyte bagSlot;
        const result = player.inventory.canStore(nullBag, nullSlot, dest, item, false, bagSlot);
        if (result != InventoryResult.ok)
            return sendMailResult(id, MailAction.itemTaken, MailError.equipError, result);
        if (mail.cod)
        {
            MailRecord payment;
            payment.sender = player.data.guid;
            payment.receiver = mail.sender;
            payment.subject = mail.subject;
            payment.money = mail.cod;
            payment.checked = mailCodPayment;
            postMail(payment, 0);
            player.modifyMoney(-cast(long) mail.cod);
            mail.cod = 0;
        }
        const count = item.count, entry = item.entry;
        player.inventory.store(dest, item);
        mail.itemGuid = 0;
        mail.itemEntry = 0;
        context.database.updateMail(*mail);
        flushInventory(true);
        sendMailResult(id, MailAction.itemTaken, MailError.ok, 0, entry, count);
    }

    /// `HandleMailMarkAsRead`
    @Handles(Opcode.CMSG_MAIL_MARK_AS_READ, WorldState.inWorld)
    void handleMailMarkAsRead(ref ByteReader reader)
    {
        const mailbox = reader.read!ulong, id = reader.read!uint;
        if (!nearMailbox(mailbox))
            return;
        if (auto mail = deliveredMail(id))
        {
            mail.checked |= mailRead;
            context.database.updateMail(*mail);
        }
    }

    /// `HandleMailDelete`: not one with cash on delivery.
    @Handles(Opcode.CMSG_MAIL_DELETE, WorldState.inWorld)
    void handleMailDelete(ref ByteReader reader)
    {
        const mailbox = reader.read!ulong, id = reader.read!uint;
        if (!nearMailbox(mailbox))
            return;
        if (auto mail = deliveredMail(id))
        {
            if (mail.cod)
                return sendMailResult(id, MailAction.deleted, MailError.internalError);
            context.database.deleteMail(id);
        }
        sendMailResult(id, MailAction.deleted, MailError.ok);
    }

    /// `HandleMailReturnToSender`: back to its sender with what is still in it.
    @Handles(Opcode.CMSG_MAIL_RETURN_TO_SENDER, WorldState.inWorld)
    void handleMailReturnToSender(ref ByteReader reader)
    {
        const mailbox = reader.read!ulong, id = reader.read!uint;
        if (!nearMailbox(mailbox))
            return;
        auto mail = deliveredMail(id);
        if (mail is null)
            return sendMailResult(id, MailAction.returnedToSender, MailError.internalError);
        context.database.deleteMail(id);
        if (mail.messageType == 0 && mail.sender)
        {
            MailRecord back;
            back.sender = player.data.guid;
            back.receiver = mail.sender;
            back.subject = mail.subject;
            back.itemTextId = mail.itemTextId;
            back.money = mail.money;
            back.itemGuid = mail.itemGuid;
            back.itemEntry = mail.itemEntry;
            back.checked = mailReturned;
            if (back.itemGuid)
                if (auto item = context.database.looseItem(back.itemGuid))
                    context.database.saveLooseItem(item.get, back.receiver);
            const senderAccount = context.database.characterRaceAccount(mail.sender)[1];
            postMail(back, (back.itemGuid || back.money) && senderAccount != account.id
                ? context.config.mailDeliveryDelay : 0);
        }
        sendMailResult(id, MailAction.returnedToSender, MailError.ok);
    }

    /// `HandleMailCreateTextItem`: the body copied as a Plain Letter.
    @Handles(Opcode.CMSG_MAIL_CREATE_TEXT_ITEM, WorldState.inWorld)
    void handleMailCreateTextItem(ref ByteReader reader)
    {
        const mailbox = reader.read!ulong, id = reader.read!uint;
        if (!nearMailbox(mailbox))
            return;
        auto mail = deliveredMail(id);
        if (mail is null || mail.itemTextId == 0)
            return sendMailResult(id, MailAction.madePermanent, MailError.internalError);
        ItemPosCount[] dest;
        const result = player.inventory.canStoreNew(nullBag, nullSlot, dest, mailBodyItem, 1);
        if (result != InventoryResult.ok)
            return sendMailResult(id, MailAction.madePermanent, MailError.equipError, result);
        if (auto letter = player.inventory.storeNew(dest, mailBodyItem))
        {
            letter.values.set!ITEM_FIELD_ITEM_TEXT_ID(mail.itemTextId);
            letter.values.set!ITEM_FIELD_CREATOR(ulong(mail.sender));
        }
        mail.checked |= mailCopied;
        context.database.updateMail(*mail);
        flushInventory();
        sendMailResult(id, MailAction.madePermanent, MailError.ok);
    }

    /// `HandleItemTextQuery`: a body (of a letter, or of a Plain Letter).
    @Handles(Opcode.CMSG_ITEM_TEXT_QUERY, WorldState.inWorld)
    void handleItemTextQuery(ref ByteReader reader)
    {
        const textId = reader.read!uint;
        ByteWriter w;
        w.put(textId);
        w.putCString(context.database.itemText(textId));
        deliver(Opcode.SMSG_ITEM_TEXT_QUERY_RESPONSE, w.data);
    }

    /// `HandleQueryNextMailTime`: 0 if there is unread mail, else a day ago.
    @Handles(Opcode.MSG_QUERY_NEXT_MAIL_TIME, WorldState.inWorld)
    void handleQueryNextMailTime()
    {
        const now = context.unixTime;
        bool unread;
        foreach (ref m; context.database.loadMail(player.data.guid))
            if (m.deliverTime <= now && !(m.checked & mailRead))
                unread = true;
        ByteWriter w;
        w.put(unread ? 0.0f : -86_400.0f);
        deliver(Opcode.MSG_QUERY_NEXT_MAIL_TIME, w.data);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * Anduin mails Jaina jerky, 10 copper and a few words; it comes an hour later (another account);
 * she takes the money and the jerky, reads the words, and deletes the letter.
 */
unittest
{
    import core.time : hours, MonoTime;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.defines : nullBag, nullSlot;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.inventory : InventoryResult, ItemPosCount;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8941, -140, 83));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8939, -140, 83));
    anduin.read();
    jaina.read();
    auto a = cast(Player) anduin.session.character, j = cast(Player) jaina.session.character;
    const mailbox = makeGuid(HighGuid.gameObject, 32349, 26880);
    assert(cast(GameObject) context.map(0).findObject(mailbox) !is null);
    ItemPosCount[] dest;
    assert(a.inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 5) == InventoryResult.ok);
    auto jerky = a.inventory.storeNew(dest, itemJerky);
    a.modifyMoney(100);

    ByteWriter send;
    send.put(mailbox);
    send.putCString("jaina");
    send.putCString("Supper");
    send.putCString("Eat well.");
    send.put(41u);
    send.put(0u);
    send.put(jerky.fullGuid);
    send.put(10u);
    send.put(0u);
    send.put(0UL);
    send.put(ubyte(0));
    anduin.write(Opcode.CMSG_SEND_MAIL, send.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_SEND_MAIL_RESULT));
    assert(a.money == 60 && a.inventory.count(itemJerky) == 0, "the postage, the money and the jerky are gone");

    ubyte[] listRequest()
    {
        ByteWriter w;
        w.put(mailbox);
        return w.data.dup;
    }

    uint[] listed()
    {
        jaina.write(Opcode.CMSG_GET_MAIL_LIST, listRequest());
        auto reply = jaina.read();
        auto r = ByteReader(reply[$ - 1].body_);
        uint[] ids;
        foreach (_; 0 .. r.read!ubyte)
        {
            ids ~= r.read!uint;
            r.read!ubyte;
            r.read!ulong;
            r.readCString();
            r.readBytes(4 * 3 + 4 * 4 + 1 + 4 * 6 + 4 + 4);
        }
        return ids;
    }

    assert(listed().length == 0, "not yet: an hour for items to another account");
    now += 1.hours;
    const ids = listed();
    assert(ids.length == 1);

    ubyte[] onMail(uint id)
    {
        ByteWriter w;
        w.put(mailbox);
        w.put(id);
        return w.data.dup;
    }

    jaina.write(Opcode.CMSG_MAIL_TAKE_MONEY, onMail(ids[0]));
    jaina.write(Opcode.CMSG_MAIL_TAKE_ITEM, onMail(ids[0]));
    jaina.read();
    assert(j.money == 10 && j.inventory.count(itemJerky) == 5, "her jerky and money now");

    const mail = db.mails[ids[0]];
    ByteWriter text;
    text.put(mail.itemTextId);
    text.put(ids[0]);
    text.put(0u);
    jaina.write(Opcode.CMSG_ITEM_TEXT_QUERY, text.data);
    auto words = jaina.read();
    auto r = ByteReader(words[0].body_);
    r.read!uint;
    assert(r.readCString() == "Eat well.");

    jaina.write(Opcode.CMSG_MAIL_DELETE, onMail(ids[0]));
    jaina.read();
    assert(ids[0] !in db.mails);
}

/**
 * `ReturnOrDeleteOldMails`: a player's letter with an item, its time up, goes back to its sender
 * (once); one without an item, or already returned, is deleted with its item.
 */
unittest
{
    import core.time : MonoTime;
    import std.algorithm.searching : canFind;
    import dmangos.world.database : MailRecord;
    import dmangos.world.inventory : ItemRecord;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const past = context.unixTime - 10;
    ItemRecord sword;
    sword.guid = 5001;
    sword.entry = itemSword;
    sword.count = 1;
    db.saveLooseItem(sword, 8);
    auto withSword = MailRecord(901, 0, 41, 0, 7, 8, "a sword", 0, past, past, 0, 0, 0, 5001, itemSword);
    auto note = MailRecord(902, 0, 41, 0, 7, 8, "hello", 0, past, past, 0, 0, 0, 0, 0);
    db.sendMail(withSword);
    db.sendMail(note);
    context.update(now);
    auto mine = db.loadMail(7);
    assert(db.mailById(901).isNull && db.mailById(902).isNull, "both gone from the receiver");
    assert(mine.length == 1 && mine[0].itemGuid == 5001 && mine[0].checked == mailReturned, "the sword back to its sender");
    assert(!db.looseItem(5001).isNull);

    // Returned once already: next time it is deleted, with the sword.
    auto back = mine[0];
    db.deleteMail(back.id);
    back.expireTime = past;
    db.sendMail(back);
    import core.time : hours;

    now += 2.hours;
    context.update(now);
    assert(db.loadMail(7).length == 0 && db.loadMail(8).length == 0 && db.looseItem(5001).isNull, "deleted");
}
