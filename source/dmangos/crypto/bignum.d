/**
 * Conversions between `std.bigint.BigInt` and the little-endian byte order
 * that the WoW client uses for every SRP6 value.
 */
module dmangos.crypto.bignum;

import std.bigint : BigInt;

@safe: // the compiler checks every function here

/// Interprets `bytes` as an unsigned little-endian integer.
BigInt fromLittleEndian(scope const(ubyte)[] bytes) @safe
{
    BigInt result;
    foreach_reverse (b; bytes)
    {
        result <<= 8;
        result += b;
    }
    return result;
}

/// Minimal little-endian encoding of a non-negative integer (zero encodes as no bytes).
ubyte[] toLittleEndian(BigInt value) @safe
in (value >= 0, "only non-negative integers can be encoded")
{
    ubyte[] bytes;
    while (value > 0)
    {
        bytes ~= cast(ubyte)(value % 256);
        value >>= 8;
    }
    return bytes;
}

/// Little-endian encoding zero-padded to exactly `N` bytes. The value must fit.
ubyte[N] toFixedLittleEndian(size_t N)(BigInt value) @safe
in (value >= 0, "only non-negative integers can be encoded")
{
    const bytes = toLittleEndian(value);
    assert(bytes.length <= N, "integer does not fit in the requested width");
    ubyte[N] result;
    result[0 .. bytes.length] = bytes[];
    return result;
}

@safe unittest
{
    const ubyte[4] encoded = [0x04, 0x03, 0x02, 0x01];
    assert(fromLittleEndian(encoded[]) == 0x01020304);
    assert(toFixedLittleEndian!4(BigInt(0x01020304)) == encoded);

    const ubyte[6] padded = [0x04, 0x03, 0x02, 0x01, 0, 0];
    assert(toFixedLittleEndian!6(BigInt(0x01020304)) == padded);
    assert(toLittleEndian(BigInt(0)).length == 0);

    // Leading (high-order) zero bytes do not change the value.
    assert(fromLittleEndian(padded[]) == fromLittleEndian(encoded[]));
}
