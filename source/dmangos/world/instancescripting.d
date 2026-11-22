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

/// What `instance.data` starts with when a dungeon script wrote it.
enum string instanceDataPrefix = "dmangos-script:";

/// See the module documentation. It is also the core's side of the script's context.
final class InstanceScript : InstanceHost
{
    private
    {
        ScriptRuntime runtime;
        ScriptHandle handle;
        void delegate(string data) persist;
        string saved;
        uint id, mapId;
        bool world; // open-world round 2: a continent's script (`@world`), kept in memory only
    }

    /// The copy's map, once it is made.
    Map map;

    /// Objects of a cell being loaded, not on the map yet (a door opened now is open when it appears).
    MapObject[] loading;

    /// The world's creatures (summons); null in tests without one.
    CreatureLore lore;

    /// A `Signal` for a game object's script (`InstanceContext.signal` to an object).
    bool delegate(GameObject go, Map map, EntityRef from, uint id, int value) signalObject;

    /// Puts the dungeon's game objects of an entry in the world (`InstanceContext.spawnObjects`).
    uint delegate(Map map, uint entry, uint despawnSeconds, Location near, float range) spawnObjects;

    /// Whether an entry is in this copy's persisted creature deaths.
    bool delegate(uint instance, uint entry) entryKilled;
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
        void delegate(string data) persist)
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
            auto bytes = fromHex(data[instanceDataPrefix.length .. $]);
            auto r = ByteReader(bytes);
            if (runtime.load(script.handle, r))
                script.fromSave = true;
            else
                info!"instance %s: the saved state of script %s has another layout; it starts afresh"(id, name);
        }
        return script;
    }

    /// Whether its state was read from `instance.data` (and `restored` has not been called since).
    bool fromSave;

    /// The copy's map made, nothing of it loaded yet: `Restored`, if its state came from `instance.data`
    /// (the server restarted, the copy was unloaded), so what was under way when it was saved starts again.
    void restored()
    {
        if (!fromSave)
            return;
        fromSave = false;
        raise(Restored());
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
    private bool dispatch(E)(const E event)
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
        runtime.raise(handle, context, event);
        return context.consumed;
    }

    /**
     * Raises `event` for the script, then saves its state if it changed; whether the script consumed
     * it. An event caused by one of the script's own actions (a creature it summoned coming into the
     * world) is raised once the handler it came from is done.
     */
    bool raise(E)(const E event)
    {
        if (!runtime.handles!E(handle))
            return false;
        if (raising)
        {
            pending ~= () { raise(event); };
            return false;
        }
        raising = true;
        const consumed = dispatch(event);
        raising = false;
        save();
        while (pending.length)
        {
            auto next = pending[0];
            pending = pending[1 .. $];
            next();
        }
        return consumed;
    }

    private bool raising;              // a handler runs
    private void delegate()[] pending; // events its actions caused, for after it

    /// Its schedules, `ms` milliseconds on (nothing to do when none is pending).
    void tick(int ms)
    {
        if (!runtime.busy(handle))
            return;
        raising = true;
        if (world)
        {
            auto context = WorldMapContext(this);
            runtime.tick(handle, context, ms);
        }
        else
        {
            auto context = InstanceContext(this);
            runtime.tick(handle, context, ms);
        }
        raising = false;
        save();
        while (pending.length)
        {
            auto next = pending[0];
            pending = pending[1 .. $];
            next();
        }
    }

    private void save()
    {
        if (persist is null) // a world map's script: kept in memory only
            return;
        ByteWriter w;
        runtime.save(handle, w);
        const data = instanceDataPrefix ~ toHex(w.data);
        if (data != saved)
        {
            saved = data;
            persist(data);
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

    void hostRespawnKilled(uint entry)
    {
        if (map !is null && respawnKilled !is null)
            respawnKilled(map, entry);
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

private string toHex(const(ubyte)[] bytes)
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

private ubyte[] fromHex(const(char)[] text)
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
