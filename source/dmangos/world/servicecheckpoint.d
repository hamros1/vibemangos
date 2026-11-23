/// Durable, revision-fenced snapshots of realm services that also support clean handoff.
module dmangos.world.servicecheckpoint;

import core.time : Duration, seconds;
import dmangos.cluster.services : ServiceKind;
import dmangos.world.context : WorldContext;
import dmangos.world.database : ServiceCheckpoint;

struct RealmServiceCheckpoint
{
    private WorldContext context;
    private ServiceKind kind;
    private ulong revision;
    private bool revisionKnown;
    private long nextSave;

    this(WorldContext context, ServiceKind kind)
    {
        if (context !is null && context.config.cluster.nodeId && context.regionOwnerAround !is null)
        {
            this.context = context;
            this.kind = kind;
        }
    }

    /// Refresh the revision even when a clean handoff already supplied state.
    const(ubyte)[] load(bool recovering, out ushort previousNode, out Duration elapsed)
    {
        import dmangos.log : warning;
        import std.algorithm.searching : startsWith;
        import std.base64 : Base64;

        if (context is null)
            return null;
        try
        {
            const row = readCheckpoint();
            const age = context.unixTime - row.at;
            if (recovering && revision && age >= -5 && age <= 120 && row.state.startsWith("1:"))
            {
                previousNode = row.node;
                elapsed = (age < 0 ? 0 : age).seconds;
                return Base64.decode(row.state[2 .. $]);
            }
        }
        catch (Exception error)
            warning!"%s: could not read the saved service state: %s"(kind, error.msg);
        return null;
    }

    private ServiceCheckpoint readCheckpoint()
    {
        const row = context.database.loadServiceCheckpoint(kind, context.config.realmId);
        revision = row.revision;
        revisionKnown = true;
        return row;
    }

    bool save(bool changed, scope ubyte[] delegate() snapshot)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import std.base64 : Base64;

        if (context is null || !context.canWrite())
            return false;
        const now = context.unixTime;
        if (!changed && now < nextSave)
            return false;
        nextSave = now + 10;
        try
        {
            // A failed startup read leaves the comparison revision unknown.
            if (!revisionKnown)
                readCheckpoint();
            const row = ServiceCheckpoint(revision, now, context.nodeId, "1:" ~ Base64.encode(snapshot()).idup);
            if (context.database.saveServiceCheckpoint(kind, context.config.realmId, row))
            {
                ++revision;
                return true;
            }
            else if (context.canWrite())
            {
                warning!"%s: another host has a newer service checkpoint"(kind);
                context = null;
            }
        }
        catch (DatabaseException error)
            warning!"%s: could not checkpoint the service: %s"(kind, error.msg);
        return false;
    }
}

unittest
{
    import dmangos.mysql : DatabaseException;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.database : WorldDatabase;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import std.typecons : AutoImplement;

    static abstract class FailsFirstRead : WorldDatabase
    {
        WorldDatabase inner;
        bool fail = true;

        this(WorldDatabase inner) { this.inner = inner; }

        override ServiceCheckpoint loadServiceCheckpoint(ServiceKind kind, uint realm)
        {
            if (fail)
            {
                fail = false;
                throw new DatabaseException("checkpoint read failed");
            }
            return inner.loadServiceCheckpoint(kind, realm);
        }
    }

    enum string forward(C, alias method) = "return inner." ~ __traits(identifier, method) ~ "(args);";
    alias Database = AutoImplement!(FailsFirstRead, forward);
    auto db = newDatabase();
    auto context = newCreationContext(db, (ref WorldConfig config) { config.cluster.nodeId = 1; });
    context.nodeId = 1;
    context.regionOwnerAround = (uint, Position, float) => context.nodeId;

    ubyte[] snapshot() { return [7]; }
    auto first = RealmServiceCheckpoint(context, ServiceKind.weather);
    assert(first.save(true, &snapshot));
    context.database = new Database(db);
    auto restarted = RealmServiceCheckpoint(context, ServiceKind.weather);
    ushort previous;
    Duration age;
    assert(!restarted.load(true, previous, age).length);
    assert(restarted.save(true, &snapshot));
    assert(db.loadServiceCheckpoint(ServiceKind.weather, context.config.realmId).revision == 2);
    assert(!first.save(true, &snapshot));
}
