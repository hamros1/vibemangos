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
import dmangos.script.registry : ScriptHandle, ScriptKind, ScriptRuntime;
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
    }

    /// The copy's map, once it is made.
    Map map;

    /// Objects of a cell being loaded, not on the map yet (a door opened now is open when it appears).
    MapObject[] loading;

    /// The world's creatures (summons); null in tests without one.
    CreatureLore lore;

    /// Puts the dungeon's game objects of an entry in the world (`InstanceContext.spawnObjects`).
    uint delegate(Map map, uint entry, uint despawnSeconds, Location near, float range) spawnObjects;

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
            if (!runtime.load(script.handle, r))
                info!"instance %s: the saved state of script %s has another layout; it starts afresh"(id, name);
        }
        return script;
    }

    /// Raises `event` for the script, then saves its state if it changed.
    void raise(E)(const E event)
    {
        if (!runtime.handles!E(handle))
            return;
        auto context = InstanceContext(this);
        runtime.raise(handle, context, event);
        save();
    }

    /// Its schedules, `ms` milliseconds on (nothing to do when none is pending).
    void tick(int ms)
    {
        if (!runtime.busy(handle))
            return;
        auto context = InstanceContext(this);
        runtime.tick(handle, context, ms);
        save();
    }

    private void save()
    {
        ByteWriter w;
        runtime.save(handle, w);
        const data = instanceDataPrefix ~ toHex(w.data);
        if (data != saved)
        {
            saved = data;
            persist(data);
        }
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
            made.ai.hostAttack(attack);
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

    ActionResult hostUnitFlags(EntityRef creature, uint set, uint clear)
    {
        auto c = creatureOf(creature);
        if (c is null)
            return ActionResult.notHere;
        c.ai.hostUnitFlags(set, clear);
        return ActionResult.ok;
    }

    ActionResult hostAttack(EntityRef creature, EntityRef target)
    {
        auto c = creatureOf(creature);
        return c is null ? ActionResult.notHere : c.ai.hostAttack(target);
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
        auto c = creatureOf(creature);
        return c !is null && c.alive;
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
        c.ai.hostRemoveAura(spell);
        return ActionResult.ok;
    }

    EntityRef hostVictimOf(EntityRef creature)
    {
        auto c = creatureOf(creature);
        return c is null ? EntityRef.init : c.ai.hostVictim();
    }

    uint hostRandom(uint below)
    {
        import std.random : uniform;

        return below == 0 ? 0 : uniform(0, below);
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
