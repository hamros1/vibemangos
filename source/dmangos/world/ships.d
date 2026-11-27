/**
 * The ships, zeppelins and elevators this node runs: the ships at sea on their schedules
 * (`dmangos.world.transports`), the clock they keep, and each elevator's home and path (`WorldContext.fleet`).
 */
module dmangos.world.ships;

import dmangos.world.movement : Position;
import dmangos.world.objects : UpdateValues;
import dmangos.world.map : Map;
import dmangos.world.transports : ShipObject, mapAt, transportClock;
import dmangos.world.elevators : ElevatorPath;
import dmangos.world.character : Character;
import dmangos.world.worlddata : Ship;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class Ships
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    /// A ship sailing: its schedule, its object, and the map it is on now (`uint.max`: not placed yet).
    package struct ShipAtSea
    {
        const(Ship)* ship;
        ShipObject object;
        uint map = uint.max;
    }

    package ShipAtSea[] ships;

    /// The transport clock now: the wall clock's milliseconds, moving with `clock`.
    uint transportNow()
    {
        return transportClock(world.startUnixMillis + (world.clock() - world.startClock).total!"msecs");
    }

    package struct ElevatorAnimation
    {
        uint entry;
        float[4] rotation;
        ElevatorPath path;
    }

    package ElevatorAnimation[ulong] elevatorAnimations;

    package bool[ulong][uint] longElevatorHomes;

    /// Keep routes longer than a grid cell available while this map is active.
    package bool[ulong] elevatorHomesFor(uint mapId)
    {
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.grid : cellSize;

        if (auto homes = mapId in longElevatorHomes)
            return *homes;
        bool[ulong] homes;
        foreach (cell, indices; world.data.gameObjectCells.get(mapId, null))
            foreach (index; indices)
            {
                const spawn = &world.data.gameObjectSpawns[index];
                const proto = spawn.entry in world.data.gameObjectTemplates;
                if (proto is null || proto.type != GameObjectType.transport || proto.data[1] || spawn.respawnSeconds < 0)
                    continue;
                const path = ElevatorPath(world.client.transportFrames(spawn.entry), spawn.worldRotation);
                if (path.travelsAcross(cellSize))
                {
                    homes[cell] = true;
                    break;
                }
            }
        longElevatorHomes[mapId] = homes;
        return homes;
    }

    package void refreshElevatorHomes(Map map_)
    {
        longElevatorHomes.remove(map_.id);
        map_.elevatorHomes = elevatorHomesFor(map_.id);
    }

    package ElevatorPath elevatorPathOf(ulong guid, const ref UpdateValues fields)
    {
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.updatefields;

        if (fields.type != TypeId.gameObject || fields.get!GAMEOBJECT_TYPE_ID != GameObjectType.transport
            || fields.get!GAMEOBJECT_LEVEL != 0)
            return ElevatorPath.init;
        const entry = fields.get!OBJECT_FIELD_ENTRY;
        float[4] rotation;
        foreach (i, ref component; rotation)
            component = fields.get!GAMEOBJECT_ROTATION(i);
        auto animation = guid in elevatorAnimations;
        if (animation is null || animation.entry != entry || animation.rotation != rotation)
        {
            elevatorAnimations[guid] = ElevatorAnimation(entry, rotation, ElevatorPath(world.client.transportFrames(entry), rotation));
            animation = guid in elevatorAnimations;
        }
        return animation.path;
    }

    /// The current pose of a loaded elevator (local object or replica).
    package bool elevatorPose(Map map_, ulong guid, out Position at, out float maxSpeed)
    {
        import dmangos.world.updatefields;

        auto platform = map_.findObject(guid);
        if (platform is null)
            return false;
        const fields = &platform.fields();
        const path = elevatorPathOf(guid, *fields);
        if (!path.valid)
            return false;

        const stationary = Position(fields.get!GAMEOBJECT_POS_X, fields.get!GAMEOBJECT_POS_Y,
            fields.get!GAMEOBJECT_POS_Z, fields.get!GAMEOBJECT_FACING);
        at = path.positionAt(stationary, transportNow());
        maxSpeed = path.maxSpeed;
        return at.isFinite;
    }

    /**
     * Each tick: each ship is where its schedule says. One that came to another map leaves the old one (its
     * players forget it) for the new one (its players get it), and the players aboard cross with it.
     * Ships on dungeon maps are not sailed.
     */
    package void updateShips()
    {
        import dmangos.log : info;
        import dmangos.world.movement : MovementFlags, Position;

        if (ships.length == 0 && world.data.ships.length)
            foreach (ref ship; world.data.ships)
            {
                import std.algorithm.searching : canFind;

                if (world.config.disabledTransports.canFind(ship.entry))
                    continue; // left out by the configuration
                bool dungeon;
                foreach (ref k; ship.frames)
                    dungeon |= world.dungeons.instanceable(k.node.map);
                if (dungeon)
                    continue;
                const k = ship.frames[0];
                const t = ship.entry in world.data.gameObjectTemplates;
                ships ~= ShipAtSea(&ship, new ShipObject(t, ship.period,
                    Position(k.node.x, k.node.y, k.node.z, k.facing), &transportNow));
            }
        const clock = transportNow();
        foreach (ref s; ships)
        {
            size_t frame;
            const map = mapAt(s.ship.frames, clock % s.ship.period, frame);
            // Arriving at a crossing, it is at the next frame, on the next map.
            auto k = &s.ship.frames[frame];
            if (k.teleport)
                k = &s.ship.frames[(frame + 1) % s.ship.frames.length];
            const at = Position(k.node.x, k.node.y, k.node.z, k.facing);
            s.object.moveTo(at);
            if (map == s.map)
                continue;
            const from = s.map;
            s.map = map;
            Character[] aboard;
            if (from != uint.max)
                if (auto old = world.existingMap(from))
                {
                    foreach (who; old.playersNow())
                    {
                        const move = &who.character.movement;
                        if (move.has(MovementFlags.onTransport) && move.transportGuid == s.object.guid)
                            if (auto session = cast(Character) who)
                                aboard ~= session;
                    }
                    old.removeEverywhere(s.object.guid);
                }
            if (auto there = world.existingMap(map))
                there.addEverywhere(s.object);
            info!"%s sails to map %s (%s aboard)"(s.ship.name, map, aboard.length);
            foreach (session; aboard)
                session.rideShipAcross(map, at, s.object.guid, s.ship.entry);
        }
    }
}
