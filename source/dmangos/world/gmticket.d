/// Player support tickets.
module dmangos.world.gmticket;

mixin template TicketCommands()
{
    import std.format : format;
    import std.conv : to, ConvException;
    import dmangos.world.commands;
    import dmangos.world.database : TicketRecord;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets;
    import dmangos.world.queries : chatMessage;

private:
    /// The ticket `id` (closed ones too); false if none.
    private bool ticketById(uint id, out TicketRecord ticket)
    {
        foreach (t; context.database.tickets(true))
            if (t.id == id)
            {
                ticket = t;
                return true;
            }
        return false;
    }

    /// The online session of the ticket's author; null if offline.
    private typeof(this) ticketAuthor(const ref TicketRecord t)
    {
        return context.onlinePlayer(cast(ulong) t.player);
    }

    /// `.gmTicket list`: every open ticket, a line each, to this GM.
    bool handleGMTicketListCommand(Rest args = Rest.init)
    {
        if (context.config.gmClientChannel.length == 0)
            return false;
        ticketChannelSay("GmTicket:2", false);
        foreach (t; context.database.tickets(false))
        {
            auto plr = ticketAuthor(t);
            string assigned;
            if (const gm = t.id in context.ticketAssignedTo)
            {
                if (auto aplr = context.onlinePlayer(*gm))
                    assigned = aplr.player.data.name;
                else
                {
                    const info = context.database.nameInfo(cast(uint) *gm);
                    if (!info.isNull)
                        assigned = info.get.name;
                }
            }
            ticketChannelSay(format!"GmTicket:3:%s:%s:%s:%s:%s:%s"(t.id, plr is null ? t.level : plr.player.data.level,
                plr is null ? 0 : 1, assigned, plr is null ? t.name : plr.player.data.name,
                context.ticketComments.get(t.id, "")), false);
        }
        return true;
    }

    /// `.gmTicket get <id>`: the ticket's words, a line each, to this GM.
    bool handleGMTicketGetByIdCommand(Rest args = Rest.init)
    {
        import std.string : split;

        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        // A line for each piece between line ends, empty ones too; none for what follows the last line end if empty.
        const lines = t.text.split('\n');
        foreach (k, line; lines)
        {
            if (k + 1 == lines.length && line.length == 0)
                break;
            ticketChannelSay(format!"GmTicket:%s:%s:%s"(k == 0 ? 4 : 5, t.id, line), false);
        }
        return true;
    }

    /// `.gmTicket remove <id>`: the ticket is closed, the channel told, its author told.
    bool handleGMTicketRemoveByIdCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned != 0 && assigned != player.guid && !canUseCommand('z'))
        {
            ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
            return true;
        }
        auto plr = ticketAuthor(t);
        ticketChannelSay(format!"GmTicket:6:%s"(t.id), true);
        context.database.closeTicket(t.id);
        if (plr !is null)
            plr.ticketRemoved();
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
    bool handleGMTicketAssignToCommand(Rest args = Rest.init)
    {
        import std.array : split;

        const words = args.text.split;
        if (words.length < 1)
            return false;
        const id = cast(uint) leadingNumber(words[0]);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        typeof(this) plr = words.length == 1 ? this : context.onlinePlayer(words[1]);
        if (plr is null)
        {
            ticketChannelSay("GmTicket:0:Player not found.", false);
            return true;
        }
        if (plr.player is null)
        {
            ticketChannelSay("GmTicket:0:Player isn't online.", false);
            return true;
        }
        if (!plr.hasPermissions)
        {
            ticketChannelSay("GmTicket:0:Player is not a GM.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned == plr.player.guid)
        {
            ticketChannelSay("GmTicket:0:Ticket already assigned to this GM.", false);
            return true;
        }
        if (assigned != 0 && assigned != player.guid)
            if (auto aplr = context.onlinePlayer(assigned))
                if (aplr.player !is null && !canUseCommand('z'))
                {
                    ticketChannelSay("GmTicket:0:Ticket already assigned to another GM.", false);
                    return true;
                }
        context.ticketAssignedTo[t.id] = plr.player.guid;
        ticketChannelSay(format!"GmTicket:8:%s:%s"(t.id, plr.player.data.name), true);
        return true;
    }

    /// `.gmTicket release <id>`: the ticket no longer assigned.
    bool handleGMTicketReleaseCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned == 0)
        {
            ticketChannelSay("GmTicket:0:Ticket not assigned to a GM.", false);
            return true;
        }
        auto plr = context.onlinePlayer(assigned);
        if (!canUseCommand('z') && plr !is null && plr.player !is null && plr.canUseCommand('z'))
        {
            ticketChannelSay("GmTicket:0:You can not release tickets from admins.", false);
            return true;
        }
        context.ticketAssignedTo.remove(t.id);
        ticketChannelSay(format!"GmTicket:9:%s"(t.id), true);
        return true;
    }

    /// `.gmTicket comment <id> [comment]`: the ticket's comment set (none without one).
    bool handleGMTicketCommentCommand(Rest args = Rest.init)
    {
        import std.string : indexOf;

        const space = args.text.indexOf(' ');
        const comment = space < 0 ? "" : args.text[space + 1 .. $];
        const id = cast(uint) leadingNumber(space < 0 ? args.text : args.text[0 .. space]);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t) || t.closed)
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        const assigned = context.ticketAssignedTo.get(t.id, 0);
        if (assigned != 0 && assigned != player.guid && !canUseCommand('z'))
        {
            ticketChannelSay("GmTicket:0:Ticket is assigned to another GM.", false);
            return true;
        }
        context.ticketComments[t.id] = comment;
        ticketChannelSay(format!"GmTicket:10:%s:%s:%s"(t.id, player.data.name, comment), true);
        return true;
    }

    /// `.gmTicket deletepermanent <id>`: the ticket gone for good (closed first if it was open).
    bool handleGMTicketDeletePermanentCommand(Rest args = Rest.init)
    {
        const id = cast(uint) leadingNumber(args);
        if (!id)
        {
            redSystemMessage("You must specify a ticket id.");
            return true;
        }
        if (context.config.gmClientChannel.length == 0)
            return false;
        TicketRecord t;
        if (!ticketById(id, t))
        {
            ticketChannelSay("GmTicket:0:Ticket not found.", false);
            return true;
        }
        typeof(this) plr;
        if (!t.closed)
        {
            plr = ticketAuthor(t);
            ticketChannelSay(format!"GmTicket:6:%s"(t.id), true);
            context.database.closeTicket(t.id);
        }
        context.database.deleteTicket(t.id);
        context.ticketAssignedTo.remove(t.id);
        context.ticketComments.remove(t.id);
        if (plr !is null)
            plr.ticketRemoved();
        return true;
    }

    /// `.gmTicket toggle`: the ticket system on or off.
    bool handleGMTicketToggleTicketSystemStatusCommand(Rest args = Rest.init)
    {
        context.gmTicketsOn = !context.gmTicketsOn;
        greenSystemMessage(context.gmTicketsOn ? "TicketSystem enabled." : "TicketSystem disabled.");
        return true;
    }

    /// `.pet createpet`: its body does nothing (it was disabled), so the command answers nothing.
}
