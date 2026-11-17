> Design-research archive: the comparison of scripting systems made before the script framework was designed. It is not a description of the dmangos implementation; see docs/SCRIPTING.md for that.

# Scripting systems compared

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

