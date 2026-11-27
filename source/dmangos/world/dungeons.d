/**
 * The dungeon copies this node hosts and players' and groups' binds to them: which copy a player enters, a copy's
 * saved state (its dead, its used-up objects, its script's data), raid resets, a dungeon's copies handed between
 * nodes, and copies unloaded when empty (`WorldContext.dungeons`).
 */
module dmangos.world.dungeons;

import dmangos.bytes : ByteReader, ByteWriter;
import core.time : MonoTime;
import dmangos.world.creature : Creature;
import dmangos.world.gameobject : GameObject, GameObjectSpawn;
import dmangos.world.movement : Position;
import dmangos.world.migration : Migrant, MigrantKind;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.objects : HighGuid, makeGuid, temporaryCounterStart;
import dmangos.world.bgqueue : battlegroundOfMap;
import dmangos.script.api : EntityRef;
import dmangos.world.instancescripting : InstanceScript;
import dmangos.world.database : DungeonFightCheckpoint, InstanceChestRecord, InstanceCorpseRecord, PickpocketRecord,
    QuestActorCheckpoint, WorldDatabase;
import dmangos.world.map : Map, MapObject;
import dmangos.world.worlddata : PoolMember;
import dmangos.world.context : WorldContext;

/// See the module documentation.
final class Dungeons
{
    private WorldContext world;

    this(WorldContext world)
    {
        this.world = world;
    }

    // -----------------------------------------------------------------------
    // Dungeon instances: their copies, saved state and players' binds
    // -----------------------------------------------------------------------

    /// What is kept of an instance: its map, when it emptied, its dead and used-up spawns.
    static struct InstanceState
    {
        uint mapId;
        long resetAt;          /// a raid's reset (Unix time): its lockout lasts till then; 0 for a dungeon
        long createdAt;        /// when it was made (or, saved, read back), Unix time
        MonoTime emptySince;   /// MonoTime.init while someone is in it
        bool[uint] dead;       /// creature spawns killed there
        bool[uint] usedUp;     /// game object spawns used up there
        string data;           /// its dungeon script's state (`instance.data`)
        InstanceChestRecord[uint] chests; /// scripted reward loot, by spawn
        InstanceCorpseRecord[uint] corpses; /// unexpired defeated creatures, by spawn
        long[uint] trashRespawns;         /// Molten Core trash deadlines, by spawn
    }

    package Map[uint] instanceMaps;            // instance id -> its map
    package InstanceState[uint] instances;     // instance id -> its state
    package uint[uint][ulong] playerBinds;     // player guid -> map id -> instance (`character_instance`)
    package uint[uint][ulong] groupBinds;      // group leader guid -> map id -> instance (`group_instance`)

    /**
     * Whether map `mapId` is a dungeon whose groups each get a copy of it.
     * In a cluster a dungeon is one region (never split), and the node owning it hosts every copy.
     */
    bool instanceable(uint mapId)
    {
        const entry = world.client.maps.lookup(mapId);
        return entry !is null && (entry.isDungeon || entry.isBattleground);
    }

    /**
     * The node hosting dungeon `mapId`'s copies: the owner of its one region; this node standalone;
     * 0 while nobody owns it (a lost owner's lease not over yet).
     */
    ushort dungeonHost(uint mapId)
    {
        if (world.regionOwnerAround is null)
            return world.nodeId;
        return world.regionOwnerAround(mapId, Position(0, 0, 0), 0);
    }

    /// Whether this node hosts dungeon `mapId`'s copies: it decides which one a player goes into.
    bool hostsDungeon(uint mapId)
    {
        return world.regionOwnerAround is null || dungeonHost(mapId) == world.nodeId;
    }

    /**
     * The instance of `mapId` the player goes into: its group's, else its own, else a new one, to
     * which it (and its group) are bound.
     * 0 for a map that is not instanced, or (in a cluster) a dungeon another node hosts: the player
     * goes there (`InWorldHandlers.migrateTo`), and gets its copy there.
     */
    uint instanceFor(ulong player, uint mapId, scope bool delegate(uint) admit = null)
    {
        import dmangos.cluster.ownership : IdKind;
        import dmangos.log : info, warning;

        if (!instanceable(mapId) || !hostsDungeon(mapId))
            return 0;
        // A battleground's copy is the one the queue sent the player to.
        if (battlegroundOfMap(mapId))
            return world.database.loadBattlegroundData(cast(uint) player).instance;
        auto group = world.groups.of(player);
        const raid = world.client.maps.lookup(mapId).isRaid;
        uint chosen = boundInstance(player, mapId);
        const fresh = chosen == 0;
        if (fresh)
        {
            // Ids are the cluster's (each node makes the copies of its own dungeons).
            if (!world.takeId(IdKind.instance, chosen) || chosen == 0)
            {
                warning!"instance of map %s not made: no instance ids (the coordinator's next block has not come)"(mapId);
                return 0;
            }
        }
        if (admit !is null && !admit(chosen))
            return 0;
        if (fresh)
        {
            const resetAt = raid ? raidResetAt(mapId) : 0;
            instances[chosen] = InstanceState(mapId, resetAt, world.unixTime);
            world.database.saveInstance(chosen, mapId, resetAt);
            info!"instance %s of map %s made"(chosen, mapId);
        }
        if (playerBinds.get(player, null).get(mapId, 0) != chosen)
        {
            playerBinds.require(player, null)[mapId] = chosen;
            world.database.saveInstanceBind(false, cast(uint) player, chosen, raid);
        }
        if (group !is null && groupBinds.get(group.leader, null).get(mapId, 0) !in instances)
        {
            groupBinds.require(group.leader, null)[mapId] = chosen;
            world.database.saveInstanceBind(true, cast(uint) group.leader, chosen, raid);
        }
        return chosen;
    }

    /// The copy of `mapId` the player would go into, of those that exist: a raid's lockout, its
    /// group's, its own; 0 if a new one would be made.
    uint boundInstance(ulong player, uint mapId)
    {
        const raid = world.client.maps.lookup(mapId).isRaid;
        auto group = world.groups.of(player);
        if (raid)
            if (auto bound = mapId in playerBinds.get(player, null))
                if (*bound in instances)
                    return *bound;
        if (group !is null)
            if (auto bound = mapId in groupBinds.get(group.leader, null))
                if (*bound in instances)
                    return *bound;
        if (auto bound = mapId in playerBinds.get(player, null))
            if (*bound in instances)
                return *bound;
        return 0;
    }

    /**
     * On the node hosting dungeon `mapId`: whether `player` may go in (into `toInstance`, uint.max:
     * the copy it would get); 0 if so, else `SMSG_TRANSFER_ABORTED`'s reason (a lockout, a full copy).
     */
    ubyte dungeonEntryProblem(ulong player, uint mapId, uint toInstance, bool gameMaster)
    {
        enum ubyte abortMaxPlayers = 0x01, abortNotFound = 0x02;
        if (!instanceable(mapId) || !hostsDungeon(mapId))
            return abortNotFound;
        if (toInstance == uint.max && lockedOutOfGroupRaid(player, mapId))
            return abortNotFound;
        const instance = toInstance != uint.max ? toInstance : boundInstance(player, mapId);
        if (instance && !gameMaster)
            if (const most = mapId in world.data.instanceMaxPlayers)
                if (auto there = world.existingMap(mapId, instance))
                    if (there.population >= *most)
                        return abortMaxPlayers;
        return 0;
    }

    bool instanceLimitReached(uint account, uint instance)
    {
        return world.database.instanceLimitReached(account, instance, world.unixTime);
    }

    bool enteredInstance(uint account, uint instance)
    {
        return world.database.admitInstance(account, instance, world.unixTime);
    }

    /// Asks the node hosting a dungeon whether a player may go in (`dungeonEntryProblem` there); null standalone.
    void delegate(ushort host, ulong player, uint map, uint instance, bool gameMaster,
        void delegate(ubyte abort) then) askDungeonEntry;

    /**
     * Entering a dungeon: a player who is not a game master, sent into a copy of `mapId` (summoned,
     * appearing), is bound to it unless it is bound to a copy of that map already.
     */
    void bindOnEntering(ulong player, uint mapId, uint instance)
    {
        if (!instance || instance !in instances || mapId in playerBinds.get(player, null) || battlegroundOfMap(mapId))
            return;
        playerBinds.require(player, null)[mapId] = instance;
        world.database.saveInstanceBind(false, cast(uint) player, instance, instances[instance].resetAt != 0);
    }

    /**
     * A raid's lockout: whether the player is bound to another copy of raid `mapId` than its group's
     * (such a player may not enter).
     */
    bool lockedOutOfGroupRaid(ulong player, uint mapId)
    {
        const entry = world.client.maps.lookup(mapId);
        if (entry is null || !entry.isRaid || !instanceable(mapId))
            return false;
        auto group = world.groups.of(player);
        if (group is null)
            return false;
        const mine = playerBinds.get(player, null).get(mapId, 0), theirs = groupBinds.get(group.leader, null).get(mapId, 0);
        return mine && theirs && mine != theirs && mine in instances && theirs in instances;
    }

    /// The instances saved: their rows, binds and dead, read at start-up.
    package long[uint] raidResets_;   /// each raid map's next reset (Unix time), as `instance_reset` keeps it
    package bool raidResetsRead;

    /**
     * When the raid `mapId`'s copies next reset, all together: at `instance_reset_time_hour` every
     * `raidResetDays` days, counted on from the last, kept in `instance_reset`.
     */
    long raidResetAt(uint mapId)
    {
        if (!raidResetsRead)
        {
            raidResetsRead = true;
            raidResets_ = world.database.loadRaidResets();
        }
        const now = world.unixTime;
        auto t = raidResets_.get(mapId, 0);
        if (t > now)
            return t;
        const t2 = nextRaidReset(t, now, raidResetDays(mapId), world.config.instanceResetTimeHour);
        raidResets_[mapId] = t2;
        world.database.saveRaidReset(mapId, t2);
        return t2;
    }

    /**
     * How many days apart raid `mapId`'s copies reset: Blizzard's interval (`ClientData.resetIntervalDays`), else
     * (no data/instance-resets.csv) `instance_template.reset_delay`, else a week.
     */
    uint raidResetDays(uint mapId) const
    {
        bool known;
        const days = world.client.resetIntervalDays(mapId, known);
        return known && days ? days : world.data.instanceResetDays.get(mapId, 7);
    }

    /**
     * The reset after `last` (0: none yet) that is after `now`, every `days` days at `hour` (as the reference
     * counts them: the first `days` after today).
     */
    static long nextRaidReset(long last, long now, uint days, uint hour) pure nothrow @nogc @safe
    {
        enum long day = 86_400;
        const period = (days ? days : 7) * day, diff = (hour % 24) * 3600L;
        const today = now / day * day;
        if (last == 0)
            return today + period + diff;
        long t = last / day * day;
        t += ((today - t) / period + 1) * period + diff;
        while (t <= now)
            t += period;
        return t;
    }

    /// When copy `instance` resets (Unix time); 0 for none (a dungeon, or not a copy known here).
    long instanceResetAt(uint instance)
    {
        if (auto s = instance in instances)
            return s.resetAt;
        return 0;
    }

    package void loadInstances()
    {
        loadInstancesOf((uint) => true);
    }

    /// The saved instances of the maps `which` accepts, read anew (replacing what was known of them).
    package void loadInstancesOf(scope bool delegate(uint mapId) which)
    {
        import std.algorithm.comparison : max;
        import dmangos.cluster.ownership : IdKind;

        const saved = world.database.loadInstances();
        foreach (r; saved.instances)
            if (which(r.map))
            {
                instances[r.id] = InstanceState(r.map, r.resetTime, world.unixTime);
                instances[r.id].data = r.data;
                world.raise(IdKind.instance, r.id + 1);
                if (!world.config.cluster.enabled) // its saved actors keep their GUIDs: the next summons count from above
                {
                    const highest = InstanceScript.highestSavedSummon(r.data);
                    if (highest >= temporaryCounterStart)
                        world.summonsMade = max(world.summonsMade, highest - temporaryCounterStart);
                }
            }
        foreach (b; saved.binds)
            if (auto state = b.instance in instances)
                if (which(state.mapId))
                {
                    if (b.group)
                        groupBinds.require(b.owner, null)[state.mapId] = b.instance;
                    else
                        playerBinds.require(b.owner, null)[state.mapId] = b.instance;
                }
        foreach (r; saved.respawns)
            if (auto state = r.instance in instances)
                if (which(state.mapId))
                {
                    if (r.gameObject)
                        state.usedUp[r.spawnGuid] = true;
                    else
                    {
                        state.dead[r.spawnGuid] = true;
                        if (!world.config.cluster.enabled && r.spawnGuid >= temporaryCounterStart)
                            world.summonsMade = max(world.summonsMade, r.spawnGuid - temporaryCounterStart);
                        if (const spawn = world.creatureSpawnOf(r.spawnGuid))
                            if (world.deadCreatures.moltenCoreTrash(*spawn) && r.until > 0 && (!state.resetAt || r.until < state.resetAt))
                                state.trashRespawns[r.spawnGuid] = r.until;
                    }
                }
        foreach (chest; saved.chests)
            if (auto state = chest.instance in instances)
                if (which(state.mapId))
                    state.chests[chest.spawn] = chest;
        foreach (corpse; saved.corpses)
            if (auto state = corpse.instance in instances)
                if (which(state.mapId) && corpse.expiresAt > world.unixTime && corpse.spawn in state.dead)
                    state.corpses[corpse.spawn] = corpse;
    }

    /**
     * A dungeon's copies are another node's now (its region moved): what this node knew of them goes
     * from memory (not from the database, which the new host reads). A copy with players in it stays
     * until they have moved on (`unloadEmptyInstances`).
     */
    package void dungeonLost(uint mapId)
    {
        if (battlegroundOfMap(mapId))
            world.battlegrounds.forgetMap(mapId);
        foreach (id; instances.keys)
            if (instances[id].mapId == mapId)
            {
                const m = instanceMaps.get(id, null);
                if (m is null || m.population == 0)
                    forgetInstance(id);
            }
    }

    /// This node hosts dungeon `mapId` now: its copies, binds and dead as the last host saved them.
    package void dungeonGained(uint mapId)
    {
        import dmangos.log : info;

        foreach (id; instances.keys)
            if (instances[id].mapId == mapId && instanceMaps.get(id, null) is null)
                forgetInstance(id);
        loadInstancesOf((uint m) => m == mapId);
        size_t count;
        foreach (ref state; instances)
            count += state.mapId == mapId;
        if (count)
            info!"cluster: dungeon map %s is hosted here now, with %s saved instances"(mapId, count);
    }

    /// The copies of dungeon `mapId` and their pending database actions for the next owner.
    package const(ubyte)[] dungeonCopiesOut(uint mapId, ushort next)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.log : info;
        import dmangos.world.battlegroundstate : BattlegroundState;
        import dmangos.world.migration : encodeBundle;
        import std.algorithm.searching : canFind;

        ByteWriter w;
        ByteWriter deadlines;
        world.saveDungeonObjectDeadlines(mapId, deadlines); // before migrateOut removes the local objects and their timers
        uint[] ids;
        foreach (id, m; instanceMaps)
            if (instances.get(id, InstanceState.init).mapId == mapId && m.instanceId == id)
                ids ~= id;
        const bg = battlegroundOfMap(mapId);
        if (bg)
            foreach (copy; world.battlegrounds.all)
                if (copy.mapId == mapId && !ids.canFind(copy.instance))
                    ids ~= copy.instance; // its first player may still be acknowledging the world port
        w.put(cast(uint) ids.length);
        // Each script's state goes first, with its encounter's creatures still here to capture (a save held back
        // by its two-second pace would otherwise be lost): the next host makes the script from `instance.data`.
        foreach (id; ids)
            if (auto script = world.instanceScripts.get(id, null))
                script.saveNow();
        world.settleWrites();
        foreach (id; ids)
        {
            auto m = instanceMaps.get(id, null);
            const before = m is null ? 0 : m.objectCount - m.replicaCount;
            const bundle = m is null ? encodeBundle(null, null) : m.migrateOut((ulong) => true, next, &world.saveMigrant);
            w.put(id);
            w.put(cast(uint) bundle.length);
            w.putBytes(bundle);
            if (bg)
            {
                ByteWriter match;
                if (auto copy = world.battlegrounds.find(id))
                {
                    auto state = BattlegroundState(world.clock(), writer: &match);
                    copy.transferState(state);
                    auto stored = instances.get(id, InstanceState.init);
                    state.transfer(stored.dead, stored.usedUp);
                    copy.transferPause(state);
                }
                w.put(cast(uint) match.data.length);
                w.putBytes(match.data);
            }
            info!"migration: instance %s of map %s leaves for node %s with %s objects"(id, mapId, next,
                m is null ? 0 : before - (m.objectCount - m.replicaCount));
        }
        world.saveDungeonScriptRuns(mapId, w, true);
        w.putBytes(deadlines.data);
        return w.data;
    }

    /// A copy being made for `dungeonCopiesIn` (its script's `Restored` is not raised: its creatures come along).
    package bool copyArriving;

    /// The same object and match data used for a clean handoff, captured without releasing the live map.
    package const(ubyte)[] snapshotBattleground(imported!"dmangos.world.battleground".Battleground copy)
    {
        import dmangos.world.battlegroundstate : BattlegroundState;
        import dmangos.world.migration : encodeBundle;

        auto m = world.existingMap(copy.mapId, copy.instance);
        const bundle = m is null ? encodeBundle(null, null) : m.snapshotObjects((MapObject object) {
            if (auto creature = cast(Creature) object)
                if (creature.meleeController || creature.totemOwner || creature.guardianOwner)
                    return Migrant.init;
            return world.saveMigratingObject(object, false);
        });
        ByteWriter w, match;
        auto state = BattlegroundState(world.clock(), writer: &match);
        copy.transferState(state, durableSnapshot: true);
        copy.transferPause(state);
        w.put(cast(uint) match.length);
        w.putBytes(match.data);
        w.put(cast(uint) bundle.length);
        w.putBytes(bundle);
        auto stored = instances.get(copy.instance, InstanceState.init);
        state.writer = &w;
        state.transfer(stored.dead, stored.usedUp);
        world.saveDungeonScriptRuns(copy.mapId, w, false, copy.instance);
        world.saveDungeonObjectDeadlines(copy.mapId, w, copy.instance);
        return w.data;
    }

    package void restoreBattleground(uint mapId, uint id, const(ubyte)[] bytes, uint formatVersion = 3)
    {
        import dmangos.world.battlegroundstate : BattlegroundState;

        auto r = ByteReader(bytes);
        auto match = ByteReader(r.readBytes(r.read!uint));
        const bundle = r.readBytes(r.read!uint);
        auto stored = InstanceState(mapId, 0, world.unixTime);
        auto state = BattlegroundState(world.clock(), reader: &r);
        state.transfer(stored.dead, stored.usedUp);
        auto copy = world.battlegrounds.restore(id, battlegroundOfMap(mapId), match, formatVersion);
        auto matchState = BattlegroundState(world.clock(), reader: &match);
        copy.transferPause(matchState);
        instances[id] = stored;
        restoreDungeonCopy(mapId, id, bundle);
        world.restoreDungeonScriptRuns(mapId, r);
        world.restoreDungeonObjectDeadlines(mapId, r);
        copy.recoveredAfterCrash();
    }

    /// What `dungeonCopiesOut` sent: each copy made here and its objects as they were.
    package void dungeonCopiesIn(uint mapId, const(ubyte)[] copies)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : info;
        import dmangos.world.battlegroundstate : BattlegroundState;

        if (copies.length < 4)
            return;
        auto r = ByteReader(copies);
        const bg = battlegroundOfMap(mapId);
        foreach (_; 0 .. r.read!uint)
        {
            const id = r.read!uint;
            const bundle = r.readBytes(r.read!uint);
            if (bg)
            {
                const match = r.readBytes(r.read!uint);
                if (!match.length)
                    continue;
                auto reader = ByteReader(match);
                auto copy = world.battlegrounds.restore(id, bg, reader);
                auto stored = InstanceState(mapId, 0, world.unixTime);
                auto state = BattlegroundState(world.clock(), reader: &reader);
                state.transfer(stored.dead, stored.usedUp);
                copy.transferPause(state);
                instances[id] = stored;
            }
            if (id !in instances)
                continue; // reset meanwhile
            info!"migration: instance %s of map %s arrived with %s objects"(id, mapId,
                restoreDungeonCopy(mapId, id, bundle));
        }
        if (!r.empty) // older owners sent only the copy/object pairs
        {
            world.restoreDungeonScriptRuns(mapId, r);
            world.restoreDungeonObjectDeadlines(mapId, r);
        }
    }

    package size_t restoreDungeonCopy(uint mapId, uint id, const(ubyte)[] bundle)
    {
        import dmangos.world.gameobject : GameObject;

        Map m;
        {
            copyArriving = true;
            scope (exit) copyArriving = false;
            m = world.map(mapId, id);
        }
        const before = m.objectCount - m.replicaCount;
        auto copy = battlegroundOfMap(mapId) ? world.battlegrounds.find(id) : null;
        ArrivedObject[] arrived;
        m.migrateIn(bundle, (const ref Migrant migrant) {
            auto object = world.restoreWorldMigrant(migrant, m);
            if (auto creature = cast(Creature) object)
                creature.instanceId = id;
            else if (auto go = cast(GameObject) object)
            {
                if (copy !is null && go.spawn.battlegroundPowerUp
                    && !copy.powerUpAvailable(go.spawn.guid, true))
                    return null;
                go.instanceId = id;
            }
            if (object !is null)
                arrived ~= ArrivedObject(object.guid, migrant.kind);
            return object;
        });
        if (world.recovery.ownsDungeonFights(m))
            world.recovery.restoreDungeonFights(m, true);
        const restored = m.objectCount - m.replicaCount - before;
        if (copy !is null)
            copy.reconcilePowerUps(m);
        copyObjectsArrived(id, arrived);
        return restored;
    }

    package static struct ArrivedObject
    {
        ulong guid;
        MigrantKind kind;
    }

    /**
     * A copy's objects came in from another node: its script, made afresh from `instance.data`, learns them as it
     * would from their cells loading (`CreatureLoaded`, `ObjectLoaded`), so the doors and bosses it holds by
     * reference answer again. A summon is told only if the encounter keeps it in its checkpoint, as when it comes
     * back from one (`InstanceScript.restorePendingSummons`).
     */
    package void copyObjectsArrived(uint id, const(ArrivedObject)[] arrived)
    {
        import dmangos.script.api : CreatureLoaded, EntityRef, ObjectLoaded;

        auto script = world.instanceScripts.get(id, null);
        if (script is null)
            return;
        foreach (object; arrived)
        {
            const entity = EntityRef(object.guid);
            final switch (object.kind)
            {
            case MigrantKind.creature:
                script.raise(CreatureLoaded(entity));
                break;
            case MigrantKind.gameObject:
                script.raise(ObjectLoaded(entity));
                break;
            case MigrantKind.summonedCreature:
                if (script.keepsCheckpoint(entity))
                    script.raise(CreatureLoaded(entity, true));
                break;
            case MigrantKind.summonedGameObject:
                if (script.keepsCheckpoint(entity))
                    script.raise(ObjectLoaded(entity));
                break;
            case MigrantKind.none, MigrantKind.creatureRespawn, MigrantKind.gameObjectRespawn, MigrantKind.scriptRun:
                break;
            }
        }
    }

    /// An instance gone from this node's memory only (another node hosts it).
    package void forgetInstance(uint id)
    {
        instances.remove(id);
        dropInstanceMap(id);
        foreach (ref binds; playerBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
        foreach (ref binds; groupBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
    }

    /// Whether creature spawn `spawnGuid` is dead in instance `instance`.
    bool deadInInstance(uint instance, uint spawnGuid)
    {
        if (auto state = instance in instances)
            return (spawnGuid in state.dead) !is null;
        return false;
    }

    package bool entryKilledInInstance(uint instance, uint entry)
    {
        if (auto state = instance in instances)
            foreach (guid; state.dead.byKey)
                if (const idx = guid in world.spawnIndex)
                    if (world.data.creatureSpawns[*idx].entry == entry)
                        return true;
        return false;
    }

    package void respawnKilledInCopy(Map map, uint entry)
    {
        if (auto state = map.instanceId in instances)
            foreach (guid; state.dead.keys)
                if (const idx = guid in world.spawnIndex)
                {
                    const spawn = &world.data.creatureSpawns[*idx];
                    if (spawn.entry == entry)
                        world.respawnInCopy(map, spawn, cast(Creature) map.findObject(makeGuid(HighGuid.unit, entry, guid)));
                }
    }

    /// The instances that are made.
    @property size_t instanceCount() const
    {
        return instances.length;
    }

    package bool groupSpawnAllowed(Map where, uint type, uint guid)
    {
        if (const gate = guid in world.data.spawnConditions[type])
            return where !is null && world.mapConditionMet(where, gate.condition)
                && (!gate.expression || world.worldStateExpressionMet(where, gate.expression));
        return true;
    }

    /// Activate or retire conditional placements in owned, already-loaded cells.
    package void refreshConditionalSpawns()
    {
        void refresh(Map where)
        {
            const selected = where.id in world.data.conditionalSpawns;
            if (selected is null)
                return;
            const instance = where.instanceId;
            foreach (index; selected.creatures)
            {
                const spawn = &world.data.creatureSpawns[index];
                const home = cellKeyAt(spawn.x, spawn.y);
                if (!where.cellLoaded(home))
                    continue;
                const guid = makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
                auto alive = where.creatureAt(guid);
                if (!groupSpawnAllowed(where, 0, spawn.guid))
                {
                    if (alive !is null && alive.alive && (alive.ai is null || !alive.ai.inCombat))
                        where.removeObject(guid);
                    continue;
                }
                if (alive !is null || (instance ? deadInInstance(instance, spawn.guid)
                        : world.awaitingRespawn(spawn.guid) || world.creatureOnLoan(spawn.guid))
                    || !world.calendar.creatureInEvents(spawn.guid) || !world.upInPool(PoolMember.Kind.creature, spawn.guid))
                    continue;
                if (auto creature = world.makeCreature(spawn))
                {
                    creature.instanceId = instance;
                    where.addObject(creature);
                    world.links.queueLinked(where.id, instance, creature);
                }
            }
            foreach (index; selected.objects)
            {
                const ref spawn = world.data.gameObjectSpawns[index];
                if (!where.cellLoaded(cellKeyAt(spawn.x, spawn.y)))
                    continue;
                const guid = makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
                auto present = cast(GameObject) where.findObject(guid);
                if (!groupSpawnAllowed(where, 1, spawn.guid))
                {
                    if (present !is null)
                        where.removeObject(guid);
                }
                else if (present is null)
                {
                    if (!instance)
                    {
                        if (auto object = world.spawnWorldGameObject(spawn))
                            where.addObject(object);
                        continue;
                    }
                    if (auto object = spawnGameObjectInCopy(where.id, instance, spawn))
                    {
                        where.addObject(object);
                        if (auto script = world.instanceScripts.get(instance, null))
                            script.raise(imported!"dmangos.script.api".ObjectLoaded(EntityRef(object.guid)));
                    }
                }
            }
        }
        foreach (where; world.maps)
            refresh(where);
        foreach (where; instanceMaps)
            refresh(where);
    }

    /// A cell of an instance loading: the cell's spawns but those killed or used up in it.
    package MapObject[] spawnCellIn(uint mapId, uint instance, ulong cell)
    {
        import dmangos.world.gameobject : GameObject;

        auto state = instance in instances;
        auto script = world.instanceScripts.get(instance, null);
        // A battleground's copy: only the spawns of its events now.
        auto copy = battlegroundOfMap(mapId) ? world.battlegrounds.find(instance) : null;
        MapObject[] spawned;
        if (auto cells = mapId in world.data.creatureCells)
            foreach (index; (*cells).get(cell, null))
            {
                if (state !is null && world.data.creatureSpawns[index].guid in state.dead)
                    continue;
                if (const tracking = instance in world.recovery.dungeonFights)
                    if (const fight = world.data.creatureSpawns[index].guid in *tracking)
                        if (instanceMaps[instance].creatureAt(fight.guid) !is null)
                            continue;
                if (script !is null && script.restoringEntity(EntityRef(makeGuid(HighGuid.unit,
                    world.data.creatureSpawns[index].entry, world.data.creatureSpawns[index].guid))))
                    continue;
                if (!world.calendar.creatureInEvents(world.data.creatureSpawns[index].guid)
                        || !groupSpawnAllowed(world.existingMap(mapId, instance), 0, world.data.creatureSpawns[index].guid)
                        || !world.upInPool(PoolMember.Kind.creature, world.data.creatureSpawns[index].guid))
                    continue;
                if (copy !is null && !copy.spawnAllowed(world.data.creatureSpawns[index].guid in world.data.creatureBattleEvents))
                    continue;
                if (world.cantSpawnWhileBossDead(world.data.creatureSpawns[index], state))
                    continue;
                if (auto creature = world.makeCreature(&world.data.creatureSpawns[index]))
                {
                    creature.instanceId = instance;
                    spawned ~= creature;
                    world.links.queueLinked(mapId, instance, creature);
                }
            }
        if (auto cells = mapId in world.data.gameObjectCells)
            foreach (index; (*cells).get(cell, null))
                if (auto go = spawnGameObjectInCopy(mapId, instance, world.data.gameObjectSpawns[index]))
                    spawned ~= go;
        if (script !is null)
        {
            import std.algorithm.searching : canFind;
            import dmangos.script.api : CreatureLoaded, EntityRef, ObjectLoaded;

            script.loading = spawned;
            foreach (object; spawned)
                if (cast(Creature) object)
                    script.raise(CreatureLoaded(EntityRef(object.guid)));
                else
                    script.raise(ObjectLoaded(EntityRef(object.guid)));
            if (script.loading.length != spawned.length)
                foreach (object; spawned)
                    if (auto go = cast(GameObject) object)
                        if (!script.loading.canFind(object))
                            world.scripts.destroy(go.behaviour);
            spawned = script.loading;
            script.loading = null;
        }
        return spawned;
    }

    package GameObject spawnGameObjectInCopy(uint mapId, uint instance, const ref GameObjectSpawn spawn)
    {
        if (auto script = world.instanceScripts.get(instance, null))
            if (script.restoringEntity(EntityRef(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid))))
                return null;
        const state = instance in instances;
        const reward = state is null ? null : spawn.guid in state.chests;
        if ((spawn.respawnSeconds < 0 && reward is null) || (state !is null && spawn.guid in state.usedUp)
            || !world.calendar.gameObjectInEvents(spawn.guid) || !groupSpawnAllowed(world.existingMap(mapId, instance), 1, spawn.guid))
            return null;
        auto copy = battlegroundOfMap(mapId) ? world.battlegrounds.find(instance) : null;
        const available = copy !is null && spawn.battlegroundPowerUp ? copy.powerUpAvailable(spawn.guid)
            : world.upInPool(PoolMember.Kind.gameObject, spawn.guid);
        const event = spawn.guid in world.data.gameObjectBattleEvents;
        if (!available || (copy !is null && !copy.spawnAllowed(event)))
            return null;
        auto go = world.makeGameObject(spawn);
        go.instanceId = instance;
        if (reward !is null && !world.restoreReward(go, *reward))
        {
            world.scripts.destroy(go.behaviour);
            return null;
        }
        if (copy !is null && event !is null && (*event)[0] == 254 && copy.doorsOpen)
            go.setDoorOpen(true);
        return go;
    }

    /// After `Instance.UnloadDelay` empty, an instance's map is unloaded, and its binds go with it.
    package void unloadEmptyInstances(MonoTime now)
    {
        import core.time : seconds;
        import dmangos.log : info;

        uint[] gone, elsewhere;
        const time = world.unixTime;
        foreach (id, ref state; instances)
        {
            const m = instanceMaps.get(id, null);
            if (m !is null && m.population > 0)
            {
                state.emptySince = MonoTime.init;
                continue;
            }
            if (!hostsDungeon(state.mapId))
            {
                elsewhere ~= id; // another node's (or nobody's yet): it saves and resets its copies, not this one
                continue;
            }
            if (battlegroundOfMap(state.mapId))
                continue; // a battleground's copy closes when it is over and empty (`dmangos.world.battleground`)
            if (state.emptySince == MonoTime.init)
                state.emptySince = now;
            if (state.resetAt && time >= state.resetAt)
                gone ~= id; // a raid's reset time: empty (its players were sent out), it goes now
            else if (now - state.emptySince >= world.config.instanceUnloadDelay.seconds)
            {
                // A raid copy outlives its emptiness until its reset (only its map goes); a dungeon's resets.
                if (state.resetAt && time < state.resetAt)
                    dropInstanceMap(id, true);
                else
                    gone ~= id;
            }
        }
        foreach (id; elsewhere)
            forgetInstance(id);
        foreach (id; gone)
        {
            info!"instance %s of map %s reset: empty for %s seconds"(id, instances[id].mapId, world.config.instanceUnloadDelay);
            resetInstance(id);
        }
    }

    /**
     * The player (or, its group's leader, the group) resets its dungeons: each copy of a dungeon (not a
     * raid) it is bound to, hosted here, with nobody in it, is reset (`reset`); one with players inside
     * is not (`busy`). By map.
     */
    void resetDungeonsOf(ulong player, out uint[] reset, out uint[] busy)
    {
        import dmangos.log : info;

        uint[uint]* binds;
        if (auto group = world.groups.of(player))
        {
            if (group.leader != player)
                return;
            binds = group.leader in groupBinds;
        }
        else
            binds = player in playerBinds;
        if (binds is null)
            return;
        foreach (mapId, id; (*binds).dup)
        {
            const entry = world.client.maps.lookup(mapId);
            if (entry is null || entry.isRaid || !hostsDungeon(mapId))
                continue;
            if (auto m = instanceMaps.get(id, null))
                if (m.population > 0)
                {
                    busy ~= mapId;
                    continue;
                }
            info!"instance %s of map %s reset by its owner"(id, mapId);
            resetInstance(id);
            reset ~= mapId;
        }
    }

    /// An instance gone for good: its map, state, saved rows and binds.
    void resetInstance(uint id)
    {
        instances.remove(id);
        dropInstanceMap(id);
        world.database.deleteInstance(id);
        foreach (ref binds; playerBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
        foreach (ref binds; groupBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
    }

    /**
     * A copy's map goes from memory (unloaded, reset, shut down, another node's now): its scripts too. `keep`: the
     * copy goes on (unloaded or shut down, its objects still here), so its script saves its state first.
     */
    package void dropInstanceMap(uint id, bool keep = false)
    {
        if (keep)
            if (auto script = world.instanceScripts.get(id, null))
                script.saveNow();
        world.recovery.dungeonFights.remove(id);
        world.recovery.pendingDungeonFights.remove(id);
        if (auto m = instanceMaps.get(id, null))
            m.forEachObject((MapObject o) => world.objectGone(m, o));
        instanceMaps.remove(id);
        if (auto script = id in world.instanceScripts)
        {
            script.release();
            world.instanceScripts.remove(id);
        }
    }

    /// The instance's map if it is loaded, else null.
    Map instanceMap(uint id)
    {
        return instanceMaps.get(id, null);
    }

    /// The player's binds: map id -> instance.
    const(uint[uint]) bindsOf(ulong player)
    {
        return playerBinds.get(player, null);
    }

    /// Takes a player's bind to map `mapId` away.
    void revokeBind(ulong player, uint mapId)
    {
        if (auto binds = player in playerBinds)
            if (auto instance = mapId in *binds)
            {
                world.database.deleteInstanceBind(cast(uint) player, *instance);
                (*binds).remove(mapId);
            }
    }

    /// Shuts an instance down: its map goes (its state stays); false if it was not loaded.
    bool shutdownInstance(uint id)
    {
        auto m = instanceMaps.get(id, null);
        if (m is null)
            return false;
        dropInstanceMap(id, true);
        return true;
    }
}
