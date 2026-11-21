/**
 * Little-endian byte streams for reading and writing network packets.
 *
 * `ByteWriter` appends to a dynamic array. `ByteReader` reads from a slice
 * and copies nothing. If a packet has not fully arrived, the reader throws
 * `IncompletePacketException`, and the caller waits for more data before
 * trying again.
 */
module dmangos.bytes;

import std.algorithm.searching : canFind;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.exception : basicExceptionCtors;
import std.string : assumeUTF, representation;
import std.traits : isFloatingPoint, isIntegral, isSomeChar;

/// Thrown when a packet is malformed. The connection should be dropped.
class PacketException : Exception
{
    mixin basicExceptionCtors;
}

/// Thrown when more bytes are needed to decode a packet. The caller should retry later.
class IncompletePacketException : PacketException
{
    mixin basicExceptionCtors;
}

/// Types that are written as a fixed number of little-endian bytes.
enum isWireScalar(T) = !is(T == enum)
    && (isIntegral!T || isFloatingPoint!T || isSomeChar!T || is(T == bool));

/// The raw bits of a float.
uint floatBits(float f) pure nothrow @nogc @safe
{
    union Bits { float f; uint u; }
    return Bits(f).u;
}

/// The float with these raw bits.
float bitsFloat(uint i) pure nothrow @nogc @safe
{
    union Bits { uint u; float f; }
    return Bits(i).f;
}

/// Builds a packet by appending little-endian values.
struct ByteWriter
{
    private ubyte[] buffer;

    /// Bytes written so far.
    @property const(ubyte)[] data() const pure nothrow @nogc @safe
    {
        return buffer;
    }

    /// Number of bytes written so far.
    @property size_t length() const pure nothrow @nogc @safe
    {
        return buffer.length;
    }

    /// Appends a scalar in little-endian order.
    void put(T)(const T value) if (isWireScalar!T)
    {
        static if (is(T == bool))
            buffer ~= cast(ubyte)(value ? 1 : 0);
        else
        {
            const bytes = nativeToLittleEndian(value);
            buffer ~= bytes[];
        }
    }

    /**
     * Forgets what was written but keeps the memory, so a writer that is used again and again
     * (a cluster link's output) stops allocating once it has grown to its working size. Slices of
     * `data` taken before must no longer be used.
     */
    void clear() pure nothrow @trusted
    {
        buffer.length = 0;
        buffer.assumeSafeAppend();
    }

    /// Forgets what was written from `length` on (keeping the memory).
    void truncate(size_t length) pure nothrow @trusted
    in (length <= buffer.length)
    {
        buffer.length = length;
        buffer.assumeSafeAppend();
    }

    /// Overwrites a scalar written earlier at `offset` (a length known only at the end).
    void patch(T)(size_t offset, const T value) if (isWireScalar!T)
    in (offset + T.sizeof <= buffer.length)
    {
        const bytes = nativeToLittleEndian(value);
        buffer[offset .. offset + T.sizeof] = bytes[];
    }

    /// Appends raw bytes.
    void putBytes(scope const(ubyte)[] bytes) pure nothrow @safe
    {
        buffer ~= bytes;
    }

    /// Appends a null-terminated string.
    void putCString(scope const(char)[] text) pure nothrow @safe
    in (!text.representation.canFind(ubyte(0)), "C strings cannot contain null characters")
    {
        buffer ~= text.representation;
        buffer ~= ubyte(0);
    }

    /**
     * Appends a four-character code such as "x86" or "enUS".
     *
     * The client sends these as a multi-character constant in a little-endian
     * `uint32`, so "x86" goes over the wire as `"68x\0"`.
     */
    void putFourCC(scope const(char)[] code) pure nothrow @safe
    in (code.length <= 4, "four-character codes have at most four characters")
    {
        ubyte[4] bytes;
        foreach (i, c; code)
            bytes[code.length - 1 - i] = cast(ubyte) c;
        buffer ~= bytes[];
    }

    /// Appends a guid in packed form: a byte with a bit per non-zero byte, then those bytes.
    void putPackedGuid(ulong guid) pure nothrow @safe
    {
        ubyte mask;
        ubyte[8] bytes;
        size_t count;
        foreach (i; 0 .. 8)
            if (const b = cast(ubyte)(guid >> (8 * i)))
            {
                mask |= 1 << i;
                bytes[count++] = b;
            }
        buffer ~= mask;
        buffer ~= bytes[0 .. count];
    }

    /// Returns the written bytes and resets the writer.
    ubyte[] release() pure nothrow @safe
    {
        auto result = buffer;
        buffer = null;
        return result;
    }
}

/// Reads little-endian values from a slice of bytes.
struct ByteReader
{
    private const(ubyte)[] data;
    private size_t offset;

    // Checked around every public method; the attributes let pure/@nogc methods call it.
    pure nothrow @nogc @safe invariant ()
    {
        assert(offset <= data.length, "read position past the end of the buffer");
    }

    this(const(ubyte)[] data) pure nothrow @nogc @safe
    {
        this.data = data;
    }

    /// Number of bytes consumed so far.
    @property size_t position() const pure nothrow @nogc @safe
    {
        return offset;
    }

    /// Number of bytes not yet read.
    @property size_t remaining() const pure nothrow @nogc @safe
    {
        return data.length - offset;
    }

    /// Whether every byte has been read.
    @property bool empty() const pure nothrow @nogc @safe
    {
        return remaining == 0;
    }

    /// Throws `IncompletePacketException` unless `count` more bytes are available.
    void ensureAvailable(size_t count) const pure @safe
    {
        if (remaining < count)
            throw new IncompletePacketException("packet truncated");
    }

    /// Reads a scalar stored in little-endian order.
    T read(T)() if (isWireScalar!T)
    {
        static if (is(T == bool))
            return read!ubyte != 0;
        else
        {
            ensureAvailable(T.sizeof);
            ubyte[T.sizeof] bytes = data[offset .. offset + T.sizeof];
            offset += T.sizeof;
            return littleEndianToNative!T(bytes);
        }
    }

    /// Returns the next `count` bytes as a slice of the underlying buffer, without copying.
    const(ubyte)[] readBytes(size_t count) pure @safe
    {
        ensureAvailable(count);
        auto slice = data[offset .. offset + count];
        offset += count;
        return slice;
    }

    /// Skips `count` bytes.
    void skip(size_t count) pure @safe
    {
        readBytes(count);
    }

    /// Reads a string of exactly `length` bytes.
    string readString(size_t length) pure @safe
    {
        return readBytes(length).idup.assumeUTF;
    }

    /// Reads a null-terminated string that is at most `maxLength` characters long.
    string readCString(size_t maxLength = 255) pure @safe
    {
        foreach (i, b; data[offset .. $])
        {
            if (b == 0)
            {
                auto text = readString(i);
                offset += 1; // the terminator
                return text;
            }
            if (i >= maxLength)
                throw new PacketException("C string exceeds its maximum length");
        }
        throw new IncompletePacketException("unterminated C string");
    }

    /// Reads a guid in packed form; see `ByteWriter.putPackedGuid`.
    ulong readPackedGuid() pure @safe
    {
        const mask = read!ubyte;
        ulong guid;
        foreach (i; 0 .. 8)
            if (mask & (1 << i))
                guid |= ulong(read!ubyte) << (8 * i);
        return guid;
    }

    /// Reads a four-character code. See `ByteWriter.putFourCC` for the wire format.
    string readFourCC() pure @safe
    {
        const raw = readBytes(4);
        size_t length = 4;
        while (length > 0 && raw[length - 1] == 0)
            --length;
        auto text = new char[length];
        foreach (i; 0 .. length)
            text[i] = cast(char) raw[length - 1 - i];
        return text.idup;
    }
}

@safe unittest
{
    import std.exception : assertThrown;

    ByteWriter writer;
    writer.put!ushort(0x1234);
    writer.put(true);
    writer.putFourCC("x86");
    writer.putCString("Realm");
    writer.put(1.5f);

    const(ubyte)[] expected = [0x34, 0x12, 1, '6', '8', 'x', 0, 'R', 'e', 'a', 'l', 'm', 0,
                               0x00, 0x00, 0xC0, 0x3F];
    assert(writer.data == expected);

    auto reader = ByteReader(writer.data);
    assert(reader.read!ushort == 0x1234);
    assert(reader.read!bool);
    assert(reader.readFourCC() == "x86");
    assert(reader.readCString() == "Realm");
    assert(reader.read!float == 1.5f);
    assert(reader.empty);
    assertThrown!IncompletePacketException(reader.read!uint);
}

@safe unittest
{
    import std.exception : assertThrown;

    // "WoW" and "enUS" as the 1.12 client actually sends them.
    const(ubyte)[] wire = ['W', 'o', 'W', 0, 'S', 'U', 'n', 'e'];
    auto reader = ByteReader(wire);
    assert(reader.readFourCC() == "WoW");
    assert(reader.readFourCC() == "enUS");

    // A missing terminator means "wait"; an overlong string means "malformed".
    const(ubyte)[] partial = ['a', 'b'];
    assertThrown!IncompletePacketException(ByteReader(partial).readCString());
    const(ubyte)[] overlong = ['a', 'b', 'c', 'd', 0];
    auto strict = ByteReader(overlong);
    try
    {
        strict.readCString(2);
        assert(false, "expected a PacketException");
    }
    catch (IncompletePacketException)
        assert(false, "an overlong string must not look incomplete");
    catch (PacketException)
    {
    }
}

unittest
{
    ByteWriter w;
    w.put(uint(0));
    w.put(ubyte(7));
    w.patch(0, uint(0xDEADBEEF));
    assert(w.data == [0xEF, 0xBE, 0xAD, 0xDE, 7]);
    const before = w.data.ptr;
    w.clear();
    assert(w.length == 0);
    w.put(ulong(1));
    assert(w.data.ptr is before, "the memory is reused");
}
