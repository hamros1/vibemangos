/**
 * The header cipher of the 1.12 world protocol.
 *
 * After authentication, every packet header is obfuscated with the 40-byte
 * SRP6 session key: the 4-byte server header and the 6-byte client header.
 * Bodies are never encrypted. Each direction keeps its own key position `i`
 * and previous cipher byte `j`. This is a scrambler, not real cryptography:
 * the 1.12 client cannot use anything else.
 */
module dmangos.world.crypt;

import dmangos.crypto.srp6 : sessionKeyLength;

/// Length of a server -> client header (`uint16` size, `uint16` opcode).
enum serverHeaderLength = 4;

/// Length of a client -> server header (`uint16` size, `uint32` opcode).
enum clientHeaderLength = 6;

/// Key-stream position for one direction.
struct CipherState
{
    private size_t i;
    private ubyte j;

    /// Encrypts `data` in place, continuing the stream.
    void encrypt(scope ubyte[] data, in ubyte[sessionKeyLength] key) pure nothrow @nogc @safe
    {
        foreach (ref b; data)
        {
            i %= key.length;
            const x = cast(ubyte)((b ^ key[i]) + j);
            ++i;
            b = j = x;
        }
    }

    /// Decrypts `data` in place, continuing the stream.
    void decrypt(scope ubyte[] data, in ubyte[sessionKeyLength] key) pure nothrow @nogc @safe
    {
        foreach (ref b; data)
        {
            i %= key.length;
            const x = cast(ubyte)((b - j) ^ key[i]);
            ++i;
            j = b;
            b = x;
        }
    }
}

/// The server's half: encrypts outgoing headers and decrypts incoming ones once a key is set.
struct HeaderCrypt
{
    private ubyte[sessionKeyLength] key;
    private CipherState sending, receiving;
    private bool enabled;

    /// Whether headers are being encrypted (from the auth response onwards).
    @property bool active() const pure nothrow @nogc @safe
    {
        return enabled;
    }

    /// Starts encrypting with the session key `K`.
    void initialize(in ubyte[sessionKeyLength] sessionKey) pure nothrow @nogc @safe
    {
        key = sessionKey;
        sending = CipherState.init;
        receiving = CipherState.init;
        enabled = true;
    }

    /// Encrypts a server header in place; a no-op before `initialize`.
    void encryptHeader(scope ubyte[] header) pure nothrow @nogc @safe
    in (header.length == serverHeaderLength)
    {
        if (enabled)
            sending.encrypt(header, key);
    }

    /// Decrypts a client header in place; a no-op before `initialize`.
    void decryptHeader(scope ubyte[] header) pure nothrow @nogc @safe
    in (header.length == clientHeaderLength)
    {
        if (enabled)
            receiving.decrypt(header, key);
    }
}

@safe unittest
{
    ubyte[sessionKeyLength] key;
    foreach (i, ref b; key)
        b = cast(ubyte)(i * 7 + 3);

    // What a client encrypts, the server's receiving state decrypts, packet after packet.
    CipherState client;
    HeaderCrypt server;
    server.initialize(key);
    foreach (packet; 0 .. 20)
    {
        ubyte[clientHeaderLength] header = [0, 8, cast(ubyte) packet, 0x01, 0, 0];
        const original = header;
        client.encrypt(header, key);
        assert(header != original);
        server.decryptHeader(header);
        assert(header == original);
    }

    // And the reverse direction.
    CipherState clientReceive;
    foreach (packet; 0 .. 20)
    {
        ubyte[serverHeaderLength] header = [0, 6, 0xDD, cast(ubyte) packet];
        const original = header;
        server.encryptHeader(header);
        clientReceive.decrypt(header, key);
        assert(header == original);
    }
}

@safe unittest
{
    // Before initialize headers pass through untouched.
    HeaderCrypt crypt;
    ubyte[serverHeaderLength] header = [1, 2, 3, 4];
    crypt.encryptHeader(header);
    const ubyte[serverHeaderLength] same = [1, 2, 3, 4];
    assert(header == same && !crypt.active);
}
