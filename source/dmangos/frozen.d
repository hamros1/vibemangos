/**
 * Static data off the scanned heap (docs/DESIGN.md, step 7).
 *
 * The tables loaded at start-up (items, spells, creature templates, quests, ...) are read for as long
 * as the server runs and change only by a GM's `.reload`. In the collector's heap they cost every
 * collection the time to mark them: about 18 ms of a collection that, without them, takes 2.
 *
 * This module keeps them where the collector does not look:
 * $(UL
 *   $(LI The $(I arena) is memory from `malloc`, never freed and never registered with the collector.
 *        What is in it must not point into the collector's heap, which would free what it points to
 *        unseen; so only plain data goes in (`isPlainData`: numbers, characters, strings, arrays and
 *        structs of them), copied deep (`frozenCopy`), strings and arrays included.)
 *   $(LI `StaticMap!(K, V)` is an associative array while the data loads. `freeze` copies it into the
 *        arena as an open-addressed table. Nothing in it moves after that, so a pointer to a value
 *        stays good, as in an associative array.)
 * )
 *
 * A value read from a frozen map whose type has pointers (a string, an array) is `const`: written to
 * in the arena, it could be given a pointer into the collector's heap that the collector does not see.
 * `edit` gives a mutable one, in place, and registers it with the collector, which scans it from then
 * on (a GM command or a test changes a few). Keys added after freezing go into an associative array.
 */
module dmangos.frozen;

import core.stdc.stdlib : malloc;
import std.traits : hasIndirections, isDynamicArray, isFloatingPoint, isIntegral, isSomeChar, isStaticArray,
    OriginalType, Unqual;

// ---------------------------------------------------------------------------------------------------
// Plain data
// ---------------------------------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------------------------------
// The arena
// ---------------------------------------------------------------------------------------------------

private enum size_t chunkSize = 4 << 20;

private __gshared
{
    ubyte* free;      // the rest of the current chunk
    size_t left;
    size_t placed;    // bytes handed out
    size_t reserved;  // bytes taken from malloc
}

private shared Object arenaLock = new Object;

/// `size` bytes in the arena, aligned to `alignment`; never freed.
void[] arenaAllocate(size_t size, size_t alignment) @trusted
{
    if (size == 0)
        return null;
    synchronized (arenaLock)
    {
        auto skip = (alignment - cast(size_t) free % alignment) % alignment;
        if (free is null || skip + size > left)
        {
            const want = size + alignment > chunkSize ? size + alignment : chunkSize;
            free = cast(ubyte*) malloc(want);
            if (free is null)
                assert(false, "out of memory for static data");
            left = want;
            reserved += want;
            skip = (alignment - cast(size_t) free % alignment) % alignment;
        }
        auto block = free + skip;
        free = block + size;
        left -= skip + size;
        placed += size;
        return block[0 .. size];
    }
}

/// How much is in the arena, and how much memory it took (for the metrics).
size_t arenaPlaced() @trusted
{
    synchronized (arenaLock)
        return placed;
}

/// ditto
size_t arenaReserved() @trusted
{
    synchronized (arenaLock)
        return reserved;
}

/// Room for `count` values of `T` in the arena, set to `T.init`.
T[] arenaArray(T)(size_t count) @trusted
{
    auto block = cast(T[]) arenaAllocate(count * T.sizeof, T.alignof);
    foreach (ref element; block)
    {
        static if (__traits(compiles, { T t = T.init; element = t; }))
        {
            import core.lifetime : emplace;

            emplace(&element);
        }
    }
    return block;
}

/**
 * A copy of `value` whose arrays and strings, at every depth, are in the arena: nothing of it is in the
 * collector's heap.
 */
Unqual!T frozenCopy(T)(const ref T value) @trusted
if (isPlainData!T)
{
    alias U = Unqual!T;
    static if (!hasIndirections!U)
        return cast(U) value;
    else static if (isDynamicArray!U)
    {
        alias E = Unqual!(typeof(U.init[0]));
        if (value.length == 0)
            return null;
        auto copy = cast(E[]) arenaAllocate(value.length * E.sizeof, E.alignof);
        static if (!hasIndirections!E)
            (cast(ubyte[]) copy)[] = (cast(const(ubyte)[]) value)[];
        else
            foreach (i, ref element; value)
            {
                auto e = frozenCopy(element);
                (cast(ubyte*) &copy[i])[0 .. E.sizeof] = (cast(ubyte*) &e)[0 .. E.sizeof];
            }
        return cast(U) copy;
    }
    else static if (isStaticArray!U)
    {
        U copy;
        foreach (i, ref element; value)
            copy[i] = frozenCopy(element);
        return copy;
    }
    else static if (is(U == struct))
    {
        U copy;
        static foreach (i; 0 .. U.tupleof.length)
            *cast(Unqual!(typeof(U.tupleof[i]))*) &copy.tupleof[i] = cast(Unqual!(typeof(U.tupleof[i])))
                frozenCopy(value.tupleof[i]);
        return copy;
    }
    else
        static assert(false);
}

/// Whether `p` points into the collector's heap (for tests).
bool inCollectedHeap(const(void)* p) @trusted
{
    import core.memory : GC;

    return GC.addrOf(cast(void*) p) !is null;
}

unittest
{
    static struct Row { uint id; string name; uint[] ids; ubyte[4] tag; }
    const original = Row(5, "Thunderfury".idup, [1u, 2, 3].dup, [1, 2, 3, 4]);
    const copy = frozenCopy(original);
    assert(copy == original);
    assert(!inCollectedHeap(copy.name.ptr) && !inCollectedHeap(copy.ids.ptr));
    static assert(!isPlainData!(int[int]) && !isPlainData!Object && isPlainData!Row);
}

// ---------------------------------------------------------------------------------------------------
// StaticMap
// ---------------------------------------------------------------------------------------------------

/**
 * A table read far more than it is changed: an associative array until `freeze`, then a table in the
 * arena. See the module documentation.
 */
struct StaticMap(K, V)
if (isPlainData!K && isPlainData!V)
{
    /// What a lookup gives: `V`, or `const V` if it has pointers (see the module documentation).
    static if (hasIndirections!V)
        alias Value = const(V);
    else
        alias Value = V;

    private
    {
        V[K] building;     // before `freeze`; after it, the keys added since
        K[] keys_;         // frozen: in the arena
        V[] values_;       // frozen: in the arena, matching `keys_`
        uint[] slots;      // frozen: an index into `keys_` plus one, 0 for none; a power of two long
        bool[size_t] rooted; // frozen values given out to change: the collector scans them
        bool frozen;
    }

    /// Whether it is in the arena now.
    @property bool isFrozen() const
    {
        return frozen;
    }

    /// Moves it into the arena.
    void freeze() @trusted
    {
        if (frozen)
            return;
        const count = building.length;
        keys_ = cast(K[]) arenaArray!(Unqual!K)(count);
        values_ = cast(V[]) arenaArray!(Unqual!V)(count);
        size_t size = 8;
        while (size < count * 2)
            size *= 2;
        slots = arenaArray!uint(size);
        slots[] = 0;
        size_t i;
        foreach (ref key, ref value; building)
        {
            auto k = frozenCopy(key);
            auto v = frozenCopy(value);
            (cast(ubyte*) &keys_[i])[0 .. K.sizeof] = (cast(ubyte*) &k)[0 .. K.sizeof];
            (cast(ubyte*) &values_[i])[0 .. V.sizeof] = (cast(ubyte*) &v)[0 .. V.sizeof];
            auto slot = hashOf(keys_[i]) & (size - 1);
            while (slots[slot])
                slot = (slot + 1) & (size - 1);
            slots[slot] = cast(uint)(i + 1);
            ++i;
        }
        building = null;
        frozen = true;
    }

    // The index of `key` in the frozen table, or size_t.max.
    private size_t indexOf(const K key) const @trusted
    {
        if (!frozen || keys_.length == 0)
            return size_t.max;
        const mask = slots.length - 1;
        auto slot = hashOf(key) & mask;
        for (;;)
        {
            const at = slots[slot];
            if (at == 0)
                return size_t.max;
            if (keys_[at - 1] == key)
                return at - 1;
            slot = (slot + 1) & mask;
        }
    }

    private inout(V)* find(const K key) inout @trusted
    {
        const i = indexOf(key);
        if (i != size_t.max)
            return &values_[i];
        return cast(inout(V)*)(key in building);
    }

    /// `key in map`.
    Value* opBinaryRight(string op : "in")(const K key) @trusted
    {
        return find(key);
    }

    /// ditto
    const(V)* opBinaryRight(string op : "in")(const K key) const @trusted
    {
        return find(key);
    }

    /// `map[key]`; a missing key is an error, as in an associative array.
    ref Value opIndex(const K key) @trusted
    {
        import core.exception : RangeError;

        if (auto p = find(key))
            return *p;
        throw new RangeError();
    }

    /// ditto
    ref const(V) opIndex(const K key) const @trusted
    {
        import core.exception : RangeError;

        if (auto p = find(key))
            return *p;
        throw new RangeError();
    }

    /// The value, or `fallback`.
    V get(const K key, lazy V fallback) const @trusted
    {
        if (auto p = find(key))
            return cast(V)*p;
        return fallback;
    }

    /**
     * A value to change in place; null if missing. A frozen one stays where it is (whoever holds a
     * pointer to it sees the change), and the collector scans it from now on, so what is stored in it
     * may point into its heap.
     */
    V* edit(const K key) @trusted
    {
        const i = indexOf(key);
        if (i == size_t.max)
            return key in building;
        static if (hasIndirections!V)
            if (i !in rooted)
            {
                import core.memory : GC;

                GC.addRange(&values_[i], V.sizeof);
                rooted[i] = true;
            }
        return &values_[i];
    }

    /// `map[key] = value`: in place if it is frozen there (see `edit`), otherwise added.
    void opIndexAssign(V value, K key)
    {
        if (auto p = indexOf(key) != size_t.max ? edit(key) : null)
            *p = value;
        else
            building[key] = value;
    }

    /// The value to change in place, made if missing.
    ref V require(K key, lazy V value = V.init)
    {
        if (auto p = edit(key))
            return *p;
        return building.require(key, value);
    }

    /// Removes `key`; whether it was there. (From a frozen table it is rebuilt without it, so pointers
    /// to its other values no longer see changes: removing is for tests and GM commands.)
    bool remove(const K key)
    {
        if (indexOf(key) == size_t.max)
            return building.remove(key);
        V[K] back = building;
        foreach (i, ref k; keys_)
            if (k != key)
                back[k] = values_[i];
        keys_ = null;
        values_ = null;
        slots = null;
        rooted = null;
        building = back;
        frozen = false;
        freeze();
        return true;
    }

    /// Empties it.
    void clear()
    {
        building = null;
        keys_ = null;
        values_ = null;
        slots = null;
        rooted = null;
        frozen = false;
    }

    /// How many keys.
    @property size_t length() const
    {
        return keys_.length + building.length;
    }

    /// The keys.
    @property const(K)[] keys() const
    {
        return building.length ? keys_ ~ building.keys : keys_;
    }

    /// The values.
    @property Value[] values() @trusted
    {
        return building.length ? cast(Value[]) values_ ~ cast(Value[]) building.values : cast(Value[]) values_;
    }

    /// ditto
    @property const(V)[] values() const @trusted
    {
        return building.length ? values_ ~ building.values : values_;
    }

    /// ditto
    alias byKey = keys;
    /// ditto
    alias byValue = values;

    /// `foreach (key, value; map)` and `foreach (value; map)`.
    int opApply(scope int delegate(const K, ref Value) dg) @trusted
    {
        foreach (i, ref key; keys_)
            if (const r = dg(key, *cast(Value*) &values_[i]))
                return r;
        foreach (key, ref value; building)
            if (const r = dg(key, *cast(Value*) &value))
                return r;
        return 0;
    }

    /// ditto
    int opApply(scope int delegate(ref Value) dg)
    {
        return opApply((const K, ref Value value) => dg(value));
    }

    /// ditto
    int opApply(scope int delegate(const K, ref const V) dg) const @trusted
    {
        return (cast() this).opApply((const K key, ref Value value) => dg(key, value));
    }

    /// ditto
    int opApply(scope int delegate(ref const V) dg) const @trusted
    {
        return (cast() this).opApply((const K, ref Value value) => dg(value));
    }
}

/**
 * Freezes every `StaticMap` in `root` (a class or struct), and in the classes and structs it holds,
 * at every depth: called once the data has loaded.
 */
void freezeAll(T)(T root) @trusted
if (is(T == class))
{
    if (root !is null)
        freezeMembers(root);
}

private void freezeMembers(T)(ref T root) @trusted
{
    static foreach (i; 0 .. T.tupleof.length)
    {{
        alias F = typeof(T.tupleof[i]);
        static if (is(F == StaticMap!(K, V), K, V))
            root.tupleof[i].freeze();
        else static if (is(F == class) && __traits(getProtection, T.tupleof[i]) != "private" && isOwnData!F)
        {
            if (root.tupleof[i] !is null)
                freezeMembers(root.tupleof[i]);
        }
        else static if (is(F == struct))
            freezeMembers(root.tupleof[i]);
    }}
}

// The classes of the static data, which `freezeAll` goes into: they say so with
// `enum holdsStaticData = true`.
private template isOwnData(C)
{
    static if (__traits(hasMember, C, "holdsStaticData"))
        enum isOwnData = C.holdsStaticData;
    else
        enum isOwnData = false;
}

unittest
{
    static struct Template { uint entry; string name; }
    StaticMap!(uint, Template) map;
    foreach (uint i; 0 .. 1000)
        map[i] = Template(i, "item " ~ cast(char)('a' + i % 26));
    map.freeze();
    assert(map.isFrozen && map.length == 1000);
    assert((7 in map).name == "item h" && 1000 !in map);
    assert(map[999].entry == 999 && map.get(5000, Template(1)).entry == 1);
    assert(!inCollectedHeap(&map[3]) && !inCollectedHeap(map[3].name.ptr));
    size_t seen;
    foreach (k, ref v; map)
        seen += k == v.entry;
    assert(seen == 1000);

    // A change is made in place: a pointer taken before sees it, and what it stores is kept alive.
    const before = 3 in map;
    map.edit(3).name = "changed".idup;
    assert(map.isFrozen && before.name == "changed" && map.length == 1000);
    map[1000] = Template(1000, "new");
    assert(map.length == 1001 && map[1000].name == "new" && map.isFrozen);
    assert(map.remove(5) && 5 !in map && map.length == 1000 && map[1000].name == "new");

    StaticMap!(uint, uint) plain; // no pointers: mutable even frozen
    plain[1] = 2;
    plain.freeze();
    *(1 in plain) = 3;
    assert(plain[1] == 3 && plain.isFrozen);
}
