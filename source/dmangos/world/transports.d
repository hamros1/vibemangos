/**
 * Ships and zeppelins: game objects of type 15 (`GAMEOBJECT_TYPE_MO_TRANSPORT`) that sail a taxi path
 * (`TaxiPathNode.dbc`, the template's `data0`) round and round, crossing from one continent to another.
 *
 * The client moves a ship along its path by itself, from the path, the template's speed (`data1`) and
 * acceleration (`data2`) and the transport time in the ship's create block. The server works out the same
 * schedule (`generatePath`): the path is cut into key frames, one per path node, each with the distance
 * along a Catmull-Rom spline from the one before; the ship speeds up from each stop at the template's
 * acceleration, sails at its speed, and slows down to the next stop; it waits at a stop for the node's
 * delay. A node that changes map (or is flagged to teleport) ends a leg: arriving there, the ship is taken
 * to the next node's map, and so are the players aboard. A round takes `transports.period` milliseconds.
 *
 * Every node of a cluster derives where each ship is from the wall clock (`transportClock`), so they agree
 * with each other and with the clients, which are given the same clock's time.
 */
module dmangos.world.transports;

import std.math : PI, atan2, sqrt;
import dmangos.world.map : MapObject;

/// A point of a ship's path: a `TaxiPathNode.dbc` row.
struct PathNode
{
    uint map;
    float x = 0, y = 0, z = 0;
    uint actionFlag; /// 1: teleport from here; 2: a stop
    uint delay;      /// seconds waited at a stop
}

/// A path node with its place in the ship's schedule (milliseconds from the start of a round).
struct KeyFrame
{
    PathNode node;
    float facing = 0;          /// the ship's facing here
    float distSinceStop = -1;  /// along the path from the last stop
    float distUntilStop = -1;  /// to the next stop
    float distFromPrev = -1;   /// from the frame before
    float nextDistFromPrev = 0;
    float timeFrom = 0;        /// seconds since the last stop
    float timeTo = 0;          /// seconds to the next stop
    bool teleport;             /// arriving here, the ship goes on to the next frame's map
    uint arriveTime;
    uint departureTime;
    uint nextArriveTime;       /// when it arrives at the next frame

    /// A stop: the ship waits here.
    @property bool isStop() const pure nothrow @nogc @safe
    {
        return node.actionFlag == 2;
    }
}

private struct V3
{
    float x = 0, y = 0, z = 0;

    V3 opBinary(string op)(const V3 v) const pure nothrow @nogc @safe if (op == "+" || op == "-")
    {
        return V3(mixin("x " ~ op ~ " v.x"), mixin("y " ~ op ~ " v.y"), mixin("z " ~ op ~ " v.z"));
    }

    V3 opBinary(string op : "*")(float k) const pure nothrow @nogc @safe
    {
        return V3(x * k, y * k, z * k);
    }

    float length() const pure nothrow @nogc @safe
    {
        return sqrt(x * x + y * y + z * z);
    }

    /// `this + (to - this) * t`.
    V3 lerp(const V3 to, float t) const pure nothrow @nogc @safe
    {
        return this + (to - this) * t;
    }
}

/// A Catmull-Rom point between `p[1]` and `p[2]` at `t` (0 to 1).
private V3 catmullRom(const V3[] p, float t) pure nothrow @nogc @safe
{
    const t3 = t * t * t, t2 = t * t;
    const w0 = -0.5f * t3 + t2 - 0.5f * t;
    const w1 = 1.5f * t3 - 2.5f * t2 + 1;
    const w2 = -1.5f * t3 + 2 * t2 + 0.5f * t;
    const w3 = 0.5f * t3 - 0.5f * t2;
    return p[0] * w0 + p[1] * w1 + p[2] * w2 + p[3] * w3;
}

/**
 * The distances along a Catmull-Rom spline through `controls` (each segment measured in three straight
 * steps): `result[k]` is the distance from the first point to point `k - 1` (`result[0]` and `result[1]` 0).
 */
private float[] splineLengths(const V3[] controls) pure nothrow @safe
{
    const n = controls.length;
    if (n < 2)
        return new float[n + 1];
    // A control point before the first, and the last again after it.
    const V3[] points = [controls[0].lerp(controls[1], -1)] ~ controls ~ [controls[n - 1]];
    auto lengths = new float[n + 1];
    lengths[] = 0;
    double total = 0;
    foreach (i; 1 .. n)
    {
        const p = points[i - 1 .. i + 3];
        V3 current = p[1];
        double segment = 0;
        foreach (step; 1 .. 4)
        {
            const next = catmullRom(p, step / 3.0f);
            segment += (next - current).length;
            current = next;
        }
        total += cast(float) segment;
        lengths[i + 1] = cast(float) total;
    }
    return lengths;
}

/// An angle within [0, 2 pi).
private float normalized(float o) pure nothrow @nogc @safe
{
    while (o < 0)
        o += 2 * PI;
    while (o >= 2 * PI)
        o -= 2 * PI;
    return o;
}

/**
 * A ship's schedule along `path` (its taxi path's nodes, in order) at `speed` yards a second and
 * `acceleration` yards a second squared; `period`, if given, is a round's length (`transports.period`),
 * which the last frame's departure is set to. Empty if the path is too short.
 */
KeyFrame[] generatePath(const PathNode[] path, float speed, float acceleration, uint period = 0) pure @safe
{
    if (path.length < 3 || !(speed > 0) || !(acceleration > 0))
        return null;
    // Facings: along the path, from the nodes on either side.
    V3[] all;
    foreach (ref n; path)
        all ~= V3(n.x, n.y, n.z);
    all = [all[0].lerp(all[1], -0.2f)] ~ all;
    all ~= all[$ - 1].lerp(all[$ - 2], -0.2f);

    KeyFrame[] frames;
    V3[] splinePath;
    bool mapChange;
    foreach (i; 1 .. path.length - 1)
    {
        if (mapChange)
        {
            mapChange = false;
            continue;
        }
        const node = path[i];
        if ((node.actionFlag & 1) || node.map != path[i + 1].map)
        {
            if (frames.length)
                frames[$ - 1].teleport = true;
            mapChange = true;
            continue;
        }
        KeyFrame k;
        k.node = node;
        const h = (all[i + 2] - all[i]) * 0.5f;
        k.facing = normalized(atan2(h.y, h.x) + PI);
        frames ~= k;
        splinePath ~= V3(node.x, node.y, node.z);
    }
    if (frames.length == 0)
        return null;
    frames[$ - 1].teleport = true;

    const accelDist = 0.5f * speed * speed / acceleration;
    const accelTime = speed / acceleration;

    // Distances: along each leg's spline, from one frame to the next.
    int firstStop = -1, lastStop = -1;
    frames[0].distFromPrev = 0;
    if (frames[0].isStop)
        firstStop = lastStop = 0;
    size_t start = 0;
    foreach (i; 1 .. frames.length)
    {
        if (frames[i - 1].teleport || i + 1 == frames.length)
        {
            const extra = frames[i - 1].teleport ? 0 : 1;
            const lengths = splineLengths(splinePath[start .. i + extra]);
            foreach (j; start .. i + extra)
            {
                frames[j].distFromPrev = lengths[j + 1 - start] - lengths[j - start];
                if (j > 0)
                    frames[j - 1].nextDistFromPrev = frames[j].distFromPrev;
            }
            if (frames[i - 1].teleport)
            {
                frames[i].distFromPrev = 0;
                frames[i - 1].nextDistFromPrev = 0;
            }
            start = i;
        }
        if (frames[i].isStop)
        {
            if (firstStop == -1)
                firstStop = cast(int) i;
            lastStop = cast(int) i;
        }
    }
    frames[$ - 1].nextDistFromPrev = frames[0].distFromPrev;
    if (firstStop == -1 || lastStop == -1)
        firstStop = lastStop = 0;

    const count = frames.length;
    float tmp = 0;
    foreach (i; 0 .. count)
    {
        const j = (i + lastStop) % count;
        if (frames[j].isStop || j == lastStop)
            tmp = 0;
        else
            tmp += frames[j].distFromPrev;
        frames[j].distSinceStop = tmp;
    }
    tmp = 0;
    foreach_reverse (i; 0 .. count)
    {
        const j = (i + firstStop) % count;
        tmp += frames[(j + 1) % count].distFromPrev;
        frames[j].distUntilStop = tmp;
        if (frames[j].isStop || j == firstStop)
            tmp = 0;
    }

    // Times: speeding up from a stop, at full speed, slowing down to the next.
    foreach (ref k; frames)
    {
        const total = k.distSinceStop + k.distUntilStop;
        if (total < 2 * accelDist)
        {
            if (k.distSinceStop < k.distUntilStop)
                k.timeTo = 2.0f * sqrt(total / acceleration) - sqrt(2 * k.distSinceStop / acceleration);
            else
                k.timeTo = sqrt(2 * k.distUntilStop / acceleration);
        }
        else if (k.distSinceStop < accelDist)
            k.timeTo = total / speed + speed / acceleration - sqrt(2 * k.distSinceStop / acceleration);
        else if (k.distUntilStop < accelDist)
            k.timeTo = sqrt(2 * k.distUntilStop / acceleration);
        else
            k.timeTo = k.distUntilStop / speed + 0.5f * speed / acceleration;
    }
    float segmentTime = 0;
    foreach (i; 0 .. count)
    {
        const j = (i + lastStop) % count;
        if (frames[j].isStop || j == lastStop)
            segmentTime = frames[j].timeTo;
        frames[j].timeFrom = segmentTime - frames[j].timeTo;
    }

    frames[0].arriveTime = 0;
    float pathTime = 0;
    if (frames[0].isStop)
    {
        pathTime = frames[0].node.delay;
        frames[0].departureTime = cast(uint)(pathTime * 1000);
    }
    foreach (i; 1 .. count)
    {
        pathTime += frames[i - 1].timeTo;
        if (frames[i].isStop)
        {
            frames[i].arriveTime = cast(uint)(pathTime * 1000);
            frames[i - 1].nextArriveTime = frames[i].arriveTime;
            pathTime += frames[i].node.delay;
            frames[i].departureTime = cast(uint)(pathTime * 1000);
        }
        else
        {
            pathTime -= frames[i].timeTo;
            frames[i].arriveTime = cast(uint)(pathTime * 1000);
            frames[i - 1].nextArriveTime = frames[i].arriveTime;
            frames[i].departureTime = frames[i].arriveTime;
        }
    }
    frames[$ - 1].nextArriveTime = frames[$ - 1].departureTime;
    if (period)
        frames[$ - 1].departureTime = period;
    return frames;
}

/// A round's length: the last frame's departure.
uint roundTime(const KeyFrame[] frames) pure nothrow @nogc @safe
{
    return frames.length ? frames[$ - 1].departureTime : 0;
}

/**
 * Where a ship is `progress` milliseconds into its round: the frame it last came to (`frame`), and the map
 * it is on. Arriving at a teleport frame takes it to the next frame's map (the last frame's: the first's).
 */
uint mapAt(const KeyFrame[] frames, uint progress, out size_t frame) pure nothrow @nogc @safe
{
    if (frames.length == 0)
        return uint.max;
    size_t current = 0;
    uint map = frames[0].node.map;
    foreach (_; 0 .. 2 * frames.length + 2)
    {
        const k = &frames[current];
        if (progress >= k.arriveTime && progress < k.departureTime)
            break; // waiting at a stop
        if (progress >= k.departureTime && progress < k.nextArriveTime)
            break; // on the way to the next
        const next = (current + 1) % frames.length;
        if (next == 0)
            break; // past the end of the round: at the last frame
        current = next;
        if (frames[current].node.map != map || frames[current].teleport)
            map = frames[(current + 1) % frames.length].node.map;
    }
    frame = current;
    return map;
}

/**
 * A ship on a map: a game object whose create block carries the transport clock (`transportClock`), from
 * which the client works out where on its path the ship is. Its guid is the transport high part with its
 * entry. Every player on its map sees it (`Map.addEverywhere`).
 */
final class ShipObject : MapObject
{
    import dmangos.world.gameobject : GameObjectTemplate, goStateReady;
    import dmangos.world.movement : Position;
    import dmangos.world.objects;
    import dmangos.world.updatefields;

    const uint entry;
    UpdateValues values;
    private ulong guid_;
    private Position position_;
    private uint delegate() clock_;

    /// A ship of template `t`, a round of `period` milliseconds, at `at`; `clock` gives the transport clock.
    this(const(GameObjectTemplate)* t, uint period, Position at, uint delegate() clock)
    {
        import std.math : cos, sin;

        entry = t.entry;
        guid_ = makeGuid(HighGuid.moTransport, t.entry);
        position_ = at;
        clock_ = clock;
        values = UpdateValues(TypeId.gameObject);
        values.set!OBJECT_FIELD_GUID(guid_);
        values.set!OBJECT_FIELD_TYPE(TypeMask.object | TypeMask.gameObject);
        values.set!OBJECT_FIELD_ENTRY(t.entry);
        values.set!OBJECT_FIELD_SCALE_X(t.size > 0 ? t.size : 1.0f);
        values.set!GAMEOBJECT_POS_X(at.x);
        values.set!GAMEOBJECT_POS_Y(at.y);
        values.set!GAMEOBJECT_POS_Z(at.z);
        values.set!GAMEOBJECT_FACING(at.orientation);
        values.set!GAMEOBJECT_ROTATION(2, sin(at.orientation / 2));
        values.set!GAMEOBJECT_ROTATION(3, cos(at.orientation / 2));
        values.set!GAMEOBJECT_FACTION(t.faction);
        values.set!GAMEOBJECT_FLAGS(t.flags);
        values.set!GAMEOBJECT_DISPLAYID(t.displayId);
        values.set!GAMEOBJECT_STATE(goStateReady);
        values.set!GAMEOBJECT_TYPE_ID(t.type);
        values.set!GAMEOBJECT_ANIMPROGRESS(255u);
        values.set!GAMEOBJECT_LEVEL(period); // the round's length
        values.clearChanges();
    }

    @property ulong guid() const
    {
        return guid_;
    }

    @property Position position() const
    {
        return position_;
    }

    /// Where it is now (a path node: where it last came to); its position fields follow, for create blocks.
    void moveTo(Position at)
    {
        import std.math : cos, sin;

        if (at == position_)
            return;
        position_ = at;
        values.set!GAMEOBJECT_POS_X(at.x);
        values.set!GAMEOBJECT_POS_Y(at.y);
        values.set!GAMEOBJECT_POS_Z(at.z);
        values.set!GAMEOBJECT_FACING(at.orientation);
        values.set!GAMEOBJECT_ROTATION(2, sin(at.orientation / 2));
        values.set!GAMEOBJECT_ROTATION(3, cos(at.orientation / 2));
        values.clearChanges(); // the client moves it by itself: only create blocks show where it is
    }

    ref UpdateValues fields()
    {
        return values;
    }

    UpdateData appearance(uint) const
    {
        MovementBlock block;
        block.flags = UpdateFlags.all | UpdateFlags.hasPosition | UpdateFlags.transport;
        block.position = position_;
        block.transportTime = clock_();
        UpdateData update;
        update.addCreate(UpdateType.createObject, guid_, block, values, seenByEveryone);
        return update;
    }
}

/// The transport clock: the wall clock's milliseconds, cut to 32 bits, as the clients are given it.
uint transportClock(long unixMilliseconds) pure nothrow @nogc @safe
{
    return cast(uint) unixMilliseconds;
}

/// Where a passenger `offset` from a ship at `ship` (facing `facing`) is in the world, and its facing.
void passengerPosition(float shipX, float shipY, float shipZ, float facing, float ox, float oy, float oz, float oo,
    out float x, out float y, out float z, out float o) pure nothrow @nogc @safe
{
    import std.math : cos, sin;

    x = shipX + ox * cos(facing) - oy * sin(facing);
    y = shipY + oy * cos(facing) + ox * sin(facing);
    z = shipZ + oz;
    o = normalized(facing + oo);
}

unittest
{
    import std.math : isClose;

    // A straight line: the spline's length is the distance.
    const lengths = splineLengths([V3(0, 0, 0), V3(10, 0, 0), V3(20, 0, 0)]);
    assert(lengths[1] == 0 && isClose(lengths[2], 10.0f) && isClose(lengths[3], 20.0f));

    // Two maps: a stop at either end, a crossing in the middle.
    PathNode[] path;
    foreach (i; 0 .. 6)
        path ~= PathNode(0, i * 100.0f, 0, 0, i == 1 ? 2 : 0, i == 1 ? 30 : 0);
    path ~= PathNode(0, 600, 0, 0, 0, 0); // the edge of map 0
    foreach (i; 0 .. 6)
        path ~= PathNode(1, i * 100.0f, 0, 0, i == 2 ? 2 : 0, i == 2 ? 20 : 0);
    const frames = generatePath(path, 30, 10);
    assert(frames.length > 6);
    foreach (i; 1 .. frames.length)
        assert(frames[i].arriveTime >= frames[i - 1].departureTime, "in order");
    size_t stop0 = size_t.max, stop1 = size_t.max;
    foreach (i, ref k; frames)
        if (k.isStop)
            (k.node.map == 0 ? stop0 : stop1) = i;
    assert(frames[stop0].departureTime - frames[stop0].arriveTime == 30_000, "the stop's delay");
    assert(frames[stop1].departureTime - frames[stop1].arriveTime == 20_000);

    // Waiting at the first stop: map 0; at the second: map 1; the crossing between.
    size_t at;
    assert(mapAt(frames, frames[stop0].arriveTime + 1000, at) == 0 && at == stop0);
    assert(mapAt(frames, frames[stop1].arriveTime + 1000, at) == 1 && at == stop1);
    size_t crossing = size_t.max;
    foreach (i, ref k; frames)
        if (k.teleport && k.node.map == 0)
            crossing = i;
    assert(crossing != size_t.max && frames[crossing + 1].node.map == 1);
    assert(mapAt(frames, frames[crossing].arriveTime - 1, at) == 0, "before the crossing");
    assert(mapAt(frames, frames[crossing].arriveTime, at) == 1, "on arriving there");
    // Just before the last frame it is still on map 1; arriving there, back to map 0 for the next round.
    assert(mapAt(frames, frames[$ - 1].arriveTime - 1, at) == 1);
    assert(mapAt(frames, frames[$ - 1].arriveTime, at) == 0 && at == frames.length - 1);

    // A passenger a yard forward of a ship facing north is a yard north of it.
    float x, y, z, o;
    passengerPosition(10, 10, 0, cast(float)(PI / 2), 1, 0, 0, 0, x, y, z, o);
    assert(isClose(x, 10.0f, 1e-4) && isClose(y, 11.0f) && isClose(o, cast(float)(PI / 2)));
}

/**
 * A ship sailing between two maps: everyone on its map is shown it; at the crossing it leaves for the
 * other map, those left behind are told to forget it, and the player aboard crosses with it, onto it.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteReader;
    import dmangos.world.gameobject : GameObjectTemplate, GameObjectType;
    import dmangos.world.movement : MovementFlags, Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.worlddata : Ship;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;

    // Along the coast of map 0, across, and along a coast of map 1.
    enum uint entry = 99_001;
    GameObjectTemplate t;
    t.entry = entry;
    t.type = GameObjectType.moTransport;
    t.displayId = 3015;
    t.data[1] = 30;
    t.data[2] = 10;
    context.data.gameObjectTemplates[entry] = t;
    PathNode[] path;
    foreach (i; 0 .. 6)
        path ~= PathNode(0, -8900 + i * 100.0f, -132, 0, i == 1 ? 2 : 0, i == 1 ? 30 : 0);
    path ~= PathNode(0, -8300, -132, 0, 0, 0);
    foreach (i; 0 .. 6)
        path ~= PathNode(1, 1000 + i * 100.0f, -4000, 0, i == 2 ? 2 : 0, i == 2 ? 20 : 0);
    auto frames = generatePath(path, 30, 10);
    const period = roundTime(frames) + 1000;
    frames[$ - 1].departureTime = period;
    context.data.ships = [Ship(entry, "The Test", period, frames)];
    const shipGuid = makeGuid(HighGuid.moTransport, entry);

    // Bring the clock to the first stop on map 0 before anyone is there.
    size_t stop;
    foreach (i, ref k; frames)
        if (k.isStop && k.node.map == 0)
            stop = i;
    void to(uint progress)
    {
        const at = context.fleet.transportNow() % period;
        now += ((progress + period - at) % period).msecs;
        context.update(now);
    }
    auto sailor = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    auto ashore = loggedIn(context, db, 8, "Jaina", Position(-8949.95f, -130.49f, 83.53f));
    // Whether an update `c` was sent names the ship (its guid, as its fields hold it).
    bool shown(TestClient c)
    {
        import std.bitmanip : nativeToLittleEndian;
        import std.zlib : uncompress;

        const guidBytes = nativeToLittleEndian(shipGuid);
        foreach (p; c.read())
        {
            const(ubyte)[] body_ = p.body_;
            if (p.opcode == Opcode.SMSG_COMPRESSED_UPDATE_OBJECT)
                body_ = cast(const(ubyte)[]) uncompress(p.body_[4 .. $]);
            else if (p.opcode != Opcode.SMSG_UPDATE_OBJECT)
                continue;
            if (body_.canFind(guidBytes[]))
                return true;
        }
        return false;
    }
    to(frames[stop].arriveTime + 1000);
    assert(context.existingMap(0).everywhere.length == 1, "waiting at its stop on map 0");
    sailor.read();
    ashore.read();

    // Aboard, three yards along its deck: the client says so in a movement packet, as a real one does.
    auto me = cast(Player) sailor.session.character;
    {
        import dmangos.bytes : ByteWriter;

        auto aboard = me.movement;
        aboard.flags = MovementFlags.onTransport;
        aboard.transportGuid = shipGuid;
        aboard.transportOffset = Position(3, 0, 5, 0);
        ByteWriter w;
        aboard.write(w);
        sailor.write(Opcode.MSG_MOVE_HEARTBEAT, w.data);
    }
    assert(me.movement.has(MovementFlags.onTransport) && me.movement.transportGuid == shipGuid,
        "a passenger's movement is taken");

    // The crossing: it leaves map 0, with its passenger.
    size_t crossing;
    foreach (i, ref k; frames)
        if (k.teleport && k.node.map == 0)
            crossing = i;
    to(frames[crossing].arriveTime + 10);
    const went = sailor.read();
    assert(opcodesOf(went).canFind(Opcode.SMSG_TRANSFER_PENDING) && opcodesOf(went).canFind(Opcode.SMSG_NEW_WORLD));
    foreach (p; went)
        if (p.opcode == Opcode.SMSG_TRANSFER_PENDING)
        {
            auto r = ByteReader(p.body_);
            assert(r.read!uint == 1 && r.read!uint == entry && r.read!uint == 0, "to map 1, on the ship, from map 0");
        }
        else if (p.opcode == Opcode.SMSG_NEW_WORLD)
        {
            auto r = ByteReader(p.body_);
            assert(r.read!uint == 1 && r.read!float == 3 && r.read!float == 0 && r.read!float == 5, "its place aboard");
        }
    assert(me.data.map == 1 && me.movement.has(MovementFlags.onTransport) && me.movement.transportGuid == shipGuid);
    assert(opcodesOf(ashore.read()).canFind(Opcode.SMSG_UPDATE_OBJECT), "those ashore are told to forget it");
    assert(context.existingMap(0).everywhere.length == 0);

    // Round again to its stop: back on map 0, shown to those there.
    to(frames[stop].arriveTime + 1000);
    assert(shown(ashore) && context.existingMap(0).everywhere.length == 1, "it comes back");
}
