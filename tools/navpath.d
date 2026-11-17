/**
 * Finds a path over a map's movement maps, for checking them by hand:
 *
 *   navpath DATA_DIR MAP X1 Y1 Z1 X2 Y2 Z2
 *
 * loads every `.mmtile` of the map from DATA_DIR/mmaps and prints the corners of the way.
 * Build: dmd -Isource tools/navpath.d source/dmangos/navigation.d source/dmangos/vmap/math.d
 *        source/dmangos/bytes.d thirdparty/build/libdmnav.a -L-lstdc++
 */
module navpath;

import std.conv : to;
import std.file : dirEntries, read, SpanMode;
import std.format : format;
import std.path : baseName, buildPath;
import std.stdio : writefln;

import dmangos.bytes : ByteReader;
import dmangos.navigation;
import dmangos.vmap.math : Vector3;

int main(string[] args)
{
    if (args.length != 9)
    {
        writefln("usage: navpath DATA_DIR MAP X1 Y1 Z1 X2 Y2 Z2");
        return 2;
    }
    const mapId = args[2].to!uint;
    auto mesh = new NavMesh;
    foreach (entry; dirEntries(buildPath(args[1], "mmaps"), format!"%03d*.mmtile"(mapId), SpanMode.shallow))
    {
        const name = baseName(entry.name);
        const bytes = cast(const(ubyte)[]) read(entry.name);
        const gx = name[3 .. 5].to!int, gy = name[5 .. 7].to!int;
        const t = meshTileOf(gx, gy);
        if (!mesh.addTile(t[0], t[1], bytes[20 .. $]))
            writefln("tile %s refused", name);
    }
    writefln("%s tiles", mesh.tileCount);
    const from = Vector3(args[3].to!float, args[4].to!float, args[5].to!float);
    const to_ = Vector3(args[6].to!float, args[7].to!float, args[8].to!float);
    const path = mesh.findPath(from, to_);
    writefln("%s corners%s", path.points.length, path.partial ? " (partial)" : "");
    foreach (p; path.points)
        writefln("  %.1f %.1f %.1f", p.x, p.y, p.z);
    return 0;
}
