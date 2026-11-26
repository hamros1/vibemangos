# Developing dmangos

For a first login, start with [Set up dmangos](SETUP.md). This guide covers development builds,
code changes and testing. Use the [source layout](SOURCE-LAYOUT.md) to find a module.

## Toolchain

```sh
source ~/dlang/dmd-2.114.0/activate   # DMD 2.114, dub 1.43
dub test                               # every module's unittests
dub build -c authserver                # or worldserver, extractor; add -b release-fast for optimized builds
```

Building also needs `g++` and `make`: dub first runs `thirdparty/Makefile`, which compiles Recast and
Detour (recastnavigation 1.6.0, vendored there) and the C interface to them
(`thirdparty/dmnav/dmnav.cpp`) into `thirdparty/build/libdmnav.a`. A plain `dmd` build of the tests
links it with `thirdparty/build/libdmnav.a -L-lstdc++`.

The login server, extractor and load generator compile the D modules they import. The world server
and `dub test` include the full source tree.

To check movement maps by hand, `tools/navpath.d` loads a map's tiles and prints the way between two
points (how to build it is in its header):

```sh
navpath /path/to/data 1 1007.8 -4446.2 11.2 1629.4 -4373.4 31.3   # Durotar into Orgrimmar, by the gate
```

The databases use the CMaNGOS Classic schema. See [database setup](SETUP.md#3-import-the-database-and-write-the-configs)
for a fresh install and [live tests](#live-tests-against-real-data) for the scripted client.

## Recipes

### Handle a new client packet

1. **Opcode.** Add it to `world/opcodes.d`, in value order, with the
   opcode's conventional upper-case name (`CMSG_...`, `SMSG_...`, `MSG_...`) and its value in the
   1.12 client's protocol.
2. **Layout.** Add the packet struct to `world/packets.d`. A client packet is a plain struct:

   ```d
   /// `CMSG_SET_SELECTION`
   struct ClientSetSelection
   {
       ulong guid;
   }
   ```

   If the layout depends on the contents (like movement or chat), give the struct a
   `static T read(ref ByteReader)`, and the dispatcher will use it.
3. **Handler.** Write it in the handler group of its area, e.g. `inworld.d` for the
   miscellaneous in-world packets (queries, settings, chat):

   ```d
   @Handles(Opcode.CMSG_SET_SELECTION, WorldState.inWorld)
   void handleSetSelection(const ClientSetSelection request)
   {
       ...
   }
   ```

   The method name must start with `handle`. Use one `@Handles` with an array to serve several
   opcodes, and add an `Opcode` parameter to tell them apart.
4. **Test.** Add a test that drives it through `TestClient` (see `inworld.d`'s tests).

### Send a new server packet

```d
/// `SMSG_STANDSTATE_UPDATE`
struct ServerStandStateUpdate
{
    mixin ServerPacket!(Opcode.SMSG_STANDSTATE_UPDATE);
    ubyte state;
}
...
send(ServerStandStateUpdate(1));
```

* **Fixed size:** add `static assert(wireSize!ServerX == n);` with the packet's size on the wire.
* **Variable layout:** declare a `@Remainder ubyte[] body_` and build the body in a function, as
  `queries.d` does for item queries and chat.

### Add a handler group

For a new area, such as spells, groups or guilds, create `world/<area>.d`:

```d
module dmangos.world.groups;

/// Group handlers, mixed into Character.
mixin template GroupHandlers()
{
    import dmangos.world.opcodes;
    import dmangos.world.packets;
private:
    @Handles(Opcode.CMSG_GROUP_INVITE, WorldState.inWorld)
    void handleGroupInvite(const ClientGroupInvite request) { ... }
}
```

Then add `import dmangos.world.groups : GroupHandlers;` and `mixin GroupHandlers;` to
`Character` in `character.d` (a handler of the character screen goes to `WorldSession` in
`session.d` instead). The handlers can use every character member (`context`, `player`, `send`,
and the connection's `account`, ...).

### Read another DBC file

In `world/clientdata.d`:

1. Declare the record struct, with fields in file order.
2. Write its format string, one letter per field of the file. The store checks at compile time that
   the struct matches the format, and at load time that the file matches both.
3. Add a `DbcStore!(Entry, format)` member, and add its `"member:FileName"` to the list in
   `ClientData.load`.
4. Make sure the extractor writes the file. It copies every DBC, so it normally does.

Take the layout from the file itself, not from a published format string: those are not always
right. `CharStartOutfit` is often described with one 4-byte field where the file has four 1-byte
fields, and only a loader that does not check record sizes gets away with it. Ours checks, so a
wrong format fails at load time.

### Read another world table

Add a query to `WorldData.load` (or to `SpellData.load` for spell tables):

```d
foreach (row; world.queryAs!(Row, "SELECT a, b, c FROM table")())   // Row: a struct, fields in column order
    ...
```

For wide tables, follow `itemDetailColumns` in `worlddata.d`: a CTFE table of
column → field pairs that the loader is generated from. Validate the rows as they load: skip
(and log) a row that names a template, item or spell that does not exist, rather than failing later.

### Read or write the characters database

1. Declare the method in the `WorldDatabase` interface (`world/database.d`).
2. Write the SQL in `CharacterStatements` (`world/characterdb.d`), against the schema's columns
   exactly (the rows must stay readable by any server on the same schema), and forward to it from
   `MySqlWorldDatabase`.
3. Implement it in `MemoryWorldDatabase`, so tests can see what was written.

### Change an object's fields

```d
player.values.set!UNIT_FIELD_HEALTH(newHealth);
player.values.set!UNIT_FIELD_POWER1(Power.mana, newMana);
flushPlayerChanges();     // a values block with exactly the changed fields
```

The field name decides the type, and a mismatch doesn't compile. Integers go to `int_` fields,
floats to `float_` fields, `ulong` to guids. An index may run on into the following fields if they
have the same type, and a contract checks that. To show an object to *another* player, send
`seenByEveryone` (plus `seenByOwner` for its owner) instead of `seenBySelf`.

### Write a GM command

Add the handler to the appropriate `gm*.d` mixin and register it in `commandtable.d`.
The catalog supplies the in-game usage, permission checks and generated reference. For example,
this is the action for `.wp move`.

```d
action("movehere", permit("world.waypoints"), "handleWaypointMoveHereCommand", "<point>",
    "Move a draft point to your position.", "move"),
```

The last argument is the preferred spelling. The original name stays in existing permission
paths, so `.wp move` uses `command.waypoint movehere`. Use `shortcut` to link to an action in
another group. Use the narrowest named capability that covers the action.

The dispatch code converts arguments to the handler’s parameter types. A default value makes an
argument optional. An omitted `Nullable` argument is null. `Rest` takes the rest of the line and
`OnOff` accepts `on` or `off`. Return false to show usage, or send a message and return true if
the input is valid but the action cannot run.

Use `greenSystemMessage`, `redSystemMessage` and `blueSystemMessage` for command feedback.
`chatstyle.d` owns the color palette and item and player link formatting.

Run `python3 tools/commands_doc.py` after editing the catalog.

### Write a script

Scripts are D structs in `source/dmangos/scripts/` (one module per dungeon or area; a new module is
added to `scriptModules` in `scripts/package.d`). docs/SCRIPTING.md has the design.

```d
import dmangos.script;

@creature("boss_example")                        // creature_template.ScriptName
struct Example
{
    enum Step : ubyte { bolt }                   // its own steps
    Schedule!Step steps;                         // timers are data: saved with the rest
    ubyte phase;

    void on(ref CreatureContext me, const ref EnteredCombat e)
    {
        steps.every(Step.bolt, 8.seconds);
    }

    void on(ref CreatureContext me, const ref Damaged e)
    {
        if (phase == 0 && e.crossed(50))
        {
            phase = 1;
            me.say(-1000123);                    // a script_texts row
        }
    }

    void on(ref CreatureContext me, Step step)   // a step is due
    {
        me.castSpell(12345);                     // at its victim, by the usual rules
    }

    void on(ref CreatureContext me, const ref Reset e)
    {
        this = Example.init;                     // home after a fight it gave up
    }
}
```

Rules the build enforces: every `on` takes the context of its kind and one of its events (or a
step of one of its schedules), every schedule's steps have an `on`, no name is served twice, and the
state holds only values (numbers, enums, strings, arrays, structs, `EntityRef`s; mark caches
`@transient`). Keep entities as `EntityRef`, never as anything else: the context resolves them when
used. Test a script with the world in memory (`scripttests.d` has a boss and a dungeon).

### Teleport a player

Call `teleportTo(map, Position(x, y, z, o))` (`world/teleport.d`). It checks the destination and,
for another map, the map's entrance requirements; it returns false if the player may not go.
Never set `player.data.map` yourself: the client must load the map first.

### Reach a group or channel

`context.groups.of(guid)` is the player's group (null if none). `group.broadcast(opcode, body)`
sends to every member online, `group.updatePlayerOutOfRange(this, GroupUpdate.x)` sends member
stats to those who do not see the player. `context.channelsFor(this).find(name, this)` is a
channel the player may talk in.

### Add a configuration key

1. Add a field to `WorldConfig` (`world/config.d`), with `@JsonName("snake_case")`, its default,
   and a documentation comment saying what it does and in what unit.
2. Add it to `config/worldserver.example.json` and to the table in the README.

## Testing

### Unit tests

`dub test` runs every module's tests: 156 modules. Session tests use
`world/testclient.d`. Importing it gives you a scripted client (`TestClient`), a pre-filled
in-memory database (`newDatabase`), contexts (`newContext`, `newCreationContext`),
`authenticate`, and for tests in the world `loggedIn` (an account and a character, logged in),
`chatBody`, `opcodesOf` and `bodyOf`. To let time pass, replace `context.clock`, as the movement
check's test does.

The client keeps what its update packets told it of objects' fields (`TestClient.view`, decoded from
the client's format, not with `objects.d`). `assertSeesItself` checks that the client sees every field
of its own player as the server holds it. `loggedIn` checks it after login. Call it after anything
that changes the player (the quest test does, after each step): a test of the server's values alone
missed that the quest log never reached the client. From the live server, `testclient.py`'s
`questlog[:ID]` shows the log as the client has it.

### The test harness

`tools/harness/` holds what every change goes through, against a private MariaDB with its own copy of
the databases (so load tests never touch a dev server's characters):

```sh
tools/harness/setup.sh SOURCE_DATADIR   # once: copies a stopped MariaDB data directory, writes configs
tools/harness/check.sh --fast [MODULE ...]  # one change's loop, about a minute: every module compiled, the
                                        # unit and real-data tests of the modules named (all if none; a name
                                        # or a prefix, dmangos.world.realscripts_raids, dmangos.cluster.),
                                        # and unoptimized servers in $DMANGOS_HARNESS/fastbin for chaos cases
tools/harness/check.sh                  # the gate before a push, about 8 minutes: unit tests, release
                                        # builds (`-b release-fast`) while the spell audit and the real-data
                                        # tests run, then the cluster regression. `dub build -b release` for
                                        # benchmarks.
tools/harness/check.sh --quick          # the gate without the regression
WORLDSERVER=~/.cache/dmangos-harness/fastbin/worldserver AUTHSERVER=~/.cache/dmangos-harness/fastbin/authserver \
    python3 tools/harness/chaos.py -j 4 [CASE ...]  # chaos cases four at a time against the fast servers
tools/harness/regression.sh             # two nodes, 250 bots in a crowd while regions split and merge
python3 tools/harness/quorum.py         # three voters and a gateway, with clients connected during failover
python3 tools/harness/realms.py         # sign into two clusters through one login server and check isolation
python3 tools/harness/named_objects.py  # named spells and a clean handoff of saved spawns and a corpse
python3 tools/harness/named_objects.py --abrupt  # kill the worker and check the original respawn deadline
python3 tools/harness/group_loot.py     # two clients roll from separate nodes and only the winner receives the item
python3 tools/harness/group_loot.py --migrate-member  # vote from the original prompt after moving to a third node
tools/harness/bench.sh LABEL crowd 500  # one benchmark run (docs/BENCHMARKS.md), report in LABEL.md
tools/harness/db.sh start|stop|status
# The full check also runs tools/harness/spell-audit.py: every spell a player can learn (trainers, starting
# spells, talents, what they trigger) against what the server does; it fails on an effect left undone or an aura
# type the code never names, unless tools/harness/spell-audit-known.txt lists it with its reason.
```

The checks size themselves to the machine's free memory, not its cores: a unit-test compiler takes up
to 4 GB and the world server's release build 6 GB, so `check.sh` runs as many compilers as
`MemAvailable` allows (`CHECK_JOBS` overrides) and the real-data tests in up to 12 processes of about
1 GB (`CHECK_REAL_SHARDS`). Only one check on the machine builds at a time: every build holds
`flock` on `$XDG_RUNTIME_DIR/dmangos-build.lock` (`DMANGOS_BUILD_LOCK`), so checks in several
worktrees queue their compilers instead of running the machine out of memory together. The test
binary's runner (`source/dmangos/testrunner.d`) takes `DMANGOS_TEST_MODULES`, `DMANGOS_TEST_SHARD=i/n`
and `DMANGOS_TEST_TIMES=FILE` (each module's seconds).

The harness lives in `~/.cache/dmangos-harness` (`DMANGOS_HARNESS`). It needs an unpacked MariaDB
(`MARIADB_ROOT`, by default the dev server's in `~/dmangos-server/mariadb`) and extracted client data
(`CLIENT_DATA`, used read-only). Its MariaDB listens on a private socket only and runs without grant
tables. The regression requires all bots in the world at the end and both nodes still running.
It fails on crashes, lease lapses and writes refused by lease fencing. It records lease and write
failures in `regression/lease-failures.log` before the deliberate shutdown. Runs with at least
250 bots, 180 seconds of load and 60 seconds of idle time also require a region split, a region
merge and a player handoff. Set `EXPECT_BALANCING=1` to check these events in a shorter run or
`EXPECT_BALANCING=0` to skip those assertions.

### Cluster chaos suite

After harness setup and a release build, run the opt-in suite with
`python3 tools/harness/chaos.py`. It runs the quorum partition and heal, coordinator kill,
paused battlegroup host, gateway checkpoint retry, departure retry, lease lapse arrival, worker
rejoin, stall release, gateway return, C'Thun recovery, loot award crash, migration stall, standby
login and standby bundle cases against isolated fixtures.
Use `--repeat 3` to check repeatability. Each case prints the harness directory containing
its process logs and uses fresh login and character schemas.

Run the partition alone with `python3 tools/harness/quorum_partition.py`. Its loopback TCP
proxy cuts voter links between the two groups while the minority coordinator, its worker,
and the nonvoting gateway stay connected. The case checks that minority regions move to
the majority after release, the original gateway client recovers from its durable checkpoint,
and the old owners rejoin without overwriting the replacement's progress. The proxy runs
without firewall changes or elevated privileges.

Run `python3 tools/harness/departure_retry.py` to hold a gateway player's character row in a
second MariaDB session while the client disconnects. The worker's save keeps timing out, so it
must keep the departure until the row is free, then report it once, after the save; the same
account then logs in and speaks at once, while the gateway hands it to the worker, and must be
answered. The cluster runs with the default failure timeout and lease: the
stalled database must cost the worker neither a link nor its lease. It sets the server's
`innodb_lock_wait_timeout` to one second for its run and restores it afterwards.

Run `python3 tools/harness/lease_lapse_arrival.py` to drop the worker lease frames between the
coordinator and one worker at the proxy, so only that worker's lease lapses, in the same term and
with every link up. A gateway client sends chat during the handoff and receives its reply when
the lease returns. The test then lets the lease lapse again while that player is active. The same
worker must restore the character and answer chat on the original client connection.

Run `python3 tools/harness/worker_rejoin.py` to stop (`SIGSTOP`) the worker simulating a gateway
player until the coordinator drops it and the gateway restores the player elsewhere. Resumed, the
old process must be refused, wait for its own lease to lapse, and join again as a new incarnation
while the player plays on.

Run `python3 tools/harness/stall_release.py` to stall one worker's database with a held row, as
`departure_retry.py` does, in a cluster whose `database_stall_release_seconds` is 8. A stall shorter
than that must release nothing, and neither must one of every node's database (each node's row of
`dmangos_write_applied` held) that lasts longer. Held past the limit while the others write, the
worker must be fenced out: the gateway restores its player on another worker as last saved (the change
made during the stall rolled back), where it speaks and is answered, and the worker joins again as a new
incarnation. It sets `innodb_lock_wait_timeout` to one second for its run and restores it afterwards.

Run `python3 tools/harness/gateway_return.py` to chat through the gateway across a hand-off: the
client says a numbered line every 50 ms and ports to ground of its map another worker simulates, while
the proxy delays the gateway's frames to its first worker by 600 ms. The lines that reach that worker
after the player left must come back to the gateway (both log it) and, with the rest, be answered
once each, in the order said.

Run `python3 tools/harness/loot_award_crash.py` to kill (`SIGKILL`) a party member's worker after
it claims a remote loot award, while a second MariaDB session locks the member's inventory so the
item's write waits. The award must stay claimed, not stored. The gateway restores the member on
another worker, and the award sent again must store exactly one copy of the prize.

Run `python3 tools/harness/migration_stall.py` to teleport a gateway player to the other continent,
simulated by another worker, while a second MariaDB session holds the character's row. The client
must get a transfer abort and stay on its worker, with no link timeout and no lease lapse. Once the
row is free, the same teleport moves the player, and it plays on there.

Both set `innodb_lock_wait_timeout` to one second for their run, as `departure_retry.py` does.
Run `python3 tools/harness/standby_login.py` in single-standby mode (a coordinator, its standby, two
workers): while an account plays on one worker, the coordinator is killed and the account logs in on the
other at once. Watching both workers' logs every 50 ms, the case fails if the second login enters the
world before the first has left it; the standby must evict the first, and the second must play.

Run `python3 tools/harness/standby_bundle.py` in single-standby mode with a gateway: a gateway player
plays on a worker, the proxy holds that worker's frames to the coordinator for two seconds, the worker is
stopped cleanly (it drains), and the coordinator is killed as soon as the worker has sent its releases.
The test compares the original and resent bundles byte for byte and checks that each region
arrives once with its original object count. On the original connection, the player must see
the same living NPC's GUID exactly once after recovery and receive a chat reply.

Run `python3 tools/harness/battleground_recovery.py --cross-realm --map arathi` to kill the
active match worker and check the same match's objectives, scoreboard and PvP on its standby.
Both scripted clients verify that Stables still shows a single pickup, then one walks onto it
and checks that its buff fires and the object disappears.

### Live tests against real data

For two players, run two clients at once: one listening, one acting.

```sh
python3 tools/testclient.py 3724 tester PASS login:Me listen:2 accept listen:3 join:Club listen:5 logout &
python3 tools/testclient.py 3724 tester2 PASS2 login:Other invite:Me listen:3 party:hi join:Club chan:Club:yo whisper:me:psst logout
```

A game master can try teleports and commands alone:

```sh
python3 tools/testclient.py 3724 tester PASS login:Me "cmd:.recall port goldshire" cmd:.gps \
    "cmd:.worldport 0 -11208.5 1685.34 25.76" trigger:78 "cmd:.cheat triggerpass" trigger:78 logout
```

The client answers teleports by itself, as the real one does.

A battleground, alone (`.battleground forcestart` makes a copy for whoever waits; a GM account gets
no Deserter for leaving): at the Orgrimmar battlemaster for Warsong Gulch,

```sh
python3 tools/testclient.py 3724 tester PASS login:Me "cmd:.worldport 1 1985 -4794 56" bgjoin:3890:489 \
    "cmd:.battleground forcestart" bgport:489:1 pvplog listen:5 bgleave:489 logout
```

Trading and moving items, next to a vendor with repairs (Andrew Krighton in Goldshire):

```sh
python3 tools/testclient.py 3724 tester PASS login:Me listen:2 move:-9463:88:58.3 npc:2046 vendor \
    buy:1201 inv equip:27 sell:27 buyback:0 split:25:30:5 destroy:30 tobank:23 frombank:39 repair inv logout
```

`inv` prints the items as the client knows them, so a slot pointing at an item the client was
never sent, or one it was told to forget, fails the run.

Creature movement: listening in Goldshire prints every `SMSG_MONSTER_MOVE` (`[monster moves]`, with
its start, destination, point count and duration) and, for creatures that come into sight mid-walk,
the walk in their create block (`[walking]`). The second login shows the latter: the cells are
loaded and their creatures under way.

```sh
python3 tools/testclient.py 3724 tester PASS login:Me listen:25 logout
```

Pets: a hunter (with Tame Beast, Dismiss Pet and Call Pet learned) tames the nearest Mottled Boar in
the Valley of Trials, sends it at a Scorpid Worker, dismisses it and calls it back. `[pet spells]`
prints the bar as each `SMSG_PET_SPELLS` gives it; `pet:` presses a button of it (`attack` at the
creature last `target`ed), `petname:N` asks for pet number N's name, `petrename:`, `petabandon`, and
`stablelist:`, `buystableslot:`, `stablepet:`, `unstable:` take a stable master's entry.

```sh
python3 tools/testclient.py 3724 tester PASS login:Hunter listen:2 approach:3098:8 cast:1515:3098 listen:22 \
    target:3124 pet:attack listen:10 cast:2641 listen:6 cast:883 listen:3 logout
```


`tools/testclient.py` is a scripted 1.12.1 client written in Python, independent of the D code
(see its header for the actions):

```sh
python3 tools/testclient.py 3724 tester PASSWORD create:Probe:1:1 login:Probe query move:1:2:3 say:hi logout delete:Probe
```

It checks the update packet structure on its own: the mask sizes against the client's field
counts, that every slot points at an object the client was sent, and that no byte is left over.

You need running servers with the databases and extracted DBCs. `~/dmangos-server` (outside the
repo) has that set up: a portable MariaDB, `start.sh`/`stop.sh`, and a test account. To build such
a setup from scratch without root:

* Use `apt-get download` with `dpkg -x` to unpack `libmariadb3`, `mariadb-server-core` and
  `mariadb-client-core`, then run `mariadbd --no-defaults` with a private data directory and
  socket.
* Import the [fresh-install SQL and world archive](SETUP.md#3-import-the-database-and-write-the-configs) with
  `tools/database.sh install sql/local/classicmangos.sql.gz --socket=/path/to/mysql.sock`.
* Extract the DBCs with `bin/extractor -i CLIENT -o DATA` and point `data_dir` at `DATA`.
* Create accounts with `bin/authserver --config ... account create NAME PASSWORD`.

Restart the servers after rebuilding. Right after a start, the realm shows as offline for up to
5 seconds, until the login server's next realm list refresh.

### Load tests

`bin/loadgen` (`dub build -c loadgen`) logs in hundreds of headless clients and makes them play;
`tools/bench.sh` starts a fresh server, runs one scenario and appends the report. Point both at a
test copy of the databases: the generator creates accounts, writes session keys and moves
characters. docs/BENCHMARKS.md has the scenarios, the baseline and how to read the numbers.

```sh
CONFIG=bench.json WORLD=127.0.0.1:8085 LOGIN_DB=... CHARACTER_DB=... WORLD_DB=... \
    tools/bench.sh crowd 250 --duration 60 --warmup 10
```

To see exactly what a client is sent, one bot can say chat commands and print every packet it
receives:
* `--commands` takes commands separated by `;`, said `--command-seconds` apart. The bots' accounts
  become administrators.
* `--trace` prints each packet with its opcode, its length and its first bytes.

For example, retracing a player's way across the nodes of a cluster:

```sh
bin/loadgen --world 127.0.0.1:8085 --login-db ... --character-db ... --world-db ... --bots 1 \
    --prefix PROBE --scenario idle --chat 0 --warmup 1 --duration 40 --trace \
    --commands ".recall port orgrimmar;.recall port gmisland;.recall port orgrimmar;.mod speed 5"
```

Without `perf`, `tools/gdb-sample.py` profiles by sampling: gdb runs the server (built with `-g`)
and records the main thread's stack whenever the server is interrupted, and
`tools/gdb-summary.py` counts the functions. While a load test runs:

```sh
SAMPLE_OUT=samples.txt gdb -q -batch -x tools/gdb-sample.py --args $PWD/bin/worldserver -c bench.json &
while kill -INT "$(pgrep -f "^$PWD/bin/worldserver")"; do sleep 0.1; done &   # stop it when done
touch samples.txt.stop      # then interrupt once more: gdb detaches
python3 tools/gdb-summary.py samples.txt
```

A server slower than it should be says where: a loop iteration over 500 ms is logged with its
time split between receiving, the tick and sending; a tick over 500 ms with its time in players and
maps; and a single packet over 200 ms with its opcode.

### A local cluster

Start with the [two-node local setup](SETUP.md#4-start-the-servers). For a three-node failover
test, make three world server configs and give each a `cluster` object
with its own `node_id` (1, 2, 3) and `listen_port` (9000, 9001, 9002), all with
`"coordinator": "127.0.0.1:9000"`, and `metrics_interval_seconds` at 10 to see the links in the log.
Node 1 is the coordinator. Give one other node `"standby": true` and it takes over when the
coordinator dies (`kill -9` the coordinator to see it); `kill` (SIGTERM) a member to see it drain
its regions to the others first (docs/CLUSTER.md).

```sh
for n in 1 2 3; do bin/worldserver -c node$n.json > node$n.log 2>&1 & done
grep -h "cluster:" node*.log
```

Every node serves clients on its own world port (`say:`, `yell:` and `whisper:` in the test client
show speech crossing nodes). `tools/testclient.py` normally connects where the
realm list points (the coordinator steers it to the least busy node); `WORLD=127.0.0.1:38086` in its
environment connects it to a given node instead.

`kill -9` a member to see it leave the view at once, `kill -STOP` one to see it dropped after
`failure_timeout_ms`, and start a second process with a node's id (on another port) to see the
older one fenced. docs/research/CLUSTER-HISTORY.md records what each stage of the cluster was tested with.

### The real client

Point `realmlist.wtf` at 127.0.0.1. If the client hangs on the loading screen, the last update
packet was wrong. Check `logs/worldserver.log`, then run `tools/testclient.py`'s `login` action on
the same character: its parser points at the broken block.

## Pitfalls found so far

* **Character's mixins share one namespace.** A member that `Character` defines itself silently hides a
  mixin's member of the same name, and two mixins defining the same name collide only where it is used.
  `tools/harness/mixin-names.py` (run by `check.sh`) reports any name defined twice. A mixin method
  that implements one of `Character`'s interfaces needs no forwarder: give it the interface's name
  and make it `public`.

These are facts about the database, its data and the 1.12 client that the code relies on, and
that cost time to find.

* **`character_spell` does not hold default spells**, or spells taught by skills. They are learned
  again at every login. Load only `character_spell`, and the spellbook comes up nearly empty.
* **Update field types matter on the wire.** The five stats, their bonus fields and resistances
  are integers on the wire, even where the server computes them as floats. Attack times are
  integers too. `PLAYER_FIELD_MOD_DAMAGE_DONE_PCT` is sent as a float, though field tables often
  list it as an integer. `updatefields.d` encodes all of this.
* **Visibility:** health is `DYNAMIC` (strangers see a percentage), money and inventory are
  `PRIVATE`, and item durability and stack size are `OWNER_ONLY`.
* **Update packets** over 100 bytes are zlib-compressed (`SMSG_COMPRESSED_UPDATE_OBJECT`, prefixed
  with the plain size). A values block always carries the full field mask (41 words for a player),
  so even a one-field change is usually compressed.
* **The player's own create block** is `CREATE_OBJECT2` with flags `SELF | ALL | LIVING |
  HAS_POSITION` (0x71). Items are `CREATE_OBJECT` with `ALL`. The items come before the player.
* **Movement:** client→server movement packets carry no guid. When relaying them to others, put
  the mover's packed guid first. The transport guid inside `MovementInfo` is a full `uint64` in
  1.12, not packed.
* **Inventory:** `character_inventory.bag` is the *bag item's guid*, not a slot. Load with
  `ORDER BY bag` so bags exist before their contents. `PLAYER_FIELD_INV_SLOT_HEAD` continues over
  bags, backpack, bank, buyback and keyring: 113 guids in a row.
* **`CharStartOutfit.dbc`**: race, class, gender and outfit are 4 separate bytes.
* **`SMSG_MESSAGECHAT` starts with a one-byte chat type**, though `CMSG_MESSAGECHAT` sends it as a
  uint32. The first version wrote four bytes. That passed its own unit test, but the independent
  Python decoder caught it.
* **Field constants share offsets across object types** (`ITEM_FIELD_SPELL_CHARGES` and
  `UNIT_FIELD_TARGET` are both 16). D shares a template instance between alias arguments of equal
  value, so `set!(alias field)` could not tell them apart. That's why field constants are
  `UpdateFieldId` values carrying their table row.
* **Not every `MSG_MOVE_*` is a move.** `MSG_MOVE_TELEPORT_ACK` and `MSG_MOVE_WORLDPORT_ACK` are
  the client's answers to teleports, and `MSG_MOVE_TELEPORT` is sent to others. `movementOpcodes`
  leaves them out; adding them to `Opcode` would otherwise route them to the movement handler.
* **A far teleport makes the client forget every object.** After `MSG_MOVE_WORLDPORT_ACK` the
  server sends most of the login packets again, and the player's create block with its items.
* **Area trigger positions come from `AreaTrigger.dbc`**, and a trigger counts within its radius
  plus 5 yards. Test positions should be taken from the file: a made-up one 13 yards off is
  ignored.
* **Group health views:** health is `DYNAMIC`, so joining or leaving a group changes what members
  in sight see without any field changing. `groupChanged` sends those values on purpose,
  as a forced update of the health fields.
* **The client sends `MSG_MOVE_TELEPORT_ACK` with a full 8-byte guid**, not a packed one; the
  server's `MSG_MOVE_TELEPORT_ACK` has a packed one.
* **Packets for another player are sent by the server loop.** A session that delivers to another
  (chat, moves, group updates, GM commands) only queues the bytes; `TcpServer.run` collects every
  session's output on each pass. It used to collect it only when that client sent something, which
  delayed everything an idle player should see until its next ping. Scripted clients that keep
  sending hide that kind of bug, so live tests should include a client that only listens.
* **`.modify` field types:** the typed setters reject a float for an integer field at compile
  time, so a `modifiableFields` row with the wrong field does not compile.
* **Update field offsets are absolute.** `updatefields.d` gives every field its
  slot from the start of the object (`UNIT_NPC_FLAGS` is slot 0x93); some tools and posts give them
  relative to the type's start. The Python client's debug prints once added `OBJECT_END` twice.
* **Creature health comes from `creature_template_classlevelstats`**, times the template's
  `HealthMultiplier`, not from `MinLevelHealth`. The latter is used only without a stats row.
* **`creature.id` can be 0**: the spawn takes an entry from `creature_spawn_entry` or its spawn
  group. Pools and spawn groups decide which spawns are up; spawning every row gives several copies
  of rare creatures and thousands of extra herbs and veins.
* **Logging out takes 20 seconds** for player accounts. Session tests log out at once because
  `newCreationContext` sets `instant_logout` to 0; the tick test sets it back.
* **Ids** come from `MAX(id) + 1` at start-up for standalone servers, which each require
  their own characters database. Cluster nodes share a characters database and receive
  blocks of IDs from their coordinator.
* **Client builds:** 5875, 6005 and 6141 share the world protocol. The login protocol differs
  slightly. See the [protocol notes](CONFIGURATION.md#protocol-notes).
