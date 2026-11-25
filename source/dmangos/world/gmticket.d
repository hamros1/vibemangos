/// Player support tickets.
module dmangos.world.gmticket;

/// See the module documentation.
mixin template TicketCommands()
{
    import std.array : split;
    import std.format : format;
    import dmangos.bytes : ByteWriter;
    import dmangos.world.commands;
    import dmangos.world.database : TicketRecord;
    import dmangos.world.opcodes : Opcode;

private:
    /// Reads the numeric ticket prefix used by the legacy GM client.
    static long leadingNumber(string text)
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
    bool ticketById(uint id, out TicketRecord ticket)
    {
        foreach (record; context.database.tickets(true))
            if (record.id == id)
            {
                ticket = record;
                return true;
            }
        return false;
    }

    /// Whether the command named a ticket; false after "You must specify a ticket id.".
    bool ticketIdGiven(uint id)
    {
        if (!id)
            redSystemMessage("You must specify a ticket id.");
        return id != 0;
    }

    /// The ticket `id`, if open (or closed too, with `closedToo`); false after the channel's "Ticket not found.".
    bool findTicket(uint id, out TicketRecord ticket, bool closedToo = false)
    {
        if (ticketById(id, ticket) && (closedToo || !ticket.closed))
            return true;
        ticketChannelSay("GmTicket:0:Ticket not found.", false);
        return false;
    }

    /// The online session of the ticket's author; null if offline.
    typeof(this) ticketAuthor(const ref TicketRecord ticket)
    {
        return context.onlinePlayer(cast(ulong) ticket.player);
    }

    /// `.gmTicket list`: every open ticket, a line each, to this GM.
    bool handleGmTicketListCommand(Rest args = Rest.init)
    {
        if (context.config.gmClientChannel.length == 0)
            return false;
        ticketChannelSay("GmTicket:2", false);
        foreach (const ref ticket; context.database.tickets(false))
        {
            auto author = ticketAuthor(ticket);
            string assigned;
            if (const assignee = ticket.id in context.ticketAssignedTo)
            {
                if (auto online = context.onlinePlayer(*assignee))
                    assigned = online.player.data.name;
                else
                {
                    const info = context.database.nameInfo(cast(uint) *assignee);
                    if (!info.isNull)
                        assigned = info.get.name;
                }
            }
            ticketChannelSay(format!"GmTicket:3:%s:%s:%s:%s:%s:%s"(ticket.id,
                author is null ? ticket.level : author.player.data.level, author is null ? 0 : 1, assigned,
                author is null ? ticket.name : author.player.data.name, context.ticketComments.get(ticket.id, "")),
                false);
        }
        return true;
    }

    /// `.gmTicket get <id>`: the ticket's words, a line each, to this GM.
    bool handleGmTicketGetByIdCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!ticketIdGiven(id))
            return true;
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord ticket;
        if (!findTicket(id, ticket))
            return true;
        // A line for each piece between line ends, empty ones too; none for what follows the last line end if empty.
        const lines = ticket.text.split('\n');
        foreach (i, line; lines)
        {
            if (i + 1 == lines.length && line.length == 0)
                break;
            ticketChannelSay(format!"GmTicket:%s:%s:%s"(i == 0 ? 4 : 5, ticket.id, line), false);
        }
        return true;
    }

    /// `.gmTicket remove <id>`: the ticket is closed, the channel told, its author told.
    bool handleGmTicketRemoveByIdCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!ticketIdGiven(id))
            return true;
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord ticket;
        if (!findTicket(id, ticket))
            return true;
        const assigned = context.ticketAssignedTo.get(ticket.id, 0);
        if (assigned != 0 && assigned != player.guid && !allowsStaff("staff.admin"))
        {
            ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
            return true;
        }
        auto author = ticketAuthor(ticket);
        ticketChannelSay(format!"GmTicket:6:%s"(ticket.id), true);
        context.database.closeTicket(ticket.id);
        if (author !is null)
            author.ticketRemoved();
        return true;
    }

    /// The player's ticket was removed by a GM.
    package void ticketRemoved()
    {
        ByteWriter w;
        w.put(9u);
        deliver(Opcode.SMSG_GMTICKET_DELETETICKET, w.data);
    }

    /// `.gmTicket assign <id> [name]`: the ticket to a GM online (this one by default).
    bool handleGmTicketAssignToCommand(Rest args = Rest.init)
    {
        const words = args.text.split;
        if (words.length < 1)
            return false;
        const id = cast(uint) leadingNumber(words[0]);
        if (!ticketIdGiven(id))
            return true;
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord ticket;
        if (!findTicket(id, ticket))
            return true;
        typeof(this) assignee = words.length == 1 ? this : context.onlinePlayer(words[1]);
        if (assignee is null)
        {
            ticketChannelSay("GmTicket:0:Player not found.", false);
            return true;
        }
        if (assignee.player is null)
        {
            ticketChannelSay("GmTicket:0:Player isn't online.", false);
            return true;
        }
        if (!assignee.isStaff)
        {
            ticketChannelSay("GmTicket:0:Player is not a GM.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(ticket.id, 0);
        if (assigned == assignee.player.guid)
        {
            ticketChannelSay("GmTicket:0:Ticket already assigned to this GM.", false);
            return true;
        }
        if (assigned != 0 && assigned != player.guid)
            if (auto holder = context.onlinePlayer(assigned))
                if (holder.player !is null && !allowsStaff("staff.admin"))
                {
                    ticketChannelSay("GmTicket:0:Ticket already assigned to another GM.", false);
                    return true;
                }
        context.ticketAssignedTo[ticket.id] = assignee.player.guid;
        ticketChannelSay(format!"GmTicket:8:%s:%s"(ticket.id, assignee.player.data.name), true);
        return true;
    }

    /// `.gmTicket release <id>`: the ticket no longer assigned.
    bool handleGmTicketReleaseCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!ticketIdGiven(id))
            return true;
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord ticket;
        if (!findTicket(id, ticket))
            return true;
        const assigned = context.ticketAssignedTo.get(ticket.id, 0);
        if (assigned == 0)
        {
            ticketChannelSay("GmTicket:0:Ticket not assigned to a GM.", false);
            return true;
        }
        auto holder = context.onlinePlayer(assigned);
        if (!allowsStaff("staff.admin") && holder !is null && holder.player !is null
            && holder.allowsStaff("staff.admin"))
        {
            ticketChannelSay("GmTicket:0:You can not release tickets from admins.", false);
            return true;
        }
        context.ticketAssignedTo.remove(ticket.id);
        ticketChannelSay(format!"GmTicket:9:%s"(ticket.id), true);
        return true;
    }

    /// `.gmTicket comment <id> [comment]`: the ticket's comment set (none without one).
    bool handleGmTicketCommentCommand(Rest args = Rest.init)
    {
        import std.string : indexOf;

        const space = args.text.indexOf(' ');
        const comment = space < 0 ? "" : args.text[space + 1 .. $];
        const id = cast(uint) leadingNumber(space < 0 ? args.text : args.text[0 .. space]);
        if (!ticketIdGiven(id))
            return true;
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord ticket;
        if (!findTicket(id, ticket))
            return true;
        const assigned = context.ticketAssignedTo.get(ticket.id, 0);
        if (assigned != 0 && assigned != player.guid && !allowsStaff("staff.admin"))
        {
            ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
            return true;
        }
        context.ticketComments[ticket.id] = comment;
        ticketChannelSay(format!"GmTicket:10:%s:%s:%s"(ticket.id, player.data.name, comment), true);
        return true;
    }

    /// `.gmTicket deletepermanent <id>`: the ticket gone for good (closed first if it was open).
    bool handleGmTicketDeletePermanentCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!ticketIdGiven(id))
            return true;
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord ticket;
        if (!findTicket(id, ticket, true))
            return true;
        typeof(this) author;
        if (!ticket.closed)
        {
            author = ticketAuthor(ticket);
            ticketChannelSay(format!"GmTicket:6:%s"(ticket.id), true);
            context.database.closeTicket(ticket.id);
        }
        context.database.deleteTicket(ticket.id);
        context.ticketAssignedTo.remove(ticket.id);
        context.ticketComments.remove(ticket.id);
        if (author !is null)
            author.ticketRemoved();
        return true;
    }

    /// `.gmTicket toggle`: the ticket system on or off.
    bool handleGmTicketToggleTicketSystemStatusCommand(Rest args = Rest.init)
    {
        context.gmTicketsOn = !context.gmTicketsOn;
        greenSystemMessage(context.gmTicketsOn ? "TicketSystem enabled." : "TicketSystem disabled.");
        return true;
    }
}
