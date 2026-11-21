/**
 * The ground of each map, from the extractor's `.map` files:
 * heights, areas, liquids and holes, per 533-yard tile.
 *
 * `GridMap` is one tile, read from `<data_dir>/maps/MMMXXYY.map`: `height` interpolates the
 * triangle of the terrain square the point is in, `areaFlag`
 * gives the cell's `AreaTable.dbc` explore flag, and `liquidStatus` whether a point is above, on,
 * in or under water. `Terrain` is the tiles of one map (and its buildings), loaded the first
 * time something asks about them, and the questions answered for the map (zone and area ids, the
 * height under a point).
 *
 * Without vmaps, heights come from the terrain alone: inside buildings and in caves the ground
 * found is the terrain above or below. A tile without a file (no data extracted, or an instance
 * with none) has no height (`invalidHeightValue`), and its area is the map's own.
 */
module dmangos.world.terrain;

import core.time : Duration, MonoTime;
import dmangos.navigation : NavMesh;
import dmangos.vmap.math : Vector3;
import std.bitmanip : littleEndianToNative;
import std.math : abs, isNaN;
import std.file : exists, read;
import std.format : format;
import std.path : buildPath;

import dmangos.log;
import dmangos.mapfile;
import dmangos.vmap.maptree : liquidLevel, LocationInfo, ModelCache, StaticMapTree, toInternal, vmapInvalidHeightValue;
import dmangos.world.clientdata : AreaTableEntry, ClientData;

/// A tile's side, in yards.
enum float sizeOfGrids = 533.33333f;

/// Tiles per map side; the map's centre is tile 32.
enum maxNumberOfGrids = 64;

/// Terrain squares per tile side.
enum mapResolution = 128;

/// Heights at or below this are "none found".
enum float invalidHeight = -100_000.0f;

/// What a lookup that finds nothing returns.
enum float invalidHeightValue = -200_000.0f;

/// Where a point is relative to the liquid there.
enum LiquidStatus : uint
{
    noWater = 0x0,
    aboveWater = 0x1,
    waterWalk = 0x2,
    inWater = 0x4,
    underWater = 0x8,
}

/// The liquid at a point: its type flags, `LiquidType.dbc` entry, surface and bottom.
struct LiquidData
{
    uint typeFlags;
    uint entry;
    float level = 0;
    float depthLevel = 0;
}

/// The tile a point is on: x and y indexes, 0 .. 63.
int[2] tileOf(float x, float y) pure nothrow @nogc @safe
{
    return [cast(int)(32 - x / sizeOfGrids), cast(int)(32 - y / sizeOfGrids)];
}

private immutable ushort[4] holeTabH = [0x1111, 0x2222, 0x4444, 0x8888];
private immutable ushort[4] holeTabV = [0x000F, 0x00F0, 0x0F00, 0xF000];

/// One tile; see the module documentation.
final class GridMap
{
    private
    {
        ushort[16 * 16] holes;
        ushort gridArea;
        ushort[] areaMap;          // 16 x 16, or null for one area
        float gridHeight = invalidHeightValue;
        float heightMultiplier = 0; // to unpack byte and short heights
        HeightFormat heightFormat = HeightFormat.flat;
        float[] v9, v8;
        ushort[] v9Short, v8Short;
        ubyte[] v9Byte, v8Byte;
        ushort liquidGlobalEntry;
        ubyte liquidGlobalFlags;
        ubyte liquidOffX, liquidOffY, liquidWidth, liquidHeight;
        float liquidLevelGlobal = invalidHeightValue;
        ushort[] liquidEntries;    // 16 x 16, or null
        ubyte[] liquidFlags;       // 16 x 16, or null
        float[] liquidMap;         // liquidHeight x liquidWidth, or null
    }

    private enum HeightFormat
    {
        flat,
        floats,
        shorts,
        bytes,
    }

    /**
     * A tile from the file's bytes. Throws for a file of another version or a
     * damaged one; `Terrain` logs that and goes without the tile.
     */
    this(const(ubyte)[] file, string name)
    {
        auto r = Reader(file, name);
        if (r.word(0) != mapMagic || r.word(4) != mapVersionMagic)
            throw new Exception(format!"map file '%s' is not version z1.4; extract the maps again"(name));
        const areaOffset = r.word(8), heightOffset = r.word(16), liquidOffset = r.word(24),
            holesOffset = r.word(32);

        if (areaOffset)
        {
            r.expect(areaOffset, mapAreaMagic, "area");
            gridArea = r.get!ushort(areaOffset + 6);
            if (!(r.get!ushort(areaOffset + 4) & mapAreaNoArea))
                areaMap = r.array!ushort(areaOffset + 8, 16 * 16);
        }
        if (holesOffset)
            holes[] = r.array!ushort(holesOffset, 16 * 16);
        if (heightOffset)
        {
            r.expect(heightOffset, mapHeightMagic, "height");
            const flags = r.word(heightOffset + 4);
            gridHeight = r.get!float(heightOffset + 8);
            const maxHeight = r.get!float(heightOffset + 12);
            const data = heightOffset + 16;
            if (flags & mapHeightNoHeight)
                heightFormat = HeightFormat.flat;
            else if (flags & mapHeightAsInt16)
            {
                v9Short = r.array!ushort(data, 129 * 129);
                v8Short = r.array!ushort(data + 129 * 129 * 2, 128 * 128);
                heightMultiplier = (maxHeight - gridHeight) / 65_535;
                heightFormat = HeightFormat.shorts;
            }
            else if (flags & mapHeightAsInt8)
            {
                v9Byte = r.array!ubyte(data, 129 * 129);
                v8Byte = r.array!ubyte(data + 129 * 129, 128 * 128);
                heightMultiplier = (maxHeight - gridHeight) / 255;
                heightFormat = HeightFormat.bytes;
            }
            else
            {
                v9 = r.array!float(data, 129 * 129);
                v8 = r.array!float(data + 129 * 129 * 4, 128 * 128);
                heightFormat = HeightFormat.floats;
            }
        }
        if (liquidOffset)
        {
            r.expect(liquidOffset, mapLiquidMagic, "liquid");
            const flags = r.get!ubyte(liquidOffset + 4);
            liquidGlobalFlags = r.get!ubyte(liquidOffset + 5);
            liquidGlobalEntry = r.get!ushort(liquidOffset + 6);
            liquidOffX = r.get!ubyte(liquidOffset + 8);
            liquidOffY = r.get!ubyte(liquidOffset + 9);
            liquidWidth = r.get!ubyte(liquidOffset + 10);
            liquidHeight = r.get!ubyte(liquidOffset + 11);
            liquidLevelGlobal = r.get!float(liquidOffset + 12);
            size_t next = liquidOffset + 16;
            if (!(flags & mapLiquidNoType))
            {
                liquidEntries = r.array!ushort(next, 16 * 16);
                liquidFlags = r.array!ubyte(next + 16 * 16 * 2, 16 * 16);
                next += 16 * 16 * 3;
            }
            if (!(flags & mapLiquidNoHeight))
                liquidMap = r.array!float(next, liquidWidth * liquidHeight);
        }
    }

    /// The explore flag of the cell the point is in.
    ushort areaFlag(float x, float y) const
    {
        if (areaMap is null)
            return gridArea;
        const lx = cast(int)(16 * (32 - x / sizeOfGrids)) & 15;
        const ly = cast(int)(16 * (32 - y / sizeOfGrids)) & 15;
        return areaMap[lx * 16 + ly];
    }

    /// The terrain's height at the point; `invalidHeightValue` in a hole.
    float height(float x, float y) const
    {
        final switch (heightFormat)
        {
        case HeightFormat.flat:
            return gridHeight;
        case HeightFormat.floats:
            return heightFromFloat(x, y);
        case HeightFormat.shorts:
            return heightFromPacked(v9Short, v8Short, x, y);
        case HeightFormat.bytes:
            return heightFromPacked(v9Byte, v8Byte, x, y);
        }
    }

    /// The liquid's surface height at the point.
    float liquidLevel(float x, float y) const
    {
        if (liquidMap is null)
            return liquidLevelGlobal;
        const cx = (cast(int)(mapResolution * (32 - x / sizeOfGrids)) & (mapResolution - 1)) - liquidOffY;
        const cy = (cast(int)(mapResolution * (32 - y / sizeOfGrids)) & (mapResolution - 1)) - liquidOffX;
        if (cx < 0 || cx >= liquidHeight || cy < 0 || cy >= liquidWidth)
            return invalidHeightValue;
        return liquidMap[cx * liquidWidth + cy];
    }

    /// The liquid flags of the cell (`MAP_LIQUID_TYPE_*`).
    ubyte terrainType(float x, float y) const
    {
        if (liquidFlags is null)
            return liquidGlobalFlags;
        const lx = cast(int)(16 * (32 - x / sizeOfGrids)) & 15;
        const ly = cast(int)(16 * (32 - y / sizeOfGrids)) & 15;
        return liquidFlags[lx * 16 + ly];
    }

    /**
     * Where a point at height `z` is relative to the liquid there.
     * `requiredType` (`MAP_LIQUID_TYPE_*` bits, 0 for any) narrows which liquids count.
     */
    LiquidStatus liquidStatus(float x, float y, float z, ubyte requiredType, const ClientData client,
        out LiquidData data, float collisionHeight = 2.03128f) const
    {
        if (liquidFlags is null && liquidGlobalFlags == 0)
            return LiquidStatus.noWater;
        const xInt = cast(int)(mapResolution * (32 - x / sizeOfGrids)) & (mapResolution - 1);
        const yInt = cast(int)(mapResolution * (32 - y / sizeOfGrids)) & (mapResolution - 1);
        const index = (xInt >> 3) * 16 + (yInt >> 3);
        uint type = liquidFlags !is null ? liquidFlags[index] : liquidGlobalFlags;
        uint entry = liquidEntries !is null ? liquidEntries[index] : liquidGlobalEntry;
        if (const liquid = client.liquidTypes.lookup(entry))
        {
            entry = liquid.id;
            type &= mapLiquidTypeDeepWater;
            uint typeIndex = liquid.type;
            // An area may make its water another liquid (AreaTable's LiquidTypeOverride). The area is
            // looked up by the cell's explore flag taken as an area id.
            if (entry < 21)
                if (auto area = client.areas.lookup(areaFlag(x, y)))
                {
                    uint overrideLiquid = area.liquidTypeOverride;
                    if (!overrideLiquid && area.zone)
                        if (const zone = client.areas.lookup(area.zone))
                            overrideLiquid = zone.liquidTypeOverride;
                    if (const other = client.liquidTypes.lookup(overrideLiquid))
                    {
                        entry = overrideLiquid;
                        typeIndex = other.type;
                    }
                }
            type |= 1 << typeIndex;
        }
        if (type == 0 || (requiredType && !(requiredType & type)))
            return LiquidStatus.noWater;

        const lx = xInt - liquidOffY, ly = yInt - liquidOffX;
        if (lx < 0 || lx >= liquidHeight || ly < 0 || ly >= liquidWidth)
            return LiquidStatus.noWater;
        const level = liquidMap !is null ? liquidMap[lx * liquidWidth + ly] : liquidLevelGlobal;
        const ground = height(x, y);
        if (level < ground || z < ground - 2)
            return LiquidStatus.noWater;
        data = LiquidData(type, entry, level, ground);
        const delta = level - z;
        if (delta > collisionHeight)
            return LiquidStatus.underWater;
        if (delta > 0)
            return LiquidStatus.inWater;
        if (delta > -1)
            return LiquidStatus.waterWalk;
        return LiquidStatus.aboveWater;
    }

private:
    /// The point's square, and where in it the point is (both from 0 to 1).
    static void squareOf(float x, float y, out int xInt, out int yInt, out float fx, out float fy)
    {
        fx = mapResolution * (32 - x / sizeOfGrids);
        fy = mapResolution * (32 - y / sizeOfGrids);
        xInt = cast(int) fx;
        yInt = cast(int) fy;
        fx -= xInt;
        fy -= yInt;
        xInt &= mapResolution - 1;
        yInt &= mapResolution - 1;
    }

    /**
     * The height at corner (row, col) of the tile's 128 x 128 squares (`V9`, 0 to 128) and at the
     * centre of square (row, col) (`V8`, 0 to 127): for building movement maps.
     */
    public float cornerHeight(int row, int col) const
    in (row >= 0 && row <= 128 && col >= 0 && col <= 128)
    {
        final switch (heightFormat)
        {
        case HeightFormat.flat:
            return gridHeight;
        case HeightFormat.floats:
            return v9[row * 129 + col];
        case HeightFormat.shorts:
            return v9Short[row * 129 + col] * heightMultiplier + gridHeight;
        case HeightFormat.bytes:
            return v9Byte[row * 129 + col] * heightMultiplier + gridHeight;
        }
    }

    /// ditto
    public float centreHeight(int row, int col) const
    in (row >= 0 && row < 128 && col >= 0 && col < 128)
    {
        final switch (heightFormat)
        {
        case HeightFormat.flat:
            return gridHeight;
        case HeightFormat.floats:
            return v8[row * 128 + col];
        case HeightFormat.shorts:
            return v8Short[row * 128 + col] * heightMultiplier + gridHeight;
        case HeightFormat.bytes:
            return v8Byte[row * 128 + col] * heightMultiplier + gridHeight;
        }
    }

    /// Whether the terrain square at (`row`, `col`) is a hole.
    public bool isHole(int row, int col) const
    {
        const cellRow = row / 8, cellCol = col / 8;
        const holeRow = row % 8 / 2, holeCol = (col - cellCol * 8) / 2;
        return (holes[cellRow * 16 + cellCol] & holeTabH[holeCol] & holeTabV[holeRow]) != 0;
    }

    /**
     * The height from a tile of float heights. A square's corners are h1 .. h4 (V9) and its centre h5 (V8);
     * the four triangles between them each make a plane h = a*x + b*y + c.
     */
    float heightFromFloat(float x, float y) const
    {
        int xInt, yInt;
        float fx, fy;
        squareOf(x, y, xInt, yInt, fx, fy);
        if (isHole(xInt, yInt))
            return invalidHeightValue;
        const h1 = v9[xInt * 129 + yInt], h2 = v9[(xInt + 1) * 129 + yInt];
        const h3 = v9[xInt * 129 + yInt + 1], h4 = v9[(xInt + 1) * 129 + yInt + 1];
        const h5 = 2 * v8[xInt * 128 + yInt];
        float a, b, c;
        triangle(fx, fy, h1, h2, h3, h4, h5, a, b, c);
        return a * fx + b * fy + c;
    }

    /// The height from a tile of packed 8- or 16-bit heights; these do not look for holes.
    float heightFromPacked(T)(const(T)[] corners, const(T)[] centres, float x, float y) const
    {
        int xInt, yInt;
        float fx, fy;
        squareOf(x, y, xInt, yInt, fx, fy);
        const base = xInt * 129 + yInt;
        const int h1 = corners[base], h2 = corners[base + 129], h3 = corners[base + 1], h4 = corners[base + 130];
        const int h5 = 2 * centres[xInt * 128 + yInt];
        int a, b, c;
        triangle(fx, fy, h1, h2, h3, h4, h5, a, b, c);
        return cast(float)(a * fx + b * fy + c) * heightMultiplier + gridHeight;
    }

    /// The plane of the triangle the point (fx, fy) is in.
    static void triangle(T)(float fx, float fy, T h1, T h2, T h3, T h4, T h5, out T a, out T b, out T c)
    {
        if (fx + fy < 1)
        {
            if (fx > fy) // h1, h2, h5
            {
                a = h2 - h1;
                b = h5 - h1 - h2;
                c = h1;
            }
            else // h1, h3, h5
            {
                a = h5 - h1 - h3;
                b = h3 - h1;
                c = h1;
            }
        }
        else if (fx > fy) // h2, h4, h5
        {
            a = h2 + h4 - h5;
            b = h4 - h2;
            c = h5 - h4;
        }
        else // h3, h4, h5
        {
            a = h4 - h3;
            b = h3 + h4 - h5;
            c = h5 - h4;
        }
    }
}

/// How far down (and up) heights, and water, are looked for.
enum float defaultHeightSearch = 10.0f, defaultWaterSearch = 50.0f;

/// The building group a point is in.
struct BuildingArea
{
    uint flags;     /// the group's `mogpFlags`
    int adtId;      /// the placement's name set
    int rootId;     /// the building's WMO id
    int groupId;    /// the group's WMO id
    float floorZ = 0;
}

/// One map's tiles and buildings; see the module documentation.
final class Terrain
{
    immutable uint mapId;
    private
    {
        const ClientData client;
        string directory;               // <data_dir>/maps
        GridMap[maxNumberOfGrids * maxNumberOfGrids] tiles;
        bool[maxNumberOfGrids * maxNumberOfGrids] attempted;
        StaticMapTree vmap;             // null without vmaps
        NavMesh navigation;             // the movement maps, null without them
        string navDirectory;            // <data_dir>/mmaps
        int[2][] navPending;            // grid tiles whose movement map waits to be added (`addPendingNavigation`)
    }

    /**
     * The tiles are read from `<dataDir>/maps`, and the buildings, if `models` is given and the map
     * has them, from `<dataDir>/vmaps`.
     */
    this(uint mapId, string dataDir, const ClientData client, ModelCache models = null, bool movementMaps = true)
    {
        this.mapId = mapId;
        this.client = client;
        directory = buildPath(dataDir, "maps");
        // The map's movement maps, if it has them; their tiles come with the grids'.
        navDirectory = buildPath(dataDir, "mmaps");
        if (movementMaps && exists(buildPath(navDirectory, format!"%03d.mmap"(mapId))))
        {
            try
                navigation = new NavMesh;
            catch (Exception e)
                error!"movement maps of map %s not loaded: %s"(mapId, e.msg);
        }
        const vmapDirectory = buildPath(dataDir, "vmaps");
        if (models !is null && StaticMapTree.exists(mapId, vmapDirectory))
        {
            try
                vmap = new StaticMapTree(mapId, vmapDirectory, models);
            catch (Exception e)
                error!"vmaps of map %s not loaded: %s"(mapId, e.msg);
        }
    }

    /// Whether the map's buildings are loaded.
    @property bool hasVmaps() const
    {
        return vmap !is null;
    }

    /**
     * The tile the point is on, loaded with its
     * buildings if it was not; null if it has no `.map` file.
     */
    const(GridMap) tile(float x, float y)
    {
        const coords = tileOf(x, y);
        if (coords[0] < 0 || coords[0] >= maxNumberOfGrids || coords[1] < 0 || coords[1] >= maxNumberOfGrids)
            return null;
        const index = coords[0] * maxNumberOfGrids + coords[1];
        if (!attempted[index])
        {
            attempted[index] = true;
            const path = buildPath(directory, format!"%03d%02d%02d.map"(mapId, coords[0], coords[1]));
            if (exists(path))
            {
                try
                    tiles[index] = new GridMap(cast(const(ubyte)[]) read(path), path);
                catch (Exception e)
                    error!"%s"(e.msg);
            }
            if (vmap !is null)
                vmap.loadTile(coords[0], coords[1]);
            if (navigation !is null)
                navPending ~= coords;
        }
        return tiles[index];
    }

    /**
     * Adds the movement maps of the tiles loaded since, until `budget` is spent: adding one to the mesh
     * (Detour linking its polygons to its neighbours') takes about 3 ms, and an area coming into use
     * loads many at once. Until a tile's is added, units there walk straight. Returns how many wait.
     */
    size_t addPendingNavigation(Duration budget)
    {
        if (navPending.length == 0)
            return 0;
        const until = MonoTime.currTime + budget;
        size_t done;
        while (done < navPending.length)
        {
            loadNavigationTile(navPending[done][0], navPending[done][1]);
            ++done;
            if (MonoTime.currTime >= until)
                break;
        }
        navPending = navPending[done .. $];
        if (navPending.length == 0)
            navPending = null;
        return navPending.length;
    }

    /// Loads grid tile [gx, gy]'s movement map (`MMMXXYY.mmtile`), if there is one.
    private void loadNavigationTile(int gx, int gy)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.navigation : meshTileOf;

        const path = buildPath(navDirectory, format!"%03d%02d%02d.mmtile"(mapId, gx, gy));
        if (!exists(path))
            return;
        try
        {
            const bytes = cast(const(ubyte)[]) read(path);
            auto r = ByteReader(bytes);
            enum uint magic = 0x4D4D4150, detourVersion = 7, formatVersion = 1;
            if (r.read!uint != magic || r.read!uint != detourVersion || r.read!uint != formatVersion)
                return error!"movement map %s is of another version: run the extractor with -e 8 again"(path);
            const size = r.read!uint;
            r.read!uint;
            if (20 + size > bytes.length)
                return error!"movement map %s is cut short"(path);
            const t = meshTileOf(gx, gy);
            if (!navigation.addTile(t[0], t[1], bytes[20 .. 20 + size]))
                error!"movement map %s was refused by Detour"(path);
        }
        catch (Exception e)
            error!"movement map %s: %s"(path, e.msg);
    }

    /**
     * The way from `from` to `to` over the movement maps, its corners from
     * `from` on; empty if the map has none there, or either end is off them (the caller then walks
     * straight). An unreachable end gives the way to the nearest place to it.
     */
    Vector3[] pathBetween(Vector3 from, Vector3 to)
    {
        if (navigation is null)
            return null;
        tile(from.x, from.y); // the tiles under both ends, loaded
        tile(to.x, to.y);
        return navigation.findPath(from, to).points;
    }

    /// Whether the map has movement maps.
    @property bool hasMovementMaps() const
    {
        return navigation !is null;
    }

    /// Whether anything is known about the point: a tile, buildings, or an area of the map's own.
    bool knows(float x, float y)
    {
        return tile(x, y) !is null || vmap !is null || client.areaFlagOfMap(mapId) != 0;
    }

    /// The terrain's height at the point, buildings left out; `invalidHeightValue` if unknown.
    float height(float x, float y)
    {
        if (const grid = tile(x, y))
            return grid.height(x, y);
        return invalidHeightValue;
    }

    /**
     * The ground under (or a little above) the point at height `z`:
     * the terrain, or a building's floor, bridge or roof, whichever the point stands on.
     */
    float heightStatic(float x, float y, float z, bool useVmaps = true, float maxSearchDist = defaultHeightSearch)
    {
        const mapHeight = height(x, y);
        float vmapHeight = vmapInvalidHeightValue;
        if (useVmaps && vmap !is null)
        {
            const z2 = z + 2.0f;
            // With the terrain known, search at least down to it, so a point far above the ground finds it.
            if (mapHeight > invalidHeight && z2 - mapHeight > maxSearchDist)
                maxSearchDist = z2 - mapHeight + 1.0f;
            vmapHeight = buildingHeight(x, y, z2, maxSearchDist);
            if (vmapHeight <= invalidHeight)
                vmapHeight = buildingHeight(x, y, z2, 10_000.0f);
            if (vmapHeight <= invalidHeight && mapHeight > z2 && abs(z2 - mapHeight) > 30)
                vmapHeight = buildingHeight(x, y, z2, -maxSearchDist); // upwards
            if (vmapHeight <= invalidHeight && mapHeight > invalidHeight && z2 < mapHeight)
                vmapHeight = buildingHeight(x, y, mapHeight + 2.0f, defaultHeightSearch);
        }
        if (vmapHeight > invalidHeight)
        {
            // Under the terrain already, or a building above it: the building's.
            if (mapHeight > invalidHeight && !(z < mapHeight || vmapHeight > mapHeight))
                return mapHeight;
            return vmapHeight;
        }
        return mapHeight;
    }

    /**
     * The building group the point is in, unless terrain lies between
     * the point and the group's floor.
     */
    bool buildingArea(float x, float y, float z, out BuildingArea area)
    {
        if (vmap is null)
            return false;
        tile(x, y);
        LocationInfo info;
        if (!vmap.locate(toInternal(x, y, z), info))
            return false;
        if (const grid = tile(x, y))
        {
            const mapHeight = grid.height(x, y);
            if (z + 2.0f > mapHeight && mapHeight > info.groundZ)
                return false;
        }
        area = BuildingArea(info.group.mogpFlags, info.adtId, info.rootId, info.group.groupWmoId, info.groundZ);
        return true;
    }

    /// Outdoors is outside any building, or in an outdoor part of one.
    /// The vmap height under `z`, searching `maxSearchDist` down.
    float vmapHeight(float x, float y, float z, float maxSearchDist = 10_000.0f)
    {
        return vmap is null ? vmapInvalidHeightValue : buildingHeight(x, y, z, maxSearchDist);
    }

    bool isOutdoors(float x, float y, float z)
    {
        BuildingArea area;
        return !buildingArea(x, y, z, area) || (area.flags & 0x8000) != 0;
    }

    /**
     * The point's explore flag: a building group's area (from
     * `WMOAreaTable.dbc`) if it is in one with an area on this map, else the land's, else the map's own.
     */
    ushort areaFlag(float x, float y, float z)
    {
        BuildingArea building;
        if (buildingArea(x, y, z, building))
        {
            const(AreaTableEntry)* found;
            foreach (entry; client.wmoAreasOf(building.rootId, building.adtId, building.groupId))
                if (const area = client.areas.lookup(entry.areaId))
                    if (area.mapId == mapId)
                        found = area;
            if (found !is null)
                return cast(ushort) found.exploreFlag;
        }
        if (const grid = tile(x, y))
            return grid.areaFlag(x, y);
        return cast(ushort) client.areaFlagOfMap(mapId);
    }

    /// The point's [zone, area], 0 for unknown.
    uint[2] zoneAndArea(float x, float y, float z)
    {
        const area = client.areaByFlag(areaFlag(x, y, z), mapId);
        if (area is null)
            return [0, 0];
        return [area.zone ? area.zone : area.id, area.id];
    }

    /**
     * Whether nothing built stands between the two points; doodads (trees,
     * barrels) left out with `ignoreM2`. Without vmaps everything is in sight.
     */
    bool isInLineOfSight(float x1, float y1, float z1, float x2, float y2, float z2, bool ignoreM2 = false)
    {
        if (vmap is null)
            return true;
        tile(x1, y1);
        tile(x2, y2);
        const from = toInternal(x1, y1, z1), to = toInternal(x2, y2, z2);
        return from == to || vmap.isInLineOfSight(from, to, ignoreM2);
    }

    /**
     * Where the point is relative to liquid: water in a building first, then the land's. `data` is filled
     * when the point is in, on or above some.
     */
    LiquidStatus liquidStatus(float x, float y, float z, ubyte requiredType, out LiquidData data,
        float collisionHeight = 2.03128f)
    {
        const ground = heightStatic(x, y, z, true, defaultWaterSearch);
        float level, floor;
        uint type;
        tile(x, y);
        if (vmap !is null && .liquidLevel(vmap, x, y, z, requiredType, level, floor, type))
        {
            if (!(level > floor && z > floor - 2))
                return LiquidStatus.noWater;
            uint flagType;
            if (const liquid = client.liquidTypes.lookup(type))
                flagType = liquid.type;
            if (type && type < 21)
                if (auto area = client.areaByFlag(areaFlag(x, y, z), mapId))
                {
                    uint overrideLiquid = area.liquidTypeOverride;
                    if (!overrideLiquid && area.zone)
                        if (const zone = client.areas.lookup(area.zone))
                            overrideLiquid = zone.liquidTypeOverride;
                    if (const other = client.liquidTypes.lookup(overrideLiquid))
                    {
                        type = overrideLiquid;
                        flagType = other.type;
                    }
                }
            data = LiquidData(1u << flagType, type, level, floor);
            const delta = level - z;
            if (delta > collisionHeight)
                return LiquidStatus.underWater;
            if (delta > 0)
                return LiquidStatus.inWater;
            if (delta > -1)
                return LiquidStatus.waterWalk;
            return LiquidStatus.aboveWater;
        }
        if (const grid = tile(x, y))
        {
            LiquidData found;
            const status = grid.liquidStatus(x, y, z, requiredType, client, found, collisionHeight);
            // Water below a building's floor is not the point's. A building found (without water)
            // gives its floor.
            const under = isNaN(floor) ? ground : floor;
            if (status != LiquidStatus.noWater && found.level > under)
            {
                data = found;
                return status;
            }
        }
        return LiquidStatus.noWater;
    }

private:
    /// A building's surface below `z` (above, if `maxSearchDist` is negative).
    float buildingHeight(float x, float y, float z, float maxSearchDist)
    {
        tile(x, y);
        const h = vmap.height(toInternal(x, y, z), maxSearchDist);
        return h < float.infinity ? h : vmapInvalidHeightValue;
    }
}

/// Bounds-checked little-endian reads from a `.map` file.
private struct Reader
{
    const(ubyte)[] data;
    string name;

    T get(T)(size_t offset) const
    {
        if (offset + T.sizeof > data.length)
            throw new Exception(format!"map file '%s' is truncated"(name));
        return data[offset .. offset + T.sizeof][0 .. T.sizeof].littleEndianToNative!T;
    }

    uint word(size_t offset) const
    {
        return get!uint(offset);
    }

    T[] array(T)(size_t offset, size_t count) const
    {
        auto values = new T[count];
        foreach (i, ref value; values)
            value = get!T(offset + i * T.sizeof);
        return values;
    }

    void expect(size_t offset, uint magic, string part) const
    {
        if (word(offset) != magic)
            throw new Exception(format!"map file '%s': damaged %s data"(name, part));
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import std.math : isClose;
    import dmangos.extractor.maps : buildTestAdt, convertAdt, TestTerrain;

    /// A world position on tile [tileX, tileY] at fractional square (row, column), as a tile counts them.
    float[2] pointAt(int tileX, int tileY, float row, float column)
    {
        return [sizeOfGrids * (32 - (mapResolution * tileX + row) / mapResolution),
            sizeOfGrids * (32 - (mapResolution * tileY + column) / mapResolution)];
    }
}

/// Heights between the points, areas per cell, holes and water, read back from the extractor's files.
unittest
{
    import dmangos.world.testdata : testClientData;

    const client = testClientData();
    const ushort[uint] flags = [12: 5, 40: 7];
    string problem;

    // A plane, stored as shorts: any point lies on it.
    TestTerrain slope;
    slope.height = (row, column) => row + column / 2;
    slope.areaId = (i, j) => i == 0 && j == 0 ? 12 : 40;
    slope.waterLevel[[2, 3]] = 100;
    auto tile = new GridMap(convertAdt(buildTestAdt(slope), flags, problem), "slope");
    foreach (rc; [[0.25f, 0.5f], [17.9f, 3.1f], [100.5f, 127.75f], [5.0f, 5.0f]])
    {
        const p = pointAt(30, 40, rc[0], rc[1]);
        assert(isClose(tile.height(p[0], p[1]), rc[0] + rc[1] / 2, 0, 0.01), "on the plane");
    }
    auto p = pointAt(30, 40, 3, 3);
    assert(tile.areaFlag(p[0], p[1]) == 5);
    p = pointAt(30, 40, 3, 9);
    assert(tile.areaFlag(p[0], p[1]) == 7, "the next cell's area");

    // The water of cell [2, 3] stands at 100 over ground near 26.
    p = pointAt(30, 40, 20, 28);
    LiquidData water;
    assert(tile.liquidLevel(p[0], p[1]) == 100);
    assert(tile.liquidStatus(p[0], p[1], 95, 0, client, water) == LiquidStatus.underWater);
    assert(water.level == 100 && water.typeFlags == mapLiquidTypeWater && isClose(water.depthLevel, 34, 0, 0.01));
    assert(tile.liquidStatus(p[0], p[1], 99, 0, client, water) == LiquidStatus.inWater);
    assert(tile.liquidStatus(p[0], p[1], 100.5f, 0, client, water) == LiquidStatus.waterWalk);
    assert(tile.liquidStatus(p[0], p[1], 120, 0, client, water) == LiquidStatus.aboveWater);
    assert(tile.liquidStatus(p[0], p[1], 99, mapLiquidTypeMagma, client, water) == LiquidStatus.noWater);
    p = pointAt(30, 40, 60, 60);
    assert(tile.liquidStatus(p[0], p[1], 50, 0, client, water) == LiquidStatus.noWater, "a dry cell");

    // A steep plane is kept as floats, where holes count: cell [1, 1]'s first quarter is one.
    TestTerrain steep;
    steep.height = (row, column) => 20 * row;
    steep.areaId = (i, j) => 40;
    steep.holes[[1, 1]] = 0x0001;
    tile = new GridMap(convertAdt(buildTestAdt(steep), flags, problem), "steep");
    p = pointAt(30, 40, 50.5f, 70.5f);
    assert(isClose(tile.height(p[0], p[1]), 1010, 0, 0.01));
    p = pointAt(30, 40, 8.5f, 8.5f);
    assert(tile.height(p[0], p[1]) == invalidHeightValue, "a hole");
    assert(tile.areaFlag(p[0], p[1]) == 7, "one area for the tile");

    // Another version is refused.
    auto other = convertAdt(buildTestAdt(steep), flags, problem);
    other[7] = '5';
    bool refused;
    try
        new GridMap(other, "old");
    catch (Exception)
        refused = true;
    assert(refused);
}

/// `Terrain` loads a map's tiles from data_dir/maps and names their zone and area.
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import dmangos.world.testdata;

    const client = testClientData();
    const dir = buildPath(tempDir, "dmangos-terrain-test");
    scope (exit)
        rmdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "maps"));

    TestTerrain land;
    land.height = (row, column) => 42.0f;
    land.areaId = (i, j) => i < 8 ? zoneElwynn : areaGoldshire;
    string problem;
    const ushort[uint] flags = [zoneElwynn: exploreElwynn, areaGoldshire: exploreGoldshire];
    write(buildPath(dir, "maps", "0003040.map"), convertAdt(buildTestAdt(land), flags, problem));

    auto terrain = new Terrain(mapEasternKingdoms, dir, client);
    auto p = pointAt(30, 40, 10, 10);
    assert(tileOf(p[0], p[1]) == [30, 40] && terrain.height(p[0], p[1]) == 42);
    assert(terrain.zoneAndArea(p[0], p[1], 42) == [zoneElwynn, zoneElwynn]);
    p = pointAt(30, 40, 100, 10);
    assert(terrain.zoneAndArea(p[0], p[1], 42) == [zoneElwynn, areaGoldshire], "an area names its zone");
    p = pointAt(31, 40, 10, 10);
    assert(terrain.tile(p[0], p[1]) is null && terrain.height(p[0], p[1]) == invalidHeightValue, "no file");
}

/// Builds a 10 x 10 house with a wall across its middle, for collision tests.
version (unittest)
void writeTestHouseVmaps(string dir)
{
    import std.file : mkdirRecurse, write;
    import dmangos.bytes : ByteWriter;
    import dmangos.extractor.assembler : assembleVmaps;
    import dmangos.vmap.math : putBox, putVector, Vector3, AABox;
    import dmangos.vmap.model : modHasBound, putTag, rawVmapMagic;
    import dmangos.world.testdata;

    mkdirRecurse(buildPath(dir, "Buildings"));

    // A 10 x 10 house, 5 high: a floor, a roof, and a wall across its middle at x = 5. Indoors (0x2000).
    const Vector3[] corners = [
        Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(0, 10, 0), Vector3(10, 10, 0),   // floor
        Vector3(0, 0, 5), Vector3(10, 0, 5), Vector3(0, 10, 5), Vector3(10, 10, 5),   // roof
        Vector3(5, 0, 0), Vector3(5, 10, 0), Vector3(5, 0, 5), Vector3(5, 10, 5),     // wall
    ];
    const ushort[] indexes = [0, 1, 2, 1, 3, 2, 4, 5, 6, 5, 7, 6, 8, 9, 10, 9, 11, 10];
    ByteWriter raw;
    putTag(raw, rawVmapMagic);
    raw.put(cast(uint)(indexes.length / 3));
    raw.put(1u);
    raw.put(cast(uint) testHouseRoot);
    raw.put(0x2000u);
    raw.put(cast(uint) testHouseGroup);
    putBox(raw, AABox(Vector3(0, 0, 0), Vector3(10, 10, 5)));
    raw.put(0u);                        // no liquid
    putTag(raw, "GRP ");
    raw.put(8u);
    raw.put(1u);
    raw.put(0u);
    putTag(raw, "INDX");
    raw.put(cast(uint)(4 + 2 * indexes.length));
    raw.put(cast(uint) indexes.length);
    foreach (i; indexes)
        raw.put(i);
    putTag(raw, "VERT");
    raw.put(cast(uint)(4 + 12 * corners.length));
    raw.put(cast(uint) corners.length);
    foreach (c; corners)
        putVector(raw, c);
    write(buildPath(dir, "Buildings", "house.wmo"), raw.data);

    // Placed at internal (16000, 16100, 50): grid tile [30, 30], whose ADT is listed as x 30, y 30.
    const pos = Vector3(16000, 16100, 50);
    ByteWriter dirBin;
    foreach (v; [0u, 30, 30, modHasBound])
        dirBin.put(v);
    dirBin.put(cast(ushort) testHouseNameSet);
    dirBin.put(1u);                     // id
    putVector(dirBin, pos);
    putVector(dirBin, Vector3(0, 0, 0));
    dirBin.put(1.0f);
    putBox(dirBin, AABox(pos, pos + Vector3(10, 10, 5)));
    dirBin.put(cast(uint) "house.wmo".length);
    dirBin.putBytes(cast(const(ubyte)[]) "house.wmo");
    write(buildPath(dir, "Buildings", "dir_bin"), dirBin.data);

    const report = assembleVmaps(dir);
    assert(report.maps == 1 && report.tiles == 1 && report.models == 1 && report.problems.length == 0);
}

/// Buildings: the extractor's raw house, assembled into vmaps, stands on the map with its floor, roof and wall.
unittest
{
    import std.file : rmdirRecurse, tempDir;
    import dmangos.world.testdata;

    const dir = buildPath(tempDir, "dmangos-vmap-test");
    scope (exit)
        rmdirRecurse(dir);
    writeTestHouseVmaps(dir);
    const client = testClientData();
    auto terrain = new Terrain(mapEasternKingdoms, dir, client, new ModelCache(buildPath(dir, "vmaps")));
    assert(terrain.hasVmaps);
    // World coordinates of an internal point (the conversion is its own inverse).
    float[2] world(float ix, float iy)
    {
        const w = toInternal(ix, iy, 0);
        return [w.x, w.y];
    }

    // On the floor, and on the roof.
    auto p = world(16002, 16105);
    assert(abs(terrain.heightStatic(p[0], p[1], 52) - 50) < 0.01, "the floor below");
    assert(abs(terrain.heightStatic(p[0], p[1], 57) - 55) < 0.01, "the roof below");
    assert(terrain.heightStatic(world(15990, 16105)[0], world(15990, 16105)[1], 52) == invalidHeightValue,
        "beside the house: no terrain, no building");

    // The wall at x = 16005 blocks a line across it; doodads are not what blocks it.
    auto a = world(16002, 16105), b = world(16008, 16105), c = world(16002, 16108);
    assert(!terrain.isInLineOfSight(a[0], a[1], 52, b[0], b[1], 52));
    assert(!terrain.isInLineOfSight(a[0], a[1], 52, b[0], b[1], 52, true));
    assert(terrain.isInLineOfSight(a[0], a[1], 52, c[0], c[1], 52), "along the wall");

    // Inside: the group, indoors, and its area from WMOAreaTable.
    BuildingArea area;
    assert(terrain.buildingArea(p[0], p[1], 52, area));
    assert(area.rootId == testHouseRoot && area.groupId == testHouseGroup && area.adtId == testHouseNameSet);
    assert(abs(area.floorZ - 50) < 0.01 && !terrain.isOutdoors(p[0], p[1], 52));
    assert(terrain.areaFlag(p[0], p[1], 52) == exploreGoldshire);
    auto outside = world(15990, 16105);
    assert(terrain.isOutdoors(outside[0], outside[1], 52));
}

// Movement map tiles wait until added a few at a time; until then the map has no way there.
unittest
{
    import core.time : Duration;
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : to;
    import dmangos.extractor.maps : buildTestAdt, convertAdt, TestTerrain;
    import dmangos.extractor.mmaps : buildGridTile;
    import dmangos.world.testdata : testClientData;
    import dmangos.bytes : ByteWriter;

    const dir = buildPath(tempDir, "dmangos-navload-" ~ thisProcessID.to!string);
    mkdirRecurse(buildPath(dir, "maps"));
    mkdirRecurse(buildPath(dir, "mmaps"));
    scope (exit)
        rmdirRecurse(dir);
    TestTerrain flat;
    flat.height = (float, float) => 42.0f;
    flat.areaId = (int, int) => 0;
    string problem;
    const ushort[uint] noFlags;
    write(buildPath(dir, "maps", "0013030.map"), convertAdt(buildTestAdt(flat), noFlags, problem));
    const data = buildGridTile(buildPath(dir, "maps"), buildPath(dir, "vmaps"), 1, 30, 30);
    ByteWriter tile;
    foreach (uint word; [0x4D4D4150, 7, 1, cast(uint) data.length, 1])
        tile.put(word);
    tile.putBytes(data);
    write(buildPath(dir, "mmaps", "0013030.mmtile"), tile.data);
    write(buildPath(dir, "mmaps", "001.mmap"), new ubyte[28]);

    auto terrain = new Terrain(1, dir, testClientData());
    assert(terrain.hasMovementMaps);
    const from = Vector3(1000, 1000, 42), dest = Vector3(600, 1000, 42);
    assert(terrain.tile(800, 800) !is null);
    assert(terrain.pathBetween(from, dest).length == 0, "not added yet: walk straight");
    assert(terrain.addPendingNavigation(Duration.zero) == 0, "at least one is added, whatever the budget");
    assert(terrain.pathBetween(from, dest).length == 2, "added: the way across");
}
