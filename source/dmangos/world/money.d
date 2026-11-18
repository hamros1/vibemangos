/**
 * Money: an amount of copper (100 copper are a silver, 100 silver a gold).
 *
 * `Copper` never wraps around. A sum stops at `Copper.max`, what a purse can hold (the client shows money
 * as a signed 32-bit number), and a difference stops at nothing. Nothing converts to it implicitly: an
 * amount from the client, the database or the game's data becomes money where it enters, and a `uint`
 * sum computed beforehand (which can wrap) does not compile where money is expected.
 *
 * A player's purse is `Player.money`; `Player.canAfford`, `Player.pay` and `Player.receive` change it. The
 * database and the wire keep the plain `uint` (`Copper.amount`).
 */
module dmangos.world.money;

/// See the module documentation.
struct Copper
{
    uint amount; /// in copper

    /// The most a purse holds.
    enum Copper max = Copper(int.max);

    /// The sum, at most `max`; the difference, at least nothing.
    Copper opBinary(string op)(const Copper other) const pure nothrow @nogc @safe
        if (op == "+" || op == "-")
    {
        static if (op == "+")
        {
            const ulong sum = ulong(amount) + other.amount;
            return Copper(sum > max.amount ? max.amount : cast(uint) sum);
        }
        else
            return Copper(amount > other.amount ? amount - other.amount : 0);
    }

    /// `times` as much, at most `max`.
    Copper opBinary(string op : "*")(uint times) const pure nothrow @nogc @safe
    {
        const ulong product = ulong(amount) * times;
        return Copper(product > max.amount ? max.amount : cast(uint) product);
    }

    ///
    int opCmp(const Copper other) const pure nothrow @nogc @safe
    {
        return (amount > other.amount) - (amount < other.amount);
    }

    /// Whether there is any.
    bool opCast(T : bool)() const pure nothrow @nogc @safe
    {
        return amount != 0;
    }

    /// "1g 2s 3c", as the game writes it.
    string toString() const pure @safe
    {
        import std.format : format;

        return format!"%sg %ss %sc"(amount / 10_000, amount / 100 % 100, amount % 100);
    }
}

///
pure nothrow @safe unittest
{
    assert(Copper(10) + Copper(5) == Copper(15));
    assert(Copper(10) - Copper(15) == Copper(0), "never below nothing");
    assert(Copper(uint.max - 29) + Copper(30) == Copper.max, "no wrap: 32-bit overflow stops at the ceiling");
    assert(Copper(int.max) + Copper(1) == Copper.max);
    assert(Copper(3) * 4 == Copper(12) && Copper(int.max) * 2 == Copper.max);
    assert(Copper(1) < Copper(2) && Copper(2) >= Copper(2));
    assert(!Copper(0) && Copper(1));
    static assert(!__traits(compiles, { Copper c = 5u; }), "an integer is not money until it is made money");
    static assert(!__traits(compiles, Copper(1) + 5u));
}

@safe unittest
{
    assert(Copper(1_02_03).toString == "1g 2s 3c");
}
