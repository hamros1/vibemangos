/**
 * Player support tickets.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmticket;

import dmangos.world.character : Character;

import std.array : split;
import std.format : format;
import dmangos.bytes : ByteWriter;
import dmangos.world.commands;
import dmangos.world.database : TicketRecord;
import dmangos.world.opcodes : Opcode;

/// Reads the numeric ticket prefix used by the legacy GM client.
long leadingNumber(string text)
{
    import std.ascii : isDigit;

    size_t i;
    while (i < text.length && (text[i] == ' ' || text[i] == '\t'))
        ++i;
    bool negative;
    if (i < text.length && (text[i] == '-' || text[i] == '+'))
        negative = text[i++] == '-';
    long value;
    while (i < text.length && text[i].isDigit && value < uint.max)
        value = value * 10 + (text[i++] - '0');
    return negative ? -value : value;
}

/// The ticket `id` (closed ones too); false if none.
bool ticketById(Character gm, uint id, out TicketRecord ticket)
{
    foreach (record; gm.context.database.tickets(true))
        if (record.id == id)
        {
            ticket = record;
            return true;
        }
    return false;
}

/// Whether the command named a ticket; false after "You must specify a ticket id.".
bool ticketIdGiven(Character gm, uint id)
{
    if (!id)
        gm.redSystemMessage("You must specify a ticket id.");
    return id != 0;
}

/// The ticket `id`, if open (or closed too, with `closedToo`); false after the channel's "Ticket not found.".
bool findTicket(Character gm, uint id, out TicketRecord ticket, bool closedToo = false)
{
    if (gm.ticketById(id, ticket) && (closedToo || !ticket.closed))
        return true;
    gm.ticketChannelSay("GmTicket:0:Ticket not found.", false);
    return false;
}

/// The online session of the ticket's author; null if offline.
Character ticketAuthor(Character gm, const ref TicketRecord ticket)
{
    return gm.context.onlinePlayer(cast(ulong) ticket.player);
}

/// `.gmTicket list`: every open ticket, a line each, to this GM.
bool handleGmTicketListCommand(Character gm, Rest args = Rest.init)
{
    if (gm.context.config.gmClientChannel.length == 0)
        return false;
    gm.ticketChannelSay("GmTicket:2", false);
    foreach (const ref ticket; gm.context.database.tickets(false))
    {
        auto author = gm.ticketAuthor(ticket);
        string assigned;
        if (const assignee = ticket.id in gm.context.ticketAssignedTo)
        {
            if (auto online = gm.context.onlinePlayer(*assignee))
                assigned = online.player.data.name;
            else
            {
                const info = gm.context.database.nameInfo(cast(uint) *assignee);
                if (!info.isNull)
                    assigned = info.get.name;
            }
        }
        gm.ticketChannelSay(format!"GmTicket:3:%s:%s:%s:%s:%s:%s"(ticket.id,
            author is null ? ticket.level : author.player.data.level, author is null ? 0 : 1, assigned,
            author is null ? ticket.name : author.player.data.name, gm.context.ticketComments.get(ticket.id, "")),
            false);
    }
    return true;
}

/// `.gmTicket get <id>`: the ticket's words, a line each, to this GM.
bool handleGmTicketGetByIdCommand(Character gm, Rest args = Rest.init)
{
    const id = cast(uint) leadingNumber(args);
    if (!gm.ticketIdGiven(id))
        return true;
    if (gm.context.config.gmClientChannel.length == 0)
        return false;
    TicketRecord ticket;
    if (!gm.findTicket(id, ticket))
        return true;
    // A line for each piece between line ends, empty ones too; none for what follows the last line end if empty.
    const lines = ticket.text.split('\n');
    foreach (i, line; lines)
    {
        if (i + 1 == lines.length && line.length == 0)
            break;
        gm.ticketChannelSay(format!"GmTicket:%s:%s:%s"(i == 0 ? 4 : 5, ticket.id, line), false);
    }
    return true;
}

/// `.gmTicket remove <id>`: the ticket is closed, the channel told, its author told.
bool handleGmTicketRemoveByIdCommand(Character gm, Rest args = Rest.init)
{
    const id = cast(uint) leadingNumber(args);
    if (!gm.ticketIdGiven(id))
        return true;
    if (gm.context.config.gmClientChannel.length == 0)
        return false;
    TicketRecord ticket;
    if (!gm.findTicket(id, ticket))
        return true;
    const assigned = gm.context.ticketAssignedTo.get(ticket.id, 0);
    if (assigned != 0 && assigned != gm.player.guid && !gm.allowsStaff("staff.admin"))
    {
        gm.ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
        return true;
    }
    auto author = gm.ticketAuthor(ticket);
    gm.ticketChannelSay(format!"GmTicket:6:%s"(ticket.id), true);
    gm.context.database.closeTicket(ticket.id);
    if (author !is null)
        author.ticketRemoved();
    return true;
}

/// The player's ticket was removed by a GM.
package void ticketRemoved(Character gm)
{
    ByteWriter w;
    w.put(9u);
    gm.deliver(Opcode.SMSG_GMTICKET_DELETETICKET, w.data);
}

/// `.gmTicket assign <id> [name]`: the ticket to a GM online (this one by default).
bool handleGmTicketAssignToCommand(Character gm, Rest args = Rest.init)
{
    const words = args.text.split;
    if (words.length < 1)
        return false;
    const id = cast(uint) leadingNumber(words[0]);
    if (!gm.ticketIdGiven(id))
        return true;
    if (gm.context.config.gmClientChannel.length == 0)
        return false;
    TicketRecord ticket;
    if (!gm.findTicket(id, ticket))
        return true;
    Character assignee = words.length == 1 ? gm : gm.context.onlinePlayer(words[1]);
    if (assignee is null)
    {
        gm.ticketChannelSay("GmTicket:0:Player not found.", false);
        return true;
    }
    if (assignee.player is null)
    {
        gm.ticketChannelSay("GmTicket:0:Player isn't online.", false);
        return true;
    }
    if (!assignee.isStaff)
    {
        gm.ticketChannelSay("GmTicket:0:Player is not a GM.", false);
        return true;
    }
    const assigned = gm.context.ticketAssignedTo.get(ticket.id, 0);
    if (assigned == assignee.player.guid)
    {
        gm.ticketChannelSay("GmTicket:0:Ticket already assigned to this GM.", false);
        return true;
    }
    if (assigned != 0 && assigned != gm.player.guid)
        if (auto holder = gm.context.onlinePlayer(assigned))
            if (holder.player !is null && !gm.allowsStaff("staff.admin"))
            {
                gm.ticketChannelSay("GmTicket:0:Ticket already assigned to another GM.", false);
                return true;
            }
    gm.context.ticketAssignedTo[ticket.id] = assignee.player.guid;
    gm.ticketChannelSay(format!"GmTicket:8:%s:%s"(ticket.id, assignee.player.data.name), true);
    return true;
}

/// `.gmTicket release <id>`: the ticket no longer assigned.
bool handleGmTicketReleaseCommand(Character gm, Rest args = Rest.init)
{
    const id = cast(uint) leadingNumber(args);
    if (!gm.ticketIdGiven(id))
        return true;
    if (gm.context.config.gmClientChannel.length == 0)
        return false;
    TicketRecord ticket;
    if (!gm.findTicket(id, ticket))
        return true;
    const assigned = gm.context.ticketAssignedTo.get(ticket.id, 0);
    if (assigned == 0)
    {
        gm.ticketChannelSay("GmTicket:0:Ticket not assigned to a GM.", false);
        return true;
    }
    auto holder = gm.context.onlinePlayer(assigned);
    if (!gm.allowsStaff("staff.admin") && holder !is null && holder.player !is null
        && holder.allowsStaff("staff.admin"))
    {
        gm.ticketChannelSay("GmTicket:0:You can not release tickets from admins.", false);
        return true;
    }
    gm.context.ticketAssignedTo.remove(ticket.id);
    gm.ticketChannelSay(format!"GmTicket:9:%s"(ticket.id), true);
    return true;
}

/// `.gmTicket comment <id> [comment]`: the ticket's comment set (none without one).
bool handleGmTicketCommentCommand(Character gm, Rest args = Rest.init)
{
    import std.string : indexOf;

    const space = args.text.indexOf(' ');
    const comment = space < 0 ? "" : args.text[space + 1 .. $];
    const id = cast(uint) leadingNumber(space < 0 ? args.text : args.text[0 .. space]);
    if (!gm.ticketIdGiven(id))
        return true;
    if (gm.context.config.gmClientChannel.length == 0)
        return false;
    TicketRecord ticket;
    if (!gm.findTicket(id, ticket))
        return true;
    const assigned = gm.context.ticketAssignedTo.get(ticket.id, 0);
    if (assigned != 0 && assigned != gm.player.guid && !gm.allowsStaff("staff.admin"))
    {
        gm.ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
        return true;
    }
    gm.context.ticketComments[ticket.id] = comment;
    gm.ticketChannelSay(format!"GmTicket:10:%s:%s:%s"(ticket.id, gm.player.data.name, comment), true);
    return true;
}

/// `.gmTicket deletepermanent <id>`: the ticket gone for good (closed first if it was open).
bool handleGmTicketDeletePermanentCommand(Character gm, Rest args = Rest.init)
{
    const id = cast(uint) leadingNumber(args);
    if (!gm.ticketIdGiven(id))
        return true;
    if (gm.context.config.gmClientChannel.length == 0)
        return false;
    TicketRecord ticket;
    if (!gm.findTicket(id, ticket, true))
        return true;
    Character author;
    if (!ticket.closed)
    {
        author = gm.ticketAuthor(ticket);
        gm.ticketChannelSay(format!"GmTicket:6:%s"(ticket.id), true);
        gm.context.database.closeTicket(ticket.id);
    }
    gm.context.database.deleteTicket(ticket.id);
    gm.context.ticketAssignedTo.remove(ticket.id);
    gm.context.ticketComments.remove(ticket.id);
    if (author !is null)
        author.ticketRemoved();
    return true;
}

/// `.gmTicket toggle`: the ticket system on or off.
bool handleGmTicketToggleTicketSystemStatusCommand(Character gm, Rest args = Rest.init)
{
    gm.context.gmTicketsOn = !gm.context.gmTicketsOn;
    gm.greenSystemMessage(gm.context.gmTicketsOn ? "TicketSystem enabled." : "TicketSystem disabled.");
    return true;
}

