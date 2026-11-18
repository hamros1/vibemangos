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
                flight.points ~= p;
        }
    }
    return flight.points.length > 1;
}

unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : taxiNodesFormat, taxiPathFormat, taxiPathNodeFormat;

    uint bits(float f) { return *cast(uint*) &f; }
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
}
