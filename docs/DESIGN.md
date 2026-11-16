# Design: dmangos as a D program

dmangos follows CMaNGOS's *behaviour*: the same packets, rules, SQL and order of operations. That
makes it checkable against a reference, and lets it run on CMaNGOS's data. It does not follow
CMaNGOS's *structure*. Where C++ needs a runtime table, a code generator, a class hierarchy or a
macro, D usually has a compile-time feature that does the job more directly. This document lists
those choices, so new code can follow them.

The rule of thumb: **use a D feature when it removes a whole class of mistakes or a whole layer
of boilerplate.** Don't use one just to show it off. Plain structs, plain functions and plain loops
are the default.

## Compile-time data and code generation

| What | Where | What it replaces in C++ |
|---|---|---|
| The update field table is compile-time data. Constants, per-type slot counts, and type and visibility arrays are derived from it with CTFE and a string mixin. | `world/updatefields.d` | A generated header plus a runtime `g_updateFieldsData` array. |
| `UpdateValues.set!FIELD(value)` looks the field up by name at compile time and rejects a value of the wrong type. | `world/objects.d` | `SetUInt32Value`/`SetFloatValue`, whose type is unchecked. Writing a float into the integer stat fields was a real bug here, and now it doesn't compile. |
| A DBC store's reader is generated from CMaNGOS's format string, and the record struct is checked against it at compile time. | `dbc.d`, `world/clientdata.d` | `DBCFileLoader` interpreting the format at run time. |
| Packet (de)serialization is generated from the struct fields, with UDAs for the wire formats: `@CString`, `@LengthPrefix!T`, `@Remainder`, ... `wireSize!T` is computed with CTFE and `static assert`ed against the C++ sizes. | `serialization.d`, `*/packets.d` | Hand-written `operator<<` chains per packet. |
| Packet dispatch is a `switch` generated from `@Handles` attributes. The dispatcher deserializes the handler's parameter type for it. | `net/dispatch.d` | CMaNGOS's opcode table with function pointers and manual `recv_data >>` reads. |
| `movementOpcodes` is collected from the `Opcode` enum at compile time. | `world/opcodes.d` | A hand-maintained list. |
| Chat commands are methods with a `@Command` attribute. The command table, and the `switch` that calls them, are generated from those attributes across every handler group. | `world/commands.d` | ArcEmu's and CMaNGOS's `ChatCommand` tables of names, levels and function pointers, kept in step with the handlers by hand. |
| `.modify`'s fields are a table of update field constants; a string mixin turns each row into a command, and the typed setters check each field's type at compile time. | `world/gmcharacter.d` | ArcEmu's table with raw field offsets and a runtime float/integer switch. |
| `readArguments!required(args, a, b, c)` reads a command's arguments into variables, converting each to its type. | `world/commands.d` | `strtok` and `atoi` in every handler. |
| `@PackedGuid` marks a `ulong` field sent in packed form; the serializer handles it like any other field. | `serialization.d` | `data << guid.WriteAsPacked()` in each packet's code. |
| `notice(type, channel, extra...)` writes a channel notice from its arguments' types: a guid, a name or a number. | `world/channel.d` | Some thirty `Channel::Make*` functions. |
| `item_template`'s query columns and their target fields are a CTFE table, and the loader is generated from it. | `world/worlddata.d` | 120 hand-written `fields[i].Get...()` lines. |
| SQL is a template parameter. Placeholders are counted at compile time, so a wrong argument count fails the build. | `mysql/connection.d` | Runtime `PExecute` format strings. |
| The SRP6 constants, the MPQ crypt table and the PKWare Huffman tables are computed during compilation. | `crypto/srp6.d`, `mpq/*.d` | Static initializers or init-time code. |
| The log functions are generated from the `LogLevel` members, and the MySQL API table from a list of signatures. | `log.d`, `mysql/binding.d` | Macros. |

**Guideline:** when CMaNGOS has a table, such as fields, opcodes, DBC formats or SQL columns,
make it D data that the compiler reads. Derive the code from it, and cross-check the result with
`static assert` against numbers from CMaNGOS's headers (`PLAYER_END == 1282`, packet sizes, ...).

## Composition instead of inheritance

* **Mixin templates split a class across modules.** `WorldSession`'s handlers are in
  `charscreen.d` and `inworld.d`, each a `mixin template` that becomes part of the class. It's the
  structure of CMaNGOS's `*Handler.cpp` files without a base class or a friend declaration.
* **`mixin ServerPacket!(Opcode.X)`** gives a packet struct its opcode, so
  `send(ServerPong(seq))` needs no opcode argument and can't send the wrong one.
* **Interfaces only at real seams.** `WorldDatabase` has a MySQL and an in-memory implementation.
  `NetSession` is what the server loop needs. `Inhabitant`, `OnlinePlayer` and `Directory` are what
  maps, groups and channels need from sessions and the context, so their tests run on fakes
  instead of whole sessions. Game objects are structs and final classes, not a
  `Object → Unit → Player` hierarchy: an item is just an `UpdateValues` of type `TypeId.item`.

## Contracts and invariants

Contracts state what callers must provide and what a function guarantees, and they are checked in
debug builds:

* `in`: `Handles` needs at least one opcode. `UpdateValues.set` checks that an index stays inside
  fields of the same type. `Player` needs a non-zero guid and level. `equipped` needs an equipment
  slot. Byte writers reject embedded NULs.
* `out`: `computeStats` never returns 0 maximum health. A fresh `Player` has no unsent changes.
  `parseNumbers` returns exactly `count` numbers. Encoded packets are at least a header long.
* `invariant`: `WorldSession` (an authenticated session encrypts; a player exists exactly while in
  the world), `UpdateValues` (the change mask matches the slots), `ByteReader`, the login session
  and the in-memory databases.

**Guideline:** write a contract when breaking the rule would be a bug in *our* code. Malformed
input from the network is not a contract violation: reject it with an exception or a reply.

## Resource management

* `scope (exit)` closes connections, sockets, listeners, MPQ archives and result sets where they
  are opened.
* `transaction(scope void delegate())` is the database's unit of work: `scope (failure)` rolls
  back, and the normal exit commits.
* Memory is the GC's. The hot paths (packet parsing) slice the input buffer instead of copying.

## Built-in types

* **Slices** are used for zero-copy parsing (`ByteReader` hands out views of the input),
  `~=` for building buffers, and `[] =` for bulk assignment (`tutorials[] = uint.max`).
* **Associative arrays** hold everything looked up by id: item templates, spells, player info by
  race and class, the session table, and the in-memory database. `require` and `get(key, default)`
  replace find-then-insert code.
* **`Nullable!T`** is used for "maybe a row" results instead of out-parameters and booleans.
* **Ranges and `std.algorithm`** are used where they read better than a loop, e.g.
  `motd.splitter('@').filter!(l => l.length)`, `skillOrder.remove!(id => ...)`, or
  `spells.map!(id => InitialSpell(id)).array`. A loop is kept when it carries state or
  early exits that a pipeline would hide.

## Attributes

`pure`, `nothrow`, `@nogc` and `@safe` are on the leaf functions where they hold: byte handling,
crypto, stats formulas, guid helpers and field access. They're not forced onto code that logs or
touches the database. `@trusted` is limited to a few small, obviously correct functions (float
bit casts).

## Testing

* Every module has `unittest` blocks next to the code they test. `version (unittest)` modules
  (`testdata`, `testclient`) hold fixtures and are not compiled into the programs.
* Compile-time facts are `static assert`ed right where they are defined.
* "Must not compile" rules are tested too:
  `static assert(!__traits(compiles, values.set!UNIT_FIELD_STAT0(22.5f)))`.
* Expected values come from CMaNGOS's sources and from real 1.12.1 data, not from running the code
  and copying its output.

## Naming

* Protocol names keep CMaNGOS's spelling (`CMSG_PLAYER_LOGIN`, `UNIT_FIELD_HEALTH`,
  `CHAR_CREATE_SUCCESS`), so they can be looked up in any 1.12 reference. Everything else is D
  style: `camelCase` functions and values, `PascalCase` types, and enum members like
  `PlayerClass.warrior`.
* Every port names its CMaNGOS original in its documentation comment (`` `Player::LoadFromDB` ``),
  so the reference code is one search away.
