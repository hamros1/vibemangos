/**
 * The level 0 command handlers: `.help`, `.commands`, `.start`, `.server info`,
 * `.server netstatus`, `.dismount`, `.server save`, `.gm list`,
 * `.debug rangecheck` and `.logcomment`. Mixed into
 * `dmangos.world.character.Character`; `dmangos.world.commands` calls them.
 */
module dmangos.world.gmlevel0;

/// See the module documentation.
mixin template Level0Commands()
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
    /// The help of the command named by `cmd` and `words`. It skips the rows the player cannot use, as
    /// `executeCommandInTable` does (ArcEmu skips those it *can* use, which makes `.help` find nothing).
    bool showHelpForCommand(immutable(ChatCommand)[] table, string path, ref string words, string cmd)
    {
        foreach (ref row; table)
        {
            if (!hasStringAbbr(row.name, cmd))
                continue;
            const rowPath = path.length ? path ~ " " ~ row.name : row.name;
            const group = commandGroup(rowPath, row);
            if (group != '0' && !canUseCommand(group))
                continue;
            if (row.children.length)
            {
                const next = nextWord(words);
                if (next !is null && showHelpForCommand(row.children, rowPath, words, next))
                    return true;
            }
            if (row.help.length == 0)
            {
                systemMessage("There is no help for that command");
                return true;
            }
            sendMultilineMessage(row.help);
            return true;
        }
        return false;
    }

    bool handleHelpCommand(Rest command)
    {
        string words = command;
        const cmd = nextWord(words);
        if (!showHelpForCommand(commandTable, null, words, cmd))
            redSystemMessage("Sorry, no help was found for this command, or that command does not exist.");
        return true;
    }

    bool handleCommandsCommand(Rest filter = Rest.init)
    {
        string output = "Available commands: \n\n";
        uint count;
        foreach (ref row; commandTable)
        {
            if (filter.length && !hasStringAbbr(row.name, filter))
                continue;
            const group = commandGroup(row.name, row);
            if (group != '0' && !canUseCommand(group))
                continue;
            switch (group)
            {
            case 'z':
                output ~= MSG_COLOR_LIGHTRED ~ row.name ~ "|r, ";
                break;
            case 'm':
                output ~= MSG_COLOR_CYAN ~ row.name ~ ", "; // this colour is left open, without `|r`
                break;
            case 'c':
                output ~= MSG_COLOR_GREEN ~ row.name ~ "|r, ";
                break;
            default:
                output ~= MSG_COLOR_LIGHTBLUE ~ row.name ~ "|r, ";
                break;
            }
            if (++count == 5) // 5 per line
            {
                output ~= "\n";
                count = 0;
            }
        }
        if (count)
            output ~= "\n";
        sendMultilineMessage(output);
        return true;
    }

    bool handleStartCommand(string raceName = null)
    {
        static immutable string[12] races = ["", "human", "orc", "dwarf", "nightelf", "undead", "tauren", "gnome",
            "troll", "", "bloodelf", "draenei"];
        auto plr = getSelectedChar(false);
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
        greenSystemMessage(format!"Telporting %s to %s starting location."(plr.player.data.name, race));
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
            if (other.hasPermissions)
                ++gm;
        }
        // In a cluster, the other nodes' players too.
        const elsewhere = context.remotePlayers;
        foreach (ref r; elsewhere)
            if (r.entry.flags & PresenceFlags.permissions)
                ++gm;
        greenSystemMessage(format!"Server Revision: |r%sdmangos %s(a World of Warcraft 1.12 server in D)"(
            MSG_COLOR_WHITE, MSG_COLOR_LIGHTBLUE));
        greenSystemMessage("Server Uptime: |r" ~ uptimeString());
        greenSystemMessage(format!"Current Players: |r%d (%d GMs, %d queued)"(context.sessionCount + elsewhere.length,
            gm, 0));
        greenSystemMessage(format!"Active Thread Count: |r%u"(1)); // one thread runs the world
        greenSystemMessage(format!"Free Thread Count: |r%u"(0));
        greenSystemMessage(format!"Average Latency: |r%.3fms"(cast(float) latency / count));
        greenSystemMessage(format!"SQL Query Cache Size (World): |r%u queries delayed"(0)); // queries run at once
        greenSystemMessage(format!"SQL Query Cache Size (Character): |r%u queries delayed"(0));
        return true;
    }

    /// How long the server has been up, in days, hours, minutes and seconds.
    string uptimeString()
    {
        const up = context.unixTime - context.startTime;
        return format!"%u days, %u hours, %u minutes, %u seconds."(up / 86_400 % 365, up / 3600 % 24, up / 60 % 60,
            up % 60);
    }

    /// The network status, written to the server's console only.
    bool handleNetworkStatusCommand()
    {
        info!"Network status: %s sessions (at most %s since start-up), %s accepted"(context.sessionCount,
            context.peakSessions, context.acceptedSessions);
        return true;
    }

    bool handleDismountCommand()
    {
        auto target = getSelectedChar(false);
        auto creature = target is null ? getSelectedCreature(false) : null;
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
        auto target = getSelectedChar(false);
        if (target is null)
            return false;
        // Only when the next periodic save (every `player_save_interval`) is less than 5 minutes
        // away.
        if (target.saveTimer.interval - target.saveTimer.elapsed < 300.seconds)
        {
            target.savePlayer();
            greenSystemMessage(format!"Player %s saved to DB"(target.player.data.name));
        }
        else
            redSystemMessage("You can only save once every 5 minutes.");
        return true;
    }

    bool handleGMListCommand()
    {
        bool first = true;
        const isGM = hasPermissions;
        const onlyActive = context.config.gamemasterListOnlyActiveGMs;
        void list(string name, string permissions, bool tagOn)
        {
            if (!(isGM || !onlyActive || tagOn))
                return;
            if (first)
                greenSystemMessage("There are following active GMs on this server:");
            if (context.config.gamemasterHidePermissions && !isGM)
                systemMessage(" - " ~ name);
            else if (onlyActive && !tagOn)
                systemMessage(format!"|cff888888 - %s [%s]|r"(name, permissions));
            else
                systemMessage(format!" - %s [%s]"(name, permissions));
            first = false;
        }

        foreach (other; context.onlinePlayers)
            if (other.hasPermissions)
                list(other.character.data.name, sessionOf(other).permissions, other.character.gmTagOn);
        // In a cluster, the other nodes' GMs too, as presence says.
        foreach (ref r; context.remotePlayers)
            if (r.entry.flags & PresenceFlags.permissions)
                list(r.entry.name, r.entry.permissions, (r.entry.flags & PresenceFlags.gmTag) != 0);
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
        blueSystemMessage("Added Logcomment: " ~ comment);
        gmLog("Logcomment: " ~ comment);
        return true;
    }
}
