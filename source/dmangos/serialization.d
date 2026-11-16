/**
 * Packet (de)serialization generated at compile time from struct definitions.
 *
 * A packet is a plain struct. Its fields are written in declaration order,
 * little-endian and without alignment padding. User-defined attributes
 * select the wire format of fields that a type alone cannot describe:
 *
 * ---
 * struct Example
 * {
 *     uint id;                                // 4 bytes
 *     @FourCC string platform;                // "x86" -> "68x\0"
 *     @CString string name;                   // null-terminated
 *     @LengthPrefix!ubyte string account;     // ubyte length, then the bytes
 *     @LengthPrefix!ubyte Entry[] entries;    // ubyte count, then each Entry
 *     ubyte[20] hash;                         // fixed-size raw bytes
 *     @Remainder ubyte[] trailer;             // everything up to the end of the packet
 * }
 * ---
 *
 * `serialize` and `deserialize` iterate over the struct's fields at compile
 * time with `static foreach`, so each packet type gets its own unrolled
 * (de)serializer and there is no run-time reflection. `wireSize` uses CTFE
 * to compute a fixed-size packet's length. That lets protocol definitions
 * `static assert` their layout against the reference implementations.
 */
module dmangos.serialization;

import std.exception : enforce;
import std.string : representation;
import std.traits : getUDAs, hasUDA, isDynamicArray, isScalarType, isSomeString, isStaticArray,
    isUnsigned, OriginalType, Unqual, EnumMembers;

import dmangos.bytes;

/// The field is a null-terminated string.
struct CString
{
}

/// The field is a four-character code stored reversed in four bytes; see `ByteWriter.putFourCC`.
struct FourCC
{
}

/// The field (a string or dynamic array) is preceded by its length, encoded as `T`.
struct LengthPrefix(T) if (isUnsigned!T)
{
    alias Type = T;
}

/// The field (a dynamic array, normally the last one) takes up the rest of the packet; no length is sent.
struct Remainder
{
}

/// The field (a `ulong`) is a guid in packed form; see `ByteWriter.putPackedGuid`.
struct PackedGuid
{
}

/// On a packet struct: the body is preceded by its size as a `ushort`. Applied by the packet encoder.
struct SizePrefixed
{
}

/// Appends `value` to `writer`.
void serialize(T)(ref ByteWriter writer, auto ref const T value) if (is(T == struct))
{
    static foreach (i; 0 .. T.tupleof.length)
    {{
        alias Field = typeof(T.tupleof[i]);
        enum fieldName = __traits(identifier, T.tupleof[i]);

        static if (hasUDA!(T.tupleof[i], CString))
        {
            static assert(isSomeString!Field, "@CString requires a string field: " ~ fieldName);
            writer.putCString(value.tupleof[i]);
        }
        else static if (hasUDA!(T.tupleof[i], FourCC))
        {
            static assert(isSomeString!Field, "@FourCC requires a string field: " ~ fieldName);
            writer.putFourCC(value.tupleof[i]);
        }
        else static if (hasUDA!(T.tupleof[i], PackedGuid))
        {
            static assert(is(Unqual!Field == ulong), "@PackedGuid requires a ulong field: " ~ fieldName);
            writer.putPackedGuid(value.tupleof[i]);
        }
        else static if (hasUDA!(T.tupleof[i], LengthPrefix))
        {
            alias Attribute = getUDAs!(T.tupleof[i], LengthPrefix)[0];
            alias Prefix = Attribute.Type;
            static assert(isDynamicArray!Field, "@LengthPrefix requires a string or dynamic array: " ~ fieldName);

            const field = value.tupleof[i];
            enforce!PacketException(field.length <= Prefix.max, "too many elements in " ~ fieldName);
            writer.put(cast(Prefix) field.length);
            static if (isSomeString!Field)
                writer.putBytes(field.representation);
            else
                foreach (ref element; field)
                    writeValue(writer, element);
        }
        else static if (hasUDA!(T.tupleof[i], Remainder))
        {
            static assert(isDynamicArray!Field, "@Remainder requires a dynamic array: " ~ fieldName);
            static if (is(Unqual!(typeof(Field.init[0])) == ubyte))
                writer.putBytes(value.tupleof[i]);
            else
                foreach (ref element; value.tupleof[i])
                    writeValue(writer, element);
        }
        else
            writeValue(writer, value.tupleof[i]);
    }}
}

/// Whether `T` reads itself, with `static T read(ref ByteReader)`: packets whose layout depends on their contents.
enum readsItself(T) = __traits(compiles, { ByteReader r; T t = T.read(r); });

/**
 * Reads a `T` from `reader`. Throws `IncompletePacketException` if the bytes are not all there yet.
 * A type with its own `read` (see `readsItself`) is read with it.
 */
T deserialize(T)(ref ByteReader reader) if (is(T == struct))
{
    static if (readsItself!T)
        return T.read(reader);
    else
        return deserializeFields!T(reader);
}

private T deserializeFields(T)(ref ByteReader reader)
{
    T result;
    static foreach (i; 0 .. T.tupleof.length)
    {{
        alias Field = typeof(T.tupleof[i]);

        static if (hasUDA!(T.tupleof[i], CString))
            result.tupleof[i] = reader.readCString();
        else static if (hasUDA!(T.tupleof[i], FourCC))
            result.tupleof[i] = reader.readFourCC();
        else static if (hasUDA!(T.tupleof[i], PackedGuid))
            result.tupleof[i] = reader.readPackedGuid();
        else static if (hasUDA!(T.tupleof[i], LengthPrefix))
        {
            alias Attribute = getUDAs!(T.tupleof[i], LengthPrefix)[0];
            alias Prefix = Attribute.Type;
            immutable count = reader.read!Prefix;
            static if (isSomeString!Field)
                result.tupleof[i] = reader.readString(count);
            else
            {
                alias Element = typeof(Field.init[0]);
                result.tupleof[i] = new Element[count];
                foreach (ref element; result.tupleof[i])
                    element = readValue!Element(reader);
            }
        }
        else static if (hasUDA!(T.tupleof[i], Remainder))
        {
            alias Element = typeof(Field.init[0]);
            static if (is(Unqual!Element == ubyte))
                result.tupleof[i] = reader.readBytes(reader.remaining).dup;
            else
                while (!reader.empty)
                    result.tupleof[i] ~= readValue!Element(reader);
        }
        else
            result.tupleof[i] = readValue!Field(reader);
    }}
    return result;
}

/// Size of `T` on the wire, or 0 if it has variable-length fields. A compile-time constant.
enum wireSize(T) = computeWireSize!T();

private size_t computeWireSize(T)()
{
    static if (is(T == enum))
        return OriginalType!T.sizeof;
    else static if (isScalarType!T)
        return T.sizeof;
    else static if (isStaticArray!T)
    {
        const element = computeWireSize!(typeof(T.init[0]))();
        return element * T.length;
    }
    else static if (is(T == struct))
    {
        size_t total;
        bool variable;
        static foreach (i; 0 .. T.tupleof.length)
        {{
            static if (hasUDA!(T.tupleof[i], CString) || hasUDA!(T.tupleof[i], LengthPrefix)
                || hasUDA!(T.tupleof[i], Remainder) || hasUDA!(T.tupleof[i], PackedGuid))
                variable = true;
            else static if (hasUDA!(T.tupleof[i], FourCC))
                total += 4;
            else
            {
                const size = computeWireSize!(typeof(T.tupleof[i]))();
                if (size == 0)
                    variable = true;
                total += size;
            }
        }}
        return variable ? 0 : total;
    }
    else
        return 0; // dynamic arrays, strings without attributes, ...
}

private void writeValue(T)(ref ByteWriter writer, auto ref const T value)
{
    static if (is(T == enum))
        writer.put(cast(OriginalType!T) value);
    else static if (isScalarType!T)
        writer.put(value);
    else static if (isStaticArray!T)
    {
        static if (is(Unqual!(typeof(T.init[0])) == ubyte))
            writer.putBytes(value[]);
        else
            foreach (ref element; value)
                writeValue(writer, element);
    }
    else static if (is(T == struct))
        serialize(writer, value);
    else
        static assert(false, "cannot serialize " ~ T.stringof ~ " without an attribute such as @LengthPrefix");
}

private T readValue(T)(ref ByteReader reader)
{
    static if (is(T == enum))
    {
        // An unrolled comparison against every declared member rejects values the enum does not define.
        const raw = reader.read!(OriginalType!T);
        static foreach (member; EnumMembers!T)
            if (raw == member)
                return member;
        throw new PacketException("invalid " ~ T.stringof ~ " value");
    }
    else static if (isScalarType!T)
        return reader.read!T;
    else static if (isStaticArray!T)
    {
        T array;
        static if (is(Unqual!(typeof(T.init[0])) == ubyte))
            array[] = reader.readBytes(T.length)[];
        else
            foreach (ref element; array)
                element = readValue!(typeof(T.init[0]))(reader);
        return array;
    }
    else static if (is(T == struct))
        return deserialize!T(reader);
    else
        static assert(false, "cannot deserialize " ~ T.stringof ~ " without an attribute such as @LengthPrefix");
}

version (unittest)
{
    private enum Colour : ushort
    {
        red = 1,
        green = 2,
    }

    private struct Inner
    {
        ubyte a;
        Colour colour;
    }

    private struct Sample
    {
        uint number;
        @FourCC string platform;
        @CString string name;
        ubyte[3] raw;
        @LengthPrefix!ubyte Inner[] items;
        @LengthPrefix!ubyte string tag;
        float ratio;
    }

    private struct WithTrailer
    {
        ushort id;
        @Remainder ubyte[] rest;
    }

    private struct Fixed
    {
        ubyte a;
        uint b;
        ubyte[20] c;
        Inner d;
    }
}

@safe unittest
{
    Sample sample;
    sample.number = 0x01020304;
    sample.platform = "x86";
    sample.name = "Azeroth";
    sample.raw = [7, 8, 9];
    sample.items = [Inner(1, Colour.red), Inner(2, Colour.green)];
    sample.tag = "PLAYER";
    sample.ratio = 0.25f;

    ByteWriter writer;
    serialize(writer, sample);
    const ubyte[4] numberBytes = [4, 3, 2, 1];
    assert(writer.data[0 .. 4] == numberBytes[]);

    auto reader = ByteReader(writer.data);
    const decoded = deserialize!Sample(reader);
    assert(decoded == sample);
    assert(reader.empty);
}

@safe unittest
{
    const sample = WithTrailer(7, [1, 2, 3]);
    ByteWriter writer;
    serialize(writer, sample);
    const ubyte[5] expected = [7, 0, 1, 2, 3];
    assert(writer.data == expected[]);
    auto reader = ByteReader(writer.data);
    assert(deserialize!WithTrailer(reader) == sample && reader.empty);
    static assert(wireSize!WithTrailer == 0);
}

@safe unittest
{
    // The wire size has no alignment padding, unlike `.sizeof`.
    static assert(wireSize!Fixed == 1 + 4 + 20 + 3);
    static assert(wireSize!Fixed < Fixed.sizeof);
    static assert(wireSize!Sample == 0);
}

@safe unittest
{
    import std.exception : assertThrown;

    // Values that are not members of the enum are rejected.
    const(ubyte)[] wire = [1, 9, 0];
    auto reader = ByteReader(wire);
    assertThrown!PacketException(deserialize!Inner(reader));
}

unittest
{
    // A type that reads itself is read with its own function.
    static struct Custom
    {
        uint value;
        static Custom read(ref ByteReader r) { return Custom(r.read!ubyte * 2); }
    }
    static assert(readsItself!Custom && !readsItself!(ServerTestPacket));
    const ubyte[1] bytes = [21];
    auto r = ByteReader(bytes);
    assert(deserialize!Custom(r).value == 42);
}

version (unittest) private struct ServerTestPacket
{
    uint id;
}
