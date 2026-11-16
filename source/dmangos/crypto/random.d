/// Cryptographically secure random bytes from the operating system.
module dmangos.crypto.random;

/// Fills `buffer` with secure random bytes.
void fillSecureRandom(scope ubyte[] buffer) @trusted
{
    version (Posix)
    {
        import std.exception : enforce;
        import std.stdio : File;

        auto source = File("/dev/urandom", "rb");
        scope (exit)
            source.close();
        enforce(source.rawRead(buffer).length == buffer.length, "short read from /dev/urandom");
    }
    else
        static assert(false, "no secure random source implemented for this platform yet");
}

/// Returns `N` secure random bytes.
ubyte[N] secureRandom(size_t N)() @safe
{
    ubyte[N] bytes;
    fillSecureRandom(bytes[]);
    return bytes;
}

@safe unittest
{
    const a = secureRandom!32;
    const b = secureRandom!32;
    assert(a != b, "two 256-bit random values should never collide");
}
