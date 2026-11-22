/// Line of sight through the loaded doors of one map copy.
module dmangos.world.gameobjectcollision;

import dmangos.vmap.gameobjectmodels : GameObjectModels, GameObjectShape;
import dmangos.vmap.math : AABox, Ray, Vector3;
import dmangos.world.gameobject : GameObjectType;
import dmangos.world.grid : cellCoordinate, cellKey;
import dmangos.world.movement : Position;
import dmangos.world.objects : UpdateValues;
import dmangos.world.updatefields;

/// Cells covered by the horizontal projection of a box.
private struct CoveredCells
{
    int left, right, bottom, top;

    this(const ref AABox box)
    {
        left = cellCoordinate(box.lo.x);
        right = cellCoordinate(box.hi.x);
        bottom = cellCoordinate(box.lo.y);
        top = cellCoordinate(box.hi.y);
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
    }

    private struct Collider
    {
        Placement placement;
        GameObjectShape shape;
    }

    private GameObjectModels models;
    private Collider[uint] doors;
    private bool[uint][ulong] cells; // world cell -> door slots with geometry here

    this(GameObjectModels models)
    {
        this.models = models;
    }

    void update(uint slot, const ref UpdateValues fields, Position at)
    {
        if (fields.type != TypeId.gameObject || fields.get!GAMEOBJECT_TYPE_ID != GameObjectType.door)
        {
            remove(slot);
            return;
        }
        Placement next;
        next.display = fields.get!GAMEOBJECT_DISPLAYID;
        next.position = Vector3(at.x, at.y, at.z);
        next.scale = fields.get!OBJECT_FIELD_SCALE_X;
        foreach (i, ref part; next.rotation)
            part = fields.get!GAMEOBJECT_ROTATION(i);
        if (const previous = slot in doors)
        {
            if (previous.placement == next)
                return;
            remove(slot);
        }
        auto shape = models.place(next.display, next.position, next.rotation, next.scale);
        if (!shape)
            return;
        doors[slot] = Collider(next, shape);
        foreach (key; CoveredCells(shape.bounds))
            cells.require(key, null)[slot] = true;
    }

    void remove(uint slot)
    {
        if (const door = slot in doors)
        {
            foreach (key; CoveredCells(door.shape.bounds))
                if (auto bucket = key in cells)
                {
                    (*bucket).remove(slot);
                    if (!bucket.length)
                        cells.remove(key);
                }
            doors.remove(slot);
        }
    }

    bool obstructs(Position from, Position to, scope bool delegate(uint slot) closed) const
    {
        import std.math : isFinite;

        if (!doors.length)
            return false;
        const a = Vector3(from.x, from.y, from.z), b = Vector3(to.x, to.y, to.z);
        const direction = b - a;
        const length = direction.magnitude();
        if (!isFinite(length) || length <= 0)
            return false;
        const ray = Ray(a, direction / length);
        const bounds = AABox(a.min(b), a.max(b));
        foreach (key; CoveredCells(bounds))
            if (const bucket = key in cells)
                foreach (slot, _; *bucket)
                    if (closed(slot) && doors[slot].shape.intersects(ray, length))
                        return true;
        return false;
    }
}

/// Door geometry follows state, transform, and replica lifetime through the map's normal plumbing.
unittest
{
    import std.conv : to;
    import std.file : mkdir, rmdirRecurse, tempDir, write;
    import std.math : PI;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import dmangos.bytes : ByteWriter;
    import dmangos.vmap.maptree : ModelCache;
    import dmangos.vmap.math : putBox;
    import dmangos.vmap.model : gameObjectModels, GroupModel, MeshTriangle, WorldModel;
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
    auto local = new Map(0, MapSettings.init, () => 0, models: models);
    auto remote = new Map(0, MapSettings.init, () => 0, models: models);
    auto otherCopy = new Map(0, MapSettings.init, () => 0, models: models);
    const template_ = GameObjectTemplate(entry: entry, type: GameObjectType.door, displayId: display, size: 2);
    const straightSpawn = GameObjectSpawn(guid: 1, entry: entry);
    const rotatedSpawn = GameObjectSpawn(guid: 2, entry: entry, orientation: PI / 2);
    auto door = new GameObject(straightSpawn, &template_);
    auto rotated = new GameObject(rotatedSpawn, &template_);
    const a = Position(68, 0, 0), b = Position(72, 0, 0);
    assert(local.inLineOfSight(a, b));
    local.addObject(door);
    assert(!local.inLineOfSight(a, b), "the mesh reaches the adjacent cell even though its origin is outside it");
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
}
