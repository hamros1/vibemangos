/**
 * A script's state written out and read back, by compile-time reflection over its struct: every
 * field but those marked `@transient`, recursively (numbers, enums, booleans, characters, static
 * arrays, structs, strings and arrays of these). The bytes start with a fingerprint of the layout
 * (field names and types, computed at compile time): state written by another layout is refused,
 * and the script starts fresh rather than reading it wrongly.
 *
 * The same bytes carry a creature's script to the node it moves to and a dungeon script into
 * `instance.data`.
 */
module dmangos.script.state;

import std.traits : hasUDA, isArray, isSomeString, isStaticArray;

import dmangos.bytes : ByteReader, ByteWriter, isWireScalar;

/// A field that is not saved (a cache, a value rebuilt on load).
enum transient;

/// The fingerprint of `S`'s saved layout.
enum ulong layoutFingerprint(S) = fnv1a(layoutOf!S);

/// Writes `state`.
void saveScript(S)(const ref S state, ref ByteWriter w)
{
    w.put(layoutFingerprint!S);
    writeValue(w, state);
}

/// Reads what `saveScript` wrote into `state`; false (and `state` untouched) if the layout differs or the bytes are short.
bool loadScript(S)(ref S state, ref ByteReader r)
{
    try
    {
        if (r.read!ulong != layoutFingerprint!S)
            return false;
        S read;
        readValue(r, read);
        state = read;
        return true;
    }
    catch (Exception)
        return false;
}

private:

string layoutOf(T)()
{
    static if (is(T == struct))
    {
        string s = T.stringof ~ "{";
        static foreach (i, field; T.tupleof)
            static if (!hasUDA!(T.tupleof[i], transient))
                s ~= __traits(identifier, T.tupleof[i]) ~ ":" ~ layoutOf!(typeof(field)) ~ ";";
        return s ~ "}";
    }
    else static if (is(T E == enum))
        return T.stringof ~ "(" ~ E.stringof ~ ")";
    else static if (isStaticArray!T)
        return layoutOf!(typeof(T.init[0])) ~ "[" ~ T.length.stringof ~ "]";
    else static if (isArray!T)
        return layoutOf!(typeof(T.init[0])) ~ "[]";
    else
        return T.stringof;
}

ulong fnv1a(string text) pure nothrow @nogc @safe
{
    ulong hash = 0xcbf29ce484222325;
    foreach (c; text)
    {
        hash ^= c;
        hash *= 0x100000001b3;
    }
    return hash;
}

void writeValue(T)(ref ByteWriter w, const ref T value)
{
    static if (is(T E == enum))
        w.put(cast(const E) value);
    else static if (isWireScalar!T)
        w.put(value);
    else static if (is(T == struct))
    {
        static foreach (i, field; T.tupleof)
            static if (!hasUDA!(T.tupleof[i], transient))
                writeValue(w, value.tupleof[i]);
    }
    else static if (isStaticArray!T)
    {
        foreach (ref element; value)
            writeValue(w, element);
    }
    else static if (isSomeString!T)
    {
        w.put(cast(uint) value.length);
        w.putBytes(cast(const(ubyte)[]) value);
    }
    else static if (isArray!T)
    {
        w.put(cast(uint) value.length);
        foreach (ref element; value)
            writeValue(w, element);
    }
    else
        static assert(false, "a script's state cannot hold a " ~ T.stringof
            ~ " (hold guids as EntityRef; mark caches @transient)");
}

void readValue(T)(ref ByteReader r, ref T value)
{
    static if (is(T E == enum))
        value = cast(T) r.read!E;
    else static if (isWireScalar!T)
        value = r.read!T;
    else static if (is(T == struct))
    {
        static foreach (i, field; T.tupleof)
            static if (!hasUDA!(T.tupleof[i], transient))
                readValue(r, value.tupleof[i]);
    }
    else static if (isStaticArray!T)
    {
        foreach (ref element; value)
            readValue(r, element);
    }
    else static if (isSomeString!T)
        value = cast(T) r.readString(r.read!uint);
    else static if (isArray!T)
    {
        value.length = r.read!uint;
        foreach (ref element; value)
            readValue(r, element);
    }
}

unittest
{
    import core.time : seconds;
    import dmangos.script.schedule : Schedule;

    enum Phase : ubyte { one, two }
    enum Step { a, b }
    static struct Inner { int x; ulong[2] pair; }
    static struct State
    {
        Phase phase;
        Schedule!Step steps;
        Inner inner;
        string note;
        uint[] list;
        @transient int cache = 7;
    }

    State s;
    s.phase = Phase.two;
    s.steps.every(Step.b, 5.seconds);
    s.inner = Inner(-3, [1, 2]);
    s.note = "hi";
    s.list = [4, 5];
    s.cache = 99;
    ByteWriter w;
    saveScript(s, w);

    State back;
    auto r = ByteReader(w.data);
    assert(loadScript(back, r));
    assert(back.phase == Phase.two && back.steps.remaining(Step.b) == 5000 && back.inner == s.inner);
    assert(back.note == "hi" && back.list == [4, 5] && back.cache == 7, "transient: not saved");

    // Another layout: refused, untouched.
    static struct Other { int phase; }
    Other o;
    o.phase = 1;
    auto r2 = ByteReader(w.data);
    assert(!loadScript(o, r2) && o.phase == 1);
    auto r3 = ByteReader(w.data[0 .. 10]);
    assert(!loadScript(back, r3), "short");
    static assert(layoutFingerprint!State != layoutFingerprint!Other);
}
