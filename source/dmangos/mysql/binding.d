/**
 * The handful of MySQL C API functions dmangos needs, loaded at run time.
 *
 * Loading the client library with `dlopen` (or `LoadLibrary` on Windows),
 * instead of linking it, means the project builds and its tests run with no
 * MySQL development package installed. It also works unchanged with either
 * MariaDB Connector/C or Oracle's libmysqlclient, which share this part of
 * the API. Unlike a protocol reimplementation, it supports every
 * authentication plugin the installed client does, including MySQL 8's
 * default `caching_sha2_password`.
 *
 * Only opaque handles cross the boundary (no struct layouts are shared), so
 * the binding does not depend on the library version.
 *
 * The declarations live in one table. Mixins generate a C-linkage function
 * pointer type and a field for each entry, and the loader resolves every
 * field with a `static foreach`.
 */
module dmangos.mysql.binding;

import core.stdc.config : c_ulong;
import std.array : join;
import std.exception : enforce;
import std.string : fromStringz, toStringz;

/// Opaque connection handle.
struct MYSQL;
/// Opaque result set handle.
struct MYSQL_RES;
/// A row: an array of nullable, non-terminated column values.
alias MYSQL_ROW = char**;

/// `enum mysql_option` values (identical in MySQL and MariaDB).
enum MySqlOption : int
{
    connectTimeout = 0,
    setCharsetName = 7,
    readTimeout = 11,
    writeTimeout = 12,
}

/// Client error codes that mean the connection is gone and may be re-established.
enum : uint
{
    CR_SERVER_GONE_ERROR = 2006,
    CR_SERVER_LOST = 2013,
}

/// Name and C signature of every function used.
private enum string[2][] declarations = [
    ["mysql_init", "MYSQL* function(MYSQL*)"],
    ["mysql_options", "int function(MYSQL*, int, const(void)*)"],
    ["mysql_real_connect", "MYSQL* function(MYSQL*, const(char)*, const(char)*, const(char)*, const(char)*, uint, const(char)*, c_ulong)"],
    ["mysql_close", "void function(MYSQL*)"],
    ["mysql_errno", "uint function(MYSQL*)"],
    ["mysql_error", "const(char)* function(MYSQL*)"],
    ["mysql_real_escape_string", "c_ulong function(MYSQL*, char*, const(char)*, c_ulong)"],
    ["mysql_real_query", "int function(MYSQL*, const(char)*, c_ulong)"],
    ["mysql_store_result", "MYSQL_RES* function(MYSQL*)"],
    ["mysql_field_count", "uint function(MYSQL*)"],
    ["mysql_affected_rows", "ulong function(MYSQL*)"],
    ["mysql_insert_id", "ulong function(MYSQL*)"],
    ["mysql_num_fields", "uint function(MYSQL_RES*)"],
    ["mysql_fetch_row", "MYSQL_ROW function(MYSQL_RES*)"],
    ["mysql_fetch_lengths", "c_ulong* function(MYSQL_RES*)"],
    ["mysql_free_result", "void function(MYSQL_RES*)"],
    ["mysql_get_client_info", "const(char)* function()"],
];

// One C-linkage function pointer type per declaration, e.g. `Fn_mysql_init`.
static foreach (declaration; declarations)
    mixin("extern (C) nothrow @nogc alias Fn_" ~ declaration[0] ~ " = " ~ declaration[1] ~ ";");

/// The loaded entry points, one field per declaration.
struct MySqlApi
{
    static foreach (declaration; declarations)
        mixin("Fn_" ~ declaration[0] ~ " " ~ declaration[0] ~ ";");
}

static assert(MySqlApi.tupleof.length == declarations.length);

/// The process-wide API table. Valid once `loadMySqlLibrary` has returned.
__gshared MySqlApi mysql;

private __gshared string loadedFrom;

/// Library names tried when no explicit path is configured, most common first.
version (Windows)
    immutable string[] defaultLibraryNames = ["libmariadb.dll", "libmysql.dll"];
else version (OSX)
    immutable string[] defaultLibraryNames = ["libmariadb.3.dylib", "libmysqlclient.dylib", "libmariadb.dylib"];
else
    immutable string[] defaultLibraryNames = [
        "libmariadb.so.3", "libmysqlclient.so.24", "libmysqlclient.so.21", "libmysqlclient.so.20",
        "libmysqlclient.so.18", "libmariadb.so", "libmysqlclient.so",
    ];

/**
 * Loads the client library. `path` overrides the default search when not empty.
 * Calling it again after a successful load does nothing.
 *
 * Returns: the name of the library that was loaded.
 */
string loadMySqlLibrary(string path = null)
{
    if (loadedFrom !is null)
        return loadedFrom;

    const candidates = path.length ? [path] : defaultLibraryNames;
    void* handle;
    string chosen;
    foreach (candidate; candidates)
    {
        handle = openLibrary(candidate);
        if (handle !is null)
        {
            chosen = candidate;
            break;
        }
    }
    enforce(handle !is null, "could not load a MySQL client library (tried "
        ~ candidates.join(", ") ~ "); install libmariadb3 or libmysqlclient, or set mysql_library");

    MySqlApi api;
    static foreach (i; 0 .. MySqlApi.tupleof.length)
    {{
        enum name = __traits(identifier, MySqlApi.tupleof[i]);
        auto symbol = findSymbol(handle, name);
        enforce(symbol !is null, chosen ~ " does not export " ~ name);
        api.tupleof[i] = cast(typeof(MySqlApi.tupleof[i])) symbol;
    }}

    mysql = api;
    loadedFrom = chosen;
    return chosen;
}

/// Version string of the loaded client library.
string clientLibraryVersion()
{
    return mysql.mysql_get_client_info().fromStringz.idup;
}

version (Windows)
{
    import core.sys.windows.winbase : GetProcAddress, LoadLibraryA;

    private void* openLibrary(string name)
    {
        return cast(void*) LoadLibraryA(name.toStringz);
    }

    private void* findSymbol(void* library, string name)
    {
        import core.sys.windows.windef : HMODULE;

        return cast(void*) GetProcAddress(cast(HMODULE) library, name.toStringz);
    }
}
else
{
    import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_NOW;

    private void* openLibrary(string name)
    {
        return dlopen(name.toStringz, RTLD_NOW);
    }

    private void* findSymbol(void* library, string name)
    {
        return dlsym(library, name.toStringz);
    }
}
