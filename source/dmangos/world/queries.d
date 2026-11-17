/**
 * Bodies of the variable-layout packets: the item query response
 * (`WorldSession::HandleItemQuerySingleOpcode`) and chat messages
 * (`ChatHandler::BuildChatPacket`).
 */
module dmangos.world.queries;

import dmangos.bytes;
import dmangos.world.creature : CreatureTemplate;
import dmangos.world.defines : ItemClass;
import dmangos.world.gameobject : GameObjectTemplate;
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

/// `WorldSession::HandleCreatureQueryOpcode`: the name, title and kind of a creature; the entry with its top
/// bit set if there is none.
ubyte[] creatureQueryResponse(uint entry, const(CreatureTemplate)* t) pure @safe
{
    ByteWriter w;
    if (t is null)
    {
        w.put(entry | 0x8000_0000);
        return w.data.dup;
    }
    w.put(entry);
    w.putCString(t.name);
    w.put(ubyte(0));
    w.put(ubyte(0));
    w.put(ubyte(0)); // the other three names
    w.putCString(t.subName);
    w.put(t.typeFlags);
    w.put(t.creatureType);
    w.put(t.family);
    w.put(t.rank);
    w.put(uint(0));
    w.put(t.petSpellDataId);
    w.put(t.modelIds[0]);
    w.put(cast(ushort) t.civilian);
    return w.data.dup;
}

/// `WorldSession::HandleGameObjectQueryOpcode`: type, model, name, icon and the 24 data fields.
ubyte[] gameObjectQueryResponse(uint entry, const(GameObjectTemplate)* t) pure @safe
{
    ByteWriter w;
    if (t is null)
    {
        w.put(entry | 0x8000_0000);
        return w.data.dup;
    }
    w.put(entry);
    w.put(t.type);
    w.put(t.displayId);
    w.putCString(t.name);
    w.put(ubyte(0));
    w.put(ubyte(0));
    w.put(ubyte(0)); // the other three names
    w.putCString(""); // the icon name; classic-db has none
    foreach (value; t.data)
        w.put(value);
    return w.data.dup;
}

/**
 * `ChatHandler::BuildChatPacket`: the body of `SMSG_MESSAGECHAT` for the message types a player
 * sends. `channel` is the channel's name for `CHAT_MSG_CHANNEL`.
 */
ubyte[] chatMessage(ChatType type, Language language, ulong sender, string text, ubyte chatTag = 0,
    string channel = null) pure @safe
{
    ByteWriter w;
    w.put(cast(ubyte) type); // one byte here, though the client sends it as a uint32
    w.put(cast(uint) language);
    switch (type)
    {
    case ChatType.CHAT_MSG_SAY:
    case ChatType.CHAT_MSG_PARTY:
    case ChatType.CHAT_MSG_YELL:
        w.put(sender);
        w.put(sender);
        break;
    case ChatType.CHAT_MSG_CHANNEL:
        w.putCString(channel);
        w.put(uint(0)); // the speaker's PvP rank
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

/// `ChatHandler::BuildChatPacket` for a creature's say, yell, emote or whisper: its name, and whom it addresses.
ubyte[] monsterChatMessage(ChatType type, ulong sender, string name, string text,
    Language language = Language.LANG_UNIVERSAL, ulong target = 0) pure @safe
{
    ByteWriter w;
    w.put(cast(ubyte) type);
    w.put(cast(uint) language);
    // Says and yells name their speaker's guid first; emotes and whispers do not.
    if (type == ChatType.CHAT_MSG_MONSTER_SAY || type == ChatType.CHAT_MSG_MONSTER_YELL)
        w.put(sender);
    w.put(cast(uint)(name.length + 1));
    w.putCString(name);
    w.put(target); // the listener
    w.put(cast(uint)(text.length + 1));
    w.putCString(text);
    w.put(ubyte(0));
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
    CreatureTemplate hogger;
    hogger.name = "Hogger";
    hogger.modelId1 = 384;
    hogger.rank = 1;
    const reply = creatureQueryResponse(448, &hogger);
    assert(reply[0 .. 4] == [0xC0, 1, 0, 0] && reply[4 .. 11] == "Hogger\0");
    assert(reply.length == 4 + 7 + 3 + 1 + 4 * 7 + 2, "entry, name, empty names, title, seven numbers, civilian");
    assert(creatureQueryResponse(5, null) == [5, 0, 0, 0x80]);
    GameObjectTemplate mailbox;
    mailbox.name = "Mailbox";
    assert(gameObjectQueryResponse(32349, &mailbox).length == 4 * 3 + 8 + 3 + 1 + 24 * 4);
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

    // Say: the type (uint8, as BuildChatPacket writes it), language, the sender twice, length with the
    // terminator, text, tag.
    const say = chatMessage(ChatType.CHAT_MSG_SAY, Language.LANG_COMMON, 7, "hi");
    assert(say.length == 1 + 4 + 8 + 8 + 4 + 3 + 1);
    assert(say[0] == 0 && say[1 .. 5] == [7, 0, 0, 0] && say[5] == 7);
    assert(say[21 .. 25] == [3, 0, 0, 0] && say[25 .. 28] == ['h', 'i', 0]);
    assert(chatMessage(ChatType.CHAT_MSG_EMOTE, Language.LANG_UNIVERSAL, 7, "waves").length == 1 + 4 + 8 + 4 + 6 + 1);
    // A channel message: the channel's name and the rank before the sender.
    const inChannel = chatMessage(ChatType.CHAT_MSG_CHANNEL, Language.LANG_COMMON, 7, "hi", 0, "world");
    assert(inChannel[5 .. 11] == "world\0" && inChannel[11 .. 15] == [0, 0, 0, 0] && inChannel[15] == 7);

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

/// `CMSG_WHO`: what /who asks for (`WorldSession::HandleWhoOpcode`).
struct ClientWho
{
    uint levelMin, levelMax;
    string name, guild;   /// parts of them, any case
    uint raceMask, classMask;
    uint[] zones;         /// at most 10
    string[] strings;     /// at most 4: parts of a name, guild or zone

    static ClientWho read(ref ByteReader r)
    {
        import std.exception : enforce;

        ClientWho who;
        who.levelMin = r.read!uint;
        who.levelMax = r.read!uint;
        who.name = r.readCString();
        who.guild = r.readCString();
        who.raceMask = r.read!uint;
        who.classMask = r.read!uint;
        const zoneCount = r.read!uint;
        enforce!PacketException(zoneCount <= 10, "too many zones in a who request");
        foreach (_; 0 .. zoneCount)
            who.zones ~= r.read!uint;
        const stringCount = r.read!uint;
        enforce!PacketException(stringCount <= 4, "too many strings in a who request");
        foreach (_; 0 .. stringCount)
            who.strings ~= r.readCString();
        return who;
    }
}

/// One player of the who list.
struct WhoEntry
{
    string name, guild;
    uint level, classId, race, zone;
    uint team;
    uint security;
}

/**
 * The `SMSG_WHO` body for `request`, from `candidates`, as `HandleWhoOpcode` chooses them: a player
 * (security 0) sees only its own team unless `twoSide`, and no one above `gmLevel`; then the level
 * range (a maximum of 100 or more means any), the class and race masks, the zones, and the name, guild
 * and strings as parts, in any case (`areaName` gives a zone's name for the strings). At most 49 are
 * listed; the count of matches is capped at `maxReturns` (0: no cap).
 */
const(ubyte)[] whoList(const ref ClientWho request, const(WhoEntry)[] candidates, uint viewerTeam, uint viewerSecurity,
    bool twoSide, uint gmLevel, uint maxReturns, scope string delegate(uint zone) areaName)
{
    import std.algorithm.searching : canFind;
    import std.uni : toLower;

    const levelMax = request.levelMax >= 100 ? 255 : request.levelMax;
    const name = request.name.toLower, guild = request.guild.toLower;
    string[] strings;
    foreach (s; request.strings)
        strings ~= s.toLower;
    uint matches, shown;
    ByteWriter entries;
    foreach (ref p; candidates)
    {
        if (viewerSecurity == 0 && ((p.team != viewerTeam && !twoSide) || p.security > gmLevel))
            continue;
        if (p.level < request.levelMin || p.level > levelMax)
            continue;
        if (!(request.classMask & (1u << p.classId)) || !(request.raceMask & (1u << p.race)))
            continue;
        if (request.zones.length && !request.zones.canFind(p.zone))
            continue;
        const pname = p.name.toLower, gname = p.guild.toLower;
        if (name.length && !pname.canFind(name))
            continue;
        if (guild.length && !gname.canFind(guild))
            continue;
        if (strings.length)
        {
            const area = areaName(p.zone).toLower;
            bool any;
            foreach (s; strings)
                if (s.length == 0 || gname.canFind(s) || pname.canFind(s) || area.canFind(s))
                {
                    any = true;
                    break;
                }
            if (!any)
                continue;
        }
        if (++matches > 49)
            continue;
        ++shown;
        entries.putCString(p.name);
        entries.putCString(p.guild);
        entries.put(p.level);
        entries.put(p.classId);
        entries.put(p.race);
        entries.put(p.zone);
    }
    if (maxReturns && matches > maxReturns)
        matches = maxReturns;
    ByteWriter w;
    w.put(shown);
    w.put(matches);
    w.putBytes(entries.data);
    return w.data;
}

unittest
{
    const everyone = [WhoEntry("Thrall", "", 60, 7, 2, 1637, 67, 0), WhoEntry("Anduin", "", 10, 2, 1, 1519, 469, 0),
        WhoEntry("Keeper", "", 60, 1, 2, 1637, 67, 3), WhoEntry("Grunt", "", 12, 1, 2, 14, 67, 0)];
    ClientWho all;
    all.levelMax = 100;
    all.raceMask = all.classMask = uint.max;
    string zoneName(uint zone) { return zone == 1637 ? "Orgrimmar" : "Durotar"; }
    uint shown(const(ubyte)[] body_) { auto r = ByteReader(body_); return r.read!uint; }

    // A horde player: horde only, and no GM above level 2 (with the setting at 2).
    assert(shown(whoList(all, everyone, 67, 0, false, 2, 49, &zoneName)) == 2);
    assert(shown(whoList(all, everyone, 67, 0, true, 3, 49, &zoneName)) == 4, "both factions, GMs listed");
    assert(shown(whoList(all, everyone, 469, 3, false, 0, 49, &zoneName)) == 4, "a GM sees everyone");

    auto search = all;
    search.strings = ["orgri"];
    assert(shown(whoList(search, everyone, 67, 0, false, 3, 49, &zoneName)) == 2, "by zone name, in part");
    search = all;
    search.name = "gru";
    search.levelMin = 10;
    assert(shown(whoList(search, everyone, 67, 0, false, 3, 49, &zoneName)) == 1);
    search = all;
    search.guild = "x";
    assert(shown(whoList(search, everyone, 67, 0, false, 3, 49, &zoneName)) == 0, "nobody is in a guild yet");

    // Capped: 60 matches, 49 shown, the count of matches capped by the setting.
    WhoEntry[] crowd;
    foreach (i; 0 .. 60)
        crowd ~= WhoEntry("Grunt", "", 5, 1, 2, 14, 67, 0);
    auto r = ByteReader(whoList(all, crowd, 67, 0, false, 3, 55, &zoneName));
    assert(r.read!uint == 49 && r.read!uint == 55);
}

