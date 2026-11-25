/** ClassicDB's hexadecimal world-state programs. See CMaNGOS WorldStateExpression.cpp. */
module dmangos.world.worldstateexpression;

import dmangos.bytes : ByteReader, IncompletePacketException;
import dmangos.world.conditions : compareConditionOperands;
import dmangos.world.instancescripting : fromHex;

struct WorldStateExpressions
{
    private const(ubyte)[][uint] programs;

    void add(uint id, const(char)[] hex)
    {
        if (hex.length && !(hex.length % 2))
            if (const bytes = fromHex(hex))
                programs[id] = bytes;
    }

    bool matches(uint id, int delegate(uint) variable, bool delegate(uint) holiday, long unixTime, uint seed) const
    {
        import std.datetime.systime : SysTime;
        import std.datetime.timezone : LocalTime;

        auto context = Evaluation(&programs, variable, holiday, SysTime.fromUnixTime(unixTime, LocalTime()), unixTime, seed);
        try
            return context.expression(id);
        catch (IncompletePacketException)
            return false;
    }
}

private struct Evaluation
{
    import std.datetime.systime : SysTime;

    const(const(ubyte)[][uint])* programs;
    int delegate(uint) variable;
    bool delegate(uint) holiday;
    SysTime time;
    long unixTime;
    uint seed;
    uint budget = 1024;

    bool expression(uint id, uint depth = 0)
    {
        const program = id in *programs;
        if (program is null)
            return false;
        ByteReader reader = ByteReader(*program);
        if (!reader.read!bool)
            return false;
        bool result = relation(reader, depth);
        for (ubyte link; (link = reader.read!ubyte) != 0;)
        {
            const next = relation(reader, depth);
            switch (link)
            {
            case 1: result = result && next; break;
            case 2: result = result || next; break;
            case 3: result = result != next; break;
            default: return false;
            }
        }
        return reader.empty && result;
    }

    bool relation(ref ByteReader reader, uint depth)
    {
        const lhs = arithmetic(reader, depth);
        const comparison = reader.read!ubyte;
        if (!comparison)
            return lhs != 0;
        if (comparison > 6)
            throw new IncompletePacketException("unknown world-state comparison");
        const rhs = arithmetic(reader, depth);
        return compareConditionOperands(comparison, lhs, rhs);
    }

    int arithmetic(ref ByteReader reader, uint depth)
    {
        const lhs = scalar(reader, depth);
        const op = reader.read!ubyte;
        if (!op)
            return lhs;
        const rhs = scalar(reader, depth);
        switch (op)
        {
        case 1: return lhs + rhs;
        case 2: return lhs - rhs;
        case 3: return lhs * rhs;
        case 4: return rhs ? cast(int)(long(lhs) / rhs) : 0;
        case 5: return rhs ? cast(int)(long(lhs) % rhs) : 0;
        default: throw new IncompletePacketException("unknown world-state operator");
        }
    }

    int scalar(ref ByteReader reader, uint depth)
    {
        if (!budget || depth >= 32)
            throw new IncompletePacketException("world-state expression is too complex");
        --budget;
        switch (reader.read!ubyte)
        {
        case 0: return 0; // omitted argument
        case 1: return reader.read!int;
        case 2: return variable(reader.read!uint);
        case 3:
            const op = reader.read!uint;
            const arg = scalar(reader, depth + 1);
            const other = scalar(reader, depth + 1);
            return call(op, arg, other, depth + 1);
        default: throw new IncompletePacketException("unknown world-state value type");
        }
    }

    int call(uint op, int arg, int other, uint depth)
    {
        import std.algorithm.comparison : min, max;
        import std.random : Random, uniform;

        switch (op)
        {
        case 1:
            auto rng = Random(seed++);
            return uniform!"[]"(min(arg, other), max(arg, other), rng);
        case 2: return cast(int) time.month;
        case 3: return time.day + 1; // the ClassicDB interpreter's calendar convention
        case 4: return time.hour * 60 + time.minute;
        case 5: return 1; // the reference interpreter's realm region
        case 6: return time.hour % 12 + 1;
        case 7: return -1; // the old difficulty enum has no Classic value
        case 10: return holiday(cast(uint) arg);
        case 11: return cast(int) unixTime;
        case 12: return cast(int)((unixTime - 1_135_695_600) / (7 * 86_400));
        case 22: return expression(cast(uint) arg, depth);
        case 33:
            if (!arg)
                return 0;
            auto rng = Random(other ? cast(uint) other : 1u);
            return cast(int)(rng.front % cast(uint) arg + 1);
        default: return 0; // unused functions and later-expansion data follow the Classic interpreter
        }
    }
}

unittest
{
    WorldStateExpressions expressions;
    // ((state 1 + 2) == 4) AND (state 2 != 0) XOR (state 3 != 0).
    expressions.add(1, "010201000000010102000000010104000000000102020000000000030203000000000000");
    expressions.add(2, "010316000000010100000000000000"); // calls expression 1
    expressions.add(3, "010316000000010300000000000000"); // loops
    expressions.add(4, "0102010000");                      // truncated
    expressions.add(5, "01ff");
    expressions.add(6, "00");
    int[4] variables = [0, 2, 1, 0];
    bool matches(uint id)
    {
        return expressions.matches(id, key => variables[key], id => false, 0, 1);
    }
    assert(matches(1) && matches(2));
    variables[3] = 1;
    assert(!matches(1) && !matches(2));
    foreach (bad; 3 .. 8)
        assert(!matches(bad));
}
