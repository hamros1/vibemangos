/**
 * Bodies of the variable-layout packets: the item query response
 * (`WorldSession::HandleItemQuerySingleOpcode`) and chat messages
 * (`ChatHandler::BuildChatPacket`).
 */
module dmangos.world.queries;

import dmangos.bytes;
import dmangos.world.defines : ItemClass;
import dmangos.world.opcodes : ChatType, Language;
import dmangos.world.spells : SpellData;
import dmangos.world.worlddata : ItemTemplate;


/// The body of `SMSG_ITEM_QUERY_SINGLE_RESPONSE` for `item`.
ubyte[] itemQueryResponse(uint entry, const ItemTemplate* item, const SpellData spells)
{
    ByteWriter w;
    if (item is null)
    {
        w.put(entry | 0x8000_0000u); // "no such item"
        return w.data.dup;
    }

    const d = &item.details;
    w.put(entry);
    w.put(item.itemClass);
    w.put(item.itemClass == ItemClass.consumable ? 0u : item.subClass);
    w.putCString(d.name);
    w.put(ubyte(0)); // the other three names are always empty
    w.put(ubyte(0));
    w.put(ubyte(0));
    w.put(item.displayId);
    w.put(d.quality);
    w.put(item.flags);
    w.put(d.buyPrice);
    w.put(d.sellPrice);
    w.put(uint(item.inventoryType));
    w.put(item.allowableClass);
    w.put(item.allowableRace);
    w.put(d.itemLevel);
    w.put(item.requiredLevel);
    w.put(item.requiredSkill);
    w.put(item.requiredSkillRank);
    w.put(item.requiredSpell);
    w.put(item.requiredHonorRank);
    w.put(d.requiredCityRank);
    w.put(item.requiredReputationFaction);
    w.put(item.requiredReputationFaction > 0 ? item.requiredReputationRank : 0u);
    w.put(item.maxCount);
    w.put(item.stackable);
    w.put(item.containerSlots);
    foreach (stat; d.stats)
    {
        w.put(stat.type);
        w.put(stat.value);
    }
    foreach (damage; d.damage)
    {
        w.put(damage.min);
        w.put(damage.max);
        w.put(damage.school);
    }
    w.put(d.armor);
    foreach (resistance; d.resistances)
        w.put(resistance);
    w.put(d.delay);
    w.put(d.ammoType);
    w.put(d.rangedModRange);
    foreach (i, spell; d.spells)
    {
        if (const info = spells.spell(spell.id))
        {
            w.put(spell.id);
            w.put(spell.trigger);
            w.put(item.spellCharges[i]);
            if (spell.cooldown >= 0 || spell.categoryCooldown >= 0)
            {
                w.put(cast(uint) spell.cooldown);
                w.put(item.spellCategory[i]);
                w.put(cast(uint) spell.categoryCooldown);
            }
            else
            {
                w.put(info.recoveryTime);
                w.put(info.category);
                w.put(info.categoryRecoveryTime);
            }
        }
        else
        {
            w.put(0u);
            w.put(0u);
            w.put(0u);
            w.put(uint.max);
            w.put(0u);
            w.put(uint.max);
        }
    }
    w.put(item.bonding);
    w.putCString(d.description);
    w.put(d.pageText);
    w.put(d.languageId);
    w.put(d.pageMaterial);
    w.put(d.startQuest);
    w.put(d.lockId);
    w.put(d.material);
    w.put(d.sheath);
    w.put(item.randomProperty);
    w.put(d.block);
    w.put(d.itemSet);
    w.put(item.maxDurability);
    w.put(d.area);
    w.put(d.map);
    w.put(item.bagFamily);
    return w.data.dup;
}

/// The body of `SMSG_MESSAGECHAT` for the message types a player sends to those around them.
ubyte[] chatMessage(ChatType type, Language language, ulong sender, string text, ubyte chatTag = 0) pure @safe
{
    ByteWriter w;
    w.put(cast(uint) type);
    w.put(cast(uint) language);
    switch (type)
    {
    case ChatType.CHAT_MSG_SAY:
    case ChatType.CHAT_MSG_PARTY:
    case ChatType.CHAT_MSG_YELL:
        w.put(sender);
        w.put(sender);
        break;
    default:
        w.put(sender);
        break;
    }
    w.put(cast(uint)(text.length + 1));
    w.putCString(text);
    w.put(chatTag);
    return w.data.dup;
}

/// `CMSG_MESSAGECHAT`
struct ClientChat
{
    ChatType type;
    Language language;
    string target;  /// whispers: who to
    string channel; /// channel messages: which channel
    string text;

    /// Reads a message; the layout depends on its type.
    static ClientChat read(ref ByteReader reader)
    {
        ClientChat chat;
        chat.type = cast(ChatType) reader.read!uint;
        chat.language = cast(Language) reader.read!uint;
        if (chat.type == ChatType.CHAT_MSG_WHISPER)
            chat.target = reader.readCString();
        else if (chat.type == ChatType.CHAT_MSG_CHANNEL)
            chat.channel = reader.readCString();
        chat.text = reader.readCString();
        return chat;
    }
}

unittest
{
    import dmangos.world.worlddata : ItemSpell;

    auto spells = new SpellData;
    // An unknown item: just the entry with the top bit set.
    const missing = itemQueryResponse(25, null, spells);
    assert(missing == [25, 0, 0, 0x80]);

    // A sword with a name and no spells: the fixed part plus the two strings.
    auto sword = ItemTemplate.display(1542, 21);
    sword.itemClass = 2;
    sword.details.name = "Worn Shortsword";
    const body_ = itemQueryResponse(25, &sword, spells);
    // 113 numbers (3 before the names, 20 item fields, 20 stat, 15 damage, 7 armor and resistance, 3 weapon,
    // 30 spell, 1 bonding, 14 after the description), the name, three empty names and the empty description.
    enum numbers = 3 + 20 + 20 + 15 + 7 + 3 + 30 + 1 + 14;
    assert(body_.length == 4 * numbers + "Worn Shortsword".length + 1 + 3 + 1);
    assert(body_[12 .. 12 + 15] == cast(const(ubyte)[]) "Worn Shortsword");

    // Say: type, language, the sender twice, length with terminator, text, tag.
    const say = chatMessage(ChatType.CHAT_MSG_SAY, Language.LANG_COMMON, 7, "hi");
    assert(say.length == 4 + 4 + 8 + 8 + 4 + 3 + 1);
    assert(say[24 .. 28] == [3, 0, 0, 0] && say[28 .. 31] == ['h', 'i', 0]);
    assert(chatMessage(ChatType.CHAT_MSG_EMOTE, Language.LANG_UNIVERSAL, 7, "waves").length == 4 + 4 + 8 + 4 + 6 + 1);

    // Reading what the client sends.
    ByteWriter w;
    w.put(uint(ChatType.CHAT_MSG_WHISPER));
    w.put(uint(Language.LANG_COMMON));
    w.putCString("Someone");
    w.putCString("hello");
    auto r = ByteReader(w.data);
    const chat = ClientChat.read(r);
    assert(chat.type == ChatType.CHAT_MSG_WHISPER && chat.target == "Someone" && chat.text == "hello");
}
