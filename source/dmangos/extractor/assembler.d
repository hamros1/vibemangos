/**
 * Builds the vmaps from the raw extraction, as CMaNGOS's `vmap_assembler` does
 * (`vmap/TileAssembler.cpp`): from `<output>/Buildings` into `<output>/vmaps`.
 *
 * For each map in `dir_bin`: every placed model's bound (a doodad's from its vertices, turned and
 * scaled as placed), a tree over them, `MMM.vmtree` (the tree, and the models a map without terrain
 * places) and `MMM_XX_YY.vmtile` per tile (the models placed there, with their place in the tree).
 * Then every model placed or shown by a game object becomes `NAME.vmo`, its groups with a tree over
 * their triangles and one over the groups; and `temp_gameobject_models` lists the game object
 * models with their bounds.
 */
module dmangos.extractor.assembler;

import std.algorithm.sorting : sort;
import std.exception : enforce;
import std.file : exists, mkdirRecurse;
import std.format : format;
import std.path : buildPath;
static import std.file;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.log;
import dmangos.vmap.bih;
import dmangos.vmap.math;
import dmangos.vmap.model;

/// What an assembly did.
struct AssemblyReport
{
    size_t maps;    /// .vmtree files
    size_t tiles;   /// .vmtile files
    size_t models;  /// .vmo files
    string[] problems;
}

/// `TileAssembler::convertWorld2`: `<outputDir>/Buildings` to `<outputDir>/vmaps`.
AssemblyReport assembleVmaps(string outputDir, void delegate(string) progress = null)
{
    const source = buildPath(outputDir, "Buildings"), destination = buildPath(outputDir, "vmaps");
    enforce(exists(buildPath(source, "dir_bin")), "no Buildings/dir_bin: extract the vmap data first");
    mkdirRecurse(destination);

    AssemblyReport report;
    auto maps = readMapSpawns(buildPath(source, "dir_bin"));
    bool[string] modelFiles;
    RawModel[string] rawModels;

    RawModel* raw(string name)
    {
        if (auto found = name in rawModels)
            return found;
        try
            return &(rawModels[name] = RawModel.read(buildPath(source, name)));
        catch (Exception e)
        {
            report.problems ~= name ~ ": " ~ e.msg;
            return null;
        }
    }

    auto mapIds = maps.keys;
    mapIds.sort();
    foreach (mapId; mapIds)
    {
        auto map = maps[mapId];
        auto ids = map.unique.keys;
        ids.sort();
        ModelSpawn*[] spawns;
        foreach (id; ids)
        {
            auto spawn = &map.unique[id];
            if (spawn.flags & modM2)
            {
                // calculateTransformedBound: a doodad's bound is that of its vertices, as placed.
                auto model = raw(spawn.name);
                if (model is null)
                    break; // as CMaNGOS, the map's remaining models are left out
                if (model.groups.length != 1)
                    warning!"'%s' does not seem to be an M2 model"(spawn.name);
                enum float pi = 3.1415926535897932f;
                const rotation = Matrix3.fromEulerAnglesZYX(pi * spawn.rot.y / 180.0f, pi * spawn.rot.x / 180.0f,
                    pi * spawn.rot.z / 180.0f);
                AABox bound;
                bool empty = true;
                foreach (ref group; model.groups)
                    foreach (v; group.vertices)
                    {
                        const p = rotation * (v * spawn.scale);
                        if (empty)
                            bound = AABox(p, p), empty = false;
                        else
                            bound.merge(p);
                    }
                spawn.bound = bound + spawn.pos;
                spawn.flags |= modHasBound;
            }
            else if (spawn.flags & modWorldSpawn) // a WDT's origin is the map's corner, a tile's its centre
                spawn.bound = spawn.bound + Vector3(533.33333f * 32, 533.33333f * 32, 0);
            spawns ~= spawn;
            modelFiles[spawn.name] = true;
        }

        BIH tree;
        tree.build(spawns.length, (size_t i) => spawns[i].bound);
        uint[uint] nodeOf;
        foreach (i, spawn; spawns)
            nodeOf.require(spawn.id, cast(uint) i);

        enum uint globalTile = 65 << 16 | 65;
        const globals = map.tiles.get(globalTile, null);
        ByteWriter w;
        putTag(w, vmapMagic);
        w.put(cast(ubyte)(globals.length == 0)); // tiled: only maps without terrain have global models
        putTag(w, "NODE");
        tree.write(w);
        putTag(w, "GOBJ");
        foreach (id; globals)
        {
            map.unique[id].write(w);
            w.put(nodeOf.get(id, 0));
        }
        std.file.write(buildPath(destination, format!"%03d.vmtree"(mapId)), w.data);
        ++report.maps;

        auto tileKeys = map.tiles.keys;
        tileKeys.sort();
        foreach (key; tileKeys)
        {
            const entries = map.tiles[key];
            if (map.unique[entries[0]].flags & modWorldSpawn)
                continue;
            ByteWriter t;
            putTag(t, vmapMagic);
            t.put(cast(uint) entries.length);
            foreach (id; entries)
            {
                map.unique[id].write(t);
                t.put(nodeOf.get(id, 0));
            }
            std.file.write(buildPath(destination, format!"%03d_%02d_%02d.vmtile"(mapId, key >> 16, key & 0xFF)),
                t.data);
            ++report.tiles;
        }
        if (progress)
            progress(format!"map %s: %s models, %s tiles"(mapId, spawns.length, tileKeys.length));
    }

    exportGameObjectModels(source, destination, modelFiles, &raw);

    // convertRawFile: each model once.
    auto names = modelFiles.keys;
    names.sort();
    foreach (name; names)
    {
        auto model = raw(name);
        if (model is null)
            continue;
        auto world = new WorldModel;
        world.rootWmoId = model.rootWmoId;
        GroupModel[] groups;
        foreach (ref g; model.groups)
        {
            auto group = new GroupModel(g.mogpFlags, g.groupWmoId, g.bound);
            group.setMeshData(g.vertices.dup, g.triangles.dup);
            group.liquid = g.liquid;
            groups ~= group;
        }
        if (groups.length)
            world.setGroups(groups);
        world.write(buildPath(destination, name ~ ".vmo"));
        ++report.models;
    }
    return report;
}

private:

struct MapSpawns
{
    ModelSpawn[uint] unique;  // by id: the first placement read
    uint[][uint] tiles;       // packed tile -> ids, in file order
}

/// `TileAssembler::readMapSpawns`
MapSpawns*[uint] readMapSpawns(string path)
{
    MapSpawns*[uint] maps;
    auto r = ByteReader(cast(const(ubyte)[]) std.file.read(path));
    while (!r.empty)
    {
        const mapId = r.read!uint, tileX = r.read!uint, tileY = r.read!uint;
        const spawn = ModelSpawn.read(r);
        auto map = maps.require(mapId, new MapSpawns);
        map.unique.require(spawn.id, spawn);
        map.tiles[tileX << 16 | tileY] ~= spawn.id;
    }
    return maps;
}

/// `GroupModel_Raw`
struct RawGroup
{
    uint mogpFlags, groupWmoId;
    AABox bound;
    MeshTriangle[] triangles;
    Vector3[] vertices;
    WmoLiquid liquid;
}

/// `WorldModel_Raw`: a raw model file of the extraction.
struct RawModel
{
    uint rootWmoId;
    RawGroup[] groups;

    static RawModel read(string path)
    {
        auto r = ByteReader(cast(const(ubyte)[]) std.file.read(path));
        expectChunk(r, rawVmapMagic);
        r.read!uint; // collision triangles or vertices
        RawModel model;
        model.groups = new RawGroup[r.read!uint];
        model.rootWmoId = r.read!uint;
        foreach (ref g; model.groups)
        {
            g.mogpFlags = r.read!uint;
            g.groupWmoId = r.read!uint;
            g.bound = readBox(r);
            const liquidFlags = r.read!uint;
            expectChunk(r, "GRP ");
            r.read!int;
            foreach (_; 0 .. r.read!uint)
                r.read!uint;
            expectChunk(r, "INDX");
            r.read!int;
            const nIndexes = r.read!uint;
            foreach (_; 0 .. nIndexes / 3)
                g.triangles ~= MeshTriangle(r.read!ushort, r.read!ushort, r.read!ushort);
            foreach (_; 0 .. nIndexes % 3)
                r.read!ushort;
            expectChunk(r, "VERT");
            r.read!int;
            g.vertices = new Vector3[r.read!uint];
            foreach (ref v; g.vertices)
                v = readVector(r);
            if (liquidFlags & 1)
            {
                expectChunk(r, "LIQU");
                r.read!int;
                const xVerts = r.read!int, yVerts = r.read!int, xTiles = r.read!int, yTiles = r.read!int;
                const corner = readVector(r);
                const type = r.read!short;
                r.read!ushort; // padding
                g.liquid = new WmoLiquid(xTiles, yTiles, corner, type);
                enforce(xVerts * yVerts == g.liquid.heights.length, "liquid vertices do not match its tiles");
                foreach (ref h; g.liquid.heights)
                    h = r.read!float;
                g.liquid.flags[] = r.readBytes(xTiles * yTiles);
            }
        }
        return model;
    }
}

/// `TileAssembler::exportGameobjectModels`: the game object models, with their bounds as they are.
void exportGameObjectModels(string source, string destination, ref bool[string] modelFiles,
    scope RawModel* delegate(string) raw)
{
    const listPath = buildPath(source, gameObjectModels);
    if (!exists(listPath))
        return;
    auto r = ByteReader(cast(const(ubyte)[]) std.file.read(listPath));
    ByteWriter w;
    while (!r.empty)
    {
        const displayId = r.read!uint;
        const name = r.readString(r.read!uint);
        auto model = raw(name);
        if (model is null)
            continue;
        modelFiles[name] = true;
        AABox bounds;
        bool empty = true;
        foreach (ref g; model.groups)
            foreach (v; g.vertices)
            {
                if (empty)
                    bounds = AABox(v, v), empty = false;
                else
                    bounds.merge(v);
            }
        w.put(displayId);
        w.put(cast(uint) name.length);
        w.putBytes(cast(const(ubyte)[]) name);
        putBox(w, bounds);
    }
    std.file.write(buildPath(destination, gameObjectModels), w.data);
}
