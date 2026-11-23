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
            const row = context.database.loadServiceCheckpoint(kind, context.config.realmId);
            revision = row.revision;
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

    void save(bool changed, scope ubyte[] delegate() snapshot)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import std.base64 : Base64;

        if (context is null || !context.canWrite())
            return;
        const now = context.unixTime;
        if (!changed && now < nextSave)
            return;
        nextSave = now + 10;
        try
        {
            const row = ServiceCheckpoint(revision, now, context.nodeId, "1:" ~ Base64.encode(snapshot()).idup);
            if (context.database.saveServiceCheckpoint(kind, context.config.realmId, row))
                ++revision;
            else if (context.canWrite())
            {
                warning!"%s: another host has a newer service checkpoint"(kind);
                context = null;
            }
        }
        catch (DatabaseException error)
            warning!"%s: could not checkpoint the service: %s"(kind, error.msg);
    }
}
