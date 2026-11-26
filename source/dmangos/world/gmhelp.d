/**
 * Command discovery and player support information.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmhelp;

import dmangos.world.character : Character;

import core.time : seconds;
import std.algorithm.searching : countUntil;
import std.format : format;
import std.math : sqrt;
import std.uni : toLower;
import dmangos.world.commands : ChatColor, Rest, trimSpaces;
import dmangos.world.context : PresenceFlags;
import dmangos.world.movement : Position;
import dmangos.world.updatefields : UNIT_FIELD_MOUNTDISPLAYID, UNIT_FIELD_TARGET;

/// `.help [command]`: a command's syntax and description, or a group's actions.
bool handleHelpCommand(Character gm, Rest command = Rest.init)
{
    return gm.browseCommands(command, true);
}

/// `.commands [prefix]`: the commands this player may use, or those starting with `filter`.
bool handleCommandsCommand(Character gm, Rest filter = Rest.init)
{
    return gm.browseCommands(filter, false);
}

/// `.help` (`help`) or `.commands` for `query`, with or without its leading dot.
bool browseCommands(Character gm, string query, bool help)
{
    if (query.length && query[0] == '.')
        query = query[1 .. $];
    string args = query;
    const match = gm.readCommand(args, help);
    if (!query.length)
        gm.showCommandList(gm.CommandMatch.init);
    else if (match.row is null && !help)
        gm.showCommandList(gm.CommandMatch.init, query);
    else if (match.row is null || trimSpaces(args).length)
        gm.unknownCommand();
    else if (match.row.children.length)
        gm.showCommandList(match);
    else
        gm.showCommandHelp(match);
    return true;
}

/// `.start [race]`: the selected player is sent to its race's starting area, or to `raceName`'s.
bool handleStartCommand(Character gm, string raceName = null)
{
    static immutable string[12] races = ["", "human", "orc", "dwarf", "nightelf", "undead", "tauren", "gnome",
        "troll", "", "bloodelf", "draenei"];
    auto target = gm.selectedCharacter(false);
    if (target is null || raceName.length == 2)
        return false;
    uint raceId;
    string race;
    if (raceName.length < 2)
    {
        raceId = target.player.data.race;
        if (raceId >= races.length || races[raceId].length == 0)
            return false;
        race = races[raceId];
    }
    else
    {
        race = raceName.toLower;
        const found = races[].countUntil(race); // `race` is not empty: never one of the gaps
        if (found <= 0)
        {
            gm.redSystemMessage("Invalid start location! Valid locations are: human, dwarf, gnome, nightelf, "
                ~ "draenei, orc, troll, tauren, undead, bloodelf");
            return true;
        }
        raceId = cast(uint) found;
    }

    // The first class the race can be: they all start in the same place.
    typeof(gm.context.data.createInfo(0, 0)) info;
    foreach (ubyte classId; 1 .. 11)
        if ((info = gm.context.data.createInfo(cast(ubyte) raceId, classId)) !is null)
            break;
    if (info is null)
    {
        gm.redSystemMessage("Internal error: Could not find create info.");
        return true;
    }
    gm.greenSystemMessage(format!"Sending %s to the %s starting area."(target.player.data.name, race));
    target.commandTeleport(info.map, Position(info.x, info.y, info.z, 0));
    return true;
}

/// `.server info`: players and staff online (in a cluster, on every node), uptime and latency.
bool handleInfoCommand(Character gm)
{
    uint staff, count;
    ulong latency;
    foreach (other; gm.context.onlinePlayers)
    {
        ++count;
        latency += gm.sessionOf(other).latencyMs;
        if (other.isStaff)
            ++staff;
    }
    const elsewhere = gm.context.remotePlayers;
    foreach (ref remote; elsewhere)
        if (remote.entry.flags & PresenceFlags.staff)
            ++staff;
    const uptime = gm.context.unixTime - gm.context.startTime;
    gm.greenSystemMessage("dmangos  ·  Server status");
    gm.systemMessage(format!"%s players online  ·  %s staff  ·  Uptime %sd %02d:%02d:%02d"
        (count + elsewhere.length, staff, uptime / 86_400, uptime / 3600 % 24, uptime / 60 % 60, uptime % 60));
    if (count)
        gm.systemMessage(format!"Local latency averages %.1f ms."(cast(double) latency / count));
    return true;
}

/// `.server netstatus`: this node's connection counts.
bool handleNetworkStatusCommand(Character gm)
{
    gm.blueSystemMessage(format!"Local connections: %s active  ·  %s peak  ·  %s accepted"
        (gm.context.sessionCount, gm.context.peakSessions, gm.context.acceptedSessions));
    return true;
}

/// `.dismount`: the selected player or creature (oneself without a selection) dismounted.
bool handleDismountCommand(Character gm)
{
    auto target = gm.selectedCharacter(false);
    auto creature = target is null ? gm.selectedCreature(false) : null;
    if (target is null && creature is null)
    {
        gm.redSystemMessage("No target found.");
        return true;
    }
    auto values = target !is null ? &target.player.values : &creature.values;
    if (values.get!UNIT_FIELD_MOUNTDISPLAYID == 0)
    {
        gm.redSystemMessage("Target is not mounted.");
        return true;
    }
    values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
    if (target !is null)
        target.flushPlayerChanges();
    else
        gm.map.flushObjectChanges(creature);
    gm.greenSystemMessage("Now unmounted.");
    return true;
}

/// `.server save`: the selected player saved, if its periodic save is less than 5 minutes away.
bool handleSaveCommand(Character gm)
{
    auto target = gm.selectedCharacter(false);
    if (target is null)
        return false;
    if (target.saveTimer.interval - target.saveTimer.elapsed >= 300.seconds)
    {
        gm.redSystemMessage("You can only save once every 5 minutes.");
        return true;
    }
    target.savePlayer();
    gm.greenSystemMessage(format!"Saved %s."(target.player.data.name));
    return true;
}

/// `.gm list`: the staff online (in a cluster, on every node), with their roles.
bool handleGmListCommand(Character gm)
{
    bool first = true;
    const viewerIsStaff = gm.isStaff;
    const onlyActive = gm.context.config.gamemasterListOnlyActiveGMs;
    void list(string name, string roles, bool tagOn)
    {
        if (onlyActive && !tagOn && !viewerIsStaff)
            return;
        if (first)
            gm.greenSystemMessage("Active GMs");
        if (gm.context.config.gamemasterHidePermissions && !viewerIsStaff)
            gm.systemMessage(" - " ~ name);
        else if (onlyActive && !tagOn)
            gm.colorSystemMessage(ChatColor.grey, format!" - %s [%s]"(name, roles));
        else
            gm.systemMessage(format!" - %s [%s]"(name, roles));
        first = false;
    }

    foreach (other; gm.context.onlinePlayers)
        if (other.isStaff)
            list(other.character.data.name, gm.sessionOf(other).staffRoles, other.character.gmTagOn);
    foreach (ref remote; gm.context.remotePlayers)
        if (remote.entry.flags & PresenceFlags.staff)
            list(remote.entry.name, remote.entry.staffRoles, (remote.entry.flags & PresenceFlags.gmTag) != 0);
    if (first)
        gm.systemMessage("There are no GMs currently logged in on this server.");
    return true;
}

/// `.debug rangecheck`: the distances to the selected unit.
bool handleRangeCheckCommand(Character gm)
{
    const guid = gm.player.values.get!UNIT_FIELD_TARGET;
    gm.systemMessage("=== RANGE CHECK ===");
    if (guid == 0)
    {
        gm.redSystemMessage("No selection.");
        return true;
    }
    Position at;
    if (auto other = gm.map.find(guid))
        at = other.character.position;
    else if (auto object = gm.map.findObject(guid))
        at = object.position;
    else
    {
        gm.redSystemMessage("Invalid selection.");
        return true;
    }
    const own = gm.player.position;
    const dx = at.x - own.x, dy = at.y - own.y, dz = at.z - own.z;
    const float distanceSq = dx * dx + dy * dy + dz * dz;
    gm.systemMessage(format!"GetDistanceSq  :   %u"(cast(uint) distanceSq));
    gm.systemMessage(format!"CalcDistance   :   %u"(cast(uint) sqrt(distanceSq)));
    gm.systemMessage(format!"GetDistance2dSq:   %u"(cast(uint)(dx * dx + dy * dy)));
    return true;
}

/// `.logcomment <comment>`: a note in the GM log.
bool handleGmLogCommentCommand(Character gm, Rest comment)
{
    gm.greenSystemMessage("GM log updated: " ~ comment);
    gm.gmLog("Logcomment: " ~ comment);
    return true;
}

