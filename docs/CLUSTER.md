# Clustering

How dmangos grows from one world server process into several that simulate one continuous world
together, after Photon's "seamless MMO backend across machines": dynamic spatial regions, overlap
between neighbours, one authoritative owner per entity, and ownership that migrates.

This document records the decisions and why they were made; each phase adds to it when it lands.
Status: **phases 0 (measurement, with the standalone baseline in docs/BENCHMARKS.md), 1 (cluster
foundation), 2 (distributed world ownership) and 3 (replication: creatures, game objects and players
seen across nodes, every node serving clients, one login per account) are implemented and tested,
and so is phase 4: creatures and game objects migrate with their region, players move to the node
that owns the ground they stand on while their client stays connected where it is, and a node whose
lease lapsed writes nothing; and most of phase 5: speech, whispers, the who list, NPC services
(limited vendor stock counted on the vendor's node), chat channels, groups, GM commands and world
texts across nodes; nodes drain on a clean stop; phase 6, load balancing by measured cost;
and phase 7, a standby coordinator that takes over.** Trades and duels (not written yet), splitting
regions, and a quorum of coordinators are design.

## What the client allows

These constraints decide more of the design than anything else.

* **One connection, one endpoint.** A 1.12 client keeps a single TCP connection to the world server
  it was given by the realm list, with header encryption keyed by the session key. It cannot be
  told to move to another address without logging out (there is no redirect in 1.12). So the
  machine holding a client's socket cannot change during play, while the machine simulating that
  client's character must be able to. Something has to sit between them.
* **No loading screen within a map.** Crossing between nodes must not involve `SMSG_NEW_WORLD` or
  `SMSG_TRANSFER_PENDING`, which show one. The client must keep receiving the same kinds of update
  packets, for the same guids, as if one server sent them.
* **The client does not know about nodes.** Guids must stay stable across migrations; a creature
  or player keeps its guid wherever it is simulated.

## The server today, and what a cluster changes

| Part | Today | In the cluster |
|---|---|---|
| Event loop (`net/server.d`) | One thread, `select`, sessions only handle bytes | Reused as is: cluster links are more `NetSession`s on the same loop. Gains a second listener and outgoing connections |
| Client sessions (`session.d` and its handler mixins) | Crypto, framing, auth, character screen and in-world handlers in one object | Split in phase 3: the connection half stays on the node the client connected to (its *home*), the in-world half runs on the node that owns the character |
| Tick (`context.update`) | Players, then maps, then the shutdown timer | Per node, over what the node owns, then the cluster's own tick |
| Maps (`map.d`) | Cells of 66.67 yards, sight and broadcast by cell | A node holds the part of a map it owns plus an overlap band of replicas; cells are already the unit regions are made of |
| Visibility and updates (`objects.d`, `map.d`) | Create, values and out-of-range blocks per seeing player | Unchanged in form; replicas feed them, so a player near a border sees entities owned next door |
| Creatures (`creature.d`, `motion.d`) | Ticked by their map, spline movement | Ticked only by their owner; replicas follow the owner's splines, which already describe motion for a duration (cheap to replicate) |
| Global state (`context.d`, `online.d`, `group.d`, `channel.d`) | Online players by guid and name, groups, channels, one session per account | Cluster services on the coordinator (phase 2/5): they are not on the simulation hot path |
| Ids (`GuidCounters`) | Highest id in the database at start-up, then counting | Ranges leased from the coordinator (phase 2): two nodes must never hand out the same item or mail id |
| Persistence (`database.d`, `characterdb.d`) | The process saves what it has | Only the owner saves an entity, with its ownership epoch checked (phase 4) |
| Terrain, client data, world data | Loaded once, read-only | Loaded by every node; read-only, so nothing changes |

Combat, spells, creature AI, loot, quests, guilds and instances are not implemented yet, so they
cannot be broken by the cluster. They will be written against the cluster's rules from the start:
gameplay effects as idempotent events sent to the target's owner (phase 5).

## Architecture

### Nodes, the coordinator, and homes

Every node is a full world server process. One node, the **coordinator**, also keeps the cluster's
control state: membership, and from phase 2 on, which node owns which region (with leases and
epochs), id ranges, and the global services. Control traffic goes through it; gameplay traffic goes
directly between neighbouring nodes and never waits on it.

A single coordinator is a deliberate choice over gossip-only membership: single authoritative
ownership needs one source of truth that hands out leases with increasing epochs (fencing tokens),
and gossip cannot give that. The coordinator is off the hot path, so it is not a throughput
bottleneck; its failure is handled in phase 7 (members keep simulating what they own until their
leases run out; a standby takes over with an epoch higher than any it can have seen).

The node a client connects to is its **home** for the whole session: it holds the socket, the
header encryption, authentication and the character screen. In the world, the character is
simulated by whichever node owns the region it stands in. When home and owner differ, the home
forwards the client's packets to the owner and the owner's packets back. That is one extra hop on a
local network, paid only by players whose home is not their owner, and it is what lets the
character migrate without the client noticing. In standalone operation, home and owner are the same
process and the forwarding is a function call.

### Regions

The unit of ownership is the map **cell** (66.67 yards, `grid.d`), which maps already use for sight.
Each map is covered by a tree of rectangular regions of cells (a k-d tree: a region splits along its
longer side at the point that halves its *cost*, not its area). Each leaf region has one owning node,
a lease, and an epoch that increases whenever its owner changes. Regions split where load is high
and merge back where it is low (phase 6), so a busy city can be shared by several nodes while an
empty continent is held by one, which is the opposite of fixed zone servers.

Around each region is an **overlap band** as wide as the visibility distance plus the relocation
limit (100 + 10 yards, two cells): the neighbouring owners send replicas of everything in it. A
player standing at a border therefore already sees what lies beyond, and when an entity crosses,
the receiving node already holds an up-to-date replica of it.

The baseline (docs/BENCHMARKS.md) adds one rule: in a crowd the expensive part is the fan-out to
client sockets, which happens on each client's home node. A node therefore receives an entity's
updates **once** and fans them out to its own clients; traffic between nodes is per entity and
node, never per entity and client.

### Ownership and migration

Every entity has exactly one owner: `(node, region epoch, entity generation)`. Replicas are
read-only: they are drawn, and may be targeted, but never run gameplay logic. Migration (phase 4)
hands over at a line inside the overlap band, with hysteresis so an entity walking along a border
does not bounce:

1. The owner freezes the entity at a tick boundary, bumps its generation and sends its full state,
   with the sequence number of the last event it applied.
2. The receiver promotes its replica, applies the state and acknowledges.
3. The old owner turns its copy into a replica and forwards anything addressed to the entity to the
   new owner; messages carrying an older generation are dropped there.

Messages that change an entity carry its generation and a per-sender sequence number, so retries
after a reconnect are recognized and applied once. Delivery is not assumed to be exactly-once: links
resend unacknowledged messages after a reconnect, and receivers deduplicate.

### Communication between nodes

Persistent TCP connections, one per pair of nodes, on the same event loop as the clients:

* **Why TCP:** the nodes share a local network, so head-of-line blocking costs little. The ownership
  protocol needs reliable, ordered delivery anyway. TCP fits the existing loop and needs no
  dependencies. UDP would mean writing reliability that TCP already gives; QUIC would add a large
  dependency for features (streams over lossy links) that a datacentre does not need. This can be
  revisited if measurements show otherwise.
* **Frames:** a 16-byte header (length, type, flags, sequence number) and a binary payload,
  little-endian like the client protocol. Every message written during a tick is appended to the
  link's buffer and sent in one write: batching comes for free.
* **No allocations per message:** payloads are written into a buffer that each link reuses, and read
  in place from the receive buffer.

### Memory and GC

The prompt's concern is right, but the evidence must come first. Phase 0 adds measurements of tick
time (average, worst, 99th percentile) and GC behaviour (collections, pause times, bytes allocated
per tick) to the standalone server, logged every `metrics_interval_seconds`. Memory work then goes
where the numbers point. Cluster code is written to allocate nothing per message from the start,
because it is new and the cost of doing it right is low.

## Phases

Each phase is testable on its own and leaves standalone operation working.

0. **Measurement.** Tick, event loop and GC metrics, a load generator of headless clients
   (`loadgen`), and the standalone baseline (docs/BENCHMARKS.md). *Done.*
1. **Cluster foundation.** Node identity and incarnations, the cluster listener and outgoing links,
   framing, the hello handshake, heartbeats with round-trip times, membership views held by the
   coordinator, failure detection, rejoining, and fencing of stale incarnations. *Done.*
2. **Distributed world ownership.** The region tree, leases and epochs on the coordinator, id ranges,
   assigning regions to nodes, and only spawning and ticking what a node owns. *Done.*
3. **Replication.** The session split (home and owner), overlap bands, replicas, interest management
   between nodes, and players seeing across borders.
4. **Migration.** State transfer of creatures, then players; generations; resending and
   deduplication; ownership-checked saves.
5. **Distributed gameplay.** Chat, groups and whispers through cluster services, and cross-border
   interaction as events to the owner. Combat and spells are built on these rules when they are
   implemented.
6. **Load balancing.** Cost per region (measured tick time spent on it, packets, players), splits
   and merges with hysteresis and a cool-down.
7. **Fault tolerance.** Node and coordinator failure, lease expiry, recovery, and the benchmarks
   against standalone that decide whether the cluster is worth running.

## Phase 0: measurement

`dmangos.metrics` keeps `TickStats` (count, sum, maximum and a histogram of tick durations in a
fixed array, so recording one never allocates) and reads druntime's GC statistics
(`GC.profileStats`, `GC.stats`, `GC.allocatedInCurrentThread`). The world server records every tick
and, every `metrics_interval_seconds` (60 by default, 0 turns it off), logs one line:

```
metrics: 1200 ticks, avg 0.31 ms, p99 1.20 ms, max 4.10 ms; gc: 2 collections, max pause 0.84 ms,
total pause 1.30 ms, 412 KiB allocated (343 B/tick), heap 18.4 MiB used
```

## Phase 1: the cluster foundation

Configuration (`cluster` in `worldserver.json`; leaving it out keeps the server standalone and runs
none of this code):

```json
"cluster": {
    "node_id": 2,
    "name": "dmangos",
    "listen_address": "0.0.0.0",
    "listen_port": 9001,
    "advertise_address": "10.0.0.2",
    "coordinator": "10.0.0.1:9000",
    "heartbeat_ms": 500,
    "failure_timeout_ms": 3000
}
```

A node whose `coordinator` is its own advertised address and port is the coordinator.

* **Identity.** `node_id` is configured and unique in the cluster. Each start of the process gets an
  **incarnation**, a number larger than any earlier start's (milliseconds since the epoch). The
  coordinator admits a node id only with an incarnation at least as high as the one it knows:
  a restarted node replaces its earlier incarnation, which is fenced out, and a stale process that
  comes back later is refused.
* **Links.** `cluster/link.d`: a `NetSession` that frames messages, checks the hello, numbers what it
  sends, drops what it has already received from that incarnation, sends heartbeats and measures
  round trips. It closes when nothing has arrived for `failure_timeout_ms`.
* **Membership.** `cluster/membership.d`: the coordinator keeps the members and a view version that
  increases with every change, and sends each member the new view. Members connect to each other
  (the lower id dials the higher, so each pair has one link) and to the coordinator, and dial again
  after a link fails, backing off up to five seconds.
* **Until phase 2,** members do not open the client port or register the realm: two nodes serving
  the same characters without ownership would overwrite each other's saves. The coordinator serves
  clients as a standalone server does.

`cluster/node.d` ties these together and runs on the world tick. All of it is tested with links
wired back to back in memory and a fake clock (joining, views, heartbeats, timeouts, restarts and
fencing), and live with three processes.

### Tested live (three processes on one machine)

| Case | What happened |
|---|---|
| Start | All three linked to each other and agreed on view 3; round trips 0.04 to 0.18 ms |
| `kill -9` of a member | Left the view at once: the closed socket is noticed before any timeout |
| Restart of it | Rejoined with a new incarnation (view 5); the lower-id member dialed it again |
| `kill -STOP` of a member | Dropped after the 3 s timeout (view 6); the others closed their links to it as the view arrived |
| `kill -CONT` | Rejoined as the same incarnation (view 7) |
| A second process with a member's id | Took its place (view 8); the older process was refused as stale, reports itself fenced and stops dialing |

Idle, a node's tick took about 10 µs and allocated 29 to 55 bytes, most of it in the event loop
copying each link's output into a fresh pending buffer: a candidate for the memory work, once the
baseline under load shows whether it matters. A member keeps its incarnation when it comes back
from a hang, so from phase 2 on its region leases (with their epochs) are what stops it from
acting on regions it lost meanwhile.

## Phase 2: distributed world ownership

### Regions (`cluster/regions.d`)

At start-up the coordinator divides every map of `Map.dbc` into regions: rectangles of cells, the
leaves of a k-d tree. It splits the most expensive region at the median of its cost, across the
longer side of the box around that cost, until no region holds more than 1/`region_count` of the
world's cost. Cost, until phase 6 measures it, is the number of creature and game object spawns in
a cell: the benchmarks show that spread-out load is creatures ticking. With the default of 32, the
CMaNGOS world database gives 74 regions: 32 on the two continents of about 2,000 spawns each (from
the whole of the south of Stranglethorn to a few cells of Stormwind), and one per dungeon.
Partitioning is deterministic, and the coordinator logs every region with its cells and spawns.

Regions are dealt out longest-processing-time first (the most expensive to the least loaded node).
When a node joins, as few regions as it takes move to it until the busiest and idlest nodes are
within 20% of the mean load of each other (`rebalance`). Phase 6 makes both continuous and measured
(below).

### Ownership, epochs and leases (`cluster/ownership.d`)

* **One owner at a time.** A region moves in two steps: the coordinator marks it `revoking`; the
  owner stops simulating it and answers `RegionReleased` with the grant's epoch; only then does the
  coordinator grant it to the new owner. A release of another epoch is ignored.
* **Epochs** increase with every grant and are built as (coordinator incarnation << 20) + count, so
  a restarted coordinator's grants are newer than anything its predecessor gave. Phase 4 puts them on
  migrations and saves.
* **Leases.** A node may act on its regions only until `lease_ms` (5 s) after the last of its own
  heartbeats the coordinator echoed. A node cut off from the coordinator therefore stops by itself.
  The coordinator gives a lost node's regions away only after the lease and a 500 ms margin have
  passed since it last heard from it, so the two never overlap, with only clock rates (not clock
  readings) assumed to agree. A new coordinator grants nothing during its first lease, so its
  predecessor's grants have run out. A fenced node gets no more echoes, so it also stops.
* **Tables** are sent whole when they change (they are small) and kept only if newer; a table from a
  new coordinator incarnation replaces the old one and its lease starts afresh.

### In the world server

* `WorldContext.ownsCell` tells maps which cells are this node's. A map creates a cell's spawns only
  if the cell is owned. An object belongs to the cell it spawned in (its *home*) until objects can
  migrate (phase 4): a creature whose waypoints cross into another region is still simulated by its
  home's owner.
* When a region is lost, `Map.release` removes the objects whose home is in it, sends players who
  saw them an out-of-range block, and lets the cells load again if regained. When a region is gained,
  every player on the map looks around again, so the cells near them load (`Map.ownershipGained`).
* Because a map holds only what its node owns, the tick needs no ownership checks.
* Standalone, `ownsCell` is null and none of this runs.

### Ids

The coordinator hands out ids from its own counters (`WorldContext` implements `IdCounters`; group
ids come from the groups' own counter). A member asks for a block (`id_block`, 1000) of each kind and
for the next one when half is used (`IdPool`), so allocation never waits on the network. A member
reports the highest ids it holds whenever it links to the coordinator, and the coordinator grants
nothing during its first lease, so a restarted coordinator does not hand out a block a member still
has. Members do not create anything yet (they serve no clients until phase 3).

### Settings

`cluster.lease_ms` (5000; longer than `failure_timeout_ms`), `cluster.region_count` (32),
`cluster.id_block` (1000), and for phase 6 `cluster.balance_interval_seconds` (30),
`cluster.balance_min_load_us` (20000) and `cluster.region_cooldown_seconds` (120).

### Tested

* **Unit tests:** partitioning (every cell in one region, costs kept, deterministic); assignment and
  rebalancing; the authority (no grants in the first lease, revoke then release then grant, stale
  epochs ignored, a lost node's regions held for its lease); the view (lease expiry, revocations, a new
  coordinator); the id pool; maps (unowned cells do not spawn, release and regain). On an in-memory
  cluster with a fake clock: regions dealt out after the first lease, handed over when a node joins,
  and, with a node cut off from the network, **on every 50 ms tick no cell has two owners** while its
  lease runs out and its regions move.
* **Live, two processes:** the coordinator took the whole world after one lease. When node 2
  joined, 18 of the 74 regions (the south of the Eastern Kingdoms and most of Kalimdor) were revoked,
  released and granted to it within the same second; the loads were 42,859 and 37,453 spawns. A player
  on the coordinator in Duskwood (node 2's region 4) saw no creatures. After a `kill -9` of node 2, the
  coordinator took its regions back 5.5 s later (lease and margin), and the same player then received
  50 creatures. When node 2 joined again, the same 18 regions moved back, and the player received an
  out-of-range block for the Duskwood creatures.
* **Standalone:** idle and spread-out runs of 500 players (docs/BENCHMARKS.md) show the same tick
  and loop times as before within the measured variance (idle: tick 3.12 ms against 2.96 ms, busy
  6.6% against 6.3%), and less allocation (53 KB a tick against 67 KB, from phase 0's buffer work).

### Until phase 3

A player sees only what the node holding their connection owns: in a cluster, the coordinator's
players find the regions of other nodes empty, as the live test shows. Phase 3 brings replicas of
neighbouring regions and the home/owner split for players. Standalone servers are unaffected.

## Phase 3: replication (design)

Players stay simulated by the node holding their connection in phase 3, wherever they walk; a
player's simulation needs to move between nodes only once there is migration (phase 4), so the
session splits into a home half and an owner half then. Phase 3 is in two steps:

* **3a, replicas of creatures and game objects.** Every node tells every peer which cells its
  players can see (`InterestUpdate`: the 5 × 5 cells around each player, as additions and
  removals). A node sends a replica of everything it simulates in a cell some peer is interested in:
  its state when it enters the cell or the interest (`ReplicaCreate`), its changed fields
  (`ReplicaValues`), its walks (`ReplicaMove`, the client packet and the exact spline), and its end
  (`ReplicaRemove`). Interest from a peer also loads the cell on its owner, so a creature is
  simulated where it is owned even when only another node's player is near it. The receiving map
  keeps replicas with its own objects: its players see them as usual, and replicas follow their
  splines but run no AI. Traffic is per entity and node, never per entity and client.
* **3b, players on several nodes.** Members serve clients, one login per account across the
  cluster (the coordinator's session directory), and players replicated by the same interest so that
  players on different nodes see each other move.

Until phase 4, a region that changes owner makes its creatures disappear and appear again (fresh
from their spawn points); a creature replica and the real creature may briefly exist on one node
when grants and removals cross, so a spawned object replaces a replica with its guid and messages
for a guid that is no longer a replica are ignored.

## Phase 3a: replicas of creatures and game objects (implemented)

* **Interest** (`Map.updateInterest`, `takeInterest`): a map counts, per cell, its players within the
  visibility distance of it (the 5 × 5 cells around each), recomputed when a player's visibility is
  (every 10 yards, `visibility_relocation_lower_limit`). The changes go to every linked node each tick
  (`InterestUpdate`), and a node that links gets the whole interest (`ClusterBridge.peerLinked`).
  Standalone, none of this is computed.
* **Sending** (`Map.replicate`): an own object in a cell some peer wants is created on that peer
  (`encodeState`: the fields everyone may see, and its movement with the walk written exactly,
  `MoveSpline.writeExact`). Its changed public fields follow from `flushObjectChanges`, its walks from
  `sendToObservers` (the client packet, and the movement after it), and its end from leaving the
  peer's cells, the peer's interest, or the node (a released region). A peer's interest also loads the
  cell on its owner, so the owner simulates creatures only another node's player is near.
* **Receiving** (`Replica`, `Map.replicaCreated` and the like): a replica sits with the map's own
  objects, its players see it through the usual sight rules, and it follows its spline so its
  position and cell stay right, without AI. Messages are accepted only from the node that sent the
  replica. A replica of a node that is lost goes at once (`peerGone`).
* **Crossing messages:** when a region moves, the old owner's removals and the coordinator's grant come
  over different links. A spawned object replaces a replica with its guid (its viewers keep seeing it),
  and replica messages for a guid that is now this node's own are ignored.

### Tested

* **Unit tests:** state, movement and slot encoding (a walk is followed exactly on the replica);
  between two maps wired in memory: another node's player loads the owner's cell and sees the replica,
  then its changed fields and its walk, its removal when it runs out of the interest and when the owner
  is lost, and the interest shrinking when the player walks away.
* **Live, two nodes:** a player on the coordinator in Duskwood (node 2's region) saw 50 creatures and
  146 of their walks in 20 seconds, replicated from node 2, which had loaded 177 objects for it alone.
  Through a `kill -9` of node 2, its restart and the handovers, the player saw: the replicas; all 146
  of them go at once; after the 5 s lease the coordinator's own 50 creatures; 147 objects go when node
  2 rejoined and the region moved back; and node 2's replicas again.

### Cost (docs/BENCHMARKS.md)

With all 500 players on the coordinator and node 2 owning about half the world's spawns, the
coordinator's tick was 3.51 ms, as standalone (3.4 to 3.5 ms): it holds 24,447 objects, about half of
them replicas, and every object costs it about 143 ns a tick whether it is a creature or a replica.
Node 2 took 1.9 ms a tick for 13,600 objects. So the per-object cost is the map's bookkeeping, not
creature AI, and a cluster divides load only when players are divided between nodes and each holds
what its own players see (3b). Two improvements follow: iterate movers as an array rather than an
associative array, and keep replicas that are not walking out of the tick.

## Phase 3b: players on several nodes (implemented)

* **Every node serves clients.** Each advertises where clients reach it (`cluster.client_address`;
  127.0.0.1 and its world port by default), and every 10 seconds the coordinator points the realm's
  `realmlist.address` and `port` at the node with the fewest players (from the heartbeats' load
  reports), so new logins spread over the nodes with the CMaNGOS schema as it is. Only the coordinator
  speaks for the realm otherwise: it marks the realm online, updates its population and uptime, and
  marks characters offline at start.
* **One login per account** (`cluster/sessions.d`). A node claims every session it authenticates
  (`SessionClaim`, with its own serial number for it). The coordinator's directory grants an account
  to one session: a second claim evicts the holder (`SessionEvict`: it is kicked) and is granted only
  when the holder has released the account (`SessionReleased`), which a node sends when the session
  has ended, after its character was saved (saves are synchronous). A session may enter the world only
  once granted (`WorldSession.admit`; a `CMSG_PLAYER_LOGIN` waits for it), so no character is ever in
  the world on two nodes, and none is loaded before its last session's save. The accounts of a lost
  node are freed when its lease has run out. Claims made while the coordinator is unreachable are sent
  when it is back, and a node claims all its sessions again whenever it links to a coordinator.
* **Ids on members** come from the coordinator's blocks: new characters, items, mails and groups
  (`WorldContext.takeId`; a member without a block refuses to create a character, and stops a session
  rather than reuse an item or mail id).
* **Players replicated** by the same interest as creatures: a player in a cell another node wants is
  created there as a stranger sees it (`encodePlayerState`: health in percent), its moves and emotes
  (whatever its watchers get) and its field changes (`Map.playerChanged`, from `flushPlayerChanges`)
  follow, and it is removed when it leaves the cell, the map or the game. A player is still simulated
  by the node its client is connected to, wherever it walks: that changes with migration (phase 4).
* **Not across nodes yet** (phase 5): say, yell and text emotes (sent by range to local players),
  whispers and the who-is-online lists (each node's own players), groups, channels, trades and
  duels, and talking to an NPC another node simulates. A player sees and is seen everywhere, but
  interacts only with what its own node has.

### Tested

* **Unit tests:** the session directory (grant, evict, the newest waiting claim winning, lost nodes);
  across an in-memory cluster: a second login evicts the first and is granted only after its release,
  and a cut-off holder's account is freed only after its lease; a player login that waits for its
  grant, ignores another session's grant, and is kicked by an eviction and then releases; players on
  two maps seeing each other's replicas, moves (the very packet), changes (in percent) and departure.
* **Live, two nodes:** Alpha on node 2 and Gamma on node 1, 15 yards apart in Goldshire (the
  coordinator's region): each client saw the other player appear, Alpha's saw every one of Gamma's
  moves, and Alpha (on node 2) saw the 46 Goldshire creatures node 1 simulates. Alpha then logged in
  on node 1 while in the world on node 2: node 2 kicked and saved Alpha, and node 1's login entered
  the world after that, within the same second.
* **Load divided** (docs/BENCHMARKS.md): 500 players spread over the continents, 250 on each node:
  ticks of 1.55 and 1.81 ms, against 2.66 ms for all 500 on one server; each node held 18,600 and
  20,000 objects (its own and replicas) against 26,000. Together the two used about the CPU one server
  did: the replicas are the price of dividing the load.

## Phase 4a: objects migrate with their region; fenced writes (implemented)

* **Where a region goes.** A revoked region names its next owner (`Region.next`). Its owner writes
  every object homed in it (`Map.migrateOut`, `dmangos.world.migration`): a creature's every field, its
  movement and exact spline, its movement generator's timers and place on its path, and its vendor
  stock (`Creature.saveState`); a game object's fields. It keeps each one as a replica of the next
  owner's object, so its own players notice nothing, and lets its replicas elsewhere be replaced by the
  next owner's.
* **In order, through the coordinator.** The bundle goes with the release (`RegionReleased.objects`);
  the coordinator, granting the region, sends it to the new owner (`RegionHandover`) on the same link
  as, and ahead of, the table that grants it. The new owner rebuilds each object from its spawn and
  loads the state (`Map.migrateIn`, `WorldContext.restoreMigrant`), replacing replicas silently, before
  it lets anything load the region's cells afresh. Handovers are rare (rebalancing), so routing the
  state through the coordinator costs little and needs no protocol of its own.
* **The same spawns everywhere.** Pools, spawn groups and spawn entries are chosen with a seed made from
  the cluster's name and realm (`WorldData.load`), so every node agrees on which creature a spawn is.
* **A lost node's objects** are not migrated: its state died with it, and the new owner spawns afresh.
* **Fenced writes** (`dmangos.world.fencing`). A cluster node's `WorldDatabase` is wrapped so that
  while its lease has lapsed every write (every method returning nothing; generated from the interface)
  is dropped. A node whose lease lapses also ends every session; their logout saves are dropped and
  logged as not saved. Its accounts are given to other nodes only after that (phase 3b), so a node cut
  off from the coordinator can never overwrite a character that has since played elsewhere. Character
  creation and deletion wait for the account's grant too.

### Tested

* **Unit tests:** a creature's state saved and loaded into one made anew walks its waypoints in step
  with the original for 30 s, through a wait, sending the same packets; three maps, one region moving
  from the first to the second with a hurt creature in it while players on all three watch: no client
  gets a packet, the creature arrives hurt, and its next move reaches all three; a migrant that finds a
  fresh spawn of itself replaces it; the fenced database drops writes and keeps reads; the bundle
  reaches the joining node ahead of its grant in an in-memory cluster.
* **Live, two nodes:** with Gamma on the coordinator in Darkshire, node 2 joined and took 18 regions;
  region 4 (Duskwood) left with 176 objects in 71 KiB and arrived with 176. Gamma's client got no
  out-of-range and no create for them; their walks went on (233 moves). Freezing the coordinator
  (`kill -STOP`) with Alpha playing on node 2: 5 s later node 2's lease lapsed, it gave up its
  regions, kicked Alpha and refused the save (logged as not saved); when the coordinator resumed, node 2
  linked again and took its regions back under the same grants.
* **A bug the live test found:** the first version applied each region's bundle and then loaded the
  cells it gained, region by region, so loading one region's cells spawned afresh the objects of
  another region whose bundle came next; the migrated state was dropped and creatures were in effect
  respawned (silently, so the client test alone did not show it). All bundles are now applied first,
  and a migrant also replaces a fresh spawn of itself.

### Not yet

* **Players** still stay with the node their client is connected to. Moving a player's simulation to
  the node that owns the region it walks into (the home and owner split) is phase 4b.
* ~~A node shutting down cleanly is treated like one that failed~~: it drains first (phase 5b,
  below).

## Phase 4b: players move between nodes (implemented)

* **Home and owner.** The node a client connects to stays its *home*: it holds the socket and the
  header encryption. The player is simulated by whichever node owns the ground it stands on, its
  *owner*. On the owner the player has an ordinary `WorldSession` that has no socket
  (`WorldSession(context, account, home)`): what it sends goes home as (opcode, body)
  (`PlayerMessage.toHome`) and the home encrypts it for the client; what the client sends, the home
  passes on unread (`toOwner`) while its own session is `WorldState.elsewhere`. Every in-world handler
  runs unchanged on the owner.
* **When.** Once a second (the zone check) a player checks whose ground it stands on
  (`migrationTarget`): it moves when the ground 25 yards around it in all four directions is one other
  node's (so walking along a border does not bounce it), not within 10 seconds of its last move, and
  not while teleporting or logging out. Away from home it goes straight on to a third node.
* **How** (`migrateTo`, `arrive`). The simulating node saves the character (saves are synchronous) and
  sends the account, the guid, the movement, and every guid the client has (`Map.knownTo`). It takes
  the player off its map without a destroy packet: players there who saw it see a replica owned by the
  next node (`Map.removeForMigration`). The next node loads the character through the login code but
  sends none of the login packets, and puts it on its map knowing what its client has
  (`Map.addMigrated`): in sight and known is just marked seen, in sight and new is created, known but
  out of sight goes out of range, and known but not held here yet *lingers*: its replica, when it
  comes, is adopted without a create block, and whatever has not come in 5 s goes out of range.
  Players there who saw its replica now see it as itself.
* **Leaving.** A logout or disconnect on the owner saves there and tells the home (`left`); a client
  that disconnects at home is passed on (`disconnect`), and the home releases the account (phase 3b)
  only when the owner says it has saved. If the owner is lost, the home disconnects the client and
  releases the account after the owner's lease; if the home is lost, the owner logs the player out,
  saved (before the coordinator frees the account, at the home's lease).

### Tested

* **Unit tests:** between two maps with players on both, a handover that sends nothing to anyone (the
  migrating client, a watcher on each node), then a lingering object adopted without a create, and
  the player's next move reaching both watchers; two sessions joined in memory: the zone check moves a
  logged-in player to the other node, the client's packets are handled there and its answers come back
  encrypted for it, and a logout there returns the home session to the character screen.
* **Live, two nodes:**
  * Gamma, connected to node 1, teleported into Duskwood (node 2's): node 2 took it over; `.gps` was
    answered from node 2 through node 1; teleported back, it moved home after its 10 s, and logged out
    at home, saved.
  * Walking from Elwynn into Duskwood in 10-yard steps, it moved to node 2 at x = -9560 (the border is
    at -9533.3, the margin 25 yards). Over the whole session the client got 123 create blocks, none for
    an object it already had, and 106 out-of-range, none for one it did not have.
  * The client vanished while Gamma was on node 2: node 2 saved it, and a login straight after found
    it where node 2 had saved it. Node 2 killed while simulating Gamma: node 1 disconnected the client
    the same second, and a login after the lease brought Gamma back as saved at the handover.

### Not yet

* ~~One owner at a time: a player away from home goes back home before going on to a third node~~:
  it goes straight there (below).
* **Carried over:** the character as saved, its movement and what its client has. Not carried: timers
  that only shape timing (regeneration, rest, flood protection), `.gm allowwhispers` targets and
  `.cheat triggerpass`, which start afresh on the new node.
* **Across nodes** (phase 5): chat, whispers, groups, channels and GM commands that find players by
  name see only the players their node simulates.
* **Cost:** every packet of a player away from home crosses one more link; not yet benchmarked.

## Phase 5a: speech, whispers and NPCs across nodes (implemented)

Since phase 4b, players standing together are simulated by the same node, so most interaction is
local; what crosses nodes is what happens near a region border, and whispers.

* **Range packets** (say, yell, text emotes, and anything else `Map.sendInRange` sends): delivered to
  the node's own players in range, and sent (`InRange`) to every node interested in a cell within the
  range, which delivers it to its own players in range (`Map.deliverInRange`). Each node delivers only
  to the players it simulates, so nobody hears anything twice. Emotes and moves already reach other
  nodes with the replicas (phase 3).
* **Presence** (`ClusterBridge.sendPresence`, `WorldContext.presence`): once a second every node tells
  the others what changed of the players it simulates (name, race, class, level, gender, zone, the GM
  tag, away and busy with their message, whether it has GM permissions), and a node that links gets
  them all. A lost node's players are forgotten with it.
* **Whispers** (`dmangos.world.whisper`) are checked and delivered where the receiver is simulated:
  a whisper to another node's player goes there (`Whisper`, with the sender's guid, race, permissions
  and chat tag), which runs the same `deliverWhisper` as for a local one (the GM tag against its own
  `.gm allowwhispers` list, factions) and sends the sender's copy, the away or busy reply or the
  refusal back (`DeliverTo`).
* **The who list** (`CMSG_WHO`, `whoList`, CMaNGOS's `HandleWhoOpcode`) lists the node's own players
  and those presence reports, with CMaNGOS's filters: the viewer's team unless
  `allow_two_side_who_list`, no account above `gm_level_in_who_list` for players (presence carries the
  account level), the level range, class and race masks, zones, and name, guild and zone-name parts.
  At most 49 are shown, the count capped by `max_who_list_returns`. Nobody is in a guild yet.
* **NPC services** (gossip, trainers, vendors, innkeepers, bankers, repairs) take a `Npc`: a creature,
  or for a replica of another node's creature an `NpcStandIn` with the replica's fields and position
  and the template every node shares. All the player's side (money, items, spells, its bind point)
  is on the player's node, where it belongs. Limited vendor stock is the creature's, counted on its
  node: buying a limited item from a stand-in first reserves it there (`StockRequest`, answered with
  `StockReply` and what is left), the purchase goes on when the answer comes, and stock reserved for
  a purchase that then fails (bags full, not enough money) goes back (`StockRelease`).

### Tested

* **Unit tests:** a say heard by a player in range on another node and not by one out of range; a
  whisper to a player another node simulates going to that node, with the sender's copy and the away
  reply, and "player not found" for a name nobody has and once its node is lost; a whisper from
  another node to a GM with its tag on refused there unless the GM allowed it; a replica of a vendor
  served through a stand-in with its template, spawn and flags, one stand-in per creature; limited
  stock of another node's vendor reserved there, refused when sold out, and given back when the
  purchase fails; the who list's filters and caps.
* **Live, two nodes:** Gamma on node 1 and Alpha on node 2, 60 yards apart across the Elwynn and
  Duskwood border: Alpha heard Gamma's yell and not Gamma's say (beyond its 25 yards), and Gamma got
  Alpha's whisper.

### Still on one node (phase 5b)

Trades and duels (not implemented at all yet), and GM commands that find players by name (now
phase 5b).

## Phase 5b: cluster services

What belongs to no place and to players anywhere is kept in one place: the coordinator. Other nodes
send it their players' commands, and it sends what it has to tell a player to the node simulating it
(`DeliverTo`, found by presence). Standalone, the same service runs in the one server.

### Chat channels (implemented)

* `ChannelService` (`dmangos.world.channelservice`) holds every channel. Each channel command a
  player gives (joining, leaving, talking, the list, passwords, moderation, kicks, bans, invitations,
  and logging out and changing zone, which leave or move zone channels) is a `ChannelCommand`
  carrying what the channels need of the player: guid, name, race, chat tag and ArcEmu's `c`
  permission. The checks that are the player's node's (names, the GM client channel) stay there.
* Channels see players as `ChannelMember`s; a member's messages go to its node, the one presence
  says simulates it, or failing that the one its last command came from. A target named in a command
  is found among the coordinator's players or through presence.
* A lost node's players leave their channels, as if they had logged out.
* **Not yet:** a new coordinator (phase 7) starts with no channels; players rejoin when they next
  log in or change zone. A message sent to a member in the second between its moving to another
  node and presence saying so is lost.
* **Tested:** a unit test with a player on the coordinator and one on another node joining one
  channel, talking, being made moderator by name, and leaving with its lost node; live, Alpha on
  node 2 and Gamma on the coordinator in one channel: both heard each other, the list showed both,
  and Alpha was told when Gamma logged out.

### Groups (implemented)

* **One place changes groups:** the coordinator's `Groups`, loaded from and saved to `groups` and
  `group_member` as before; no other node writes them, and none needs group ids any more. What
  changes a group (invitations, accepting and declining, kicks, the leader, leaving and disbanding,
  loot settings, target icons, raids, sub-groups, assistants, and logging out) is a `GroupCommand`
  that `GroupService` (`dmangos.world.groupservice`, CMaNGOS's `GroupHandler` rules) runs there,
  with what the rules need of the player: guid, name, race and whether it has GM permissions.
* **Every other node mirrors the groups** (`Groups.mirror`): the coordinator sends a group's whole
  state (`GroupState`: members, sub-groups, assistants, leader, loot, icons) after each change, its
  removal when disbanded, and all of them to a node that links. What only reads a group is decided
  on the player's node with its mirror: who sees whose health (group mates see more), party, raid
  and raid-warning chat, member stats, ready checks, rolls, minimap pings, the icon list. When a
  mirror changes, its players there see their mates anew, and a newcomer's stats go out.
* **Telling members** (`GroupDirectory`, the context): a packet for a member goes to its node,
  found by presence, or for a few seconds after a command by the node the command came from (a
  player who just logged in is in no presence report yet). A member's status in the list (online,
  away, busy) comes from presence for another node's player. `CMSG_REQUEST_PARTY_MEMBER_STATS` for
  a member another node simulates is answered by that node (`MemberStatsRequest`).
* **Not yet:** a new coordinator (phase 7) reloads groups from the database but loses invitations
  in flight; nodes keep their mirrors until it sends its own.
* **Tested:** a unit test with Anduin on the coordinator inviting Jaina of node 2, the group
  created when she accepts, the lists going to both, node 2's mirror making them group mates there
  and sending her stats to node 1, party chat from node 2 reaching node 1, and the mirror forgetting
  the disbanded group; every standalone group test runs through the service. Live: node 2's mirror
  gave Alpha its saved raid at login and the coordinator refused Alpha's invitation (not the
  leader), as CMaNGOS does; then Alpha on node 2 invited Gamma on the coordinator, both got the
  list, party chat crossed both ways, and Alpha's leaving disbanded the party for both.

### GM commands and world texts (implemented)

* **World texts** (`World::SendWorldText`, `SendGMWorldText`, `SendWorldWideScreenText`: `.announce`,
  `.wannounce`, kick and ban notices, and the rest) reach every node's players (`ToEveryone`, with
  the `u` permission filter for GM texts).
* **Commands that name a player** another node simulates are sent there (`GmRemote`): `.kickplayer`,
  `.summon`, `.appear`, `.playerinfo`, `.kill` by name, `.ban character` (the account is banned where
  the GM is; the player is kicked where it is) and `.rename` (the database renamed where the GM is;
  the player renamed where it is). What each does to its player is a method of the player's session
  (`dmangos.world.gmtargets`), the same one a GM on the player's node uses, with a `GmSink` for the
  GM's messages, which go back to the GM's node. `.appear` sends the player's place back
  (`appearAt`) and the GM teleports there. `.gm allowwhispers` and `.gm blockwhispers` find the
  player through presence, and `.gm list` and `.info` count the GMs and players presence reports
  (presence carries each GM's permission letters).
* **Every node:** `.server saveall` and `.admin masssummon` go to every other node presence knows
  (`GmRemoteOp.saveAll`, `massSummon`, run there for each of its players; the count includes theirs).
  A player that moves carries its client's address and build, so `.playerinfo` shows them wherever
  it is simulated.
* **Tested:** a unit test with `.summon` and `.kickplayer` naming a player of node 2 (the command
  sent there with the GM's place), `.gm list` naming node 2's GM, and on the target's node a summons,
  an appear sending the place back, and a kick whose notice goes to every node. Live: Gamma on the
  coordinator ran `.playerinfo Alpha` (answered by node 2, where Alpha played in Kalimdor) and
  `.appear Alpha`: Gamma went to Kalimdor and moved to node 2; `.summon` of a player simulated by
  the coordinator brought it, and `.gm list` listed Gamma.

### A third node, and a clean shutdown (implemented)

* **Straight to a third node.** A player simulated away from its home that walks onto a third node's
  ground moves there directly: its state names its home (the node holding its client), the new
  owner makes its session for that home, and the old owner tells the home (`PlayerMessage.moved`),
  which sends the client's packets there from then on. Packets the client sent before its home heard
  are passed on by the old owner for a few seconds; a home that hears from a new owner before the
  old one's word takes it as the owner. One handover and one save instead of two.
* **A drain.** A member stopped cleanly (SIGTERM, SIGINT, `.server shutdown`) does not stop at once:
  it sends the coordinator `Drain`, which revokes each of its regions toward the member that carries
  least (`RegionAuthority.drain`) and gives it none from then on. Its regions go with their objects,
  as when the load is balanced; the players it simulates for other nodes' clients move on at once
  (no margin, no cool-down), and the players whose clients it holds stay and are logged out, saved,
  when it stops. It stops when it owns nothing and has no visitors, or after 20 seconds whatever is
  left. The coordinator itself does not drain (phase 7).
* **Tested:** unit tests with three nodes in memory (a player handed from node 2 straight to node 3,
  its home following, the client's packets going to node 3 and its answers coming back, then home
  from node 3), and the authority draining a node toward the others and never granting it again.
  Live: Gamma, connected to node 1, played in Durotar, which node 2 simulated; node 2 got SIGTERM,
  handed over its 32 regions (Durotar's with 102 objects), Gamma moved home, and node 2 stopped
  1 second after the signal; Gamma's client noticed nothing (`.gps` and a say worked after).

### Trades and duels (design)

Neither exists yet, even on one server. When they are written: both need the two players simulated
together (trade windows and duel combat change both players at once, and a node may only change
what it simulates). Two players near enough to trade or duel usually are on the same node already
(phase 4b moves a player to the owner of its ground); when they are not (within the 25-yard
hysteresis of a border), the one who asked moves to the other's node before the trade or duel
starts, through the same migration, and stays there until it ends.

## Phase 6: load balancing by measured cost (implemented, without splits)

* **Measured.** Every 10 seconds each node divides the loop's busy time (packets, tick and sending,
  `TcpServer.busyTotal`) among the regions it owns, by what each holds now (`Map.weighCells`): an
  object in the tick weighs 10, a resting one 1, a player 100 (a player's packets and what it sees
  cost far more than a creature). The result, µs of loop time a second per region, goes to the
  coordinator (`RegionLoads`), which keeps each region's cost as the mean of its last value and the
  new one. The first report replaces the spawn counts of phase 2 everywhere; a region nobody
  reports costs nothing, as nothing of it is loaded.
* **Balanced with hysteresis** (`RegionAuthority.balanceMeasured`): every `balance_interval_seconds`
  (30) the coordinator moves regions from the busiest node to the idlest while the gap is over a
  quarter of the mean, only when the busiest takes at least `balance_min_load_us` (20,000: 2% of a
  core), at most two regions a look, each only if it narrows the gap (at most half the gap), and
  never one that moved in the last `region_cooldown_seconds` (120): no region goes back and forth.
  A move is the handover of phase 4 (revoke, release with the objects, grant); players move with
  their ground (phase 4b).
* **Not yet: splits and merges.** The regions are still the leaves of the start-up partition. A
  crowd in one region is that region's node's to carry; balancing moves the node's other regions
  away, which is what lets it. Splitting a hot region (a new cut through its k-d leaf, two new
  region ids, both handed over like any move) and merging cold neighbours are the next step.
* **Tested:** unit tests for the threshold, the cap of two moves, the cool-down and the smoothing.
  Live, two nodes on one machine: 300 bots spread over both continents measured 19 and 24 ms/s,
  within the tolerance, and nothing moved; with 250 more crowded in Goldshire the two measured 176
  and 132 ms/s, and the coordinator moved one region of 21 ms/s (to 155 and 153); a minute later,
  at 181 and 135, another of 19 ms/s. Every bot stayed in the world (ping p99 17 ms spread out, 28
  ms in the crowd).

## Phase 7: the standby coordinator (implemented)

When the coordinator dies, everything it keeps is needed within a lease: without lease
confirmations every member stops writing and ends its sessions after `lease_ms`. So a member can be
the **standby** (`cluster.standby`): it computes the coordinator's start-up partition and costs too,
and like every member it has the latest region table.

* **Taking over** (`ClusterNode.promote`): when the standby has had no link to the coordinator for
  half a second after losing it (`standbyGrace`; the link itself closes at once if the process
  died, after `failure_timeout_ms` if it hangs), it becomes the coordinator. It adopts the table it
  has (`RegionAuthority.adopt`): every grant stands with its epoch, so no member loses or reloads a
  region, regions on their way somewhere still go there, new epochs start above every epoch in the
  table, and the old coordinator's regions are held until its lease is surely over, then dealt out
  (spawned afresh, as after any failure). The view and table versions go on from the old ones. As
  after any start, nothing new is granted, and no ids, for a lease: grants and blocks the old
  coordinator made that the standby never heard of have lapsed or been reported by then.
* **Members follow it** (`Takeover`, sent again each second until accepted): a member takes the
  standby as its coordinator once it has lost the old one itself (while its own link to the old one
  is alive, it waits). The standby's heartbeats on the link they already have renew its lease at
  once; it re-claims its sessions and reports its ids, as to any new coordinator, and from then on
  dials the new coordinator's address. Heartbeats every 500 ms, a failure timeout of 3 s and a lease
  of 5 s leave about a second and a half to spare.
* **The world server's part** (`onPromoted`): the groups are loaded from the database (the old
  coordinator saved every change) and sent to every mirror; channels are kept here from now on,
  starting empty; ids come from this node's counters, raised to what the database holds and what
  members report; and the node speaks for the realm (its row, and steering new clients).
* **Not yet:** there is one standby, and none after a takeover until one is configured. Without a
  quorum, a coordinator that is alive but cut off from the standby (while the members still reach
  it) is not told apart from a dead one; run the two where that cannot happen (one machine, one
  switch), or add a third voter. The old coordinator must come back as a member of the new one (its
  `coordinator` pointing there). Players whose client was connected to the old coordinator lose
  their connection and log in again (the realm list now sends them to a live node); channels, and
  invitations in flight, are gone.
* **Tested:** a unit test with three nodes in memory: the coordinator dies, the standby takes over
  within the failure timeout, the member follows; neither node's lease lapses at any 50 ms tick,
  neither loses a region; both have the same view; the dead coordinator's regions are dealt out
  after its lease; the member's id blocks come from the new coordinator's counters. Live, two
  nodes: Alpha playing on node 2 (the standby) in Durotar; `kill -9` of the coordinator; node 2 took
  over 3 seconds later with its lease holding, Alpha stayed in the world and was heard after it,
  node 2 took all 74 regions once the old lease was over, and Gamma logged in through node 2
  afterwards, its session granted by the new coordinator.


## Phase 8: combat across nodes (implemented, first part)

Combat came after the cluster, and keeps its rule: a node changes only what it simulates. A
creature's fight, its threat, its loot and its corpse are on the node that simulates it, so the
player goes there.

* **An action at a replica** (`actAtReplica`): attacking another node's creature, casting at it, or
  looting its corpse moves the player's simulation to that node at once (`migrateTo`, whatever the
  ground and however recent its last move), with what it asked for (`ArrivalAction`: the attack,
  the spell and its target, the corpse). The state carries it just before the home node, which
  stays last; the next node does it at the player's first tick there, once the move is complete
  everywhere (`performArrivalAction`). The client sees nothing of the move: its swing simply begins.
* **A fight stays put:** a player in combat does not move (`migrationTarget`), so a chase across a
  region border keeps the player with the creatures it fights; once out of combat (5 seconds after
  its last swing, or when they evade) the ground decides again. A draining node still sends its
  players on.
* **Auras travel:** they are saved before a move and loaded on arrival, as the rest of the character;
  so do quests and reputation.
* **Game objects:** using another node's game object (its replica here), or casting at one (a lock
  to open, an herb to pick), moves the player to that node first, as attacking does
  (`ArrivalAction.useObject`, `castObject`), and the object is used there.
* **Auctions** need no owner node: the `auction` table is their one place, and every change to a
  row is guarded by what was seen of it (README's "Auctions"); the coordinator settles those over.
* **Flights** stay on the node they start on until they land: the server follows the flight there,
  and the first move after landing moves the player on if the ground is another node's.
* **Scripts and summons** run on the node of the map cell where they started (`dbscripts.d` keeps
  them in the node's context); a summoned creature's guid comes from its node's own range, so two
  nodes never make the same one. A summon is not handed over with its cell: it is dropped there.
* **Not yet:** a creature does not notice (aggro on) a player another node simulates, nor does it
  answer a call for help from another node's creature; group experience and loot rights count only
  the members on the creature's node; a player's own spells at another node's player (there is no
  PvP yet).
* **Tested:** a unit test with two nodes in memory: node 1 holds a replica of node 2's innkeeper
  made an enemy; attacking it moves the player to node 2, where the attack begins and the creature
  fights; on node 1's ground, the player stays on node 2 while fighting. Live, two nodes, after
  combat, spells, auras, loot and quests were added: Gamma, connected to node 1, logged in in
  Durotar (node 2's) and moved there within the second; it fought a boar there, its swings and the
  boar's shown through node 1, until a Razor Hill guard joined in against the Alliance character
  and killed it on node 2 (death, release on logout, the save); no errors on either node. At the
  Elwynn border both sides were node 1's in this run's partition, so the attack on a replica was
  tested in memory only.
