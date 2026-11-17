# dmangos's own architecture: research and decisions

This document records what we learned from other engines, game servers and data-oriented libraries,
what we decided for each idea, and the architecture those decisions add up to. It also records the
order in which the server moves to it. It is written for this server's actual needs: a vanilla WoW
1.12 world server that speaks a fixed client protocol, persists to a fixed CMaNGOS schema, and runs
as one process or as a cluster of nodes that own spatial regions (docs/CLUSTER.md).

Nothing here is copied from another project. For each idea the question was whether the problem it
solves exists here, what it costs, and whether D lets us solve that problem more simply.

## How the research was done

The projects studied were Bevy (`bevy_ecs`), Flecs, EnTT, Unreal Engine (actors, subsystems, tick
functions, Mass Entity, classic replication, ReplicationGraph, Iris), Open 3D Engine (components,
EBus, Gems, the Multiplayer gem), Source and Source 2, Godot (servers and RIDs, signals, the
multiplayer synchroniser), Nakama and SpacetimeDB. SpatialOS, Orleans and EVE Online were studied
for distributed state.

These facts were read in the projects' own sources:
* Bevy's `Entity` is an index plus a generation (`crates/bevy_ecs/src/entity/mod.rs`).
* EnTT's 32-bit entity is 20 bits of index and 12 of version (`entity.hpp`).
* Source's entity handle keeps a 16-bit serial number beside the slot index (`public/const.h`,
  `basehandle.h`).
* O3DE's EBus has address and handler policies, and `AZ::EntityId` is a plain 64-bit id
  (`EBus/Policies.h`, `Component/EntityId.h`).
* Godot's RID owner keeps a validator per slot, in chunks (`core/templates/rid_owner.h`).
* Nakama's match is one loop over a ticker and a bounded input queue that drops when full
  (`server/match_handler.go`).
* SpacetimeDB stores rows in 64 KiB pages with fixed parts from the front and variable parts from
  the back (`crates/table/src/page.rs`).

Unreal's source needs an Epic account, so what is said of it comes from Epic's documentation.
Everything else comes from the projects' design documentation. None of the decisions below rests
on a detail that was not checked.

## What our server needs

These requirements come from the code and from the measurements in docs/BENCHMARKS.md.

1. **A fixed protocol.** The client is told about objects in create blocks and changed-field blocks
   (an update mask over a fixed field array), out-of-range lists and movement packets. It
   acknowledges nothing. A unit has 188 fields (752 bytes); a player has over 1,200.
2. **A fixed schema.** Characters, pets, items and the rest are saved in CMaNGOS's tables, and the
   rows cannot change.
3. **Few kinds, many instances.** There are six kinds of object (player, creature, game object,
   corpse, dynamic object, item). One node holds 25,000 to 30,000 objects with 500 players spread
   out, and should hold 100,000.
4. **The cost of keeping objects.** An object costs about 150 ns a tick, creature or replica, and
   its AI is not most of that. The map finds everything through about twenty associative arrays
   keyed by guid, sets included (`bool[ulong][ulong]`).
5. **Crowds cost fan-out and allocation.** In a crowd the standing cost is relaying movement to
   everyone who sees the mover, and allocation drives the collector: 2.5 MB a tick at 500 players.
6. **Pauses come from the collector.** The worst loop iteration is a collection of 40 to 90 ms, over
   a heap of 360 to 640 MiB that is mostly static data.
7. **Regions are owned by nodes.** Players and creatures move between nodes as serialised state,
   and objects near a border are replicated to the neighbour.
8. **The structure resists change.** Adding pets showed this in several places:
   * A player's gameplay lives in its network session, a class of 37 mixins.
   * Creatures see their enemies through `Combatant`, an interface of about two dozen methods that
     only sessions implemented, so creatures fighting creatures needed an adapter
     (`CreatureCombatant`).
   * Per-kind state hangs off a creature as an untyped `Object`.
   * Mixin methods cannot implement an interface or be reliably called from another module, so
     every such crossing needs a hand-written forwarder.

   PvP and battlegrounds are next. Both would build on these seams.

## The ideas, and what we decided

### Entity identity

**What others do.**
* Every data-oriented engine studied refers to entities by a slot index and a generation (or
  serial):
  * Bevy uses 32+32 bits.
  * EnTT uses 20+12 bits (or 32+32).
  * Flecs uses 32+16 bits plus flags.
  * Source uses an edict index with a 16-bit serial.
  * Mass uses an index and a serial.
  * Godot's RIDs carry a validator.
* Lookup is an array index. A stale reference is caught by its generation instead of reaching a
  reused slot.
* O3DE is the exception: its 64-bit id is looked up through a map.

**Our problem.** We use the WoW guid everywhere, and every lookup is a hash lookup in an
associative array. That accounts for much of the 150 ns an object costs (requirement 4). Threat
lists, auras, targets and summons also hold guids that must be looked up again each time.

**Decision: adopt, redesigned.**
* Inside a map, objects are referred to by a typed handle `Ref!Kind`: a 32-bit slot and a 32-bit
  generation. With 32 bits there is no aliasing to reason about, as there is with EnTT's 12.
* The kind is part of the type, so a `Ref!Creature` cannot be passed where a `Ref!Player` is
  expected. Generic code takes `Ref!Unit` (below).
* The guid stays the identity the client, the database and other nodes see. Each map keeps one
  table from guid to slot, used only at those boundaries.
* Memory: 8 bytes a reference, the same as a guid, and one lookup table instead of twenty.

### Storage and memory layout

**What others do.**
* **Archetype ECSs** (Bevy, Flecs, Mass) store each unique set of components in its own table of
  columns. Adding or removing a component moves the entity to another table. Every column is
  copied, and the published weak points are fragmentation and that move cost.
* **EnTT** keeps one sparse set per component. Adding and removing is O(1) and nothing else moves,
  but iterating several components together reads at random.
* **Unreal actors and O3DE entities** are heap objects with heap components, which is why Unreal
  built Mass.
* **Shared data** comes as Flecs's prefabs (`IsA`) and Mass's shared fragments: data held once for
  many entities.

**Our problem.** Our set of kinds is small and fixed, and every object has a large fixed field
block the protocol defines. The state that comes and goes (in combat, stunned, casting, an aura)
changes all the time. That is an archetype ECS's worst case: a table move on every toggle. It
also saves nothing, because our "component sets" are known at compile time.

**Decision.**
* **Reject archetypes.**
* **Adopt one store per kind.** A `Store!Creature` is an array of structs in slots with a free list
  and generations. Iterating the creatures is a walk along one array. The fixed field block stays
  next to the object it describes, because almost everything that changes a field also reads the
  object's other state.
* **Adopt sparse side tables for state that comes and goes.** Threat lists, a cast under way, an
  escort, waypoint movement, loot and a pet's state go in side tables (`Side!T`: a dense array plus
  a slot→index map, EnTT's sparse set). This replaces fields such as `petData` (an `Object`) and
  `asCombatant`. Adding or removing one moves nothing else, and a system that cares (ticking casts)
  walks only its own dense array.
* **Keep the shared templates.** `CreatureTemplate` and the other templates stay immutable and
  shared by pointer. This is Flecs's prefab idea, and CMaNGOS already has it.
* **Split hot from cold only where measured.** A separate array for the few fields the tick reads
  for every creature (position, next think time, flags) is worth it only if the profiler says so.

### Players and creatures: one unit core

**What others do.**
* Source and Unreal share behaviour through deep class hierarchies (`CBaseEntity`, `AActor`), and
  both are criticised for it.
* ECSs share it through components that systems match on.
* Godot keeps the heavy state in servers addressed by handles, and the scene objects are thin.

**Our problem.**
* Combat, auras, spells and movement are the same rules for every unit, but today they live in two
  places:
  * the player's in the session's mixins;
  * the creature's in `CreatureAI`'s mixins.
* They meet through interfaces (`Combatant`, `CombatWorld`, `CreatureLore`).
* PvP, pets fighting players, and players and creatures in battlegrounds all need any unit to fight
  any unit.

**Decision: a `Unit` core, shared by composition.**
* Player and creature each hold the same `Unit` struct: their fields, health and power, auras,
  combat state (attackers, threat), movement, casting.
* The rules are functions over units: `swing(ref Unit attacker, ref Unit victim, ref MapContext)`,
  `applyAura`, `dealDamage`. Creature against player, player against player, and pet against
  anything are one code path.
* Where a kind reacts differently (a creature's AI fights back, a player's client is told), the
  function branches on the kind with a `final switch`. The compiler then checks that every kind is
  handled. There are no virtual interfaces.
* This removes `Combatant`, `CreatureCombatant`, and most forwarders.

### Where the player's gameplay lives

**What others do.**
* Every engine studied separates the connection from the simulated entity:
  * Unreal's `PlayerController` and `NetConnection` are not the pawn.
  * Source's client is not its `CBasePlayer`.
  * Nakama's session is not its match state.
  * In SpatialOS and Orleans, the network endpoint and the authoritative entity live on different
    machines entirely.

**Our problem.**
* Our `WorldSession` is both the connection and the character.
* Moving a player to another node serialises a session from the inside.
* Every gameplay system is a session mixin.

**Decision: adopt the split.**
* A `Connection` (socket, encryption, account, which handler to call) stays at the player's home
  node, as the cluster already does.
* A `Character` is the map-owned simulation: the player's `Unit`, inventory, quests, talents and the
  rest. Packet handlers become functions that turn a packet into an action on a character.
* Migration moves a character, and saving saves a character.

### Scheduling the tick

**What others do.**
* **Bevy** orders systems by declared constraints and runs them in parallel where their access sets
  do not conflict. Its known costs are dispatch overhead per system and an order that is
  nondeterministic unless pinned.
* **Flecs** runs systems in named phases.
* **Unreal** builds a tick task graph every frame, and "disable tick" is standard advice because of
  its cost.
* **Source** gives each entity a next-think tick.
* **Mass** uses LOD and signals so processors run only for entities that need it.
* **EnTT's owning groups** keep the matching entities packed at the front of their arrays.
* **Bevy and Flecs** defer structural changes (spawning, despawning) to sync points.

**Our problem.**
* A creature with nothing to do this tick still costs its slot in the loop.
* Spawns and despawns during iteration need care today (`dup` before iterating, for example).
* Our parallelism has a natural unit already: the map or region, which the cluster distributes.

**Decision.**
* **Fixed phases, written down in order.** A map's tick runs: input (the packets received), timers,
  movement, AI, spells and auras, combat, then the queued changes applied, visibility, and building
  and sending updates. They are ordered by hand. A dependency solver is not worth it for ten
  systems.
* **Activity by timer, not by polling.** Each unit has a next think time. A timer wheel (buckets by
  tick) gives each phase the units due now, and active ones sit at the front of their store, as in
  EnTT's groups.
  * A creature standing in a cell nobody is near costs nothing until something wakes it.
  * The map's `ticking` array is a first step in this direction.
* **Deferred structural changes.** Spawning, despawning, cell changes and moves to another node are
  queued during a phase and applied at one point in the tick. Nothing is removed from under an
  iteration.
* **Parallelism by map** (decided 2026-11-17: designed for from now on, switched on once the phases
  of step 4 are in). A map is a single-threaded actor with an input queue (Nakama's
  match loop, EVE's solar system, Orleans's grain). Maps share nothing they write, so they can later
  run on their own threads.
  * Unlike Nakama, a full queue is never silently dropped from. It slows the sender down or
    disconnects it.
  * Parallelism inside a map is rejected. Bevy's own measurements show it pays only for heavy
    systems.

### Events

**What others do.**
* **O3DE's EBus:** an addressed bus with handler policies. Its own developers criticise it for
  hidden coupling, debugging pain and compile times, and added lighter alternatives.
* **Godot's signals:** they allocate their arguments.
* **Flecs and Bevy observers:** run a lookup and a dynamic call on every matching change.
* **Bevy's message queues:** double-buffered arrays read through a cursor, as cheap as an append.
* **EnTT's delegate vectors:** allocate nothing per call.

**Our problem.**
* When a creature dies, loot, quests, scripts, the dungeon's script, kill credit and the group all
  need to know. Today each is called directly from the place of death, and the list grows.
* Inside a system, direct calls are right.

**Decision.**
* **Typed event queues per tick.** A death becomes a `Died` record appended to the map's
  `Events!Died`. Loot, quests, scripts and the group read it in their phase. A system that wants
  deaths reads one array, and the code that kills does not know who listens.
* Direct calls stay inside a system.
* **Rejected:** a bus, observers on every change, and string-named signals.
* The script framework already dispatches typed events to scripts (docs/SCRIPTING.md). It becomes
  a reader of these queues.

### Script registration

**What others do.**
* Nakama registers handlers in an `InitModule` function. Its Go plugins must be built with the
  exact server toolchain, which is widely criticised.
* Godot registers classes in `ClassDB`.
* SpacetimeDB reads a module's description at publish time.

**Decision: keep what we have.** Scripts, packet handlers and GM commands are registered at
compile time from attributes (`@creature`, `@Handles`, the ArcEmu command tables). D does at compile
time what these projects do at start-up, and nothing is loaded at run time. Embedded script VMs and
run-time plugins stay rejected.

### Replication to clients

**What others do.**
* **Unreal's classic replication** compares each property against a copy per connection, which
  costs objects × connections. It added push-model dirty flags for that reason.
* **ReplicationGraph** buckets actors in a spatial grid, keeps lists per connection, and prioritises
  by distance and age.
* **Iris** describes replicated state once per class and serialises an object once for all
  connections.
* **Source** delta-encodes against the last snapshot the client acknowledged, picks entities by
  potentially visible set, and marks changed variables dirty.
* **SpacetimeDB** evaluates subscriptions on the rows a transaction changed.

**Our problem.**
* The protocol defines the delta: a mask over the fixed field array, sent once per change, never
  acknowledged.
* Relevance is a radius around the player. A known-set per player is required to send creates,
  updates and out-of-range lists.
* The crowd cost is fan-out (requirement 5).

**Decision.**
* **Keep:** the dirty mask per object, the cell grid, the known-set per player, and building and
  compressing a create block once for each kind of viewer (done in docs/BENCHMARKS.md's second
  optimisation).
* **Adopt:**
  * A per-map list of the objects that changed this tick, so building updates costs what changed
    and not what exists.
  * Serialising a value update once for each kind of viewer (stranger, group member, owner) and
    sending the same bytes to all of them (Iris's idea).
  * Batching each viewer's movement and updates into one write per tick.
* **Reject:** snapshots and acknowledged deltas, lag compensation, and per-connection shadow
  copies. The client acknowledges nothing, and the rules are server-side with leeway.

### Persistence

**What others do.**
* **SpacetimeDB** commits each transaction to an append-only log of checksummed segments, with page
  snapshots for recovery.
* **Nakama** writes synchronously to SQL when a script asks.
* **Orleans** writes a grain's state with an etag for optimistic concurrency.
* **SpatialOS** flushed an entity's state to its runtime before handing authority to another
  worker.

**Our problem.** We write to MySQL from the game loop, so a slow statement stalls the tick. CMaNGOS
accepts losing the last few minutes of play on a crash, and so do we.

**Decision.**
* **A writer thread, fed by value records.**
  * The loop makes an immutable record of what to save, for example a character with its items.
    D's `immutable` lets the record cross to the writer thread without locks or copies.
  * The writer keeps only the newest record per character, and writes each character in one
    transaction.
* **Ordering rules:**
  * Before a character moves to another node or logs out, its pending save is written and
    acknowledged. Records carry a sequence number per character.
  * A trade, a mail or an auction writes both sides in one transaction.
  * Writes carry the node's lease, so a node that has lost its region cannot write over the new
    owner.
* **A local write-ahead log** (decided 2026-11-17): stronger than CMaNGOS, which loses what was not
  yet saved.
  * Each record is appended to the node's log (length-prefixed, checksummed, in segments, as
    SpacetimeDB's commitlog does) and flushed before the writer takes it.
  * The log is trimmed once MySQL has the record.
  * At start-up a node replays what MySQL does not have yet.
  * A crash then loses at most the records not yet flushed to the log, which is one flush interval.
* **Rejected:**
  * A database as the server (SpacetimeDB) or a distributed SQL store (Nakama on CockroachDB). The
    schema and protocol are fixed, and one writer per database contradicts ownership by region.

### Distribution between nodes

**What others do.**
* SpatialOS gave each entity one authoritative worker, chosen by region. A worker's interest
  reached past its authority, and authority was handed over after the state was flushed.
* Orleans guarantees one activation of a grain through a directory.
* EVE has no live handoff at all; players move between solar systems through gates.
* O3DE's Multiplayer gem has authority roles per entity.

**Our problem.** Our cluster already has this shape:
* regions owned by nodes under leases;
* replicas past the border;
* migration of serialised state;
* ids handed out in blocks;
* the client's connection kept at its home node.

**Decision: keep it, and build on the rest of this design.**
* Handoff becomes "move a character" and "move a creature store's slots" instead of serialising
  sessions.
* Saves gain the lease check above.
* Traffic between nodes stays one message per object and node, never per object and client.

### Memory and the collector

**What others do.** Every high-performance engine studied avoids allocating per object per frame.
They allocate in chunks or pages (Mass's chunks, SpacetimeDB's pages, Godot's RID chunks) and
recycle slots.

**Our problem.** The pauses are collections over a heap that is mostly static data (requirement 6),
and crowds allocate per packet (requirement 5).

**Decision.**
* **Large arrays and recycled slots.** Stores and side tables are large arrays with recycled slots,
  so the collector sees a few big blocks instead of hundreds of thousands of objects and
  associative-array nodes.
* **Static data off the scanned heap.** Static data (templates, the client's tables, terrain) moves
  to memory the collector does not scan: blocks without pointers marked `NO_SCAN`, or immutable
  arenas.
* **`@nogc` hot paths.** The hot paths (movement relay, the tick's loops, building updates) are
  marked `@nogc`. The compiler then proves they do not allocate, which no C++ engine can check.

## What stays, what changes

| Today | Becomes |
|---|---|
| Guids looked up in about twenty associative arrays per map | `Ref!Kind` handles into per-kind stores; one guid table per map |
| `Creature` and `CreatureAI` classes, with `petData`, `asCombatant`, summon state on every creature | `Store!Creature` of structs; side tables for pets, threat, casts, escorts |
| Combat and auras written twice, joined by `Combatant` and an adapter | One `Unit` core and rule functions over it |
| `WorldSession` as connection and character, 37 mixins | `Connection` at home; `Character` owned by its map; handlers as functions |
| Everything ticked by polling, removals guarded by copies | Fixed phases, a timer wheel, deferred structural changes |
| Deaths and kills call each interested system directly | Typed event queues read in their phase |
| Saves on the game loop | Value records to a writer thread, coalesced, fenced by lease |
| Static data in the scanned heap | Unscanned, immutable memory |
| Kept as it is | The update-field tables, compile-time registration of scripts, handlers and commands, the cell grid, the cluster's ownership, leases and id blocks, the script framework |

## What was rejected, and why

* **A general ECS with archetypes:** it solves composition we do not have, and its worst case is our
  common case.
* **Actors or objects with components per entity** (Unreal, O3DE): a heap object and virtual calls
  per entity and per component, which is the cost Unreal built Mass to escape.
* **An event bus or observers on every change:** hidden coupling and per-change dispatch on hot
  paths.
* **Automatic parallel scheduling of systems:** overhead per system and nondeterminism. Parallelism
  by map is coarser and fits the cluster.
* **Snapshot deltas and lag compensation:** the client protocol rules them out.
* **The database as the engine, embedded script VMs, run-time plugins:** fixed schema, fixed
  protocol, and D's compile-time registration does better.
* **Change ticks per component** (Bevy): 8 bytes per component per object and a write on every
  change, where one dirty mask per object (which the protocol needs anyway) does the job.

## The order of the move

Each step is a working server: the unit tests, the cluster's 250-bot regression and the benchmark
scenarios run after it, and the step that is meant to make something faster shows it in
docs/BENCHMARKS.md's terms.

Decisions taken on 2026-11-17:
* The connection/character split goes ahead.
* Saves get a write-ahead log.
* Maps are built to run on their own threads.

1. **Handles and stores in the map.**
   * Change: `Ref!Kind`, `Store!T` and `Side!T`; the map's associative arrays become stores and
     side tables; one guid table per map.
   * Measure: the cost per object per tick in the idle and spread scenarios, today about 150 ns.
2. **The unit core.**
   * Change: `Unit` in players and creatures; melee, spells, auras and death as functions over
     units; `Combatant` and `CreatureCombatant` go.
   * Gate: the combat, pet, duel and script tests pass unchanged. This step is what PvP needs.
   * Done (2026-11-17) as `dmangos.world.unit`. A `UnitRef` value (a session or a creature, and its
     map) replaces the interface and the adapter. `dealDamage` replaces six paths: three to a player
     (`hitByCreature`, `takeDamageFrom`, `hitByCreatureSpell`) and three to a creature (the player's
     swing, `spellAttacked`, `CreatureCombatant.takeHit`).
   * Behaviour that changed, now as CMaNGOS has it:
     * A player gets rage from any damage taken, a player's spells included.
     * A player stands up when any non-periodic damage hits it.
     * A death costs durability unless a player dealt it.
     * A creature's heal on a friend never misses.
   * Not unified yet: healing and aura application keep a path per kind behind `UnitRef`.
3. **Character and connection.**
   * Change: the session's gameplay mixins move to `Character`, one area at a time; migration and
     saving move a character.
   * Done (2026-11-17), all areas at once. The handler groups depend on each other too much to
     move one at a time.
     * `WorldSession` is the connection: framing, encryption, the account, the protocol state,
       authentication, pings, the character screen.
     * `Character` (`character.d`) holds the player and every gameplay mixin, and exists only while
       in the world.
     * The login's checks stay with the connection; the rest is `CharacterLogin`.
     * An arrival from another node makes a `Character` on the arriving connection.
     * The context's online players, the map and every system know the `Character`. The session
       table, `.disconnect` and the cluster's relay know the connection.
   * What is left of the connection in the gameplay code goes through forwarding properties of the
     same names (`account`, `state_`, `homeNode`, `send`, ...). That is the seam to narrow next.
4. **Phases, the timer wheel, deferred changes and event queues.**
   * Measure: the tick with 25,000 objects and few players, which should approach the cost of the
     active units only.
5. **Replication.**
   * Change: the per-map changed list, value updates serialised once per kind of viewer, one write
     per viewer per tick.
   * Measure: allocation and loop busy time in the 500-player crowd.
6. **The save writer.**
   * Change: records, the write-ahead log, coalescing, the ordering rules, lease fencing.
   * Measure: the worst loop iteration with saves under load.
7. **Static data off the scanned heap.**
   * Measure: GC pause length.

Features resume after step 3. Mmaps fits anywhere, because it touches movement only through a few
queries. PvP, the honor system and battlegrounds come after step 2 at the earliest, so they are
built on the unit core. Steps 4 to 7 are performance work and can interleave with features.
