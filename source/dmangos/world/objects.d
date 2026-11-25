/**
 * Objects as the client sees them: guids, update field values, and the
 * `SMSG_UPDATE_OBJECT` blocks that create and change them.
 *
 * A create block is:
 * $(OL
 *   $(LI the update type and the object's packed guid and type id;)
 *   $(LI the movement part, whose layout the update flags select;)
 *   $(LI the values: a bit mask over all of the type's fields, then every
 *        field whose bit is set, in order.)
 * )
 * On creation, the mask has a bit for every field that is not zero. A
 * values block later sends only the fields that changed.
 */
module dmangos.world.objects;

import dmangos.bytes : bitsFloat, floatBits;

import dmangos.world.spline : SplineFlags;
import std.algorithm.searching : all, any;
import std.zlib : compress;

import dmangos.bytes;
import dmangos.world.movement;
import dmangos.world.spline : MoveSpline, writeSplineCreate;
import dmangos.world.updatefields;

/// The top 16 bits of a guid: what kind of object it is.
enum HighGuid : ushort
{
    player = 0x0000,
    item = 0x4000, /// items and containers alike
    gameObject = 0xF110,
    unit = 0xF130,
    pet = 0xF140,
    dynamicObject = 0xF100, /// a spell's spot on the ground (`dmangos.world.dynobject`)
    corpse = 0xF101,        /// low guid: its player's
    moTransport = 0x8000, /// ships and zeppelins: the high part and the entry
}

/// First counter reserved for unsaved objects.
package enum uint temporaryCounterStart = 0x00C0_0000;

/// The full guid of an object with low guid `low`.
ulong makeGuid(HighGuid high, uint low) pure nothrow @nogc @safe
{
    return ulong(high) << 48 | low;
}

/// The guid of a creature or game object: its spawn's database guid (24 bits) and its entry.
ulong makeGuid(HighGuid high, uint entry, uint counter) pure nothrow @nogc @safe
in (counter < 1 << 24, "a creature or game object counter has 24 bits")
{
    return ulong(high) << 48 | ulong(entry) << 24 | counter;
}

/// A pet's guid: `HighGuid.pet`, its pet number (24 bits) and a counter (24 bits).
ulong makePetGuid(uint number, uint counter) pure nothrow @nogc @safe
{
    return ulong(HighGuid.pet) << 48 | ulong(number & 0xFF_FFFF) << 24 | (counter & 0xFF_FFFF);
}

/// The kind of object a guid names.
HighGuid highGuidOf(ulong guid) pure nothrow @nogc @safe
{
    return cast(HighGuid)(guid >> 48);
}

/// The spawn's database guid in a creature's or game object's guid.
uint counterOf(ulong guid) pure nothrow @nogc @safe
{
    return cast(uint)(guid & 0xFF_FFFF);
}

/// The low 32 bits of a guid: the database id.
uint lowGuid(ulong guid) pure nothrow @nogc @safe
{
    return cast(uint) guid;
}


/// Which fields a viewer sees: everyone.
enum Visibility seenByEveryone = Visibility.public_ | Visibility.dynamic;
/// ditto: a player looking at itself; it is in its own group, so it sees the group's fields too (its quest
/// log's quest ids are group fields: without them the client's quest log is empty).
enum Visibility seenBySelf = seenByEveryone | Visibility.private_ | Visibility.groupOnly;
/// ditto: a member of the player's group.
enum Visibility seenByGroup = seenByEveryone | Visibility.groupOnly;
/// ditto: the owner of an item, pet or other object, on top of what it otherwise sees.
enum Visibility seenByOwner = Visibility.ownerOnly | Visibility.unk2;

/// Changes the value of slot `slot` for one viewer.
alias ValueAdjuster = uint delegate(size_t slot, uint value) const;

/// What a value written into a field of type `type` must be (see `UpdateValues.set`).
private template accepts(FieldType type, T)
{
    import std.traits : isFloatingPoint, isIntegral, isSomeChar, Unqual;

    static if (type == FieldType.float_)
        enum accepts = is(T : float) && isFloatingPoint!T;
    else static if (type == FieldType.guid)
        enum accepts = is(Unqual!T == ulong);
    else // integers, and bytes and two shorts set whole (or part by part with setByte / setHalf)
        enum accepts = (isIntegral!T || is(T == enum) || is(T == bool)) && !isFloatingPoint!T && !isSomeChar!T;
}

/// The table row of an update field constant.
private enum UpdateField rowOf(UpdateFieldId field) = updateFields[field.row];

/**
 * An object's update fields, with a record of which have changed since
 * `clearChanges`. Setters only mark a field when its value really changes.
 *
 * Fields are set by name, and the name decides the type:
 * ---
 * values.set!UNIT_FIELD_HEALTH(60);           // an integer field
 * values.set!UNIT_FIELD_MINDAMAGE(4.5f);      // a float field
 * values.set!UNIT_FIELD_STAT0(Stat.stamina, 22); // the third of five stats
 * values.set!UNIT_FIELD_STAT0(22.5f);         // does not compile: stats are integers
 * ---
 * An index counts elements: guids for guid fields, slots otherwise. It may run
 * past the named field into the ones that follow (`UNIT_FIELD_STAT0` .. `STAT4`
 * are five fields of one slot), as long as they have the same type; a contract
 * checks that.
 */
struct UpdateValues
{
    private TypeId type_;
    private uint[] slots;
    private uint[] changed; // one bit per slot

    // Not copied: a copy would share both arrays, so a change through it would reach the slots but not be
    // told to the clients through the original's change bits (or the other way round).
    @disable this(this);

    invariant (changed.length == (slots.length + 31) / 32);

    /// The fields of an object of `type`, all zero.
    this(TypeId type) pure nothrow @safe
    {
        type_ = type;
        const count = typesOf(type).length;
        slots = new uint[count];
        changed = new uint[(count + 31) / 32];
    }

    /// The object type the fields belong to.
    @property TypeId type() const pure nothrow @nogc @safe
    {
        return type_;
    }

    /// Number of slots.
    @property size_t length() const pure nothrow @nogc @safe
    {
        return slots.length;
    }

    // -----------------------------------------------------------------------
    // Typed access, by field name
    // -----------------------------------------------------------------------

    /// Sets element `index` of `field` (or the field itself) to `value`; see the struct documentation.
    void set(UpdateFieldId field, T)(size_t index, T value)
    in (slotOf!field(index) + (rowOf!field.type == FieldType.guid ? 1 : 0) < slots.length,
        "past the end of the object's fields")
    in (typeAt(slotOf!field(index)) == rowOf!field.type, "the index runs into a field of another type")
    {
        enum row = rowOf!field;
        static assert(accepts!(row.type, T), "cannot write a " ~ T.stringof ~ " into " ~ row.name ~ ", a "
            ~ __traits(identifier, typeName!(row.type)) ~ " field");
        const slot = slotOf!field(index);
        static if (row.type == FieldType.float_)
            writeSlot(slot, floatBits(value));
        else static if (row.type == FieldType.guid)
        {
            writeSlot(slot, cast(uint) value);
            writeSlot(slot + 1, cast(uint)(value >> 32));
        }
        else
            writeSlot(slot, cast(uint) value);
        // A unit under a fifth of its health shows it (Execute's target: `dmangos.world.aurastate`), wherever the
        // health was set from (CMaNGOS checks it at each `Unit::Update`).
        static if (field == UNIT_FIELD_HEALTH || field == UNIT_FIELD_MAXHEALTH)
            refreshHealthAuraState();
    }

    /// ditto
    void set(UpdateFieldId field, T)(T value)
    {
        set!field(0, value);
    }

    /// `AURA_STATE_HEALTHLESS_20_PERCENT` as the unit's health has it.
    private void refreshHealthAuraState() pure nothrow @nogc @safe
    {
        import dmangos.world.aurastate : AuraState, healthless20Percent, withAuraState;

        if (type_ != TypeId.unit && type_ != TypeId.player)
            return;
        const low = healthless20Percent(slots[UNIT_FIELD_HEALTH], slots[UNIT_FIELD_MAXHEALTH]);
        writeSlot(UNIT_FIELD_AURASTATE, withAuraState(slots[UNIT_FIELD_AURASTATE], AuraState.healthless20Percent, low));
    }

    /// Element `index` of `field`, as its type: `float`, `ulong` for guids, `uint` otherwise.
    auto get(UpdateFieldId field)(size_t index = 0) const
    in (typeAt(slotOf!field(index)) == rowOf!field.type, "the index runs into a field of another type")
    {
        enum row = rowOf!field;
        const slot = slotOf!field(index);
        static if (row.type == FieldType.float_)
            return bitsFloat(slots[slot]);
        else static if (row.type == FieldType.guid)
            return slots[slot] | ulong(slots[slot + 1]) << 32;
        else
            return slots[slot];
    }

    /// Sets byte `offset` (0 = lowest) of a `bytes` field.
    void setByte(UpdateFieldId field)(uint offset, ubyte value, size_t index = 0)
    in (offset < 4)
    {
        static assert(rowOf!field.type == FieldType.bytes, rowOf!field.name ~ " is not a bytes field");
        const slot = slotOf!field(index), shift = offset * 8;
        writeSlot(slot, (slots[slot] & ~(0xFFu << shift)) | (uint(value) << shift));
    }

    /// Byte `offset` of a `bytes` field.
    ubyte getByte(UpdateFieldId field)(uint offset, size_t index = 0) const
    in (offset < 4)
    {
        static assert(rowOf!field.type == FieldType.bytes, rowOf!field.name ~ " is not a bytes field");
        return cast(ubyte)(slots[slotOf!field(index)] >> (offset * 8));
    }

    /// Sets half `offset` (0 = low) of a `twoShort` field, or of a `bytes` field holding a 16-bit value.
    void setHalf(UpdateFieldId field)(uint offset, ushort value, size_t index = 0)
    in (offset < 2)
    {
        static assert(rowOf!field.type == FieldType.twoShort || rowOf!field.type == FieldType.bytes,
            rowOf!field.name ~ " has no halves");
        const slot = slotOf!field(index), shift = offset * 16;
        writeSlot(slot, (slots[slot] & ~(0xFFFFu << shift)) | (uint(value) << shift));
    }

    // -----------------------------------------------------------------------
    // Raw slots, for the wire format and tests
    // -----------------------------------------------------------------------

    /// The raw value of slot `i`.
    uint opIndex(size_t i) const pure nothrow @nogc @safe
    {
        return slots[i];
    }

    /// Whether any field changed since `clearChanges`.
    @property bool hasChanges() const pure nothrow @nogc @safe
    {
        return changed.any!(word => word != 0);
    }

    /// Whether a specific field changed since `clearChanges`.
    bool slotChanged(size_t slot) const pure nothrow @nogc @safe
    {
        return (changed[slot / 32] & (1u << (slot % 32))) != 0;
    }

    /// Forgets the changes, e.g. once they have been sent.
    void clearChanges() pure nothrow @nogc @safe
    {
        changed[] = 0;
    }

    /**
     * Writes the values part of a create block: every non-zero field `seen` lets the viewer see.
     * `adjust`, if given, changes what this viewer is told (per-viewer cases, such as health in
     * percent for strangers).
     */
    void writeCreate(ref ByteWriter writer, Visibility seen, scope ValueAdjuster adjust = null) const
    {
        const visibility = visibilityOf(type_);
        auto mask = new uint[changed.length];
        foreach (i, value; slots)
            if (value && (visibility[i] & seen))
                mask[i / 32] |= 1u << (i % 32);
        writeMasked(writer, mask, adjust);
    }

    /// Writes the values part of a values block: the fields changed since `clearChanges` that `seen` covers.
    void writeChanges(ref ByteWriter writer, Visibility seen, scope ValueAdjuster adjust = null) const
    {
        writeMasked(writer, changesSeen(seen), adjust);
    }

    /// Writes the values part of a values block with exactly the slots `which`, changed or not.
    void writeSlots(ref ByteWriter writer, const(size_t)[] which, scope ValueAdjuster adjust = null) const
    in (which.all!(slot => slot < slots.length))
    {
        auto mask = new uint[changed.length];
        foreach (slot; which)
            mask[slot / 32] |= 1u << (slot % 32);
        writeMasked(writer, mask, adjust);
    }

    /// The slots that `seen` covers but `seenByEveryone` does not, and that are not zero.
    size_t[] slotsOnlyFor(Visibility seen) const pure nothrow @safe
    {
        const visibility = visibilityOf(type_);
        size_t[] found;
        foreach (i, value; slots)
            if (value && (visibility[i] & seen) && !(visibility[i] & seenByEveryone))
                found ~= i;
        return found;
    }

    /// Sets a slot by number, whatever its type: for `.debug setvalue`, not for game code.
    void setSlot(size_t slot, uint value) pure nothrow @safe
    in (slot < slots.length)
    {
        writeSlot(slot, value);
    }

    /// The slots everyone may see that are not zero, as (slot, value): a replica's state.
    SlotValue[] publicSlots() const pure nothrow @safe
    {
        const visibility = visibilityOf(type_);
        SlotValue[] found;
        foreach (i, value; slots)
            if (value && (visibility[i] & seenByEveryone))
                found ~= SlotValue(cast(ushort) i, value);
        return found;
    }

    /// The slots everyone may see that changed since `clearChanges`, zeros included: a replica's update.
    SlotValue[] changedPublicSlots() const pure nothrow @safe
    {
        const visibility = visibilityOf(type_);
        SlotValue[] found;
        foreach (i, value; slots)
            if ((changed[i / 32] & (1u << (i % 32))) && (visibility[i] & seenByEveryone))
                found ~= SlotValue(cast(ushort) i, value);
        return found;
    }

    /// Whether a viewer that sees `seen` has changes to be told about.
    bool hasChangesFor(Visibility seen) const pure nothrow @safe
    {
        return changesSeen(seen).any!(word => word != 0);
    }

private:
    static size_t slotOf(UpdateFieldId field)(size_t index) pure nothrow @nogc @safe
    {
        return field + index * (rowOf!field.type == FieldType.guid ? 2 : 1);
    }

    FieldType typeAt(size_t slot) const pure nothrow @nogc @safe
    {
        const types = typesOf(type_);
        return slot < types.length ? types[slot] : FieldType.none;
    }

    void writeSlot(size_t slot, uint value) pure nothrow @nogc @safe
    {
        if (slots[slot] != value)
        {
            slots[slot] = value;
            changed[slot / 32] |= 1u << (slot % 32);
        }
    }

    uint[] changesSeen(Visibility seen) const pure nothrow @safe
    {
        const visibility = visibilityOf(type_);
        auto mask = changed.dup;
        foreach (i; 0 .. slots.length)
            if (!(visibility[i] & seen))
                mask[i / 32] &= ~(1u << (i % 32));
        return mask;
    }

    void writeMasked(ref ByteWriter writer, const(uint)[] mask, scope ValueAdjuster adjust) const
    {
        writer.put(cast(ubyte) mask.length);
        foreach (word; mask)
            writer.put(word);
        foreach (i, value; slots)
            if (mask[i / 32] & (1u << (i % 32)))
                writer.put(adjust is null ? value : adjust(i, value));
    }
}

/// The compile-time per-slot tables of `updatefields`, chosen at run time.
private immutable(FieldType)[] typesOf(TypeId type) pure nothrow @nogc @safe
{
    final switch (type)
    {
        static foreach (t; __traits(allMembers, TypeId))
        {
    case __traits(getMember, TypeId, t):
            return fieldTypes!(__traits(getMember, TypeId, t));
        }
    }
}

/// ditto
private immutable(Visibility)[] visibilityOf(TypeId type) pure nothrow @nogc @safe
{
    final switch (type)
    {
        static foreach (t; __traits(allMembers, TypeId))
        {
    case __traits(getMember, TypeId, t):
            return fieldVisibility!(__traits(getMember, TypeId, t));
        }
    }
}

private alias typeName(FieldType type) = __traits(getMember, FieldType, __traits(allMembers, FieldType)[type]);

/// The kind of an update block.
enum UpdateType : ubyte
{
    values = 0,
    movement = 1,
    createObject = 2,
    createObject2 = 3, /// a new object: a player, creature or game object that just appeared
    outOfRangeObjects = 4,
    nearObjects = 5,
}

/// What a create block's movement part holds.
enum UpdateFlags : ubyte
{
    none = 0x00,
    self = 0x01,          /// the receiving client's own player
    transport = 0x02,
    attackingTarget = 0x04,
    highGuid = 0x08,
    all = 0x10,           /// adds a uint32 1
    living = 0x20,        /// adds movement info and speeds
    hasPosition = 0x40,   /// adds a position, for objects that are not living
}

/// A slot of an object's fields and its value (replication).
struct SlotValue
{
    ushort slot;
    uint value;
}

/// What the movement part of a create block contains.
struct MovementBlock
{
    ubyte flags;         /// a set of `UpdateFlags`
    MovementInfo info;   /// for `living`
    float[MoveType.max + 1] speeds = baseMoveSpeed; /// for `living`
    Position position;   /// for `hasPosition` without `living`
    uint highGuid;       /// for `highGuid`
    uint transportTime;  /// for `transport`: the path's time (elevators)
    const(MoveSpline)* spline; /// for `living` with `MovementFlags.splineEnabled`: the walk under way

    /// Writes the movement part, as `flags` selects it, without transports or attack targets.
    void write(ref ByteWriter writer) const
    {
        writer.put(flags);
        if (flags & UpdateFlags.living)
        {
            // A unit that is not walking a spline has no spline to show, whatever its flags say: a walk that
            // has ended (a replica's ends between its ticks) included. It stands, facing where it ended.
            const walking = info.has(MovementFlags.splineEnabled) && spline !is null && spline.showable;
            MovementInfo living = info;
            if (!walking && info.has(MovementFlags.splineEnabled))
            {
                living.flags &= ~(MovementFlags.splineEnabled | MovementFlags.forward);
                if (spline !is null && spline.initialized && (spline.flags & SplineFlags.finalAngle))
                    living.position.orientation = spline.facingAngle;
            }
            living.write(writer);
            foreach (speed; speeds)
                writer.put(speed);
            if (walking)
                writeSplineCreate(writer, *spline);
        }
        else if (flags & UpdateFlags.hasPosition)
        {
            writer.put(position.x);
            writer.put(position.y);
            writer.put(position.z);
            writer.put(position.orientation);
        }
        if (flags & UpdateFlags.highGuid)
            writer.put(highGuid);
        if (flags & UpdateFlags.all)
            writer.put(uint(1));
        if (flags & UpdateFlags.transport)
            writer.put(transportTime);
    }
}

/// Collects update blocks for one `SMSG_UPDATE_OBJECT`.
struct UpdateData
{
    private ByteWriter blocks;
    private uint count;
    private bool hasTransport; // a block creates a ship or zeppelin (the header says so)

    /// Number of blocks added.
    @property uint blockCount() const pure nothrow @nogc @safe
    {
        return count;
    }

    /// A create block, for a viewer that sees the fields `seen` covers.
    void addCreate(UpdateType type, ulong guid, const ref MovementBlock movement, const ref UpdateValues values,
        Visibility seen, scope ValueAdjuster adjust = null)
    in (type == UpdateType.createObject || type == UpdateType.createObject2)
    {
        blocks.put(cast(ubyte) type);
        blocks.putPackedGuid(guid);
        blocks.put(cast(ubyte) values.type);
        movement.write(blocks);
        values.writeCreate(blocks, seen, adjust);
        ++count;
        if (highGuidOf(guid) == HighGuid.moTransport)
            hasTransport = true;
    }

    /// A values block: the fields changed since the last `clearChanges`.
    void addValues(ulong guid, const ref UpdateValues values, Visibility seen, scope ValueAdjuster adjust = null)
    {
        blocks.put(cast(ubyte) UpdateType.values);
        blocks.putPackedGuid(guid);
        values.writeChanges(blocks, seen, adjust);
        ++count;
    }

    /// A values block with the slots `which`, whether they changed or not.
    void addSlots(ulong guid, const ref UpdateValues values, const(size_t)[] which, scope ValueAdjuster adjust = null)
    {
        blocks.put(cast(ubyte) UpdateType.values);
        blocks.putPackedGuid(guid);
        values.writeSlots(blocks, which, adjust);
        ++count;
    }

    /// Objects the viewer should forget, sent as one block.
    void addOutOfRange(const(ulong)[] guids)
    in (guids.length > 0)
    {
        blocks.put(cast(ubyte) UpdateType.outOfRangeObjects);
        blocks.put(cast(uint) guids.length);
        foreach (guid; guids)
            blocks.putPackedGuid(guid);
        ++count;
    }

    /// Adds the blocks of another update.
    void append()(auto ref const UpdateData other)
    {
        blocks.putBytes(other.blocks.data);
        count += other.count;
        hasTransport |= other.hasTransport;
    }

    /// Whether no block has been added.
    @property bool empty() const pure nothrow @nogc @safe
    {
        return count == 0;
    }

    /// Bytes of blocks so far, before compression.
    @property size_t byteSize() const pure nothrow @nogc @safe
    {
        return blocks.length;
    }

    /**
     * The packet body: the block count and whether a block creates a transport, then the blocks. Bodies over
     * 100 bytes are compressed.
     */
    UpdatePacket build() const
    {
        ByteWriter body_;
        body_.put(count);
        // Whether a block creates a transport: the 1.12 client sets a ship up from such a packet (as vmangos and
        // CMaNGOS send it); with 0, it crashed a few seconds after showing a zeppelin.
        body_.put(ubyte(hasTransport ? 1 : 0));
        body_.putBytes(blocks.data);
        if (body_.length <= 100)
            return UpdatePacket(false, body_.data.dup);

        ByteWriter compressed;
        compressed.put(cast(uint) body_.length);
        compressed.putBytes(cast(const(ubyte)[]) compress(body_.data, updateCompression));
        return UpdatePacket(true, compressed.data.dup);
    }
}

/**
 * The zlib level update packets are compressed with (the `Compression` setting: 1, the fastest,
 * by default); set from the configuration at start-up.
 */
__gshared int updateCompression = 1; // written once at start-up, before any other thread; read after

/**
 * The most bytes of blocks one update packet should carry before it is compressed:
 * the largest packet the client accepts (32766 bytes), less 128 kept in reserve.
 */
enum size_t maxUpdatePacketBytes = 32_766 - 128;

/// An `SMSG_UPDATE_OBJECT` or `SMSG_COMPRESSED_UPDATE_OBJECT` body.
struct UpdatePacket
{
    bool compressed;
    ubyte[] body_;
}

unittest
{
    // Packed guids: only the non-zero bytes follow the mask.
    ByteWriter w;
    w.putPackedGuid(makeGuid(HighGuid.item, 0x0102));
    const ubyte[4] expected = [0b1000_0011, 0x02, 0x01, 0x40];
    assert(w.data == expected[]);
    auto r = ByteReader(w.data);
    assert(r.readPackedGuid() == 0x4000_0000_0000_0102);
    assert(lowGuid(makeGuid(HighGuid.item, 77)) == 77);
}

unittest
{
    import core.exception : AssertError;
    import std.exception : assertThrown;

    // Each object type gets exactly its fields.
    assert(UpdateValues(TypeId.player).length == PLAYER_END && UpdateValues(TypeId.item).length == ITEM_END);

    auto values = UpdateValues(TypeId.player);
    values.set!OBJECT_FIELD_GUID(5UL);
    values.set!OBJECT_FIELD_SCALE_X(1.0f);
    values.set!UNIT_FIELD_STAT0(2, 22);      // the third stat
    values.setByte!UNIT_FIELD_BYTES_0(1, 8);
    values.setHalf!PLAYER_BYTES_3(0, 1);
    values.set!PLAYER_FIELD_INV_SLOT_HEAD(15, 0x4000_0000_0000_0007UL); // the main hand's guid
    assert(values[OBJECT_FIELD_SCALE_X] == 0x3F80_0000 && values.get!OBJECT_FIELD_SCALE_X == 1.0f);
    assert(values[UNIT_FIELD_STAT0 + 2] == 22 && values.get!UNIT_FIELD_STAT0(2) == 22);
    assert(values[UNIT_FIELD_BYTES_0] == 0x0800 && values.getByte!UNIT_FIELD_BYTES_0(1) == 8);
    assert(values.get!OBJECT_FIELD_GUID == 5 && values.get!PLAYER_FIELD_INV_SLOT_HEAD(15) == 0x4000_0000_0000_0007);

    // The type rules are checked while compiling; the index rule by a contract.
    static assert(!__traits(compiles, values.set!UNIT_FIELD_STAT0(22.5f)), "stats are integers");
    static assert(!__traits(compiles, values.set!UNIT_FIELD_MINDAMAGE(4)), "damage is a float");
    static assert(!__traits(compiles, values.set!OBJECT_FIELD_GUID(5)), "a guid is a ulong");
    static assert(!__traits(compiles, values.setByte!UNIT_FIELD_HEALTH(0, 1)), "health has no bytes");
    debug assertThrown!AssertError(values.set!UNIT_FIELD_RANGEDATTACKTIME(1, 5), "the slot after it is a float");

    // Creation sends the fields the viewer may see: coinage is private, health public.
    values.set!PLAYER_FIELD_COINAGE(100);
    values.set!UNIT_FIELD_HEALTH(60);
    ByteWriter self, other;
    values.writeCreate(self, seenBySelf);
    values.writeCreate(other, seenByEveryone);
    assert(self.length == other.length + 4 * 4,
        "coinage, the third stat and the main hand's two-slot guid are private");

    // Changes: unchanged writes are not recorded.
    values.clearChanges();
    assert(!values.hasChanges);
    values.set!OBJECT_FIELD_SCALE_X(1.0f);
    assert(!values.hasChanges);
    values.set!UNIT_FIELD_HEALTH(59);
    ByteWriter change;
    values.writeChanges(change, seenByEveryone);
    assert(change.length == 1 + 41 * 4 + 4);
}

unittest
{
    import std.zlib : uncompress;

    // An item: type 2, packed guid, type id, movement flags ALL (adds uint32 1), values.
    auto values = UpdateValues(TypeId.item);
    values.set!OBJECT_FIELD_GUID(makeGuid(HighGuid.item, 1));
    MovementBlock movement;
    movement.flags = UpdateFlags.all;
    UpdateData data;
    data.addCreate(UpdateType.createObject, makeGuid(HighGuid.item, 1), movement, values, seenBySelf);
    const small = data.build();
    assert(!small.compressed);
    // count (4) + transport (1) + type (1) + guid (3) + type id (1) + flags (1) + 1 (4) + mask count (1)
    // + 2 words + 2 values
    assert(small.body_.length == 4 + 1 + 1 + 3 + 1 + 1 + 4 + 1 + 8 + 8);
    assert(small.body_[0 .. 6] == [1, 0, 0, 0, 0, 2]);

    // Large updates are compressed, prefixed with their real size.
    foreach (i; 0 .. 30)
        data.addValues(makeGuid(HighGuid.item, 1), values, seenBySelf);
    const large = data.build();
    assert(large.compressed);
    const size = large.body_[0] | large.body_[1] << 8 | large.body_[2] << 16 | large.body_[3] << 24;
    const plain = cast(const(ubyte)[]) uncompress(large.body_[4 .. $]);
    assert(plain.length == size && plain[0] == 31);
}

unittest
{
    auto values = UpdateValues(TypeId.player);
    values.set!UNIT_FIELD_HEALTH(30);
    values.set!UNIT_FIELD_MAXHEALTH(60);
    values.set!PLAYER_FIELD_COINAGE(5);

    // A viewer can be told something else than the stored value.
    uint percent(size_t slot, uint value) const
    {
        return slot == UNIT_FIELD_HEALTH ? 50 : slot == UNIT_FIELD_MAXHEALTH ? 100 : value;
    }
    ByteWriter told;
    values.writeCreate(told, seenByEveryone, &percent);
    auto r = ByteReader(told.data);
    r.skip(1 + 41 * 4);
    assert(r.read!uint == 50 && r.read!uint == 100);

    // Private changes are not for others.
    values.clearChanges();
    values.set!PLAYER_FIELD_COINAGE(6);
    assert(values.hasChangesFor(seenBySelf) && !values.hasChangesFor(seenByEveryone));

    // The quest log's ids are group fields, and the player sees them in its own log; strangers do not.
    values.clearChanges();
    values.set!PLAYER_QUEST_LOG_1_1(33);
    assert(values.hasChangesFor(seenBySelf) && values.hasChangesFor(seenByGroup)
        && !values.hasChangesFor(seenByEveryone));

    // An out-of-range block: type 4, the count, packed guids.
    UpdateData data;
    assert(data.empty);
    data.addOutOfRange([1, makeGuid(HighGuid.player, 2)]);
    const packet = data.build();
    assert(packet.body_ == [1, 0, 0, 0, 0, 4, 2, 0, 0, 0, 1, 1, 1, 2]);
}
