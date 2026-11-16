/**
 * A MySQL connection with compile-time checked queries.
 *
 * The SQL text is a template argument, and `?` marks each parameter:
 *
 * ---
 * auto rows = db.query!"SELECT id, gmlevel FROM account WHERE username = ?"(name);
 * db.execute!"UPDATE account SET failed_logins = failed_logins + 1 WHERE id = ?"(id);
 * ---
 *
 * The statement is split at its placeholders at compile time, and a
 * mismatch between placeholders and arguments is a compile error. Strings
 * are escaped with `mysql_real_escape_string` for the connection's
 * character set. Numbers are formatted, so values never reach SQL unescaped.
 *
 * Queries are synchronous. A dropped connection (server restart, idle
 * timeout) is re-established once, and the statement is retried.
 */
module dmangos.mysql.connection;

import std.conv : to;
import std.exception : basicExceptionCtors, enforce;
import std.format : format;
import std.string : fromStringz, toStringz;
import std.traits : isFloatingPoint, isIntegral, isSomeString, OriginalType;

import dmangos.log;
import dmangos.mysql.binding;

/// Thrown when connecting or running a statement fails.
class DatabaseException : Exception
{
    mixin basicExceptionCtors;
}

/// Where and as whom to connect.
struct ConnectionInfo
{
    string host = "127.0.0.1";
    ushort port = 3306;
    string socket;   /// Unix socket path; used instead of host/port when set.
    string user;
    string password;
    string database;

    /**
     * Parses the `"host;port;user;password;database"` format of CMaNGOS's
     * `LoginDatabaseInfo`. As there, a host of `"."` means the port field is
     * a Unix socket path.
     */
    static ConnectionInfo parse(string text)
    {
        import std.array : split;

        const parts = text.split(';');
        enforce!DatabaseException(parts.length == 5,
            "database info must look like \"host;port;user;password;database\"");

        ConnectionInfo info;
        if (parts[0] == ".")
        {
            info.host = null;
            info.socket = parts[1];
        }
        else
        {
            info.host = parts[0];
            info.port = parts[1].to!ushort;
        }
        info.user = parts[2];
        info.password = parts[3];
        info.database = parts[4];
        return info;
    }

    /// Description without the password, for logs.
    string toString() const
    {
        const where = socket.length ? socket : format!"%s:%s"(host, port);
        return format!"%s@%s/%s"(user, where, database);
    }
}

/// One row of a result set. Values are kept as the text the server sent.
struct Row
{
    private string[] values;
    private bool[] nulls;

    /// Number of columns.
    @property size_t length() const pure nothrow @nogc @safe
    {
        return values.length;
    }

    /// Whether column `i` is SQL NULL.
    bool isNull(size_t i) const pure @safe
    {
        return nulls[i];
    }

    /// Column `i` converted to `T`. NULL gives `T.init`.
    T get(T)(size_t i) const
    {
        if (nulls[i])
            return T.init;
        static if (is(T == string))
            return values[i];
        else static if (is(T == bool))
            return values[i] != "0";
        else static if (is(T == enum))
            return cast(T) values[i].to!(OriginalType!T);
        else
            return values[i].to!T;
    }

    /// Maps the columns, in order, onto the fields of `T`.
    T as(T)() const if (is(T == struct))
    {
        enforce!DatabaseException(values.length == T.tupleof.length,
            format!"query returned %s columns, %s has %s fields"(values.length, T.stringof, T.tupleof.length));
        T result;
        static foreach (i; 0 .. T.tupleof.length)
            result.tupleof[i] = get!(typeof(T.tupleof[i]))(i);
        return result;
    }
}

/**
 * Splits `sql` at its `?` placeholders. Question marks inside quoted
 * literals and identifiers are not placeholders.
 */
string[] splitPlaceholders(string sql) pure @safe
{
    string[] pieces;
    size_t start = 0;
    char quote = 0;
    foreach (i, c; sql)
    {
        if (quote)
        {
            if (c == quote)
                quote = 0;
        }
        else if (c == '\'' || c == '"' || c == '`')
            quote = c;
        else if (c == '?')
        {
            pieces ~= sql[start .. i];
            start = i + 1;
        }
    }
    pieces ~= sql[start .. $];
    return pieces;
}

///
@safe unittest
{
    static assert(splitPlaceholders("SELECT 1") == ["SELECT 1"]);
    static assert(splitPlaceholders("a = ? AND b = '?' AND c = ?") == ["a = ", " AND b = '?' AND c = ", ""]);
}

/// A connection to a MySQL or MariaDB server.
final class MySqlConnection
{
    private MYSQL* handle;
    private ConnectionInfo info;

    /// Loads the client library if needed (`library` overrides the search) and connects.
    this(ConnectionInfo info, string library = null)
    {
        const loaded = loadMySqlLibrary(library);
        verbose!"using MySQL client library %s (%s)"(loaded, clientLibraryVersion());
        this.info = info;
        connect();
    }

    /// Closes the connection. Safe to call more than once.
    void close()
    {
        if (handle !is null)
        {
            mysql.mysql_close(handle);
            handle = null;
        }
    }

    /// Runs a statement that returns rows.
    Row[] query(string sql, Args...)(auto ref Args args)
    {
        return run(bind!sql(args), true);
    }

    /// Runs `sql` and maps every row onto `T`; see `Row.as`.
    T[] queryAs(T, string sql, Args...)(auto ref Args args)
    {
        T[] result;
        foreach (row; query!sql(args))
            result ~= row.as!T;
        return result;
    }

    /// Runs a statement that returns no rows. Returns: the number of affected rows.
    ulong execute(string sql, Args...)(auto ref Args args)
    {
        run(bind!sql(args), false);
        return mysql.mysql_affected_rows(handle);
    }

    /**
     * Runs `work` inside a transaction: committed if it returns, rolled back if it throws.
     * (MyISAM tables, which CMaNGOS uses for many tables, ignore transactions.)
     */
    void transaction(scope void delegate() work)
    {
        run("START TRANSACTION", false);
        scope (failure)
            run("ROLLBACK", false);
        work();
        run("COMMIT", false);
    }

    /// The AUTO_INCREMENT id generated by the last INSERT.
    @property ulong lastInsertId()
    {
        return mysql.mysql_insert_id(handle);
    }

    /// Escapes `text` for use inside a quoted SQL string literal.
    string escape(scope const(char)[] text)
    {
        auto buffer = new char[text.length * 2 + 1];
        const length = mysql.mysql_real_escape_string(handle, buffer.ptr, text.ptr, text.length);
        return buffer[0 .. length].idup;
    }

private:
    /// Substitutes the arguments into the placeholders. The split happens at compile time.
    string bind(string sql, Args...)(auto ref Args args)
    {
        enum pieces = splitPlaceholders(sql);
        static assert(pieces.length == Args.length + 1,
            format!"statement has %s placeholders but %s arguments were given: %s"(
                pieces.length - 1, Args.length, sql));

        string text = pieces[0];
        static foreach (i; 0 .. Args.length)
            text ~= literal(args[i]) ~ pieces[i + 1];
        return text;
    }

    string literal(T)(auto ref const T value)
    {
        static if (is(T == typeof(null)))
            return "NULL";
        else static if (is(T == bool))
            return value ? "1" : "0";
        else static if (is(T == enum))
            return literal(cast(OriginalType!T) value);
        else static if (isIntegral!T)
            return value.to!string;
        else static if (isFloatingPoint!T)
            return format!"%.9g"(value);
        else static if (isSomeString!T)
            return "'" ~ escape(value) ~ "'";
        else
            static assert(false, "cannot use " ~ T.stringof ~ " as a query parameter");
    }

    void connect()
    {
        handle = mysql.mysql_init(null);
        enforce!DatabaseException(handle !is null, "mysql_init failed");

        uint connectTimeout = 10, ioTimeout = 30;
        mysql.mysql_options(handle, MySqlOption.connectTimeout, &connectTimeout);
        mysql.mysql_options(handle, MySqlOption.readTimeout, &ioTimeout);
        mysql.mysql_options(handle, MySqlOption.writeTimeout, &ioTimeout);
        mysql.mysql_options(handle, MySqlOption.setCharsetName, "utf8".ptr);

        const connected = mysql.mysql_real_connect(handle,
            info.host.length ? info.host.toStringz : null,
            info.user.toStringz, info.password.toStringz, info.database.toStringz,
            info.socket.length ? 0 : info.port,
            info.socket.length ? info.socket.toStringz : null, 0);
        if (connected is null)
        {
            const message = lastError();
            mysql.mysql_close(handle);
            handle = null;
            throw new DatabaseException("cannot connect to " ~ info.toString ~ ": " ~ message);
        }
        verbose!"connected to MySQL %s"(info.toString);
    }

    Row[] run(string text, bool wantRows)
    {
        foreach (attempt; 0 .. 2)
        {
            if (handle is null)
                connect();
            if (mysql.mysql_real_query(handle, text.ptr, text.length) == 0)
                return collect(wantRows);

            const code = mysql.mysql_errno(handle);
            if (attempt == 0 && (code == CR_SERVER_GONE_ERROR || code == CR_SERVER_LOST))
            {
                warning!"lost the connection to MySQL (%s), reconnecting"(lastError());
                close();
                continue;
            }
            throw new DatabaseException(format!"MySQL error %s: %s"(code, lastError()));
        }
        assert(false, "unreachable");
    }

    Row[] collect(bool wantRows)
    {
        auto result = mysql.mysql_store_result(handle);
        if (result is null)
        {
            enforce!DatabaseException(mysql.mysql_field_count(handle) == 0,
                "could not read the result: " ~ lastError());
            enforce!DatabaseException(!wantRows, "statement returned no result set");
            return null;
        }
        scope (exit)
            mysql.mysql_free_result(result);

        const columns = mysql.mysql_num_fields(result);
        Row[] rows;
        for (;;)
        {
            auto row = mysql.mysql_fetch_row(result);
            if (row is null)
                break;
            const lengths = mysql.mysql_fetch_lengths(result);

            Row converted;
            converted.values = new string[columns];
            converted.nulls = new bool[columns];
            foreach (column; 0 .. columns)
            {
                if (row[column] is null)
                    converted.nulls[column] = true;
                else
                    converted.values[column] = row[column][0 .. lengths[column]].idup;
            }
            rows ~= converted;
        }
        return rows;
    }

    string lastError()
    {
        return handle is null ? "no connection" : mysql.mysql_error(handle).fromStringz.idup;
    }
}

unittest
{
    const info = ConnectionInfo.parse("127.0.0.1;3306;mangos;secret;classicrealmd");
    assert(info.host == "127.0.0.1" && info.port == 3306 && info.socket is null);
    assert(info.user == "mangos" && info.password == "secret" && info.database == "classicrealmd");
    assert(info.toString == "mangos@127.0.0.1:3306/classicrealmd");

    const local = ConnectionInfo.parse(".;/var/run/mysqld/mysqld.sock;mangos;mangos;classicrealmd");
    assert(local.host is null && local.socket == "/var/run/mysqld/mysqld.sock");

    import std.exception : assertThrown;

    assertThrown!DatabaseException(ConnectionInfo.parse("127.0.0.1;3306;mangos"));
}

unittest
{
    static struct Pair
    {
        uint id;
        string name;
    }

    auto row = Row(["7", "TEST"], [false, false]);
    assert(row.as!Pair == Pair(7, "TEST"));
    auto withNull = Row(["", "0"], [true, false]);
    assert(withNull.get!string(0) is null && withNull.isNull(0));
    assert(!withNull.get!bool(1));
}
