/**
 * Compile-time packet dispatch.
 *
 * A session marks its handler methods with `@Handles(opcode, states...)`
 * and mixes in `PacketDispatch`. The mixin generates one `switch` with a
 * `case` per attribute, so routing costs a jump table, adding a handler
 * means writing one method, and two handlers for one opcode fail to compile
 * as duplicate cases.
 *
 * ---
 * alias Handles = dmangos.net.dispatch.Handles!(Opcode, State);
 *
 * final class Session
 * {
 *     mixin PacketDispatch!Handles;
 *
 *     @Handles(Opcode.CMSG_PING, State.authenticated, State.inWorld)
 *     void handlePing(ref ByteReader reader) { ... }
 * }
 * ---
 *
 * Only methods whose names start with `handle` are inspected.
 */
module dmangos.net.dispatch;

import std.traits : EnumMembers;

/// Outcome of `dispatchPacket`.
enum DispatchResult
{
    handled,    /// a handler ran
    unhandled,  /// no handler exists for the opcode
    wrongState, /// a handler exists, but not for the session's current state
}

/**
 * Marks a method as the handler of one or more opcodes, legal in any of `states`.
 *
 * The handler's parameter says what it wants, and `PacketDispatch` provides it:
 * $(UL
 *   $(LI nothing: the body is ignored;)
 *   $(LI `ref ByteReader`: the raw body;)
 *   $(LI a packet struct: the body deserialized into it (`dmangos.serialization.deserialize`);)
 *   $(LI a packet struct and the opcode: for one handler of several opcodes.)
 * )
 * This is how vibe.d's web interfaces fill a method's parameters from a request.
 */
struct Handles(Op, State) if (is(State == enum))
{
    static assert(EnumMembers!State.length <= 64, "state sets are stored as a 64-bit mask");

    alias OpcodeType = Op;
    alias StateType = State;

    Op[] opcodes;
    ulong stateMask; /// bit n set: allowed in the state with value n

    ///
    this(Op opcode, State[] states...)
    {
        this([opcode], states);
    }

    ///
    this(const(Op)[] opcodes, State[] states...)
    in (opcodes.length > 0, "a handler needs at least one opcode")
    {
        this.opcodes = opcodes.dup;
        foreach (state; states)
            stateMask |= 1UL << state;
    }

    /// Whether the handler may run in `state`.
    bool allows(State state) const pure nothrow @nogc @safe
    {
        return (stateMask & (1UL << state)) != 0;
    }
}

/**
 * Generates `dispatchPacket(opcode, state, reader)` for the enclosing class
 * from its `@Attribute`-tagged `handle*` methods. `Attribute` is an
 * instance of `Handles`. Two handlers for one opcode are a compile error.
 */
mixin template PacketDispatch(Attribute, parts...)
{
    private DispatchResult dispatchPacket(Attribute.OpcodeType opcode, Attribute.StateType state,
        ref ByteReader reader)
    {
        import std.meta : AliasSeq;
        import std.traits : Parameters, Unqual;
        import dmangos.serialization : deserialize;

        // The session's own handlers (`""`), then those of each of its parts (a field holding an object).
        static foreach (part; AliasSeq!("", parts))
        {
            // A route on a method not named handle*, or on one of several overloads, would never be taken (the
            // overloads' attributes are not all seen): both refuse to compile.
            static foreach (member; __traits(allMembers, typeof(mixin("this" ~ (part.length ? "." ~ part : "")))))
                static if (__traits(compiles, __traits(getOverloads,
                        typeof(mixin("this" ~ (part.length ? "." ~ part : ""))), member)))
                    static foreach (overload; __traits(getOverloads,
                            typeof(mixin("this" ~ (part.length ? "." ~ part : ""))), member))
                        static foreach (route; __traits(getAttributes, overload))
                            static if (is(typeof(route) == Attribute))
                            {
                                static assert(member.length > 6 && member[0 .. 6] == "handle",
                                    member ~ " has a route, so it must be named handle...");
                                static assert(__traits(getOverloads,
                                    typeof(mixin("this" ~ (part.length ? "." ~ part : ""))), member).length == 1,
                                    member ~ " has a route and is overloaded: give the overloads different names");
                            }
        }
        switch (opcode)
        {
            static foreach (part; AliasSeq!("", parts))
            {
                static foreach (member; __traits(allMembers, typeof(mixin("this" ~ (part.length ? "." ~ part : "")))))
                {
                    static if (member.length > 6 && member[0 .. 6] == "handle")
                    {
                        static foreach (route; __traits(getAttributes,
                                __traits(getMember, typeof(mixin("this" ~ (part.length ? "." ~ part : ""))), member)))
                        {
                            static if (is(typeof(route) == Attribute))
                            {
                                static foreach (code; route.opcodes)
                                {
            case code:
                                }
                                if (!route.allows(state))
                                    return DispatchResult.wrongState;
                                {
                                    auto receiver = mixin("this" ~ (part.length ? "." ~ part : ""));
                                    alias Params = Parameters!(__traits(getMember, receiver, member));
                                    static if (Params.length == 0)
                                        __traits(getMember, receiver, member)();
                                    else static if (is(Params[0] == ByteReader))
                                        __traits(getMember, receiver, member)(reader);
                                    else static if (Params.length == 1)
                                        __traits(getMember, receiver, member)(deserialize!(Unqual!(Params[0]))(reader));
                                    else
                                        __traits(getMember, receiver, member)(deserialize!(Unqual!(Params[0]))(reader),
                                            opcode);
                                }
                                return DispatchResult.handled;
                            }
                        }
                    }
                }
            }

        default:
            return DispatchResult.unhandled;
        }
    }
}

unittest
{
    import dmangos.bytes : ByteReader;

    enum Op : ushort
    {
        ping = 1,
        hello = 2,
        bye = 3,
        left = 4,
        right = 5,
        knock = 6,
    }

    enum State
    {
        fresh,
        ready,
    }

    alias On = Handles!(Op, State);

    static struct Ping
    {
        ubyte sequence;
    }

    static final class Door // a part of the machine: its handlers are the machine's too
    {
        string[]* log;

        @On(Op.knock, State.ready)
        void handleKnock()
        {
            *log ~= "knock";
        }
    }

    static final class Machine
    {
        mixin PacketDispatch!(On, "door");

        Door door;

        this()
        {
            door = new Door;
            door.log = &log;
        }

        string[] log;

        @On(Op.hello, State.fresh)
        void handleHello()
        {
            log ~= "hello";
        }

        @On(Op.ping, State.fresh, State.ready)
        void handlePing(Ping ping) // deserialized by the dispatcher
        {
            log ~= "ping " ~ cast(char)('0' + ping.sequence);
        }

        @On(Op.bye, State.ready)
        void handleBye(ref ByteReader reader) // the raw body
        {
            log ~= "bye, " ~ cast(char)('0' + reader.remaining) ~ " bytes";
        }

        @On([Op.left, Op.right], State.ready)
        void handleTurn(Ping ping, Op direction) // one handler, several opcodes
        {
            log ~= (direction == Op.left ? "left " : "right ") ~ cast(char)('0' + ping.sequence);
        }

        DispatchResult feed(Op op, State state, const(ubyte)[] bytes)
        {
            auto reader = ByteReader(bytes);
            return dispatchPacket(op, state, reader);
        }
    }

    static assert(On(Op.ping, State.fresh, State.ready).stateMask == 0b11);

    auto machine = new Machine;
    const ubyte[1] seven = [7];
    assert(machine.feed(Op.hello, State.fresh, null) == DispatchResult.handled);
    assert(machine.feed(Op.ping, State.ready, seven) == DispatchResult.handled);
    assert(machine.feed(Op.bye, State.ready, seven) == DispatchResult.handled);
    assert(machine.feed(Op.right, State.ready, seven) == DispatchResult.handled);
    assert(machine.feed(Op.left, State.fresh, seven) == DispatchResult.wrongState);
    assert(machine.feed(Op.hello, State.ready, null) == DispatchResult.wrongState);
    assert(machine.feed(Op.knock, State.ready, null) == DispatchResult.handled); // a part's route
    assert(machine.feed(Op.knock, State.fresh, null) == DispatchResult.wrongState);
    assert(machine.log == ["hello", "ping 7", "bye, 1 bytes", "right 7", "knock"]);
}
