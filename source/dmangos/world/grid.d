/**
 * The world's grid cells (CMaNGOS `GridDefines.h`): squares of 533.33 / 8
 * yards, keyed by their two coordinates. Maps keep players and spawned
 * objects by cell, and the world data indexes spawns the same way.
 */
module dmangos.world.grid;

import std.math : floor;

/// Side of a grid cell, in yards (`SIZE_OF_GRID_CELL`: 533.33 / 8).
enum float cellSize = 533.3333f / 8;

/// The cell coordinate of a world coordinate.
int cellCoordinate(float coordinate) pure nothrow @nogc @safe
{
    return cast(int) floor(coordinate / cellSize);
}

/// The key of a cell, from its coordinates.
ulong cellKey(int x, int y) pure nothrow @nogc @safe
{
    return ulong(cast(uint) x) << 32 | cast(uint) y;
}

/// The key of the cell holding a point.
ulong cellKeyAt(float x, float y) pure nothrow @nogc @safe
{
    return cellKey(cellCoordinate(x), cellCoordinate(y));
}

unittest
{
    assert(cellCoordinate(0) == 0 && cellCoordinate(-1) == -1 && cellCoordinate(cellSize) == 1);
    assert(cellKeyAt(10, -10) == cellKey(0, -1) && cellKey(0, -1) != cellKey(-1, 0));
}
