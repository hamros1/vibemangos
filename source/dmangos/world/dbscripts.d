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

import dmangos.world.spellids;

import dmangos.mysql : MySqlConnection;
import dmangos.world.character : Character;
import dmangos.world.creature : Creature;
import dmangos.world.database : OutdoorQuestUpdate, OutdoorScriptCheckpoint, OutdoorSummonRequest, OutdoorWorldState,
    QuestActorCheckpoint;
import dmangos.world.grid : noCell;
import dmangos.world.movement : Position;
import dmangos.world.quests : QuestStatus;

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

/// The tables, by `DbScriptType` (one per member: the array's length is the enum's).
immutable string[DbScriptType.max + 1] dbScriptTables = ["dbscripts_on_quest_start", "dbscripts_on_quest_end", "dbscripts_on_gossip",
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
    despawnGameObject = 40,
    startRelayScript = 45,
    setWorldState = 53,
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
        case ScriptCommand.respawnGameObject, ScriptCommand.despawnGameObject, 11, 12, 13, 27, 43:
            return false;
        default:
            return true;
        }
    }

    /// Steps whose effect can be applied by the node simulating one selected creature.
    bool runsAtCreature() const pure nothrow @nogc @safe
    {
        switch (command)
        {
        case ScriptCommand.talk, ScriptCommand.emote, ScriptCommand.moveTo, ScriptCommand.flagSet,
            ScriptCommand.flagRemove, ScriptCommand.removeAura, ScriptCommand.castSpell, ScriptCommand.despawnSelf,
            ScriptCommand.setFaction, ScriptCommand.morphToEntryOrModel, ScriptCommand.mountToEntryOrModel,
            ScriptCommand.movement, ScriptCommand.standState, ScriptCommand.modifyNpcFlags, ScriptCommand.pauseWaypoints,
            ScriptCommand.setFacing, ScriptCommand.startRelayScript:
            return true;
        default:
            return false;
        }
    }

    /// Identifies the exact row on a peer regardless of ordering of tied delay and priority.
    uint fingerprint() const
    {
        import dmangos.bytes : ByteReader, ByteWriter;
        import dmangos.serialization : serialize;
        import std.digest.crc : crc32Of;

        ByteWriter bytes;
        serialize(bytes, this);
        const checksum = crc32Of(bytes.data);
        auto reader = ByteReader(checksum[]);
        return reader.read!uint;
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

    uint[uint] summonRelays; /// spawn-data template ID -> relay started by a temporary summon

    /// The steps of script `id` of `type`, in the order they run.
    const(DbScriptStep)[] steps(DbScriptType type, uint id) const
    {
        return scripts[type].get(id, null);
    }

    /// Every step can run immediately on the selected creature without resolving another actor.
    package bool targetsOnly(uint spell) const
    {
        const plan = steps(DbScriptType.spell, spell);
        foreach (ref step; plan)
        {
            if (step.delay || step.conditionId || step.wantsBuddy)
                return false;
            if (step.command == ScriptCommand.despawnSelf && !step.dataFlags)
                continue;
            if (step.command != ScriptCommand.castSpell
                || step.dataFlags != (ScriptFlag.reverseDirection | ScriptFlag.sourceTargetsSelf))
                return false;
        }
        return plan.length != 0;
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

    /// Reads the `dbscripts_on_*` tables, relay groups and creature spawn relays.
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
                // The marksman is the caster. Dorius, the step's buddy, receives the scripted shot.
                if (type == DbScriptType.relay && s.id == 8338 && s.command == ScriptCommand.castSpell
                    && s.datalong == 12198 && s.buddyEntry == 8284 && s.dataFlags == 0)
                    s.dataFlags = ScriptFlag.buddyAsTarget;
                byId[s.id] ~= s;
                ++count;
            }
            foreach (id, steps; byId)
                data.scripts[type][id] = steps;
        }}
        foreach (row; world.query!"SELECT id, target_id FROM dbscript_random_templates WHERE type = 1"())
            data.relayGroups[row.get!uint(0)] ~= row.get!uint(1);
        foreach (row; world.query!"SELECT Entry, RelayId FROM creature_spawn_data_template WHERE RelayId <> 0"())
            data.summonRelays[row.get!uint(0)] = row.get!uint(1);
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
    import dmangos.world.replication : Replica;
    import dmangos.world.updatefields : TypeId;

    ulong guid;
    Position position;
    Creature creature;   /// if it is one
    GameObject go;       /// ditto
    Replica mirror;      /// observed location, with authority on its own node

    /// Whether there is one.
    @property bool exists() const pure nothrow @nogc @safe
    {
        return guid != 0;
    }

    /// Whether it is a creature or a game object .
    @property bool creatureOrGo() const
    {
        return creature !is null || go !is null || (mirror !is null && mirror.fieldsOf.type != TypeId.player);
    }

    @property bool isCreature() const
    {
        return creature !is null || (mirror !is null && mirror.fieldsOf.type == TypeId.unit);
    }
}

/// Whether a script starts again while the same one runs (`Map::ScriptExecutionParam`).
enum ScriptUnique
{
    no,       /// it always starts
    bySource, /// not while it runs with the same source (`SCRIPT_EXEC_PARAM_UNIQUE_BY_SOURCE`)
    byTarget, /// not while it runs with the same target (`SCRIPT_EXEC_PARAM_UNIQUE_BY_TARGET`)
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
    ulong anchor;           /// outdoor world object whose region carries this run
    ulong home = noCell;    /// also retained if the anchor despawns during the run
    bool waitForSource, waitForTarget; /// players present when the old owner released the copy
    long waitForPlayersUntil;
    ushort outdoorOrigin;
    ulong outdoorSequence;
    long outdoorStartedAt;
    long outdoorRetryAt;
    bool outdoorSaved;
    bool waitingForSummons;
    /// The claim of step `next` failed without an answer, and may have committed (`claimOutdoorStep`).
    bool claimInDoubt;
    /// What that step staged: published as it was if the claim did commit (its summons' rows name their guids).
    OutdoorScriptStep* stagedInDoubt;

    this(DbScriptType type, uint id, uint mapId, uint instanceId, ulong source, ulong target,
        const(DbScriptStep)[] steps)
    {
        this.type = type;
        this.id = id;
        this.mapId = mapId;
        this.instanceId = instanceId;
        this.source = source;
        this.target = target;
        this.steps = steps;
    }
}

package struct ScriptQuestEffect
{
    enum Kind { explored, failed, kill }

    Character player;
    Kind kind;
    uint id;
    ulong rewarder;

    void apply(QuestStatus[uint]* proposed = null)
    {
        final switch (kind)
        {
        case Kind.explored: player.areaExploredOrEventHappens(id, proposed); break;
        case Kind.failed: player.failQuest(id, proposed); break;
        case Kind.kill: player.scriptKillCredit(id, rewarder, proposed); break;
        }
    }
}

package struct ScriptCreatureSpawn
{
    Creature creature;
    uint relay;
    ulong target;
    QuestActorCheckpoint checkpoint;
    ScriptRun relayRun;
}

package struct ScriptSummonPayload
{
    uint entry, duration, relay;
    Position at;
    ulong source, target;
}

package struct OutdoorObjectPayload
{
    uint entry;
    long expiresAt;
    Position at;
}

package struct OutdoorOpenableAction
{
    ulong guid;
    uint seconds;
    bool open;
}

package struct OutdoorScriptedObject
{
    ulong guid;
    uint seconds;
}

package struct OutdoorOpenableState
{
    long resetAt;
    bool open;
    long expiresAt;
}

package struct OutdoorScriptStep
{
    imported!"dmangos.cluster.protocol".ScriptQuestCredit[] credits;
    private QuestStatus[uint][Character] rows;
    ScriptQuestEffect[] effects;
    ScriptCreatureSpawn[] summons;
    QuestActorCheckpoint[] changedActors;
    ScriptRun[] relays;
    OutdoorScriptCheckpoint[] relayCheckpoints;
    OutdoorSummonRequest[] forwards;
    OutdoorWorldState[] worldStates;
    ulong parentHome;
    void delegate()[] afterCommit;

    void add(ScriptQuestEffect effect)
    {
        effect.apply(&rows.require(effect.player, null));
        effects ~= effect;
    }

    OutdoorQuestUpdate[] updates()
    {
        OutdoorQuestUpdate[] result;
        foreach (player, quests; rows)
            if (quests.length)
                result ~= OutdoorQuestUpdate(player.player.data.guid, quests.values);
        return result;
    }

    QuestActorCheckpoint[] actorCheckpoints()
    {
        auto result = changedActors;
        foreach (ref summon; summons)
            if (summon.checkpoint.actor)
                result ~= summon.checkpoint;
        return result;
    }

    void discardUnpublishedSummons()
    {
        foreach (ref summon; summons)
            if (summon.creature !is null)
                summon.creature.ai.releaseBehaviour();
    }
}

/**
 * The database scripts' side of `WorldContext`: starting a script, the steps due each tick, and
 * the commands.
 */
mixin template DbScriptRunner()
{
    import dmangos.cluster.protocol : ScriptCreatureStep, ScriptGameObject, ScriptQuestCredit;
    import dmangos.world.spellids;
    import std.random : uniform;
    import dmangos.log : trace;
    import dmangos.world.dbscripts;
    import dmangos.world.dbscripts : OutdoorObjectPayload, OutdoorOpenableAction, OutdoorOpenableState, OutdoorScriptedObject,
        OutdoorScriptStep, ScriptCreatureSpawn, ScriptQuestEffect, ScriptSummonPayload;
    import dmangos.world.creature : Creature;
    import dmangos.world.database : OutdoorScriptCheckpoint, OutdoorSummonKind, OutdoorSummonRequest, OutdoorWorldState, QuestActorCheckpoint;
    import dmangos.world.gameobject : GameObject;
    import dmangos.world.grid : noCell;
    import dmangos.world.map : Map;
    import dmangos.world.movement : Position;
    import dmangos.world.replication : Replica;

    private ScriptRun[] scriptRuns;
    private bool retryOutdoorScriptRecovery;
    private long nextOutdoorScriptRecovery;
    private long nextOutdoorSummonPoll;

    bool delegate(ushort, const ref ScriptGameObject) sendScriptGameObject;
    private ulong[ushort] lastScriptGameObject;
    bool delegate(ushort, const ref ScriptCreatureStep) sendScriptCreatureStep;
    private ulong[ushort] lastCreatureStep;

    void scriptCreatureStepArrived(ushort peer, const ref ScriptCreatureStep message)
    {
        enum maxTransitMs = 2_000;
        if (!peer || message.sequence <= lastCreatureStep.get(peer, 0) || !canWrite()
            || message.table > DbScriptType.max || cast(int) (transportNow() - message.sentAt) > maxTransitMs)
            return;
        if (client.maps.lookup(message.map) is null || instanceable(message.map))
            return;
        lastCreatureStep[peer] = message.sequence;
        const type = cast(DbScriptType) message.table;
        foreach (ref step; data.dbScripts.steps(type, message.script))
        {
            if (step.fingerprint != message.fingerprint)
                continue;
            if (step.command == ScriptCommand.tempSpawnCreature)
            {
                const at = Position(message.x, message.y, message.z, message.orientation);
                if (message.source && message.actor == message.source
                    && ((step.x == 0 && step.y == 0 && step.z == 0) || at == Position(step.x, step.y, step.z, step.o)))
                    placeScriptCreature(map(message.map), step, at, message.source, message.target, type, peer,
                        message.forwarded);
                return;
            }
            auto region = existingMap(message.map, 0);
            if (!step.runsAtCreature || region is null)
                return;
            auto source = scriptObject(region, message.source), target = scriptObject(region, message.target);
            const actor = scriptActor(step, source, target);
            if (actor.guid != message.actor || !actor.isCreature)
                return;
            if (actor.creature !is null)
                executeScriptCommand(type, step, region, source, target, true);
            else if (!message.forwarded && actor.mirror.owner && actor.mirror.owner != peer
                && actor.mirror.owner != nodeId && sendScriptCreatureStep !is null)
            {
                ScriptCreatureStep next = message;
                next.sequence = nextGameplaySequence();
                next.forwarded = true;
                sendScriptCreatureStep(actor.mirror.owner, next);
            }
            return;
        }
    }

    void scriptGameObjectArrived(ushort peer, const ref ScriptGameObject command)
    {
        if (!peer || command.sequence <= lastScriptGameObject.get(peer, 0) || !canWrite()
            || command.action > ScriptGameObject.Action.max
            || client.maps.lookup(command.map) is null || instanceable(command.map))
            return;
        lastScriptGameObject[peer] = command.sequence;
        final switch (command.action)
        {
        case ScriptGameObject.Action.summon:
            placeWildGameObject(map(command.map), command.entry,
                Position(command.x, command.y, command.z, command.orientation), command.delay, peer, command.forwarded);
            break;
        case ScriptGameObject.Action.respawn, ScriptGameObject.Action.despawn,
            ScriptGameObject.Action.open, ScriptGameObject.Action.close:
            scriptGameObjectAction(map(command.map), command.target, command.delay, command.action, peer, command.forwarded);
            break;
        }
    }

    /// The scripts under way.
    @property size_t runningScripts() const
    {
        return scriptRuns.length;
    }

    /**
     * Script `id` of `type` begins on `map` with `source` and `target` (either
     * may be 0); false if there is no such script. With `unique`, not while it runs already for the same source
     * or target (true: it is under way).
     */
    bool startScript(DbScriptType type, uint id, Map map, ulong source, ulong target,
        ScriptUnique unique = ScriptUnique.no)
    {
        if (map is null || id == 0)
            return false;
        const steps = data.dbScripts.steps(type, id);
        if (steps.length == 0)
            return false;
        if (unique != ScriptUnique.no)
            foreach (run; scriptRuns)
                if (run.type == type && run.id == id && run.next < run.steps.length && run.mapId == map.id
                        && run.instanceId == map.instanceId
                        && (unique == ScriptUnique.bySource ? run.source == source : run.target == target))
                    return true;
        auto run = prepareScriptRun(type, id, map, source, target, steps);
        trackOutdoorScript(run);
        scriptRuns ~= run;
        return true;
    }

    private static ScriptRun prepareScriptRun(DbScriptType type, uint id, Map map, ulong source, ulong target,
        const(DbScriptStep)[] steps)
    {
        auto run = new ScriptRun(type, id, map.id, map.instanceId, source, target, steps);
        if (!run.instanceId)
        {
            run.home = map.migrantHome(source);
            run.anchor = source;
            if (run.home == noCell)
            {
                run.home = map.migrantHome(target);
                run.anchor = target;
            }
        }
        return run;
    }

    private long scriptClock()
    {
        return startUnixMillis + (clock() - startClock).total!"msecs";
    }

    private void trackOutdoorScript(ScriptRun run, bool force = false)
    {
        if (config.cluster.enabled && !run.instanceId && run.home != noCell && (force || run.steps[$ - 1].delay))
        {
            run.outdoorOrigin = config.cluster.nodeId;
            run.outdoorSequence = nextGameplaySequence();
            run.outdoorStartedAt = scriptClock() - run.elapsed;
        }
    }

    private static uint outdoorScriptFingerprint(const(DbScriptStep)[] steps)
    {
        import dmangos.serialization : serialize;
        import std.digest.crc : crc32Of;

        ByteWriter rows;
        foreach (ref step; steps)
            serialize(rows, step);
        const checksum = crc32Of(rows.data);
        auto reader = ByteReader(checksum[]);
        return reader.read!uint;
    }

    private OutdoorScriptCheckpoint outdoorScriptState(ScriptRun run, Map map, bool localPlayers = true)
    {
        import dmangos.world.instancescripting : toHex;

        ByteWriter state;
        state.put(cast(ubyte) run.type);
        state.put(run.id);
        state.put(outdoorScriptFingerprint(run.steps));
        state.put(run.outdoorStartedAt);
        state.put(run.source);
        state.put(run.target);
        state.put(run.anchor);
        state.put(localPlayers && map.find(run.source) !is null);
        state.put(localPlayers && map.find(run.target) !is null);
        return OutdoorScriptCheckpoint(run.outdoorOrigin, run.outdoorSequence, run.mapId, cast(uint) run.next,
            run.home, toHex(state.data));
    }

    private bool beginOutdoorRun(ScriptRun run, Map map)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        const row = outdoorScriptState(run, map);
        try
        {
            foreach (guid; [run.source, run.target])
                if (auto session = onlinePlayer(guid))
                    if (session.character !is null && session.currentMap is map && !session.transferring)
                    {
                        session.saveQuests();
                        const progress = session.character.progress(session.secondsInWorld());
                        database.saveProgress(progress);
                    }
            if (!database.beginOutdoorScript(config.realmId, row))
            {
                // A rejected write can also mean that an earlier attempt committed before its connection broke.
                run.next = run.steps.length;
                retryOutdoorScriptRecovery = true;
                return false;
            }
            run.outdoorSaved = true;
            return true;
        }
        catch (DatabaseException error)
        {
            warning!"outdoor script %s: could not save its start: %s"(run.id, error.msg);
            run.outdoorRetryAt = unixTime + 1;
            return false;
        }
    }

    private bool claimOutdoorStep(ScriptRun run, Map map, const ref DbScriptStep step, bool finished,
        OutdoorScriptStep* planned)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        try
        {
            if (run.claimInDoubt)
                final switch (earlierClaim(run, finished))
                {
                case EarlierClaim.committed:
                    run.claimInDoubt = false;
                    if (planned !is null && run.stagedInDoubt !is null)
                        *planned = *run.stagedInDoubt;
                    run.stagedInDoubt = null;
                    run.waitingForSummons = planned !is null && planned.forwards.length != 0;
                    return true;
                case EarlierClaim.notCommitted:
                    run.claimInDoubt = false;
                    if (run.stagedInDoubt !is null)
                        run.stagedInDoubt.discardUnpublishedSummons();
                    run.stagedInDoubt = null;
                    break; // claimed again below, staged afresh
                case EarlierClaim.elsewhere:
                    run.claimInDoubt = false;
                    if (run.stagedInDoubt !is null)
                        run.stagedInDoubt.discardUnpublishedSummons();
                    run.stagedInDoubt = null;
                    run.next = run.steps.length;
                    retryOutdoorScriptRecovery = true;
                    return false;
                }
            if (planned !is null)
            {
                planned.parentHome = run.home;
                runScriptStep(run.type, step, map, run.source, run.target, planned);
                foreach (i, ref request; planned.forwards)
                {
                    request.origin = run.outdoorOrigin;
                    request.sequence = run.outdoorSequence;
                    request.cursor = cast(uint) run.next;
                    request.ordinal = cast(uint) i;
                }
            }
            if (database.advanceOutdoorScript(config.realmId, run.outdoorOrigin, run.outdoorSequence,
                    cast(uint) run.next, finished, planned is null ? null : planned.updates(),
                    planned is null ? null : planned.actorCheckpoints(),
                    planned is null ? null : planned.relayCheckpoints, planned is null ? null : planned.forwards,
                    planned is null ? null : planned.worldStates, planned is null ? null : planned.credits))
            {
                run.waitingForSummons = planned !is null && planned.forwards.length != 0;
                return true;
            }
            run.next = run.steps.length;
            retryOutdoorScriptRecovery = true;
        }
        catch (DatabaseException error)
        {
            // The COMMIT may have gone through with its answer lost and the retry unable to reconnect: whether the
            // step is ours is read back before it is claimed again (`earlierClaim`), and what it staged is kept.
            warning!"outdoor script %s: could not claim step %s: %s"(run.id, run.next, error.msg);
            if (!run.claimInDoubt && planned !is null)
            {
                run.stagedInDoubt = new OutdoorScriptStep;
                *run.stagedInDoubt = *planned;
                *planned = OutdoorScriptStep.init; // kept, not discarded with the caller's copy
            }
            run.claimInDoubt = true;
            run.outdoorRetryAt = unixTime + 1;
        }
        return false;
    }

    private enum EarlierClaim
    {
        committed,    /// the cursor moved past the step (or the finished run's row is gone): the step is this run's
        notCommitted, /// the cursor still waits at the step
        elsewhere,    /// anything else: another owner has taken the run on
    }

    /// Reads back whether a claim of `run.next` whose answer was lost committed. Throws if it cannot read.
    private EarlierClaim earlierClaim(ScriptRun run, bool finished)
    {
        foreach (ref row; database.loadOutdoorScripts(config.realmId))
            if (row.origin == run.outdoorOrigin && row.sequence == run.outdoorSequence)
            {
                if (row.cursor == run.next)
                    return EarlierClaim.notCommitted;
                return !finished && row.cursor == run.next + 1 ? EarlierClaim.committed : EarlierClaim.elsewhere;
            }
        return finished ? EarlierClaim.committed : EarlierClaim.elsewhere;
    }

    private void restoreOutdoorScripts(const(imported!"dmangos.cluster.regions".Region)[] gained = null)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.database : OutdoorScriptCheckpoint;
        import dmangos.world.instancescripting : fromHex;
        import std.algorithm.comparison : clamp;
        import std.algorithm.searching : any;

        if (!config.cluster.enabled)
            return;
        const allOwned = retryOutdoorScriptRecovery && ownsCell !is null;
        if (!allOwned && !gained.any!(r => physicalWorldRegion(r)))
            return;
        if (!canWrite())
        {
            retryOutdoorScriptRecovery = true;
            return;
        }
        OutdoorScriptCheckpoint[] saved;
        try
        {
            saved = database.loadOutdoorScripts(config.realmId);
            retryOutdoorScriptRecovery = false;
        }
        catch (DatabaseException error)
        {
            warning!"outdoor scripts: could not read pending work: %s"(error.msg);
            retryOutdoorScriptRecovery = true;
            nextOutdoorScriptRecovery = unixTime + 1;
            return;
        }
        foreach (ref row; saved)
        {
            if (allOwned ? !ownsCell(row.map, row.home)
                : !gained.any!(r => physicalWorldRegion(r) && r.map == row.map && r.rect.containsKey(row.home)))
                continue;
            if (scriptRuns.any!(run => run.outdoorOrigin == row.origin && run.outdoorSequence == row.sequence))
                continue;
            try
            {
                auto reader = ByteReader(fromHex(row.state));
                const type = cast(DbScriptType) reader.read!ubyte;
                const id = reader.read!uint, fingerprint = reader.read!uint, started = reader.read!long;
                const source = reader.read!ulong, target = reader.read!ulong, anchor = reader.read!ulong;
                const waitForSource = reader.read!bool, waitForTarget = reader.read!bool;
                const steps = type <= DbScriptType.max ? data.dbScripts.steps(type, id) : null;
                if (row.cursor >= steps.length || fingerprint != outdoorScriptFingerprint(steps))
                {
                    warning!"outdoor script %s changed while pending; discarding checkpoint"(id);
                    database.advanceOutdoorScript(config.realmId, row.origin, row.sequence, row.cursor, true);
                    continue;
                }
                map(row.map).loadCell(row.home);
                auto run = new ScriptRun(type, id, row.map, 0, source, target, steps);
                run.next = row.cursor;
                run.elapsed = cast(uint) clamp(scriptClock() - started, 0L, cast(long) uint.max);
                run.anchor = anchor;
                run.home = row.home;
                run.outdoorOrigin = row.origin;
                run.outdoorSequence = row.sequence;
                run.outdoorStartedAt = started;
                run.outdoorSaved = true;
                run.waitingForSummons = row.waitingForSummons;
                run.waitForSource = waitForSource;
                run.waitForTarget = waitForTarget;
                if (waitForSource || waitForTarget)
                    run.waitForPlayersUntil = unixTime + (long(config.cluster.leaseMs) + config.cluster.failureTimeoutMs
                        + 6_999) / 1000;
                scriptRuns ~= run;
            }
            catch (Exception error)
                warning!"outdoor script %s/%s could not be restored: %s"(row.origin, row.sequence, error.msg);
        }
    }

    /// Move outdoor scripts with their first local world object and keep their completed steps consumed.
    private imported!"dmangos.world.migration".Migrant[] takeRegionScriptRuns(Map map,
        const ref imported!"dmangos.cluster.regions".Region region)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.migration : Migrant, MigrantKind;

        Migrant[] runs;
        const now = transportNow();
        foreach (run; scriptRuns)
        {
            if (run.mapId != map.id || run.instanceId || run.home == noCell || run.next >= run.steps.length)
                continue;
            const knownHome = map.migrantHome(run.anchor);
            const home = run.outdoorSaved || knownHome == noCell ? run.home : knownHome;
            if (!region.rect.containsKey(home))
                continue;
            if (region.next && !run.outdoorSaved)
            {
                ByteWriter w;
                w.put(cast(ubyte) run.type);
                w.put(cast(uint) run.next);
                w.put(run.elapsed);
                w.put(now);
                w.put(run.source);
                w.put(run.target);
                w.put(run.anchor);
                runs ~= Migrant(MigrantKind.scriptRun, run.id, home, w.data);
            }
            run.next = run.steps.length;
        }
        scriptRuns = scriptRuns.remove!(run => run.next >= run.steps.length);
        return runs;
    }

    private void restoreRegionScriptRun(uint mapId, const ref imported!"dmangos.world.migration".Migrant migrant)
    {
        import std.algorithm.comparison : max, min;

        auto r = ByteReader(migrant.state);
        const type = cast(DbScriptType) r.read!ubyte;
        const next = r.read!uint, elapsed = r.read!uint;
        const transit = max(0, cast(int)(transportNow() - r.read!uint));
        const source = r.read!ulong, target = r.read!ulong, anchor = r.read!ulong;
        if (type > DbScriptType.max || (anchor != source && anchor != target))
            return;
        const steps = data.dbScripts.steps(type, migrant.spawn);
        if (next >= steps.length)
            return;
        auto run = new ScriptRun(type, migrant.spawn, mapId, 0, source, target, steps);
        run.next = next;
        run.elapsed = cast(uint) min(uint.max, cast(ulong) elapsed + transit);
        run.anchor = anchor;
        run.home = migrant.home;
        trackOutdoorScript(run);
        scriptRuns ~= run;
    }

    /// Saves pending database script steps. A transfer detaches them from the old map.
    private void saveDungeonScriptRuns(uint mapId, ref ByteWriter w, bool departing, uint onlyInstance = 0,
        const(uint)[] selected = null)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : canFind;

        const countAt = w.length;
        w.put(0u);
        uint count;
        const now = unixTime;
        foreach (run; scriptRuns)
        {
            if (run.mapId != mapId || run.instanceId == 0 || (onlyInstance && run.instanceId != onlyInstance)
                || run.next >= run.steps.length || (selected.length && !selected.canFind(run.id)))
                continue;
            auto copy = instanceMap(run.instanceId);
            if (copy is null)
                continue;
            ++count;
            const sourcePresent = run.source && copy.find(run.source) !is null;
            const targetPresent = run.target && copy.find(run.target) !is null;
            const awaitingPlayers = run.waitForPlayersUntil > now;
            enum playerHandoffGraceSeconds = 10;
            w.put(run.instanceId);
            w.put(cast(ubyte) run.type);
            w.put(run.id);
            w.put(cast(uint) run.next);
            w.put(run.elapsed);
            w.put(run.source);
            w.put(run.target);
            w.put(sourcePresent || (awaitingPlayers && run.waitForSource));
            w.put(targetPresent || (awaitingPlayers && run.waitForTarget));
            w.put(sourcePresent || targetPresent ? now + playerHandoffGraceSeconds : run.waitForPlayersUntil);
        }
        w.patch(countAt, count);
        if (departing)
            scriptRuns = scriptRuns.remove!(run => run.mapId == mapId && run.instanceId != 0);
    }

    /// Rebuilds transferred runs from the receiver's database without replaying their completed steps.
    private void restoreDungeonScriptRuns(uint mapId, ref ByteReader r, bool cold = false)
    {
        foreach (_; 0 .. r.read!uint)
        {
            const instance = r.read!uint;
            const type = cast(DbScriptType) r.read!ubyte;
            const id = r.read!uint;
            const next = r.read!uint;
            const elapsed = r.read!uint;
            const source = r.read!ulong, target = r.read!ulong;
            const waitForSource = r.read!bool, waitForTarget = r.read!bool;
            const waitUntil = r.read!long;
            auto copy = instanceMap(instance);
            if (copy is null || copy.id != mapId || type > DbScriptType.max)
                continue;
            const steps = data.dbScripts.steps(type, id);
            if (next >= steps.length)
                continue;
            auto run = new ScriptRun(type, id, mapId, instance, source, target, steps);
            run.next = next;
            run.elapsed = elapsed;
            run.waitForSource = waitForSource;
            run.waitForTarget = waitForTarget;
            run.waitForPlayersUntil = cold && (waitForSource || waitForTarget) ? unixTime + 10 : waitUntil;
            scriptRuns ~= run;
        }
    }

    /// Runs the steps whose time has come, `diff` milliseconds on.
    package void updateScripts(uint diff)
    {
        pollOutdoorSummons();
        if (retryOutdoorScriptRecovery && unixTime >= nextOutdoorScriptRecovery)
            restoreOutdoorScripts();
        // A copy: a step may start a relay script.
        foreach (run; scriptRuns.dup)
        {
            run.elapsed += diff > uint.max - run.elapsed ? uint.max - run.elapsed : diff;
            auto map = existingMap(run.mapId, run.instanceId);
            if (map !is null && run.outdoorSequence && (unixTime < run.outdoorRetryAt || !canWrite()
                    || (ownsCell !is null && !ownsCell(run.mapId, run.home))
                    || (!run.outdoorSaved && !beginOutdoorRun(run, map))))
                continue;
            if (run.waitingForSummons && !outdoorSummonsDone(run))
                continue;
            if (map !is null && run.waitForPlayersUntil)
            {
                if (unixTime < run.waitForPlayersUntil
                    && ((run.waitForSource && map.find(run.source) is null)
                        || (run.waitForTarget && map.find(run.target) is null)))
                    continue;
                run.waitForPlayersUntil = 0;
            }
            while (map !is null && run.next < run.steps.length && run.steps[run.next].delay <= run.elapsed)
            {
                const step = &run.steps[run.next];
                if (run.outdoorSaved)
                {
                    // A termination check has no side effects. Decide it before committing the cursor.
                    const terminator = step.command == ScriptCommand.terminateScript;
                    const stops = terminator && runScriptStep(run.type, *step, map, run.source, run.target);
                    import std.algorithm.comparison : among;

                    const stagesEffects = step.command.among(ScriptCommand.questExplored, ScriptCommand.killCredit,
                        ScriptCommand.tempSpawnCreature, ScriptCommand.openDoor, ScriptCommand.closeDoor,
                        ScriptCommand.respawnGameObject, ScriptCommand.despawnGameObject, ScriptCommand.startRelayScript,
                        ScriptCommand.setFaction, ScriptCommand.setWorldState);
                    OutdoorScriptStep planned;
                    scope (exit) planned.discardUnpublishedSummons();
                    if (!claimOutdoorStep(run, map, *step, stops || run.next + 1 == run.steps.length,
                            stagesEffects ? &planned : null))
                        break;
                    run.next = stops ? run.steps.length : run.next + 1;
                    if (!terminator && canWrite())
                    {
                        if (stagesEffects)
                            publishOutdoorStep(map, planned);
                        else
                            runScriptStep(run.type, *step, map, run.source, run.target);
                    }
                    if (run.waitingForSummons)
                    {
                        run.outdoorRetryAt = unixTime + 1;
                        break;
                    }
                }
                else
                {
                    ++run.next;
                    if (runScriptStep(run.type, *step, map, run.source, run.target))
                    {
                        run.next = run.steps.length;
                        break;
                    }
                }
            }
            if (map is null)
                run.next = run.steps.length;
        }
        import std.algorithm.mutation : remove;

        scriptRuns = scriptRuns.remove!(r => r.next >= r.steps.length);
    }

    private bool outdoorSummonsDone(ScriptRun run)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        try
        {
            run.waitingForSummons = database.outdoorSummonsPending(config.realmId, run.outdoorOrigin, run.outdoorSequence);
            if (!run.waitingForSummons)
                return true;
        }
        catch (DatabaseException error)
            warning!"outdoor script %s: could not read pending summons: %s"(run.id, error.msg);
        run.outdoorRetryAt = unixTime + 1;
        return false;
    }

    private void pollOutdoorSummons()
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!config.cluster.enabled || config.cluster.gateway || ownsCell is null || !canWrite()
            || unixTime < nextOutdoorSummonPoll)
            return;
        nextOutdoorSummonPoll = unixTime + 1;
        try
        {
            foreach (ref request; database.loadOutdoorSummons(config.realmId))
                if (canWrite() && ownsCell(request.map, request.home))
                    deliverOutdoorSummon(request);
        }
        catch (DatabaseException error)
            warning!"outdoor scripts: could not process pending summons: %s"(error.msg);
    }

    private void deliverOutdoorSummon(ref OutdoorSummonRequest request)
    {
        import dmangos.log : warning;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.serialization : deserialize;

        if (request.kind == OutdoorSummonKind.relay)
        {
            // The sender committed the child with its own cursor. Its new owner only needs to load it.
            retryOutdoorScriptRecovery = true;
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        auto where = map(request.map);
        if (request.actor)
        {
            if (request.kind == OutdoorSummonKind.scriptedDespawn)
                publishOutdoorDespawn(where, request.actor);
            else if (request.kind == OutdoorSummonKind.staticDespawn)
            {
                import dmangos.world.objects : counterOf;

                const at = database.loadGameObjectRespawns().get(counterOf(request.actor), 0L);
                if (at > unixTime && canWrite() && ownsCell(request.map, request.home))
                    publishOutdoorDespawn(where, request.actor, at);
            }
            else if (request.kind == OutdoorSummonKind.openable)
            {
                if (request.checkpoint.actor)
                {
                    const installed = request.actor in outdoorQuestActors;
                    if (installed is null || installed.state != request.checkpoint.state)
                    {
                        if (savedOpenableToggle(request.checkpoint.state))
                            restoreOutdoorOpenable(where, request.checkpoint);
                        else if (where.gameObjectAt(request.actor) is null && !restoreQueuedSummon(where, request.checkpoint))
                            return;
                    }
                }
            }
            else if (request.checkpoint.actor && where.creatureAt(request.actor) is null && where.gameObjectAt(request.actor) is null)
            {
                if (!restoreQueuedSummon(where, request.checkpoint))
                    return;
                // A former owner may have committed after this worker loaded the region.
                retryOutdoorScriptRecovery = true;
            }
            if (canWrite() && ownsCell(request.map, request.home))
                database.retireOutdoorSummon(config.realmId, request);
            return;
        }

        if (request.kind == OutdoorSummonKind.gameObject)
            return deliverOutdoorObject(where, request);
        if (request.kind == OutdoorSummonKind.openable)
            return deliverOutdoorOpenable(where, request);
        if (request.kind == OutdoorSummonKind.scriptedObject || request.kind == OutdoorSummonKind.scriptedDespawn
            || request.kind == OutdoorSummonKind.staticDespawn)
            return deliverOutdoorScriptedObject(where, request);

        ScriptSummonPayload payload;
        try
        {
            auto bytes = ByteReader(fromHex(request.state));
            payload = deserialize!ScriptSummonPayload(bytes);
        }
        catch (Exception error)
        {
            warning!"map %s: could not decode an outdoor summon: %s"(request.map, error.msg);
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        if (cellKeyAt(payload.at.x, payload.at.y) != request.home
            || !client.isValidMapCoord(request.map, payload.at.x, payload.at.y, payload.at.z, payload.at.orientation))
        {
            warning!"map %s: discarded an outdoor summon with an invalid destination"(request.map);
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        auto spawn = prepareScriptCreature(where, payload);
        if (spawn.creature is null)
        {
            warning!"map %s: discarded an outdoor summon for unavailable creature %s"(request.map, payload.entry);
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        OutdoorScriptStep planned;
        scope (exit) planned.discardUnpublishedSummons();
        stageScriptCreature(where, spawn, planned);
        if (!planned.summons[0].checkpoint.actor || !database.commitOutdoorSummon(config.realmId, request,
                planned.summons[0].checkpoint, planned.relayCheckpoints))
            return;
        request.actor = spawn.creature.guid;
        if (canWrite() && ownsCell(request.map, request.home))
        {
            publishOutdoorStep(where, planned);
            database.retireOutdoorSummon(config.realmId, request);
        }
    }

    private void deliverOutdoorObject(Map where, ref OutdoorSummonRequest request)
    {
        import dmangos.log : warning;
        import dmangos.script.api : Location;
        import dmangos.serialization : deserialize;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : fromHex;

        OutdoorObjectPayload payload;
        try
        {
            auto bytes = ByteReader(fromHex(request.state));
            payload = deserialize!OutdoorObjectPayload(bytes);
        }
        catch (Exception error)
        {
            warning!"map %s: could not decode an outdoor object summon: %s"(request.map, error.msg);
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        const proto = payload.entry in data.gameObjectTemplates;
        const at = payload.at;
        if (payload.expiresAt <= unixTime || proto is null || !durableOutdoorObject(where, proto.type)
            || cellKeyAt(at.x, at.y) != request.home || !client.isValidMapCoord(where.id, at.x, at.y, at.z, at.orientation))
        {
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        auto object = prepareGameObjectSummon(where, payload.entry, Location(at.x, at.y, at.z, at.orientation));
        commitOutdoorGameObject(where, request, object, payload.expiresAt);
    }

    private void deliverOutdoorScriptedObject(Map where, ref OutdoorSummonRequest request)
    {
        import dmangos.log : warning;
        import dmangos.serialization : deserialize;
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.objects : counterOf;

        OutdoorScriptedObject action;
        try
        {
            auto bytes = ByteReader(fromHex(request.state));
            action = deserialize!OutdoorScriptedObject(bytes);
        }
        catch (Exception error)
        {
            warning!"map %s: could not decode an outdoor scripted object: %s"(request.map, error.msg);
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        const counter = counterOf(action.guid);
        if (action.guid && scriptGameObjectGuid(counter, where.id) == action.guid)
        {
            const spawn = &data.gameObjectSpawns[gameObjectSpawnIndex[counter]];
            const proto = spawn.entry in data.gameObjectTemplates;
            const staticDespawn = request.kind == OutdoorSummonKind.staticDespawn;
            if (proto !is null && cellKeyAt(spawn.x, spawn.y) == request.home
                && (staticDespawn ? durableStaticDespawn(*spawn, *proto) : durableScriptedSpawn(*spawn, *proto)))
            {
                if (staticDespawn || request.kind == OutdoorSummonKind.scriptedDespawn)
                {
                    long respawnAt;
                    if (staticDespawn)
                    {
                        where.loadCell(request.home);
                        const object = where.gameObjectAt(action.guid);
                        if (object is null)
                        {
                            database.retireOutdoorSummon(config.realmId, request);
                            return;
                        }
                        respawnAt = outdoorObjectRespawnDeadline(object);
                    }
                    const chest = proto.type == GameObjectType.chest ? spawn.guid : 0u;
                    if (database.commitOutdoorDespawn(config.realmId, request, action.guid, chest, respawnAt)
                        && canWrite() && ownsCell(request.map, request.home))
                    {
                        request.actor = action.guid;
                        publishOutdoorDespawn(where, action.guid, respawnAt);
                        database.retireOutdoorSummon(config.realmId, request);
                    }
                    return;
                }
                if (action.seconds && where.findObject(action.guid) is null)
                    return commitOutdoorGameObject(where, request, makeGameObject(*spawn), unixTime + action.seconds);
            }
        }
        database.retireOutdoorSummon(config.realmId, request);
    }

    private void publishOutdoorDespawn(Map where, ulong guid, long respawnAt = 0)
    {
        import dmangos.world.objects : counterOf;

        // The checkpoint is already gone. A clean bundle can still have the former owner's visible copy.
        const counter = counterOf(guid);
        outdoorQuestActors.remove(guid);
        outdoorChests.remove(counter);
        if (respawnAt)
            gameObjectRespawnAt[counter] = respawnAt;
        if (where.gameObjectAt(guid) !is null)
            where.removeObject(guid);
    }

    private void commitOutdoorGameObject(Map where, ref OutdoorSummonRequest request, GameObject object, long expires)
    {
        import dmangos.world.gameobject : GameObjectType;

        bool published;
        scope (exit)
            if (!published)
                scripts.destroy(object.behaviour);
        const state = outdoorObjectCheckpoint(where, object, expires);
        const chest = object.type == GameObjectType.chest ? object.spawn.guid : 0u;
        if (!state.actor || !database.commitOutdoorSummon(config.realmId, request, state, null, chest))
            return;
        request.actor = state.actor;
        if (canWrite() && ownsCell(request.map, request.home))
        {
            outdoorQuestActors[state.actor] = state;
            if (chest)
                outdoorChests.remove(chest);
            published = true;
            publishGameObjectSummon(where, object, expires);
            database.retireOutdoorSummon(config.realmId, request);
        }
    }

    private void deliverOutdoorOpenable(Map where, ref OutdoorSummonRequest request)
    {
        import dmangos.log : warning;
        import dmangos.serialization : deserialize, serialize;
        import dmangos.world.gameobject : goStateReady;
        import dmangos.world.instancescripting : fromHex, toHex;

        OutdoorOpenableAction action;
        try
        {
            auto bytes = ByteReader(fromHex(request.state));
            action = deserialize!OutdoorOpenableAction(bytes);
        }
        catch (Exception error)
        {
            warning!"map %s: could not decode an outdoor door action: %s"(request.map, error.msg);
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        where.loadCell(request.home);
        auto door = where.gameObjectAt(action.guid);
        if (door is null || where.migrantHome(action.guid) != request.home || !door.canScriptToggleOpenable(action.open))
        {
            database.retireOutdoorSummon(config.realmId, request);
            return;
        }
        // Opening and closing both use the same toggle as a live door.
        ByteWriter bytes;
        const expires = scriptedGameObjects.get(GameObjectOnMap(where, door.guid), 0L);
        serialize(bytes, OutdoorOpenableState(unixTime + action.seconds, door.goState == goStateReady, expires));
        const checkpoint = QuestActorCheckpoint(request.map, action.guid, request.home, 0, unixTime, toHex(bytes.data));
        if (!database.commitOutdoorSummon(config.realmId, request, checkpoint, null))
            return;
        request.actor = action.guid;
        if (canWrite() && ownsCell(request.map, request.home))
        {
            restoreOutdoorOpenable(where, checkpoint);
            database.retireOutdoorSummon(config.realmId, request);
        }
    }

    private static bool savedOpenableToggle(string state)
    {
        // The compact toggle has a deadline and a bool, with the visibility deadline appended in newer rows.
        enum toggleSize = (long.sizeof + bool.sizeof) * 2;
        return state.length == toggleSize || state.length == toggleSize + long.sizeof * 2;
    }

    private void restoreOutdoorOpenable(Map where, const ref QuestActorCheckpoint checkpoint)
    {
        import dmangos.log : warning;
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.objects : counterOf;
        import std.algorithm.comparison : clamp;

        OutdoorOpenableState state;
        try
        {
            auto bytes = ByteReader(fromHex(checkpoint.state));
            state.resetAt = bytes.read!long;
            state.open = bytes.read!bool;
            if (bytes.remaining)
                state.expiresAt = bytes.read!long;
        }
        catch (Exception error)
        {
            warning!"map %s: could not restore outdoor door %s: %s"(where.id, checkpoint.actor, error.msg);
            database.deleteQuestActor(config.realmId, checkpoint.actor);
            return;
        }
        where.loadCell(checkpoint.home);
        auto door = where.gameObjectAt(checkpoint.actor);
        bool publish;
        if (door is null && state.expiresAt > unixTime)
            if (const spawn = gameObjectSpawnOf(counterOf(checkpoint.actor)))
                if (const proto = spawn.entry in data.gameObjectTemplates)
                    if (proto.type == GameObjectType.button && durableScriptedSpawn(*spawn, *proto) && spawn.map == where.id
                        && cellKeyAt(spawn.x, spawn.y) == checkpoint.home
                        && scriptGameObjectGuid(spawn.guid, where.id) == checkpoint.actor)
                    {
                        door = makeGameObject(*spawn);
                        publish = true;
                    }
        if ((!state.expiresAt || state.expiresAt > unixTime) && door !is null && door.doorOrButton
            && (publish || where.migrantHome(door.guid) == checkpoint.home))
        {
            const remaining = cast(int)(clamp(state.resetAt - unixTime, 0L, int.max / 1000L) * 1000);
            door.installOpenableState(state.open, remaining);
            if (publish)
                publishGameObjectSummon(where, door, state.expiresAt);
            else
                where.flushGameObject(door);
            if (remaining)
            {
                outdoorQuestActors[door.guid] = checkpoint;
                where.wake(door.guid);
                return;
            }
            if (state.expiresAt)
            {
                checkpointOutdoorScriptObject(where, door);
                return;
            }
        }
        outdoorQuestActors.remove(checkpoint.actor);
        database.deleteQuestActor(config.realmId, checkpoint.actor);
    }

    private void publishOutdoorStep(Map map, ref OutdoorScriptStep planned)
    {
        foreach (ref state; planned.worldStates)
            outdoorWorldStates[state.map][state.id] = state.value;
        foreach (ref effect; planned.effects)
            effect.apply();
        foreach (ref effect; planned.summons)
        {
            auto summon = effect;
            effect.creature = null;
            publishScriptCreature(map, summon);
        }
        scriptRuns ~= planned.relays;
        foreach (action; planned.afterCommit)
            action();
    }

    /// Run the immediate, target-only spell steps on the map that owns the target.
    package void applyTargetSpellScript(uint spell, Map map, ulong caster, ulong target)
    {
        foreach (ref step; data.dbScripts.steps(DbScriptType.spell, spell))
            runScriptStep(DbScriptType.spell, step, map, caster, target);
    }

    /// The object `guid` on `map`: a player there, or a creature or game object; none if it is not there.
    private ScriptThing scriptObject(Map map, ulong guid)
    {
        if (guid == 0)
            return ScriptThing.init;
        if (auto who = map.find(guid))
            return ScriptThing(guid, who.character.position);
        if (auto o = map.findObject(guid))
            return ScriptThing(guid, o.position, cast(Creature) o, cast(GameObject) o, cast(Replica) o);
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
        import std.algorithm.comparison : among;

        if (step.command.among(ScriptCommand.respawnGameObject, ScriptCommand.despawnGameObject,
            ScriptCommand.openDoor, ScriptCommand.closeDoor))
            return scriptGameObjectBuddies(step, map, source, target, buddies);
        import dmangos.world.objects : counterOf;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, UNIT_FIELD_HEALTH;

        const deadOk = (step.dataFlags & ScriptFlag.buddyIsDespawned) != 0;
        const observeOtherNodes = !map.instanceId && sendScriptCreatureStep !is null
            && (step.runsAtCreature || step.command == ScriptCommand.terminateScript)
            && !(step.dataFlags & (ScriptFlag.buddyIsPet | ScriptFlag.buddyByPool | ScriptFlag.buddyBySpawnGroup
                | ScriptFlag.buddyByStringId));
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
                if (observeOtherNodes)
                    foreach (mirror; map.creatureReplicasNear(at, 1000))
                        if (counterOf(mirror.guid) == spawn && (mirror.fields[UNIT_FIELD_HEALTH] != 0) != deadOk)
                            buddies ~= ScriptThing(mirror.guid, mirror.position, null, null, mirror);
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
            void consider(ScriptThing candidate)
            {
                if (step.dataFlags & ScriptFlag.allEligibleBuddies)
                {
                    buddies ~= candidate;
                    return;
                }
                const distance = distanceSq(at, candidate.position);
                if (distance < best)
                {
                    best = distance;
                    nearest = candidate;
                }
            }
            if (step.creatureBuddy)
            {
                foreach (creature; map.creaturesNear(at, range))
                {
                    if (creature.template_.entry != step.buddyEntry || creature.alive == deadOk)
                        continue;
                    consider(thing(creature));
                }
                if (observeOtherNodes)
                    foreach (mirror; map.creatureReplicasNear(at, range))
                        if (mirror.fields[OBJECT_FIELD_ENTRY] == step.buddyEntry
                            && (mirror.fields[UNIT_FIELD_HEALTH] != 0) != deadOk)
                            consider(ScriptThing(mirror.guid, mirror.position, null, null, mirror));
            }
            else
                foreach (o; map.objectsNear(at, range))
                    if (auto go = cast(GameObject) o)
                    {
                        if (go.spawn.entry != step.buddyEntry)
                            continue;
                        consider(thing(go));
                    }
            if (nearest.exists)
                buddies ~= nearest;
        }
        else
            return false; // pools and spawn groups: not yet
        return buddies.length > 0 || step.command == ScriptCommand.terminateScript;
    }

    private bool scriptGameObjectBuddies(const ref DbScriptStep step, Map map, ScriptThing source, ScriptThing target,
        ref ScriptThing[] buddies)
    {
        import dmangos.cluster.regions : cellMin, cellMax;
        import dmangos.world.grid : cellCoordinate, cellKey;
        import dmangos.world.objects : makeGuid, HighGuid;
        import std.algorithm.comparison : max, min;

        void found(const ref imported!"dmangos.world.gameobject".GameObjectSpawn spawn)
        {
            const guid = makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
            // An inactive spawn has no map object. Its position and GUID still select it as a buddy.
            buddies ~= ScriptThing(guid, Position(spawn.x, spawn.y, spawn.z, spawn.orientation), null,
                map.gameObjectAt(guid));
        }

        if (step.dataFlags & ScriptFlag.buddyByGuid)
        {
            indexSpawns();
            if (const index = step.searchRadius in gameObjectSpawnIndex)
                if (data.gameObjectSpawns[*index].map == map.id)
                    found(data.gameObjectSpawns[*index]);
            return buddies.length != 0;
        }
        if (!step.buddyEntry || (step.dataFlags & (ScriptFlag.buddyByPool | ScriptFlag.buddyBySpawnGroup)))
            return false;
        const origin = source.creatureOrGo || !target.exists ? source : target;
        if (!origin.exists)
            return false;
        const cells = map.id in data.gameObjectCells;
        if (cells is null)
            return false;
        const at = origin.position, radius = cast(float) step.searchRadius;
        const all = (step.dataFlags & ScriptFlag.allEligibleBuddies) != 0;
        float nearest = radius * radius;
        size_t best = size_t.max;
        foreach (x; max(cellMin, cellCoordinate(at.x - radius)) .. min(cellMax, cellCoordinate(at.x + radius) + 1))
            foreach (y; max(cellMin, cellCoordinate(at.y - radius)) .. min(cellMax, cellCoordinate(at.y + radius) + 1))
                foreach (index; cells.get(cellKey(x, y), null))
                {
                    const spawn = &data.gameObjectSpawns[index];
                    if (spawn.entry != step.buddyEntry)
                        continue;
                    const distance = distanceSq(at, Position(spawn.x, spawn.y, spawn.z));
                    if (distance > nearest)
                        continue;
                    if (all)
                        found(*spawn);
                    else if (best == size_t.max || distance < nearest
                        || (distance == nearest && spawn.guid < data.gameObjectSpawns[best].guid))
                    {
                        best = index;
                        nearest = distance;
                    }
                }
        if (best != size_t.max)
            found(data.gameObjectSpawns[best]);
        return buddies.length != 0;
    }

    private static float distanceSq(Position a, Position b)
    {
        return (a.x - b.x) ^^ 2 + (a.y - b.y) ^^ 2 + (a.z - b.z) ^^ 2;
    }

    /// Runs the step for each source and target it comes to; true if the script stops here.
    private bool runScriptStep(DbScriptType type, const ref DbScriptStep step, Map map, ulong sourceGuid, ulong targetGuid,
        OutdoorScriptStep* planned = null)
    {
        auto source = scriptObject(map, sourceGuid), target = scriptObject(map, targetGuid);
        stepObjects = [targetGuid, sourceGuid]; // a player not on this map is not in `source` or `target`
        scope (exit)
            stepObjects = null;
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
        bool dispatch(ScriptThing source, ScriptThing target)
        {
            if (planned is null)
                return dispatchScriptCommand(type, step, map, source, target);
            return executeScriptCommand(type, step, map, source, target, false, planned);
        }
        bool stop;
        if (targets.length)
        {
            foreach (s; sources)
                foreach (t; targets)
                    stop |= dispatch(s, t);
        }
        else
            foreach (s; sources)
                stop |= dispatch(s, ScriptThing.init);
        // A step with no source at all may still act on its target (kill credit, quest explored).
        if (sources.length == 0 && targets.length)
            foreach (t; targets)
                stop |= dispatch(ScriptThing.init, t);
        return stop;
    }

    private static ScriptThing scriptActor(const ref DbScriptStep step, ScriptThing source, ScriptThing target)
    {
        return step.command == ScriptCommand.despawnSelf && target.isCreature ? target : source;
    }

    private bool dispatchScriptCommand(DbScriptType type, const ref DbScriptStep step, Map map,
        ScriptThing source, ScriptThing target)
    {
        const actor = scriptActor(step, source, target);
        if (!step.runsAtCreature || !actor.isCreature || actor.mirror is null)
            return executeScriptCommand(type, step, map, source, target);
        if (map.instanceId || sendScriptCreatureStep is null || !canWrite() || actor.mirror.owner == nodeId)
            return false;
        if (step.conditionId)
        {
            auto player = scriptPlayer(source, target);
            if (!scriptConditionMet(map, step.conditionId, player))
                return false;
        }
        const message = ScriptCreatureStep(nextGameplaySequence(), actor.guid, source.guid, target.guid,
            map.id, step.id, step.fingerprint, transportNow(), cast(ubyte) type);
        sendScriptCreatureStep(actor.mirror.owner, message);
        return false;
    }

    /// A known static buddy's relay follows its spawn cell, even if the destination changes workers.
    private ulong forwardedRelayHome(Map map, const ref ScriptThing source)
    {
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.objects : counterOf, highGuidOf, HighGuid;

        const counter = counterOf(source.guid);
        if (highGuidOf(source.guid) != HighGuid.unit || counter >= temporaryCounterStart || regionOwnerAround is null)
            return noCell;
        const spawn = creatureSpawnOf(counter);
        if (spawn is null || spawn.map != map.id || creatureOnLoan(counter)
            || regionOwnerAround(map.id, Position(spawn.x, spawn.y, spawn.z), 0) != source.mirror.owner)
            return noCell;
        return cellKeyAt(spawn.x, spawn.y);
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
                if (!found && !map.instanceId)
                {
                    import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, UNIT_FIELD_HEALTH;

                    foreach (mirror; map.creatureReplicasNear(at, step.datalong2))
                        if (mirror.guid != searcher.guid && mirror.fields[OBJECT_FIELD_ENTRY] == step.datalong
                            && mirror.fields[UNIT_FIELD_HEALTH])
                            found = true;
                }
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
                if (auto session = onlinePlayer(o.guid))
                    return session;
        return null;
    }

    private ulong[] stepObjects; // the guids the running step began with (`runScriptStep`)

    /**
     * The player a step began with that this node does not simulate (its guid 0 if none), and where its copy
     * here is, if one is (`mirror`). After a crash the player's region and the script's can go to two different
     * survivors: the script runs on here, its player there.
     */
    private ScriptThing remoteScriptPlayer(ScriptThing source, ScriptThing target)
    {
        import dmangos.world.objects : highGuidOf, HighGuid;

        foreach (guid; stepObjects)
        {
            if (!guid || highGuidOf(guid) != HighGuid.player || onlinePlayer(guid) !is null)
                continue;
            foreach (o; [target, source])
                if (o.guid == guid && o.mirror !is null)
                    return o;
            return ScriptThing(guid);
        }
        return ScriptThing.init;
    }

    /**
     * A quest-credit step whose player another node simulates: the credit goes to that node
     * (`ScriptQuestCredit`), after the step's claim when it has one.
     */
    private void creditRemoteScriptPlayer(Map map, ulong player, ScriptQuestCredit.Kind kind, uint id,
        ulong rewarder, OutdoorScriptStep* planned)
    {
        if (scriptQuestCreditElsewhere is null)
            return;
        const credit = ScriptQuestCredit(player, kind, id, rewarder, config.cluster.nodeId, nextGameplaySequence());
        if (planned !is null)
            planned.credits ~= credit;
        else if (!database.enqueueScriptQuestCredit(config.realmId, credit))
            return;
        // The owner's poll also finds the row if the player moves or either worker loses its link.
        const node = remoteKillRecipient(player, map).node;
        if (!node || node == config.cluster.nodeId)
            return;
        auto notifyOwner = () { scriptQuestCreditElsewhere(node, credit); };
        if (planned !is null)
            planned.afterCommit ~= notifyOwner;
        else
            notifyOwner();
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
        move.relay = step.datalong;
        move.relayTarget = target.guid;
        creature.generator = move;
        move.initialize(creature, map);
        map.wake(creature.guid);
    }

    private long[GameObjectOnMap] scriptedGameObjects; // spawned by a script: when it goes (Unix time)

    private void saveDungeonObjectDeadlines(uint mapId, ref ByteWriter w, uint onlyInstance = 0)
    {
        const countAt = w.length;
        w.put(0u);
        uint count;
        foreach (key, deadline; scriptedGameObjects)
            if (key.map.id == mapId && key.map.instanceId && (!onlyInstance || key.map.instanceId == onlyInstance)
                && instanceMap(key.map.instanceId) is key.map)
            {
                ++count;
                w.put(key.map.instanceId);
                w.put(key.guid);
                w.put(deadline);
            }
        w.patch(countAt, count);
    }

    private void restoreDungeonObjectDeadlines(uint mapId, ref ByteReader r)
    {
        const now = unixTime;
        foreach (_; 0 .. r.read!uint)
        {
            const instance = r.read!uint;
            const guid = r.read!ulong;
            const deadline = r.read!long;
            auto copy = instanceMap(instance);
            if (copy is null || copy.id != mapId || cast(GameObject) copy.findObject(guid) is null)
                continue;
            if (deadline <= now)
                copy.removeObject(guid);
            else
                scriptedGameObjects[GameObjectOnMap(copy, guid)] = deadline;
        }
    }

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
        const template_ = spawn.entry in data.gameObjectTemplates;
        if (template_ is null || template_.type == GameObjectType.door || template_.type == GameObjectType.fishingNode)
            return;
        if (template_.type == GameObjectType.chest)
            if (const state = map.instanceId in instances)
                if (spawn.guid in state.usedUp || spawn.guid in state.chests)
                    return;
        auto made = makeGameObject(*spawn);
        made.instanceId = map.instanceId;
        // A static spawn just comes back; one that is not there by default goes again after a while.
        if (spawn.respawnSeconds < 0)
        {
            const deadline = unixTime + despawnSeconds;
            scriptedGameObjects[GameObjectOnMap(map, made.guid)] = deadline;
            rememberUnopenedReward(made, deadline);
        }
        if (!map.instanceId && gameObjectRespawnAt.remove(spawn.guid))
            database.saveGameObjectRespawn(spawn.guid, 0);
        map.addObject(made);
        // Instance round 2: the dungeon's script hears of it as of any object of the copy (a ritual's bell, a trap).
        if (map.instanceId)
            if (auto script = map.instanceId in instanceScripts)
            {
                import dmangos.script.api : EntityRef, ObjectLoaded;

                script.raise(ObjectLoaded(EntityRef(made.guid)));
            }
    }

    private ulong scriptGameObjectGuid(uint spawnGuid, uint mapId)
    {
        import dmangos.world.objects : makeGuid, HighGuid;

        indexSpawns();
        if (const index = spawnGuid in gameObjectSpawnIndex)
        {
            const spawn = &data.gameObjectSpawns[*index];
            if (spawn.map == mapId)
                return makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
        }
        return 0;
    }

    private void scriptOpenable(Map map, ulong guid, uint delay, bool open, OutdoorScriptStep* planned)
    {
        import dmangos.serialization : serialize;
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : toHex;
        import dmangos.world.objects : counterOf;
        import std.algorithm.comparison : among, max;

        const action = open ? ScriptGameObject.Action.open : ScriptGameObject.Action.close;
        const counter = counterOf(guid);
        if (config.cluster.enabled && !map.instanceId && ownsCell !is null && canWrite() && guid
            && scriptGameObjectGuid(counter, map.id) == guid)
        {
            const spawn = &data.gameObjectSpawns[gameObjectSpawnIndex[counter]];
            if (const proto = spawn.entry in data.gameObjectTemplates)
                if (proto.type.among(GameObjectType.door, GameObjectType.button))
                {
                    ByteWriter bytes;
                    serialize(bytes, OutdoorOpenableAction(guid, max(delay, 15u), open));
                    auto request = OutdoorSummonRequest(map: map.id, home: cellKeyAt(spawn.x, spawn.y),
                        state: toHex(bytes.data), kind: OutdoorSummonKind.openable);
                    if (planned !is null)
                        planned.forwards ~= request;
                    else
                        enqueueOutdoorPlacement(request, spawn.entry);
                    return;
                }
        }
        if (planned is null)
            scriptGameObjectAction(map, guid, delay, action);
        else
            planned.afterCommit ~= () => scriptGameObjectAction(map, guid, delay, action);
    }

    private void scriptObjectPlacement(Map map, ulong guid, uint delay, ScriptGameObject.Action action,
        OutdoorScriptStep* planned)
    {
        import dmangos.serialization : serialize;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : toHex;
        import dmangos.world.objects : counterOf;

        const counter = counterOf(guid);
        const respawn = action == ScriptGameObject.Action.respawn;
        if (config.cluster.enabled && !map.instanceId && ownsCell !is null && canWrite() && guid && (delay > 0) == respawn
            && scriptGameObjectGuid(counter, map.id) == guid)
        {
            const spawn = &data.gameObjectSpawns[gameObjectSpawnIndex[counter]];
            if (const proto = spawn.entry in data.gameObjectTemplates)
            {
                const staticDespawn = !respawn && durableStaticDespawn(*spawn, *proto);
                if (staticDespawn || durableScriptedSpawn(*spawn, *proto))
                {
                    ByteWriter bytes;
                    serialize(bytes, OutdoorScriptedObject(guid, delay));
                    auto request = OutdoorSummonRequest(map: map.id, home: cellKeyAt(spawn.x, spawn.y),
                        state: toHex(bytes.data), kind: respawn ? OutdoorSummonKind.scriptedObject
                            : staticDespawn ? OutdoorSummonKind.staticDespawn : OutdoorSummonKind.scriptedDespawn);
                    if (planned !is null)
                        planned.forwards ~= request;
                    else
                        enqueueOutdoorPlacement(request, spawn.entry);
                    return;
                }
            }
        }
        if (planned is null)
            scriptGameObjectAction(map, guid, delay, action);
        else
            planned.afterCommit ~= () => scriptGameObjectAction(map, guid, delay, action);
    }

    private void scriptGameObjectAction(Map map, ulong guid, uint delay, ScriptGameObject.Action action,
        ushort from = 0, bool forwarded = false)
    {
        import dmangos.world.objects : counterOf, highGuidOf, HighGuid;
        import dmangos.world.replication : Replica;

        if (highGuidOf(guid) != HighGuid.gameObject || !canWrite())
            return;
        const spawnGuid = counterOf(guid);
        auto go = map.gameObjectAt(guid);
        if (!map.instanceId && regionOwnerAround !is null)
        {
            ushort owner;
            if (scriptGameObjectGuid(spawnGuid, map.id) == guid)
            {
                const spawn = &data.gameObjectSpawns[gameObjectSpawnIndex[spawnGuid]];
                owner = regionOwnerAround(map.id, Position(spawn.x, spawn.y, spawn.z), 0);
            }
            else if (go !is null)
                owner = regionOwnerAround(map.id, go.position, 0);
            else if (auto copy = cast(Replica) map.findObject(guid))
                owner = copy.owner;
            if (owner != nodeId)
            {
                if (owner && owner != from && !forwarded && sendScriptGameObject !is null)
                {
                    const command = ScriptGameObject(nextGameplaySequence(), guid, map.id, delay, action, from != 0);
                    sendScriptGameObject(owner, command);
                }
                return;
            }
        }
        final switch (action)
        {
        case ScriptGameObject.Action.respawn:
            scriptSpawnGameObject(map, spawnGuid, go, delay);
            break;
        case ScriptGameObject.Action.despawn:
            if (go !is null)
            {
                go.forceDespawn(map, delay);
                if (delay)
                    map.wake(guid);
            }
            break;
        case ScriptGameObject.Action.open, ScriptGameObject.Action.close:
            import dmangos.world.gameobject : GameObjectType;

            if (go !is null && (go.type == GameObjectType.door || go.type == GameObjectType.button))
            {
                const reset = delay < 15 ? 15 : delay;
                go.useOpenable(map, action == ScriptGameObject.Action.open, reset * 1000);
                map.wake(guid);
            }
            break;
        case ScriptGameObject.Action.summon:
            break; // handled by placeWildGameObject
        }
    }

    /// A spell's destination may be on a different worker even when its caster is simulated here.
    package void placeWildGameObject(Map map, uint entry, Position at, uint duration, ushort from = 0,
        bool forwarded = false)
    {
        const proto = entry in data.gameObjectTemplates;
        if (proto is null || !canWrite()
            || !client.isValidMapCoord(map.id, at.x, at.y, at.z, at.orientation))
            return;
        if (usesOutdoorObjectQueue(map, entry, duration))
        {
            queueOutdoorObject(map, entry, at, duration);
            return;
        }
        if (!map.instanceId && regionOwnerAround !is null)
        {
            const owner = regionOwnerAround(map.id, at, 0);
            if (owner != nodeId)
            {
                if (owner && owner != from && !forwarded && sendScriptGameObject !is null)
                {
                    const command = ScriptGameObject(nextGameplaySequence(), 0, map.id, duration,
                        ScriptGameObject.Action.summon, from != 0, entry, at.x, at.y, at.z, at.orientation);
                    sendScriptGameObject(owner, command);
                }
                return;
            }
        }
        if (auto object = summonWildGameObject(map, entry, at, duration))
            checkpointOutdoorScriptObject(map, object, true);
    }

    package bool usesOutdoorObjectQueue(Map map, uint entry, uint duration)
    {
        const proto = entry in data.gameObjectTemplates;
        return duration && ownsCell !is null && proto !is null && durableOutdoorObject(map, proto.type);
    }

    package bool queueOutdoorObject(Map map, uint entry, Position at, uint duration)
    {
        import dmangos.serialization : serialize;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : toHex;

        if (!canWrite() || !client.isValidMapCoord(map.id, at.x, at.y, at.z, at.orientation))
            return false;
        ByteWriter state;
        serialize(state, OutdoorObjectPayload(entry, unixTime + duration, at));
        auto request = OutdoorSummonRequest(map: map.id,
            home: cellKeyAt(at.x, at.y), state: toHex(state.data), kind: OutdoorSummonKind.gameObject);
        return enqueueOutdoorPlacement(request, entry);
    }

    private bool enqueueOutdoorPlacement(ref OutdoorSummonRequest request, uint entry)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        request.origin = nodeId;
        request.sequence = nextGameplaySequence();
        bool stored;
        try
        {
            stored = database.enqueueOutdoorSummon(config.realmId, request);
            if (stored && canWrite() && ownsCell(request.map, request.home))
                deliverOutdoorSummon(request);
        }
        catch (DatabaseException error)
            warning!"map %s: could not save outdoor object work for %s: %s"(request.map, entry, error.msg);
        return stored;
    }

    private void placeScriptCreature(Map map, const ref DbScriptStep step, Position at, ulong source, ulong target,
        DbScriptType type, ushort from = 0, bool forwarded = false, OutdoorScriptStep* planned = null)
    {
        import dmangos.serialization : serialize;
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.instancescripting : toHex;

        if (!canWrite() || step.datalong !in data.creatureTemplates
            || !client.isValidMapCoord(map.id, at.x, at.y, at.z, at.orientation))
            return;
        const relay = step.dataint[3] > 0 ? data.dbScripts.summonRelays.get(cast(uint) step.dataint[3], 0) : 0;
        const payload = ScriptSummonPayload(step.datalong, step.datalong2, relay, at, source, target);
        if (!map.instanceId && regionOwnerAround !is null)
        {
            const owner = regionOwnerAround(map.id, at, 0);
            if (owner != nodeId)
            {
                if (planned !is null)
                {
                    ByteWriter state;
                    serialize(state, payload);
                    planned.forwards ~= OutdoorSummonRequest(map: map.id, home: cellKeyAt(at.x, at.y),
                        state: toHex(state.data));
                }
                else if (owner && owner != from && !forwarded && sendScriptCreatureStep !is null)
                {
                    const message = ScriptCreatureStep(nextGameplaySequence(), source, source, target, map.id, step.id,
                        step.fingerprint, transportNow(), cast(ubyte) type, from != 0, at.x, at.y, at.z, at.orientation);
                    sendScriptCreatureStep(owner, message);
                }
                return;
            }
        }
        auto spawn = prepareScriptCreature(map, payload);
        if (spawn.creature is null)
            return;
        if (planned is null)
            publishScriptCreature(map, spawn);
        else
            stageScriptCreature(map, spawn, *planned);
    }

    private ScriptCreatureSpawn prepareScriptCreature(Map map, const ref ScriptSummonPayload payload)
    {
        import dmangos.world.creature : TempSpawnType;

        const lifetime = payload.duration ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead;
        auto creature = prepareCreatureSummon(map, payload.entry, payload.at, lifetime, payload.duration, payload.source);
        return ScriptCreatureSpawn(creature, payload.relay, payload.target);
    }

    private void stageScriptCreature(Map map, ScriptCreatureSpawn spawn, ref OutdoorScriptStep planned)
    {
        scope (failure) spawn.creature.ai.releaseBehaviour();
        spawn.checkpoint = outdoorCreatureCheckpoint(spawn.creature);
        if (spawn.checkpoint.actor && spawn.relay)
            if (auto steps = data.dbScripts.steps(DbScriptType.relay, spawn.relay))
            {
                auto run = new ScriptRun(DbScriptType.relay, spawn.relay, map.id, 0, spawn.creature.guid, spawn.target, steps);
                run.home = spawn.checkpoint.home;
                run.anchor = spawn.creature.guid;
                trackOutdoorScript(run, true);
                run.outdoorSaved = true;
                spawn.relayRun = run;
                planned.relayCheckpoints ~= outdoorScriptState(run, map);
            }
        planned.summons ~= spawn;
    }

    private void publishScriptCreature(Map map, ScriptCreatureSpawn summon)
    {
        if (summon.checkpoint.actor)
            outdoorQuestActors[summon.creature.guid] = summon.checkpoint;
        publishCreatureSummon(map, summon.creature);
        if (!summon.checkpoint.actor)
            checkpointOutdoorCreature(summon.creature, true);
        if (summon.relayRun !is null)
            scriptRuns ~= summon.relayRun;
        else if (summon.relay)
            startScript(DbScriptType.relay, summon.relay, map, summon.creature.guid, summon.target);
    }

    /// The game objects a script spawned whose time is up, gone again.
    package void scriptedGameObjectsDue()
    {
        const now = unixTime;
        GameObjectOnMap[] due;
        foreach (key, at; scriptedGameObjects)
            if (at <= now)
                due ~= key;
        foreach (key; due)
        {
            scriptedGameObjects.remove(key);
            if (key.map.findObject(key.guid) !is null)
                key.map.removeObject(key.guid);
        }
    }

    private bool scriptConditionMet(Map map, uint id, Character player)
    {
        return player is null ? mapConditionMet(map, id) : player.conditionMet(id);
    }

    /// Carries out a step's command; true if the script should stop.
    private bool executeScriptCommand(DbScriptType type, const ref DbScriptStep step, Map map, ScriptThing source,
        ScriptThing target, bool conditionChecked = false, OutdoorScriptStep* planned = null)
    {
        import dmangos.world.updatefields;

        auto player = scriptPlayer(source, target);
        if (!conditionChecked && step.conditionId && !scriptConditionMet(map, step.conditionId, player))
            return false;
        auto creature = source.creature;
        if (planned is null && creature !is null && creature.ai !is null)
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
            const place = source.creatureOrGo ? source : (target.creatureOrGo ? target : ScriptThing.init);
            if (step.datalong2 && !place.exists)
                break;
            if (player is null)
            {
                // Another node may simulate the player: from its copy here, the distance can be checked.
                const elsewhere = remoteScriptPlayer(source, target);
                if (!elsewhere.guid || (step.datalong2 && elsewhere.mirror is null))
                    break;
                bool far = place.creature !is null && !place.creature.alive;
                if (!far && step.datalong2)
                    far = distanceSq(place.position, elsewhere.position) > float(step.datalong2) ^^ 2;
                creditRemoteScriptPlayer(map, elsewhere.guid,
                    far ? ScriptQuestCredit.Kind.failed : ScriptQuestCredit.Kind.explored, step.datalong, 0, planned);
                break;
            }
            bool fail = place.creature !is null && !place.creature.alive;
            if (!fail && step.datalong2)
                fail = distanceSq(place.position, player.character.position) > float(step.datalong2) ^^ 2;
            alias Kind = ScriptQuestEffect.Kind;
            auto effect = ScriptQuestEffect(player, fail ? Kind.failed : Kind.explored, step.datalong);
            if (planned !is null)
                planned.add(effect);
            else
                effect.apply();
            break;
        }
        case ScriptCommand.killCredit:
        {
            auto rewarder = source.creature !is null ? source.creature : target.creature;
            const entry = step.datalong ? step.datalong : (rewarder !is null ? rewarder.template_.entry : 0);
            if (entry == 0)
                break;
            if (player is null)
            {
                const elsewhere = remoteScriptPlayer(source, target);
                if (elsewhere.guid)
                    creditRemoteScriptPlayer(map, elsewhere.guid, ScriptQuestCredit.Kind.kill, entry,
                        rewarder !is null ? rewarder.guid : 0, planned);
                break;
            }
            auto effect = ScriptQuestEffect(player, ScriptQuestEffect.Kind.kill, entry, rewarder !is null ? rewarder.guid : 0);
            if (planned !is null)
                planned.add(effect);
            else
                effect.apply();
            break;
        }
        case ScriptCommand.respawnGameObject:
            scriptObjectPlacement(map, step.datalong ? scriptGameObjectGuid(step.datalong, map.id) : source.guid,
                step.datalong2, ScriptGameObject.Action.respawn, planned);
            break;
        case ScriptCommand.despawnGameObject:
            scriptObjectPlacement(map, target.guid, step.datalong, ScriptGameObject.Action.despawn, planned);
            break;
        case ScriptCommand.tempSpawnCreature:
        {
            auto at = Position(step.x, step.y, step.z, step.o);
            if (source.exists && resolveCreatureSummonPosition(map, source.guid, at))
                placeScriptCreature(map, step, at, source.guid, target.guid, type, 0, false, planned);
            break;
        }
        case ScriptCommand.openDoor, ScriptCommand.closeDoor:
        {
            import dmangos.world.objects : highGuidOf, HighGuid;

            const guid = step.datalong ? scriptGameObjectGuid(step.datalong, map.id)
                : highGuidOf(source.guid) == HighGuid.gameObject ? source.guid : target.guid;
            scriptOpenable(map, guid, step.datalong2, step.command == ScriptCommand.openDoor, planned);
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
        {
            if (planned !is null && source.mirror !is null)
            {
                const row = step;
                planned.afterCommit ~= () { dispatchScriptCommand(type, row, map, source, target); };
                break;
            }
            if (creature is null)
                break;
            const faction = step.datalong ? step.datalong : creature.template_.faction;
            void apply()
            {
                creature.factionTemplate = client.factionTemplates.lookup(faction);
                creature.values.set!UNIT_FIELD_FACTIONTEMPLATE(faction);
                map.flushCreature(creature);
            }
            if (planned is null)
                apply();
            else
            {
                QuestActorCheckpoint saved;
                const current = creature.guid in outdoorQuestActors;
                if (creature.ai !is null && (current is null || !current.player)
                    && faction != creature.values.get!UNIT_FIELD_FACTIONTEMPLATE)
                    saved = outdoorCreatureCheckpoint(creature, &faction);
                if (saved.actor)
                    planned.changedActors ~= saved;
                planned.afterCommit ~= () {
                    if (saved.actor)
                    {
                        if (!ownsQuestActor(creature))
                            return;
                        outdoorQuestActors[saved.actor] = saved;
                    }
                    apply();
                };
            }
            break;
        }
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
                const fromTable = (step.datalong3 & 2) != 0;
                const path = data.waypoints.pathFor(s.entry, s.guid, step.datalong2, fromTable);
                if (path.length == 0)
                    return false;
                creature.generator = new WaypointMovement(path, step.datalong == MotionType.linearWaypoint,
                    step.datalong2, fromTable);
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
            if (creature.spline.finalized
                && launch(creature, map, [Vector3(from.x, from.y, from.z), Vector3(from.x, from.y, from.z)], true, facing))
                map.wake(creature.guid);
            break;
        }
        case ScriptCommand.setWorldState:
        {
            if (step.dataint[0] <= 0)
                break;
            const state = OutdoorWorldState(map.id, cast(uint) step.dataint[0], step.dataint[1]);
            if (planned !is null)
                planned.worldStates ~= state;
            else if (map.instanceId || !config.cluster.enabled)
                map.scriptedWorldStates[state.id] = state.value;
            else if (canWrite())
            {
                database.saveOutdoorWorldState(config.realmId, state);
                outdoorWorldStates[map.id][state.id] = state.value;
            }
            break;
        }
        case ScriptCommand.startRelayScript:
        {
            ulong remoteHome = noCell;
            if (planned !is null && source.mirror !is null)
            {
                remoteHome = forwardedRelayHome(map, source);
                if (remoteHome == noCell)
                {
                    const row = step;
                    planned.afterCommit ~= () { dispatchScriptCommand(type, row, map, source, target); };
                    break;
                }
            }
            const relay = step.datalong2 ? data.dbScripts.randomRelay(step.datalong2) : step.datalong;
            if (!relay)
                break;
            if (planned is null)
                startScript(DbScriptType.relay, relay, map, source.guid, target.guid);
            else if (const steps = data.dbScripts.steps(DbScriptType.relay, relay))
            {
                auto run = prepareScriptRun(DbScriptType.relay, relay, map, source.guid, target.guid, steps);
                if (remoteHome != noCell)
                {
                    run.home = remoteHome;
                    run.anchor = source.guid;
                    planned.forwards ~= OutdoorSummonRequest(map: map.id, home: remoteHome,
                        kind: OutdoorSummonKind.relay);
                }
                else if (run.home == noCell)
                    run.home = planned.parentHome;
                trackOutdoorScript(run, true);
                run.outdoorSaved = true;
                planned.relayCheckpoints ~= outdoorScriptState(run, map, remoteHome == noCell);
                if (remoteHome == noCell)
                    planned.relays ~= run;
            }
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

/// An outdoor relay resumes its next step after the source's region moves.
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.cluster.regions : CellRect, Region, RegionState;
    import dmangos.world.creature : TempSpawnType;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.motion : PointMovement;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : creatureInnkeeper;
    import dmangos.world.updatefields : UNIT_NPC_FLAGS;

    auto db = newDatabase();
    auto source = newCreationContext(db), destination = newCreationContext(db);
    source.nodeId = 1;
    destination.nodeId = 2;
    auto now = MonoTime.currTime;
    source.clock = destination.clock = () => now;
    enum uint relay = 9901, walk = 9902, arrive = 9903;
    enum uint first = 0x10000000, second = 0x20000000, reached = 0x40000000;
    const at = Position(-8930, -120, 83.53f);
    foreach (owner; [source, destination])
    {
        owner.data.dbScripts.add(DbScriptType.relay, DbScriptStep(relay, 0, 0, ScriptCommand.modifyNpcFlags, first, 1));
        owner.data.dbScripts.add(DbScriptType.relay, DbScriptStep(relay, 1000, 0, ScriptCommand.modifyNpcFlags, second, 1));
        DbScriptStep move = {id: walk, command: ScriptCommand.moveTo, datalong: arrive, x: at.x + 4, y: at.y, z: at.z};
        owner.data.dbScripts.add(DbScriptType.relay, move);
        owner.data.dbScripts.add(DbScriptType.relay, DbScriptStep(arrive, 0, 0, ScriptCommand.modifyNpcFlags, reached, 2));
    }
    auto from = source.map(0), to = destination.map(0);
    auto speaker = source.summonCreature(from, creatureInnkeeper, at, TempSpawnType.manual, 0, 0);
    auto other = source.summonCreature(from, creatureInnkeeper, Position(at.x + 500, at.y, at.z),
        TempSpawnType.manual, 0, 0);
    assert(source.startScript(DbScriptType.relay, relay, from, speaker.guid, 0));
    assert(source.startScript(DbScriptType.relay, relay, from, other.guid, 0));
    assert(source.startScript(DbScriptType.relay, walk, from, speaker.guid, 0));
    source.updateScripts(400);
    speaker.tick(from, 400);
    assert(cast(PointMovement) speaker.generator !is null && !speaker.spline.finalized);
    now += 400.msecs;
    assert(speaker.values.get!UNIT_NPC_FLAGS & first);
    speaker.values.set!UNIT_NPC_FLAGS(speaker.values.get!UNIT_NPC_FLAGS & ~first);

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(7, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    source.regionsChanged(null, [region], null, leaving);
    now += 200.msecs;
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    destination.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto resumed = to.creatureAt(speaker.guid);
    assert(resumed !is null && from.creatureAt(speaker.guid) is null);
    assert(cast(PointMovement) resumed.generator !is null && resumed.spline.timePassed == speaker.spline.timePassed);
    assert(destination.runningScripts == 1 && source.runningScripts == 1,
        "only the run anchored in the departing region moves");

    destination.updateScripts(350);
    assert(!(resumed.values.get!UNIT_NPC_FLAGS & (first | second)));
    destination.updateScripts(100);
    assert((resumed.values.get!UNIT_NPC_FLAGS & (first | second)) == second);
    assert(destination.runningScripts == 0);
    foreach (_; 0 .. 20)
    {
        resumed.tick(to, 250);
        destination.updateScripts(250);
    }
    assert(cast(PointMovement) resumed.generator is null && (resumed.position.x - (at.x + 4)) ^^ 2 < 0.01f);
    assert(resumed.values.get!UNIT_NPC_FLAGS & reached, "the arrival relay runs once at the destination");
    source.updateScripts(600);
    assert((other.values.get!UNIT_NPC_FLAGS & (first | second)) == (first | second));
    assert(source.runningScripts == 0);
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
        context.data.spells.spells.edit(ritual).casting.dmgClass = DamageClass.none;
        context.data.dbScripts.add(DbScriptType.spell, DbScriptStep(ritual, 0, 0, ScriptCommand.questExplored, rite));
        anduin.session.inWorld.castTriggeredAt(ritual, me.guid);
        context.updateScripts(0);
        assert(me.questStatus[rite].status == QuestState.complete, "the spell's script");

        context.data.spells.spells[call] = testSpell(call, 41, 1, 0);
        context.data.spells.spells.edit(call).miscValue[0] = creatureTrainer;
        context.data.spells.spells.edit(call).casting.dmgClass = DamageClass.none;
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
    // Held in place, a unit field set, threat wiped from everyone.
    EventAiEvent held = {id: 5, type: EventType.receiveEmote, chance: 100, params: [wave + 4, 0, 0, 0, 0, 0]};
    held.actions[0] = EventAiAction(ActionType.setImmobilized, [1, 0, 0]);
    held.actions[1] = EventAiAction(ActionType.setUnitField, [UNIT_NPC_EMOTESTATE.offset, 69, EventTarget.self]);
    held.actions[2] = EventAiAction(ActionType.threatAllPct, [-100, 0, 0]);
    auto holding = [held];
    keeper.ai.setScript(holding, context.data.eventAi);
    keeper.ai.receivedEmote(me.guid, wave + 4, map);
    assert(keeper.immobilized && keeper.values.get!UNIT_NPC_EMOTESTATE == 69, "held, and its emote state set");

    // It becomes another creature: the banker's entry, keeping its guid.
    const keeperGuid = keeper.guid;
    EventAiEvent becomes = {id: 6, type: EventType.receiveEmote, chance: 100, params: [wave + 5, 0, 0, 0, 0, 0]};
    becomes.actions[0] = EventAiAction(ActionType.updateTemplate, [creatureBanker, 0, 0]);
    auto becoming = [becomes];
    keeper.ai.setScript(becoming, context.data.eventAi);
    keeper.ai.receivedEmote(me.guid, wave + 5, map);
    assert(keeper.template_.entry == creatureBanker && keeper.values.get!OBJECT_FIELD_ENTRY == creatureBanker
        && keeper.guid == keeperGuid && keeper.alive, "a banker now");

    EventAiEvent ended = {id: 4, type: EventType.receiveEmote, chance: 100, params: [wave + 3, 0, 0, 0, 0, 0]};
    ended.actions[0] = EventAiAction(ActionType.die, [0, 0, 0]);
    auto ending = [ended];
    keeper.ai.setScript(ending, context.data.eventAi);
    keeper.ai.receivedEmote(me.guid, wave + 3, map);
    assert(!keeper.alive, "it died");
}
