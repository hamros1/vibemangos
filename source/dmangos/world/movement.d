/**
 * Movement data as 1.12 clients send and receive it, read from and
 * written to packets.
 *
 * Client movement packets (`MSG_MOVE_*`) carry a `MovementInfo` and nothing
 * else. The same structure starts the "living" part of a unit's create
 * block, followed by the unit's six speeds.
 */
module dmangos.world.movement;

import std.math : isFinite;

import dmangos.bytes;

/// The movement flags (only the ones that change the packet layout or matter here).
enum MovementFlags : uint
{
    none = 0,
    forward = 0x00000001,
    backward = 0x00000002,
    strafeLeft = 0x00000004,
    strafeRight = 0x00000008,
    turnLeft = 0x00000010,
    turnRight = 0x00000020,
    walkMode = 0x00000100,
    root = 0x00001000,
    jumping = 0x00002000,     /// adds the jump fields
    fallingFar = 0x00004000,
    swimming = 0x00200000,    /// adds the pitch
    splineEnabled = 0x00400000,
    pitchUp = 0x00000040,
    pitchDown = 0x00000080,
    onTransport = 0x02000000, /// adds the transport guid and offset
    splineElevation = 0x04000000, /// adds one float
}

/// The moving flags with the turning flags: the player is moving or turning, so it stands up and
/// stops a looping emote.
enum uint movingOrTurning = MovementFlags.forward | MovementFlags.backward | MovementFlags.strafeLeft
    | MovementFlags.strafeRight | MovementFlags.pitchUp | MovementFlags.pitchDown | MovementFlags.fallingFar
    | MovementFlags.splineElevation | MovementFlags.turnLeft | MovementFlags.turnRight;

/// A position and facing.
struct Position
{
    float x = 0;
    float y = 0;
    float z = 0;
    float orientation = 0;

    /// Whether every coordinate is a real number (the first check of a valid map position).
    bool isFinite() const pure nothrow @nogc @safe
    {
        return .isFinite(x) && .isFinite(y) && .isFinite(z) && .isFinite(orientation);
    }
}

/// Where a unit is and how it moves, as movement packets carry it.
struct MovementInfo
{
    uint flags;          /// `MovementFlags`
    uint time;           /// milliseconds; the sender's clock
    Position position;
    ulong transportGuid;
    Position transportOffset;
    float pitch = 0;
    uint fallTime;
    float jumpVelocity = 0;
    float jumpCos = 0;
    float jumpSin = 0;
    float jumpXySpeed = 0;
    float splineElevation = 0;

    /// Whether `flag` is set.
    bool has(MovementFlags flag) const pure nothrow @nogc @safe
    {
        return (flags & flag) != 0;
    }

    /// Reads one from a packet.
    static MovementInfo read(ref ByteReader reader)
    {
        MovementInfo m;
        m.flags = reader.read!uint;
        m.time = reader.read!uint;
        m.position = readPosition(reader);
        if (m.has(MovementFlags.onTransport))
        {
            m.transportGuid = reader.read!ulong;
            m.transportOffset = readPosition(reader);
        }
        if (m.has(MovementFlags.swimming))
            m.pitch = reader.read!float;
        m.fallTime = reader.read!uint;
        if (m.has(MovementFlags.jumping))
        {
            m.jumpVelocity = reader.read!float;
            m.jumpCos = reader.read!float;
            m.jumpSin = reader.read!float;
            m.jumpXySpeed = reader.read!float;
        }
        if (m.has(MovementFlags.splineElevation))
            m.splineElevation = reader.read!float;
        return m;
    }

    /// Writes it to a packet.
    void write(ref ByteWriter writer) const
    {
        writer.put(flags);
        writer.put(time);
        writePosition(writer, position);
        if (has(MovementFlags.onTransport))
        {
            writer.put(transportGuid);
            writePosition(writer, transportOffset);
        }
        if (has(MovementFlags.swimming))
            writer.put(pitch);
        writer.put(fallTime);
        if (has(MovementFlags.jumping))
        {
            writer.put(jumpVelocity);
            writer.put(jumpCos);
            writer.put(jumpSin);
            writer.put(jumpXySpeed);
        }
        if (has(MovementFlags.splineElevation))
            writer.put(splineElevation);
    }
}

private Position readPosition(ref ByteReader reader)
{
    Position p;
    p.x = reader.read!float;
    p.y = reader.read!float;
    p.z = reader.read!float;
    p.orientation = reader.read!float;
    return p;
}

private void writePosition(ref ByteWriter writer, const Position p)
{
    writer.put(p.x);
    writer.put(p.y);
    writer.put(p.z);
    writer.put(p.orientation);
}

/// The kinds of movement, each with its own speed.
enum MoveType
{
    walk,
    run,
    runBack,
    swim,
    swimBack,
    turnRate,
}

/// `baseMoveSpeed`: yards (or radians for turning) per second.
enum float[MoveType.max + 1] baseMoveSpeed = [2.5f, 7.0f, 4.5f, 4.722222f, 2.5f, 3.141594f];

unittest
{
    // A jump while swimming: every optional part present.
    MovementInfo m;
    m.flags = MovementFlags.forward | MovementFlags.jumping | MovementFlags.swimming;
    m.time = 1234;
    m.position = Position(1, 2, 3, 0.5f);
    m.pitch = 0.25f;
    m.fallTime = 77;
    m.jumpVelocity = -7.9f;
    m.jumpCos = 1;
    m.jumpXySpeed = 7;

    ByteWriter w;
    m.write(w);
    assert(w.length == 4 + 4 + 16 + 4 + 4 + 16);
    auto r = ByteReader(w.data);
    assert(MovementInfo.read(r) == m && r.empty);

    // Standing still: the 28 bytes every movement packet has.
    ByteWriter plain;
    MovementInfo().write(plain);
    assert(plain.length == 28);

    assert(Position(1, 2, 3, 4).isFinite && !Position(float.nan, 0, 0, 0).isFinite);
}
