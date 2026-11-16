/// Hash helpers used by the authentication protocols.
module dmangos.crypto.hash;

import std.digest.sha : SHA1;
import std.string : representation;
import std.traits : isArray, isSomeString;

/// Length of a SHA-1 digest in bytes.
enum sha1Length = 20;

/**
 * SHA-1 over the concatenation of every argument.
 *
 * Arguments may be strings or byte arrays, fixed-size or dynamic, in any
 * mix. The loop over the variadic arguments is unrolled at compile time.
 */
ubyte[sha1Length] sha1(Parts...)(const Parts parts)
{
    SHA1 context;
    context.start();
    foreach (ref part; parts)
    {
        static if (isSomeString!(typeof(part)))
            context.put(part.representation);
        else static if (isArray!(typeof(part)))
            context.put(part[]);
        else
            static assert(false, "sha1() accepts strings and byte arrays, not " ~ typeof(part).stringof);
    }
    return context.finish();
}

/// Compares two byte strings in time that does not depend on where they differ.
bool constantTimeEqual(scope const(ubyte)[] a, scope const(ubyte)[] b) pure nothrow @nogc @safe
{
    if (a.length != b.length)
        return false;
    ubyte difference = 0;
    foreach (i; 0 .. a.length)
        difference |= a[i] ^ b[i];
    return difference == 0;
}

@safe unittest
{
    import dmangos.hex : hexLiteral;

    // Known SHA-1 of "abc" (FIPS 180-2), fed in pieces of different types.
    const ubyte[1] b = ['b'];
    assert(sha1("a", b, "c") == hexLiteral!"A9993E364706816ABA3E25717850C26C9CD0D89D");

    const ubyte[3] x = [1, 2, 3];
    const ubyte[3] y = [1, 2, 4];
    assert(constantTimeEqual(x[], x[]));
    assert(!constantTimeEqual(x[], y[]));
    assert(!constantTimeEqual(x[], x[0 .. 2]));
}
