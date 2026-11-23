# Cluster services

A **cluster service** is a responsibility with an identity of its own that belongs to no place in
the world: the chat channels, the battleground queues, the Ahn'Qiraj war effort, world PvP. The cluster (docs/CLUSTER.md) places each
service on one node, and every node calls it by what it is, not by where it runs. A call to a
service on the caller's own node is a direct function call; a call to one on another node goes over
the cluster's links and its reply comes back the same way. Callers do not know which it was.

The code is `cluster/services.d`. The services are `ChannelsHost` (`world/channelservice.d`),
`BattlegroundQueueHost` (`world/bgqueue.d`), `WarEffortHost` (`world/wareffort.d`) and `WorldPvpHost`
(`world/worldpvp.d`).

## Why services

Much of what a cluster coordinates is tied to a place: a creature, a dungeon copy, a player standing
somewhere. That is handled by regions, which move with the load. A few things are tied to no place
and to players anywhere: a chat channel's members can be on every node, and a battleground queue
gathers players from every node into one copy. Each needs exactly one authoritative instance, a way
for every node to find it, and a way to survive its node's loss. Services give that once, for any
such responsibility, instead of a message pair, a routing rule and a takeover step written by hand
for each.

The service layer is not on the simulation's hot path. It is called for channel commands and queue
changes, not per tick per entity.

## Declaring a service

A service is a D struct marked `@Service(ServiceKind.x)`. Its methods marked `@Call` are what it
can be asked. Each takes one plain-data request struct (`dmangos.plaindata`: numbers, strings,
arrays and structs of them) and returns a plain-data reply, or nothing.

```d
@Service(ServiceKind.channels)
struct ChannelsHost
{
    ChannelService channels;

    /// A player's channel command.
    @Call void run(const ref ChannelCall call)
    {
        channels.run(call.command, call.via);
    }
}
```

A service may also have:

* `start()`, run when its host starts it;
* `tick(Duration)`, run every world tick of its host;
* `stop()`, run when it is released;
* `saveState()`, returning bytes that go along with the service when it moves, from which the next
  host's factory rebuilds it. The channels and the queues have none (they start empty after a move);
  the war effort's is its whole state.

Everything about the calls is worked out at compile time, by `static foreach` over the `@Call`
methods:

* **Checks.** A call that takes more than one argument, or a request or reply that is not plain data,
  fails to compile.
* **Call ids.** Each call's id is an FNV-1a hash of its service kind, its name, and the layouts of its
  request and reply (`callId`). Two builds that disagree on any of them disagree on the id, so a call
  between them is refused (`unknownCall`) rather than misread.
* **The dispatcher** (`Hosted!S.dispatch`) runs a call from its request's bytes and writes its
  reply's. There is no virtual dispatch per call and no registry filled at run time.

The kinds of service are an enum, `ServiceKind`: `channels`, `battlegroundQueue`, `warEffort`, `worldPvp`,
and `example` for tests. `clusterServiceKinds` lists those a cluster places.

## Hosting

Each node has a `ServiceHost` (`WorldContext.services`):

* `provide!S(make)` tells it how to build a service of type `S`, from the state its last host saved
  or from nothing. Every world server provides both services.
* `start(kind, state)` and `stop(kind)` host a service here, or release it (returning its state).
* `hosts(kind)` and `local!S()` say whether it runs here.
* `tick` runs every hosted service's `tick` and resends parked calls (below).

A standalone server starts every service it provides (`startAllServices`), and every call is a
direct call. A cluster node first stops them all and then runs only the services whose regions it
is granted.

## Placement: a service is a region

Each service kind is a one-cell region on a map of its own: map `0xFFFF0000 | kind`
(`serviceMap`). The coordinator appends these regions to its partition of the world at start-up
(`serviceRegions`), so the cluster's ownership machinery places services exactly as it places parts
of the world:

* the coordinator deals each one out to a node under a lease, with an epoch;
* it is released by one node before it is granted to another;
* it is moved off a lost node once that node's lease has run out;
* a standby that takes over adopts the table with the services in it;
* load balancing may move it, though it has little reason to: a service region starts with a cost of
  1 and measures as nothing, since no map cells belong to it. It cannot be split (it is one cell),
  and merges only join regions that came from splits.

A gateway node (docs/CLUSTER.md) is never granted a service.

Every node holds a copy of the region table, so every node knows where each service runs with no
round trip: `regions.ownerAt(serviceMap(kind), 0)`. When a node's regions change
(`WorldContext.regionsChanged`), a service region it lost is stopped, its `saveState` bytes going
along with the region to the next owner; a service region it gained is started from the bytes that
arrived with it. Both are logged (`services: channels runs here`, `services: channels moves to node
2`).

## Calling a service

```d
context.services.call!(BattlegroundQueueHost.port)(BattlegroundPort(guid, context.nodeId, type, enter),
    (BattlegroundEntry entry) { ... });
context.services.call!(ChannelsHost.run)(ChannelCall(command, nodeId));   // no reply
```

* **Here.** If the service runs on this node, the method is called with the request struct and the
  continuation gets the reply at once. Nothing is encoded or allocated beyond what the method itself
  does.
* **Elsewhere.** The request is encoded and sent as a `ServiceCall` message (service kind, call id,
  origin node, sequence number, request bytes) to the node the region table names. That node answers
  with a `ServiceReply` (kind, sequence, status, reply bytes), and the continuation runs when it
  arrives.
* **Nowhere.** While the service is placed on no node (it is moving, or its node was lost and its
  lease has not run out), or there is no link to its node, the call is **parked**. Every tick parked
  calls are sent again to wherever the table now says.
* **Moved.** A node that no longer hosts the service answers `notHere`; the caller parks the call and
  sends it again where the table says.
* **Lost.** When a peer is lost, every call sent to it and not yet answered goes back to parked.
* **Given up.** A call unanswered after 30 seconds is dropped and logged.

Because a call may be sent twice (after `notHere`, or after its node was lost while the reply was
on its way), the host remembers its last 4096 answers by (origin node, sequence number). A call it
has answered before is answered again from memory and not run twice. A clean handoff carries the
service's cached replies to the new host, including when that host is the original caller. No epoch travels with a call:
a node hosts a service only while it holds the service region's lease, and stops it when it loses
it, so a call reaching a node that is no longer the host gets `notHere`.

Links between nodes deliver each direction in order (docs/CLUSTER.md), so the calls one node makes
to a service arrive in the order they were made, behind every other message that node sent first.

## News: from a service to every node

A call goes to the service; some services must also tell every node something, without being asked: a
state that every node follows (the war effort's phase starts game events, spawns objects and changes what
players in the capitals see, on whichever node simulates them). That is **news**:

```d
services.listen!(WarEffortHost, WarEffort)(&warEffortHeard);   // every node, at start-up
services.announce!WarEffortHost(state);                        // the service, on its node
```

* `announce!S(news)` runs this node's listeners for that type of news at once, with the struct as it is,
  and sends it as a `ServiceNews` message (kind, `newsId`, bytes) to every other linked node, whose
  listeners hear it decoded. The news id is a hash of the service kind and the news's layout, as for calls.
* Links deliver in order, so a node hears one host's news in the order it was given. A node not linked
  at the time misses it: a service whose state nodes follow sends its whole state each time, repeats it
  now and then, and answers a call for it, so a node that comes late asks once and then listens.

## The services

### Chat channels

`ChannelsHost` wraps `ChannelService`, which holds every channel of both teams. Its one call,
`run`, takes a `ChannelCommand` and the node it came from. A player's channel command (joining,
leaving, talking, the list, passwords, moderation, kicks, bans, invitations; and logging out or
changing zone, which leave or move zone channels) becomes a call through
`WorldContext.channelCommand`. The command carries what the channels need of the player: guid,
name, race, chat tag, honor rank (for the defense channels) and whether it may moderate every
channel (a GM permission). Checks that belong to the player's
node (names, the GM client channel) are made there before the call.

What a channel says to a member goes to the member's node: the one presence says simulates it
(docs/CLUSTER.md), or failing that the node its last command came from. When a node is lost,
members whose sessions moved to another node stay in their channels. Members whose sessions ended
leave as if they had logged out. A planned move preserves members, ownership, bans, and
channel settings. Clients already in a channel can keep talking without rejoining. Losing the service
host before it can hand off still empties its channels.

### Battleground queues

`BattlegroundQueueHost` holds every player's queue slots (up to three each), the invitations, and
the running copies of each battleground with their room. Players' nodes call `join`, `joinGroup`,
`port` (accept or decline an invitation), `status`, `logout` and `list`. The node running a copy
calls `left`, `changed` and `invited`, and `forceStart` serves `.battleground forcestart`. A copy is
made, or room in a running one filled, as players join; the service's `tick` reminds players of
invitations and expires them after 80 seconds. What the queue tells a player goes to the player's node.

A battleground map, like a dungeon, is one region, so one node runs every copy of it. A player
accepting an invitation moves to that node, as for a dungeon. A planned service move carries the
queue order, groups, player slots, invitations, wait averages and running copies. Timers resume with
their remaining time on the new host's clock. If the old host is lost before it can hand off, the
service starts with empty queues.

### The Ahn'Qiraj war effort

`WarEffortHost` (`world/wareffort.d`) holds the war effort (`WarEffort`: the phase, when it ends, the
thirty resource counters, the piles' tier while the supplies are carried, the fallen Colossi). The officers'
scripts call `contribute` when a resource quest is turned in, the Scarab Gong's calls `gong`, and a Colossus
dying calls `colossusDied`; `current` answers a node starting. Its `tick` moves the timed phases on
(five days of carrying, the ten-hour war).

Every change is saved to the characters database (`world_state`, row 1, in CMaNGOS's text, through the
writes behind the game loop) by the node hosting it, and announced to every node as news (the whole
`WarEffort`), and again once a minute. Each node keeps what it heard (`WorldContext.warEffort`) and follows
it: it starts and stops the phases' game events (120 to 124, and 125 to 127 for fallen Colossi) through
`GameEvents.start`, brings and takes away the piles of supplies (a spawn's presence is worked out from the
state), and sends the capitals' world states to its own players as they change. After a move the service
goes on with the state it moved with; started anew (first grant, or its node lost), it reads the row.

### World PvP

`WorldPvpHost` (`world/worldpvp.d`) holds the state of 1.12's world PvP (`WorldPvp`): each Eastern Plaguelands tower's
slider, holder and how often it was taken, and Silithus's Silithyst counts and favored side.

**Why a service, not the node that owns the zone.** A tower is taken by the players within 80 yards of it, and those
need not be on one node: regions split maps, and a player near a border stays on the node it came from until the ground
25 yards around it is another's (docs/CLUSTER.md). A zone's buffs reach players in another map too (Echoes of
Lordaeron in Stratholme, Cenarion Favor in the Ahn'Qiraj raids), which a dungeon's node runs. And the turn-ins in
Silithus come from wherever its camps are simulated. So the state is a service, placed like the others, and the
nodes report to it:

* Each node counts, once a second, the players it simulates at each tower (alive, flagged for PvP, not stealthed or
  invisible) and calls `present` with its counts when they change, and every 5 seconds while any are there. The
  service sums the reports it has had in the last 15 seconds (a lost node's players stop counting when its report
  ages out) and moves the sliders once a second.
* A turn-in at a camp calls `silithyst` from the player's node.
* `current` answers a node starting.

The service announces the whole state as news at every change a client would see (a holder, a map state, the
slider's whole percent, a count), and once a minute besides. Each node keeps what it heard
(`WorldContext.worldPvp`, a `WorldPvpFollower`) and follows it for what it simulates: its players' world states (the
map's tower states, the towers held, the capture bar, the counts) and buffs (Echoes of Lordaeron by towers held,
Cenarion Favor), the banners' art kits, Crown Guard's graveyard, Northpass's shrine (a spawn present or not, as the
war effort's piles). A tower taken (its `taken` count went up) rewards that node's players counted there and tells
its players in the zone; the node that simulates the tower's capture point runs the capture's event script (the
flight master, the squad), and a lost tower's are taken away there. A Silithyst count reaching a quarter, half or three
quarters of the goal has the side's camp announcer say so where a node simulates it, and a race won has it cheer and
the node's players in Silithus told in the defense channel. A node hearing the state for the first time
follows it without the rewards and events, which happened before it listened.

**Not saved.** 1.12 kept neither zone's state over a restart ("A server reboot will reset the battle", of Silithus),
so the service has no row in `world_state`: it moves with its state (`saveState`), and starts anew on a first grant
or when its node is lost.

## Gateways

A gateway (`cluster.gateway`) is a node that holds client connections and simulates nothing: it is
granted no regions and no services. Its players are simulated wherever they stand, through the
home-node relay (docs/CLUSTER.md), and while any gateway is linked the coordinator points the realm
list at the least busy gateway. The coordinator and the standby cannot be gateways.

## Monitoring

Each node's metrics line includes a services line (`ServiceHost.describe`): the services it hosts,
and its calls so far, counted as local, sent, served, repeated (answered from memory), given up, and
waiting.

`tools/servicebench.d` measures a call with a request the size of a channel command:

* answered on the caller's own node: **23 ns**, a direct method call;
* through the remote path over an in-memory link: **1.7 µs**, for encoding, dispatching from bytes,
  the reply cache and decoding.

On a real network the round trip dominates a remote call.

## Adding a service

1. Add a kind to `ServiceKind`, and to `clusterServiceKinds` if a cluster should place it.
2. Write the struct with `@Service(kind)`, its `@Call` methods over plain-data requests and replies,
   and `tick`, `stop` or `saveState` if it needs them.
3. `provide!` it in `WorldContext`'s constructor (and `listen!` for its news, if it has some).
4. Call it through `context.services.call!(S.method)`, which works the same standalone and in a
   cluster.

## Background

The design research behind this layer is archived in docs/research/SERVICES-RESEARCH.md. It is not
needed to understand or change the services.
