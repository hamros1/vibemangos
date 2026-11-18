/**
 * `LoginDatabase` on a MySQL/MariaDB database with the CMaNGOS `realmd` schema.
 *
 * The tables are read and written exactly as the CMaNGOS login server and
 * account tools do, so both can share a database, and accounts created by
 * either work in both.
 *
 * Time comparisons use the database server's `UNIX_TIMESTAMP`, so bans
 * behave identically even if the servers' clocks differ.
 */
module dmangos.auth.mysqldb;

import std.algorithm.iteration : map;
import std.array : array;
import std.exception : enforce;
import std.typecons : Nullable, nullable;

import dmangos.crypto.srp6 : keyLength, saltLength, sessionKeyLength;
import dmangos.log;
import dmangos.mysql;
import dmangos.auth.accounts;
import dmangos.auth.database;
import dmangos.auth.realms : RealmRecord;

/// See the module documentation.
final class MySqlLoginDatabase : LoginDatabase
{
    private MySqlConnection db;

    /// Account columns plus the ban counts, as the logon challenge needs them.
    private enum selectAccounts = "SELECT a.id, a.username, a.gmlevel, a.v, a.s, a.sessionkey, a.locked, "
        ~ "a.lockedIp, a.failed_logins, "
        ~ "(SELECT COUNT(*) FROM account_banned WHERE account_id = a.id AND active = 1 AND expires_at = banned_at), "
        ~ "(SELECT COUNT(*) FROM account_banned WHERE account_id = a.id AND active = 1 "
        ~ "AND expires_at <> banned_at AND expires_at > UNIX_TIMESTAMP()) "
        ~ "FROM account a";

    /// One row of `selectAccounts`.
    private static struct AccountRow
    {
        uint id;
        string username;
        uint gmlevel;
        string v;
        string s;
        string sessionkey;
        uint locked;
        string lockedIp;
        uint failedLogins;
        uint permanentBans;
        uint temporaryBans;
    }

    /// Connects to the database described by `info`.
    this(ConnectionInfo info, string library = null)
    {
        db = new MySqlConnection(info, library);
        checkSchema();
    }

    /// Works on an open connection, such as the world server's to the login database.
    this(MySqlConnection db)
    in (db !is null)
    {
        this.db = db;
        checkSchema();
    }

    /// Closes the connection.
    void close()
    {
        db.close();
    }

    Nullable!Account findAccount(string username)
    {
        auto rows = db.queryAs!(AccountRow, selectAccounts ~ " WHERE a.username = ?")(canonicalAccountName(username));
        return rows.length ? nullable(toAccount(rows[0])) : Nullable!Account.init;
    }

    bool isIpBanned(string ip)
    {
        const rows = db.query!("SELECT COUNT(*) FROM ip_banned "
            ~ "WHERE (expires_at = banned_at OR expires_at > UNIX_TIMESTAMP()) AND ip = ?")(ip);
        return rows[0].get!uint(0) > 0;
    }

    void recordLogin(uint accountId, in ubyte[sessionKeyLength] sessionKey, string ip, ClientDetails client)
    {
        db.execute!("UPDATE account SET sessionkey = ?, locale = ?, failed_logins = 0, os = ?, platform = ? "
            ~ "WHERE id = ?")(encodeBigNumberHex(sessionKey, 2 * sessionKeyLength), client.locale, client.os,
            client.platform, accountId);
        db.execute!("INSERT INTO account_logons(accountId, ip, loginTime, loginSource) "
            ~ "VALUES (?, ?, NOW(), ?)")(accountId, ip, loginSourceRealmd);
    }

    uint recordFailedLogin(uint accountId)
    {
        db.execute!"UPDATE account SET failed_logins = failed_logins + 1 WHERE id = ?"(accountId);
        const rows = db.query!"SELECT failed_logins FROM account WHERE id = ?"(accountId);
        return rows.length ? rows[0].get!uint(0) : 0;
    }

    void banAccount(uint accountId, uint seconds, string bannedBy, string reason)
    {
        db.execute!("INSERT INTO account_banned(account_id, banned_at, expires_at, banned_by, reason, active) "
            ~ "VALUES (?, UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + ?, ?, ?, 1)")(accountId, seconds, bannedBy, reason);
    }

    void unbanAccount(uint accountId, string unbannedBy)
    {
        db.execute!("UPDATE account_banned SET active = 0, unbanned_at = UNIX_TIMESTAMP(), unbanned_by = ? "
            ~ "WHERE account_id = ? AND active = 1")(unbannedBy, accountId);
    }

    void banIp(string ip, uint seconds, string bannedBy, string reason)
    {
        // IGNORE: (ip, banned_at) is the primary key, so a second ban in the same second is a no-op.
        db.execute!("INSERT IGNORE INTO ip_banned(ip, banned_at, expires_at, banned_by, reason) "
            ~ "VALUES (?, UNIX_TIMESTAMP(), UNIX_TIMESTAMP() + ?, ?, ?)")(ip, seconds, bannedBy, reason);
    }

    void unbanIp(string ip)
    {
        db.execute!"DELETE FROM ip_banned WHERE ip = ?"(ip);
    }

    RealmRecord[] loadRealms()
    {
        return db.queryAs!(RealmRecord, "SELECT id, name, address, port, icon, realmflags, timezone, "
            ~ "allowedSecurityLevel, population, realmbuilds FROM realmlist WHERE (realmflags & 1) = 0 "
            ~ "ORDER BY name")();
    }

    ubyte[uint] characterCounts(uint accountId)
    {
        ubyte[uint] counts;
        foreach (row; db.query!"SELECT realmid, numchars FROM realmcharacters WHERE acctid = ?"(accountId))
            counts[row.get!uint(0)] = row.get!ubyte(1);
        return counts;
    }

    Account createAccount(string username, string password, AccountLevel level = AccountLevel.player)
    {
        validateNewCredentials(username, password);
        immutable name = canonicalAccountName(username);
        enforce(db.query!"SELECT 1 FROM account WHERE username = ?"(name).length == 0,
            "account '" ~ name ~ "' already exists");

        const credentials = makeCredentials(name, password);
        db.execute!"INSERT INTO account(username, v, s, joindate) VALUES (?, ?, ?, NOW())"(
            name, credentials.verifierHex, credentials.saltHex);
        if (level != AccountLevel.player)
            db.execute!"UPDATE account SET gmlevel = ? WHERE username = ?"(level, name);
        // The new account gets a zero character count on every realm.
        db.execute!("INSERT INTO realmcharacters (realmid, acctid, numchars) SELECT realmlist.id, account.id, 0 "
            ~ "FROM realmlist, account LEFT JOIN realmcharacters ON acctid = account.id WHERE acctid IS NULL")();
        return findAccount(name).get;
    }

    void setPassword(string username, string password)
    {
        validateNewCredentials(username, password);
        const account = require(username);
        const credentials = makeCredentials(account.username, password);
        db.execute!"UPDATE account SET v = ?, s = ? WHERE id = ?"(credentials.verifierHex, credentials.saltHex,
            account.id);
    }

    void setLevel(string username, AccountLevel level)
    {
        db.execute!"UPDATE account SET gmlevel = ? WHERE id = ?"(level, require(username).id);
    }

    Account[] listAccounts()
    {
        return db.queryAs!(AccountRow, selectAccounts ~ " ORDER BY a.id")().map!toAccount.array;
    }

private:
    /// `account_logons.loginSource` for logins through the login server.
    enum uint loginSourceRealmd = 0;

    Account require(string username)
    {
        auto account = findAccount(username);
        enforce(!account.isNull, "no account named '" ~ canonicalAccountName(username) ~ "'");
        return account.get;
    }

    /// Fails early, with a clear message, if the database lacks a `realmd` table.
    void checkSchema()
    {
        static immutable tables = ["account", "account_banned", "account_logons", "ip_banned", "realmcharacters",
            "realmlist"];
        foreach (table; tables)
            enforce!DatabaseException(db.query!("SELECT COUNT(*) FROM information_schema.tables "
                ~ "WHERE table_schema = DATABASE() AND table_name = ?")(table)[0].get!uint(0) == 1,
                "table '" ~ table ~ "' is missing; import CMaNGOS sql/base/realmd.sql into the database first");
    }

    static Account toAccount(const AccountRow row)
    {
        Account account;
        account.id = row.id;
        account.username = row.username;
        account.level = toAccountLevel(row.gmlevel);
        account.locked = row.locked == 1;
        account.lockedIp = row.lockedIp;
        account.failedLogins = row.failedLogins;
        account.ban = row.permanentBans ? BanState.banned : row.temporaryBans ? BanState.suspended : BanState.none;

        const salt = decodeBigNumberHex!saltLength(row.s);
        const verifier = decodeBigNumberHex!keyLength(row.v);
        account.credentialsValid = !salt.isNull && !verifier.isNull;
        if (account.credentialsValid)
        {
            account.salt = salt.get;
            account.verifier = verifier.get;
        }

        const key = decodeBigNumberHex!sessionKeyLength(row.sessionkey);
        if (!key.isNull)
            account.sessionKey = key.get.dup;
        return account;
    }
}
