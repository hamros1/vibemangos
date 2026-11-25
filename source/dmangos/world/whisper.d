/**
 * Whispers (`CHAT_MSG_WHISPER`), wherever the receiver is simulated (docs/CLUSTER.md):
 * the checks and deliveries happen where the receiver is, with what the whisper says of its
 * sender, and whatever goes back to the sender (its copy of the whisper, the receiver's away message,
 * a refusal) goes through `toSender`: straight to its client on the same node, or back to its node.
 */
module dmangos.world.whisper;

import dmangos.world.map : packetBody;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.opcodes;
import dmangos.world.packets : ServerChatWrongFaction;
import dmangos.world.player : PlayerFlags;
import dmangos.world.queries : chatMessage;

/// What a whisper says of its sender.
struct WhisperFrom
{
    ulong guid;
    ubyte race;
    bool staff;   /// GM permissions: any faction, past a GM's tag
    ubyte chatTag;
}

/**
 * Delivers a whisper to `target`: a GM with its tag
 * on hears only senders with permissions or those it allowed (`allowsWhispersFrom`); factions may not
 * whisper each other unless allowed or one has permissions. Whispers are always readable.
 */
void deliverWhisper(OnlinePlayer target, const WhisperFrom from, string text, bool twoSideChat,
    bool delegate(ulong sender) allowsWhispersFrom, uint delegate(ubyte race) teamOf,
    scope void delegate(Opcode, const(ubyte)[]) toSender)
{
    const receiver = target.character;
    // Ignored: the sender hears that it is ignored, and the whisper goes nowhere.
    if (!from.staff && target.ignores(from.guid))
        return toSender(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_IGNORED, Language.LANG_UNIVERSAL,
            receiver.guid, ""));
    if (!from.staff && receiver.gmTagOn && !allowsWhispersFrom(from.guid))
        return toSender(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_WHISPER, Language.LANG_UNIVERSAL,
            receiver.guid, "This Game Master does not currently have an open ticket from you and did not receive "
            ~ "your whisper. Please submit a new GM Ticket request if you need to speak to a GM. This is an "
            ~ "automatic message.", ChatTag.CHAT_TAG_GM));
    const sameTeam = teamOf(receiver.data.race) == teamOf(from.race);
    if (!sameTeam && !twoSideChat && !from.staff && !target.isStaff)
        return toSender(Opcode.SMSG_CHAT_WRONG_FACTION, packetBody(ServerChatWrongFaction()));
    target.deliver(Opcode.SMSG_MESSAGECHAT,
        chatMessage(ChatType.CHAT_MSG_WHISPER, Language.LANG_UNIVERSAL, from.guid, text, from.chatTag));
    toSender(Opcode.SMSG_MESSAGECHAT, chatMessage(ChatType.CHAT_MSG_WHISPER_INFORM, Language.LANG_UNIVERSAL,
        receiver.guid, text, receiver.chatTag));
    if (receiver.hasFlag(PlayerFlags.afk) || receiver.hasFlag(PlayerFlags.dnd))
        toSender(Opcode.SMSG_MESSAGECHAT, chatMessage(receiver.hasFlag(PlayerFlags.afk) ? ChatType.CHAT_MSG_AFK
            : ChatType.CHAT_MSG_DND, Language.LANG_UNIVERSAL, receiver.guid, receiver.autoReply));
}
