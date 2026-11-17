/**
 * How creatures move on their own (CMaNGOS `MotionGenerators/`): each creature has a movement
 * generator, chosen from its spawn's `MovementType` as `MotionMaster::Initialize` chooses it, that
 * starts walks along splines (`MoveSplineInit::Launch`) when it is time, and the creature follows its
 * spline as the map ticks (`Unit::UpdateSplineMovement`).
 *
 * - `IdleMovement` (type 0): stands.
 * - `WanderMovement` (type 1): walks to random points within `spawndist` of its spawn point, one to
 *   three walks in a row, then waits 3 to 10 seconds.
 * - `WaypointMovement` (type 2): walks its `creature_movement` path (or its entry's
 *   `creature_movement_template` path) round and round, waiting where a point says; type 4 walks it
 *   back and forth. Paths are sent a few points at a time, at least six seconds' worth. A script
 *   can pause it.
 * - `PointMovement`: a walk to one point a script asked for, then back to the movement before.
 *
 * A point's script (`ScriptId`) runs when the creature gets there. What is not here yet: AI being
 * told of arrivals, scripts pausing the path or changing it, formations,
 * and type 3 (a flying path, which here walks as type 2 does). Without movement maps, paths are
 * straight lines; a random point's height is taken from the terrain (`Unit::UpdateAllowedPositionZ`,
 * which CMaNGOS applies only with `PathFinder.NormalizeZ` and otherwise takes from its movement maps).
 */
module dmangos.world.motion;

import std.math : cos, isNaN, PI, sin;
import std.random : Random, uniform, uniform01;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.vmap.math : Vector3;
import dmangos.world.creature : Creature;
import dmangos.world.movement : MovementFlags, MoveType, Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.spline;

/// `MovementGeneratorType`, as far as the database uses it.
enum MotionType : uint
{
    idle = 0,
    random = 1,
    waypoint = 2,
    path = 3,
    linearWaypoint = 4,
    point = 8,
}

/// `WaypointNode`: a point of a path.
struct WaypointNode
{
    uint point;         /// its number in the path, from 1
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = float.nan; /// where to face when waiting there; NaN: no facing (100 in the table)
    uint delay;         /// milliseconds to wait there
    uint scriptId;      /// `dbscripts_on_creature_movement`, run when it gets there
}

/// `WaypointManager`: the paths of `creature_movement` (by spawn) and `creature_movement_template`.
final class WaypointStore
{
    private
    {
        WaypointNode[][uint] bySpawn;    // spawn guid -> path, by point
        WaypointNode[][uint] byEntry;    // entry << 8 | path id -> path
    }

    /// Adds a `creature_movement` point; `finish` sorts them.
    void addSpawnNode(uint guid, WaypointNode node)
    {
        bySpawn[guid] ~= node;
    }

    /// Adds a `creature_movement_template` point.
    void addEntryNode(uint entry, uint pathId, WaypointNode node)
    {
        byEntry[entry << 8 | pathId] ~= node;
    }

    /// Puts each path in point order, and drops those with a point 0 (as `WaypointManager::Load`).
    void finish()
    {
        import std.algorithm.searching : canFind;
        import std.algorithm.sorting : sort;

        foreach (paths; [&bySpawn, &byEntry])
        {
            uint[] broken;
            foreach (key, ref path; *paths)
            {
                path.sort!((a, b) => a.point < b.point);
                if (path.canFind!(n => n.point == 0))
                    broken ~= key;
            }
            foreach (key; broken)
                (*paths).remove(key);
        }
    }

    /// `GetDefaultPath`: the spawn's own path, or else its entry's path 0; null if neither.
    const(WaypointNode)[] defaultPath(uint entry, uint guid) const
    {
        if (auto path = guid in bySpawn)
            return *path;
        return byEntry.get(entry << 8, null);
    }

    /// Number of paths.
    @property size_t length() const
    {
        return bySpawn.length + byEntry.length;
    }
}

/// What movement needs from the map the creature is on.
interface MotionWorld
{
    /// `Map::GetHeight`: the ground below or near `z`; `invalidHeightValue` and below if none.
    float groundHeight(float x, float y, float z, bool swim);

    /// `TerrainInfo::GetWaterOrGroundLevel`: how high a swimmer may be above `groundZ`.
    float waterOrGroundLevel(float x, float y, float z, float groundZ, float minWaterDeep);

    /// Sends a packet to the players whose clients have the object `guid`.
    void sendToObservers(ulong guid, Opcode opcode, const(ubyte)[] body_);

    /// The map's random numbers.
    ref Random random();

    /// `ScriptsStart(SCRIPT_TYPE_CREATURE_MOVEMENT)`: a waypoint's script, the creature its source and target.
    void waypointScript(Creature creature, uint scriptId);
}

/// `MovementGenerator`: see the module documentation.
abstract class MovementGenerator
{
    /// The type, as the database and `.npc info` know it.
    @property MotionType type() const;

    /// `Initialize`: starts, on the creature's first tick on the map.
    void initialize(Creature creature, MotionWorld world)
    {
    }

    /// `Update`: `diff` milliseconds on.
    void update(Creature creature, MotionWorld world, int diff)
    {
    }

    /**
     * For how many milliseconds `update` would do nothing but count down (docs/DESIGN.md, step 4: the
     * map lets the creature sleep that long); 0 if it must be updated every tick.
     */
    int idleFor(const Creature creature) const
    {
        return 0;
    }

    /// Writes what changes as it runs, for the creature's next owner (docs/CLUSTER.md, phase 4).
    void save(ref ByteWriter w) const
    {
    }

    /// Reads what `save` wrote, into a generator of the same type made for the same spawn.
    void load(ref ByteReader r)
    {
    }
}

/// `IdleMovementGenerator`
final class IdleMovement : MovementGenerator
{
    override @property MotionType type() const
    {
        return MotionType.idle;
    }

    override int idleFor(const Creature creature) const
    {
        return int.max;
    }
}

/// `WanderMovementGenerator`
final class WanderMovement : MovementGenerator
{
    enum delayMin = 3000, delayMax = 10_000, movesMax = 3;

    private
    {
        Vector3 centre;
        float radius;
        bool randomRun;    // CREATURE_EXTRA_FLAG_RUN_DURING_WANDER
        int nextMoveTimer;
        uint nextMoveCount = 1;
    }

    /// Around `centre`, at most `radius` yards from it.
    this(Vector3 centre, float radius, bool randomRun)
    {
        this.centre = centre;
        this.radius = radius;
        this.randomRun = randomRun;
    }

    override @property MotionType type() const
    {
        return MotionType.random;
    }

    override void initialize(Creature creature, MotionWorld world)
    {
        if (!creature.spline.finalized)
            interruptMoving(creature, world);
    }

    override void save(ref ByteWriter w) const
    {
        w.put(nextMoveTimer);
        w.put(nextMoveCount);
    }

    override void load(ref ByteReader r)
    {
        nextMoveTimer = r.read!int;
        nextMoveCount = r.read!uint;
    }

    /// Standing between walks: until the next.
    override int idleFor(const Creature creature) const
    {
        return creature.spline.finalized && nextMoveTimer > 0 ? nextMoveTimer : 0;
    }

    override void update(Creature creature, MotionWorld world, int diff)
    {
        if (!creature.spline.finalized)
            return;
        nextMoveTimer -= diff;
        if (nextMoveTimer > 0)
            return;
        if (!setLocation(creature, world))
            nextMoveTimer = 500;
        else if (nextMoveCount > 1)
            --nextMoveCount;
        else
        {
            nextMoveCount = uniform!"[]"(1, movesMax, world.random);
            nextMoveTimer = uniform!"[]"(delayMin, delayMax, world.random);
        }
    }

private:
    /// `_setLocation` with `PathFinder::ComputePathToRandomPoint`, without movement maps: a straight walk.
    bool setLocation(Creature creature, MotionWorld world)
    {
        const angle = uniform01!float(world.random) * 2 * cast(float) PI;
        const range = uniform01!float(world.random) * radius;
        auto end = Vector3(centre.x + range * cos(angle), centre.y + range * sin(angle), centre.z);
        const at = creature.position;
        const start = Vector3(at.x, at.y, at.z);
        const offset = start - end;
        if (offset.dot(offset) < 0.01f)
            return false;
        allowedPositionZ(creature, world, end);
        const walk = randomRun ? uniform!"[]"(0, 99, world.random) >= 15 : true;
        return launch(creature, world, [start, end], walk) != 0;
    }
}

/// `WaypointMovementGenerator<Creature>` and, back and forth, `LinearWPMovementGenerator`.
final class WaypointMovement : MovementGenerator
{
    /// A path is sent with the points after the next until it is this long (milliseconds).
    enum minimumPathTime = 6000;
    /// A path through points without a wait is sent again this long before its end.
    enum preSendTime = 1500;

    private
    {
        WaypointNode[] path;
        bool linear;
        bool drivingBack;   // `m_driveWayBack`
        size_t current;     // `m_currentWaypointNode`
        uint currentPoint;  // `i_currentNode`
        uint lastReached;   // `m_lastReachedWaypoint`; 0 for none
        int nextMoveTime;   // `i_nextMoveTime`: waiting while above 0
        int pathDuration;
        size_t[] nodeIndexes; // spline points that are path points, to arrive at on the way
    }

    bool paused; /// `SCRIPT_COMMAND_PAUSE_WAYPOINTS`: stands where it is until resumed

    /// `LoadPath`: a lone point without a wait waits five seconds.
    this(const(WaypointNode)[] path, bool linear)
    {
        this.path = path.dup;
        this.linear = linear;
        if (this.path.length == 1 && this.path[0].delay == 0)
            this.path[0].delay = 5000;
        if (this.path.length)
            currentPoint = this.path[0].point;
    }

    override @property MotionType type() const
    {
        return linear ? MotionType.linearWaypoint : MotionType.waypoint;
    }

    override void save(ref ByteWriter w) const
    {
        w.put(drivingBack);
        w.put(cast(uint) current);
        w.put(currentPoint);
        w.put(lastReached);
        w.put(nextMoveTime);
        w.put(pathDuration);
        w.put(cast(ushort) nodeIndexes.length);
        foreach (i; nodeIndexes)
            w.put(cast(uint) i);
    }

    override void load(ref ByteReader r)
    {
        drivingBack = r.read!bool;
        current = r.read!uint;
        currentPoint = r.read!uint;
        lastReached = r.read!uint;
        nextMoveTime = r.read!int;
        pathDuration = r.read!int;
        nodeIndexes = new size_t[r.read!ushort];
        foreach (ref i; nodeIndexes)
            i = r.read!uint;
        if (current >= path.length) // the path changed under it: start it over
            current = 0;
    }

    /// `InitializeWaypointPath`: off to the first point at once.
    override void initialize(Creature creature, MotionWorld world)
    {
        if (path.length)
            sendNextPath(creature, world);
    }

    /// Waiting at a point (or paused, or without a path): until it goes on.
    override int idleFor(const Creature creature) const
    {
        if (path.length == 0 || (paused && creature.spline.finalized))
            return int.max;
        return nextMoveTime > 0 && creature.spline.finalized ? nextMoveTime : 0;
    }

    override void update(Creature creature, MotionWorld world, int diff)
    {
        if (path.length == 0)
            return;
        if (paused)
        {
            if (!creature.spline.finalized)
            {
                interruptMoving(creature, world);
                nextMoveTime = 1; // goes on to its point when resumed
            }
            return;
        }
        if (nextMoveTime > 0)
        {
            if (!creature.spline.finalized)
                stopMoving(creature, world);
            nextMoveTime -= diff;
            if (nextMoveTime <= 0)
                sendNextPath(creature, world);
            return;
        }
        if (creature.spline.finalized)
        {
            arrived(creature, world);
            if (nextMoveTime <= 0)
                sendNextPath(creature, world);
            return;
        }
        if (pathDuration <= 0)
        {
            if (path[current].delay == 0)
                sendNextPath(creature, world);
        }
        else
            pathDuration -= diff;
        if (nodeIndexes.length && creature.spline.currentPathIndex >= nodeIndexes[0])
        {
            nodeIndexes = nodeIndexes[1 .. $];
            arrived(creature, world);
        }
    }

private:
    /// `OnArrived`: at the current point; on to the next, waiting first if the point says so.
    void arrived(Creature creature, MotionWorld world)
    {
        if (lastReached == currentPoint)
            return;
        lastReached = path[current].point;
        const wait = path[current].delay;
        if (path[current].scriptId)
            world.waypointScript(creature, path[current].scriptId);
        switchToNextNode();
        if (wait > 0)
            nextMoveTime = wait;
        currentPoint = path[current].point;
    }

    /// `SwitchToNextNode`
    void switchToNextNode()
    {
        if (!linear)
            current = (current + 1) % path.length;
        else if (path.length > 1)
        {
            if (!drivingBack && current + 1 == path.length)
                drivingBack = true;
            else if (drivingBack && current == 0)
                drivingBack = false;
            current = drivingBack ? current - 1 : current + 1;
        }
    }

    /// `GetNodeAfter`: the point after `node` along the way; false where a linear path turns.
    bool nodeAfter(ref size_t node, bool looped) const
    {
        if (!linear)
        {
            node = (node + 1) % path.length;
            return true;
        }
        const outwards = looped ? drivingBack : !drivingBack;
        if (outwards ? node + 1 == path.length : node == 0)
            return false;
        node = outwards ? node + 1 : node - 1;
        return true;
    }

    /**
     * `SendNextWayPointPath`: a walk to the current point, and on through the points after it
     * without a wait until the walk lasts `minimumPathTime`; facing as the last point says.
     */
    void sendNextPath(Creature creature, MotionWorld world)
    {
        nodeIndexes = null;
        const speed = creature.speeds[creature.movement.has(MovementFlags.walkMode) ? MoveType.walk : MoveType.run];
        const at = creature.spline.finalized ? creature.position : creature.spline.position;
        Vector3[] points = [Vector3(at.x, at.y, at.z)];

        // BuildIntPath: a straight line to the point; its time, from the point before.
        uint travel(const ref WaypointNode node)
        {
            const end = Vector3(node.x, node.y, node.z);
            const time = cast(uint)((end - points[$ - 1]).magnitude() / speed * 1000);
            points ~= end;
            return time;
        }

        const(WaypointNode)* next = &path[current];
        uint travelTime = travel(*next);
        bool looped;
        size_t node = current;
        while (next.delay == 0 && travelTime < minimumPathTime)
        {
            size_t after = node;
            if (!nodeAfter(after, looped))
            {
                if (looped)
                    break;
                looped = true;
                if (!nodeAfter(after, true))
                    break;
            }
            nodeIndexes ~= points.length - 1;
            travelTime += travel(path[after]);
            node = after;
            next = &path[after];
        }

        const facing = !isNaN(next.orientation) && next.delay != 0 ? next.orientation : float.nan;
        pathDuration = launch(creature, world, points, true, facing);
        if (next.delay == 0)
            pathDuration -= preSendTime;
        if (path.length == 1)
            lastReached = 0;
    }
}

/**
 * `PointMovementGenerator` (`MotionMaster::MovePoint`): a walk (or run) to one point, facing there as
 * told; then the movement it had before goes on, and `onArrived` is told.
 */
final class PointMovement : MovementGenerator
{
    private Vector3 destination;
    private float facing;
    private bool walk;
    package MovementGenerator after; // what it goes back to
    private bool launched;
    void delegate(Creature creature) onArrived; /// told once there

    ///
    this(Vector3 destination, float facing, bool walk, MovementGenerator after)
    {
        this.destination = destination;
        this.facing = facing;
        this.walk = walk;
        this.after = after;
    }

    override @property MotionType type() const
    {
        return MotionType.point;
    }

    override void initialize(Creature creature, MotionWorld world)
    {
        const at = creature.spline.finalized ? creature.position : creature.spline.position;
        launch(creature, world, [Vector3(at.x, at.y, at.z), destination], walk, facing);
        launched = true;
    }

    override void update(Creature creature, MotionWorld world, int diff)
    {
        if (!launched)
            return initialize(creature, world);
        if (!creature.spline.finalized)
            return;
        // There: back to what it did before (from where it stands now).
        creature.generator = after is null ? new IdleMovement : after;
        creature.generator.initialize(creature, world);
        if (onArrived !is null)
            onArrived(creature);
    }
}

/**
 * `FactorySelector::selectMovementGenerator` with `MotionMaster::Initialize`: the generator for the
 * spawn's movement type. A waypoint creature without a path stands.
 */
MovementGenerator selectMovement(const Creature creature, const WaypointStore waypoints)
{
    enum uint runDuringWander = 0x20; // CREATURE_EXTRA_FLAG_RUN_DURING_WANDER
    const spawn = creature.spawn;
    switch (spawn.movementType)
    {
    case MotionType.random:
        return new WanderMovement(Vector3(spawn.x, spawn.y, spawn.z), spawn.wanderDistance,
            (creature.template_.extraFlags & runDuringWander) != 0);
    case MotionType.waypoint, MotionType.path, MotionType.linearWaypoint:
        const path = waypoints is null ? null : waypoints.defaultPath(spawn.entry, spawn.guid);
        if (path.length == 0)
            return new IdleMovement;
        return new WaypointMovement(path, spawn.movementType == MotionType.linearWaypoint);
    default:
        return new IdleMovement;
    }
}

/// The next spline id (`splineCounter`): one counter for every unit on the server.
private uint splineCounter = 1;

/**
 * `MoveSplineInit::Launch`: starts a walk (or run) along `points` from where the creature is, tells
 * the clients, and returns its duration in milliseconds. `facing` (radians, unless NaN) is where it
 * looks at the end.
 */
int launch(Creature creature, MotionWorld world, Vector3[] points, bool walk, float facing = float.nan)
in (points.length > 1)
{
    const at = creature.spline.finalized ? creature.position : creature.spline.position;
    points[0] = Vector3(at.x, at.y, at.z);

    uint flags = walk ? SplineFlags.none : SplineFlags.runMode;
    float angle = 0;
    if (!isNaN(facing))
    {
        flags |= SplineFlags.finalAngle;
        angle = wrapAngle(facing);
    }
    auto move = &creature.movement;
    if (walk)
        move.flags |= MovementFlags.walkMode;
    else
        move.flags &= ~MovementFlags.walkMode;
    move.flags |= MovementFlags.splineEnabled | MovementFlags.forward;

    const velocity = creature.speeds[walk ? MoveType.walk : MoveType.run];
    if (!(velocity > 0))
        return 0;
    creature.spline = MoveSpline(points, flags, velocity, splineCounter++, angle);
    creature.positionTimer = 0;
    world.sendToObservers(creature.guid, Opcode.SMSG_MONSTER_MOVE, monsterMove(creature.guid, creature.spline));
    return creature.spline.duration;
}

/// `Unit::StopMoving` with `MoveSplineInit::Stop`: stands where it is, and tells the clients.
void stopMoving(Creature creature, MotionWorld world)
{
    if (creature.spline.finalized)
        return;
    creature.movement.position = creature.spline.position;
    creature.spline = MoveSpline.stopped(splineCounter++);
    creature.movement.flags &= ~(MovementFlags.forward | MovementFlags.splineEnabled);
    world.sendToObservers(creature.guid, Opcode.SMSG_MONSTER_MOVE,
        monsterStop(creature.guid, creature.position, creature.spline.id));
}

/// `Unit::InterruptMoving`: stops a walk at the point reached.
void interruptMoving(Creature creature, MotionWorld world)
{
    if (creature.spline.finalized)
        return;
    creature.movement.position = creature.spline.position;
    stopMoving(creature, world);
}

/**
 * `Unit::UpdateSplineMovement`: `diff` milliseconds along the walk. The creature's position follows
 * every 400 ms, and when it arrives.
 */
void followSpline(Creature creature, int diff)
{
    enum positionUpdateDelay = 400;
    if (creature.spline.finalized)
        return;
    creature.spline.update(diff);
    const arrived = creature.spline.finalized;
    if (arrived)
        creature.movement.flags &= ~(MovementFlags.forward | MovementFlags.splineEnabled);
    creature.positionTimer -= diff;
    if (creature.positionTimer > 0 && !arrived)
        return;
    creature.positionTimer = positionUpdateDelay;

    // UpdateSplinePosition: facing along the way, or the final facing.
    auto next = creature.spline.position;
    const was = creature.position;
    if (!(creature.spline.flags & SplineFlags.finalAngle))
    {
        import std.math : atan2;

        if (next.x == was.x && next.y == was.y)
            next.orientation = was.orientation;
        else
        {
            const angle = atan2(next.y - was.y, next.x - was.x);
            next.orientation = angle >= 0 ? angle : 2 * cast(float) PI + angle;
        }
    }
    creature.movement.position = next;
}

/// `Unit::UpdateAllowedPositionZ` for a creature: on the ground, or between it and the water's surface.
void allowedPositionZ(const Creature creature, MotionWorld world, ref Vector3 p)
{
    import dmangos.world.terrain : invalidHeight;

    enum uint inhabitWater = 2, inhabitAir = 4;
    const inhabit = creature.template_.inhabitType;
    if (inhabit & inhabitAir)
    {
        const ground = world.groundHeight(p.x, p.y, p.z, false);
        if (p.z < ground)
            p.z = ground;
        return;
    }
    const canSwim = (inhabit & inhabitWater) != 0;
    const ground = world.groundHeight(p.x, p.y, p.z, canSwim);
    const top = canSwim ? world.waterOrGroundLevel(p.x, p.y, p.z, ground, creature.collisionHeight) : ground;
    if (top > invalidHeight)
    {
        if (p.z > top)
            p.z = top;
        else if (p.z < ground)
            p.z = ground;
    }
}

version (unittest)
{
    import dmangos.world.creature : CreatureParts, CreatureSpawn, CreatureTemplate;

    /// Flat ground at `ground`; records what is sent.
    private final class TestWorld : MotionWorld
    {
        float ground = 0;
        Random rng = Random(7);
        Opcode[] sent;
        const(ubyte)[][] bodies;

        float groundHeight(float, float, float, bool) { return ground; }
        float waterOrGroundLevel(float, float, float, float groundZ, float) { return groundZ; }
        void sendToObservers(ulong, Opcode opcode, const(ubyte)[] body_) { sent ~= opcode; bodies ~= body_; }
        ref Random random() { return rng; }
        uint[] scripts;
        void waypointScript(Creature, uint scriptId) { scripts ~= scriptId; }
    }

    private Creature testCreature(CreatureSpawn spawn, uint extraFlags = 0)
    {
        import dmangos.world.testdata : testClientData;

        auto t = new CreatureTemplate;
        t.entry = spawn.entry;
        t.minLevel = t.maxLevel = 1;
        t.modelId1 = 1;
        t.inhabitType = 1;
        t.extraFlags = extraFlags;
        CreatureParts parts;
        return new Creature(spawn, t, 1, 1, parts, testClientData());
    }

    private bool near(float a, float b) { return (a > b ? a - b : b - a) < 0.01f; }

    /// `ms` milliseconds of map ticks, 100 ms each, as the world updates.
    private void run(Creature creature, MotionWorld world, int ms)
    {
        for (; ms > 0; ms -= 100)
            creature.tick(world, ms < 100 ? ms : 100);
    }
}

/// Wandering: walks within its distance, on the ground, then waits.
unittest
{
    auto world = new TestWorld;
    world.ground = 3;
    auto spawn = CreatureSpawn(1, 100, 0, 50, 50, 5, 0);
    spawn.wanderDistance = 10;
    spawn.movementType = MotionType.random;
    auto creature = testCreature(spawn);
    creature.generator = selectMovement(creature, null);
    assert(creature.generator.type == MotionType.random && creature.movement.has(MovementFlags.walkMode));

    creature.tick(world, 0);
    assert(world.sent == [Opcode.SMSG_MONSTER_MOVE], "the first walk starts at once");
    assert(creature.movement.has(MovementFlags.splineEnabled) && creature.movement.has(MovementFlags.forward));
    const end = creature.spline.finalDestination;
    assert((end.x - 50) ^^ 2 + (end.y - 50) ^^ 2 <= 100.01f && end.z == 3, "within 10 yards, on the ground");
    assert(creature.appearance(0).blockCount == 1);

    // Following the walk: the position moves on, and is the destination at the end.
    const duration = creature.spline.duration;
    creature.tick(world, duration / 2);
    assert(creature.position != Position(50, 50, 5, 0) && !creature.spline.finalized);
    creature.tick(world, duration);
    assert(creature.spline.finalized && !creature.movement.has(MovementFlags.splineEnabled));
    assert(near(creature.position.x, end.x) && near(creature.position.y, end.y) && creature.position.z == 3);

    // Then up to two more walks, each as the last ends, and a wait of at least 3 seconds.
    world.sent = null;
    foreach (_; 0 .. 2)
    {
        creature.tick(world, 1);
        if (creature.spline.finalized)
            break;
        creature.tick(world, creature.spline.duration);
    }
    world.sent = null;
    creature.tick(world, 2900);
    assert(world.sent.length == 0);
}

/// Waypoints: several points in one walk, waits and facings, round and round.
unittest
{
    auto world = new TestWorld;
    auto spawn = CreatureSpawn(2, 101, 0, 0, 0, 0, 0);
    spawn.movementType = MotionType.waypoint;
    auto creature = testCreature(spawn);
    auto store = new WaypointStore;
    store.addSpawnNode(2, WaypointNode(3, 0, 10, 0));
    store.addSpawnNode(2, WaypointNode(1, 10, 0, 0));
    store.addSpawnNode(2, WaypointNode(2, 10, 10, 0, 1.0f, 2000, 77));
    store.addEntryNode(102, 0, WaypointNode(0, 1, 1, 1));
    store.finish();
    assert(store.length == 1, "a path with a point 0 is dropped");
    assert(store.defaultPath(101, 2).length == 3 && store.defaultPath(101, 3) is null);
    creature.generator = selectMovement(creature, store);
    assert(creature.generator.type == MotionType.waypoint);

    // Points 1 and 2 in one walk (4 s to point 1 is under 6 s), facing as point 2 says.
    creature.tick(world, 0);
    assert(world.sent == [Opcode.SMSG_MONSTER_MOVE]);
    assert(creature.spline.path.length == 4 && creature.spline.finalDestination == Vector3(10, 10, 0));
    assert(creature.spline.flags & SplineFlags.finalAngle);

    run(creature, world, creature.spline.duration);
    assert(creature.spline.finalized && creature.position == Position(10, 10, 0, 1.0f), "there, facing");
    assert(world.scripts == [77], "point 2's script, once there");
    world.sent = null;
    run(creature, world, 1000);
    assert(world.sent.length == 0, "waiting two seconds");
    run(creature, world, 1000);
    assert(world.sent == [Opcode.SMSG_MONSTER_MOVE]);
    // On to point 3 and round to point 1: 10 + 14.1 yards, 9.7 s, so sent again 1.5 s before its end.
    assert(creature.spline.finalDestination == Vector3(10, 0, 0) && creature.spline.path.length == 4);
    assert(!(creature.spline.flags & SplineFlags.finalAngle));
    world.sent = null;
    assert(creature.spline.duration == 9657);
    run(creature, world, 8100);
    assert(world.sent.length == 0);
    run(creature, world, 200); // 8.16 s, and the tick that sees it
    assert(world.sent == [Opcode.SMSG_MONSTER_MOVE], "the next walk starts before this one ends");
    assert(creature.spline.finalDestination == Vector3(10, 10, 0));

    // A spawn without a path stands.
    spawn.guid = 3;
    auto lost = testCreature(spawn);
    assert(selectMovement(lost, store).type == MotionType.idle);
}

/// Back and forth: the points in order, then back.
unittest
{
    auto path = [WaypointNode(1, 0, 0, 0), WaypointNode(2, 5, 0, 0), WaypointNode(3, 10, 0, 0)];
    auto linear = new WaypointMovement(path, true);
    size_t[] visited;
    foreach (_; 0 .. 6)
    {
        linear.switchToNextNode();
        visited ~= linear.current;
    }
    assert(visited == [1, 2, 1, 0, 1, 2]);
    size_t node = 2;
    assert(!linear.nodeAfter(node, false) && linear.nodeAfter(node, true) && node == 1);

    auto lone = new WaypointMovement(path[0 .. 1], false);
    assert(lone.path[0].delay == 5000, "a lone point without a wait waits five seconds");
}

/// Stopping: where the walk got to, told to the clients.
unittest
{
    auto world = new TestWorld;
    auto creature = testCreature(CreatureSpawn(4, 103, 0, 0, 0, 0, 0));
    assert(launch(creature, world, [Vector3(), Vector3(25, 0, 0)], false) == 3572, "running at 7 yards a second");
    assert(!creature.movement.has(MovementFlags.walkMode));
    creature.tick(world, 1000);
    interruptMoving(creature, world);
    assert(creature.spline.finalized && near(creature.position.x, 7.0f));
    assert(world.sent == [Opcode.SMSG_MONSTER_MOVE, Opcode.SMSG_MONSTER_MOVE] && world.bodies[1][$ - 1] == 1);
    stopMoving(creature, world);
    assert(world.sent.length == 2, "already stopped");
}

/// Migration (phase 4): a creature's state, saved and loaded into one made anew, goes on exactly the same.
unittest
{
    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.world.updatefields;

    auto spawn = CreatureSpawn(5, 104, 0, 0, 0, 0, 0);
    spawn.movementType = MotionType.waypoint;
    auto store = new WaypointStore;
    store.addSpawnNode(5, WaypointNode(1, 20, 0, 0));
    store.addSpawnNode(5, WaypointNode(2, 20, 20, 0, 1.0f, 3000));
    store.addSpawnNode(5, WaypointNode(3, 0, 20, 0));
    store.finish();

    auto original = testCreature(spawn);
    original.generator = selectMovement(original, store);
    auto worldA = new TestWorld;
    run(original, worldA, 5000);
    original.values.set!UNIT_FIELD_HEALTH(17u);
    original.values.clearChanges();

    ByteWriter w;
    original.saveState(w);
    auto copy = testCreature(spawn);
    copy.generator = selectMovement(copy, store);
    auto r = ByteReader(w.data);
    copy.loadState(r);
    assert(r.empty);
    assert(copy.position == original.position && copy.values[UNIT_FIELD_HEALTH] == 17);
    assert(copy.spline.path == original.spline.path && copy.spline.timePassed == original.spline.timePassed);

    // From here on both walk the same, send the same, and wait at the same point.
    auto worldB = new TestWorld;
    worldA.sent = null;
    foreach (_; 0 .. 300)
    {
        original.tick(worldA, 100);
        copy.tick(worldB, 100);
        assert(copy.position == original.position);
    }
    assert(worldA.sent == worldB.sent && worldA.sent.length > 0);
}
