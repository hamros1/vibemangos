/**
 * The world divided into regions that nodes own (docs/CLUSTER.md).
 *
 * A region is a rectangle of map cells (`dmangos.world.grid`, 66.67 yards). Every map starts as one
 * region over the whole grid; `partition` splits the most expensive region at the median of its
 * cost, along the longer side of where that cost lies, until there are as many regions as asked for
 * (a k-d tree whose leaves are the regions). Cost, until the cluster measures it, is the
 * number of creature and game object spawns in a cell: what the benchmarks show spread-out load is
 * made of. A city full of spawns ends up in small regions, an empty sea in one large one.
 *
 * `assign` gives unowned regions to the least loaded nodes, most expensive first; `rebalance` moves
 * as few regions as it can to even nodes out after one joins.
 */
module dmangos.cluster.regions;

import std.algorithm.comparison : max, min;
import std.algorithm.sorting : sort;

import dmangos.serialization : LengthPrefix;
import dmangos.world.grid : cellKey;

@safe: // the compiler checks every function here

/// The cell coordinates of the world: 64 grids of 8 cells either side.
enum int cellMin = -256, cellMax = 256;

/// Cells [x0, x1) × [y0, y1).
struct CellRect
{
    int x0 = cellMin;
    int y0 = cellMin;
    int x1 = cellMax;
    int y1 = cellMax;

    /// Whether cell (x, y) is inside.
    bool contains(int x, int y) const pure nothrow @nogc @safe
    {
        return x >= x0 && x < x1 && y >= y0 && y < y1;
    }

    /// Whether the cell with this key is inside.
    bool containsKey(ulong key) const pure nothrow @nogc @safe
    {
        return contains(cast(int)(key >> 32), cast(int) cast(uint) key);
    }
}

/// Where a region stands with its owner.
enum RegionState : ubyte
{
    unowned = 0,  /// nobody may simulate it (waiting for a lost owner's lease to end, or for a node)
    granted = 1,  /// `owner` simulates it
    revoking = 2, /// `owner` must stop and say so; it is moving elsewhere
}

/// A region and who owns it.
struct Region
{
    uint id;
    uint map;
    CellRect rect;
    ushort owner;        /// node id; 0 for none
    ulong epoch;         /// increases whenever the region is granted anew: a fencing token
    RegionState state;
    ushort next;         /// while revoking: the node it goes to, which the owner sends its objects to
}

/// Spawns (or other cost) per cell: map -> cell key -> cost.
alias CellCosts = uint[ulong][uint];

/// The cost of a rectangle of a map.
ulong costOf(const CellCosts costs, uint map, CellRect rect) pure @safe
{
    ulong total;
    if (const cells = map in costs)
        foreach (key, cost; *cells)
            if (rect.containsKey(key))
                total += cost;
    return total;
}

/**
 * Divides the maps into regions until none holds more than 1/`count` of the world's cost (or cannot
 * be split, its cost all in one cell), splitting the most expensive region first: a continent is cut
 * into many regions, a small dungeon stays one. Every map is at least one region; a map in `whole` (a
 * dungeon: one node hosts all its copies) is exactly one. Regions get ids from 1, are unowned, and
 * have epoch 0.
 */
Region[] partition(const uint[] maps, const CellCosts costs, size_t count, const bool[uint] whole = null)
{
    static struct Leaf
    {
        uint map;
        CellRect rect;
        ulong cost;
        bool splittable = true;
    }

    Leaf[] leaves;
    ulong total;
    foreach (map; maps)
    {
        leaves ~= Leaf(map, CellRect.init, costOf(costs, map, CellRect.init));
        leaves[$ - 1].splittable = (map in whole) is null;
        total += leaves[$ - 1].cost;
    }
    const limit = count ? total / count : total;
    while (true)
    {
        size_t best = size_t.max;
        foreach (i, ref leaf; leaves)
            if (leaf.splittable && leaf.cost > limit && (best == size_t.max || leaf.cost > leaves[best].cost))
                best = i;
        if (best == size_t.max)
            break;
        CellRect a, b;
        const cells = leaves[best].map in costs;
        if (cells is null || !split(leaves[best].rect, *cells, a, b))
        {
            leaves[best].splittable = false;
            continue;
        }
        const map = leaves[best].map;
        leaves[best] = Leaf(map, a, costOf(costs, map, a));
        leaves ~= Leaf(map, b, costOf(costs, map, b));
    }

    // Ids in a stable order: by map, then position.
    leaves.sort!((p, q) => p.map != q.map ? p.map < q.map : p.rect.x0 != q.rect.x0 ? p.rect.x0 < q.rect.x0
        : p.rect.y0 < q.rect.y0);
    Region[] regions;
    foreach (i, leaf; leaves)
        regions ~= Region(cast(uint)(i + 1), leaf.map, leaf.rect);
    return regions;
}

/**
 * Splits `rect` in two at the median of the cost inside it, across the longer side of the box
 * around that cost. False if it cannot be split: no cost, or all of it in one cell.
 */
bool split(CellRect rect, const uint[ulong] cells, out CellRect a, out CellRect b)
{
    static struct Cell
    {
        int x, y;
        uint cost;
    }

    Cell[] inside;
    ulong total;
    int minX = int.max, minY = int.max, maxX = int.min, maxY = int.min;
    foreach (key, cost; cells)
        if (cost && rect.containsKey(key))
        {
            const x = cast(int)(key >> 32), y = cast(int) cast(uint) key;
            inside ~= Cell(x, y, cost);
            total += cost;
            minX = min(minX, x), maxX = max(maxX, x), minY = min(minY, y), maxY = max(maxY, y);
        }
    if (total == 0 || (minX == maxX && minY == maxY))
        return false;

    const alongX = maxX - minX >= maxY - minY;
    inside.sort!((p, q) => alongX ? p.x < q.x : p.y < q.y);
    // The first coordinate at which half the cost is behind; both sides keep some cost.
    ulong behind;
    int at = alongX ? maxX : maxY;
    foreach (cell; inside)
    {
        behind += cell.cost;
        if (2 * behind >= total)
        {
            at = (alongX ? cell.x : cell.y) + 1;
            break;
        }
    }
    const low = alongX ? minX : minY, high = alongX ? maxX : maxY;
    at = max(low + 1, min(at, high));
    a = rect;
    b = rect;
    if (alongX)
        a.x1 = b.x0 = at;
    else
        a.y1 = b.y0 = at;
    return true;
}

/// Cuts `rect` in two halves along its longer side; false if it is a single cell.
bool halve(const CellRect rect, out CellRect a, out CellRect b) pure nothrow @nogc @safe
{
    const width = rect.x1 - rect.x0, height = rect.y1 - rect.y0;
    if (width < 2 && height < 2)
        return false;
    a = rect;
    b = rect;
    if (width >= height)
        a.x1 = b.x0 = rect.x0 + width / 2;
    else
        a.y1 = b.y0 = rect.y0 + height / 2;
    return true;
}

/// Whether `outer` holds every cell of `inner`.
bool contains(const CellRect outer, const CellRect inner) pure nothrow @nogc @safe
{
    return inner.x0 >= outer.x0 && inner.x1 <= outer.x1 && inner.y0 >= outer.y0 && inner.y1 <= outer.y1;
}

/// The union of two rectangles that share a whole edge (it is then a rectangle); false otherwise.
bool unionOf(const CellRect a, const CellRect b, out CellRect union_) pure nothrow @nogc @safe
{
    if (a.y0 == b.y0 && a.y1 == b.y1 && (a.x1 == b.x0 || b.x1 == a.x0))
    {
        union_ = CellRect(a.x0 < b.x0 ? a.x0 : b.x0, a.y0, a.x1 > b.x1 ? a.x1 : b.x1, a.y1);
        return true;
    }
    if (a.x0 == b.x0 && a.x1 == b.x1 && (a.y1 == b.y0 || b.y1 == a.y0))
    {
        union_ = CellRect(a.x0, a.y0 < b.y0 ? a.y0 : b.y0, a.x1, a.y1 > b.y1 ? a.y1 : b.y1);
        return true;
    }
    return false;
}

/// The region of `regions` holding cell (x, y) of `map`, or null.
inout(Region)* regionAt(return scope inout(Region)[] regions, uint map, int x, int y) pure nothrow @nogc @safe
{
    foreach (i; 0 .. regions.length)
        if (regions[i].map == map && regions[i].rect.contains(x, y))
            return &regions[i];
    return null;
}

/// What each node's granted (and revoking) regions cost.
ulong[ushort] loads(const Region[] regions, const ulong[uint] cost, const ushort[] nodes)
{
    ulong[ushort] load;
    foreach (node; nodes)
        load[node] = 0;
    foreach (ref r; regions)
        if (r.owner && r.state != RegionState.unowned)
            if (auto l = r.owner in load)
                *l += cost.get(r.id, 0);
    return load;
}

/**
 * Gives every unowned region not in `held` to a node: the most expensive first, each to the node
 * with the least load so far (longest processing time first). Returns the ids it assigned, with the
 * chosen owner set; the caller grants them.
 */
uint[] assign(Region[] regions, const ulong[uint] cost, const ushort[] nodes, const bool[uint] held)
{
    if (nodes.length == 0)
        return null;
    auto load = loads(regions, cost, nodes);
    size_t[] waiting;
    foreach (i, ref r; regions)
        if (r.state == RegionState.unowned && r.id !in held)
            waiting ~= i;
    waiting.sort!((p, q) => cost.get(regions[p].id, 0) != cost.get(regions[q].id, 0)
        ? cost.get(regions[p].id, 0) > cost.get(regions[q].id, 0) : regions[p].id < regions[q].id);
    uint[] assigned;
    foreach (i; waiting)
    {
        ushort lightest = nodes[0];
        foreach (node; nodes)
            if (load[node] < load[lightest] || (load[node] == load[lightest] && node < lightest))
                lightest = node;
        regions[i].owner = lightest;
        load[lightest] += cost.get(regions[i].id, 0);
        assigned ~= regions[i].id;
    }
    return assigned;
}

/// A region to move from one node to another.
struct Move
{
    uint region;
    ushort from, to;
}

/**
 * Moves that bring the busiest and idlest nodes closer, as few as it takes: the most expensive
 * granted region of the busiest node that still leaves it at least as busy as the idlest one, again
 * and again, while the gap is over `tolerance` (a fraction of the mean load).
 */
Move[] rebalance(const Region[] regions, const ulong[uint] cost, const ushort[] nodes, double tolerance = 0.2,
    const bool[uint] frozen = null, size_t maxMoves = size_t.max)
{
    if (nodes.length < 2)
        return null;
    auto load = loads(regions, cost, nodes);
    bool[uint] moved;
    Move[] moves;
    ulong total;
    foreach (l; load)
        total += l;
    const mean = cast(double) total / nodes.length;
    foreach (_; 0 .. regions.length)
    {
        ushort busiest = nodes[0], idlest = nodes[0];
        foreach (node; nodes)
        {
            if (load[node] > load[busiest] || (load[node] == load[busiest] && node < busiest))
                busiest = node;
            if (load[node] < load[idlest] || (load[node] == load[idlest] && node < idlest))
                idlest = node;
        }
        const gap = load[busiest] - load[idlest];
        if (gap <= tolerance * mean || gap == 0)
            break;
        const(Region)* best;
        foreach (i; 0 .. regions.length)
        {
            const r = &regions[i];
            const c = cost.get(r.id, 0);
            if (r.owner == busiest && r.state == RegionState.granted && r.id !in moved && r.id !in frozen && c > 0
                && 2 * c <= gap && (best is null || c > cost.get(best.id, 0)))
                best = r;
        }
        if (best is null)
            break;
        const c = cost.get(best.id, 0);
        moves ~= Move(best.id, busiest, idlest);
        moved[best.id] = true;
        if (moves.length >= maxMoves)
            break;
        load[busiest] -= c;
        load[idlest] += c;
    }
    return moves;
}

version (unittest)
{
    private CellCosts sampleCosts()
    {
        CellCosts costs;
        // Map 0: a dense city at cells (10..12, 10..12), a village at (100, -50), scattered spawns.
        foreach (x; 10 .. 13)
            foreach (y; 10 .. 13)
                costs[0][cellKey(x, y)] = 50;
        costs[0][cellKey(100, -50)] = 40;
        costs[0][cellKey(-200, 200)] = 5;
        costs[0][cellKey(30, 30)] = 5;
        // Map 1: one cell.
        costs[1][cellKey(0, 0)] = 10;
        return costs;
    }
}

unittest
{
    const costs = sampleCosts();
    CellRect a, b;
    assert(split(CellRect.init, costs[0], a, b));
    assert(costOf(costs, 0, a) + costOf(costs, 0, b) == costOf(costs, 0, CellRect.init));
    assert(costOf(costs, 0, a) > 0 && costOf(costs, 0, b) > 0, "both halves keep some cost");
    assert(!split(CellRect.init, costs[1], a, b), "all in one cell");

    // No region over a fifth of the cost (102): the city is cut into small regions, map 1 and the
    // empty map 2 stay whole.
    auto regions = partition([0u, 1, 2], costs, 5);
    ulong total;
    size_t onMap0;
    foreach (r; regions)
    {
        const c = costOf(costs, r.map, r.rect);
        total += c;
        onMap0 += r.map == 0;
        assert(c <= 102 || c == 50, "small enough, or one cell");
    }
    assert(total == 450 + 40 + 10 + 10);
    assert(onMap0 >= 5 && regions.length == onMap0 + 2);
    // Every cell of every map is in exactly one region.
    foreach (map; 0u .. 3)
        foreach (cell; [[10, 10], [12, 12], [100, -50], [-256, -256], [255, 255], [0, 0]])
        {
            size_t found;
            foreach (ref r; regions)
                found += r.map == map && r.rect.contains(cell[0], cell[1]);
            assert(found == 1);
        }
    assert(regionAt(regions, 0, 11, 11) !is null && regionAt(regions, 5, 0, 0) is null);
    assert(regions[0].id == 1 && regions[$ - 1].map == 2);

    // Same input, same regions.
    assert(partition([0u, 1, 2], costs, 5) == regions);
    assert(partition([0u, 1, 2, 3, 4], costs, 1).length == 5, "one region per map is enough for 1");
    assert(partition([0u, 1, 2], costs, 5, [0: true]).length < regions.length, "map 0 is kept whole");
    foreach (r; partition([0u, 1, 2], costs, 5, [0: true]))
        assert(r.map != 0 || r.rect == CellRect.init);
}

unittest
{
    // Six regions of costs 60, 50, 40, 30, 20, 10 to two nodes: 110 and 100.
    Region[] regions;
    ulong[uint] cost;
    foreach (uint i; 1 .. 7)
    {
        regions ~= Region(i, 0, CellRect(i, 0, i + 1, 1));
        cost[i] = 70 - 10 * i;
    }
    const assigned = assign(regions, cost, [1, 2], null);
    assert(assigned.length == 6);
    foreach (ref r; regions)
        r.state = RegionState.granted;
    const load = loads(regions, cost, [1, 2]);
    assert(load[1] + load[2] == 210 && load[1] >= 100 && load[2] >= 100);
    assert(assign(regions, cost, [1, 2], null).length == 0, "nothing is unowned now");

    // A third node joins: a few regions move to it, and the load evens out.
    const moves = rebalance(regions, cost, [1, 2, 3]);
    assert(moves.length >= 1 && moves.length <= 3);
    foreach (m; moves)
        assert(m.to == 3);
    auto after = regions.dup;
    foreach (m; moves)
        foreach (ref r; after)
            if (r.id == m.region)
                r.owner = m.to;
    const balanced = loads(after, cost, [1, 2, 3]);
    assert(balanced[3] >= 40, "the new node takes a fair share");
    assert(rebalance(after, cost, [1, 2, 3]).length == 0, "balanced enough: nothing more moves");
}
