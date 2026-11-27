/**
 * Spawns made and deleted by game masters (`.npc spawn`, `.gobject spawn`, their deletes and moves): put on the
 * map, registered in the world data, saved to the world database, and erased again (`WorldContext.spawnEditor`).
 */
module dmangos.world.spawnediting;

import dmangos.world.creature : Creature, CreatureSpawn;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectType;
import dmangos.world.movement : Position;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.map : Map;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class SpawnEditor
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    package bool[uint] unsavedGameObjectSpawns;

    /**
     * A new `creature` row of `entry` at `at` on `map` (saved, in the world data and its cell, so that
     * it comes back when the cell loads again), and its creature there now; null if it cannot be made.
     */
    Creature spawnCreatureAt(Map map, uint entry, Position at)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!world.canWrite() || entry !in world.data.creatureTemplates)
            return null;
        CreatureSpawn spawn = {entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation, respawnSeconds: 120, respawnSecondsMax: 120};
        try
            spawn.guid = world.database.createCreatureSpawn(spawn);
        catch (DatabaseException error)
        {
            warning!"could not save the new creature spawn %s: %s"(entry, error.msg);
            return null;
        }
        if (!spawn.guid)
            return null;
        // Load the other spawns first so addObject installs and returns this creature.
        map.loadCell(cellKeyAt(spawn.x, spawn.y));
        const index = registerCreatureSpawn(spawn);
        auto creature = world.makeCreature(&world.data.creatureSpawns[index]);
        if (creature is null)
            return null;
        creature.instanceId = map.instanceId;
        map.addObject(creature);
        return creature;
    }

    package size_t registerCreatureSpawn(const ref CreatureSpawn spawn)
    {
        const index = world.data.creatureSpawns.length;
        world.data.creatureSpawns ~= spawn;
        world.data.creatureCells.require(spawn.map, null).require(cellKeyAt(spawn.x, spawn.y), null) ~= index;
        world.spawnIndex[spawn.guid] = index;
        return index;
    }

    /// The creature's spawn deleted: gone from the map, the world data's cell and the database.
    bool deleteCreatureSpawn(Map map, Creature creature)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.grid : cellKeyAt;

        const s = creature.spawn;
        if (!world.canWrite())
            return false;
        world.indexSpawns();
        if (s.guid in world.spawnIndex && !eraseSavedSpawn(s.guid, false))
            return false;
        if (auto cells = s.map in world.data.creatureCells)
            if (auto list = cellKeyAt(s.x, s.y) in *cells)
                foreach (i, index; *list)
                    if (world.data.creatureSpawns[index].guid == s.guid)
                    {
                        *list = (*list).remove(i);
                        break;
                    }
        world.deadCreatures.respawnAt.remove(s.guid);
        world.spawnIndex.remove(s.guid);
        map.removeObject(creature.guid);
        return true;
    }

    /// A new `gameobject` row of `entry` at `at` (facing as it), and its object there now; null if unknown.
    GameObject spawnGameObjectAt(Map map, uint entry, Position at, bool save)
    {
        import std.math : cos, sin;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!world.canWrite() || entry !in world.data.gameObjectTemplates)
            return null;
        GameObjectSpawn spawn = {entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation, rotation: [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)]};
        if (save)
        {
            try
                spawn.guid = world.database.createGameObjectSpawn(spawn);
            catch (DatabaseException error)
            {
                warning!"could not save the new game object spawn %s: %s"(entry, error.msg);
                return null;
            }
            if (!spawn.guid)
                return null;
        }
        else
        {
            spawn.guid = world.nextTemporaryCounter();
            unsavedGameObjectSpawns[spawn.guid] = true;
        }
        map.loadCell(cellKeyAt(spawn.x, spawn.y));
        const index = registerGameObjectSpawn(spawn);
        auto go = world.makeGameObject(world.data.gameObjectSpawns[index]);
        go.instanceId = map.instanceId;
        if (go.type == GameObjectType.transport)
            world.fleet.refreshElevatorHomes(map);
        map.addObject(go);
        return go;
    }

    package size_t registerGameObjectSpawn(const ref GameObjectSpawn spawn)
    {
        const index = world.data.gameObjectSpawns.length;
        world.data.gameObjectSpawns ~= spawn;
        world.data.gameObjectCells.require(spawn.map, null).require(cellKeyAt(spawn.x, spawn.y), null) ~= index;
        world.gameObjectSpawnIndex[spawn.guid] = index;
        return index;
    }

    /**
     * The game object's spawn changed (moved, turned): its row and the world data rewritten, and the
     * object made anew from it, so that the clients see it there. Returns null if it could not save.
     */
    GameObject respawnGameObjectAs(Map map, GameObject go, GameObjectSpawn changed)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!world.canWrite())
            return null;
        const home = cellKeyAt(changed.x, changed.y);
        if (!map.instanceId && world.ownsCell !is null && !world.ownsCell(changed.map, home))
            return null;
        world.indexSpawns();
        const at = go.spawn.guid in world.gameObjectSpawnIndex;
        if (at is null)
            return null;
        if (changed.guid !in unsavedGameObjectSpawns)
            try
            {
                if (!world.database.updateGameObjectPlacement(changed))
                    return null;
            }
            catch (DatabaseException error)
            {
                warning!"could not save changes to game object %s: %s"(changed.guid, error.msg);
                return null;
            }
        if (home != cellKeyAt(go.spawn.x, go.spawn.y))
            map.loadCell(home);
        replaceGameObjectSpawn(*at, changed);
        map.removeObject(go.guid);
        auto made = world.makeGameObject(world.data.gameObjectSpawns[*at]);
        made.instanceId = map.instanceId;
        if (made.type == GameObjectType.transport)
            world.fleet.refreshElevatorHomes(map);
        map.addObject(made);
        return made;
    }

    /// Adjust a saved spawn and its cell index together, on a GM edit or at region arrival.
    package void replaceGameObjectSpawn(size_t at, const ref GameObjectSpawn changed)
    {
        import std.algorithm.mutation : remove;

        const old = world.data.gameObjectSpawns[at];
        const oldCell = cellKeyAt(old.x, old.y), newCell = cellKeyAt(changed.x, changed.y);
        if (old.map != changed.map || oldCell != newCell)
        {
            if (auto cells = old.map in world.data.gameObjectCells)
                if (auto list = oldCell in *cells)
                    foreach (i, index; *list)
                        if (index == at)
                        {
                            *list = (*list).remove(i);
                            break;
                        }
            world.data.gameObjectCells.require(changed.map, null).require(newCell, null) ~= at;
        }
        world.data.gameObjectSpawns[at] = changed;
    }

    /// The game object's spawn deleted: gone from the map, the world data's cell and the database.
    bool deleteGameObjectSpawn(Map map, GameObject go)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.grid : cellKeyAt;

        const s = go.spawn;
        if (!world.canWrite())
            return false;
        world.indexSpawns();
        if (s.guid in world.gameObjectSpawnIndex && s.guid !in unsavedGameObjectSpawns && !eraseSavedSpawn(s.guid, true))
            return false;
        if (auto cells = s.map in world.data.gameObjectCells)
            if (auto list = cellKeyAt(s.x, s.y) in *cells)
                foreach (i, index; *list)
                    if (world.data.gameObjectSpawns[index].guid == s.guid)
                    {
                        *list = (*list).remove(i);
                        break;
                    }
        world.gameObjectRespawnAt.remove(s.guid);
        world.gameObjectSpawnIndex.remove(s.guid);
        unsavedGameObjectSpawns.remove(s.guid);
        map.removeObject(go.guid);
        if (go.type == GameObjectType.transport)
            world.fleet.refreshElevatorHomes(map);
        return true;
    }

    package bool eraseSavedSpawn(uint guid, bool gameObject)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        try
            return world.database.eraseSavedSpawn(guid, gameObject);
        catch (DatabaseException error)
        {
            warning!"could not delete world spawn %s: %s"(guid, error.msg);
            return false;
        }
    }
}
