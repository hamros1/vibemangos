/**
 * Flight paths: the taxi network of `TaxiNodes.dbc`, `TaxiPath.dbc` and
 * `TaxiPathNode.dbc`, which nodes a character knows (`taximask`, a bit a node), the node a flight
 * master stands at, and a flight over one or more legs: their points one after the other, and
 * their price. `dmangos.world.taxihandlers` flies it.
 */
module dmangos.world.taxi;

import dmangos.vmap.math : Vector3;
import dmangos.world.clientdata : ClientData, Team, TaxiNodesEntry;
import dmangos.world.movement : Position;

/// How fast a player flies, in yards a second.
enum float flightSpeed = 32;

/// The answer to a flight request (`SMSG_ACTIVATETAXIREPLY`).
enum TaxiReply : uint
{
    ok = 0,
    unspecified = 1,
    noSuchPath = 2,
    notEnoughMoney = 3,
    tooFarAway = 4,
    noVendorNearby = 5,
    notVisited = 6,
    playerBusy = 7,
    alreadyMounted = 8,
    shapeshifted = 9,
    moving = 10,
    sameNode = 11,
    notStanding = 12,
}

/// Whether the mask has node `id`.
bool knowsNode(const uint[8] mask, uint id) pure nothrow @nogc @safe
{
    if (id == 0 || id > 8 * 32)
        return false;
    return (mask[(id - 1) / 32] & (1u << ((id - 1) % 32))) != 0;
}

/// Adds node `id` to the mask: true if it was not known.
bool learnNode(ref uint[8] mask, uint id) pure nothrow @nogc @safe
{
    if (id == 0 || id > 8 * 32 || knowsNode(mask, id))
        return false;
    mask[(id - 1) / 32] |= 1u << ((id - 1) % 32);
    return true;
}

/// The network node nearest `at` on `mapId` with a mount for `team`; 0 if none.
uint nearestTaxiNode(const ClientData client, Position at, uint mapId, Team team)
{
    uint best;
    float bestDistance = float.max;
    foreach (id; 1 .. client.taxiNodes.idLimit)
    {
        const node = client.taxiNodes.lookup(id);
        if (node is null || node.mapId != mapId || !node.mountCreature[team == Team.alliance ? 1 : 0])
            continue;
        if (id !in client.taxiNetwork)
            continue;
        const d = (node.x - at.x) ^^ 2 + (node.y - at.y) ^^ 2 + (node.z - at.z) ^^ 2;
        if (d < bestDistance)
        {
            bestDistance = d;
            best = id;
        }
    }
    return best;
}

/// The creature a flight from `node` rides: the node's mount for `team`, else the other's.
uint taxiMountCreature(const(TaxiNodesEntry)* node, Team team) pure nothrow @nogc @safe
{
    if (node is null)
        return 0;
    const own = node.mountCreature[team == Team.alliance ? 1 : 0], other = node.mountCreature[team == Team.alliance ? 0 : 1];
    return own ? own : other;
}

/// A flight planned: its points in order on one map, the price, the end and the first node.
struct TaxiFlight
{
    Vector3[] points;
    uint cost;
    uint from, to;
    uint mapId;
    /// For each of `points`: the path (`TaxiPath.dbc`) it is on and its index there, for a save in flight.
    PathPoint[] pathPoints;
}

/// A point of a flight path: the path and the point's index on it.
struct PathPoint
{
    uint path;
    uint index;
}

/**
 * A flight saved in `characters.taxi_path`, in CMaNGOS's format: `resumenode#pathid` (the path flown, and
 * the point on it the flight resumes from). Only the leg under way is saved, as CMaNGOS does by default: a
 * flight over several legs, resumed, ends at the end of that leg.
 */
string taxiPathText(PathPoint at) pure @safe
{
    import std.format : format;

    return at.path ? format!"%s#%s"(at.index, at.path) : "";
}

/// What a `taxi_path` read gave.
enum SavedFlight
{
    none,     /// not in flight
    flight,   /// a flight to resume (`at`)
    node,     /// a single node (an older format's destination): the character goes there
    invalid,  /// unreadable: the character goes home
}

/// Reads a `taxi_path`: see `taxiPathText`.
SavedFlight readTaxiPath(string text, out PathPoint at, out uint node) pure @safe
{
    import std.algorithm.iteration : splitter;
    import std.array : array;
    import std.conv : ConvException, to;
    import std.string : strip;

    text = text.strip;
    if (text.length == 0)
        return SavedFlight.none;
    uint[] numbers;
    try
        foreach (part; text.splitter('#'))
            numbers ~= part.strip.to!uint;
    catch (ConvException)
        return SavedFlight.invalid;
    if (numbers.length == 1)
    {
        node = numbers[0];
        return SavedFlight.node;
    }
    at = PathPoint(numbers[1], numbers[0]); // more paths after the first: not saved by us, and not flown
    return SavedFlight.flight;
}

/// The point to save for a flight at its `points[next]` (the point ahead): never a path's first or last point.
PathPoint resumePoint(const ClientData client, const ref TaxiFlight flight, size_t next)
{
    if (flight.pathPoints.length == 0)
        return PathPoint.init;
    if (next >= flight.pathPoints.length)
        next = flight.pathPoints.length - 1;
    PathPoint at = flight.pathPoints[next];
    const points = client.taxiPathPoints.get(at.path, null);
    if (points.length < 3)
        return PathPoint(at.path, points.length ? points[0].index : 0);
    const first = points[0].index + 1, last = points[$ - 1].index - 1;
    at.index = at.index < first ? first : at.index > last ? last : at.index;
    return at;
}

/**
 * The rest of a saved flight: path `at.path` from its point `at.index` to its end, on the point's map; its
 * nodes the path's. Nothing is paid again.
 */
bool resumeFlight(const ClientData client, PathPoint at, out TaxiFlight flight)
{
    const entry = client.taxiPaths.lookup(at.path);
    const points = client.taxiPathPoints.get(at.path, null);
    if (entry is null || points.length < 2)
        return false;
    size_t start = points.length;
    foreach (i, point; points)
        if (point.index == at.index)
        {
            start = i;
            break;
        }
    if (start + 1 >= points.length)
        return false;
    flight.from = entry.from;
    flight.to = entry.to;
    flight.mapId = points[start].mapId;
    foreach (point; points[start .. $])
    {
        if (point.mapId != flight.mapId)
            return false; // a flight that changes maps: not yet
        flight.points ~= Vector3(point.x, point.y, point.z);
        flight.pathPoints ~= PathPoint(at.path, point.index);
    }
    return true;
}

/**
 * Plans a flight over `nodes` (each leg from one to the next): every leg must be
 * a path of the network on the first node's map; the points of all legs one after another, the
 * prices added (times `priceRate`, the reputation's discount).
 */
bool planFlight(const ClientData client, const(uint)[] nodes, float priceRate, out TaxiFlight flight)
{
    import std.math : floor;

    if (nodes.length < 2)
        return false;
    const first = client.taxiNodes.lookup(nodes[0]);
    if (first is null)
        return false;
    flight.from = nodes[0];
    flight.to = nodes[$ - 1];
    flight.mapId = first.mapId;
    foreach (i; 0 .. nodes.length - 1)
    {
        const toward = nodes[i] in client.taxiPathBetween;
        const path = toward is null ? null : nodes[i + 1] in *toward;
        if (path is null)
            return false;
        const entry = client.taxiPaths.lookup(*path);
        flight.cost += cast(uint) floor(entry.price * priceRate);
        foreach (point; client.taxiPathPoints.get(*path, null))
        {
            if (point.mapId != flight.mapId)
                return false; // a flight that changes maps: not yet
            const p = Vector3(point.x, point.y, point.z);
            if (flight.points.length == 0 || flight.points[$ - 1] != p)
            {
                flight.points ~= p;
                flight.pathPoints ~= PathPoint(*path, point.index);
            }
        }
    }
    return flight.points.length > 1;
}

unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : taxiNodesFormat, taxiPathFormat, taxiPathNodeFormat;

    import dmangos.bytes : bits = floatBits;
    uint[] node(uint id, float x, float y, uint alliance)
    {
        auto row = new uint[taxiNodesFormat.length];
        row[0] = id;
        row[2] = bits(x);
        row[3] = bits(y);
        row[15] = alliance;
        return row;
    }
    uint[] point(uint id, uint path, uint index, float x)
    {
        return [id, path, index, 0, bits(x), bits(0), bits(0), 0, 0];
    }

    auto client = new ClientData;
    client.taxiNodes = typeof(client.taxiNodes).parse(buildDbc(taxiNodesFormat,
        [node(2, 0, 0, 541), node(5, 100, 0, 541), node(7, 300, 0, 541)]), "TaxiNodes.dbc");
    client.taxiPaths = typeof(client.taxiPaths).parse(buildDbc(taxiPathFormat, [[10u, 2, 5, 100], [11u, 5, 7, 50]]),
        "TaxiPath.dbc");
    client.taxiPathNodes = typeof(client.taxiPathNodes).parse(buildDbc(taxiPathNodeFormat,
        [point(1, 10, 1, 50), point(2, 10, 0, 0), point(3, 10, 2, 100), point(4, 11, 0, 100), point(5, 11, 1, 300)]),
        "TaxiPathNode.dbc");
    client.buildIndexes();

    assert(nearestTaxiNode(client, Position(90, 5, 0), 0, Team.alliance) == 5);
    assert(nearestTaxiNode(client, Position(90, 5, 0), 0, Team.horde) == 0, "no Horde mounts here");
    uint[8] mask;
    assert(learnNode(mask, 5) && !learnNode(mask, 5) && knowsNode(mask, 5) && mask[0] == 0x10);

    TaxiFlight f;
    assert(planFlight(client, [2u, 5, 7], 0.9f, f));
    assert(f.cost == 90 + 45 && f.to == 7);
    assert(f.points == [Vector3(0, 0, 0), Vector3(50, 0, 0), Vector3(100, 0, 0), Vector3(300, 0, 0)],
        "the legs joined, in order");
    assert(!planFlight(client, [2u, 7], 1, f), "no direct path");

    // Saved in flight: the path point ahead, never a path's first or last; a path of two points from its first.
    assert(planFlight(client, [2u, 5, 7], 1, f)); // again: the failed plan above emptied it
    assert(f.pathPoints == [PathPoint(10, 0), PathPoint(10, 1), PathPoint(10, 2), PathPoint(11, 1)]);
    assert(resumePoint(client, f, 1) == PathPoint(10, 1) && resumePoint(client, f, 0) == PathPoint(10, 1));
    assert(resumePoint(client, f, 2) == PathPoint(10, 1), "not the last point either");
    assert(resumePoint(client, f, 3) == PathPoint(11, 0));
    assert(taxiPathText(PathPoint(10, 1)) == "1#10" && taxiPathText(PathPoint.init) == "");

    PathPoint at;
    uint saved;
    assert(readTaxiPath("1#10", at, saved) == SavedFlight.flight && at == PathPoint(10, 1));
    assert(readTaxiPath("1#10#11", at, saved) == SavedFlight.flight && at == PathPoint(10, 1), "the first leg only");
    assert(readTaxiPath("5", at, saved) == SavedFlight.node && saved == 5, "an older format's destination");
    assert(readTaxiPath("", at, saved) == SavedFlight.none && readTaxiPath("a#b", at, saved) == SavedFlight.invalid);

    // Resumed: the rest of the leg from the point, to the leg's end node.
    TaxiFlight rest;
    assert(resumeFlight(client, PathPoint(10, 1), rest));
    assert(rest.points == [Vector3(50, 0, 0), Vector3(100, 0, 0)] && rest.from == 2 && rest.to == 5 && rest.cost == 0);
    assert(!resumeFlight(client, PathPoint(10, 2), rest), "nothing left after the last point");
    assert(!resumeFlight(client, PathPoint(12, 0), rest), "no such path");
}
