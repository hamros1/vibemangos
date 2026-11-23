/// A common lease chooses one combined battleground host for independently elected realms.
module dmangos.world.battlegrouplease;

import core.time : MonoTime, seconds;
import dmangos.cluster.services : ServiceKind, serviceMap;
import dmangos.mysql : MySqlConnection;

package immutable uint[] battlegroupMaps = [30u, 489u, 529u, serviceMap(ServiceKind.battlegroundQueue)];

/// MySQL time serializes different hosts. The worker stops using a grant well before it can be acquired again.
final class BattlegroupHostLease
{
    private enum databaseLeaseSeconds = 12;
    private enum localLease = 10.seconds;

    private
    {
        MySqlConnection database;
        string group, topology;
        ulong token;
        ubyte slot;
        size_t expectedRealms;
        bool delegate()[] healthy, assigned;
        MonoTime delegate() clock;
        MonoTime deadline, nextRenewal, mayAcquireAt;
        bool acquired;
        bool retired;
    }

    this(MySqlConnection database, string group, string topology, ulong token, ubyte slot, size_t realms,
        MonoTime delegate() clock)
    {
        this.database = database;
        this.group = group;
        this.topology = topology;
        this.token = token;
        this.slot = slot;
        expectedRealms = realms;
        this.clock = clock;
        if (slot == 2)
            mayAcquireAt = clock() + 2.seconds;
        ensureTable(database);
        database.execute!"INSERT IGNORE INTO d_battlegroup_host (battlegroup, topology) VALUES (?, ?)"(group, topology);
        foreach (row; database.query!"SELECT topology FROM d_battlegroup_host WHERE battlegroup = ?"(group))
            if (row.get!string(0) != topology)
                throw new Exception("The battlegroup hosts disagree on their participating realms and node IDs.");
    }

    static void ensureTable(MySqlConnection database)
    {
        database.execute!"CREATE TABLE IF NOT EXISTS d_battlegroup_host (
            battlegroup VARBINARY(128) NOT NULL PRIMARY KEY,
            topology VARBINARY(1024) NOT NULL,
            host_slot TINYINT UNSIGNED NOT NULL DEFAULT 0,
            owner_token BIGINT UNSIGNED NOT NULL DEFAULT 0,
            expires_at DATETIME(6) NOT NULL DEFAULT '1970-01-01 00:00:00'
        ) ENGINE=InnoDB"();
    }

    static ubyte currentSlot(MySqlConnection database, string group)
    {
        foreach (row; database.query!"SELECT host_slot FROM d_battlegroup_host
            WHERE battlegroup = ? AND expires_at > UTC_TIMESTAMP(6)"(group))
            return row.get!ubyte(0);
        return 0;
    }

    void addRealm(bool delegate() hasLease, bool delegate() hasMaps)
    {
        healthy ~= hasLease;
        assigned ~= hasMaps;
    }

    /// Both realms must have seen grants for the whole group before either handles a queue or map action.
    bool assignedEverywhere()
    {
        import std.algorithm.searching : all;

        return holds() && assigned.all!(check => check());
    }

    private bool allRealmsHealthy()
    {
        import std.algorithm.searching : all;

        return healthy.length == expectedRealms && healthy.all!(check => check());
    }

    /// Only this process can run the shared queue and maps, and only while every realm still trusts it.
    bool holds()
    {
        return !retired && clock() < deadline && allRealmsHealthy();
    }

    /// Once fenced, the old process exits. It cannot start simulating an abandoned match again.
    @property bool fenced() const
    {
        return retired;
    }

    @property bool engaged() const
    {
        return acquired;
    }

    /// Bound on queued character writes after the shared lease lapses.
    @property MonoTime validUntil() const
    {
        return deadline;
    }

    void tick()
    {
        import dmangos.log : info, warning;
        import dmangos.mysql : DatabaseException;

        const now = clock();
        if (acquired && !holds())
        {
            retired = true;
            return;
        }
        if (retired || now < nextRenewal || now < mayAcquireAt || !allRealmsHealthy())
            return;
        nextRenewal = now + 1.seconds;
        try
        {
            const changed = database.execute!"UPDATE d_battlegroup_host
                SET host_slot = ?, owner_token = ?, expires_at = TIMESTAMPADD(SECOND, ?, UTC_TIMESTAMP(6))
                WHERE battlegroup = ? AND topology = ? AND (expires_at <= UTC_TIMESTAMP(6) OR owner_token = ?)"(
                    slot, token, databaseLeaseSeconds, group, topology, token);
            if (changed && clock() < now + localLease)
            {
                deadline = now + localLease;
                if (!acquired)
                    info!"battlegroup %s: host slot %s acquired the shared lease"(group, slot);
                acquired = true;
            }
        }
        catch (DatabaseException error)
            warning!"battlegroup %s: shared lease renewal failed: %s"(group, error.msg);
        if (acquired && !holds())
            retired = true;
    }
}
