# Cluster services

How the cluster (docs/CLUSTER.md) gets **logical services**:
* responsibilities with an identity of their own, such as chat channels, groups, the battleground
  queue and the login gate;
* placed on nodes by the coordinator and addressed by what they are, not by where they run;
* called directly when they are local, and over the cluster's links when they are not.

The design draws on two references:
* Blizzard's patent US10086279B2, *Cross-realm zones for interactive gameplay*;
* Ryzom Core's service architecture, read from its source.

It keeps the cluster as the foundation. There is still one process type, the world node, still regions
under leases, and still one cluster manager.

Decided with the user on 2026-11-17: do this before battlegrounds, which are its first real
customer.

## 1. What the references show

### Blizzard's patent (US 10,086,279 B2; parent US 9,220,982 B2)

The patent describes realms, whose world servers are made of "virtual servers", each responsible
for zones. A message router hides the server-side components from the client. Cross-realm zones
are instances of a zone shared by a subset of realms.

What the claims actually require is narrow:
* **'279 claim 1** is the border handshake into a zone that runs as several concurrent instances on
  different servers, each instance with its own objects. A character within a threshold distance
  is sent to the chosen instance's server with its location, is made visible there, and the client
  is sent the instance's objects to preload before crossing.
* **'982** claims a table mapping groups of realms to zone instances. The table is changed when an
  instance's population passes a threshold, and an instance whose group is empty is stopped.

Everything else is an embodiment ("may", "in one embodiment"), not a statement about WoW's
production servers:
* owner lookup by a deterministic function or a stored, replicated decision;
* a realm-group tree, split going down and merged going up;
* players already inside left in place, or moved, when a mapping changes;
* per-instance corpses;
* parties placed by their leader's realm;
* dungeons and battlegrounds on separate instance servers.

What our cluster already has of it:

| Patent | Here |
|---|---|
| Virtual servers for zones | regions owned by nodes under leases (`cluster/ownership.d`) |
| Buffer region, preload, visible before entry | the overlap band: replicas of everything near a border (phase 3) |
| Transfer of management on entry | player and creature migration (phase 4) |
| Split and merge by population | load balancing by measured cost, region splits and merges (phase 6) |
| Owner lookup without a round trip | the region table, replicated to every node |
| Message router hiding the topology | the home node: the client's connection, with the character simulated anywhere (phase 3b) |
| Instance servers for dungeons | dungeon copies hosted whole by one node (`IdKind.instance`) |

**Caution.** '279 claim 1 needs a *destination zone run as several concurrent instances with
different objects*. Our open world has one owner per region, so it does not meet that element. We
should not run several concurrent copies of an open-world zone with a border handshake into them
without a legal check first (the patent is estimated to expire in 2032). Battleground and dungeon
copies are private instances entered by portal, which the patent treats separately.

### Ryzom Core

A Ryzom shard splits **by function**:
* the frontends (FS), several, which hold client connections;
* one Entities Game Service (EGS) with every player and rule;
* AI services (AIS), one per continent, assigned by command line;
* one Global Position Manager (GPMS) for vision;
* one Tick Service (TS) that holds every service to a global TICK/TOCK barrier;
* one Mirror Service (MS) per machine, sharing entity properties through shared memory and deltas;
* one Input/Output Service (IOS) for chat and strings;
* a Backup Service (BS) master/slave pair for files.

Around the shard sit a Naming Service (a directory), a Welcome Service (the login placement), the
Shard Unifier (domain-wide services) and an Admin Executor per machine (supervision).

What its source shows about how this works:
* **It runs in lockstep.** The shard runs at its slowest service's speed. A stall in the EGS stalls
  everything.
* **The EGS, TS and GPMS are single points of failure.** The shard does not survive losing them.
  Losing a machine's mirror takes the whole machine down.
* **Routing is hard-coded by service name** (`send("EGS", …)`), which assumes singletons.
* **Messages are unversioned**, except its "transport classes", which exchange their field lists
  when a link comes up.
* **What is good:**
  * the Naming Service's up/down callbacks;
  * its keep-links-while-the-directory-is-down rule;
  * `sendMessageViaMirror`: a message delivered after the state changes of the same tick;
  * the Welcome Service's placement by load;
  * the Admin Executor's restarts with backoff and its chain-crash detection.

### What we take, and what we do not

* **Take:**
  * a directory of services with up/down events, in the coordinator, which every node mirrors;
  * placement by load;
  * messages for a service ordered behind the state they depend on: per-peer FIFO links already
    give this, and it must stay so;
  * a gateway role, the patent's router and Ryzom's frontend, as a node that holds connections;
  * supervision outside the server (documented, not built).
* **Do not take:**
  * splitting by function (EGS/GPMS/AIS): one process type, split by region, is the better axis;
  * a global tick barrier;
  * a shared mirror of all properties;
  * name broadcast without ownership;
  * static assignment by configuration.

## 2. The cluster today (what services must build on)

* **Nodes and the coordinator.**
  * One process type.
  * A coordinator admits members and keeps the view.
  * It grants regions under leases with epochs, hands out id blocks, and balances by measured cost.
  * A standby takes over within the failure timeout.
* **Ownership** is per region, with epochs and fencing (`cluster/ownership.d`, `world/fencing.d`).
  Queued writes carry the lease time (`world/writebehind.d`).
* **Links** are TCP, one per pair of nodes. They carry framed, versioned binary messages
  (`cluster/protocol.d`, protocol 27; the whole cluster speaks one version). A link is a FIFO in
  each direction.
* **Cross-node features** are reached through about 20 hooks on `WorldContext`, wired by hand in
  `world/main.d` to `world/clusterbridge.d`:
  * `forwardChannel`, `forwardGroup`;
  * `whisperRemote`, `deliverRemote`;
  * `reserveStock`, `killShareElsewhere`;
  * `guildBroadcastElsewhere`, `signalElsewhere`;
  * and more.

  Each is its own pair of message types (45 types). Receiving them is one large `ReplicationHandler`
  interface and a `switch`.
* **Services that exist in all but name, all fixed to the coordinator:**
  * chat channels (`world/channelservice.d`);
  * groups;
  * one login per account (`cluster/sessions.d`);
  * id blocks;
  * realm steering.

  The standby's takeover has a hand-written step for each one (`onPromoted` in `world/main.d`).
* **Idempotency** is per feature. Script signals carry an origin node and a sequence number; kill
  shares and stock have their own rules.

What this costs. A new cross-node feature, such as the battleground queue, would need:
* a message pair and a protocol bump;
* bridge code, a hook and wiring in `main.d`;
* a takeover step;
* a dedupe rule.

There is no common notion of where a service runs, whether it is up, or how to reach it. Nothing
but the coordinator can host one.

## 3. Design

### Services

A **service** is a D struct marked `@Service(ServiceKind.x)`. Its methods marked `@Call` are what it
can be asked. Each takes one plain-data request struct and returns a plain-data reply (or nothing).

```d
@Service(ServiceKind.battlegroundQueue)
struct BattlegroundQueue
{
    @Call JoinResult join(const ref JoinQueue request);   // a player asks for a battleground
    @Call void leave(const ref LeaveQueue request);
    void tick(ServiceContext ctx, Duration elapsed);      // optional: driven by its host's loop
    void recover(ServiceContext ctx);                     // optional: rebuilt after it moved
}
```

* **The dispatcher is generated at compile time** (`static foreach` over the `@Call` methods),
  together with each call's id and a layout fingerprint, as `writebehind.d` does. There is no
  virtual dispatch and no registry filled at run time.
* **Serialization** is `dmangos.serialization`, which already serves packets and cluster messages.
* **A call to a local instance** is a direct function call with the request struct: nothing is
  serialized, and nothing is allocated beyond what the method itself does.
* **A call to a remote instance** is one generic cluster message, `ServiceCall` (service, call id,
  placement epoch, origin node, sequence number, bytes), and `ServiceReply` back. Both go over the
  existing links.

### Placement and lifecycle

* **Services are regions** (as built in stage 2). Each service kind is a one-cell region of a map of
  its own (`serviceMap`, from `0xFFFF0000`). So the existing ownership machinery places it, with no
  second table and no second cluster manager:
  * the coordinator deals it out by load, under a lease, with an epoch;
  * it is released before it is granted elsewhere;
  * it is moved off a lost node after that node's lease;
  * the standby adopts it, and balancing may move it.

  Every node's copy of the region table says where each service runs
  (`regions.ownerAt(serviceMap(kind), 0)`), with no round trip. A node that gains a service's region
  starts the service, from the state its last host sent along with the region (`saveState`). A node
  that loses it stops the service and sends that state on. A one-cell region cannot be split, and
  merges only touch regions that came from splits.
* **Placement** is by configuration (`cluster.services`: which node may host what) and else by
  load: the least busy eligible node. A service moves:
  * when its node is lost (after that node's lease, as with regions);
  * when the coordinator rebalances;
  * on a GM's request.
* **Lifecycle on a node:**
  * `start` when it is granted;
  * `recover` after a move (state rebuilt from the database, or from what the other nodes announce
    again, as channels and session claims are today);
  * `tick` each world tick of its host;
  * `stop` when released.
* **Up and down events** go to every node when a service's placement changes. Callers park calls
  while a service is down, and resend them under the new epoch.
* **Authority** is one instance per kind, by default. A kind may be **partitioned** by a key, such as
  battleground instances by id, as regions are by cell. The table then maps key ranges to nodes.
* **Consistency.** Calls carry the placement epoch, so a call to a stale placement is refused and
  resent. Each call carries `(origin node, sequence)`, so a duplicate after a resend is answered from
  a small reply cache, not done twice. Nothing assumes exactly-once delivery.
* **Ordering.** A service's calls from one node arrive in order, because the links are FIFO, so a
  call never overtakes the replication it depends on. That is Ryzom's `sendMessageViaMirror`, which
  we get for free.

### Deployment

* **One executable.** A standalone server hosts every service locally, and every call is a direct
  call. This is what tests and single-machine setups run.
* **Several nodes.** Services spread by the table.
* **A gateway node** (`cluster.role = "gateway"`) owns no regions and hosts no simulation. It holds
  client connections and relays, the patent's message router and Ryzom's frontend. The home-node
  relay already does this; a gateway is a home node that is never also an owner. It is the
  prerequisite for surviving the loss of a simulation node without a disconnect (CLUSTER.md, "Later").
* **Several processes on one machine**, as now: one per node.

### What stays as it is

* The world simulation, its tick and its maps.
* Regions, their replication and migration.
* The write-behind database layer.

The service layer is not on the simulation's hot path: services are called for queues, chat and
groups, not per tick per entity.

## 4. Stages

1. **Service foundation (done 2026-11-17)** (`cluster/services.d`):
   * `@Service` and `@Call`, the generated dispatcher, local calls;
   * a `ServiceHost` per node that runs `start`, `tick` and `stop`;
   * a standalone server that hosts everything.

   Tests: local calls, the generated ids, the fingerprints.
2. **Placement in the cluster: done (2026-11-17).** Services are regions of maps of their own,
   appended to the coordinator's partition (`clusterServiceKinds`).
   * `WorldContext.regionsChanged` starts and stops them, carrying their state.
   * A standalone server starts every service it provides (`startAllServices`).
   * Tests: a three-node cluster in memory, where the service goes to one node, is moved off it when
     it is cut off after its lease, and is never on two nodes at once.
   * Live, the 74 world regions became 76.
3. **Remote calls: done (2026-11-17).** `ServiceCall` and `ServiceReply` (protocol 28) go over
   the existing links.
   * The caller routes by the region table: here directly, elsewhere as bytes.
   * A call waits (parked) while its service is nowhere, and goes once it is somewhere.
   * A node that no longer hosts a service answers `notHere`, and the call is sent again where the
     table says.
   * Calls to a lost peer go back to waiting. Calls unanswered after 30 s are given up and logged.
   * The host keeps the last 4096 answers by (origin, sequence), so a resent call is answered again
     and not run twice.
   * No epoch is carried: a node hosts a service only while it holds that region's lease, and stops
     when it loses it.
   * Tests: two hosts with in-memory transports, covering a call and its reply, a parked call sent
     once placed, a duplicate answered from memory, and a call following its service to a new node.
4. **The first service, chat channels: done (2026-11-17).** `ChannelsHost`
   (`@Service(ServiceKind.channels)`) wraps the existing `ChannelService` with one call, `run`, which
   takes a `ChannelCommand` and the node it came from. `WorldContext.channelCommand` is now a service
   call, so these went:
   * the `forwardChannel` hook;
   * the coordinator-only routing, and its message's handling in `ClusterNode` and the bridge;
   * the standby's channel takeover step.

   Every context starts its services, as standalone; a cluster node stops them and runs only those
   whose regions it is granted. After a move the channels start empty, as after a coordinator
   takeover before.
   * Tests: two world contexts with the channels on node 2, where node 1's player joins (answered
     across) and hears node 2's player. The existing channel tests run unchanged.
   * Live: two scripted clients simulated on nodes 1 and 3 talked in one channel, hosted on a third
     node's choice.
5. **The battleground queue**, placed by the table: the first new service, with battlegrounds.
6. **The gateway role:** a node with clients and no regions.
7. **Monitoring:**
   * services and their placement in the metrics line and in `cluster.describe`;
   * calls a second, local and remote;
   * a two-node benchmark of chat calls.

Later stages may move groups, session claims, id blocks and guild broadcasts onto services, where
it removes code. Each move is judged on its own.
