/// Draft and save a native spawn's waypoint route.
module dmangos.world.gmwaypoint;

/// See the module documentation.
mixin template WaypointCommands()
{
    import std.algorithm.searching : countUntil;
    import std.algorithm.sorting : sort;
    import std.format : format;
    import dmangos.mysql : DatabaseException;
    import dmangos.world.commands : ChatColor, colored;
    import dmangos.world.creature : Creature, TempSpawnType;
    import dmangos.world.motion : MotionType, WaypointGait, WaypointNode;
    import dmangos.world.objects : temporaryCounterStart;

private:
    enum uint maxWaypointPoint = 0xFF_FFFF;
    uint waypointSpawn;           // the spawn the draft is for; 0: none
    MotionType waypointMode;      // looped or linear
    WaypointNode[] waypointDraft; // its points, in order

    /// The selected creature if it is a saved spawn, its route loaded as the draft when it is a new one; null
    /// after a message otherwise.
    Creature waypointTarget()
    {
        auto creature = selectedCreature(true);
        if (creature is null)
            return null;
        const guid = creature.spawn.guid;
        if (!guid || guid >= temporaryCounterStart || creature.summon.type != TempSpawnType.none)
        {
            redSystemMessage("Select a saved creature spawn.");
            return null;
        }
        if (waypointSpawn != guid)
        {
            waypointSpawn = guid;
            waypointDraft = context.data.waypoints.defaultPath(creature.spawn.entry, waypointSpawn).dup;
            waypointMode = creature.spawn.movementType == MotionType.linearWaypoint
                ? MotionType.linearWaypoint : MotionType.waypoint;
        }
        return creature;
    }

    /// Where the point numbered `point` is in the draft; -1 if it is not.
    ptrdiff_t draftIndex(uint point)
    {
        return waypointDraft.countUntil!(node => node.point == point);
    }

    /// One line for a point: its place, wait, and what it does.
    void showWaypoint(const ref WaypointNode node)
    {
        string details;
        if (node.gait != WaypointGait.default_)
            details ~= format!"  ·  %s"(node.gait);
        if (node.scriptId)
            details ~= format!"  ·  Script %s"(node.scriptId);
        if (node.emote)
            details ~= format!"  ·  Emote %s"(node.emote);
        if (node.model)
            details ~= format!"  ·  Model %s"(node.model);
        systemMessage(format!"%s  ·  %.3f, %.3f, %.3f  ·  Wait %s ms%s"
            (colored(ChatColor.sky, format!"Point %s"(node.point)), node.x, node.y, node.z, node.delay, details));
    }

    /// `.wp list`: the selected spawn's draft.
    bool handleWaypointShowCommand()
    {
        if (!waypointTarget())
            return true;
        greenSystemMessage(format!"Route draft  ·  Spawn %s  ·  %s points"(waypointSpawn, waypointDraft.length));
        foreach (const ref node; waypointDraft)
            showWaypoint(node);
        return true;
    }

    /// `.wp discard`: the draft dropped unsaved.
    bool handleWaypointHideCommand()
    {
        waypointSpawn = 0;
        waypointDraft = null;
        greenSystemMessage("Unsaved route edits discarded.");
        return true;
    }

    /// `.wp script`: a movement script run at a point (0 clears it).
    bool handleWaypointScriptCommand(uint point, uint script)
    {
        import dmangos.world.dbscripts : DbScriptType;

        if (script && !context.data.dbScripts.steps(DbScriptType.creatureMovement, script).length)
            return false;
        if (!waypointTarget())
            return true;
        const index = draftIndex(point);
        if (index < 0)
            return false;
        waypointDraft[index].scriptId = script;
        return true;
    }

    /// `.wp generate`: the navigation mesh's path from the draft's last point (or the spawn) to the GM, added.
    bool handleGenerateWaypointsCommand()
    {
        import dmangos.vmap.math : Vector3;

        auto creature = waypointTarget();
        if (creature is null)
            return true;
        const at = player.position;
        const home = creature.spawn;
        const start = waypointDraft.length ? waypointDraft[$ - 1].point : 0;
        const from = waypointDraft.length ? Vector3(waypointDraft[$ - 1].x, waypointDraft[$ - 1].y,
            waypointDraft[$ - 1].z) : Vector3(home.x, home.y, home.z);
        const route = map.pathBetween(from, Vector3(at.x, at.y, at.z));
        if (route.length < 2 || route.length - 1 > maxWaypointPoint - start
            || (route[$ - 1].x - at.x) ^^ 2 + (route[$ - 1].y - at.y) ^^ 2 + (route[$ - 1].z - at.z) ^^ 2 > 4)
        {
            redSystemMessage("No complete navigation path reaches your position.");
            return true;
        }
        foreach (node; route[1 .. $])
            if (!context.client.isValidMapCoord(map.id, node.x, node.y, node.z))
                return false;
        foreach (i, node; route[1 .. $])
            waypointDraft ~= WaypointNode(start + cast(uint) i + 1, node.x, node.y, node.z);
        greenSystemMessage(format!"Added %s navigation points to the draft."(route.length - 1));
        return true;
    }

    /// `.wp info`: one point of the draft.
    bool handleWaypointInfoCommand(uint point)
    {
        if (!waypointTarget())
            return true;
        const index = draftIndex(point);
        if (index < 0)
            redSystemMessage("That point is not in the draft.");
        else
            showWaypoint(waypointDraft[index]);
        return true;
    }

    /// `.wp add`: the GM's position added as the draft's next point.
    bool handleWaypointAddCommand(uint waitMs = 0)
    {
        return addDraftPoint(waitMs, WaypointGait.default_);
    }

    /// `.wp add-air`: as `.wp add`, flown to, for a creature that can fly.
    bool handleWaypointAddFlyCommand(uint waitMs = 0)
    {
        return addDraftPoint(waitMs, WaypointGait.fly);
    }

    /// The GM's position added as the draft's next point, reached with `gait`.
    bool addDraftPoint(uint waitMs, WaypointGait gait)
    {
        auto creature = waypointTarget();
        if (creature is null)
            return true;
        if (gait == WaypointGait.fly && !(creature.template_.inhabitType & 4))
        {
            redSystemMessage("Select a creature whose template allows flight.");
            return true;
        }
        const at = player.position;
        if (!context.client.isValidMapCoord(map.id, at.x, at.y, at.z)
            || (waypointDraft.length && waypointDraft[$ - 1].point >= maxWaypointPoint))
            return false;
        const point = waypointDraft.length ? waypointDraft[$ - 1].point + 1 : 1;
        waypointDraft ~= WaypointNode(point, at.x, at.y, at.z, at.orientation, waitMs, 0, gait);
        showWaypoint(waypointDraft[$ - 1]);
        return true;
    }

    /// The draft's point numbered `point`; null after a message if there is none.
    WaypointNode* draftPoint(uint point)
    {
        if (waypointTarget() is null)
            return null;
        const index = draftIndex(point);
        if (index < 0)
        {
            redSystemMessage("This point is not in the draft.");
            return null;
        }
        return &waypointDraft[index];
    }

    /// `.wp gait`: how the creature moves to a point.
    bool handleWaypointGaitCommand(uint point, string mode)
    {
        WaypointGait gait;
        switch (mode)
        {
        case "default": gait = WaypointGait.default_; break;
        case "walk": gait = WaypointGait.walk; break;
        case "run": gait = WaypointGait.run; break;
        default: return false;
        }
        if (auto node = draftPoint(point))
        {
            node.gait = gait;
            showWaypoint(*node);
        }
        return true;
    }

    /// `.wp emote`: an emote played at a point (0 clears it).
    bool handleWaypointEmoteCommand(uint point, uint emote)
    {
        if (emote && context.client.emotes.lookup(emote) is null)
        {
            redSystemMessage("Unknown emote ID.");
            return true;
        }
        if (auto node = draftPoint(point))
        {
            node.emote = emote;
            showWaypoint(*node);
        }
        return true;
    }

    /// `.wp model`: a model the creature takes at a point (0 clears it).
    bool handleWaypointModelCommand(uint point, uint display)
    {
        if (display && context.client.creatureDisplays.lookup(display) is null)
        {
            redSystemMessage("Unknown display ID.");
            return true;
        }
        if (auto node = draftPoint(point))
        {
            node.model = display;
            showWaypoint(*node);
        }
        return true;
    }

    /// `.wp delete`: a point taken out of the draft.
    bool handleWaypointDeleteCommand(uint point)
    {
        import std.algorithm.mutation : remove;

        if (!waypointTarget())
            return true;
        const index = draftIndex(point);
        if (index < 0)
            redSystemMessage("That point is not in the draft.");
        else
            waypointDraft = waypointDraft.remove(index);
        return true;
    }

    /// `.wp move`: a point moved to the GM's position and facing.
    bool handleWaypointMoveHereCommand(uint point)
    {
        if (!waypointTarget())
            return true;
        const index = draftIndex(point);
        const at = player.position;
        if (index < 0 || !context.client.isValidMapCoord(map.id, at.x, at.y, at.z))
            return false;
        waypointDraft[index].x = at.x;
        waypointDraft[index].y = at.y;
        waypointDraft[index].z = at.z;
        waypointDraft[index].orientation = at.orientation;
        return true;
    }

    /// `.wp wait`: how long the creature waits at a point.
    bool handleWaypointWaitCommand(uint point, uint waitMs)
    {
        if (!waypointTarget())
            return true;
        const index = draftIndex(point);
        if (index < 0)
            return false;
        waypointDraft[index].delay = waitMs;
        return true;
    }

    /// `.wp renumber`: a point given a free number, the draft kept in order.
    bool handleWaypointChangeNoCommand(uint point, uint replacement)
    {
        if (!waypointTarget())
            return true;
        const index = draftIndex(point);
        if (index < 0 || !replacement || replacement > maxWaypointPoint || draftIndex(replacement) >= 0)
            return false;
        waypointDraft[index].point = replacement;
        waypointDraft.sort!((a, b) => a.point < b.point);
        return true;
    }

    /// `.wp mode`: the route looped or run in a line.
    bool handleWaypointMoveTypeCommand(string mode)
    {
        if (mode != "loop" && mode != "linear")
            return false;
        if (waypointTarget())
            waypointMode = mode == "linear" ? MotionType.linearWaypoint : MotionType.waypoint;
        return true;
    }

    /// `.wp clear`: every point taken out of the draft.
    bool handleDeleteWaypointsCommand()
    {
        if (!waypointTarget())
            return true;
        waypointDraft = null;
        greenSystemMessage("Draft cleared. Use .wp save to apply.");
        return true;
    }

    /// `.wp save`: the draft saved as the spawn's route (an empty one leaves it idle), for the workers to load
    /// on restart.
    bool handleSaveWaypointsCommand()
    {
        if (!waypointTarget())
            return true;
        try
        {
            const mode = waypointDraft.length ? waypointMode : MotionType.idle;
            if (!context.canWrite() || !context.database.saveSpawnWaypoints(waypointSpawn, mode, waypointDraft))
            {
                redSystemMessage("The draft could not be saved. Check that the spawn exists and the world waypoint "
                    ~ "migration is installed.");
                return true;
            }
            gmLog(format!"saved %s waypoint(s) for spawn %s"(waypointDraft.length, waypointSpawn));
            greenSystemMessage("Route saved. World workers load it on restart.");
        }
        catch (DatabaseException)
            redSystemMessage("The world database could not save the waypoint draft.");
        return true;
    }
}

/// Edits only change the database on save, and deleting a route makes the saved spawn idle.
unittest
{
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.motion : MotionType;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.objects : HighGuid, makeGuid;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto gm = loggedIn(context, db, 7, "Varian", Position(-8930, -120, 83.53f), AccountLevel.administrator);
    gm.say(".npc spawn 6774");
    gm.read();
    const spawn = db.creatureSpawnRows.values[0];
    gm.write(Opcode.CMSG_SET_SELECTION, ClientGuid(makeGuid(HighGuid.unit, spawn.entry, spawn.guid)));
    gm.say(".wp add 150");
    assert(systemMessages(gm.read()).length == 1 && spawn.guid !in db.waypointRows);
    gm.say(".wp mode linear");
    gm.say(".waypoint save");
    gm.read();
    assert(db.waypointRows[spawn.guid].length == 1 && db.waypointRows[spawn.guid][0].delay == 150);
    assert(db.creatureSpawnRows[spawn.guid].movementType == MotionType.linearWaypoint);

    gm.say(".wp clear");
    gm.say(".waypoint save");
    gm.read();
    assert(!db.waypointRows[spawn.guid].length && db.creatureSpawnRows[spawn.guid].movementType == MotionType.idle);
}
