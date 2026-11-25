/// Guild administration.
module dmangos.world.gmguild;

mixin template GuildAdminCommands()
{
    import std.format : format;
    import dmangos.world.commands : Rest;

private:
    /// `.guild rename <name>`: the selected player's guild is renamed in the database, for the next start.
    bool handleRenameGuildCommand(Rest name = Rest.init)
    {
        auto plr = getSelectedChar(true);
        if (plr is null || plr.ownGuild() is null || name.length == 0)
            return false;
        if (context.guilds.named(name) !is null)
        {
            redSystemMessage(format!"Guild name %s is already taken."(name));
            return false;
        }
        auto g = plr.ownGuild();
        greenSystemMessage(format!"Changed guild name of %s to %s. This will take effect next restart."(g.name, name));
        context.database.renameGuild(g.id, name);
        return true;
    }

    /// `.guild members`: the selected player's guild's members and their ranks.
    bool handleGuildMembersCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null || plr.ownGuild() is null)
            return false;
        auto g = plr.ownGuild();
        greenSystemMessage(format!"Now showing guild members for %s"(g.name));
        foreach (ref m; g.members)
        {
            string rank;
            foreach (ref r; g.ranks)
                if (r.id == m.rank)
                    rank = r.name;
            blueSystemMessage(format!"%s (Rank: %s)"(m.name, rank));
        }
        return true;
    }

    /// `.guild removeplayer`: the selected player is removed from its guild (not its leader).
    bool handleGuildRemovePlayerCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null || plr.ownGuild() is null || plr.ownGuild().leader == plr.player.data.guid)
            return false;
        const guildName = plr.ownGuild().name;
        greenSystemMessage(format!"Removed %s from %s."(plr.player.data.name, guildName));
        if (plr !is this)
            gmLog(format!"Kicked %s from Guild %s"(plr.player.data.name, guildName));
        plr.gmLeaveGuild();
        return true;
    }

    /// `.guild disband`: the selected player's guild is disbanded.
    bool handleGuildDisbandCommand()
    {
        auto plr = getSelectedChar(true);
        if (plr is null || plr.ownGuild() is null)
            return false;
        const guildName = plr.ownGuild().name;
        greenSystemMessage(format!"Disbanded Guild: %s"(guildName));
        gmLog(format!"Disbanded guild %s"(guildName)); // ArcEmu's spelling
        plr.gmDisbandGuild();
        return true;
    }
}
