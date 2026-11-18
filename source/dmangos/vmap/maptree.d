/**
 * A map's buildings and doodads, as the world server queries them: `StaticMapTree` reads
 * `<data_dir>/vmaps/MMM.vmtree`
 * (the tree over every model placed on the map) and, as tiles are needed, `MMM_YY_XX.vmtile` (the
 * models placed on that tile), whose models (`*.vmo`) are shared between maps through
 * `ModelCache`.
 *
 * The questions: the height of the first surface below a point (`height`), whether one point sees
 * another (`isInLineOfSight`), which building group a point is in and its floor (`areaInfo`, for
 * WMO areas and indoors), and the liquid there (`liquidLevel`). Positions are world coordinates;
 * the trees use the vmap files' internal ones (`toInternal`), mirrored about the map's centre.
 *
 * The area query takes both the floor and the group from the building with the highest floor
 * below the point, never the group of another building it tested.
 */
module dmangos.vmap.maptree;

import std.exception : enforce;
import std.format : format;
import std.math : abs;
import std.path : buildPath;
import std.typecons : Rebindable;
static import std.file;

import dmangos.bytes : ByteReader;
import dmangos.log;
import dmangos.vmap.bih;
import dmangos.vmap.math;
import dmangos.vmap.model;

/// No height found.
enum float vmapInvalidHeightValue = -200_000.0f;

/// World coordinates to the trees' internal ones (it is its own inverse).
Vector3 toInternal(float x, float y, float z) pure nothrow @nogc @safe
{
    enum float mid = 0.5f * 64.0f * 533.33333333f;
    return Vector3(mid - x, mid - y, z);
}

/// The models loaded, shared by every map that places them.
final class ModelCache
{
    private string directory;
    private WorldModel[string] models;
    private bool[string] failed;

    ///
    this(string directory)
    {
        this.directory = directory;
    }

    /// The model `name` (`name.vmo`), read the first time; null if it cannot be.
    WorldModel acquire(string name)
    {
        if (auto model = name in models)
            return *model;
        if (name in failed)
            return null;
        try
            return models[name] = WorldModel.read(buildPath(directory, name ~ ".vmo"));
        catch (Exception e)
        {
            error!"vmaps: could not load '%s.vmo': %s"(name, e.msg);
            failed[name] = true;
            return null;
        }
    }

    /// Models in memory.
    @property size_t length() const
    {
        return models.length;
    }
}

/// A placed model, with the transform back into its own coordinates.
struct ModelInstance
{
    ModelSpawn spawn;
    WorldModel model;   /// null until its tile is loaded
    Matrix3 invRot;
    float invScale = 0;

    ///
    this(ModelSpawn spawn, WorldModel model)
    {
        this.spawn = spawn;
        this.model = model;
        enum float pi = 3.1415926535897932f;
        invRot = Matrix3.fromEulerAnglesZYX(pi * spawn.rot.y / 180.0f, pi * spawn.rot.x / 180.0f,
            pi * spawn.rot.z / 180.0f).inverse();
        invScale = 1.0f / spawn.scale;
    }

    /// Whether `ray` hits the model within `maxDist`, which it shortens to the hit (world units).
    bool intersectRay(const Ray ray, ref float maxDist, bool stopAtFirstHit, bool ignoreM2) const
    {
        if (model is null || ray.intersectionTime(spawn.bound) == float.infinity)
            return false;
        const p = invRot * (ray.origin - spawn.pos) * invScale;
        const modelRay = Ray(p, invRot * ray.direction);
        float distance = maxDist * invScale;
        if (!model.intersectRay(modelRay, distance, stopAtFirstHit, ignoreM2))
            return false;
        maxDist = distance * spawn.scale;
        return true;
    }

    /**
     * The building group the point is in, and
     * the world height of its floor below; buildings only.
     */
    bool locate(const Vector3 p, ref LocationInfo info) const
    {
        if (model is null || (spawn.flags & modM2) || !spawn.bound.contains(p))
            return false;
        const pModel = invRot * (p - spawn.pos) * invScale;
        const zDir = invRot * Vector3(0, 0, -1);
        GroupHit hit;
        if (!model.intersectPoint(pModel, zDir, hit))
            return false;
        const ground = pModel + hit.zDist * zDir;
        const worldZ = ((ground * invRot) * spawn.scale + spawn.pos).z;
        if (info.groundZ >= worldZ)
            return false;
        info.groundZ = worldZ;
        info.rootId = hit.rootId;
        info.group = hit.group;
        info.adtId = spawn.adtId;
        info.instance = &this;
        return true;
    }

    /// The level of the located group's liquid at `p`, in world height.
    bool liquidLevel(const Vector3 p, const ref LocationInfo info, out float height) const
    {
        const pModel = invRot * (p - spawn.pos) * invScale;
        float level;
        if (!info.group.liquidLevel(pModel, level))
            return false;
        height = (level - pModel.z) * spawn.scale + p.z;
        return true;
    }
}

/// What `StaticMapTree.locate` found.
struct LocationInfo
{
    float groundZ = -float.infinity;
    uint rootId;
    ushort adtId;
    Rebindable!(const GroupModel) group;
    const(ModelInstance)* instance;

    /// Whether a building group was found.
    @property bool found() const
    {
        return group !is null;
    }
}

/// A map's tree of placed models: see the module documentation.
final class StaticMapTree
{
    immutable uint mapId;
    private
    {
        string directory;
        ModelCache cache;
        bool tiled;
        BIH tree;
        ModelInstance[] values;   // by tree object index
        uint[uint] loadedSpawns;  // tree index -> tiles referring to it
        uint[][uint] tileSpawns;  // packed tile -> the tree indexes its file lists
        bool[uint] loadedTiles;   // packed tile -> whether it had a file
    }

    /// The key of tile [x, y].
    static uint packTileId(uint x, uint y) pure nothrow @nogc @safe
    {
        return x << 16 | y;
    }

    /**
     * Reads `MMM.vmtree` from `directory`, with its global models if the map
     * has no tiles. Throws if the file is missing or damaged.
     */
    this(uint mapId, string directory, ModelCache cache)
    {
        this.mapId = mapId;
        this.directory = directory;
        this.cache = cache;
        const path = buildPath(directory, format!"%03d.vmtree"(mapId));
        auto data = cast(const(ubyte)[]) std.file.read(path);
        auto r = ByteReader(data);
        expectChunk(r, vmapMagic);
        tiled = r.read!ubyte != 0;
        expectChunk(r, "NODE");
        tree = BIH.read(r);
        values = new ModelInstance[tree.primCount];
        expectChunk(r, "GOBJ");
        if (!tiled)
            while (!r.empty)
                place(ModelSpawn.read(r), r.read!uint);
    }

    /// Whether the map's `.vmtree` file exists (the map file alone).
    static bool exists(uint mapId, string directory)
    {
        return std.file.exists(buildPath(directory, format!"%03d.vmtree"(mapId)));
    }

    /// A tile's file name: note it names the y tile before the x.
    static string tileFileName(uint mapId, uint tileX, uint tileY)
    {
        return format!"%03d_%02d_%02d.vmtile"(mapId, tileY, tileX);
    }

    /// Loads the models of grid tile [x, y]; once.
    void loadTile(uint tileX, uint tileY)
    {
        const key = packTileId(tileX, tileY);
        if (key in loadedTiles)
            return;
        if (!tiled)
        {
            loadedTiles[key] = false;
            return;
        }
        const path = buildPath(directory, tileFileName(mapId, tileX, tileY));
        if (!std.file.exists(path))
        {
            loadedTiles[key] = false;
            return;
        }
        loadedTiles[key] = true;
        try
        {
            auto r = ByteReader(cast(const(ubyte)[]) std.file.read(path));
            expectChunk(r, vmapMagic);
            uint[] listed;
            foreach (_; 0 .. r.read!uint)
            {
                const spawn = ModelSpawn.read(r);
                const index = r.read!uint;
                place(spawn, index);
                listed ~= index;
            }
            tileSpawns[key] = listed;
        }
        catch (Exception e)
            error!"vmaps: tile %s of map %s: %s"(path, mapId, e.msg);
    }

    /**
     * The models grid tile [x, y] has (those its file lists, which reach into it), loaded; every
     * model of the map if it has no tiles. For building movement maps.
     */
    const(ModelInstance)[] tileInstances(uint tileX, uint tileY)
    {
        loadTile(tileX, tileY);
        if (!tiled)
        {
            const(ModelInstance)[] all;
            foreach (ref v; values)
                if (v.model !is null)
                    all ~= v;
            return all;
        }
        const(ModelInstance)[] listed;
        foreach (index; tileSpawns.get(packTileId(tileX, tileY), null))
            if (index < values.length && values[index].model !is null)
                listed ~= values[index];
        return listed;
    }

    /// Whether tile [x, y] is loaded (always, on a map without tiles).
    bool isTileLoaded(uint tileX, uint tileY) const
    {
        return !tiled || (packTileId(tileX, tileY) in loadedTiles) !is null;
    }

    /// Whether nothing is between `from` and `to` (internal coordinates).
    bool isInLineOfSight(const Vector3 from, const Vector3 to, bool ignoreM2) const
    {
        float maxDist = (to - from).magnitude();
        if (maxDist < 1e-10f)
            return true;
        const ray = Ray(from, (to - from) / maxDist);
        return !intersection(ray, maxDist, true, ignoreM2);
    }

    /**
     * The first surface below `p` (internal coordinates) within `maxSearchDist` (above, if
     * negative); `float.infinity` if none.
     */
    float height(const Vector3 p, float maxSearchDist) const
    {
        const up = maxSearchDist < 0;
        float maxDist = abs(maxSearchDist);
        if (!intersection(Ray(p, Vector3(0, 0, up ? 1 : -1)), maxDist, false, false))
            return float.infinity;
        return up ? p.z + maxDist : p.z - maxDist;
    }

    /// The building group `p` is in and its floor (internal coordinates).
    bool locate(const Vector3 p, out LocationInfo info) const
    {
        bool found;
        LocationInfo best;
        tree.intersectPoint(p, (uint entry) {
            if (values[entry].locate(p, best))
                found = true;
        });
        info = best;
        return found;
    }

    /// Placed models with their model loaded.
    @property size_t loadedModels() const
    {
        return loadedSpawns.length;
    }

private:
    /// Whether `ray` hits a model; shortens `maxDist` to the nearest hit.
    bool intersection(const Ray ray, ref float maxDist, bool stopAtFirstHit, bool ignoreM2) const
    {
        float distance = maxDist;
        bool hit;
        tree.intersectRay(ray, (uint entry, ref float dist) {
            const result = values[entry].intersectRay(ray, dist, stopAtFirstHit, ignoreM2);
            if (result)
                hit = true;
            return result;
        }, distance, stopAtFirstHit);
        if (hit)
            maxDist = distance;
        return hit;
    }

    /// A spawn read from the tree or a tile, at tree index `index` (the first time it is seen).
    void place(ModelSpawn spawn, uint index)
    {
        auto model = cache.acquire(spawn.name);
        if (model !is null)
            model.modelFlags = spawn.flags;
        if (auto count = index in loadedSpawns)
        {
            ++*count;
            return;
        }
        if (index >= values.length)
        {
            error!"vmaps: invalid tree element %s/%s on map %s"(index, values.length, mapId);
            return;
        }
        values[index] = ModelInstance(spawn, model);
        loadedSpawns[index] = 1;
    }
}

/// A WMO liquid type as `mapLiquidType*` bits.
ubyte liquidMask(uint type) pure nothrow @nogc @safe
{
    switch (type)
    {
    case 1, 41, 61: return 0x08; // water
    case 2: return 0x02;         // ocean
    case 3: return 0x01;         // magma
    case 4, 21: return 0x04;     // slime
    default: return 0;
    }
}

/// The liquid at a point on one map tree (world coordinates): its level, the floor below, and its type.
bool liquidLevel(const StaticMapTree tree, float x, float y, float z, ubyte requiredMask, out float level,
    out float floor, out uint type)
{
    LocationInfo info;
    const pos = toInternal(x, y, z);
    if (!tree.locate(pos, info))
        return false;
    floor = info.groundZ;
    type = info.group.liquidType;
    if (requiredMask && !(liquidMask(type) & requiredMask))
        return false;
    return info.instance.liquidLevel(pos, info, level);
}
