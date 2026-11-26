/**
 * Guild administration.
 *
 * `.guild`: the selected player's guild renamed, listed, left or disbanded.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmguild;

import dmangos.world.character : Character;

import std.format : format;
import dmangos.world.commands : Rest;

/// The selected player (oneself without a selection) if it is in a guild; null if not.
Character selectedGuildMember(Character gm)
{
    auto target = gm.selectedCharacter(true);
    return target is null || target.ownGuild() is null ? null : target;
}

/// `.guild rename <name>`: the selected player's guild is renamed in the database, for the next start.
bool handleRenameGuildCommand(Character gm, Rest name = Rest.init)
{
    auto target = gm.selectedGuildMember();
    if (target is null || name.length == 0)
        return false;
    if (gm.context.guilds.named(name) !is null)
    {
        gm.redSystemMessage(format!"Guild name %s is already taken."(name));
        return true;
    }
    const guild = target.ownGuild();
    gm.greenSystemMessage(format!"Changed guild name of %s to %s. This will take effect next restart."(guild.name,
        name));
    gm.context.database.renameGuild(guild.id, name);
    return true;
}

/// `.guild members`: the selected player's guild's members and their ranks.
bool handleGuildMembersCommand(Character gm)
{
    auto target = gm.selectedGuildMember();
    if (target is null)
        return false;
    const guild = target.ownGuild();
    gm.greenSystemMessage(format!"Now showing guild members for %s"(guild.name));
    foreach (ref member; guild.members)
    {
        string rankName;
        foreach (ref rank; guild.ranks)
            if (rank.id == member.rank)
                rankName = rank.name;
        gm.blueSystemMessage(format!"%s (Rank: %s)"(member.name, rankName));
    }
    return true;
}

/// `.guild removeplayer`: the selected player is removed from its guild (not its leader).
bool handleGuildRemovePlayerCommand(Character gm)
{
    auto target = gm.selectedGuildMember();
    if (target is null || target.ownGuild().leader == target.player.data.guid)
        return false;
    const guildName = target.ownGuild().name;
    gm.greenSystemMessage(format!"Removed %s from %s."(target.player.data.name, guildName));
    if (target !is gm)
        gm.gmLog(format!"Kicked %s from Guild %s"(target.player.data.name, guildName));
    target.gmLeaveGuild();
    return true;
}

/// `.guild disband`: the selected player's guild is disbanded.
bool handleGuildDisbandCommand(Character gm)
{
    auto target = gm.selectedGuildMember();
    if (target is null)
        return false;
    const guildName = target.ownGuild().name;
    gm.greenSystemMessage(format!"Disbanded Guild: %s"(guildName));
    gm.gmLog(format!"Disbanded guild %s"(guildName));
    target.gmDisbandGuild();
    return true;
}

