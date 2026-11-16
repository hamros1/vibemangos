# Developing dmangos

## Toolchain

```sh
source ~/dlang/dmd-2.114.0/activate   # DMD 2.114, dub 1.43
dub test                               # every module's unittests
dub build -c authserver                # or worldserver, extractor; add -b release for release builds
```

For the CMaNGOS reference, keep checkouts of
[mangos-classic](https://github.com/cmangos/mangos-classic) (the code) and
[classic-db](https://github.com/cmangos/classic-db) (the world database) at hand. Every ported
function names its original in its documentation comment.

## Recipes

### Handle a new client packet

1. **Opcode.** Add it to `world/opcodes.d`, in value order, with CMaNGOS's name and value from
   `Server/Opcodes.h`.
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
3. **Handler.** Write it in the handler group that matches CMaNGOS's file, e.g. `inworld.d` for
   `MiscHandler.cpp`:

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

* **Fixed size:** add `static assert(wireSize!ServerX == n);` with the size from CMaNGOS.
* **Variable layout:** declare a `@Remainder ubyte[] body_` and build the body in a function, as
  `queries.d` does for item queries and chat.

### Add a handler group

For a new area, such as spells, groups or guilds, create `world/<area>.d`:

```d
module dmangos.world.groups;

/// Handlers of `GroupHandler.cpp`, mixed into WorldSession.
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
`WorldSession` in `session.d`. The handlers can use every session member (`context`, `account`,
`player`, `send`, ...).

### Read another DBC file

In `world/clientdata.d`:

1. Declare the record struct, with fields in file order.
2. Copy its format string from CMaNGOS's `Server/DBCfmt.h`. The store checks at compile time that
   the struct matches the format, and at load time that the file matches both.
3. Add a `DbcStore!(Entry, format)` member, and add its `"member:FileName"` to the list in
   `ClientData.load`.
4. Make sure the extractor writes the file. It copies every DBC, so it normally does.

Don't trust CMaNGOS's format strings blindly. `CharStartOutfit`'s claims one 4-byte field where the
file has four 1-byte fields, and CMaNGOS only gets away with it because its loader doesn't check
record sizes. dmangos's loader does check.

### Read another world table

Add a query to `WorldData.load` (or to `SpellData.load` for spell tables):

```d
foreach (row; world.queryAs!(Row, "SELECT a, b, c FROM table")())   // Row: a struct, fields in column order
    ...
```

For wide tables, follow `itemDetailColumns` in `worlddata.d`: a CTFE table of
column → field pairs that the loader is generated from. Apply the same validation as the
`ObjectMgr::Load*` function in CMaNGOS.

### Read or write the characters database

1. Declare the method in the `WorldDatabase` interface (`world/database.d`).
2. Write the SQL in `CharacterStatements` (`world/characterdb.d`), using CMaNGOS's statement from
   the function you port, and forward to it from `MySqlWorldDatabase`.
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

### Add a chat command

Add a method to the command group it belongs to (`gmtravel.d`, `gmcharacter.d`, `gmadmin.d`,
`gmdebug.d`, or `commands.d` for general ones). Its name starts with `command`, and it returns false
when the arguments are wrong (the player is then shown the syntax):

```d
@Command("go xyz", AccountLevel.moderator, "x y z [map]", "Teleports you to a position.", ["goxyz"])
bool commandGoXyz(string args)
{
    float x, y, z;
    uint map = player.data.map;
    if (!readArguments!3(args, x, y, z, map))   // three required, the map optional
        return false;
    ...
}
```

That is all: the table, the aliases, `.help` and the dispatch come from the attribute. Use
`selectedOrSelf()` for "the selected player", and call that session's methods to change it (they
send its packets). A teleport should go through `commandTeleport`, which remembers where `.recall`
returns to. Add the command to `docs/COMMANDS.md`.

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

1. Add a field to `WorldConfig` (`world/config.d`), with `@JsonName("snake_case")`, the default
   from `mangosd.conf`, and a comment naming the `mangosd.conf` key.
2. Add it to `config/worldserver.example.json` and to the table in the README.

## Testing

### Unit tests

`dub test` runs every module's tests: 56 modules, in a few seconds. Session tests use
`world/testclient.d`. Importing it gives you a scripted client (`TestClient`), a pre-filled
in-memory database (`newDatabase`), contexts (`newContext`, `newCreationContext`),
`authenticate`, and for tests in the world `loggedIn` (an account and a character, logged in),
`chatBody`, `opcodesOf` and `bodyOf`. To let time pass, replace `context.clock`, as the movement
check's test does.

### Live tests against real data

For two players, run two clients at once: one listening, one acting.

```sh
python3 tools/testclient.py 3724 tester PASS login:Me listen:2 accept listen:3 join:Club listen:5 logout &
python3 tools/testclient.py 3724 tester2 PASS2 login:Other invite:Me listen:3 party:hi join:Club chan:Club:yo whisper:me:psst logout
```

A game master can try teleports and commands alone:

```sh
python3 tools/testclient.py 3724 tester PASS login:Me "cmd:.tele goldshire" cmd:.gps \
    "cmd:.go xyz -11208.5 1685.34 25.76" trigger:78 "cmd:.gm on" trigger:78 cmd:.recall logout
```

The client answers teleports by itself, as the real one does.


`tools/testclient.py` is a scripted 1.12.1 client written in Python, independent of the D code
(see its header for the actions):

```sh
python3 tools/testclient.py 3724 tester PASSWORD create:Probe:1:1 login:Probe query move:1:2:3 say:hi logout delete:Probe
```

It checks the update packet structure on its own: the mask sizes against the client's field
counts, that every slot points at an object the client was sent, and that no byte is left over.

You need running servers with CMaNGOS databases and extracted DBCs. `~/dmangos-server` (outside the
repo) has that set up: a portable MariaDB, `start.sh`/`stop.sh`, and a test account. To build such
a setup from scratch without root:

* Use `apt-get download` with `dpkg -x` to unpack `libmariadb3`, `mariadb-server-core` and
  `mariadb-client-core`, then run `mariadbd --no-defaults` with a private data directory and
  socket.
* Import CMaNGOS's `sql/base/realmd.sql` and `characters.sql`, and classic-db's
  `Full_DB/*.sql.gz` (about 5 s).
* Extract the DBCs with `bin/extractor -i CLIENT -o DATA` and point `data_dir` at `DATA`.
* Create accounts with `bin/authserver --config ... account create NAME PASSWORD`.

Restart the servers after rebuilding. Right after a start, the realm shows as offline for up to
5 seconds, until the login server's next realm list refresh.

### The real client

Point `realmlist.wtf` at 127.0.0.1. If the client hangs on the loading screen, the last update
packet was wrong. Check `logs/worldserver.log`, then run `tools/testclient.py`'s `login` action on
the same character: its parser points at the broken block.

## Pitfalls found so far

These are facts about CMaNGOS and the 1.12 client that the code relies on, and that cost time to
find.

* **CMaNGOS never saves default spells**, or spells taught by skills. It relearns them at every
  login. Load only `character_spell`, and the spellbook comes up nearly empty.
* **Update field types matter on the wire.** The five stats, their bonus fields and resistances
  are integers. CMaNGOS keeps some of them as floats internally and converts them to integers when
  sending. Attack times are integers too. `PLAYER_FIELD_MOD_DAMAGE_DONE_PCT` is sent as a float,
  though CMaNGOS's table says integer. `updatefields.d` encodes all of this.
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
  ignored, as CMaNGOS ignores it.
* **Group health views:** health is `DYNAMIC`, so joining or leaving a group changes what members
  in sight see without any field changing. `groupChanged` sends those values on purpose
  (CMaNGOS's `ForceValuesUpdateAtIndex`).
* **The client sends `MSG_MOVE_TELEPORT_ACK` with a full 8-byte guid**, not a packed one; the
  server's `MSG_MOVE_TELEPORT_ACK` has a packed one.
* **Packets for another player are sent by the server loop.** A session that delivers to another
  (chat, moves, group updates, GM commands) only queues the bytes; `TcpServer.run` collects every
  session's output on each pass. It used to collect it only when that client sent something, which
  delayed everything an idle player should see until its next ping. Scripted clients that keep
  sending hide that kind of bug, so live tests should include a client that only listens.
* **`.modify` field types:** the typed setters reject a float for an integer field at compile
  time, so a `modifiableFields` row with the wrong field does not compile.
* **Update field offsets are absolute.** CMaNGOS's table, and `updatefields.d`, give every field its
  slot from the start of the object (`UNIT_NPC_FLAGS` is slot 0x93); some tools and posts give them
  relative to the type's start. The Python client's debug prints once added `OBJECT_END` twice.
* **Creature health comes from `creature_template_classlevelstats`**, times the template's
  `HealthMultiplier`, not from `MinLevelHealth`. The latter is used only without a stats row.
* **`creature.id` can be 0**: the spawn takes an entry from `creature_spawn_entry` or its spawn
  group. Pools and spawn groups decide which spawns are up; spawning every row gives several copies
  of rare creatures and thousands of extra herbs and veins.
* **Logging out takes 20 seconds** for player accounts. Session tests log out at once because
  `newCreationContext` sets `instant_logout` to 0; the tick test sets it back.
* **Ids** come from `MAX(id) + 1` at start-up. Never run dmangos and mangosd on the same characters
  database at once.
* **Client builds:** 5875, 6005 and 6141 share the world protocol. The login protocol differs
  slightly (see the README's protocol notes).
