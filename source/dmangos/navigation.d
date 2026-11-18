/**
 * Movement maps (mmaps): navigation meshes over the terrain and the buildings, which
 * creatures find their way over.
 *
 * Recast builds them and Detour searches them: recastnavigation 1.6.0 (zlib licence), compiled
 * from `thirdparty/` with a small C interface (`thirdparty/dmnav/dmnav.cpp`).
 * This module is that interface in D: building a tile (`buildTile`, for the extractor), and a map's
 * mesh with the tiles it has loaded, which finds paths (`NavMesh`).
 *
 * Recast has y up; the world has z up. A world point (x, y, z) is (y, z, x) to Recast. A map is
 * 64 x 64 grid tiles of 533 1/3 yards (`tileOf` in `dmangos.world.terrain`), and
 * each is one tile of the mesh: grid tile [gx, gy] is mesh tile (63 - gy, 63 - gx).
 */
module dmangos.navigation;

import dmangos.vmap.math : Vector3;

/// Yards per side of a grid tile, and so of a mesh tile.
enum float gridTileSize = 533.33333f;

/// What a polygon is, and the flag it carries.
enum NavArea : ubyte
{
    none = 0,     /// not walkable
    ground = 1,   /// flag 1
    water = 2,    /// flag 2
    magma = 3,    /// magma and slime: flag 4
}

/// The flags of an area's polygons.
enum ushort navFlag(NavArea area) = cast(ushort)(1 << (area - 1));

/// The flags a walking creature may cross (it swims, too).
enum ushort walkingFlags = navFlag!(NavArea.ground) | navFlag!(NavArea.water);

/// How a tile is built: its cell size (80 cells a piece) and the steepest walkable slope, in degrees.
struct BuildConfig
{
    float cellSize = 0.2666666f;
    float walkableSlope = 50;
    int walkableHeight = 6;
    int walkableClimb = 4;
    int walkableRadius = 2;
    int subTileCells = 80;
    float maxSimplificationError = 1.8f;
    int minRegionArea = 60 * 60;
    int mergeRegionArea = 50 * 50;
    float detailSampleDist = 0.2666666f * 64;
    float detailSampleMaxError = 0.2666666f * 2;
    float[3] bmin = 0;
    float[3] bmax = 0;
    int tileX, tileY;
}

private extern (C) nothrow @nogc
{
    int dmnav_build_tile(const(BuildConfig)* config, const(float)* verts, int nverts, const(int)* tris,
        const(ubyte)* areas, int ntris, ubyte** data, int* size);
    void dmnav_free(void* p);
    void* dmnav_mesh_create(const(float)* origin, float tileWidth, int maxTiles, int maxPolys);
    void dmnav_mesh_free(void* mesh);
    int dmnav_mesh_add_tile(void* mesh, const(ubyte)* data, int size);
    void dmnav_mesh_remove_tile(void* mesh, int tileX, int tileY);
    void* dmnav_query_create(void* mesh, int maxNodes);
    void dmnav_query_free(void* query);
    int dmnav_find_path(void* query, const(float)* start, const(float)* end, const(float)* extents,
        ushort include, ushort exclude, float* points, int maxPoints, int* partial);
    int dmnav_height(void* query, const(float)* point, const(float)* extents, ushort include, float* height);
}

/// A world point in Recast's axes, and back.
float[3] toRecast(Vector3 p) pure nothrow @nogc @safe
{
    return [p.y, p.z, p.x];
}

/// ditto
Vector3 fromRecast(const float[3] r) pure nothrow @nogc @safe
{
    return Vector3(r[2], r[0], r[1]);
}

/// The mesh tile of grid tile [gx, gy].
int[2] meshTileOf(int gx, int gy) pure nothrow @nogc @safe
{
    return [63 - gy, 63 - gx];
}

/// Grid tile [gx, gy]'s bounds across, in Recast's axes (x, z).
void gridTileBounds(int gx, int gy, out float[3] bmin, out float[3] bmax) pure nothrow @nogc @safe
{
    bmin = [(31 - gy) * gridTileSize, 0, (31 - gx) * gridTileSize];
    bmax = [(32 - gy) * gridTileSize, 0, (32 - gx) * gridTileSize];
}

/// Why `buildTile` gave nothing.
class NavBuildException : Exception
{
    ///
    this(string msg, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
    }
}

/**
 * Builds a tile from world triangles (`vertices`, `triangles` as index triples, an `NavArea` per
 * triangle): its Detour data, or null if nothing on it is walkable. The tile's bounds and place
 * are in `config`.
 */
ubyte[] buildTile(const ref BuildConfig config, const(Vector3)[] vertices, const(int)[] triangles,
    const(NavArea)[] areas) @trusted
in (triangles.length == 3 * areas.length)
{
    import std.format : format;

    auto verts = new float[3 * vertices.length];
    foreach (i, v; vertices)
        verts[3 * i .. 3 * i + 3] = toRecast(v);
    ubyte* data;
    int size;
    const result = dmnav_build_tile(&config, verts.ptr, cast(int) vertices.length, triangles.ptr,
        cast(const(ubyte)*) areas.ptr, cast(int) areas.length, &data, &size);
    if (result == 1)
        return null;
    if (result != 0)
        throw new NavBuildException(format!"Recast failed at step %s"(-result));
    scope (exit)
        dmnav_free(data);
    return data[0 .. size].dup;
}

/// A way found: corners from start to end (or as near the end as can be reached).
struct NavPath
{
    Vector3[] points;   /// empty: no way (an end is off the mesh)
    bool partial;       /// the end could not be reached: the last point is the nearest place to it
}

/**
 * A map's navigation mesh: the tiles loaded so far, and a query over them. Used by one thread.
 */
final class NavMesh
{
    private void* mesh;
    private void* query;
    private bool[uint] loaded;

    /// An empty mesh for a whole map (64 x 64 tiles of `tileWidth` yards).
    this(float tileWidth = gridTileSize, int maxNodes = 4096)
    {
        const float[3] origin = [-32 * tileWidth, 0, -32 * tileWidth];
        mesh = dmnav_mesh_create(origin.ptr, tileWidth, 64 * 64, 1 << 20);
        if (mesh is null)
            throw new NavBuildException("cannot make a navigation mesh");
        query = dmnav_query_create(mesh, maxNodes);
        if (query is null)
        {
            dmnav_mesh_free(mesh);
            throw new NavBuildException("cannot make a navigation query");
        }
    }

    ~this()
    {
        close();
    }

    /// Frees it (also when collected).
    void close() nothrow @nogc
    {
        if (query !is null)
            dmnav_query_free(query);
        if (mesh !is null)
            dmnav_mesh_free(mesh);
        query = null;
        mesh = null;
    }

    /// Adds a tile `buildTile` made, as mesh tile (tileX, tileY); false if Detour refused it.
    bool addTile(int tileX, int tileY, const(ubyte)[] data)
    {
        const key = cast(uint)(tileX << 16 | tileY);
        if (key in loaded)
            return true;
        if (dmnav_mesh_add_tile(mesh, data.ptr, cast(int) data.length) != 0)
            return false;
        loaded[key] = true;
        return true;
    }

    /// Whether mesh tile (tileX, tileY) is loaded.
    bool hasTile(int tileX, int tileY) const
    {
        return (cast(uint)(tileX << 16 | tileY) in loaded) !is null;
    }

    /// Takes a tile out.
    void removeTile(int tileX, int tileY)
    {
        const key = cast(uint)(tileX << 16 | tileY);
        if (loaded.remove(key))
            dmnav_mesh_remove_tile(mesh, tileX, tileY);
    }

    /// How many tiles are loaded.
    @property size_t tileCount() const
    {
        return loaded.length;
    }

    /**
     * The way from `start` to `end` (world points) over the polygons with `include` flags, looking
     * for each end's polygon within `extents` yards across and `extentsUp` up and down.
     */
    NavPath findPath(Vector3 start, Vector3 end, ushort include = walkingFlags, float extents = 3,
        float extentsUp = 5) @trusted
    {
        enum maxPoints = 74; // the longest path, in points
        const s = toRecast(start), e = toRecast(end);
        const float[3] ext = [extents, extentsUp, extents];
        float[3 * maxPoints] corners;
        int partial;
        const count = dmnav_find_path(query, s.ptr, e.ptr, ext.ptr, include, 0, corners.ptr, maxPoints, &partial);
        NavPath path;
        path.partial = partial != 0;
        path.points = new Vector3[count];
        foreach (i, ref p; path.points)
            p = fromRecast(corners[3 * i .. 3 * i + 3][0 .. 3]);
        return path;
    }

    /// The mesh's height under `at`, if it is on the mesh (within `extents`).
    bool height(Vector3 at, out float z, float extents = 3, float extentsUp = 5) @trusted
    {
        const p = toRecast(at);
        const float[3] ext = [extents, extentsUp, extents];
        return dmnav_height(query, p.ptr, ext.ptr, walkingFlags, &z) != 0;
    }
}

// A field 20 yards square, a wall across most of it: the way goes round the wall.
unittest
{
    import std.math : abs;

    enum float side = 21.333332f; // one piece of 80 cells
    Vector3[] vertices;
    int[] triangles;
    NavArea[] areas;
    void quad(Vector3 a, Vector3 b, Vector3 c, Vector3 d)
    {
        const base = cast(int) vertices.length;
        vertices ~= [a, b, c, d];
        triangles ~= [base, base + 1, base + 2, base, base + 2, base + 3];
        areas ~= [NavArea.ground, NavArea.ground];
    }
    // The ground, from (0, 0) to (side, side) in world x and y, at height 10 (wound so it faces up).
    quad(Vector3(0, 0, 10), Vector3(side, 0, 10), Vector3(side, side, 10), Vector3(0, side, 10));
    // A wall along x = 10, from y = 0 to y = 16, 5 yards high: its top is too high to climb.
    quad(Vector3(9.5f, 0, 15), Vector3(9.5f, 16, 15), Vector3(10.5f, 16, 15), Vector3(10.5f, 0, 15));
    quad(Vector3(9.5f, 0, 10), Vector3(9.5f, 16, 10), Vector3(9.5f, 16, 15), Vector3(9.5f, 0, 15));
    quad(Vector3(10.5f, 0, 15), Vector3(10.5f, 16, 15), Vector3(10.5f, 16, 10), Vector3(10.5f, 0, 10));

    BuildConfig config;
    // Recast's x is the world's y, its z the world's x.
    config.bmin = [0, 0, 0];
    config.bmax = [side, 0, side];
    config.minRegionArea = 8;
    config.mergeRegionArea = 20;
    const origin = -32 * side;
    config.tileX = cast(int)((0 - origin) / side);
    config.tileY = config.tileX;
    const data = buildTile(config, vertices, triangles, areas);
    assert(data.length > 0, "something is walkable");

    auto mesh = new NavMesh(side);
    scope (exit)
        mesh.close();
    assert(mesh.addTile(config.tileX, config.tileY, data) && mesh.tileCount == 1);

    float z;
    assert(mesh.height(Vector3(3, 3, 10), z) && abs(z - 10) < 0.6f, "on the ground");

    const path = mesh.findPath(Vector3(5, 5, 10), Vector3(15, 5, 10));
    assert(path.points.length >= 3 && !path.partial, "round the wall, not through it");
    bool beyondWall;
    foreach (p; path.points)
        beyondWall = beyondWall || p.y > 16;
    assert(beyondWall, "the way passes the wall's end");
    assert(abs(path.points[$ - 1].x - 15) < 0.5f && abs(path.points[$ - 1].y - 5) < 0.5f);

    const straight = mesh.findPath(Vector3(3, 3, 10), Vector3(3, 18, 10));
    assert(straight.points.length == 2, "on one side of the wall: straight");

    assert(mesh.findPath(Vector3(100, 100, 10), Vector3(3, 3, 10)).points.length == 0, "off the mesh");
}
