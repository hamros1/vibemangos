/**
 * Character name rules, as in CMaNGOS's `normalizePlayerName`,
 * `ObjectMgr::CheckPlayerName` and `isValidString`.
 */
module dmangos.world.names;

import std.utf : toUTF32, toUTF8, UTFException, validate;

import dmangos.world.worlddata : wcharToLower, wcharToUpper;

/// The longest name the client accepts (`MAX_PLAYER_NAME`).
enum maxPlayerName = 12;
/// The longest name normalization accepts (`MAX_INTERNAL_PLAYER_NAME`).
enum maxInternalPlayerName = 15;

/// `ResponseCodes` for names (`CHAR_NAME_*`).
enum CharNameResult : ubyte
{
    CHAR_NAME_SUCCESS = 0x50,
    CHAR_NAME_FAILURE = 0x4F,
    CHAR_NAME_NO_NAME = 0x43,
    CHAR_NAME_TOO_SHORT = 0x44,
    CHAR_NAME_TOO_LONG = 0x45,
    CHAR_NAME_INVALID_CHARACTER = 0x46,
    CHAR_NAME_MIXED_LANGUAGES = 0x47,
    CHAR_NAME_PROFANE = 0x48,
    CHAR_NAME_RESERVED = 0x49,
}

/**
 * `normalizePlayerName`: first letter upper case, the rest lower case.
 * Returns false for an empty, invalid or overlong (> 15 characters) name.
 */
bool normalizePlayerName(ref string name, size_t maxLength = maxInternalPlayerName) @safe
{
    if (name.length == 0)
        return false;
    try
        validate(name);
    catch (UTFException)
        return false;
    auto text = name.toUTF32.dup;
    if (text.length > maxLength)
        return false;
    text[0] = wcharToUpper(text[0]);
    foreach (ref c; text[1 .. $])
        c = wcharToLower(c);
    name = text.toUTF8;
    return true;
}

/// `ObjectMgr::CheckPlayerName` for a new character.
CharNameResult checkPlayerName(string name, uint minLength, uint strictMask, uint realmZone) @safe
{
    dstring text;
    try
        text = name.toUTF32;
    catch (UTFException)
        return CharNameResult.CHAR_NAME_INVALID_CHARACTER;
    if (text.length > maxPlayerName)
        return CharNameResult.CHAR_NAME_TOO_LONG;
    if (text.length < minLength)
        return CharNameResult.CHAR_NAME_TOO_SHORT;
    if (!isValidName(text, strictMask, realmZone))
        return CharNameResult.CHAR_NAME_MIXED_LANGUAGES;
    return CharNameResult.CHAR_NAME_SUCCESS;
}

private enum : uint
{
    ltBasicLatin = 0x00,
    ltExtendedLatin = 0x01,
    ltCyrillic = 0x02,
    ltEastAsia = 0x04,
    ltAny = 0xFFFF,
}

/// `GetRealmLanguageType(create = true)`, by `RealmZone`.
private uint realmLanguageType(uint realmZone) pure nothrow @nogc @safe
{
    switch (realmZone)
    {
    case 0, 1, 26, 28: // unknown, development, test, QA
        return ltAny;
    case 2, 3, 4, 8, 9, 10, 11: // US, oceanic, Latin America, English, German, French, Spanish
        return ltExtendedLatin;
    case 6, 14, 16: // Korea, Taiwan, China
        return ltEastAsia;
    case 12: // Russian
        return ltCyrillic;
    default:
        return ltBasicLatin;
    }
}

/// `isValidString` without the numeric-or-space allowance (names never allow it).
private bool isValidName(dstring text, uint strictMask, uint realmZone) pure nothrow @nogc @safe
{
    if (strictMask == 0)
        return all!isExtendedLatin(text) || all!isCyrillic(text) || all!isEastAsian(text);
    if (strictMask & 0x2)
    {
        const language = realmLanguageType(realmZone);
        if ((language & ltExtendedLatin) && all!isExtendedLatin(text))
            return true;
        if ((language & ltCyrillic) && all!isCyrillic(text))
            return true;
        if ((language & ltEastAsia) && all!isEastAsian(text))
            return true;
    }
    if (strictMask & 0x1)
        return all!isBasicLatin(text);
    return false;
}

private bool all(alias predicate)(dstring text) pure nothrow @nogc @safe
{
    foreach (c; text)
        if (!predicate(c))
            return false;
    return true;
}

/// `isBasicLatinCharacter`
bool isBasicLatin(dchar c) pure nothrow @nogc @safe
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/// `isExtendedLatinCharacter`
bool isExtendedLatin(dchar c) pure nothrow @nogc @safe
{
    return isBasicLatin(c) || (c >= 0x00C0 && c <= 0x00D6) || (c >= 0x00D8 && c <= 0x00DF)
        || (c >= 0x00E0 && c <= 0x00F6) || (c >= 0x00F8 && c <= 0x00FE) || (c >= 0x0100 && c <= 0x012F)
        || c == 0x1E9E;
}

/// `isCyrillicCharacter`
bool isCyrillic(dchar c) pure nothrow @nogc @safe
{
    return (c >= 0x0410 && c <= 0x044F) || c == 0x0401 || c == 0x0451;
}

/// `isEastAsianCharacter`
bool isEastAsian(dchar c) pure nothrow @nogc @safe
{
    return (c >= 0x1100 && c <= 0x11F9) || (c >= 0x3041 && c <= 0x30FF) || (c >= 0x3131 && c <= 0x318E)
        || (c >= 0x31F0 && c <= 0x31FF) || (c >= 0x3400 && c <= 0x4DB5) || (c >= 0x4E00 && c <= 0x9FC3)
        || (c >= 0xAC00 && c <= 0xD7A3) || (c >= 0xFF01 && c <= 0xFFEE);
}

@safe unittest
{
    string name = "tHRALL";
    assert(normalizePlayerName(name) && name == "Thrall");
    string german = "äRGER";
    assert(normalizePlayerName(german) && german == "Ärger");
    string empty;
    assert(!normalizePlayerName(empty));
    string overlong = "Abcdefghijklmnop";
    assert(!normalizePlayerName(overlong));

    with (CharNameResult)
    {
        assert(checkPlayerName("Thrall", 2, 0, 1) == CHAR_NAME_SUCCESS);
        assert(checkPlayerName("A", 2, 0, 1) == CHAR_NAME_TOO_SHORT);
        assert(checkPlayerName("Abcdefghijklm", 2, 0, 1) == CHAR_NAME_TOO_LONG);
        assert(checkPlayerName("Thr4ll", 2, 0, 1) == CHAR_NAME_MIXED_LANGUAGES);
        assert(checkPlayerName("Thrаll", 2, 0, 1) == CHAR_NAME_MIXED_LANGUAGES, "a Cyrillic 'а' among Latin letters");
        assert(checkPlayerName("Дмитрий", 2, 0, 1) == CHAR_NAME_SUCCESS);
        assert(checkPlayerName("Ärger", 2, 1, 1) == CHAR_NAME_MIXED_LANGUAGES, "strict basic Latin rejects umlauts");
        assert(checkPlayerName("Ärger", 2, 2, 9) == CHAR_NAME_SUCCESS, "a German realm allows extended Latin");
        assert(checkPlayerName("Дмитрий", 2, 2, 9) == CHAR_NAME_MIXED_LANGUAGES);
    }
}
