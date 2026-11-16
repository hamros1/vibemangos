/**
 * GM commands that move players (ArcEmu `Level1.cpp`/`Level3.cpp`'s
 * appear, summon, worldport, gotrig, start, `RecallCommands.cpp`, and
 * CMaNGOS's `.go xyz`, `.tele`, `.recall`). Mixed into
 * `dmangos.world.session.WorldSession` like the other handler groups.
 *
 * ArcEmu's recall locations are CMaNGOS's `game_tele` places: `.recall
 * list/port/add/del` read and write that table, so `.tele` sees the same
 * places. `.recall` alone returns to where the last command teleport
 * started, as in CMaNGOS.
 */
module dmangos.world.gmtravel;

/// See the module documentation.
mixin template TravelCommands()
{
    import std.algorithm.searching : canFind;
    import std.array : join, replace, split;
    import std.format : format;
    import std.uni : toLower;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.commands : Command, readArguments;
    import dmangos.world.movement : Position;
    import dmangos.world.worlddata : GameTele, WorldData;

private:
    /// Teleports `who` with a command, checking the destination first; reports what went wrong.
    bool commandTeleportChecked(WorldSession who, uint mapId, Position destination)
    {
        const entry = context.client.maps.lookup(mapId);
        if (entry is null || entry.isBattleground)
        {
            sendSystemMessage(format!"Map %s is battleground or arena. Not allowed through this command."(mapId));
            return false;
        }
        if (!context.client.isValidMapCoord(mapId, destination.x, destination.y, destination.z))
        {
            sendSystemMessage(format!"Invalid target coordinates (X: %s Y: %s) on map %s."(destination.x,
                destination.y, mapId));
            return false;
        }
        return who.commandTeleport(mapId, destination);
    }

    @Command("go xyz", AccountLevel.moderator, "x y z [map]", "Teleports you to a position, on this map or another.")
    bool commandGoXyz(string args)
    {
        float x, y, z;
        uint mapId = player.data.map;
        if (!readArguments!3(args.replace(",", " "), x, y, z, mapId))
            return false;
        commandTeleportChecked(this, mapId, Position(x, y, z, player.position.orientation));
        return true;
    }

    @Command("worldport", AccountLevel.moderator, "map x y z", "Teleports you to a position on a map.")
    bool commandWorldport(string args)
    {
        uint mapId;
        float x, y, z;
        if (!readArguments!4(args, mapId, x, y, z))
            return false;
        commandTeleportChecked(this, mapId, Position(x, y, z, player.position.orientation));
        return true;
    }

    @Command("tele", AccountLevel.moderator, "name", "Teleports you to a place of the game_tele table.", ["recall port"])
    bool commandTele(string args)
    {
        if (args.length == 0)
            return false;
        const tele = context.data.findTeleport(args);
        if (tele is null)
        {
            sendSystemMessage("Teleport location not found!");
            return true;
        }
        commandTeleport(tele.map, Position(tele.x, tele.y, tele.z, tele.orientation));
        return true;
    }

    @Command("recall portplayer", AccountLevel.gameMaster, "player place", "Teleports a player to a game_tele place.")
    bool commandRecallPortPlayer(string args)
    {
        string name, place;
        if (!readArguments!2(args, name, place))
            return false;
        auto target = context.onlinePlayer(name);
        const tele = context.data.findTeleport(place);
        if (target is null || tele is null)
        {
            sendSystemMessage(target is null ? format!"Player (%s) does not exist."(name) : "Teleport location not found!");
            return true;
        }
        if (sessionOf(target).commandTeleport(tele.map, Position(tele.x, tele.y, tele.z, tele.orientation)))
            tellBoth(sessionOf(target), format!"You are teleporting %s to %s."(target.character.data.name, tele.name),
                format!"You are being teleported by %s."(player.data.name));
        return true;
    }

    @Command("recall list", AccountLevel.moderator, "[text]", "Lists the game_tele places, or those whose name contains text.")
    bool commandRecallList(string args)
    {
        string[] names;
        foreach (ref tele; context.data.teleports)
            if (args.length == 0 || tele.name.toLower.canFind(args.toLower))
                names ~= tele.name;
        if (names.length == 0)
            sendSystemMessage("There are no teleport locations matching your request.");
        // One line per 20 names: the client cuts long messages.
        for (size_t i = 0; i < names.length; i += 20)
            sendSystemMessage(names[i .. i + 20 < names.length ? i + 20 : names.length].join(", "));
        return true;
    }

    @Command("recall add", AccountLevel.gameMaster, "name", "Saves where you stand as a game_tele place (CMaNGOS .tele add).")
    bool commandRecallAdd(string args)
    {
        if (args.length == 0)
            return false;
        foreach (ref tele; context.data.teleports)
            if (tele.name.toLower == args.toLower)
            {
                sendSystemMessage("A teleport location with this name already exists.");
                return true;
            }
        const p = player.position;
        const tele = GameTele(p.x, p.y, p.z, p.orientation, player.data.map, args);
        context.database.addTeleport(tele);
        context.data.teleports ~= cast(GameTele) tele;
        sendSystemMessage(format!"Teleport location '%s' added."(args));
        return true;
    }

    @Command("recall del", AccountLevel.gameMaster, "name", "Deletes a game_tele place (CMaNGOS .tele del).")
    bool commandRecallDel(string args)
    {
        import std.algorithm.mutation : remove;

        if (args.length == 0)
            return false;
        if (!context.database.deleteTeleport(args))
        {
            sendSystemMessage("Teleport location not found!");
            return true;
        }
        context.data.teleports = context.data.teleports.remove!(t => t.name == args);
        sendSystemMessage(format!"Teleport location '%s' deleted."(args));
        return true;
    }

    @Command("recall", AccountLevel.moderator, "", "Teleports you back to where you were before your last teleport command.")
    bool commandRecall(string)
    {
        commandTeleport(recallMap, recallPosition);
        return true;
    }

    @Command("appear", AccountLevel.moderator, "[name]", "Teleports you to a player, or to the one you have selected.")
    bool commandAppear(string args)
    {
        auto target = targetPlayer(args);
        if (target is null || target is this)
        {
            sendSystemMessage(target is null ? "No character selected." : "You can't teleport self to self!");
            return true;
        }
        if (sessionOf(target).transferring)
        {
            sendSystemMessage(format!"%s is already being teleported."(target.character.data.name));
            return true;
        }
        if (commandTeleport(target.character.data.map, target.character.position))
            tellBoth(sessionOf(target), format!"Appearing at %s's location."(target.character.data.name),
                format!"%s is appearing to your location."(player.data.name));
        return true;
    }

    @Command("summon", AccountLevel.moderator, "[name]", "Teleports a player, or the one you have selected, to you.")
    bool commandSummon(string args)
    {
        auto target = targetPlayer(args);
        if (target is null || target is this)
        {
            sendSystemMessage(target is null ? "No character selected." : "You can't teleport self to self!");
            return true;
        }
        auto other = sessionOf(target);
        if (other.commandTeleport(player.data.map, player.position))
            tellBoth(other, format!"You are summoning %s."(target.character.data.name),
                format!"You are being teleported by %s."(player.data.name));
        return true;
    }

    @Command("admin masssummon", AccountLevel.administrator, "", "Summons every player online to you.", ["masssummon"])
    bool commandMassSummon(string)
    {
        size_t count;
        foreach (other; context.onlinePlayers)
            if (other !is this && sessionOf(other).commandTeleport(player.data.map, player.position))
            {
                sessionOf(other).sendSystemMessage(format!"You are being teleported by %s."(player.data.name));
                ++count;
            }
        sendSystemMessage(format!"Summoned %s players."(count));
        return true;
    }

    @Command("gotrig", AccountLevel.moderator, "id", "Teleports you to an area trigger of AreaTrigger.dbc.")
    bool commandGoTrigger(string args)
    {
        uint id;
        if (!readArguments!1(args, id))
            return false;
        const trigger = context.client.areaTriggers.lookup(id);
        if (trigger is null)
        {
            sendSystemMessage(format!"Area trigger %s does not exist."(id));
            return true;
        }
        commandTeleportChecked(this, trigger.mapId, Position(trigger.x, trigger.y, trigger.z,
            player.position.orientation));
        return true;
    }

    @Command("start", AccountLevel.moderator, "[race]",
        "Teleports you to where your race, or the one named (human, orc, dwarf, nightelf, undead, tauren, gnome, troll), starts.")
    bool commandStart(string args)
    {
        static immutable string[] races = ["", "human", "orc", "dwarf", "nightelf", "undead", "tauren", "gnome", "troll"];
        ubyte race = player.data.race;
        if (args.length)
        {
            race = 0;
            foreach (ubyte i, name; races)
                if (i && name == args.toLower.replace(" ", ""))
                    race = i;
            if (race == 0)
                return false;
        }
        // Any class of the race starts in the same place.
        foreach (ubyte classId; 1 .. 12)
            if (const info = context.data.createInfo(race, classId))
            {
                commandTeleportChecked(this, info.map, Position(info.x, info.y, info.z, info.orientation));
                return true;
            }
        sendSystemMessage("That race has no start location.");
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import dmangos.world.testclient;
}

/// Recall places in game_tele, area triggers, start locations.
unittest
{
    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.gameMaster);
    gm.read();

    gm.say(".recall add Northshire");
    assert(db.teleportRows.length == 1 && context.data.findTeleport("northshire") !is null);
    gm.say(".recall list north");
    assert(systemMessages(gm.read())[$ - 1] == "Northshire");
    gm.say(".gotrig " ~ triggerDeadmines.stringof[0 .. $ - 1]);
    assert(gm.session.character.position.x == deadminesEntrance[0]);
    gm.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(7, 0, 0));
    gm.say(".recall port Northshire"); // not `.recall portplayer`
    assert(gm.session.character.position.x == -8949.95f);
    gm.write(Opcode.MSG_MOVE_TELEPORT_ACK, ClientTeleportAck(7, 1, 0));
    gm.say(".recall del Northshire");
    assert(db.teleportRows.length == 0 && context.data.findTeleport("northshire") is null);

    // `.start orc`: Kalimdor, where orc hunters start in the test data.
    gm.say(".start orc");
    assert(gm.session.transferring && gm.session.character.data.map == 1);
}
