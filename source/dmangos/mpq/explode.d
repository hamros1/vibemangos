/**
 * Decompression of PKWare Data Compression Library ("implode") streams, the
 * older of the two compressions MPQ archives use.
 *
 * This follows Mark Adler's reference decoder, `blast.c` from zlib's
 * contrib directory. The three canonical Huffman codes are fixed, so their
 * decoding tables are built by the compiler.
 */
module dmangos.mpq.explode;

import std.exception : basicExceptionCtors, enforce;

/// Thrown for a corrupt or truncated stream.
class ExplodeException : Exception
{
    mixin basicExceptionCtors;
}

private enum maxBits = 13;

/// A canonical Huffman code: code counts per length, symbols ordered by length.
private struct Huffman
{
    short[maxBits + 1] count;
    short[256] symbol;
}

/// Builds a code from blast's compact form (count - 1 in the high nibble, length in the low one).
private Huffman construct(const(ubyte)[] compact) pure @safe
{
    short[256] length;
    size_t n;
    foreach (rep; compact)
        foreach (_; 0 .. (rep >> 4) + 1)
            length[n++] = rep & 15;

    Huffman h;
    foreach (symbol; 0 .. n)
        ++h.count[length[symbol]];
    short[maxBits + 1] offsets;
    foreach (len; 1 .. maxBits)
        offsets[len + 1] = cast(short)(offsets[len] + h.count[len]);
    foreach (symbol; 0 .. n)
        if (length[symbol])
            h.symbol[offsets[length[symbol]]++] = cast(short) symbol;
    return h;
}

private static immutable ubyte[] literalLengths = [
    11, 124, 8, 7, 28, 7, 188, 13, 76, 4, 10, 8, 12, 10, 12, 10, 8, 23, 8, 9, 7, 6, 7, 8, 7, 6, 55, 8, 23, 24, 12, 11,
    7, 9, 11, 12, 6, 7, 22, 5, 7, 24, 6, 11, 9, 6, 7, 22, 7, 11, 38, 7, 9, 8, 25, 11, 8, 11, 9, 12, 8, 12, 5, 38, 5,
    38, 5, 11, 7, 5, 6, 21, 6, 10, 53, 8, 7, 24, 10, 27, 44, 253, 253, 253, 252, 252, 252, 13, 12, 45, 12, 45, 12, 61,
    12, 45, 44, 173];
private static immutable ubyte[] lengthLengths = [2, 35, 36, 53, 38, 23];
private static immutable ubyte[] distanceLengths = [2, 20, 53, 230, 247, 151, 248];

private static immutable Huffman literalCode = construct(literalLengths);
private static immutable Huffman lengthCode = construct(lengthLengths);
private static immutable Huffman distanceCode = construct(distanceLengths);

private static immutable short[16] lengthBase = [3, 2, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24, 40, 72, 136, 264];
private static immutable ubyte[16] lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8];

/// Least-significant-bit-first reader over the compressed bytes.
private struct BitReader
{
    const(ubyte)[] input;
    size_t position;
    uint buffer;
    uint count;

    uint bits(uint need) pure @safe
    {
        while (count < need)
        {
            enforce!ExplodeException(position < input.length, "implode stream is truncated");
            buffer |= uint(input[position++]) << count;
            count += 8;
        }
        const value = buffer & ((1u << need) - 1);
        buffer >>= need;
        count -= need;
        return value;
    }

    /// `decode` from blast.c: codes are read bit by bit, inverted, shortest first.
    int decode(const ref Huffman h) pure @safe
    {
        int code, first, index;
        foreach (len; 1 .. maxBits + 1)
        {
            code |= bits(1) ^ 1;
            const count = h.count[len];
            if (code < first + count)
                return h.symbol[index + (code - first)];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        throw new ExplodeException("invalid Huffman code in implode stream");
    }
}

/**
 * Decompresses a PKWare DCL stream. `expectedSize`, when known, is used to
 * size the output; the stream's own end code decides where it stops.
 */
ubyte[] explode(const(ubyte)[] input, size_t expectedSize = 0) pure @safe
{
    auto reader = BitReader(input);
    const coded = reader.bits(8);
    enforce!ExplodeException(coded <= 1, "invalid implode literal mode");
    const dictionary = reader.bits(8);
    enforce!ExplodeException(dictionary >= 4 && dictionary <= 6, "invalid implode dictionary size");

    ubyte[] output;
    output.reserve(expectedSize);
    for (;;)
    {
        if (reader.bits(1))
        {
            const lengthSymbol = reader.decode(lengthCode);
            uint length = lengthBase[lengthSymbol] + reader.bits(lengthExtra[lengthSymbol]);
            if (length == 519)
                break; // end code
            const shift = length == 2 ? 2 : dictionary;
            uint distance = reader.decode(distanceCode) << shift;
            distance += reader.bits(shift);
            distance += 1;
            enforce!ExplodeException(distance <= output.length, "implode distance points before the start");
            // Overlapping copies are intended: byte by byte repeats the window.
            foreach (_; 0 .. length)
                output ~= output[$ - distance];
        }
        else
            output ~= cast(ubyte)(coded ? reader.decode(literalCode) : reader.bits(8));
    }
    return output;
}

@safe unittest
{
    import std.exception : assertThrown;

    // The worked example from blast.c.
    static immutable ubyte[] example = [0x00, 0x04, 0x82, 0x24, 0x25, 0x8F, 0x80, 0x7F];
    import std.string : representation;

    assert(explode(example) == "AIAIAIAIAIAIA".representation);
    static assert(explode(example) == "AIAIAIAIAIAIA".representation, "and the decoder runs at compile time too");

    assertThrown!ExplodeException(explode(example[0 .. 5]));
    static immutable ubyte[] badHeader = [0x02, 0x04];
    assertThrown!ExplodeException(explode(badHeader));
}
