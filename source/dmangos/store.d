/**
 * Slot storage (docs/DESIGN.md, "Entity identity" and "Storage and memory layout").
 *
 * A `Store!T` keeps values of `T` in a growing array of slots and hands out `Ref!T`: a slot and its
 * generation. Removing a value frees its slot for reuse and bumps its generation, so a reference kept
 * from before no longer finds anything (a stale reference is caught, not misdirected). Lookup is an
 * array index; iterating walks one array. A `Side!T` holds a value for some of a store's slots (state
 * that comes and goes) packed in a dense array, and a `SlotBits` is a set of slots, one bit each.
 *
 * Generations are 32 bits: a slot would have to be reused four billion times before an old reference
 * could alias a new value.
 */
module dmangos.store;

/// A reference to the value in a slot of a `Store!T`; `Ref!T.init` refers to nothing.
struct Ref(T)
{
    uint slot = uint.max;
    uint generation;

    /// Whether it refers to anything at all (it may still be stale).
    bool opCast(B : bool)() const pure nothrow @nogc @safe
    {
        return slot != uint.max;
    }
}

/// See the module documentation.
struct Store(T)
{
    private T[] items;
    private uint[] generations; // odd: the slot holds a value
    private uint[] free;
    private size_t freeCount;
    private size_t live;

    /// Puts `value` in a free slot (or a new one).
    Ref!T add(T value) pure nothrow @safe
    {
        uint slot;
        if (freeCount)
            slot = free[--freeCount];
        else
        {
            slot = cast(uint) items.length;
            items ~= T.init;
            generations ~= 0;
        }
        items[slot] = value;
        ++generations[slot];
        ++live;
        return Ref!T(slot, generations[slot]);
    }

    /// The value `r` refers to; null if it is gone (or `r` refers to nothing).
    inout(T)* opIndex(Ref!T r) inout pure nothrow @nogc @trusted
    {
        return holds(r.slot) && generations[r.slot] == r.generation ? &items[r.slot] : null;
    }

    /// The value in `slot`, which must hold one.
    ref inout(T) at(uint slot) inout pure nothrow @nogc @safe
    in (holds(slot))
    {
        return items[slot];
    }

    /// Whether `slot` holds a value.
    bool holds(uint slot) const pure nothrow @nogc @safe
    {
        return slot < items.length && (generations[slot] & 1);
    }

    /// The reference to the value in `slot` now.
    Ref!T refOf(uint slot) const pure nothrow @nogc @safe
    in (holds(slot))
    {
        return Ref!T(slot, generations[slot]);
    }

    /// Takes the value out; its slot is free, and references to it are stale. Nothing if already gone.
    void remove(Ref!T r) pure nothrow @safe
    {
        if (this[r] is null)
            return;
        items[r.slot] = T.init; // what it held is no longer reachable from here
        ++generations[r.slot];
        if (freeCount == free.length)
            free ~= r.slot;
        else
            free[freeCount] = r.slot;
        ++freeCount;
        --live;
    }

    /// How many values it holds.
    @property size_t length() const pure nothrow @nogc @safe
    {
        return live;
    }

    /// How many slots there are (held or free): the bound for `SlotBits` over them.
    @property size_t capacity() const pure nothrow @nogc @safe
    {
        return items.length;
    }

    /// Every value, with its slot.
    int opApply(scope int delegate(uint slot, ref T value) dg)
    {
        foreach (i, ref value; items)
            if (generations[i] & 1)
                if (const r = dg(cast(uint) i, value))
                    return r;
        return 0;
    }
}

/// A value for some slots, packed: adding and removing moves nothing else; iterating walks the values.
struct Side(T)
{
    private T[] values;
    private uint[] owners;  // the slot of each value
    private uint[] indexOf; // slot -> index + 1 (0: none)

    /// The value for `slot`, made (as `T.init`) if it has none.
    ref T require(uint slot) pure nothrow @safe
    {
        if (auto v = this[slot])
            return *v;
        if (indexOf.length <= slot)
            indexOf.length = slot + 1;
        values ~= T.init;
        owners ~= slot;
        indexOf[slot] = cast(uint) values.length;
        return values[$ - 1];
    }

    /// The value for `slot`; null if it has none.
    inout(T)* opIndex(uint slot) inout pure nothrow @nogc @trusted
    {
        if (slot >= indexOf.length || indexOf[slot] == 0)
            return null;
        return &values[indexOf[slot] - 1];
    }

    /// Whether `slot` has a value.
    bool has(uint slot) const pure nothrow @nogc @safe
    {
        return slot < indexOf.length && indexOf[slot] != 0;
    }

    /// The value for `slot` goes (the last value takes its place).
    void remove(uint slot) pure nothrow @safe
    {
        if (!has(slot))
            return;
        const i = indexOf[slot] - 1, last = values.length - 1;
        if (i != last)
        {
            values[i] = values[last];
            owners[i] = owners[last];
            indexOf[owners[i]] = cast(uint)(i + 1);
        }
        values[last] = T.init;
        values.length = last;
        owners.length = last;
        () @trusted { values.assumeSafeAppend(); owners.assumeSafeAppend(); }();
        indexOf[slot] = 0;
    }

    /// How many slots have a value.
    @property size_t length() const pure nothrow @nogc @safe
    {
        return values.length;
    }

    /// Every value, with its slot.
    int opApply(scope int delegate(uint slot, ref T value) dg)
    {
        foreach (i, ref value; values)
            if (const r = dg(owners[i], value))
                return r;
        return 0;
    }
}

/// A set of slots, one bit each.
struct SlotBits
{
    private ulong[] words;
    private size_t count_;

    /// Whether `slot` is in it.
    bool opIndex(uint slot) const pure nothrow @nogc @safe
    {
        const w = slot >> 6;
        return w < words.length && (words[w] >> (slot & 63) & 1);
    }

    /// Puts `slot` in; whether it was not in before.
    bool add(uint slot) pure nothrow @safe
    {
        const w = slot >> 6;
        if (w >= words.length)
            words.length = w + 1;
        const bit = 1UL << (slot & 63);
        if (words[w] & bit)
            return false;
        words[w] |= bit;
        ++count_;
        return true;
    }

    /// Takes `slot` out; whether it was in.
    bool remove(uint slot) pure nothrow @nogc @safe
    {
        const w = slot >> 6;
        if (w >= words.length)
            return false;
        const bit = 1UL << (slot & 63);
        if (!(words[w] & bit))
            return false;
        words[w] &= ~bit;
        --count_;
        return true;
    }

    /// How many slots are in it.
    @property size_t length() const pure nothrow @nogc @safe
    {
        return count_;
    }

    /// Empties it.
    void clear() pure nothrow @nogc @safe
    {
        words[] = 0;
        count_ = 0;
    }

    /// Every slot in it, in order.
    int opApply(scope int delegate(uint slot) dg) const
    {
        import core.bitop : bsf;

        foreach (w, const full; words)
            for (ulong word = full; word;)
            {
                const b = bsf(word);
                word &= word - 1;
                if (const r = dg(cast(uint)(w * 64 + b)))
                    return r;
            }
        return 0;
    }
}

unittest
{
    static struct Thing
    {
        int value;
    }

    Store!Thing store;
    const a = store.add(Thing(1)), b = store.add(Thing(2));
    assert(store[a].value == 1 && store[b].value == 2 && store.length == 2);
    store.remove(a);
    assert(store[a] is null && store.length == 1, "gone");
    const freeSlot = Ref!Thing(a.slot, a.generation + 1);
    assert(store[freeSlot] is null);
    store.remove(freeSlot);
    assert(store.length == 1);
    const c = store.add(Thing(3));
    assert(c.slot == a.slot && c.generation != a.generation, "the slot is reused under a new generation");
    assert(store[a] is null && store[c].value == 3, "the old reference does not find the new value");
    assert(!Ref!Thing.init && store[Ref!Thing.init] is null);
    int sum;
    foreach (slot, ref t; store)
        sum += t.value;
    assert(sum == 5);
    store.remove(a); // stale: nothing happens
    assert(store.length == 2);

    Side!int side;
    side.require(5) = 50;
    side.require(9) = 90;
    side.require(2) = 20;
    side.remove(5);
    assert(side[5] is null && *side[9] == 90 && *side[2] == 20 && side.length == 2);
    int[uint] seen;
    foreach (slot, ref v; side)
        seen[slot] = v;
    assert(seen.length == 2 && seen[9] == 90 && seen[2] == 20);

    SlotBits bits;
    assert(bits.add(3) && bits.add(200) && !bits.add(3) && bits.length == 2);
    assert(bits[3] && bits[200] && !bits[4] && !bits[100_000]);
    uint[] all;
    foreach (slot; bits)
        all ~= slot;
    assert(all == [3, 200]);
    assert(bits.remove(3) && !bits.remove(3) && bits.length == 1);
}
