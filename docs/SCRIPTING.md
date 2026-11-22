# Scripting

How gameplay that the database cannot describe (boss fights, dungeon doors and encounters, escort
quests, special spells, scripted objects and triggers) is written for dmangos, in D, with the
framework in `dmangos.script` and the scripts in `dmangos.scripts`.

Status: the framework with creature, dungeon (instance), game object, spell, area trigger, scripted
event, item and world map scripts, their persistence, gossip (menus of the database's or the script's
own) and quest events, script movement, escorts, and signals between scripts on different nodes is
implemented and tested. Command scripts are planned.

## Principles

1. **Scripts are bound to data by name.** The world database's `ScriptName` columns (398 creatures
   use 294 names, and game objects, area triggers, events and dungeons have them too) say which
   script serves which row. The schema stays as it is.
2. **Events are typed.** A handler takes one event struct; a misspelt event fails to compile, and a
   server need not raise an event no script handles.
3. **Scripts hold no pointers.** An object a script refers to may leave the map, or be simulated on
   another machine; a script holds an identity and asks for it to be resolved at the moment of use.
4. **All script state is plain data.** Timers, phases and components are fields of a struct, so a
   script's state can be saved, sent to another node with its creature, and (later) carried across a
   reload. No coroutines, fibers or closures hold state.
5. **One language.** D's templates and attributes give the concise declarations and generated glue a
   scripting language is usually used for, with static checking, no marshalling, and no second
   runtime or collector.

## The design

### The parts

| Layer | Package | What it is |
|---|---|---|
| Core | `dmangos.world`, `dmangos.cluster` | Simulation, rules, persistence, the cluster |
| Framework | `dmangos.script` | Registration, dispatch, schedules, state persistence, the script API and the *host* interfaces the core implements |
| Scripts | `dmangos.scripts` | Gameplay: one module per area or dungeon |
| Data | world database | `ScriptName` columns, `script_texts`; saved script state in `instance.data` |

The framework does not import the core: it declares what it needs as interfaces (`CreatureHost`,
`InstanceHost`), which the core implements. Scripts import only `dmangos.script`. A script therefore
cannot reach a `Creature`, a `Map` or a session: what it can do is exactly what the API offers, and
every operation goes through the same checks a player's action would.

### A script is a struct

```d
@creature("boss_mr_smite")
struct MrSmite
{
    enum Step : ubyte { slam, stomp, rearm }
    Schedule!Step steps;            // when to do what: plain data
    ubyte phase;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        me.say(sayAggro);
        steps.every(Step.slam, 9.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (phase == 0 && e.crossed(66)) ...
    }

    void on(ref CreatureContext me, Step step) { ... }   // a step of `steps` is due
}
```

* **Registration** is a UDA (`@creature`, `@instance`, ...) with the `ScriptName` of the rows it
  serves. `dmangos.scripts` lists its modules once; `ScriptRegistry` walks them with
  `static foreach` and `__traits(getAttributes)` at compile time and builds a table sorted by name.
  Two scripts with one name fail the build (a CTFE check). At start-up the world reports names in
  the database that no script serves and scripts no row uses.
* **Handlers are overloads of `on`** taking the context and one event struct. Which events a script
  handles is found at compile time; for each script type a table of function pointers is generated
  with `null` for events it ignores. Dispatch is: look up the handle's table, test one pointer,
  call. Each kind of script has its own context and event list, so a creature event cannot be sent
  to a dungeon script by mistake, and an `on` with a misspelt event type fails to compile.
* **Events are small value structs** built on the stack (`EnteredCombat { EntityRef enemy; }`,
  `Damaged { EntityRef attacker; uint amount; ubyte before, after; }`), passed by `ref const`.
  Raising one allocates nothing.

### State: owned by the framework, plain data, serializable

* A script's struct lives in a pool of its type (`ScriptPool!S`): fixed chunks of structs that are
  never moved, so a handler may spawn more scripted creatures while it runs. The entity holds an
  8-byte `ScriptHandle` (script id, slot, generation); a stale handle (the creature is gone, the
  slot reused) is detected by its generation.
* **Time is data.** A `Schedule!E` is a small fixed array of (step, due, repeat) in milliseconds of
  simulation time, advanced by the creature's own tick. A repeating step keeps its rhythm; beats
  missed in a long pause are not made up (the step runs once). Timelines are therefore not coroutines or
  fibers (whose stacks cannot be written to a database or sent to another node) and not closures
  (which capture pointers). A boss fight is a set of steps and a phase variable: plain data.
* **Persistence by reflection.** `saveScript`/`loadScript` serialize every field of the struct
  except those marked `@transient`, recursively, with a layout fingerprint computed at compile time
  from the field names and types: state saved by an older layout is detected and the script starts
  fresh rather than reading garbage. The same bytes are used to move a creature to another node, to
  save a dungeon script into `instance.data`, and (later) to carry state across a reload.

### Entities are handles

Scripts never hold an object. They hold an `EntityRef` (the guid, stable across nodes and
migrations) and ask the context to act on it: `me.castSpell(spell, target)`, `me.healthPercentOf(who)`.
The context resolves the guid at the moment of the call, on this node, and refuses (with a result
code) what is not here or not allowed. Nothing a script keeps can dangle.

### Authority and the cluster

* **Scripts run where the simulation is.** Events are raised by the creature's AI, which only the
  owning node runs; replicas never run scripts, so replication never fires an event twice.
* **Migration carries the script.** A creature moving to another node with its region carries its
  script's state in its migration state; the new owner rebuilds the struct from it. Dungeon
  scripts move with their dungeon (`dungeonGained` reads `instance.data`).
* **Cross-node actions are messages** to the owner, through the cluster's existing links (the
  script signal, below), carrying the sender's identity and a sequence number so a resent message
  is applied once. A script cannot change an entity another node simulates directly: the context
  does not resolve replicas for writing.

### Kinds of scripts

| Kind | UDA | Bound by | Events (implemented / planned) |
|---|---|---|---|
| Creature | `@creature` | `creature_template.ScriptName` | spawned, reset, entered combat, damaged, killed a unit, died, evaded, spell hit, signal, steps, movement done, gossip hello and select, quest accepted and rewarded, a creature it summoned died (or went) or arrived where it sent it, a player in sight, a text emote at it, an aura of its gone (`AuraRemoved`: run out, dispelled, cancelled or taken away); *summoned* |
| Dungeon | `@instance` | `instance_template.ScriptName` | creature or object loaded (summons too), creature died, signal, a creature engaged or evaded (an encounter's start and wipe), scripted event (`scripted_event_id`: a spell's or a goober's event), a player entered, an object used, a question asked (`Asked`, answered with `answer`), its state read back after a restart (`Restored`), steps of its own schedules |
| Game object | `@gameObject` | `gameobject_template.ScriptName` | used, signal, spawned (put in the world), a quest accepted from it, its trap set off (`TrapSprung`, refusable), steps of its own schedules; *state changed* |
| Area trigger | `@areaTrigger` | `scripted_areatrigger` | entered |
| Scripted event | `@scriptedEvent` | `scripted_event_id` | started (`EventStarted`: a player's or a creature's `SEND_EVENT` spell, a goober's event), around the player who started it or is its target; then the dungeon's `EventHappened`, then `dbscripts_on_event` |
| Item | `@item` | `item_template.ScriptName` | used (`ItemUsed`; `consume` makes the use fail) |
| Spell | `@spell` | `spell_scripts`; `@spellIds` beside it: spells by id that no row names (CMaNGOS's core cases) | a dummy or script effect hit (a player's or a creature's cast), an aura applied (on a player, whoever cast it; on a creature), its periodic tick on a creature (the amount changeable), a player's cast checked (`CastChecked`, refusable) and started (`CastStarted`), a heartbeat of an aura on a player (`AuraHeartbeat`, every five seconds), an aura's end (`AuraEnded`, whether it ran out), a periodic tick on a player done (`AuraTickEnded`), a creature's spell about to reach a target (`TargetChecked`, which may pass it over), a player's cast going (`SpellCast`, before its hits: Execute) and where it landed (`SpellLanded`, hit or missed); the class calls: a cast with its own amounts, power set, cooldowns ended, an effect's amount, spell power, the auras that affect the spell, the highest rank known cast; *a creature's cast checked, a summon made, a destination chosen, heartbeats of creatures' auras* |
| World map | `@world` | `world_template.ScriptName` (a continent) | a creature of it died (`summoned` says whether a script's), signal (`signalDungeon` on the continent), asked, steps of its own schedules; *player login/logout, level, zone change, world events* |
| Command | `@command` | its name | *a GM command of a script* |

Each kind adds a context type, an event list and a host interface; the registry, pools, schedules
and persistence are shared, so a new kind is a few dozen lines in the framework.

### Components: the escort

Behaviour shared by many scripts is a *component*: a struct among the script's fields, not a base
class. The registry ticks any field with `tick(ref Context, int ms)` and `busy` along with the
script, so a component needs no wiring. `Escort` (`dmangos.script.escort`) is the first: started
with a player and a quest, it walks the creature's `script_waypoint` path (`moveTo` point by point,
waiting where the path says), takes its NPC flags away on the way, fails the quest when the player
dies or falls more than 50 yards behind, and may send the creature home when it is over. The script
passes it its `MovementDone`s and reacts to the points it reports (a line at Moonbrook, the quest's
event at the end). It can be paused (an ambush to fight off, a scene to play) and can run its points'
movement scripts (a sniffed path's scenery). Being data, an escort handed to another node goes on there; if the creature's
movement did not come along, the escort sends it on again.

`Follower` (`dmangos.script.follower`) is the
second component: a creature that follows its player (a lost cub, a sleepwalker) until its script
says it has arrived, and that fails the player's quest when the player dies or is left behind.

`Walk` (`dmangos.script.walk`) takes a creature along its path with nobody escorting it (a drunk to
the keg, a guard to his door); `Pack` (`dmangos.script.pack`) counts the creatures a dungeon script
watches together (the keepers of a ward, a wave's adds), so "the last one fell" survives a restart.

A handler of `GossipHello`, `GossipSelect`, `ObjectUsed`, `EffectHit`, `TriggerEntered`, `EventStarted` or (a
dungeon's) `EventHappened` may call `consume()` on its context: the script answered, and the
server's usual menu, use, database script or trigger does not follow. An event's own script that
leaves the work to its dungeon (most of them do: the dungeon holds the state) handles `EventStarted`
without consuming it; with no player near the event (a creature's cast at nobody) only the dungeon
hears of it.

### Game objects' and continents' own time

A game object script may keep schedules like a creature's: the world ticks the scripted objects whose
steps are pending (and only those), and an object hears `Spawned` once it is in the world, its cell
loaded (a bell watching the hour, a rift sending invaders). A trap's script can consume `TrapSprung` to
prevent activation or `TrapDisarmed` to replace the default removal with a rearm timer.

A world map script (`@world`) is a dungeon script for a continent: it has the same abilities
(`WorldMapContext` is an `InstanceContext`), hears the continent's creatures die and the signals its
creatures', objects' and triggers' scripts send with `signalDungeon`, and ticks. A node has one for each
continent it simulates a part of; its state is kept in memory only (CMaNGOS keeps none either), so a
wave half done when the server stops begins anew.

### Dungeon scripts

A database condition of type 18 raises `InstanceCondition` in the current copy. The script answers
with 1 when the condition holds. Dire Maul uses this for the tribute chest's loot tiers.

A dungeon's script is the copy's memory: which encounters are done (saved in `instance.data` after
every event), which doors are open (it opens them again as their objects load), and the events no
single creature owns: waves called by a gong, a ritual's timer, a boss who comes when six others
are dead. It acts on the copy's creatures and objects by their guids (summon, say, cast, attack,
walk, faction and flags, despawn; doors and object flags; spawning the dungeon's objects of an
entry), hears every creature of the copy engage, evade and die, and talks with the creatures' and
objects' own scripts through signals. The `creature_ai_scripts` "set instance data" action is a
signal to it too (its field the signal's id), so a dungeon script keeps the numbers of CMaNGOS's
`TYPE_*` for those and numbers its own signals from 100. It hears `ObjectLoaded` for the objects
database scripts spawn in the copy (a ritual's bell, a trap) as for those its cells load, and
`CreatureLoaded` for linked creatures a boss's wipe brings back (`creature_linking`'s respawn flags work
in copies too).

A copy's script made again from `instance.data` (the server restarted, or the copy was unloaded and is
entered again) hears `Restored` once, before any of its creatures or objects load. What was under way
when it was saved is not any more: its summons, its creatures' fights and its timers went with the old
world. The handler puts back what ScriptDev's `Load` does (an encounter `IN_PROGRESS` becomes
`NOT_STARTED`): an event half done can be begun again, a door it shut opens. Each dungeon's real-data
tests restart a copy in the middle of its events and do them again. A copy that moves to another node
with its creatures does not hear it: its fights go on there.

### Gossip menus of a script's own

A creature script builds a menu on the stack (`GossipMenu`, up to 16 options, each with an icon, its
text and an *action* number) and sends it under an `npc_text` id, with the creature's quests or
without. The option the player picks comes back as `GossipSelect` with its action, so a
conversation is a `switch` over actions. Spell and area trigger scripts are stateless: one instance
per spell or trigger, made on first use, holding nothing between calls that matters.

### Signals across nodes

`signal` to a creature this node does not simulate (it sees its replica) becomes a `ScriptSignal`
message to the creature's node. Each carries its origin node and a sequence number
that only grows (it starts above anything an earlier run of the node sent), so a receiver drops a
signal resent after a reconnect; a creature that moved on meanwhile gets it passed on, at most
three times.

### Performance

* No allocation per event: events and contexts are stack values, handlers are function pointers,
  schedules are fixed arrays. A unit test asserts that a million dispatches allocate nothing.
* Pools keep one script type's states together (good locality when a type's creatures tick).
* A creature without a script pays one null test per hook.
* Lookups by name happen once, when a creature is made.

### Reloading

Scripts are compiled D, linked into the server. Hot reloading is not promised. What makes it
possible later is already in place: script state is serializable with a layout fingerprint, and
scripts reach the core only through interfaces. A reload would load a shared library exporting a
registry, save every live script's state with the old one, and load it with the new one
(fingerprints deciding what is kept). D runtime and GC integration of unloaded libraries is the
open question, and is to be designed before it is offered.

## Background

A comparison of other scripting systems, made before the framework was designed, is archived in
docs/research/SCRIPTING-SURVEY.md. It is not needed to write or understand scripts.
