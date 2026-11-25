/// Command discovery and player support information.
module dmangos.world.gmhelp;

/// See the module documentation.
mixin template SupportCommands()
{
    import core.time : seconds;
    import std.algorithm.searching : countUntil;
    import std.format : format;
    import std.math : sqrt;
    import std.uni : toLower;
    import dmangos.world.commands : ChatColor, Rest, trimSpaces;
    import dmangos.world.context : PresenceFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.updatefields : UNIT_FIELD_MOUNTDISPLAYID, UNIT_FIELD_TARGET;

private:
    /// `.help [command]`: a command's syntax and description, or a group's actions.
    bool handleHelpCommand(Rest command = Rest.init)
    {
        return browseCommands(command, true);
    }

    /// `.commands [prefix]`: the commands this player may use, or those starting with `filter`.
    bool handleCommandsCommand(Rest filter = Rest.init)
    {
        return browseCommands(filter, false);
    }

    /// `.help` (`help`) or `.commands` for `query`, with or without its leading dot.
    bool browseCommands(string query, bool help)
    {
        if (query.length && query[0] == '.')
            query = query[1 .. $];
        string args = query;
        const match = readCommand(args, help);
        if (!query.length)
            showCommandList(CommandMatch.init);
        else if (match.row is null && !help)
            showCommandList(CommandMatch.init, query);
        else if (match.row is null || trimSpaces(args).length)
            unknownCommand();
        else if (match.row.children.length)
            showCommandList(match);
        else
            showCommandHelp(match);
        return true;
    }

    /// `.start [race]`: the selected player is sent to its race's starting area, or to `raceName`'s.
    bool handleStartCommand(string raceName = null)
    {
        static immutable string[12] races = ["", "human", "orc", "dwarf", "nightelf", "undead", "tauren", "gnome",
            "troll", "", "bloodelf", "draenei"];
        auto target = selectedCharacter(false);
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
                redSystemMessage("Invalid start location! Valid locations are: human, dwarf, gnome, nightelf, "
                    ~ "draenei, orc, troll, tauren, undead, bloodelf");
                return true;
            }
            raceId = cast(uint) found;
        }

        // The first class the race can be: they all start in the same place.
        typeof(context.data.createInfo(0, 0)) info;
        foreach (ubyte classId; 1 .. 11)
            if ((info = context.data.createInfo(cast(ubyte) raceId, classId)) !is null)
                break;
        if (info is null)
        {
            redSystemMessage("Internal error: Could not find create info.");
            return true;
        }
        greenSystemMessage(format!"Sending %s to the %s starting area."(target.player.data.name, race));
        target.commandTeleport(info.map, Position(info.x, info.y, info.z, 0));
        return true;
    }

    /// `.server info`: players and staff online (in a cluster, on every node), uptime and latency.
    bool handleInfoCommand()
    {
        uint staff, count;
        ulong latency;
        foreach (other; context.onlinePlayers)
        {
            ++count;
            latency += sessionOf(other).latencyMs;
            if (other.isStaff)
                ++staff;
        }
        const elsewhere = context.remotePlayers;
        foreach (ref remote; elsewhere)
            if (remote.entry.flags & PresenceFlags.staff)
                ++staff;
        const uptime = context.unixTime - context.startTime;
        greenSystemMessage("dmangos  ·  Server status");
        systemMessage(format!"%s players online  ·  %s staff  ·  Uptime %sd %02d:%02d:%02d"
            (count + elsewhere.length, staff, uptime / 86_400, uptime / 3600 % 24, uptime / 60 % 60, uptime % 60));
        if (count)
            systemMessage(format!"Local latency averages %.1f ms."(cast(double) latency / count));
        return true;
    }

    /// `.server netstatus`: this node's connection counts.
    bool handleNetworkStatusCommand()
    {
        blueSystemMessage(format!"Local connections: %s active  ·  %s peak  ·  %s accepted"
            (context.sessionCount, context.peakSessions, context.acceptedSessions));
        return true;
    }

    /// `.dismount`: the selected player or creature (oneself without a selection) dismounted.
    bool handleDismountCommand()
    {
        auto target = selectedCharacter(false);
        auto creature = target is null ? selectedCreature(false) : null;
        if (target is null && creature is null)
        {
            redSystemMessage("No target found.");
            return true;
        }
        auto values = target !is null ? &target.player.values : &creature.values;
        if (values.get!UNIT_FIELD_MOUNTDISPLAYID == 0)
        {
            redSystemMessage("Target is not mounted.");
            return true;
        }
        values.set!UNIT_FIELD_MOUNTDISPLAYID(0u);
        if (target !is null)
            target.flushPlayerChanges();
        else
            map.flushObjectChanges(creature);
        greenSystemMessage("Now unmounted.");
        return true;
    }

    /// `.server save`: the selected player saved, if its periodic save is less than 5 minutes away.
    bool handleSaveCommand()
    {
        auto target = selectedCharacter(false);
        if (target is null)
            return false;
        if (target.saveTimer.interval - target.saveTimer.elapsed >= 300.seconds)
        {
            redSystemMessage("You can only save once every 5 minutes.");
            return true;
        }
        target.savePlayer();
        greenSystemMessage(format!"Saved %s."(target.player.data.name));
        return true;
    }

    /// `.gm list`: the staff online (in a cluster, on every node), with their roles.
    bool handleGmListCommand()
    {
        bool first = true;
        const viewerIsStaff = isStaff;
        const onlyActive = context.config.gamemasterListOnlyActiveGMs;
        void list(string name, string roles, bool tagOn)
        {
            if (onlyActive && !tagOn && !viewerIsStaff)
                return;
            if (first)
                greenSystemMessage("Active GMs");
            if (context.config.gamemasterHidePermissions && !viewerIsStaff)
                systemMessage(" - " ~ name);
            else if (onlyActive && !tagOn)
                colorSystemMessage(ChatColor.grey, format!" - %s [%s]"(name, roles));
            else
                systemMessage(format!" - %s [%s]"(name, roles));
            first = false;
        }

        foreach (other; context.onlinePlayers)
            if (other.isStaff)
                list(other.character.data.name, sessionOf(other).staffRoles, other.character.gmTagOn);
        foreach (ref remote; context.remotePlayers)
            if (remote.entry.flags & PresenceFlags.staff)
                list(remote.entry.name, remote.entry.staffRoles, (remote.entry.flags & PresenceFlags.gmTag) != 0);
        if (first)
            systemMessage("There are no GMs currently logged in on this server.");
        return true;
    }

    /// `.debug rangecheck`: the distances to the selected unit.
    bool handleRangeCheckCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        systemMessage("=== RANGE CHECK ===");
        if (guid == 0)
        {
            redSystemMessage("No selection.");
            return true;
        }
        Position at;
        if (auto other = map.find(guid))
            at = other.character.position;
        else if (auto object = map.findObject(guid))
            at = object.position;
        else
        {
            redSystemMessage("Invalid selection.");
            return true;
        }
        const own = player.position;
        const dx = at.x - own.x, dy = at.y - own.y, dz = at.z - own.z;
        const float distanceSq = dx * dx + dy * dy + dz * dz;
        systemMessage(format!"GetDistanceSq  :   %u"(cast(uint) distanceSq));
        systemMessage(format!"CalcDistance   :   %u"(cast(uint) sqrt(distanceSq)));
        systemMessage(format!"GetDistance2dSq:   %u"(cast(uint)(dx * dx + dy * dy)));
        return true;
    }

    /// `.logcomment <comment>`: a note in the GM log.
    bool handleGmLogCommentCommand(Rest comment)
    {
        greenSystemMessage("GM log updated: " ~ comment);
        gmLog("Logcomment: " ~ comment);
        return true;
    }
}
