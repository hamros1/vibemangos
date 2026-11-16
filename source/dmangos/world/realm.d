/**
 * The world server's entry in the login database, maintained as mangosd
 * does (`mangosd/Master.cpp`, `World/World.cpp`).
 *
 * At start-up the realm is marked online and its `realmbuilds` set, so login
 * servers list it as reachable. While it runs, `population` and the
 * `uptime` row are kept current. At shutdown it is marked offline again.
 */
module dmangos.world.realm;

import std.algorithm.iteration : map;
import std.array : array, join;
import std.conv : to;
import std.datetime.systime : Clock, SysTime;
import std.format : format;

import dmangos.log;
import dmangos.mysql : MySqlConnection;

/// `realmlist.realmflags` bit meaning "offline" (`REALM_FLAG_OFFLINE`).
private enum uint realmFlagOffline = 0x02;

/// See the module documentation.
final class RealmRegistration
{
    private MySqlConnection login;
    private uint realmId;
    private long startTime;
    private bool online;

    ///
    this(MySqlConnection login, uint realmId)
    in (realmId > 0, "realm ids start at 1")
    {
        this.login = login;
        this.realmId = realmId;
    }

    /// Marks the realm online for `builds`, sets its type and zone, and opens an `uptime` row.
    void markOnline(const(ushort)[] builds, uint gameType, uint realmZone)
    {
        const buildNames = builds.map!(to!string).array;

        const changed = login.execute!("UPDATE realmlist SET realmflags = realmflags & ~(?), population = 0, "
            ~ "realmbuilds = ? WHERE id = ?")(realmFlagOffline, buildNames.join(" "), realmId);
        if (changed == 0 && login.query!"SELECT 1 FROM realmlist WHERE id = ?"(realmId).length == 0)
            warning!"realmlist has no realm with id %s; add one or set realm_id, or no client can find this server"(
                realmId);
        login.execute!"UPDATE realmlist SET icon = ?, timezone = ? WHERE id = ?"(gameType, realmZone, realmId);

        const now = Clock.currTime;
        startTime = now.toUnixTime;
        login.execute!("INSERT INTO uptime (realmid, starttime, startstring, uptime) VALUES (?, ?, ?, 0)")(
            realmId, startTime, isoDate(now));
        online = true;
        info!"realm %s is online for builds %s"(realmId, buildNames.join(", "));
    }

    /// `realmlist.population`: sessions relative to the player limit, times two, as CMaNGOS computes it.
    void updatePopulation(size_t sessions, uint playerLimit)
    {
        if (playerLimit == 0)
            return;
        const population = float(sessions) / playerLimit * 2;
        login.execute!"UPDATE realmlist SET population = ? WHERE id = ?"(population, realmId);
    }

    /// `realmlist.address` and `port`: where clients of the realm connect (in a cluster, the least busy node).
    void setAddress(string host, ushort port)
    {
        login.execute!"UPDATE realmlist SET address = ?, port = ? WHERE id = ?"(host, port, realmId);
        info!"realm %s now sends clients to %s:%s"(realmId, host, port);
    }

    /// Updates this run's `uptime` row.
    void updateUptime(uint maxPlayers)
    {
        const seconds = Clock.currTime.toUnixTime - startTime;
        login.execute!"UPDATE uptime SET uptime = ?, maxplayers = ? WHERE realmid = ? AND starttime = ?"(
            seconds, maxPlayers, realmId, startTime);
    }

    /// Marks the realm offline. Safe to call more than once.
    void markOffline()
    {
        if (!online)
            return;
        login.execute!"UPDATE realmlist SET realmflags = realmflags | ? WHERE id = ?"(realmFlagOffline, realmId);
        online = false;
        info!"realm %s is offline"(realmId);
    }

    private static string isoDate(SysTime time)
    {
        return format!"%04d-%02d-%02d %02d:%02d:%02d"(time.year, cast(int) time.month, time.day, time.hour,
            time.minute, time.second);
    }
}
