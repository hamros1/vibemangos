/**
 * Objects moving to another node with a region (docs/CLUSTER.md): what their last owner
 * writes (`encodeBundle`) and their next owner reads (`decodeBundle`). A bundle lists the region's
 * cells the old owner had loaded, and every object homed there with its kind, spawn, home cell and
 * state (`Creature.saveState`, `GameObject.saveState`): the new owner rebuilds each from its spawn
 * and loads the state, so the creature goes on where it was, as it was.
 */
module dmangos.world.migration;

import dmangos.bytes : ByteReader, ByteWriter;

/// What kind of object a migrant is.
enum MigrantKind : ubyte
{
    none = 0,     /// not carried
    creature = 1,
    gameObject = 2,
    creatureRespawn = 3,   /// a timer, potentially with no live object in the bundle
    gameObjectRespawn = 4, /// ditto
}

/// An object on its way to its next owner.
struct Migrant
{
    MigrantKind kind;
    uint spawn;          /// its `creature` or `gameobject` row
    ulong home;          /// the cell it spawned in
    const(ubyte)[] state;
}

/// See the module documentation.
const(ubyte)[] encodeBundle(const(ulong)[] cells, const(Migrant)[] objects)
{
    ByteWriter w;
    w.put(cast(uint) cells.length);
    foreach (cell; cells)
        w.put(cell);
    w.put(cast(uint) objects.length);
    foreach (ref m; objects)
    {
        w.put(cast(ubyte) m.kind);
        w.put(m.spawn);
        w.put(m.home);
        w.put(cast(uint) m.state.length);
        w.putBytes(m.state);
    }
    return w.data;
}

/// See `encodeBundle`.
void decodeBundle(const(ubyte)[] bytes, out ulong[] cells, out Migrant[] objects)
{
    auto r = ByteReader(bytes);
    // Each count is checked against the bytes left before anything is allocated (a peer's frame).
    const cellCount = r.read!uint;
    r.ensureAvailable(cellCount * ulong.sizeof);
    cells = new ulong[cellCount];
    foreach (ref cell; cells)
        cell = r.read!ulong;
    const objectCount = r.read!uint;
    r.ensureAvailable(objectCount * (ubyte.sizeof + uint.sizeof + ulong.sizeof + uint.sizeof));
    objects = new Migrant[objectCount];
    foreach (ref m; objects)
    {
        m.kind = cast(MigrantKind) r.read!ubyte;
        m.spawn = r.read!uint;
        m.home = r.read!ulong;
        m.state = r.readBytes(r.read!uint).dup;
    }
}

unittest
{
    const objects = [Migrant(MigrantKind.creature, 89, 7, [1, 2, 3]), Migrant(MigrantKind.gameObject, 4, 8, [])];
    ulong[] cells;
    Migrant[] back;
    decodeBundle(encodeBundle([7, 8, 9], objects), cells, back);
    assert(cells == [7, 8, 9] && back == objects);
}

// A bundle whose counts the bytes cannot hold is refused before anything is allocated.
unittest
{
    import std.exception : assertThrown;
    import dmangos.bytes : IncompletePacketException;

    ulong[] cells;
    Migrant[] objects;
    assertThrown!IncompletePacketException(decodeBundle([0xFF, 0xFF, 0xFF, 0x7F], cells, objects));
    assertThrown!IncompletePacketException(decodeBundle([0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0x7F], cells, objects));
}
