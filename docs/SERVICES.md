# Cluster services

A **cluster service** is a responsibility with an identity of its own that belongs to no place in
the world: the chat channels, the battleground queues. The cluster (docs/CLUSTER.md) places each
service on one node, and every node calls it by what it is, not by where it runs. A call to a
service on the caller's own node is a direct function call; a call to one on another node goes over
the cluster's links and its reply comes back the same way. Callers do not know which it was.

The code is `cluster/services.d`. The services are `ChannelsHost` (`world/channelservice.d`) and
`BattlegroundQueueHost` (`world/bgqueue.d`).

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
  host's factory rebuilds it. Neither existing service has one: both start empty after a move.

Everything about the calls is worked out at compile time, by `static foreach` over the `@Call`
methods:

* **Checks.** A call that takes more than one argument, or a request or reply that is not plain data,
  fails to compile.
* **Call ids.** Each call's id is an FNV-1a hash of its service kind, its name, and the layouts of its
  request and reply (`callId`). Two builds that disagree on any of them disagree on the id, so a call
  between them is refused (`unknownCall`) rather than misread.
* **The dispatcher** (`Hosted!S.dispatch`) runs a call from its request's bytes and writes its
  reply's. There is no virtual dispatch per call and no registry filled at run time.

The kinds of service are an enum, `ServiceKind`: `channels`, `battlegroundQueue`, and `example` for
tests. `clusterServiceKinds` lists those a cluster places.

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
has answered before is answered again from memory and not run twice. No epoch travels with a call:
a node hosts a service only while it holds the service region's lease, and stops it when it loses
it, so a call reaching a node that is no longer the host gets `notHere`.

Links between nodes deliver each direction in order (docs/CLUSTER.md), so the calls one node makes
to a service arrive in the order they were made, behind every other message that node sent first.

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
(docs/CLUSTER.md), or failing that the node its last command came from. A lost node's players leave
their channels as if they had logged out. After the service moves, channels start empty; players
join again when they next log in or change zone.

### Battleground queues

`BattlegroundQueueHost` holds every player's queue slots (up to three each), the invitations, and
the running copies of each battleground with their room. Players' nodes call `join`, `joinGroup`,
`port` (accept or decline an invitation), `status`, `logout` and `list`. The node running a copy
calls `left`, `changed` and `invited`, and `forceStart` serves `.battleground forcestart`. A copy is
made, or room in a running one filled, as players join; the service's `tick` reminds players of
invitations and expires them after 80 seconds. What the queue tells a player goes to the player's node.

A battleground map, like a dungeon, is one region, so one node runs every copy of it. A player
accepting an invitation moves to that node, as for a dungeon. After the service moves, the queues
start empty: invitations are lost and running copies are not refilled.

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
3. `provide!` it in `WorldContext`'s constructor.
4. Call it through `context.services.call!(S.method)`, which works the same standalone and in a
   cluster.

## Background

The design research behind this layer is archived in docs/research/SERVICES-RESEARCH.md. It is not
needed to understand or change the services.
