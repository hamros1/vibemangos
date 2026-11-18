# Writing D in dmangos

The rules this code base follows, so that new code reads like the rest. Each says what the code
already does and where to look. None is a reason to rewrite working code that predates it; follow it
where code is written or touched.

## Types over integers

* **An amount, an id or a kind gets a type when mixing it up is possible.** Money is `Copper`
  (`world/money.d`): sums stop at a purse's ceiling, differences at nothing, and no integer becomes
  money implicitly, so a `uint` sum that can wrap does not compile where money is expected. Spell
  effects, aura types, targets and damage classes are enums (`world/spellids.d`), and the spell data's
  fields have those types.
* **Convert at the boundary.** The database and the wire keep their plain numbers; the conversion
  happens once, where a row or packet is read (`Copper(row.money)`, `SpellData.forgetUnknownIds`).
* **Where two ids of one type sit side by side, name them at the call** (`healLog(target: t, caster: c,
  ...)`). It costs nothing and a swap reads wrong.
* **Not everything needs a type.** A guid is still a `ulong`, and a cell key too: no mixup has been
  found, and the change would reach every message. Add a type when a bug or a near miss shows the need.

## Generate instead of listing

* **A list that must match another list is generated from it, or checked against it at compile time.**
  Packet handlers are found by their `@Handles` attribute (`net/dispatch.d`); GM handlers are named by
  the command tables (`world/commands.d` checks that each `handle...Command` is); client data stores
  carry their file in `@DbcFile` (`world/clientdata.d`); `dbScriptTables` is sized by its enum.
* **Wire formats come from struct definitions** (`serialization.d`, with `wireSize` computed at compile
  time), and the cluster protocol's layout has a fingerprint tied to `protocolVersion`
  (`cluster/protocol.d`): a message changed without raising the version does not compile.
* **Flat packets are structs; data-dependent ones** (update blocks, movement) are written with
  `ByteWriter`, where the code is clearer than any attribute language would be.
* **No metaprogramming for show.** A template or a mixin earns its place by removing a list that could
  drift, a cast, or a copy of logic.

## Exhaustive over silent

* **A `switch` over an id enum is a `final switch`.** Every member is either handled or named in one
  explicit list of those not done, which logs once (`doEffect` in `world/spellhandlers.d`). A new member
  does not compile until someone decides.
* **Validate before switching.** A `final switch` on a value no member names aborts the process under
  `-release`. Data from the client's files, the database or the network is checked where it is read:
  `knownOr` for spell ids, enum-typed message fields for the cluster (the deserializer refuses any other
  value).
* **An `Error` is not caught.** A length prefix is checked against the bytes left before anything is
  allocated (`serialization.d`): an `OutOfMemoryError` would pass every `catch (Exception)`.

## Values, handles and ownership

* **Plain data is a struct, passed by value or `const ref`.** Classes are for identity and real
  polymorphism (sessions, map objects with their test fakes, cluster replicas).
* **A struct that owns arrays but must not be copied says so** (`@disable this(this)` on
  `UpdateValues`).
* **No `Object` and casts where the type is known** (`Creature.petData` is a `PetState`). A downcast
  in a hot path is replaced by a reference cached when the object is added (`Map`'s entities).
* **Static data lives in the frozen arena** (`frozen.d`), out of the collector's scan; what comes out
  of it with indirections is `const`.

## Safety

* **Leaf modules are `@safe:`** (crypto, timer, events, metrics, hex, vmap math, the cluster protocol
  and regions). A `@trusted` function is small and its comment says why it is sound.
* **No module-level mutable variable is thread-local by accident.** One set once at start-up is
  `__gshared`; a counter shared by all is a `shared` atomic. Our code compiles under
  `-preview=nosharedaccess` (the flag waits on `std.parallelism` in the extractor).
* **The handler mixins are not `@safe`**, and are not made so wholesale: they call into the world core,
  which is not either. Pure helpers are annotated `pure nothrow @nogc @safe`.

## Character's mixins

`Character` is composed from about forty mixin templates, the D way of keeping each handler group
beside its state without a partial class. They share one namespace: `tools/harness/mixin-names.py`
(run by `tools/harness/check.sh`) reports any name defined twice. A mixin method can implement one of
`Character`'s interfaces directly; give it the interface's name and make it `public`.

## Performance

A change made for speed is measured (`tools/harness/bench.sh`, docs/BENCHMARKS.md) and kept only if
the numbers show it: epoll was kept for its connection ceiling, not for speed it did not give.
