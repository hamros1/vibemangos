/**
 * Accounts as the login server sees them, plus the way their credentials are
 * stored.
 *
 * In the `account` table, the salt `s`, verifier `v` and session key
 * `sessionkey` are OpenSSL `BN_bn2hex` strings. Each is the big-endian hex
 * of the number whose little-endian bytes go over the wire.
 * `decodeBigNumberHex` and `encodeBigNumberHex` convert between the two. This
 * is the CMaNGOS `realmd` format, so accounts created by CMaNGOS and by
 * dmangos work interchangeably.
 */
module dmangos.auth.accounts;

import std.typecons : Nullable, nullable;

import dmangos.crypto.hash : sha1;
import dmangos.crypto.random : secureRandom;
import dmangos.crypto.srp6 : computeVerifier, keyLength, normalizeCredential, saltLength, sessionKeyLength;
import dmangos.hex : parseHex, toHex;

/// Longest account name, in characters.
enum maxAccountNameLength = 16;

/// Longest password, in characters.
enum maxPasswordLength = 16;

/// Staff rank projected from role capabilities for visibility and character creation.
enum AccountLevel : ubyte
{
    player,        /// 0
    moderator,     /// 1
    gameMaster,    /// 2
    administrator, /// 3
}

/// Decodes a realm’s configured staff rank threshold.
AccountLevel toAccountLevel(uint rank) pure nothrow @nogc @safe
{
    return rank >= AccountLevel.administrator ? AccountLevel.administrator : cast(AccountLevel) rank;
}

/// Whether an account may log in, according to `account_banned`.
enum BanState
{
    none,
    suspended, /// a ban with an end date that has not passed yet
    banned,    /// a permanent ban (`expires_at = banned_at`)
}

/// An account and everything the login handshake needs to know about it.
struct Account
{
    uint id;
    string username;
    ubyte[saltLength] salt;
    ubyte[keyLength] verifier;
    bool credentialsValid;  /// False if the stored `s`/`v` cannot be decoded.
    ubyte[] sessionKey;     /// K from the last login; empty if there is none.
    bool locked;            /// If set, logins are only accepted from `lockedIp`.
    string lockedIp;
    uint failedLogins;
    BanState ban;

    pure nothrow @nogc @safe invariant ()
    {
        assert(sessionKey.length == 0 || sessionKey.length == sessionKeyLength,
            "a stored session key is always 40 bytes");
    }
}

/// Client details recorded at login (`account.locale`, `os`, `platform`).
struct ClientDetails
{
    string locale;   /// e.g. "enUS"
    string os;       /// e.g. "Win"
    string platform; /// e.g. "x86"
}

/// Account names are stored upper-cased (Latin letters only); see `normalizeCredential`.
alias canonicalAccountName = normalizeCredential;

/// Whether `name` is acceptable as an account name: 1-16 characters, valid UTF-8, no control characters.
bool isValidAccountName(scope const(char)[] name) pure @safe
{
    import std.utf : byDchar, UTFException, validate;

    try
        validate(name);
    catch (UTFException)
        return false;

    size_t length;
    foreach (dchar c; name.byDchar)
    {
        if (c < 0x20 || c == 0x7F)
            return false;
        ++length;
    }
    return length > 0 && length <= maxAccountNameLength;
}

/// Whether `password` is within the length limits.
bool isValidPassword(scope const(char)[] password) pure @safe
{
    import std.range : walkLength;
    import std.utf : byDchar;

    const length = password.byDchar.walkLength;
    return length > 0 && length <= maxPasswordLength;
}

/**
 * Decodes a `BN_bn2hex` string into `N` little-endian bytes.
 *
 * Returns: null if the text is empty, not hex, too large for `N` bytes, or
 * zero. All of these are broken credentials.
 */
Nullable!(ubyte[N]) decodeBigNumberHex(size_t N)(scope const(char)[] hex) pure @safe
{
    import std.conv : ConvException;

    if (hex.length == 0)
        return typeof(return).init;
    const(char)[] digits = hex.length % 2 ? "0" ~ hex : hex;
    while (digits.length > 2 * N && digits[0 .. 2] == "00")
        digits = digits[2 .. $];
    if (digits.length > 2 * N)
        return typeof(return).init;

    ubyte[] bigEndian;
    try
        bigEndian = parseHex(digits);
    catch (ConvException)
        return typeof(return).init;

    ubyte[N] littleEndian;
    bool nonZero;
    foreach (i, b; bigEndian)
    {
        littleEndian[bigEndian.length - 1 - i] = b;
        nonZero |= b != 0;
    }
    return nonZero ? nullable(littleEndian) : typeof(return).init;
}

/**
 * Encodes little-endian bytes as `BN_bn2hex` does: big-endian, upper-case,
 * without leading zero bytes. The result is left-padded with '0' to at least
 * `minDigits` characters; the session key is padded to 80.
 */
string encodeBigNumberHex(scope const(ubyte)[] littleEndian, size_t minDigits = 0) pure @safe
{
    import std.algorithm.mutation : reverse, stripRight;
    import std.string : rightJustify;

    auto bigEndian = littleEndian.stripRight(ubyte(0)).dup;
    bigEndian.reverse();
    const hex = toHex(bigEndian).rightJustify(minDigits, '0');
    return hex.length ? hex : "0";
}

/// A random salt shaped like OpenSSL's `BN_rand(256, 0, 1)`: the top bit is set and the value is odd.
ubyte[saltLength] generateSalt() @safe
{
    return shapedLikeSalt(secureRandom!saltLength);
}

/// Sets the bits that `BN_rand(256, 0, 1)` always sets: the top one, and the bottom one (odd).
private ubyte[saltLength] shapedLikeSalt(ubyte[saltLength] salt) pure nothrow @nogc @safe
{
    salt[$ - 1] |= 0x80;
    salt[0] |= 0x01;
    return salt;
}

/// Salt and verifier to store for a new password.
struct Credentials
{
    ubyte[saltLength] salt;
    ubyte[keyLength] verifier;

    /// The `s` column value.
    @property string saltHex() const pure @safe
    {
        return encodeBigNumberHex(salt);
    }

    /// The `v` column value.
    @property string verifierHex() const pure @safe
    {
        return encodeBigNumberHex(verifier);
    }
}

/// Creates fresh credentials for `username`/`password`.
Credentials makeCredentials(string username, string password) @safe
{
    Credentials credentials;
    credentials.salt = generateSalt();
    credentials.verifier = computeVerifier(username, password, credentials.salt);
    return credentials;
}

/**
 * Credentials for an account that does not exist. They are stable for a
 * given name and never match any password.
 *
 * Answering such a challenge normally instead of with "unknown account"
 * keeps account names from being enumerated. They are tagged SHA-1 blocks of
 * (secret, name), with the salt shaped like a real one.
 */
Credentials fakeCredentials(in ubyte[20] secret, string canonicalName) @safe
{
    static ubyte[32] expand(in ubyte[20] secret, string name, string tag) @safe
    {
        ubyte[] output;
        for (ubyte counter = 0; output.length < 32; ++counter)
        {
            const ubyte[1] counterByte = [counter];
            const block = sha1(secret, name, tag, counterByte);
            output ~= block[];
        }
        ubyte[32] result = output[0 .. 32];
        return result;
    }

    Credentials credentials;
    credentials.verifier = expand(secret, canonicalName, "v");
    credentials.salt = shapedLikeSalt(expand(secret, canonicalName, "s"));
    return credentials;
}

/// The sample accounts that ship in the schema's `realmd.sql` (password = name) must verify.
@safe unittest
{
    static immutable string[3][] rows = [
        ["ADMINISTRATOR", "312B99EEF1C0196BB73B79D114CE161C5D089319E6EF54FAA6117DAB8B672C14",
            "8EB5DE915AA3D805FA7099CF61C0BB8A77990EA869078A0C5B9EEE55828F4505"],
        ["PLAYER", "3738EC7E7C731FD431C716990C6D97CA5C1D50EF0DA7DE9819076DE1D03AA891",
            "EBA23AF194D89B8061CA7FEBA06D336B1C38D8FBDABA76F2C51D45141362D881"],
    ];
    foreach (row; rows)
    {
        const salt = decodeBigNumberHex!saltLength(row[2]);
        const verifier = decodeBigNumberHex!keyLength(row[1]);
        assert(!salt.isNull && !verifier.isNull);
        assert(computeVerifier(row[0], row[0], salt.get) == verifier.get);
        assert(encodeBigNumberHex(salt.get) == row[2]);
        assert(encodeBigNumberHex(verifier.get) == row[1]);
    }
}

@safe unittest
{
    // Short (leading-zero-stripped) and padded forms decode to the same value.
    const short_ = decodeBigNumberHex!4("ABC");
    const padded = decodeBigNumberHex!4("00000ABC");
    assert(!short_.isNull && short_.get == padded.get);
    const ubyte[4] expected = [0xBC, 0x0A, 0, 0];
    assert(short_.get == expected);
    assert(encodeBigNumberHex(expected) == "0ABC");
    assert(encodeBigNumberHex(expected, 10) == "0000000ABC");

    assert(decodeBigNumberHex!4("").isNull);
    assert(decodeBigNumberHex!4("00").isNull);         // zero
    assert(decodeBigNumberHex!4("123456789A").isNull); // too large
    assert(decodeBigNumberHex!4("XYZ").isNull);
}

@safe unittest
{
    const salt = generateSalt();
    assert(salt[$ - 1] & 0x80 && salt[0] & 1);
    assert(encodeBigNumberHex(salt).length == 64);

    const ubyte[20] secret = 3;
    const a = fakeCredentials(secret, "NOBODY");
    assert(a == fakeCredentials(secret, "NOBODY"), "fake credentials must be stable");
    assert(a != fakeCredentials(secret, "SOMEBODY"));
    assert(a.salt[$ - 1] & 0x80 && a.salt[0] & 1);

    assert(isValidAccountName("Player_1") && isValidAccountName("Müller"));
    assert(!isValidAccountName("") && !isValidAccountName("ABCDEFGHIJKLMNOPQ") && !isValidAccountName("a\nb"));
    assert(toAccountLevel(7) == AccountLevel.administrator);
}
