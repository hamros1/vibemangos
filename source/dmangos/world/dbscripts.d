/**
 * Database scripts: the steps of `dbscripts_on_*`, each with its delay from the script's start, run by the map the
 * script began on with a source and a target (the quest giver and the player, the creature and the
 * one who chose its gossip option, the player and the game object used).
 *
 * A step may name a buddy instead (`buddy_entry` within `search_radius`, or a spawn by its guid),
 * to act as its source or, with `ScriptFlag.buddyAsTarget`, its target; the flags may turn them
 * about or make the source its own target. Its condition must hold.
 *
 * Scripts start from quests (taken, rewarded), gossip options, game objects used, relays, waypoints
 * reached (`dbscripts_on_creature_movement`, the creature its own source and target), creatures
 * killed (`dbscripts_on_creature_death`, the killer the target) and spells' events
 * (`SPELL_EFFECT_SEND_EVENT`: `dbscripts_on_event`). Doors open and close.
 *
 * Commands: talking (`broadcast_text`, one of several, or one of a `dbscript_random_templates`
 * group), emotes, a quest's place explored (or failed when too far), kill credit, spawning a game
 * object, summoning a creature, taking an aura off, casting a spell, despawning, a faction, models
 * and mounts, stand states, NPC flags, unit and other flags, facing someone, stopping the script
 * when a buddy is (or is not) near, and starting a relay script (or one of a group). The others
 * (AI events, paths by id) are skipped; `dmangos.log` says which when it traces. Moving: walking
 * to a point (or back to the spawn point, or running), turning, teleporting, a movement type
 * (standing, wandering, its path), pausing and resuming its path.
 */
module dmangos.world.dbscripts;

import dmangos.mysql : MySqlConnection;

/// Which table a script comes from.
enum DbScriptType : ubyte
{
    questStart,
    questEnd,
    gossip,
    relay,
    creatureDeath,
    goUse,
    goTemplateUse,
    event,
    spell,
    creatureMovement,
}

/// The tables, by `DbScriptType`.
immutable string[] dbScriptTables = ["dbscripts_on_quest_start", "dbscripts_on_quest_end", "dbscripts_on_gossip",
    "dbscripts_on_relay", "dbscripts_on_creature_death", "dbscripts_on_go_use", "dbscripts_on_go_template_use",
    "dbscripts_on_event", "dbscripts_on_spell", "dbscripts_on_creature_movement"];

/// `ScriptCommand`: the commands this server runs.
enum ScriptCommand : uint
{
    talk = 0,
    emote = 1,
    fieldSet = 2,
    moveTo = 3,
    flagSet = 4,
    flagRemove = 5,
    questExplored = 7,
    killCredit = 8,
    respawnGameObject = 9,
    removeAura = 14,
    castSpell = 15,
    despawnSelf = 18,
    setFaction = 22,
    morphToEntryOrModel = 23,
    mountToEntryOrModel = 24,
    movement = 20,
    standState = 28,
    modifyNpcFlags = 29,
    tempSpawnCreature = 10,
    openDoor = 11,
    closeDoor = 12,
    terminateScript = 31,
    sendAiEvent = 35,
    pauseWaypoints = 32,
    setFacing = 36,
    startRelayScript = 45,
}

/// A step's `data_flags`.
enum ScriptFlag : uint
{
    buddyAsTarget = 0x001,
    reverseDirection = 0x002,
    sourceTargetsSelf = 0x004,
    commandAdditional = 0x008,
    buddyByGuid = 0x010,
    buddyIsPet = 0x020,
    buddyIsDespawned = 0x040,
    buddyByPool = 0x080,
    buddyBySpawnGroup = 0x100,
    allEligibleBuddies = 0x200,
    buddyByGo = 0x400,
    buddyByStringId = 0x800,
}

/// A `dbscripts_on_*` row.
struct DbScriptStep
{
    uint id;
    uint delay;          /// milliseconds from the script's start
    uint priority;
    uint command;
    uint datalong, datalong2, datalong3;
    uint buddyEntry;
    uint searchRadius;   /// or the buddy's spawn guid (`ScriptFlag.buddyByGuid`)
    uint dataFlags;
    int[4] dataint;      /// `textId`: texts, emotes or spells to choose from
    float x, y, z, o;
    uint conditionId;

    /// Whether its buddy is a creature (else a game object).
    @property bool creatureBuddy() const pure nothrow @nogc @safe
    {
        switch (command)
        {
        case ScriptCommand.terminateScript, ScriptCommand.setFacing:
            return !(dataFlags & ScriptFlag.buddyByGo);
        case ScriptCommand.respawnGameObject, 11, 12, 13, 27, 40, 43:
            return false;
        default:
            return true;
        }
    }

    /// Whether any kind of buddy is asked for.
    @property bool wantsBuddy() const pure nothrow @nogc @safe
    {
        return buddyEntry || (dataFlags & (ScriptFlag.buddyByGuid | ScriptFlag.buddyByPool)) != 0;
    }
}

/// The scripts of every table, and the relay groups.
final class DbScriptData
{
    const(DbScriptStep)[][uint][DbScriptType.max + 1] scripts; /// by table, by script id: steps in order
    uint[][uint] relayGroups;                                  /// `dbscript_random_templates` of type 1

    /// The steps of script `id` of `type`, in the order they run.
    const(DbScriptStep)[] steps(DbScriptType type, uint id) const
    {
        return scripts[type].get(id, null);
    }

    /// One of the relay scripts of group `templateId`, chosen at random; 0 if none.
    uint randomRelay(uint templateId) const
    {
        import std.random : uniform;

        const group = relayGroups.get(templateId, null);
        return group.length ? group[uniform(0, group.length)] : 0;
    }

    /// Adds a step (in delay and priority order).
    void add(DbScriptType type, DbScriptStep step)
    {
        import std.algorithm.sorting : sort;

        auto list = scripts[type].get(step.id, null).dup;
        list ~= step;
        list.sort!((a, b) => a.delay != b.delay ? a.delay < b.delay : a.priority < b.priority);
        scripts[type][step.id] = list;
    }

    /// Reads every `dbscripts_on_*` table and the relay groups.
    static DbScriptData load(MySqlConnection world)
    {
        import dmangos.log : info;

        auto data = new DbScriptData;
        size_t count;
        static foreach (type; 0 .. DbScriptType.max + 1)
        {{
            DbScriptStep[][uint] byId;
            enum query = "SELECT id, delay, priority, command, datalong, datalong2, datalong3, buddy_entry, "
                ~ "search_radius, data_flags, dataint, dataint2, dataint3, dataint4, x, y, z, o, condition_id FROM "
                ~ dbScriptTables[type] ~ " ORDER BY id, delay, priority";
            foreach (row; world.query!query())
            {
                DbScriptStep s;
                s.id = row.get!uint(0);
                s.delay = row.get!uint(1); // milliseconds
                s.priority = row.get!uint(2);
                s.command = row.get!uint(3);
                s.datalong = row.get!uint(4);
                s.datalong2 = row.get!uint(5);
                s.datalong3 = row.get!uint(6);
                s.buddyEntry = row.get!uint(7);
                s.searchRadius = row.get!uint(8);
                s.dataFlags = row.get!uint(9);
                foreach (i; 0 .. 4)
                    s.dataint[i] = row.get!int(10 + i);
                s.x = row.get!float(14);
                s.y = row.get!float(15);
                s.z = row.get!float(16);
                s.o = row.get!float(17);
                s.conditionId = row.get!uint(18);
                byId[s.id] ~= s;
                ++count;
            }
            foreach (id, steps; byId)
                data.scripts[type][id] = steps;
        }}
        foreach (row; world.query!"SELECT id, target_id FROM dbscript_random_templates WHERE type = 1"())
            data.relayGroups[row.get!uint(0)] ~= row.get!uint(1);
        info!"%s database script steps"(count);
        return data;
    }
}

/// One of a step's sources or targets: a player, a creature or a game object on the map.
struct ScriptThing
{
    import dmangos.world.creature : Creature;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.movement : Position;

    ulong guid;
    Position position;
    Creature creature;   /// if it is one
    GameObject go;       /// ditto

    /// Whether there is one.
    @property bool exists() const pure nothrow @nogc @safe
    {
        return guid != 0;
    }

    /// Whether it is a creature or a game object .
    @property bool creatureOrGo() const pure nothrow @nogc @safe
    {
        return creature !is null || go !is null;
    }
}

/// A script under way on a map: its steps, from one start.
final class ScriptRun
{
    DbScriptType type;
    uint id;
    const(DbScriptStep)[] steps;
    size_t next;            /// the step to run next
    uint elapsed;           /// milliseconds since it began
    uint mapId;
    uint instanceId;        /// the map's dungeon instance (0: none)
    ulong source, target;   /// the objects it began with (0: none)
}

/**
 * The database scripts' side of `WorldContext`: starting a script, the steps due each tick, and
 * the commands.
 */
mixin template DbScriptRunner()
{
    import std.random : uniform;
    import dmangos.log : trace;
    import dmangos.world.dbscripts;
    import dmangos.world.creature : Creature;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.map : Map;
    import dmangos.world.movement : Position;

    private ScriptRun[] scriptRuns;

    /// The scripts under way.
    @property size_t runningScripts() const
    {
        return scriptRuns.length;
    }

    /**
     * Script `id` of `type` begins on `map` with `source` and `target` (either
     * may be 0); false if there is no such script.
     */
    bool startScript(DbScriptType type, uint id, Map map, ulong source, ulong target)
    {
        if (map is null || id == 0)
            return false;
        const steps = data.dbScripts.steps(type, id);
        if (steps.length == 0)
            return false;
        auto run = new ScriptRun;
        run.type = type;
        run.id = id;
        run.steps = steps;
        run.mapId = map.id;
        run.instanceId = map.instanceId;
        run.source = source;
        run.target = target;
        scriptRuns ~= run;
        return true;
    }

    /// Runs the steps whose time has come, `diff` milliseconds on.
    package void updateScripts(uint diff)
    {
        // A copy: a step may start a relay script.
        foreach (run; scriptRuns.dup)
        {
            run.elapsed += diff;
            auto map = existingMap(run.mapId, run.instanceId);
            while (map !is null && run.next < run.steps.length && run.steps[run.next].delay <= run.elapsed)
            {
                const step = &run.steps[run.next++];
                if (runScriptStep(*step, map, run.source, run.target))
                {
                    run.next = run.steps.length; // terminated
                    break;
                }
            }
            if (map is null)
                run.next = run.steps.length;
        }
        import std.algorithm.mutation : remove;

        scriptRuns = scriptRuns.remove!(r => r.next >= r.steps.length);
    }

    /// The object `guid` on `map`: a player there, or a creature or game object; none if it is not there.
    private ScriptThing scriptObject(Map map, ulong guid)
    {
        if (guid == 0)
            return ScriptThing.init;
        if (auto who = map.find(guid))
            return ScriptThing(guid, who.character.position);
        if (auto o = map.findObject(guid))
            return ScriptThing(guid, o.position, cast(Creature) o, cast(GameObject) o);
        return ScriptThing.init;
    }

    private static ScriptThing thing(Creature c)
    {
        return ScriptThing(c.guid, c.position, c, null);
    }

    private static ScriptThing thing(GameObject go)
    {
        return ScriptThing(go.guid, go.position, null, go);
    }

    /// The buddies a step asks for; false if one was asked for but is not there.
    private bool scriptBuddies(const ref DbScriptStep step, Map map, ScriptThing source, ScriptThing target,
        out ScriptThing[] buddies)
    {
        if (!step.wantsBuddy)
            return true;
        const deadOk = (step.dataFlags & ScriptFlag.buddyIsDespawned) != 0;
        if (step.dataFlags & ScriptFlag.buddyByGuid)
        {
            // By its spawn: its guid is made of the entry and the spawn, so look for it by the spawn.
            const spawn = step.searchRadius;
            const at = (source.exists ? source : target).position;
            if (step.creatureBuddy)
            {
                foreach (creature; map.creaturesNear(at, 1000))
                    if (creature.spawn.guid == spawn && creature.alive != deadOk)
                        buddies ~= thing(creature);
            }
            else
                foreach (o; map.objectsNear(at, 1000))
                    if (auto go = cast(GameObject) o)
                        if (go.spawn.guid == spawn)
                            buddies ~= thing(go);
        }
        else if (step.buddyEntry && (step.dataFlags & ScriptFlag.buddyByPool) == 0)
        {
            // Searched for from the source, unless the source is a player and the target is not.
            auto origin = source.exists ? source : target;
            if (!origin.exists)
                return false;
            if (origin.guid == source.guid && !source.creatureOrGo && target.exists)
                origin = target;
            const at = origin.position;
            const range = float(step.searchRadius);
            ScriptThing nearest;
            float best = float.max;
            if (step.creatureBuddy)
            {
                foreach (creature; map.creaturesNear(at, range))
                {
                    if (creature.template_.entry != step.buddyEntry || creature.alive == deadOk)
                        continue;
                    if (step.dataFlags & ScriptFlag.allEligibleBuddies)
                        buddies ~= thing(creature);
                    else if (distanceSq(at, creature.position) < best)
                    {
                        best = distanceSq(at, creature.position);
                        nearest = thing(creature);
                    }
                }
            }
            else
                foreach (o; map.objectsNear(at, range))
                    if (auto go = cast(GameObject) o)
                    {
                        if (go.spawn.entry != step.buddyEntry)
                            continue;
                        if (step.dataFlags & ScriptFlag.allEligibleBuddies)
                            buddies ~= thing(go);
                        else if (distanceSq(at, go.position) < best)
                        {
                            best = distanceSq(at, go.position);
                            nearest = thing(go);
                        }
                    }
            if (nearest.exists)
                buddies ~= nearest;
        }
        else
            return false; // pools and spawn groups: not yet
        return buddies.length > 0 || step.command == ScriptCommand.terminateScript;
    }

    private static float distanceSq(Position a, Position b)
    {
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2;
    }

    /// Runs the step for each source and target it comes to; true if the script stops here.
    private bool runScriptStep(const ref DbScriptStep step, Map map, ulong sourceGuid, ulong targetGuid)
    {
        auto source = scriptObject(map, sourceGuid), target = scriptObject(map, targetGuid);
        ScriptThing[] buddies;
        if (!scriptBuddies(step, map, source, target, buddies))
            return false;
        ScriptThing[] sources = source.exists ? [source] : null, targets = target.exists ? [target] : null;
        if (step.dataFlags & ScriptFlag.buddyAsTarget)
            targets = buddies;
        else if (buddies.length)
            sources = buddies;
        if (step.dataFlags & ScriptFlag.reverseDirection)
        {
            auto swap = sources;
            sources = targets;
            targets = swap;
        }
        if (step.dataFlags & ScriptFlag.sourceTargetsSelf)
            targets = sources;
        if (step.command == ScriptCommand.terminateScript)
            return terminates(step, map, sources.length ? sources[0] : ScriptThing.init,
                targets.length ? targets[0] : ScriptThing.init, buddies.length > 0);
        bool stop;
        if (targets.length)
        {
            foreach (s; sources)
                foreach (t; targets)
                    stop |= executeScriptCommand(step, map, s, t);
        }
        else
            foreach (s; sources)
                stop |= executeScriptCommand(step, map, s, ScriptThing.init);
        // A step with no source at all may still act on its target (kill credit, quest explored).
        if (sources.length == 0 && targets.length)
            foreach (t; targets)
                stop |= executeScriptCommand(step, map, ScriptThing.init, t);
        return stop;
    }

    /// `SCRIPT_COMMAND_TERMINATE_SCRIPT`: stops when its buddy is not near (or, with the additional flag, when it is).
    private bool terminates(const ref DbScriptStep step, Map map, ScriptThing source, ScriptThing target, bool buddyFound)
    {
        if (!source.exists && !target.exists)
            return true;
        bool found = buddyFound;
        if (step.datalong)
        {
            auto searcher = source.exists ? source : target;
            if (!searcher.creatureOrGo && target.exists)
                searcher = target;
            found = false;
            const at = searcher.position;
            if (step.creatureBuddy)
            {
                foreach (creature; map.creaturesNear(at, step.datalong2))
                    if (creature.template_.entry == step.datalong && creature.alive && creature.guid != searcher.guid)
                        found = true;
            }
            else
                foreach (o; map.objectsNear(at, step.datalong2))
                    if (auto go = cast(GameObject) o)
                        if (go.spawn.entry == step.datalong)
                            found = true;
        }
        return (step.dataFlags & ScriptFlag.commandAdditional) ? found : !found;
    }

    /// The player among a step's source and target; null if neither.
    private auto scriptPlayer(ScriptThing source, ScriptThing target)
    {
        import dmangos.world.character : Character;

        foreach (o; [target, source])
            if (o.exists && !o.creatureOrGo)
                if (auto session = cast(Character) onlinePlayer(o.guid))
                    return session;
        return null;
    }

    /**
     * `SCRIPT_COMMAND_MOVE_TO`: walks to the step's point (its relay script once there), or back to
     * its spawn point; turns where it stands when the point is none; with the additional flag, is
     * there at once.
     */
    private void scriptMoveTo(const ref DbScriptStep step, Map map, Creature creature, ScriptThing target)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : launch, PointMovement, stopMoving;
        import dmangos.world.spline : MoveSpline, monsterStop;
        import dmangos.world.opcodes : Opcode;

        const here = creature.spline.finalized ? creature.position : creature.spline.position;
        Vector3 to = Vector3(step.x, step.y, step.z);
        float facing = step.o;
        if (step.dataint[0] == 1 || step.dataint[0] == 2)
        {
            const s = creature.spawn;
            to = Vector3(s.x, s.y, s.z);
            facing = s.orientation;
        }
        else if ((to.x == 0 && to.y == 0 && to.z == 0)
            || distanceSq(here, Position(to.x, to.y, to.z)) < 0.01f * 0.01f)
        {
            // Just turn round.
            if (creature.spline.finalized)
                launch(creature, map, [Vector3(here.x, here.y, here.z), Vector3(here.x, here.y, here.z)], true, step.o);
            return;
        }
        if (step.dataFlags & ScriptFlag.commandAdditional)
        {
            // Teleported there, on the same map
            stopMoving(creature, map);
            creature.movement.position = Position(to.x, to.y, to.z, step.o != 0 ? step.o : here.orientation);
            map.objectRelocated(creature);
            map.sendToObservers(creature.guid, Opcode.SMSG_MONSTER_MOVE,
                monsterStop(creature.guid, creature.position, creature.spline.id));
            return;
        }
        // Walking, unless told to run (`FORCED_MOVEMENT_RUN`, or a travel speed: a charge).
        const walk = step.datalong3 != 2 && step.datalong2 == 0;
        auto previous = creature.generator;
        if (auto point = cast(PointMovement) previous)
            previous = point.after;
        auto move = new PointMovement(to, facing == 0 ? float.nan : facing, walk, previous);
        if (step.datalong)
        {
            const relay = step.datalong, targetGuid = target.guid;
            move.onArrived = (Creature c) {
                startScript(DbScriptType.relay, relay, map, c.guid, targetGuid);
            };
        }
        creature.generator = move;
        move.initialize(creature, map);
        map.wake(creature.guid);
    }

    /// The game object of spawn `spawnGuid` on `map`, if it is there.
    private GameObject scriptSpawnedGameObject(Map map, uint spawnGuid)
    {
        import dmangos.world.objects : makeGuid, HighGuid;

        if (gameObjectSpawnIndex is null)
            foreach (i, ref spawn; data.gameObjectSpawns)
                gameObjectSpawnIndex[spawn.guid] = i;
        const index = spawnGuid in gameObjectSpawnIndex;
        if (index is null)
            return null;
        const spawn = &data.gameObjectSpawns[*index];
        return cast(GameObject) map.findObject(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid));
    }

    private long[ulong] scriptedGameObjects; // spawned by a script: guid -> when it goes (Unix time)

    /**
     * `SCRIPT_COMMAND_RESPAWN_GAMEOBJECT`: the game object of spawn `spawnGuid` (or `go`) put in
     * the world if it is not; one not spawned by default goes again after `despawnSeconds`.
     */
    private void scriptSpawnGameObject(Map map, uint spawnGuid, GameObject go, uint despawnSeconds)
    {
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.objects : makeGuid, HighGuid;

        if (go !is null)
            return; // already in the world
        if (spawnGuid == 0)
            return;
        if (gameObjectSpawnIndex is null)
            foreach (i, ref spawn; data.gameObjectSpawns)
                gameObjectSpawnIndex[spawn.guid] = i;
        const index = spawnGuid in gameObjectSpawnIndex;
        if (index is null)
            return;
        const spawn = &data.gameObjectSpawns[*index];
        if (spawn.map != map.id || map.findObject(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid)) !is null)
            return;
        auto made = makeGameObject(spawn);
        made.instanceId = map.instanceId;
        if (made is null || made.type == GameObjectType.door)
            return;
        // A static spawn just comes back; one that is not there by default goes again after a while.
        if (spawn.respawnSeconds < 0 || gameObjectAwaitingRespawn(spawn.guid))
            scriptedGameObjects[made.guid] = unixTime + (despawnSeconds ? despawnSeconds : 0);
        gameObjectRespawnAt.remove(spawn.guid);
        map.addObject(made);
    }

    /// The game objects a script spawned whose time is up, gone again.
    package void scriptedGameObjectsDue()
    {
        const now = unixTime;
        ulong[] due;
        foreach (guid, at; scriptedGameObjects)
            if (at <= now)
                due ~= guid;
        foreach (guid; due)
        {
            scriptedGameObjects.remove(guid);
            foreach (map; maps)
                if (map.findObject(guid) !is null)
                    map.removeObject(guid);
        }
    }

    /// Carries out a step's command; true if the script should stop.
    private bool executeScriptCommand(const ref DbScriptStep step, Map map, ScriptThing source, ScriptThing target)
    {
        import dmangos.world.updatefields;

        auto player = scriptPlayer(source, target);
        if (step.conditionId && (player is null || !player.conditionMet(step.conditionId)))
            return false;
        auto creature = source.creature;
        if (creature !is null && creature.ai !is null)
            creature.ai.bind(map);
        switch (step.command)
        {
        case ScriptCommand.talk:
        {
            if (creature is null || creature.ai is null)
                break;
            int text = step.dataint[0];
            if (step.datalong)
            {
                const group = data.eventAi.textGroups.get(step.datalong, null);
                if (group.length == 0)
                    break;
                text = group[uniform(0, group.length)];
            }
            else if (step.dataint[1])
            {
                size_t filled = 1;
                while (filled < 4 && step.dataint[filled])
                    ++filled;
                text = step.dataint[uniform(0, filled)];
            }
            if (text > 0)
                creature.ai.scriptText(text, target.guid);
            break;
        }
        case ScriptCommand.emote:
        {
            if (creature is null || creature.ai is null)
                break; // a player's emote: not yet
            uint[] emotes = [step.datalong];
            foreach (e; step.dataint)
            {
                if (!e)
                    break;
                emotes ~= cast(uint) e;
            }
            creature.ai.scriptEmote(emotes[uniform(0, emotes.length)]);
            break;
        }
        case ScriptCommand.flagSet, ScriptCommand.flagRemove:
        {
            if (creature is null || step.datalong <= 3 || step.datalong >= UNIT_END)
                break;
            const now = creature.values[step.datalong];
            creature.values.setSlot(step.datalong, step.command == ScriptCommand.flagSet ? now | step.datalong2
                : now & ~step.datalong2);
            map.flushCreature(creature);
            break;
        }
        case ScriptCommand.questExplored:
        {
            if (player is null)
                break;
            const place = source.creatureOrGo ? source : (target.creatureOrGo ? target : ScriptThing.init);
            if (step.datalong2 && !place.exists)
                break;
            bool fail = place.creature !is null && !place.creature.alive;
            if (!fail && step.datalong2)
                fail = distanceSq(place.position, player.character.position) > float(step.datalong2) ^^ 2;
            if (fail)
                player.failQuest(step.datalong);
            else
                player.areaExploredOrEventHappens(step.datalong);
            break;
        }
        case ScriptCommand.killCredit:
        {
            if (player is null)
                break;
            auto rewarder = source.creature !is null ? source.creature : target.creature;
            const entry = step.datalong ? step.datalong : (rewarder !is null ? rewarder.template_.entry : 0);
            if (entry == 0)
                break;
            player.scriptKillCredit(entry, rewarder !is null ? rewarder.guid : 0);
            break;
        }
        case ScriptCommand.respawnGameObject:
            scriptSpawnGameObject(map, step.datalong, source.go, step.datalong2);
            break;
        case ScriptCommand.tempSpawnCreature:
        {
            import dmangos.world.creature : TempSpawnType;

            if (!source.exists)
                break;
            // Where the step says (all zeros: near the source), for its time out of combat, or until it dies.
            summonCreature(map, step.datalong, Position(step.x, step.y, step.z, step.o),
                step.datalong2 ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, step.datalong2, source.guid);
            break;
        }
        case ScriptCommand.openDoor, ScriptCommand.closeDoor:
        {
            // The door of the spawn named (or the source, or the target), for its reset time (15 s at least).
            GameObject door = source.go !is null ? source.go : target.go;
            if (step.datalong)
                door = scriptSpawnedGameObject(map, step.datalong);
            if (door is null)
                break;
            import dmangos.world.gameobject : GameObjectType;

            if (door.type != GameObjectType.door && door.type != GameObjectType.button)
                break;
            const reset = step.datalong2 < 15 ? 15 : step.datalong2;
            door.useOpenable(map, step.command == ScriptCommand.openDoor, reset * 1000);
            map.wake(door.guid);
            break;
        }
        case ScriptCommand.removeAura:
            if (creature !is null && creature.ai !is null)
                creature.ai.scriptRemoveAura(creature.guid, step.datalong);
            else if (auto session = cast(typeof(player)) onlinePlayer(source.guid))
                session.auraRemovedBy(step.datalong);
            break;
        case ScriptCommand.castSpell:
        {
            uint spell = step.datalong;
            size_t filled;
            while (filled < 4 && step.dataint[filled])
                ++filled;
            if (filled)
                if (const pick = uniform(0, filled + 1))
                    spell = step.dataint[pick - 1];
            const at = (step.dataFlags & ScriptFlag.commandAdditional) || !target.exists ? source : target;
            if (creature !is null && creature.ai !is null)
                creature.ai.scriptCast(spell, at.guid, 2 /* triggered */);
            else if (source.go !is null && target.exists)
            {
                // A game object casts through its target, at itself.
                if (auto session = cast(typeof(player)) onlinePlayer(target.guid))
                    session.castTriggeredAt(spell, target.guid);
            }
            else if (auto session = cast(typeof(player)) onlinePlayer(source.guid))
                session.castTriggeredAt(spell, at.guid);
            break;
        }
        case ScriptCommand.despawnSelf:
        {
            auto who = target.creature !is null ? target.creature : creature;
            if (who !is null && who.ai !is null)
            {
                who.ai.bind(map);
                who.ai.scriptDespawn(step.datalong);
                map.wake(who.guid);
            }
            break;
        }
        case ScriptCommand.setFaction:
            if (creature is null)
                break;
            const faction = step.datalong ? step.datalong : creature.template_.faction;
            creature.factionTemplate = client.factionTemplates.lookup(faction);
            creature.values.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
            map.flushCreature(creature);
            break;
        case ScriptCommand.morphToEntryOrModel, ScriptCommand.mountToEntryOrModel:
        {
            // A model (with the additional flag), or the model of a creature entry; 0 puts its own back (or dismounts).
            if (creature is null)
                break;
            import dmangos.world.creature : chooseDisplay;

            uint display = step.datalong;
            if (display && !(step.dataFlags & ScriptFlag.commandAdditional))
            {
                const t = step.datalong in data.creatureTemplates;
                display = t is null ? 0 : chooseDisplay(*t, spawnRandom);
                if (display == 0)
                    break;
            }
            if (step.command == ScriptCommand.mountToEntryOrModel)
                creature.values.set!UNIT_FIELD_MOUNTDISPLAYID(display);
            else
                creature.values.set!UNIT_FIELD_DISPLAYID(display ? display
                    : creature.values.get!UNIT_FIELD_NATIVEDISPLAYID);
            map.flushCreature(creature);
            break;
        }
        case ScriptCommand.moveTo:
            if (creature !is null)
                scriptMoveTo(step, map, creature, target);
            break;
        case ScriptCommand.movement:
        {
            // `MovementType`: 0 standing, 1 wandering (so far, or as its spawn says), 2 a path round and round,
            // 4 a path there and back: path `datalong2` (0: its own), of `waypoint_path` if `datalong3` has 2.
            import dmangos.world.motion : IdleMovement, MotionType, WanderMovement, WaypointMovement;
            import dmangos.vmap.math : Vector3;

            if (creature is null)
                break;
            const s = creature.spawn;
            switch (step.datalong)
            {
            case MotionType.idle:
                creature.generator = new IdleMovement;
                break;
            case MotionType.random:
                creature.generator = new WanderMovement(Vector3(s.x, s.y, s.z),
                    step.datalong2 ? float(step.datalong2) : s.wanderDistance, false);
                break;
            case MotionType.waypoint, MotionType.linearWaypoint:
                const path = data.waypoints.pathFor(s.entry, s.guid, step.datalong2, (step.datalong3 & 2) != 0);
                if (path.length == 0)
                    return false;
                creature.generator = new WaypointMovement(path, step.datalong == MotionType.linearWaypoint);
                break;
            default:
                return false;
            }
            creature.generator.initialize(creature, map);
            map.wake(creature.guid);
            break;
        }
        case ScriptCommand.pauseWaypoints:
            import dmangos.world.motion : WaypointMovement;

            if (creature !is null)
                if (auto path = cast(WaypointMovement) creature.generator)
                {
                    path.paused = step.datalong != 0;
                    map.wake(creature.guid);
                }
            break;
        case ScriptCommand.sendAiEvent:
        {
            // An AI event of its type from the source: to the creatures around (within datalong2), or to the target.
            if (creature is null || creature.ai is null)
                break;
            if (step.datalong2)
                creature.ai.scriptThrowAiEvent(step.datalong, step.datalong2, target.guid);
            else if (target.creature !is null && target.creature.ai !is null)
                target.creature.ai.aiEventFrom(step.datalong, creature, target.guid, map);
            break;
        }
        case ScriptCommand.standState:
            if (creature !is null && creature.ai !is null)
                creature.ai.scriptStandState(step.datalong);
            break;
        case ScriptCommand.modifyNpcFlags:
        {
            if (creature is null)
                break;
            const flags = creature.values.get!UNIT_NPC_FLAGS;
            uint changed = flags;
            if (step.datalong2 == 0)
                changed &= ~step.datalong;
            else if (step.datalong2 == 1)
                changed |= step.datalong;
            else if (step.datalong2 == 2)
                changed ^= step.datalong;
            creature.values.set!UNIT_NPC_FLAGS(changed);
            map.flushCreature(creature);
            break;
        }
        case ScriptCommand.setFacing:
        {
            if (creature is null || !target.exists)
                break;
            import std.math : atan2;
            import dmangos.vmap.math : Vector3;
            import dmangos.world.motion : launch;

            const from = creature.position, to = target.position;
            const facing = step.datalong ? creature.spawn.orientation : atan2(to.y - from.y, to.x - from.x);
            if (creature.spline.finalized)
                launch(creature, map, [Vector3(from.x, from.y, from.z), Vector3(from.x, from.y, from.z)], true, facing);
            break;
        }
        case ScriptCommand.startRelayScript:
        {
            const relay = step.datalong2 ? data.dbScripts.randomRelay(step.datalong2) : step.datalong;
            if (relay)
                startScript(DbScriptType.relay, relay, map, source.guid, target.guid);
            break;
        }
        default:
            trace!"database script %s: command %s not handled"(step.id, step.command);
            break;
        }
        return false;
    }
}

unittest
{
    DbScriptStep a = {id: 1, delay: 2000, command: ScriptCommand.talk};
    DbScriptStep b = {id: 1, delay: 0, priority: 1, command: ScriptCommand.emote};
    DbScriptStep c = {id: 1, delay: 0, priority: 0, command: ScriptCommand.standState};
    auto data = new DbScriptData;
    data.add(DbScriptType.relay, a);
    data.add(DbScriptType.relay, b);
    data.add(DbScriptType.relay, c);
    const steps = data.steps(DbScriptType.relay, 1);
    assert(steps.length == 3 && steps[0].command == ScriptCommand.standState && steps[2].command == ScriptCommand.talk,
        "by delay, then priority");
    assert(data.steps(DbScriptType.questEnd, 1).length == 0);
    DbScriptStep respawn = {command: ScriptCommand.respawnGameObject};
    assert(!respawn.creatureBuddy && a.creatureBuddy);
}

/**
 * A relay script run by the context: the innkeeper's emote at once, a second on its yell and the
 * player's quest explored; then it stops, as no buddy it needs is near, before its last step.
 */
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.creature : Creature;
    import dmangos.world.movement : Position;
    import dmangos.world.npcdata : BroadcastText;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.quests : Quest, QuestState;
    import dmangos.world.player : Player;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    enum uint yell = 95101, relay = 500, questId = 9400;
    context.data.npcs.broadcastTexts[yell] = BroadcastText("Behold!", "", 0, 1);
    Quest q = {id: questId, method: 2, maxLevel: 60, title: "Witness", specialFlags: 0x02};
    context.data.quests.quests[questId] = q;
    with (context.data.dbScripts)
    {
        add(DbScriptType.relay, DbScriptStep(relay, 0, 0, ScriptCommand.emote, 5));
        add(DbScriptType.relay, DbScriptStep(relay, 1000, 0, ScriptCommand.talk, 0, 0, 0, 0, 0, 0, [yell, 0, 0, 0]));
        add(DbScriptType.relay, DbScriptStep(relay, 1000, 1, ScriptCommand.questExplored, questId));
        add(DbScriptType.relay, DbScriptStep(relay, 2000, 0, ScriptCommand.terminateScript, 99999, 10));
        add(DbScriptType.relay, DbScriptStep(relay, 3000, 0, ScriptCommand.modifyNpcFlags, 0x80, 1));
    }
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    anduin.session.inWorld.addQuest(context.data.quests.quests[questId]);
    anduin.read();
    const flags = keeper.values.get!UNIT_NPC_FLAGS;

    assert(!context.startScript(DbScriptType.relay, 501, map, keeper.guid, anduin.session.character.guid));
    assert(context.startScript(DbScriptType.relay, relay, map, keeper.guid, anduin.session.character.guid));
    context.updateScripts(0);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_EMOTE), "the emote at once");
    context.updateScripts(999);
    assert(!opcodesOf(anduin.read()).canFind(Opcode.SMSG_MESSAGECHAT), "not yet");
    context.updateScripts(1);
    const said = opcodesOf(anduin.read());
    assert(said.canFind(Opcode.SMSG_MESSAGECHAT) && said.canFind(Opcode.SMSG_QUESTUPDATE_COMPLETE), "the yell, the place");
    const me = cast(Player) anduin.session.character;
    assert(me.questStatus[questId].status == QuestState.complete);
    context.updateScripts(2000);
    assert(context.runningScripts == 0, "stopped: no buddy near");
    assert(keeper.values.get!UNIT_NPC_FLAGS == flags, "its last step never ran");

    // EventAI: a player's emote at it gives kill credit and starts a relay script (a stand state).
    import dmangos.world.eventai;

    enum uint wave = 101, credit = 9401, sit = 501;
    Quest c = {id: credit, method: 2, maxLevel: 60, title: "Greet", specialFlags: 0x20};
    c.reqCreatureOrGoId[0] = 12345;
    c.reqCreatureOrGoCount[0] = 1;
    context.data.quests.quests[credit] = c;
    anduin.session.inWorld.addQuest(context.data.quests.quests[credit]);
    context.data.dbScripts.add(DbScriptType.relay, DbScriptStep(sit, 0, 0, ScriptCommand.standState, 1));
    EventAiEvent greeted = {id: 1, type: EventType.receiveEmote, chance: 100, params: [wave, 0, 0, 0, 0, 0]};
    greeted.actions[0] = EventAiAction(ActionType.killedMonster, [12345, EventTarget.actionInvoker, 0]);
    greeted.actions[1] = EventAiAction(ActionType.startRelayScript, [sit, EventTarget.actionInvoker, 0]);
    auto events = [greeted];
    keeper.ai.setScript(events, context.data.eventAi);
    anduin.read();
    keeper.ai.receivedEmote(me.guid, wave, map);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_QUESTUPDATE_ADD_KILL), "the credit");
    assert(me.questStatus[credit].status == QuestState.complete);
    context.updateScripts(0);
    assert(keeper.values.getByte!UNIT_FIELD_BYTES_1(0) == 1, "sitting, by the relay script");

    // A model (the additional flag), then its own again.
    enum uint morph = 502;
    DbScriptStep toModel = {id: morph, command: ScriptCommand.morphToEntryOrModel, datalong: 308,
        dataFlags: ScriptFlag.commandAdditional};
    DbScriptStep back = {id: morph, delay: 1000, command: ScriptCommand.morphToEntryOrModel};
    context.data.dbScripts.add(DbScriptType.relay, toModel);
    context.data.dbScripts.add(DbScriptType.relay, back);
    const own = keeper.values.get!UNIT_FIELD_DISPLAYID;
    context.startScript(DbScriptType.relay, morph, map, keeper.guid, 0);
    context.updateScripts(0);
    assert(keeper.values.get!UNIT_FIELD_DISPLAYID == 308);
    context.updateScripts(1000);
    assert(keeper.values.get!UNIT_FIELD_DISPLAYID == own);

    // A walk to a point 4 yards off, then a relay script there (an emote), and back to standing.
    import core.time : msecs;
    import dmangos.world.motion : PointMovement;

    enum uint walk = 503, arrive = 504;
    const from = keeper.position;
    DbScriptStep go = {id: walk, command: ScriptCommand.moveTo, datalong: arrive, x: from.x + 4, y: from.y, z: from.z};
    context.data.dbScripts.add(DbScriptType.relay, go);
    context.data.dbScripts.add(DbScriptType.relay, DbScriptStep(arrive, 0, 0, ScriptCommand.emote, 3));
    const was = keeper.generator;
    context.startScript(DbScriptType.relay, walk, map, keeper.guid, 0);
    context.updateScripts(0);
    assert(cast(PointMovement) keeper.generator !is null && !keeper.spline.finalized, "walking");
    anduin.read();
    foreach (_; 0 .. 20)
        map.update(250.msecs);
    assert(keeper.generator is was, "back to what it did");
    const there = keeper.position;
    assert((there.x - from.x - 4) ^^ 2 + (there.y - from.y) ^^ 2 < 0.01f);
    context.updateScripts(0);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_EMOTE), "its relay script, there");

    // AI events: the innkeeper, greeted, throws one; the trainer near it answers with an emote.
    {
        auto trainer = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
        EventAiEvent greet = {id: 3, type: EventType.receiveEmote, chance: 100, params: [wave + 2, 0, 0, 0, 0, 0]};
        greet.actions[0] = EventAiAction(ActionType.throwAiEvent, [5, 50, EventTarget.actionInvoker]);
        auto throwing = [greet];
        keeper.ai.setScript(throwing, context.data.eventAi);
        EventAiEvent heard = {id: 4, type: EventType.receiveAiEvent, chance: 100,
            params: [5, creatureInnkeeper, 0, 0, 0, 0]};
        heard.actions[0] = EventAiAction(ActionType.emote, [4, 0, 0]);
        auto hearing = [heard];
        trainer.ai.setScript(hearing, context.data.eventAi);
        anduin.read();
        keeper.ai.receivedEmote(me.guid, wave + 2, map);
        bool answered;
        foreach (packet; anduin.read())
            if (packet.opcode == Opcode.SMSG_EMOTE && packet.body_.length >= 12)
            {
                auto r = ByteReader(packet.body_);
                const emote = r.read!uint, who = r.read!ulong;
                answered |= emote == 4 && who == trainer.guid;
            }
        assert(answered, "the trainer heard the innkeeper's AI event");
    }

    // A player's spells: a dummy effect runs the spell's script (the place explored); a wild summon summons.
    {
        import dmangos.world.spellhandlers : testSpell;

        enum uint ritual = 95200, call = 95201, rite = 9402;
        Quest r = {id: rite, method: 2, maxLevel: 60, title: "Rite", specialFlags: 0x02};
        context.data.quests.quests[rite] = r;
        anduin.session.inWorld.addQuest(context.data.quests.quests[rite]);
        context.data.spells.spells[ritual] = testSpell(ritual, 3, 1, 0);
        context.data.spells.spells.edit(ritual).casting.dmgClass = 0;
        context.data.dbScripts.add(DbScriptType.spell, DbScriptStep(ritual, 0, 0, ScriptCommand.questExplored, rite));
        anduin.session.inWorld.castTriggeredAt(ritual, me.guid);
        context.updateScripts(0);
        assert(me.questStatus[rite].status == QuestState.complete, "the spell's script");

        context.data.spells.spells[call] = testSpell(call, 41, 1, 0);
        context.data.spells.spells.edit(call).miscValue[0] = creatureTrainer;
        context.data.spells.spells.edit(call).casting.dmgClass = 0;
        anduin.session.inWorld.castTriggeredAt(call, me.guid);
        bool found;
        foreach (near; map.creaturesNear(me.position, 5))
            if (near.summon.summoner == me.guid && near.template_.entry == creatureTrainer)
                found = true;
        assert(found, "summoned beside the caster");
    }

    // A summon (for 3 seconds): beside it, and gone after its time out of combat, for good.
    import dmangos.world.creature : TempSpawnType;

    EventAiEvent called = {id: 2, type: EventType.receiveEmote, chance: 100, params: [wave + 1, 0, 0, 0, 0, 0]};
    called.actions[0] = EventAiAction(ActionType.spawn, [creatureTrainer, EventTarget.self, 3000]);
    auto summoning = [called];
    keeper.ai.setScript(summoning, context.data.eventAi);
    const before = map.creaturesNear(keeper.position, 10).length;
    keeper.ai.receivedEmote(me.guid, wave + 1, map);
    Creature summoned;
    foreach (near; map.creaturesNear(keeper.position, 10))
        if (near.summon.type != TempSpawnType.none)
            summoned = near;
    assert(summoned !is null && summoned.template_.entry == creatureTrainer && summoned.summon.summoner == keeper.guid);
    const guid = summoned.guid;
    map.update(2000.msecs);
    assert(map.findObject(guid) !is null);
    map.update(1100.msecs);
    assert(map.findObject(guid) is null, "gone after its time");
    assert(map.creaturesNear(keeper.position, 10).length == before);

    // Its look by its script: another model, a mount, its weapons out; then it dies of its own accord.
    EventAiEvent changed = {id: 3, type: EventType.receiveEmote, chance: 100, params: [wave + 2, 0, 0, 0, 0, 0]};
    changed.actions[0] = EventAiAction(ActionType.morph, [0, 1234, 0]);
    changed.actions[1] = EventAiAction(ActionType.mount, [0, 555, 0]);
    changed.actions[2] = EventAiAction(ActionType.setSheath, [1, 0, 0]);
    auto looks = [changed];
    keeper.ai.setScript(looks, context.data.eventAi);
    keeper.ai.receivedEmote(me.guid, wave + 2, map);
    assert(keeper.values.get!UNIT_FIELD_DISPLAYID == 1234 && keeper.values.get!UNIT_FIELD_MOUNTDISPLAYID == 555
        && keeper.values.getByte!UNIT_FIELD_BYTES_2(0) == 1, "its new look");
    EventAiEvent ended = {id: 4, type: EventType.receiveEmote, chance: 100, params: [wave + 3, 0, 0, 0, 0, 0]};
    ended.actions[0] = EventAiAction(ActionType.die, [0, 0, 0]);
    auto ending = [ended];
    keeper.ai.setScript(ending, context.data.eventAi);
    keeper.ai.receivedEmote(me.guid, wave + 3, map);
    assert(!keeper.alive, "it died");
}
