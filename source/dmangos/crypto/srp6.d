/**
 * SRP6, the password-authenticated key exchange used by the 1.x login protocol.
 *
 * This follows the client's variant of SRP6:
 *
 * $(UL
 *   $(LI every number travels as a little-endian byte string;)
 *   $(LI `k` is 3 and `g` is 7;)
 *   $(LI `x = H(s, H(normalize(user) ":" normalize(pass)))`, see `normalizeCredential`;)
 *   $(LI the session key `K` is the 40-byte "SHA interleave" of `S`;)
 *   $(LI `M1 = H(H(N) xor H(g), H(user), s, A, B, K)` and `M2 = H(A, M1, K)`.)
 * )
 *
 * The constants are decoded from hex at compile time. The unit tests check
 * the whole exchange against vectors from an independent Python
 * implementation.
 */
module dmangos.crypto.srp6;

import std.bigint : BigInt, powmod;
import std.typecons : Nullable, nullable;

import dmangos.crypto.bignum;
import dmangos.crypto.hash;
import dmangos.crypto.random : secureRandom;
import dmangos.hex : hexLiteral;

enum size_t saltLength = 32;       /// Length of the salt `s`.
enum size_t keyLength = 32;        /// Length of `N`, `A`, `B` and `v`.
enum size_t privateKeyLength = 19; /// Length of the private ephemerals `a` and `b`.
enum size_t sessionKeyLength = 40; /// Length of the session key `K`.
enum size_t proofLength = sha1Length; /// Length of `M1` and `M2`.

/// The safe prime N, big-endian, as it appears in every reference implementation.
private enum primeHex = "894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7";

private ubyte[N] reversed(size_t N)(ubyte[N] bytes) pure nothrow @nogc @safe
{
    import std.algorithm.mutation : reverse;

    bytes[].reverse();
    return bytes;
}

/// N in the little-endian order used on the wire. Computed by the compiler.
immutable ubyte[keyLength] primeBytes = reversed(hexLiteral!primeHex);

static assert(primeBytes[0] == 0xB7 && primeBytes[$ - 1] == 0x89);

/// The generator g.
enum ubyte generator = 7;

/// g as the single byte that is hashed and sent to the client.
immutable ubyte[1] generatorBytes = [generator];

/// The SRP6 multiplier k.
private enum ubyte multiplier = 3;

private BigInt prime() @safe
{
    return fromLittleEndian(primeBytes[]);
}

/**
 * Case-folds an account name or password the way the client does, and the
 * stored verifiers expect: Latin letters are upper-cased, and
 * every other character is left alone.
 */
string normalizeCredential(string text) pure @safe
{
    import std.uni : toUpper;
    import std.utf : toUTF8;

    dchar[] folded;
    foreach (dchar c; text)
        folded ~= c < 0x0250 ? toUpper(c) : c; // Basic Latin through Latin Extended-B
    return folded.toUTF8;
}

///
@safe unittest
{
    assert(normalizeCredential("Thrall_99") == "THRALL_99");
    assert(normalizeCredential("Müller") == "MÜLLER");
    assert(normalizeCredential("Дмитрий") == "Дмитрий"); // Cyrillic is not folded
}

/// Computes the verifier `v = g^x mod N` stored for an account in place of its password.
ubyte[keyLength] computeVerifier(string username, string password, in ubyte[saltLength] salt) @safe
{
    const credentials = sha1(normalizeCredential(username), ":", normalizeCredential(password));
    const xHash = sha1(salt, credentials);
    auto x = fromLittleEndian(xHash[]);
    return toFixedLittleEndian!keyLength(powmod(BigInt(generator), x, prime()));
}

/**
 * Derives the 40-byte session key from `S`, as the client does.
 *
 * Zero bytes at the start of the little-endian `S` are dropped, plus one
 * more byte if that leaves an odd count. The even-indexed and odd-indexed
 * bytes are then hashed separately and the two digests are interleaved.
 */
ubyte[sessionKeyLength] interleaveHash(in ubyte[keyLength] S) @safe
{
    size_t skip = 0;
    while (skip < S.length && S[skip] == 0)
        ++skip;
    if ((S.length - skip) % 2)
        ++skip;

    immutable half = (S.length - skip) / 2;
    ubyte[keyLength / 2] even, odd;
    foreach (i; 0 .. half)
    {
        even[i] = S[skip + 2 * i];
        odd[i] = S[skip + 2 * i + 1];
    }

    const evenHash = sha1(even[0 .. half]);
    const oddHash = sha1(odd[0 .. half]);
    ubyte[sessionKeyLength] key;
    foreach (i; 0 .. proofLength)
    {
        key[2 * i] = evenHash[i];
        key[2 * i + 1] = oddHash[i];
    }
    return key;
}

/// The client's proof `M1 = H(H(N) xor H(g), H(user), s, A, B, K)`.
ubyte[proofLength] computeClientProof(string username, in ubyte[saltLength] salt,
    in ubyte[keyLength] clientPublicKey, in ubyte[keyLength] serverPublicKey,
    in ubyte[sessionKeyLength] sessionKey) @safe
{
    const primeHash = sha1(primeBytes);
    const generatorHash = sha1(generatorBytes);
    ubyte[proofLength] mixed = primeHash[] ^ generatorHash[];
    const userHash = sha1(username);
    return sha1(mixed, userHash, salt, clientPublicKey, serverPublicKey, sessionKey);
}

/// The proof `H(user, R1, challenge, K)` a client sends when it reconnects with a known session key.
ubyte[proofLength] computeReconnectProof(string username, in ubyte[16] clientData,
    in ubyte[16] serverChallenge, in ubyte[sessionKeyLength] sessionKey) @safe
{
    return sha1(username, clientData, serverChallenge, sessionKey);
}

/// What the server learns from a successful handshake.
struct Srp6Session
{
    ubyte[sessionKeyLength] sessionKey; /// K, later handed to the world server.
    ubyte[proofLength] serverProof;     /// M2, proves to the client that the server knows v.
}

/// Server side of the handshake: send `publicKey` (B), then check the client's proof with `verify`.
struct Srp6Server
{
    private
    {
        string username;
        ubyte[saltLength] salt;
        BigInt verifier;
        BigInt privateKey;
        ubyte[keyLength] publicKey_;
    }

    /// Starts a handshake for an account using a fresh random private key `b`.
    this(string username, in ubyte[saltLength] salt, in ubyte[keyLength] verifier) @safe
    {
        this(username, salt, verifier, secureRandom!privateKeyLength);
    }

    /// Starts a handshake with a caller-chosen private key. Only tests should need this.
    this(string username, in ubyte[saltLength] salt, in ubyte[keyLength] verifier,
        in ubyte[privateKeyLength] privateKey) @safe
    in (username.length > 0, "username must not be empty")
    {
        this.username = normalizeCredential(username);
        this.salt = salt;
        this.verifier = fromLittleEndian(verifier[]);
        this.privateKey = fromLittleEndian(privateKey[]);

        auto N = prime();
        auto B = (this.verifier * multiplier + powmod(BigInt(generator), this.privateKey, N)) % N;
        publicKey_ = toFixedLittleEndian!keyLength(B);
    }

    /// B, the server's public ephemeral value.
    @property ubyte[keyLength] publicKey() const pure nothrow @nogc @safe
    {
        return publicKey_;
    }

    /**
     * Checks the client's public key `A` and proof `M1`.
     *
     * Returns: the session key and the server proof `M2`, or null if the
     * password was wrong or `A` is degenerate.
     */
    Nullable!Srp6Session verify(in ubyte[keyLength] clientPublicKey, in ubyte[proofLength] clientProof) @safe
    {
        auto N = prime();
        auto A = fromLittleEndian(clientPublicKey[]);
        if (A % N == 0)
            return typeof(return).init; // A ≡ 0 would force S = 0 regardless of the password

        const scramblerHash = sha1(clientPublicKey, publicKey_);
        auto u = fromLittleEndian(scramblerHash[]);
        if (u == 0)
            return typeof(return).init;

        auto S = powmod(A * powmod(verifier, u, N), privateKey, N);
        const K = interleaveHash(toFixedLittleEndian!keyLength(S));
        const M1 = computeClientProof(username, salt, clientPublicKey, publicKey_, K);
        if (!constantTimeEqual(M1[], clientProof[]))
            return typeof(return).init;

        return nullable(Srp6Session(K, sha1(clientPublicKey, M1, K)));
    }
}

/// What a client computes in response to the server's challenge.
struct Srp6ClientProof
{
    ubyte[sessionKeyLength] sessionKey;      /// K
    ubyte[proofLength] clientProof;          /// M1, sent to the server
    ubyte[proofLength] expectedServerProof;  /// M2 the server must answer with
}

/// Client side of the handshake. Used by tests, and later by test clients and bots.
struct Srp6Client
{
    private
    {
        string username;
        string password;
        BigInt privateKey;
        ubyte[keyLength] publicKey_;
    }

    ///
    this(string username, string password, in ubyte[privateKeyLength] privateKey) @safe
    {
        this.username = normalizeCredential(username);
        this.password = normalizeCredential(password);
        this.privateKey = fromLittleEndian(privateKey[]);
        publicKey_ = toFixedLittleEndian!keyLength(powmod(BigInt(generator), this.privateKey, prime()));
    }

    /// A, the client's public ephemeral value.
    @property ubyte[keyLength] publicKey() const pure nothrow @nogc @safe
    {
        return publicKey_;
    }

    /// Computes the session key and proof for the server's salt and public key `B`.
    Srp6ClientProof respond(in ubyte[saltLength] salt, in ubyte[keyLength] serverPublicKey) @safe
    {
        auto N = prime();
        auto B = fromLittleEndian(serverPublicKey[]);

        const scramblerHash = sha1(publicKey_, serverPublicKey);
        auto u = fromLittleEndian(scramblerHash[]);
        const credentials = sha1(username, ":", password);
        const xHash = sha1(salt, credentials);
        auto x = fromLittleEndian(xHash[]);

        auto base = (B - powmod(BigInt(generator), x, N) * multiplier) % N;
        if (base < 0)
            base += N;
        auto S = powmod(base, privateKey + u * x, N);

        Srp6ClientProof result;
        result.sessionKey = interleaveHash(toFixedLittleEndian!keyLength(S));
        result.clientProof = computeClientProof(username, salt, publicKey_, serverPublicKey, result.sessionKey);
        result.expectedServerProof = sha1(publicKey_, result.clientProof, result.sessionKey);
        return result;
    }
}

version (unittest)
{
    private ubyte[N] sequence(size_t N)(ubyte start) pure nothrow @safe
    {
        ubyte[N] bytes;
        foreach (i, ref b; bytes)
            b = cast(ubyte)(start + i);
        return bytes;
    }
}

/// Known-answer test against an independent Python implementation of the same algorithm.
@safe unittest
{
    const salt = sequence!saltLength(1);
    const serverKey = sequence!privateKeyLength(0x40);
    const clientKey = sequence!privateKeyLength(0x80);

    const verifier = computeVerifier("test", "password", salt);
    assert(verifier == hexLiteral!"60A1AA193FC9979D28B2F4D007CE29D1B98FB2A7748DF8AAEE08D88683E4ED74");

    auto server = Srp6Server("TEST", salt, verifier, serverKey);
    assert(server.publicKey == hexLiteral!"F204C3331DC0FE6272B84E001B6184949A919FE1E53171FDC7ED961DD56D411A");

    auto client = Srp6Client("test", "password", clientKey);
    assert(client.publicKey == hexLiteral!"78FEE5C4DDB5E8C613E8160322190F27769AF7D0A3CAA1D371D0E8624D215C17");

    const answer = client.respond(salt, server.publicKey);
    assert(answer.sessionKey == hexLiteral!(
        "7404B45F948B00BCD8AA1C020CF2D00DBF666A721616F00F0C9F904A33A5CC7B2C60C8AECA915543"));
    assert(answer.clientProof == hexLiteral!"9B4584A71498D82BBA7966DDA925D78E96D42061");

    const session = server.verify(client.publicKey, answer.clientProof);
    assert(!session.isNull);
    assert(session.get.sessionKey == answer.sessionKey);
    assert(session.get.serverProof == hexLiteral!"E90C2757F5616CF2119E415AF3C5BDFC42C7D8E8");
    assert(session.get.serverProof == answer.expectedServerProof);
}

/// Random handshakes succeed with the right password and fail with a wrong one.
@safe unittest
{
    const salt = secureRandom!saltLength;
    const verifier = computeVerifier("Arthas", "frostmourne", salt);

    foreach (attempt; 0 .. 8)
    {
        auto server = Srp6Server("ARTHAS", salt, verifier);
        auto good = Srp6Client("arthas", "FrostMourne", secureRandom!privateKeyLength);
        const goodAnswer = good.respond(salt, server.publicKey);
        const accepted = server.verify(good.publicKey, goodAnswer.clientProof);
        assert(!accepted.isNull);
        assert(accepted.get.sessionKey == goodAnswer.sessionKey);

        auto bad = Srp6Client("arthas", "ashbringer", secureRandom!privateKeyLength);
        const badAnswer = bad.respond(salt, server.publicKey);
        assert(server.verify(bad.publicKey, badAnswer.clientProof).isNull);
    }
}

/// A degenerate client key (A ≡ 0 mod N) is rejected outright.
@safe unittest
{
    const salt = secureRandom!saltLength;
    auto server = Srp6Server("TEST", salt, computeVerifier("test", "test", salt));
    const ubyte[proofLength] anyProof;
    const ubyte[keyLength] zero;
    assert(server.verify(zero, anyProof).isNull);
    assert(server.verify(primeBytes, anyProof).isNull);
}

/// The interleave drops low-order zero bytes, and one more byte when that leaves an odd count.
@safe unittest
{
    ubyte[keyLength] S = sequence!keyLength(1);
    const full = interleaveHash(S);
    S[0] = 0; // 31 bytes left: odd, so the next byte is dropped as well
    const trimmed = interleaveHash(S);
    assert(full != trimmed);

    ubyte[keyLength] shifted = S;
    shifted[1] = 0x55; // that byte is skipped, so changing it must not matter
    assert(interleaveHash(shifted) == trimmed);
}
