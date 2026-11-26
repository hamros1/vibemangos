/**
 * Draft and save a native spawn's waypoint route.
 *
 * Each command's action is a function here taking first the player who typed it (`gm`); the catalog
 * (`dmangos.world.commandtable`) names it and `dmangos.world.commands` calls it.
 */
module dmangos.world.gmwaypoint;

import dmangos.world.character : Character;

import std.algorithm.searching : countUntil;
import std.algorithm.sorting : sort;
import std.format : format;
import dmangos.mysql : DatabaseException;
import dmangos.world.commands : ChatColor, colored;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.motion : MotionType, WaypointGait, WaypointNode;
import dmangos.world.objects : temporaryCounterStart;

enum uint maxWaypointPoint = 0xFF_FFFF;

/// The selected creature if it is a saved spawn, its route loaded as the draft when it is a new one; null
/// after a message otherwise.
Creature waypointTarget(Character gm)
{
    auto creature = gm.selectedCreature(true);
    if (creature is null)
        return null;
    const guid = creature.spawn.guid;
    if (!guid || guid >= temporaryCounterStart || creature.summon.type != TempSpawnType.none)
    {
        gm.redSystemMessage("Select a saved creature spawn.");
        return null;
    }
    if (gm.gmState.waypointSpawn != guid)
    {
        gm.gmState.waypointSpawn = guid;
        gm.gmState.waypointDraft = gm.context.data.waypoints.defaultPath(creature.spawn.entry, gm.gmState.waypointSpawn).dup;
        gm.gmState.waypointMode = creature.spawn.movementType == MotionType.linearWaypoint
            ? MotionType.linearWaypoint : MotionType.waypoint;
    }
    return creature;
}

/// Where the point numbered `point` is in the draft; -1 if it is not.
ptrdiff_t draftIndex(Character gm, uint point)
{
    return gm.gmState.waypointDraft.countUntil!(node => node.point == point);
}

/// One line for a point: its place, wait, and what it does.
void showWaypoint(Character gm, const ref WaypointNode node)
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
    gm.systemMessage(format!"%s  ·  %.3f, %.3f, %.3f  ·  Wait %s ms%s"
        (colored(ChatColor.sky, format!"Point %s"(node.point)), node.x, node.y, node.z, node.delay, details));
}

/// `.wp list`: the selected spawn's draft.
bool handleWaypointShowCommand(Character gm)
{
    if (!gm.waypointTarget())
        return true;
    gm.greenSystemMessage(format!"Route draft  ·  Spawn %s  ·  %s points"(gm.gmState.waypointSpawn, gm.gmState.waypointDraft.length));
    foreach (const ref node; gm.gmState.waypointDraft)
        gm.showWaypoint(node);
    return true;
}

/// `.wp discard`: the draft dropped unsaved.
bool handleWaypointHideCommand(Character gm)
{
    gm.gmState.waypointSpawn = 0;
    gm.gmState.waypointDraft = null;
    gm.greenSystemMessage("Unsaved route edits discarded.");
    return true;
}

/// `.wp script`: a movement script run at a point (0 clears it).
bool handleWaypointScriptCommand(Character gm, uint point, uint script)
{
    import dmangos.world.dbscripts : DbScriptType;

    if (script && !gm.context.data.dbScripts.steps(DbScriptType.creatureMovement, script).length)
        return false;
    if (!gm.waypointTarget())
        return true;
    const index = gm.draftIndex(point);
    if (index < 0)
        return false;
    gm.gmState.waypointDraft[index].scriptId = script;
    return true;
}

/// `.wp generate`: the navigation mesh's path from the draft's last point (or the spawn) to the GM, added.
bool handleGenerateWaypointsCommand(Character gm)
{
    import dmangos.vmap.math : Vector3;

    auto creature = gm.waypointTarget();
    if (creature is null)
        return true;
    const at = gm.player.position;
    const home = creature.spawn;
    const start = gm.gmState.waypointDraft.length ? gm.gmState.waypointDraft[$ - 1].point : 0;
    const from = gm.gmState.waypointDraft.length ? Vector3(gm.gmState.waypointDraft[$ - 1].x, gm.gmState.waypointDraft[$ - 1].y,
        gm.gmState.waypointDraft[$ - 1].z) : Vector3(home.x, home.y, home.z);
    const route = gm.map.pathBetween(from, Vector3(at.x, at.y, at.z));
    if (route.length < 2 || route.length - 1 > maxWaypointPoint - start
        || (route[$ - 1].x - at.x) ^^ 2 + (route[$ - 1].y - at.y) ^^ 2 + (route[$ - 1].z - at.z) ^^ 2 > 4)
    {
        gm.redSystemMessage("No complete navigation path reaches your position.");
        return true;
    }
    foreach (node; route[1 .. $])
        if (!gm.context.client.isValidMapCoord(gm.map.id, node.x, node.y, node.z))
            return false;
    foreach (i, node; route[1 .. $])
        gm.gmState.waypointDraft ~= WaypointNode(start + cast(uint) i + 1, node.x, node.y, node.z);
    gm.greenSystemMessage(format!"Added %s navigation points to the draft."(route.length - 1));
    return true;
}

/// `.wp info`: one point of the draft.
bool handleWaypointInfoCommand(Character gm, uint point)
{
    if (!gm.waypointTarget())
        return true;
    const index = gm.draftIndex(point);
    if (index < 0)
        gm.redSystemMessage("That point is not in the draft.");
    else
        gm.showWaypoint(gm.gmState.waypointDraft[index]);
    return true;
}

/// `.wp add`: the GM's position added as the draft's next point.
bool handleWaypointAddCommand(Character gm, uint waitMs = 0)
{
    return gm.addDraftPoint(waitMs, WaypointGait.default_);
}

/// `.wp add-air`: as `.wp add`, flown to, for a creature that can fly.
bool handleWaypointAddFlyCommand(Character gm, uint waitMs = 0)
{
    return gm.addDraftPoint(waitMs, WaypointGait.fly);
}

/// The GM's position added as the draft's next point, reached with `gait`.
bool addDraftPoint(Character gm, uint waitMs, WaypointGait gait)
{
    auto creature = gm.waypointTarget();
    if (creature is null)
        return true;
    if (gait == WaypointGait.fly && !(creature.template_.inhabitType & 4))
    {
        gm.redSystemMessage("Select a creature whose template allows flight.");
        return true;
    }
    const at = gm.player.position;
    if (!gm.context.client.isValidMapCoord(gm.map.id, at.x, at.y, at.z)
        || (gm.gmState.waypointDraft.length && gm.gmState.waypointDraft[$ - 1].point >= maxWaypointPoint))
        return false;
    const point = gm.gmState.waypointDraft.length ? gm.gmState.waypointDraft[$ - 1].point + 1 : 1;
    gm.gmState.waypointDraft ~= WaypointNode(point, at.x, at.y, at.z, at.orientation, waitMs, 0, gait);
    gm.showWaypoint(gm.gmState.waypointDraft[$ - 1]);
    return true;
}

/// The draft's point numbered `point`; null after a message if there is none.
WaypointNode* draftPoint(Character gm, uint point)
{
    if (gm.waypointTarget() is null)
        return null;
    const index = gm.draftIndex(point);
    if (index < 0)
    {
        gm.redSystemMessage("This point is not in the draft.");
        return null;
    }
    return &gm.gmState.waypointDraft[index];
}

/// `.wp gait`: how the creature moves to a point.
bool handleWaypointGaitCommand(Character gm, uint point, string mode)
{
    WaypointGait gait;
    switch (mode)
    {
    case "default": gait = WaypointGait.default_; break;
    case "walk": gait = WaypointGait.walk; break;
    case "run": gait = WaypointGait.run; break;
    default: return false;
    }
    if (auto node = gm.draftPoint(point))
    {
        node.gait = gait;
        gm.showWaypoint(*node);
    }
    return true;
}

/// `.wp emote`: an emote played at a point (0 clears it).
bool handleWaypointEmoteCommand(Character gm, uint point, uint emote)
{
    if (emote && gm.context.client.emotes.lookup(emote) is null)
    {
        gm.redSystemMessage("Unknown emote ID.");
        return true;
    }
    if (auto node = gm.draftPoint(point))
    {
        node.emote = emote;
        gm.showWaypoint(*node);
    }
    return true;
}

/// `.wp model`: a model the creature takes at a point (0 clears it).
bool handleWaypointModelCommand(Character gm, uint point, uint display)
{
    if (display && gm.context.client.creatureDisplays.lookup(display) is null)
    {
        gm.redSystemMessage("Unknown display ID.");
        return true;
    }
    if (auto node = gm.draftPoint(point))
    {
        node.model = display;
        gm.showWaypoint(*node);
    }
    return true;
}

/// `.wp delete`: a point taken out of the draft.
bool handleWaypointDeleteCommand(Character gm, uint point)
{
    import std.algorithm.mutation : remove;

    if (!gm.waypointTarget())
        return true;
    const index = gm.draftIndex(point);
    if (index < 0)
        gm.redSystemMessage("That point is not in the draft.");
    else
        gm.gmState.waypointDraft = gm.gmState.waypointDraft.remove(index);
    return true;
}

/// `.wp move`: a point moved to the GM's position and facing.
bool handleWaypointMoveHereCommand(Character gm, uint point)
{
    if (!gm.waypointTarget())
        return true;
    const index = gm.draftIndex(point);
    const at = gm.player.position;
    if (index < 0 || !gm.context.client.isValidMapCoord(gm.map.id, at.x, at.y, at.z))
        return false;
    gm.gmState.waypointDraft[index].x = at.x;
    gm.gmState.waypointDraft[index].y = at.y;
    gm.gmState.waypointDraft[index].z = at.z;
    gm.gmState.waypointDraft[index].orientation = at.orientation;
    return true;
}

/// `.wp wait`: how long the creature waits at a point.
bool handleWaypointWaitCommand(Character gm, uint point, uint waitMs)
{
    if (!gm.waypointTarget())
        return true;
    const index = gm.draftIndex(point);
    if (index < 0)
        return false;
    gm.gmState.waypointDraft[index].delay = waitMs;
    return true;
}

/// `.wp renumber`: a point given a free number, the draft kept in order.
bool handleWaypointChangeNoCommand(Character gm, uint point, uint replacement)
{
    if (!gm.waypointTarget())
        return true;
    const index = gm.draftIndex(point);
    if (index < 0 || !replacement || replacement > maxWaypointPoint || gm.draftIndex(replacement) >= 0)
        return false;
    gm.gmState.waypointDraft[index].point = replacement;
    gm.gmState.waypointDraft.sort!((a, b) => a.point < b.point);
    return true;
}

/// `.wp mode`: the route looped or run in a line.
bool handleWaypointMoveTypeCommand(Character gm, string mode)
{
    if (mode != "loop" && mode != "linear")
        return false;
    if (gm.waypointTarget())
        gm.gmState.waypointMode = mode == "linear" ? MotionType.linearWaypoint : MotionType.waypoint;
    return true;
}

/// `.wp clear`: every point taken out of the draft.
bool handleDeleteWaypointsCommand(Character gm)
{
    if (!gm.waypointTarget())
        return true;
    gm.gmState.waypointDraft = null;
    gm.greenSystemMessage("Draft cleared. Use .wp save to apply.");
    return true;
}

/// `.wp save`: the draft saved as the spawn's route (an empty one leaves it idle), for the workers to load
/// on restart.
bool handleSaveWaypointsCommand(Character gm)
{
    if (!gm.waypointTarget())
        return true;
    try
    {
        const mode = gm.gmState.waypointDraft.length ? gm.gmState.waypointMode : MotionType.idle;
        if (!gm.context.canWrite() || !gm.context.database.saveSpawnWaypoints(gm.gmState.waypointSpawn, mode, gm.gmState.waypointDraft))
        {
            gm.redSystemMessage("The draft could not be saved. Check that the spawn exists and the world waypoint "
                ~ "migration is installed.");
            return true;
        }
        gm.gmLog(format!"saved %s waypoint(s) for spawn %s"(gm.gmState.waypointDraft.length, gm.gmState.waypointSpawn));
        gm.greenSystemMessage("Route saved. World workers load it on restart.");
    }
    catch (DatabaseException)
        gm.redSystemMessage("The world database could not save the waypoint draft.");
    return true;
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
