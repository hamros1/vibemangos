/// The world translation of a continuously animated game-object transport.
module dmangos.world.elevators;

import std.algorithm.comparison : max;
import std.math : abs, isFinite;
import dmangos.vmap.math : AABox, Matrix3, Vector3;
import dmangos.world.clientdata : TransportAnimationEntry;
import dmangos.world.grid : cellSize;
import dmangos.world.movement : Position;

package struct ElevatorPath
{
    private struct Frame
    {
        uint time;
        Vector3 offset;
    }

    private Frame[] frames;
    private float speed = 0;

    this(const(TransportAnimationEntry*)[] rows, const float[4] rotation)
    {
        if (rows.length < 2 || rows[0].time != 0)
            return;
        const transform = Matrix3.fromQuaternion(rotation[0], rotation[1], rotation[2], rotation[3]);
        auto result = new Frame[rows.length];
        foreach (i, row; rows)
        {
            if (i && row.time <= rows[i - 1].time)
                return;
            // The client rotates the translation, then reverses Y.
            auto offset = Vector3(row.x, row.y, row.z) * transform;
            offset.y = -offset.y;
            if (!offset.x.isFinite || !offset.y.isFinite || !offset.z.isFinite)
                return;
            result[i] = Frame(row.time, offset);
            if (i)
                speed = max(speed, (offset - result[i - 1].offset).magnitude * 1000
                    / (row.time - result[i - 1].time));
        }
        if (speed.isFinite)
            frames = result;
    }

    @property bool valid() const
    {
        return frames.length != 0;
    }

    /// The greatest movement per second between two consecutive keyframes.
    @property float maxSpeed() const
    {
        return speed;
    }

    bool travelsAcross(float distance) const
    {
        foreach (ref frame; frames)
            if (frame.offset.x ^^ 2 + frame.offset.y ^^ 2 >= distance ^^ 2)
                return true;
        return false;
    }

    Vector3 offsetAt(uint clock) const
    in (valid)
    {
        const time = clock % frames[$ - 1].time;
        foreach (i; 1 .. frames.length)
        {
            const next = frames[i];
            if (next.time > time)
            {
                const previous = frames[i - 1];
                const fraction = cast(float)(time - previous.time) / (next.time - previous.time);
                return previous.offset * (1 - fraction) + next.offset * fraction;
            }
        }
        return frames[0].offset;
    }

    Position positionAt(Position stationary, uint clock) const
    {
        const offset = offsetAt(clock);
        stationary.x += offset.x;
        stationary.y += offset.y;
        stationary.z += offset.z;
        return stationary;
    }

    AABox sweptBounds(AABox mesh) const
    in (valid)
    {
        const initial = frames[0].offset;
        auto swept = AABox(mesh.lo + initial, mesh.hi + initial);
        foreach (ref frame; frames[1 .. $])
            swept.merge(AABox(mesh.lo + frame.offset, mesh.hi + frame.offset));
        return swept;
    }
}

/// The pose last sampled for the map's spatial index. The create packet still uses the base.
package struct ElevatorMotion
{
    ElevatorPath path;
    uint delegate() clock;
    Position position;

    @property bool active() const
    {
        return path.valid && clock !is null;
    }

    void advance(Position stationary)
    {
        enum float edge = 256 * cellSize - 0.5f;
        const current = path.positionAt(stationary, clock());
        position = current.isFinite && abs(current.x) <= edge && abs(current.y) <= edge ? current : stationary;
    }
}

/// Local and replica elevators carry a stationary rider between client movement packets.
unittest
{
    import core.time : MonoTime, msecs;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter, floatBits;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : transportAnimationFormat;
    import dmangos.world.gameobject : GameObjectSpawn, GameObjectTemplate, GameObjectType;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : MovementFlags, MovementInfo, Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.replication : encodeState;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto owner = newCreationContext(db), viewer = newCreationContext(db);
    auto ownerNow = MonoTime.currTime, viewerNow = ownerNow;
    owner.clock = () => ownerNow;
    viewer.clock = () => viewerNow;
    enum uint entry = 97_001, period = 4000;
    const rows = buildDbc(transportAnimationFormat,
        [[0, entry, 0, 0, 0, 0, 0], [1, entry, 2000, floatBits(180), 0, floatBits(20), 0],
         [2, entry, period, 0, 0, 0, 0]]);
    foreach (world; [owner, viewer])
    {
        world.client.transportAnimations = typeof(world.client.transportAnimations).parse(rows, "test elevator");
        world.client.buildIndexes();
    }
    void tickTo(uint progress)
    {
        ownerNow += ((progress + period - owner.transportNow() % period) % period).msecs;
        viewerNow += ((progress + period - viewer.transportNow() % period) % period).msecs;
        owner.update(ownerNow);
        viewer.update(viewerNow);
    }
    tickTo(0);
    const spawn = GameObjectSpawn(guid: 21, entry: entry, x: 60, y: 10, z: 30);
    const home = cellKeyAt(spawn.x, spawn.y);
    const guid = makeGuid(HighGuid.gameObject, entry, spawn.guid);
    bool originalOwnsHome = true;
    owner.ownsCell = (uint map, ulong cell) => cell != home || originalOwnsHome;
    viewer.ownsCell = (uint map, ulong cell) => cell != home || !originalOwnsHome;
    foreach (world; [owner, viewer])
    {
        world.data.gameObjectTemplates[entry] = GameObjectTemplate(entry: entry, type: GameObjectType.transport);
        world.data.gameObjectCells[0][home] ~= world.data.gameObjectSpawns.length;
        world.data.gameObjectSpawns ~= spawn;
        assert(!world.map(0).cellLoaded(home));
    }
    tickTo(1);
    assert(owner.map(0).cellLoaded(home) && !viewer.map(0).cellLoaded(home), "only the owner loads the transport home");
    owner.map(0).unloadIdleCells(1_000_000);
    auto platform = owner.map(0).gameObjectAt(guid);
    assert(platform !is null && owner.map(0).cellLoaded(home), "the home remains loaded while idle");
    viewer.map(0).replicaCreated(1, home, platform.guid, encodeState(platform, 0));

    const boardAt = Position(62, 11, 31, 0.25f);
    auto rider = loggedIn(viewer, db, 7, "Anduin", boardAt);
    auto witness = loggedIn(viewer, db, 8, "Jaina", Position(74, 14, 35));
    loggedIn(viewer, db, 9, "Varian", Position(220, 10, 41));
    assert(!viewer.map(0).knownTo(9).canFind(platform.guid), "the platform starts out of sight");
    rider.read();
    witness.read();
    void sendMove(MovementInfo movement)
    {
        ByteWriter packet;
        movement.write(packet);
        rider.write(Opcode.MSG_MOVE_HEARTBEAT, packet.data);
    }
    MovementInfo move;
    move.flags = MovementFlags.onTransport;
    move.position = boardAt;
    move.transportGuid = platform.guid;
    move.transportOffset = Position(2, 1, 1, 0.25f);
    sendMove(move);
    witness.read(); // discard the boarding movement
    tickTo(50);
    tickTo(1000);

    const during = Position(152, 11, 41, 0.25f);
    assert(rider.session.character.position == during, "stationary rider followed the platform replica");
    assert(opcodesOf(witness.read()).canFind(Opcode.MSG_MOVE_HEARTBEAT), "the rider's position was sent to observers");
    Position localPose;
    float maxSpeed;
    assert(owner.elevatorPose(owner.map(0), platform.guid, localPose, maxSpeed));
    assert(localPose == Position(150, 10, 40) && maxSpeed > 0);
    assert(platform.position == localPose && viewer.map(0).findObject(platform.guid).position == localPose);
    assert(viewer.map(0).knownTo(9).canFind(platform.guid), "the animated platform came into view");
    assert(platform.motion(0).position == Position(60, 10, 30),
        "the client still receives the animation's base coordinates");
    assert(!opcodesOf(rider.read()).canFind(Opcode.SMSG_NEW_WORLD), "the ride stayed on its map");

    auto dismount = MovementInfo.init;
    dismount.position = during;
    sendMove(dismount);
    tickTo(1500);
    assert(rider.session.character.position == during, "the elevator does not carry a player after they step off");
    move.position = during;
    move.transportOffset = Position(99, 99, 99);
    sendMove(move);
    tickTo(1900);
    assert(rider.session.character.position == during, "an offset inconsistent with the reported position cannot move a rider");

    originalOwnsHome = false;
    owner.map(0).release((ulong cell) => cell == home);
    tickTo(2000);
    assert(!owner.map(0).cellLoaded(home) && owner.map(0).findObject(guid) is null);
    assert(viewer.map(0).gameObjectAt(guid) !is null && !viewer.map(0).isReplica(guid),
        "the new owner takes over the existing slot with one platform");
}
