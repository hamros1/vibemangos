/**
 * Reader for the client's DBC tables (`WDBC` files, as extracted into the data directory's `dbc/` folder).
 *
 * A DBC file is a header, fixed-size records and a string block. Records
 * are described by format strings, one
 * character per field:
 *
 * $(UL
 *   $(LI `n`: the record id, stored in the struct and used as the index;)
 *   $(LI `d`: the record id, used as the index but not stored;)
 *   $(LI `i`: a 32-bit integer; `f`: a float; `s`: a string; `l`: a 32-bit boolean;)
 *   $(LI `b`: an 8-bit integer; `x`/`X`: a skipped 32-/8-bit field.)
 * )
 *
 * `DbcStore!(Entry, format)` checks at compile time that the stored
 * characters match `Entry`'s fields, with static arrays counting once per
 * element. It then generates the decoder for that layout, so a record
 * definition that does not match its format fails to compile.
 */
module dmangos.dbc;

import std.bitmanip : littleEndianToNative;
import std.exception : basicExceptionCtors, enforce;
import std.format : format;
import std.traits : isFloatingPoint, isIntegral, isSomeString, isStaticArray;

/// Thrown for a missing, truncated or mismatched DBC file.
class DbcException : Exception
{
    mixin basicExceptionCtors;
}

/// The first four bytes of a DBC file, "WDBC", read as a little-endian `uint`.
enum uint dbcMagic = 0x43424457;

/// Bytes a format character occupies in a record.
private size_t fieldSize(char c) pure @safe
{
    return c == 'X' || c == 'b' ? 1 : 4;
}

private bool isStored(char c) pure @safe
{
    return c != 'x' && c != 'X' && c != 'd' && c != 'F';
}

/// One assignment of the generated decoder: a record field into a struct field (element).
private struct Step
{
    size_t offset;   // byte offset in the record
    char kind;       // format character
    size_t field;    // index into Entry.tupleof
    size_t element;  // index within a static array field
}

/// The decoding plan for `Entry` under `fmt`, computed at compile time.
private Step[] planFor(Entry)(string fmt)
{
    size_t[] fieldOf, elementOf;
    static foreach (i; 0 .. Entry.tupleof.length)
    {{
        alias F = typeof(Entry.tupleof[i]);
        static if (isStaticArray!F && !isSomeString!F)
            enum count = F.length;
        else
            enum count = 1;
        foreach (e; 0 .. count)
        {
            fieldOf ~= i;
            elementOf ~= e;
        }
    }}

    Step[] steps;
    size_t offset, next;
    foreach (c; fmt)
    {
        if (isStored(c))
        {
            assert(next < fieldOf.length, "format string stores more fields than " ~ Entry.stringof ~ " has");
            steps ~= Step(offset, c, fieldOf[next], elementOf[next]);
            ++next;
        }
        offset += fieldSize(c);
    }
    assert(next == fieldOf.length, "format string stores fewer fields than " ~ Entry.stringof ~ " has");
    return steps;
}

/// Record size in bytes described by `fmt`.
size_t recordSize(string fmt) pure @safe
{
    size_t total;
    foreach (c; fmt)
        total += fieldSize(c);
    return total;
}

/// The records of one DBC file, decoded into `Entry` values.
struct DbcStore(Entry, string fmt)
{
    private enum Step[] steps = planFor!Entry(fmt);
    private enum bool indexed = fmt.length > 0 && (fmt[0] == 'n' || fmt[0] == 'd');

    // Every stored field's type must suit its format character; checked when the store is instantiated.
    private static void checkLayout()
    {
        static foreach (step; steps)
        {{
            alias F = typeof(Entry.tupleof[step.field]);
            static if (isStaticArray!F && !isSomeString!F)
                alias E = typeof(F.init[0]);
            else
                alias E = F;
            static if (step.kind == 'i' || step.kind == 'n')
                static assert(isIntegral!E && E.sizeof == 4, Entry.stringof ~ ": field " ~ step.field.stringof
                    ~ " must be a 32-bit integer");
            else static if (step.kind == 'f')
                static assert(isFloatingPoint!E, Entry.stringof ~ ": expected a float");
            else static if (step.kind == 's')
                static assert(is(E == string), Entry.stringof ~ ": expected a string");
            else static if (step.kind == 'b')
                static assert(is(E == ubyte), Entry.stringof ~ ": expected a ubyte");
            else static if (step.kind == 'l')
                static assert(is(E == bool), Entry.stringof ~ ": expected a bool");
        }}
    }

    /// Records in file order.
    Entry[] rows;

    /// Record ids in file order (the row number for unindexed formats).
    uint[] ids;

    private size_t[uint] positionOf;

    /// Decodes a DBC image. `name` is only used in error messages.
    static DbcStore parse(const(ubyte)[] data, string name)
    {
        enforce!DbcException(data.length >= 20, name ~ ": file too short for a DBC header");
        const magic = read!uint(data, 0);
        enforce!DbcException(magic == dbcMagic, name ~ ": not a DBC file");
        const recordCount = read!uint(data, 4);
        const fieldCount = read!uint(data, 8);
        const size = read!uint(data, 12);
        const stringSize = read!uint(data, 16);
        enforce!DbcException(fieldCount == fmt.length, format!"%s: has %s fields, the format expects %s"(name,
            fieldCount, fmt.length));
        enforce!DbcException(size == recordSize(fmt), format!"%s: records are %s bytes, the format expects %s"(name,
            size, recordSize(fmt)));
        const recordsEnd = 20 + ulong(recordCount) * size;
        enforce!DbcException(data.length >= recordsEnd + stringSize, name ~ ": file is truncated");
        const strings = data[cast(size_t) recordsEnd .. cast(size_t)(recordsEnd + stringSize)];

        DbcStore store;
        store.rows.reserve(recordCount);
        foreach (r; 0 .. recordCount)
        {
            const record = data[20 + r * size .. 20 + (r + 1) * size];
            Entry entry;
            static foreach (step; steps)
                assign!step(entry, record, strings);
            const id = indexed ? read!uint(record, 0) : r;
            store.positionOf[id] = store.rows.length;
            store.rows ~= entry;
            store.ids ~= id;
        }
        return store;
    }

    /// Reads and decodes `path`.
    static DbcStore load(string path)
    {
        import std.file : exists, read;

        enforce!DbcException(path.exists,
            path ~ ": not found (set data_dir to mangosd's DataDir, with its dbc/ folder)");
        return parse(cast(const(ubyte)[]) read(path), path);
    }

    /// The record with id `id`, or null.
    const(Entry)* lookup(uint id) const
    {
        if (auto position = id in positionOf)
            return &rows[*position];
        return null;
    }

    /// Highest id + 1, for loops over the id range.
    @property uint idLimit() const
    {
        uint limit;
        foreach (id; ids)
            if (id + 1 > limit)
                limit = id + 1;
        return limit;
    }

    private static T read(T)(const(ubyte)[] bytes, size_t offset)
    {
        ubyte[T.sizeof] raw = bytes[offset .. offset + T.sizeof];
        return littleEndianToNative!T(raw);
    }

    private static void assign(Step step)(ref Entry entry, const(ubyte)[] record, const(ubyte)[] strings)
    {
        alias F = typeof(Entry.tupleof[step.field]);
        static if (isStaticArray!F && !isSomeString!F)
            alias E = typeof(F.init[0]);
        else
            alias E = F;

        static if (step.kind == 's')
        {
            const start = read!uint(record, step.offset);
            enforce!DbcException(start < strings.length || (start == 0 && strings.length == 0),
                "string offset outside the string block");
            size_t end = start;
            while (end < strings.length && strings[end] != 0)
                ++end;
            E value = strings.length ? (cast(const(char)[]) strings[start .. end]).idup : null;
        }
        else static if (step.kind == 'f')
            E value = read!float(record, step.offset);
        else static if (step.kind == 'b')
            E value = record[step.offset];
        else static if (step.kind == 'l')
            E value = read!uint(record, step.offset) != 0;
        else
            E value = cast(E) read!uint(record, step.offset);

        static if (isStaticArray!F && !isSomeString!F)
            entry.tupleof[step.field][step.element] = value;
        else
            entry.tupleof[step.field] = value;
    }
}

/**
 * Builds a DBC image, for tests and tools. `fields` holds the raw 32-bit
 * value of every field of every record, in order, with strings given as
 * offsets into `stringBlock` (which should start with a 0 byte).
 */
ubyte[] buildDbc(string fmt, const(uint[])[] records, const(ubyte)[] stringBlock = [0])
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] output;
    void put(uint value)
    {
        output ~= nativeToLittleEndian(value)[];
    }

    put(dbcMagic);
    put(cast(uint) records.length);
    put(cast(uint) fmt.length);
    put(cast(uint) recordSize(fmt));
    put(cast(uint) stringBlock.length);
    foreach (record; records)
    {
        assert(record.length == fmt.length, "one value per format character");
        foreach (i, c; fmt)
        {
            if (fieldSize(c) == 1)
                output ~= cast(ubyte) record[i];
            else
                put(record[i]);
        }
    }
    return output ~ stringBlock;
}

unittest
{
    import std.exception : assertThrown;

    static struct Sample
    {
        uint id;
        int signed;
        float ratio;
        string name;
        uint[2] pair;
        ubyte small;
    }

    enum fmt = "nixfsiibx";
    static assert(recordSize(fmt) == 4 * 8 + 1);

    const ubyte[] block = cast(const(ubyte)[]) "\0Ragefire\0";
    const uint[][] records = [
        [7, cast(uint) -5, 99, 0x40490FDB, 1, 10, 20, 3, 0],
        [9, 4, 0, 0, 0, 0, 0, 0, 0],
    ];
    const raw = buildDbc(fmt, records, block);
    const store = DbcStore!(Sample, fmt).parse(raw, "Sample.dbc");
    assert(store.rows.length == 2 && store.ids == [7, 9]);
    const first = store.lookup(7);
    assert(first !is null && first.id == 7 && first.signed == -5 && first.name == "Ragefire");
    assert(first.ratio > 3.14f && first.ratio < 3.15f);
    assert(first.pair == [10, 20] && first.small == 3);
    assert(store.lookup(8) is null && store.idLimit == 10);

    // Unindexed formats are keyed by row number; 'd' indexes without storing.
    static struct Pair
    {
        uint a;
        uint b;
    }

    const uint[][] pairs = [[5, 6], [7, 8]];
    const unindexed = DbcStore!(Pair, "ii").parse(buildDbc("ii", pairs), "Pair.dbc");
    assert(unindexed.lookup(1).a == 7);
    const uint[][] sortedRecords = [[40, 5, 6]];
    const sorted = DbcStore!(Pair, "dii").parse(buildDbc("dii", sortedRecords), "Sorted.dbc");
    assert(sorted.lookup(40).b == 6);

    // A file whose layout disagrees with the format is rejected, not misread.
    const uint[][] triple = [[1, 2, 3]];
    assertThrown!DbcException(DbcStore!(Pair, "ii").parse(buildDbc("iii", triple), "Wrong.dbc"));
    const ubyte[3] tiny = [1, 2, 3];
    assertThrown!DbcException(DbcStore!(Pair, "ii").parse(tiny[], "Short.dbc"));

    // And a struct that disagrees with its format does not compile.
    static struct TooFew
    {
        uint a;
    }

    static assert(!__traits(compiles, DbcStore!(TooFew, "ii").parse(null, "")));
}
