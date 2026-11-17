/**
 * Builds movement maps (CMaNGOS's `MoveMapGen`): a navigation mesh per grid tile, from the terrain
 * of `OUTPUT/maps` and the buildings and doodads of `OUTPUT/vmaps`, written to `OUTPUT/mmaps`.
 *
 * For each tile (`TerrainBuilder::loadMap` and `loadVMap`):
 * $(UL
 *   $(LI The terrain: each of the 128 x 128 squares is four triangles from its corners to its centre,
 *        holes left out, with a strip of the neighbouring tiles so that the tiles' edges meet. Ground
 *        deeper under water than a creature stands is water, which creatures swim across.)
 *   $(LI The buildings and doodads the tile's vmap file lists, placed as on the map.)
 * )
 * `dmangos.navigation.buildTile` then has Recast build it, with `MapBuilder::buildMoveMapTile`'s
 * settings. Tiles are built in parallel; each worker thread reads the files it needs itself.
 *
 * Files: `MMM.mmap` (the mesh's origin, tile size and limits) and `MMMXXYY.mmtile` per tile with
 * anything walkable (a header and Detour's tile data), XX and YY as in the `.map` files.
 */
module dmangos.extractor.mmaps;

import std.algorithm.iteration : filter, map;
import std.array : array;
import std.conv : to;
import std.file : dirEntries, exists, mkdirRecurse, read, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath;

import dmangos.bytes : ByteWriter;
import dmangos.navigation;
import dmangos.vmap.math : Vector3;
import dmangos.vmap.maptree : ModelCache, ModelInstance, StaticMapTree, toInternal;
import dmangos.world.terrain : GridMap;

/// `MMAP_MAGIC`, and the versions a tile file records (Detour's, and this format's).
enum uint mmapMagic = 0x4D4D4150, detourVersion = 7, mmapVersion = 1;

/// What was built.
struct MmapReport
{
    size_t maps, tiles, empty;
    string[] problems;
}

/// One map's tiles, and the depth of water a creature swims in rather than walks.
private enum float swimDepth = 1.5f;

/**
 * Builds the movement maps of the maps in `OUTPUT/maps` (or only `only`, if given) into
 * `OUTPUT/mmaps`. `print` is told about each map.
 */
MmapReport buildMovementMaps(string output, const(uint)[] only, void delegate(string) print)
{
    import std.parallelism : parallel, taskPool;

    const mapsDir = buildPath(output, "maps"), vmapsDir = buildPath(output, "vmaps");
    const outDir = buildPath(output, "mmaps");
    mkdirRecurse(outDir);

    // The tiles there are, by map: `MMMXXYY.map`.
    int[2][][uint] tilesOf;
    foreach (entry; dirEntries(mapsDir, "*.map", SpanMode.shallow))
    {
        const name = baseName(entry.name);
        if (name.length != 11)
            continue;
        const mapId = name[0 .. 3].to!uint;
        if (only.length && !only.canFindValue(mapId))
            continue;
        int[2] tile = [name[3 .. 5].to!int, name[5 .. 7].to!int];
        tilesOf[mapId] ~= tile;
    }
    // Maps that are one building (most dungeons) have no terrain: the tiles their models cover
    // (`MapBuilder::getGridBounds`).
    if (exists(vmapsDir))
        foreach (entry; dirEntries(vmapsDir, "*.vmtree", SpanMode.shallow))
        {
            const mapId = baseName(entry.name)[0 .. 3].to!uint;
            if (mapId in tilesOf || (only.length && !only.canFindValue(mapId)))
                continue;
            auto covered = modelTiles(vmapsDir, mapId);
            if (covered.length)
                tilesOf[mapId] = covered;
        }

    MmapReport report;
    foreach (mapId; tilesOf.keys.sort)
    {
        writeMapFile(outDir, mapId);
        auto tiles = tilesOf[mapId];
        size_t built, empty;
        string[] problems;
        foreach (tile; parallel(tiles, 1))
        {
            try
            {
                const data = buildGridTile(mapsDir, vmapsDir, mapId, tile[0], tile[1]);
                if (data is null)
                {
                    synchronized
                        ++empty;
                    continue;
                }
                writeTileFile(outDir, mapId, tile[0], tile[1], data);
                synchronized
                    ++built;
            }
            catch (Exception e)
                synchronized
                    problems ~= format!"map %s tile %s %s: %s"(mapId, tile[0], tile[1], e.msg);
        }
        ++report.maps;
        report.tiles += built;
        report.empty += empty;
        report.problems ~= problems;
        print(format!"map %s: %s tiles with a mesh, %s with nothing walkable"(mapId, built, empty));
    }
    return report;
}

/// The grid tiles the models of a map without tiles reach into.
private int[2][] modelTiles(string vmapsDir, uint mapId)
{
    import dmangos.world.terrain : tileOf;

    auto tree = new StaticMapTree(mapId, vmapsDir, new ModelCache(vmapsDir));
    bool[int[2]] tiles;
    foreach (ref instance; tree.tileInstances(0, 0))
    {
        // The bound is in the trees' internal coordinates, mirrored in x and y.
        const lo = toInternal(instance.spawn.bound.hi.x, instance.spawn.bound.hi.y, 0);
        const hi = toInternal(instance.spawn.bound.lo.x, instance.spawn.bound.lo.y, 0);
        const a = tileOf(hi.x, hi.y), b = tileOf(lo.x, lo.y);
        foreach (x; a[0] .. b[0] + 1)
            foreach (y; a[1] .. b[1] + 1)
                if (x >= 0 && y >= 0 && x < 64 && y < 64)
                    tiles[[x, y]] = true;
    }
    return tiles.keys;
}

private bool canFindValue(const(uint)[] list, uint value)
{
    foreach (v; list)
        if (v == value)
            return true;
    return false;
}

private auto sort(uint[] keys)
{
    import std.algorithm.sorting : sort;

    return keys.sort;
}

/// `MMM.mmap`: Detour's `dtNavMeshParams` (origin, tile width and height, the most tiles and polygons).
private void writeMapFile(string dir, uint mapId)
{
    ByteWriter w;
    w.put(-32 * gridTileSize);
    w.put(0.0f);
    w.put(-32 * gridTileSize);
    w.put(gridTileSize);
    w.put(gridTileSize);
    w.put(64 * 64);
    w.put(1 << 20);
    write(buildPath(dir, format!"%03d.mmap"(mapId)), w.data);
}

/// `MMMXXYY.mmtile`: `MmapTileHeader` (magic, Detour version, format version, size, liquids) and the data.
private void writeTileFile(string dir, uint mapId, int gx, int gy, const(ubyte)[] data)
{
    ByteWriter w;
    w.put(mmapMagic);
    w.put(detourVersion);
    w.put(mmapVersion);
    w.put(cast(uint) data.length);
    w.put(uint(1)); // uses liquids (water), and three bytes of padding
    w.putBytes(data);
    write(buildPath(dir, format!"%03d%02d%02d.mmtile"(mapId, gx, gy)), w.data);
}

// Each worker thread's own: the models it has read, and its maps' building trees.
private ModelCache workerModels;
private StaticMapTree[uint] workerTrees;

/// A tile's Detour data, or null if nothing on it is walkable.
ubyte[] buildGridTile(string mapsDir, string vmapsDir, uint mapId, int gx, int gy)
{
    Vector3[] vertices;
    int[] triangles;
    NavArea[] areas;

    addTerrain(mapsDir, mapId, gx, gy, vertices, triangles, areas);
    addBuildings(vmapsDir, mapId, gx, gy, vertices, triangles, areas);
    if (areas.length == 0)
        return null;

    BuildConfig config;
    gridTileBounds(gx, gy, config.bmin, config.bmax);
    const meshTile = meshTileOf(gx, gy);
    config.tileX = meshTile[0];
    config.tileY = meshTile[1];
    return buildTile(config, vertices, triangles, areas);
}

/**
 * The terrain of tile [gx, gy], and `border` squares of its neighbours: each square four triangles
 * from its corners to its centre (`TerrainBuilder::getHeightTriangle`).
 */
private void addTerrain(string mapsDir, uint mapId, int gx, int gy, ref Vector3[] vertices, ref int[] triangles,
    ref NavArea[] areas)
{
    enum border = 4; // squares of 4.17 yards: more than Recast's border of 5 cells of 0.27
    GridMap[int[2]] grids;
    GridMap gridAt(int x, int y)
    {
        if (auto g = [x, y] in grids)
            return *g;
        GridMap g;
        const path = buildPath(mapsDir, format!"%03d%02d%02d.map"(mapId, x, y));
        if (x >= 0 && y >= 0 && x < 64 && y < 64 && exists(path))
            g = new GridMap(cast(const(ubyte)[]) read(path), path);
        grids[[x, y]] = g;
        return g;
    }

    enum float square = gridTileSize / 128;
    // Squares by their index across the whole map: row r of tile gx is gx * 128 + r.
    foreach (row; gx * 128 - border .. (gx + 1) * 128 + border)
        foreach (col; gy * 128 - border .. (gy + 1) * 128 + border)
        {
            const tx = row >= 0 ? row / 128 : -1, ty = col >= 0 ? col / 128 : -1;
            auto grid = gridAt(tx, ty);
            if (grid is null)
                continue;
            const r = row - tx * 128, c = col - ty * 128;
            if (grid.isHole(r, c))
                continue;
            // World x falls as the row grows, world y as the column does.
            float xAt(int rr) { return gridTileSize * 32 - (tx * 128 + rr) * square; }
            float yAt(int cc) { return gridTileSize * 32 - (ty * 128 + cc) * square; }
            const corner = (int rr, int cc) => Vector3(xAt(rr), yAt(cc), grid.cornerHeight(rr, cc));
            const a = corner(r, c), b = corner(r + 1, c), d = corner(r, c + 1), e = corner(r + 1, c + 1);
            const centre = Vector3((a.x + b.x) / 2, (a.y + d.y) / 2, grid.centreHeight(r, c));

            // Ground deeper under water than a creature can stand in is swum across.
            NavArea area = NavArea.ground;
            const level = grid.liquidLevel(centre.x, centre.y);
            if (level > -500 && level - centre.z > swimDepth)
                area = NavArea.water;

            const base = cast(int) vertices.length;
            vertices ~= [a, b, d, e, centre];
            enum ia = 0, ib = 1, id = 2, ie = 3, ic = 4;
            foreach (t; [[ia, ib, ic], [ib, ie, ic], [ie, id, ic], [id, ia, ic]])
                addFacingUp(vertices, triangles, areas, base + t[0], base + t[1], base + t[2], area);
        }
}

/// Adds a triangle wound so that its normal points up (Recast's `rcClearUnwalkableTriangles` needs it).
private void addFacingUp(const(Vector3)[] vertices, ref int[] triangles, ref NavArea[] areas, int i0, int i1,
    int i2, NavArea area)
{
    const p0 = toRecast(vertices[i0]), p1 = toRecast(vertices[i1]), p2 = toRecast(vertices[i2]);
    // The normal's y (up) in Recast's axes: (p1 - p0) x (p2 - p0).
    const ny = (p1[2] - p0[2]) * (p2[0] - p0[0]) - (p1[0] - p0[0]) * (p2[2] - p0[2]);
    if (ny >= 0)
        triangles ~= [i0, i1, i2];
    else
        triangles ~= [i0, i2, i1];
    areas ~= area;
}

/**
 * The buildings and doodads tile [gx, gy]'s vmap file lists, placed in the world (`ModelInstance`'s
 * transform, then out of the trees' internal coordinates). Their floors face up as they are.
 */
private void addBuildings(string vmapsDir, uint mapId, int gx, int gy, ref Vector3[] vertices, ref int[] triangles,
    ref NavArea[] areas)
{
    if (!StaticMapTree.exists(mapId, vmapsDir))
        return;
    if (workerModels is null)
        workerModels = new ModelCache(vmapsDir);
    auto tree = workerTrees.get(mapId, null);
    if (tree is null)
    {
        tree = new StaticMapTree(mapId, vmapsDir, workerModels);
        workerTrees[mapId] = tree;
    }
    foreach (ref instance; tree.tileInstances(gx, gy))
    {
        foreach (group; instance.model.groups)
        {
            if (group.triangles.length == 0)
                continue;
            const base = cast(int) vertices.length;
            foreach (v; group.vertices)
            {
                const placed = (v * instance.invRot) * instance.spawn.scale + instance.spawn.pos;
                vertices ~= toInternal(placed.x, placed.y, placed.z);
            }
            // Mirrored out of the internal coordinates (x and y both negated keeps the handedness).
            foreach (t; group.triangles)
            {
                triangles ~= [base + t.idx0, base + t.idx1, base + t.idx2];
                areas ~= NavArea.ground;
            }
        }
    }
}

// A flat tile of terrain with a hole in one cell: walkable round it, not in it.
unittest
{
    import std.file : rmdirRecurse, tempDir;
    import std.process : thisProcessID;
    import dmangos.extractor.maps : buildTestAdt, convertAdt, TestTerrain;

    const dir = buildPath(tempDir, "dmangos-mmaps-" ~ thisProcessID.to!string);
    mkdirRecurse(buildPath(dir, "maps"));
    scope (exit)
        rmdirRecurse(dir);
    TestTerrain flat;
    flat.height = (float, float) => 42.0f;
    flat.areaId = (int, int) => 0;
    flat.holes[[5, 5]] = 0xFFFF;
    string problem;
    const ushort[uint] noFlags;
    write(buildPath(dir, "maps", "0013030.map"), convertAdt(buildTestAdt(flat), noFlags, problem));
    const data = buildGridTile(buildPath(dir, "maps"), buildPath(dir, "vmaps"), 1, 30, 30);
    assert(data.length > 0);

    auto mesh = new NavMesh;
    scope (exit)
        mesh.close();
    const t = meshTileOf(30, 30);
    assert(mesh.addTile(t[0], t[1], data));
    // Tile [30, 30] spans world x and y from 533 to 1067; row and column grow as x and y fall.
    float z;
    assert(mesh.height(Vector3(800, 800, 42), z) && z > 41 && z < 43);
    const path = mesh.findPath(Vector3(1000, 1000, 42), Vector3(600, 1000, 42));
    assert(path.points.length == 2 && !path.partial, "flat ground: straight across");
    // Cell [5, 5] is squares 40 to 47 each way: world x and y from 1067 - 47 * 4.17 to 1067 - 40 * 4.17.
    const holeCentre = 1066.6667f - 43.5f * (gridTileSize / 128);
    assert(!mesh.height(Vector3(holeCentre, holeCentre, 42), z), "no ground in the hole");
}
