# Scripting

How gameplay that the database cannot describe (boss fights, dungeon doors and encounters, escort
quests, special spells, scripted objects and triggers) is written for dmangos. The framework
(`dmangos.script`) is its own design. This document first compares how other servers and engines
script, then states what dmangos takes from them, what it does differently, and why.

Status: the framework with creature, dungeon (instance), game object, spell and area trigger
scripts, their persistence, gossip (menus of the database's or the script's own) and quest events,
script movement, escorts, and signals between scripts on different nodes is implemented and tested
(`dmangos.script`; scripts in `dmangos.scripts`). World and command scripts are planned.

## What other systems do

### TrinityCore (`ScriptMgr`)

* **Registration:** every script is a C++ class derived from a kind of `ScriptObject`
  (`CreatureScript`, `InstanceMapScript`, `SpellScriptLoader`, `PlayerScript`, ...). Its
  constructor adds it, by name, to a registry of that kind; a generated `AddScripts()` calls one
  `AddSC_*` function per file. The world database binds names (`ScriptName`) to entities.
* **Dispatch:** typed virtual hooks per kind. `ScriptMgr` has one method per hook (`OnPlayerLogin`,
  `OnQuestAccept`, ...), each looping over the registry of its kind (global hooks) or asking the
  one bound script (entity hooks). Creature behaviour is a `CreatureAI` subclass the script's
  `GetAI` returns: one heap object per creature, overriding `UpdateAI`, `JustEngagedWith`, etc.
* **Time:** `EventMap` (integer event ids, due times; the AI polls it in `UpdateAI`) and
  `TaskScheduler` (lambdas with captures, scheduled and rescheduled from inside each other).
* **State:** member variables of the AI or instance object. Instances persist a string
  (`GetSaveData`/`Load`) written by hand per dungeon; nothing else persists.
* **Isolation:** none in practice: scripts receive `Creature*`, `Player*` and can call anything.
* **Reloading:** a dynamic-library mode exists for development; it reloads whole modules, after
  which every AI is rebuilt (state lost).
* **Strengths:** typed hooks, one language, fast dispatch, data-driven `SmartAI` for simple cases.
* **Weaknesses:** inheritance-heavy; raw pointers kept across ticks (a classic crash source when the
  object leaves the map); lambdas in `TaskScheduler` capture pointers and cannot be saved; every
  instance script hand-writes its save format; a script can bypass any rule.

### MaNGOS / CMaNGOS (ScriptDev2)

* **Registration:** a `Script` struct of function pointers (`GetAI`, `pGossipHello`,
  `pQuestAcceptNPC`, `pGOUse`, `pAreaTrigger`, ...) filled per name and added with
  `RegisterSelf()`. `ScriptName` columns bind them; `scripted_areatrigger` and `scripted_event_id`
  bind triggers and events.
* **Creature AI:** `ScriptedAI` subclasses with countdown timers in member variables
  (`m_uiSlamTimer -= diff`), boss phases as integers. `script_texts` holds texts by negative id.
* **Instances:** `ScriptedInstance` with `SetData`/`GetData` encounter states and a hand-written
  save string; doors opened from there.
* **Data-driven siblings:** EventAI (`creature_ai_scripts`) and `dbscripts_on_*`, which dmangos
  already runs (`eventai.d`, `dbscripts.d`).
* **Strengths:** the function-pointer table is simple and cheap; names bind data to code cleanly.
* **Weaknesses:** the same as TrinityCore's AI side (pointers, hand-written timers, per-dungeon
  save strings), and the table mixes unrelated hooks in one struct.

### Eluna (Lua on TrinityCore/MaNGOS)

* **Registration:** at run time: `RegisterCreatureEvent(entry, EVENT_ID, function)`, events named by
  numbers, handlers receiving untyped arguments (`event, creature, target`).
* **Time:** `CreateLuaEvent`/`RegisterEvent` with callbacks and repeat counts.
* **Isolation:** through bound userdata objects, but nearly the whole core is exposed.
* **Reloading:** `.reload eluna` works: Lua state is thrown away and scripts run again.
* **Strengths:** hot reload, quick iteration, no compile step.
* **Weaknesses:** dynamic typing (typos found at run time), a second language and runtime with its
  own GC, marshalling cost on every call, pointers inside userdata that dangle when objects go,
  untyped events, and state lost on reload.

### Unreal Engine (gameplay framework, Gameplay Ability System)

* **Composition:** behaviour is components attached to actors; events are typed multicast
  delegates; gameplay tags (hierarchical names) classify everything.
* **Abilities:** `GameplayAbility` objects run asynchronous *ability tasks* (wait for an event, a
  delay, an input) and apply `GameplayEffect`s, which are data: durations, modifiers, stacking.
  Gameplay events carry a tag and a small payload struct.
* **Networking:** server authority; properties replicate; RPCs are explicit. Latent actions and
  timers belong to an object and die with it.
* **Strengths:** data (effects, tags) separated from code (abilities); typed payloads; explicit
  authority.
* **Weaknesses for us:** heavy object model; latent actions are coroutine-like and cannot be
  serialized or moved to another machine.

### Others

* **EverQuest emulator (EQEmu):** quest scripts per NPC in Perl or Lua, dispatched by event name
  (`EVENT_SAY`, `EVENT_COMBAT`). Very approachable; untyped; per-call interpreter cost.
* **Ryzom Core:** a dedicated AI script language for NPC groups, compiled to bytecode; powerful
  for groups and states, but a whole language to maintain.
* **SpatialOS / Improbable and Photon's server-side model:** component data with one authoritative
  worker per entity, commands sent to the authoritative worker, events read by everyone. This
  matches our cluster rule and is the part of the cluster design scripts must follow.
* **Godot:** signals (typed, connected at run time) and per-node scripts: easy to write, but
  connections hold object references and the dispatch is dynamic.

### What the comparison shows

1. **Name-based binding to data works.** Every MMO server above binds code to rows by a script name.
   The world database already carries `ScriptName` for 398 creatures (294 scripts), game objects,
   area triggers, events and dungeons, so dmangos keeps that binding and the schema stays as it is.
2. **Typed hooks beat untyped buses.** The bugs in Eluna and EQEmu scripts are typing bugs. Typed
   events also let a server skip work no script asked for.
3. **Pointers held across time are the recurring crash.** Every C++ server has a "creature left the
   map while the script held it" class of bugs. In a cluster the object may be on another machine.
4. **State nobody can save is state nobody can move.** Hand-written instance save strings, timers
   in lambdas or coroutines, and AI objects with pointer members cannot be persisted, migrated to
   another node or survive a reload. Our cluster migrates creatures; scripts must migrate with them.
5. **A second language costs more than it gives** when the host language compiles fast and has
   compile-time introspection: D's templates and UDAs give most of what a scripting language is
   used for (concise declarations, generated glue) with static checking and no marshalling.

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
| Creature | `@creature` | `creature_template.ScriptName` | spawned, reset, entered combat, damaged, killed a unit, died, evaded, spell hit, signal, steps, movement done, gossip hello and select, quest accepted and rewarded; *summoned, emote* |
| Dungeon | `@instance` | `instance_template.ScriptName` | creature or object loaded, creature died, signal; *player entered, encounter start/wipe* |
| Game object | `@gameObject` | `gameobject_template.ScriptName` | used, signal; *loaded, state changed* |
| Area trigger | `@areaTrigger` | `scripted_areatrigger` | entered |
| Spell | `@spell` | `spell_scripts` | a dummy or script effect hit (a player's or a creature's cast), a player's aura applied, its periodic tick on a creature (the amount changeable); *aura removed, cast check, auras on players from creatures* |
| World | `@world` | always | *player login/logout, level, zone change, world events* |
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
event at the end). Being data, an escort handed to another node goes on there; if the creature's
movement did not come along, the escort sends it on again.

A handler of `GossipHello`, `GossipSelect`, `ObjectUsed`, `EffectHit` or `TriggerEntered` may call
`consume()` on its context: the script answered, and the server's usual menu, use, database script
or trigger does not follow.

### Gossip menus of a script's own

A creature script builds a menu on the stack (`GossipMenu`, up to 16 options, each with an icon, its
text and an *action* number) and sends it under an `npc_text` id, with the creature's quests or
without. The option the player picks comes back as `GossipSelect` with its action, so a
conversation is a `switch` over actions. Spell and area trigger scripts are stateless: one instance
per spell or trigger, made on first use, holding nothing between calls that matters.

### Signals across nodes

`signal` to a creature this node does not simulate (it sees its replica) becomes a `ScriptSignal`
message to the creature's node (protocol 21). Each carries its origin node and a sequence number
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
