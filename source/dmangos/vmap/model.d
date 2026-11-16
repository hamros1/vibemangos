/**
 * Models in the vmap files (CMaNGOS `vmap/WorldModel.h`, `WorldModel.cpp`, `ModelInstance.h`,
 * `ModelInstance.cpp`, `VMapDefinitions.h`): a `WorldModel` is one building (a WMO, in groups)
 * or one doodad (an M2, one group) in its own coordinates, with a tree over its groups and each
 * group a tree over its triangles. A `ModelSpawn` places a model on a map.
 *
 * The `.vmo` layout, written and read here as CMaNGOS does: the magic, "WMOD" with the root WMO
 * id, then "GMOD" with the groups (bound, flags, WMO group id, "VERT", "TRIM", "MBIH" and "LIQU"
 * for each) and "GBIH" with the group tree.
 */
module dmangos.vmap.model;

import std.exception : enforce;
static import std.file;
import std.math : abs;
import std.typecons : Rebindable;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.vmap.bih;
import dmangos.vmap.math;

/// `VMAP_MAGIC`: the final vmap files.
enum string vmapMagic = "VMAP_7.0";
/// `RAW_VMAP_MAGIC`: the extractor's raw model files, null-terminated to 8 bytes.
enum string rawVmapMagic = "VMAPs05\0";
/// `GAMEOBJECT_MODELS`: the list of game object models.
enum string gameObjectModels = "temp_gameobject_models";
/// `LIQUID_TILE_SIZE`
enum float liquidTileSize = 533.333f / 128.0f;

/// `ModelFlags`
enum : uint
{
    modM2 = 1,              /// a doodad, not a building
    modWorldSpawn = 1 << 1, /// placed by the map's WDT, not a tile
    modHasBound = 1 << 2,   /// the spawn carries its bound
}

/// A triangle's three vertex indexes.
struct MeshTriangle
{
    uint idx0, idx1, idx2;
}

/// `WmoLiquid`: water in a building, a grid of heights over tiles of `liquidTileSize`.
final class WmoLiquid
{
    uint tilesX, tilesY;
    Vector3 corner;     /// the low corner
    uint type;
    float[] heights;    /// (tilesX + 1) x (tilesY + 1)
    ubyte[] flags;      /// tilesX x tilesY; low four bits 0xF: no liquid on the tile

    ///
    this(uint tilesX, uint tilesY, Vector3 corner, uint type)
    {
        this.tilesX = tilesX;
        this.tilesY = tilesY;
        this.corner = corner;
        this.type = type;
        heights = new float[(tilesX + 1) * (tilesY + 1)];
        flags = new ubyte[tilesX * tilesY];
    }

    /// `WmoLiquid::GetLiquidHeight`: the level at `pos` (model coordinates), on one of each tile's two triangles.
    bool liquidHeight(const Vector3 pos, out float height) const
    {
        const txF = (pos.x - corner.x) / liquidTileSize;
        const tx = cast(uint) txF;
        if (txF < 0 || tx >= tilesX)
            return false;
        const tyF = (pos.y - corner.y) / liquidTileSize;
        const ty = cast(uint) tyF;
        if (tyF < 0 || ty >= tilesY)
            return false;
        if ((flags[tx + ty * tilesX] & 0x0F) == 0x0F)
            return false;
        const dx = txF - cast(float) tx, dy = tyF - cast(float) ty;
        const row = tilesX + 1;
        float sx, sy;
        if (dx > dy)
        {
            sx = heights[tx + 1 + ty * row] - heights[tx + ty * row];
            sy = heights[tx + 1 + (ty + 1) * row] - heights[tx + 1 + ty * row];
        }
        else
        {
            sx = heights[tx + 1 + (ty + 1) * row] - heights[tx + (ty + 1) * row];
            sy = heights[tx + (ty + 1) * row] - heights[tx + ty * row];
        }
        height = heights[tx + ty * row] + dx * sx + dy * sy;
        return true;
    }

    /// `WmoLiquid::GetFileSize`
    @property uint fileSize() const
    {
        return cast(uint)(2 * 4 + 12 + heights.length * 4 + flags.length);
    }

    /// `WmoLiquid::writeToFile`
    void write(ref ByteWriter w) const
    {
        w.put(tilesX);
        w.put(tilesY);
        putVector(w, corner);
        w.put(type);
        foreach (h; heights)
            w.put(h);
        w.putBytes(flags);
    }

    /// `WmoLiquid::readFromFile`
    static WmoLiquid read(ref ByteReader r)
    {
        const tx = r.read!uint, ty = r.read!uint;
        const c = readVector(r);
        auto liquid = new WmoLiquid(tx, ty, c, r.read!uint);
        foreach (ref h; liquid.heights)
            h = r.read!float;
        liquid.flags[] = r.readBytes(liquid.flags.length);
        return liquid;
    }
}

/// `IntersectTriangle`: Möller–Trumbore; shortens `distance` to a nearer hit.
bool intersectTriangle(const MeshTriangle tri, const Vector3[] points, const Ray ray, ref float distance)
{
    enum float eps = 1e-5f;
    const e1 = points[tri.idx1] - points[tri.idx0];
    const e2 = points[tri.idx2] - points[tri.idx0];
    const p = ray.direction.cross(e2);
    const a = e1.dot(p);
    if (abs(a) < eps)
        return false;
    const f = 1.0f / a;
    const s = ray.origin - points[tri.idx0];
    const u = f * s.dot(p);
    if (u < 0 || u > 1)
        return false;
    const q = s.cross(e1);
    const v = f * ray.direction.dot(q);
    if (v < 0 || u + v > 1)
        return false;
    const t = f * e2.dot(q);
    if (t > 0 && t < distance)
    {
        distance = t;
        return true;
    }
    return false;
}

/// `GroupModel`: one group of a building, or a whole doodad.
final class GroupModel
{
    AABox bound;
    uint mogpFlags;  /// 0x8 outdoors, 0x2000 indoors
    uint groupWmoId;
    Vector3[] vertices;
    MeshTriangle[] triangles;
    BIH meshTree;
    WmoLiquid liquid;

    ///
    this(uint mogpFlags, uint groupWmoId, AABox bound)
    {
        this.mogpFlags = mogpFlags;
        this.groupWmoId = groupWmoId;
        this.bound = bound;
    }

    /// `GroupModel::setMeshData`: the triangles and the tree over them.
    void setMeshData(Vector3[] vertices, MeshTriangle[] triangles)
    {
        this.vertices = vertices;
        this.triangles = triangles;
        meshTree.build(triangles.length, (size_t i) {
            const t = this.triangles[i];
            auto lo = this.vertices[t.idx0], hi = lo;
            lo = lo.min(this.vertices[t.idx1]).min(this.vertices[t.idx2]);
            hi = hi.max(this.vertices[t.idx1]).max(this.vertices[t.idx2]);
            return AABox(lo, hi);
        });
    }

    /// `GroupModel::IntersectRay`
    bool intersectRay(const Ray ray, ref float distance, bool stopAtFirstHit) const
    {
        if (triangles.length == 0)
            return false;
        bool hit;
        meshTree.intersectRay(ray, (uint entry, ref float dist) {
            if (intersectTriangle(triangles[entry], vertices, ray, dist))
                hit = true;
            return hit;
        }, distance, stopAtFirstHit);
        return hit;
    }

    /// `GroupModel::IsInsideObject`: the distance down to the group's floor below `pos`, if it is inside the bound.
    bool isInsideObject(const Vector3 pos, const Vector3 down, out float zDist) const
    {
        if (triangles.length == 0 || !bound.contains(pos))
            return false;
        float dist = float.infinity;
        if (!intersectRay(Ray(pos - 0.1f * down, down), dist, false))
            return false;
        zDist = dist - 0.1f;
        return true;
    }

    /// `GroupModel::GetLiquidLevel`
    bool liquidLevel(const Vector3 pos, out float height) const
    {
        return liquid !is null && liquid.liquidHeight(pos, height);
    }

    /// `GroupModel::GetLiquidType`
    @property uint liquidType() const
    {
        return liquid is null ? 0 : liquid.type;
    }

    /// `GroupModel::writeToFile`
    void write(ref ByteWriter w) const
    {
        putBox(w, bound);
        w.put(mogpFlags);
        w.put(groupWmoId);
        putTag(w, "VERT");
        w.put(cast(uint)(4 + 12 * vertices.length));
        w.put(cast(uint) vertices.length);
        if (vertices.length == 0) // models without geometry end here
            return;
        foreach (v; vertices)
            putVector(w, v);
        putTag(w, "TRIM");
        w.put(cast(uint)(4 + 12 * triangles.length));
        w.put(cast(uint) triangles.length);
        foreach (t; triangles)
        {
            w.put(t.idx0);
            w.put(t.idx1);
            w.put(t.idx2);
        }
        putTag(w, "MBIH");
        meshTree.write(w);
        putTag(w, "LIQU");
        w.put(liquid is null ? 0u : liquid.fileSize);
        if (liquid !is null)
            liquid.write(w);
    }

    /// `GroupModel::readFromFile`
    static GroupModel read(ref ByteReader r)
    {
        const b = readBox(r);
        const flags = r.read!uint;
        auto group = new GroupModel(flags, r.read!uint, b);
        expectChunk(r, "VERT");
        r.read!uint; // chunk size
        group.vertices = new Vector3[r.read!uint];
        if (group.vertices.length == 0)
            return group;
        foreach (ref v; group.vertices)
            v = readVector(r);
        expectChunk(r, "TRIM");
        r.read!uint;
        group.triangles = new MeshTriangle[r.read!uint];
        foreach (ref t; group.triangles)
            t = MeshTriangle(r.read!uint, r.read!uint, r.read!uint);
        expectChunk(r, "MBIH");
        group.meshTree = BIH.read(r);
        expectChunk(r, "LIQU");
        if (r.read!uint > 0)
            group.liquid = WmoLiquid.read(r);
        return group;
    }
}

/// What a point query found in a model (`AreaInfo`'s model part, `GroupLocationInfo`).
struct GroupHit
{
    Rebindable!(const GroupModel) group;
    uint rootId;
    float zDist = 0; /// down to the group's floor, in model units
}

/// `WorldModel`: see the module documentation.
final class WorldModel
{
    uint rootWmoId;
    GroupModel[] groups;
    BIH groupTree;
    uint modelFlags; /// `MOD_M2` for a doodad; set by the spawns that use it, as in CMaNGOS

    /// `WorldModel::setGroupModels`
    void setGroups(GroupModel[] groups)
    {
        this.groups = groups;
        groupTree.build(groups.length, (size_t i) => this.groups[i].bound, 1);
    }

    /// `WorldModel::IntersectRay`; doodads are left out when `ignoreM2`.
    bool intersectRay(const Ray ray, ref float distance, bool stopAtFirstHit, bool ignoreM2 = false) const
    {
        if (ignoreM2 && (modelFlags & modM2))
            return false;
        if (groups.length == 1)
            return groups[0].intersectRay(ray, distance, stopAtFirstHit);
        bool hit;
        groupTree.intersectRay(ray, (uint entry, ref float dist) {
            if (groups[entry].intersectRay(ray, dist, stopAtFirstHit))
                hit = true;
            return hit;
        }, distance, stopAtFirstHit);
        return hit;
    }

    /**
     * `WorldModel::IntersectPoint` and `GetLocationInfo`: the group whose floor is nearest below
     * `p`, of those whose bound holds it.
     */
    bool intersectPoint(const Vector3 p, const Vector3 down, out GroupHit found) const
    {
        if (groups.length == 0)
            return false;
        Rebindable!(const GroupModel) best;
        float zDist = float.infinity;
        groupTree.intersectPoint(p, (uint entry) {
            float groupZ;
            if (groups[entry].isInsideObject(p, down, groupZ) && groupZ < zDist)
            {
                zDist = groupZ;
                best = groups[entry];
            }
        });
        if (best is null)
            return false;
        found = GroupHit(best, rootWmoId, zDist);
        return true;
    }

    /// `WorldModel::writeFile`. As CMaNGOS, "WMOD" says 8 bytes and holds 4.
    void write(string path) const
    {
        ByteWriter w;
        putTag(w, vmapMagic);
        putTag(w, "WMOD");
        w.put(8u);
        w.put(rootWmoId);
        if (groups.length)
        {
            putTag(w, "GMOD");
            w.put(cast(uint) groups.length);
            foreach (g; groups)
                g.write(w);
            putTag(w, "GBIH");
            groupTree.write(w);
        }
        std.file.write(path, w.data);
    }

    /// `WorldModel::readFile`
    static WorldModel read(string path)
    {
        auto data = cast(const(ubyte)[]) std.file.read(path);
        auto r = ByteReader(data);
        expectChunk(r, vmapMagic);
        expectChunk(r, "WMOD");
        r.read!uint;
        auto model = new WorldModel;
        model.rootWmoId = r.read!uint;
        if (r.remaining >= 4 && cast(const(char)[]) data[r.position .. r.position + 4] == "GMOD")
        {
            r.skip(4);
            model.groups = new GroupModel[r.read!uint];
            foreach (ref g; model.groups)
                g = GroupModel.read(r);
            expectChunk(r, "GBIH");
            model.groupTree = BIH.read(r);
        }
        return model;
    }
}

/// `ModelSpawn`: a model placed on a map.
struct ModelSpawn
{
    uint flags;
    ushort adtId;
    uint id;
    Vector3 pos;
    Vector3 rot;     /// degrees
    float scale = 1;
    AABox bound;
    string name;

    /// `ModelSpawn::writeToFile`
    void write(ref ByteWriter w) const
    {
        w.put(flags);
        w.put(adtId);
        w.put(id);
        putVector(w, pos);
        putVector(w, rot);
        w.put(scale);
        if (flags & modHasBound)
            putBox(w, bound);
        w.put(cast(uint) name.length);
        w.putBytes(cast(const(ubyte)[]) name);
    }

    /// `ModelSpawn::readFromFile`
    static ModelSpawn read(ref ByteReader r)
    {
        ModelSpawn s;
        s.flags = r.read!uint;
        s.adtId = r.read!ushort;
        s.id = r.read!uint;
        s.pos = readVector(r);
        s.rot = readVector(r);
        s.scale = r.read!float;
        if (s.flags & modHasBound)
            s.bound = readBox(r);
        const length = r.read!uint;
        enforce(length <= 500, "a model name of more than 500 characters: a damaged vmap file");
        s.name = r.readString(length);
        return s;
    }
}

/// A tag (a chunk name or a magic), its characters in order.
void putTag(ref ByteWriter w, string tag)
{
    w.putBytes(cast(const(ubyte)[]) tag);
}

/// `readChunk`: the next bytes must be `name`.
void expectChunk(ref ByteReader r, string name)
{
    enforce(cast(const(char)[]) r.readBytes(name.length) == name, "vmap file: expected " ~ name);
}

unittest
{
    import std.file : remove, tempDir;
    import std.math : isClose;
    import std.path : buildPath;

    // A one-group model: a floor at z = 0, 10 x 10, and water at z = 2 over its first tile.
    auto group = new GroupModel(0x8, 7, AABox(Vector3(0, 0, -1), Vector3(10, 10, 5)));
    group.setMeshData([Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(0, 10, 0), Vector3(10, 10, 0)],
        [MeshTriangle(0, 1, 2), MeshTriangle(1, 3, 2)]);
    group.liquid = new WmoLiquid(1, 1, Vector3(0, 0, 0), 1);
    group.liquid.heights[] = 2;
    auto model = new WorldModel;
    model.rootWmoId = 42;
    model.setGroups([group]);

    // Down onto the floor from 3 yards up.
    float dist = 100;
    assert(model.intersectRay(Ray(Vector3(5, 5, 3), Vector3(0, 0, -1)), dist, false) && isClose(dist, 3));
    dist = 100;
    assert(!model.intersectRay(Ray(Vector3(15, 5, 3), Vector3(0, 0, -1)), dist, false), "beside it");
    GroupHit hit;
    assert(model.intersectPoint(Vector3(5, 5, 3), Vector3(0, 0, -1), hit));
    assert(hit.rootId == 42 && hit.group.groupWmoId == 7 && isClose(hit.zDist, 3));
    float level;
    assert(group.liquidLevel(Vector3(1, 1, 0), level) && level == 2);
    assert(!group.liquidLevel(Vector3(9, 9, 0), level), "past the liquid's tiles");

    // Written and read back.
    const path = buildPath(tempDir, "dmangos-model-test.vmo");
    scope (exit)
        remove(path);
    model.write(path);
    const copy = WorldModel.read(path);
    assert(copy.rootWmoId == 42 && copy.groups.length == 1 && copy.groups[0].triangles.length == 2);
    assert(copy.groups[0].liquid.heights == [2.0f, 2, 2, 2] && copy.groups[0].meshTree.tree == group.meshTree.tree);
    dist = 100;
    assert(copy.intersectRay(Ray(Vector3(5, 5, 3), Vector3(0, 0, -1)), dist, false) && isClose(dist, 3));

    // A spawn with and without its bound.
    ModelSpawn spawn = {flags: modHasBound, adtId: 3, id: 9, pos: Vector3(1, 2, 3), rot: Vector3(0, 90, 0),
        scale: 1, bound: AABox(Vector3(0, 0, 0), Vector3(1, 1, 1)), name: "house.wmo"};
    ByteWriter w;
    spawn.write(w);
    spawn.flags = modM2;
    spawn.write(w);
    auto r = ByteReader(w.data);
    const a = ModelSpawn.read(r), b = ModelSpawn.read(r);
    assert(a.bound.hi.x == 1 && a.name == "house.wmo" && a.adtId == 3);
    assert(b.bound == AABox.init && b.flags == modM2 && r.empty);
}
