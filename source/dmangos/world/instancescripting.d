/**
 * A dungeon copy's script (docs/SCRIPTING.md): one per copy whose `instance_template.ScriptName` a
 * script serves. The world tells it of the copy's creatures and objects as they load and of the
 * creatures that die there; after every event its state is saved in the copy's `instance.data`, so
 * it outlives a restart and goes with the dungeon when another node comes to host it.
 */
module dmangos.world.instancescripting;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.log : info;
import dmangos.script.api;
import dmangos.script.registry : KindInfo, ScriptHandle, ScriptKind, ScriptRuntime;
import std.meta : staticIndexOf;
import dmangos.world.creature : Creature, TempSpawnType;
import dmangos.world.creatureai : CreatureLore;
import dmangos.world.movement : Position;
import dmangos.world.gameobject : GameObject;
import dmangos.world.map : Map, MapObject;
import dmangos.world.migration : Migrant, MigrantKind, decodeBundle, encodeBundle;

/// What `instance.data` starts with when a dungeon script wrote it.
enum string instanceDataPrefix = "dmangos-script:";
private enum string instanceSummonPrefix = ":summons1:";
private enum string instanceScriptRunsPrefix = ":steps1:";

/// The script bytes from a row written by a dungeon script, including older rows without summons.
package ubyte[] instanceScriptBytes(string data)
{
    import std.algorithm.searching : findSplit;

    return fromHex(data[instanceDataPrefix.length .. $].findSplit(":")[0]);
}

/// See the module documentation. It is also the core's side of the script's context.
final class InstanceScript : InstanceHost
{
    private
    {
        ScriptRuntime runtime;
        ScriptHandle handle;
        void delegate(string data, bool checkpoint) persist;
        string saved;
        uint id, mapId;
        bool world; // open-world round 2: a continent's script (`@world`), kept in memory only
        EntityRef[] durableSummons;
        Migrant[] pendingSummons;
        bool summonsPending;
        int sinceSummonSave;
        const(uint)[] durableScripts;
        const(ubyte)[] pendingScriptRuns;
    }

    /// The copy's map, once it is made.
    Map map;

    /// Objects of a cell being loaded, not on the map yet (a door opened now is open when it appears).
    MapObject[] loading;

    /// The world's creatures (summons); null in tests without one.
    CreatureLore lore;

    /// Read-only capture and cold restore of creatures that the encounter opted to checkpoint.
    Migrant delegate(EntityRef) captureSummon;
    MapObject delegate(const ref Migrant) restoreSummon;
    const(ubyte)[] delegate(const(uint)[]) captureScriptRuns;
    void delegate(const(ubyte)[]) restoreScriptRuns;
    void delegate(uint, EntityRef, EntityRef) startDatabaseEvent;

    /// A `Signal` for a game object's script (`InstanceContext.signal` to an object).
    bool delegate(GameObject go, Map map, EntityRef from, uint id, int value) signalObject;

    /// Puts the dungeon's game objects of an entry in the world (`InstanceContext.spawnObjects`).
    uint delegate(Map map, uint entry, uint despawnSeconds, Location near, float range) spawnObjects;

    /// Whether an entry is in this copy's persisted creature deaths.
    bool delegate(uint instance, uint entry) entryKilled;
    bool delegate(uint instance, ulong guid) spawnKilled;
    void delegate(Map map, uint entry) respawnKilled;

    // Raid scripts:

    /// Puts the game object of a spawn of `entry` on the copy's map in the world for `seconds` (0: for
    /// good); false if there is none (`WorldContext` sets it).
    bool delegate(Map map, uint entry, uint seconds) respawnObjectOf;

    /// A game object of `entry` (no spawn of the map's) put at `at` for `seconds` (0: for good); null if
    /// there is no such object (`WorldContext` sets it).
    GameObject delegate(Map map, uint entry, Location at, uint seconds) summonObjectAt;

    /**
     * The script `name` for copy `id` of `mapId`, its state read from `data` (`instance.data`);
     * `persist` writes its state back. Null if no script serves `name`.
     */
    static InstanceScript make(ScriptRuntime runtime, string name, uint id, uint mapId, string data,
        void delegate(string data, bool checkpoint) persist, scope EntityRef delegate(MigrantKind, uint) nativeSpawn,
        scope bool delegate(uint) defeated)
    {
        if (runtime is null || !runtime.serves(ScriptKind.instance, name))
            return null;
        auto script = new InstanceScript;
        script.runtime = runtime;
        script.handle = runtime.create(ScriptKind.instance, name);
        script.persist = persist;
        script.id = id;
        script.mapId = mapId;
        script.saved = data;
        if (data.length > instanceDataPrefix.length && data[0 .. instanceDataPrefix.length] == instanceDataPrefix)
        {
            auto bytes = instanceScriptBytes(data);
            auto r = ByteReader(bytes);
            if (runtime.load(script.handle, r))
            {
                script.fromSave = true;
                script.loadCreatures(data, nativeSpawn, defeated);
                script.loadScriptRuns(data);
            }
            else
                info!"instance %s: the saved state of script %s has another layout; it starts afresh"(id, name);
        }
        return script;
    }

    private void loadCreatures(string data, scope EntityRef delegate(MigrantKind, uint) nativeSpawn,
        scope bool delegate(uint) defeated)
    {
        import std.algorithm.searching : findSplit;
        import dmangos.world.creature : CreatureSpawn;
        import dmangos.world.gameobject : GameObjectSpawn;
        import dmangos.world.objects : HighGuid, makeGuid;
        import dmangos.serialization : deserialize;
        import dmangos.log : warning;

        const section = data.findSplit(instanceSummonPrefix)[2].findSplit(":")[0];
        if (!section.length)
            return;
        try
        {
            ulong[] cells;
            Migrant[] saved;
            decodeBundle(fromHex(section), cells, saved);
            EntityRef[] refs;
            Migrant[] accepted;
            foreach (ref migrant; saved)
            {
                EntityRef object;
                if (migrant.kind == MigrantKind.creature || migrant.kind == MigrantKind.gameObject)
                    object = nativeSpawn(migrant.kind, migrant.spawn);
                else if (migrant.kind == MigrantKind.summonedCreature)
                {
                    if (defeated(migrant.spawn))
                        continue;
                    auto r = ByteReader(migrant.state);
                    const spawn = deserialize!CreatureSpawn(r);
                    object = EntityRef(makeGuid(HighGuid.unit, spawn.entry, spawn.guid));
                }
                else if (migrant.kind == MigrantKind.summonedGameObject)
                {
                    auto r = ByteReader(migrant.state);
                    const spawn = deserialize!GameObjectSpawn(r);
                    object = EntityRef(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid));
                }
                if (object)
                {
                    refs ~= object;
                    accepted ~= migrant;
                }
            }
            durableSummons = refs;
            pendingSummons = accepted;
        }
        catch (Exception error)
            warning!"instance %s: could not load its encounter creatures: %s"(id, error.msg);
    }

    /**
     * The highest temporary GUID counter among the summons a copy's saved state (`instance.data`) keeps: a standalone
     * server's next summons count from above it, or one made before a player returns to the copy could take the
     * GUID of a saved actor. 0 if it keeps none.
     */
    static uint highestSavedSummon(string data)
    {
        import std.algorithm.searching : findSplit;

        const section = data.findSplit(instanceSummonPrefix)[2].findSplit(":")[0];
        uint highest;
        if (!section.length)
            return highest;
        try
        {
            ulong[] cells;
            Migrant[] saved;
            decodeBundle(fromHex(section), cells, saved);
            foreach (ref migrant; saved)
                if ((migrant.kind == MigrantKind.summonedCreature || migrant.kind == MigrantKind.summonedGameObject)
                    && migrant.spawn > highest)
                    highest = migrant.spawn;
        }
        catch (Exception)
            return 0;
        return highest;
    }

    private void loadScriptRuns(string data)
    {
        import dmangos.log : warning;
        import std.algorithm.searching : findSplit;

        const section = data.findSplit(instanceScriptRunsPrefix)[2];
        if (!section.length)
            return;
        try
        {
            auto reader = ByteReader(fromHex(section));
            uint[] ids;
            foreach (_; 0 .. reader.read!ubyte)
                ids ~= reader.read!uint;
            durableScripts = ids;
            pendingScriptRuns = reader.readBytes(reader.remaining()).dup;
        }
        catch (Exception error)
            warning!"instance %s: could not read the saved database script steps: %s"(id, error.msg);
    }

    /// Whether its state was read from `instance.data` (and `restored` has not been called since).
    bool fromSave;

    /// The copy's map made, nothing of it loaded yet: `Restored`, if its state came from `instance.data`
    /// (the server restarted, the copy was unloaded), lets the script reconcile its saved progress.
    void restored()
    {
        if (!fromSave)
            return;
        fromSave = false;
        raise(Restored());
    }

    private void restorePendingSummons()
    {
        if (!summonsPending)
            return;
        summonsPending = false;
        const pending = pendingSummons;
        pendingSummons = null;
        size_t index;
        EntityRef[] missing;
        struct RestoredActor { EntityRef entity; bool summoned; }
        RestoredActor[] restored;
        map.migrateIn(encodeBundle(null, pending), (const ref Migrant migrant) {
            const guid = durableSummons[index++];
            auto object = restoreSummon(migrant);
            if (object is null && guid.isCreature)
                missing ~= guid;
            else if (object !is null)
                restored ~= RestoredActor(guid, migrant.kind == MigrantKind.summonedCreature);
            return object;
        });
        if (pendingScriptRuns.length && restoreScriptRuns !is null)
        {
            restoreScriptRuns(pendingScriptRuns);
            pendingScriptRuns = null;
        }
        foreach (actor; restored)
            if (actor.entity.isCreature)
                raise(CreatureLoaded(actor.entity, actor.summoned));
            else
                raise(ObjectLoaded(actor.entity));
        foreach (creature; missing)
            raise(CreatureEvaded(creature));
        // What `Restored` settled while the actors waited (no save was written meanwhile) is a checkpoint now.
        save(true);
    }

    /// The checkpoint supplies this creature or object when the first player enters the copy.
    bool restoringEntity(EntityRef entity) const
    {
        return summonsPending && keepsCheckpoint(entity);
    }

    /// Whether this object still has active encounter state to save.
    bool keepsCheckpoint(EntityRef entity) const
    {
        import std.algorithm.searching : canFind;

        return durableSummons.canFind(entity);
    }

    /// Open-world round 2: the script `name` (`world_template.ScriptName`) of continent `mapId`; null if none serves it.
    static InstanceScript makeWorld(ScriptRuntime runtime, string name, uint mapId)
    {
        if (runtime is null || !runtime.serves(ScriptKind.world, name))
            return null;
        auto script = new InstanceScript;
        script.runtime = runtime;
        script.handle = runtime.create(ScriptKind.world, name);
        script.mapId = mapId;
        script.world = true;
        return script;
    }

    /// Raises `event` with the context of its kind; whether it consumed it (a world map's never does).
    private bool dispatch(E)(const E event, out bool checkpoint)
    {
        if (world)
        {
            static if (staticIndexOf!(E, KindInfo!(ScriptKind.world).Events) >= 0)
            {
                auto context = WorldMapContext(this);
                runtime.raise(handle, context, event);
            }
            return false;
        }
        auto context = InstanceContext(this);
        static if (is(E == Restored))
        {
            context.savedSummons = durableSummons;
            const savedActors = durableSummons.dup; // in the order of `pendingSummons`
        }
        runtime.raise(handle, context, event);
        checkpoint = context.checkpointRequested;
        updateCheckpointActors(context);
        if (context.changedDatabaseScripts)
            durableScripts = context.databaseScripts;
        static if (is(E == Restored))
        {
            // What the script let go of as it reconciled its saved progress (a ritual failed, its actors and database
            // steps released) is not brought back when a player returns for what it kept (another encounter's).
            import std.algorithm.searching : canFind;

            Migrant[] keptSummons;
            EntityRef[] keptActors;
            foreach (i, actor; savedActors)
                if (i < pendingSummons.length && keepsCheckpoint(actor))
                {
                    keptSummons ~= pendingSummons[i];
                    keptActors ~= actor;
                }
            foreach (actor; durableSummons)
                if (!savedActors.canFind(actor))
                    keptActors ~= actor; // checkpointed by the handler itself: after those the save restores
            pendingSummons = keptSummons;
            durableSummons = keptActors;
            if (context.changedDatabaseScripts && !durableScripts.length)
                pendingScriptRuns = null;
            waitForPlayer = context.waitingForPlayer;
            summonsPending = waitForPlayer && (pendingSummons.length || pendingScriptRuns.length);
            if (!summonsPending)
            {
                pendingSummons = null;
                durableSummons = null;
                pendingScriptRuns = null;
            }
        }
        return context.consumed;
    }

    /**
     * Raises `event` for the script, then saves its state if it changed; whether the script consumed
     * it. An event caused by one of the script's own actions (a creature it summoned coming into the
     * world) is raised once the handler it came from is done.
     */
    bool raise(E)(const E event)
    {
        const handled = runtime.handles!E(handle);
        // A returning player also restores saved actors for scripts without a PlayerEntered handler.
        if (!handled && !(is(E == PlayerEntered) && summonsPending))
            return false;
        if (raising)
        {
            pending ~= () { raise(event); };
            return false;
        }
        static if (is(E == PlayerEntered))
        {
            restorePendingSummons();
            if (!handled)
                return false;
        }
        raising = true;
        bool checkpoint;
        const consumed = dispatch(event, checkpoint);
        raising = false;
        saveAfterEvents(checkpoint);
        return consumed;
    }

    /**
     * As `raise`, but what the event changes is written as a checkpoint (`persist`'s `checkpoint`), however recent the
     * last save: a death, already queued for the database, must not land without what the script made of it.
     */
    bool raiseCheckpointed(E)(const E event)
    {
        if (raising)
        {
            pending ~= () { raiseCheckpointed(event); };
            return false;
        }
        const outer = checkpointChanges;
        checkpointChanges = true;
        needsCheckpoint |= drainingEvents; // its save comes once the events before it are done
        scope (exit)
            checkpointChanges = outer;
        return raise(event);
    }

    private bool checkpointChanges;    // `raiseCheckpointed`: the next save is a checkpoint
    private bool raising;              // a handler runs
    private void delegate()[] pending; // events its actions caused, for after it
    private bool waitForPlayer;
    private bool drainingEvents, needsCheckpoint;

    /// Its schedules, `ms` milliseconds on (nothing to do when none is pending).
    void tick(int ms)
    {
        if ((!runtime.busy(handle) && !durableSummons.length && !durableScripts.length)
            || (waitForPlayer && !map.population))
            return;
        waitForPlayer = false;
        sinceSummonSave += ms;
        raising = true;
        bool checkpoint;
        if (world)
        {
            auto context = WorldMapContext(this);
            runtime.tick(handle, context, ms);
        }
        else
        {
            auto context = InstanceContext(this);
            runtime.tick(handle, context, ms);
            checkpoint = context.checkpointRequested;
            updateCheckpointActors(context);
            if (context.changedDatabaseScripts)
                durableScripts = context.databaseScripts;
        }
        raising = false;
        saveAfterEvents(checkpoint);
    }

    private void saveAfterEvents(bool checkpoint)
    {
        needsCheckpoint |= checkpoint;
        if (drainingEvents)
            return;
        drainingEvents = true;
        while (pending.length)
        {
            auto next = pending[0];
            pending = pending[1 .. $];
            next();
        }
        drainingEvents = false;
        const durable = needsCheckpoint;
        needsCheckpoint = false;
        save(durable);
    }

    private void updateCheckpointActors(ref InstanceContext context)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        foreach (actor; context.checkpointSummons)
            if (!keepsCheckpoint(actor))
                durableSummons ~= actor;
        foreach (actor; context.releasedCheckpointActors)
        {
            const index = durableSummons.countUntil(actor);
            if (index >= 0)
                durableSummons = durableSummons.remove(index);
        }
    }

    private void save(bool checkpoint)
    {
        if (persist is null || summonsPending) // wait for the saved actors before writing another checkpoint
            return;
        checkpoint |= checkpointChanges;
        string summons;
        if ((durableSummons.length || durableScripts.length) && !checkpoint && sinceSummonSave < 2_000)
            return;
        if (durableSummons.length && captureSummon !is null)
        {
            Migrant[] migrants;
            EntityRef[] living;
            foreach (creature; durableSummons)
            {
                auto made = captureSummon(creature);
                if (!made.state.length)
                    continue;
                migrants ~= made;
                living ~= creature;
            }
            durableSummons = living;
            if (migrants.length)
                summons = instanceSummonPrefix ~ toHex(encodeBundle(null, migrants));
        }
        sinceSummonSave = 0;
        ByteWriter w;
        runtime.save(handle, w);
        if (durableScripts.length && captureScriptRuns !is null)
        {
            ByteWriter runs;
            runs.put(cast(ubyte) durableScripts.length);
            foreach (id; durableScripts)
                runs.put(id);
            runs.putBytes(captureScriptRuns(durableScripts));
            summons ~= instanceScriptRunsPrefix ~ toHex(runs.data);
        }
        const data = instanceDataPrefix ~ toHex(w.data) ~ summons;
        if (data != saved)
        {
            saved = data;
            persist(data, checkpoint);
        }
    }

    /// Raid scripts: asks the script question `id` (`Asked`) from `from`; its answer, 0 if it gave none.
    int ask(EntityRef from, uint id)
    {
        if (world)
        {
            auto context = WorldMapContext(this);
            runtime.raise(handle, context, Asked(from, id));
            return context.answerGiven;
        }
        auto context = InstanceContext(this);
        runtime.raise(handle, context, Asked(from, id));
        return context.answerGiven;
    }

    bool condition(uint id)
    {
        auto context = InstanceContext(this);
        runtime.raise(handle, context, InstanceCondition(id));
        return context.answerGiven == 1;
    }

    bool hostEntryKilled(uint entry)
    {
        return entryKilled !is null && entryKilled(id, entry);
    }

    bool hostKilled(EntityRef creature)
    {
        return spawnKilled !is null && creature.isCreature && spawnKilled(id, creature.guid);
    }

    void hostStartDatabaseEvent(uint event, EntityRef source, EntityRef target)
    {
        if (startDatabaseEvent !is null)
            startDatabaseEvent(event, source, target);
    }

    void hostRespawnKilled(uint entry)
    {
        if (map !is null && respawnKilled !is null)
            respawnKilled(map, entry);
    }

    /**
     * Writes its state now, whatever the pace of its saves: the copy is about to leave this node or memory. Its
     * encounter's creatures must still be on the map (they are captured with it).
     */
    void saveNow()
    {
        if (!world && !raising)
            save(true);
    }

    /// The copy goes from this node: the script's state goes from memory (it is saved).
    void release()
    {
        runtime.destroy(handle);
    }

    /// The `ScriptName` it serves.
    @property string name() const
    {
        return runtime.nameOf(handle);
    }

    // `InstanceHost`

    uint hostMapId()
    {
        return mapId;
    }

    uint hostInstanceId()
    {
        return id;
    }

    ActionResult hostDoor(EntityRef door, bool open)
    {
        foreach (object; loading)
            if (object.guid == door.guid)
                if (auto go = cast(GameObject) object)
                {
                    go.setDoorOpen(open);
                    return ActionResult.ok;
                }
        auto go = map is null ? null : cast(GameObject) map.findObject(door.guid);
        if (go is null)
            return ActionResult.notHere;
        go.setDoorOpen(open);
        map.flushGameObject(go);
        return ActionResult.ok;
    }

    ActionResult hostSignal(EntityRef to, uint signal, int value)
    {
        if (to.isGameObject)
        {
            GameObject go;
            foreach (object; loading)
                if (object.guid == to.guid)
                    go = cast(GameObject) object;
            if (go is null && map !is null)
                go = cast(GameObject) map.findObject(to.guid);
            if (go is null || signalObject is null)
                return ActionResult.notHere;
            return signalObject(go, map, EntityRef.init, signal, value) ? ActionResult.ok : ActionResult.failed;
        }
        foreach (object; loading) // loading with it: not on the map yet
            if (object.guid == to.guid)
                if (auto creature = cast(Creature) object)
                {
                    creature.ai.signalled(EntityRef.init, signal, value, map);
                    return ActionResult.ok;
                }
        auto creature = map is null ? null : cast(Creature) map.findObject(to.guid);
        if (creature is null)
            return ActionResult.notHere;
        creature.ai.signalled(EntityRef.init, signal, value, map);
        return ActionResult.ok;
    }

    uint hostPlayerCount()
    {
        return map is null ? 0 : cast(uint) map.population;
    }

    void hostSignalObjects(uint entry, uint id, int value)
    {
        if (map is null || signalObject is null)
            return;
        map.forEachObject((MapObject object) {
            if (auto go = cast(GameObject) object)
                if (go.spawn.entry == entry)
                    signalObject(go, map, EntityRef.init, id, value);
        });
    }

    void hostLog(string text)
    {
        info!"script %s (instance %s of map %s): %s"(name, id, mapId, text);
    }

    // Dungeon scripts:

    /// A creature of the copy, ready to act on this map; null if it is not here.
    private Creature creatureOf(EntityRef who)
    {
        Creature found;
        foreach (object; loading)
            if (object.guid == who.guid)
                found = cast(Creature) object;
        if (found is null && map !is null)
            found = cast(Creature) map.findObject(who.guid);
        if (found is null || found.ai is null || map is null)
            return null;
        found.ai.bind(map);
        return found;
    }

    EntityRef hostSummon(uint entry, Location at, uint despawnMs, EntityRef attack)
    {
        if (lore is null || map is null)
            return EntityRef.init;
        auto made = lore.summon(map, entry, Position(at.x, at.y, at.z, at.orientation),
            despawnMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, despawnMs, 0);
        if (made is null)
            return EntityRef.init;
        if (attack)
        {
            made.ai.bind(map);
            made.ai.hostAttackBy(EntityRef(made.guid), attack);
        }
        return EntityRef(made.guid);
    }

    ActionResult hostSay(EntityRef speaker, int textEntry, EntityRef target)
    {
        auto c = creatureOf(speaker);
        return c is null ? ActionResult.notHere : c.ai.hostSay(textEntry, target);
    }

    ActionResult hostCast(EntityRef caster, uint spell, EntityRef target, bool triggered)
    {
        if (caster.isPlayer && map !is null)
            if (auto unit = map.unit(caster.guid))
                return unit.session.scriptCast(spell, target.guid, triggered);
        auto c = creatureOf(caster);
        if (c is null)
            return ActionResult.notHere;
        const result = c.ai.hostCast(spell, target, triggered);
        map.wake(c.guid);
        return result;
    }

    ActionResult hostSetFaction(EntityRef creature, uint faction)
    {
        auto c = creatureOf(creature);
        if (c is null)
            return ActionResult.notHere;
        c.ai.hostSetFaction(faction);
        return ActionResult.ok;
    }

    ActionResult hostUnitFlags(EntityRef creature, uint flags, bool set)
    {
        auto c = creatureOf(creature);
        if (c is null)
            return ActionResult.notHere;
        c.ai.hostUnitFlags(flags, set);
        return ActionResult.ok;
    }

    ActionResult hostAttack(EntityRef creature, EntityRef target)
    {
        auto c = creatureOf(creature);
        return c is null ? ActionResult.notHere : c.ai.hostAttackBy(creature, target);
    }

    ActionResult hostMoveTo(EntityRef creature, Location at, uint point, bool run)
    {
        auto c = creatureOf(creature);
        if (c is null || !c.alive)
            return ActionResult.notHere;
        c.ai.hostMoveTo(at, point, run);
        return ActionResult.ok;
    }

    ActionResult hostDespawn(EntityRef creature, uint delayMs)
    {
        auto c = creatureOf(creature);
        if (c is null)
            return ActionResult.notHere;
        c.ai.despawnFor(map, delayMs);
        return ActionResult.ok;
    }

    bool hostAlive(EntityRef creature)
    {
        if (auto c = creatureOf(creature))
            return c.alive;
        if (map !is null && creature.isPlayer)
            if (auto player = map.unit(creature.guid))
                return player.alive;
        return false;
    }

    uint hostSpawnObjects(uint entry, uint despawnSeconds, Location near, float range)
    {
        return spawnObjects is null || map is null ? 0 : spawnObjects(map, entry, despawnSeconds, near, range);
    }

    ActionResult hostObjectFlags(EntityRef object, uint set, uint clear)
    {
        import dmangos.world.updatefields : GAMEOBJECT_FLAGS;

        GameObject go;
        foreach (o; loading)
            if (o.guid == object.guid)
                go = cast(GameObject) o;
        if (go is null && map !is null)
            go = cast(GameObject) map.findObject(object.guid);
        if (go is null)
            return ActionResult.notHere;
        go.values.set!GAMEOBJECT_FLAGS((go.values.get!GAMEOBJECT_FLAGS | set) & ~clear);
        if (map !is null)
            map.flushGameObject(go);
        return ActionResult.ok;
    }

    ActionResult hostRemoveAura(EntityRef creature, uint spell)
    {
        auto c = creatureOf(creature);
        if (c is null)
            return ActionResult.notHere;
        c.ai.hostRemoveAura(creature, spell);
        return ActionResult.ok;
    }

    EntityRef hostVictimOf(EntityRef creature)
    {
        auto c = creatureOf(creature);
        return c is null ? EntityRef.init : c.ai.hostVictim();
    }

    uint hostUnitFlagsOf(EntityRef creature)
    {
        import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

        auto c = creatureOf(creature);
        return c is null ? 0 : c.values.get!UNIT_FIELD_FLAGS;
    }

    bool hostLocationOf(EntityRef who, out Location at)
    {
        Position there;
        bool found;
        foreach (object; loading) // loading: not on the map yet
            if (object.guid == who.guid)
            {
                there = object.position;
                found = true;
            }
        if (!found && (map is null || !map.positionOf(who.guid, there)))
            return false;
        at = Location(there.x, there.y, there.z, there.orientation);
        return true;
    }

    EntityRef hostAnyPlayer()
    {
        if (map is null)
            return EntityRef.init;
        foreach (who; map.playersNow())
            if (who.character !is null)
                if (auto unit = map.unit(who.character.guid))
                    if (unit.alive && !unit.untouchable)
                        return EntityRef(unit.combatGuid);
        return EntityRef.init;
    }

    void hostKillCreditAll(uint entry)
    {
        if (map is null)
            return;
        foreach (who; map.playersNow())
            if (who.character !is null)
                if (auto unit = map.unit(who.character.guid))
                    unit.killCreditFrom(entry, 0);
    }

    bool hostChangeEntry(EntityRef creature, uint entry)
    {
        auto c = creatureOf(creature);
        return c !is null && c.ai.hostChangeEntry(entry);
    }

    uint hostRandom(uint below)
    {
        import std.random : uniform;

        return below == 0 ? 0 : uniform(0, below);
    }

    // Raid scripts:

    ActionResult hostDespawnObject(EntityRef object)
    {
        foreach (i, o; loading)
            if (o.guid == object.guid)
            {
                loading = loading[0 .. i] ~ loading[i + 1 .. $]; // not added at all
                return ActionResult.ok;
            }
        if (map is null || cast(GameObject) map.findObject(object.guid) is null)
            return ActionResult.notHere;
        map.removeObject(object.guid);
        return ActionResult.ok;
    }

    bool hostRespawnObject(uint entry, uint seconds)
    {
        return map !is null && respawnObjectOf !is null && respawnObjectOf(map, entry, seconds);
    }

    ActionResult hostUseObject(EntityRef object)
    {
        auto go = map is null ? null : cast(GameObject) map.findObject(object.guid);
        if (go is null)
            return ActionResult.notHere;
        go.useDoorOrButton(map);
        map.flushGameObject(go);
        return ActionResult.ok;
    }

    size_t hostPlayers(EntityRef[] into)
    {
        if (map is null)
            return 0;
        size_t n;
        foreach (who; map.playersNow())
            if (who.character !is null && n < into.length)
                into[n++] = EntityRef(who.character.guid);
        return n;
    }

    EntityRef hostSummonObject(uint entry, Location at, uint seconds)
    {
        if (map is null || summonObjectAt is null)
            return EntityRef.init;
        auto go = summonObjectAt(map, entry, at, seconds);
        return go is null ? EntityRef.init : EntityRef(go.guid);
    }

    size_t hostCreaturesNear(Location at, uint entry, float range, EntityRef[] into)
    {
        if (map is null)
            return 0;
        size_t n;
        foreach (c; map.creaturesNear(Position(at.x, at.y, at.z), range))
            if (c.alive && (entry == 0 || c.spawn.entry == entry) && n < into.length)
                into[n++] = EntityRef(c.guid);
        return n;
    }

    ActionResult hostWalkPath(EntityRef creature, uint pathId)
    {
        auto c = creatureOf(creature);
        if (c is null || !c.alive)
            return ActionResult.notHere;
        c.ai.hostWalkPath(pathId);
        return ActionResult.ok;
    }

    bool hostHasAura(EntityRef creature, uint spell)
    {
        if (creature.isPlayer && map !is null)
            if (auto unit = map.unit(creature.guid))
                return unit.alive && unit.auraSet.find(spell) !is null;
        auto c = creatureOf(creature);
        return c !is null && c.alive && c.auras.find(spell) !is null;
    }

    ActionResult hostZoneCombat(EntityRef creature)
    {
        auto c = creatureOf(creature);
        if (c is null || !c.alive)
            return ActionResult.notHere;
        c.ai.scriptZoneCombatPulse();
        map.wake(c.guid);
        return ActionResult.ok;
    }
}

package string toHex(const(ubyte)[] bytes)
{
    static immutable digits = "0123456789abcdef";
    auto text = new char[bytes.length * 2];
    foreach (i, b; bytes)
    {
        text[2 * i] = digits[b >> 4];
        text[2 * i + 1] = digits[b & 15];
    }
    return cast(string) text;
}

package ubyte[] fromHex(const(char)[] text)
{
    static int value(char c)
    {
        return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
    }

    auto bytes = new ubyte[text.length / 2];
    foreach (i, ref b; bytes)
    {
        const hi = value(text[2 * i]), lo = value(text[2 * i + 1]);
        if (hi < 0 || lo < 0)
            return null;
        b = cast(ubyte)(hi << 4 | lo);
    }
    return bytes;
}

unittest
{
    assert(fromHex(toHex([0, 1, 0xAB, 0xFF])) == [0, 1, 0xAB, 0xFF]);
    assert(fromHex("zz") is null);
}

// What a script makes of a death is written as a checkpoint (the death itself is already queued), and only what
// changed is written.
unittest
{
    static import dmangos.scripts.deadmines;
    import dmangos.scripts.deadmines : rhahkZor;
    import dmangos.world.objects : HighGuid, makeGuid;

    bool[] checkpoints;
    auto script = InstanceScript.make(ScriptRuntime.of!(dmangos.scripts.deadmines)(), "instance_deadmines", 1, 36,
        null, (string, bool checkpoint) { checkpoints ~= checkpoint; }, (MigrantKind, uint) => EntityRef.init,
        (uint) => false);
    const guard = EntityRef(makeGuid(HighGuid.unit, rhahkZor, 90002));
    script.raiseCheckpointed(CreatureDied(guard, EntityRef.init, false));
    assert(checkpoints == [true], "Rhahk'Zor's death settled with its door");
    script.raiseCheckpointed(CreatureDied(guard, EntityRef.init, false));
    assert(checkpoints == [true], "nothing changed: nothing written");
    script.raise(CreatureDied(EntityRef(makeGuid(HighGuid.unit, 4417, 90003)), EntityRef.init, false));
    assert(checkpoints == [true]);
}
