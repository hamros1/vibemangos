/**
 * Hexadecimal encoding and decoding.
 *
 * Every function here is pure, so it can also run at compile time.
 * `hexLiteral` relies on that to turn a hex string into a fixed-size byte
 * array during compilation, which is how the SRP6 prime and the test vectors
 * are declared.
 */
module dmangos.hex;

import std.conv : ConvException;
import std.exception : enforce;

/// Value of a single hexadecimal digit.
private ubyte nibble(char c) pure @safe
{
    if (c >= '0' && c <= '9')
        return cast(ubyte)(c - '0');
    if (c >= 'a' && c <= 'f')
        return cast(ubyte)(c - 'a' + 10);
    if (c >= 'A' && c <= 'F')
        return cast(ubyte)(c - 'A' + 10);
    throw new ConvException("invalid hexadecimal digit '" ~ c ~ "'");
}

/// Parses a string of hex digit pairs into bytes, in the order they are written.
ubyte[] parseHex(scope const(char)[] hex) pure @safe
{
    enforce!ConvException(hex.length % 2 == 0, "hexadecimal string must have an even length");
    auto result = new ubyte[hex.length / 2];
    foreach (i, ref b; result)
        b = cast(ubyte)((nibble(hex[2 * i]) << 4) | nibble(hex[2 * i + 1]));
    return result;
}

/// ditto, but into a fixed-size array; throws if the length does not match.
ubyte[N] parseHexFixed(size_t N)(scope const(char)[] hex) pure @safe
{
    enforce!ConvException(hex.length == 2 * N, "hexadecimal string has the wrong length");
    ubyte[N] result;
    result[] = parseHex(hex)[];
    return result;
}

/// A `ubyte[N]` computed from a hex string at compile time.
enum hexLiteral(string hex) = parseHexFixed!(hex.length / 2)(hex);

/// Upper-case hex representation of `bytes`.
string toHex(scope const(ubyte)[] bytes) pure nothrow @safe
{
    static immutable digits = "0123456789ABCDEF";
    auto result = new char[bytes.length * 2];
    foreach (i, b; bytes)
    {
        result[2 * i] = digits[b >> 4];
        result[2 * i + 1] = digits[b & 0x0F];
    }
    return result.idup;
}

@safe unittest
{
    import std.exception : assertThrown;

    // Evaluated by the compiler, not at run time.
    static assert(hexLiteral!"0aFF10".length == 3);
    static assert(hexLiteral!"0aFF10"[1] == 0xFF);

    const ubyte[3] expected = [0x0A, 0xFF, 0x10];
    assert(parseHex("0aff10") == expected[]);
    assert(toHex(expected[]) == "0AFF10");
    assert(parseHex("") == []);
    assertThrown!ConvException(parseHex("abc"));
    assertThrown!ConvException(parseHex("zz"));
    assertThrown!ConvException(parseHexFixed!2("00"));
}
