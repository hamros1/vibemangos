/// Line of sight through loaded doors and elevator platforms in one map copy.
module dmangos.world.gameobjectcollision;

import std.algorithm.comparison : clamp, max;
import std.math : isFinite;
import dmangos.vmap.gameobjectmodels : GameObjectModels, GameObjectShape;
import dmangos.vmap.math : AABox, Ray, Vector3;
import dmangos.world.clientdata : ClientData;
import dmangos.world.elevators : ElevatorPath;
import dmangos.world.gameobject : GameObjectType;
import dmangos.world.grid : cellCoordinate, cellKey, cellSize;
import dmangos.world.movement : Position;
import dmangos.world.objects : UpdateValues;
import dmangos.world.updatefields;

/// Cells covered by the horizontal projection of a box.
private struct CoveredCells
{
    // Large rectangles are cheaper to handle with a bounds check per loaded object.
    private enum long indexLimit = 64;
    int left, right, bottom, top;

    this(const ref AABox box)
    {
        // The whole playable map is 512 cells across. Clamp meshes that extend beyond it.
        enum float edge = 256 * cellSize;
        left = cellCoordinate(clamp(box.lo.x, -edge, edge));
        right = cellCoordinate(clamp(box.hi.x, -edge, edge));
        bottom = cellCoordinate(clamp(box.lo.y, -edge, edge));
        top = cellCoordinate(clamp(box.hi.y, -edge, edge));
    }

    @property bool fitsIndex() const
    {
        return (cast(long) right - left + 1) * (cast(long) top - bottom + 1) <= indexLimit;
    }

    ulong firstOverlap(const ref CoveredCells other) const
    {
        return cellKey(max(left, other.left), max(bottom, other.bottom));
    }

    int opApply(scope int delegate(ulong) visit) const
    {
        foreach (long x; left .. cast(long) right + 1)
            foreach (long y; bottom .. cast(long) top + 1)
                if (const status = visit(cellKey(cast(int) x, cast(int) y)))
                    return status;
        return 0;
    }
}

/// Meshes indexed by the cells they can intersect. The map owns each slot's current door state.
package final class GameObjectCollision
{
    private struct Placement
    {
        uint display;
        Vector3 position;
        float[4] rotation;
        float scale;
        uint elevatorEntry; // zero for a door
    }

    private struct Collider
    {
        Placement placement;
        GameObjectShape shape;
        ElevatorPath elevator;
        CoveredCells covered;
    }

    private GameObjectModels models;
    private ClientData client;
    private uint delegate() transportTime;
    private Collider[uint] colliders;
    private bool[uint][ulong] cells; // world cell -> slots with geometry here
    private bool[uint] largeColliders;

    this(GameObjectModels models, ClientData client, uint delegate() transportTime)
    {
        this.models = models;
        this.client = client;
        this.transportTime = transportTime;
    }

    void update(uint slot, const ref UpdateValues fields, Position at)
    {
        Placement next;
        if (fields.type == TypeId.gameObject && fields.get!GAMEOBJECT_TYPE_ID == GameObjectType.transport &&
            client !is null && transportTime !is null && fields.get!GAMEOBJECT_LEVEL == 0)
            next.elevatorEntry = fields.get!OBJECT_FIELD_ENTRY;
        if (!next.elevatorEntry &&
            (fields.type != TypeId.gameObject || fields.get!GAMEOBJECT_TYPE_ID != GameObjectType.door))
        {
            remove(slot);
            return;
        }
        next.display = fields.get!GAMEOBJECT_DISPLAYID;
        next.position = next.elevatorEntry ? Vector3(fields.get!GAMEOBJECT_POS_X,
            fields.get!GAMEOBJECT_POS_Y, fields.get!GAMEOBJECT_POS_Z) : Vector3(at.x, at.y, at.z);
        next.scale = fields.get!OBJECT_FIELD_SCALE_X;
        foreach (i, ref part; next.rotation)
            part = fields.get!GAMEOBJECT_ROTATION(i);
        if (const previous = slot in colliders)
        {
            if (previous.placement == next)
                return;
            remove(slot);
        }
        auto shape = models.place(next.display, next.position, next.rotation, next.scale);
        if (!shape)
            return;
        ElevatorPath elevator;
        auto bounds = shape.bounds;
        if (next.elevatorEntry)
        {
            elevator = ElevatorPath(client.transportFrames(next.elevatorEntry), next.rotation);
            if (!elevator.valid)
                return;
            bounds = elevator.sweptBounds(bounds);
        }
        foreach (axis; 0 .. 3)
            if (!bounds.lo[axis].isFinite || !bounds.hi[axis].isFinite)
                return;
        const covered = CoveredCells(bounds);
        colliders[slot] = Collider(next, shape, elevator, covered);
        if (covered.fitsIndex)
            foreach (key; covered)
                cells.require(key, null)[slot] = true;
        else
            largeColliders[slot] = true;
    }

    void remove(uint slot)
    {
        if (const collider = slot in colliders)
        {
            if (!largeColliders.remove(slot))
                foreach (key; collider.covered)
                    if (auto bucket = key in cells)
                    {
                        (*bucket).remove(slot);
                        if (!bucket.length)
                            cells.remove(key);
                    }
            colliders.remove(slot);
        }
    }

    bool obstructs(Position from, Position to, scope bool delegate(uint slot) closed) const
    {
        if (!colliders.length)
            return false;
        const a = Vector3(from.x, from.y, from.z), b = Vector3(to.x, to.y, to.z);
        const direction = b - a;
        const length = direction.magnitude();
        if (!isFinite(length) || length <= 0)
            return false;
        const ray = Ray(a, direction / length);
        const bounds = AABox(a.min(b), a.max(b));
        const clock = transportTime is null ? 0 : transportTime();
        bool blocks(uint slot, const ref Collider collider)
        {
            if (!collider.elevator.valid)
                return closed(slot) && collider.shape.intersects(ray, length);
            const offset = collider.elevator.offsetAt(clock);
            return collider.shape.intersects(Ray(a - offset, ray.direction), length);
        }

        const covered = CoveredCells(bounds);
        if (!covered.fitsIndex)
        {
            foreach (slot, ref collider; colliders)
                if (blocks(slot, collider))
                    return true;
            return false;
        }
        foreach (slot, _; largeColliders)
            if (blocks(slot, colliders[slot]))
                return true;
        foreach (key; covered)
            if (const bucket = key in cells)
                foreach (slot, _; *bucket)
                {
                    const collider = slot in colliders;
                    if (key == covered.firstOverlap(collider.covered) && blocks(slot, *collider))
                        return true;
                }
        return false;
    }
}

/// Door and elevator geometry follow the state and replica lifetime used by normal maps.
unittest
{
    import std.conv : to;
    import std.file : mkdir, rmdirRecurse, tempDir, write;
    import std.math : PI;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import dmangos.bytes : ByteWriter, floatBits;
    import dmangos.dbc : buildDbc;
    import dmangos.vmap.maptree : ModelCache;
    import dmangos.vmap.math : putBox;
    import dmangos.vmap.model : gameObjectModels, GroupModel, MeshTriangle, WorldModel;
    import dmangos.world.clientdata : transportAnimationFormat;
    import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.map : Map, MapSettings;
    import dmangos.world.replication : encodeSlots, encodeState;

    const directory = buildPath(tempDir, "dmangos-door-collision-" ~ thisProcessID.to!string);
    mkdir(directory);
    scope (exit)
        rmdirRecurse(directory);
    const bounds = AABox(Vector3(35, -1, 0), Vector3(35, 1, 2));
    auto group = new GroupModel(0, 1, bounds);
    group.setMeshData([Vector3(35, -1, 0), Vector3(35, 1, 0), Vector3(35, -1, 2), Vector3(35, 1, 2)],
        [MeshTriangle(0, 1, 2), MeshTriangle(1, 3, 2)]);
    auto model = new WorldModel;
    model.setGroups([group]);
    model.write(buildPath(directory, "panel.vmo"));
    enum uint display = 17, entry = 99;
    ByteWriter catalog;
    catalog.put(display);
    catalog.put(cast(uint) "panel".length);
    catalog.putBytes(cast(const(ubyte)[]) "panel");
    putBox(catalog, bounds);
    write(buildPath(directory, gameObjectModels), catalog.data);

    auto models = GameObjectModels.load(directory, new ModelCache(directory));
    assert(models !is null);
    enum uint elevatorEntry = entry + 1;
    auto client = new ClientData;
    // Deliberately out of order, with an animated return to the first position.
    client.transportAnimations = typeof(client.transportAnimations).parse(buildDbc(transportAnimationFormat,
        [[0, elevatorEntry, 1000, floatBits(130), floatBits(12), floatBits(8), 0],
         [1, elevatorEntry, 0, 0, 0, 0, 0],
         [2, elevatorEntry, 2000, 0, 0, 0, 0]]), "test elevator animation");
    client.buildIndexes();
    uint clock;
    auto local = new Map(0, MapSettings.init, () => 0,
        objectCollision: new GameObjectCollision(models, client, () => clock));
    auto remote = new Map(0, MapSettings.init, () => 0,
        objectCollision: new GameObjectCollision(models, client, () => clock));
    auto otherCopy = new Map(0, MapSettings.init, () => 0,
        objectCollision: new GameObjectCollision(models, client, () => clock));
    const template_ = GameObjectTemplate(entry: entry, type: GameObjectType.door, displayId: display, size: 2);
    const straightSpawn = GameObjectSpawn(guid: 1, entry: entry);
    const rotatedSpawn = GameObjectSpawn(guid: 2, entry: entry, orientation: PI / 2);
    auto door = new GameObject(straightSpawn, &template_);
    auto rotated = new GameObject(rotatedSpawn, &template_);
    const a = Position(68, 0, 0), b = Position(72, 0, 0);
    assert(local.inLineOfSight(a, b));
    local.addObject(door);
    assert(!local.inLineOfSight(a, b), "the mesh reaches the adjacent cell even though its origin is outside it");
    assert(!local.inLineOfSight(Position(-9000, 0, 0), Position(9000, 0, 0)),
        "a ray across many cells still sees a small indexed door");
    assert(local.lineOfSightBetween(Position(68, 0, 5), Position(72, 0, 5)), "over the mesh");
    assert(otherCopy.inLineOfSight(a, b), "another copy has its own doors");
    remote.replicaCreated(1, cellKeyAt(0, 0), door.guid, encodeState(door, 0));
    assert(!remote.inLineOfSight(a, b));

    door.setDoorOpen(true);
    assert(local.inLineOfSight(a, b), "opening affects collision immediately");
    remote.replicaValues(1, door.guid, encodeSlots(door.values.changedPublicSlots));
    assert(remote.inLineOfSight(a, b));
    door.setDoorOpen(false);
    remote.replicaValues(1, door.guid, encodeSlots(door.values.changedPublicSlots));
    assert(!remote.inLineOfSight(a, b), "the replicated close blocks sight again");
    remote.replicaRemoved(1, door.guid);
    local.removeObject(door.guid);
    assert(remote.inLineOfSight(a, b) && local.inLineOfSight(a, b));
    local.addObject(rotated);
    assert(local.inLineOfSight(a, b) && !local.inLineOfSight(Position(0, 68, 0), Position(0, 72, 0)),
        "rotation changes the occupied cells and the direction of the blocking mesh");
    local.removeObject(rotated.guid);

    const elevatorTemplate = GameObjectTemplate(entry: elevatorEntry, type: GameObjectType.transport,
        displayId: display, size: 2);
    const elevatorSpawn = GameObjectSpawn(guid: 3, entry: elevatorEntry);
    auto elevator = new GameObject(elevatorSpawn, &elevatorTemplate);
    local.addObject(elevator);
    remote.replicaCreated(1, cellKeyAt(0, 0), elevator.guid, encodeState(elevator, 0));
    assert(!local.inLineOfSight(a, b) && !remote.inLineOfSight(a, b));
    clock = 500;
    assert(local.inLineOfSight(a, b) && remote.inLineOfSight(a, b), "the platform has left the spawn position");
    const midwayA = Position(133, -6, 4), midwayB = Position(137, -6, 4);
    assert(!local.inLineOfSight(midwayA, midwayB) && !remote.inLineOfSight(midwayA, midwayB),
        "both maps use the platform between two keyframes in a different cell");
    assert(local.inLineOfSight(Position(133, -6, 0), Position(137, -6, 0)), "under the platform");
    clock = 1000;
    const endA = Position(198, -12, 8), endB = Position(202, -12, 8);
    assert(!remote.inLineOfSight(endA, endB) && local.inLineOfSight(midwayA, midwayB));
    clock = 2500;
    assert(!remote.inLineOfSight(midwayA, midwayB), "the collision position repeats on the shared clock");
    remote.replicaRemoved(1, elevator.guid);
    assert(remote.inLineOfSight(midwayA, midwayB));

    local.removeObject(elevator.guid);
    enum uint tramEntry = entry + 2;
    client.transportAnimations = typeof(client.transportAnimations).parse(buildDbc(transportAnimationFormat,
        [[0, tramEntry, 0, 0, 0, 0, 0],
         [1, tramEntry, 1000, floatBits(5000), floatBits(5000), 0, 0],
         [2, tramEntry, 2000, 0, 0, 0, 0]]), "test long platform animation");
    client.buildIndexes();
    const tramTemplate = GameObjectTemplate(entry: tramEntry, type: GameObjectType.transport,
        displayId: display, size: 2);
    const tramSpawn = GameObjectSpawn(guid: 4, entry: tramEntry);
    auto tram = new GameObject(tramSpawn, &tramTemplate);
    clock = 0;
    local.addObject(tram);
    assert(!local.inLineOfSight(a, b));
    clock = 1000;
    const farA = Position(5068, -5000, 0), farB = Position(5072, -5000, 0);
    assert(local.inLineOfSight(a, b) && !local.inLineOfSight(farA, farB),
        "a platform with a large swept rectangle still moves and blocks at the current offset");
    local.removeObject(tram.guid);
    assert(local.inLineOfSight(farA, farB));
}
