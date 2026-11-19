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
import dmangos.world.creature : Creature;
import dmangos.world.creatureai : CreatureLore;
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

    // Raid scripts:

    /// The world's data, for summoning and texts (`WorldContext`).
    CreatureLore lore;

    /// Puts the game object of a spawn of `entry` on the copy's map in the world for `seconds` (0: for
    /// good); false if there is none (`WorldContext` sets it).
    bool delegate(Map map, uint entry, uint seconds) respawnObjectOf;

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
        auto context = InstanceContext(this);
        runtime.raise(handle, context, event);
        ByteWriter w;
        runtime.save(handle, w);
        const data = instanceDataPrefix ~ toHex(w.data);
        if (data != saved)
        {
            saved = data;
            persist(data);
        }
    }

    // Raid scripts:

    /// Asks the script question `id` (`Asked`) from `from`; its answer, 0 if it gave none.
    int ask(EntityRef from, uint id)
    {
        auto context = InstanceContext(this);
        runtime.raise(handle, context, Asked(from, id));
        return context.answerGiven;
    }

    /// `ms` of the copy's time pass for the script's schedules. Its state is saved with its next event.
    void tick(int ms)
    {
        if (!runtime.busy(handle))
            return;
        auto context = InstanceContext(this);
        runtime.tick(handle, context, ms);
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

    // Raid scripts:

    private Creature creatureHere(EntityRef who)
    {
        foreach (object; loading)
            if (object.guid == who.guid)
                return cast(Creature) object;
        return map is null ? null : cast(Creature) map.findObject(who.guid);
    }

    EntityRef hostSummon(uint entry, Location at, uint despawnMs)
    {
        import dmangos.world.creature : TempSpawnType;
        import dmangos.world.movement : Position;

        if (lore is null || map is null)
            return EntityRef.init;
        auto made = lore.summon(map, entry, Position(at.x, at.y, at.z, at.orientation),
            despawnMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, despawnMs, 0);
        return made is null ? EntityRef.init : EntityRef(made.guid);
    }

    bool hostAlive(EntityRef who)
    {
        auto c = creatureHere(who);
        return c !is null && c.alive;
    }

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

    ActionResult hostDespawnCreature(EntityRef creature, uint delayMs)
    {
        auto c = creatureHere(creature);
        if (c is null || map is null)
            return ActionResult.notHere;
        c.ai.despawnFor(map, delayMs);
        return ActionResult.ok;
    }

    ActionResult hostCastAs(EntityRef caster, uint spell, EntityRef target, bool triggered)
    {
        auto c = creatureHere(caster);
        if (c is null || map is null)
            return ActionResult.notHere;
        return c.ai.castFor(map, spell, target.guid, triggered);
    }

    size_t hostPlayers(EntityRef[] into)
    {
        if (map is null)
            return 0;
        size_t n;
        foreach (who; map.playersNow())
            if (n < into.length)
                into[n++] = EntityRef(who.character.guid);
        return n;
    }

    Location hostLocationOf(EntityRef who)
    {
        import dmangos.world.movement : Position;

        foreach (object; loading)
            if (object.guid == who.guid)
            {
                const p = object.position;
                return Location(p.x, p.y, p.z, p.orientation);
            }
        Position at;
        if (map is null || !map.positionOf(who.guid, at))
            return Location.init;
        return Location(at.x, at.y, at.z, at.orientation);
    }

    ActionResult hostSay(EntityRef speaker, int textEntry, EntityRef target)
    {
        auto c = creatureHere(speaker);
        if (c is null || map is null)
            return ActionResult.notHere;
        return c.ai.sayScriptFor(map, textEntry, target);
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
