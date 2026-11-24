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

/// Saved state added at the end of an existing script layout; older records use its default.
enum appended;

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
        const stored = r.read!ulong;
        const older = !compatibleLayout(stored, layoutFingerprint!S);
        enum prior = fnv1a(layoutOf!(S, true));
        if (older && !compatibleLayout(stored, prior))
            return false;
        S read;
        readValue(r, read, older);
        state = read;
        return true;
    }
    catch (Exception)
        return false;
}

private:

bool compatibleLayout(ulong stored, ulong current)
{
    const legacy = legacyDungeonLayout(current);
    return stored == current || (legacy != 0 && stored == legacy);
}

// Dungeon layouts with enums saved by 219ecf7 and the matching enum-aware fingerprints.
// A later change to those enum values also changes the lookup key.
ulong legacyDungeonLayout(ulong current) pure nothrow @nogc @safe
{
    switch (current)
    {
    case 0x485605316b929e94UL: return 0x3def319d8434f6eaUL; // Deadmines
    case 0x21314848b8220200UL: return 0x13647cd038c9c4ccUL; // ShadowfangKeep
    case 0x79ed00fbda77adeeUL: return 0x5254ad1cbcd364e6UL; // Gnomeregan
    case 0xf42962d98d45e308UL: return 0xf58ef804aa79ca29UL; // ScarletMonastery
    case 0x5bb70847c70ef71aUL: return 0x3388fd22daa3a5a8UL; // Uldaman
    case 0x9d03d77813dec195UL: return 0x783120410c6378bfUL; // ZulFarrak
    case 0x54d14e49f617b487UL: return 0x07d8a290ee9f3768UL; // Maraudon
    case 0xea95117c233f15f7UL: return 0x2cd948dcaa3295fdUL; // BlackfathomDeeps
    case 0x16663c1a96892d9bUL: return 0xd55de4fa96ca9c08UL; // SunkenTemple
    case 0xf9ea7af64bb35083UL: return 0x09873c5cccd6d62bUL; // BlackrockDepths
    case 0xbdaf7d3a6da5faf3UL: return 0x6722bd559cf208d5UL; // BlackrockSpire
    case 0x2ff3a5ff97f3461eUL: return 0xfdf53dada7b5b9a0UL; // Stratholme
    case 0x047e72f7bede7dc4UL: return 0xfb153714702be643UL; // Scholomance
    case 0x50a9302ef83caeeaUL: return 0xb5d2ff570b594c8fUL; // DireMaul
    case 0xb67098a4d5e07cbaUL: return 0xb6c36d52991d570eUL; // MoltenCore
    case 0x07790e4e603f7da1UL: return 0xe1b4dffdcd20a6f1UL; // OnyxiasLair
    case 0x83881956a512360fUL: return 0x32570741e17de7e3UL; // ZulGurub
    case 0xa61171b3679a2d60UL: return 0x5c21858c252ae812UL; // BlackwingLair
    case 0xe7bcf2f0f0cfae55UL: return 0xa676c85b7c5997c7UL; // RuinsOfAhnQiraj
    case 0x2b625e18f5cc90f1UL: return 0x1930997e372b81b0UL; // TempleOfAhnQiraj
    case 0xf681f342534aff66UL: return 0x2edbb9bc0f083bfeUL; // Naxxramas
    default: return 0;
    }
}

string layoutOf(T, bool omitAppended = false)()
{
    static if (is(T == struct))
    {
        string s = T.stringof ~ "{";
        static foreach (i, field; T.tupleof)
            static if (!hasUDA!(T.tupleof[i], transient) && !(omitAppended && hasUDA!(T.tupleof[i], appended)))
                s ~= __traits(identifier, T.tupleof[i]) ~ ":" ~ layoutOf!(typeof(field), omitAppended) ~ ";";
        return s ~ "}";
    }
    else static if (is(T E == enum))
    {
        import std.conv : to;

        string s = T.stringof ~ "(" ~ E.stringof;
        static foreach (name; __traits(allMembers, T))
            s ~= ";" ~ name ~ "=" ~ (cast(E) __traits(getMember, T, name)).to!string;
        return s ~ ")";
    }
    else static if (isStaticArray!T)
        return layoutOf!(typeof(T.init[0]), omitAppended) ~ "[" ~ T.length.stringof ~ "]";
    else static if (isArray!T)
        return layoutOf!(typeof(T.init[0]), omitAppended) ~ "[]";
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

void readValue(T)(ref ByteReader r, ref T value, bool omitAppended = false)
{
    static if (is(T E == enum))
        value = cast(T) r.read!E;
    else static if (isWireScalar!T)
        value = r.read!T;
    else static if (is(T == struct))
    {
        static foreach (i, field; T.tupleof)
            static if (!hasUDA!(T.tupleof[i], transient))
            {
                static if (hasUDA!(T.tupleof[i], appended))
                {
                    if (!omitAppended)
                        readValue(r, value.tupleof[i]);
                }
                else
                    readValue(r, value.tupleof[i], omitAppended);
            }
    }
    else static if (isStaticArray!T)
    {
        foreach (ref element; value)
            readValue(r, element, omitAppended);
    }
    else static if (isSomeString!T)
        value = cast(T) r.readString(r.read!uint);
    else static if (isArray!T)
    {
        value.length = r.read!uint;
        foreach (ref element; value)
            readValue(r, element, omitAppended);
    }
}

unittest
{
    static struct Encounter
    {
        uint cleared;
        @appended uint phase = 2;
    }

    ByteWriter old;
    old.put(fnv1a(layoutOf!(Encounter, true)));
    old.put(19u);
    auto reader = ByteReader(old.data);
    Encounter state;
    assert(loadScript(state, reader) && state.cleared == 19 && state.phase == 2);

    state.phase = 3;
    ByteWriter current;
    saveScript(state, current);
    reader = ByteReader(current.data);
    Encounter restored;
    assert(loadScript(restored, reader) && restored.cleared == 19 && restored.phase == 3);
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

unittest
{
    static struct Previous
    {
        enum Step : ubyte { intro, outro }
        struct State { Step step; }
    }
    static struct Reordered
    {
        enum Step : ubyte { outro, intro }
        struct State { Step step; }
    }
    ByteWriter w;
    const previous = Previous.State(Previous.Step.intro);
    saveScript(previous, w);
    auto reader = ByteReader(w.data);
    Reordered.State state;
    assert(!loadScript(state, reader));

    import dmangos.scripts.deadmines : Deadmines;

    ByteWriter current, legacy;
    Deadmines dungeon;
    saveScript(dungeon, current);
    legacy.put(0x3def319d8434f6eaUL);
    legacy.putBytes(current.data[ulong.sizeof .. $]);
    reader = ByteReader(legacy.data);
    assert(loadScript(dungeon, reader));
}
