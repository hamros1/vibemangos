# Clustering

How several world server processes simulate one continuous world together. Each process is a
**node**. The world is divided into **regions**, each owned by one node under a lease. Nodes send each
other replicas of what lies near their borders, players and creatures move between nodes with the
ground they stand on, and the client sees one server throughout.

A world server without a `cluster` object in its configuration is **standalone**: none of this code
runs, and every rule below collapses into ordinary function calls inside one process.

The code is `source/dmangos/cluster/` (membership, links, the message protocol, regions, ownership,
the session directory, services) and, on the world server's side, `world/clusterbridge.d`
(replication and player relay), `world/replication.d`, `world/migration.d`, `world/fencing.d`, and
the cluster wiring in `world/main.d` and `world/context.d`.

## What the client allows

These constraints decide more of the design than anything else.

* **One connection, one endpoint.** A 1.12 client keeps a single TCP connection to the world server
  it was given by the realm list, with header encryption keyed by the session key. It cannot be told
  to move to another address without logging out. So the node holding a client's socket cannot change
  during play, while the node simulating its character must be able to.
* **No loading screen within a map.** Crossing between nodes must not involve `SMSG_NEW_WORLD` or
  `SMSG_TRANSFER_PENDING`, which show one. The client must keep receiving the same update packets,
  for the same guids, as if one server sent them.
* **The client does not know about nodes.** Guids stay the same wherever an object is simulated.

## Roles

Every node runs the same program, the world server, and loads the same static data (client data,
terrain, world database). Roles are a matter of configuration:

| Role | What it does |
|---|---|
| **Coordinator** | A node whose `coordinator` setting is its own advertised address. Besides simulating its share of the world, it admits members and keeps the membership view; divides the world into regions, grants them under leases and balances them; hands out id blocks; keeps the session directory (one login per account); holds the groups; speaks for the realm in `realmlist`; and points new clients at a node. Control traffic goes through it; gameplay traffic goes directly between nodes and never waits on it. |
| **Member** | Simulates the regions it is granted and serves clients. |
| **Standby** | A member (`cluster.standby`) that also keeps what a coordinator needs, and becomes the coordinator when the coordinator is lost. |
| **Gateway** | A member (`cluster.gateway`) that holds client connections and simulates nothing: it is granted no regions and no services. Neither the coordinator nor the standby can be one. |

Every node serves clients. The node a client connects to is that client's **home** for the whole
session: it holds the socket, the header encryption, authentication and the character screen. In the
world, the character is simulated by whichever node owns the region it stands in, its **owner**.
When home and owner differ, the home relays the client's packets to the owner and the owner's
packets back.

## Configuration

The [setup guide](SETUP.md) installs a two-node cluster with one realm (ID 1).
Use the settings below to add nodes, change endpoints, or configure failover.

The `cluster` object of `worldserver.json` (`cluster/config.d`):

```json
"cluster": {
    "node_id": 2,
    "name": "dmangos",
    "listen_address": "0.0.0.0",
    "listen_port": 9001,
    "advertise_address": "10.0.0.2",
    "client_address": "10.0.0.2:8085",
    "coordinator": "10.0.0.1:9000",
    "heartbeat_ms": 500,
    "failure_timeout_ms": 3000
}
```

| Key | Meaning | Default |
|---|---|---|
| `node_id` | This node's id, unique in the cluster; 0 means standalone | `0` |
| `name` | The cluster's name; nodes of another cluster are refused | `"dmangos"` |
| `listen_address`, `listen_port` | Where other nodes connect to this one | `0.0.0.0`, `9000` |
| `advertise_address` | The address other nodes reach this one at | `127.0.0.1` |
| `client_address` | `host:port` clients reach this node's world port at; empty for 127.0.0.1 and the world port | empty |
| `coordinator` | The coordinator's `host:port`; a node whose own advertised address this is, is the coordinator | `127.0.0.1:9000` |
| `heartbeat_ms` | How often each link sends a heartbeat | `500` |
| `failure_timeout_ms` | A link that hears nothing for this long is dead; at least three heartbeats | `3000` |
| `lease_ms` | How long a node may act on its regions without hearing from the coordinator; longer than the failure timeout | `5000` |
| `region_count` | How finely the coordinator divides the world at start-up | `32` |
| `id_block` | How many ids of a kind a member takes from the coordinator at a time | `1000` |
| `balance_interval_seconds` | How often the coordinator looks at the load | `30` |
| `balance_min_load_us` | How busy (µs of loop time per second) the busiest node must be before anything moves | `20000` |
| `region_cooldown_seconds` | How long a region that moved or was split stays put | `120` |
| `standby` | This member is the standby coordinator | `false` |
| `gateway` | This member is a gateway | `false` |
| `voters` | The fixed list of voting nodes for quorum mode, identical on every node | empty |
| `vote_file` | Durable path for this voter's election term and vote | required on voters |

A node in a cluster writes its write-ahead log to `writes-<node_id>.log` unless `write_log` says
otherwise.

## Nodes and membership

* **Identity.** `node_id` is configured. Each start of the process gets an **incarnation**, the
  milliseconds since the epoch at start, so a later start always has a higher one. The coordinator
  admits a node id only with an incarnation at least as high as the one it knows: a restarted node
  replaces its earlier incarnation, which is fenced out, and a stale process that comes back later is
  refused (`staleIncarnation`).
* **The handshake.** The dialing side sends `Hello` (protocol version, cluster name, node id,
  incarnation, its cluster and client addresses, whether it is a gateway); the other side checks it
  and answers with its own or with a `Reject` giving the reason: another cluster, another protocol
  version, a stale incarnation, a duplicate node id, not the node that was dialed, or a member the
  coordinator has not admitted.
* **The view.** The coordinator keeps the members and a view version that increases with every
  change, and sends every member each new view. Members connect to each other (the lower id dials the
  higher, so each pair has one link) and to the coordinator. A link that fails is dialed again, backing
  off from 250 ms up to five seconds.
* **Failure detection.** A link closes when nothing has arrived on it for `failure_timeout_ms`; a
  process that dies closes its sockets, which is noticed at once. The coordinator drops a member whose
  link has closed, and the new view tells the others.

`cluster/node.d` (`ClusterNode`) ties membership, links, regions, ids and sessions together and runs
on the world tick.

## Links and messages

Nodes talk over persistent TCP connections, one per pair of nodes, on the same event loop as the
clients (`net/server.d`). A link (`cluster/link.d`) is a `NetSession` like a client's: no thread and
no lock of its own.

* **Why TCP.** The nodes share a local network, so head-of-line blocking costs little, and the
  ownership protocol needs reliable, ordered delivery anyway. TCP fits the existing loop and needs no
  dependencies.
* **Frames** (`cluster/protocol.d`): a 16-byte header (payload length, message type, flags, sequence
  number) and a binary payload, little-endian like the client protocol. Payloads are plain structs
  serialized by `dmangos.serialization`. A payload over 16 MiB is refused.
* **Batching and allocation.** Messages are written straight into the link's output buffer, which the
  event loop sends in one write: everything sent to a peer during a tick goes out together. Input is
  parsed in place, so a message made only of numbers, such as a heartbeat, costs no allocation either
  way.
* **Order, duplicates and delivery.** Each direction of a link is a FIFO.
  * **Numbering.** Every message carries a sequence number per sender incarnation and receiver. The
    numbers are kept across reconnects to the same incarnation of a peer, so a message received twice
    is recognized and dropped.
  * **Retention.** The sender keeps each message (`PeerSequences`) until the peer acknowledges it.
  * **After a reconnect:** both sides send a heartbeat at once. New messages wait until the peer's
    acknowledgement arrives, then everything after it is sent again, in order, before them.
  * **A peer that restarted** (a new incarnation) starts afresh.
  * **Limits and losses.** Past 64 MiB unacknowledged, the oldest messages are given up and the loss is
    logged. A receiver that sees a sequence number skip logs it and counts it as a gap.
  * **Features' own resends** (session claims, service calls, script signals, takeovers) remain, and
    receivers deduplicate them.
* **Heartbeats** go out on every link each `heartbeat_ms`. They carry no sequence number and are never
  resent. Each one:
  * measures the round trip;
  * carries the sender's load (tick time, players, objects);
  * acknowledges the highest sequence number the sender has received.

  Those sent to the coordinator are echoed, which is what renews a node's lease.
* **Protocol version.** `protocolVersion` changes whenever a message changes. Nodes speaking
  another version are refused at the handshake, so a cluster runs one build throughout. The compiler
  enforces it: a fingerprint of every message's layout (including nested fields, length prefixes, and enum values) is
  recorded with the version, and a message changed without both being updated does not compile. It
  also checks that every message type has exactly one struct and that the types are contiguous.
* **Enum fields.** A field typed as an enum (a group, channel or GM operation, a service status)
  accepts only that enum's members: any other value makes the frame malformed.

The cluster messages include:

| Group | Messages |
|---|---|
| Membership | `Hello`, `Reject`, `Heartbeat`, `View` |
| Ownership | `RegionTable`, `RegionReleased`, `RegionHandover`, `RegionLoads`, `Drain`, `Takeover`, `TakeoverAccepted` |
| Ids | `IdRequest`, `IdGrant`, `IdReport` |
| Sessions | `SessionClaim`, `SessionGrant`, `SessionEvict`, `SessionReleased`, `SessionRoute` |
| Replication | `InterestUpdate`, `ReplicaCreate`, `ReplicaValues`, `ReplicaMove`, `ReplicaRemove`, `InRange` |
| Players | `PlayerMessage` (to the owner, to the home, arrival, departure, a move to a third node), `Presence`, `DeliverTo`, `Whisper` |
| Gameplay across nodes | `StockRequest`, `StockReply`, `StockRelease`, `GroupCommand`, `GroupState`, `MemberStatsRequest`, `ToEveryone`, `GmRemote`, `KillShare`, `GroupLootRoll`, `LootCoinShare`, `QuestLootCheck`, `PartyHeal`, `AreaDamage`, `CreatureSwing`, `PeriodicResult`, `ScriptSignal`, `DungeonEntryRequest`, `DungeonEntryReply`, `FriendStatusChange`, `GuildReload`, `GuildBroadcast`, `GuildInvitation` |
| Services | `ServiceCall`, `ServiceReply` (docs/SERVICES.md) |

On the world server's side, `ClusterBridge` implements the handlers `ClusterNode` calls, and
`world/main.d` connects `WorldContext`'s cluster hooks (`whisperRemote`, `deliverRemote`,
`gmRemote`, `killShareElsewhere`, `signalElsewhere`, `askDungeonEntry`, `reserveStock`, the guild
and friend hooks and so on) to the bridge. Standalone, those hooks are null and the context handles
everything locally.

## Regions

The unit of ownership is the map **cell** (66.67 yards, `grid.d`), which maps already use for sight.

* **Partition** (`cluster/regions.d`). At start-up the coordinator divides every map of `Map.dbc` into
  regions: rectangles of cells, the leaves of a k-d tree. It splits the most expensive region at the
  median of its cost, across the longer side of the box around that cost, until no region holds more
  than 1/`region_count` of the world's cost. The start-up cost of a cell is the number of creature and
  game object spawns in it. With the default of 32 and the standard world database this gives 74
  world regions: 32 on the two continents, and one for each other map. The partition is
  deterministic, and the coordinator logs every region with its cells and spawns.
* **Whole maps.** A dungeon or battleground map is never cut and never split: it is one region, and
  the node owning it hosts every copy of it.
* **Service regions.** Each cluster service is a one-cell region on a map of its own
  (docs/SERVICES.md), appended to the partition.
* **Dealing out.** Regions are dealt longest-processing-time first: the most expensive to the least
  loaded node. When a node joins, as few regions as it takes move to it until the busiest and idlest
  nodes are within 20% of the mean load. From then on the load is measured and balanced (below).

### Ownership, epochs and leases

`cluster/ownership.d` (`RegionAuthority` on the coordinator, `RegionView` on every node).

* **One owner at a time.** A region moves in two steps. The coordinator marks it `revoking`, naming
  its next owner; the owner stops simulating it and answers `RegionReleased` with the grant's epoch;
  only then does the coordinator grant it to the next owner. A release of another epoch is ignored.
* **Epochs** increase with every grant and are built as (coordinator incarnation << 20) + count, so a
  restarted or new coordinator's grants are newer than anything its predecessor gave.
* **Leases.** A node may act on its regions only until `lease_ms` after the last of its own heartbeats
  the coordinator echoed. A node cut off from the coordinator therefore stops by itself. The
  coordinator gives a lost node's regions away only once the lease and a 500 ms margin have passed
  since it last heard from that node, so the two never overlap; only clock rates, not clock readings,
  are assumed to agree. A new coordinator grants nothing during its first lease, so its predecessor's
  grants have run out first. A fenced node gets no more echoes, so it also stops.
* **Tables.** The region table is sent whole when it changes (it is small) and kept only if newer; a
  table from a new coordinator incarnation replaces the old one, and its lease starts afresh. Every
  node holds a copy, so every node knows who owns any cell (`regions.ownerAt`) without asking.

### In the world server

* `WorldContext.ownsCell` tells maps which cells are this node's. A map creates a cell's spawns only
  if the cell is owned. Because a map holds only what its node owns (and replicas), the tick needs no
  ownership checks.
* `WorldContext.regionsChanged` applies a new table: services stop or start, dungeon copies go or
  come, the objects of lost regions leave the maps (`Map.release`), and players near gained regions
  look around again so the cells near them load.

### Ids

Character, item, mail, group, instance and pet ids must never be handed out twice.
The coordinator hands out ids from its own counters (`IdKind`). A member asks for a block of
`id_block` ids of each kind, and for the next block when half is used (`IdPool`), so allocation never
waits on the network. A member reports the highest ids it holds whenever it links to a coordinator,
and a coordinator grants no ids during its first lease, so a restarted coordinator never hands out a
block a member still has. A member without a block refuses to create a character, and ends a session
rather than reuse an item or mail id. Creatures a node summons take guids from that node's own
range.

## Replication

A node sends its neighbours replicas of what they need to see, so a player at a border sees what lies
beyond it.

* **Interest.** Each map counts, per cell, its players within visibility distance of it (the 5 × 5
  cells around each player), recomputed when a player's visibility is (every 10 yards,
  `visibility_relocation_lower_limit`). Each tick the changes go to every linked node
  (`InterestUpdate`), and a node that links gets the whole interest. A peer's interest also loads the
  cell on its owner, so the owner simulates creatures that only another node's player is near.
* **Sending** (`Map.replicate`). An object a node simulates, in a cell some peer is interested in, is
  created on that peer (`ReplicaCreate`: the fields everyone may see, and its movement with any walk
  written exactly). Its changed public fields follow (`ReplicaValues`), its walks (`ReplicaMove`: the
  client packet and the exact spline), and its end (`ReplicaRemove`) when it leaves the peer's cells,
  the peer's interest, or the node.
* **Players** are replicated by the same interest, as a stranger sees them (health in percent): their
  moves and emotes, their field changes, and their departure.
* **Receiving** (`Replica`). A replica sits on the map with the node's own objects, and the node's
  players see it through the usual sight rules. A replica follows its spline, so its position and cell
  stay right, but runs no AI and no gameplay: replicas are drawn and may be targeted, never changed.
  Messages about a replica are accepted only from the node that sent it. A lost node's replicas go at
  once.
* **Once per node.** Traffic between nodes is per entity and node, never per entity and client: a
  node receives an entity's updates once and fans them out to its own clients. In a crowd the
  expensive part is fan-out to sockets, and that stays with each client's home node.
* **Crossing messages.** When a region moves, the old owner's removals and the coordinator's grant
  come over different links. A spawned object replaces a replica with the same guid without its
  viewers noticing, and replica messages for a guid that is now the node's own are ignored.
* **Range packets.** Say, yell, text emotes and anything else `Map.sendInRange` sends are delivered to
  the node's own players in range and sent (`InRange`) to every node interested in a cell within the
  range, which delivers them to its own players in range. Each node delivers only to players it
  simulates, so nobody hears anything twice.

## Players moving between nodes

### Home and owner

On the owner, a player from another home has an ordinary session without a socket. What it sends goes
home as opcode and body (`PlayerMessage`, to the home), where the home encrypts it for the client;
what the client sends, the home passes on unread (to the owner) while its own session is in the
`elsewhere` state. Every in-world handler runs unchanged on the owner. A gateway is a home that is
never an owner.

### When a player moves

Once a second (the zone check) a player asks whose ground it stands on (`migrationTarget`). It moves
when:

* the ground 25 yards around it in all four directions is one other node's, so walking along a border
  does not bounce it;
* it has not moved in the last 10 seconds;
* it is not teleporting, logging out, or in combat (a fight stays with the creatures it is against).

A player logging in on another node's ground moves there as it logs in; a player logging in through
a gateway therefore moves at once to the owner of its ground.

Some actions move a player immediately, whatever its ground and however recently it last moved,
because only the node simulating a creature or object may change it:

* attacking another node's creature, casting at it, or looting its corpse;
* using another node's game object, or casting at one (a lock to open, an herb to pick);
* being noticed by another node's creature: when a player moves, its node asks the replicas of other
  nodes' creatures near it what the creature itself would ask (alive, out of combat, aggressive, an
  enemy that may attack, the player within its aggro radius and in sight). If so the player moves to
  that creature's node, and there the creature decides and attacks. A node moves a player for the
  same creature at most once in 30 seconds;
* a teleport to another node's ground (leaving a dungeon, a hearthstone, a graveyard, a GM's port):
  the player moves there first and is teleported there, so the client never loads a world its node
  does not simulate;
* going into a dungeon or battleground copy another node hosts (below).

The action travels with the player (`ArrivalAction`: the attack, the spell and its target, the corpse,
the object, the teleport), and the next node performs it at the player's first tick there. The client
sees nothing of the move: its swing simply begins.

### How a player moves

1. The simulating node saves the character, waiting until every queued write has reached the
   database, and sends the account, the guid, the movement, the arrival action, and every guid the
   client knows (`Map.knownTo`). It takes the player off its map without a destroy packet: players
   there who saw it now see a replica owned by the next node (`Map.removeForMigration`).
2. The next node loads the character through the login code without sending any login packets, and
   puts it on its map knowing what its client has (`Map.addMigrated`): an object in sight and known is
   marked seen; in sight and new, created; known but out of sight, sent out of range; known but not
   held there yet, it *lingers*: its replica, when it comes, is adopted without a create block, and
   whatever has not come within 5 seconds goes out of range.
3. Players there who saw the player's replica now see the player itself.

A player away from home that walks onto a third node's ground goes straight there: its state names
its home, the new owner makes its session for that home, and the old owner tells the home
(`PlayerMessage`, moved), which sends the client's packets there from then on. Packets the client
sent before its home heard are passed on by the old owner for a few seconds, and a home that hears
from a new owner before the old one's word takes it as the owner.

The character's saved auras, cooldowns, quests and reputation move with it. A clean handoff also
carries its movement, corpse and death state, pending projectile impacts, what its client knows,
active pet, dungeon copy and client connection details. Regeneration, rest, zone checks and chat
flood protection keep their progress. Temporary GM commands and allowed whisper senders stay in
effect for the same session. Ordinary balancing waits for a taxi flight to land. A forced clean
handoff can resume the flight from its current route and position.

### Leaving the game

A logout or disconnect on the owner is saved there and the home is told. A client that disconnects at
home is passed on to the owner, and the home releases the account only when the owner says it has
saved.

## Objects moving with their region

When a region is revoked toward a named next owner, its owner writes the state of every object
homed in it (`Map.migrateOut`, `world/migration.d`): a creature's every field, its movement and exact
spline, its movement generator, its vendor stock, its script state and the remaining time and
ticks of its auras (`Creature.saveState`). Its corpse keeps its original decay and respawn deadlines,
and any remaining corpse, skinning or pickpocketing loot keeps its contents and claims. Game objects
keep their fields and script state, including pending door and
goober resets and a trap's cooldown and spent charges. An opened chest keeps its remaining loot, claims,
despawn timer and gathering uses. Its loot window closes during transfer and can be reopened on the receiving
node. It keeps each object as a replica of
the next owner's object, so its own players notice nothing.

EventAI keeps its current phase, completed spawn events and pending timers when a creature moves.

The bundle goes with the release (`RegionReleased`). The coordinator, granting the region, sends it to
the new owner (`RegionHandover`) on the same link as, and ahead of, the table that grants it. The new
owner rebuilds each object from its spawn and loads the state (`Map.migrateIn`), replacing replicas
silently, and only after applying every bundle lets anything load the region's cells afresh. A hurt
creature arrives hurt; a boss arrives in the same phase with the same timers. A saved game-object
move or rotation also updates the receiving node's spawn and cell index when the object arrives.

Scripted waypoint movement carries the database path ID, its progress and any pause. The new owner
resolves that path from its world data, including when the spawn normally stands still. A waypoint
route suspended by combat resumes when the creature goes home.

An outdoor database script anchored to a creature or game object moves with that object's home
region. Scripts with delayed steps save their next step in the characters database before they start.
After a clean handoff or a worker crash, the new owner resumes the pending steps using the original
schedule and waits briefly for participants to reconnect. Scripted kill and exploration credit commit
the quest progress and the script cursor in one transaction. The worker sends the quest update after
the commit. A crash during that write rolls it back so the replacement can grant the credit once.
A delayed step that summons a creature on the same worker commits the script cursor, the creature's
GUID and state, and any relay it starts in one transaction. The worker publishes the creature after
the commit. During recovery, the new owner either retries the pending summon step or restores the
saved creature and its relay. Its original lifetime continues and saved deaths and despawns still
apply. When a delayed script summons on another worker, the sending worker commits a request with
the script cursor. The worker that owns the destination cell commits the actor and its relay with
a receipt, which it retires after publishing the creature. A replacement can finish an open request
or publish the actor from a committed receipt. The parent script waits for delivery before running
its following steps. Scripted toggles of outdoor doors and buttons also use the queue. The new owner
restores the active door state and resets it at the original deadline. The same queue saves timed
respawns of outdoor quest givers, goobers, generic objects, spell focuses, buttons, and consumable
non-gathering chests that scripts place at their database spawn. The replacement restores their
original spawn GUID and visibility deadline. A timed button keeps that deadline through a scripted
toggle and reset. Scripted chests keep the contents and claims they saved during opening and looting.
Depleting or removing a scripted chest retires its loot and placement together.
An immediate scripted despawn of one of those objects removes the checkpoint before publishing its
removal. An immediate scripted despawn of a standing outdoor object outside a pool commits its normal
respawn deadline before making it disappear. A parent on another worker waits for that result before
it continues.
When a delayed script starts a local relay or starts one on a static creature on another worker,
the parent cursor and the new relay commit together. For a remote relay, the same transaction queues
delivery to the creature's spawn cell. The replacement resumes the relay on its original schedule.
A checkpointed outdoor script saves a locally owned creature's faction change with its cursor
when the creature has no active player escort checkpoint. The replacement restores the faction
used for client updates and combat. A native creature with a saved faction change keeps its grid
loaded until its faction resets or it despawns.
Other commands claim their step before executing it, so a crash during their effects can leave the
step incomplete.
Finite wild objects of the generic and spell-focus types use the same durable queue from placement.
An immediate object-only player spell saves the request before reporting a successful cast.
The objects keep their GUIDs, state, and original expiry during recovery. Timed outdoor summons and saved
quest objects keep their grid loaded through idle cleanup until they leave the map. The worker retries
pending region recovery if its first database read fails.

On a clean dungeon handoff, queued database scripts resume at their next step with the elapsed
time intact. The receiving node waits briefly for players who were participating when the copy
moved. Script-spawned game objects, including temporary unowned objects, keep their original
expiry deadlines. An object whose deadline passes in transit is removed on arrival.

One-shot dungeon reward chests survive a host crash from the moment a script spawns them. The
characters database stores the expiry first and the rolled contents when the chest opens. An
inventory award and its consumed loot slot are written in the same transaction. The lockout keeps
the record until reset, including after the chest is exhausted or expires.
Opened outdoor consumable chests also retain their contents, claims and expiry on the replacement
worker. This covers unpooled chests and gathering nodes in outdoor pools made entirely of game
objects. The chest checkpoint is retired in the transaction that starts its respawn. These pools
save their selected placements together, including each placement's cooldown, so workers can
use different placements without overwriting each other's changes.

Dungeon and raid corpses with loot have a saved record alongside the spawn death, including
scripted summons whose despawn rules leave a corpse. A
replacement worker restores the corpse's original GUID, location, decay deadline, rolled contents,
eligible players and pending rolls. Only players who still need to vote receive the original roll
prompt. Item claims and the inventory award commit together. Coin shares use a durable payout
token, so retrying a payout pays each player once.
Ordinary native enemies checkpoint active fights by spawn and dungeon copy. A replacement
restores the original creature's health and combat state. A recorded death or copy reset retires
the fight. Encounters with their own actor snapshots use that state on recovery.
The record also preserves a corpse ready for skinning and any unclaimed skinning loot.
On a clustered realm, the replacement also reopens a native living creature's original
pickpocket loot, with any previous claims applied. Once emptied, the pockets keep their saved
restock deadline. Death starts a new lifetime with fresh pockets.

Ordinary outdoor creature spawns also save their corpses and respawn deadlines together. The
replacement region owner restores the original loot and rolls. A player on another worker can
answer the same roll, including when the coordinator election makes that player reload on the
same gateway connection.
Loot-bearing outdoor scripted summons that leave a corpse, including Thunderaan, keep their
original body and loot on the replacement worker. Their expiry never schedules a respawn.

Outdoor creature scripts using the escort or follower component save the actor's active progress
and nearby living summons. The replacement waits for the player to return before continuing the
script. A planned handoff supplies the current actors for its region.
Ordinary living outdoor enemies also checkpoint their health and combat state when damaged.
The replacement resumes the original spawn and allows time for its opponent to reconnect through
the gateway. Evading back to full health or dying retires the combat checkpoint.

* **The same spawns everywhere.** Pools, spawn groups and spawn entries are chosen with a seed made
  from the cluster's name and the realm, so every node agrees on which creature a spawn is.
* **After a node is lost**, the new owner loads saved respawn deadlines, discovers spawns added
  since startup and refreshes saved game-object positions and rotations for gained outdoor regions.
  A move across cell boundaries updates both cell entries before the new owner loads them. Clean
  moves carry the live placement and the running deadlines for creatures and game objects that are
  currently absent. Only the node owning a spawn's home cell clears its due respawn timer.
* **Scripted summons** keep their GUID, placement, state and remaining lifetime during a clean
  handoff. Active player guardians and totems follow their player on the same map and retain their
  GUIDs, position, health and timers. The gateway's replacement worker also restores these
  summons from the last save for the current login on the same map and copy. Their original
  lifetime continues through the outage, and a totem resumes at its next scheduled pulse. Death,
  dismissal, and expiry remove the summon from the checkpoint. Dungeon scripts can checkpoint
  selected summons for crash recovery. Cluster nodes reserve temporary GUID ranges so a restarted
  node does not reuse the IDs of objects it handed off. A player's corpse
  keeps its original location and reclaim deadline when the player changes nodes. The current owner
  replicates the body and its removal to nearby observers on other nodes.

### Creature assistance

An open-world creature calling for help can borrow a nearby allied spawn from another node. Event
spawns stay with their home region because an event can replace or remove them. After
the usual assistance delay, the coordinator reserves the helper's spawn in the region table and
uses a separate lease to move that creature to the fight's node. That node checks the caller,
victim, faction and line of sight again before the helper joins. A defeated helper stays where it
fell until its corpse expires.

The reservation follows the creature even if its home cell changes owners. The current owner of
the home cell skips that spawn until the helper comes home and the lease retires. If the borrower
is lost, the coordinator waits for its lease to expire and recovers the spawn on the current home
owner. If the creature died, the home owner restores the original corpse and its unclaimed loot
until the decay deadline. The spawn remains dead until its saved respawn time. For a single-choice
creature pool, the corpse and the pool's death record commit together, so another placement in
the pool cannot appear while the corpse is still available.

### Dungeons and battlegrounds

A dungeon or battleground is one region, and its node hosts every copy. It alone chooses which copy a
player goes into (`instanceFor`: the raid lockout, the group's bind, the player's own), makes copies,
binds players and groups, records the dead, and resets empty copies. Instance ids come from the
cluster's blocks (`IdKind.instance`), so two hosts never make the same one.

* **Going in.** A teleport into a dungeon another node hosts (a portal, `.worldport`, a summon,
  `.appear`) checks the entrance where the player is, then asks the host (`DungeonEntryRequest`)
  whether the player may enter. A raid lockout or a full copy is answered with the reason, and the
  player does not move. Allowed, the player moves to the host with the teleport as its arrival
  action, and the client sees the usual loading screen. A summon or appear across nodes carries the
  copy, so the player lands in the other's copy.
* **The region moving** (a rebalance, a takeover). The new host reads the dungeon's copies, binds and
  dead from the database, and the copies' creatures and objects come along, copy by copy, as they
  were. The old host forgets the copies and deletes nothing. After a crash, the replacement uses
  saved binds, spawn deaths, and script state. In Blackrock Depths, the Ring of Law resumes its
  saved wave once a player returns. The replacement restores the gates, announcer, remaining
  timer, and living opponents. The script checkpoints each wave's summons and deaths and saves
  changes to surviving opponents every two seconds. At each wave checkpoint the worker also
  saves the party's current positions and health.
  The Tomb of the Seven keeps its active dwarves, the current round and its timer. The entrance
  stays closed through combat, and the doors and reward survive a crash after Doom'rel falls.
  In Blackrock Spire, Pyroguard Emberseer resumes his growth or fight with the surviving guards,
  and the replacement restores the confinement runes and doors for that phase.
  The Rookery resumes its remaining wave timer and living hatchers, guardians, or Solakar.
  Rend's stadium restores its wave, gates and surviving opponents, including Rend after his dismount.
  The Beast resumes combat, and the replacement keeps the surviving Blackhand ambushers.
  Both of Drakkisath's gates reopen from his saved death.
  In Dire Maul North, Mizzle resumes his walk or remains available for the tribute at the throne.
  The Dreadsteed ritual in Dire Maul West resumes with its actors, supplies, wave timers and
  pending database steps. The final summons continue from the saved step.
  In Uldaman, a replacement resumes the Stone Keepers from the last saved keeper and wake timer.
  The next keeper waits for a player to return, and defeated keepers stay dead.
  Archaedas resumes his awakening or fight with the awake statues.
  In Sunken Temple, the statue puzzle keeps its lit statues and Atal'alarion resumes as the same
  creature. The Avatar of Hakkar ritual keeps its extinguished flames, closed doors, surviving
  summons and pending waves. Defeating the Avatar keeps the doors open after a crash.
  Onyxia keeps her health, flight phase, surviving whelps and the remaining time to the next wave.
  The recovered fight can proceed through landing and her final ground phase.
  In Blackwing Lair, Razorgore's destroyed eggs stay gone and surviving defenders return with
  their saved health and wave timer. A player uses the orb again to resume control during the
  egg phase. The freed dragon's fight and the open exit after his death also survive a crash.
  Nefarian's raid keeps its drakonid kill count, surviving drakonids and the original tunnel
  spawners. The tunnels continue their waves. After the 42nd kill, the saved transition timer
  brings in one dragon, whose approach and ground fight both resume after a crash.
* **GM commands.** `.instance info`, `.instance shutdown` and `.instance reset` of a copy another node
  hosts go to that node and its answer comes back; `.instance resetall` goes to every node.

Battleground copies run on the node hosting their map in the same way. The queues that fill them are
a cluster service (docs/SERVICES.md). A replacement worker restores a recent running match from
MariaDB before accepting players. The checkpoint keeps its copy ID, scoreboard, objectives,
members, timers, and map objects. An alive Warsong flag carrier gets the flag aura back if the
character save predates the pickup. A dropped flag keeps its object GUID and remaining return time.
Gateway clients load the restored map over their original connections.

Match checkpoints record objective changes before the worker sends its response in normal
operation. The worker also saves every two seconds while a copy is running. The countdown and
objective timers pause at the checkpoint during recovery. Player positions and combat state still
recover from each character's last durable save. The replacement closes copies whose checkpoints
are missing, unreadable, retired, or older than two minutes. Unpublished results stay eligible for
recovery past that cutoff. The standby can restore the final scoreboard during the post-match window.
Each home database commits the character's marks, honor, and reputation together with a payout receipt.
The current character owner can deliver a pending reward after recovery or on a later login. Marks
that exceed available bag space arrive by mail.

## State shared across nodes

### One login per account

`cluster/sessions.d`. A node claims every session it authenticates (`SessionClaim`, with a serial
number of its own). The coordinator's directory grants an account to one session at a time: a second
claim evicts the holder (`SessionEvict`, which kicks it) and is granted only when the holder has
released the account (`SessionReleased`), which a node sends once the session has ended and its
character has been saved. A session may enter the world only once granted, so no character is ever
in the world on two nodes, and none is loaded before its last session's save has been written.
Character creation and deletion wait for the grant too. Claims made while the coordinator is
unreachable are sent when it is back, and a node claims all its sessions again whenever it links to a
coordinator. A lost node's accounts are freed when its lease has run out.

### Outdoor script world state

Workers read the realm's map-scoped script variables from the character database once per second.
A delayed script commits a variable update and its next step in the same transaction. A replacement
can resume the script while workers that own affected spawn cells continue to evaluate the last
committed value.

### Presence

Once a second every node tells the others what changed of the players it simulates (`Presence`:
name, account, race, class, level, gender, zone, account level, the GM tag, away and busy with their
message, whether it has GM permissions and its permission letters), and a node that links gets all of them. A
lost node's players are forgotten with it. Presence answers "which node simulates this player" for
every feature that has to reach one (`DeliverTo` carries a packet to a player on its node), and
supplies what the who list, friend lists, group lists and GM commands show of other nodes' players.

### What crosses nodes, feature by feature

* **Whispers** are checked and delivered where the receiver is simulated: a whisper to another node's
  player goes there (`Whisper`, with the sender's guid, race, permissions and chat tag), which runs the
  same delivery as for a local one (GM whisper blocking, factions) and sends back the sender's copy,
  the away or busy reply, or the refusal.
* **The who list** shows the node's own players and those presence reports, through the same filters
  (team, account level, level range, class, race, zones, name, guild and zone-name parts) and caps.
* **Chat channels** and **battleground queues** are cluster services (docs/SERVICES.md).
* **Duels** can be requested against a nearby player simulated on another node. The challenger
  moves to the opponent's node and the cast is checked there again. Both stay on that node while
  the challenge is pending or the duel is active. A forced move, such as a drain, ends the duel.
* **Single-target player spells.** Direct heals, buffs, damage spells and debuffs can follow
  their target to another node. The caster's node checks the target's replica for friendship
  or PvP eligibility, range and line of sight before moving the caster. The target's node
  repeats the checks against the real player at the start and end of the cast. The completed cast
  pays its normal cost and starts its cooldown. The caster must be out of combat and free to
  move. Their PvP flags and expiry timers travel with them. A cancel received before the cast
  starts discards the pending action.
* **Party summons.** A warlock ritual or meeting stone sends the offer to the target's node, even
  on another map. The target can accept it after changing nodes. An open player-owned ritual portal
  keeps its GUID and participants when the caster changes nodes on the same map.
* **Direct party heals.** At cast completion, one cast on the caster's node pays the usual cost
  and starts the cooldown. This includes cast-time spells such as Prayer of Healing. Each
  recipient's node rechecks range, map, and party or raid subgroup before applying the heal
  with that recipient's healing modifiers. It adds threat from health actually restored to
  creatures fighting the recipient. The caster's node logs and runs caster procs for confirmed
  heals while it still simulates the caster. Repeated deliveries and confirmations have no effect.
* **Chain Heal.** A cast that starts on a party or raid member on the caster's node can bounce
  to injured members across nodes. Each bounce searches around the previous recipient's
  position at cast completion and prefers the eligible player missing the most hit points. Nodes
  exchange that deficit separately from client-visible health percentages. Each cast shares
  the spell's target cap across nodes and reduces each bounce by the
  spell's normal falloff. The receiving node checks current group membership and range from
  the captured position and applies the heal once. The cast spends mana once on the caster's node.
* **Instant hostile area damage.** A caster-centered magic hit can reach players and creatures on
  another node. The caster's node charges once and applies the spell's cap to the combined
  list of local and remote targets. The receiving node rechecks range, attack eligibility
  and immunity, then resolves hit chance, damage, resistance and shields. The
  caster's node records confirmed damage and PvP kill credit while it still simulates the
  caster. The creature's node applies damage, threat, tapping, death and loot. Each hit and
  its confirmation are processed once.
* **Chain Lightning.** A cast that starts on a target on the caster's node can bounce to PvP
  opponents and creatures on other nodes. The nearest eligible enemy to the previous target gets
  the next jump. Local and remote enemies share the target cap and 30% damage falloff per jump.
  The receiving node rechecks range from the previous target's captured position, PvP
  eligibility and immunities. Damage and kill credit are applied once for each hit.
* **Damage over time.** The target's node advances player-cast damage auras after the caster
  hands off. Creature ticks keep the caster's threat and tap, and a lethal tick settles loot on
  the creature's node. Solo kill and quest credit, or honor for a PvP kill, go to the node
  simulating the caster. Group rewards still use their existing proximity checks.
  Health and mana drains send the amount actually drained to the caster's current node.
  For a targeted channel, the caster stays on its node and the target's node verifies the
  active channel before each tick. Cancellation and pushback update the remote aura.
  The victim's node runs periodic reactions and returns caster benefits such as Vampiric Embrace.
* **Spell-selected game objects.** A player or creature can animate and change eligible game objects
  named for the spell, including objects on another node. Nearest-object and area effects use
  the same selection across the two nodes and share any target limit. The object's node
  checks ownership, entry, effect exclusions and range. If it observes the caster, it also
  checks that the caster's owner and state allow the cast.
  Object state and collision follow the owner. Duplicate requests apply an effect once, and a
  confirmed player cast can grant quest credit.
* **Spell foci.** A nearby anvil, forge or other spell focus can satisfy a cast from an adjacent
  node. The caster's node checks the observed focus's template and three-dimensional distance.
* **Persistent ground effects.** The caster's node owns the spot and its tick timer. It sends
  each tick to the observed targets' nodes, which check the targets' current positions and
  resolve damage once. If an in-flight tick reaches a previous owner that knows where the
  target went, it declines the tick and the caster's node routes it once more. The spot is
  visible across nodes. Effects such as slows expire unless the next pulse renews them.
  A clean handoff on the same map and copy preserves the ground objects and their next tick for
  players and NPCs. An active player ground channel moves too. Cancelling it still removes its ground objects.
  After a worker crash, the gateway's replacement also recovers the player's ground effects and
  active ground channel in the same copy. The original expiry still applies. Pulses that fell
  during the outage are skipped.
* **Creature melee.** An NPC keeps threat on a player it can still see after the player's
  handoff. The fight keeps nearby replicas available even when the last local player leaves.
  A pet, charmed creature or guardian can melee nearby players and creatures across the
  boundary, and nearby NPCs can fight it back. The attacker's node chases and runs the
  weapon timer. The target's node checks the attacker's current replica and controller,
  eligibility, reach and facing, then rolls damage and applies armor and absorbs once.
  The creature holds the threat and its controller receives the loot tap and kill credit.
  When a target creature's region moves, its health, combat state, threat and tap go with
  it, and the attacker directs its next swing to the new owner. Requests from a previous
  charm or a despawned guardian are discarded once the target node sees the change. Damage
  shields such as Thorns and block retaliation from Holy Shield or Blessing of Sanctuary
  strike the creature on its node using the swing reply. The defender's node spends the
  Holy Shield charge when it resolves the block. The creature's node applies the damage
  and threat and sends the corresponding combat log once.
  A queued weapon ability such as Maul or Cleave replaces one swing. Cleave shares its
  target cap across local and remote enemies, and the attacker spends any applicable mana
  once. Each target's node resolves that target's weapon hit. A fighting creature carries
  its queued ability through a region handoff. An old owner can discard a swing sent before
  the target's handoff.
* **Creature casts.** Direct magical damage and hostile auras can reach targets across
  nodes, including caster-centered areas, target-centered areas and forward cones.
  The creature holds the cast timer, mana and spell-list cooldown. The target's node
  rechecks eligibility and the spell's geometry. An interrupt before completion cancels
  the cast.
* **Targeted item use.** When an item targets a nearby creature or game object on another node,
  the player's handoff carries the item GUID and cast targets. The new owner runs the item script
  and consumes charges through the usual cast path.
* **Named creature targets.** A player or creature can select the nearest living creature, targets in a cone,
  or an area around the caster or destination using `spell_script_target` entries, including replicas.
  An area's target cap is shared across nodes. Each target's node checks its entry and position again,
  resolves heals, aura groups or damage with its attached auras, and signals a successful hit to the creature's AI.
  The database can exclude individual effects for an entry, including an attached aura or the damage itself.
  It can also run immediate database script steps that despawn the selected creature or make it cast on itself.
* **Spell procs.** A hostile hit can trigger auras on both actors. Self effects run with the
  actor, and supported direct damage, healing and aura effects of the same proc can
  reach a named target on its node. Aura effects with the same target share one
  application. Projectiles dispatch on impact, and triggered channel missiles can be
  aimed at a remote target. Proc results are applied once.
* **Trades** between nearby players move the requester to the other player's node, where the usual
  trade checks and exchange run. Both stay there until the trade ends. A forced move cancels any
  open trade before the player leaves.
* **Groups** are changed in one place, the coordinator's `Groups`, loaded from and saved to `groups`
  and `group_member`. What changes a group (invitations, accepting and declining, kicks, the leader,
  leaving and disbanding, loot settings, icons, raids, sub-groups, assistants, logging out) is a
  `GroupCommand` that `GroupService` runs there. Every other node **mirrors** the groups: the
  coordinator sends a group's whole state (`GroupState`) after each change, its removal when it is
  disbanded, and a complete roster after a worker accepts the coordinator. The worker drops groups
  omitted from that roster after reconnecting. What only reads a group (who sees whose health,
  party and raid chat, member stats, ready checks, rolls, minimap pings) is decided on the player's
  node from its mirror. Each node publishes arrivals and departures immediately, including during
  a handoff. A packet for a member goes to its node by presence, or for a few seconds
  after a command to the node the command came from. Stats of a member another node simulates are
  asked of that node (`MemberStatsRequest`). The coordinator checkpoints pending invitations and
  meeting stone queues. A promoted coordinator restores the original invitations, even before the
  first accept creates the party. It also resumes waiting parties and solo places.
* **NPC services** (gossip, trainers, vendors, innkeepers, bankers, repairs) work on a replica of
  another node's creature through an `NpcStandIn` built from the replica's fields and the shared
  template; the player's side (money, items, spells, bind point) is on the player's node. A vendor's
  limited stock belongs to the creature. The vendor list reads its current count from the creature's
  node. A purchase reserves stock there (`StockRequest`, `StockReply`), and a failed purchase returns
  that reservation (`StockRelease`).
* **GM commands that name a player** another node simulates are sent there (`GmRemote`):
  `.kickplayer`, `.summon`, `.appear` (the place comes back and the GM teleports there),
  `.playerinfo`, `.kill`, `.ban character`, `.rename`. What each does to its player is the same method
  a GM on the player's node uses, and its messages come back to the GM's node. `.server saveall` and
  `.admin masssummon` run on every node. `.gm list`, `.gm allowwhispers` and `.info` use presence.
* **World texts** (`.announce`, `.wannounce`, kick and ban notices) reach every node's players
  (`ToEveryone`, with the permission filter for GM texts).
* **Group kills.** Members near a kill whose replicas are on the killer's node count in the group's
  share; each one's part (kill credit, experience, reputation) goes to its node (`KillShare`).
* **Group loot rolls.** Nearby party members on other nodes can roll for shared items under Group
  Loot and Need Before Greed. The loot's node counts votes and chooses the winner. The player's own
  node checks loot conditions and whether they can use the item for Need Before Greed. The winning
  player's node stores the item and confirms the award. A remote participant can use the same roll
  prompt after their simulation moves to another node on the same map, once the loot owner sees the
  new player owner. They also keep the prompt when the corpse or chest moves. The player's node
  sends its vote to the owner of the visible replica and replays the original vote if that owner changes.
  A failed store leaves the item reserved for the winner. The inventory write and its result
  commit together. If the delivery or reply is lost, the loot's owner reads the saved result or
  retries the same award on the winner's current worker.
* **Master loot.** The designated master can assign shared items at or above the loot threshold
  to eligible party members on any node. If the master is eligible and starts on another node,
  the corpse shows them the loot cursor and interacting with the corpse or chest moves them to
  the loot's node. They receive the recipient list on opening, including when another party
  member opened the loot first. An ineligible master leaves the group with its usual fallback
  loot rules. The recipient's node checks item conditions and saves the award once. A rejected
  award leaves the item available for reassignment and reports the error to the master. A pending
  award keeps the slot locked while the current owner checks for its saved result or retries it.
* **Party coin splits.** The loot's node divides the drop among eligible, reachable members,
  with the extra copper going to the looter first and then in GUID order. For a cross-node split,
  all shares are saved together before the gold is cleared. A player's current node applies the
  share once, even if the previous node failed or the delivery message was lost. A clean corpse
  handoff preserves the payout if its database write needs a retry.
* **Round-robin item pickup.** The coordinator chooses the turn for ordinary shared drops under
  Round Robin, Group Loot, and Need Before Greed. The turn advances once for the party even when
  consecutive drops come from different nodes. The designated member may click the corpse or
  chest and claim the item on its owner's node. The round-robin slot waits for the coordinator's
  reply while coins and rolls remain available. If the reply times out, the item stays with the
  player who created the drop. The party's rotation and recent choices survive a coordinator
  restart. A retried request gets the original choice without advancing the turn twice.
  Conditioned and personal non-quest drops keep their local pickup rules.
* **Quest drops.** At a kill or chest opening, the loot's node asks each eligible remote member's
  node which quest drops that character needs. Eligible members see the corpse's loot cursor on
  replicas. Clicking the corpse or chest moves the player to the loot's node, where the player's
  quest is checked again before pickup. A shared slot goes to one player and follows the group's
  loot turn when the loot method uses one. A multi-drop slot gives each eligible member one claim.
  The loot's node records each claim, including when the player leaves and returns. A quest check
  that goes unanswered for five seconds releases its provisional rights. A clean region handoff
  carries the remaining drops and their claims to the new owner. It repeats unanswered checks
  within their original deadline.
* **Script signals** to a creature another node simulates go there (`ScriptSignal`), applied once
  (its origin and sequence number drop a resend), and are passed on, at most three times, if the
  creature has moved again (docs/SCRIPTING.md).
* **Friends.** A friend list shows a friend another node simulates from presence; a login or logout
  is told to every other node (`FriendStatusChange`). A move between nodes is neither.
* **Guilds.** Workers share the same database and serialize guild mutations there. Each action
  checks current membership and rank before it writes. Changes to different fields survive when
  they come from separate workers. A successful commit publishes the change and its guild events.
  Workers also check the saved revision to recover updates they missed while disconnected.
  Guild chat, officer chat and invitations reach players on other nodes.
* **Auctions** need no owner node: the `auction` table is their one place, every node lists from it,
  and every change to a row is guarded by what was seen of it, so two nodes cannot both sell one
  auction. The coordinator settles auctions whose time is up.
* **Mail** lives in the database and is read each time, so it is the same on every node; one node
  returns and deletes expired mail.
* **Weather.** A realm service rolls each zone's weather once using its seasonal chances. Every
  worker shows the same weather to players in that zone. The service carries the current weather
  and the next change timer during a clean handoff. A new host can recover a recent checkpoint
  after a crash. Workers ask for the current state when players arrive and periodically while
  they remain in the zone.
* **GM edits of world data.** Vendor items, NPC quest starters and finishers, creature template
  scale, and recall destinations are saved to the world database. Workers reload the affected
  data within five seconds. A teleport table reload also reaches other workers. Realms that use
  the same world database share these edits.

## Load balancing

* **Measured.** Every 10 seconds each node divides its event loop's busy time (packets, tick and
  sending) among the regions it owns, by what each holds now (`Map.weighCells`): an object in the tick
  weighs 10, a resting one 1, a player 100. The result, µs of loop time per second per region, goes to
  the coordinator (`RegionLoads`), which keeps each region's cost as the mean of its last value and
  the new one. The first report replaces the start-up spawn counts.
* **Moves.** Every `balance_interval_seconds` the coordinator moves regions from the busiest node to
  the idlest while the gap between them is over a quarter of the mean, and only when the busiest takes
  at least `balance_min_load_us`. It moves at most two regions per look, each only if it narrows the
  gap (by at most half of it), and never one that moved within `region_cooldown_seconds`. A move is
  the handover above; players move with their ground.
* **Splits.** When most of the busiest node's load is one region too costly to move (more than half
  the gap), the coordinator cuts it in two along its longer side (`RegionAuthority.splitHot`). The old
  id keeps one half with its owner and epoch, so nothing changes hands; the other half is a new region
  granted to the same node, which the next look may move. A region is split at most once per balance
  interval, so its halves are measured first. Splits stop at 1024 regions. A crowd within one cell
  cannot be split further: its node carries it.
* **Merges.** Two granted regions of one node on one map that share a whole edge, together cost less
  than 1 ms/s, have not moved or been split within the cool-down, and of which at least one came from
  a split, become one (`RegionAuthority.mergeCold`, one per look). The lower id keeps the union. The
  table never shrinks below the start-up partition's size: merges take back what splits added.

## Failure handling

| What fails | What happens |
|---|---|
| **A member** | Its links close (at once if the process died, after `failure_timeout_ms` if it hangs) and the coordinator drops it from the view. Its replicas vanish from the other nodes at once. After its lease and the margin, the coordinator reassigns its regions and services. The replacements load durable state where available. Its accounts are freed at the same time. |
| **A player's owner** | A gateway keeps the client connected and reloads its saved character once the coordinator has fenced the old process. A regular home disconnects the client, who can log in again after the owner's lease. |
| **A gateway's direct link to an owner** | The gateway pauses client gameplay and answers pings. The owner keeps the character and buffers packets while both nodes remain in the coordinator's view. |
| **A player's home** | The owner logs the player out, saved. For a gateway, the coordinator waits for the simulation to stop or be fenced before it grants the account again. |
| **The coordinator, with a standby** | The standby takes over (below). |
| **The link to the coordinator** | A member keeps simulating until its lease lapses. Then it ends every session, writes nothing more (its saves are dropped and logged as not saved), and gives up its regions. When it reaches a coordinator again it re-claims its sessions, reports its ids, and is granted regions again. |
| **A restarted process** | It joins with a new incarnation, which fences out the old one; queued writes from before its lease lapsed are dropped on replay. |

### Fenced writes

A node must never write over a character that has since played elsewhere.

* A cluster node's `WorldDatabase` is wrapped (`world/fencing.d`) so that while its lease has lapsed
  every write is dropped. The wrapper is generated from the interface: every method that returns
  nothing is a write.
* Writes are queued for a writer thread (`world/writebehind.d`), and each queued write carries the
  time until which the node's lease held when it was made. The writer drops a write it reaches after
  that time, and so does the replay of the write-ahead log at start-up. A node restarted after its
  lease lapsed therefore never writes over the regions' new owner.
* Before an account is released to the coordinator and before a player moves to another node, the node
  waits until everything queued has been written: the next node loads the character from the database.

### Gateway recovery

The gateway routes a saved handoff only after the coordinator records the new simulation owner's
node and incarnation under that login. It holds later gameplay packets during the handoff. A
gateway-to-owner outage leaves the recorded owner active while that worker still reaches the
coordinator. The ordered relay retains outgoing packets for the gateway's same incarnation.

If the coordinator loses the owner, it waits for the old write lease and margin before approving
a replacement. The former incarnation cannot reconnect to renew its lease. The surviving worker
that owns the saved position loads the latest database checkpoint and sends a world transfer
over the gateway's existing client connection. The character enters the replacement's map
after the client acknowledges the transfer. The gateway and replacement worker retry a failed
checkpoint read while the existing connection waits. The replacement reads the saved active
effects and pending summon offer before starting the world transfer. Checkpoints that record
a change in both position and effects commit those records together. Gateway-hosted characters use a checkpoint
interval capped at 15 seconds. Clustered player saves also include the active permanent pet's
health, power, auras and cooldowns. Work since the latest durable save can be lost in a crash.
An open party summon request belongs to the gateway login. The replacement worker presents the
same request with the time left on its original deadline. It records acceptance before teleporting
the player so a second response cannot trigger the same teleport again.
An open Ritual of Summoning restores the same portal and both the owner's and helpers' channels
with their remaining time. The party can finish it and receive the original target's summon request.
Active environmental timers resume on the same connection. Time spent waiting for recovery counts
toward the original timer. Damage pulses due during the outage are skipped.
A player reloaded in the middle of a fall keeps the original fall height for landing damage.

If the worker and coordinator both fail, a gateway linked to the standby reports its last
acknowledged simulation owner when it accepts the takeover. The standby restores the original
login claim before processing new claims. For a worker missing at takeover, it allows a full
write lease plus the margin from promotion before assigning the saved character to another
process. This also covers the former coordinator hosting the character.

### Quorum-based failover

Quorum mode runs on Linux. Configure the same list of voting node IDs and cluster addresses on every
node, including gateways.
Use an odd number of voters, starting with three. The voters also simulate regions. Give each voter a
distinct `vote_file` on persistent local storage, in an existing writable directory. Keep the file
across process restarts. For example, on voter 2:

```json
{
    "node_id": 2,
    "listen_port": 9001,
    "voters": [
        {"node_id": 1, "address": "127.0.0.1:9000"},
        {"node_id": 2, "address": "127.0.0.1:9001"},
        {"node_id": 3, "address": "127.0.0.1:9002"}
    ],
    "vote_file": "run/node2.vote"
}
```

In quorum mode the election picks the coordinator. Each voter records its term and one candidate
incarnation for that term before acknowledging it. A successful round gives the coordinator a lease
only through the round's original send time plus `lease_ms`. Voters promise the candidate their votes
for a lease and margin measured from receipt. A restarted voter waits out any outstanding promise
before voting for a different candidate. The cluster uses monotonic clocks that include host suspend
and uses the lease margin for timing differences.

Coordinator heartbeats still measure liveness. Separately, a worker's lease challenge returns only the
coordinator's remaining authority, measured from when that worker sent its request. A partitioned
coordinator therefore stops granting ownership and renewing workers even if its workers can still reach
it. Once their own leases end, those workers stop simulating and writing. The majority can elect a
successor, and the former coordinator can rejoin it as a member.

Views, regions and replayed gameplay traffic carry the elected term. A worker clears its old
simulation before accepting a new term. Gateways keep the client socket and report their previous
routes so the new coordinator can restore characters from their saved checkpoints, even when the same
worker takes the character in the new term. Clients connected directly to a worker can log in again
after its lease expires.

The voter list is fixed for the life of this cluster. To change it, stop every node and start the new
configuration with separate vote files. The single-standby mode below is available when the voter
list is empty.

### The single standby coordinator

When the coordinator dies, everything it keeps is needed within a lease, because without lease
renewals every member stops after `lease_ms`. The standby (`cluster.standby`) computes the
coordinator's start-up partition and costs too and, like every member, holds the latest region table.

* **Taking over** (`ClusterNode.promote`). When the standby has had no link to the coordinator for
  500 ms after losing it, it becomes the coordinator. It adopts the table it has
  (`RegionAuthority.adopt`): surviving members keep their regions and grant epochs, including
  transfers already on their way to them. Regions of missing members are held through their lease,
  then reassigned and spawned afresh. New epochs start above every epoch in the table. View and
  table versions continue from the old ones. The standby waits one lease before granting new regions
  or ids.
* **Members follow** (`Takeover`, sent again each second until accepted). A member takes the standby
  as its coordinator once it has lost the old one itself; while its own link to the old one is alive,
  it waits. The standby's heartbeat echoes on the link they already have renew the member's lease at
  once; the member re-claims its sessions, reports its ids, and from then on dials the new
  coordinator's address. With heartbeats every 500 ms, a failure timeout of 3 s and a lease of 5 s,
  about a second and a half is left to spare. The gateways linked to the standby report their
  confirmed routes with `TakeoverAccepted`, before re-claiming their sessions.
* **The world server's part** (`onPromoted` in `world/main.d`). The groups are loaded from the
  database (the old coordinator saved every change) and sent to every mirror; ids come from this
  node's counters, raised to what the database holds and what members report; the node speaks for the
  realm (its `realmlist` row, steering new clients) and keeps the honor week. Services the old
  coordinator hosted are dealt out with its other regions. Saved party invitations and meeting
  stone queues are restored on promotion.

**Limits.** There is one standby, and none after a takeover until one is configured again. There is
no quorum: a coordinator that is alive but cut off from the standby while members still reach it is
not told apart from a dead one, so run the two where that cannot happen (one machine or one switch).
The old coordinator must come back as a member of the new one (its `coordinator` pointing there).
Players whose client was connected directly to the old coordinator lose their connection and log in
again. Players behind a surviving gateway can accept their original pending party invitations.

### A clean stop: draining

A member stopped cleanly (SIGTERM, SIGINT, `.server shutdown`) does not stop at once. It sends the
coordinator `Drain`, and the coordinator revokes each of its regions toward the member that carries
least (`RegionAuthority.drain`) and grants it none from then on. Its regions go with their objects, as
in balancing; the players it simulates for other nodes' clients move on at once (no margin, no
cool-down); the players whose clients it holds stay and are logged out, saved, when it stops. It stops
when it owns nothing and has no visitors, or after 20 seconds whatever is left. The coordinator does
not drain.

## The realm list

Only the coordinator speaks for the realm: it marks the realm online, updates its population and
uptime, and marks characters offline at start. Every 10 seconds it points the realm's
`realmlist.address` and `port` at the node with the fewest players (from the heartbeats' load
reports), or at the least busy gateway while any gateway is linked. New logins so spread over the
nodes with the `realmlist` table as it is.

### Several realms on one login server

Each realm has a separate `realmlist` row and its own cluster. Every world node in that cluster uses
the row's `realm_id` and the same character database. Nodes check the realm ID when they connect to
each other. All realms can share one login database and one world database.

To add a realm, import [the character schema](../sql/classiccharacters.sql) into a new database and
give the server's database user access to it. The following `realmlist` row uses realm ID 2 and world port 8185.

```sql
INSERT INTO realmlist (id, name, address, port, icon, realmflags, timezone)
VALUES (2, 'dmangos 2', '127.0.0.1', 8185, 1, 2, 1);
```

Copy the world configs for the new realm. Set `realm_id` to `2` and point `character_database` at the
new database. Give it distinct world ports, cluster ports and coordinator addresses. Set a separate
`write_log` for each node when running the two realms from one directory. With quorum enabled, give
each voter its own `vote_file`. The same login server lists both realms after their coordinators
come online.

### Cross-realm battlegrounds

After setting up two realms as above, you can let their players queue together for Warsong Gulch,
Arathi Basin and Alterac Valley. Choose one node in each realm to host matches. The two designated
nodes run in the same worldserver process. Give every world node in both realms the same
`battlegroup` name. Set `battlegroup_node` to its own realm's designated node ID. For example,
add these top-level properties in each config when node 1 hosts matches in both realms.

```json
"battlegroup": "Emberstorm",
"battlegroup_node": 1
```

Keep the distinct ports, character databases, coordinator addresses and write logs from the
multi-realm setup. Use matching game data for the participating realms. Stop the old world
processes before enabling the group so that every client gets the new realm-qualified player GUIDs.
Start both designated nodes in one worldserver process. Substitute your actual config paths.

```sh
bin/worldserver -c realm1-node1.json --battlegroup-realm realm2-node1.json
```

Start every other world node normally, each with its own config. Additional realms can join the
same host by repeating `--battlegroup-realm`. The first config runs the shared map and matchmaking
queue. A player can log in through any node, queue at the usual battlemaster, receive an invite,
play the match and return to their home realm. Each realm stores its own characters and rewards.

The 1.12.1 client adds ` (*)` to foreign nameplates and displays the full realm after a hyphen on
the scoreboard. In chat the client omits spaces from realm names. To players from other realms,
Bob from Silver Hand appears as `Bob (*)`, `Bob-Silver Hand` on the scoreboard and `Bob-SilverHand`
in chat and emotes. Built-in emotes such as `/wave` use the server's extracted `EmotesTextData.dbc`
for the text shown to foreign viewers. Allies in the same match can whisper him with
`/w Bob-SilverHand` and reply with `/r`.

### Automatic battlegroup failover

1. Enable quorum in every participating realm. Keep enough voters online in each realm to elect a
   coordinator when either combined host is offline.
2. In each realm's world configs, keep `battlegroup_node` as the primary and set
   `battlegroup_standby_node` to a different node ID in that realm. Use world nodes for both hosts.
   Gateways remain separate. Every config in a realm must use the same two IDs.
3. Start the primary and standby in separate processes using `--battlegroup-realm` for the
   additional realms on each host. Pass the lowest realm ID as the first config on both processes.
   That realm's character database holds the shared queue checkpoint. For machine failover,
   run the two processes on different machines.
4. Check the logs for the active slot and for `services: battlegroundQueue runs here` on both
   realms. The shared login database stores the host lease in `d_battlegroup_host`, created
   at startup if needed.

The combined host renews its lease while every realm trusts it. Both realms grant their battleground
maps and queue to that host before it accepts queue actions. The standby takes over automatically
after the old lease expires. A recovered host stays on standby while the replacement holds the
lease. Queues, valid invites, and running matches recover from the lowest realm's character database.
The standby loads the match before reconciling its queue slots. With a single combined host, restart
its process to restore service.

The isolated end-to-end checks need the harness database, client data and release binaries
described in [Developing](DEVELOPING.md).

```sh
python3 tools/harness/battlegroup.py
python3 tools/harness/battlegroup_failover.py
python3 tools/harness/group_invite_recovery.py
python3 tools/harness/party_summon_recovery.py
python3 tools/harness/gateway_checkpoint_retry.py
python3 tools/harness/battleground_recovery.py
python3 tools/harness/battleground_recovery.py --cross-realm
python3 tools/harness/battleground_recovery.py --map arathi
python3 tools/harness/battleground_recovery.py --map alterac
python3 tools/harness/battleground_recovery.py --map alterac --cross-realm --finish-phase during
python3 tools/harness/dungeon_recovery.py
python3 tools/harness/dungeon_recovery.py --new-party --active-wave
python3 tools/harness/dungeon_recovery.py --native-fight
python3 tools/harness/tomb_recovery.py
python3 tools/harness/tomb_recovery.py --after-reward
python3 tools/harness/tomb_recovery.py --after-claim
python3 tools/harness/corpse_recovery.py
python3 tools/harness/corpse_recovery.py --after-claim
python3 tools/harness/corpse_recovery.py --during-roll
python3 tools/harness/outdoor_corpse_recovery.py
python3 tools/harness/outdoor_chest_recovery.py
python3 tools/harness/outdoor_chest_recovery.py --pooled
python3 tools/harness/dreadsteed_recovery.py
python3 tools/harness/escort_recovery.py
python3 tools/harness/outdoor_script_recovery.py
python3 tools/harness/outdoor_script_recovery.py --clean
python3 tools/harness/outdoor_script_recovery.py --after-summon
python3 tools/harness/outdoor_script_recovery.py --after-summon --clean
python3 tools/harness/outdoor_script_recovery.py --retry-actor-db
python3 tools/harness/outdoor_script_recovery.py --dead-actor
python3 tools/harness/outdoor_world_state_recovery.py during
python3 tools/harness/outdoor_world_state_recovery.py after
python3 tools/harness/outdoor_object_recovery.py
python3 tools/harness/player_summon_recovery.py
python3 tools/harness/player_summon_recovery.py --scenario guardian
python3 tools/harness/player_summon_recovery.py --scenario dead-guardian
python3 tools/harness/player_summon_recovery.py --scenario expired-totem
python3 tools/harness/fishing_recovery.py
python3 tools/harness/fishing_recovery.py --canceled
python3 tools/harness/ground_spell_recovery.py
python3 tools/harness/ground_spell_recovery.py --channeled
python3 tools/harness/ground_spell_recovery.py --native-enemy
python3 tools/harness/spell_cast_recovery.py
python3 tools/harness/spell_cast_recovery.py --finished
python3 tools/harness/spell_cast_recovery.py --projectile
python3 tools/harness/spell_cast_recovery.py --remote-bounce
python3 tools/harness/spell_cast_recovery.py --channel
python3 tools/harness/spell_cast_recovery.py --channel-canceled
python3 tools/harness/spell_cast_recovery.py --camera
python3 tools/harness/spell_cast_recovery.py --camera-canceled
python3 tools/harness/spell_cast_recovery.py --cooldown
python3 tools/harness/spell_cast_recovery.py --cooldown-reset
python3 tools/harness/party_summon_recovery.py --open-ritual
python3 tools/harness/environment_recovery.py
python3 tools/harness/environment_recovery.py --fall
python3 tools/harness/environment_recovery.py --atomic
python3 tools/harness/party_summon_recovery.py --retry-db
python3 tools/harness/player_summon_recovery.py --scenario guardian --retry-db
python3 tools/harness/hunter_trap_recovery.py
python3 tools/harness/hunter_trap_recovery.py --clean
```

Both map options also accept `--cross-realm`. The Arathi Basin test checks the resource score,
the Stables, and a Farm capture in progress. The Alterac Valley test checks the scorecard,
Irondeep Mine, and a contested Iceblood Tower that the Horde can still defend after takeover.
The party invitation test kills the coordinator with an invitation open. The original member
accepts it on the same connection, and MariaDB records one party with the two original players.
The party summon test kills the recipient's worker with the request open and sends two responses.
The original client teleports to the original destination once.
The gateway checkpoint test temporarily makes the fixture's character table unavailable during
takeover. Once the table returns, the same client reloads and can send chat.
The dungeon test takes an unbound party through the Blackrock Depths portal and kills its
worker between waves. `--new-party` forms the group through an invitation after a worker
handoff. `--active-wave` tests a crash with some opponents still alive. Both clients must
finish the same copy on their existing connections. Gerstahn stays dead and the party keeps
the one Prison Cell Key it looted before the crash.
The Tomb checks kill the worker during combat, before opening the reward, and after the first
claim. Both clients stay in the same copy, and MariaDB records each claimed item once.
The corpse checks kill Gerstahn's worker before opening his loot, after claiming one drop, and
after the first player casts a group loot vote. The original client connections reload the same
copy and the same corpse. The claims and the winner's item are checked in MariaDB.
The outdoor check starts a roll with players on separate workers, kills the corpse owner after
the first vote, and verifies that the second player can use the original roll to win one item.
The chest check kills the owner after a partial claim and uses the same client connection to
reopen the original chest. MariaDB must record both original drops once and the chest's respawn.
The pooled version also checks that the respawn is recorded for the original selected placement.
The Dreadsteed check kills the worker just after calling the Keeper and J'eevee. Both existing
clients see the same actors finish placing the ritual supplies and spawn the first wave once.
The escort check kills the Defias Traitor's worker after the quest starts. The original client
reloads the same actor, sees the route finish, and keeps the completed quest in MariaDB.
The outdoor script check kills the worker after the first quest script step. The original client
sees the delayed summon and emote once each, and MariaDB has no steps pending for that script.
`--clean` checks the same sequence during a clean handoff.
`--after-summon` moves or kills the worker after the summon appears. The next owner keeps the
same actor GUID and finishes the pending emote.
The outdoor object test restores the same Relic Bundle and checks that it expires on schedule.
The summon checks kill the player's worker after Magma Totem first pulses or after a Battle
Chicken appears. The totem keeps its GUID, pulses again and expires on schedule. The guardian
keeps its GUID while alive and stays gone if killed before takeover.
The expiry case crashes just before the totem would despawn and checks it stays gone after takeover.
The fishing checks recover the original bobber and catch, then verify that a canceled cast stays gone.
The ground-spell checks kill the caster's worker after Consecration or Blizzard starts ticking and
verify the same effect resumes and expires on schedule. Blizzard also restores the channel timer.
The unfinished-cast check preserves a Fireball's original target, then checks that the spell
resolves once even if the worker dies just after it lands.
The projectile check kills the worker after Fireball launches and verifies that the missile
hits once on the original client connection.
The hunter-trap checks keep an armed Freezing Trap through both kinds of transfer and verify
that it can freeze the new target once.

## Monitoring

Every `metrics_interval_seconds` each node logs, besides its tick and GC figures, its cluster lines
(`ClusterNode.describe`: the view, the regions it owns and whether its lease holds; on the
coordinator, the cost each node carries; each link's round trip and the duplicates it dropped) and its
services line (`ServiceHost.describe`). Every log line of the cluster code starts with `cluster:`.

## Spell routing limits

Players and creatures can channel periodic healing, timed visuals, and supported stat auras on a
nearby creature named by the spell, including one on another node. Supercharge's damage, haste, and
size bonuses travel together in one aura. The caster's node tracks the duration and sends interruptions
to the creature's node. The target checks the caster's active channel before healing. If the target's
region changes owners, the aura keeps its duration and next tick time. Moving the target out of range
or line of sight ends the channel.
The target's current owner must confirm the channel before completion can grant quest
credit. When a player or creature casting one of these channels moves to another node, its new owner
resumes the original cast and publishes the caster to the target's owner. The aura stays on the
target with its original tick schedule. This requires a clean handoff with the caster's state.

EventAI can select a wounded ally in combat on another node when all the rule's actions are
supported channels aimed at that ally. Leprous Technicians and Machinesmiths use this for
Supercharge and Rebuild. The chosen ally remains the cast target. A channeling creature keeps observing its target
after nearby players leave. A Cultist Engineer can
channel its Buttress visual into a Damaged Necrotic Shard on another node. The target
keeps a single aura while the caster renews it. It expires if the caster's node stops.

Boon of Life can send its final spell hit to Ras Frostwhisper's current owner. The caster confirms
completion, and Ras's owner consumes that cast's token before starting its EventAI relay. A short
record of the expired aura can move with Ras when the two nodes' timers finish in different ticks.
The Glowing Crystal Prison uses the same completion check for its Doomguard Commander.
It applies the taunt immunity and opening threat on the target's node. A completed channel conjures
one prison and removes its target. An interrupt leaves the target in the world.

Cross-node spell routing is effect-specific. A player's cast or item use that selects one nearby creature
can move to that creature's node when the script needs both actors together. The new owner rechecks the
original creature before starting the cast. Database script steps can respawn or despawn a named game
object and open or close a door on its owner. A spell can summon its wild game object on the node
that owns the destination.
Smokey's Special Compound uses both paths for its charge, focus and fires. Timed outdoor objects and
pending forced despawns keep their deadlines in a clean handoff. Outdoor database script steps can
select an observed creature on another node and send its exact command to the owner. This preserves
the original actors for dialogue, emotes, movement, casts, state changes and relay scripts. For
example, each acolyte runs its part of The Binding on its own node. A scripted point movement
keeps the destination and its arrival relay when ownership changes mid-walk. During combat or evade,
the creature keeps its active movement and the route it will resume when it returns home. A creature summoned
by a database script starts on the node that owns its destination. Highlord Demitrian can summon
Thunderaan at his original spawn point across a region boundary. Ground ticks
use observed targets around the spot and require a current caster replica at the target. At impact,
the caster's node resolves the original target GUID locally or sends the hit to the current replica's
owner. A projectile can wait up to two seconds for the target to appear during a handoff. A clean caster
handoff carries pending cross-node projectiles and their impact deadlines with it. The caster's current
node supplies a short-lived replica for impact even when the target's node has no nearby players.
NPC Arcane Missiles also carries its channel aura and remaining pulses with the caster. An interrupt
stops future launches and leaves already launched missiles in flight.

An unfinished player or creature cast resumes after a clean handoff with its original target and
remaining cast time. The new owner also keeps active spell-school lockouts and the player's global
cooldown. A gateway player can resume an unfinished cast after a worker crash. The replacement
uses the original deadline and removes the checkpoint before resolving the cast.
Finite spell cooldowns and explicit resets for gateway players are saved when they change.
The replacement enforces the saved cooldown deadline when the player next casts.
Player projectiles, including supported cross-node spell effects, keep their flight time when
the caster moves or their gateway worker crashes in the same map and copy. The replacement
retires the pending impact before dispatch. Supported direct damage, healing and aura effects can
also follow the target to its new owner.
Player channels with a periodic aura on the caster, such as Arcane Missiles, preserve their
remaining time and next pulse through a handoff or worker crash. Pulses due during the outage
are skipped. A far-seeing gateway player also keeps the original camera viewpoint and sees its
surroundings again after a handoff or worker crash. Canceling removes that checkpoint.
Mind Vision can find a distant player on another node. The target's owner supplies its current
position for the usual spell checks. The caster's body stays at its original position while the
cast starts on the target's node.
The Orb of Draconic Energy moves its user to Emberstrife's node before checking his health and
starting control. Routine balancing waits while a player controls a creature. If the creature's
region is reassigned, control ends before the creature's state moves to the new owner. A forced
player move releases a native creature. Eyes of the Beast can resume after a clean move on the
same map. The hunter controls the same pet at its current position for the rest of the channel.
An angler can finish the original cast after moving. Their bobber keeps its GUID and bite timer
until the catch begins. A replacement worker recovers the same active cast while the original
bite window is still available. Reeling it in closes that checkpoint before rolling the catch.
A hunter's armed trap follows its owner within the same map and copy during a handoff or worker
recovery. It keeps its original expiry, remaining charges and cooldown. A charge is saved as
spent before the trap casts its spell.

Party area auras reach nearby players in the same raid subgroup across region boundaries. The
recipient's node checks membership and distance. It removes the aura when those checks fail or the
source stops renewing it. A login recalculates inherited auras from their current sources.
Windfury and Flametongue Totem also reach the main-hand weapons of remote subgroup members.
A pulse preserves a different temporary enchantment already on the weapon.

When a battleground map moves, the players follow it, including during combat. After a crash,
the new map owner reports the matches it recovered from MariaDB. Unused invitations stay valid for
matches that recovered and those that had yet to open. The queue closes missing copies, clears
their slots, and returns affected players to their entry points.
After the gateway reloads a player, the queue rebinds their delivery route and sends their
current tickets. A worker loss gives recovering players time to reclaim their places within
the original invitation deadline.

## Testing

Run `python3 tools/harness/queue_failover.py` to check queue host loss with an open invitation, and
`python3 tools/harness/queue_failover.py --active-match` to check map host loss during Warsong Gulch.

The cluster code is tested in memory: links wired back to back and a fake clock, with whole clusters
of world contexts (joining, views, heartbeats, timeouts, restarts and fencing; handovers with no cell
ever having two owners on any 50 ms tick; replicas, migrations, takeovers, drains, splits and merges;
services moving). The [developer guide](DEVELOPING.md#a-local-cluster) describes testing a local cluster, and
docs/BENCHMARKS.md has the cluster's measurements.

## Background

The cluster's development log, phase by phase with the live tests of each, is archived in
docs/research/CLUSTER-HISTORY.md. It is not needed to understand the cluster as it is.
