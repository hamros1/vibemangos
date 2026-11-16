/**
 * Maps structs to and from JSON using compile-time introspection.
 *
 * Fields map to keys of the same name unless they carry `@JsonName("key")`.
 * Keys missing from the input leave the field at its default, so a struct's
 * initializers serve as the configuration defaults. Enums are written by
 * member name. Byte arrays (`ubyte[N]` and `ubyte[]`) are written as hex
 * strings.
 */
module dmangos.json;

import std.conv : ConvOverflowException, to;
import std.exception : basicExceptionCtors;
import std.json : JSONType, JSONValue;
import std.traits : getUDAs, hasUDA, isArray, isDynamicArray, isFloatingPoint, isIntegral,
    isSomeString, isStaticArray, Unqual;

import dmangos.hex : parseHex, parseHexFixed, toHex;

/// Overrides the JSON key of a field.
struct JsonName
{
    string name;
}

/// Thrown when a JSON document does not match the structure it is mapped onto.
class JsonMappingException : Exception
{
    mixin basicExceptionCtors;
}

private template jsonKey(alias field)
{
    static if (hasUDA!(field, JsonName))
        enum jsonKey = getUDAs!(field, JsonName)[0].name;
    else
        enum jsonKey = __traits(identifier, field);
}

private enum isByteArray(T) = isArray!T && is(Unqual!(typeof(T.init[0])) == ubyte);

/// Converts `value` to JSON.
JSONValue toJson(T)(auto ref const T value)
{
    static if (is(T == struct))
    {
        JSONValue[string] fields;
        static foreach (i; 0 .. T.tupleof.length)
            fields[jsonKey!(T.tupleof[i])] = toJson(value.tupleof[i]);
        return JSONValue(fields);
    }
    else static if (is(T == enum))
        return JSONValue(value.to!string);
    else static if (is(T == bool))
        return JSONValue(value);
    else static if (isIntegral!T)
        return JSONValue(cast(long) value);
    else static if (isFloatingPoint!T)
        return JSONValue(cast(double) value);
    else static if (isSomeString!T)
        return JSONValue(value.to!string);
    else static if (isByteArray!T)
        return JSONValue(toHex(value[]));
    else static if (isArray!T)
    {
        JSONValue[] elements;
        foreach (ref element; value)
            elements ~= toJson(element);
        return JSONValue(elements);
    }
    else
        static assert(false, "cannot convert " ~ T.stringof ~ " to JSON");
}

/// Builds a `T` from JSON, throwing `JsonMappingException` on a structural mismatch.
T fromJson(T)(const JSONValue json)
{
    static if (is(T == struct))
    {
        expectType(json, JSONType.object, T.stringof);
        T result;
        static foreach (i; 0 .. T.tupleof.length)
        {{
            enum key = jsonKey!(T.tupleof[i]);
            if (auto value = key in json.object)
                result.tupleof[i] = fromJson!(typeof(T.tupleof[i]))(*value);
        }}
        return result;
    }
    else static if (is(T == enum))
    {
        expectType(json, JSONType.string, T.stringof);
        // One comparison per member, generated at compile time.
        static foreach (member; __traits(allMembers, T))
            if (json.str == member)
                return __traits(getMember, T, member);
        throw new JsonMappingException("'" ~ json.str ~ "' is not a valid " ~ T.stringof);
    }
    else static if (is(T == bool))
    {
        if (json.type == JSONType.true_)
            return true;
        if (json.type == JSONType.false_)
            return false;
        throw new JsonMappingException("expected true or false, got " ~ json.toString);
    }
    else static if (isIntegral!T)
    {
        long value;
        if (json.type == JSONType.integer)
            value = json.integer;
        else if (json.type == JSONType.uinteger && json.uinteger <= long.max)
            value = cast(long) json.uinteger;
        else
            throw new JsonMappingException("expected an integer, got " ~ json.toString);

        T converted;
        try
            converted = value.to!T;
        catch (ConvOverflowException)
            throw new JsonMappingException(json.toString ~ " does not fit in " ~ T.stringof);
        return converted;
    }
    else static if (isFloatingPoint!T)
    {
        switch (json.type)
        {
        case JSONType.float_:
            return cast(T) json.floating;
        case JSONType.integer:
            return cast(T) json.integer;
        case JSONType.uinteger:
            return cast(T) json.uinteger;
        default:
            throw new JsonMappingException("expected a number, got " ~ json.toString);
        }
    }
    else static if (isSomeString!T)
    {
        expectType(json, JSONType.string, T.stringof);
        return json.str.to!T;
    }
    else static if (isByteArray!T && isStaticArray!T)
    {
        expectType(json, JSONType.string, T.stringof);
        return parseHexFixed!(T.length)(json.str);
    }
    else static if (isByteArray!T)
    {
        expectType(json, JSONType.string, T.stringof);
        return parseHex(json.str);
    }
    else static if (isDynamicArray!T)
    {
        expectType(json, JSONType.array, T.stringof);
        alias Element = typeof(T.init[0]);
        Element[] result;
        foreach (element; json.array)
            result ~= fromJson!Element(element);
        return result;
    }
    else
        static assert(false, "cannot read " ~ T.stringof ~ " from JSON");
}

private void expectType(const JSONValue json, JSONType type, string what)
{
    if (json.type != type)
        throw new JsonMappingException("expected " ~ type.to!string ~ " for " ~ what
            ~ ", got " ~ json.type.to!string);
}

version (unittest)
{
    private enum Mode
    {
        fast,
        safe,
    }

    private struct Nested
    {
        string label;
        ubyte[] blob;
    }

    private struct Settings
    {
        @JsonName("listen_port") ushort port = 3724;
        string host = "localhost";
        Mode mode = Mode.safe;
        bool enabled;
        float ratio = 0.5f;
        ubyte[4] key;
        Nested[] children;
        ushort[] numbers = [1, 2];
    }
}

unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;

    // Missing keys keep their defaults.
    auto partial = fromJson!Settings(parseJSON(`{"listen_port": 8000, "mode": "fast"}`));
    assert(partial.port == 8000);
    assert(partial.host == "localhost");
    assert(partial.mode == Mode.fast);
    const ushort[] defaultNumbers = [1, 2];
    assert(partial.numbers == defaultNumbers);

    Settings full;
    full.enabled = true;
    full.key = [0xDE, 0xAD, 0xBE, 0xEF];
    full.children = [Nested("a", [1, 2, 3]), Nested("b", null)];
    const json = toJson(full);
    assert(json["listen_port"].integer == 3724);
    assert(json["key"].str == "DEADBEEF");
    assert(fromJson!Settings(parseJSON(json.toString)) == full);

    assertThrown!JsonMappingException(fromJson!Settings(parseJSON(`{"listen_port": 70000}`)));
    assertThrown!JsonMappingException(fromJson!Settings(parseJSON(`{"mode": "reckless"}`)));
    assertThrown!JsonMappingException(fromJson!Settings(parseJSON(`{"host": 5}`)));
}
