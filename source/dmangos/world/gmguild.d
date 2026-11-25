/// Guild administration.
module dmangos.world.gmguild;

/// `.guild`: the selected player's guild renamed, listed, left or disbanded.
mixin template GuildAdminCommands()
{
    import std.format : format;
    import dmangos.world.commands : Rest;

private:
    /// The selected player (oneself without a selection) if it is in a guild; null if not.
    Character selectedGuildMember()
    {
        auto target = selectedCharacter(true);
        return target is null || target.ownGuild() is null ? null : target;
    }

    /// `.guild rename <name>`: the selected player's guild is renamed in the database, for the next start.
    bool handleRenameGuildCommand(Rest name = Rest.init)
    {
        auto target = selectedGuildMember();
        if (target is null || name.length == 0)
            return false;
        if (context.guilds.named(name) !is null)
        {
            redSystemMessage(format!"Guild name %s is already taken."(name));
            return true;
        }
        const guild = target.ownGuild();
        greenSystemMessage(format!"Changed guild name of %s to %s. This will take effect next restart."(guild.name,
            name));
        context.database.renameGuild(guild.id, name);
        return true;
    }

    /// `.guild members`: the selected player's guild's members and their ranks.
    bool handleGuildMembersCommand()
    {
        auto target = selectedGuildMember();
        if (target is null)
            return false;
        const guild = target.ownGuild();
        greenSystemMessage(format!"Now showing guild members for %s"(guild.name));
        foreach (ref member; guild.members)
        {
            string rankName;
            foreach (ref rank; guild.ranks)
                if (rank.id == member.rank)
                    rankName = rank.name;
            blueSystemMessage(format!"%s (Rank: %s)"(member.name, rankName));
        }
        return true;
    }

    /// `.guild removeplayer`: the selected player is removed from its guild (not its leader).
    bool handleGuildRemovePlayerCommand()
    {
        auto target = selectedGuildMember();
        if (target is null || target.ownGuild().leader == target.player.data.guid)
            return false;
        const guildName = target.ownGuild().name;
        greenSystemMessage(format!"Removed %s from %s."(target.player.data.name, guildName));
        if (target !is this)
            gmLog(format!"Kicked %s from Guild %s"(target.player.data.name, guildName));
        target.gmLeaveGuild();
        return true;
    }

    /// `.guild disband`: the selected player's guild is disbanded.
    bool handleGuildDisbandCommand()
    {
        auto target = selectedGuildMember();
        if (target is null)
            return false;
        const guildName = target.ownGuild().name;
        greenSystemMessage(format!"Disbanded Guild: %s"(guildName));
        gmLog(format!"Disbanded guild %s"(guildName));
        target.gmDisbandGuild();
        return true;
    }
}
