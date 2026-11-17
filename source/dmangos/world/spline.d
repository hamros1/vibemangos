/**
 * Server-driven movement along a path (CMaNGOS `Movement/MoveSpline.cpp`, `spline.cpp`,
 * `MoveSplineInit.cpp` and `packet_builder.cpp`), as creatures walk: the server decides a path, tells
 * the clients once with `SMSG_MONSTER_MOVE`, and then only follows the unit along it in time, so it
 * knows where the unit is when someone asks.
 *
 * Only linear paths are kept: catmull-rom (flying) paths, falling and cyclic paths come with what
 * needs them.
 */
module dmangos.world.spline;

import std.math : atan2, PI;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.vmap.math : Vector3;
import dmangos.world.movement : Position;

/// `MoveSplineFlag`
enum SplineFlags : uint
{
    none = 0,
    done = 0x0000_0001,
    falling = 0x0000_0002,
    runMode = 0x0000_0100,
    flying = 0x0000_0200,
    finalPoint = 0x0001_0000,
    finalTarget = 0x0002_0000,
    finalAngle = 0x0004_0000,
    cyclic = 0x0010_0000,
    enterCycle = 0x0020_0000,

    finalFacing = finalPoint | finalTarget | finalAngle, /// `Mask_Final_Facing`
    noMonsterMove = finalFacing | done,                 /// `Mask_No_Monster_Move`
}

/// `MonsterMoveType`: the byte after the spline id.
enum MonsterMoveType : ubyte
{
    normal = 0,
    stop = 1,
    facingSpot = 2,
    facingTarget = 3,
    facingAngle = 4,
}

/**
 * The shortest walk a 1.12 client is shown, in yards. Its unit spline code reads a segment table it
 * never set up for a spline of next to no length: an access violation at 0x453885 (`fld [eax+esi*4]`,
 * eax 0). Seen with a creature stepping 0.3 to 0.4 yards, and with one turning where it stood (both
 * points the same), each in the create block of a client that had just come into the world.
 */
enum float minimumWalk = 1.0f;

/// `MoveSpline` with a linear `Spline<int32>`: see the module documentation.
struct MoveSpline
{
    private
    {
        Vector3[] points;   // the path, its last point twice (`SplineBase::InitLinear`)
        int[] lengths;      // milliseconds from the start to each point
        uint flags_ = SplineFlags.done;
        uint id_;
        float facingAngle_ = 0;
        float velocity_ = 0;
        int timePassed_;
        int pointIndex;     // `point_Idx`: the segment being walked
    }

    /// `MoveSplineInitArgs` and `MoveSpline::Initialize`: walks `path` at `velocity` yards a second.
    this(const(Vector3)[] path, uint flags, float velocity, uint id, float facingAngle = 0)
    in (path.length > 1 && velocity > 0, "MoveSplineInitArgs::Validate")
    {
        flags_ = flags;
        id_ = id;
        facingAngle_ = facingAngle;
        velocity_ = velocity;
        points = path.dup ~ path[$ - 1];
        lengths = new int[path.length];

        // CommonInitializer: the time of each point, from 1 ms on, truncated as it adds up.
        const velocityInv = 1000.0f / velocity;
        int time = 1;
        foreach (i; 0 .. path.length - 1)
        {
            time = cast(int)(time + (points[i] - points[i + 1]).magnitude() * velocityInv);
            lengths[i + 1] = time;
        }
        if (duration < 1) // MoveSpline::init_spline: all the points in one place
            lengths[last] = 1;
    }

    /// `MoveSpline::Initialize` for a stop: no path, done at once.
    static MoveSpline stopped(uint id)
    {
        MoveSpline spline;
        spline.id_ = id;
        return spline;
    }

    /// `MoveSplineFlag`
    @property uint flags() const pure nothrow @nogc @safe
    {
        return flags_;
    }

    /// The id the clients know it by.
    @property uint id() const pure nothrow @nogc @safe
    {
        return id_;
    }

    /// The length of the path, in yards.
    @property float length() const pure nothrow @nogc @safe
    {
        float total = 0;
        if (points.length > 2)
            foreach (i; 1 .. points.length - 1)
                total += (points[i] - points[i - 1]).magnitude();
        return total;
    }

    /// Whether a client may be shown it: under way, and not too short (`minimumWalk`).
    @property bool showable() const pure nothrow @nogc @safe
    {
        return initialized && !finalized && length >= minimumWalk;
    }

    /// `Finalized`: arrived, stopped or never started.
    @property bool finalized() const pure nothrow @nogc @safe
    {
        return (flags_ & SplineFlags.done) != 0;
    }

    /// `Initialized`: has a path.
    @property bool initialized() const pure nothrow @nogc @safe
    {
        return points.length != 0;
    }

    /// `Duration`: milliseconds from the first point to the last.
    @property int duration() const pure nothrow @nogc @safe
    {
        return initialized ? lengths[last] : 0;
    }

    /// `timePassed`
    @property int timePassed() const pure nothrow @nogc @safe
    {
        return timePassed_;
    }

    /// The facing at the end, for `SplineFlags.finalAngle`.
    @property float facingAngle() const pure nothrow @nogc @safe
    {
        return facingAngle_;
    }

    /// `getPath`: the points, the last one twice.
    @property const(Vector3)[] path() const pure nothrow @nogc @safe
    {
        return points;
    }

    /// `FinalDestination`
    @property Vector3 finalDestination() const pure nothrow @nogc @safe
    {
        return initialized ? points[last] : Vector3.init;
    }

    /// `currentPathIdx`: the number of points passed (all of them once finalized).
    @property int currentPathIndex() const pure nothrow @nogc @safe
    {
        return pointIndex + finalized;
    }

    /// `MoveSpline::updateState`: `diff` milliseconds on.
    void update(int diff) pure nothrow @nogc @safe
    {
        while (diff > 0 && !finalized)
        {
            const step = diff < nextTimestamp - timePassed_ ? diff : nextTimestamp - timePassed_;
            timePassed_ += step;
            diff -= step;
            if (timePassed_ >= nextTimestamp && ++pointIndex >= last)
                finalize();
        }
    }

    /// `_Interrupt`: stopped where it is.
    void interrupt() pure nothrow @nogc @safe
    {
        flags_ |= SplineFlags.done;
    }

    /**
     * `MoveSpline::ComputePosition`: where the walk is, facing along the segment; or the final
     * facing once done.
     */
    Position position() const pure nothrow @nogc @safe
    in (initialized)
    {
        const segmentTime = lengths[pointIndex + 1] - lengths[pointIndex];
        const u = segmentTime > 0 ? (timePassed_ - lengths[pointIndex]) / float(segmentTime) : 1.0f;
        const a = points[pointIndex], b = points[pointIndex + 1];
        const p = a + (b - a) * u;
        float orientation;
        if (finalized && (flags_ & SplineFlags.finalAngle))
            orientation = facingAngle_;
        else
            orientation = atan2(b.y - a.y, b.x - a.x);
        return Position(p.x, p.y, p.z, orientation);
    }

    /**
     * Writes the spline so that `readExact` rebuilds it exactly, times included: what a replica on
     * another node follows (docs/CLUSTER.md, phase 3).
     */
    void writeExact(ref ByteWriter w) const
    {
        w.put(id_);
        w.put(flags_);
        w.put(velocity_);
        w.put(facingAngle_);
        w.put(timePassed_);
        w.put(cast(ushort)(initialized ? points.length - 1 : 0));
        if (initialized)
            foreach (p; points[0 .. $ - 1])
            {
                w.put(p.x);
                w.put(p.y);
                w.put(p.z);
            }
    }

    /// See `writeExact`.
    static MoveSpline readExact(ref ByteReader r)
    {
        const id = r.read!uint, flags = r.read!uint, velocity = r.read!float, facing = r.read!float;
        const passed = r.read!int;
        Vector3[] path = new Vector3[r.read!ushort];
        foreach (ref p; path)
            p = Vector3(r.read!float, r.read!float, r.read!float);
        if (path.length < 2 || !(velocity > 0))
            return stopped(id);
        auto spline = MoveSpline(path, flags & ~SplineFlags.done, velocity, id, facing);
        spline.update(passed);
        if (flags & SplineFlags.done)
            spline.interrupt();
        return spline;
    }

private:
    @property int last() const pure nothrow @nogc @safe
    {
        return cast(int) points.length - 2;
    }

    @property int nextTimestamp() const pure nothrow @nogc @safe
    {
        return lengths[pointIndex + 1];
    }

    /// `_Finalize`
    void finalize() pure nothrow @nogc @safe
    {
        flags_ |= SplineFlags.done;
        pointIndex = last - 1;
        timePassed_ = duration;
    }
}

/// `G3D::wrap(angle, 0, 2π)`, as `MoveSplineInit::SetFacing` stores an angle.
float wrapAngle(float angle) pure nothrow @nogc @safe
{
    import std.math : floor;

    enum float twoPi = 2 * PI;
    return angle - twoPi * floor(angle / twoPi);
}

/// `ByteBuffer::appendPackXYZ`: an offset in quarter yards, 11, 11 and 10 bits.
uint packXYZ(float x, float y, float z) pure nothrow @nogc @safe
{
    return (cast(int)(x / 0.25f) & 0x7FF) | (cast(int)(y / 0.25f) & 0x7FF) << 11
        | (cast(int)(z / 0.25f) & 0x3FF) << 22;
}

/**
 * The body of `SMSG_MONSTER_MOVE` for a started spline (`PacketBuilder::WriteMonsterMove`): the start,
 * the facing, the flags (with the run mode the client wants to see), the duration and the path, as
 * the destination and the packed offsets of the points before it.
 */
const(ubyte)[] monsterMove(ulong guid, const ref MoveSpline spline)
in (spline.initialized)
{
    ByteWriter w;
    w.putPackedGuid(guid);
    const path = spline.path;
    putVector(w, path[0]);
    w.put(spline.id);
    if (spline.flags & SplineFlags.finalAngle)
    {
        w.put(ubyte(MonsterMoveType.facingAngle));
        w.put(spline.facingAngle);
    }
    else
        w.put(ubyte(MonsterMoveType.normal));
    w.put(uint((spline.flags & ~SplineFlags.noMonsterMove) | SplineFlags.runMode));
    w.put(spline.duration);

    // WriteLinearPath: the destination, then the offsets to it of the points between, if not tiny.
    const destination = path[$ - 2];
    uint[] offsets;
    foreach (point; path[1 .. $ - 2])
    {
        const offset = destination - point;
        if (offset.dot(offset) >= 0.5f)
            offsets ~= packXYZ(offset.x, offset.y, offset.z);
    }
    w.put(cast(uint)(offsets.length + 1));
    putVector(w, destination);
    foreach (packed; offsets)
        w.put(packed);
    return w.data;
}

/// The body of `SMSG_MONSTER_MOVE` for a stop (`MoveSplineInit::Stop`): where it stands.
const(ubyte)[] monsterStop(ulong guid, Position at, uint splineId)
{
    ByteWriter w;
    w.putPackedGuid(guid);
    w.put(at.x);
    w.put(at.y);
    w.put(at.z);
    w.put(splineId);
    w.put(ubyte(MonsterMoveType.stop));
    return w.data;
}

/// `PacketBuilder::WriteCreate`: the walk so far, after the speeds of a moving unit's create block.
void writeSplineCreate(ref ByteWriter w, const ref MoveSpline spline)
in (spline.showable, "a create block shows a walk under way, of some length, only")
{
    w.put(spline.flags);
    if (spline.flags & SplineFlags.finalAngle)
        w.put(spline.facingAngle);
    w.put(spline.timePassed);
    w.put(spline.duration);
    w.put(spline.id);
    w.put(cast(uint) spline.path.length);
    foreach (point; spline.path)
        putVector(w, point);
    putVector(w, spline.finalDestination);
}

private void putVector(ref ByteWriter w, const Vector3 v)
{
    w.put(v.x);
    w.put(v.y);
    w.put(v.z);
}

unittest
{
    import std.math : abs, isClose;

    static bool near(float a, float b) { return abs(a - b) < 0.01f; }

    // Two segments of 10 and 5 yards at 2.5 yards a second: 4 and 2 seconds, from 1 ms on.
    const path = [Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 5, 0)];
    auto spline = MoveSpline(path, SplineFlags.none, 2.5f, 7);
    assert(spline.duration == 6001 && !spline.finalized && spline.path.length == 4);
    assert(spline.position == Position(0, 0, 0, 0));

    spline.update(2000);
    assert(near(spline.position.x, 5.0f) && spline.position.y == 0 && spline.currentPathIndex == 0);
    spline.update(2001);
    assert(spline.currentPathIndex == 1 && near(spline.position.x, 10.0f));
    spline.update(1000);
    assert(near(spline.position.y, 2.5f) && isClose(spline.position.orientation, cast(float) PI / 2));
    spline.update(5000);
    assert(spline.finalized && spline.currentPathIndex == 2 && spline.timePassed == 6001);
    assert(spline.position == Position(10, 5, 0, cast(float) PI / 2) && spline.finalDestination == Vector3(10, 5, 0));

    // A final facing holds once it is there.
    auto facing = MoveSpline(path[0 .. 2], SplineFlags.finalAngle, 7, 8, 1.5f);
    facing.update(100_000);
    assert(facing.position.orientation == 1.5f);

    // All in one place: a millisecond long.
    assert(MoveSpline([Vector3(1, 1, 1), Vector3(1, 1, 1)], SplineFlags.none, 1, 9).duration == 1);

    assert(isClose(wrapAngle(-cast(float) PI / 2), 3 * cast(float) PI / 2) && wrapAngle(1) == 1);
    assert(packXYZ(1, -1, 0.5f) == (4 | (0x7FF & -4) << 11 | 2 << 22));
}

unittest
{
    import dmangos.bytes : ByteReader;

    const path = [Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 0.2f, 0), Vector3(20, 0, 0)];
    auto spline = MoveSpline(path, SplineFlags.none, 10, 3);
    auto r = ByteReader(monsterMove(0xF130_0000_0000_0001, spline));
    assert(r.readPackedGuid() == 0xF130_0000_0000_0001);
    assert(r.read!float == 0 && r.read!float == 0 && r.read!float == 0 && r.read!uint == 3);
    assert(r.read!ubyte == MonsterMoveType.normal && r.read!uint == SplineFlags.runMode);
    assert(r.read!uint == spline.duration);
    assert(r.read!uint == 3, "the destination and two offsets; none is tiny");
    assert(r.read!float == 20 && r.read!float == 0 && r.read!float == 0);
    assert(r.read!uint == packXYZ(10, 0, 0) && r.read!uint == packXYZ(10, -0.2f, 0) && r.empty);

    // Points within 0.7 yards of the destination are left out.
    const close = [Vector3(0, 0, 0), Vector3(19.5f, 0, 0), Vector3(20, 0, 0)];
    auto near = MoveSpline(close, SplineFlags.finalAngle, 10, 4, 2);
    r = ByteReader(monsterMove(1, near));
    r.readPackedGuid();
    r.readBytes(16);
    assert(r.read!ubyte == MonsterMoveType.facingAngle && r.read!float == 2);
    assert(r.read!uint == SplineFlags.runMode, "the final facing is not among the flags");
    r.read!uint;
    assert(r.read!uint == 1 && r.readBytes(12).length == 12 && r.empty);

    r = ByteReader(monsterStop(1, Position(1, 2, 3, 0), 5));
    r.readPackedGuid();
    assert(r.read!float == 1 && r.read!float == 2 && r.read!float == 3 && r.read!uint == 5);
    assert(r.read!ubyte == MonsterMoveType.stop && r.empty);

    ByteWriter w;
    spline.update(1000);
    writeSplineCreate(w, spline);
    r = ByteReader(w.data);
    assert(r.read!uint == SplineFlags.none && r.read!uint == 1000 && r.read!uint == spline.duration);
    assert(r.read!uint == 3 && r.read!uint == 5, "the path with its last point twice");
    r.readBytes(5 * 12);
    assert(r.read!float == 20 && r.read!float == 0 && r.read!float == 0 && r.empty);
}

unittest
{
    // A spline written and read back is the same walk at the same point of it.
    auto walk = MoveSpline([Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 7, 1)], SplineFlags.finalAngle, 2.5f, 42, 1);
    walk.update(3333);
    ByteWriter w;
    walk.writeExact(w);
    auto r = ByteReader(w.data);
    auto copy = MoveSpline.readExact(r);
    assert(r.empty && copy.duration == walk.duration && copy.timePassed == walk.timePassed && copy.id == 42);
    assert(copy.position == walk.position && copy.path == walk.path && copy.flags == walk.flags);
    copy.update(100_000);
    walk.update(100_000);
    assert(copy.position == walk.position && copy.finalized);

    w.clear();
    MoveSpline.stopped(7).writeExact(w);
    r = ByteReader(w.data);
    const none = MoveSpline.readExact(r);
    assert(none.finalized && !none.initialized && none.id == 7);
}

