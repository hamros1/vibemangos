/**
 * Plain data: values made of numbers, characters, enums, strings, arrays and structs of them, with
 * no pointers, classes, delegates or associative arrays. Such a value can be copied out of the
 * collector's heap (`dmangos.frozen`), queued as bytes (`dmangos.world.writebehind`) and sent to
 * another node (`dmangos.cluster.services`).
 *
 * `encode` writes a value as bytes (numbers in the machine's order, arrays after a 32-bit length),
 * `decode` reads it back, and `layout` describes a type in words, so that two builds can tell whether
 * they agree on a value's bytes.
 */
module dmangos.plaindata;

import std.traits : isDynamicArray, isFloatingPoint, isIntegral, isSomeChar, isStaticArray, OriginalType, Unqual;

/// Whether `T` is plain data: numbers, characters, enums, strings, arrays and structs of them (no
/// pointers, classes, delegates or associative arrays).
template isPlainData(T)
{
    alias U = Unqual!T;
    static if (is(U == enum))
        enum isPlainData = isPlainData!(OriginalType!U);
    else static if (isIntegral!U || isFloatingPoint!U || isSomeChar!U || is(U == bool))
        enum isPlainData = true;
    else static if (isStaticArray!U || isDynamicArray!U)
        enum isPlainData = isPlainData!(typeof(U.init[0]));
    else static if (is(U == struct))
    {
        enum isPlainData = () {
            bool all = true;
            static foreach (F; typeof(U.tupleof))
                all = all && isPlainData!F;
            return all;
        }() && !__traits(isNested, U);
    }
    else
        enum isPlainData = false;
}

/// The layout of `T` in words: two builds of the server agree on a write's bytes if they agree on this.
template layout(T)
{
    alias U = Unqual!T;
    static if (is(U == enum))
        enum layout = layout!(OriginalType!U);
    else static if (isStaticArray!U)
        enum layout = layout!(typeof(U.init[0])) ~ "[" ~ () { import std.conv : to; return U.length.to!string; }() ~ "]";
    else static if (isDynamicArray!U)
        enum layout = layout!(typeof(U.init[0])) ~ "[]";
    else static if (is(U == struct))
    {
        enum layout = () {
            string s = "{";
            static foreach (i, F; typeof(U.tupleof))
                s ~= __traits(identifier, U.tupleof[i]) ~ ":" ~ layout!F ~ ";";
            return s ~ "}";
        }();
    }
    else
        enum layout = U.stringof;
}

/// Appends `value` to `bytes`: numbers in the machine's order, arrays after their length.
void encode(T)(ref ubyte[] bytes, const ref T value) @trusted
{
    alias U = Unqual!T;
    static if (is(U == enum))
        encode(bytes, *cast(const(OriginalType!U)*) &value);
    else static if (isIntegral!U || isFloatingPoint!U || isSomeChar!U || is(U == bool))
        bytes ~= (cast(const(ubyte)*) &value)[0 .. U.sizeof];
    else static if (isStaticArray!U)
    {
        foreach (ref element; value)
            encode(bytes, element);
    }
    else static if (isDynamicArray!U)
    {
        const uint count = cast(uint) value.length;
        encode(bytes, count);
        foreach (ref element; value)
            encode(bytes, element);
    }
    else static if (is(U == struct))
    {
        static foreach (i; 0 .. U.tupleof.length)
            encode(bytes, value.tupleof[i]);
    }
    else
        static assert(false, "cannot queue a " ~ T.stringof);
}

// Minimum encoded size, excluding native struct padding.
private template minimumEncodedSize(T)
{
    alias U = Unqual!T;
    static if (is(U == enum))
        enum minimumEncodedSize = minimumEncodedSize!(OriginalType!U);
    else static if (isStaticArray!U)
        enum minimumEncodedSize = U.length * minimumEncodedSize!(typeof(U.init[0]));
    else static if (isDynamicArray!U)
        enum minimumEncodedSize = uint.sizeof; // even an empty array has a length
    else static if (is(U == struct))
        enum minimumEncodedSize = () {
            size_t size;
            static foreach (F; typeof(U.tupleof))
                size += minimumEncodedSize!F;
            return size;
        }();
    else
        enum minimumEncodedSize = U.sizeof;
}

/// Reads back what `encode` wrote, from the front of `bytes`.
void decode(T)(ref const(ubyte)[] bytes, ref T value) @safe
if (isPlainData!T && __traits(compiles, value = T.init))
{
    T decoded;
    decodeFresh(bytes, decoded);
    value = decoded;
}

// The caller owns fresh storage. Qualified fields are initialized before publication.
private void decodeFresh(T)(ref const(ubyte)[] bytes, ref T value) @trusted
{
    import std.exception : enforce;

    alias U = Unqual!T;
    auto target = cast(U*) &value;
    static if (is(U == enum))
        decodeFresh(bytes, *cast(OriginalType!U*) target);
    else static if (isIntegral!U || isFloatingPoint!U || isSomeChar!U || is(U == bool))
    {
        enforce(bytes.length >= U.sizeof, "a queued write ends early");
        (cast(ubyte*) target)[0 .. U.sizeof] = bytes[0 .. U.sizeof];
        bytes = bytes[U.sizeof .. $];
    }
    else static if (isStaticArray!U)
    {
        foreach (ref element; *target)
            decodeFresh(bytes, element);
    }
    else static if (isDynamicArray!U)
    {
        uint count;
        decodeFresh(bytes, count);
        alias E = Unqual!(typeof(U.init[0]));
        // Keep the existing one-byte-per-element bound for zero-width encodings.
        enum width = minimumEncodedSize!E ? minimumEncodedSize!E : 1;
        enforce(count <= bytes.length / width, "a queued write ends early");
        auto elements = new E[count];
        foreach (ref element; elements)
            decodeFresh(bytes, element);
        *target = cast(U) elements;
    }
    else static if (is(U == struct))
    {
        static foreach (i; 0 .. U.tupleof.length)
            decodeFresh(bytes, target.tupleof[i]);
    }
}

unittest
{
    static struct Inner { ubyte[3] tag; string note; }
    static struct Outer { uint id; float x; bool on; Inner[] inner; char[] raw; }
    static assert(isPlainData!Outer && !isPlainData!(void delegate()) && !isPlainData!Object);

    ubyte[] bytes;
    const before = Outer(7, 1.5f, true, [Inner([1, 2, 3], "a"), Inner([4, 5, 6], "")], "xy".dup);
    encode(bytes, before);
    const(ubyte)[] rest = bytes;
    Outer after;
    decode(rest, after);
    assert(after == before && rest.length == 0);
}

unittest
{
    import std.exception : assertThrown;

    static assert(!__traits(compiles, {
        const(ubyte)[] bytes;
        immutable uint target = 0;
        decode(bytes, target);
    }));

    ubyte[] bytes;
    const uint[] source = [7u, 8u];
    encode(bytes, source);
    const(ubyte)[] rest = bytes[0 .. $ - 1];
    uint[] target = [42u];
    assertThrown(decode(rest, target));
    assert(target == [42u]);
}
