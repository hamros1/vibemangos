/// Shared selections and respawn deadlines for outdoor game-object pools.
module dmangos.world.gameobjectpools;

import std.algorithm.searching : all, any;
import std.random : Random;
import dmangos.log : warning;
import dmangos.mysql : DatabaseException;
import dmangos.world.database : GameObjectPoolPlacement, GameObjectPoolState, WorldDatabase;
import dmangos.world.worlddata : PoolChooser, PoolMember, WorldData;

package final class GameObjectPools
{
    private WorldDatabase delegate() database;
    private uint realm;
    private PoolChooser chooser;
    private uint[uint] poolOf;
    private GameObjectPoolState[uint] initial, saved;
    private struct Exhausted
    {
        long due;
        bool chest;
    }
    private Exhausted[uint] pending;

    this(WorldDatabase delegate() database, uint realm, WorldData world, ref long[uint] oldTimers, bool enabled)
    {
        this.database = database;
        this.realm = realm;
        chooser = world.pools;
        if (!enabled || chooser is null)
            return;
        bool[uint] onContinent;
        foreach (ref spawn; world.gameObjectSpawns)
            if ((spawn.map == 0 || spawn.map == 1) && spawn.respawnSeconds >= 0)
                onContinent[spawn.guid] = true;
        foreach (pool, members; chooser.gameObjectPools())
            if (members.all!(spawn => spawn in onContinent))
                foreach (spawn; members)
                {
                    poolOf[spawn] = pool;
                    if (chooser.spawns(PoolMember.Kind.gameObject, spawn))
                        initial.require(pool, GameObjectPoolState.init).placements ~= GameObjectPoolPlacement(spawn, 0);
                }
        if (poolOf.length)
        {
            saved = database().loadGameObjectPoolStates(realm);
            adoptTimers(oldTimers);
        }
    }

    bool manages(uint spawn) const { return (spawn in poolOf) !is null; }

    bool selected(uint spawn) const
    {
        return selection(poolOf.get(spawn, 0)).placements.any!(slot => slot.spawn == spawn);
    }

    bool waiting(uint spawn) const
    {
        return spawn in pending
            || selection(poolOf.get(spawn, 0)).placements.any!(slot => slot.spawn == spawn && slot.due);
    }

    void exhausted(uint spawn, long due, bool chest)
    {
        pending[spawn] = Exhausted(due, chest);
        savePending(spawn);
    }

    bool refresh()
    {
        if (!poolOf.length)
            return false;
        try
        {
            saved = database().loadGameObjectPoolStates(realm);
            foreach (spawn; pending.keys)
                savePending(spawn);
            return true;
        }
        catch (DatabaseException error)
        {
            warning!"game object pools: could not refresh selections: %s"(error.msg);
            return false;
        }
    }

    const(GameObjectPoolState[uint]) states() const { return saved; }

    uint roll(uint pool, uint spawn, const ref GameObjectPoolState state, ref Random rng) const
    {
        import std.algorithm.iteration : map;
        import std.array : array;

        return chooser.rollWorldGameObject(pool, spawn, state.placements.map!(slot => slot.spawn).array, rng);
    }

    bool change(uint pool, const ref GameObjectPoolState state, uint exhaustedChest = 0)
    {
        try
        {
            if (!database().updateGameObjectPoolState(realm, pool, state, exhaustedChest))
                return false;
            saved[pool] = GameObjectPoolState(state.revision + 1, state.placements.dup);
            return true;
        }
        catch (DatabaseException error)
        {
            warning!"game object pool %s: could not save selection: %s"(pool, error.msg);
            return false;
        }
    }

private:
    const(GameObjectPoolState) selection(uint pool) const
    {
        return saved.get(pool, initial.get(pool, GameObjectPoolState.init));
    }

    void savePending(uint spawn)
    {
        const used = pending[spawn];
        const pool = poolOf[spawn];
        const current = selection(pool);
        auto slots = current.placements.dup;
        foreach (ref slot; slots)
            if (slot.spawn == spawn)
            {
                if (slot.due)
                    break; // a previous attempt has already written the cooldown
                slot.due = used.due;
                const next = GameObjectPoolState(current.revision, slots);
                if (!change(pool, next, used.chest ? spawn : 0))
                    return; // another worker may have updated one of the pool's other placements
                break;
            }
        pending.remove(spawn);
    }

    void adoptTimers(ref long[uint] oldTimers)
    {
        import std.algorithm.sorting : sort;

        GameObjectPoolPlacement[][uint] legacy;
        foreach (spawn; oldTimers.keys)
            if (const pool = spawn in poolOf)
            {
                if (*pool !in saved)
                    legacy[*pool] ~= GameObjectPoolPlacement(spawn, oldTimers[spawn]);
                oldTimers.remove(spawn);
            }
        foreach (pool, slots; legacy)
        {
            const chosen = initial.get(pool, GameObjectPoolState.init).placements;
            if (!chosen.length)
                continue;
            slots.sort!((a, b) => a.due != b.due ? a.due > b.due : a.spawn < b.spawn);
            if (slots.length > chosen.length)
                slots.length = chosen.length;
            foreach (seed; chosen)
                if (slots.length < chosen.length && !slots.any!(slot => slot.spawn == seed.spawn))
                    slots ~= seed;
            const state = GameObjectPoolState(0, slots);
            change(pool, state);
        }
        if (legacy.length)
            saved = database().loadGameObjectPoolStates(realm);
    }
}
