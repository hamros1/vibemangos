/**
 * Extracts the client's buildings (WMOs) and doodads (M2s), in the vmap extractor's raw format,
 * into `<output>/Buildings`:
 *
 * $(UL
 *   $(LI one raw model file per building and doodad ("VMAPs05"): its collision triangles and
 *        vertices, per WMO group with the group's flags, bound and liquid;)
 *   $(LI `dir_bin`: every placement of a model, map by map and tile by tile (with the doodads
 *        of each placed building's doodad set);)
 *   $(LI `temp_gameobject_models`: the models of `GameObjectDisplayInfo.dbc`.)
 * )
 *
 * `dmangos.extractor.assembler` then builds the vmaps from them.
 *
 * The doodads a building lists are both written and looked up under their normalized names
 * (`fixNameCase`, `fixNameSpaces`), so none is lost on a case-sensitive file system. A building's
 * doodads are placed in index order, which decides the numbering of the placements.
 */
module dmangos.extractor.vmaps;

import std.algorithm.searching : canFind, endsWith;
import std.algorithm.sorting : sort;
import std.array : appender;
import std.ascii : isAlpha, isDigit;
import std.bitmanip : littleEndianToNative;
import std.exception : enforce;
import std.file : exists, mkdirRecurse, rmdirRecurse;
import std.format : format;
import std.math : PI;
import std.path : buildPath;
static import std.file;

import dmangos.bytes : ByteWriter;
import dmangos.dbc : DbcStore;
import dmangos.log;
import dmangos.mpq.archive;
import dmangos.vmap.math;
import dmangos.vmap.model : gameObjectModels, modHasBound, modM2, modWorldSpawn, putTag, rawVmapMagic;

/// The archives the vmap extractor reads, oldest first (`fillArchiveNameVector`, with dbc for the DBC files).
immutable string[] vmapArchives = ["dbc.MPQ", "terrain.MPQ", "model.MPQ", "texture.MPQ", "wmo.MPQ", "base.MPQ",
    "patch.MPQ", "patch-2.MPQ"];

/// What a raw extraction did.
struct VmapReport
{
    size_t wmos;       /// buildings written
    size_t models;     /// doodads written
    size_t spawns;     /// placements in dir_bin
    string[] missing;  /// models placed but not found in the archives
}

/// Extracts into `<outputDir>/Buildings`, which is emptied first.
VmapReport extractVmapData(MpqArchive[] archives, string outputDir, void delegate(string) progress = null)
{
    auto x = new RawExtractor(archives, buildPath(outputDir, "Buildings"));
    return x.run(progress);
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

/// The part after the last backslash.
string plainName(string path) pure nothrow @safe
{
    foreach_reverse (i, c; path)
        if (c == '\\')
            return path[i + 1 .. $];
    return path;
}

/// Each word capitalized, the rest lower case; the extension lower case.
string fixNameCase(string name) pure @safe
{
    if (name.length < 3)
        return name;
    auto s = name.dup;
    foreach (i; 0 .. s.length - 3)
    {
        if (i > 0 && s[i] >= 'A' && s[i] <= 'Z' && isAlpha(s[i - 1]))
            s[i] |= 0x20;
        else if ((i == 0 || !isAlpha(s[i - 1])) && s[i] >= 'a' && s[i] <= 'z')
            s[i] &= ~0x20;
    }
    foreach (i; s.length - 3 .. s.length)
        s[i] |= 0x20;
    return s.idup;
}

/// Spaces become underscores, the extension left alone.
string fixNameSpaces(string name) pure @safe
{
    if (name.length < 3)
        return name;
    auto s = name.dup;
    foreach (i; 0 .. s.length - 3)
        if (s[i] == ' ')
            s[i] = '_';
    return s.idup;
}

/// The name a model's raw file has: the plain name, normalized, ".mdx" and ".mdl" made ".m2".
string modelFileName(string path) pure @safe
{
    auto name = fixNameSpaces(fixNameCase(plainName(path)));
    if (name.length > 3 && (name.endsWith(".mdx") || name.endsWith(".mdl")))
        name = name[0 .. $ - 2] ~ "2";
    return name;
}

// ---------------------------------------------------------------------------
// The extraction
// ---------------------------------------------------------------------------

private:

/// A doodad set of a building's root file (`MODS`).
struct DoodadSet
{
    uint startIndex, count;
}

/// A doodad a building's root file lists (`MODD`).
struct DoodadSpawn
{
    uint nameIndex;
    Vector3 position;
    float[4] rotation; // quaternion x, y, z, w
    float scale = 0;
}

/// `WMODoodadData`
struct WmoDoodads
{
    DoodadSet[] sets;
    const(ubyte)[] paths;
    DoodadSpawn[] spawns;
    bool[ushort] references;
}

/// A placed building (`MODF`).
struct WmoPlacement
{
    uint uniqueId;
    Vector3 position, rotation;
    AABox bounds;
    ushort flags, doodadSet, nameSet;
}

/// A chunked client file (`MPQFile` with the chunk loop the readers share).
struct ChunkFile
{
    const(ubyte)[] data;

    /// Each chunk: its name, read the right way round, and its body (`size` bytes, cut at the end).
    int opApply(scope int delegate(string name, const(ubyte)[] body_, size_t offset) dg) const
    {
        size_t pos;
        while (pos + 8 <= data.length)
        {
            const char[4] raw = cast(const(char)[]) data[pos .. pos + 4];
            const name = [raw[3], raw[2], raw[1], raw[0]].idup;
            const size = peek!uint(data, pos + 4);
            const start = pos + 8;
            // A group's MOGP chunk holds the other chunks: only its 68-byte header is its own.
            const length = name == "MOGP" ? 68 : size;
            const end = start + length < data.length ? start + length : data.length;
            if (const result = dg(name, data[start .. end], start))
                return result;
            pos = start + length;
        }
        return 0;
    }
}

T peek(T)(const(ubyte)[] data, size_t offset)
{
    enforce(offset + T.sizeof <= data.length, "read past the end of a client file");
    return data[offset .. offset + T.sizeof][0 .. T.sizeof].littleEndianToNative!T;
}

Vector3 getVector(const(ubyte)[] data, size_t offset)
{
    return Vector3(peek!float(data, offset), peek!float(data, offset + 4), peek!float(data, offset + 8));
}

/// `fixCoords`: the client's (x, y, z) as (z, x, y).
Vector3 fixCoords(const Vector3 v) pure nothrow @nogc @safe
{
    return Vector3(v.z, v.x, v.y);
}

final class RawExtractor
{
    MpqArchive[] archives;
    string directory;
    WmoDoodads[string] doodads;    // by building file name
    uint[ulong] uniqueIds;         // (client id, doodad id) -> id
    uint[string] written;          // raw files written -> their first count (kept here, not read back from the file)
    ByteWriter dirBin;
    VmapReport report;
    bool[string] missing;

    this(MpqArchive[] archives, string directory)
    {
        this.archives = archives;
        this.directory = directory;
    }

    VmapReport run(void delegate(string) progress)
    {
        if (exists(directory))
            rmdirRecurse(directory);
        mkdirRecurse(directory);

        // Every building any archive lists.
        bool[string] listed;
        foreach (archive; archives)
            foreach (name; archive.listfile())
                if (name.canFind(".wmo") && name !in listed)
                {
                    listed[name] = true;
                    extractWmo(name);
                }
        if (progress)
            progress(format!"%s buildings, %s doodads"(report.wmos, report.models));

        // What the maps place.
        const maps = DbcStore!(MapName, "nsxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx").parse(
            readFile("DBFilesClient\\Map.dbc"), "Map.dbc");
        foreach (ref map; maps.rows)
        {
            const before = report.spawns;
            const wdt = readFile(format!"World\\Maps\\%s\\%s.wdt"(map.internalName, map.internalName));
            if (wdt is null)
                continue;
            parseWdt(wdt, map.id);
            foreach (uint x; 0 .. 64)
                foreach (uint y; 0 .. 64)
                {
                    const adt = readFile(format!"World\\Maps\\%s\\%s_%d_%d.adt"(map.internalName,
                        map.internalName, x, y));
                    if (adt !is null)
                        parseAdt(adt, map.id, x, y);
                }
            if (progress && report.spawns > before)
                progress(format!"%s (%s): %s placements"(map.internalName, map.id, report.spawns - before));
        }
        std.file.write(buildPath(directory, "dir_bin"), dirBin.data);

        extractGameObjectModels();
        report.missing = missing.keys;
        report.missing.sort();
        return report;
    }

    /// A file from the newest archive that has it; null if none (or a one-byte placeholder).
    const(ubyte)[] readFile(string name)
    {
        foreach (archive; archives)
            if (archive.contains(name))
                return archive.sizeOf(name) <= 1 ? null : archive.read(name);
        return null;
    }

    string outputPath(string name)
    {
        return buildPath(directory, name);
    }

    /// A raw file's first count: collision triangles (WMO) or vertices (M2); 0 if none was written.
    uint rawCount(string name)
    {
        return written.get(name, 0);
    }

    uint uniqueId(uint clientId, ushort doodadId)
    {
        const key = ulong(clientId) << 16 | doodadId;
        return uniqueIds.require(key, cast(uint)(uniqueIds.length + 1));
    }

    // -----------------------------------------------------------------------
    // Doodads
    // -----------------------------------------------------------------------

    /// Extracts an M2's collision mesh. False if it has none or is not found.
    bool extractModel(string path, out string fileName)
    {
        if (path.length < 4)
            return false;
        const source = modelSourceName(path);
        fileName = modelFileName(path);
        if (fileName in written)
            return true;
        const data = readFile(source);
        if (data is null)
        {
            missing[source] = true;
            return false;
        }
        // The M2 header: the bounding triangles and vertices follow the magic and version, 43 words
        // (the name, the type and 20 count and offset pairs) and 14 floats (the bounding boxes and radii).
        enum boundsAt = 8 + 43 * 4 + 14 * 4;
        static assert(boundsAt == 236);
        if (data.length < boundsAt + 16)
            return false;
        const nIndices = peek!uint(data, boundsAt), indicesAt = peek!uint(data, boundsAt + 4);
        const nVertices = peek!uint(data, boundsAt + 8), verticesAt = peek!uint(data, boundsAt + 12);
        if (nIndices == 0)
            return false;
        ByteWriter w;
        putTag(w, rawVmapMagic);
        w.put(nVertices);
        w.put(1u);                  // one group
        foreach (_; 0 .. 3 + 6 + 1) // root id, flags, group id; the bound; liquid flags
            w.put(0u);
        putTag(w, "GRP ");
        w.put(8u);
        w.put(1u);                  // one branch
        w.put(nIndices);
        putTag(w, "INDX");
        w.put(cast(uint)(4 + 2 * nIndices));
        w.put(nIndices);
        // Each triangle's last two indexes swap.
        foreach (i; 0 .. nIndices)
        {
            const j = i % 3 == 1 ? i + 1 : i % 3 == 2 ? i - 1 : i;
            w.put(peek!ushort(data, indicesAt + j * 2));
        }
        putTag(w, "VERT");
        w.put(cast(uint)(4 + 12 * nVertices));
        w.put(nVertices);
        // The coordinate fix and its undoing cancel out: the vertices as stored.
        foreach (i; 0 .. nVertices)
            putVector(w, getVector(data, verticesAt + i * 12));
        std.file.write(outputPath(fileName), w.data);
        written[fileName] = nVertices;
        ++report.models;
        return true;
    }

    /// A doodad placed by a terrain tile (MDDF).
    void placeModel(const(ubyte)[] entry, string name, uint mapId, uint tileX, uint tileY)
    {
        const clientId = peek!uint(entry, 0);
        const pos = fixCoords(getVector(entry, 4));
        const rot = getVector(entry, 16);
        const scale = peek!ushort(entry, 28) / 1024.0f;
        if (rawCount(name) == 0)
            return;
        const flags = modM2 | (tileX == 65 && tileY == 65 ? modWorldSpawn : 0);
        writeSpawn(mapId, tileX, tileY, flags, 0, uniqueId(clientId, 0), pos, rot, scale, null, name);
    }

    /// Places the doodads of a placed building's doodad set.
    void placeDoodads(string wmoName, const ref WmoPlacement wmo, uint mapId, uint tileX, uint tileY)
    {
        auto data = wmoName in doodads;
        if (data is null || wmo.doodadSet >= data.sets.length)
            return;
        enum float toRadians = PI / 180, toDegrees = 180 / PI;
        const wmoRotation = Matrix3.fromEulerAnglesZYX(wmo.rotation.y * toRadians, wmo.rotation.x * toRadians,
            wmo.rotation.z * toRadians);
        const set = data.sets[wmo.doodadSet];
        auto indexes = data.references.keys;
        indexes.sort();
        ushort doodadId;
        foreach (index; indexes)
        {
            if (index < set.startIndex || index >= set.startIndex + set.count)
                continue;
            const doodad = data.spawns[index];
            const name = modelFileName(cStringAt(data.paths, doodad.nameIndex));
            if (rawCount(name) == 0)
                continue;
            ++doodadId;
            const position = wmo.position + wmoRotation * doodad.position;
            const q = doodad.rotation;
            float rx, ry, rz;
            (Matrix3.fromQuaternion(q[0], q[1], q[2], q[3]) * wmoRotation).toEulerAnglesXYZ(rz, rx, ry);
            const rotation = Vector3(rx * toDegrees, ry * toDegrees, rz * toDegrees);
            const flags = modM2 | (tileX == 65 && tileY == 65 ? modWorldSpawn : 0);
            writeSpawn(mapId, tileX, tileY, flags, 0, uniqueId(wmo.uniqueId, doodadId), position, rotation,
                doodad.scale, null, name);
        }
    }

    // -----------------------------------------------------------------------
    // Buildings
    // -----------------------------------------------------------------------

    /// Extracts a building's root and groups, as one raw file.
    void extractWmo(string path)
    {
        const name = fixNameSpaces(fixNameCase(plainName(path)));
        if (name in written)
            return;
        // A group file (NAME_000.wmo) is read with its root, not on its own.
        foreach_reverse (i, c; name)
            if (c == '_')
            {
                int digits;
                foreach (k; i .. i + 4 < name.length ? i + 4 : name.length)
                    digits += isDigit(name[k]);
                if (digits == 3)
                    return;
                break;
            }
        const root = readFile(path);
        if (root is null)
            return;

        uint nGroups, rootWmoId, rootFlags;
        WmoDoodads found;
        bool[uint] validDoodadNames;
        const(char)[] groupNames;
        foreach (chunk, body_, _; ChunkFile(root))
            switch (chunk)
            {
            case "MOHD":
                nGroups = peek!uint(body_, 4);
                rootWmoId = peek!uint(body_, 32);
                rootFlags = peek!uint(body_, 60);
                break;
            case "MODS":
                foreach (i; 0 .. body_.length / 32)
                    found.sets ~= DoodadSet(peek!uint(body_, i * 32 + 20), peek!uint(body_, i * 32 + 24));
                break;
            case "MODN":
                found.paths = body_.dup;
                for (size_t offset = 0; offset < body_.length;)
                {
                    const doodadPath = cStringAt(body_, offset);
                    string unused;
                    if (extractModel(doodadPath, unused))
                        validDoodadNames[cast(uint) offset] = true;
                    offset += doodadPath.length + 1;
                }
                break;
            case "MODD":
                foreach (i; 0 .. body_.length / 40)
                {
                    const at = i * 40;
                    DoodadSpawn s;
                    s.nameIndex = peek!uint(body_, at) & 0xFF_FFFF;
                    s.position = getVector(body_, at + 4);
                    foreach (k; 0 .. 4)
                        s.rotation[k] = peek!float(body_, at + 16 + k * 4);
                    s.scale = peek!float(body_, at + 32);
                    found.spawns ~= s;
                }
                break;
            case "MOGN":
                groupNames = cast(const(char)[]) body_;
                break;
            default:
                break;
            }

        ByteWriter w;
        putTag(w, rawVmapMagic);
        w.put(0u);         // collision triangles, filled in below
        w.put(nGroups);    // groups written, likewise
        w.put(rootWmoId);
        uint triangles, groupsWritten;
        foreach (i; 0 .. nGroups)
        {
            const groupFile = readFile(format!"%s_%03d.wmo"(path[0 .. $ - 4], i));
            if (groupFile is null)
            {
                warning!"could not open every group file of %s"(name);
                return; // an incomplete building is not written
            }
            auto group = WmoGroup.read(groupFile);
            if (group.shouldSkip(groupNames))
                continue;
            ++groupsWritten;
            triangles += group.convert(w, rootFlags, path);
            foreach (reference; group.doodadReferences)
                if (reference < found.spawns.length && found.spawns[reference].nameIndex in validDoodadNames)
                    found.references[reference] = true;
        }
        auto bytes = w.data.dup;
        bytes[8 .. 12] = (cast(ubyte*)&triangles)[0 .. 4];
        bytes[12 .. 16] = (cast(ubyte*)&groupsWritten)[0 .. 4];
        std.file.write(outputPath(name), bytes);
        written[name] = triangles;
        doodads[name] = found;
        ++report.wmos;
    }

    /// A placed building (MODF), then its doodads.
    void placeWmo(const(ubyte)[] entry, string name, uint mapId, uint tileX, uint tileY)
    {
        WmoPlacement wmo;
        wmo.uniqueId = peek!uint(entry, 0);
        wmo.position = getVector(entry, 4);
        wmo.rotation = getVector(entry, 16);
        wmo.bounds = AABox(getVector(entry, 28), getVector(entry, 40));
        wmo.flags = peek!ushort(entry, 52);
        wmo.doodadSet = peek!ushort(entry, 54);
        wmo.nameSet = peek!ushort(entry, 56);
        // A destructible building (flag 1), or one without collision, is not placed; its doodads
        // still are, from the unconverted position.
        if ((wmo.flags & 1) == 0 && rawCount(name) != 0)
        {
            if (wmo.position.x == 0 && wmo.position.z == 0)
                wmo.position.x = wmo.position.z = 533.33333f * 32;
            wmo.position = fixCoords(wmo.position);
            wmo.bounds = AABox(fixCoords(wmo.bounds.lo), fixCoords(wmo.bounds.hi));
            const flags = modHasBound | (tileX == 65 && tileY == 65 ? modWorldSpawn : 0);
            writeSpawn(mapId, tileX, tileY, flags, wmo.nameSet, uniqueId(wmo.uniqueId, 0), wmo.position,
                wmo.rotation, 1.0f, &wmo.bounds, name);
        }
        placeDoodads(name, wmo, mapId, tileX, tileY);
    }

    // -----------------------------------------------------------------------
    // Maps
    // -----------------------------------------------------------------------

    /// The buildings a map without terrain places (tile 65, 65).
    void parseWdt(const(ubyte)[] wdt, uint mapId)
    {
        string[] names;
        foreach (chunk, body_, _; ChunkFile(wdt))
            if (chunk == "MWMO")
                foreach (n; cStrings(body_))
                    names ~= fixNameCase(plainName(n));
            else if (chunk == "MODF")
                foreach (i; 0 .. body_.length / 64)
                {
                    const id = peek!uint(body_, i * 64);
                    if (id < names.length)
                        placeWmo(body_[i * 64 + 4 .. i * 64 + 64], names[id], mapId, 65, 65);
                }
    }

    /// The doodads and buildings a terrain tile places.
    void parseAdt(const(ubyte)[] adt, uint mapId, uint tileX, uint tileY)
    {
        string[] modelNames, wmoNames;
        foreach (chunk, body_, _; ChunkFile(adt))
            switch (chunk)
            {
            case "MMDX":
                foreach (n; cStrings(body_))
                {
                    string fileName;
                    extractModel(n, fileName);
                    modelNames ~= fileName;
                }
                break;
            case "MWMO":
                foreach (n; cStrings(body_))
                    wmoNames ~= fixNameSpaces(fixNameCase(plainName(n)));
                break;
            case "MDDF":
                foreach (i; 0 .. body_.length / 36)
                {
                    const id = peek!uint(body_, i * 36);
                    if (id < modelNames.length)
                        placeModel(body_[i * 36 + 4 .. i * 36 + 36], modelNames[id], mapId, tileX, tileY);
                }
                break;
            case "MODF":
                foreach (i; 0 .. body_.length / 64)
                {
                    const id = peek!uint(body_, i * 64);
                    if (id < wmoNames.length)
                        placeWmo(body_[i * 64 + 4 .. i * 64 + 64], wmoNames[id], mapId, tileX, tileY);
                }
                break;
            default:
                break;
            }
    }

    /// Extracts the models game objects show, and the list of them.
    void extractGameObjectModels()
    {
        const displays = DbcStore!(MapName, "nsxxxxxxxxxx").parse(readFile("DBFilesClient\\GameObjectDisplayInfo.dbc"),
            "GameObjectDisplayInfo.dbc");
        ByteWriter list;
        foreach (ref display; displays.rows)
        {
            const path = display.internalName;
            if (path.length < 4)
                continue;
            const name = fixNameSpaces(fixNameCase(plainName(path)));
            string fileName = name;
            bool extracted;
            if (name.endsWith(".wmo"))
            {
                extractWmo(fixNameCase(path));
                extracted = (name in written) !is null;
            }
            else if (name.endsWith(".mdl"))
                continue;
            else
                extracted = extractModel(path, fileName);
            if (!extracted)
                continue;
            list.put(display.id);
            list.put(cast(uint) fileName.length);
            list.putBytes(cast(const(ubyte)[]) fileName);
        }
        std.file.write(outputPath(gameObjectModels), list.data);
    }

    void writeSpawn(uint mapId, uint tileX, uint tileY, uint flags, ushort adtId, uint id, Vector3 pos, Vector3 rot,
        float scale, const(AABox)* bounds, string name)
    {
        dirBin.put(mapId);
        dirBin.put(tileX);
        dirBin.put(tileY);
        dirBin.put(flags);
        dirBin.put(adtId);
        dirBin.put(id);
        putVector(dirBin, pos);
        putVector(dirBin, rot);
        dirBin.put(scale);
        if (bounds !is null)
            putBox(dirBin, *bounds);
        dirBin.put(cast(uint) name.length);
        dirBin.putBytes(cast(const(ubyte)[]) name);
        ++report.spawns;
    }
}

/// A doodad path as the archives know it: the extension made ".m2" when it is ".mdx" or ".mdl".
string modelSourceName(string path) pure @safe
{
    foreach (old; [".mdx", ".MDX", ".mdl", ".MDL"])
        if (path.endsWith(old))
            return path[0 .. $ - 2] ~ "2";
    return path;
}

struct MapName
{
    uint id;
    string internalName;
}

/// The null-terminated string at `offset`.
string cStringAt(const(ubyte)[] data, size_t offset)
{
    size_t end = offset;
    while (end < data.length && data[end] != 0)
        ++end;
    return (cast(const(char)[]) data[offset .. end]).idup;
}

/// A block of null-terminated strings, each.
string[] cStrings(const(ubyte)[] block)
{
    string[] all;
    for (size_t offset = 0; offset < block.length;)
    {
        const s = cStringAt(block, offset);
        all ~= s;
        offset += s.length + 1;
    }
    return all;
}

/// `WMOGroup`: one group file.
struct WmoGroup
{
    int groupName, mogpFlags;
    Vector3 boundLo, boundHi;
    uint liquidType, groupWmoId;
    const(ubyte)[] mopy;     // per triangle: flags, material
    ushort[] movi;
    Vector3[] movt;
    ushort[] moba;           // batches, 12 shorts each
    ushort[] doodadReferences;
    bool hasLiquid;
    int[4] liquidSize;       // xverts, yverts, xtiles, ytiles
    Vector3 liquidCorner;
    float[] liquidHeights;
    const(ubyte)[] liquidTiles;

    static WmoGroup read(const(ubyte)[] file)
    {
        WmoGroup g;
        foreach (chunk, body_, _; ChunkFile(file))
        {
            // A liquid counts only in the last chunk: any chunk after it clears it again.
            g.hasLiquid = false;
            switch (chunk)
            {
            case "MOGP":
                g.groupName = peek!int(body_, 0);
                g.mogpFlags = peek!int(body_, 8);
                g.boundLo = getVector(body_, 12);
                g.boundHi = getVector(body_, 24);
                g.liquidType = peek!uint(body_, 52);
                g.groupWmoId = peek!uint(body_, 56);
                break;
            case "MOPY":
                g.mopy = body_;
                break;
            case "MOVI":
                g.movi = shorts(body_);
                break;
            case "MOVT":
                foreach (i; 0 .. body_.length / 12)
                    g.movt ~= getVector(body_, i * 12);
                break;
            case "MOBA":
                g.moba = shorts(body_);
                break;
            case "MODR":
                g.doodadReferences = shorts(body_);
                break;
            case "MLIQ":
                g.hasLiquid = true;
                foreach (k; 0 .. 4)
                    g.liquidSize[k] = peek!int(body_, k * 4);
                g.liquidCorner = getVector(body_, 16);
                const verts = g.liquidSize[0] * g.liquidSize[1], tiles = g.liquidSize[2] * g.liquidSize[3];
                g.liquidHeights = new float[verts];
                foreach (k; 0 .. verts) // unknown words, then the height
                    g.liquidHeights[k] = peek!float(body_, 0x1E + k * 8 + 4);
                g.liquidTiles = body_[0x1E + verts * 8 .. 0x1E + verts * 8 + tiles];
                break;
            default:
                break;
            }
        }
        return g;
    }

    /// Whether the group is left out: unreachable groups and antiportals.
    bool shouldSkip(const(char)[] groupNames) const
    {
        if (mogpFlags & 0x80 || mogpFlags & 0x4000000)
            return true;
        if (groupName >= 0 && groupName < groupNames.length)
        {
            size_t end = groupName;
            while (end < groupNames.length && groupNames[end] != 0)
                ++end;
            return groupNames[groupName .. end] == "antiportal";
        }
        return false;
    }

    /// Writes the group (small data): the collision triangles. Returns their count.
    uint convert(ref ByteWriter w, uint rootFlags, string path) const
    {
        w.put(cast(uint) mogpFlags);
        w.put(groupWmoId);
        putVector(w, boundLo);
        putVector(w, boundHi);
        w.put(hasLiquid ? 1u : 0u);

        putTag(w, "GRP ");
        const batches = cast(uint)(moba.length / 12);
        w.put(batches * 4 + 4);
        w.put(batches);
        for (size_t i = 8; i < moba.length; i += 12)
            w.put(cast(uint) moba[i]);

        // Collision triangles: marked for collision, or rendered and not detail.
        const nTriangles = mopy.length / 2;
        ushort[] kept;
        auto renumber = new int[movt.length];
        renumber[] = -1;
        foreach (i; 0 .. nTriangles)
        {
            const flags = mopy[2 * i];
            const render = (flags & 0x20) && !(flags & 0x04);
            if (!(flags & 0x08) && !render)
                continue;
            foreach (j; 0 .. 3)
            {
                renumber[movi[3 * i + j]] = 1;
                kept ~= movi[3 * i + j];
            }
        }
        int nVertices;
        foreach (ref r; renumber)
            if (r == 1)
                r = nVertices++;
        const nKept = cast(uint)(kept.length / 3);
        putTag(w, "INDX");
        w.put(nKept * 6 + 4);
        w.put(nKept * 3);
        foreach (index; kept)
            w.put(cast(ushort) renumber[index]);
        putTag(w, "VERT");
        w.put(cast(uint)(nVertices * 12 + 4));
        w.put(cast(uint) nVertices);
        foreach (i, v; movt)
            if (renumber[i] >= 0)
                putVector(w, v);

        if (hasLiquid && liquidHeights.length)
        {
            // The liquid's type (wowdev.wiki).
            uint entry;
            if (rootFlags & 4)
                entry = liquidType;
            else if (liquidType == 15)
                entry = 0;
            else
                entry = liquidType + 1;
            if (!entry)
                foreach (tile; liquidTiles)
                    if ((tile & 0xF) != 15)
                    {
                        entry = (tile & 0xF) + 1;
                        break;
                    }
            if (entry && entry < 21)
                switch ((cast(ubyte) entry - 1) & 3)
                {
                case 0: entry = ((mogpFlags & 0x80000) != 0) + 1; break;
                case 1: entry = 2; break; // ocean
                case 2: entry = 3; break; // magma
                case 3: entry = path.canFind("Stratholme_raid") ? 21 : 4; break; // Naxxramas' or other slime
                default: break;
                }
            putTag(w, "LIQU");
            // Deliberately, as in the standard vmap files: the size counts each vertex's eight bytes, though four are written.
            w.put(cast(uint)(32 + liquidHeights.length * 8 + liquidTiles.length));
            foreach (k; 0 .. 4)
                w.put(liquidSize[k]);
            putVector(w, liquidCorner);
            w.put(cast(short) entry);
            w.put(ushort(0)); // the header's padding
            foreach (h; liquidHeights)
                w.put(h);
            w.putBytes(liquidTiles);
        }
        return nKept;
    }
}

ushort[] shorts(const(ubyte)[] block)
{
    auto values = new ushort[block.length / 2];
    foreach (i, ref v; values)
        v = peek!ushort(block, i * 2);
    return values;
}

public unittest
{
    assert(plainName("World\\Generic\\Lamp Post.MDX") == "Lamp Post.MDX");
    assert(fixNameCase("LAMPPOST01.MDX") == "Lamppost01.mdx" && fixNameCase("big BARREL.m2") == "Big Barrel.m2");
    assert(fixNameSpaces("Big Barrel.m2") == "Big_Barrel.m2");
    assert(modelFileName("World\\Generic\\Big BARREL.MDX") == "Big_Barrel.m2");
    assert(modelSourceName("World\\A.MDX") == "World\\A.M2");
    assert(cStrings(cast(const(ubyte)[]) "a\0bc\0") == ["a", "bc"]);
}
