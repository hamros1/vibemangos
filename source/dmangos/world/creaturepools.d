/// Durable choices for world creature pools that can have one placement active at a time.
module dmangos.world.creaturepools;

import std.random : Random;
import dmangos.log : warning;
import dmangos.mysql : DatabaseException;
import dmangos.world.database : CreaturePoolState, WorldDatabase;
import dmangos.world.worlddata : PoolChooser, PoolMember, WorldData;

package final class CreaturePools
{
    private WorldDatabase delegate() database;
    private uint realm;
    private PoolChooser chooser;
    private uint[uint] poolOf;
    private CreaturePoolState[uint] saved;
    private CreaturePoolState[uint] pending;

    this(WorldDatabase delegate() database, uint realm, WorldData world, ref long[uint] oldTimers)
    {
        this.database = database;
        this.realm = realm;
        chooser = world.pools;
        if (chooser is null)
            return;

        import std.algorithm.searching : all;

        bool[uint] onContinent;
        foreach (ref spawn; world.creatureSpawns)
            if (spawn.map == 0 || spawn.map == 1)
                onContinent[spawn.guid] = true;
        foreach (pool, members; chooser.singleCreaturePools())
            if (members.all!(guid => guid in onContinent))
                foreach (guid; members)
                    poolOf[guid] = pool;
        if (!poolOf.length)
            return;

        read();
        // Older builds left pooled timers in creature_respawn. Keep the latest outstanding choice if the
        // pool has no durable selection yet. Once it does, old timers cannot revive another placement.
        CreaturePoolState[uint] legacy;
        foreach (guid; oldTimers.keys)
            if (const pool = guid in poolOf)
            {
                const due = oldTimers[guid];
                oldTimers.remove(guid);
                if (*pool in saved || due <= 0)
                    continue;
                auto previous = legacy.get(*pool, CreaturePoolState.init);
                if (due > previous.due || (due == previous.due && guid < previous.spawn))
                    legacy[*pool] = CreaturePoolState(guid, due);
            }
        foreach (pool, state; legacy)
            change(pool, 0, state.spawn, state.due);
        if (legacy.length)
            read();
    }

    bool manages(uint spawn) const { return (spawn in poolOf) !is null; }
    bool contains(uint pool, uint spawn) const { return pool && poolOf.get(spawn, 0) == pool; }

    bool selected(uint spawn) const
    {
        if (const pool = spawn in poolOf)
            if (const state = *pool in saved)
                if (poolOf.get(state.spawn, 0) == *pool)
                    return state.spawn == spawn;
        return chooser is null || chooser.spawns(PoolMember.Kind.creature, spawn);
    }

    bool waiting(uint spawn) const
    {
        if (const pool = spawn in poolOf)
        {
            const state = saved.get(*pool, CreaturePoolState.init);
            return spawn in pending || (state.spawn == spawn && state.due > 0);
        }
        return false;
    }

    /// Records the original deadline once. GM or linked respawns may bring an existing one forward.
    void dead(uint spawn, long due, bool earlier = false)
    {
        const pool = poolOf.get(spawn, 0);
        if (!pool || !selected(spawn))
            return;
        const old = saved.get(pool, CreaturePoolState.init);
        if (old.spawn == spawn && old.due && (!earlier || old.due <= due))
            return;
        if (const previous = spawn in pending)
            if (!earlier || previous.due <= due)
                return;
        const attempt = CreaturePoolState(spawn, due, old.revision);
        pending[spawn] = attempt;
        savePending(attempt);
    }

    /// Read current choices after region migration or before processing their deadlines.
    bool refresh()
    {
        if (!poolOf.length)
            return false;
        try
        {
            read();
            foreach (spawn; pending.keys)
                savePending(pending[spawn]);
            return pending.length == 0; // a failed death write must not respawn the ready database row
        }
        catch (DatabaseException error)
        {
            warning!"creature pools: could not read current selections: %s"(error.msg);
            return false;
        }
    }

    /// Polling provides live choices to the placement's owner, including changes made on a different node.
    const(CreaturePoolState[uint]) states() const { return saved; }

    uint roll(uint pool, uint spawn, ref Random rng) const
    {
        return chooser.rollSingleCreature(pool, spawn, rng);
    }

    bool change(uint pool, ulong revision, uint spawn, long due)
    {
        try
        {
            if (!database().updateCreaturePoolState(realm, pool, revision, spawn, due))
                return false;
            saved[pool] = CreaturePoolState(spawn, due, revision + 1);
            return true;
        }
        catch (DatabaseException error)
        {
            warning!"creature pool %s: could not save spawn %s: %s"(pool, spawn, error.msg);
            return false;
        }
    }

private:
    void read() { saved = database().loadCreaturePoolStates(realm); }

    void savePending(CreaturePoolState attempt)
    {
        const pool = poolOf[attempt.spawn];
        const state = saved.get(pool, CreaturePoolState.init);
        if (state.revision != attempt.revision || !selected(attempt.spawn)
            || change(pool, attempt.revision, attempt.spawn, attempt.due))
            pending.remove(attempt.spawn);
    }
}
