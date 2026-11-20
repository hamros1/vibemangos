/**
 * Extracts the terrain of every map from the client's MPQ archives into `.map` files, reading the
 * ADT and WDT files.
 *
 * For each map in `Map.dbc` whose `World\Maps\NAME\NAME.wdt` exists, every ADT tile the WDT lists
 * becomes `<output>/maps/MMMYYXX.map`: the tile's area flags (`AreaTable.dbc`'s explore flag per
 * cell), its ground heights (a 129 x 129 grid of corners and a 128 x 128 grid of centres, packed
 * to bytes or shorts when the terrain is flat enough), its liquids (from the vanilla `MCLQ`
 * chunks) and its holes. The files are in the CMaNGOS `.map` format (version "z1.4"), byte for
 * byte what that project's extractor writes, so either extractor's files serve either server.
 *
 * The ADT and WDT chunks are read at the offsets the client's own headers give, and each chunk's
 * name is checked.
 * One difference from that extractor's output, which no server reads: the liquid heights'
 * last row and column (index 128, past the tile's 128 squares) hold what this tile's liquid has
 * there, not what the previous tile's had.
 */
module dmangos.extractor.maps;

import std.algorithm.comparison : max, min;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.exception : enforce;
import std.file : mkdirRecurse, write;
import std.format : format;
import std.path : buildPath;

import dmangos.dbc : DbcStore;
import dmangos.mapfile;
import dmangos.log;
import dmangos.mpq.archive;

/// Cells per tile side, and height points per cell side.
enum cellsPerTile = 16, cellSize = 8, gridSize = cellsPerTile * cellSize;

/// Tiles per map side.
enum wdtMapSize = 64;

// The extractor's options, fixed: they decide the packing of the files.
private enum float useMinHeight = -500.0f;      // deep ocean is cut off here
private enum float floatToInt8Limit = 2.0f;     // heights within this range pack to bytes
private enum float floatToInt16Limit = 2048.0f; // ... and within this range to shorts
private enum float flatHeightDeltaLimit = 0.005f; // terrain within this height is flat
private enum float flatLiquidDeltaLimit = 0.001f; // liquid within this height is flat

// ---------------------------------------------------------------------------
// DBC files the extractor reads
// ---------------------------------------------------------------------------

private struct MapName
{
    uint id;
    string internalName;
}

private struct AreaFlag
{
    uint id;
    uint exploreFlag;
}

// Map.dbc and AreaTable.dbc with only the columns read.
private enum mapNameFormat = "nsxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
private enum areaFlagFormat = "nxxixxxxxxxxxxxxxxxxxxxxx";

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// What a map extraction did.
struct MapReport
{
    size_t maps;   /// maps with a WDT
    size_t tiles;  /// `.map` files written
    string[] problems;
}

/// Every map's tiles from `archives` (newest first) into `<outputDir>/maps`.
MapReport extractMaps(MpqArchive[] archives, string outputDir, void delegate(string) progress = null)
{
    MapReport report;
    const maps = DbcStore!(MapName, mapNameFormat).parse(readFile(archives, "DBFilesClient\\Map.dbc"), "Map.dbc");
    const areas = DbcStore!(AreaFlag, areaFlagFormat).parse(readFile(archives, "DBFilesClient\\AreaTable.dbc"),
        "AreaTable.dbc");
    ushort[uint] areaFlags;
    foreach (ref area; areas.rows)
        areaFlags[area.id] = cast(ushort) area.exploreFlag;

    const directory = buildPath(outputDir, "maps");
    mkdirRecurse(directory);
    foreach (ref map; maps.rows)
    {
        const wdtName = format!"World\\Maps\\%s\\%s.wdt"(map.internalName, map.internalName);
        const wdtData = tryRead(archives, wdtName);
        if (wdtData is null)
            continue;
        uint[2][] tiles;
        if (!wdtTiles(wdtData, tiles))
        {
            report.problems ~= wdtName ~ ": not a valid WDT";
            continue;
        }
        ++report.maps;
        if (progress)
            progress(format!"%s (%s): %s tiles"(map.internalName, map.id, tiles.length));
        foreach (tile; tiles)
        {
            const adtName = format!"World\\Maps\\%s\\%s_%s_%s.adt"(map.internalName, map.internalName, tile[1],
                tile[0]);
            const adt = tryRead(archives, adtName);
            if (adt is null)
            {
                report.problems ~= adtName ~ ": listed in the WDT but missing";
                continue;
            }
            string problem;
            const converted = convertAdt(adt, areaFlags, problem);
            if (converted is null)
            {
                report.problems ~= adtName ~ ": " ~ problem;
                continue;
            }
            if (problem.length)
                report.problems ~= adtName ~ ": " ~ problem;
            write(buildPath(directory, format!"%03d%02d%02d.map"(map.id, tile[0], tile[1])), converted);
            ++report.tiles;
        }
    }
    return report;
}

/**
 * The tiles a WDT says exist (its MAIN chunk), as [y, x] pairs in file order. False if it
 * is not a WDT. A map made only of buildings (a WMO) has a WDT with no tiles.
 */
bool wdtTiles(const(ubyte)[] wdt, out uint[2][] tiles)
{
    // MVER, then MPHD, then MAIN.
    if (!hasVersion(wdt))
        return false;
    const mphd = 12;
    if (!isChunk(wdt, mphd, "MPHD"))
        return false;
    const main = mphd + 8 + word(wdt, mphd + 4);
    if (!isChunk(wdt, main, "MAIN") || main + 8 + wdtMapSize * wdtMapSize * 8 > wdt.length)
        return false;
    foreach (uint y; 0 .. wdtMapSize)
        foreach (uint x; 0 .. wdtMapSize)
            if (word(wdt, main + 8 + (y * wdtMapSize + x) * 8))
                tiles ~= [y, x];
    return true;
}

/**
 * One tile's `.map` file, or null (with `problem` set) if the ADT cannot be read.
 * `problem` is also set, with a file returned, for an area id `AreaTable.dbc` does not know.
 */
ubyte[] convertAdt(const(ubyte)[] adt, const ushort[uint] areaFlagsById, out string problem)
{
    const cells = readCells(adt, problem);
    if (cells is null)
        return null;

    // Areas.
    ushort[cellsPerTile][cellsPerTile] areaFlags;
    foreach (i; 0 .. cellsPerTile)
        foreach (j; 0 .. cellsPerTile)
        {
            areaFlags[i][j] = 0xFFFF;
            const cell = cells[i][j];
            if (cell.offset == 0 || cell.areaId == 0)
                continue;
            if (auto flag = cell.areaId in areaFlagsById)
                areaFlags[i][j] = *flag;
            else
                problem = format!"no area flag for area id %s"(cell.areaId);
        }
    bool fullAreaData;
    foreach (row; areaFlags)
        foreach (flag; row)
            fullAreaData |= flag != areaFlags[0][0];

    // Heights: the corners of each cell's 8 x 8 squares (V9) and their centres (V8).
    float[gridSize + 1][gridSize + 1] v9 = 0;
    float[gridSize][gridSize] v8 = 0;
    foreach (i; 0 .. cellsPerTile)
        foreach (j; 0 .. cellsPerTile)
        {
            const cell = cells[i][j];
            if (cell.offset == 0)
                continue;
            foreach (y; 0 .. cellSize + 1)
                foreach (x; 0 .. cellSize + 1)
                    v9[i * cellSize + y][j * cellSize + x] = cell.baseHeight;
            foreach (y; 0 .. cellSize)
                foreach (x; 0 .. cellSize)
                    v8[i * cellSize + y][j * cellSize + x] = cell.baseHeight;
            if (cell.heights is null)
                continue;
            // The 145 heights alternate rows of 9 corners and 8 centres.
            foreach (y; 0 .. cellSize + 1)
                foreach (x; 0 .. cellSize + 1)
                    v9[i * cellSize + y][j * cellSize + x] += cell.heights[y * (cellSize * 2 + 1) + x];
            foreach (y; 0 .. cellSize)
                foreach (x; 0 .. cellSize)
                    v8[i * cellSize + y][j * cellSize + x] += cell.heights[y * (cellSize * 2 + 1) + cellSize + 1 + x];
        }

    float maxHeight = -20_000, minHeight = 20_000;
    foreach (ref row; v8)
        foreach (h; row)
        {
            maxHeight = max(maxHeight, h);
            minHeight = min(minHeight, h);
        }
    foreach (ref row; v9)
        foreach (h; row)
        {
            maxHeight = max(maxHeight, h);
            minHeight = min(minHeight, h);
        }
    // Deep ocean floor is not kept (CONF_allow_height_limit).
    if (minHeight < useMinHeight)
    {
        foreach (ref row; v8)
            foreach (ref h; row)
                h = max(h, useMinHeight);
        foreach (ref row; v9)
            foreach (ref h; row)
                h = max(h, useMinHeight);
        minHeight = useMinHeight;
        maxHeight = max(maxHeight, useMinHeight);
    }

    uint heightFlags;
    if (maxHeight == minHeight || maxHeight - minHeight < flatHeightDeltaLimit)
        heightFlags |= mapHeightNoHeight;
    float step = 0;
    if (!(heightFlags & mapHeightNoHeight))
    {
        const float diff = maxHeight - minHeight;
        if (diff < floatToInt8Limit)
        {
            heightFlags |= mapHeightAsInt8;
            step = 255 / diff;
        }
        else if (diff < floatToInt16Limit)
        {
            heightFlags |= mapHeightAsInt16;
            step = 65_535 / diff;
        }
    }

    // Liquids, from the vanilla MCLQ chunks.
    ushort[cellsPerTile][cellsPerTile] liquidEntry;
    ubyte[cellsPerTile][cellsPerTile] liquidFlags;
    bool[gridSize][gridSize] liquidShow;
    float[gridSize + 1][gridSize + 1] liquidHeight = 0;
    foreach (i; 0 .. cellsPerTile)
        foreach (j; 0 .. cellsPerTile)
        {
            const cell = cells[i][j];
            if (cell.offset == 0 || cell.liquid is null)
                continue;
            int shown;
            foreach (y; 0 .. cellSize)
                foreach (x; 0 .. cellSize)
                {
                    const flags = cell.liquid.flags[y * cellSize + x];
                    if (flags == 0x0F)
                        continue;
                    liquidShow[i * cellSize + y][j * cellSize + x] = true;
                    if (flags & 0x80)
                        liquidFlags[i][j] |= mapLiquidTypeDeepWater;
                    ++shown;
                }
            if (cell.flags & 1 << 2)
            {
                liquidEntry[i][j] = 1;
                liquidFlags[i][j] |= mapLiquidTypeWater;
            }
            if (cell.flags & 1 << 3)
            {
                liquidEntry[i][j] = 2;
                liquidFlags[i][j] |= mapLiquidTypeOcean;
            }
            if (cell.flags & 1 << 4)
            {
                liquidEntry[i][j] = 3;
                liquidFlags[i][j] |= mapLiquidTypeMagma;
            }
            if (!shown && liquidFlags[i][j])
                warning!"wrong liquid detect in MCLQ chunk"();
            foreach (y; 0 .. cellSize + 1)
                foreach (x; 0 .. cellSize + 1)
                    liquidHeight[i * cellSize + y][j * cellSize + x] = cell.liquid.heights[y * (cellSize + 1) + x];
        }

    const firstEntry = liquidEntry[0][0];
    const firstFlags = liquidFlags[0][0];
    bool fullType;
    foreach (y; 0 .. cellsPerTile)
        foreach (x; 0 .. cellsPerTile)
            fullType |= liquidEntry[y][x] != firstEntry || liquidFlags[y][x] != firstFlags;
    const hasLiquid = firstFlags != 0 || fullType;

    int minX = 255, minY = 255, maxX = 0, maxY = 0;
    float maxLiquid = -20_000, minLiquid = 20_000;
    if (hasLiquid)
        foreach (y; 0 .. gridSize)
            foreach (x; 0 .. gridSize)
            {
                if (liquidShow[y][x])
                {
                    minX = min(minX, x);
                    maxX = max(maxX, x);
                    minY = min(minY, y);
                    maxY = max(maxY, y);
                    maxLiquid = max(maxLiquid, liquidHeight[y][x]);
                    minLiquid = min(minLiquid, liquidHeight[y][x]);
                }
                else
                {
                    liquidHeight[y][x] = useMinHeight;
                    minLiquid = min(minLiquid, useMinHeight);
                }
            }
    // The format stores these sizes in bytes; with no square shown they wrap.
    const ubyte liquidWidth = cast(ubyte)(maxX - minX + 2), liquidRows = cast(ubyte)(maxY - minY + 2);
    uint liquidHeaderFlags;
    if (maxLiquid == minLiquid || maxLiquid - minLiquid < flatLiquidDeltaLimit)
        liquidHeaderFlags |= mapLiquidNoHeight;
    if (!fullType)
        liquidHeaderFlags |= mapLiquidNoType;

    // Writing: header, areas, heights, liquids, holes.
    Writer area, height, liquid, holes;
    area.put(mapAreaMagic);
    area.put(cast(ushort)(fullAreaData ? 0 : mapAreaNoArea));
    area.put(cast(ushort)(fullAreaData ? 0 : areaFlags[0][0]));
    if (fullAreaData)
        foreach (ref row; areaFlags)
            foreach (flag; row)
                area.put(flag);

    height.put(mapHeightMagic);
    height.put(heightFlags);
    height.put(minHeight);
    height.put(maxHeight);
    if (!(heightFlags & mapHeightNoHeight))
    {
        void putPacked(T)()
        {
            foreach (ref row; v9)
                foreach (h; row)
                    height.put(cast(T) cast(float)((h - minHeight) * step + 0.5f));
            foreach (ref row; v8)
                foreach (h; row)
                    height.put(cast(T) cast(float)((h - minHeight) * step + 0.5f));
        }

        if (heightFlags & mapHeightAsInt16)
            putPacked!ushort();
        else if (heightFlags & mapHeightAsInt8)
            putPacked!ubyte();
        else
        {
            foreach (ref row; v9)
                foreach (h; row)
                    height.put(h);
            foreach (ref row; v8)
                foreach (h; row)
                    height.put(h);
        }
    }

    if (hasLiquid)
    {
        liquid.put(mapLiquidMagic);
        liquid.put(cast(ubyte) liquidHeaderFlags);
        liquid.put(cast(ubyte)(fullType ? 0 : firstFlags));
        liquid.put(cast(ushort)(fullType ? 0 : firstEntry));
        liquid.put(cast(ubyte) minX);
        liquid.put(cast(ubyte) minY);
        liquid.put(liquidWidth);
        liquid.put(liquidRows);
        liquid.put(minLiquid);
        if (fullType)
        {
            foreach (ref row; liquidEntry)
                foreach (entry; row)
                    liquid.put(entry);
            foreach (ref row; liquidFlags)
                foreach (flags; row)
                    liquid.put(flags);
        }
        if (!(liquidHeaderFlags & mapLiquidNoHeight))
            foreach (y; 0 .. liquidRows)
                foreach (x; 0 .. liquidWidth)
                {
                    // Past the grid only when no square shows (see above): the minimum height there.
                    const row = y + minY, column = x + minX;
                    liquid.put(row <= gridSize && column <= gridSize ? liquidHeight[row][column] : useMinHeight);
                }
    }

    foreach (i; 0 .. cellsPerTile)
        foreach (j; 0 .. cellsPerTile)
            holes.put(cast(ushort)(cells[i][j].offset ? cells[i][j].holes : 0));

    assert(holes.length == cellsPerTile * cellsPerTile * 2, "16 x 16 holes of 2 bytes");
    enum headerSize = 40;
    const areaOffset = headerSize, heightOffset = areaOffset + area.length;
    const liquidOffset = hasLiquid ? heightOffset + height.length : 0;
    const holesOffset = hasLiquid ? liquidOffset + liquid.length : heightOffset + height.length;
    Writer file;
    foreach (value; [mapMagic, mapVersionMagic, areaOffset, area.length, heightOffset, height.length, liquidOffset,
        liquid.length, holesOffset, holes.length])
        file.put(cast(uint) value);
    return file.bytes ~ area.bytes ~ height.bytes ~ liquid.bytes ~ holes.bytes;
}

// ---------------------------------------------------------------------------
// Reading ADT files
// ---------------------------------------------------------------------------

/// What `convertAdt` reads from one `MCNK` cell.
private struct Cell
{
    size_t offset;       // where the chunk is; 0 for none
    uint flags;
    uint areaId;
    ushort holes;
    float baseHeight;    // the cell's base height
    const(float)[] heights; // 145 from MCVT, or null
    const(Liquid)* liquid; // MCLQ, or null
}

private struct Liquid
{
    float[(cellSize + 1) * (cellSize + 1)] heights;
    ubyte[cellSize * cellSize] flags;
}

/// The 16 x 16 cells of an ADT, or null with `problem` set.
private Cell[cellsPerTile][] readCells(const(ubyte)[] adt, out string problem)
{
    if (!hasVersion(adt))
    {
        problem = "no MVER chunk of version 18";
        return null;
    }
    // MHDR follows MVER; its offsets count from its data.
    enum mhdr = 12, mhdrData = mhdr + 8;
    if (!isChunk(adt, mhdr, "MHDR") || word(adt, mhdr + 4) != 64)
    {
        problem = "no MHDR chunk";
        return null;
    }
    const mcin = mhdrData + word(adt, mhdrData + 4);
    if (!isChunk(adt, mcin, "MCIN") || mcin + 8 + cellsPerTile * cellsPerTile * 16 > adt.length)
    {
        problem = "no MCIN chunk";
        return null;
    }
    if (word(adt, mhdrData + 40))
        warning!"an MH2O chunk in a 1.12 ADT is not read"();

    auto cells = new Cell[cellsPerTile][cellsPerTile];
    foreach (i; 0 .. cellsPerTile)
        foreach (j; 0 .. cellsPerTile)
        {
            const entry = word(adt, mcin + 8 + (i * cellsPerTile + j) * 16);
            if (entry == 0)
                continue;
            // An MCIN entry's offset counts from the file's start, with MCIN at 84.
            const m = mcin + entry - 84;
            if (!isChunk(adt, m, "MCNK") || m + 136 > adt.length)
            {
                problem = format!"cell %s,%s: no MCNK chunk"(i, j);
                return null;
            }
            Cell cell;
            cell.offset = m;
            cell.flags = word(adt, m + 8);
            cell.areaId = word(adt, m + 60);
            cell.holes = read!ushort(adt, m + 68);
            cell.baseHeight = read!float(adt, m + 120);
            if (const mcvt = word(adt, m + 28))
            {
                enum count = (cellSize + 1) * (cellSize + 1) + cellSize * cellSize;
                if (!isChunk(adt, m + mcvt, "MCVT") || word(adt, m + mcvt + 4) != count * 4
                    || m + mcvt + 8 + count * 4 > adt.length)
                {
                    problem = format!"cell %s,%s: no MCVT chunk"(i, j);
                    return null;
                }
                cell.heights = floats(adt, m + mcvt + 8, count);
            }
            const mclq = word(adt, m + 104), mclqSize = word(adt, m + 108);
            if (mclq && mclqSize > 8)
            {
                const l = m + mclq;
                enum liquidBytes = 8 + 8 + 81 * 8 + 64;
                if (!isChunk(adt, l, "MCLQ") || l + liquidBytes > adt.length)
                {
                    problem = format!"cell %s,%s: no MCLQ chunk"(i, j);
                    return null;
                }
                auto liquid = new Liquid;
                foreach (k; 0 .. 81) // light, then height, per corner
                    liquid.heights[k] = read!float(adt, l + 16 + k * 8 + 4);
                liquid.flags[] = adt[l + 16 + 81 * 8 .. l + 16 + 81 * 8 + 64];
                cell.liquid = liquid;
            }
            cells[i][j] = cell;
        }
    return cells;
}

/// Whether the file starts with an MVER chunk of version 18.
private bool hasVersion(const(ubyte)[] data)
{
    return isChunk(data, 0, "MVER") && data.length >= 12 && word(data, 8) == 18;
}

/// Whether a chunk named `name` starts at `offset`. The files store names backwards ("REVM").
private bool isChunk(const(ubyte)[] data, size_t offset, string name)
{
    return offset + 8 <= data.length && data[offset .. offset + 4] == [name[3], name[2], name[1], name[0]];
}

/// A little-endian value at `offset`.
private T read(T)(const(ubyte)[] data, size_t offset)
{
    enforce(offset + T.sizeof <= data.length, "read past the end of a terrain file");
    return data[offset .. offset + T.sizeof][0 .. T.sizeof].littleEndianToNative!T;
}

private alias word = read!uint;

private float[] floats(const(ubyte)[] data, size_t offset, size_t count)
{
    auto values = new float[count];
    foreach (k, ref value; values)
        value = read!float(data, offset + k * 4);
    return values;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private ubyte[] readFile(MpqArchive[] archives, string name)
{
    auto data = tryRead(archives, name);
    enforce(data !is null, name ~ " is in none of the client's archives");
    return data;
}

/// A file from the newest archive that has it, or null.
private ubyte[] tryRead(MpqArchive[] archives, string name)
{
    foreach (archive; archives)
        if (archive.contains(name))
            return archive.read(name);
    return null;
}

/// Little-endian output, of the field types the format has: no integer promotion slips through.
private struct Writer
{
    import std.traits : Unqual;

    ubyte[] bytes;

    void put(T)(T value)
        if (is(Unqual!T == ubyte) || is(Unqual!T == ushort) || is(Unqual!T == uint) || is(Unqual!T == float))
    {
        bytes ~= nativeToLittleEndian(value);
    }

    @property size_t length() const
    {
        return bytes.length;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    /// What a test ADT's cells hold.
    struct TestTerrain
    {
        /// The height at a point of the tile's 128 x 128 squares (row and column, fractional).
        float delegate(float row, float column) height;
        uint delegate(int i, int j) areaId;
        ushort[int[2]] holes;          /// by cell [i, j]
        float[int[2]] waterLevel;      /// cells with water, and its level
        bool[int[2]] magma;            /// of those, the cells whose liquid is magma
        bool[int[2]] deepWater;        /// of those, the cells of the open sea's deep water
    }

    /// A 1.12 ADT (version 18, MCIN at 84, absolute MCNK offsets) whose terrain is `t`.
    ubyte[] buildTestAdt(const TestTerrain t)
    {
        Writer w;
        void chunk(string name, uint size)
        {
            w.bytes ~= [cast(ubyte) name[3], name[2], name[1], name[0]];
            w.put(size);
        }

        chunk("MVER", 4);
        w.put(18u);
        chunk("MHDR", 64);
        w.put(0u);         // pad
        w.put(84u - 20);   // offsMCIN, from the data
        foreach (_; 0 .. 14)
            w.put(0u);
        assert(w.length == 84);
        chunk("MCIN", 256 * 16);
        const mcinEntries = w.length;
        foreach (_; 0 .. 256 * 4)
            w.put(0u);

        enum mcvtSize = 145 * 4, mclqSize = 8 + 81 * 8 + 64 + 84;
        foreach (i; 0 .. cellsPerTile)
            foreach (j; 0 .. cellsPerTile)
            {
                const start = w.length;
                const water = [i, j] in t.waterLevel;
                const cellSize_ = 136 + 8 + mcvtSize + (water ? 8 + mclqSize : 0);
                w.bytes[mcinEntries + (i * 16 + j) * 16 .. mcinEntries + (i * 16 + j) * 16 + 4]
                    = nativeToLittleEndian(cast(uint) start);
                chunk("MCNK", cellSize_ - 8);
                w.put(cast(uint)(!water ? 0 : [i, j] in t.magma ? 1 << 4 : 1 << 2)); // flags: water or magma
                w.put(cast(uint) j);
                w.put(cast(uint) i);
                foreach (_; 0 .. 2)
                    w.put(0u);
                w.put(136u);                           // offsMCVT, at 28
                foreach (_; 0 .. 7)
                    w.put(0u);                         // offsMCNR .. sizeMCSH
                w.put(t.areaId(i, j));                 // at 60
                w.put(0u);
                w.put(t.holes.get([i, j], ushort(0))); // at 68
                w.put(ushort(0));
                foreach (_; 0 .. 2 + 6)
                    w.put(ushort(0));                  // s[2], data1 .. data3
                foreach (_; 0 .. 4)
                    w.put(0u);                         // predTex .. nSndEmitters
                w.put(water ? 136u + 8 + mcvtSize : 0u); // offsMCLQ, at 104
                w.put(water ? cast(uint) mclqSize + 8 : 0u);
                w.put(0.0f);
                w.put(0.0f);
                w.put(10.0f);                          // ypos: the base height, at 120
                foreach (_; 0 .. 3)
                    w.put(0u);
                assert(w.length - start == 136);
                chunk("MCVT", mcvtSize);
                foreach (y; 0 .. cellSize * 2 + 1)
                {
                    const row = i * cellSize + y / 2;
                    if (y % 2 == 0)
                        foreach (x; 0 .. cellSize + 1)
                            w.put(t.height(row, j * cellSize + x) - 10);
                    else
                        foreach (x; 0 .. cellSize)
                            w.put(t.height(row + 0.5f, j * cellSize + x + 0.5f) - 10);
                }
                if (water)
                {
                    chunk("MCLQ", 0);
                    w.put(*water);
                    w.put(*water);
                    foreach (_; 0 .. 81)
                    {
                        w.put(0u);
                        w.put(*water);
                    }
                    foreach (_; 0 .. 64)
                        w.put(ubyte([i, j] in t.deepWater ? 0x80 : 0)); // every square shows it (0x80: deep)
                    foreach (_; 0 .. 84)
                        w.put(ubyte(0));
                }
            }
        return w.bytes;
    }
}

/// A WDT lists its tiles; an ADT becomes a .map file, packed.
unittest
{
    // WDT: MVER, MPHD, MAIN with tiles [y 1, x 2] and [y 63, x 0].
    Writer wdt;
    wdt.bytes ~= cast(ubyte[]) "REVM";
    wdt.put(4u);
    wdt.put(18u);
    wdt.bytes ~= cast(ubyte[]) "DHPM";
    wdt.put(32u);
    foreach (_; 0 .. 8)
        wdt.put(0u);
    wdt.bytes ~= cast(ubyte[]) "NIAM";
    wdt.put(64u * 64 * 8);
    foreach (y; 0 .. 64)
        foreach (x; 0 .. 64)
        {
            wdt.put((y == 1 && x == 2) || (y == 63 && x == 0) ? 1u : 0u);
            wdt.put(0u);
        }
    uint[2][] tiles;
    assert(wdtTiles(wdt.bytes, tiles) && tiles == [[1u, 2u], [63u, 0u]]);
    assert(!wdtTiles(wdt.bytes[0 .. 40], tiles));

    // A gentle slope packs to shorts, a flat tile to one height.
    const ushort[uint] flags = [12: 5, 40: 7];
    string problem;
    TestTerrain slope;
    slope.height = (row, column) => row + column / 2;
    slope.areaId = (i, j) => i == 0 && j == 0 ? 12 : 40;
    const sloped = convertAdt(buildTestAdt(slope), flags, problem);
    assert(problem is null && sloped[0 .. 8] == cast(const(ubyte)[]) "MAPSz1.4");
    const heightOffset = read!uint(sloped, 16);
    assert(read!uint(sloped, heightOffset + 4) == mapHeightAsInt16);

    TestTerrain flat;
    flat.height = (row, column) => 25.0f;
    flat.areaId = (i, j) => 99; // unknown to AreaTable
    const level = convertAdt(buildTestAdt(flat), flags, problem);
    assert(problem == "no area flag for area id 99");
    const areaOffset = read!uint(level, 8);
    assert(level[areaOffset + 4 .. areaOffset + 8] == [1, 0, 0xFF, 0xFF], "one area: none");
    const flatHeight = read!uint(level, 16);
    assert(read!uint(level, flatHeight + 4) == mapHeightNoHeight);
    assert(read!uint(level, 24) == 0, "no liquid");
    assert(read!uint(level, 36) == 512 && read!uint(level, 32) + 512 == level.length, "the holes end the file");
}
