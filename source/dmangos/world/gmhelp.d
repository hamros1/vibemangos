/// Command discovery and player support information.
module dmangos.world.gmhelp;

/// See the module documentation.
mixin template SupportCommands()
{
    import dmangos.world.context : PresenceFlags;
    import core.time : seconds;
    import std.algorithm.searching : countUntil;
    import std.format : format;
    import std.math : sqrt;
    import std.uni : toLower;
    import dmangos.log;
    import dmangos.world.commands;
    import dmangos.world.commandtable;
    import dmangos.world.movement : Position;
    import dmangos.world.updatefields;

private:
    bool handleHelpCommand(Rest command = Rest.init)
    {
        return browseCommands(command, true);
    }

    bool handleCommandsCommand(Rest filter = Rest.init)
    {
        return browseCommands(filter, false);
    }

    private bool browseCommands(string query, bool help)
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

    bool handleStartCommand(string raceName = null)
    {
        static immutable string[12] races = ["", "human", "orc", "dwarf", "nightelf", "undead", "tauren", "gnome",
            "troll", "", "bloodelf", "draenei"];
        auto plr = selectedCharacter(false);
        uint raceId;
        string race;
        if (plr !is null && raceName.length < 2)
        {
            raceId = plr.player.data.race;
            if (raceId >= races.length || races[raceId].length == 0)
                return false;
            race = races[raceId];
        }
        else if (plr !is null && raceName.length > 2)
        {
            race = raceName.toLower;
            const found = races[].countUntil(race); // `race` is not empty: never one of the gaps
            raceId = found < 0 ? 0 : cast(uint) found;
            if (raceId == 0)
            {
                redSystemMessage("Invalid start location! Valid locations are: human, dwarf, gnome, nightelf, "
                    ~ "draenei, orc, troll, tauren, undead, bloodelf");
                return true;
            }
        }
        else
            return false;

        // Try to find a class that works.
        typeof(context.data.createInfo(0, 0)) info;
        foreach (ubyte classId; 1 .. 11)
            if ((info = context.data.createInfo(cast(ubyte) raceId, classId)) !is null)
                break;
        if (info is null)
        {
            redSystemMessage("Internal error: Could not find create info.");
            return false;
        }
        greenSystemMessage(format!"Sending %s to the %s starting area."(plr.player.data.name, race));
        plr.commandTeleport(info.map, Position(info.x, info.y, info.z, 0));
        return true;
    }

    bool handleInfoCommand()
    {
        uint gm, count;
        ulong latency;
        foreach (other; context.onlinePlayers)
        {
            ++count;
            latency += sessionOf(other).latencyMs;
            if (other.isStaff)
                ++gm;
        }
        // In a cluster, the other nodes' players too.
        const elsewhere = context.remotePlayers;
        foreach (ref r; elsewhere)
            if (r.entry.flags & PresenceFlags.staff)
                ++gm;
        const up = context.unixTime - context.startTime;
        greenSystemMessage("dmangos  ·  Server status");
        systemMessage(format!"%s players online  ·  %s staff  ·  Uptime %sd %02d:%02d:%02d"
            (count + elsewhere.length, gm, up / 86_400, up / 3600 % 24, up / 60 % 60, up % 60));
        if (count)
            systemMessage(format!"Local latency averages %.1f ms."(cast(double) latency / count));
        return true;
    }

    bool handleNetworkStatusCommand()
    {
        blueSystemMessage(format!"Local connections: %s active  ·  %s peak  ·  %s accepted"
            (context.sessionCount, context.peakSessions, context.acceptedSessions));
        return true;
    }

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
        blueSystemMessage("Now unmounted.");
        return true;
    }

    bool handleSaveCommand()
    {
        auto target = selectedCharacter(false);
        if (target is null)
            return false;
        // Only when the next periodic save (every `player_save_interval`) is less than 5 minutes
        // away.
        if (target.saveTimer.interval - target.saveTimer.elapsed < 300.seconds)
        {
            target.savePlayer();
            greenSystemMessage(format!"Saved %s."(target.player.data.name));
        }
        else
            redSystemMessage("You can only save once every 5 minutes.");
        return true;
    }

    bool handleGmListCommand()
    {
        bool first = true;
        const isGM = isStaff;
        const onlyActive = context.config.gamemasterListOnlyActiveGMs;
        void list(string name, string roles, bool tagOn)
        {
            if (!(isGM || !onlyActive || tagOn))
                return;
            if (first)
                greenSystemMessage("Active GMs");
            if (context.config.gamemasterHidePermissions && !isGM)
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
        // In a cluster, the other nodes' GMs too, as presence says.
        foreach (ref r; context.remotePlayers)
            if (r.entry.flags & PresenceFlags.staff)
                list(r.entry.name, r.entry.staffRoles, (r.entry.flags & PresenceFlags.gmTag) != 0);
        if (first)
            systemMessage("There are no GMs currently logged in on this server.");
        return true;
    }

    bool handleRangeCheckCommand()
    {
        const guid = player.values.get!UNIT_FIELD_TARGET;
        systemMessage("=== RANGE CHECK ===");
        if (guid == 0)
        {
            systemMessage("No selection.");
            return true;
        }
        Position at;
        if (auto other = map.find(guid))
            at = other.character.position;
        else if (auto object = map.findObject(guid))
            at = object.position;
        else
        {
            systemMessage("Invalid selection.");
            return true;
        }
        const me = player.position;
        const dx = at.x - me.x, dy = at.y - me.y, dz = at.z - me.z;
        const float distanceSq = dx * dx + dy * dy + dz * dz;
        systemMessage(format!"GetDistanceSq  :   %u"(cast(uint) distanceSq));
        systemMessage(format!"CalcDistance   :   %u"(cast(uint) sqrt(distanceSq)));
        systemMessage(format!"GetDistance2dSq:   %u"(cast(uint)(dx * dx + dy * dy)));
        return true;
    }

    bool handleGmLogCommentCommand(Rest comment)
    {
        blueSystemMessage("GM log updated: " ~ comment);
        gmLog("Logcomment: " ~ comment);
        return true;
    }
}
