/**
 * Replicas: what one node shows of the creatures and game objects another node simulates
 * (docs/CLUSTER.md, phase 3).
 *
 * A node that simulates an object in a cell some other node is interested in sends that node the
 * object's state (`encodeState`: its fields as everyone sees them, and its movement), then what
 * changes (fields, walks), then its removal, through a `Replicator`. The other node keeps a `Replica`:
 * a map object its players see like any other, which follows its spline so it stays where the real
 * one is, but runs no AI and is never saved. Only what a stranger may see is replicated.
 */
module dmangos.world.replication;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.map : MapObject, Moving;
import dmangos.world.motion : MotionWorld;
import dmangos.world.movement : MovementFlags, MovementInfo, MoveType, Position;
import dmangos.world.objects;
import dmangos.world.player : Player;
import dmangos.world.spline : MoveSpline;
import dmangos.world.updatefields : TypeId;

/// Sends replicas of a map's own objects to the nodes that want them.
interface Replicator
{
    /// `peer` now holds a replica of `guid`, in cell `cell`, with this state (`encodeState`).
    void create(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state);

    /// Fields of `guid` changed (`encodeSlots`).
    void values(ushort peer, uint map, ulong guid, const(ubyte)[] slots);

    /// `guid` started or stopped a walk: the client packet, and its movement after (`encodeMotion`).
    void move(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion);

    /// `peer` no longer holds a replica of `guid`.
    void remove(ushort peer, uint map, ulong guid);
}

/// A map object that can be replicated: it can say how it moves, apart from its whole create block.
interface Replicable : MapObject
{
    /// The movement part of its create block, at `serverTime`.
    MovementBlock motion(uint serverTime) const;
}

/// The movement part of a create block, with its walk written exactly (`MoveSpline.writeExact`).
const(ubyte)[] encodeMotion()(auto ref const MovementBlock block)
{
    ByteWriter w;
    w.put(block.flags);
    if (block.flags & UpdateFlags.living)
    {
        block.info.write(w);
        foreach (speed; block.speeds)
            w.put(speed);
        const walking = block.info.has(MovementFlags.splineEnabled) && block.spline !is null
            && block.spline.initialized;
        w.put(walking);
        if (walking)
            block.spline.writeExact(w);
    }
    else
    {
        w.put(block.position.x);
        w.put(block.position.y);
        w.put(block.position.z);
        w.put(block.position.orientation);
    }
    w.put(block.highGuid);
    w.put(block.transportTime);
    return w.data;
}

/// See `encodeMotion`; the block's spline is `spline`.
MovementBlock decodeMotion(const(ubyte)[] bytes, ref MoveSpline spline)
{
    auto r = ByteReader(bytes);
    MovementBlock block;
    block.flags = r.read!ubyte;
    spline = MoveSpline.init;
    if (block.flags & UpdateFlags.living)
    {
        block.info = MovementInfo.read(r);
        foreach (ref speed; block.speeds)
            speed = r.read!float;
        if (r.read!bool)
            spline = MoveSpline.readExact(r);
    }
    else
        block.position = Position(r.read!float, r.read!float, r.read!float, r.read!float);
    block.highGuid = r.read!uint;
    block.transportTime = r.read!uint;
    return block;
}

/// Changed or initial fields: (slot, value) pairs.
const(ubyte)[] encodeSlots(const(SlotValue)[] slots)
{
    ByteWriter w;
    w.put(cast(ushort) slots.length);
    foreach (s; slots)
    {
        w.put(s.slot);
        w.put(s.value);
    }
    return w.data;
}

/// See `encodeSlots`.
SlotValue[] decodeSlots(ref ByteReader r)
{
    auto slots = new SlotValue[r.read!ushort];
    foreach (ref s; slots)
        s = SlotValue(r.read!ushort, r.read!uint);
    return slots;
}

/// What a replica starts from: the type of its fields, its movement and its public fields.
const(ubyte)[] encodeState(Replicable object, uint serverTime)
{
    ByteWriter w;
    w.put(cast(ubyte) object.fields.type);
    const motion = encodeMotion(object.motion(serverTime));
    w.put(cast(uint) motion.length);
    w.putBytes(motion);
    w.putBytes(encodeSlots(object.fields.publicSlots));
    return w.data;
}

/// What a replica of a player starts from (`encodeState` for a player: as a stranger sees it).
const(ubyte)[] encodePlayerState(const Player player, uint serverTime)
{
    ByteWriter w;
    w.put(cast(ubyte) TypeId.player);
    const motion = encodeMotion(player.motionForOthers(serverTime));
    w.put(cast(uint) motion.length);
    w.putBytes(motion);
    w.putBytes(encodeSlots(player.strangerSlots));
    return w.data;
}

/// See the module documentation.
final class Replica : Replicable, Moving
{
    immutable ulong guid_;
    immutable ushort owner;     /// the node that simulates the real object
    private
    {
        UpdateValues values_;
        MovementBlock block;
        MoveSpline spline;
    }

    /// A replica of `guid` owned by node `owner`, from `encodeState`'s bytes.
    this(ulong guid, ushort owner, const(ubyte)[] state)
    {
        guid_ = guid;
        this.owner = owner;
        auto r = ByteReader(state);
        values_ = UpdateValues(cast(TypeId) r.read!ubyte);
        block = decodeMotion(r.readBytes(r.read!uint), spline);
        foreach (s; decodeSlots(r))
            values_.setSlot(s.slot, s.value);
        values_.clearChanges();
    }

    /// Fields changed on the owner (`encodeSlots`); `Map.flushObjectChanges` sends them on.
    void applySlots(const(ubyte)[] bytes)
    {
        auto r = ByteReader(bytes);
        foreach (s; decodeSlots(r))
            if (s.slot < values_.length)
                values_.setSlot(s.slot, s.value);
    }

    /// The owner's object moved (`encodeMotion`).
    void applyMotion(const(ubyte)[] bytes)
    {
        block = decodeMotion(bytes, spline);
    }

    @property ulong guid() const
    {
        return guid_;
    }

    @property Position position() const
    {
        return block.flags & UpdateFlags.living ? block.info.position : block.position;
    }

    ref UpdateValues fields()
    {
        return values_;
    }

    MovementBlock motion(uint serverTime) const
    {
        MovementBlock m = block;
        m.info.time = serverTime;
        m.spline = &spline;
        return m;
    }

    UpdateData appearance(uint serverTime) const
    {
        UpdateData update;
        auto m = motion(serverTime);
        update.addCreate(UpdateType.createObject, guid_, m, values_, seenByEveryone);
        return update;
    }

    /// See `Moving.resting`: a replica does something only while it walks.
    @property bool resting() const
    {
        return spline.finalized;
    }

    /// Follows the walk, as the owner's object does; nothing else.
    void tick(MotionWorld world, int diff)
    {
        if (spline.finalized)
            return;
        spline.update(diff);
        block.info.position = spline.position;
        if (spline.finalized)
            block.info.flags &= ~(MovementFlags.splineEnabled | MovementFlags.forward);
    }
}

unittest
{
    import dmangos.vmap.math : Vector3;
    import dmangos.world.spline : SplineFlags;
    import dmangos.world.updatefields;

    // A walking unit, written and read back.
    MovementBlock block;
    block.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
    block.info.flags = MovementFlags.splineEnabled | MovementFlags.forward | MovementFlags.walkMode;
    block.info.position = Position(1, 2, 3, 0.5f);
    auto walk = MoveSpline([Vector3(1, 2, 3), Vector3(21, 2, 3)], SplineFlags.none, 2.5f, 9);
    walk.update(1000);
    block.spline = &walk;
    MoveSpline read;
    const back = decodeMotion(encodeMotion(block), read);
    assert(back.flags == block.flags && back.info == block.info && back.speeds == block.speeds);
    assert(read.position == walk.position && read.duration == walk.duration);

    // A game object: just a position.
    MovementBlock still;
    still.flags = UpdateFlags.all | UpdateFlags.hasPosition;
    still.position = Position(5, 6, 7, 1);
    assert(decodeMotion(encodeMotion(still), read).position == still.position && !read.initialized);
}

unittest
{
    import dmangos.vmap.math : Vector3;
    import dmangos.world.spline : SplineFlags;
    import dmangos.world.updatefields;

    // An owner's object, as a test stands in for a creature.
    static final class Walker : Replicable
    {
        UpdateValues values = UpdateValues(TypeId.unit);
        MovementBlock block;
        MoveSpline walk;
        this()
        {
            values.set!OBJECT_FIELD_GUID(ulong(0xF130_0000_0000_0007));
            values.set!OBJECT_FIELD_ENTRY(448u);
            values.set!UNIT_FIELD_HEALTH(100u);
            values.clearChanges();
            block.flags = UpdateFlags.all | UpdateFlags.living | UpdateFlags.hasPosition;
            block.info.flags = MovementFlags.splineEnabled | MovementFlags.forward;
            block.info.position = Position(0, 0, 0, 0);
            walk = MoveSpline([Vector3(0, 0, 0), Vector3(10, 0, 0)], SplineFlags.none, 5, 3);
        }
        @property ulong guid() const { return 0xF130_0000_0000_0007; }
        @property Position position() const { return block.info.position; }
        ref UpdateValues fields() { return values; }
        MovementBlock motion(uint time) const
        {
            MovementBlock m = block;
            m.info.time = time;
            m.spline = &walk;
            return m;
        }
        UpdateData appearance(uint time) const { return UpdateData.init; }
    }

    auto owner = new Walker;
    auto replica = new Replica(owner.guid, 2, encodeState(owner, 100));
    assert(replica.fields[OBJECT_FIELD_ENTRY] == 448 && replica.fields[UNIT_FIELD_HEALTH] == 100);
    assert(!replica.fields.hasChanges && replica.owner == 2);
    assert(replica.appearance(100).blockCount == 1);

    // It follows its walk: 10 yards at 5 a second, 2001 ms.
    replica.tick(null, 2100);
    assert(replica.position.x > 9.9f && replica.position.x < 10.1f);
    assert(!(replica.motion(0).info.flags & MovementFlags.splineEnabled), "arrived");

    // Field changes come over as slots, zeros included.
    owner.values.set!UNIT_FIELD_HEALTH(0u);
    replica.applySlots(encodeSlots(owner.values.changedPublicSlots));
    assert(replica.fields[UNIT_FIELD_HEALTH] == 0 && replica.fields.hasChanges);
}
