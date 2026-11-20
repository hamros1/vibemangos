# The design of the world server

Why the world server's core is built as it is: how objects are identified and stored, where a
player's gameplay lives, how the tick is scheduled, how events reach the systems that care, how
updates reach clients, how saves reach the database, how memory is kept away from the collector, and
how all of it fits the cluster (docs/CLUSTER.md). For each part it states the problem, the decision,
and how far the code has got. The last section lists the steps by which the server was moved to this
design, with their measured results, which docs/BENCHMARKS.md refers to.

## What the server needs

These requirements come from the protocol, the data, and the measurements in docs/BENCHMARKS.md.

1. **A fixed protocol.** The client is told about objects in create blocks and changed-field blocks
   (an update mask over a fixed field array), out-of-range lists and movement packets. It
   acknowledges nothing. A unit has 188 fields (752 bytes); a player has over 1,200.
2. **A fixed schema.** Characters, pets, items and the rest are saved in the existing character
   database tables (README, "Compatibility"), and their rows cannot change.
3. **Few kinds, many instances.** There are six kinds of object: player, creature, game object,
   corpse, dynamic object, item. One node holds 25,000 to 30,000 objects with 500 players spread
   out, and should hold 100,000.
4. **The cost of keeping objects.** Before the redesign an object cost about 150 ns a tick, creature
   or replica, and its AI was not most of that: the map found everything through about twenty
   associative arrays keyed by guid.
5. **Crowds cost fan-out and allocation.** In a crowd the standing cost is relaying movement to
   everyone who sees the mover, and allocation drives the collector (2.5 MB a tick at 500 players
   before the redesign).
6. **Pauses come from the collector.** The worst loop iteration was a collection of 40 to 90 ms, over
   a heap of 360 to 640 MiB that is mostly static data.
7. **Regions are owned by nodes.** Players and creatures move between nodes as serialized state, and
   objects near a border are replicated to the neighbour.
8. **Any unit fights any unit.** Pets, PvP, duels and battlegrounds need creatures and players to
   fight each other through one set of rules.

## Entity identity and storage

**Problem.** Every lookup was a hash lookup by the 64-bit guid, and threat lists, auras, targets and
summons hold guids that must be looked up again each time.

**Decision.**
* Inside a map, an object is referred to by its slot. `dmangos.store` provides `Store!T`, an array of
  slots with a free list, and `Ref!T`, a 32-bit slot and a 32-bit generation. Removing a value frees
  its slot and bumps its generation, so a reference kept from before is caught rather than
  misdirected; with 32 bits a slot would have to be reused four billion times before an old reference
  could alias a new value. Lookup is an array index and iteration walks one array.
* The guid stays the identity the client, the database and other nodes see. Each map keeps one table
  from guid to slot (`Map.slotOf`), used only at those boundaries.
* Who sees what is kept from both sides: a player's `known` set (a `SlotBits`, one bit per slot) and
  an entity's `viewers` (the slots of the players whose clients have it). Sending to an object's
  viewers walks its viewer list instead of asking every player on the map.
* State that comes and goes (threat, a cast under way, an escort, loot, a pet's state) belongs in
  sparse side tables (`Side!T`: a dense array and a slot-to-index map), so adding or removing it moves
  nothing else and a system walks only its own dense array.
* Shared templates (`CreatureTemplate` and the others) are immutable and shared by pointer.

**Status.** The map keeps every player and object in one `Store!Entity` with a single guid table
(step 1). Creatures and game objects are still classes referred to from their slots, and `Side!T` is
not used yet; per-kind stores of structs and side tables are the next part of this work. Splitting
hot fields from cold ones is done only where the profiler shows it pays.

**Not chosen.** An archetype entity-component system: our kinds are few and known at compile time,
every object has the large fixed field block the protocol defines, and the state that comes and goes
(combat, stuns, casts, auras) changes all the time, which would move an entity between tables on
every toggle. Heap objects with per-entity components and virtual calls are not chosen either.

## One unit core

**Problem.** Combat, auras, spells and movement are the same rules for every unit, but they lived in
two places, the player's session and the creature's AI, joined by interfaces and an adapter.

**Decision.** The rules are functions over units. `dmangos.world.unit` defines `UnitRef`, a value
naming a player (its `Character`) or a creature, and its map. `dealDamage` is the one path for damage
to any unit; where a kind reacts differently (a creature's AI fights back, a player's client is told),
the code branches on the kind with a `final switch`, which the compiler checks covers every kind.
There are no virtual interfaces. Creature against player, player against player, and pet against
anything take the same path.

**Status.** Damage, the death that follows, and the reactions to it are unified (step 2). A spell's
effects, damage, heals, power and auras are one pipeline for every caster over `Caster` and `UnitRef`
(docs/SPELLS.md); casting itself (checks, costs, cooldowns, targets) keeps a side per kind.

## Connection and character

**Problem.** A session that is both the network connection and the character makes moving a player to
another node mean serializing a connection from the inside.

**Decision.**
* `WorldSession` is the **connection**: framing, encryption, the account, the protocol state,
  authentication, pings and the character screen. It stays on the player's home node.
* `Character` (`character.d`) is the **simulation**: the player and every gameplay handler group. It
  exists only while the player is in the world. Packet handlers are methods of its mixins.
* The login's checks stay with the connection; the rest is `CharacterLogin`. An arrival from another
  node makes a `Character` on the arriving connection.
* The context's online players, the map and every system know the `Character`. The session table,
  `.disconnect` and the cluster's relay know the connection.

Migration moves a character, and saving saves a character. What is left of the connection in the
gameplay code goes through forwarding properties of the same names (`account`, `state_`, `homeNode`,
`send`, ...); that is the seam to narrow next.

## Scheduling the tick

**Problem.** A creature with nothing to do still cost its place in the loop, and spawns and despawns
during iteration needed care.

**Decision.**
* **Fixed phases, in order.** `WorldContext.update` runs `TickPhase.maps` (on each map, its players,
  then its creatures and game objects), `deaths` (the creatures that died: their dungeon's scripts,
  their respawn) and `world` (what belongs to no one map: dungeon copies, scripts, weather, respawns,
  auctions, mail). The order is written by hand; a dependency solver is not worth it for so few
  systems.
* **Activity by timer, not by polling.** An object that can say how long it will idle (`Idler.idleFor`:
  alive, standing, with nothing for its AI to do) sleeps on its map's timer wheel and is out of the
  tick until then. Each object keeps its last tick time, so a wake gives it the whole time it slept.
  A creature standing where nobody is near costs nothing until something wakes it.
* **No removal from under an iteration.** The tick works on a reused copy of what ticks; spawning,
  despawning and moves to another node take effect for the next pass.
* **Searches do not load cells.** Only a player's sight loads cells, so a creature looking around does
  not start a wave of loading.
* **Parallelism by map.** Maps share nothing they write, so they can later run on threads of their
  own, each a single-threaded actor with its input queue. They do not yet; the server runs the world
  on one thread, with database writes on another. A full input queue will slow its sender or
  disconnect it, never drop silently. Parallelism inside a map is not planned: it pays only for heavy
  systems.

## Events

**Problem.** When a creature dies, loot, quests, scripts, the dungeon's script, kill credit and the
group all need to know, and calling each directly from the place of death makes that list grow.

**Decision.** Typed event queues per tick (`dmangos.events.EventQueue!T`). The code where something
happens appends a record to the queue of its type and goes on; the systems that care read the queue in
their phase. A queue is two arrays, one filling while the other is read, whose memory is reused, so a
queue in steady use allocates nothing. Inside a system, direct calls stay. The first queue is the
map's creature deaths, read in the deaths phase. There is no event bus, no observer on every change,
and no string-named signal.

## Registration at compile time

Scripts (`@creature`, `@instance`, ...), packet handlers (`@Handles`), GM commands (the command
tables) and cluster services (`@Service`, `@Call`) are found at compile time from attributes, and their
dispatch tables are generated by the compiler. Nothing is registered or loaded at run time, and there
is no embedded script language or plugin loader: D's templates and attributes give the concise
declarations and generated glue those are usually used for, with static checking.

## Updates to clients

**Problem.** The protocol defines the delta (a mask over the fixed field array, sent once per change,
never acknowledged), relevance is a radius around the player, and the crowd cost is fan-out.

**Decision.**
* **Kept:** the dirty mask per object, the cell grid, the known set per player, and building and
  compressing a create block once for each kind of viewer.
* **Built once, sent to many.** An object's field update is built once for every viewer who sees the
  same fields (stranger, group member, owner) and the same bytes go to all of them. The player's own
  updates are built once per kind of viewer, without a list of watchers.
* **Changes made in a map's tick are sent once at its end**, from the map's list of changed slots.
* **Output that is reused.** A session writes into an `OutputBuffer` whose memory the server gives
  back once sent (`ReusesOutput`), and each socket gets one write per loop iteration.
* **Not done:** snapshots and acknowledged deltas, lag compensation, and per-connection shadow
  copies. The client acknowledges nothing, and the rules are server-side with leeway.

## Persistence

**Problem.** Writing to MySQL from the game loop lets one slow statement stall the tick.

**Decision** (`dmangos.world.writebehind`):
* **Writes behind the loop.** `WriteBehind` wraps `WorldDatabase`. A write (a method that returns
  nothing, with plain-data arguments) is encoded into bytes and queued, and the call returns at once.
  A thread of its own, with its own connections, writes the queue in the order it was made. The layer
  is generated from the interface, so item, mail and other writes keep their order with the saves,
  and a method added to the interface is queued without anyone remembering to.
* **Reads wait.** Any other call (a read, or a write that hands over a delegate or an `out` argument)
  first waits for the queue to be written, so it sees everything written before it.
* **Coalescing.** A write marked `@Replaces` (a character's whole progress, its auras, its cooldowns)
  makes a queued one with the same key pointless, and the writer skips the older one.
* **A write-ahead log.** Before the writer carries out what it took from the queue, it appends it to
  a log file (`write_log`) and flushes the file to disk; once MySQL has it, the log is emptied. At
  start-up, what the log still holds is written first. A crash loses only what was queued and not yet
  logged. Each write is numbered, and its number is recorded in `dmangos_write_applied` in the write's
  own transaction, so the replay skips what MySQL already has (exactly once). While MySQL is
  unavailable, the writer tries the same write again with a growing delay; a write MySQL refuses goes
  to a file of failed writes.
* **Ordering rules.** Before an account is released and before a player moves to another node, the
  node waits until everything queued has been written: the next node reads the character from the
  database.
* **Fencing.** Each queued write carries the time until which the node's cluster lease held when it
  was made; the writer and the replay drop a write they reach after that time (docs/CLUSTER.md). A
  standalone server always writes.

A database as the server, or a distributed SQL store, is not used: the schema is fixed, and ownership
by region already says which node writes what.

## Memory and the collector

**Decision.**
* **Static data off the scanned heap** (`dmangos.frozen`). Tables loaded at start-up (items, creature
  and game object templates, models, addons, spells and spell chains) are `StaticMap`s: associative
  arrays while loading, then frozen into an arena from `malloc` that the collector never scans, as
  open-addressed tables. Only plain data goes in, copied deep. A value with pointers read from a
  frozen map is `const`; `edit` gives a mutable one in place and registers it with the collector, for
  the few a GM command or a test changes.
* **Large arrays and recycled slots.** Stores are large arrays with recycled slots, so the collector
  sees a few big blocks instead of many small objects and associative-array nodes.
* **Marking on one thread** (`gcopt=parallel:0`).
* **Planned:** NPC data, quests and the spawn cells off the scanned heap (about 4 ms of marking), and
  `@nogc` on the hot paths (movement relay, the tick's loops, building updates), so the compiler proves
  they do not allocate.

## Distribution between nodes

The cluster gives each entity one authoritative node, chosen by region; replicates past borders;
migrates serialized state; hands out ids in blocks; and keeps the client's connection at its home
node (docs/CLUSTER.md). The rest of this design builds on it: a move is "move a character" and
"move a creature's state", saves are fenced by the lease, and traffic between nodes is one message per
object and node, never per object and client.

## The steps, and what they measured

Each step left a working server: the unit tests, the cluster's 250-bot regression and the benchmark
scenarios ran after it, and the steps meant to make something faster show it in docs/BENCHMARKS.md.

1. **Slots in the map.** The map's associative arrays became one store of entities with a single guid
   table, and viewer lists and known sets by slot. Measured alone (`tools/mapbench.d`), a tick of 500
   players and 30,000 objects went from 15.9 to 1.9 ms, delivering exactly the same packets.
2. **The unit core.** `UnitRef` replaced the `Combatant` interface and its creature adapter, and
   `dealDamage` replaced six damage paths: three to a player (`hitByCreature`, `takeDamageFrom`,
   `hitByCreatureSpell`) and three to a creature (the player's swing, `spellAttacked`, the adapter's
   `takeHit`). With one path, these rules now hold for every unit:
   * a player gets rage from any damage taken, a player's spells included;
   * a player stands up when any non-periodic damage hits it;
   * a death costs durability unless a player dealt it;
   * a creature's heal on a friend never misses.
3. **Character and connection.** All handler groups moved to `Character` at once; they depend on each
   other too much to move one at a time.
4. **Phases, the timer wheel, no removal under iteration, event queues, searches that do not load.**
   Loop busy time 19.8% to 7.3%, tick 10.2 to 3.5 ms, worst tick 1,073 to 80 ms.
5. **Updates built once, output reused.** In the 500-player crowd: allocation 2.57 to 0.41 MB a tick,
   CPU 58% to 11%, loop busy 12.5% to 7.9%, ping p99 21.9 to 3.8 ms.
6. **Writes behind the loop**, with the log, coalescing, the ordering rules and lease fencing. With
   every character saving every 5 s: tick average 3.49 to 0.54 ms, worst 15.1 to 3.3 ms.
7. **Static data off the scanned heap.** Collection pause 55.6 to 16.4 ms in the crowd, 71.6 to
   37.7 ms spread out.

## Background

The survey of other engines and servers that preceded these decisions is archived in
docs/research/DESIGN-SURVEY.md. It is not needed to understand the design.
