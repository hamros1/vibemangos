/**
 * Typed event queues (docs/DESIGN.md, "Events", step 4).
 *
 * Where several systems must hear of something (a creature died: its dungeon's script, its respawn
 * time, ...), the code where it happens appends a record to a queue of that record's type and goes on;
 * the systems that care read the queue in their phase of the tick. Nothing is looked up or called at
 * the moment of the event, and whoever happens to cause it need not know who listens. Inside a
 * system, direct calls stay.
 *
 * A queue is two arrays: `put` appends to one, `take` hands it over and starts filling the other,
 * whose memory is reused, so a queue in steady use allocates nothing.
 */
module dmangos.events;

/// See the module documentation.
struct EventQueue(T)
{
    private T[] filling;
    private T[] spare;

    /// An event, for the next `take`.
    void put(T event) pure nothrow @safe
    {
        filling ~= event;
    }

    /// Whether nothing is waiting.
    @property bool empty() const pure nothrow @nogc @safe
    {
        return filling.length == 0;
    }

    /// The events since the last `take`, in order. Valid until the next `take`; events put while
    /// they are read go to the next.
    T[] take() pure nothrow @trusted
    {
        auto taken = filling;
        spare.length = 0;
        spare.assumeSafeAppend();
        filling = spare;
        spare = taken;
        return taken;
    }
}

unittest
{
    EventQueue!int deaths;
    assert(deaths.empty);
    deaths.put(1);
    deaths.put(2);
    const first = deaths.take();
    assert(first == [1, 2] && deaths.empty);
    deaths.put(3); // while the first batch is read
    assert(first == [1, 2], "the batch taken is not disturbed");
    assert(deaths.take() == [3] && deaths.take().length == 0);
}
