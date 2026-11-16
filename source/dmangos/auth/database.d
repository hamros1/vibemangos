/**
 * The login database: everything the login server reads and writes.
 *
 * `LoginDatabase` describes operations rather than tables. Its production
 * implementation is `MySqlLoginDatabase`, which works on an unmodified
 * CMaNGOS `realmd` schema. `MemoryLoginDatabase` keeps the same data in
 * associative arrays with the same rules, so the protocol tests run without
 * a server.
 */
module dmangos.auth.database;

import std.algorithm.searching : canFind;
import std.algorithm.sorting : sort;
import std.datetime.systime : Clock;
import std.exception : enforce;
import std.typecons : Nullable, nullable;

import dmangos.crypto.srp6 : sessionKeyLength;
import dmangos.auth.accounts;
import dmangos.auth.realms : RealmRecord;

/// Name recorded in `banned_by` for automatic bans.
enum autoBanAuthor = "dmangos realmd";

/// See the module documentation.
interface LoginDatabase
{
    /// The account named `username` (case-insensitive), with its current ban state.
    Nullable!Account findAccount(string username);

    /// Whether `ip` has an active entry in `ip_banned`.
    bool isIpBanned(string ip);

    /// Stores the session key after a successful login, resets `failed_logins` and logs to `account_logons`.
    void recordLogin(uint accountId, in ubyte[sessionKeyLength] sessionKey, string ip, ClientDetails client);

    /// Increments `failed_logins`. Returns: the new count.
    uint recordFailedLogin(uint accountId);

    /// Bans an account. `seconds` = 0 bans permanently.
    void banAccount(uint accountId, uint seconds, string bannedBy, string reason);

    /// Lifts every active ban on an account.
    void unbanAccount(uint accountId, string unbannedBy);

    /// Bans an IP address. `seconds` = 0 bans permanently.
    void banIp(string ip, uint seconds, string bannedBy, string reason);

    /// Removes every ban on an IP address.
    void unbanIp(string ip);

    /// The `realmlist` rows that are not flagged invalid.
    RealmRecord[] loadRealms();

    /// `realmcharacters.numchars` per realm id for an account.
    ubyte[uint] characterCounts(uint accountId);

    /// Creates an account. Throws if the name is invalid or taken.
    Account createAccount(string username, string password, AccountLevel level = AccountLevel.player);

    /// Replaces an account's salt and verifier.
    void setPassword(string username, string password);

    /// Changes an account's security level.
    void setLevel(string username, AccountLevel level);

    /// Every account, by id.
    Account[] listAccounts();
}

/// Checks shared by every implementation of `createAccount`/`setPassword`.
void validateNewCredentials(string username, string password)
{
    enforce(isValidAccountName(username), "account names must be 1-16 characters long");
    enforce(isValidPassword(password), "passwords must be 1-16 characters long");
}

/// A `LoginDatabase` held in memory, following the same rules as the CMaNGOS tables.
class MemoryLoginDatabase : LoginDatabase
{
    private static struct BanRow
    {
        long bannedAt;
        long expiresAt;
        bool active = true;

        bool permanent() const pure nothrow @nogc @safe
        {
            return expiresAt == bannedAt;
        }

        bool inForce(long now) const pure nothrow @nogc @safe
        {
            return active && (permanent || expiresAt > now);
        }
    }

    private
    {
        Account[string] accounts;   // by canonical name
        BanRow[][uint] accountBans; // by account id
        BanRow[][string] ipBans;    // by address
        ubyte[uint][uint] characters; // account id -> realm id -> count
        uint nextId = 1;
    }

    /// The realm rows `loadRealms` returns. Tests fill this directly.
    RealmRecord[] realms;

    /// Login records, newest last, as `account_logons` would hold them.
    string[] logons;

    /// The clock used for bans. Tests may replace it.
    long delegate() @safe now;

    invariant (nextId > accounts.length, "ids are allocated past every existing account");

    this()
    {
        now = () @safe => Clock.currTime.toUnixTime;
    }

    Nullable!Account findAccount(string username)
    {
        auto account = canonicalAccountName(username) in accounts;
        if (account is null)
            return Nullable!Account.init;

        Account result = *account;
        result.ban = BanState.none;
        foreach (ban; accountBans.get(result.id, null))
            if (ban.inForce(now()))
                result.ban = ban.permanent ? BanState.banned : (result.ban == BanState.none ? BanState.suspended : result.ban);
        return nullable(result);
    }

    bool isIpBanned(string ip)
    {
        return ipBans.get(ip, null).canFind!(ban => ban.inForce(now()));
    }

    void recordLogin(uint accountId, in ubyte[sessionKeyLength] sessionKey, string ip, ClientDetails client)
    {
        auto account = byId(accountId);
        account.sessionKey = sessionKey.dup;
        account.failedLogins = 0;
        logons ~= account.username ~ "@" ~ ip ~ " (" ~ client.locale ~ " " ~ client.os ~ " " ~ client.platform ~ ")";
    }

    uint recordFailedLogin(uint accountId)
    {
        return ++byId(accountId).failedLogins;
    }

    void banAccount(uint accountId, uint seconds, string bannedBy, string reason)
    {
        const at = now();
        accountBans[accountId] ~= BanRow(at, at + seconds);
    }

    void unbanAccount(uint accountId, string unbannedBy)
    {
        foreach (ref ban; accountBans.get(accountId, null))
            ban.active = false;
    }

    void banIp(string ip, uint seconds, string bannedBy, string reason)
    {
        const at = now();
        ipBans[ip] ~= BanRow(at, at + seconds);
    }

    void unbanIp(string ip)
    {
        ipBans.remove(ip);
    }

    RealmRecord[] loadRealms()
    {
        RealmRecord[] valid;
        foreach (realm; realms)
            if ((realm.realmflags & 1) == 0)
                valid ~= realm;
        return valid;
    }

    ubyte[uint] characterCounts(uint accountId)
    {
        return characters.get(accountId, null).dup;
    }

    /// Sets `realmcharacters.numchars`, which the world server maintains in a real deployment.
    void setCharacterCount(uint accountId, uint realmId, ubyte count)
    {
        characters[accountId][realmId] = count;
    }

    /// Locks an account to an IP address (`account.locked`/`lockedIp`).
    void lockAccount(string username, string ip)
    {
        auto account = byName(username);
        account.locked = true;
        account.lockedIp = ip;
    }

    /// Replaces an account's stored credentials, as if the `s`/`v` columns had been corrupted.
    void breakCredentials(string username)
    {
        byName(username).credentialsValid = false;
    }

    Account createAccount(string username, string password, AccountLevel level = AccountLevel.player)
    {
        validateNewCredentials(username, password);
        immutable name = canonicalAccountName(username);
        enforce(name !in accounts, "account '" ~ name ~ "' already exists");

        const credentials = makeCredentials(name, password);
        Account account;
        account.id = nextId++;
        account.username = name;
        account.level = level;
        account.salt = credentials.salt;
        account.verifier = credentials.verifier;
        account.credentialsValid = true;
        accounts[name] = account;
        return account;
    }

    void setPassword(string username, string password)
    {
        validateNewCredentials(username, password);
        auto account = byName(username);
        const credentials = makeCredentials(account.username, password);
        account.salt = credentials.salt;
        account.verifier = credentials.verifier;
        account.credentialsValid = true;
    }

    void setLevel(string username, AccountLevel level)
    {
        byName(username).level = level;
    }

    Account[] listAccounts()
    {
        auto all = accounts.values;
        all.sort!((a, b) => a.id < b.id);
        return all;
    }

    private Account* byName(string username)
    {
        auto account = canonicalAccountName(username) in accounts;
        enforce(account !is null, "no account named '" ~ canonicalAccountName(username) ~ "'");
        return account;
    }

    private Account* byId(uint id)
    {
        foreach (ref account; accounts)
            if (account.id == id)
                return &account;
        import std.conv : to;

        throw new Exception("no account with id " ~ id.to!string);
    }
}

unittest
{
    import std.exception : assertThrown;

    long clock = 1000;
    auto db = new MemoryLoginDatabase;
    db.now = () @safe => clock;

    const thrall = db.createAccount("Thrall", "Lok'tar", AccountLevel.gameMaster);
    assert(thrall.username == "THRALL" && thrall.id == 1 && thrall.credentialsValid);
    assert(!db.findAccount("thrall").isNull);
    assert(db.findAccount("jaina").isNull);
    assertThrown(db.createAccount("THRALL", "other"));
    assertThrown(db.createAccount("x", ""));

    // Temporary bans expire; permanent ones (expires_at = banned_at) do not; unbanning lifts both.
    db.banAccount(thrall.id, 60, "test", "test");
    assert(db.findAccount("thrall").get.ban == BanState.suspended);
    clock += 61;
    assert(db.findAccount("thrall").get.ban == BanState.none);
    db.banAccount(thrall.id, 0, "test", "test");
    clock += 1_000_000;
    assert(db.findAccount("thrall").get.ban == BanState.banned);
    db.unbanAccount(thrall.id, "test");
    assert(db.findAccount("thrall").get.ban == BanState.none);

    db.banIp("1.2.3.4", 10, "test", "test");
    assert(db.isIpBanned("1.2.3.4") && !db.isIpBanned("4.3.2.1"));
    clock += 11;
    assert(!db.isIpBanned("1.2.3.4"));

    assert(db.recordFailedLogin(thrall.id) == 1);
    assert(db.recordFailedLogin(thrall.id) == 2);
    ubyte[sessionKeyLength] key = 9;
    db.recordLogin(thrall.id, key, "10.0.0.1", ClientDetails("enUS", "Win", "x86"));
    assert(db.findAccount("thrall").get.failedLogins == 0);
    assert(db.findAccount("thrall").get.sessionKey == key[]);

    db.realms = [RealmRecord(1, "Live"), RealmRecord(2, "Hidden", "127.0.0.1", 8085, 0, 0x01)];
    assert(db.loadRealms().length == 1, "realms flagged invalid (0x01) are never loaded");
}
