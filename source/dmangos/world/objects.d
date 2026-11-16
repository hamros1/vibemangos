/**
 * Objects as the client sees them: guids, update field values, and the
 * `SMSG_UPDATE_OBJECT` blocks that create and change them (CMaNGOS
 * `Entities/Object.cpp`, `UpdateData.cpp`, `UpdateMask.h`).
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

import std.algorithm.searching : all;
import std.zlib : compress;

import dmangos.bytes;
import dmangos.world.movement;
import dmangos.world.updatefields;

/// `HighGuid`: the top 16 bits of a guid.
enum HighGuid : ushort
{
    player = 0x0000,
    item = 0x4000, /// items and containers alike
}

/// The full guid of an object with low guid `low`.
ulong makeGuid(HighGuid high, uint low) pure nothrow @nogc @safe
{
    return ulong(high) << 48 | low;
}

/// The low 32 bits of a guid: the database id.
uint lowGuid(ulong guid) pure nothrow @nogc @safe
{
    return cast(uint) guid;
}

/// Writes a guid in packed form (`ByteWriter.putPackedGuid`).
void putPackedGuid(ref ByteWriter writer, ulong guid) pure nothrow @safe
{
    writer.putPackedGuid(guid);
}

/// Reads a packed guid (`ByteReader.readPackedGuid`).
ulong readPackedGuid(ref ByteReader reader) pure @safe
{
    return reader.readPackedGuid();
}

/// Which fields a viewer sees (`Object::GetUpdateFieldFlagsForTarget`).
enum Visibility seenByEveryone = Visibility.public_ | Visibility.dynamic;
/// ditto: a player looking at itself.
enum Visibility seenBySelf = seenByEveryone | Visibility.private_;
/// ditto: a member of the player's group.
enum Visibility seenByGroup = seenByEveryone | Visibility.groupOnly;
/// ditto: the owner of an item, pet or other object, on top of what it otherwise sees.
enum Visibility seenByOwner = Visibility.ownerOnly | Visibility.unk2;

/// Changes the value of slot `slot` for one viewer.
alias ValueAdjuster = uint delegate(size_t slot, uint value) const;

/// What a value written into a field of type `type` must be (see `UpdateValues.set`).
private template accepts(FieldType type, T)
{
    import std.traits : isFloatingPoint, isIntegral, isSomeChar;

    static if (type == FieldType.float_)
        enum accepts = is(T : float) && isFloatingPoint!T;
    else static if (type == FieldType.guid)
        enum accepts = is(T == ulong);
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
    }

    /// ditto
    void set(UpdateFieldId field, T)(T value)
    {
        set!field(0, value);
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
        foreach (word; changed)
            if (word)
                return true;
        return false;
    }

    /// Forgets the changes, e.g. once they have been sent.
    void clearChanges() pure nothrow @nogc @safe
    {
        changed[] = 0;
    }

    /**
     * Writes the values part of a create block: every non-zero field `seen` lets the viewer see.
     * `adjust`, if given, changes what this viewer is told (`Object::BuildValuesUpdate`'s per-viewer
     * cases, such as health in percent for strangers).
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

    /// Whether a viewer that sees `seen` has changes to be told about.
    bool hasChangesFor(Visibility seen) const pure nothrow @safe
    {
        foreach (word; changesSeen(seen))
            if (word)
                return true;
        return false;
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

private uint floatBits(float value) pure nothrow @nogc @trusted
{
    return *cast(uint*)&value;
}

private float bitsFloat(uint bits) pure nothrow @nogc @trusted
{
    return *cast(float*)&bits;
}

/// `OBJECT_UPDATE_TYPE`
enum UpdateType : ubyte
{
    values = 0,
    movement = 1,
    createObject = 2,
    createObject2 = 3, /// a new object: a player, creature or game object that just appeared
    outOfRangeObjects = 4,
    nearObjects = 5,
}

/// `OBJECT_UPDATE_FLAGS`
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

/// What the movement part of a create block contains.
struct MovementBlock
{
    ubyte flags;         /// `UpdateFlags`
    MovementInfo info;   /// for `living`
    float[MoveType.max + 1] speeds = baseMoveSpeed; /// for `living`
    Position position;   /// for `hasPosition` without `living`
    uint highGuid;       /// for `highGuid`

    /// `Object::BuildMovementUpdate`, without splines, transports or attack targets.
    void write(ref ByteWriter writer) const
    {
        writer.put(flags);
        if (flags & UpdateFlags.living)
        {
            info.write(writer);
            foreach (speed; speeds)
                writer.put(speed);
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
    }
}

/// Collects update blocks for one `SMSG_UPDATE_OBJECT`.
struct UpdateData
{
    private ByteWriter blocks;
    private uint count;

    /// Number of blocks added.
    @property uint blockCount() const pure nothrow @nogc @safe
    {
        return count;
    }

    /// `Object::BuildCreateUpdateBlockForPlayer`, for a viewer that sees the fields `seen` covers.
    void addCreate(UpdateType type, ulong guid, const ref MovementBlock movement, const ref UpdateValues values,
        Visibility seen, scope ValueAdjuster adjust = null)
    in (type == UpdateType.createObject || type == UpdateType.createObject2)
    {
        blocks.put(cast(ubyte) type);
        putPackedGuid(blocks, guid);
        blocks.put(cast(ubyte) values.type);
        movement.write(blocks);
        values.writeCreate(blocks, seen, adjust);
        ++count;
    }

    /// `Object::BuildValuesUpdateBlockForPlayer`: the fields changed since the last `clearChanges`.
    void addValues(ulong guid, const ref UpdateValues values, Visibility seen, scope ValueAdjuster adjust = null)
    {
        blocks.put(cast(ubyte) UpdateType.values);
        putPackedGuid(blocks, guid);
        values.writeChanges(blocks, seen, adjust);
        ++count;
    }

    /// A values block with the slots `which`, whether they changed or not (`ForceValuesUpdateAtIndex`).
    void addSlots(ulong guid, const ref UpdateValues values, const(size_t)[] which, scope ValueAdjuster adjust = null)
    {
        blocks.put(cast(ubyte) UpdateType.values);
        putPackedGuid(blocks, guid);
        values.writeSlots(blocks, which, adjust);
        ++count;
    }

    /// `UpdateData::AddOutOfRangeGUID`: objects the viewer should forget, sent as one block.
    void addOutOfRange(const(ulong)[] guids)
    in (guids.length > 0)
    {
        blocks.put(cast(ubyte) UpdateType.outOfRangeObjects);
        blocks.put(cast(uint) guids.length);
        foreach (guid; guids)
            putPackedGuid(blocks, guid);
        ++count;
    }

    /// Whether no block has been added.
    @property bool empty() const pure nothrow @nogc @safe
    {
        return count == 0;
    }

    /**
     * `UpdateData::BuildPacketOfBlocks`: the block count and transport flag,
     * then the blocks. Bodies over 100 bytes are compressed, as CMaNGOS does.
     */
    UpdatePacket build() const
    {
        ByteWriter body_;
        body_.put(count);
        body_.put(ubyte(0)); // no block describes a transport
        body_.putBytes(blocks.data);
        if (body_.length <= 100)
            return UpdatePacket(false, body_.data.dup);

        ByteWriter compressed;
        compressed.put(cast(uint) body_.length);
        compressed.putBytes(cast(const(ubyte)[]) compress(body_.data));
        return UpdatePacket(true, compressed.data.dup);
    }
}

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
    putPackedGuid(w, makeGuid(HighGuid.item, 0x0102));
    const ubyte[4] expected = [0b1000_0011, 0x02, 0x01, 0x40];
    assert(w.data == expected[]);
    auto r = ByteReader(w.data);
    assert(readPackedGuid(r) == 0x4000_0000_0000_0102);
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
    assert(self.length == other.length + 4 * 4, "coinage, the third stat and the main hand's two-slot guid are private");

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
    // count (4) + transport (1) + type (1) + guid (3) + type id (1) + flags (1) + 1 (4) + mask count (1) + 2 words + 2 values
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

    // An out-of-range block: type 4, the count, packed guids.
    UpdateData data;
    assert(data.empty);
    data.addOutOfRange([1, makeGuid(HighGuid.player, 2)]);
    const packet = data.build();
    assert(packet.body_ == [1, 0, 0, 0, 0, 4, 2, 0, 0, 0, 1, 1, 1, 2]);
}
