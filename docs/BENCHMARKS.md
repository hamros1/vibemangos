# Benchmarks

Measurements of the standalone world server under load: the baseline the cluster is compared
against (docs/CLUSTER.md), and the guide to where performance work goes.

## Method

* **Load:** `bin/loadgen` (`dub build -c loadgen`), many headless 1.12 clients in one process. Each
  logs in with a session key the generator puts in the login database (the login server stays out
  of the measurement), enters the world as a human warrior, and plays like a player: runs at
  6.5 yards a second between points with a heartbeat every 500 ms, stops for up to 3 seconds, says
  something on average once a minute and pings every 30 seconds. It reads and decrypts everything the
  server sends.
* **Scenarios:** `crowd` (everyone within 30 yards of Goldshire, running within 15 yards of where they
  entered), `spread` (each at a random creature spawn of the two continents, running within 30
  yards), `travel` (each at a random creature spawn, running 300 yards out and back), `idle` (as
  spread, standing still, no chat). Logins ramp at 50 a second; measuring starts 10 seconds after the
  last one and lasts 60 seconds.
* **Server side:** the server's own `metrics:` lines every 5 seconds (`metrics_interval_seconds`):
  tick time, **event loop busy time** (packets, tick and sending: the tick alone leaves out the
  packet handling, which is most of the work in a crowd), GC collections, pauses and bytes allocated,
  players and objects. CPU time and memory from `/proc`. `tools/bench.sh` runs one scenario against
  a freshly started server.
* **Machine:** Intel i9-13900K (32 threads), 31 GiB, Linux 6.14; server, MariaDB and load generator on
  the same machine. The server's loop is single-threaded, so 100% (one core) is its budget; the D GC
  marks with several threads, which is why CPU can exceed 100%.
* **Caveat: variance.** Two identical runs of a 500-player crowd gave the same allocation
  (2.48 and 2.49 MB a tick) and loop busy time (13.5% and 14.3%), but CPU of 47% and 63%, GC pauses
  of 664 and 951 ms and a ping p99 of 7 and 51 ms: those depend on when collections fall. Compare
  allocation and busy time; treat CPU, pauses and tail latency within about a third as noise. The
  load generator stayed under 60% of a core in every run, so it was not the bottleneck.

## Baseline (before any optimization)

| Scenario | Bots | Loop busy | Tick avg | Ping p99 | CPU | Allocated per tick | GC per minute | Worst loop iteration |
|---|---|---|---|---|---|---|---|---|
| crowd | 100 | 1.2% | 0.03 ms | 0.66 ms | 3% | 0.20 MB | 1 collection, 41 ms paused | 42 ms |
| crowd | 250 | 4.5% | 0.07 ms | 2.31 ms | 25% | 1.16 MB | 8, 401 ms | 54 ms |
| crowd | 500 | 15.0% | 0.26 ms | 13.5 ms | 74% | 4.97 MB | 27, 1150 ms | 52 ms |
| crowd | 900 | 48.9% | 2.6 ms | 3372 ms | 197% | 16.3 MB | 69, 2970 ms | 81 ms (3.7 s during logins) |
| spread | 500 | 8.2% | 3.42 ms | 1.03 ms | 9% | 0.15 MB | none | 6 ms |
| travel | 500 | 10.4% | 4.34 ms | 1.61 ms | 15% | 0.19 MB | 1, 75 ms | 78 ms |
| idle | 500 | 6.3% | 2.96 ms | 1.27 ms | 7% | 0.07 MB | none | 5 ms |

The idle run had 23,116 creatures and game objects loaded; memory was 360 MiB with a crowd and
565 to 636 MiB with players spread out (cells loaded across both continents). Logins took 5 to
20 ms (median) until the server was overloaded.

## What the baseline shows

1. **Crowds cost by the square of their size, and the garbage collector pays most of it.** Every
   movement packet is relayed to everyone who sees the mover, so 500 players in one place mean about
   500,000 deliveries a second. Each delivery allocated a framed copy of the packet and was copied
   twice more on its way to the socket: 5 MB allocated per tick at 500 players, 27 collections a
   minute, and a process using 74% of a core while its loop was busy only 15% of the time. At 900 the
   server falls behind (ping p99 of seconds) and the backlog makes it worse.
2. **Players spread out cost by the creatures around them.** Every cell a player has been near stays
   loaded and its creatures tick forever (cells are never unloaded yet): 500 players loaded 23,000
   objects, which take 3 ms of every 50 ms tick, about 130 ns each. This is the cost spatial
   partitioning divides between nodes directly; unloading idle cells would cut it on one node too.
3. **The worst latency is a GC pause.** Every scenario with collections has a worst loop iteration
   of 40 to 90 ms, the length of one collection. The heap is 360 to 640 MiB, mostly static data
   (world, client and terrain data) that every collection scans; fewer collections help, and so would
   keeping static data out of the scanned heap.
4. **Logins into a crowd stall the server.** With 900 players logging into one place, one loop
   iteration took 3.7 seconds, all of it receiving and handling packets, while no single packet took
   over 200 ms and the tick took nothing. Each login builds and compresses the newcomer's create block
   once per player who sees it, and sends the newcomer one compressed packet per player already
   there: about 1,800 zlib compressions per login in a crowd of 900. (Confirmed below.)
5. **The event loop is capped at 1000 connections** (`max_connections`), because it uses `select`,
   which also scans every socket on every iteration. (Lifted since: see "epoll instead of select".)
6. **The speed check misfires under overload:** queued movement packets arrive together, so a
   player seems to have covered 16 yards in no time and is put back.

## First optimization: framing in place

From finding 1, the delivery path: `appendPacket` frames a packet straight onto the receiving
session's output (no temporary array and one copy instead of three), the server adopts a session's
output array as its send buffer instead of copying it, and `NetSession.takeOutput` now hands the
array over (cluster links included).

| Crowd | Allocated per tick | GC per minute | CPU | Ping p99 | Loop busy |
|---|---|---|---|---|---|
| 250 | 1.16 → 0.61 MB | 8 → 4 collections, 401 → 191 ms | 25% → 14% | 2.3 → 3.1 ms | 4.5% → 4.4% |
| 500 | 4.97 → 2.49 MB | 27 → 14, 1150 → 671 ms | 74% → 48% | 13.5 → 10.9 ms | 15.0% → 13.9% |
| 900 | 16.3 → 7.5 MB | 69 → 36, 2970 → 1726 ms | 197% → 131% | overloaded either way | 48.9% → 44.4% |

Allocation and collections halved; the 3.7 s login stall did not change, so allocation was not its
cause (finding 4).

## Second optimization: logins into crowds

Profiled with `tools/gdb-sample.py` (300 samples at 10 Hz while 900 players logged into one
place; `perf` is not available on the test machine). Of the busy samples, 57% were in
`Map.updateVisibility` called from the login handler: 30% compressing (zlib's `deflate_slow`) and
20% building create blocks (`appearanceFor`, `UpdateValues.writeCreate`). Relaying movement was
26%.

The fix, in `Map.updateVisibility`:

* A player's create block comes in two versions only, a stranger's view and a group member's
  (`Inhabitant.appearanceKind`), so it is built and compressed once per version and the same bytes go
  to everyone who gets that version, instead of once per viewer.
* The blocks a newcomer receives go out together, as many as fit in 32 KB before compression
  (the largest packet the client takes, less a reserve), instead of one packet each.
* Update packets are compressed at zlib level 1, not zlib's default 6. `compression` in the configuration sets it.

| Crowd of 900 | Before | After |
|---|---|---|
| Login, median / max | 92 ms / 7.2 s | 16 ms / 115 ms |
| Ping p99 / max | 3.4 s / 4.6 s | 65 ms / 78 ms |
| Worst loop iteration | 3.8 s (during the logins) | 75 ms (a GC pause) |
| Loop busy, steady state | 44.4% | 44.9% |
| Allocated per tick | 7.5 MB | 7.4 MB |

The stall is gone: no iteration was slow enough to be logged. The steady state did not change, as
expected: the crowd's standing cost is relaying movement, which this did not touch. At 250 and 500
players the steady-state figures were the same as before within the variance above.

## Next, in order of what the numbers say

1. **The rest of the crowd allocation** (2.5 MB a tick at 500): serialized bodies per broadcast, the
   output arrays each session grows anew every iteration (a buffer handed back after sending would
   end that), and movement handling. Relaying movement is now the largest cost in a crowd.
2. **GC pauses:** fewer collections from the above, then static data allocated outside the scanned
   heap, and the collector's options (`--DRT-gcopt`: initial heap size, mark threads), measured.
3. **Unloading idle cells:** cells nobody has been near for a while give back their objects.
4. **`epoll` instead of `select`,** to go past 1000 connections.

## Regions owned by nodes (after cluster phase 2)

Standalone, idle with 500 players: tick 3.12 ms (2.96 before), loop busy 6.6% (6.3%), 53 KB allocated
a tick (67 KB): the same within the variance, and one stray allocation found on the way (a copy of the
online players' table every tick, from the slow-tick report, now gone).

## Replicas of creatures (cluster phase 3a; two nodes, 500 players spread out, all on the coordinator)

| | Tick | Loop busy | Objects | Allocated per tick |
|---|---|---|---|---|
| Standalone | 3.42 to 3.53 ms | 8.2 to 8.6% | about 26,500 | 149 to 188 KB |
| Coordinator | 3.51 ms | 9.7% | 24,447 (about half replicas) | 166 KB |
| Node 2 (no players) | 1.94 ms | | 13,600 | |

Every object costs about 143 ns a tick on either node, creature or replica: the cost is keeping
objects (iterating the movers, which are in an associative array, and checking positions), not their
AI. With every player on one node, the cluster moves AI but not bookkeeping, and total CPU goes up.
Load divides when players are on different nodes (below). Next here: movers in an array, and
replicas that stand still left out of the tick.

## Fewer objects in the tick (array of movers, resting objects left out)

| 500 players, standalone | Tick before → after | Loop busy before → after |
|---|---|---|
| idle | 2.96 → 2.27 ms | 6.3 → 4.9% |
| spread | 3.42–3.53 → 2.66 ms | 8.2–8.6 → 6.7% |

Creatures that wander or walk paths (two thirds of the spawns) still tick, about 150 ns each; per-object
update timers (an object that has nothing to do skips ticks until it has) would be the next step.

## Players divided between two nodes (cluster phase 3b)

500 players spread over the continents, 250 connected to each node:

| | Players | Tick | Loop busy | Objects (own and replicas) | CPU |
|---|---|---|---|---|---|
| Standalone | 500 | 2.66 ms | 6.7% | about 26,000 | about 12.7% |
| Coordinator | 250 | 1.55 ms | 4.6% | 18,639 | 4.9% |
| Node 2 | 250 | 1.81 ms | 4.9% | 20,040 | 8.7% |

Each node's tick fell by a third or more; not by half, because players dropped anywhere on two
continents see much the same objects, so each node still holds three quarters as many. The two
together use the CPU one server does. The less two nodes' players overlap, the closer each comes to
half; a cluster's gain is in carrying more players than one machine can, not in using less CPU.

## For the cluster

* In a crowd the expensive part is the fan-out to sockets, which happens on the node that holds each
  client's connection (its home, docs/CLUSTER.md). Spreading connections over nodes spreads that
  cost, but only if each node receives an entity's update **once** and fans it out to its own
  clients: traffic between nodes must be per (entity, node), never per (entity, client).
* Spread-out players are where partitioning pays most: creature ticking divides cleanly by region.
* Every comparison of the cluster against these numbers uses the same scenarios and `tools/bench.sh`.

## Balancing by measured cost (cluster phase 6; two nodes, one machine)

| Load | Node 1 | Node 2 | Moves |
|---|---|---|---|
| 300 spread out | 19 ms/s | 24 ms/s | none (within the tolerance) |
| 300 spread out and 250 in a crowd | 176 ms/s | 132 ms/s | one region of 21 ms/s: 155 and 153 |
| the same, a minute later | 181 ms/s | 135 ms/s | one of 19 ms/s (the first stays: cool-down) |

Costs are each node's loop busy time divided among its regions by what they hold
(docs/CLUSTER.md, "Load balancing"). The crowd's region cannot be divided until regions can be split; what
balancing does is take the rest of that node's work away.


## With combat, scripts and game objects (2026-11-17)

`spread` with 500 bots after creatures fight, run their EventAI scripts and cast, and game objects
have loot states. The bots are level 1 humans dropped at random creature spawns of both
continents, so hostile creatures notice and kill them: 407 deaths in one run, each with its corpse,
the creatures' chase, swings and spells, and their evading home.

| Build | Tick avg | Loop busy | CPU | Allocated per tick | Objects |
|---|---|---|---|---|---|
| Before combat (above, fewer objects in the tick) | 2.66 ms | 6.7% | 12.7% | 0.15 MB | about 26,000 |
| Combat, as first written | 9.86 ms | 21.5% | 21.0% | 0.14 MB | 26,720 |
| Noticing by cell | 5.24 ms | 12.3% | 17.4% | 0.26 MB | 27,837 |
| With database scripts, summons, instances, idle cell unloading (later that night) | 5.65 ms | 13.3% | 18.8% | 0.28 MB | 29,080 |

A profile of the second run (tools/gdb-sample.py) put a third of the busy time in noticing: every
time a creature moved, it went through every player on the map to find those who see it
(`creatureNoticing`), and every move of a player through every object it sees (`playerNoticed`).
Now a creature asks the cells within 50 yards for players, and neither goes on for a creature that
attacks nobody on sight (passive, defensive, dead or neutral to all: `CreatureAI.mayNotice`). The
rest of the increase is the fighting itself and the creatures whose scripts run out of combat
(their timers keep them in the tick: about 4,800 spawns in the world have such events). The last
row adds database scripts (waypoint scripts, relays) and everything else of that night; its 8% is
within what two identical runs differ by, and the cells did not unload in a one-minute run.

## Step 1 of docs/DESIGN.md: slots in the map (2026-11-17)

The load scenarios could not show this one: each run of `idle` and `spread` loads a different number
of objects (26,000 to 65,000 in four runs of the same build, depending on where the bots land), and
one-second spikes while cells load dominate the averages. So the map was measured alone with
`tools/mapbench.d`: 500 players and 30,000 objects spread over 3,000 by 3,000 yards, a third of them
walking. Each 50 ms tick, a tenth of the walkers start a walk (a packet to their viewers), and a
tenth of the players move two yards (visibility, noticing, and their movement to their watchers).
It is built with `-unittest` for the test data and run with `--DRT-testmode=run-main`.

| Map | Per tick (three runs) | Packets delivered |
|---|---|---|
| Guids in associative arrays (before) | 15.88, 16.00, 15.94 ms | 737,626 |
| Slots, viewers and known sets (after) | 1.93, 1.96, 1.93 ms | 737,626 |

8.2 times faster, delivering exactly the same packets. Most of it is sending to an object's viewers
(walking its viewer list instead of asking every player on the map whether it sees the object), and
the rest is lookups by slot instead of by guid.

## Step 4 of docs/DESIGN.md: phases, sleeping objects, searches that do not load (2026-11-17)

Measured with `idle` and `spread` at 500 bots, the load generator's `--seed 7` (the same bots on the
same spawns in every run: without it the objects loaded varied from 26,000 to 65,000 between runs of
one build), against the build before the step:

| | Before | After |
|---|---|---|
| Objects loaded (idle / spread) | 44,701 / 46,482 | 24,389 / 27,608 |
| Ticking at the end | 26,515 / 27,582 | 7,734 / 8,829 |
| Event loop busy | 19.8% / 21.7% | 7.3% / 8.4% |
| Tick average | 10.2 / 10.6 ms | 3.5 / 3.3 ms |
| Worst tick | 1,073 / 900 ms | 80 / 5.5 ms |
| Allocated per tick | 641 / 746 KB | 111 / 210 KB |

Most of it is a bug the profile (`tools/gdb-sample.py`) found: every search for nearby objects loaded
the cells it looked at. It was used by creatures calling for help, EventAI looking for a hurt friend
and database scripts looking for a buddy up to 1,000 yards off. So creatures loaded cells, whose
creatures searched and loaded more, and about 20,000 of the objects loaded were near no player.
Unloading idle cells then went through tens of thousands of cells every 10 seconds, which was the
second-long spikes. Now only a player's sight loads cells; searches never do. A search wider than the cells that hold anything goes through those cells instead of
every key in its range.

The timer wheel took the objects that tick from about 59% of those loaded to about 32%. That saved
less than it looks: the ticks it removes did almost nothing, and what costs is the work an object
does when it acts. The biggest is a wandering creature's next walk, whose ground height is a ray
test against the buildings (`allowedPositionZ`). The movement maps will change that work. Creatures
now look for players to notice at most once a second as they move, instead of on every tick.

## Step 5 of docs/DESIGN.md: output that is reused, updates built once (2026-11-17)

`crowd`, `--seed 7`, against the build of step 4:

| | 500: before | 500: after | 900: before | 900: after |
|---|---|---|---|---|
| Allocated per tick | 2.57 MB | 0.41 MB | 7.39 MB | 0.84 MB |
| Collections a minute | 13 | 1 | 22 | 2 |
| CPU | 58% | 11% | 99% | 33% |
| Event loop busy | 12.5% | 7.9% | 33.9% | 24.0% |
| Ping p99 | 21.9 ms | 3.8 ms | 35.5 ms | 8.9 ms |

Most of it came from how packets were appended. The profile showed relaying movement as the crowd's
cost, and within it the appending of each packet to the receiving session's output (`~=`), which
asks the collector for the array's capacity every time, and a new array grown for every loop
iteration. Now:
* Output goes into an `OutputBuffer` that keeps its own length and doubles.
* The server gives a sent array back (`ReusesOutput`), and the session writes into it again.
* An object's update is built once for everyone who sees the same fields.
* Changes in the map's tick go out once at its end.

## Step 6 of docs/DESIGN.md: writes behind the loop (2026-11-17)

`crowd`, 500 bots, `--seed 7`, with `player_save_interval` at 5 seconds so that every character
saves 12 times a minute (about 24,000 writes a minute). Compared with the build of step 5:

| | Writes in the loop | Writes behind it |
|---|---|---|
| Tick, average | 3.49 ms | 0.54 ms |
| Tick, worst interval p99 | 10.31 ms | 1.02 ms |
| Tick, max | 15.07 ms | 3.29 ms |
| Event loop busy | 13.9% | 7.9% |
| Ping p99 | 3.94 ms | 3.73 ms |

With the default interval (900 s) the saves are spread too thinly to show. The writer kept up: its
queue was empty at every metrics line, nothing failed, and the cluster regression (250 bots on
three nodes) passed.

## Step 7 of docs/DESIGN.md: static data off the scanned heap (2026-11-17)

**What a collection cost, measured first.** Timing a full collection right after start-up, before
any player:
* 57 ms to mark 88 MiB of static data, almost all of it marking (1,249 of 1,257 ms over 25
  collections).
* With marking on one thread, the same collection took 20 ms. The default of one thread per core
  (32 here) is slower: the threads mostly wait on each other.
* Dropping the tables one at a time showed what each cost to mark:
  * items 4.1 ms, spells 4.0, NPC data 1.6, creature templates 1.5;
  * quests 1.1, the spawn cells 1.0, the spawns 0.85, models 0.75.
  * The DBC files cost 1.3 ms in all.

**Then.** Marking is on one thread, and the largest tables are frozen into the arena
(`dmangos.frozen`; 26 MiB). Against the build of step 6, `--seed 7`, 500 bots:

| | Crowd: before | Crowd: after | Spread: before | Spread: after |
|---|---|---|---|---|
| Collection pause | 55.6 ms | 16.4 ms | 71.6 ms | 37.7 ms |
| Longest pause since start | 100.8 ms | 27.9 ms | 103.1 ms | 37.7 ms |
| Event loop max | 60.1 ms | 19.8 ms | 74.2 ms | 42.9 ms |

The spread scenario has 28,000 creatures and game objects loaded. What it still pauses for is mostly
them, the live world, not static data. Next would be the NPC and quest data and the spawn cells,
then the creatures themselves.

## Movement maps (2026-11-17)

`spread`, 500 bots, `--seed 7`, about 27,500 creatures and game objects loaded:

| | No movement maps | Tiles added when loaded | Tiles added 3 ms a tick |
|---|---|---|---|
| Tick, average | 3.8 ms | 4.9 ms | 4.4 ms |
| Tick, max | 7.2 ms | 43.8 ms | 14.1 ms |
| Memory | 815 MiB | 1288 MiB | 1348 MiB |

Timing each tile's load showed where the 44 ms came from:
* Reading 600 tiles took 59 ms in all.
* Adding about 450 to the mesh took 1.4 s, about 3 ms each, the time Detour spends linking each
  tile to its neighbours.
* Ticks in which many areas came into use added a dozen at once.

## Cluster service calls (2026-11-17)

`tools/servicebench.d`, with a request the size of a channel command (a guid, a name, a channel and a
line of chat):

| Call | Cost |
|---|---|
| Answered on its own node (a direct method call) | 23 ns |
| Through the remote path, in-memory link | 1.7 µs |

The remote path covers encoding the request, dispatching it from bytes, the reply cache and decoding
the reply. The network adds its round trip on top.


## epoll instead of select (2026-11-18)

`crowd`, `--seed 7`, 60 s, against the build before it:

| | select, 900 | epoll, 900 | epoll, 1,500 |
|---|---|---|---|
| Bots in the world | 900, none failed | 900, none failed | 1,500, none failed |
| Event loop busy | 25.3% | 25.4% | 99.1% |
| Loop iteration, average | 1.97 ms | 1.99 ms | 3.12 ms |
| Ping, median / p99 | 2.9 / 9.0 ms | 3.2 / 11.2 ms | 3.2 / 35.4 ms |
| Sent | 36 MB/s | 36 MB/s | 96 MB/s |

* At 900 the two cost the same: waiting was never the expensive part; relaying every movement to everyone
  near is. The tail latencies differ within the noise described under "Method" (one collection against
  two).
* What epoll changes is the ceiling. `select` cannot watch descriptors past 1024, so a server could not
  be configured for more than 1,000 connections; with epoll the limit is 60,000 (`connectionLimit`), and
  the server raises its open-file limit to the hard limit at start.
* 1,500 players in one crowd fill one core (the fan-out grows with the square of the crowd); spread out,
  or divided between nodes, they cost far less.

## Where a crowd's allocation went (2026-11-18)

`crowd` and `spread`, 500 bots, `--seed 7`, 60 s, against the build before:

| | crowd: before | crowd: after | spread: before | spread: after |
|---|---|---|---|---|
| Allocated per tick | 430 KB | 103 KB | 240 KB | 215 KB |
| GC collections in the run | 3 | 0 | 1 | 1 |
| Ping p99 | 7.5 ms | 4.5 ms | 7.3 ms | 6.8 ms |
| Event loop busy | 7.5% | 7.9% | 10.5% | 11.2% |

**How it was found.** `-profile=gc` builds and links (with `-allinst`, without `-inline`), but the
server then took over a quarter of an hour to load the world, so it was not usable. Instead, a
throw-away build counted `GC.allocatedInCurrentThread` between marks: first in the event loop (87% of
the bytes in packet handling, 13% in the tick, none in sending), then in the movement handler (92% in
`Map.relocated`), then inside it: `updateVisibility`, about 77 KB a call, 800 calls in ten seconds. It
built two associative arrays of everyone and everything in sight (500 players and some hundreds of
objects in a crowd) and fresh arrays for the cell searches, each time a player had moved a few yards.

**The change.** The sets in sight are `SlotBits` kept by the map and emptied again by each call, and
the cell searches and the known-object lists fill lists lent from a small pool (`borrowList`,
`knownInto`), so their memory is kept from call to call.

**Tried and dropped.** Update masks from compile-time words (no per-slot pass, no arrays): a
micro-benchmark showed the helpers 1 µs and 176 B cheaper per player, but the crowd allocated 443 KB a
tick against 430: they were not where the bytes went. Reverted.

## A tick-end net for unsent player changes: tried and dropped (2026-11-19)

The idea: at the end of each tick, any player whose fields changed but were not sent (a handler that
forgot `flushPlayerChanges`) gets them sent. `crowd`, 500 bots, `--seed 7`, 60 s, runs alternated with
the build before it:

| | before (4 runs) | with the net (4 runs) |
|---|---|---|
| Tick, average | 0.630, 0.658, 0.676, 0.675 ms | 0.688, 0.701, 0.732, 0.727 ms |
| Event loop busy | 7.7–7.9% | 7.8–7.9% |

* About 0.05–0.07 ms a tick at 500 players (some 9% of the tick), from the walk itself: an interface
  call and a scan of each player's change bits, each a cache miss. A counting build showed the net
  sent almost nothing (fewer than 5,000 times in about 594,000 checks).
* It would not have caught the bugs that prompted it: the quest log's ids were never meant for the player
  by the visibility rules, and the looted item that completed a quest had its change cleared after it
  went to others only. Those are found by the tests now (`assertSeesItself`, docs/DEVELOPING.md) and
  fixed where they were.

## Ghosts in the visibility pass (2026-11-19)

Hiding ghosts from the living made who sees whom one-way, decided per pair (`Map`'s `playerSees`). The
first version cost the event loop about a tenth more in `crowd`, 500 bots (busy 8.6-8.7% against
7.7-7.9%, runs alternated with the build before it, the tick unchanged); none of the bots was dead.
Taken apart, build by build:

* Not the rule itself: the pair check was given a fast path from a ghost bit in the map's own entry; no
  change.
* Not the casts: `objectVisibleTo` tried a cast to `Replica` for every object near a moving player; it
  now asks the map's flag first; no change either.
* The old `updateVisibility` body with everything else new: back to the baseline. The new body read the
  *other* player's known set for every pair in sight, to decide the way back: a cache miss per pair,
  hundreds per call.

The fix: the map counts its ghosts; with none, and the player not just dead or alive again, visibility is
symmetric and the pass does what it did before (no rule, no other player's set, no pass over those who
see the player). Measured again, side by side while other builds ran on the machine: 9.3-9.6% before,
9.5-9.8% after, within the noise.

## A crowd of ghosts (2026-11-19)

The crowd benchmark seemed a point slower after the ghosts' visibility (busy 8.5-8.9% against 7.8-8.0% for
the build before it, measured with nothing else running). Bisecting by build put it all in
`updateVisibility`, and a counting build showed why: every one of the 500 bots was a ghost. The
harness's characters had died over earlier runs and logged out dead, so they came back released, and the
map took the one-way path for every pass. The earlier "Ghosts in the visibility pass" numbers were
measured on that crowd too.

`tools/harness/bench.sh` and `regression.sh` now bring the harness's characters back to life before a run
(`revive_bots`: the corpses and the ghost flag go). With living bots the build before the ghosts and
today's are the same: busy 7.1-7.3% and 7.1-7.2%. A crowd of 500 ghosts, all seeing each other, costs
about 0.7 points more than one of the living; that is the one-way path's price, paid only by ghosts.

## Release builds without -inline (2026-11-19)

DMD with `-O -inline` took more than ten minutes on `world/context.d` alone (70 seconds with `-O` only), and
every check built the world code three times (the world server, the login server and the load generator
each compile the whole tree). `dub.json`'s `release-fast` build type is `-release -O` without `-inline`;
`check.sh` builds the three with it at once: about 80 seconds in all.

The price, `crowd` 500 bots, runs alternated: busy 7.9-8.1% and tick 0.33-0.38 ms without `-inline`,
7.0-7.1% and 0.29-0.30 ms with it: about 13% more CPU. Measure performance with `dub build -b release`.

Without `-inline`, DMD's optimizer miscompiled `frozenCopy!(float[3])` (a static array returned by value):
the server crashed loading its data. `frozenCopy` now copies a field with nothing to copy deep as it is,
without the call.

## Stealthed players in visibility (2026-11-19)

A stealthed player counts as one-way in the map's visibility (as a ghost does): only its group, its side, and
enemies that detect it see it, worked out again once a second while anyone on the map is stealthed. With no one
stealthed nothing changes on the hot path but one aura check per relocation: `crowd` 500, release-fast builds,
alternated: busy 7.7-7.9% before, 7.7-7.8% after; tick 0.32-0.35 ms both.

## Far Sight in visibility (2026-11-19)

A player seeing from an eye (Far Sight, Eagle Eye, Mind Vision) is one-way, like a ghost: what it sees is near
the eye, who sees it is near where it stands. With nobody far-seeing the cost is one field read per
`updateVisibility`: `crowd` 500, release-fast, alternated on a quiet machine: busy 7.6-7.8% before, 7.7-7.8%
after; tick 0.34-0.35 ms both. (Runs while another build compiled read 12-17% for both: compare only quiet runs.)
