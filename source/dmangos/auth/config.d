/**
 * Server configuration, read from a JSON file.
 *
 * The field initializers are the defaults, and a configuration file only
 * needs to list what it changes. A setting that corresponds to a key of the
 * `realmd.conf` login server configuration file shared with the database's
 * other servers uses the same meaning and default; the key is named in the
 * field's comment.
 */
module dmangos.auth.config;

import std.exception : enforce;
import std.format : format;

import dmangos.json;
import dmangos.log : LogLevel;
import dmangos.auth.protocol : supportedBuilds, versionName;

/// What an automatic wrong-password ban applies to (`WrongPass.BanType`).
enum WrongPassBanTarget
{
    ip,      /// 0 in realmd.conf
    account, /// 1 in realmd.conf
}

/// Settings for the login server.
struct AuthConfig
{
    /// `LoginDatabaseInfo`: "host;port;user;password;database", or ".;socket;user;password;database".
    @JsonName("login_database") string loginDatabase = "127.0.0.1;3306;mangos;mangos;classicrealmd";

    /// Path of the MySQL/MariaDB client library; empty searches the usual names.
    @JsonName("mysql_library") string mysqlLibrary;

    @JsonName("bind_address") string bindAddress = "0.0.0.0"; /// `BindIP`
    ushort port = 3724;                                           /// `RealmServerPort`

    @JsonName("allowed_builds") ushort[] allowedBuilds = [5875, 6005, 6141];

    /// `RealmsStateUpdateDelay`: seconds between realm list reloads; 0 loads once.
    @JsonName("realms_state_update_delay") uint realmsStateUpdateDelay = 20;

    /// `WrongPass.MaxCount`: failed logins before an automatic ban; 0 disables it.
    @JsonName("wrong_pass_max_count") uint wrongPassMaxCount = 0;
    /// `WrongPass.BanTime`: seconds the automatic ban lasts (0 = permanent).
    @JsonName("wrong_pass_ban_time") uint wrongPassBanTime = 600;
    /// `WrongPass.BanType`
    @JsonName("wrong_pass_ban_type") WrongPassBanTarget wrongPassBanType = WrongPassBanTarget.ip;

    /// In-memory per-IP throttle, in addition to the database bans: failures before blocking (0 = off).
    @JsonName("max_failed_logins") uint maxFailedLogins = 5;
    /// How long the in-memory throttle blocks an address, in seconds.
    @JsonName("failed_login_block") uint failedLoginBlockSeconds = 900;

    @JsonName("idle_timeout") uint idleTimeoutSeconds = 60;
    @JsonName("max_connections") uint maxConnections = 512;
    @JsonName("log_level") LogLevel logLevel = LogLevel.info;

    /// Throws if the settings would not work at run time.
    void validate() const
    {
        enforce(allowedBuilds.length > 0, "allowed_builds must list at least one build");
        foreach (build; allowedBuilds)
            enforce(versionName(build) !is null,
                format!"build %s is not supported; supported builds are %(%s, %)"(build, supportedBuildNumbers));

        import dmangos.net.server : connectionLimit;

        enforce(maxConnections > 0 && maxConnections <= connectionLimit,
            format!"max_connections must be between 1 and %s"(connectionLimit));
        enforce(idleTimeoutSeconds > 0, "idle_timeout must be positive");
    }
}

private const(ushort)[] supportedBuildNumbers() pure nothrow @safe
{
    import std.algorithm.iteration : map;
    import std.array : array;

    return supportedBuilds.map!(known => known.build).array;
}

/// Loads and validates the configuration at `path`.
AuthConfig loadConfig(string path)
{
    import std.file : exists, readText;
    import std.json : parseJSON;

    enforce(path.exists, format!"configuration file '%s' not found (copy config/authserver.example.json)"(path));
    auto config = fromJson!AuthConfig(parseJSON(readText(path)));
    config.validate();
    return config;
}

unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;

    AuthConfig defaults;
    defaults.validate();

    auto config = fromJson!AuthConfig(parseJSON(`{
        "login_database": ".;/run/mysqld/mysqld.sock;realmd;pw;realmd",
        "wrong_pass_max_count": 3,
        "wrong_pass_ban_type": "account",
        "log_level": "verbose"
    }`));
    config.validate();
    assert(config.loginDatabase == ".;/run/mysqld/mysqld.sock;realmd;pw;realmd");
    assert(config.wrongPassMaxCount == 3 && config.wrongPassBanType == WrongPassBanTarget.account);
    assert(config.wrongPassBanTime == 600);
    assert(config.logLevel == LogLevel.verbose);

    AuthConfig unsupported;
    unsupported.allowedBuilds = [12340];
    assertThrown(unsupported.validate());
}
