/**
 * The chat packets (`SMSG_MESSAGECHAT`) of the 1.12 client (docs/PROTOCOL.md).
 */
module dmangos.protocol.chat;

import dmangos.bytes : ByteWriter;
import dmangos.protocol.packet : Packet;
import dmangos.world.opcodes : ChatType, Language, Opcode;

/**
 * `SMSG_MESSAGECHAT` for the message types a player sends, and the server's own (`CHAT_MSG_SYSTEM`, a
 * battleground's): `channel` is the channel's name for `CHAT_MSG_CHANNEL`.
 */
Packet chatPacket(ChatType type, Language language, ulong sender, string text, ubyte chatTag = 0,
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
    return Packet(Opcode.SMSG_MESSAGECHAT, w.data.dup);
}

/// `SMSG_MESSAGECHAT` for a creature's say, yell, emote or whisper: its name, and whom it addresses.
Packet monsterChatPacket(ChatType type, ulong sender, string name, string text,
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
    return Packet(Opcode.SMSG_MESSAGECHAT, w.data.dup);
}

unittest
{
    // Say: the type (uint8), language, the sender twice, length with the
    // terminator, text, tag.
    const say = chatPacket(ChatType.CHAT_MSG_SAY, Language.LANG_COMMON, 7, "hi").body_;
    assert(say.length == 1 + 4 + 8 + 8 + 4 + 3 + 1);
    assert(say[0] == 0 && say[1 .. 5] == [7, 0, 0, 0] && say[5] == 7);
    assert(say[21 .. 25] == [3, 0, 0, 0] && say[25 .. 28] == ['h', 'i', 0]);
    assert(chatPacket(ChatType.CHAT_MSG_EMOTE, Language.LANG_UNIVERSAL, 7, "waves").body_.length == 1 + 4 + 8 + 4 + 6 + 1);
    // A channel message: the channel's name and the rank before the sender.
    const inChannel = chatPacket(ChatType.CHAT_MSG_CHANNEL, Language.LANG_COMMON, 7, "hi", 0, "world").body_;
    assert(inChannel[5 .. 11] == "world\0" && inChannel[11 .. 15] == [0, 0, 0, 0] && inChannel[15] == 7);
}
