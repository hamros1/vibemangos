# D server pointer inventory

Audit of working-tree source at revision `63a67fb`, including local edits. A syntax-tree walk of all 326 tracked D files covered declarations and casts, unary address and dereference operators, typed function pointers, slice `.ptr`, and `in` / `!in` expressions. It parsed every file without a syntax error. The table adds generated MySQL signatures, selected inferred native handles and pointer arithmetic, and the project-owned navigation shim. Imported Recast/Detour internals, compiler-generated hidden pointers, implicit array decay, and every subsequent use of an already inventoried variable are outside the enumeration. Slices, class references and delegates are ordinary D types. Explicitly taking a delegate is included to distinguish it from a data pointer. A row covers all matching tokens on one line. Multiple roles on that line share the verdict on its main operation. Confidence describes the recommendation, not a proof of runtime reachability. No collector pause or allocation rate can be derived from this inventory.

## Reading the high-impact sites

- **Qualifier boundary.** The public decoder accepts caller storage by reference and strips its qualifiers at `plaindata.d:92,97`. Enforce writable output there. Nested strings and qualified fields still need initialization from newly owned bytes. This is a public API contract problem. The ordinary service callers examined provide mutable outputs.
- **Lifetime.** `regionAt` already ties the result to its slice at `cluster/regions.d:239`. `world/loot.d:615` and the test helper at `world/playercreate.d:1317` return borrows into caller-supplied aggregates without that explicit relationship. `vmap/maptree.d:132` exports a struct receiver through an output record. Its observed caller uses GC-array elements and the liquid query consumes the result immediately at line 390. Narrowing the lower-level API is sufficient.
- **Stored pointers.** `world/inventory.d:710,715` deliberately retains the supplied update-field address. `world/player.d:226` and `world/playercreate.d:357` provide fields of the same owner object, which Inventory also retains. The supplied address must have that owner lifetime. For spell/template pointers stored by auras, casts and creatures, verify that publication of frozen tables precedes retention. Frozen removal/rebuild explicitly leaves existing pointers on the previous version (`frozen.d:352–369`). Ask the owner whether live edits must update those readers.
- **GC visibility.** The poller encodes connection addresses as integers (net/server.d:221,301). The typed Connection[] at line 213 owns live objects until after the readiness batch and poller removal at line 533. The foreign/kernel integer cannot serve as the sole GC root. The manual slab cursor in `frozen.d:44–74` is native, so numeric alignment arithmetic there cannot hide an otherwise-live GC object. Deep-copy restrictions keep GC pointers out of unregistered slabs, and `edit` registers only the outer row before giving mutable access to indirect fields (`frozen.d:319–332`). For an indirect element inside a separate native child allocation, registering the outer slice descriptor leaves the child bytes unscanned. A later assignment into that child can install a GC reference without a traced owner. Limit edits to replacing an entire frozen value with a fresh deep copy, or deep-thaw the reachable child storage into traced D memory before permitting nested mutation. Preserve the root registration for the outer row in the latter design. `clear` and frozen `remove` drop the bookkeeping without unregistering old ranges. This preserves old issued addresses and can retain old edited rows’ object graphs. Count rebuilds and bytes on real reloads before changing the arena lifetime.
- **Generation and type checks.** At `store.d:56–58` compare against a live slot as well as its generation. Raw pointers returned by Store and Side must be reacquired after mutation, including growth and dense swap removal. Chunked script states deliberately avoid relocation on pool growth, while generation/occupancy still controls reuse (`script/registry.d:268–309`). Strengthen tick dispatch at `script/registry.d:614–622` to validate the context type against the kind as event dispatch already does.
- **Small simplifications.** The final switch at `world/context.d:3775–3785` always returns an actual counter. A ref return expresses this directly. Replace repeated scalar bit-punning with one pair of value-returning helpers based on `vmap/math.d:328,335`, which already compiles as `@safe nothrow @nogc`.
- **Native ownership.** `navigation.d:122–130` copies the returned tile into D storage before release. `mysql/connection.d:451–479` frees native results after copying each non-null column with its explicit byte length. Keep both copies. In the C++ tile builder, two intermediate array allocations use throwing `new[]` with raw allocations already live. Give them the same failure discipline as the other tile-build steps.

## Verdict key

Each site row names a key whose purpose, verdict, suggested alternative and confidence are defined here. The operations column distinguishes a declaration from a read, lookup or retention.

| Key | Purpose | Verdict | Alternative or lifetime condition | Confidence |
|---|---|---|---|---|
| A | Optional reference · AA/table lookup | Idiomatic | Keep the single lookup. Use the entry in its ownership epoch. | High |
| B | Membership test · temporary lookup | Idiomatic | Keep the boolean test. No stored address is required. | High |
| P | Reference to a value or subobject | Idiomatic | Keep the alias when identity, mutation or absence matters. Confirm the owner outlives retention. | Medium |
| D | Indirect read or write | Idiomatic | Keep the explicit dereference where the supplying API returns a pointer. | Medium |
| R | Returned borrow · owner-backed value | Idiomatic | Keep nullable lookup. Document invalidation at the owning API. Check return scope for caller-supplied storage. | Medium |
| L | Caller-supplied borrowed result | Questionable | Tie result to input with return scope or return ref as applicable. Check DIP1000 compatibility. | High |
| S | Static immutable row | Idiomatic | Keep. The target lives for the process. | High |
| K | Annotated slice-element borrow | Idiomatic | Keep return scope and inout. No allocation on lookup. | High |
| F | Function pointer or bound delegate | Idiomatic | Keep typed callback and its receiver context. Use scope only for synchronous consumers. | Medium |
| C | C ABI · native function, data or handle | Idiomatic | Keep pointer at the native boundary and the D owner or copy at its wrapper. | High |
| N | Navigation boundary · native memory or call borrow | Idiomatic | Keep. D input is synchronous. Mesh and query are native-owned until close. Copy tile output before freeing. | High |
| E | Registry · erased state/context/code pointer | Idiomatic | Keep the private erasure boundary and validate the registered type and handle at dispatch. | High |
| ET | Registry · erased context on tick | Questionable | Mirror the context/kind validation in raise before dispatch. Consume context within tick. | High |
| I | Buffer identity comparison | Idiomatic | Keep. Only storage identity is being compared. | High |
| H | Frozen data · manual arena or GC visibility | Idiomatic | Keep deep-copy restrictions. A registered row covers only its own bytes. See the nested-edit restriction above. | High |
| Q | Trusted write bypasses qualifiers | Questionable | Limit the public decoder to writable output. Keep construction of owned qualified fields private. | High |
| W | Plain-data scalar representation | Idiomatic | Keep native-format conversion inside the constrained serialization boundary. | Medium |
| U | Scalar bit reinterpretation | Questionable | Use a shared value-returning helper modeled on vmap/math.d:328,335. | High |
| Y | Optional slot borrow · generation or dense index | Idiomatic | Keep the handle. Reacquire after growth, removal or reuse. | High |
| G | Slot generation and occupancy | Questionable | Require a live slot as well as a matching generation before returning its address. | High |
| M | Address escapes through output record | Questionable | Keep the lookup synchronous. Restrict ModelInstance.locate visibility or encode receiver/output lifetime. | High |
| V | Non-null counter lvalue | C++ smell | Use a ref uint return. Update through the ref return or a ref parameter. | High |
| T | Temporary shuffle of borrowed loot entries | Idiomatic | Keep pointer shuffle semantics. Only reuse scratch if allocation counts justify it. | High |
| J | Native output / option target | Idiomatic | Keep the address expected by getopt or the system API. | High |
| X | Index into a byte buffer | Questionable | Use bounded scalar/string reads and the DBC decoder for this real-data test. | High |
| Z | Redundant address and dereference | Questionable | Iterate the AA static-array value directly after verifying equivalent ref iteration with DMD. | Medium |
| O | Retained owner-field address | Idiomatic | Keep owner-backed storage for Inventory. An ordinary scope parameter would contradict storage in the object. | High |
| CC | C++ shim · Recast/Detour pointer | Idiomatic | Keep the C ABI and explicit native ownership. Call-local temporaries use the matching release routine. | High |
| CA | C++ shim · intermediate allocations | Questionable | Make allocation failure follow the existing error/cleanup path. These two throwing new[] calls bypass it. | High |
| VEC | GC allocation of a struct | Idiomatic | Keep GC ownership for heap-stable test data. | High |
| GO | Required immutable input during call | C++ smell | Accept scope const ref GameObjectSpawn. The wrapper reads and copies it without retaining its address. | High |
| CS | Borrowed spawn with local rebinding | Idiomatic | Keep the local pointer for the event override. Mark the borrowed input scope if validated under DIP1000. | High |
| OPT | Optional output parameter | Idiomatic | Keep the nullable writable pointer. Add scope to the non-retaining parameter when compiler-checked. | High |
| NET | C event token · encoded GC object address | Idiomatic | Keep the separate Connection[] root and unregister before releasing it. An integer in epoll is not a GC root. | High |
| NEWS | Type-erased service event | Idiomatic | Keep synchronous handling and reconstruct the type from the same registered news ID. | High |
| RAW | Byte representation · file header | Questionable | Write the explicit wire order through the existing byte writer, especially on a new architecture. | Medium |
| FIX | Test fixture writes through const pointer | Questionable | Construct or edit the mutable test fixture through its owner before exposing a const row. | Medium |

## Returned pointers and scope

These are pointer results crossing function scope. “Owner-backed” marks an explicit escape even where the signature has no `scope`/`return` marker. A heap-backed table, static constant, or native-owned handle can legitimately outlive the call. A blanket `scope` on retained inputs would misstate ownership. Receiver-backed results should name their invalidation point, including table rebuild, slot reuse or reallocation.

| File and line | Result | Origin or lifetime |
|---|---|---|
| `source/dmangos/auth/database.d:257` | `byName` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/auth/database.d:264` | `byId` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/cluster/config.d:86` | `voter` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/cluster/node.d:1638` | `find` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/cluster/regions.d:239` | `regionAt` | Explicit return scope slice input. |
| `source/dmangos/cluster/services.d:341` | `local` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/dbc.d:182` | `lookup` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/extractor/assembler.d:47` | `raw` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/frozen.d:266` | `find` | Building AA or process-lifetime slab. An old pointer can cease to name the active row after rebuild. |
| `source/dmangos/frozen.d:275` | `opBinaryRight` | Building AA or process-lifetime slab. An old pointer can cease to name the active row after rebuild. |
| `source/dmangos/frozen.d:281` | `opBinaryRight` | Building AA or process-lifetime slab. An old pointer can cease to name the active row after rebuild. |
| `source/dmangos/frozen.d:319` | `edit` | Building AA or process-lifetime slab. An old pointer can cease to name the active row after rebuild. |
| `source/dmangos/mpq/archive.d:310` | `find` | Owner-backed result. scope on the input key describes its consumption only. |
| `source/dmangos/mysql/binding.d:149` | `openLibrary` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/mysql/binding.d:154` | `findSymbol` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/mysql/binding.d:165` | `openLibrary` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/mysql/binding.d:170` | `findSymbol` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/mysql/connection.d:539` | `fakeInit` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/mysql/connection.d:541` | `fakeConnect` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/mysql/connection.d:550` | `fakeError` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/mysql/connection.d:569` | `fakeStore` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/navigation.d:60` | `dmnav_mesh_create` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/navigation.d:64` | `dmnav_query_create` | Native handle, library symbol, or ABI test double. Follows native owner or static storage. |
| `source/dmangos/script/registry.d:253` | `at` | Chunked pool owner. Valid for the current occupied generation. |
| `source/dmangos/script/registry.d:305` | `at` | Chunked pool owner. Valid for the current occupied generation. |
| `source/dmangos/scripts/npcs.d:284` | `which` | Static immutable table, process lifetime. |
| `source/dmangos/scripts/professions.d:289` | `schoolOf` | Static immutable table, process lifetime. |
| `source/dmangos/store.d:56` | `opIndex` | Backing array owner. Reacquire after growth, removal or slot reuse. |
| `source/dmangos/store.d:140` | `opIndex` | Backing array owner. Reacquire after growth, removal or slot reuse. |
| `source/dmangos/world/auctionhandlers.d:32` | `auctionHouseOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/battleground.d:244` | `template_` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/battleground.d:756` | `eventOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/caster.d:106` | `fields` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/caster.d:117` | `auras` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/channel.d:200` | `channelEntry` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/classspells.d:377` | `aurasOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/classspells.d:1547` | `illuminatedSpell` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/classspelltests.d:99` | `spell` | Test helper returns a world-data row. Keep fixture alive for its consumers. |
| `source/dmangos/world/clientdata.d:962` | `areaByFlag` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/clientdata.d:992` | `charSection` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/clientdata.d:1003` | `facialHair` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/clientdata.d:1054` | `talentSpellPos` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/clientdata.d:1063` | `chatChannelFor` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:248` | `weatherOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:1375` | `recentHandoff` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:1650` | `remotePlayer` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:1659` | `remotePlayer` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:1776` | `creatureSpawnOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:3582` | `instanceState` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:3775` | `counterOf` | Explicit receiver return annotation. Result is always present. |
| `source/dmangos/world/context.d:4010` | `spellInfo` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:4022` | `broadcastText` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:4123` | `loanSpawn` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:4805` | `scriptText` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/context.d:5906` | `auctionHouse` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/creature.d:450` | `npcTemplate` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/creature.d:490` | `npcTemplate` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/creature.d:608` | `npcTemplate` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/creatureai.d:47` | `spellInfo` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/creatureai.d:53` | `broadcastText` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/creatureai.d:69` | `scriptText` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/creaturelinking.d:80` | `linkOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/death.d:42` | `closestGraveyard` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/death.d:45` | `fromLinks` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/effecthandlers.d:847` | `spell` | Test helper returns a world-data row. Keep fixture alive for its consumers. |
| `source/dmangos/world/gmlevel2.d:668` | `spellNamed` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/guild.d:127` | `member` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/guild.d:136` | `memberNamed` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/loot.d:615` | `rollGroup` | Element of caller-supplied storage. No explicit return scope on that input. |
| `source/dmangos/world/mailhandlers.d:181` | `deliveredMail` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/meetingstone.d:189` | `player` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/meetingstone.d:198` | `party` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/pet.d:563` | `statsFor` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/pethandlers.d:198` | `unstabledPet` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/playercreate.d:920` | `skillInfo` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/playercreate.d:1317` | `itemOf` | Element of caller-supplied storage. No explicit return scope on that input. |
| `source/dmangos/world/quests.d:245` | `greetingOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/quests.d:253` | `quest` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realclass_magewarlockpriest.d:69` | `spellOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realclass_paladin_shaman_druid.d:66` | `spellOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realclass_pets.d:36` | `spellOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realclass_warrior_rogue_hunter.d:62` | `spellOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realnpcsweep.d:851` | `dispellable` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realrules_combat.d:39` | `spellOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realscriptkit.d:280` | `spawnRow` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realscriptkit.d:289` | `objectRow` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realscriptkit.d:615` | `line` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/realspellsweep.d:331` | `dispellable` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/reputation.d:103` | `stateOf` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/spellhandlers.d:5801` | `s` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/spells.d:286` | `procEvent` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/spells.d:296` | `spell` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/spells.d:336` | `learnedSkill` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/unit.d:204` | `auraSet` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/unit.d:215` | `fields` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/worlddata.d:508` | `mapEntranceTrigger` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/worlddata.d:522` | `findTeleport` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/worlddata.d:559` | `createInfo` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/worldpvp.d:1348` | `worldPvpGraveyard` | Owner-backed lookup. No explicit result lifetime marker in this declaration. |
| `source/dmangos/world/worldspelltests.d:27` | `scripted` | Test helper returns a world-data row. Keep fixture alive for its consumers. |

## Pointer usage table

Paths in headings are relative to the workspace. Each line number resolves against that file. The source column shows the original line, abbreviated for long calls.


### `source/dmangos/auth/context.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 33 | addr | <code>this.realms = new RealmCache(&amp;database.loadRealms, config.realmsStateUpdateDelay);</code> | F |

### `source/dmangos/auth/database.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 128 | lookup | <code>auto account = canonicalAccountName(username) in accounts;</code> | A |
| 132 | deref | <code>Account result = *account;</code> | D |
| 221 | lookup | <code>enforce(name !in accounts, "account '" ~ name ~ "' already exists");</code> | B |
| 257 | return, type | <code>private Account* byName(string username)</code> | R |
| 259 | lookup | <code>auto account = canonicalAccountName(username) in accounts;</code> | A |
| 264 | return, type | <code>private Account* byId(uint id)</code> | R |
| 268 | addr | <code>return &amp;account;</code> | R |

### `source/dmangos/auth/main.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 58 | addr | <code>"config&#124;c", "Configuration file (default: authserver.json)", &amp;configPath);</code> | J |
| 121 | fn | <code>private alias Command = int function(LoginDatabase database, string[] args);</code> | F |
| 127 | addr | <code>"account create": &amp;createAccount,</code> | F |
| 128 | addr | <code>"account password": &amp;changePassword,</code> | F |
| 129 | addr | <code>"account level": &amp;changeLevel,</code> | F |
| 130 | addr | <code>"account ban": &amp;banAccount,</code> | F |
| 131 | addr | <code>"account unban": &amp;unbanAccount,</code> | F |
| 132 | addr | <code>"account list": &amp;listAccounts,</code> | F |
| 133 | addr | <code>"ip ban": &amp;banAddress,</code> | F |
| 134 | addr | <code>"ip unban": &amp;unbanAddress,</code> | F |
| 138 | lookup | <code>auto command = (args[0] ~ " " ~ args[1]) in commands;</code> | A |
| 140 | deref | <code>return (*command)(database, args[2 .. $]);</code> | D |

### `source/dmangos/auth/throttle.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 49 | lookup | <code>if (auto record = address in records)</code> | A |
| 60 | addr | <code>auto record = &amp;records.require(address);</code> | P |

### `source/dmangos/bytes.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 321 | ptr | <code>const before = w.data.ptr;</code> | I |
| 325 | ptr | <code>assert(w.data.ptr is before, "the memory is reused");</code> | I |

### `source/dmangos/cluster/config.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 86 | return, type | <code>const(ClusterVoter)* voter(ushort id) const pure nothrow @nogc @safe</code> | R |
| 90 | addr | <code>return &amp;voters[index];</code> | R |
| 153 | lookup | <code>enforce(member.nodeId &amp;&amp; member.nodeId !in ids &amp;&amp; member.address !in addresses,</code> | B |

### `source/dmangos/cluster/link.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 372 | ptr | <code>if (rest &amp;&amp; input.ptr !is inbox.ptr)</code> | I |

### `source/dmangos/cluster/node.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 222 | lookup | <code>if (auto link = peer in links)</code> | A |
| 241 | lookup | <code>if (auto link = peer in links)</code> | A |
| 298 | lookup | <code>if (auto link = coordinatorId in links)</code> | A |
| 318 | lookup | <code>if (auto link = coordinatorId in links)</code> | A |
| 329 | lookup | <code>if (auto link = coordinatorId in links)</code> | A |
| 571 | lookup | <code>if (dial.pending is null &amp;&amp; now &gt;= dial.due &amp;&amp; (key == coordinatorKey &#124;&#124; key !in links))</code> | B |
| 573 | lookup | <code>if (key == coordinatorKey &amp;&amp; coordinatorId &amp;&amp; coordinatorId in links)</code> | A |
| 625 | lookup | <code>if (takeoverGateways.length &amp;&amp; hello.nodeId !in links)</code> | B |
| 627 | lookup | <code>if (const known = hello.nodeId in highestIncarnation)</code> | A |
| 628 | deref | <code>if (hello.incarnation &lt; *known)</code> | D |
| 637 | lookup | <code>if (const previous = hello.nodeId in highestIncarnation)</code> | A |
| 638 | deref | <code>if (hello.incarnation &lt; *previous)</code> | D |
| 669 | lookup | <code>if (auto old = peer in links)</code> | A |
| 670 | deref | <code>if (*old !is link)</code> | D |
| 672 | deref | <code>if (isCoordinator &amp;&amp; (*old).peer.incarnation != link.peer.incarnation)</code> | D |
| 673 | deref | <code>noteLostProcess(*old);</code> | D |
| 1225 | lookup | <code>if (coordinatorId &amp;&amp; coordinatorId in links &amp;&amp; coordinatorId != peer)</code> | A |
| 1232 | lookup | <code>if (auto dial = coordinatorKey in dials)</code> | A |
| 1354 | lookup | <code>if (auto current = peer in links)</code> | A |
| 1356 | deref | <code>if (*current !is link)</code> | D |
| 1365 | lookup | <code>if (auto dial = peer in dials)</code> | A |
| 1370 | lookup | <code>if (auto dial = coordinatorKey in dials)</code> | A |
| 1555 | lookup | <code>if (auto link = peer in links)</code> | A |
| 1562 | lookup | <code>if (auto link = coordinatorId in links)</code> | A |
| 1571 | lookup | <code>if (r.creature.spawn &amp;&amp; r.id !in leaving &amp;&amp; regions_.leaseHolds(now))</code> | B |
| 1579 | lookup | <code>if (auto objects = r.id in arriving)</code> | A |
| 1581 | deref | <code>arrived[r.id] = *objects;</code> | D |
| 1595 | lookup | <code>else if (auto link = coordinatorId in links)</code> | A |
| 1603 | lookup | <code>if (!isCoordinator &amp;&amp; coordinatorId in links)</code> | A |
| 1638 | return, type | <code>const(ViewMember)* find(ushort node) const</code> | R |
| 1642 | addr | <code>return &amp;m;</code> | R |
| 1713 | addr | <code>auto dial = &amp;dials.require(m.nodeId, Dial(m.address, m.nodeId, now));</code> | P |
| 1780 | lookup | <code>if (target is null &#124;&#124; address in down &#124;&#124; from in isolated &#124;&#124; target in isolated</code> | A |
| 1781 | lookup | <code>&#124;&#124; linkKey(from, target) in cutLinks)</code> | A |
| 1815 | lookup | <code>if (w.from in isolated &#124;&#124; w.to in isolated)</code> | B |
| 2370 | addr | <code>bound.onOwnership = &amp;world.regionsChanged;</code> | F |
| 2377 | addr | <code>world.releaseSession = &amp;bound.releaseSession;</code> | F |
| 2511 | addr | <code>false, false, 9000, &amp;configure);</code> | F |
| 2516 | addr | <code>auto isolatedWorker = cluster.add(4, 9003, 4, CoordinatorSetup.init, false, false, 9000, &amp;configure);</code> | F |
| 2517 | addr | <code>auto gateway = cluster.add(5, 9004, 5, CoordinatorSetup.init, false, true, 9000, &amp;configure);</code> | F |
| 2529 | addr | <code>node.onOwnership = &amp;world.regionsChanged;</code> | F |
| 2531 | addr | <code>node.onTermChanged = &amp;bridge.fenceGatewaySimulations;</code> | F |
| 2537 | addr | <code>world.releaseSession = &amp;node.releaseSession;</code> | F |
| 2655 | addr | <code>node.onOwnership = &amp;world.regionsChanged;</code> | F |
| 2662 | addr | <code>world.releaseSession = &amp;node.releaseSession;</code> | F |
| 2777 | addr | <code>context.creatureLease = &amp;bound.regions.creatureRegion;</code> | F |
| 2778 | addr | <code>context.sendCreatureLoan = &amp;bound.creatureLoan;</code> | F |
| 2779 | addr | <code>bound.onCreatureRelease = &amp;context.releaseCreatureLoan;</code> | F |
| 2780 | addr | <code>bound.onOwnership = &amp;context.regionsChanged;</code> | F |

### `source/dmangos/cluster/ownership.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 131 | lookup | <code>if (r.owner &amp;&amp; r.owner !in a.members)</code> | B |
| 133 | lookup | <code>if (r.next &amp;&amp; r.next !in a.members)</code> | B |
| 185 | lookup | <code>if (!regions_.any!(r =&gt; r.owner == node &amp;&amp; r.state != RegionState.unowned &amp;&amp; r.id in busyUs))</code> | A |
| 227 | lookup | <code>if (auto target = r.id in movingTo)</code> | A |
| 228 | deref | <code>if (*target == node)</code> | D |
| 230 | deref | <code>*target = 0;</code> | D |
| 244 | lookup | <code>if (node !in members &#124;&#124; node == self &amp;&amp; members.length == 1)</code> | B |
| 253 | lookup | <code>if (auto target = r.id in movingTo)</code> | A |
| 254 | deref | <code>if (*target == node)</code> | D |
| 256 | deref | <code>*target = 0;</code> | D |
| 283 | lookup | <code>return (node in draining) !is null;</code> | A |
| 299 | lookup | <code>if (!spawn &#124;&#124; !caller &#124;&#124; !enemy &#124;&#124; borrower !in members &#124;&#124; isDraining(borrower))</code> | B |
| 386 | lookup | <code>if (target &amp;&amp; target in members)</code> | A |
| 427 | lookup | <code>if (r.id !in held)</code> | B |
| 520 | lookup | <code>if (r.owner == busiest &amp;&amp; r.state == RegionState.granted &amp;&amp; r.map !in wholeMaps &amp;&amp; !r.creature.spawn</code> | B |
| 521 | lookup | <code>&amp;&amp; (r.id !in splitAt &#124;&#124; now - splitAt[r.id] &gt;= balancing.interval)</code> | B |
| 523 | addr | <code>hottest = &amp;r;</code> | P |
| 567 | lookup | <code>return (id in movedAt &amp;&amp; now - movedAt[id] &lt; balancing.cooldown)</code> | R |
| 568 | lookup | <code>&#124;&#124; (id in splitAt &amp;&amp; now - splitAt[id] &lt; balancing.cooldown);</code> | A |
| 586 | addr | <code>auto keep = a.id &lt; b.id ? &amp;a : &amp;b;</code> | P |
| 618 | lookup | <code>if (node !in draining)</code> | B |
| 776 | lookup | <code>if (auto had = r.id in owned)</code> | A |
| 780 | deref | <code>lost ~= *had;</code> | D |
| 782 | deref | <code>*had = r;</code> | D |
| 792 | lookup | <code>if (id !in nowOwned)</code> | B |
| 804 | lookup | <code>if (t.id in nowOwned &amp;&amp; t.map == r.map &amp;&amp; contains(t.rect, r.rect))</code> | B |
| 830 | lookup | <code>if (r.owner == self &amp;&amp; r.state == RegionState.revoking &amp;&amp; r.id !in owned</code> | B |
| 999 | type | <code>const(Region)* moving;</code> | P |
| 1002 | addr | <code>moving = &amp;r;</code> | P |

### `source/dmangos/cluster/quorum.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 221 | cstr | <code>const directory = open(dirName(path).toStringz, O_RDONLY);</code> | C |

### `source/dmangos/cluster/regions.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 88 | lookup | <code>if (const cells = map in costs)</code> | A |
| 89 | deref | <code>foreach (key, cost; *cells)</code> | D |
| 117 | lookup | <code>leaves[$ - 1].splittable = (map in whole) is null;</code> | A |
| 130 | lookup | <code>const cells = leaves[best].map in costs;</code> | A |
| 131 | deref | <code>if (cells is null &#124;&#124; !split(leaves[best].rect, *cells, a, b))</code> | D |
| 239 | return, type | <code>inout(Region)* regionAt(return scope inout(Region)[] regions, uint map, int x, int y) pure nothrow @nogc @safe</code> | K |
| 243 | addr | <code>return &amp;regions[i];</code> | K |
| 255 | lookup | <code>if (auto l = r.owner in load)</code> | A |
| 256 | deref | <code>*l += cost.get(r.id, 0);</code> | D |
| 272 | lookup | <code>if (r.state == RegionState.unowned &amp;&amp; r.id !in held)</code> | B |
| 327 | type | <code>const(Region)* best;</code> | P |
| 330 | addr | <code>const r = &amp;regions[i];</code> | P |
| 332 | lookup | <code>if (r.owner == busiest &amp;&amp; r.state == RegionState.granted &amp;&amp; r.id !in moved &amp;&amp; r.id !in frozen &amp;&amp; c &gt; 0</code> | B |

### `source/dmangos/cluster/services.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 294 | lookup | <code>auto starter = kind in starters;</code> | A |
| 297 | lookup | <code>if (auto old = kind in hosted)</code> | A |
| 299 | deref | <code>hosted[kind] = (*starter)(state);</code> | D |
| 306 | lookup | <code>auto h = kind in hosted;</code> | A |
| 319 | lookup | <code>if (auto old = kind in hosted)</code> | A |
| 327 | lookup | <code>if (auto old = kind in hosted)</code> | A |
| 337 | lookup | <code>return (kind in hosted) !is null;</code> | A |
| 341 | return, type | <code>S* local(S)()</code> | R |
| 343 | lookup | <code>if (auto h = kindOf!S in hosted)</code> | A |
| 344 | addr, deref | <code>return &amp;(cast(Hosted!S) *h).service;</code> | R |
| 422 | deref | <code>auto reply = __traits(getMember, *service, __traits(identifier, method))(request);</code> | D |
| 447 | deref | <code>__traits(getMember, *service, __traits(identifier, method))(request);</code> | D |
| 466 | lookup | <code>auto p = sequence in pending;</code> | A |
| 498 | lookup | <code>if (auto earlier = key in answered)</code> | A |
| 500 | deref | <code>reply.reply = *earlier;</code> | D |
| 532 | lookup | <code>auto p = reply.sequence in pending;</code> | A |
| 567 | type | <code>void delegate(const(void)* news) direct;</code> | NEWS |
| 581 | deref, type | <code>(const(void)* news) { hear(*cast(const(News)*) news); },</code> | NEWS |
| 600 | addr | <code>l.direct(&amp;news);</code> | NEWS |
| 666 | lookup | <code>if (auto h = kind in hosted)</code> | A |
| 802 | addr | <code>a.provide!Tally(&amp;make);</code> | F |
| 803 | addr | <code>b.provide!Tally(&amp;make);</code> | F |

### `source/dmangos/cluster/sessions.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 66 | lookup | <code>if (auto holder = account in holders)</code> | A |
| 68 | deref | <code>if (*holder == session)</code> | D |
| 70 | lookup | <code>if (auto earlier = account in waiting)</code> | A |
| 71 | deref | <code>if (*earlier != session)</code> | D |
| 72 | deref | <code>actions ~= SessionAction(SessionAction.Kind.evict, account, *earlier);</code> | D |
| 74 | lookup | <code>if (holder.process !in lostUntil)</code> | B |
| 75 | deref | <code>actions ~= SessionAction(SessionAction.Kind.evict, account, *holder);</code> | D |
| 85 | lookup | <code>if (auto holder = account in holders)</code> | A |
| 86 | deref | <code>if (*holder == session)</code> | D |
| 92 | lookup | <code>if (auto next = account in waiting)</code> | A |
| 94 | deref | <code>const granted = *next;</code> | D |
| 101 | lookup | <code>if (auto next = account in waiting)</code> | A |
| 102 | deref | <code>if (*next == session)</code> | D |
| 133 | lookup | <code>if (owner in lostOwners)</code> | B |
| 135 | lookup | <code>if (route.next == owner &amp;&amp; account !in stoppedSimulations)</code> | B |
| 144 | lookup | <code>&#124;&#124; !saved.owner.incarnation &#124;&#124; saved.owner.node == gateway.node &#124;&#124; saved.account in holders)</code> | A |
| 159 | lookup | <code>const holder = request.account in holders;</code> | A |
| 160 | deref | <code>if (holder is null &#124;&#124; *holder != home &#124;&#124; !request.character &#124;&#124; !request.token &#124;&#124; !request.next.node</code> | D |
| 164 | lookup | <code>if (auto current = request.account in routes)</code> | A |
| 167 | deref | <code>return *current == request &#124;&#124; (request.kind == SessionRouteKind.observe</code> | D |
| 185 | lookup | <code>const oldTerm = request.account in endedRouteTerms;</code> | A |
| 190 | lookup | <code>const until = request.previous in lostOwners;</code> | A |
| 191 | deref | <code>if (until is null &#124;&#124; now &lt; *until)</code> | D |
| 205 | lookup | <code>if (const current = account in routes)</code> | A |
| 220 | lookup | <code>if (account in stoppedSimulations &#124;&#124; account in endedRouteTerms)</code> | B |
| 222 | lookup | <code>if (const current = account in routes)</code> | A |
| 224 | lookup | <code>const until = current.next in lostOwners;</code> | A |
| 225 | deref | <code>if (until !is null &amp;&amp; now &gt;= *until)</code> | D |

### `source/dmangos/dbc.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 182 | return, type | <code>const(Entry)* lookup(uint id) const</code> | R |
| 184 | lookup | <code>if (auto position = id in positionOf)</code> | A |
| 185 | addr, deref | <code>return &amp;rows[*position];</code> | R |

### `source/dmangos/extractor/assembler.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 47 | return, type | <code>RawModel* raw(string name)</code> | R |
| 49 | lookup | <code>if (auto found = name in rawModels)</code> | A |
| 52 | addr | <code>return &amp;(rawModels[name] = RawModel.read(buildPath(source, name)));</code> | R |
| 67 | type | <code>ModelSpawn*[] spawns;</code> | P |
| 70 | addr | <code>auto spawn = &amp;map.unique[id];</code> | P |
| 147 | addr | <code>exportGameObjectModels(source, destination, modelFiles, &amp;raw);</code> | F |
| 184 | type | <code>MapSpawns*[uint] readMapSpawns(string path)</code> | P |
| 186 | type | <code>MapSpawns*[uint] maps;</code> | P |
| 266 | type | <code>scope RawModel* delegate(string) raw)</code> | P |

### `source/dmangos/extractor/main.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 52 | addr | <code>options = getopt(args, "input&#124;i", "Client directory, the one containing Data/ (default: .)", &amp;input,</code> | J |
| 53 | addr | <code>"output&#124;o", "Output directory; dbc/ and maps/ are created in it (default: .)", &amp;output,</code> | J |
| 55 | addr | <code>&amp;extract,</code> | J |
| 56 | addr | <code>"map", "With -e 8: build only this map's movement maps (repeat for more)", &amp;mapIds);</code> | J |

### `source/dmangos/extractor/maps.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 172 | lookup | <code>if (auto flag = cell.areaId in areaFlagsById)</code> | A |
| 173 | deref | <code>areaFlags[i][j] = *flag;</code> | D |
| 202 | type | <code>v9[i * cellSize + y][j * cellSize + x] += cell.heights[y * (cellSize * 2 + 1) + x];</code> | P |
| 205 | type | <code>v8[i * cellSize + y][j * cellSize + x] += cell.heights[y * (cellSize * 2 + 1) + cellSize + 1 + x];</code> | P |
| 295 | type | <code>liquidHeight[i * cellSize + y][j * cellSize + x] = cell.liquid.heights[y * (cellSize + 1) + x];</code> | P |
| 435 | type | <code>const(Liquid)* liquid;</code> | P |
| 634 | lookup | <code>const water = [i, j] in t.waterLevel;</code> | A |
| 639 | lookup | <code>w.put(cast(uint)(!water ? 0 : [i, j] in t.magma ? 1 &lt;&lt; 4 : 1 &lt;&lt; 2));</code> | A |
| 677 | deref | <code>w.put(*water);</code> | D |
| 678 | deref | <code>w.put(*water);</code> | D |
| 682 | deref | <code>w.put(*water);</code> | D |
| 685 | lookup | <code>w.put(ubyte([i, j] in t.deepWater ? 0x80 : 0));</code> | A |

### `source/dmangos/extractor/mmaps.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 77 | lookup | <code>if (mapId in tilesOf &#124;&#124; (only.length &amp;&amp; !only.canFindValue(mapId)))</code> | B |
| 217 | lookup | <code>if (auto g = [x, y] in grids)</code> | A |
| 218 | deref | <code>return *g;</code> | D |

### `source/dmangos/extractor/vmaps.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 221 | lookup | <code>if (name.canFind(".wmo") &amp;&amp; name !in listed)</code> | B |
| 295 | lookup | <code>if (fileName in written)</code> | B |
| 360 | lookup | <code>auto data = wmoName in doodads;</code> | A |
| 398 | lookup | <code>if (name in written)</code> | B |
| 482 | lookup | <code>if (reference &lt; found.spawns.length &amp;&amp; found.spawns[reference].nameIndex in validDoodadNames)</code> | A |
| 486 | addr, type | <code>bytes[8 .. 12] = (cast(ubyte*)&amp;triangles)[0 .. 4];</code> | RAW |
| 487 | addr, type | <code>bytes[12 .. 16] = (cast(ubyte*)&amp;groupsWritten)[0 .. 4];</code> | RAW |
| 515 | addr | <code>wmo.rotation, 1.0f, &amp;wmo.bounds, name);</code> | P |
| 598 | lookup | <code>extracted = (name in written) !is null;</code> | A |
| 614 | type | <code>float scale, const(AABox)* bounds, string name)</code> | P |
| 626 | deref | <code>putBox(dirBin, *bounds);</code> | D |

### `source/dmangos/frozen.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 44 | type | <code>ubyte* free;</code> | H |
| 52 | arena | <code>void[] arenaAllocate(size_t size, size_t alignment) @trusted</code> | H |
| 60 | arena | <code>auto skip = (alignment - cast(size_t) free % alignment) % alignment;</code> | H |
| 61 | arena | <code>if (free is null &#124;&#124; skip + size &gt; left)</code> | H |
| 64 | type | <code>free = cast(ubyte*) malloc(want);</code> | H |
| 65 | arena | <code>if (free is null)</code> | H |
| 69 | arena | <code>skip = (alignment - cast(size_t) free % alignment) % alignment;</code> | H |
| 71 | arena | <code>auto block = free + skip;</code> | H |
| 72 | arena | <code>free = block + size;</code> | H |
| 75 | arena | <code>return block[0 .. size];</code> | H |
| 102 | arena | <code>auto block = cast(T[]) arenaAllocate(count * T.sizeof, T.alignof);</code> | H |
| 109 | addr | <code>emplace(&amp;element);</code> | H |
| 130 | arena | <code>auto copy = cast(E[]) arenaAllocate(value.length * E.sizeof, E.alignof);</code> | H |
| 137 | addr, type | <code>(cast(ubyte*) &amp;copy[i])[0 .. E.sizeof] = (cast(ubyte*) &amp;e)[0 .. E.sizeof];</code> | H |
| 157 | addr, deref, type | <code>*cast(F*) &amp;copy.tupleof[i] = *cast(const(F)*) &amp;value.tupleof[i];</code> | H |
| 159 | addr, deref, type | <code>*cast(F*) &amp;copy.tupleof[i] = cast(F) frozenCopy(value.tupleof[i]);</code> | H |
| 168 | type | <code>bool inCollectedHeap(const(void)* p) @trusted</code> | H |
| 172 | type | <code>return GC.addrOf(cast(void*) p) !is null;</code> | H |
| 181 | ptr | <code>assert(!inCollectedHeap(copy.name.ptr) &amp;&amp; !inCollectedHeap(copy.ids.ptr));</code> | H |
| 236 | addr, type | <code>(cast(ubyte*) &amp;keys_[i])[0 .. K.sizeof] = (cast(ubyte*) &amp;k)[0 .. K.sizeof];</code> | H |
| 237 | addr, type | <code>(cast(ubyte*) &amp;values_[i])[0 .. V.sizeof] = (cast(ubyte*) &amp;v)[0 .. V.sizeof];</code> | H |
| 266 | return, type | <code>private inout(V)* find(const K key) inout @trusted</code> | R |
| 270 | addr | <code>return &amp;values_[i];</code> | R |
| 271 | lookup, type | <code>return cast(inout(V)*)(key in building);</code> | A |
| 275 | return, type | <code>Value* opBinaryRight(string op : "in")(const K key) @trusted</code> | R |
| 281 | return, type | <code>const(V)* opBinaryRight(string op : "in")(const K key) const @trusted</code> | R |
| 292 | deref | <code>return *p;</code> | D |
| 302 | deref | <code>return *p;</code> | D |
| 310 | deref | <code>return *p;</code> | D |
| 319 | return, type | <code>V* edit(const K key) @trusted</code> | R |
| 323 | lookup | <code>return key in building;</code> | R |
| 325 | lookup | <code>if (i !in rooted)</code> | B |
| 329 | addr | <code>GC.addRange(&amp;values_[i], V.sizeof);</code> | H |
| 332 | addr | <code>return &amp;values_[i];</code> | R |
| 339 | deref | <code>*p = value;</code> | D |
| 348 | deref | <code>return *p;</code> | D |
| 416 | addr, deref, type | <code>if (const r = dg(key, *cast(Value*) &amp;values_[i]))</code> | H |
| 419 | addr, deref, type | <code>if (const r = dg(key, *cast(Value*) &amp;value))</code> | H |
| 489 | lookup | <code>assert((7 in map).name == "item h" &amp;&amp; 1000 !in map);</code> | B |
| 491 | addr, ptr | <code>assert(!inCollectedHeap(&amp;map[3]) &amp;&amp; !inCollectedHeap(map[3].name.ptr));</code> | H |
| 498 | lookup | <code>const before = 3 in map;</code> | A |
| 503 | lookup | <code>assert(map.remove(5) &amp;&amp; 5 !in map &amp;&amp; map.length == 1000 &amp;&amp; map[1000].name == "new");</code> | B |
| 508 | deref, lookup | <code>*(1 in plain) = 3;</code> | A |

### `source/dmangos/json.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 91 | lookup | <code>if (auto inner = key in json.object)</code> | A |
| 92 | deref | <code>unknown ~= unknownKeys!(typeof(T.tupleof[i]))(*inner, prefix ~ key ~ ".");</code> | D |
| 123 | lookup | <code>if (auto value = key in json.object)</code> | A |
| 124 | deref | <code>result.tupleof[i] = fromJson!(typeof(T.tupleof[i]))(*value);</code> | D |

### `source/dmangos/loadgen/main.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 80 | addr | <code>"world", "world server host:port", &amp;o.world,</code> | J |
| 81 | addr | <code>"login-db", "login database (host;port;user;password;database)", &amp;o.loginDb,</code> | J |
| 82 | addr | <code>"character-db", "characters database", &amp;o.characterDb,</code> | J |
| 83 | addr | <code>"world-db", "world database", &amp;o.worldDb,</code> | J |
| 84 | addr | <code>"mysql-library", "MySQL/MariaDB client library", &amp;o.mysqlLibrary,</code> | J |
| 85 | addr | <code>"bots", "number of clients", &amp;o.bots,</code> | J |
| 86 | addr | <code>"prefix", "account name prefix", &amp;o.prefix,</code> | J |
| 87 | addr | <code>"scenario", "crowd, spread, travel or idle", &amp;o.scenario,</code> | J |
| 89 | addr | <code>&amp;o.commands,</code> | J |
| 90 | addr | <code>"command-seconds", "seconds between those commands", &amp;o.commandSeconds,</code> | J |
| 91 | addr | <code>"trace", "print every packet the bots receive (with --bots 1, to see what a client is sent)", &amp;o.trace,</code> | J |
| 92 | addr | <code>"center", "crowd: map:x:y:z", &amp;o.center,</code> | J |
| 93 | addr | <code>"radius", "crowd: spread around the centre; wander: distance; travel: length", &amp;o.radius,</code> | J |
| 94 | addr | <code>"duration", "seconds measured", &amp;o.duration,</code> | J |
| 95 | addr | <code>"ramp", "logins started per second", &amp;o.ramp,</code> | J |
| 96 | addr | <code>"chat", "mean seconds between says per bot (0: none)", &amp;o.chatSeconds,</code> | J |
| 97 | addr | <code>"warmup", "seconds between the last login and the measurement", &amp;o.warmup,</code> | J |
| 98 | addr | <code>"seed", "random seed, for runs that place the bots the same (0: random)", &amp;o.seed,</code> | J |
| 99 | addr | <code>"server-pid", "world server process, for CPU and memory", &amp;o.serverPid,</code> | J |
| 100 | addr | <code>"server-log", "world server log, for its metrics lines", &amp;o.serverLog,</code> | J |
| 101 | addr | <code>"report", "file to append the report to", &amp;o.report);</code> | J |
| 165 | lookup | <code>if (accountIds[i] !in characterOf)</code> | B |
| 344 | ptr | <code>poll(fds.ptr, fds.length, 50);</code> | C |

### `source/dmangos/metrics.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 145 | type | <code>string report(TickStats* loop = null)</code> | P |

### `source/dmangos/mpq/archive.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 310 | return, type | <code>const(BlockEntry)* find(scope const(char)[] file) const</code> | R |
| 314 | type | <code>const(BlockEntry)* fallback;</code> | P |
| 325 | addr | <code>return &amp;blocks[entry.blockIndex];</code> | R |
| 327 | addr | <code>fallback = &amp;blocks[entry.blockIndex];</code> | P |

### `source/dmangos/mysql/binding.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 31 | type | <code>alias MYSQL_ROW = char**;</code> | C |
| 51 | abi mixin | <code>["mysql_init", "MYSQL* function(MYSQL*)"],</code> | C |
| 52 | abi mixin | <code>["mysql_options", "int function(MYSQL*, int, const(void)*)"],</code> | C |
| 53 | abi mixin | <code>["mysql_real_connect", "MYSQL* function(MYSQL*, const(char)*, const(char)*, const(char)*, const(char)*, uint, const(char)*, c_ulong)"],</code> | C |
| 54 | abi mixin | <code>["mysql_close", "void function(MYSQL*)"],</code> | C |
| 55 | abi mixin | <code>["mysql_errno", "uint function(MYSQL*)"],</code> | C |
| 56 | abi mixin | <code>["mysql_error", "const(char)* function(MYSQL*)"],</code> | C |
| 57 | abi mixin | <code>["mysql_real_escape_string", "c_ulong function(MYSQL*, char*, const(char)*, c_ulong)"],</code> | C |
| 58 | abi mixin | <code>["mysql_real_query", "int function(MYSQL*, const(char)*, c_ulong)"],</code> | C |
| 59 | abi mixin | <code>["mysql_store_result", "MYSQL_RES* function(MYSQL*)"],</code> | C |
| 60 | abi mixin | <code>["mysql_field_count", "uint function(MYSQL*)"],</code> | C |
| 61 | abi mixin | <code>["mysql_affected_rows", "ulong function(MYSQL*)"],</code> | C |
| 62 | abi mixin | <code>["mysql_insert_id", "ulong function(MYSQL*)"],</code> | C |
| 63 | abi mixin | <code>["mysql_num_fields", "uint function(MYSQL_RES*)"],</code> | C |
| 64 | abi mixin | <code>["mysql_fetch_row", "MYSQL_ROW function(MYSQL_RES*)"],</code> | C |
| 65 | abi mixin | <code>["mysql_fetch_lengths", "c_ulong* function(MYSQL_RES*)"],</code> | C |
| 66 | abi mixin | <code>["mysql_free_result", "void function(MYSQL_RES*)"],</code> | C |
| 67 | abi mixin | <code>["mysql_get_client_info", "const(char)* function()"],</code> | C |
| 111 | type | <code>void* handle;</code> | C |
| 149 | return, type | <code>private void* openLibrary(string name)</code> | C |
| 151 | cstr, type | <code>return cast(void*) LoadLibraryA(name.toStringz);</code> | C |
| 154 | return, type | <code>private void* findSymbol(void* library, string name)</code> | C |
| 158 | cstr, type | <code>return cast(void*) GetProcAddress(cast(HMODULE) library, name.toStringz);</code> | C |
| 165 | return, type | <code>private void* openLibrary(string name)</code> | C |
| 167 | cstr | <code>return dlopen(name.toStringz, RTLD_NOW);</code> | C |
| 170 | return, type | <code>private void* findSymbol(void* library, string name)</code> | C |
| 172 | cstr | <code>return dlsym(library, name.toStringz);</code> | C |

### `source/dmangos/mysql/connection.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 235 | type | <code>private MYSQL* handle;</code> | C |
| 355 | ptr | <code>const length = mysql.mysql_real_escape_string(handle, buffer.ptr, text.ptr, text.length);</code> | C |
| 398 | addr | <code>mysql.mysql_options(handle, MySqlOption.connectTimeout, &amp;connectTimeout);</code> | P |
| 399 | addr | <code>mysql.mysql_options(handle, MySqlOption.readTimeout, &amp;ioTimeout);</code> | P |
| 400 | addr | <code>mysql.mysql_options(handle, MySqlOption.writeTimeout, &amp;ioTimeout);</code> | P |
| 401 | ptr | <code>mysql.mysql_options(handle, MySqlOption.setCharsetName, "utf8".ptr);</code> | C |
| 404 | cstr | <code>info.host.length ? info.host.toStringz : null,</code> | C |
| 405 | cstr | <code>info.user.toStringz, info.password.toStringz, info.database.toStringz,</code> | C |
| 407 | cstr | <code>info.socket.length ? info.socket.toStringz : null, 0);</code> | C |
| 425 | ptr | <code>if (mysql.mysql_real_query(handle, text.ptr, text.length) == 0)</code> | C |
| 451 | native result | <code>auto result = mysql.mysql_store_result(handle);</code> | C |
| 460 | native result | <code>mysql.mysql_free_result(result);</code> | C |
| 466 | native result | <code>auto row = mysql.mysql_fetch_row(result);</code> | C |
| 469 | native result | <code>const lengths = mysql.mysql_fetch_lengths(result);</code> | C |
| 476 | native result | <code>if (row[column] is null)</code> | C |
| 479 | native result | <code>converted.values[column] = row[column][0 .. lengths[column]].idup;</code> | C |
| 539 | ptr, return, type | <code>MYSQL* fakeInit(MYSQL*) { return cast(MYSQL*) fakeHandle.ptr; }</code> | C |
| 540 | type | <code>int fakeOptions(MYSQL*, int, const(void)*) { return 0; }</code> | C |
| 541 | return, type | <code>MYSQL* fakeConnect(MYSQL* m, const(char)*, const(char)*, const(char)*, const(char)*, uint, const(char)*, c_ulong)</code> | C |
| 548 | type | <code>void fakeClose(MYSQL*) {}</code> | C |
| 549 | type | <code>uint fakeErrnoOf(MYSQL*) { return fakeErrno; }</code> | C |
| 550 | return, type | <code>const(char)* fakeError(MYSQL*) { return "fake"; }</code> | C |
| 551 | type | <code>c_ulong fakeEscape(MYSQL*, char* to, const(char)* from, c_ulong length)</code> | C |
| 556 | type | <code>int fakeQuery(MYSQL*, const(char)* text, c_ulong length)</code> | C |
| 569 | return, type | <code>MYSQL_RES* fakeStore(MYSQL*) { return null; }</code> | C |
| 570 | type | <code>uint fakeFieldCount(MYSQL*) { return 0; }</code> | C |
| 571 | type | <code>ulong fakeAffected(MYSQL*) { return 1; }</code> | C |
| 576 | addr | <code>mysql.mysql_init = cast(typeof(mysql.mysql_init)) &amp;fakeInit;</code> | C |
| 577 | addr | <code>mysql.mysql_options = cast(typeof(mysql.mysql_options)) &amp;fakeOptions;</code> | C |
| 578 | addr | <code>mysql.mysql_real_connect = cast(typeof(mysql.mysql_real_connect)) &amp;fakeConnect;</code> | C |
| 579 | addr | <code>mysql.mysql_close = cast(typeof(mysql.mysql_close)) &amp;fakeClose;</code> | C |
| 580 | addr | <code>mysql.mysql_errno = cast(typeof(mysql.mysql_errno)) &amp;fakeErrnoOf;</code> | C |
| 581 | addr | <code>mysql.mysql_error = cast(typeof(mysql.mysql_error)) &amp;fakeError;</code> | C |
| 582 | addr | <code>mysql.mysql_real_escape_string = cast(typeof(mysql.mysql_real_escape_string)) &amp;fakeEscape;</code> | C |
| 583 | addr | <code>mysql.mysql_real_query = cast(typeof(mysql.mysql_real_query)) &amp;fakeQuery;</code> | C |
| 584 | addr | <code>mysql.mysql_store_result = cast(typeof(mysql.mysql_store_result)) &amp;fakeStore;</code> | C |
| 585 | addr | <code>mysql.mysql_field_count = cast(typeof(mysql.mysql_field_count)) &amp;fakeFieldCount;</code> | C |
| 586 | addr | <code>mysql.mysql_affected_rows = cast(typeof(mysql.mysql_affected_rows)) &amp;fakeAffected;</code> | C |

### `source/dmangos/navigation.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 57 | type | <code>int dmnav_build_tile(const(BuildConfig)* config, const(float)* verts, int nverts, const(int)* tris,</code> | N |
| 58 | type | <code>const(ubyte)* areas, int ntris, ubyte** data, int* size);</code> | N |
| 59 | type | <code>void dmnav_free(void* p);</code> | N |
| 60 | return, type | <code>void* dmnav_mesh_create(const(float)* origin, float tileWidth, int maxTiles, int maxPolys);</code> | N |
| 61 | type | <code>void dmnav_mesh_free(void* mesh);</code> | N |
| 62 | type | <code>int dmnav_mesh_add_tile(void* mesh, const(ubyte)* data, int size);</code> | N |
| 63 | type | <code>void dmnav_mesh_remove_tile(void* mesh, int tileX, int tileY);</code> | N |
| 64 | return, type | <code>void* dmnav_query_create(void* mesh, int maxNodes);</code> | N |
| 65 | type | <code>void dmnav_query_free(void* query);</code> | N |
| 66 | type | <code>int dmnav_find_path(void* query, const(float)* start, const(float)* end, const(float)* extents,</code> | N |
| 67 | type | <code>ushort include, ushort exclude, float* points, int maxPoints, int* partial);</code> | N |
| 68 | type | <code>int dmnav_height(void* query, const(float)* point, const(float)* extents, ushort include, float* height);</code> | N |
| 120 | type | <code>ubyte* data;</code> | N |
| 122 | addr, ptr | <code>const result = dmnav_build_tile(&amp;config, verts.ptr, cast(int) vertices.length, triangles.ptr,</code> | N |
| 123 | addr, ptr, type | <code>cast(const(ubyte)*) areas.ptr, cast(int) areas.length, &amp;data, &amp;size);</code> | N |
| 129 | native owner | <code>dmnav_free(data);</code> | N |
| 130 | native owner | <code>return data[0 .. size].dup;</code> | N |
| 145 | type | <code>private void* mesh;</code> | N |
| 146 | type | <code>private void* query;</code> | N |
| 153 | ptr | <code>mesh = dmnav_mesh_create(origin.ptr, tileWidth, 64 * 64, 1 &lt;&lt; 20);</code> | N |
| 156 | native owner | <code>query = dmnav_query_create(mesh, maxNodes);</code> | N |
| 159 | native owner | <code>dmnav_mesh_free(mesh);</code> | N |
| 173 | native owner | <code>dmnav_query_free(query);</code> | N |
| 175 | native owner | <code>dmnav_mesh_free(mesh);</code> | N |
| 184 | lookup | <code>if (key in loaded)</code> | N |
| 186 | ptr | <code>if (dmnav_mesh_add_tile(mesh, data.ptr, cast(int) data.length) != 0)</code> | N |
| 195 | lookup | <code>return (cast(uint)(tileX &lt;&lt; 16 &#124; tileY) in loaded) !is null;</code> | N |
| 224 | addr, ptr | <code>const count = dmnav_find_path(query, s.ptr, e.ptr, ext.ptr, include, 0, corners.ptr, maxPoints, &amp;partial);</code> | N |
| 238 | addr, ptr | <code>return dmnav_height(query, p.ptr, ext.ptr, walkingFlags, &amp;z) != 0;</code> | N |

### `source/dmangos/net/server.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 94 | addr | <code>if (getrlimit(RLIMIT_NOFILE, &amp;limit) != 0)</code> | C |
| 99 | addr | <code>setrlimit(RLIMIT_NOFILE, &amp;limit);</code> | C |
| 100 | addr | <code>getrlimit(RLIMIT_NOFILE, &amp;limit);</code> | C |
| 124 | addr | <code>signal(SIGINT, &amp;onTerminate);</code> | C |
| 125 | addr | <code>signal(SIGTERM, &amp;onTerminate);</code> | C |
| 221 | type | <code>private static ulong keyOf(Connection c) { return cast(ulong) cast(void*) c; }</code> | NET |
| 301 | type | <code>auto connection = cast(Connection) cast(void*) event.key;</code> | NET |
| 626 | addr | <code>epoll_ctl(fd, EPOLL_CTL_DEL, socket, &amp;none);</code> | C |
| 634 | ptr | <code>const n = epoll_wait(fd, events.ptr, cast(int) events.length, ms);</code> | C |
| 652 | addr | <code>if (epoll_ctl(fd, op, socket, &amp;e) != 0)</code> | C |

### `source/dmangos/plaindata.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 67 | addr, deref, type | <code>encode(bytes, *cast(const(OriginalType!U)*) &amp;value);</code> | W |
| 69 | addr, type | <code>bytes ~= (cast(const(ubyte)*) &amp;value)[0 .. U.sizeof];</code> | W |
| 97 | addr, type | <code>auto target = cast(U*) &amp;value;</code> | Q |
| 99 | deref, type | <code>decode(bytes, *cast(OriginalType!U*) target);</code> | Q |
| 103 | type | <code>(cast(ubyte*) target)[0 .. U.sizeof] = bytes[0 .. U.sizeof];</code> | Q |
| 108 | deref | <code>foreach (ref element; *target)</code> | Q |
| 120 | deref | <code>*target = cast(U) elements;</code> | Q |

### `source/dmangos/script/registry.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 253 | return, type | <code>abstract void* at(uint slot, ushort generation);</code> | E |
| 305 | return, type | <code>override void* at(uint slot, ushort generation)</code> | E |
| 309 | addr | <code>return &amp;chunks[slot / chunkSize][slot % chunkSize];</code> | E |
| 328 | fn | <code>Pool function() makePool;</code> | F |
| 329 | type | <code>void*[maxEvents] handlers;</code> | E |
| 330 | fn, type | <code>void function(void* state, void* context, int ms) tick;</code> | E |
| 331 | fn, type | <code>bool function(const(void)* state) busy;</code> | E |
| 332 | fn, type | <code>void function(const(void)* state, ref ByteWriter w) save;</code> | E |
| 333 | fn, type | <code>bool function(void* state, ref ByteReader r) load;</code> | E |
| 410 | addr, type | <code>t.handlers[i] = cast(void*) &amp;dispatchEvent!(S, Ctx, E);</code> | E |
| 413 | addr | <code>t.tick = &amp;tickSchedules!(S, Ctx);</code> | E |
| 414 | type | <code>t.busy = (const(void)* p) {</code> | E |
| 415 | type | <code>const s = cast(const(S)*) p;</code> | E |
| 425 | deref, type | <code>t.save = (const(void)* p, ref ByteWriter w) =&gt; saveScript(*cast(const(S)*) p, w);</code> | E |
| 426 | deref, type | <code>t.load = (void* p, ref ByteReader r) =&gt; loadScript(*cast(S*) p, r);</code> | E |
| 430 | type | <code>private void dispatchEvent(S, Ctx, E)(void* state, ref Ctx context, const ref E event)</code> | E |
| 432 | type | <code>(cast(S*) state).on(context, event);</code> | E |
| 435 | type | <code>private void tickSchedules(S, Ctx)(void* state, void* context, int ms)</code> | ET |
| 437 | type | <code>auto s = cast(S*) state;</code> | E |
| 438 | type | <code>auto c = cast(Ctx*) context;</code> | ET |
| 440 | deref | <code>s.tupleof[i].advance(ms, (StepOf!(typeof(S.tupleof[i])) step) { s.on(*c, step); });</code> | D |
| 442 | deref | <code>s.tupleof[i].tick(*c, ms);</code> | D |
| 483 | lookup | <code>if (const name = id in spellsById)</code> | A |
| 484 | deref | <code>return *name;</code> | D |
| 518 | lookup | <code>assert(id !in runtime.spellsById, "two scripts serve a spell by id");</code> | B |
| 543 | lookup | <code>return (name in byName[kind]) !is null;</code> | A |
| 579 | addr | <code>const t = &amp;types[h.script - 1];</code> | P |
| 595 | addr | <code>const t = &amp;types[h.script - 1];</code> | P |
| 603 | dispatch | <code>if (t.kind != kind &#124;&#124; t.handlers[index] is null)</code> | E |
| 605 | dispatch | <code>auto state = pools[h.script - 1].at(h.slot, h.generation);</code> | E |
| 606 | dispatch | <code>if (state is null)</code> | E |
| 608 | dispatch, fn, type | <code>(cast(void function(void*, ref Ctx, const ref E)) t.handlers[index])(state, context, event);</code> | E |
| 618 | addr | <code>const t = &amp;types[h.script - 1];</code> | P |
| 621 | dispatch | <code>if (auto state = pools[h.script - 1].at(h.slot, h.generation))</code> | ET |
| 622 | addr | <code>t.tick(state, &amp;context, ms);</code> | ET |
| 630 | addr | <code>const t = &amp;types[h.script - 1];</code> | P |
| 631 | dispatch | <code>auto state = pools[h.script - 1].at(h.slot, h.generation);</code> | E |
| 638 | dispatch | <code>if (auto state = h ? pools[h.script - 1].at(h.slot, h.generation) : null)</code> | E |
| 645 | dispatch | <code>auto state = h ? pools[h.script - 1].at(h.slot, h.generation) : null;</code> | E |

### `source/dmangos/script/schedule.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 104 | addr | <code>auto e = &amp;entries[next];</code> | P |

### `source/dmangos/scripts/barrens.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 619 | lookup | <code>if ((c.entry == 9523 &#124;&#124; c.entry == 9524) &amp;&amp; c !in killed)</code> | B |

### `source/dmangos/scripts/kalimdortesting.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 181 | lookup | <code>if (found.length == 0 &#124;&#124; entry !in nearby)</code> | B |
| 369 | lookup | <code>if (found.length == 0 &#124;&#124; entry !in nearby)</code> | B |

### `source/dmangos/scripts/moltencore.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 1435 | lookup | <code>override bool hostAlive(EntityRef who) { return (who.guid in dead) is null; }</code> | B |

### `source/dmangos/scripts/npcs.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 284 | return, type | <code>private static immutable(Wounded)* which(uint entry)</code> | S |
| 288 | addr | <code>return &amp;w;</code> | S |

### `source/dmangos/scripts/professions.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 289 | return, type | <code>private static immutable(School)* schoolOf(uint entry)</code> | S |
| 294 | addr | <code>return &amp;schools[0];</code> | S |
| 296 | addr | <code>return &amp;schools[1];</code> | S |
| 298 | addr | <code>return &amp;schools[2];</code> | S |

### `source/dmangos/scripts/ruinsofahnqiraj.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 1403 | lookup | <code>override bool hostAlive(EntityRef who) { return (who.guid in dead) is null; }</code> | B |

### `source/dmangos/scripts/spells.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 29 | type | <code>const mana = cast(int)(amount * (it.affectingAuraTotal(e.caster, auraDummy) + 100) / 100);</code> | P |

### `source/dmangos/scripts/testing.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 279 | lookup | <code>bool hostAlive(EntityRef c) { return c &amp;&amp; c.guid !in dead; }</code> | R |
| 301 | lookup | <code>if (auto p = who.guid in places)</code> | A |
| 302 | deref | <code>at = *p;</code> | D |
| 324 | lookup | <code>bool hostHasAura(EntityRef c, uint) { return (c.guid in aurasOn) !is null; }</code> | B |

### `source/dmangos/scripts/wareffort.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 95 | lookup | <code>assert(h[2] == i &amp;&amp; h[0] !in seen &amp;&amp; h[1] !in seen);</code> | B |

### `source/dmangos/store.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 56 | return, type | <code>inout(T)* opIndex(Ref!T r) inout pure nothrow @nogc @trusted</code> | G |
| 58 | addr | <code>return r.slot &lt; items.length &amp;&amp; generations[r.slot] == r.generation ? &amp;items[r.slot] : null;</code> | G |
| 130 | deref | <code>return *v;</code> | D |
| 140 | return, type | <code>inout(T)* opIndex(uint slot) inout pure nothrow @nogc @trusted</code> | Y |
| 144 | addr | <code>return &amp;values[indexOf[slot] - 1];</code> | Y |
| 287 | deref | <code>assert(side[5] is null &amp;&amp; *side[9] == 90 &amp;&amp; *side[2] == 20 &amp;&amp; side.length == 2);</code> | D |

### `source/dmangos/vmap/bih.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 480 | addr | <code>tree.intersectRay(Ray(Vector3(-5, 0.5f, 0.5f), Vector3(1, 0, 0)), &amp;hitBox, maxDist, true);</code> | F |

### `source/dmangos/vmap/maptree.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 57 | lookup | <code>if (auto model = name in models)</code> | A |
| 58 | deref | <code>return *model;</code> | D |
| 59 | lookup | <code>if (name in failed)</code> | B |
| 102 | type | <code>const p = invRot * (ray.origin - spawn.pos) * invScale;</code> | P |
| 119 | type | <code>const pModel = invRot * (p - spawn.pos) * invScale;</code> | P |
| 132 | addr | <code>info.instance = &amp;this;</code> | M |
| 139 | type | <code>const pModel = invRot * (p - spawn.pos) * invScale;</code> | P |
| 155 | type | <code>const(ModelInstance)* instance;</code> | M |
| 225 | lookup | <code>if (key in loadedTiles)</code> | B |
| 282 | lookup | <code>return !tiled &#124;&#124; (packTileId(tileX, tileY) in loadedTiles) !is null;</code> | A |
| 314 | located instance | <code>if (values[entry].locate(p, best))</code> | M |
| 350 | lookup | <code>if (auto count = index in loadedSpawns)</code> | A |
| 352 | deref | <code>++*count;</code> | D |
| 390 | located instance | <code>return info.instance.liquidLevel(pos, info, level);</code> | M |

### `source/dmangos/world/alterac.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 286 | lookup | <code>if (copy.status != BattlegroundStatus.inProgress &#124;&#124; who !in copy.members)</code> | B |
| 336 | lookup | <code>if (auto m = killer in copy.members)</code> | A |
| 351 | deref | <code>if (event is null &#124;&#124; (*event)[0] &gt;= nodeCount)</code> | D |
| 353 | lookup | <code>auto m = who in copy.members;</code> | A |
| 357 | deref | <code>const n = (*event)[0];</code> | D |
| 358 | deref | <code>if ((*event)[1] % 2 == stateHeld)</code> | D |
| 367 | lookup | <code>auto m = who in copy.members;</code> | A |
| 442 | lookup | <code>if (auto m = killer in copy.members)</code> | A |
| 458 | addr | <code>auto node = &amp;nodes[n];</code> | P |
| 502 | addr | <code>auto node = &amp;nodes[n];</code> | P |
| 525 | addr | <code>auto node = &amp;nodes[n];</code> | P |
| 551 | addr | <code>auto node = &amp;nodes[n];</code> | P |
| 617 | lookup | <code>assert(3127 !in copy.worldStates &amp;&amp; 3128 !in copy.worldStates, "no reinforcements in 1.12");</code> | B |
| 634 | lookup | <code>return new GameObject(spawn, 178940 in context.data.gameObjectTemplates);</code> | A |
| 650 | lookup | <code>assert((eventMarshals + 4) !in copy.activeEvents, "its warmaster went");</code> | B |

### `source/dmangos/world/arathi.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 218 | deref | <code>if (event is null &#124;&#124; (*event)[0] &gt;= nodeCount)</code> | D |
| 220 | lookup | <code>auto m = who in copy.members;</code> | A |
| 224 | deref | <code>const n = (*event)[0], side = m.team;</code> | D |
| 293 | lookup | <code>auto m = who in copy.members;</code> | A |
| 396 | lookup | <code>auto banner = new GameObject(spawn, 180087 in context.data.gameObjectTemplates);</code> | A |

### `source/dmangos/world/auctionhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 32 | return, type | <code>const(AuctionHouseEntry)* auctionHouseOf(ulong auctioneer)</code> | R |
| 49 | type | <code>const(AuctionRecord)* auction = null)</code> | P |
| 110 | lookup | <code>const proto = item.entry in context.data.items;</code> | A |
| 113 | deref | <code>const deposit = Copper(auctionDeposit(*house, seconds, proto.details.sellPrice, item.count,</code> | D |
| 162 | addr | <code>return sendAuctionResult(a.id, AuctionAction.bidPlaced, AuctionError.higherBid, 0, &amp;a);</code> | R |
| 183 | addr | <code>return sendAuctionResult(id, AuctionAction.bidPlaced, AuctionError.higherBid, 0, &amp;now.get());</code> | R |
| 192 | addr | <code>sendAuctionResult(a.id, AuctionAction.bidPlaced, AuctionError.ok, 0, &amp;after);</code> | P |
| 214 | deref | <code>const cut = Copper(a.bid ? a.cut(*house, context.config.rateAuctionCut) : 0);</code> | D |
| 332 | lookup | <code>const proto = a.itemEntry in context.data.items;</code> | A |
| 408 | addr | <code>foreach (c; [&amp;anduin, &amp;jaina, &amp;varian])</code> | P |

### `source/dmangos/world/aurahandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 70 | type | <code>package void applyAuraEffect(const(SpellInfo)* spell, size_t i, ulong target, ubyte effects = 0)</code> | P |
| 94 | type | <code>private static bool partyAreaAura(const(SpellInfo)* spell)</code> | P |
| 103 | type | <code>private float areaAuraRadius(const(SpellInfo)* spell)</code> | P |
| 112 | deref | <code>return spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client));</code> | D |
| 182 | lookup | <code>if (key !in current)</code> | B |
| 406 | type | <code>package int diminishedDuration(const(SpellInfo)* spell, int ms)</code> | P |
| 411 | deref | <code>return diminishing.apply(drCategory(*spell), ms, context.clock(), level);</code> | D |
| 418 | deref | <code>diminishing.ended(imported!"dmangos.world.diminishing".drCategory(*aura.spell), context.clock());</code> | D |
| 516 | lookup | <code>const t = cast(uint) misc in context.data.creatureTemplates;</code> | A |
| 517 | deref | <code>aura.amount[i] = t is null ? pinkPig : cast(int) chooseDisplay(*t, map.random);</code> | D |
| 529 | lookup | <code>if (const t = cast(uint) aura.misc(i) in context.data.creatureTemplates)</code> | A |
| 802 | type | <code>package void interruptAurasOnCast(uint flag, const(SpellInfo)* spell)</code> | P |
| 944 | addr | <code>auto v = &amp;player.values;</code> | P |
| 1062 | deref | <code>*aura.spell);</code> | D |
| 1076 | addr | <code>auto v = &amp;player.values;</code> | P |
| 1163 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 1263 | lookup | <code>auto bonus = makeAura((devotion in context.data.spells.spells), me.guid, 60, -1, true, [30, 0, 0]);</code> | A |
| 1347 | lookup | <code>session.addAura(makeAura(shield in context.data.spells.spells, me.guid, 1, -1, true, [50, 0, 0]));</code> | A |
| 1355 | lookup | <code>session.addAura(makeAura(manaShield in context.data.spells.spells, me.guid, 1, -1, true, [100, 0, 0]));</code> | A |
| 1381 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |

### `source/dmangos/world/auras.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 70 | addr | <code>const c = &amp;spell.casting;</code> | P |
| 214 | type | <code>const(SpellInfo)* spell;</code> | P |
| 297 | deref | <code>&amp;&amp; !stacksAcrossCasters(*aura.spell, aura.positive, playerControlled(values));</code> | D |
| 345 | deref | <code>return stacksAcrossCasters(*aura.spell, aura.positive, playerControlled(values)) ? null : existing;</code> | D |
| 756 | type | <code>Aura makeAura(const(SpellInfo)* spell, ulong caster, uint casterLevel, int durationMs, bool positive,</code> | P |
| 815 | addr | <code>auto rend = set.apply(makeAura(&amp;dot, 1, 10, 9000, false, [5, 0, 0]), values, isNew);</code> | P |
| 816 | addr | <code>auto intellect = set.apply(makeAura(&amp;buff, 1, 10, 60_000, true, [2, 0, 0]), values, isNew);</code> | P |
| 835 | addr | <code>set.apply(makeAura(&amp;buff, 1, 10, 60_000, true, [2, 0, 0]), values, isNew);</code> | P |
| 860 | addr | <code>target.apply(makeAura(&amp;spells[0], 1, 60, 60_000, true, [300, 0, 0]), hidden, isNew);</code> | P |
| 861 | addr | <code>viewer.apply(makeAura(&amp;spells[1], 2, 60, 60_000, true, [100, 0, 0]), seeing, isNew);</code> | P |
| 862 | addr | <code>viewer.apply(makeAura(&amp;spells[2], 2, 60, 60_000, true, [200, 0, 0]), seeing, isNew);</code> | P |
| 873 | addr | <code>viewer.apply(makeAura(&amp;spells[3], 2, 60, 60_000, true, [300, 0, 0]), seeing, isNew);</code> | P |
| 895 | addr | <code>set.apply(makeAura(&amp;axes, 1, 10, -1, true, [5, 0, 0]), values, isNew);</code> | P |
| 896 | addr | <code>set.apply(makeAura(&amp;any, 1, 10, -1, true, [1, 0, 0]), values, isNew);</code> | P |
| 931 | addr | <code>set.apply(makeAura(&amp;defiance, 1, 10, -1, true, [15, 0, 0]), values, isNew);</code> | P |
| 932 | addr | <code>set.apply(makeAura(&amp;stance, 1, 10, -1, true, [-10, 10, 0]), values, isNew);</code> | P |
| 933 | addr | <code>set.apply(makeAura(&amp;twoHanded, 1, 10, -1, true, [5, 0, 0]), values, isNew);</code> | P |
| 962 | addr | <code>set.apply(makeAura(&amp;sliceAndDice, 1, 10, 9000, true, [20, 0, 0]), values, isNew);</code> | P |
| 965 | addr | <code>set.apply(makeAura(&amp;thunderClap, 2, 10, 10_000, false, [-10, 0, 0]), values, isNew);</code> | P |
| 968 | addr | <code>set.apply(makeAura(&amp;rapidFire, 1, 10, 15_000, true, [40, 0, 0]), values, isNew);</code> | P |
| 986 | addr | <code>set.apply(makeAura(&amp;tongues, 1, 10, 30_000, false, [-50, 0, 0]), values, isNew);</code> | P |
| 1002 | addr | <code>auto aura = set.apply(makeAura(&amp;root, 1, 10, 8000, false, [0, 0, 0]), values, isNew);</code> | P |
| 1055 | addr | <code>auto first = set.apply(makeAura(&amp;sunder, 1, 60, 30_000, false, [-450, 0, 0]), values, isNew);</code> | P |
| 1056 | addr | <code>set.apply(makeAura(&amp;sunder, 1, 60, 30_000, false, [-450, 0, 0]), values, isNew);</code> | P |
| 1057 | addr | <code>auto shared_ = set.apply(makeAura(&amp;sunder, 2, 60, 30_000, false, [-450, 0, 0]), values, isNew);</code> | P |
| 1061 | addr | <code>set.apply(makeAura(&amp;corruption, 1, 60, 18_000, false, [100, 0, 0]), values, isNew);</code> | P |
| 1062 | addr | <code>set.apply(makeAura(&amp;corruption, 2, 60, 18_000, false, [100, 0, 0]), values, isNew);</code> | P |
| 1065 | addr | <code>auto one = makeAura(&amp;fortitude, 1, 60, 1_800_000, true, [54, 0, 0]);</code> | P |
| 1067 | addr | <code>auto other = makeAura(&amp;fortitude, 2, 60, 1_800_000, true, [54, 0, 0]);</code> | P |
| 1069 | addr | <code>assert(set.displacedBy(makeAura(&amp;corruption, 3, 60, 18_000, false, [100, 0, 0]), values) is null);</code> | P |

### `source/dmangos/world/battleground.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 244 | return, type | <code>@property const(BattlegroundTemplate)* template_() const</code> | R |
| 246 | lookup | <code>return cast(ubyte) type in context.data.battlegroundTemplates;</code> | A |
| 257 | lookup | <code>if (auto known = guid in members)</code> | A |
| 279 | lookup | <code>auto m = guid in members;</code> | A |
| 302 | lookup | <code>if (auto m = guid in members)</code> | A |
| 452 | deref | <code>bracket = cast(ubyte)((t.minLevel + 10 * (level ? bracketOf(*t, level) : 0)) / 10);</code> | D |
| 486 | lookup | <code>if (auto v = victim in members)</code> | A |
| 488 | lookup | <code>if (auto k = killer in members)</code> | A |
| 537 | deref | <code>const honor = bonusHonor(units, *t, c.player.data.level);</code> | D |
| 590 | lookup | <code>if (auto m = guid in members)</code> | A |
| 632 | lookup | <code>if (auto m = guid in members)</code> | A |
| 671 | lookup | <code>if (const text = id in context.data.serverStrings)</code> | A |
| 675 | deref | <code>w.putCString(*text);</code> | D |
| 743 | lookup | <code>const t = entry in context.data.gameObjectTemplates;</code> | A |
| 756 | return, type | <code>const(ubyte[2])* eventOf(GameObject go)</code> | R |
| 758 | lookup | <code>return go.spawn.guid in context.data.gameObjectBattleEvents;</code> | A |
| 777 | type | <code>bool spawnAllowed(const(ubyte[2])* event) const</code> | P |
| 779 | deref | <code>return event is null &#124;&#124; activeEvents.get((*event)[0], eventNone) == (*event)[1];</code> | D |
| 824 | lookup | <code>if (const e = go.spawn.guid in context.data.gameObjectBattleEvents)</code> | A |
| 825 | deref | <code>if ((*e)[0] == eventDoors)</code> | D |
| 840 | lookup | <code>if (auto known = id in worldStates)</code> | A |
| 841 | deref | <code>if (*known == value)</code> | D |
| 857 | lookup | <code>const text = id in context.data.serverStrings;</code> | A |
| 860 | deref | <code>toAll(Opcode.SMSG_MESSAGECHAT, battlegroundMessage(chatType, formatServerString(*text, args), source));</code> | D |
| 900 | lookup | <code>auto m = sender in members;</code> | A |
| 912 | lookup | <code>if (auto m = guid in members)</code> | A |
| 969 | type | <code>const(ubyte[2])* e;</code> | P |
| 971 | lookup | <code>e = c.spawnId in context.data.creatureBattleEvents;</code> | A |
| 973 | lookup | <code>e = go.spawn.guid in context.data.gameObjectBattleEvents;</code> | A |
| 974 | deref | <code>if (e !is null &amp;&amp; *e == pair)</code> | D |
| 1001 | lookup | <code>if (o.guid !in present &amp;&amp; map.cellLoaded(cellKeyAt(o.position.x, o.position.y)))</code> | B |
| 1161 | lookup | <code>if (auto known = instance in copies)</code> | A |
| 1162 | deref | <code>return *known;</code> | D |
| 1200 | addr | <code>if (auto c = context.makeCreature(&amp;context.data.creatureSpawns[index]))</code> | CS |
| 1207 | addr | <code>auto go = context.makeGameObject(&amp;context.data.gameObjectSpawns[index]);</code> | GO |
| 1232 | lookup | <code>if (const e = spawn.guid in context.data.creatureBattleEvents)</code> | A |
| 1233 | deref | <code>eventCreatures[eventKey(spawn.map, *e)] ~= i;</code> | D |
| 1235 | lookup | <code>if (const e = spawn.guid in context.data.gameObjectBattleEvents)</code> | A |
| 1236 | deref | <code>eventObjects[eventKey(spawn.map, *e)] ~= i;</code> | D |
| 1334 | lookup | <code>const t = type in context.data.battlegroundTemplates;</code> | A |
| 1337 | deref | <code>if (levelAllowed(*t, player.data.level))</code> | D |
| 1340 | lookup | <code>if (const text = stringLevelRequirement in context.data.serverStrings)</code> | A |
| 1341 | deref | <code>send(ServerNotification(*text));</code> | D |
| 1396 | lookup | <code>const t = e.type in context.data.battlegroundTemplates;</code> | A |
| 1399 | lookup | <code>const start = t.startLocations[e.team] in context.data.safeLocations;</code> | A |
| 1466 | lookup | <code>if (context.groups.of(player.guid) !is null &#124;&#124; player.guid in copy.inTeamRaid)</code> | A |
| 1470 | lookup | <code>auto leader = leaderGuid &amp;&amp; leaderGuid != player.guid &amp;&amp; leaderGuid in copy.members</code> | A |
| 1487 | lookup | <code>if (player.guid !in copy.inTeamRaid)</code> | B |
| 1496 | lookup | <code>if (m.guid != player.guid &amp;&amp; m.guid in copy.inTeamRaid)</code> | A |
| 1516 | lookup | <code>if (copy !is null &amp;&amp; player.guid in copy.members &amp;&amp; copy.status != BattlegroundStatus.waitLeave)</code> | A |
| 1658 | lookup | <code>const t = type in context.data.battlegroundTemplates;</code> | A |
| 1662 | lookup | <code>if (const text = stringId in context.data.serverStrings)</code> | A |
| 1663 | deref | <code>deliver(Opcode.SMSG_MESSAGECHAT, battlegroundMessage(ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL, *text));</code> | D |
| 1668 | deref | <code>const myBracket = bracketOf(*t, player.data.level);</code> | D |
| 1695 | deref | <code>if (bracketOf(*t, level) != myBracket)</code> | D |
| 1753 | lookup | <code>if (type == BattlegroundType.none &#124;&#124; type !in context.data.battlegroundTemplates)</code> | B |
| 1883 | lookup | <code>assert(copy.type == BattlegroundType.warsongGulch &amp;&amp; 7 in copy.members &amp;&amp; copy.members[7].team == 0);</code> | A |
| 1913 | lookup | <code>assert(copy.members.length == 0 &amp;&amp; queue.ticketsOf(7) is null &amp;&amp; 7 !in db.battlegroundRows);</code> | B |
| 1970 | lookup | <code>assert(7 !in db.battlegroundRows);</code> | B |
| 1978 | type | <code>private Battleground enterWarsong(WorldContext context, TestClient*[] players, const(uint)[] guids,</code> | P |
| 2032 | addr | <code>auto copy = enterWarsong(context, [&amp;anduin, &amp;varian, &amp;thrall], [7, 9, 8], [0, 0, 1]);</code> | P |
| 2146 | addr | <code>auto copy = enterWarsong(context, [&amp;anduin], [7], [0]);</code> | P |
| 2188 | addr | <code>auto copy = enterWarsong(context, [&amp;anduin], [7], [0]);</code> | P |
| 2205 | lookup | <code>assert(timeSent &amp;&amp; 7 in copy.awaitingResurrection, "queued, and told when");</code> | A |
| 2216 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 2290 | addr | <code>auto copy = enterWarsong(context, [&amp;anduin, &amp;varian, &amp;thrall], [7, 9, 8], [0, 0, 1]);</code> | P |

### `source/dmangos/world/bgqueue.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 349 | lookup | <code>if (auto t = guid in tickets)</code> | A |
| 350 | deref | <code>return (*t)[];</code> | D |
| 361 | lookup | <code>const t = type in templates;</code> | A |
| 367 | addr, deref | <code>foreach (i, ref s; *(&amp;tickets[guid]))</code> | Z |
| 380 | deref | <code>g.bracket = bracketOf(*t, level);</code> | D |
| 405 | lookup | <code>const t = type in templates;</code> | A |
| 412 | lookup | <code>if (auto mine = p in tickets)</code> | A |
| 415 | deref | <code>foreach (ref s; *mine)</code> | D |
| 425 | deref | <code>g.bracket = bracketOf(*t, level);</code> | D |
| 466 | addr | <code>auto ticket = &amp;tickets[guid][slot];</code> | P |
| 477 | lookup | <code>auto copy = ticket.instance in running;</code> | A |
| 486 | deref | <code>*ticket = Ticket(type, Stage.inside, copy.instance, null);</code> | D |
| 496 | lookup | <code>auto mine = guid in tickets;</code> | A |
| 500 | deref | <code>foreach (i, ref t; *mine)</code> | D |
| 516 | lookup | <code>if (auto copy = t.instance in running)</code> | A |
| 527 | lookup | <code>auto mine = guid in tickets;</code> | A |
| 530 | deref | <code>foreach (i, ref t; *mine)</code> | D |
| 539 | lookup | <code>const t = type in templates;</code> | A |
| 543 | deref | <code>const bracket = bracketOf(*t, level);</code> | D |
| 567 | lookup | <code>auto copy = instance in running;</code> | A |
| 570 | lookup | <code>if (auto mine = guid in tickets)</code> | A |
| 571 | deref | <code>foreach (i, ref t; *mine)</code> | D |
| 585 | lookup | <code>auto copy = instance in running;</code> | A |
| 599 | lookup | <code>if (auto copy = instance in running)</code> | A |
| 672 | lookup | <code>if (auto mine = guid in tickets)</code> | A |
| 673 | deref | <code>foreach (i, ref t; *mine)</code> | D |
| 681 | lookup | <code>if (auto copy = instance in running)</code> | A |
| 693 | lookup | <code>if (auto mine = guid in tickets)</code> | A |
| 695 | deref | <code>foreach (ref t; *mine)</code> | D |
| 706 | addr | <code>auto ticket = &amp;tickets[guid][slot];</code> | P |
| 712 | lookup | <code>if (auto copy = g.invitedTo in running)</code> | A |
| 734 | addr | <code>auto list = &amp;waiting[g.type][g.bracket][g.team];</code> | P |
| 735 | deref | <code>const j = (*list).countUntil!(x =&gt; x is g);</code> | D |
| 737 | deref | <code>*list = (*list).remove(j);</code> | D |
| 761 | addr | <code>auto next = &amp;waitNext[g.type][g.team][g.bracket];</code> | P |
| 762 | deref | <code>waitTimes[g.type][g.team][g.bracket][*next] = cast(uint)(now - g.joined).total!"msecs";</code> | D |
| 763 | deref | <code>*next = (*next + 1) % waitSamples;</code> | D |
| 779 | lookup | <code>const t = type in templates;</code> | A |
| 782 | addr | <code>auto lists = &amp;waiting[type][bracket];</code> | P |
| 786 | addr | <code>auto copy = &amp;running[instance];</code> | P |
| 792 | deref | <code>foreach (g; (*lists)[team])</code> | D |
| 798 | deref | <code>invite(g, *copy);</code> | D |
| 808 | deref | <code>foreach (g; (*lists)[team])</code> | D |
| 850 | lookup | <code>while (id in taken)</code> | A |

### `source/dmangos/world/caster.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 106 | return, type | <code>@property UpdateValues* fields()</code> | R |
| 111 | addr | <code>case UnitKind.player: return &amp;character.player.values;</code> | R |
| 112 | addr | <code>case UnitKind.creature: return &amp;creature.values;</code> | R |
| 117 | return, type | <code>@property AuraSet* auras()</code> | R |
| 122 | addr | <code>case UnitKind.player: return &amp;character.player.auras;</code> | R |
| 123 | addr | <code>case UnitKind.creature: return &amp;creature.auras;</code> | R |
| 191 | type | <code>void castTriggered(const(SpellInfo)* spell, ulong target)</code> | P |
| 215 | type | <code>T spellMod(T)(imported!"dmangos.world.spellmods".SpellModOp op, const(SpellInfo)* spell, T value)</code> | P |
| 289 | type | <code>float spellCritChance(const(SpellInfo)* spell)</code> | P |
| 309 | type | <code>float critChance(const(SpellInfo)* spell, UnitRef victim)</code> | P |
| 329 | type | <code>static bool weaponCrit(const(SpellInfo)* spell) pure nothrow @nogc @safe</code> | P |
| 338 | type | <code>uint critDamage(const(SpellInfo)* spell, uint damage)</code> | P |
| 358 | type | <code>float hitBonus(const(SpellInfo)* spell)</code> | P |
| 391 | type | <code>void damageDealt(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage, bool periodic)</code> | P |
| 415 | type | <code>int effectAmount(const(SpellInfo)* spell, size_t i)</code> | P |
| 427 | type | <code>int modDuration(const(SpellInfo)* spell, int ms)</code> | P |

### `source/dmangos/world/channel.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 161 | type | <code>const(ChatChannelsEntry)* entry;</code> | P |
| 171 | type | <code>private this(Channels owner, string name, const(ChatChannelsEntry)* entry)</code> | P |
| 200 | return, type | <code>@property const(ChatChannelsEntry)* channelEntry() const</code> | R |
| 214 | lookup | <code>return (guid in players) !is null;</code> | A |
| 239 | lookup | <code>if (guid in bannedGuids)</code> | B |
| 288 | lookup | <code>if (ban &amp;&amp; targetGuid !in bannedGuids)</code> | B |
| 310 | lookup | <code>if (targetGuid !in bannedGuids)</code> | B |
| 452 | lookup | <code>if (targetGuid in bannedGuids)</code> | B |
| 515 | lookup | <code>auto current = guid in players;</code> | A |
| 516 | deref | <code>if (current is null &#124;&#124; ((*current &amp; flag) != 0) == set)</code> | D |
| 518 | deref | <code>const old = *current;</code> | D |
| 519 | deref | <code>*current = cast(MemberFlags)(set ? old &#124; flag : old &amp; ~flag);</code> | D |
| 520 | deref | <code>sendToAll(notice(ChatNotify.modeChange, name, guid, cast(ubyte) old, cast(ubyte) *current));</code> | D |
| 527 | lookup | <code>if (auto previous = ownerGuid in players)</code> | A |
| 529 | deref | <code>const old = *previous;</code> | D |
| 530 | deref | <code>*previous = cast(MemberFlags)((guid ? old &#124; MemberFlags.moderator : old &amp; ~MemberFlags.moderator)</code> | D |
| 532 | deref | <code>sendToAll(notice(ChatNotify.modeChange, name, ownerGuid, cast(ubyte) old, cast(ubyte) *previous));</code> | D |
| 581 | lookup | <code>if (auto found = key in byName)</code> | A |
| 582 | deref | <code>return *found;</code> | D |
| 591 | lookup | <code>if (auto found = keyOf(name) in byName)</code> | A |
| 592 | deref | <code>return *found;</code> | D |
| 614 | lookup | <code>if (auto found = key in byName)</code> | A |
| 676 | lookup | <code>if (auto list = guid in joinedBy)</code> | A |
| 678 | deref | <code>*list = (*list).remove!(c =&gt; c is channel);</code> | D |

### `source/dmangos/world/channelservice.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 185 | lookup | <code>if (auto known = guid in members)</code> | A |
| 186 | deref | <code>return *known;</code> | D |
| 210 | lookup | <code>if (auto known = c.guid in members)</code> | A |
| 213 | deref | <code>return *known;</code> | D |

### `source/dmangos/world/character.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 619 | deref | <code>if (generic.active &amp;&amp; isInterruptible(*generic.spell))</code> | D |
| 625 | deref | <code>if (channelSpell !is null &amp;&amp; isInterruptible(*channelSpell))</code> | D |
| 990 | addr | <code>const v = &amp;orc.player.values;</code> | P |
| 1346 | lookup | <code>anduin.session.inWorld.addAura(makeAura(soulstone in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));</code> | A |
| 1414 | lookup | <code>const t = bobberEntry in w.context.data.gameObjectTemplates;</code> | A |
| 1483 | addr | <code>raceHuman, 0, 1, &amp;setup);</code> | F |

### `source/dmangos/world/characterdb.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 1504 | lookup | <code>if (auto at = row.get!uint(0) in position)</code> | A |
| 1505 | deref | <code>groups[*at].members ~= member;</code> | D |

### `source/dmangos/world/characters.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 86 | lookup | <code>if (auto family = record.petEntry in data.creatureFamilies)</code> | A |
| 90 | deref | <code>entry.petFamily = *family;</code> | D |
| 96 | lookup | <code>if (auto display = items[slot] in data.items)</code> | A |

### `source/dmangos/world/charscreen.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 112 | lookup | <code>if (isPlayer &amp;&amp; (toLowerName(name) in context.data.reservedNames) !is null)</code> | A |
| 143 | addr | <code>&amp;context.nextItemGuid);</code> | F |
| 194 | lookup | <code>if (account.level == AccountLevel.player &amp;&amp; (toLowerName(name) in context.data.reservedNames) !is null)</code> | A |
| 221 | addr | <code>context.database.deleteCharacter(guid, account.id, context.deleteOptions, &amp;context.nextMailId);</code> | F |
| 378 | addr | <code>&amp;context.nextItemGuid);</code> | F |
| 381 | addr | <code>auto made = new Player(character, abilities, context.data, context.client, &amp;context.nextItemGuid);</code> | F |
| 396 | addr | <code>const c = &amp;player.data;</code> | P |
| 442 | addr | <code>const c = &amp;player.data;</code> | P |

### `source/dmangos/world/classspells.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 68 | type | <code>const(SpellInfo)* by;</code> | P |
| 84 | type | <code>bool ofFamily(const(SpellInfo)* spell, SpellFamily family, ulong mask = 0) pure nothrow @nogc @safe</code> | P |
| 90 | type | <code>bool isSeal(const(SpellInfo)* spell) pure nothrow @nogc @safe</code> | P |
| 112 | type | <code>ExclusiveKind exclusiveKind(const(SpellInfo)* spell) pure nothrow @safe</code> | P |
| 163 | type | <code>float levelPenalty(const(SpellInfo)* spell) pure nothrow @nogc @safe</code> | P |
| 355 | type | <code>package SpellCastResult castCustom(const(SpellInfo)* spell, SpellTargets targets, CustomValues custom)</code> | P |
| 377 | return, type | <code>private AuraSet* aurasOf(UnitRef unit)</code> | R |
| 384 | addr | <code>return unit.session.player is null ? null : &amp;unit.session.player.auras;</code> | R |
| 386 | addr | <code>return &amp;unit.creature.auras;</code> | R |
| 440 | type | <code>private static size_t effectOfAura(const(SpellInfo)* spell, AuraType type)</code> | P |
| 469 | type | <code>package SpellCastResult classCastCheck(const(SpellInfo)* spell, const ref SpellTargets targets)</code> | P |
| 525 | type | <code>package int classSchoolDamage(const(SpellInfo)* spell, size_t i, ulong targetGuid, int damage)</code> | P |
| 569 | type | <code>package bool classDummyEffect(const(SpellInfo)* spell, size_t i, ulong targetGuid, int value, uint castItemEntry)</code> | P |
| 624 | deref | <code>enterCombatFor(duration(*spell, context.client, player.data.level).msecs);</code> | D |
| 640 | type | <code>private bool paladinDummy(const(SpellInfo)* spell, size_t i, UnitRef target, int value)</code> | P |
| 701 | type | <code>private bool flametongue(const(SpellInfo)* spell, UnitRef target, int value)</code> | P |
| 813 | type | <code>package const(SpellInfo)* castingFor;</code> | P |
| 849 | type | <code>package void classAfterEffects(const(SpellInfo)* spell, const(ulong)[] hit, const(ulong)[] dodgedBy)</code> | P |
| 894 | type | <code>package void targetTriggers(const(SpellInfo)* spell, const(ulong)[] hit, UnitRef remote = UnitRef.init)</code> | P |
| 903 | deref | <code>&#124;&#124; !affects(aura, k, *spell))</code> | D |
| 936 | type | <code>package int classEffectMod(const(SpellInfo)* spell, size_t i, int value)</code> | P |
| 950 | deref | <code>if ((aura.effects &amp; (1 &lt;&lt; k)) &amp;&amp; aura.misc(k) == SpellModOp.effect2 &amp;&amp; affects(aura, k, *spell))</code> | D |
| 967 | deref | <code>if ((aura.effects &amp; (1 &lt;&lt; k)) &amp;&amp; aura.misc(k) == attackSpeedOp &amp;&amp; affects(aura, k, *spell))</code> | D |
| 976 | type | <code>package void classAuraValues(const(SpellInfo)* spell, ref int[3] values)</code> | P |
| 985 | type | <code>values[i] += player.stats.attackPower * (castCombo &gt; 4 ? 4 : castCombo) / 100;</code> | P |
| 987 | type | <code>values[i] += player.stats.attackPower * (castCombo &gt; 3 ? 3 : castCombo) / 100;</code> | P |
| 1054 | lookup | <code>if (const node = id in context.data.spells.chains)</code> | A |
| 1070 | type | <code>package float classWeaponBonusFactor(const(SpellInfo)* spell)</code> | P |
| 1080 | type | <code>package int classHeal(const(SpellInfo)* spell, UnitRef target, int value)</code> | P |
| 1099 | deref | <code>const ticks = period ? duration(*shortest.spell, context.client, shortest.casterLevel) / period : 0;</code> | D |
| 1119 | deref | <code>value += cast(int)(aura.amount[which] * bonusCoefficient(*spell, 0, context.client, player.data.level));</code> | D |
| 1123 | type | <code>value = value * (aura.amount[0] * cast(int) aura.stacks + 100) / 100;</code> | P |
| 1134 | type | <code>package void classHealed(const(SpellInfo)* spell, UnitRef target)</code> | P |
| 1154 | type | <code>package void classAreaTick(const(SpellInfo)* spell, UnitRef target)</code> | P |
| 1177 | type | <code>package bool reflectsSpell(const(SpellInfo)* spell)</code> | P |
| 1195 | type | <code>private int wardTalentChance(const(SpellInfo)* ward)</code> | P |
| 1208 | deref | <code>chance = effectValue(*talent, i, player.data.level, 0);</code> | D |
| 1213 | type | <code>package void reflectBack(const(SpellInfo)* spell, ulong caster)</code> | P |
| 1219 | type | <code>package void spellResistedBy(const(SpellInfo)* spell, UnitRef caster)</code> | P |
| 1273 | type | <code>package void summonPossessedEffect(const(SpellInfo)* spell, size_t i)</code> | P |
| 1280 | deref | <code>const ms = modDuration(spell, duration(*spell, context.client, player.data.level));</code> | D |
| 1329 | type | <code>private bool createHealthstone(const(SpellInfo)* spell)</code> | P |
| 1353 | type | <code>private void pyroclasm(const(SpellInfo)* spell, ulong target)</code> | P |
| 1362 | type | <code>const(SpellInfo)* periodic = ofFamily(spell, SpellFamily.warlock, 0x20) ? spell</code> | P |
| 1363 | deref | <code>: castTime(*spell, context.client, player.data.level) == 0 ? context.data.spells.spell(hellfire) : null;</code> | D |
| 1368 | deref | <code>ticks = duration(*periodic, context.client, player.data.level) / periodic.casting.amplitude[i];</code> | D |
| 1426 | type | <code>package float classCritBonus(const(SpellInfo)* spell, UnitRef target)</code> | P |
| 1431 | type | <code>package float frozenTargetCritBonus(const(SpellInfo)* spell)</code> | P |
| 1465 | type | <code>package const(SpellInfo)* procAuraSpell;</code> | P |
| 1499 | deref | <code>: duration(*bleed, context.client, player.data.level) / bleed.casting.amplitude[0];</code> | D |
| 1547 | return, type | <code>private const(SpellInfo)* illuminatedSpell(const(SpellInfo)* heal)</code> | R |
| 1719 | type | <code>private int sealOfRighteousnessAmount(int amount, const(SpellInfo)* seal)</code> | P |
| 1820 | type | <code>package void spellCastScript(const(SpellInfo)* spell, ulong target)</code> | P |
| 1828 | type | <code>package void spellLandedScript(const(SpellInfo)* spell, ulong target, bool missed)</code> | P |
| 1874 | lookup | <code>const node = id in context.data.spells.chains;</code> | A |
| 1894 | type | <code>package int affectingAuraTotal(EntityRef who, const(SpellInfo)* spell, ubyte auraType)</code> | P |
| 1903 | deref | <code>if ((aura.effects &amp; (1 &lt;&lt; k)) &amp;&amp; aura.type(k) == auraType &amp;&amp; affects(aura, k, *spell))</code> | D |

### `source/dmangos/world/classspelltests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 57 | addr, deref, type | <code>static uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 99 | return, type | <code>SpellInfo* spell(uint id, SpellEffect effect, ImplicitTarget target, int value = 1)</code> | R |
| 114 | type | <code>void auraEffect(SpellInfo* s, size_t i, AuraType type, ImplicitTarget target, int value = 0, int misc = 0)</code> | P |
| 127 | lookup | <code>return me.castSpell(id in context.data.spells.spells, target ? SpellTargets(TargetFlags.unit, target)</code> | A |

### `source/dmangos/world/clientdata.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 730 | type | <code>const(TaxiPathNodeEntry)*[][uint] taxiPathPoints;</code> | P |
| 745 | type | <code>const(CharSectionsEntry)*[][uint] sectionsByKey;</code> | P |
| 746 | type | <code>const(CharacterFacialHairStylesEntry)*[uint] facialHairByKey;</code> | P |
| 747 | type | <code>const(SkillRaceClassInfoEntry)*[][uint] raceClassInfoBySkill;</code> | P |
| 748 | type | <code>const(SkillLineAbilityEntry)*[][uint] abilitiesBySpell;</code> | P |
| 749 | type | <code>const(SkillLineAbilityEntry)*[][uint] abilitiesBySkill;</code> | P |
| 751 | type | <code>const(AreaTableEntry)*[][uint] areasByFlag;</code> | P |
| 753 | type | <code>const(WmoAreaTableEntry)*[][int[3]] wmoAreasByTriple;</code> | P |
| 807 | lookup | <code>if (spell !in spellCoefficients)</code> | B |
| 876 | lookup | <code>const interval = mapId in instanceResets;</code> | A |
| 877 | deref | <code>known = interval !is null &amp;&amp; *interval &lt; days.length;</code> | D |
| 878 | deref | <code>return known ? days[*interval] : 0;</code> | D |
| 898 | addr | <code>taxiPathPoints[row.path] ~= &amp;row;</code> | P |
| 962 | return, type | <code>const(AreaTableEntry)* areaByFlag(uint flag, uint map) const</code> | R |
| 964 | type | <code>const(AreaTableEntry)* found;</code> | P |
| 980 | type | <code>const(WmoAreaTableEntry*)[] wmoAreasOf(int rootId, int adtId, int groupId) const</code> | P |
| 992 | return, type | <code>const(CharSectionsEntry)* charSection(ubyte race, CharSectionType type, ubyte gender, ubyte variation,</code> | R |
| 1003 | return, type | <code>const(CharacterFacialHairStylesEntry)* facialHair(ubyte race, ubyte gender, ubyte facialHairId) const</code> | R |
| 1005 | lookup | <code>if (auto entry = (race &#124; gender &lt;&lt; 8 &#124; facialHairId &lt;&lt; 16) in facialHairByKey)</code> | A |
| 1006 | deref | <code>return *entry;</code> | D |
| 1011 | type | <code>const(SkillRaceClassInfoEntry*)[] raceClassInfo(uint skillId) const</code> | P |
| 1017 | type | <code>const(SkillLineAbilityEntry*)[] abilitiesForSpell(uint spellId) const</code> | P |
| 1023 | type | <code>const(SkillLineAbilityEntry*)[] abilitiesForSkill(uint skillId) const</code> | P |
| 1054 | return, type | <code>const(TalentSpellPos)* talentSpellPos(uint spellId) const</code> | R |
| 1056 | lookup | <code>return spellId in talentSpellPositions;</code> | R |
| 1063 | return, type | <code>const(ChatChannelsEntry)* chatChannelFor(string name) const</code> | R |
| 1079 | addr | <code>return &amp;entry;</code> | R |

### `source/dmangos/world/clusterbridge.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 236 | lookup | <code>if (auto then = m.request in stockWaiting)</code> | A |
| 238 | deref | <code>auto callback = *then;</code> | D |
| 530 | lookup | <code>if (auto then = m.request in entryWaiting)</code> | A |
| 532 | deref | <code>auto callback = *then;</code> | D |
| 678 | lookup | <code>if (auto sent = p.guid in presenceSent)</code> | A |
| 679 | deref | <code>if (*sent == entry)</code> | D |
| 686 | lookup | <code>if (guid !in here)</code> | B |
| 738 | lookup | <code>if (account in remote)</code> | B |
| 763 | lookup | <code>if (auto m = account in movedOn)</code> | A |
| 820 | lookup | <code>if (auto session = account in remote)</code> | A |
| 855 | lookup | <code>if (auto session = account in remote)</code> | A |
| 864 | lookup | <code>if (account in gatewayRoutes)</code> | B |
| 887 | lookup | <code>if (!home.node &#124;&#124; link is null &#124;&#124; !link.peer.gateway &#124;&#124; account in remote)</code> | A |

### `source/dmangos/world/combathandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 37 | addr | <code>const v = &amp;player.values;</code> | P |
| 44 | addr | <code>r.forced = &amp;forcedReactions;</code> | P |
| 78 | addr | <code>const d = &amp;blow.melee;</code> | P |
| 97 | lookup | <code>if (const template_ = attacker.replica.fields.get!OBJECT_FIELD_ENTRY in context.data.creatureTemplates)</code> | A |
| 640 | lookup | <code>const effects = item.enchantment(e) in context.data.enchantmentEffects;</code> | A |
| 643 | deref | <code>foreach (ref effect; *effects)</code> | D |
| 649 | lookup | <code>if (const ppm = effect.arg in context.data.enchantProcRates)</code> | A |
| 650 | deref | <code>chance = speed * *ppm / 600.0f;</code> | D |
| 654 | type | <code>chance = speed * (type == AttackType.offHand ? 1.6f : 1.8f) / 1000.0f;</code> | P |
| 856 | lookup | <code>assert(!keeper.alive &amp;&amp; innkeeperSpawn !in db.creatureRespawns, "dead; the world has not looked yet");</code> | B |
| 859 | lookup | <code>assert(innkeeperSpawn in db.creatureRespawns, "its respawn time, from the deaths phase");</code> | A |
| 963 | addr | <code>auto creature = source.makeCreature(&amp;spawn);</code> | CS |
| 978 | addr, deref, type | <code>meleeRange[2] = *cast(const uint*) &amp;fiveYards;</code> | U |
| 989 | addr | <code>auto weaponUser = source.makeCreature(&amp;weaponSpawn);</code> | CS |
| 1001 | addr | <code>auto other = owner.makeCreature(&amp;otherSpawn);</code> | CS |
| 1066 | deref | <code>auto cleaveInfo = cast(SpellInfo) *source.data.spells.spell(weaponSpell);</code> | D |
| 1076 | addr | <code>auto extra = source.makeCreature(&amp;extraSpawn);</code> | CS |
| 1081 | addr | <code>auto outsideCap = source.makeCreature(&amp;extraSpawn);</code> | CS |
| 1102 | addr | <code>const moved = from.releaseCreatureLoan(weaponUser.guid, owner.nodeId, &amp;source.saveMigrant);</code> | F |
| 1104 | addr | <code>to.migrateIn(moved, &amp;owner.restoreMigrant);</code> | F |
| 1129 | lookup | <code>victim.addAura(makeAura(hitChance in owner.data.spells.spells, playerGuid, 20, -1, true, [100, 0, 0]));</code> | A |
| 1130 | lookup | <code>victim.addAura(makeAura(shield in owner.data.spells.spells, playerGuid, 20, -1, true, [7, 0, 0]));</code> | A |
| 1131 | lookup | <code>victim.addAura(makeAura(thorns in owner.data.spells.spells, playerGuid, 20, -1, true, [9, 0, 0]));</code> | A |
| 1177 | addr, deref, type | <code>rangeRow[2] = *cast(const uint*) &amp;rangeMax;</code> | U |
| 1260 | addr, deref, type | <code>[[1u, *cast(const uint*) &amp;tenYards, 0u, 0u]]), "SpellRadius.dbc");</code> | U |
| 1325 | lookup | <code>victim.addAura(makeAura(id in owner.data.spells.spells, playerGuid, 20, -1, true, [amount, 0, 0]));</code> | A |

### `source/dmangos/world/commands.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 456 | lookup | <code>if (auto overridden = path in context.commandOverrides)</code> | A |
| 457 | deref | <code>return *overridden;</code> | D |
| 756 | addr, deref, type | <code>return *cast(uint*) &amp;number;</code> | U |

### `source/dmangos/world/conditions.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 124 | lookup | <code>const condition = id in entries;</code> | A |
| 129 | deref | <code>const result = evaluate(*condition, subject, client, depth);</code> | D |
| 190 | lookup | <code>return (c.value1 in player.data.rewardedQuests) !is null;</code> | A |
| 195 | lookup | <code>const q = c.value1 in player.questStatus;</code> | A |
| 208 | lookup | <code>return (c.value1 in player.data.rewardedQuests) is null;</code> | A |
| 289 | lookup | <code>if (type !in reported)</code> | B |

### `source/dmangos/world/context.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 201 | lookup | <code>if (auto w = zone in weathers)</code> | A |
| 203 | lookup | <code>const chances = zone in data.weatherChances;</code> | A |
| 207 | deref | <code>w.chances = *chances;</code> | D |
| 224 | lookup | <code>auto w = zone in weathers;</code> | A |
| 228 | deref | <code>w.timer = typeof(*w).init.timer;</code> | D |
| 248 | return, type | <code>package Weather* weatherOf(uint zone)</code> | R |
| 250 | lookup | <code>return zone in weathers;</code> | R |
| 590 | deref | <code>if (!isChainHealEffect(*spell, message.effect) &#124;&#124; message.radius != spellJumpRadius</code> | D |
| 595 | deref | <code>else if (!isPartyHealEffect(*spell, message.effect)</code> | D |
| 613 | addr, deref | <code>UnitRef.observed(copy, target.currentMap), threat, *spell, &amp;helper);</code> | P |
| 649 | deref | <code>caster.procAuras(spellProcFlags(*spell, true, false), UnitRef.observed(copy, caster.currentMap),</code> | D |
| 666 | type | <code>package bool sendReplicaSpell(Map map_, ushort peer, const(SpellInfo)* spell, AreaDamage hit)</code> | P |
| 727 | lookup | <code>const template_ = target.replica.fields.get!OBJECT_FIELD_ENTRY in data.creatureTemplates;</code> | A |
| 794 | lookup | <code>const template_ = copy.fields.get!OBJECT_FIELD_ENTRY in data.creatureTemplates;</code> | A |
| 804 | deref | <code>const weaponEffect = spell is null ? -1 : nextWeaponSwingEffect(*spell);</code> | D |
| 1015 | deref | <code>&#124;&#124; !isRemoteLeechChannel(*spell))</code> | D |
| 1022 | deref | <code>if (!isTargetedProcEffect(*spell, message.effect) &#124;&#124; copy.fields.get!UNIT_CHANNEL_SPELL != message.spell</code> | D |
| 1038 | deref | <code>const shape = creatureAreaShape(*spell, message.effect);</code> | D |
| 1039 | deref | <code>if (shape == ImplicitTarget.none &#124;&#124; message.radius != radius(*spell, message.effect, client)</code> | D |
| 1054 | deref | <code>&#124;&#124; !isCreatureTargetEffect(*spell, message.effect))</code> | D |
| 1066 | deref | <code>if (message.previous &#124;&#124; !isTargetedProcEffect(*spell, message.effect))</code> | D |
| 1082 | deref | <code>if (!isHostileChainEffect(*spell, message.effect) &#124;&#124; message.radius != spellJumpRadius</code> | D |
| 1086 | deref | <code>else if (!isHostileAreaEffect(*spell, message.effect))</code> | D |
| 1122 | deref | <code>const flags = spellProcFlags(*spell, false, true);</code> | D |
| 1375 | return, type | <code>private const(Heard)* recentHandoff(ulong guid)</code> | R |
| 1377 | lookup | <code>if (const hint = guid in lastHeard)</code> | A |
| 1408 | type | <code>private void remoteProcEffect(ushort peer, const ref AreaDamage message, const(SpellInfo)* spell,</code> | P |
| 1450 | deref | <code>const missed = rollSpellHit(caster, victim.fighter, *spell, victim.resistance(school),</code> | D |
| 1462 | deref | <code>ubyte effects = remoteTargetAuraEffects(*spell, i);</code> | D |
| 1558 | deref | <code>caster.procAuras(spellProcFlags(*spell, false, false), other,</code> | D |
| 1610 | addr | <code>auto players = &amp;remoteByNode.require(node, null);</code> | P |
| 1613 | deref | <code>(*players)[e.guid] = RemotePlayer(node, e);</code> | D |
| 1617 | deref | <code>(*players).remove(guid);</code> | D |
| 1650 | return, type | <code>const(RemotePlayer)* remotePlayer(ulong guid)</code> | R |
| 1653 | lookup | <code>if (auto p = guid in players)</code> | A |
| 1659 | return, type | <code>const(RemotePlayer)* remotePlayer(string name)</code> | R |
| 1667 | addr | <code>return &amp;p;</code> | R |
| 1732 | addr | <code>transportClockSource = &amp;transportNow;</code> | F |
| 1760 | addr | <code>services.provide!WarEffortHost(&amp;newWarEffortHost);</code> | F |
| 1761 | addr | <code>services.listen!(WarEffortHost, WarEffort)(&amp;warEffortHeard);</code> | F |
| 1763 | addr | <code>services.provide!WorldPvpHost(&amp;newWorldPvpHost);</code> | F |
| 1764 | addr | <code>services.listen!(WorldPvpHost, WorldPvp)(&amp;worldPvp.heard);</code> | F |
| 1776 | return, type | <code>private const(CreatureSpawn)* creatureSpawnOf(uint guid)</code> | R |
| 1781 | lookup | <code>if (auto at = guid in spawnIndex)</code> | A |
| 1782 | addr, deref | <code>return &amp;data.creatureSpawns[*at];</code> | R |
| 1787 | type | <code>private Creature[] slavesOf(Map m, Creature master, out const(CreatureLink)*[] links)</code> | P |
| 1796 | lookup | <code>links ~= guid in links_.bySlaveGuid;</code> | A |
| 1816 | type | <code>private Creature masterOf(Map m, Creature slave, out const(CreatureLink)* link)</code> | P |
| 1839 | type | <code>const(CreatureLink)*[] links;</code> | P |
| 1868 | type | <code>const(CreatureLink)* link;</code> | P |
| 1887 | addr | <code>return respawnInCopy(m, &amp;c.spawn, c);</code> | R |
| 1895 | type | <code>private void respawnInCopy(Map m, const(CreatureSpawn)* spawn, Creature corpse)</code> | P |
| 1899 | lookup | <code>if (auto state = m.instanceId in instances)</code> | A |
| 1909 | lookup | <code>if (auto script = m.instanceId in instanceScripts)</code> | A |
| 1920 | lookup | <code>if (auto at = guid in respawnAt)</code> | A |
| 1921 | deref | <code>if (*at &gt; unixTime)</code> | D |
| 1923 | deref | <code>*at = unixTime;</code> | D |
| 1932 | lookup | <code>if (const l = guid in data.creatureLinks.bySlaveGuid)</code> | A |
| 1940 | lookup | <code>if (auto state = master.instanceId in instances)</code> | A |
| 1941 | lookup | <code>if (guid in state.dead)</code> | B |
| 1954 | type | <code>const(CreatureLink)*[] links;</code> | P |
| 1979 | type | <code>const(CreatureLink)*[] links;</code> | P |
| 2003 | lookup | <code>if (!data.creatureLinks.involves(c.spawnId, c.template_.entry) &amp;&amp; c.spawnId !in data.formationSlots)</code> | B |
| 2013 | type | <code>private bool cantSpawnWhileBossDead(const ref CreatureSpawn spawn, const(InstanceState)* state)</code> | P |
| 2017 | lookup | <code>if (const l = spawn.guid in data.creatureLinks.bySlaveGuid)</code> | A |
| 2019 | lookup | <code>const bossDead = (l.masterGuid in state.dead) !is null;</code> | A |
| 2043 | lookup | <code>if (const slot = c.spawnId in data.formationSlots)</code> | A |
| 2045 | deref | <code>arrangeFormation(m, (*slot)[0]);</code> | D |
| 2048 | type | <code>const(CreatureLink)* link;</code> | P |
| 2052 | type | <code>const(CreatureLink)*[] links;</code> | P |
| 2083 | lookup | <code>const f = group in data.formations;</code> | A |
| 2114 | deref | <code>formationPlace(*f, index, cast(uint) members.length, distance, angle);</code> | D |
| 2149 | lookup | <code>if (const e = guid in data.creatureGameEvents)</code> | A |
| 2150 | deref | <code>return gameEvents.spawnIn(*e);</code> | D |
| 2164 | lookup | <code>if (const e = guid in data.gameObjectGameEvents)</code> | A |
| 2165 | deref | <code>return gameEvents.spawnIn(*e);</code> | D |
| 2242 | lookup | <code>const was = (id in eventsOnBefore) !is null;</code> | A |
| 2279 | lookup | <code>if (auto proto = lootItem.itemId in data.items)</code> | A |
| 2302 | type | <code>const(CreatureSpawn)*[] remade;</code> | P |
| 2308 | lookup | <code>else if (c.spawnId in data.eventCreatures &amp;&amp; !c.petOwner &amp;&amp; c.summon.type == TempSpawnType.none</code> | B |
| 2331 | lookup | <code>if (auto cells = m.id in data.creatureCells)</code> | A |
| 2332 | deref | <code>foreach (key, indexes; *cells)</code> | D |
| 2336 | addr | <code>const spawn = &amp;data.creatureSpawns[index];</code> | P |
| 2337 | lookup | <code>if (spawn.guid !in data.creatureGameEvents &#124;&#124; !creatureInEvents(spawn.guid)</code> | B |
| 2343 | lookup | <code>if (c is null &#124;&#124; c.guid in present)</code> | A |
| 2348 | lookup | <code>if (auto cells = m.id in data.gameObjectCells)</code> | A |
| 2349 | deref | <code>foreach (key, indexes; *cells)</code> | D |
| 2353 | addr | <code>const spawn = &amp;data.gameObjectSpawns[index];</code> | P |
| 2359 | lookup | <code>if (go.guid in present)</code> | B |
| 2376 | lookup | <code>return (guid in data.gameObjectGameEvents) !is null &#124;&#124; isSupplyPile(guid) &#124;&#124; WorldPvp.follows(guid);</code> | A |
| 2623 | type | <code>const(Ship)* ship;</code> | P |
| 2660 | lookup | <code>const t = ship.entry in data.gameObjectTemplates;</code> | A |
| 2661 | addr | <code>ships ~= ShipAtSea(&amp;ship, new ShipObject(t, ship.period,</code> | P |
| 2662 | addr | <code>Position(k.node.x, k.node.y, k.node.z, k.facing), &amp;transportNow));</code> | F |
| 2670 | addr | <code>auto k = &amp;s.ship.frames[frame];</code> | P |
| 2672 | addr | <code>k = &amp;s.ship.frames[(frame + 1) % s.ship.frames.length];</code> | P |
| 2685 | addr | <code>const move = &amp;who.character.movement;</code> | P |
| 2739 | lookup | <code>if (auto found = id in maps)</code> | A |
| 2740 | deref | <code>return *found;</code> | D |
| 2749 | lookup | <code>if (auto found = instance in instanceMaps)</code> | A |
| 2750 | deref | <code>return *found;</code> | D |
| 2751 | lookup | <code>if (instance !in instances)</code> | B |
| 2767 | lookup | <code>if (const to = spell in data.spellTargets)</code> | A |
| 2816 | addr | <code>MapObject[] delegate(uint, ulong) spawner = &amp;spawnCell;</code> | F |
| 2821 | addr | <code>&amp;serverTime, spawner, terrain(id), owns);</code> | F |
| 2825 | addr | <code>created.onCorpseRemoved = &amp;corpseRemoved;</code> | F |
| 2828 | addr | <code>created.onReplicaNoticing = &amp;replicaNoticing;</code> | F |
| 2830 | addr | <code>created.remoteCreatureSwing = &amp;queueCreatureSwing;</code> | F |
| 2841 | addr | <code>created.onGameObjectUsedUp = &amp;gameObjectUsedUp;</code> | F |
| 2842 | addr | <code>created.onObjectGone = &amp;objectGone;</code> | F |
| 2861 | addr | <code>created.onLinked = &amp;linkedEvent;</code> | F |
| 2863 | lookup | <code>if (const name = id in data.instanceScriptNames)</code> | A |
| 2865 | lookup | <code>auto state = instance in instances;</code> | A |
| 2866 | deref | <code>auto script = InstanceScript.make(scripts, *name, instance, id, state is null ? null : state.data,</code> | D |
| 2868 | lookup | <code>if (auto st = instance in instances)</code> | A |
| 2876 | addr | <code>script.spawnObjects = &amp;spawnDungeonObjects;</code> | F |
| 2877 | addr | <code>script.signalObject = &amp;gameObjectSignalled;</code> | F |
| 2878 | addr | <code>script.respawnObjectOf = &amp;respawnObjectOfEntry;</code> | F |
| 2879 | addr | <code>script.summonObjectAt = &amp;summonGameObjectAt;</code> | F |
| 2886 | lookup | <code>if (auto s = instance in instanceScripts)</code> | A |
| 2892 | lookup | <code>if (const name = id in data.worldScriptNames)</code> | A |
| 2893 | deref | <code>if (auto script = InstanceScript.makeWorld(scripts, *name, id))</code> | D |
| 2897 | addr | <code>script.spawnObjects = &amp;spawnDungeonObjects;</code> | F |
| 2898 | addr | <code>script.signalObject = &amp;gameObjectSignalled;</code> | F |
| 2899 | addr | <code>script.respawnObjectOf = &amp;respawnObjectOfEntry;</code> | F |
| 2900 | addr | <code>script.summonObjectAt = &amp;summonGameObjectAt;</code> | F |
| 3011 | lookup | <code>if (group !is null &amp;&amp; groupBinds.get(group.leader, null).get(mapId, 0) !in instances)</code> | B |
| 3026 | lookup | <code>if (auto bound = mapId in playerBinds.get(player, null))</code> | A |
| 3027 | deref, lookup | <code>if (*bound in instances)</code> | A |
| 3028 | deref | <code>return *bound;</code> | D |
| 3030 | lookup | <code>if (auto bound = mapId in groupBinds.get(group.leader, null))</code> | A |
| 3031 | deref, lookup | <code>if (*bound in instances)</code> | A |
| 3032 | deref | <code>return *bound;</code> | D |
| 3033 | lookup | <code>if (auto bound = mapId in playerBinds.get(player, null))</code> | A |
| 3034 | deref, lookup | <code>if (*bound in instances)</code> | A |
| 3035 | deref | <code>return *bound;</code> | D |
| 3052 | lookup | <code>if (const most = mapId in data.instanceMaxPlayers)</code> | A |
| 3054 | deref | <code>if (there.population &gt;= *most)</code> | D |
| 3070 | lookup | <code>auto recent = account in recentInstances;</code> | A |
| 3073 | deref | <code>*recent = withinTheHour(*recent, unixTime);</code> | D |
| 3074 | deref | <code>return tooManyInstances(*recent, instance);</code> | D |
| 3098 | lookup | <code>if (!instance &#124;&#124; instance !in instances &#124;&#124; mapId in playerBinds.get(player, null) &#124;&#124; battlegroundOfMap(mapId))</code> | B |
| 3117 | lookup | <code>return mine &amp;&amp; theirs &amp;&amp; mine != theirs &amp;&amp; mine in instances &amp;&amp; theirs in instances;</code> | R |
| 3177 | lookup | <code>if (auto s = instance in instances)</code> | A |
| 3201 | lookup | <code>if (auto state = b.instance in instances)</code> | A |
| 3210 | lookup | <code>if (auto state = r.instance in instances)</code> | A |
| 3268 | addr | <code>const bundle = m.migrateOut((ulong) =&gt; true, next, &amp;saveMigrant);</code> | F |
| 3296 | lookup | <code>if (id !in instances)</code> | B |
| 3333 | lookup | <code>if (auto state = instance in instances)</code> | A |
| 3334 | lookup | <code>return (spawnGuid in state.dead) !is null;</code> | A |
| 3349 | lookup | <code>auto state = instance in instances;</code> | A |
| 3353 | lookup | <code>if (auto cells = mapId in data.creatureCells)</code> | A |
| 3354 | deref | <code>foreach (index; (*cells).get(cell, null))</code> | D |
| 3356 | lookup | <code>if (state !is null &amp;&amp; data.creatureSpawns[index].guid in state.dead)</code> | A |
| 3361 | lookup | <code>if (copy !is null &amp;&amp; !copy.spawnAllowed(data.creatureSpawns[index].guid in data.creatureBattleEvents))</code> | A |
| 3365 | addr | <code>if (auto creature = makeCreature(&amp;data.creatureSpawns[index]))</code> | CS |
| 3372 | lookup | <code>if (auto cells = mapId in data.gameObjectCells)</code> | A |
| 3373 | deref | <code>foreach (index; (*cells).get(cell, null))</code> | D |
| 3375 | addr | <code>const spawn = &amp;data.gameObjectSpawns[index];</code> | P |
| 3376 | lookup | <code>if (spawn.respawnSeconds &lt; 0 &#124;&#124; (state !is null &amp;&amp; spawn.guid in state.usedUp)</code> | A |
| 3379 | lookup | <code>const event = spawn.guid in data.gameObjectBattleEvents;</code> | A |
| 3384 | deref | <code>if (copy !is null &amp;&amp; event !is null &amp;&amp; (*event)[0] == 254 &amp;&amp; copy.doorsOpen)</code> | D |
| 3388 | lookup | <code>if (auto script = instance in instanceScripts)</code> | A |
| 3457 | type | <code>uint[uint]* binds;</code> | P |
| 3462 | lookup | <code>binds = group.leader in groupBinds;</code> | A |
| 3465 | lookup | <code>binds = player in playerBinds;</code> | A |
| 3468 | deref | <code>foreach (mapId, id; (*binds).dup)</code> | D |
| 3507 | lookup | <code>if (auto script = id in instanceScripts)</code> | A |
| 3577 | lookup | <code>if (k.to!string ~ ":" ~ name !in used)</code> | B |
| 3582 | return, type | <code>const(InstanceState)* instanceState(uint id) const</code> | R |
| 3584 | lookup | <code>return id in instances;</code> | R |
| 3602 | lookup | <code>if (auto binds = player in playerBinds)</code> | A |
| 3603 | deref, lookup | <code>if (auto instance = mapId in *binds)</code> | A |
| 3605 | deref | <code>database.deleteInstanceBind(cast(uint) player, *instance);</code> | D |
| 3606 | deref | <code>(*binds).remove(mapId);</code> | D |
| 3635 | lookup | <code>const template_ = replica.fields[OBJECT_FIELD_ENTRY] in data.creatureTemplates;</code> | A |
| 3638 | lookup | <code>if (auto standIn = replica.guid in standIns)</code> | A |
| 3641 | deref | <code>return *standIn;</code> | D |
| 3696 | lookup | <code>if (auto copies = r.id in arriving)</code> | A |
| 3697 | deref | <code>dungeonCopiesIn(r.map, *copies);</code> | D |
| 3700 | lookup | <code>if (auto m = r.map in maps)</code> | A |
| 3708 | addr | <code>&amp;saveMigrant);</code> | F |
| 3718 | lookup | <code>if (auto objects = r.id in arriving)</code> | A |
| 3724 | addr, deref | <code>m.migrateIn(*objects, &amp;restoreMigrant);</code> | F |
| 3732 | lookup | <code>if (r.map !in looked)</code> | B |
| 3735 | lookup | <code>if (auto m = r.map in maps)</code> | A |
| 3743 | non-null borrow | <code>auto counter = counterOf(kind);</code> | V |
| 3744 | deref | <code>const first = *counter;</code> | V |
| 3745 | deref | <code>*counter += count;</code> | V |
| 3770 | non-null borrow | <code>auto counter = counterOf(kind);</code> | V |
| 3771 | deref | <code>if (*counter &lt; atLeast)</code> | V |
| 3772 | deref | <code>*counter = atLeast;</code> | V |
| 3775 | return, type | <code>private uint* counterOf(IdKind kind) return</code> | V |
| 3779 | addr | <code>case IdKind.character: return &amp;next.character;</code> | V |
| 3780 | addr | <code>case IdKind.item: return &amp;next.item;</code> | V |
| 3781 | addr | <code>case IdKind.mail: return &amp;next.mail;</code> | V |
| 3782 | addr | <code>case IdKind.group: return &amp;groups.nextId;</code> | V |
| 3783 | addr | <code>case IdKind.instance: return &amp;next.instance;</code> | V |
| 3784 | addr | <code>case IdKind.pet: return &amp;next.pet;</code> | V |
| 3797 | lookup | <code>if (auto cells = mapId in data.creatureCells)</code> | A |
| 3798 | deref | <code>foreach (index; (*cells).get(cell, null))</code> | D |
| 3806 | addr | <code>if (auto creature = makeCreature(&amp;data.creatureSpawns[index]))</code> | CS |
| 3812 | lookup | <code>if (auto cells = mapId in data.gameObjectCells)</code> | A |
| 3813 | deref | <code>foreach (index; (*cells).get(cell, null))</code> | D |
| 3815 | addr | <code>const spawn = &amp;data.gameObjectSpawns[index];</code> | P |
| 3830 | type | <code>Creature makeCreature(const(CreatureSpawn)* spawn, uint petNumber = 0)</code> | CS |
| 3836 | type | <code>const(EventCreature)* shape;</code> | P |
| 3839 | lookup | <code>if (auto list = spawn.guid in data.eventCreatures)</code> | A |
| 3840 | deref | <code>foreach (ref e; *list)</code> | D |
| 3843 | addr | <code>shape = &amp;e;</code> | P |
| 3844 | lookup | <code>if (e.entry &amp;&amp; e.entry in data.creatureTemplates)</code> | A |
| 3846 | deref | <code>reshaped = *spawn;</code> | D |
| 3848 | addr | <code>spawn = &amp;reshaped;</code> | P |
| 3852 | lookup | <code>const template_ = spawn.entry in data.creatureTemplates;</code> | A |
| 3853 | deref | <code>const display = chooseDisplay(*template_, spawnRandom);</code> | D |
| 3856 | deref | <code>const level = chooseLevel(*template_, spawnRandom);</code> | D |
| 3857 | deref | <code>auto parts = creatureParts(*template_, spawn.guid, display, level,</code> | D |
| 3859 | deref | <code>auto creature = new Creature(*spawn, template_, display, level, parts, client, petNumber);</code> | D |
| 3861 | deref | <code>applyEventShape(creature, *shape);</code> | D |
| 3885 | lookup | <code>if (const name = spawn.entry in data.creatureScriptNames)</code> | A |
| 3886 | deref | <code>creature.ai.setBehaviour(scripts, *name);</code> | D |
| 3900 | lookup | <code>if (const stats = classStatsKey(level, t.unitClass) in data.creatureClassStats)</code> | A |
| 3902 | deref | <code>parts.classStats = *stats;</code> | D |
| 3905 | lookup | <code>parts.addon = spawnGuid in data.creatureAddons;</code> | A |
| 3907 | lookup | <code>parts.addon = t.entry in data.creatureTemplateAddons;</code> | A |
| 3908 | lookup | <code>if (const model = display in data.models)</code> | A |
| 3915 | lookup | <code>if (const equipment = equipmentId in data.creatureEquipment)</code> | A |
| 3916 | deref | <code>foreach (slot, entry; *equipment)</code> | D |
| 3917 | lookup | <code>if (const item = entry in data.items)</code> | A |
| 3929 | lookup | <code>const t = entry in data.creatureTemplates;</code> | A |
| 3932 | deref | <code>const display = chooseDisplay(*t, spawnRandom);</code> | D |
| 3936 | deref | <code>auto parts = creatureParts(*t, creature.spawn.guid, display, level, t.equipmentTemplateId);</code> | D |
| 3949 | deref | <code>auto parts = creatureParts(*t, creature.spawn.guid, display, level, t.equipmentTemplateId);</code> | D |
| 3983 | lookup | <code>if (const t = cast(uint) spell.miscValue[i] in data.creatureTemplates)</code> | A |
| 3984 | deref | <code>if (const model = chooseDisplay(*t, spawnRandom))</code> | D |
| 3998 | lookup | <code>if (auto list = guid in data.eventCreatures)</code> | A |
| 3999 | deref | <code>foreach (ref e; *list)</code> | D |
| 4010 | return, type | <code>const(SpellInfo)* spellInfo(uint id)</code> | R |
| 4022 | return, type | <code>const(BroadcastText)* broadcastText(uint id)</code> | R |
| 4024 | lookup | <code>return id in data.npcs.broadcastTexts;</code> | R |
| 4079 | lookup | <code>const at = m.spawn in spawnIndex;</code> | A |
| 4082 | addr, deref | <code>auto creature = makeCreature(&amp;data.creatureSpawns[*at]);</code> | CS |
| 4088 | lookup | <code>const at = m.spawn in gameObjectSpawnIndex;</code> | A |
| 4094 | addr, deref | <code>auto gameObject = makeGameObject(&amp;data.gameObjectSpawns[*at]);</code> | GO |
| 4123 | return, type | <code>private const(CreatureSpawn)* loanSpawn(uint spawn, uint mapId)</code> | R |
| 4126 | lookup | <code>if (const at = spawn in spawnIndex)</code> | A |
| 4127 | deref | <code>if (data.creatureSpawns[*at].map == mapId)</code> | D |
| 4128 | addr, deref | <code>return &amp;data.creatureSpawns[*at];</code> | R |
| 4145 | lookup | <code>&#124;&#124; spawn in data.creatureGameEvents &#124;&#124; spawn in data.eventCreatures)</code> | A |
| 4147 | addr | <code>const values = &amp;replica.fields();</code> | P |
| 4162 | type | <code>private ulong loanGuid(const(CreatureSpawn)* spawn)</code> | P |
| 4180 | lookup | <code>if (r.id !in localCreatureLoans)</code> | B |
| 4188 | addr | <code>const bundle = map_.releaseCreatureLoan(guid, r.next, &amp;saveMigrant);</code> | F |
| 4189 | lookup | <code>if (!bundle.length &amp;&amp; r.id !in localCreatureLoans)</code> | B |
| 4221 | addr | <code>map_.migrateIn(encodeBundle(null, migrants), &amp;restoreMigrant);</code> | F |
| 4296 | lookup | <code>in (who.character.guid !in online, "a character is in the world once")</code> | B |
| 4319 | lookup | <code>if (who.character.guid !in online)</code> | B |
| 4384 | lookup | <code>if (auto script = creature.instanceId in instanceScripts)</code> | A |
| 4387 | lookup | <code>else if (auto script = creature.spawn.map in worldScripts)</code> | A |
| 4393 | lookup | <code>if (auto state = creature.instanceId in instances)</code> | A |
| 4419 | lookup | <code>if (creature.spawn.guid !in respawnAt)</code> | B |
| 4477 | lookup | <code>if (map is null &#124;&#124; entry !in data.creatureTemplates)</code> | B |
| 4498 | addr | <code>auto creature = makeCreature(&amp;spawn);</code> | CS |
| 4506 | lookup | <code>if (auto script = map.instanceId in instanceScripts)</code> | A |
| 4521 | lookup | <code>if (map is null &#124;&#124; entry !in data.creatureTemplates)</code> | B |
| 4526 | addr | <code>auto creature = makeCreature(&amp;spawn, number);</code> | CS |
| 4554 | lookup | <code>if (const spot = id in data.eventAi.summons)</code> | A |
| 4585 | addr | <code>const values = &amp;replica.fields();</code> | P |
| 4586 | lookup | <code>const template_ = values.get!OBJECT_FIELD_ENTRY in data.creatureTemplates;</code> | A |
| 4590 | deref | <code>if (faction is null &#124;&#124; isNeutralToAll(*faction))</code> | D |
| 4633 | lookup | <code>if (entry !in data.creatureTemplates)</code> | B |
| 4647 | addr | <code>auto creature = makeCreature(&amp;data.creatureSpawns[index]);</code> | CS |
| 4662 | lookup | <code>if (auto cells = s.map in data.creatureCells)</code> | A |
| 4663 | deref, lookup | <code>if (auto list = cellKeyAt(s.x, s.y) in *cells)</code> | A |
| 4664 | deref | <code>foreach (i, index; *list)</code> | D |
| 4667 | deref | <code>*list = (*list).remove(i);</code> | D |
| 4681 | lookup | <code>if (entry !in data.gameObjectTemplates)</code> | B |
| 4696 | addr | <code>auto go = makeGameObject(&amp;data.gameObjectSpawns[index]);</code> | GO |
| 4714 | lookup | <code>const at = go.spawn.guid in gameObjectSpawnIndex;</code> | A |
| 4717 | deref | <code>const old = data.gameObjectSpawns[*at];</code> | D |
| 4721 | lookup | <code>if (auto cells = old.map in data.gameObjectCells)</code> | A |
| 4722 | deref, lookup | <code>if (auto list = oldCell in *cells)</code> | A |
| 4723 | deref | <code>foreach (i, index; *list)</code> | D |
| 4724 | deref | <code>if (index == *at)</code> | D |
| 4726 | deref | <code>*list = (*list).remove(i);</code> | D |
| 4729 | deref | <code>data.gameObjectCells.require(changed.map, null).require(newCell, null) ~= *at;</code> | D |
| 4731 | deref | <code>data.gameObjectSpawns[*at] = changed;</code> | D |
| 4735 | addr, deref | <code>auto made = makeGameObject(&amp;data.gameObjectSpawns[*at]);</code> | GO |
| 4748 | lookup | <code>if (auto cells = s.map in data.gameObjectCells)</code> | A |
| 4749 | deref, lookup | <code>if (auto list = cellKeyAt(s.x, s.y) in *cells)</code> | A |
| 4750 | deref | <code>foreach (i, index; *list)</code> | D |
| 4753 | deref | <code>*list = (*list).remove(i);</code> | D |
| 4805 | return, type | <code>const(BroadcastText)* scriptText(int entry)</code> | R |
| 4807 | lookup | <code>return entry in data.scriptTexts;</code> | R |
| 4819 | lookup | <code>if (const item = entry in data.items)</code> | A |
| 4835 | lookup | <code>if (id in data.spellScriptNames)</code> | B |
| 4862 | lookup | <code>if (auto found = id in made)</code> | A |
| 4863 | deref | <code>return *found;</code> | D |
| 4864 | lookup | <code>const name = id in names;</code> | A |
| 4865 | deref | <code>return made[id] = name is null ? ScriptHandle.init : scripts.create(kind, *name);</code> | D |
| 5011 | lookup | <code>if (auto script = go.instanceId in instanceScripts)</code> | A |
| 5473 | lookup | <code>if (const t = entry in data.creatureTemplates)</code> | A |
| 5505 | lookup | <code>if (entry !in data.gameObjectTemplates)</code> | B |
| 5512 | deref | <code>*spawn = GameObjectSpawn(++lastGameObjectSpawn, entry, map.id, at.x, at.y, at.z);</code> | D |
| 5526 | lookup | <code>if (auto script = instance in instanceScripts)</code> | A |
| 5550 | lookup | <code>if (auto script = map in worldScripts)</code> | A |
| 5565 | lookup | <code>if (const entries = spell in data.spellScriptTargets)</code> | A |
| 5566 | deref | <code>return *entries;</code> | D |
| 5595 | lookup | <code>const stats = classStatsKey(level, unitClass) in data.creatureClassStats;</code> | A |
| 5642 | lookup | <code>if (auto script = instance in instanceScripts)</code> | A |
| 5651 | lookup | <code>if (auto script = instance in instanceScripts)</code> | A |
| 5681 | lookup | <code>if (auto script = map.instanceId in instanceScripts)</code> | A |
| 5732 | lookup | <code>if (auto state = corpse.instanceId in instances)</code> | A |
| 5735 | addr | <code>if (auto back = makeCreature(&amp;corpse.spawn))</code> | CS |
| 5751 | type | <code>GameObject makeGameObject(const(GameObjectSpawn)* spawn)</code> | GO |
| 5755 | deref, lookup | <code>auto go = new GameObject(*spawn, spawn.entry in data.gameObjectTemplates);</code> | A |
| 5767 | lookup | <code>if (const name = spawn.entry in data.gameObjectScriptNames)</code> | A |
| 5768 | deref | <code>if (scripts !is null &amp;&amp; scripts.serves(ScriptKind.gameObject, *name))</code> | D |
| 5771 | deref | <code>go.behaviour = scripts.create(ScriptKind.gameObject, *name);</code> | D |
| 5796 | lookup | <code>if (auto state = go.instanceId in instances)</code> | A |
| 5812 | lookup | <code>if (auto at = spawnGuid in gameObjectRespawnAt)</code> | A |
| 5813 | deref | <code>return *at &gt; unixTime;</code> | D |
| 5832 | lookup | <code>const index = guid in gameObjectSpawnIndex;</code> | A |
| 5835 | addr, deref | <code>const spawn = &amp;data.gameObjectSpawns[*index];</code> | P |
| 5837 | lookup | <code>if (const i = member in gameObjectSpawnIndex)</code> | A |
| 5839 | deref | <code>gameObjectRespawnAt[member] = time + data.gameObjectSpawns[*i].respawnSeconds;</code> | D |
| 5906 | return, type | <code>const(AuctionHouseEntry)* auctionHouse(uint houseId)</code> | R |
| 5923 | deref | <code>const cut = house is null ? 0 : a.cut(*house, config.rateAuctionCut);</code> | D |
| 6003 | lookup | <code>if (auto at = spawnGuid in respawnAt)</code> | A |
| 6004 | deref | <code>return *at &gt; unixTime;</code> | D |
| 6033 | lookup | <code>const index = guid in spawnIndex;</code> | A |
| 6036 | addr, deref | <code>const spawn = &amp;data.creatureSpawns[*index];</code> | P |
| 6038 | lookup | <code>if (const i = member in spawnIndex)</code> | A |
| 6040 | deref | <code>respawnAt[member] = time + data.creatureSpawns[*i].respawnSeconds;</code> | D |
| 6080 | lookup | <code>if (auto hint = guid in lastHeard)</code> | A |
| 6103 | lookup | <code>if (auto hint = guid in lastHeard)</code> | A |
| 6213 | addr | <code>auto timer = &amp;shutdown.get();</code> | P |
| 6251 | lookup | <code>if (player.character !is null &amp;&amp; player.character.guid !in updatedPlayers)</code> | B |
| 6263 | lookup | <code>if (player.character !is null &amp;&amp; player.character.guid !in updatedPlayers)</code> | B |
| 6391 | non-null borrow | <code>auto counter = counterOf(kind);</code> | V |
| 6392 | deref | <code>id = (*counter)++;</code> | V |
| 6451 | lookup | <code>if (auto previous = accountId in sessions)</code> | A |
| 6452 | deref | <code>if (*previous !is session)</code> | D |
| 6471 | lookup | <code>if (auto current = accountId in sessions)</code> | A |
| 6472 | deref | <code>if (*current is session)</code> | D |
| 6474 | lookup | <code>if (auto serial = session in serials)</code> | A |
| 6479 | deref | <code>releaseSession(accountId, *serial);</code> | D |
| 6503 | lookup | <code>if (auto session = account in sessions)</code> | A |
| 6504 | deref | <code>if (serials.get(*session, 0) == serial)</code> | D |
| 6578 | lookup | <code>if (auto serial = session in serials)</code> | A |
| 6579 | deref | <code>claimSession(account, *serial);</code> | D |
| 6598 | deref | <code>context.data.creatureTemplates[2046] = *vendor;</code> | D |
| 6601 | lookup | <code>auto actual = new Creature(spawn, (2046 in context.data.creatureTemplates), 1, 10, parts, testClientData());</code> | A |
| 6871 | lookup | <code>if (auto when = key in last)</code> | A |
| 6872 | deref | <code>if (now - *when &lt; quiet)</code> | D |

### `source/dmangos/world/corpse.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 66 | addr | <code>const v = &amp;body_.values;</code> | P |
| 100 | addr | <code>const v = &amp;player.values;</code> | P |

### `source/dmangos/world/creature.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 257 | type | <code>CreatureCombatStats selectLevel(const ref CreatureTemplate t, uint level, const(CreatureClassStats)* stats)</code> | P |
| 327 | type | <code>const base = power * (times[type] / 1000.0f) / 14.0f;</code> | P |
| 354 | type | <code>const(CreatureAddon)* addon;</code> | P |
| 393 | lookup | <code>auto stock = item in items;</code> | A |
| 416 | lookup | <code>auto stock = item in items;</code> | A |
| 436 | lookup | <code>if (auto stock = item in items)</code> | A |
| 450 | return, type | <code>@property const(CreatureTemplate)* npcTemplate() const;</code> | R |
| 465 | type | <code>private const(CreatureTemplate)* template_;</code> | P |
| 469 | type | <code>this(Replica replica, const(CreatureTemplate)* template_)</code> | P |
| 490 | return, type | <code>@property const(CreatureTemplate)* npcTemplate() const { return template_; }</code> | R |
| 508 | type | <code>const(CreatureTemplate)* template_;</code> | P |
| 524 | type | <code>this(const ref CreatureSpawn spawn, const(CreatureTemplate)* template_, uint display, uint level,</code> | P |
| 608 | return, type | <code>@property const(CreatureTemplate)* npcTemplate() const</code> | R |
| 827 | type | <code>void changeEntry(const(CreatureTemplate)* t, uint display, const ref CreatureParts parts, const ClientData client)</code> | P |
| 1045 | type | <code>const(FactionTemplateEntry)* factionTemplate;</code> | P |
| 1280 | addr | <code>block.spline = &amp;spline;</code> | P |
| 1386 | addr, deref | <code>const combat = selectLevel(*t, level, parts.hasClassStats ? &amp;parts.classStats : null);</code> | P |
| 1474 | addr | <code>auto creature = new Creature(spawn, &amp;hogger, 384, 11, parts, testClientData());</code> | P |

### `source/dmangos/world/creatureai.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 47 | return, type | <code>const(SpellInfo)* spellInfo(uint id);</code> | R |
| 53 | return, type | <code>const(BroadcastText)* broadcastText(uint id);</code> | R |
| 69 | return, type | <code>const(BroadcastText)* scriptText(int entry);</code> | R |
| 386 | deref | <code>&amp;&amp; (me.factionTemplate is null &#124;&#124; !isNeutralToAll(*me.factionTemplate));</code> | D |
| 426 | deref | <code>if (me.factionTemplate !is null &amp;&amp; isNeutralToAll(*me.factionTemplate))</code> | D |
| 469 | lookup | <code>else if ((who.combatGuid in threat) is null)</code> | A |
| 777 | lookup | <code>if (auto t = who in threat)</code> | A |
| 778 | deref | <code>*t = *t * (percent &lt;= -100 ? 0 : (100 + percent) / 100.0f);</code> | D |
| 813 | lookup | <code>if (aura.has(AuraType.modTaunt) &amp;&amp; (aura.caster in threat) !is null)</code> | A |
| 825 | lookup | <code>if ((guid in threat) is null)</code> | A |
| 867 | lookup | <code>if (auto t = guid in threat)</code> | A |
| 869 | deref | <code>*t += amount;</code> | D |
| 882 | lookup | <code>if (auto previous = guid in threat)</code> | A |
| 883 | deref | <code>*previous += amount;</code> | D |
| 1205 | lookup | <code>else if ((canSwingRemotely &#124;&#124; guid in remoteThreat) &amp;&amp; (victim &#124;&#124; combatTimer &gt; 0 &#124;&#124; restoringThreat))</code> | A |
| 1304 | lookup | <code>if (guid !in remoteThreat &#124;&#124; canSwingRemotely)</code> | B |
| 1314 | lookup | <code>order.sort!((a, b) =&gt; (a in suppressed) is null &amp;&amp; (b in suppressed) !is null, SwapStrategy.stable);</code> | A |
| 1315 | lookup | <code>if ((order[0] in suppressed) is null &amp;&amp; (victim in suppressed) !is null)</code> | A |
| 1318 | lookup | <code>const current = !canSwingRemotely &amp;&amp; victim in remoteThreat ? null : victim in threat;</code> | A |
| 1327 | deref | <code>if (t &lt;= 1.1f * *current)</code> | D |
| 1331 | deref | <code>if (t &gt; 1.3f * *current &#124;&#124; (t &gt; 1.1f * *current &amp;&amp; inMelee))</code> | D |
| 1432 | deref | <code>const r = range(*info, lore.clientData)[1];</code> | D |
| 1694 | deref | <code>if (aura.spell !is null &amp;&amp; removedOnEvade(*aura.spell))</code> | D |
| 1758 | type | <code>const ref SpellInfo spell, const Relating* remote = null)</code> | P |
| 1773 | deref | <code>if (canAttack(c.ai.relatingOf, remote is null ? helper.relating : *remote, c.client))</code> | D |
| 1898 | type | <code>(cast(CreatureTemplate*) keeper.template_).detection = 20;</code> | FIX |
| 1939 | type | <code>(cast(CreatureTemplate*) trainer.template_).detection = 0;</code> | FIX |

### `source/dmangos/world/creaturecasting.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 65 | type | <code>return cast(uint)(damage * (value &gt; 0 ? value : 0) / 100.0f);</code> | P |
| 97 | type | <code>const(SpellInfo)* casting_;</code> | P |
| 101 | type | <code>const(SpellInfo)* nextSwing;</code> | P |
| 172 | type | <code>void castFromCommand(const(SpellInfo)* spell, CombatWorld world)</code> | P |
| 202 | type | <code>bool castSpell(const(SpellInfo)* spell, ulong target, uint flags)</code> | P |
| 247 | deref | <code>if (isNextMeleeSwingSpell(*spell) &amp;&amp; !triggered</code> | D |
| 248 | deref | <code>? nextWeaponSwingEffect(*spell) &lt; 0</code> | D |
| 249 | deref | <code>: !iota(spell.effect.length).any!(i =&gt; isCreatureTargetEffect(*spell, i)</code> | D |
| 250 | deref | <code>&#124;&#124; creatureAreaShape(*spell, i) != ImplicitTarget.none))</code> | D |
| 284 | deref | <code>if (!triggered &amp;&amp; isNextMeleeSwingSpell(*spell))</code> | D |
| 291 | deref | <code>int time = triggered ? 0 : cast(int)(castTime(*spell, lore.clientData, me.values.get!UNIT_FIELD_LEVEL)</code> | D |
| 357 | type | <code>private bool refusedByCrowdControl(const(SpellInfo)* spell)</code> | P |
| 381 | deref | <code>if (casting_ !is null &amp;&amp; isInterruptible(*casting_))</code> | D |
| 419 | type | <code>private bool paysMana(const(SpellInfo)* spell)</code> | P |
| 425 | type | <code>private int manaCost(const(SpellInfo)* spell)</code> | P |
| 429 | deref | <code>const cost = powerCost(*spell, me.values.get!UNIT_FIELD_LEVEL, me.values.get!UNIT_FIELD_MAXPOWER1,</code> | D |
| 435 | type | <code>private void spendSpellMana(const(SpellInfo)* spell)</code> | P |
| 444 | type | <code>private bool inRangeFor(const(SpellInfo)* spell, ulong target)</code> | P |
| 448 | deref | <code>const r = range(*spell, lore.clientData);</code> | D |
| 500 | type | <code>private ulong[] targetsFor(const(SpellInfo)* spell, size_t i, ulong target)</code> | P |
| 503 | deref | <code>if (spell.casting.chainTarget[i] &gt; 1 &amp;&amp; nextWeaponSwingEffect(*spell) == i)</code> | D |
| 518 | deref | <code>const r = radius(*spell, i, lore.clientData);</code> | D |
| 547 | deref | <code>const r = radius(*spell, i, lore.clientData);</code> | D |
| 570 | deref | <code>auto r = range(*spell, lore.clientData)[1];</code> | D |
| 604 | type | <code>private void go(const(SpellInfo)* spell, ulong target, bool takeMana, bool auraAbsent = false,</code> | P |
| 649 | lookup | <code>if ((!remotePrimary &#124;&#124; guid != target) &amp;&amp; guid !in all)</code> | B |
| 727 | lookup | <code>else if (r.guid in attacked)</code> | B |
| 756 | lookup | <code>if (guid in missed &#124;&#124; (remotePrimary &amp;&amp; guid == target))</code> | B |
| 769 | type | <code>private bool sendCreatureAreaEffects(const(SpellInfo)* spell, ulong target, bool triggered, bool auraAbsent)</code> | P |
| 784 | deref | <code>const shape = creatureAreaShape(*spell, i);</code> | D |
| 791 | deref | <code>const reach = radius(*spell, i, lore.clientData);</code> | D |
| 825 | type | <code>package int effectAmount(const(SpellInfo)* spell, size_t i)</code> | P |
| 827 | deref | <code>int value = levelScaled(spell, i, effectValue(*spell, i, me.values.get!UNIT_FIELD_LEVEL, uniform01(world_.random)));</code> | D |
| 838 | type | <code>package void makePersistentArea(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, int value)</code> | P |
| 851 | type | <code>package void chargeAt(const(SpellInfo)* spell, UnitRef victim)</code> | P |
| 869 | type | <code>package void summonTotem(const(SpellInfo)* spell, size_t i, int value)</code> | P |
| 912 | type | <code>package void weaponSpellDamage(const(SpellInfo)* spell, size_t i, ulong guid, MeleeDamage d, int value)</code> | P |
| 922 | type | <code>private void weaponSpellProcs(const(SpellInfo)* spell, UnitRef target, MeleeHitOutcome outcome, uint damage)</code> | P |
| 926 | deref | <code>procAuras(spellProcFlags(*spell, false, false), target, ProcHit(spell, procExOfSwing(outcome), damage, 0,</code> | D |
| 930 | type | <code>package void remoteWeaponSpellFinished(const(SpellInfo)* spell, UnitRef target, MeleeHitOutcome outcome,</code> | P |
| 941 | type | <code>package void spellDamageTo(const(SpellInfo)* spell, ulong guid, uint damage, int school)</code> | P |
| 956 | type | <code>package void spellDamageDealt(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage)</code> | P |
| 961 | deref | <code>procAuras(spellProcFlags(*spell, false, false), victim, ProcHit(spell, crit ? ProcEx.criticalHit</code> | D |
| 968 | type | <code>package void remoteSpellDamageDealt(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage, bool killed)</code> | P |
| 986 | type | <code>package void auraOn(const(SpellInfo)* spell, size_t i, ulong guid, ubyte effects = 0)</code> | P |
| 999 | type | <code>package void summonBySpell(const(SpellInfo)* spell, size_t i, int value)</code> | P |
| 1009 | deref | <code>const ms = duration(*spell, lore.clientData, me.values.get!UNIT_FIELD_LEVEL);</code> | D |
| 1031 | deref | <code>const effect = nextWeaponSwingEffect(*spell);</code> | D |
| 1086 | type | <code>private bool distributedWeaponSwing(const(SpellInfo)* spell, size_t effect, UnitRef primary,</code> | P |
| 1616 | type | <code>void speak(const(BroadcastText)* text, ulong target)</code> | P |
| 1798 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 1969 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 2063 | lookup | <code>keeper.ai.auraOn(rot in context.data.spells.spells, 0, banker.guid);</code> | A |
| 2066 | lookup | <code>keeper.ai.auraOn(ward in context.data.spells.spells, 0, keeper.guid);</code> | A |
| 2093 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 2119 | lookup | <code>keeper.ai.castSpell(pierce in context.data.spells.spells, anduin.session.character.guid, castTriggered);</code> | A |
| 2150 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |

### `source/dmangos/world/creatureevents.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 74 | deref | <code>const reach = range(*info, lore.clientData)[1];</code> | D |
| 156 | deref | <code>? radius(*lore.spellInfo(spellId), 0, lore.clientData) : 0;</code> | D |
| 303 | type | <code>private int levelScaled(const(imported!"dmangos.world.spells".SpellInfo)* spell, size_t index, int value)</code> | P |
| 307 | deref | <code>if (lore is null &#124;&#124; !scalesWithCreatureLevel(*spell, index))</code> | D |
| 538 | addr | <code>keeper.auras.apply(makeAura(&amp;corruption, anduin.session.character.guid, 60, 18_000, false, [10, 0, 0]),</code> | P |
| 540 | addr | <code>keeper.auras.apply(makeAura(&amp;thrash, keeper.guid, 60, -1, true, [0, 0, 0]), keeper.values, isNew);</code> | P |
| 544 | addr | <code>walkTo(anduin, Position(at.x + 40, at.y, at.z, at.orientation), &amp;tick);</code> | P |
| 565 | addr | <code>walkTo(anduin, Position(-19 + 40, -383, 61, 0), &amp;tick);</code> | P |
| 597 | lookup | <code>assert(keeper.ai.threatOf(healer) == 0 &amp;&amp; (healer in keeper.ai.threatList) is null);</code> | A |
| 606 | lookup | <code>assert((healer in keeper.ai.threatList) !is null, "the healer is in its fight");</code> | A |
| 618 | lookup | <code>assert(keeper.ai.threatOf(hurt) &gt;= 0 &amp;&amp; (hurt in keeper.ai.threatList) !is null);</code> | A |

### `source/dmangos/world/creaturelinking.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 80 | return, type | <code>const(CreatureLink)* linkOf(uint guid, uint entry, uint map) const</code> | R |
| 82 | lookup | <code>if (auto l = guid in bySlaveGuid)</code> | A |
| 84 | lookup | <code>if (auto byMap = entry in bySlaveEntry)</code> | A |
| 85 | deref, lookup | <code>if (auto l = map in *byMap)</code> | A |
| 93 | lookup | <code>return (guid in bySlaveGuid) !is null &#124;&#124; (guid in slavesOfGuid) !is null &#124;&#124; (entry in bySlaveEntry) !is null</code> | A |
| 94 | lookup | <code>&#124;&#124; (entry in slaveEntriesOf) !is null;</code> | A |

### `source/dmangos/world/creatureprocs.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 45 | type | <code>const(SpellInfo)* spell;</code> | P |
| 100 | type | <code>const(SpellInfo)* spell, UnitRef other, bool triggered, bool auraAbsent, int areaEffect = -1,</code> | P |
| 123 | deref | <code>: triggered ? !isTargetedProcEffect(*spell, i) : !isCreatureTargetEffect(*spell, i))</code> | D |
| 125 | deref | <code>const within = range(*spell, context.client)[1];</code> | D |
| 135 | deref | <code>const aura = auraCast(source, spell, remoteTargetAuraEffects(*spell, i));</code> | D |

### `source/dmangos/world/creaturescripting.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 293 | type | <code>private const(SpellInfo)* scriptSpell;</code> | P |
| 296 | type | <code>package void spellEffectScript(const(SpellInfo)* spell, size_t i, ulong target, int value)</code> | P |
| 314 | type | <code>package void spellScriptEvent(E)(const(SpellInfo)* spell, const auto ref E event, CombatWorld world)</code> | P |
| 333 | type | <code>package ulong[] scriptPicked(const(SpellInfo)* spell, size_t i, ulong[] targets)</code> | P |
| 422 | deref | <code>: effectValue(*scriptSpell, effect, me.values.get!UNIT_FIELD_LEVEL, 0.5f);</code> | D |
| 1224 | type | <code>amount = percent &lt;= -100 ? 0 : amount * (100 + percent) / 100.0f;</code> | P |
| 1227 | lookup | <code>if (target.guid !in threat)</code> | B |

### `source/dmangos/world/crowdcontrol.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 175 | lookup | <code>auto fear = makeAura((8122 in context.data.spells.spells), 0, 10, 8000, false, [0, 0, 0]);</code> | A |
| 178 | lookup | <code>assert(session.castSpell((90001 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |

### `source/dmangos/world/database.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 1325 | lookup | <code>if (auto g = item in giftRows)</code> | A |
| 1327 | deref | <code>entry = (*g)[0];</code> | D |
| 1328 | deref | <code>flags = (*g)[1];</code> | D |
| 1360 | lookup | <code>if (quest == 0 &#124;&#124; (guid in questRows &amp;&amp; quest in questRows[guid] &amp;&amp; questRows[guid][quest].rewarded))</code> | A |
| 1404 | lookup | <code>if (auto c = guid in loadable)</code> | A |
| 1425 | lookup | <code>if (auto c = guid in loadable)</code> | A |
| 1438 | lookup | <code>if (auto c = guid in loadable)</code> | A |
| 1449 | lookup | <code>if (auto spells = guid in spellRows)</code> | A |
| 1450 | deref | <code>(*spells).remove(spell);</code> | D |
| 1457 | lookup | <code>else if (auto skills = guid in skillRows)</code> | A |
| 1458 | deref | <code>(*skills).remove(skill);</code> | D |
| 1530 | addr | <code>auto row = &amp;groups[group.id];</code> | P |
| 1532 | deref | <code>*row = cast(GroupRecord) group;</code> | D |
| 1564 | lookup | <code>if (auto c = guid in loadable)</code> | A |
| 1565 | deref | <code>return nullable(*c);</code> | D |
| 1636 | lookup | <code>if (auto g = id in guildRows)</code> | A |
| 1638 | deref | <code>GuildRecord copy = *g;</code> | D |
| 1643 | lookup | <code>if (auto c = m.guid in loadable)</code> | A |
| 1664 | addr | <code>auto g = &amp;guildRows.require(guild.id, GuildRecord.init);</code> | P |
| 1666 | deref | <code>*g = cast(GuildRecord) guild;</code> | D |
| 1673 | lookup | <code>if (auto g = guild in guildRows)</code> | A |
| 1679 | lookup | <code>if (auto g = guild in guildRows)</code> | A |
| 1696 | lookup | <code>if (auto g = guild in guildRows)</code> | A |
| 1703 | lookup | <code>if (auto p = petition in petitionRows)</code> | A |
| 1705 | deref | <code>PetitionRecord copy = *p;</code> | D |
| 1720 | lookup | <code>if (auto p = petition in petitionRows)</code> | A |
| 1761 | lookup | <code>else if (auto rows = player in socialRows)</code> | A |
| 1762 | deref | <code>(*rows).remove(other);</code> | D |
| 1771 | lookup | <code>if (auto r = player in talentResets)</code> | A |
| 1773 | deref | <code>cost = cast(uint)(*r)[0];</code> | D |
| 1774 | deref | <code>time = (*r)[1];</code> | D |
| 1803 | lookup | <code>if (auto p = pet in petRows)</code> | A |
| 1809 | lookup | <code>if (auto p = pet in petRows)</code> | A |
| 1833 | addr | <code>auto record = &amp;honorRows.require(player, HonorRecord.init);</code> | P |
| 1879 | addr | <code>auto r = &amp;honorRows.require(player, HonorRecord.init);</code> | P |
| 1933 | lookup | <code>if (auto m = id in mails)</code> | A |
| 1934 | deref | <code>return Nullable!MailRecord(*m);</code> | D |
| 1956 | lookup | <code>if (auto item = guid in looseItems)</code> | A |
| 1957 | deref | <code>return Nullable!ItemRecord(*item);</code> | D |
| 1962 | lookup | <code>if (auto c = guid in loadable)</code> | A |
| 1969 | lookup | <code>if (auto c = player in corpses)</code> | A |
| 1970 | deref | <code>return Nullable!CorpseRecord(*c);</code> | D |
| 2080 | lookup | <code>if (auto a = id in auctions)</code> | A |
| 2081 | deref | <code>return Nullable!AuctionRecord(*a);</code> | D |
| 2086 | lookup | <code>auto a = id in auctions;</code> | A |
| 2095 | lookup | <code>auto a = id in auctions;</code> | A |
| 2128 | lookup | <code>if (auto c = guid in loadable)</code> | A |
| 2180 | lookup | <code>return (accountId in tutorialRows) !is null;</code> | A |
| 2217 | lookup | <code>if (auto c = guid in loadable)</code> | A |
| 2224 | lookup | <code>return (guid in guildLeaders) !is null;</code> | A |
| 2232 | lookup | <code>auto list = accountId in characterLists;</code> | A |
| 2235 | deref | <code>*list = (*list).filter!(record =&gt; record.guid != guid).array;</code> | D |
| 2241 | lookup | <code>if (auto account = canonicalAccountName(username) in accounts)</code> | A |
| 2242 | deref | <code>return nullable(*account);</code> | D |
| 2248 | lookup | <code>return (accountId in bannedAccounts) !is null &#124;&#124; (ip in bannedAddresses) !is null;</code> | A |

### `source/dmangos/world/dbscripts.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 322 | addr | <code>const step = &amp;run.steps[run.next++];</code> | P |
| 323 | deref | <code>if (runScriptStep(*step, map, run.source, run.target))</code> | D |
| 582 | lookup | <code>const index = spawnGuid in gameObjectSpawnIndex;</code> | A |
| 585 | addr, deref | <code>const spawn = &amp;data.gameObjectSpawns[*index];</code> | P |
| 607 | lookup | <code>const index = spawnGuid in gameObjectSpawnIndex;</code> | A |
| 610 | addr, deref | <code>const spawn = &amp;data.gameObjectSpawns[*index];</code> | P |
| 624 | lookup | <code>if (auto script = map.instanceId in instanceScripts)</code> | A |
| 824 | lookup | <code>const t = step.datalong in data.creatureTemplates;</code> | A |
| 825 | deref | <code>display = t is null ? 0 : chooseDisplay(*t, spawnRandom);</code> | D |

### `source/dmangos/world/death.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 42 | return, type | <code>const(WorldSafeLocsEntry)* closestGraveyard(const WorldData data, const ClientData client, uint map, Position at,</code> | R |
| 45 | return, type | <code>const(WorldSafeLocsEntry)* fromLinks(uint key)</code> | R |
| 48 | type | <code>const(WorldSafeLocsEntry)* near, entrance, far;</code> | P |
| 50 | lookup | <code>const ghost = map in data.ghostEntrances;</code> | A |
| 56 | lookup | <code>if (auto own = link.safeLoc in linkTeams)</code> | A |
| 57 | deref | <code>linkTeam = *own;</code> | D |
| 88 | type | <code>const(WorldSafeLocsEntry)* found;</code> | P |
| 315 | type | <code>const(WorldSafeLocsEntry)* corpseGrave, ghostGrave;</code> | P |
| 366 | lookup | <code>if (const entrance = corpse.map in context.data.ghostEntrances)</code> | A |
| 443 | deref | <code>selfResurrect(spell, i, effectMod(spell, i, effectValue(*spell, i, player.data.level, uniform01(map.random))));</code> | D |
| 447 | type | <code>package void selfResurrect(const(SpellInfo)* spell, size_t i, int value)</code> | P |
| 451 | addr | <code>const v = &amp;player.values;</code> | P |
| 526 | addr | <code>auto v = &amp;player.values;</code> | P |
| 546 | addr | <code>auto v = &amp;player.values;</code> | P |
| 627 | lookup | <code>if (const t = copy.type in context.data.battlegroundTemplates)</code> | A |
| 742 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 770 | lookup | <code>assert(7 in db.corpses &amp;&amp; db.corpses[7].x == fell.x &amp;&amp; me.values.get!UNIT_FIELD_HEALTH == 1);</code> | B |
| 790 | lookup | <code>assert(me.values.get!UNIT_FIELD_HEALTH == me.values.get!UNIT_FIELD_MAXHEALTH / 2 &amp;&amp; 7 !in db.corpses);</code> | B |
| 803 | lookup | <code>assert(me.deathState == DeathState.alive &amp;&amp; 7 !in db.corpses);</code> | B |
| 831 | lookup | <code>assert(innkeeperSpawn in db.creatureRespawns);</code> | B |
| 846 | lookup | <code>assert(innkeeperSpawn !in db.creatureRespawns);</code> | B |
| 917 | lookup | <code>return (guid in viewer.view.fields) !is null;</code> | A |

### `source/dmangos/world/diminishing.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 112 | addr | <code>auto entry = &amp;entries[category];</code> | P |
| 130 | addr | <code>auto entry = &amp;entries[category];</code> | P |

### `source/dmangos/world/duelhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 83 | lookup | <code>if (auto template_ = duelFlagEntry in context.data.gameObjectTemplates)</code> | A |
| 291 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |

### `source/dmangos/world/durability.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 100 | type | <code>package void durabilityDamageEffect(const(imported!"dmangos.world.spells".SpellInfo)* spell, size_t i,</code> | P |

### `source/dmangos/world/effecthandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 63 | addr | <code>auto end = leapDestination(start, 20, &amp;flat, &amp;open);</code> | F |
| 68 | addr | <code>end = leapDestination(start, 20, &amp;flat, &amp;wall);</code> | F |
| 73 | addr | <code>assert(isClose(leapDestination(start, 20, &amp;cliff, &amp;open).x, 8));</code> | F |
| 75 | addr | <code>assert(isClose(leapDestination(start, 20, &amp;rise, &amp;open).x, 12), "too steep to climb");</code> | F |
| 100 | type | <code>private void logExecute(const(SpellInfo)* spell, size_t i, const(ubyte)[] targetData)</code> | P |
| 134 | type | <code>package void threatEffect(const(SpellInfo)* spell, size_t i, ulong target, int value)</code> | P |
| 160 | type | <code>package void attackMeEffect(const(SpellInfo)* spell, size_t i, ulong target)</code> | P |
| 194 | type | <code>package void sanctuaryEffect(const(SpellInfo)* spell, size_t i, ulong target)</code> | P |
| 281 | lookup | <code>if ((player.guid in creature.ai.threatList) !is null)</code> | A |
| 467 | type | <code>package void chargeEffect(const(SpellInfo)* spell, ulong target)</code> | P |
| 512 | type | <code>package void leapEffect(const(SpellInfo)* spell, size_t i)</code> | P |
| 518 | deref | <code>const distance = spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client));</code> | D |
| 534 | addr | <code>const end = leapDestination(player.position, distance, &amp;groundAt, &amp;clear);</code> | F |
| 591 | type | <code>private float multiplier(const(SpellInfo)* spell, size_t i)</code> | P |
| 602 | type | <code>package void healSelf(const(SpellInfo)* spell, uint amount)</code> | P |
| 627 | type | <code>package void distractEffect(const(SpellInfo)* spell, size_t i, ulong target, int value, const ref SpellTargets targets)</code> | P |
| 651 | type | <code>package void summonTrapEffect(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)</code> | P |
| 658 | lookup | <code>const t = entry in context.data.gameObjectTemplates;</code> | A |
| 665 | deref | <code>else if (const r = radius(*spell, i, context.client))</code> | D |
| 682 | deref | <code>const ms = modDuration(spell, duration(*spell, context.client, player.data.level));</code> | D |
| 813 | addr, deref, type | <code>static uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 847 | return, type | <code>SpellInfo* spell(uint id, uint effect, uint target, int value)</code> | R |
| 1060 | lookup | <code>session.addAura(makeAura((net in a.context.data.spells.spells), a.keeper.guid, 60, 10_000, false, [0, 0, 0]));</code> | A |
| 1061 | lookup | <code>session.addAura(makeAura((buff in a.context.data.spells.spells), a.me.guid, 60, 10_000, true, [5, 0, 0]));</code> | A |
| 1083 | lookup | <code>assert((a.me.guid in a.keeper.ai.threatList) is null &amp;&amp; !(a.me.values.get!UNIT_FIELD_FLAGS &amp; UnitFlags.inCombat));</code> | A |
| 1104 | lookup | <code>assert((a.me.guid in a.keeper.ai.threatList) is null &amp;&amp; session.unit.untouchable);</code> | A |
| 1123 | lookup | <code>a.hero.session.inWorld.castSpell((distract in a.context.data.spells.spells), targets, true, 0);</code> | A |
| 1300 | addr | <code>session.addAura(makeAura(&amp;duringCombat, me.guid, 60, -1, true, [30, 0, 0]));</code> | P |
| 1302 | addr | <code>session.addAura(makeAura(&amp;regen, me.guid, 60, -1, true, [100, 0, 0]));</code> | P |
| 1304 | addr | <code>session.addAura(makeAura(&amp;armor, me.guid, 60, -1, true, [3, 0, 0]));</code> | P |
| 1306 | addr | <code>session.addAura(makeAura(&amp;innervate, me.guid, 60, -1, true, [100, 0, 0]));</code> | P |
| 1309 | addr | <code>session.addAura(makeAura(&amp;bloodrage, me.guid, 60, -1, true, [0, 0, 0]));</code> | P |
| 1348 | lookup | <code>assert((a.me.values.get!UNIT_FIELD_FLAGS &amp; UnitFlags.untargetable) &amp;&amp; (a.me.guid in a.keeper.ai.threatList) is null);</code> | A |

### `source/dmangos/world/ekscripttests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 54 | addr | <code>auto him = context.makeCreature(&amp;spawn);</code> | CS |
| 116 | addr | <code>auto him = context.makeCreature(&amp;spawn);</code> | CS |

### `source/dmangos/world/enchanting.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 62 | lookup | <code>if (item is null &#124;&#124; enchantment == 0 &#124;&#124; enchantment !in context.data.enchantmentEffects)</code> | B |
| 130 | addr | <code>auto left = &amp;enchantmentsLeft[guid];</code> | P |
| 131 | deref | <code>*left -= elapsed;</code> | D |
| 132 | deref | <code>if (*left &lt;= Duration.zero)</code> | D |
| 139 | deref | <code>writeEnchantmentTime(item, *left);</code> | D |

### `source/dmangos/world/environment.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 606 | addr | <code>auto breath = &amp;mirrorTimers[MirrorTimerType.breath];</code> | P |

### `source/dmangos/world/eventai.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 269 | type | <code>const(EventAiEvent)* event;</code> | P |
| 455 | addr | <code>holders ~= EventHolder(&amp;e);</code> | P |
| 690 | deref | <code>repeatTimers(*e, min, max);</code> | D |

### `source/dmangos/world/experience.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 149 | type | <code>return seconds * (nextLevelXp * 0.05f / 2 / eightHours) * rate;</code> | P |

### `source/dmangos/world/gameevents.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 233 | lookup | <code>return id &lt;= ushort.max &amp;&amp; (cast(ushort) id in started_) !is null;</code> | R |
| 239 | lookup | <code>return id &lt;= ushort.max &amp;&amp; (cast(ushort) id in active_) !is null;</code> | R |
| 264 | lookup | <code>if (const parent = e.linkedTo in events)</code> | A |
| 266 | lookup | <code>on = on &#124;&#124; (id in started_) !is null;</code> | A |
| 267 | lookup | <code>const was = (id in active_) !is null;</code> | A |

### `source/dmangos/world/gameobject.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 121 | type | <code>const(GameObjectTemplate)* template_;</code> | P |
| 144 | type | <code>this(const ref GameObjectSpawn spawn, const(GameObjectTemplate)* template_)</code> | P |
| 474 | addr | <code>auto go = new GameObject(spawn, &amp;mailbox);</code> | P |

### `source/dmangos/world/gameobjecthandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 179 | addr | <code>return sendGameObjectGossip(go, menu, hasQuests ? &amp;giver : null);</code> | R |
| 292 | type | <code>SpellCastResult canOpenLock(const(SpellInfo)* spell, size_t i, uint lockId, uint castItem, out uint skillId,</code> | P |
| 324 | deref | <code>skillValue = effectValue(*spell, i, rank / 5, 0);</code> | D |
| 336 | type | <code>package SpellCastResult checkGameObjectTarget(const(SpellInfo)* spell, const ref SpellTargets targets,</code> | P |
| 362 | type | <code>package void openLock(const(SpellInfo)* spell, size_t i, ulong target, uint castItem)</code> | P |
| 371 | lookup | <code>if (skillId &amp;&amp; go.loot is null &amp;&amp; player.guid !in go.skilledUp)</code> | B |
| 401 | addr | <code>go.loot.beginQuestLootChecks(map.id, &amp;context.nextGameplaySequence, context.sendQuestLootCheck);</code> | F |
| 417 | type | <code>package void sendGameObjectGossip(GameObject go, uint menuId, const(QuestGiver)* giver)</code> | P |
| 433 | lookup | <code>if (const broadcast = option.broadcastText in npcs.broadcastTexts)</code> | A |
| 435 | lookup | <code>if (const broadcast = option.boxBroadcastText in npcs.broadcastTexts)</code> | A |
| 442 | deref | <code>prepareQuestMenu(*giver);</code> | D |
| 481 | addr | <code>sendGameObjectGossip(go, item.actionMenu, hasQuests ? &amp;giver : null);</code> | P |
| 507 | lookup | <code>const trapTemplate = trapEntry ? trapEntry in context.data.gameObjectTemplates : null;</code> | A |
| 557 | addr | <code>loot.fill(template_, context.data.loot, context.data.items, map.random, &amp;meets, &amp;allowed);</code> | F |
| 727 | deref | <code>with (*context.data.spells.spells.edit(id))</code> | D |
| 761 | addr | <code>gos[i] = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 3 + i]);</code> | GO |
| 819 | addr | <code>auto go = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]);</code> | GO |
| 848 | deref | <code>GameObjectTemplate t = cast() *again.template_;</code> | D |
| 852 | lookup | <code>again.template_ = 9002 in context.data.gameObjectTemplates;</code> | A |
| 885 | addr | <code>auto board = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]);</code> | GO |
| 897 | lookup | <code>assert(9200 in me.questStatus &amp;&amp; me.questStatus[9200].status != QuestState.none, "taken (and done: it asks nothing)");</code> | B |
| 913 | addr | <code>auto stone = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]);</code> | GO |
| 958 | addr | <code>auto go = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]);</code> | GO |
| 986 | addr | <code>linked[i] = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 3 + i]);</code> | GO |

### `source/dmangos/world/gmactions.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 151 | addr | <code>if (player.inventory.canStoreNew(nullBag, nullSlot, dest, entry, count, &amp;noSpace) != InventoryResult.ok)</code> | OPT |

### `source/dmangos/world/gminstance.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 148 | lookup | <code>if (mapId !in binds)</code> | B |
| 299 | lookup | <code>const bound = state.mapId in binds;</code> | A |
| 304 | deref | <code>if (bound !is null &amp;&amp; *bound == id)</code> | D |
| 315 | deref | <code>if (bound is null &#124;&#124; *bound != id)</code> | D |

### `source/dmangos/world/gmlevel0.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 199 | addr | <code>auto values = target !is null ? &amp;target.player.values : &amp;creature.values;</code> | P |

### `source/dmangos/world/gmlevel1.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 52 | lookup | <code>const item = entry in context.data.items;</code> | A |
| 199 | lookup | <code>const item = itemId in context.data.items;</code> | A |

### `source/dmangos/world/gmlevel2.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 88 | lookup | <code>if (const proto = item in context.data.items)</code> | A |
| 91 | addr | <code>auto list = &amp;context.data.npcs.vendors.require(entry, null);</code> | P |
| 93 | deref | <code>*list ~= VendorItem(item, 0, 0, slot, 0);</code> | D |
| 125 | lookup | <code>auto list = entry in context.data.npcs.vendors;</code> | A |
| 126 | deref | <code>const at = list is null ? -1 : (*list).countUntil!(v =&gt; v.item == item);</code> | D |
| 130 | deref | <code>*list = (*list).remove(at);</code> | D |
| 132 | lookup | <code>if (const proto = item in context.data.items)</code> | A |
| 241 | addr | <code>const v = &amp;go.values;</code> | P |
| 276 | addr | <code>auto v = &amp;go.values;</code> | P |
| 320 | lookup | <code>if (entryId !in context.data.gameObjectTemplates)</code> | B |
| 543 | addr | <code>auto values = &amp;target.player.values;</code> | P |
| 563 | addr | <code>auto values = plr !is null ? &amp;plr.player.values : &amp;creature.values;</code> | P |
| 668 | return, type | <code>const(SpellInfo)* spellNamed(string args, out uint id)</code> | R |
| 1067 | addr | <code>auto go = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]);</code> | GO |

### `source/dmangos/world/gmlevel3.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 232 | lookup | <code>if (const gm = t.id in context.ticketAssignedTo)</code> | A |
| 234 | deref | <code>if (auto aplr = cast(typeof(this)) context.onlinePlayer(*gm))</code> | D |
| 238 | deref | <code>const info = context.database.nameInfo(cast(uint) *gm);</code> | D |
| 662 | addr | <code>auto values = &amp;plr.player.values;</code> | P |
| 1250 | type | <code>bool toggleCheat(Nullable!OnOff state, string name, string logLine, bool* delegate(Character) flag,</code> | P |
| 1258 | deref | <code>state = *on ? OnOff.off : OnOff.on;</code> | D |
| 1261 | deref | <code>*on = true;</code> | D |
| 1269 | deref | <code>*on = false;</code> | D |
| 1280 | addr | <code>return toggleCheat(state, "cast time", "god cast time", (Character p) =&gt; &amp;p.castTimeCheat);</code> | R |
| 1286 | addr | <code>return toggleCheat(state, "cooldown", "cooldown cheat", (Character p) =&gt; &amp;p.cooldownCheat,</code> | R |
| 1295 | addr | <code>return toggleCheat(state, "god mode", "god mode cheat", (Character p) =&gt; &amp;p.godModeCheat);</code> | R |
| 1300 | addr | <code>return toggleCheat(state, "power", "power cheat", (Character p) =&gt; &amp;p.powerCheat);</code> | R |
| 1305 | addr | <code>return toggleCheat(state, "triggerpass", "triggerpass cheat", (Character p) =&gt; &amp;p.triggerpassCheat);</code> | R |
| 1705 | lookup | <code>if (const item = itemId in context.data.items)</code> | A |
| 1996 | lookup | <code>const item = row.id in context.data.items;</code> | A |
| 2016 | lookup | <code>const t = entry in context.data.creatureTemplates;</code> | A |
| 2182 | addr | <code>auto v = &amp;crt.values;</code> | P |
| 2332 | lookup | <code>anduin.session.inWorld.addAura(makeAura((sickness in context.data.spells.spells), victim.guid, 1, 600_000, false, [-75, 0, 0]));</code> | A |

### `source/dmangos/world/gmquest.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 36 | lookup | <code>const q = id in plr.player.questStatus;</code> | A |
| 88 | deref | <code>plr.addQuest(*quest);</code> | D |
| 144 | deref | <code>plr.rewardQuestReputation(*quest);</code> | D |
| 149 | deref | <code>plr.gmFinishQuest(*quest);</code> | D |
| 176 | deref | <code>plr.gmDropQuest(*quest);</code> | D |
| 208 | lookup | <code>if (const t = creatureId in context.data.creatureTemplates)</code> | A |
| 229 | lookup | <code>if (const t = objectId in context.data.gameObjectTemplates)</code> | A |
| 261 | lookup | <code>const proto = item in context.data.items;</code> | A |
| 298 | lookup | <code>if (entry !in context.data.quests.creatureStarts &amp;&amp; entry !in context.data.quests.creatureEnds)</code> | B |
| 332 | lookup | <code>const starts = questGiver in context.data.quests.creatureStarts;</code> | A |
| 338 | deref | <code>foreach (id; *starts)</code> | D |
| 378 | addr | <code>auto relations = start ? &amp;context.data.quests.creatureStarts : &amp;context.data.quests.creatureEnds;</code> | P |
| 379 | addr, deref | <code>auto list = &amp;(*relations).require(entry, null);</code> | P |
| 380 | deref | <code>const known = (*list).canFind(questId);</code> | D |
| 388 | deref | <code>*list ~= questId;</code> | D |
| 400 | deref | <code>*list = (*list).remove((*list).countUntil(questId));</code> | D |
| 458 | lookup | <code>const t = starterId in context.data.creatureTemplates;</code> | A |
| 489 | lookup | <code>if (item !in context.data.items)</code> | B |
| 499 | lookup | <code>if (item !in context.data.items)</code> | B |
| 539 | addr | <code>auto q = &amp;statusOf(id);</code> | P |
| 554 | addr | <code>auto q = &amp;statusOf(quest.id);</code> | P |

### `source/dmangos/world/gmtargets.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 58 | addr | <code>return GmSink(&amp;systemMessage);</code> | R |

### `source/dmangos/world/group.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 378 | lookup | <code>return (guid in invitees) !is null;</code> | A |
| 418 | lookup | <code>if (auto group = guid in owner.invitedTo)</code> | A |
| 419 | deref | <code>if (*group is this)</code> | D |
| 934 | lookup | <code>const first = a in memberOf, second = b in memberOf;</code> | A |
| 935 | deref | <code>return first !is null &amp;&amp; second !is null &amp;&amp; *first is *second;</code> | R |
| 1027 | lookup | <code>if (guid in seen)</code> | B |
| 1132 | lookup | <code>if (auto p = guid in players)</code> | A |
| 1205 | lookup | <code>assert(groups.of(1) is null &amp;&amp; groups.of(2) is null &amp;&amp; 10 !in db.groups &amp;&amp; groups.count == 0);</code> | B |
| 1218 | lookup | <code>assert(groups.count == 1 &amp;&amp; groups.of(makeGuid(HighGuid.player, 2)).id == 5 &amp;&amp; 6 !in db.groups);</code> | B |

### `source/dmangos/world/groupservice.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 259 | deref | <code>MeetingStoneQueue.fillRoles(*party, classesOf(group));</code> | D |

### `source/dmangos/world/guardians.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 97 | type | <code>package void summonGuardianEffect(const(SpellInfo)* spell, size_t i, int value, const ref SpellTargets targets,</code> | P |
| 103 | lookup | <code>const t = entry in context.data.creatureTemplates;</code> | A |
| 123 | lookup | <code>const item = castItemEntry ? castItemEntry in context.data.items : null;</code> | A |
| 129 | deref | <code>const ms = modDuration(spell, duration(*spell, context.client, player.data.level));</code> | D |
| 131 | deref | <code>const spread = radius(*spell, i, context.client);</code> | D |
| 165 | type | <code>private void makeGuardian(const(SpellInfo)* spell, uint entry, Position at, uint level, int ms)</code> | P |
| 173 | addr | <code>auto v = &amp;g.values;</code> | P |
| 236 | type | <code>package void summonWildObjectEffect(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)</code> | P |

### `source/dmangos/world/guild.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 127 | return, type | <code>inout(GuildMemberRecord)* member(uint guid) inout</code> | R |
| 131 | addr | <code>return &amp;m;</code> | R |
| 136 | return, type | <code>inout(GuildMemberRecord)* memberNamed(string name) inout</code> | R |
| 141 | addr | <code>return &amp;m;</code> | R |
| 285 | lookup | <code>if (auto g = id in byId)</code> | A |
| 316 | lookup | <code>if (const id = toLower(name) in byName)</code> | A |
| 317 | deref | <code>return byId.get(*id, null);</code> | D |
| 324 | lookup | <code>if (const id = member in memberOf)</code> | A |
| 325 | deref | <code>return byId.get(*id, null);</code> | D |

### `source/dmangos/world/guildhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 327 | lookup | <code>if (guildCharter !in context.data.items)</code> | B |
| 608 | type | <code>GuildMemberRecord* best;</code> | P |
| 611 | addr | <code>best = &amp;m;</code> | P |
| 1008 | type | <code>bool got(TestClient* c, Opcode opcode)</code> | P |
| 1025 | addr | <code>assert(got(&amp;jaina, Opcode.SMSG_GUILD_INVITE));</code> | P |
| 1029 | addr | <code>assert(got(&amp;anduin, Opcode.SMSG_GUILD_EVENT), "Anduin hears she joined");</code> | P |
| 1034 | addr | <code>assert(got(&amp;anduin, Opcode.SMSG_MESSAGECHAT) &amp;&amp; got(&amp;jaina, Opcode.SMSG_MESSAGECHAT));</code> | P |
| 1037 | addr | <code>assert(!got(&amp;anduin, Opcode.SMSG_MESSAGECHAT));</code> | P |
| 1040 | addr | <code>assert(g.motd == "Raid tonight" &amp;&amp; db.loadGuild(g.id).get.motd == "Raid tonight" &amp;&amp; got(&amp;jaina, Opcode.SMSG_GUILD_EVENT));</code> | P |
| 1049 | addr | <code>assert(g.member(8).rank == GuildRank.initiate &amp;&amp; got(&amp;jaina, Opcode.SMSG_GUILD_COMMAND_RESULT), "no right");</code> | P |
| 1112 | addr | <code>auto npc = context.makeCreature(&amp;spawn);</code> | CS |
| 1119 | type | <code>bool got(TestClient* c, Opcode opcode, out const(ubyte)[] body_)</code> | P |
| 1132 | addr | <code>assert(got(&amp;varian, Opcode.SMSG_PETITION_SHOWLIST, b) &amp;&amp; b[9 .. 13] == [0x01, 0, 0, 0]);</code> | P |
| 1164 | addr | <code>assert(got(&amp;jaina, Opcode.SMSG_PETITION_SIGN_RESULTS, b) &amp;&amp; b[16] == petitionSignOk);</code> | P |
| 1167 | addr | <code>assert(got(&amp;jaina, Opcode.SMSG_PETITION_SIGN_RESULTS, b) &amp;&amp; b[16] == petitionSignAlreadySigned, "once");</code> | P |
| 1171 | addr | <code>assert(got(&amp;varian, Opcode.SMSG_TURN_IN_PETITION_RESULTS, b) &amp;&amp; b[0] == petitionTurnNeedMoreSignatures);</code> | P |

### `source/dmangos/world/honor.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 239 | type | <code>return full * (10 - killsToday) / 10 / (groupSize ? groupSize : 1);</code> | P |
| 567 | addr | <code>auto v = &amp;player.values;</code> | P |
| 682 | addr | <code>const v = &amp;other.player.values;</code> | P |

### `source/dmangos/world/inventory.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 226 | type | <code>bool itemCanGoIntoBag(const(ItemTemplate)* proto, const(ItemTemplate)* bag) pure nothrow @nogc @safe</code> | P |
| 251 | type | <code>bool canChangeEquipStateInCombat(const(ItemTemplate)* proto) pure nothrow @nogc @safe</code> | P |
| 263 | type | <code>uint itemSkill(const(ItemTemplate)* proto) pure nothrow @nogc @safe</code> | P |
| 318 | type | <code>const(ItemTemplate)* proto;</code> | P |
| 336 | lookup | <code>if (const enchantments = property in world.propertyEnchantments)</code> | A |
| 337 | deref | <code>foreach (i, enchantment; *enchantments)</code> | D |
| 350 | type | <code>void changeEntry(const(ItemTemplate)* to)</code> | P |
| 358 | type | <code>this(uint guid, const(ItemTemplate)* proto, ulong owner)</code> | P |
| 386 | type | <code>static Item load(const ref ItemRecord record, const(ItemTemplate)* proto, ulong owner)</code> | P |
| 389 | addr | <code>auto v = &amp;item.values;</code> | P |
| 500 | type | <code>InventoryResult canBeMergedPartlyWith(const(ItemTemplate)* other) const</code> | P |
| 689 | type | <code>UpdateValues* fields;</code> | O |
| 710 | type | <code>this(const WorldData world, InventoryOwner owner, UpdateValues* fields, uint delegate() nextGuid)</code> | O |
| 715 | retained | <code>this.fields = fields;</code> | O |
| 880 | lookup | <code>const proto = entry in world.items;</code> | A |
| 899 | lookup | <code>const proto = record.entry in world.items;</code> | A |
| 935 | type | <code>InventoryResult canUse(const(ItemTemplate)* proto, bool directAction = true) const</code> | P |
| 990 | lookup | <code>const proto = entry in world.items;</code> | A |
| 999 | type | <code>bool viableEquipSlots(const(ItemTemplate)* proto, ref ubyte[4] viable) const</code> | P |
| 1048 | type | <code>ubyte findEquipSlot(const(ItemTemplate)* proto, ubyte slot, bool swap) const</code> | P |
| 1078 | type | <code>InventoryResult canTakeMoreSimilar(uint entry, uint count, const Item skip, uint* noSpace = null) const</code> | OPT |
| 1080 | lookup | <code>const proto = entry in world.items;</code> | A |
| 1084 | deref | <code>*noSpace = count;</code> | D |
| 1093 | deref | <code>*noSpace = count + current - proto.maxCount;</code> | D |
| 1102 | type | <code>uint* noSpace = null) const</code> | OPT |
| 1122 | type | <code>const Item source, bool swap, ref ubyte bagSlot, uint* noSpace) const</code> | OPT |
| 1124 | lookup | <code>const proto = entry in world.items;</code> | A |
| 1128 | deref | <code>*noSpace = left;</code> | D |
| 1138 | addr | <code>if (const result = canTakeMoreSimilar(entry, count, source, &amp;noSimilar))</code> | P |
| 2092 | type | <code>static bool bindsWhenStored(const(ItemTemplate)* proto, ushort pos)</code> | P |
| 2170 | type | <code>InventoryResult storeInSpecificSlot(ubyte bag, ubyte slot, ref ItemPosCount[] dest, const(ItemTemplate)* proto,</code> | P |
| 2217 | type | <code>InventoryResult storeInBag(ubyte bag, ref ItemPosCount[] dest, const(ItemTemplate)* proto, ref uint count,</code> | P |
| 2249 | type | <code>InventoryResult storeInSlots(ubyte begin, ubyte end, ref ItemPosCount[] dest, const(ItemTemplate)* proto,</code> | P |
| 2263 | type | <code>static bool fillSlot(const Item occupant, ushort pos, ref ItemPosCount[] dest, const(ItemTemplate)* proto,</code> | P |
| 2320 | type | <code>private Inventory testInventory(WorldData world, out UpdateValues* fields)</code> | O |
| 2322 | retained | <code>fields = new UpdateValues(TypeId.player);</code> | VEC |
| 2332 | retained | <code>auto inventory = new Inventory(world, owner, new UpdateValues(TypeId.player), testItemGuids());</code> | VEC |
| 2381 | addr | <code>assert(inventory.canStoreNew(nullBag, nullSlot, dest, itemShirt, 1, &amp;noSpace) == InventoryResult.inventoryFull);</code> | OPT |
| 2385 | addr | <code>assert(inventory.canStoreNew(nullBag, nullSlot, dest, itemJerky, 30, &amp;noSpace) == InventoryResult.inventoryFull);</code> | OPT |

### `source/dmangos/world/inworld.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 203 | deref | <code>&amp;&amp; isPlayerHandoffSpell(*spell);</code> | D |
| 226 | deref | <code>return spell !is null &amp;&amp; isPlayerHandoffSpell(*spell);</code> | R |
| 810 | lookup | <code>if (const p = page in context.data.pageTexts)</code> | A |
| 844 | lookup | <code>send(ServerItemQueryResponse(itemQueryResponse(request.entry, request.entry in context.data.items,</code> | A |
| 852 | lookup | <code>request.entry in context.data.creatureTemplates)));</code> | A |
| 859 | lookup | <code>request.entry in context.data.gameObjectTemplates)));</code> | A |
| 1088 | lookup | <code>const item = entry in context.data.items;</code> | A |
| 1442 | addr | <code>account.level, config.allowTwoSideWhoList, config.gmLevelInWhoList, config.maxWhoListReturns, &amp;areaName));</code> | F |
| 1479 | lookup | <code>return (sender in gmTargets) !is null;</code> | A |
| 1616 | lookup | <code>assert(client.session.state == WorldState.inWorld &amp;&amp; (7 in db.online) !is null);</code> | A |
| 1676 | lookup | <code>assert(client.session.state == WorldState.characterScreen &amp;&amp; (7 in db.online) is null);</code> | A |
| 1684 | lookup | <code>assert(db.progressSaves.length == 2 &amp;&amp; (7 in db.online) is null);</code> | A |

### `source/dmangos/world/itemhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 57 | lookup | <code>const proto = error.item !is null ? error.item.proto : error.itemId in context.data.items;</code> | A |
| 220 | lookup | <code>const to = wrapped in context.data.items;</code> | A |
| 597 | lookup | <code>const proto = entry in context.data.items;</code> | A |
| 610 | deref | <code>if (!canSeeVendorItem(vendor, ware, *proto))</code> | D |
| 781 | addr | <code>raceHuman, 0, 1, &amp;setup);</code> | F |
| 823 | lookup | <code>assert(character.money == Copper(954) &amp;&amp; fourGuid !in db.itemRows &amp;&amp; db.moneySaves[7][0] == 954);</code> | B |
| 836 | lookup | <code>assert(inventory[bag0, 24] is null &amp;&amp; jerkyGuid !in db.itemRows);</code> | B |
| 866 | addr | <code>raceHuman, 0, 1, &amp;setup);</code> | F |
| 931 | addr | <code>raceHuman, 0, 1, &amp;setup);</code> | F |
| 955 | lookup | <code>assert(500 !in db.giftRows &amp;&amp; db.itemRows[500].entry == itemSword);</code> | B |

### `source/dmangos/world/itemtests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 72 | deref | <code>with (*context.data.spells.spells.edit(smith))</code> | D |
| 96 | addr | <code>map.addObject(context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]));</code> | GO |
| 100 | addr | <code>map.addObject(context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]));</code> | GO |
| 183 | deref | <code>with (*context.data.spells.spells.edit(pickLock))</code> | D |
| 265 | deref | <code>with (*context.data.items.edit(itemJerky))</code> | D |
| 313 | deref | <code>with (*context.data.items.edit(itemShirt))</code> | D |
| 362 | deref | <code>with (*context.data.spells.spells.edit(spellId))</code> | D |

### `source/dmangos/world/itemuse.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 127 | lookup | <code>if (const proto = entry in context.data.items)</code> | A |
| 166 | type | <code>package uint cooldownCategoryOf(const(SpellInfo)* spell, uint itemEntry)</code> | P |
| 169 | lookup | <code>if (const proto = itemEntry in context.data.items)</code> | A |
| 236 | lookup | <code>const running = (spell.id in spellReadyAt &amp;&amp; spellReadyAt[spell.id] &gt; now)</code> | A |
| 237 | lookup | <code>&#124;&#124; (spell.category &amp;&amp; spell.category in categoryReadyAt &amp;&amp; categoryReadyAt[spell.category] &gt; now);</code> | A |
| 308 | lookup | <code>if (item.fullGuid !in timedItems &amp;&amp; player.inventory.byGuid(item.fullGuid) is item)</code> | B |

### `source/dmangos/world/loot.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 67 | addr | <code>auto group = &amp;groups[item.group - 1];</code> | P |
| 112 | lookup | <code>if (auto found = id in templates)</code> | A |
| 113 | deref | <code>return *found;</code> | D |
| 306 | lookup | <code>if (player !in allowed &#124;&#124; (quest &amp;&amp; player in loot.pendingQuestLoot))</code> | B |
| 451 | lookup | <code>if (masterLooter == 0 &#124;&#124; masterLooter !in item.allowed)</code> | B |
| 459 | lookup | <code>item.currentLooterPass = currentLooter != 0 &amp;&amp; currentLooter !in item.allowed;</code> | B |
| 492 | lookup | <code>item.currentLooterPass = currentLooter !in item.allowed;</code> | B |
| 513 | lookup | <code>if (item.quest &amp;&amp; guid in item.allowed &amp;&amp; !needs(item))</code> | A |
| 525 | lookup | <code>if (reply.sequence != questCheckSequence &#124;&#124; reply.player !in pendingQuestLoot</code> | B |
| 564 | lookup | <code>item.currentLooterPass = currentLooter !in item.allowed;</code> | B |
| 607 | deref | <code>add(*chosen, protos, random);</code> | D |
| 615 | return, type | <code>private const(LootStoreItem)* rollGroup(ref const LootGroup group, ref Random random, bool delegate(uint) meets)</code> | L |
| 621 | type | <code>auto order = new const(LootStoreItem)*[group.explicitlyChanced.length];</code> | T |
| 623 | addr | <code>order[i] = &amp;entry;</code> | T |
| 639 | type | <code>auto order = new const(LootStoreItem)*[group.equalChanced.length];</code> | T |
| 641 | addr | <code>order[i] = &amp;entry;</code> | T |
| 670 | lookup | <code>if (const proto = entry.item in protos)</code> | A |
| 717 | lookup | <code>if (gold &amp;&amp; player in owners)</code> | A |
| 747 | lookup | <code>if (guid in item.allowed)</code> | B |
| 751 | lookup | <code>if (item.winner &amp;&amp; item.winner in item.allowed)</code> | A |
| 774 | lookup | <code>if (item.winner == player &amp;&amp; !item.blocked &amp;&amp; player in item.allowed)</code> | A |
| 779 | lookup | <code>if (player !in owners &amp;&amp; !(remoteTurns &amp;&amp; player in remoteMembers))</code> | B |
| 867 | lookup | <code>w.put(player in owners ? gold : 0u);</code> | A |
| 1028 | lookup | <code>if (gold == 0 &#124;&#124; looter.looterGuid !in owners)</code> | B |
| 1048 | lookup | <code>if (guid !in owners)</code> | B |
| 1094 | lookup | <code>if (guid in looking)</code> | B |
| 1122 | lookup | <code>if (!item.blocked &#124;&#124; item.slot in rolls &#124;&#124; guid !in item.allowed)</code> | B |
| 1141 | lookup | <code>if (guid !in owners &#124;&#124; find(guid) is null)</code> | B |
| 1182 | lookup | <code>auto roll = cast(ubyte) slot in rolls;</code> | A |
| 1185 | deref | <code>if ((*roll).vote(player.looterGuid, choice) &amp;&amp; (*roll).update(nowSeconds()))</code> | D |
| 1194 | lookup | <code>auto roll = message.slot in rolls;</code> | A |
| 1195 | deref | <code>if (roll is null &#124;&#124; (*roll).serial != message.roll &#124;&#124; !message.roll)</code> | D |
| 1197 | deref | <code>if ((*roll).vote(message.player, cast(RollVote) message.choice) &amp;&amp; (*roll).update(nowSeconds()))</code> | D |
| 1234 | lookup | <code>if (loot.find(guid) is null &#124;&#124; guid !in item.allowed)</code> | B |
| 1246 | lookup | <code>if (guid !in votes)</code> | B |
| 1298 | lookup | <code>else if (const node = guid in loot.remoteMembers)</code> | A |
| 1299 | deref | <code>loot.tellRemoteRoller(*node, guid, opcode, body_);</code> | D |
| 1313 | lookup | <code>else if (const node = guid in loot.remoteMembers)</code> | A |
| 1316 | deref | <code>if (!loot.sendRemoteRoll(*node, message))</code> | D |
| 1344 | lookup | <code>auto v = player in votes;</code> | A |
| 1469 | lookup | <code>else if (const node = winner in loot.remoteMembers)</code> | A |
| 1474 | deref | <code>if (!loot.sendRemoteRoll(*node, message))</code> | D |
| 1599 | lookup | <code>assert(count.get(100, 0) == 1 &amp;&amp; 101 !in count);</code> | B |

### `source/dmangos/world/loothandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 51 | lookup | <code>if (auto loot = guid in itemLoots)</code> | A |
| 52 | deref | <code>return *loot;</code> | D |
| 73 | lookup | <code>const proto = item.entry in context.data.items;</code> | A |
| 92 | lookup | <code>const inside = context.database.loadGift(item.guid, entry, flags) ? entry in context.data.items : null;</code> | A |
| 153 | addr | <code>loot.fill(template_, context.data.loot, context.data.items, map.random, &amp;meets, &amp;allowed);</code> | F |
| 290 | addr | <code>loot.checkMasterConditions(&amp;conditionMet);</code> | F |
| 322 | lookup | <code>if ((request.target in item.allowed &#124;&#124; request.target in loot.remoteMembers)</code> | A |
| 345 | lookup | <code>if (auto offer = RemoteLootKey(request.loot, request.slot) in remoteLootOffers)</code> | A |
| 346 | deref | <code>voteOnRemoteLoot(*offer, cast(RollVote) request.vote);</code> | D |
| 389 | lookup | <code>if (auto previous = key in remoteLootOffers)</code> | A |
| 403 | lookup | <code>auto offer = RemoteLootKey(message.loot, message.slot) in remoteLootOffers;</code> | A |
| 562 | addr | <code>highest = &amp;m;</code> | P |
| 565 | addr | <code>highestNotGray = &amp;m;</code> | P |
| 714 | addr | <code>loot.fill(template_, context.data.loot, context.data.items, map.random, &amp;meets, &amp;allowed);</code> | F |
| 728 | addr | <code>loot.beginQuestLootChecks(theMap.id, &amp;context.nextGameplaySequence, context.sendQuestLootCheck);</code> | F |
| 802 | lookup | <code>loot.masterStartsRemote = crossNodeMaster &amp;&amp; group.looter in loot.remoteMembers;</code> | A |
| 805 | lookup | <code>if (group.looter !in loot.owners)</code> | B |
| 812 | addr | <code>loot.nextRoll = &amp;context.nextGameplaySequence;</code> | F |
| 914 | lookup | <code>const proto = entry in context.data.items;</code> | A |
| 1069 | lookup | <code>assert(me.skillValue(162)[0] &gt; unarmedBefore &amp;&amp; 162 in db.skillRows.get(7, null), "unarmed skill gained and saved");</code> | A |
| 1643 | addr | <code>characterLevel: scenario == Scenario.masterFailsCondition ? 10 : 1, setup: &amp;teachGathering);</code> | F |
| 1644 | addr | <code>auto jaina = loggedIn(masterNode, db, 8, "Jaina", masterAt, setup: &amp;teachGathering);</code> | F |
| 1681 | addr | <code>auto chest = lootNode.makeGameObject(&amp;lootNode.data.gameObjectSpawns[$ - 1]);</code> | GO |
| 1823 | deref | <code>with (*corpseNode.data.creatureTemplates.edit(creatureInnkeeper))</code> | D |
| 1936 | lookup | <code>assert(jaina.session.character.inventory.count(itemJerky) == 0 &amp;&amp; 7UL in loot.itemInSlot(0).allowed);</code> | A |

### `source/dmangos/world/mailhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 181 | return, type | <code>MailRecord* deliveredMail(uint id)</code> | R |
| 187 | deref | <code>*mail = found.get;</code> | D |
| 224 | lookup | <code>const proto = has ? item.get.entry in context.data.items : null;</code> | A |
| 253 | deref | <code>context.database.updateMail(*mail);</code> | D |
| 270 | lookup | <code>const proto = record.isNull ? null : record.get.entry in context.data.items;</code> | A |
| 295 | deref | <code>context.database.updateMail(*mail);</code> | D |
| 314 | deref | <code>context.database.updateMail(*mail);</code> | D |
| 384 | deref | <code>context.database.updateMail(*mail);</code> | D |
| 546 | lookup | <code>assert(ids[0] !in db.mails);</code> | B |

### `source/dmangos/world/main.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 52 | addr | <code>options = getopt(args, "config&#124;c", "Configuration file (default: worldserver.json)", &amp;configPath);</code> | J |
| 209 | addr | <code>cluster = new ClusterNode(config.cluster, ClusterNode.newIncarnation(), &amp;clusterClock,</code> | F |
| 215 | addr | <code>cluster.onOwnership = &amp;context.regionsChanged;</code> | F |
| 216 | addr | <code>cluster.onCreatureRelease = &amp;context.releaseCreatureLoan;</code> | F |
| 217 | addr | <code>context.sendCreatureLoan = &amp;cluster.creatureLoan;</code> | F |
| 218 | addr | <code>context.creatureLease = &amp;cluster.regions.creatureRegion;</code> | F |
| 227 | addr | <code>context.whisperRemote = &amp;bridge.whisperRemote;</code> | F |
| 228 | addr | <code>context.deliverRemote = &amp;bridge.deliverRemote;</code> | F |
| 229 | addr | <code>context.requestMemberStats = &amp;bridge.requestMemberStats;</code> | F |
| 230 | addr | <code>context.toEveryoneElsewhere = &amp;bridge.toEveryoneElsewhere;</code> | F |
| 231 | addr | <code>context.gmRemote = &amp;bridge.sendGmRemote;</code> | F |
| 232 | addr | <code>context.killShareElsewhere = &amp;bridge.sendKillShare;</code> | F |
| 233 | addr | <code>context.sendRemoteGroupLoot = &amp;bridge.sendGroupLootRoll;</code> | F |
| 234 | addr | <code>context.canSendLootCoins = &amp;bridge.canSendLootCoins;</code> | F |
| 235 | addr | <code>context.sendRemoteLootCoins = &amp;bridge.sendLootCoinShare;</code> | F |
| 236 | addr | <code>context.sendQuestLootCheck = &amp;bridge.sendQuestLootCheck;</code> | F |
| 237 | addr | <code>context.sendPartyHeal = &amp;bridge.sendPartyHeal;</code> | F |
| 238 | addr | <code>context.sendAreaDamage = &amp;bridge.sendAreaDamage;</code> | F |
| 239 | addr | <code>context.sendCreatureSwing = &amp;bridge.sendCreatureSwing;</code> | F |
| 240 | addr | <code>context.sendPeriodicResult = &amp;bridge.sendPeriodicResult;</code> | F |
| 241 | addr | <code>context.signalElsewhere = &amp;bridge.sendScriptSignal;</code> | F |
| 242 | addr | <code>context.askDungeonEntry = &amp;bridge.askDungeonEntry;</code> | F |
| 243 | addr | <code>context.announceFriendElsewhere = &amp;bridge.announceFriend;</code> | F |
| 244 | addr | <code>context.guildReloadElsewhere = &amp;bridge.sendGuildReload;</code> | F |
| 245 | addr | <code>context.guildBroadcastElsewhere = &amp;bridge.sendGuildBroadcast;</code> | F |
| 246 | addr | <code>context.guildInviteElsewhere = &amp;bridge.sendGuildInvitation;</code> | F |
| 249 | addr | <code>context.groups.changes = &amp;bridge.groupChanged;</code> | F |
| 250 | addr | <code>context.groups.removed = &amp;bridge.groupRemoved;</code> | F |
| 254 | addr | <code>context.forwardGroup = &amp;bridge.forwardGroup;</code> | F |
| 256 | addr | <code>context.reserveStock = &amp;bridge.reserveStock;</code> | F |
| 257 | addr | <code>context.releaseStock = &amp;bridge.releaseStock;</code> | F |
| 322 | addr | <code>context.groups.changes = &amp;bridge.groupChanged;</code> | F |
| 323 | addr | <code>context.groups.removed = &amp;bridge.groupRemoved;</code> | F |
| 336 | addr | <code>context.forwardGroup = &amp;bridge.forwardGroup;</code> | F |
| 384 | addr | <code>metrics.report(&amp;server.busy), context.sessionCount, context.objectCount, context.tickingCount,</code> | P |

### `source/dmangos/world/map.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 546 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 547 | addr | <code>auto list = &amp;cellLists.require(key);</code> | P |
| 564 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 567 | lookup | <code>auto list = e.cell in cellLists;</code> | A |
| 568 | addr | <code>auto members = e.player !is null ? &amp;list.players : &amp;list.objects;</code> | P |
| 569 | deref | <code>const i = e.cellIndex, last = (*members)[$ - 1];</code> | D |
| 570 | deref | <code>(*members)[i] = last;</code> | D |
| 572 | deref | <code>(*members).length -= 1;</code> | D |
| 573 | deref | <code>(*members).assumeSafeAppend();</code> | D |
| 689 | addr | <code>own.addValues(object.guid, object.fields, seenByEveryone, &amp;view.adjust);</code> | F |
| 752 | addr | <code>own.addSlots(object.guid, object.fields, personal.personalSlots, &amp;view.adjust);</code> | F |
| 830 | lookup | <code>if (const list = key in cellLists)</code> | A |
| 831 | deref | <code>look(key, *list);</code> | D |
| 847 | lookup | <code>if (spawner is null &#124;&#124; key in loadedCells &#124;&#124; (owns !is null &amp;&amp; !owns(key)))</code> | A |
| 874 | lookup | <code>if (cell in localInterest &#124;&#124; cell in peerCells)</code> | B |
| 879 | addr | <code>auto idle = &amp;idleMs.require(cell, 0);</code> | P |
| 880 | deref | <code>*idle += elapsedMs;</code> | D |
| 881 | deref | <code>if (*idle &gt;= settings.unloadIdleMs)</code> | D |
| 890 | lookup | <code>if (e.home == noCell &#124;&#124; e.home !in due)</code> | B |
| 899 | lookup | <code>&#124;&#124; e.cell in localInterest &#124;&#124; e.cell in peerCells))</code> | A |
| 908 | lookup | <code>if (auto gone = cell in homed)</code> | A |
| 909 | deref | <code>forget(*gone);</code> | D |
| 940 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 982 | lookup | <code>return (key in loadedCells) !is null;</code> | A |
| 1167 | lookup | <code>if (at(slot).viewers.length == 0 &amp;&amp; (replicator is null &#124;&#124; at(slot).cell !in localInterest))</code> | B |
| 1171 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 1205 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 1232 | lookup | <code>if (other.character.guid !in knows)</code> | B |
| 1234 | lookup | <code>if (o !in sawReplica)</code> | B |
| 1238 | lookup | <code>if (o !in inSight)</code> | B |
| 1254 | lookup | <code>if (object.guid !in knows)</code> | B |
| 1277 | lookup | <code>if (s != uint.max &amp;&amp; s in inSight)</code> | A |
| 1298 | addr | <code>auto lingering = &amp;at(slot).lingering;</code> | P |
| 1299 | deref | <code>foreach (g; *lingering)</code> | D |
| 1302 | deref | <code>dropValue(*lingering, object);</code> | D |
| 1467 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 1593 | lookup | <code>if (auto peers = cell in peerCells)</code> | A |
| 1595 | deref | <code>(*peers).remove(peer);</code> | D |
| 1596 | deref | <code>if ((*peers).length == 0)</code> | D |
| 1599 | lookup | <code>if (const list = cell in cellLists)</code> | A |
| 1611 | lookup | <code>if (const list = cell in cellLists)</code> | A |
| 1651 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 2070 | addr | <code>const values = &amp;replica.fields();</code> | P |
| 2171 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 2327 | lookup | <code>if (auto wanting = key in peerCells)</code> | A |
| 2328 | deref | <code>foreach (peer, _; *wanting)</code> | D |
| 2353 | lookup | <code>if (const list = key in cellLists)</code> | A |
| 2376 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 2394 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 2431 | addr | <code>auto e = &amp;at(slot);</code> | P |
| 2466 | lookup | <code>auto wanted = cell in peerCells;</code> | A |
| 2468 | deref, lookup | <code>if (wanted is null &#124;&#124; peer !in *wanted)</code> | B |
| 2476 | deref | <code>foreach (peer, _; *wanted)</code> | D |
| 2559 | lookup | <code>if (auto count = cell in localInterest)</code> | A |
| 2560 | deref | <code>if (--*count == 0)</code> | D |
| 2694 | lookup | <code>auto packet = kind in shown;</code> | A |
| 2696 | addr | <code>packet = &amp;(shown[kind] = who.appearanceFor(other, time).build());</code> | P |
| 2697 | deref | <code>deliverBuilt(other, *packet);</code> | D |
| 3034 | addr | <code>auto map = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner);</code> | F |
| 3101 | addr | <code>auto map = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner);</code> | F |
| 3192 | addr | <code>auto map = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner, null, &amp;owns);</code> | F |
| 3273 | addr | <code>auto owner = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner, null, (ulong cell) =&gt; cast(int)(cell &gt;&gt; 32) &gt;= 6);</code> | F |
| 3274 | addr | <code>auto viewer = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner, null, (ulong cell) =&gt; cast(int)(cell &gt;&gt; 32) &lt; 6);</code> | F |
| 3473 | addr | <code>auto a = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner, null, (ulong) =&gt; aOwns);</code> | F |
| 3474 | addr | <code>auto b = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner, null, (ulong) =&gt; !aOwns);</code> | F |
| 3475 | addr | <code>auto c = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner, null, (ulong) =&gt; false);</code> | F |
| 3593 | addr | <code>auto map = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner);</code> | F |
| 3739 | addr | <code>auto map = new Map(0, MapSettings(100, 10, 30_000), () =&gt; 1000u, &amp;spawner);</code> | F |
| 3743 | addr | <code>auto near = new GameObject(nearSpawn, &amp;rock);</code> | P |
| 3744 | addr | <code>auto far = new GameObject(farSpawn, &amp;rock);</code> | P |
| 3836 | addr | <code>auto map = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner);</code> | F |
| 3908 | addr | <code>assert(playerSees(alive, body_, &amp;facts) &amp;&amp; playerSees(body_, alive, &amp;facts) &amp;&amp; asked == 0, "no ghost: no facts");</code> | F |
| 3909 | addr | <code>assert(!playerSees(alive, ghost, &amp;facts) &amp;&amp; playerSees(gm, ghost, &amp;facts));</code> | F |
| 3911 | addr | <code>assert(playerSees(alive, ghost, &amp;facts), "its group");</code> | F |
| 3913 | addr | <code>assert(!playerSees(ghost, ghost, &amp;facts), "a ghost of the other side");</code> | F |
| 3915 | addr | <code>assert(playerSees(ghost, ghost, &amp;facts), "of its own");</code> | F |
| 3916 | addr | <code>assert(!playerSees(ghost, alive, &amp;facts), "the living far from its corpse");</code> | F |
| 3918 | addr | <code>assert(playerSees(ghost, alive, &amp;facts) &amp;&amp; !playerSees(ghost, body_, &amp;facts), "near it: the living, not a body");</code> | F |
| 3924 | addr | <code>assert(!playerSees(alive, hidden, &amp;facts) &amp;&amp; playerSees(gm, hidden, &amp;facts));</code> | F |
| 3926 | addr | <code>assert(playerSees(alive, hidden, &amp;facts) &amp;&amp; !playerSees(ghost, hidden, &amp;facts));</code> | F |
| 3927 | addr | <code>assert(playerSees(hidden, alive, &amp;facts), "it sees everyone");</code> | F |

### `source/dmangos/world/meetingstone.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 189 | return, type | <code>inout(QueuedPlayer)* player(ulong guid) inout pure nothrow @nogc @safe</code> | R |
| 193 | addr | <code>return &amp;players[i];</code> | R |
| 198 | return, type | <code>inout(QueuedParty)* party(uint id) inout pure nothrow @nogc @safe</code> | R |
| 202 | addr | <code>return &amp;parties[i];</code> | R |
| 304 | addr | <code>auto party = &amp;parties[partyIndex];</code> | P |
| 313 | deref | <code>take(*party, role);</code> | D |

### `source/dmangos/world/motion.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 101 | addr | <code>foreach (paths; [&amp;bySpawn, &amp;byEntry, &amp;byPath])</code> | P |
| 104 | deref | <code>foreach (key, ref path; *paths)</code> | D |
| 111 | deref | <code>(*paths).remove(key);</code> | D |
| 118 | lookup | <code>if (auto path = guid in bySpawn)</code> | A |
| 119 | deref | <code>return *path;</code> | D |
| 499 | addr, type | <code>const(WaypointNode)* next = &amp;path[current];</code> | P |
| 500 | deref | <code>uint travelTime = travel(*next);</code> | D |
| 517 | addr | <code>next = &amp;path[after];</code> | P |
| 743 | addr | <code>auto move = &amp;creature.movement;</code> | P |
| 1094 | addr | <code>auto slowAura = creature.auras.apply(makeAura(&amp;slow, 1, 1, -1, false, [-50, 0, 0]), creature.values, isNew);</code> | P |
| 1101 | addr | <code>auto rootAura = creature.auras.apply(makeAura(&amp;root, 1, 1, -1, false, [0, 0, 0]), creature.values, isNew);</code> | P |

### `source/dmangos/world/mounting.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 102 | type | <code>package SpellCastResult mountedCastRefusal(const(imported!"dmangos.world.spells".SpellInfo)* spell, bool triggered)</code> | P |
| 188 | addr | <code>auto loot = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 2]);</code> | GO |
| 189 | addr | <code>auto box = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]);</code> | GO |

### `source/dmangos/world/moveorders.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 98 | type | <code>float rate = main ? bonus * (100.0f + main) / 100.0f : bonus;</code> | P |
| 126 | addr | <code>auras.list ~= makeAura(&amp;spells[$ - 1], 1, 60, -1, amount &gt; 0, [amount, 0, 0]);</code> | P |
| 313 | addr | <code>const ack = &amp;answer.ack;</code> | P |
| 349 | addr | <code>const m = &amp;ack.movement;</code> | P |
| 364 | addr | <code>const ack = &amp;answer.ack;</code> | P |

### `source/dmangos/world/npcdata.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 253 | lookup | <code>if (const broadcast = broadcastId in broadcastTexts)</code> | A |

### `source/dmangos/world/npchandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 147 | addr | <code>return ConditionSubject(player, source is null ? null : &amp;creatureInRange);</code> | R |
| 253 | lookup | <code>if (const broadcast = option.broadcastText in npcs.broadcastTexts)</code> | A |
| 255 | lookup | <code>if (const broadcast = option.boxBroadcastText in npcs.broadcastTexts)</code> | A |
| 487 | lookup | <code>const poi = id in context.data.npcs.pointsOfInterest;</code> | A |
| 503 | lookup | <code>if (const text = request.textId in npcs.texts)</code> | A |
| 507 | lookup | <code>if (const broadcast = option.broadcastText in npcs.broadcastTexts)</code> | A |
| 512 | addr | <code>auto sent = &amp;update.options[i];</code> | P |
| 691 | lookup | <code>if (const chain = learned in context.data.spells.chains)</code> | A |
| 732 | lookup | <code>const chain = triggerSpell in spells.chains;</code> | A |
| 763 | type | <code>const(TrainerSpell)* found;</code> | P |
| 767 | addr | <code>found = &amp;trainerSpell;</code> | P |
| 773 | deref | <code>if (trainerSpellState(*found, trainerRequiredLevel(*found, fitLevel)) != TrainerSpellState.green)</code> | D |
| 798 | addr | <code>&amp;context.nextItemGuid);</code> | F |
| 883 | lookup | <code>const proto = vendorItem.item in context.data.items;</code> | A |
| 884 | deref | <code>if (proto is null &#124;&#124; !canSeeVendorItem(vendor, vendorItem, *proto))</code> | D |
| 1004 | lookup | <code>assert(spellHeroicStrike in db.spellRows[7], "saved");</code> | A |

### `source/dmangos/world/objects.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 413 | addr, deref, type | <code>return *cast(uint*)&amp;value;</code> | U |
| 418 | addr, deref, type | <code>return *cast(float*)&amp;bits;</code> | U |
| 461 | type | <code>const(MoveSpline)* spline;</code> | P |
| 483 | deref | <code>writeSplineCreate(writer, *spline);</code> | D |
| 719 | addr | <code>values.writeCreate(told, seenByEveryone, &amp;percent);</code> | F |

### `source/dmangos/world/pet.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 364 | type | <code>PetStats petStats(PetType type, const ref CreatureTemplate t, uint level, const(PetLevelStats)* levelStats,</code> | P |
| 365 | type | <code>const(CreatureClassStats)* classStats, float minScale = 0, uint minScaleLevel = 0, float maxScale = 0,</code> | P |
| 508 | addr | <code>auto v = &amp;creature.values;</code> | P |
| 552 | lookup | <code>if (const byEntry = spell in petAuras)</code> | A |
| 554 | deref, lookup | <code>if (const aura = entry in *byEntry)</code> | A |
| 555 | deref | <code>return *aura;</code> | D |
| 556 | deref, lookup | <code>if (const aura = 0 in *byEntry)</code> | A |
| 557 | deref | <code>return *aura;</code> | D |
| 563 | return, type | <code>const(PetLevelStats)* statsFor(uint entry, uint level) const</code> | R |
| 565 | lookup | <code>if (auto byLevel = entry in levelStats)</code> | A |
| 566 | deref, lookup | <code>return level in *byLevel;</code> | R |
| 573 | lookup | <code>if (auto parts = entry in nameParts)</code> | A |
| 574 | deref | <code>if ((*parts)[0].length &amp;&amp; (*parts)[1].length)</code> | D |
| 575 | deref | <code>return (*parts)[0][uniform(0, $)] ~ (*parts)[1][uniform(0, $)];</code> | D |
| 728 | addr | <code>const s = petStats(PetType.hunter, wolf, 10, &amp;stats, null, 0.5f, 1, 1.0f, 60);</code> | P |
| 739 | addr | <code>const i = petStats(PetType.summon, imp, 1, &amp;impStats, &amp;cls);</code> | P |
| 803 | addr | <code>auras.apply(makeAura(&amp;health, 1, 60, -1, true, [15, 0, 0]), values, isNew);</code> | P |
| 804 | addr | <code>auras.apply(makeAura(&amp;armor, 1, 60, -1, true, [30, 0, 0]), values, isNew);</code> | P |
| 805 | addr | <code>auras.apply(makeAura(&amp;stamina, 1, 60, -1, true, [5, 0, 0]), values, isNew);</code> | P |

### `source/dmangos/world/petai.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 64 | type | <code>bool petSpellReady(const(SpellInfo)* info) const</code> | P |
| 66 | lookup | <code>return info.id !in petCooldowns &amp;&amp; (!info.category &#124;&#124; info.category !in petCategoryCooldowns);</code> | R |
| 239 | type | <code>bool petCastByCommand(const(SpellInfo)* info, ulong target, CombatWorld world)</code> | P |
| 267 | type | <code>private void startPetCooldown(const(SpellInfo)* info, CombatWorld world)</code> | P |
| 299 | deref | <code>if (info is null &#124;&#124; !petSpellReady(info) &#124;&#124; !isAutocastable(*info))</code> | D |

### `source/dmangos/world/petauras.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 100 | type | <code>package T petSpellMod(T)(SpellModOp op, const(SpellInfo)* spell, T value, Creature pet)</code> | P |
| 104 | deref | <code>return applySpellMod(petModifiers(pet), op, *spell, value);</code> | D |
| 108 | type | <code>package int petEffectMod(const(SpellInfo)* spell, size_t i, int value, Creature pet)</code> | P |
| 113 | deref | <code>return applySpellMod(mods, SpellModOp.allEffects, *spell, applySpellMod(mods, effectOp(i), *spell, value));</code> | D |
| 162 | type | <code>private Aura castOnPet(Creature pet, const(SpellInfo)* spell, uint level)</code> | P |
| 171 | deref | <code>values[j] = petEffectMod(spell, j, effectValue(*spell, j, level, uniform01(map.random)), pet);</code> | D |
| 172 | deref | <code>const ms = duration(*spell, context.client, level);</code> | D |
| 187 | lookup | <code>&#124;&#124; aura.spell.id in context.data.pets.petAuras)</code> | A |
| 192 | type | <code>private static ubyte petAreaEffects(const(SpellInfo)* spell)</code> | P |
| 202 | type | <code>private float petAreaRadius(const(SpellInfo)* spell)</code> | P |
| 208 | deref | <code>return radius(*spell, i, context.client);</code> | D |
| 229 | type | <code>bool near(const(SpellInfo)* spell)</code> | P |
| 329 | type | <code>package bool petAuraDummy(const(SpellInfo)* spell, ulong target)</code> | P |
| 351 | type | <code>package uint petSacrificed(const(SpellInfo)* spell, Creature pet)</code> | P |

### `source/dmangos/world/pethandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 198 | return, type | <code>private PetRecord* unstabledPet()</code> | R |
| 204 | deref | <code>*copy = r;</code> | D |
| 235 | lookup | <code>const classStats = classStatsKey(level, t.unitClass) in context.data.creatureClassStats;</code> | A |
| 246 | deref | <code>const s = petStats(state.type, *t, level, context.data.pets.statsFor(statsEntry, level), classStats,</code> | D |
| 248 | addr | <code>auto v = &amp;creature.values;</code> | P |
| 283 | addr | <code>auto v = &amp;creature.values;</code> | P |
| 362 | lookup | <code>const t = r.entry in context.data.creatureTemplates;</code> | A |
| 365 | deref | <code>if (r.type == PetType.hunter &amp;&amp; !isTameable(*t))</code> | D |
| 414 | addr | <code>auto v = &amp;pet_.values;</code> | P |
| 550 | deref | <code>state.learn(spell, info.isPassive, isAutocastable(*info));</code> | D |
| 579 | lookup | <code>const spells = entry in context.data.pets.createSpells;</code> | A |
| 583 | deref | <code>foreach (id; *spells)</code> | D |
| 604 | deref | <code>state.learn(learned, taught.isPassive, isAutocastable(*taught));</code> | D |
| 725 | deref | <code>state.learn(spell, info.isPassive, isAutocastable(*info));</code> | D |
| 754 | type | <code>package SpellCastResult petCastCheck(const(SpellInfo)* spell, const ref SpellTargets targets)</code> | P |
| 835 | type | <code>package void tameCreature(const(SpellInfo)* spell, ulong target)</code> | P |
| 847 | deref | <code>if (!isTameable(*beast.template_))</code> | D |
| 889 | type | <code>package void summonPetEffect(const(SpellInfo)* spell, size_t i)</code> | P |
| 897 | deref | <code>loadPet(*r);</code> | D |
| 907 | lookup | <code>const t = entry in context.data.creatureTemplates;</code> | A |
| 946 | deref | <code>loadPet(*r, false, share);</code> | D |
| 975 | type | <code>package void takeCharm(Creature creature, const(SpellInfo)* spell, bool possess)</code> | P |
| 999 | lookup | <code>if (const list = creature.template_.spellList in context.data.creatureSpellLists)</code> | A |
| 1000 | deref | <code>foreach (entry; *list)</code> | D |
| 1002 | deref | <code>state.learn(entry.spell, info.isPassive, isAutocastable(*info));</code> | D |
| 1135 | addr | <code>auto v = &amp;pet_.values;</code> | P |
| 1523 | deref | <code>if (!isAutocastable(*info))</code> | D |
| 1544 | deref | <code>if (!isAutocastable(*info))</code> | D |
| 1578 | lookup | <code>if (!validPetName(name) &#124;&#124; (toLowerName(name) in context.data.reservedNames) !is null)</code> | A |
| 1590 | type | <code>package void summonTotem(const(SpellInfo)* spell, size_t i, int value)</code> | P |
| 1672 | lookup | <code>if (const at = key in totemTickAt)</code> | A |
| 1674 | deref | <code>if (*at &gt; now)</code> | D |
| 1693 | deref | <code>const reach = radius(*trigger, i, context.client), enchantment = cast(uint) trigger.miscValue[i];</code> | D |
| 1802 | type | <code>state.trainingPoints = cast(int)(pet.values.get!UNIT_FIELD_LEVEL * (state.loyalty &gt; 0 ? state.loyalty - 1 : 0));</code> | P |
| 1908 | type | <code>private bool stablePetUsable(PetTameFailure notOk, out PetRecord* setAside)</code> | P |
| 1956 | lookup | <code>while (free in taken)</code> | A |
| 1982 | lookup | <code>const t = wanted.entry in context.data.creatureTemplates;</code> | A |
| 1983 | deref | <code>if (t is null &#124;&#124; !isTameable(*t))</code> | D |

### `source/dmangos/world/pettests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 59 | type | <code>void addPetData(TestClient* client, imported!"dmangos.world.context".WorldContext context)</code> | P |
| 100 | addr | <code>addPetData(&amp;gul, context);</code> | P |
| 112 | addr | <code>session.summonPetEffect(&amp;summonImp, 0);</code> | P |
| 160 | addr | <code>session.summonPetEffect(&amp;summonImp, 0);</code> | P |
| 186 | addr | <code>addPetData(&amp;rexxar, context);</code> | P |
| 202 | addr | <code>session.tameCreature(&amp;tame, beast.guid);</code> | P |
| 231 | addr | <code>session.tameCreature(&amp;tame, second.guid);</code> | P |
| 329 | addr | <code>assert(session.petCastCheck(&amp;callPet, none) == SpellCastResult.dontReport);</code> | P |
| 332 | addr | <code>assert(session.petCastCheck(&amp;revive, none) == SpellCastResult.ok);</code> | P |
| 336 | addr | <code>assert(session.petCastCheck(&amp;callPet, none) == SpellCastResult.alreadyHaveSummon);</code> | P |
| 347 | lookup | <code>pet.auras.apply(makeAura(mark in context.data.spells.spells, pet.guid, 1, 300_000, true, [10, 0, 0]),</code> | A |
| 361 | lookup | <code>assert(97302 in rexxar.session.inWorld.ownPet.ai.petCooldowns, "its cooldown back");</code> | A |
| 387 | addr | <code>addPetData(&amp;rexxar, context);</code> | P |
| 392 | addr | <code>session.tameCreature(&amp;tame, beast.guid);</code> | P |
| 427 | addr | <code>addPetData(&amp;rexxar, context);</code> | P |
| 432 | addr | <code>session.tameCreature(&amp;tame, beast.guid);</code> | P |
| 462 | addr | <code>addPetData(&amp;rexxar, context);</code> | P |
| 467 | addr | <code>session.tameCreature(&amp;tame, beast.guid);</code> | P |
| 512 | addr | <code>addPetData(&amp;rexxar, context);</code> | P |
| 517 | addr | <code>session.tameCreature(&amp;tame, beast.guid);</code> | P |
| 566 | addr | <code>addPetData(&amp;rexxar, context);</code> | P |
| 571 | addr | <code>hunter.tameCreature(&amp;tame, beast.guid);</code> | P |
| 583 | addr | <code>auto target = first.makeCreature(&amp;spawn);</code> | CS |
| 612 | addr | <code>const bundle = oldRegion.releaseCreatureLoan(guid, second.nodeId, &amp;first.saveMigrant);</code> | F |
| 614 | addr | <code>newRegion.migrateIn(bundle, &amp;second.restoreMigrant);</code> | F |
| 719 | addr | <code>addPetData(&amp;client, context);</code> | P |
| 727 | addr | <code>player.takeCharm(attacker, &amp;control, false);</code> | F |
| 733 | addr | <code>player.summonGuardianEffect(&amp;control, 0, 1, targets, false, 0, false);</code> | F |
| 748 | addr | <code>auto target = first.makeCreature(&amp;spawn);</code> | CS |
| 790 | addr | <code>const bundle = oldRegion.migrateOut((ulong key) =&gt; key == cell, second.nodeId, &amp;first.saveMigrant);</code> | F |
| 792 | addr | <code>newRegion.migrateIn(bundle, &amp;second.restoreMigrant);</code> | F |
| 838 | addr | <code>player.takeCharm(attacker, &amp;control, false);</code> | F |
| 876 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 884 | addr | <code>addPetData(&amp;thrall, context);</code> | P |
| 928 | addr | <code>addPetData(&amp;rexxar, context);</code> | P |
| 933 | addr | <code>session.tameCreature(&amp;tame, beast.guid);</code> | P |
| 973 | addr | <code>addPetData(&amp;gul, context);</code> | P |
| 982 | addr | <code>session.summonPetEffect(&amp;summonImp, 0);</code> | P |
| 1029 | addr | <code>addPetData(&amp;gul, context);</code> | P |
| 1035 | deref | <code>with (*context.data.spells.spells.edit(id))</code> | D |
| 1043 | addr | <code>session.summonPetEffect(&amp;summonImp, 0);</code> | P |

### `source/dmangos/world/physicalclasses.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 37 | type | <code>package bool physicalClassDummy(const(SpellInfo)* spell, size_t i, UnitRef target, int value)</code> | P |
| 72 | type | <code>package void physicalClassAuraValues(const(SpellInfo)* spell, ref int[3] values)</code> | P |
| 87 | type | <code>package void trapEffectLanded(const(SpellInfo)* spell, const(ulong)[] landed)</code> | P |
| 117 | deref | <code>&amp;&amp; (aura.misc(k) == 4086 &#124;&#124; aura.misc(k) == 4087) &amp;&amp; affects(aura, k, *heal.spell))</code> | D |

### `source/dmangos/world/player.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 226 | addr | <code>inventory = new Inventory(world, this, &amp;values, nextItemGuid);</code> | P |
| 340 | addr | <code>groupMate ? null : &amp;strangerValue);</code> | F |
| 379 | addr | <code>update.addValues(guid, values, seen, viewer == Viewer.stranger ? &amp;strangerValue : null);</code> | F |
| 394 | addr | <code>update.addSlots(guid, values, slots, viewer == Viewer.stranger ? &amp;strangerValue : null);</code> | F |
| 1147 | lookup | <code>if (const effects = item.enchantment(enchantSlot) in world.enchantmentEffects)</code> | A |
| 1148 | deref | <code>input.enchantments.add(*effects, attack);</code> | D |
| 1150 | lookup | <code>input.ammo = values[PLAYER_AMMO_ID] in world.items;</code> | A |
| 1363 | lookup | <code>const model = displayId in world.models;</code> | A |

### `source/dmangos/world/playercreate.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 259 | type | <code>SkillRange skillRangeType(const(SkillLineEntry)* skill, bool racial)</code> | P |
| 281 | type | <code>bool isProfessionOrRiding(const(SkillLineEntry)* skill)</code> | P |
| 357 | addr | <code>inventory = new Inventory(world, this, &amp;fields, nextItemGuid);</code> | P |
| 391 | deref | <code>learnDefaultSkills(*info);</code> | D |
| 392 | deref | <code>learnDefaultSpells(*info);</code> | D |
| 394 | deref | <code>addStartingItems(*info);</code> | D |
| 433 | lookup | <code>if (saved.value == 0 &#124;&#124; (saved.skill in skills) !is null)</code> | A |
| 466 | lookup | <code>if (const skill = id in skills)</code> | A |
| 472 | deref | <code>learnDefaultSpells(*info);</code> | D |
| 542 | lookup | <code>if (auto spell = id in spells)</code> | A |
| 620 | lookup | <code>const existing = id in spells;</code> | A |
| 627 | lookup | <code>if (auto spell = next in spells)</code> | A |
| 642 | type | <code>bool isSpellValid(const(SpellInfo)* spell) const</code> | P |
| 652 | lookup | <code>if ((spell.itemType[i] in world.items) is null)</code> | A |
| 666 | lookup | <code>if (reagent &gt; 0 &amp;&amp; (cast(uint) reagent in world.items) is null)</code> | A |
| 672 | type | <code>static bool needCastAtLearn(const(SpellInfo)* spell)</code> | P |
| 684 | type | <code>void castOnSelf(const(SpellInfo)* spell)</code> | P |
| 724 | lookup | <code>if (auto existing = id in spells)</code> | A |
| 885 | lookup | <code>if (auto spell = id in spells)</code> | A |
| 900 | lookup | <code>if (auto skill = id in skills)</code> | A |
| 907 | lookup | <code>if (auto skill = id in skills)</code> | A |
| 914 | lookup | <code>if (auto skill = id in skills)</code> | A |
| 920 | return, type | <code>const(SkillRaceClassInfoEntry)* skillInfo(uint id,</code> | R |
| 929 | deref | <code>if (filter is null &#124;&#124; filter(*entry))</code> | D |
| 995 | lookup | <code>auto existing = id in skills;</code> | A |
| 1025 | deref | <code>*existing = SkillStatus(value, maxValue, step, SkillState.changed);</code> | D |
| 1138 | type | <code>const(CharStartOutfitEntry)* outfit;</code> | P |
| 1153 | lookup | <code>const proto = cast(uint) itemId in world.items;</code> | A |
| 1317 | return, type | <code>private const(NewItem)* itemOf(const ref NewCharacter character, uint entry)</code> | L |
| 1321 | addr | <code>return &amp;item;</code> | L |

### `source/dmangos/world/procs.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 44 | type | <code>const(SpellInfo)* spell;</code> | P |
| 101 | type | <code>bool procEventMatches(uint auraFlags, const(SpellProcEvent)* event, uint flags, const ref ProcHit hit)</code> | P |
| 142 | type | <code>ulong affectMaskOf(const(SpellInfo)* spell, size_t i) pure nothrow @nogc @safe</code> | P |
| 152 | type | <code>bool effectProcsOn(const(SpellInfo)* auraSpell, size_t i, const(SpellProcEvent)* event, const ref ProcHit hit)</code> | P |
| 194 | type | <code>const(SpellProcEvent)* event;</code> | P |
| 205 | type | <code>ProcRule procRule(const(SpellInfo)* spell, const(SpellProcEvent)* event, const ProcOptions[uint] procs)</code> | P |
| 217 | lookup | <code>if (const options = spell.id in procs)</code> | A |
| 238 | addr | <code>assert(procRule(&amp;shield, &amp;row, null).cooldown == 3000, "no Blizzard data: the row's");</code> | P |
| 241 | addr | <code>auto rule = procRule(&amp;shield, &amp;row, procs);</code> | P |
| 244 | addr | <code>assert(procRule(&amp;shield, &amp;row, procs).cooldown == 3000, "not the aura 1.12 has: the row's");</code> | P |
| 246 | addr | <code>assert(procRule(&amp;shield, &amp;row, procs).cooldown == 3500);</code> | P |
| 284 | type | <code>const(SpellInfo)* by;</code> | P |
| 325 | lookup | <code>if (const at = aura.spell.id in procReadyAt)</code> | A |
| 326 | deref | <code>if (*at &gt; now)</code> | D |
| 368 | deref | <code>if (procTargetsCaster(*spell))</code> | D |
| 393 | type | <code>package void tickProcs(UnitRef victim, const(SpellInfo)* spell, uint damage)</code> | P |
| 437 | type | <code>private bool procWeaponFits(const(SpellInfo)* spell, const ref ProcHit hit)</code> | P |
| 454 | type | <code>private bool procWeaponInSlot(const(SpellInfo)* spell, uint slot)</code> | P |
| 473 | addr | <code>auto crit = ProcHit(&amp;fireball, ProcEx.criticalHit, 100);</code> | P |
| 474 | addr | <code>auto hit = ProcHit(&amp;fireball, ProcEx.normalHit, 100);</code> | P |
| 477 | addr | <code>assert(procEventMatches(ProcFlag.dealHarmfulSpell, &amp;ignite, ProcFlag.dealHarmfulSpell, crit));</code> | P |
| 478 | addr | <code>assert(!procEventMatches(ProcFlag.dealHarmfulSpell, &amp;ignite, ProcFlag.dealHarmfulSpell, hit), "a crit only");</code> | P |
| 481 | addr | <code>auto frostCrit = ProcHit(&amp;frostbolt, ProcEx.criticalHit, 100);</code> | P |
| 482 | addr | <code>assert(!procEventMatches(ProcFlag.dealHarmfulSpell, &amp;ignite, ProcFlag.dealHarmfulSpell, frostCrit), "fire only");</code> | P |
| 487 | addr | <code>assert(!effectProcsOn(&amp;talent, 0, null, hit), "not a spell it affects");</code> | F |
| 489 | addr | <code>assert(effectProcsOn(&amp;talent, 0, null, hit));</code> | F |

### `source/dmangos/world/professions.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 95 | type | <code>package SpellCastResult checkSpellFocus(const(SpellInfo)* spell)</code> | P |
| 114 | type | <code>package SpellCastResult checkTools(const(SpellInfo)* spell)</code> | P |
| 126 | type | <code>package SpellCastResult checkItemTarget(const(SpellInfo)* spell, const ref SpellTargets targets, uint castItem,</code> | P |
| 167 | type | <code>package void disenchantItem(const(SpellInfo)* spell, ulong itemGuid)</code> | P |
| 181 | type | <code>package void openItemLock(const(SpellInfo)* spell, size_t i, ulong itemGuid, uint castItem)</code> | P |
| 190 | lookup | <code>if (skillId &amp;&amp; !castItem &amp;&amp; itemGuid !in itemLoots)</code> | B |

### `source/dmangos/world/queries.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 16 | type | <code>ubyte[] itemQueryResponse(uint entry, const ItemTemplate* item, const SpellData spells)</code> | P |
| 25 | addr | <code>const d = &amp;item.details;</code> | P |
| 121 | type | <code>ubyte[] creatureQueryResponse(uint entry, const(CreatureTemplate)* t) pure @safe</code> | P |
| 147 | type | <code>ubyte[] gameObjectQueryResponse(uint entry, const(GameObjectTemplate)* t) pure @safe</code> | P |
| 250 | addr | <code>const reply = creatureQueryResponse(448, &amp;hogger);</code> | P |
| 256 | addr | <code>assert(gameObjectQueryResponse(32349, &amp;mailbox).length == 4 * 3 + 8 + 3 + 1 + 24 * 4);</code> | P |
| 272 | addr | <code>const body_ = itemQueryResponse(25, &amp;sword, spells);</code> | P |
| 420 | addr | <code>assert(shown(whoList(all, everyone, 67, 0, false, 2, 49, &amp;zoneName)) == 2);</code> | F |
| 421 | addr | <code>assert(shown(whoList(all, everyone, 67, 0, true, 3, 49, &amp;zoneName)) == 4, "both factions, GMs listed");</code> | F |
| 422 | addr | <code>assert(shown(whoList(all, everyone, 469, 3, false, 0, 49, &amp;zoneName)) == 4, "a GM sees everyone");</code> | F |
| 426 | addr | <code>assert(shown(whoList(search, everyone, 67, 0, false, 3, 49, &amp;zoneName)) == 2, "by zone name, in part");</code> | F |
| 430 | addr | <code>assert(shown(whoList(search, everyone, 67, 0, false, 3, 49, &amp;zoneName)) == 1);</code> | F |
| 433 | addr | <code>assert(shown(whoList(search, everyone, 67, 0, false, 3, 49, &amp;zoneName)) == 0, "nobody is in a guild yet");</code> | F |
| 439 | addr | <code>auto r = ByteReader(whoList(all, crowd, 67, 0, false, 3, 55, &amp;zoneName));</code> | F |

### `source/dmangos/world/questhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 45 | lookup | <code>if (auto q = id in player.questStatus)</code> | A |
| 53 | lookup | <code>if (auto q = id in player.questStatus)</code> | A |
| 206 | lookup | <code>const events = quest.id in context.data.questGameEvents;</code> | A |
| 209 | deref | <code>foreach (e; *events)</code> | D |
| 256 | deref | <code>if (quest.autoComplete &amp;&amp; canTakeQuest(*quest))</code> | D |
| 260 | lookup | <code>const q = id in player.questStatus;</code> | A |
| 329 | lookup | <code>const proto = item.entry in context.data.items;</code> | A |
| 357 | deref | <code>else if (quest.autoComplete &amp;&amp; canTakeQuest(*quest))</code> | D |
| 367 | deref | <code>if (quest is null &#124;&#124; questState(id) != QuestState.none &#124;&#124; !canSeeStartQuest(*quest))</code> | D |
| 369 | deref | <code>if (!satisfyStatus(*quest))</code> | D |
| 435 | deref | <code>if (quest is null &#124;&#124; !canTakeQuest(*quest))</code> | D |
| 457 | deref | <code>return sendRequestItems(*quest, giver.guid, canRewardQuest(*quest), true);</code> | D |
| 459 | deref | <code>return sendRequestItems(*quest, giver.guid, false, true);</code> | D |
| 460 | deref | <code>return sendQuestDetails(*quest, giver.guid, true);</code> | D |
| 499 | lookup | <code>const proto = id in context.data.items;</code> | A |
| 560 | lookup | <code>const proto = quest.reqItemId[i] in context.data.items;</code> | A |
| 611 | deref | <code>sendQuestDetails(*quest, guid, true);</code> | D |
| 690 | deref | <code>if (!canTakeQuest(*quest))</code> | D |
| 698 | deref | <code>addQuest(*quest);</code> | D |
| 725 | deref | <code>offerToParty(*quest);</code> | D |
| 751 | addr | <code>auto q = &amp;statusOf(quest.id);</code> | P |
| 775 | addr | <code>auto q = &amp;statusOf(id);</code> | P |
| 787 | deref | <code>rewardQuest(*quest, 0);</code> | D |
| 796 | addr | <code>auto q = &amp;statusOf(id);</code> | P |
| 823 | lookup | <code>auto q = id in player.questStatus;</code> | A |
| 861 | addr | <code>auto q = &amp;statusOf(id);</code> | P |
| 879 | deref | <code>sendRequestItems(*quest, guid, canRewardQuest(*quest), false);</code> | D |
| 896 | deref | <code>sendOfferReward(*quest, guid, true);</code> | D |
| 911 | deref | <code>if (!canRewardQuest(*quest) &#124;&#124; !roomForRewards(*quest, reward))</code> | D |
| 912 | deref | <code>return sendOfferReward(*quest, guid, true);</code> | D |
| 913 | deref | <code>rewardQuest(*quest, reward);</code> | D |
| 915 | deref | <code>sendQuestMail(*quest, guid);</code> | D |
| 937 | deref | <code>if (involves(giver, next.id, true, false) &amp;&amp; canTakeQuest(*next))</code> | D |
| 938 | deref | <code>sendQuestDetails(*next, guid, true);</code> | D |
| 1031 | addr | <code>auto q = &amp;statusOf(quest.id);</code> | P |
| 1095 | lookup | <code>const quest = id in context.data.quests.quests;</code> | A |
| 1102 | deref | <code>if (canTakeQuest(*quest))</code> | D |
| 1104 | deref | <code>addQuest(*quest);</code> | D |
| 1130 | lookup | <code>const q = id in player.questStatus;</code> | A |
| 1168 | deref | <code>if (!member.satisfyStatus(*quest))</code> | D |
| 1178 | deref | <code>if (!member.canTakeQuest(*quest))</code> | D |
| 1193 | deref | <code>member.sendQuestDetails(*quest, player.guid, true);</code> | D |
| 1257 | addr | <code>auto q = &amp;statusOf(id);</code> | P |
| 1353 | lookup | <code>auto q = id in player.questStatus;</code> | A |
| 1356 | deref | <code>if (kill &amp;&amp; !questAllowedHere(*quest))</code> | D |
| 1419 | deref | <code>if (target &lt; 0 &amp;&amp; !questAllowedHere(*quest))</code> | D |
| 1444 | lookup | <code>auto q = id in player.questStatus;</code> | A |
| 1489 | lookup | <code>auto q = id in player.questStatus;</code> | A |
| 1492 | deref | <code>if (!questAllowedHere(*quest) &amp;&amp; !inBattlegroundMap)</code> | D |

### `source/dmangos/world/questruletests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 75 | deref | <code>assert(!session.canTakeQuest(*quests.quest(next.id)), "one of the two done: not yet");</code> | D |
| 77 | deref | <code>assert(session.canTakeQuest(*quests.quest(next.id)), "both done");</code> | D |
| 79 | deref | <code>assert(session.canTakeQuest(*quests.quest(other.id)));</code> | D |
| 81 | deref | <code>assert(session.canTakeQuest(*quests.quest(after.id)), "one of all: one done is enough");</code> | D |
| 82 | deref | <code>assert(!session.canTakeQuest(*quests.quest(other.id)), "and the other is shut");</code> | D |
| 122 | deref | <code>session.addQuest(*context.data.quests.quest(cast_.id));</code> | D |
| 123 | deref | <code>session.addQuest(*context.data.quests.quest(event.id));</code> | D |
| 134 | lookup | <code>session.castSpell(sprinkle in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);</code> | A |
| 140 | lookup | <code>session.castSpell(finish in context.data.spells.spells, SpellTargets(TargetFlags.self, me.guid), false, 0);</code> | A |
| 165 | deref | <code>session.addQuest(*context.data.quests.quest(cast_.id));</code> | D |
| 191 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 207 | deref | <code>session.addQuest(*context.data.quests.quest(alive.id));</code> | D |
| 208 | deref | <code>session.addQuest(*context.data.quests.quest(any.id));</code> | D |
| 233 | addr | <code>foreach (q; [&amp;party, &amp;raid])</code> | P |
| 237 | deref | <code>context.data.quests.quests[q.id] = *q;</code> | D |
| 243 | deref | <code>session.addQuest(*context.data.quests.quest(party.id));</code> | D |
| 244 | deref | <code>session.addQuest(*context.data.quests.quest(raid.id));</code> | D |

### `source/dmangos/world/quests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 245 | return, type | <code>const(QuestGreeting)* greetingOf(uint entry, bool gameObject) const</code> | R |
| 247 | lookup | <code>return ((ulong(gameObject ? 1 : 0) &lt;&lt; 32) &#124; entry) in greetings;</code> | A |
| 253 | return, type | <code>const(Quest)* quest(uint id) const</code> | R |
| 255 | lookup | <code>return id in quests;</code> | R |
| 285 | lookup | <code>if (q.prevQuestId &amp;&amp; (q.prevQuestId &lt; 0 ? -q.prevQuestId : q.prevQuestId) in quests)</code> | A |
| 288 | lookup | <code>if (auto next = (q.nextQuestId &lt; 0 ? -q.nextQuestId : q.nextQuestId) in quests)</code> | A |

### `source/dmangos/world/realclass_magewarlockpriest.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 69 | return, type | <code>private const(SpellInfo)* spellOf(ref RealWorld w, uint id)</code> | R |
| 85 | deref | <code>values[i] = effectValue(*s, i, 60, 0);</code> | D |
| 149 | type | <code>const expected = row.percent ? cast(int)(row.base * (100.0 + row.values[k]) / 100.0)</code> | P |
| 321 | deref | <code>return [effectValue(*s, i, 60, 0), effectValue(*s, i, 60, 0.999)];</code> | D |
| 371 | deref | <code>const full = me.costOf(*spellOf(w, 10181));</code> | D |
| 373 | deref | <code>assert(me.costOf(*spellOf(w, 10181)) == cast(int)(full * 0.85), "15% less");</code> | D |
| 381 | deref | <code>assert(me.costOf(*spellOf(w, 10181)) == cast(int)(full * 1.3), "Arcane Power: 30% more");</code> | D |
| 460 | deref | <code>const tick = rolls(w, 12526, 1)[0] + cast(int)(1000 * bonusCoefficient(*spellOf(w, 12526), 1, w.context.client, 60));</code> | D |
| 1841 | deref | <code>assert(me.costOf(*spellOf(w, 2061)) == 0, "free");</code> | D |
| 1866 | deref | <code>assert(me.costOf(*spellOf(w, 2061)) == 0, "heals free");</code> | D |

### `source/dmangos/world/realclass_paladin_shaman_druid.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 66 | return, type | <code>private const(SpellInfo)* spellOf(ref RealWorld w, uint id)</code> | R |
| 189 | type | <code>const want = base * (100 + percent) / 100.0;</code> | P |
| 236 | deref | <code>return me.costOf(*spell);</code> | D |
| 244 | deref | <code>return cast(long) me.spellMod(SpellModOp.range, spell, range(*spell, w.context.client)[1]);</code> | D |
| 248 | deref | <code>return me.modDuration(spell, duration(*spell, w.context.client, me.player.data.level));</code> | D |
| 252 | deref | <code>return me.spellMod(SpellModOp.castingTime, spell, castTime(*spell, w.context.client, me.player.data.level));</code> | D |
| 392 | deref | <code>return [effectValue(*s, i, level, 0), effectValue(*s, i, level, 0.99999f)];</code> | D |
| 398 | type | <code>const a = lo * (100 + percent) / 100.0 - 1, b = hi * (100 + percent) / 100.0 + 1;</code> | P |
| 694 | deref | <code>const bonus = cast(int)(valueRange(w, blessing, k, 60)[0] * bonusCoefficient(*spellOf(w, heal), 0, w.context.client, 60));</code> | D |
| 790 | type | <code>assert(me.unit.fighter.damageDone[0] &gt; physical * (1 + 0.03f * (rank + 1)) - 0.01f, "physical damage more");</code> | P |
| 1163 | deref | <code>return duration(*spellOf(w, spell), w.context.client, 60);</code> | D |
| 1200 | type | <code>const want = c.percent ? base * (1 + c.perRank * (rank + 1) / 100) : base + c.perRank * (rank + 1);</code> | P |

### `source/dmangos/world/realclass_pets.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 36 | return, type | <code>private const(SpellInfo)* spellOf(ref RealWorld w, uint id)</code> | R |

### `source/dmangos/world/realclass_warrior_rogue_hunter.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 62 | return, type | <code>private const(SpellInfo)* spellOf(ref RealWorld w, uint id)</code> | R |
| 78 | deref | <code>values[i] = effectValue(*spell, i, 60, 0);</code> | D |
| 364 | deref | <code>assert(applySpellMod(me.player.auras.list, row.op, *spell, row.base) == row.base, row.name ~ ": nothing without the talent");</code> | D |
| 368 | deref | <code>const got = applySpellMod(me.player.auras.list, row.op, *spell, row.base);</code> | D |
| 662 | type | <code>assert(healed &gt;= max * (r + 1) / 100 - 2 &amp;&amp; healed &lt;= max * (r + 1) / 100 + 2,</code> | P |
| 1123 | type | <code>const expected = plain[0] * (600.0 + 35 * 15) / 600;</code> | P |
| 2014 | type | <code>total += poison.amount[i] * (12_000 / poison.spell.casting.amplitude[i]);</code> | P |

### `source/dmangos/world/realclassspelltests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 148 | type | <code>if (healed == base * (100 + percent) / 100 &#124;&#124; healed == base * (100 + percent) / 100 * 3 / 2)</code> | P |

### `source/dmangos/world/realnpcsweep.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 97 | lookup | <code>auto sp = spell in found;</code> | A |
| 101 | lookup | <code>sp = spell in found;</code> | A |
| 103 | lookup | <code>if (entry &amp;&amp; (entry in data.creatureTemplates) !is null &amp;&amp; !sp.casters.canFind(entry))</code> | A |
| 134 | lookup | <code>if (auto who = list in listCreatures)</code> | A |
| 135 | deref | <code>foreach (entry; *who)</code> | D |
| 196 | lookup | <code>scripts!"dbscripts_on_creature_movement"(id =&gt; id in movementCreatures ? movementCreatures[id] : null);</code> | A |
| 198 | lookup | <code>scripts!"dbscripts_on_quest_start"(id =&gt; id in questStarters ? questStarters[id] : null);</code> | A |
| 199 | lookup | <code>scripts!"dbscripts_on_quest_end"(id =&gt; id in questEnders ? questEnders[id] : null);</code> | A |
| 200 | lookup | <code>scripts!"dbscripts_on_gossip"(id =&gt; id in gossipCreatures ? gossipCreatures[id] : null);</code> | A |
| 201 | lookup | <code>scripts!"dbscripts_on_relay"(id =&gt; id in relayCreatures ? relayCreatures[id] : null);</code> | A |
| 202 | addr | <code>scripts!"dbscripts_on_event"(&amp;none);</code> | F |
| 203 | addr | <code>scripts!"dbscripts_on_spell"(&amp;none);</code> | F |
| 204 | addr | <code>scripts!"dbscripts_on_go_use"(&amp;none);</code> | F |
| 205 | addr | <code>scripts!"dbscripts_on_go_template_use"(&amp;none);</code> | F |
| 233 | lookup | <code>if (m[1] !in found)</code> | B |
| 278 | lookup | <code>else if (const v = word in local)</code> | A |
| 279 | deref | <code>id = *v;</code> | D |
| 280 | lookup | <code>else if (const v = word in global)</code> | A |
| 281 | deref | <code>id = *v;</code> | D |
| 395 | lookup | <code>const t = entry in data.creatureTemplates;</code> | A |
| 403 | deref | <code>const r = range(*s, context.client);</code> | D |
| 407 | deref | <code>&#124;&#124; (s.implicitTargetA[i] == ImplicitTarget.unit &amp;&amp; harms(*s)));</code> | D |
| 417 | deref | <code>const by = whoOf(*s, i, true);</code> | D |
| 473 | deref | <code>const hostileSpell = harms(*s);</code> | D |
| 583 | deref | <code>const onSwing = isNextMeleeSwingSpell(*s);</code> | D |
| 596 | deref | <code>const total = ((sp.flags &amp; 0x02) ? 0 : castTime(*s, context.client, caster.values.get!UNIT_FIELD_LEVEL))</code> | D |
| 675 | lookup | <code>if (x in displayBefore &amp;&amp; unit.fields.get!UNIT_FIELD_DISPLAYID != displayBefore[x])</code> | B |
| 820 | addr | <code>auto clock = &amp;w.now;</code> | P |
| 821 | deref | <code>w.context.clock = () =&gt; *clock;</code> | D |
| 851 | return, type | <code>private const(SpellInfo)* dispellable(const WorldData data, int type, bool harmful)</code> | R |
| 853 | type | <code>static const(SpellInfo)*[string] cache;</code> | P |
| 855 | lookup | <code>if (auto found = key in cache)</code> | A |
| 856 | deref | <code>return *found;</code> | D |
| 857 | type | <code>const(SpellInfo)* best;</code> | P |
| 864 | addr | <code>best = &amp;s;</code> | P |
| 870 | type | <code>private void putAura(UnitRef unit, const(SpellInfo)* spell, ulong caster)</code> | P |
| 876 | deref | <code>auto aura = makeAura(spell, caster, 60, 60_000, !harms(*spell),</code> | D |
| 877 | deref | <code>[effectValue(*spell, 0, 60, 0), effectValue(*spell, 1, 60, 0), effectValue(*spell, 2, 60, 0)]);</code> | D |
| 997 | lookup | <code>if (id !in known)</code> | B |
| 1001 | lookup | <code>if (id !in failed)</code> | B |

### `source/dmangos/world/realrules_combat.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 39 | return, type | <code>private const(SpellInfo)* spellOf(ref RealWorld w, uint id)</code> | R |
| 141 | deref | <code>values[i] = effectValue(*song, i, 60, 0);</code> | D |
| 209 | deref | <code>assert(!isBinarySpell(*spellOf(w, 8042)), "Earth Shock: Blizzard's example of a spell resisted in part");</code> | D |
| 210 | deref | <code>assert(!isBinarySpell(*spellOf(w, 133)), "Fireball");</code> | D |
| 211 | deref | <code>assert(isBinarySpell(*spellOf(w, 172)), "Corruption");</code> | D |
| 212 | deref | <code>assert(isBinarySpell(*spellOf(w, 122)), "Frost Nova");</code> | D |
| 213 | deref | <code>assert(isBinarySpell(*spellOf(w, 116)), "Frostbolt");</code> | D |
| 237 | deref | <code>assert(partiallyResisted(100, 300, 60, victim, isBinarySpell(*corruption), roll) == Resisted(100, 0));</code> | D |
| 268 | lookup | <code>const o = id in procs;</code> | A |

### `source/dmangos/world/realrules_experience.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 86 | deref | <code>assert(questXp(*bounty, 5) == 340 &amp;&amp; questXp(*bounty, 10) == 340);</code> | D |
| 87 | deref | <code>assert(questXp(*bounty, 11) == 270 &amp;&amp; questXp(*bounty, 12) == 205 &amp;&amp; questXp(*bounty, 15) == 35);</code> | D |
| 90 | deref | <code>assert(questXp(*kits, 55) == 650, "of the player's level: 390 / 0.6");</code> | D |

### `source/dmangos/world/realrules_honor.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 61 | lookup | <code>const warsong = cast(ubyte) BattlegroundType.warsongGulch in w.context.data.battlegroundTemplates;</code> | A |
| 62 | lookup | <code>const alterac = cast(ubyte) BattlegroundType.alteracValley in w.context.data.battlegroundTemplates;</code> | A |
| 64 | deref | <code>assert(bonusHonor(1, *warsong, 15) == 24 &amp;&amp; bonusHonor(1, *warsong, 55) == 189 &amp;&amp; bonusHonor(1, *warsong, 60) == 198);</code> | D |
| 65 | deref | <code>assert(bonusHonor(2, *warsong, 25) == 82, "a capture in 20-29");</code> | D |
| 66 | deref | <code>assert(bonusHonor(4, *alterac, 52) == 792);</code> | D |

### `source/dmangos/world/realrules_world.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 71 | lookup | <code>const boar = 1190 in w.context.data.creatureTemplates;</code> | A |
| 72 | lookup | <code>const ogre = 2287 in w.context.data.creatureTemplates;</code> | A |

### `source/dmangos/world/realrules_world2.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 116 | lookup | <code>const cloak = 1376 in w.context.data.items, linen = 2589 in w.context.data.items;</code> | A |
| 119 | deref | <code>assert(auctionDeposit(*city, day, cloak.details.sellPrice, 1) == 0);</code> | D |
| 120 | deref | <code>assert(auctionDeposit(*goblins, day, cloak.details.sellPrice, 1) == 12);</code> | D |
| 121 | deref | <code>assert(auctionDeposit(*city, eight, linen.details.sellPrice, 20) == 52);</code> | D |

### `source/dmangos/world/realscriptkit.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 280 | return, type | <code>const(imported!"dmangos.world.creature".CreatureSpawn)* spawnRow(uint entry, size_t n = 0)</code> | R |
| 284 | addr | <code>return &amp;s;</code> | R |
| 289 | return, type | <code>const(imported!"dmangos.world.gameobject".GameObjectSpawn)* objectRow(uint entry, size_t n = 0)</code> | R |
| 293 | addr | <code>return &amp;s;</code> | R |
| 589 | lookup | <code>if (c.guid !in known)</code> | B |
| 615 | return, type | <code>private const(imported!"dmangos.world.npcdata".BroadcastText)* line(long entry)</code> | R |

### `source/dmangos/world/realscriptkit_raids.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 411 | lookup | <code>auto t = id in w.context.data.scriptTexts;</code> | A |
| 665 | lookup | <code>if (auto q = quest in heroes[0].session.inWorld.player.questStatus)</code> | A |
| 722 | deref | <code>me.addQuest(*q);</code> | D |
| 744 | lookup | <code>if (c !is ward &amp;&amp; c.alive &amp;&amp; c.guid !in friends)</code> | B |
| 747 | lookup | <code>if (v in friends)</code> | B |
| 759 | lookup | <code>if ((c.spawn.entry in w.context.data.creatureScriptNames) !is null)</code> | A |

### `source/dmangos/world/realscripts_dungeons.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 173 | addr | <code>assert(d.runUntil(&amp;open, 120.seconds), format!"the courtyard door opens: he %s at %s, in combat %s\n%s"(d.find(ashcrombe) is null ? "gone" : d.find(ashcrom…</code> | F |
| 305 | addr | <code>assert(d.runUntil(&amp;awake, 600.seconds), format!"Naralex wakes (the disciple at %s)\n%s"(him.position, d.story));</code> | F |
| 362 | addr | <code>assert(d.runUntil(&amp;out_, 400.seconds), format!"he gets out (at %s)\n%s"(him.position, d.story));</code> | F |
| 456 | addr | <code>assert(d.runUntil(&amp;over, 400.seconds), format!"the ritual done (he is at %s, alive %s)\n%s"(him.position,</code> | F |
| 634 | addr | <code>assert(d.runUntil(&amp;fighting, 20.seconds), "she fights\n" ~ d.story);</code> | F |
| 637 | addr | <code>assert(d.runUntil(&amp;raised, 30.seconds), "he is raised\n" ~ d.story);</code> | F |
| 775 | addr | <code>assert(d.runUntil(&amp;open, 200.seconds), "the event done again, the doors open\n" ~ d.story);</code> | F |
| 822 | addr | <code>assert(d.runUntil(&amp;open, 200.seconds), "the event done again after the restart\n" ~ d.story);</code> | F |
| 998 | addr | <code>assert(d.runUntil(&amp;grubbisDead, 600.seconds), format!"Grubbis comes and dies (she %s at %s)\n%s"(her.alive</code> | F |
| 1094 | addr | <code>assert(d.runUntil(&amp;suppressed, 90.seconds), "a suppressor reaches the Shade\n" ~ d.story);</code> | F |
| 1096 | addr | <code>assert(d.runUntil(&amp;failed, 25.seconds), "twenty seconds of suppression: the ritual fails\n" ~ d.story);</code> | F |
| 1115 | addr | <code>assert(d.runUntil(&amp;came, 60.seconds), "a suppressor\n" ~ d.story);</code> | F |
| 1236 | addr | <code>assert(d.runUntil(&amp;ported, 60.seconds), "his Shadow Portal\n" ~ d.story);</code> | F |
| 1355 | addr | <code>assert(d.runUntil(&amp;champion, 60.seconds), "a champion\n" ~ d.story);</code> | F |
| 1387 | addr | <code>assert(d.runUntil(&amp;done, 400.seconds), format!"the seven fall (round %s, tomb %s)\n%s"(d.saved!BlackrockDepths.dwarfRound, d.saved!BlackrockDepths.tomb, d.…</code> | F |
| 1415 | addr | <code>assert(d.runUntil(&amp;fighting, 60.seconds), "he breaks free and fights\n" ~ d.story);</code> | F |

### `source/dmangos/world/realscripts_world.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 59 | lookup | <code>if (m[1] !in found)</code> | B |
| 98 | lookup | <code>else if (const v = m[1] in local)</code> | A |
| 99 | deref | <code>quest = *v;</code> | D |
| 100 | lookup | <code>else if (const v = m[1] in global)</code> | A |
| 101 | deref | <code>quest = *v;</code> | D |
| 223 | lookup | <code>if (const other = c.entry in escortOf)</code> | A |
| 226 | deref | <code>npc = s.find(*other);</code> | D |
| 228 | deref | <code>return format!"no %s comes to walk"(*other);</code> | D |
| 235 | lookup | <code>if (const target = c.entry in leadsTo)</code> | A |
| 238 | deref | <code>leadTo = spawnOnContinent(data, *target, m);</code> | D |
| 255 | lookup | <code>const toUse = c.entry in objectsUsed;</code> | A |
| 271 | deref | <code>foreach (entry; *toUse)</code> | D |
| 273 | lookup | <code>if (go.guid !in used &amp;&amp; Scene.distance(go.position, npc.position) &lt; 20</code> | B |
| 299 | lookup | <code>if (const lines = c.entry in mustSay)</code> | A |
| 300 | deref | <code>foreach (line; *lines)</code> | D |
| 363 | lookup | <code>const knownWhy = key in known;</code> | A |
| 364 | deref | <code>const isKnown = knownWhy !is null &amp;&amp; outcome.canFind(*knownWhy);</code> | D |

### `source/dmangos/world/realspellsweep.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 76 | lookup | <code>if (spellId !in classOf)</code> | B |
| 99 | lookup | <code>if (spell !in classOf)</code> | B |
| 111 | lookup | <code>if (s is null &#124;&#124; id in known)</code> | A |
| 127 | lookup | <code>if (const c = id in classOf)</code> | A |
| 128 | lookup | <code>if (t !in classOf)</code> | B |
| 129 | deref | <code>classOf[t] = *c;</code> | D |
| 146 | deref | <code>if (s.attributes &amp; spellAttrPassive &#124;&#124; !castInPlay(*s))</code> | D |
| 149 | lookup | <code>if (const c = id in classOf)</code> | A |
| 150 | deref | <code>classId = *c;</code> | D |
| 151 | lookup | <code>else if (const c = s.casting.spellFamilyName in familyClass)</code> | A |
| 152 | deref | <code>classId = cast(ubyte)*c;</code> | D |
| 153 | lookup | <code>found ~= Sweepable(id, classId, (id in learned) is null &amp;&amp; (id in byTrigger) !is null);</code> | A |
| 231 | lookup | <code>if (s.casting.name !in firstRankByName)</code> | B |
| 241 | lookup | <code>if (form !in formSpell &#124;&#124; id &lt; formSpell[form])</code> | B |
| 255 | lookup | <code>if (auto found = key in itemCache)</code> | A |
| 256 | deref | <code>return *found;</code> | D |
| 290 | lookup | <code>if (auto found = key in creatureCache)</code> | A |
| 291 | deref | <code>return *found;</code> | D |
| 315 | lookup | <code>if (strict &amp;&amp; (t.minLevel + 4 &lt; top &#124;&#124; t.civilian &#124;&#124; t.npcFlags &#124;&#124; entry in data.creatureScriptNames</code> | A |
| 316 | lookup | <code>&#124;&#124; entry in data.eventAi.byCreature))</code> | A |
| 331 | return, type | <code>const(SpellInfo)* dispellable(int type, bool harmful)</code> | R |
| 333 | type | <code>const(SpellInfo)* best;</code> | P |
| 337 | deref | <code>if (s.casting.dispel != type &#124;&#124; !s.hasEffect(SpellEffect.applyAura) &#124;&#124; harms(*s) != harmful</code> | D |
| 518 | lookup | <code>if (const shift = form in choices.formSpell)</code> | A |
| 519 | deref | <code>me.castSpell(context.data.spells.spell(*shift), SpellTargets(TargetFlags.self, 0), true, 0);</code> | D |
| 527 | lookup | <code>if (const id = stealth in choices.firstRankByName)</code> | A |
| 528 | deref | <code>me.castSpell(context.data.spells.spell(*id), SpellTargets(TargetFlags.self, 0), true, 0);</code> | D |
| 556 | deref | <code>const isHostile = hostile(*s), isFriendly = friendly(*s) &#124;&#124; raises(*s);</code> | D |
| 558 | deref | <code>if (isHostile &#124;&#124; Character.usesComboPoints(*s))</code> | D |
| 560 | deref | <code>const entry = choices.enemyFor(*s);</code> | D |
| 563 | deref | <code>const r = range(*s, context.client);</code> | D |
| 592 | deref | <code>if (raises(*s))</code> | D |
| 603 | deref | <code>if (needsPet(*s) &#124;&#124; petSpell)</code> | D |
| 613 | lookup | <code>if (const first = s.casting.name in prerequisites)</code> | A |
| 614 | deref, lookup | <code>if (const id = *first in choices.firstRankByName)</code> | A |
| 615 | deref | <code>me.castSpell(context.data.spells.spell(*id), SpellTargets(TargetFlags.unit, enemy ? enemy : friend),</code> | D |
| 618 | deref | <code>if (Character.usesComboPoints(*s))</code> | D |
| 635 | deref | <code>const who = whoOf(*s, i, friend != 0);</code> | D |
| 681 | deref | <code>if (auto unit = unitOf(whoOf(*s, i, friend != 0), me, map, enemy, friend))</code> | D |
| 688 | deref | <code>const who = whoOf(*s, i, friend != 0);</code> | D |
| 737 | deref | <code>const comboPointsUsed = Character.usesComboPoints(*s) ? me.comboPoints : 0;</code> | D |
| 761 | deref | <code>if (isNextMeleeSwingSpell(*s) &amp;&amp; enemy)</code> | D |
| 777 | deref | <code>const total = castTime(*s, context.client, 60) + 3500</code> | D |
| 778 | deref | <code>+ ((s.attributesEx &amp; 0x44) ? min(10_000, max(0, duration(*s, context.client, 60))) : 0);</code> | D |
| 846 | deref | <code>const who = whoOf(*s, i, friend != 0);</code> | D |
| 863 | lookup | <code>auto seen = unitGuid in auraSeen[i];</code> | A |
| 871 | deref | <code>const expected = expectedDuration(*s, context.client, comboPointsUsed);</code> | D |
| 874 | deref | <code>if (expected != 0 &amp;&amp; (*seen &gt; expected &#124;&#124; *seen &lt; expected - early) &amp;&amp; !(s.attributesEx &amp; 0x44))</code> | D |
| 875 | deref | <code>problem(format!"effect %s: lasts %s ms, not %s"(i, *seen, expected));</code> | D |
| 951 | deref | <code>const cost = me.costOf(*s);</code> | D |
| 988 | lookup | <code>const t = cast(uint) entry in w.context.data.gameObjectTemplates;</code> | A |
| 1036 | deref | <code>const entry = choices.enemyFor(*context.data.spells.spell(spellTameBeast));</code> | D |
| 1065 | lookup | <code>if (const skill = itemSkill(entry in choices.data.items))</code> | A |
| 1141 | type | <code>private void putAura(Character me, UnitRef unit, const(SpellInfo)* spell)</code> | P |
| 1146 | deref | <code>const positive = !harms(*spell);</code> | D |
| 1148 | deref | <code>[effectValue(*spell, 0, 60, 0), effectValue(*spell, 1, 60, 0), effectValue(*spell, 2, 60, 0)]);</code> | D |
| 1275 | deref | <code>const caster = casterOf(data, client, *s, sw.classId);</code> | D |
| 1277 | lookup | <code>if (key !in sweepers)</code> | B |
| 1288 | lookup | <code>if (id !in known)</code> | B |
| 1292 | lookup | <code>if (id !in failed)</code> | B |

### `source/dmangos/world/realspelltests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 87 | addr | <code>auto clock = &amp;now;</code> | P |
| 88 | deref | <code>context.clock = () =&gt; *clock;</code> | D |
| 291 | deref | <code>set.apply(makeAura(info, 1, 60, 60_000, true, [effectValue(*info, 0, 60, 0), 0, 0]), values, isNew);</code> | D |
| 316 | deref | <code>assert(applySpellMod(me.player.auras.list, SpellModOp.damage, *w.context.data.spells.spell(fireball), 1000) == 1040,</code> | D |

### `source/dmangos/world/realsystems.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 22 | addr, deref, type | <code>uint at(size_t offset) { return *cast(const uint*) &amp;bytes[offset]; }</code> | X |
| 30 | addr, type | <code>names ~= fromStringz(cast(const(char)*) &amp;bytes[strings + at(row + 4 * 4)]).idup;</code> | X |
| 76 | lookup | <code>const t = entry in w.context.data.creatureTemplates;</code> | A |
| 106 | deref | <code>assert(auctionDeposit(*stormwind, minAuctionTime, 10_000, 1) == 500);</code> | D |
| 107 | deref | <code>assert(auctionDeposit(*stormwind, 4 * minAuctionTime, 10_000, 1) == 2000);</code> | D |
| 108 | deref | <code>assert(auctionDeposit(*stormwind, 12 * minAuctionTime, 10_000, 1) == 6000);</code> | D |
| 109 | deref | <code>assert(auctionDeposit(*goblins, minAuctionTime, 10_000, 1) == 2500);</code> | D |
| 110 | deref | <code>assert(auctionDeposit(*goblins, 12 * minAuctionTime, 10_000, 1) == 30_000);</code> | D |
| 112 | deref | <code>assert(a.cut(*stormwind) == 500 &amp;&amp; a.cut(*goblins) == 1500);</code> | D |
| 164 | lookup | <code>assert(listed.get(scarletCrusade, 99) == ReputationRank.friendly &amp;&amp; 529 in listed);</code> | A |
| 170 | lookup | <code>assert(me.player.auras.find(effect001) is null &amp;&amp; scarletCrusade !in me.forcedReactions);</code> | B |
| 204 | lookup | <code>assert(lords[side] in w.context.data.creatureTemplates);</code> | A |
| 217 | lookup | <code>if (const entry = guid in entryOf)</code> | A |
| 218 | deref | <code>kind[e[1]] = w.context.data.creatureTemplates[*entry].name;</code> | D |

### `source/dmangos/world/realworldpvp.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 27 | addr | <code>auto clock = &amp;w.now;</code> | P |
| 28 | deref | <code>w.context.clock = () =&gt; *clock;</code> | D |
| 133 | lookup | <code>const p = t.capturePoint in gameObjectTemplates;</code> | A |

### `source/dmangos/world/relations.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 34 | type | <code>const(FactionTemplateEntry)* template_;</code> | P |
| 45 | type | <code>const(ReputationRank[uint])* forced;</code> | P |
| 108 | type | <code>private int baseReputation(const Relating player, const(FactionEntry)* faction, out bool atWar) pure nothrow @nogc</code> | P |
| 118 | type | <code>ReputationRank factionReaction(const(FactionTemplateEntry)* self, const(FactionTemplateEntry)* other)</code> | P |
| 144 | type | <code>ReputationRank factionReaction(const(FactionTemplateEntry)* self, const Relating unit, const ClientData client)</code> | P |
| 152 | deref, lookup | <code>if (const rank = unit.forced is null ? null : self.faction in *unit.forced)</code> | A |
| 153 | deref | <code>return *rank;</code> | D |
| 193 | deref, lookup | <code>if (const rank = self.forced is null ? null : unit.template_.faction in *self.forced)</code> | A |
| 194 | deref | <code>return *rank;</code> | D |
| 281 | addr | <code>return Relating(flags &#124; (player ? UnitFlags.playerControlled : 0), &amp;templates[t - 1], player, 1, 1);</code> | R |
| 303 | addr | <code>Relating disguised = Relating(UnitFlags.playerControlled, &amp;templates[0], true, 1, 1);</code> | P |
| 304 | addr | <code>disguised.forced = &amp;disguise;</code> | P |

### `source/dmangos/world/replication.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 326 | addr | <code>m.spline = &amp;spline;</code> | P |
| 369 | addr | <code>block.spline = &amp;walk;</code> | P |
| 412 | addr | <code>m.spline = &amp;walk;</code> | P |
| 449 | addr | <code>block.spline = &amp;walk;</code> | P |
| 455 | addr | <code>block.spline = &amp;walk;</code> | P |

### `source/dmangos/world/reputation.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 87 | type | <code>uint defaultFlags(const(FactionEntry)* f) const</code> | P |
| 94 | type | <code>int baseOf(const(FactionEntry)* f) const</code> | P |
| 103 | return, type | <code>inout(FactionState)* stateOf(const(FactionEntry)* f) inout</code> | R |
| 107 | addr | <code>auto s = &amp;states[f.reputationListId];</code> | P |
| 112 | type | <code>int standingWith(const(FactionEntry)* f) const</code> | P |
| 126 | type | <code>ReputationRank rankWith(const(FactionEntry)* f) const</code> | P |
| 138 | type | <code>bool atWarWith(const(FactionEntry)* f) const</code> | P |
| 149 | type | <code>bool change(const(FactionEntry)* f, int standing, bool incremental, const(Spillover)[uint] spillovers,</code> | P |
| 155 | lookup | <code>if (const s = f.id in spillovers)</code> | A |
| 168 | type | <code>private bool changeOne(const(FactionEntry)* f, int standing, bool incremental)</code> | P |
| 183 | deref | <code>makeVisible(*state);</code> | D |
| 188 | deref | <code>setAtWar(*state, true);</code> | D |
| 203 | addr | <code>if (&amp;other is &amp;s)</code> | P |
| 211 | deref | <code>makeVisible(*s);</code> | D |
| 219 | addr | <code>auto s = &amp;states[listId];</code> | P |
| 222 | deref | <code>setAtWar(*s, on);</code> | D |
| 244 | addr | <code>auto s = &amp;states[listId];</code> | P |
| 268 | deref | <code>makeVisible(*s);</code> | D |
| 272 | deref | <code>setAtWar(*s, true);</code> | D |
| 274 | deref | <code>setAtWar(*s, false);</code> | D |
| 276 | deref | <code>setAtWar(*s, true);</code> | D |

### `source/dmangos/world/reputationhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 147 | lookup | <code>if (const rates = faction in context.data.reputationRates)</code> | A |
| 149 | deref | <code>const rate = (*rates)[source == ReputationSource.quest ? 0 : source == ReputationSource.kill ? 1 : 2];</code> | D |
| 168 | lookup | <code>const onKill = creatureEntry in context.data.onKillReputation;</code> | A |
| 429 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 475 | deref | <code>assert((*me.relatingNow().forced).get(defias, ReputationRank.hated) == ReputationRank.friendly);</code> | D |

### `source/dmangos/world/rituals.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 91 | type | <code>package static bool isRitualPortal(const(imported!"dmangos.world.gameobject".GameObjectTemplate)* t)</code> | P |
| 100 | type | <code>package void openRitualPortal(const(SpellInfo)* spell, size_t i)</code> | P |
| 103 | lookup | <code>const t = entry in context.data.gameObjectTemplates;</code> | A |

### `source/dmangos/world/scripttests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 49 | addr | <code>auto smite = context.makeCreature(&amp;spawn);</code> | CS |
| 83 | addr | <code>auto moved = elsewhere.makeCreature(&amp;spawn);</code> | CS |
| 319 | addr | <code>auto him = context.makeCreature(&amp;spawn);</code> | CS |
| 361 | addr | <code>auto v = &amp;(cast(Player) warlock.session.character).values;</code> | P |
| 364 | lookup | <code>warlock.session.inWorld.castSpell((1454 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), true, 0);</code> | A |
| 369 | lookup | <code>warlock.session.inWorld.castSpell((1454 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), true, 0);</code> | A |
| 434 | addr | <code>auto her = context.makeCreature(&amp;spawn);</code> | CS |
| 485 | addr | <code>auto creature = there.makeCreature(&amp;spawn);</code> | CS |
| 523 | addr | <code>auto victim = context.makeCreature(&amp;spawn);</code> | CS |
| 529 | lookup | <code>auto aura = makeAura((980 in context.data.spells.spells), warlock.session.character.guid, 10, 24_000, false, [7, 0, 0]);</code> | A |
| 595 | addr | <code>auto mob = source.makeCreature(&amp;spawn);</code> | CS |
| 628 | addr | <code>auto across = destination.makeCreature(&amp;acrossSpawn);</code> | CS |
| 694 | addr | <code>auto drained = source.makeCreature(&amp;spawn);</code> | CS |
| 732 | deref | <code>auto channel = cast(SpellInfo) *source.data.spells.spell(leechLife);</code> | D |
| 745 | addr, deref, type | <code>spellRange[2] = *cast(const uint*) &amp;thirtyYards;</code> | U |
| 808 | addr | <code>auto boss = context.makeCreature(&amp;spawn);</code> | CS |
| 814 | lookup | <code>boss.ai.spellEffectScript((9204 in context.data.spells.spells), 0, guid, 0);</code> | A |
| 1080 | addr | <code>auto twiggy = context.makeCreature(&amp;spawn);</code> | CS |
| 1109 | addr | <code>auto cub = context.makeCreature(&amp;mistSpawn);</code> | CS |
| 1411 | addr | <code>auto caller = context.makeCreature(&amp;spawn);</code> | CS |
| 1445 | addr | <code>auto marked = context.makeCreature(&amp;spawn);</code> | CS |
| 1459 | lookup | <code>marked.auras.apply(makeAura(99_002 in context.data.spells.spells, 7, 10, 100, false, [0, 0, 0]), marked.values, isNew);</code> | A |

### `source/dmangos/world/session.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 385 | ptr | <code>if (memory.ptr is buffer.ptr)</code> | I |
| 996 | lookup | <code>if (auto s = account in mesh.remotes.require(owner, null))</code> | A |
| 1130 | type | <code>void whisperTo(TestClient* target)</code> | P |
| 1137 | addr | <code>whisperTo(&amp;gm);</code> | P |
| 1140 | addr | <code>whisperTo(&amp;gm);</code> | P |
| 1193 | lookup | <code>if (auto s = account in mesh.remotes.require(owner, null))</code> | A |
| 1312 | lookup | <code>if (auto s = account in mesh.remotes.require(owner, null))</code> | A |

### `source/dmangos/world/sessionscripting.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 18 | type | <code>private const(SpellInfo)* scriptSpell;</code> | P |
| 24 | type | <code>package bool spellEffectScript(const(SpellInfo)* spell, size_t i, ulong target, int value)</code> | P |
| 39 | type | <code>package void auraAppliedScript(const(SpellInfo)* spell, size_t i, ulong target, int amount)</code> | P |
| 56 | type | <code>package int auraTickScript(const(SpellInfo)* spell, size_t i, ulong target, uint tick, uint ticks, int amount)</code> | P |
| 77 | type | <code>package bool spellScriptEvent(E)(const(SpellInfo)* spell, const auto ref E event, out CastRefusal refusal)</code> | P |
| 93 | type | <code>package void spellScriptEvent(E)(const(SpellInfo)* spell, const auto ref E event)</code> | P |
| 132 | addr | <code>if (player.inventory.canStoreNew(nullBag, nullSlot, dest, entry, count, &amp;noSpace) != InventoryResult.ok)</code> | OPT |
| 151 | lookup | <code>if (auto q = quest in player.questStatus)</code> | A |
| 204 | deref | <code>: effectValue(*scriptSpell, effect, player.data.level, uniform01(map.random));</code> | D |

### `source/dmangos/world/social.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 334 | type | <code>FriendsResult statusResult(TestClient* c)</code> | P |
| 343 | addr | <code>assert(statusResult(&amp;anduin) == FriendsResult.addedOnline);</code> | P |
| 346 | addr | <code>assert(statusResult(&amp;anduin) == FriendsResult.already);</code> | P |
| 348 | addr | <code>assert(statusResult(&amp;anduin) == FriendsResult.self);</code> | P |
| 350 | addr | <code>assert(statusResult(&amp;anduin) == FriendsResult.notFound);</code> | P |
| 355 | addr | <code>assert(statusResult(&amp;anduin) == FriendsResult.offline, "she went offline");</code> | P |
| 359 | addr | <code>assert(statusResult(&amp;anduin) == FriendsResult.online, "back online");</code> | P |
| 363 | addr | <code>assert(statusResult(&amp;jaina) == FriendsResult.ignoreAdded);</code> | P |
| 377 | addr | <code>assert(statusResult(&amp;jaina) == FriendsResult.ignoreRemoved &amp;&amp; db.loadSocial(8).length == 0);</code> | P |

### `source/dmangos/world/spellareas.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 21 | type | <code>const(SpellInfo)* spell;</code> | P |
| 34 | type | <code>void makePersistentArea(ref Caster caster, ref PersistentArea[] areas, const(SpellInfo)* spell, size_t i,</code> | P |
| 42 | deref | <code>const r = caster.spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client)),</code> | D |
| 43 | deref | <code>ms = caster.modDuration(spell, duration(*spell, context.client, caster.level));</code> | D |
| 64 | deref | <code>: effectValue(*area.spell, j, caster.level, uniform01(caster.map.random));</code> | D |
| 82 | deref | <code>tick += cast(int)(done * bonusCoefficient(*area.spell, area.effect, caster.context.client, caster.level));</code> | D |
| 104 | deref | <code>const r = radius(*area.spell, area.effect, caster.context.client);</code> | D |
| 130 | lookup | <code>if (guid in area.holding)</code> | B |
| 159 | lookup | <code>if (guid !in inArea)</code> | B |
| 176 | type | <code>private void loseAreaAura(ref Caster caster, ulong guid, const(SpellInfo)* spell)</code> | P |
| 202 | type | <code>void endPersistentAreas(ref Caster caster, ref PersistentArea[] areas, const(SpellInfo)* spell = null)</code> | P |

### `source/dmangos/world/spellauras.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 20 | type | <code>bool isAuraEffect(const(SpellInfo)* spell, size_t j, ubyte effects = 0) pure nothrow @nogc @safe</code> | P |
| 39 | type | <code>AuraCast auraCast(ref Caster caster, const(SpellInfo)* spell, ubyte effects)</code> | P |
| 50 | deref | <code>a.ms = caster.modDuration(spell, duration(*spell, caster.context.client, caster.level));</code> | D |
| 61 | deref | <code>a.values[j] += cast(int)(done * bonusCoefficient(*spell, j, caster.context.client, caster.level));</code> | D |
| 77 | type | <code>void applyAura(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, ubyte effects)</code> | P |
| 111 | deref | <code>aura.setHeartbeatResist(heartbeatResistChance(caster.fighter, target.fighter, *spell,</code> | D |
| 194 | deref | <code>imported!"dmangos.world.creatureai".assistThreat(map, who.threateners, caster.unit, 0, *spell);</code> | D |
| 216 | lookup | <code>const t = cast(uint) misc in caster.context.data.creatureTemplates;</code> | A |
| 217 | deref | <code>aura.amount[j] = t is null ? pinkPig : cast(int) chooseDisplay(*t, map.random);</code> | D |
| 385 | type | <code>private uint creaturePeriodicDamage(UnitRef victim, const(SpellInfo)* spell, uint level, uint amount, int resistance)</code> | P |
| 396 | deref | <code>return partiallyResisted(amount, resistance, level, victim.fighter, isBinarySpell(*spell),</code> | D |
| 539 | type | <code>void dispel(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, int count)</code> | P |
| 602 | type | <code>void dispelMechanic(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, int value)</code> | P |

### `source/dmangos/world/spellcast.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 281 | lookup | <code>if (auto row = spell.id in client.spellCoefficients)</code> | A |
| 283 | deref | <code>const c = (*row)[i];</code> | D |
| 364 | addr | <code>const c = &amp;spell.casting;</code> | P |
| 385 | type | <code>basePoints += lo + cast(int)(roll * (hi - lo + 1) - 0.0001f &gt; 0 ? roll * (hi - lo + 1) - 0.0001f : 0);</code> | P |
| 393 | addr | <code>const c = &amp;spell.casting;</code> | P |
| 398 | type | <code>cost += cast(int) c.manaCostPerLevel * (rankLevel / 5 - cast(int) c.baseLevel);</code> | P |
| 455 | type | <code>ubyte[] castResultPacket(uint spell, SpellCastResult result, const SpellInfo* info = null)</code> | P |

### `source/dmangos/world/spelldamage.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 52 | type | <code>float directCoefficient(ref Caster caster, const(SpellInfo)* spell, bool heal)</code> | P |
| 59 | deref | <code>return bonusCoefficient(*spell, i, caster.context.client, caster.level);</code> | D |
| 67 | type | <code>uint spellDamageBonus(ref Caster caster, const(SpellInfo)* spell, uint school)</code> | P |
| 76 | type | <code>uint healingBonus(ref Caster caster, const(SpellInfo)* spell)</code> | P |
| 103 | type | <code>uint spellDamage(ref Caster caster, const(SpellInfo)* spell, UnitRef victim, uint damage, uint school,</code> | P |
| 130 | deref | <code>const victimCrit = victimAuras is null &#124;&#124; Caster.weaponCrit(spell) ? 0 : spellCritTaken(*victimAuras, school);</code> | D |
| 137 | deref | <code>else if (school != 1 &amp;&amp; !isBinarySpell(*spell))</code> | D |
| 286 | type | <code>bool creatureTargetInRange(const(SpellInfo)* spell, const imported!"dmangos.world.combat".Fighter caster,</code> | P |
| 291 | deref | <code>const r = range(*spell, client);</code> | D |
| 298 | type | <code>void rollRemoteAreaDamage(ref AreaDamage hit, const(SpellInfo)* spell, UnitRef victim)</code> | P |
| 319 | addr | <code>auto rng = &amp;victim.map.random();</code> | P |
| 324 | deref | <code>hit.miss = rollSpellHit(caster, target, *spell, resistance, hit.hitBonus, *rng);</code> | D |
| 333 | deref | <code>&amp;&amp; uniform01(*rng) * 100 &lt; hit.critChance + frozenBonus + spellCritTaken(*victim.auraSet, school);</code> | D |
| 336 | deref | <code>if (school != 1 &amp;&amp; !isBinarySpell(*spell))</code> | D |
| 339 | deref | <code>uniform!"[]"(1u, 10000u, *rng));</code> | D |
| 392 | type | <code>uint rollHealing(ref Caster caster, const(SpellInfo)* spell, int value, out bool critical,</code> | P |
| 406 | type | <code>uint applyHealAmount(const(SpellInfo)* spell, UnitRef target, uint amount, out uint restored)</code> | P |
| 428 | type | <code>uint spellHeal(ref Caster caster, const(SpellInfo)* spell, UnitRef target, int value, SpellHeal how = SpellHeal.init)</code> | P |
| 468 | deref | <code>p.procAuras(spellProcFlags(*spell, true, false), target, hit);</code> | D |
| 471 | deref | <code>caster.ai.procAuras(spellProcFlags(*spell, true, false), target, hit);</code> | D |
| 480 | deref | <code>threat &gt; 0 ? threat : 0, *spell);</code> | D |
| 527 | addr | <code>auto v = &amp;who.creature.values;</code> | P |
| 536 | type | <code>void energize(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef target, int value)</code> | P |
| 550 | type | <code>float effectMultiplier(ref Caster caster, const(SpellInfo)* spell, size_t i)</code> | P |
| 574 | type | <code>void logExecute(ref Caster caster, const(SpellInfo)* spell, size_t i, const(ubyte)[] targetData)</code> | P |
| 588 | type | <code>void powerBurn(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef victim, int value)</code> | P |
| 609 | type | <code>void powerDrain(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef victim, int value)</code> | P |
| 639 | type | <code>void healthLeech(ref Caster caster, const(SpellInfo)* spell, size_t i, UnitRef victim, int value)</code> | P |
| 655 | type | <code>void healMaxHealth(ref Caster caster, const(SpellInfo)* spell, UnitRef target)</code> | P |
| 678 | deref | <code>p.procAuras(spellProcFlags(*spell, true, false), target, hit);</code> | D |
| 680 | deref | <code>caster.ai.procAuras(spellProcFlags(*spell, true, false), target, hit);</code> | D |

### `source/dmangos/world/spelleffects.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 22 | type | <code>const(SpellInfo)* spell;</code> | P |
| 69 | type | <code>imported!"dmangos.world.spellcast".SpellMissInfo rollHit(ref Caster caster, const(SpellInfo)* spell, UnitRef target)</code> | P |
| 76 | deref | <code>return rollSpellHit(caster.fighter, target.fighter, *spell, caster.targetResistance(target.resistance(school),</code> | D |
| 120 | type | <code>private void notDone(ref Caster caster, const(SpellInfo)* spell, size_t i)</code> | P |
| 126 | lookup | <code>if (effect in told[caster.kind])</code> | A |
| 137 | type | <code>void applyEffect(ref Caster caster, const(SpellInfo)* spell, size_t i, ulong target, ref SpellCast c, uint bounce = 0)</code> | P |
| 206 | deref | <code>const ms = p.modDuration(spell, duration(*spell, context.client, caster.level));</code> | D |
| 236 | lookup | <code>else if (p.isRitualPortal(cast(uint) spell.miscValue[i] in context.data.gameObjectTemplates))</code> | A |
| 238 | lookup | <code>else if (p.isFishingBobber(cast(uint) spell.miscValue[i] in context.data.gameObjectTemplates))</code> | A |
| 341 | deref | <code>const lockMs = duration(*spell, context.client, caster.level);</code> | D |
| 363 | lookup | <code>else if (auto d = target in c.weaponRolls)</code> | A |
| 364 | deref | <code>ai.weaponSpellDamage(spell, i, target, *d, value);</code> | D |
| 525 | addr, type | <code>ubyte* owed = p !is null ? &amp;p.extraAttacks : &amp;ai.extraAttacks;</code> | P |
| 526 | deref | <code>*owed = cast(ubyte)(*owed + value &gt; 5 ? 5 : *owed + value);</code> | D |

### `source/dmangos/world/spellhandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 59 | type | <code>const(SpellInfo)* spell;</code> | P |
| 70 | type | <code>const(SpellInfo)* channelSpell;</code> | P |
| 104 | type | <code>const(SpellInfo)* spell;</code> | P |
| 151 | deref | <code>if (targets.unit &amp;&amp; targets.unit != player.guid &amp;&amp; !isCasterCenteredClusterSpell(*spell))</code> | D |
| 155 | deref | <code>&amp;&amp; isPlayerHandoffSpell(*spell))</code> | D |
| 203 | addr | <code>if ((spell.attributesEx &amp; channels) &#124;&#124; isNextMeleeSwingSpell(spell) &#124;&#124; autoRepeats(&amp;spell))</code> | P |
| 236 | type | <code>private void handoffPlayerSpell(const(SpellInfo)* spell, const ref SpellTargets targets, const(Replica) replica)</code> | P |
| 337 | type | <code>private const(SpellInfo)* autoRepeat;</code> | P |
| 346 | type | <code>private bool ammoFor(const(SpellInfo)* spell, out uint entry)</code> | P |
| 371 | type | <code>private bool hasAmmoFor(const(SpellInfo)* spell)</code> | P |
| 378 | type | <code>private void takeAmmo(const(SpellInfo)* spell)</code> | P |
| 400 | lookup | <code>if (auto at = spell in spellReadyAt)</code> | A |
| 401 | deref | <code>if (now &lt; *at)</code> | D |
| 405 | lookup | <code>if (auto at = info.category in categoryReadyAt)</code> | A |
| 406 | deref | <code>if (now &lt; *at)</code> | D |
| 440 | type | <code>package void startCooldown(const(SpellInfo)* spell)</code> | P |
| 446 | type | <code>static bool autoRepeats(const(SpellInfo)* spell) pure nothrow @nogc @safe</code> | P |
| 453 | type | <code>private SpellCastResult startAutoRepeat(const(SpellInfo)* spell, SpellTargets targets)</code> | P |
| 544 | type | <code>package SpellCastResult castSpell(const(SpellInfo)* spell, SpellTargets targets, bool triggered, uint itemEntry,</code> | P |
| 583 | deref | <code>castTime(*spell, context.client, player.data.level)) * player.auras.castTimeFactor()));</code> | D |
| 592 | deref | <code>if (isNextMeleeSwingSpell(*spell))</code> | D |
| 603 | type | <code>private Replica remoteLeechTarget(const(SpellInfo)* spell, ulong target)</code> | P |
| 607 | deref | <code>if (context.sendAreaDamage is null &#124;&#124; !target &#124;&#124; map.unit(target) &#124;&#124; !isRemoteLeechChannel(*spell))</code> | D |
| 676 | type | <code>package bool missileOnTheWay(const(SpellInfo)* spell, ulong target)</code> | P |
| 699 | type | <code>bool resisted(const(SpellInfo)* spell)</code> | P |
| 783 | type | <code>void startChannel(const(SpellInfo)* spell, ulong target)</code> | P |
| 787 | deref | <code>const ms = modDuration(spell, duration(*spell, context.client, player.data.level));</code> | D |
| 819 | type | <code>package ulong channelledAt(const(SpellInfo)* spell)</code> | P |
| 824 | type | <code>package bool channelActiveAt(const(SpellInfo)* spell, ulong target)</code> | P |
| 829 | type | <code>private const(SpellInfo)* lastChannelSpell;</code> | P |
| 861 | type | <code>package void makeFarSightSpot(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)</code> | P |
| 871 | deref | <code>radius(*spell, i, context.client), at);</code> | D |
| 995 | type | <code>package static bool isFishingBobber(const(imported!"dmangos.world.gameobject".GameObjectTemplate)* t)</code> | P |
| 1005 | type | <code>package void transmitObject(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)</code> | P |
| 1012 | lookup | <code>if (entry !in context.data.gameObjectTemplates)</code> | B |
| 1019 | deref | <code>const r = range(*spell, context.client);</code> | D |
| 1020 | deref | <code>const distance = spell.casting.radiusIndex[i] &amp;&amp; spell.casting.speed == 0 ? radius(*spell, i, context.client)</code> | D |
| 1025 | deref | <code>const ms = modDuration(spell, duration(*spell, context.client, player.data.level));</code> | D |
| 1035 | type | <code>package void castBobber(const(SpellInfo)* spell, size_t i)</code> | P |
| 1044 | lookup | <code>const t = entry in context.data.gameObjectTemplates;</code> | A |
| 1047 | deref | <code>auto r = range(*spell, context.client);</code> | D |
| 1076 | deref | <code>const ms = modDuration(spell, duration(*spell, context.client, player.data.level));</code> | D |
| 1108 | type | <code>package void makePersistentArea(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, int value)</code> | P |
| 1131 | type | <code>int flightTime(const(SpellInfo)* spell, ulong target)</code> | P |
| 1259 | addr | <code>loot.fill(template_, context.data.loot, context.data.items, map.random, &amp;meets, &amp;allowed);</code> | F |
| 1334 | type | <code>bool hasItemFitToSpell(const(SpellInfo)* spell)</code> | P |
| 1365 | type | <code>SpellCastResult checkCast(const(SpellInfo)* spell, const ref SpellTargets targets, bool triggered, uint itemEntry,</code> | P |
| 1372 | deref | <code>if (!triggered &amp;&amp; usesComboPoints(*spell)</code> | D |
| 1386 | addr | <code>const values = other.kind == UnitKind.creature ? &amp;other.creature.values : &amp;other.session.player.values;</code> | P |
| 1406 | lookup | <code>if (const at = spell.id in spellReadyAt)</code> | A |
| 1407 | deref | <code>if (*at &gt; now)</code> | D |
| 1412 | lookup | <code>if (const at = category in categoryReadyAt)</code> | A |
| 1413 | deref | <code>if (*at &gt; now &amp;&amp; !cooldownCheat)</code> | D |
| 1473 | deref | <code>const cost = costOf(*spell);</code> | D |
| 1517 | type | <code>SpellCastResult crowdControlRefusal(const(SpellInfo)* spell)</code> | P |
| 1550 | type | <code>SpellCastResult checkCastAttributes(const(SpellInfo)* spell, const ref SpellTargets targets)</code> | P |
| 1614 | lookup | <code>if ((spell.id in context.data.spellFacing) &amp;&amp; !hasInArc(me, it))</code> | A |
| 1758 | addr | <code>int cost = spellMod(SpellModOp.cost, &amp;spell, powerCost(spell, level, createMana, createHealth, maxPower));</code> | P |
| 1762 | type | <code>cost = cost * (100 + percent) / 100;</code> | P |
| 1767 | type | <code>SpellCastResult checkTarget(const(SpellInfo)* spell, const ref SpellTargets targets, bool triggered = false,</code> | P |
| 1842 | addr | <code>const fields = &amp;targetReplica.fieldsOf();</code> | P |
| 1863 | deref | <code>auto r = range(*spell, context.client);</code> | D |
| 1922 | deref | <code>const cost = costOf(*spell);</code> | D |
| 1963 | deref | <code>&amp;&amp; !(c.targets.mask &amp; TargetFlags.sourceLocation) &amp;&amp; isHostileAreaEffect(*spell, i);</code> | D |
| 1987 | deref | <code>const chainDamage = isHostileChainEffect(*spell, i);</code> | D |
| 2021 | deref | <code>const chainHeal = isChainHealEffect(*spell, i);</code> | D |
| 2070 | deref | <code>z: center.z, radius: spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client)));</code> | D |
| 2075 | lookup | <code>if (target !in missOf)</code> | B |
| 2077 | deref | <code>missOf[target] = c.custom.alwaysHits ? SpellMissInfo.none : rollHit(*spell, target);</code> | D |
| 2110 | lookup | <code>if (remote.heal.target !in missOf)</code> | B |
| 2137 | deref | <code>castCombo = !c.triggered &amp;&amp; usesComboPoints(*spell) ? comboPoints : 0;</code> | D |
| 2187 | deref | <code>if (!(spell.attributesEx &amp; (channeled &#124; selfChanneled)) &amp;&amp; !autoRepeats(spell) &amp;&amp; !isNextMeleeSwingSpell(*spell))</code> | D |
| 2207 | deref | <code>procAuras(spellProcFlags(*spell, !harmful, false), first, ProcHit(spell, ProcEx.castEnd, 0, 0, harmful));</code> | D |
| 2270 | addr | <code>return dmangos.world.spelleffects.rollHit(me, &amp;spell, target == player.guid ? UnitRef.init : map.unit(target));</code> | R |
| 2291 | type | <code>private void sendRolledAreaDamage(const(SpellInfo)* spell, const ref Casting c, ref RemoteAreaDamage remote)</code> | P |
| 2300 | addr | <code>auto hit = &amp;remote.hit;</code> | P |
| 2308 | lookup | <code>if (const proto = copy.fields.get!OBJECT_FIELD_ENTRY in context.data.creatureTemplates)</code> | A |
| 2322 | deref | <code>context.sendReplicaSpell(map, remote.peer, spell, *hit);</code> | D |
| 2326 | type | <code>package void castProcAtReplica(const(SpellInfo)* spell, Replica target,</code> | P |
| 2353 | deref | <code>if (!isTargetedProcEffect(*spell, i))</code> | D |
| 2355 | deref | <code>const within = spellMod(SpellModOp.range, spell, range(*spell, context.client)[1]);</code> | D |
| 2376 | deref | <code>const mask = remoteTargetAuraEffects(*spell, i);</code> | D |
| 2400 | type | <code>private void updateReplicaChannel(const(SpellInfo)* spell, Replica target, int remaining)</code> | P |
| 2407 | type | <code>private void collectPartyHeals(const(SpellInfo)* spell, size_t i, ref RemotePartyHeal[] found)</code> | P |
| 2411 | deref | <code>if (!isPartyHealEffect(*spell, i))</code> | D |
| 2419 | deref | <code>radius: spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client))};</code> | D |
| 2432 | type | <code>private void sendRolledPartyHeal(const(SpellInfo)* spell, const ref Casting c, ref RemotePartyHeal remote)</code> | P |
| 2455 | type | <code>void doEffect(const(SpellInfo)* spell, size_t i, ulong target, ref Casting c, uint bounce = 0)</code> | P |
| 2469 | type | <code>package int effectAmount(const(SpellInfo)* spell, size_t i)</code> | P |
| 2471 | deref | <code>int base = effectCustom.has(i) ? effectCustom.values[i] : effectValue(*spell, i, player.data.level, uniform01(map.random));</code> | D |
| 2517 | type | <code>package void instakill(const(SpellInfo)* spell, ulong target)</code> | P |
| 2557 | lookup | <code>if (const at = spellId in spellReadyAt)</code> | A |
| 2558 | deref | <code>if (*at &gt; now)</code> | D |
| 2559 | deref | <code>r.spellExpires = unixNow + (*at - now).total!"seconds" + 1;</code> | D |
| 2561 | lookup | <code>if (const at = category in categoryReadyAt)</code> | A |
| 2562 | deref | <code>if (*at &gt; now)</code> | D |
| 2565 | deref | <code>r.categoryExpires = unixNow + (*at - now).total!"seconds" + 1;</code> | D |
| 2598 | lookup | <code>const spellLeft = spellId in spellReadyAt ? spellReadyAt[spellId] - now : Duration.zero;</code> | A |
| 2599 | lookup | <code>const categoryLeft = category &amp;&amp; category in categoryReadyAt ? categoryReadyAt[category] - now</code> | A |
| 2659 | type | <code>package int modDuration(const(SpellInfo)* spell, int ms)</code> | P |
| 2668 | type | <code>private void startCooldown(const(SpellInfo)* spell, uint itemEntry, MonoTime now)</code> | P |
| 2673 | lookup | <code>if (const proto = itemEntry in context.data.items)</code> | A |
| 2767 | type | <code>package void holdForCooldownEvent(const(SpellInfo)* spell)</code> | P |
| 2769 | lookup | <code>if (spell.id !in eventCooldowns)</code> | B |
| 2781 | type | <code>package void cooldownEvent(const(SpellInfo)* spell)</code> | P |
| 2783 | lookup | <code>const item = spell.id in eventCooldowns;</code> | A |
| 2786 | deref | <code>const itemEntry = *item;</code> | D |
| 2797 | type | <code>package T spellMod(T)(SpellModOp op, const(SpellInfo)* spell, T value)</code> | P |
| 2799 | deref | <code>const modified = applySpellMod(player.auras.list, op, *spell, value);</code> | D |
| 2815 | type | <code>private void noteChargedMods(SpellModOp op, const(SpellInfo)* spell)</code> | P |
| 2828 | deref | <code>&amp;&amp; (aura.effects &amp; (1 &lt;&lt; i)) &amp;&amp; affects(aura, i, *spell))</code> | D |
| 2845 | type | <code>private void spendChargedMods(const(SpellInfo)* spell, const(Aura)[] hadAtStart, bool triggered)</code> | P |
| 2868 | type | <code>package int effectMod(const(SpellInfo)* spell, size_t i, int value)</code> | P |
| 2874 | type | <code>package void dispelEffect(const(SpellInfo)* spell, size_t i, ulong target, int count)</code> | P |
| 2906 | type | <code>package void resurrectEffect(const(SpellInfo)* spell, size_t i, ulong target, int value, const ref Casting c)</code> | P |
| 2919 | addr | <code>const v = &amp;other.player.values;</code> | P |
| 2945 | type | <code>package float spellHitBonusOf(const(SpellInfo)* spell)</code> | P |
| 2955 | type | <code>package float critChanceOf(const(SpellInfo)* spell, UnitRef victim)</code> | P |
| 2965 | type | <code>static bool weaponCrit(const(SpellInfo)* spell)</code> | P |
| 2971 | type | <code>package uint critDamage(const(SpellInfo)* spell, uint damage)</code> | P |
| 2978 | type | <code>package float spellCritOf(const(SpellInfo)* spell)</code> | P |
| 3013 | type | <code>static bool isAreaTarget(const(SpellInfo)* spell, size_t i)</code> | P |
| 3033 | type | <code>private ulong scriptTargetNear(const(SpellInfo)* spell)</code> | P |
| 3037 | lookup | <code>const entries = spell.id in context.data.spellScriptTargets;</code> | A |
| 3040 | deref | <code>auto r = range(*spell, context.client)[1];</code> | D |
| 3051 | deref | <code>foreach (entry; *entries)</code> | D |
| 3071 | type | <code>ulong[] areaTargets(const(SpellInfo)* spell, size_t i, const ref SpellTargets targets, bool remoteEnemies = false)</code> | P |
| 3079 | deref | <code>const r = spellMod(SpellModOp.radius, spell, radius(*spell, i, context.client));</code> | D |
| 3216 | lookup | <code>if (guid in taken &#124;&#124; (group !is null &amp;&amp; !group.isMember(guid)) &#124;&#124; !assistable(guid))</code> | B |
| 3232 | lookup | <code>if (guid in taken &#124;&#124; !group.isMember(guid) &#124;&#124; context.onlinePlayer(guid) !is null &#124;&#124; duelingWith(guid))</code> | B |
| 3271 | lookup | <code>if (d &lt;= best &amp;&amp; guid !in taken)</code> | B |
| 3302 | type | <code>package uint spellDamageToPlayer(const(SpellInfo)* spell, typeof(this) other, uint damage, bool withBonus = true,</code> | P |
| 3315 | type | <code>package uint spellDamageBonus(const(SpellInfo)* spell, uint school)</code> | P |
| 3369 | type | <code>package uint healingBonus(const(SpellInfo)* spell)</code> | P |
| 3389 | addr | <code>const mods = &amp;player.damageMods;</code> | P |
| 3405 | type | <code>package uint spellDamage(const(SpellInfo)* spell, Creature victim, uint damage, uint school, bool withBonus = true,</code> | P |
| 3421 | type | <code>package void weaponSpellDamage(const(SpellInfo)* spell, size_t i, UnitRef victim, int value)</code> | P |
| 3439 | deref | <code>const v = j == i ? value : effectMod(spell, j, effectValue(*spell, j, player.data.level, uniform01(map.random)));</code> | D |
| 3498 | type | <code>private void harmlessHitProcs(const(SpellInfo)* spell, const(ulong)[] landed)</code> | P |
| 3519 | deref | <code>procAuras(spellProcFlags(*spell, false, false), victim, ProcHit(spell, ProcEx.normalHit, 0, 0, false));</code> | D |
| 3525 | type | <code>package void spellHitProcs(const(SpellInfo)* spell, UnitRef victim, bool crit, uint damage, ubyte hand = 0)</code> | P |
| 3532 | deref | <code>const flags = spellProcFlags(*spell, false, false);</code> | D |
| 3543 | type | <code>private void landedWithoutDamageProcs(const(SpellInfo)* spell, bool triggered, const(ulong)[] landed)</code> | P |
| 3559 | deref | <code>procAuras(spellProcFlags(*spell, true, false), other, ProcHit(spell, ProcEx.normalHit, 0, 0, false));</code> | D |
| 3566 | type | <code>void spellAttacked(Creature victim, uint damage, bool tick = false, uint school = 0, const(SpellInfo)* spell = null)</code> | P |
| 3580 | type | <code>package void heal(const(SpellInfo)* spell, ulong target, int value)</code> | P |
| 3600 | type | <code>package void summonCompanion(const(SpellInfo)* spell, size_t i)</code> | P |
| 3620 | deref | <code>const ms = duration(*spell, context.client, player.data.level);</code> | D |
| 3651 | type | <code>package void teleportUnits(const(SpellInfo)* spell, size_t i, ref Casting c)</code> | P |
| 3662 | lookup | <code>if (const to = spell.id in context.data.spellTargets)</code> | A |
| 3743 | addr, deref, type | <code>radiusRow[1] = *cast(const uint*) &amp;radius;</code> | U |
| 3798 | lookup | <code>protectedTarget.addAura(makeAura(protection in owner.data.spells.spells, 9, 20, -1, true, [-50, 0, 0]));</code> | A |
| 3827 | lookup | <code>targets[12].session.inWorld.addAura(makeAura(shield in owner.data.spells.spells, 12, 20, -1, true, [0, 0, 0]));</code> | A |
| 3923 | addr, deref, type | <code>rangeRow[2] = *cast(const uint*) &amp;range;</code> | U |
| 4020 | lookup | <code>third.session.inWorld.addAura(makeAura(shield in owner.data.spells.spells, 10, 40, -1, true, [0, 0, 0]));</code> | A |
| 4116 | addr, deref, type | <code>rangeRow[2] = *cast(const uint*) &amp;range;</code> | U |
| 4160 | lookup | <code>second.session.inWorld.addAura(makeAura(reduced in owner.data.spells.spells, 9, 40, -1, false, [-50, 0, 0]));</code> | A |
| 4287 | addr, deref, type | <code>radiusRow[1] = *cast(const uint*) &amp;radius;</code> | U |
| 4346 | addr | <code>auto mob = owner.makeCreature(&amp;spawn);</code> | CS |
| 4376 | lookup | <code>caster.session.inWorld.addAura(makeAura(healProc in origin.data.spells.spells, 7, 20, -1, true, [0, 0, 0]));</code> | A |
| 4403 | lookup | <code>caster.session.inWorld.addAura(makeAura(echo in origin.data.spells.spells, 7, 20, -1, true, [0, 0, 0]));</code> | A |
| 4405 | lookup | <code>mob.receiveAura(makeAura(retaliation in owner.data.spells.spells, mob.guid, 20, -1, true, [0, 0, 0]),</code> | A |
| 4431 | lookup | <code>assert(!mob.alive &amp;&amp; mob.loot !is null &amp;&amp; 7UL in mob.loot.owners);</code> | A |
| 4478 | addr, deref, type | <code>const areaBits = *cast(const uint*) &amp;area;</code> | U |
| 4527 | lookup | <code>caster.session.inWorld.addAura(makeAura(healerAura in origin.data.spells.spells, healer.guid, 1, -1, true, [50, 0, 0]));</code> | A |
| 4528 | lookup | <code>remote.session.inWorld.addAura(makeAura(reduced in owner.data.spells.spells, other.guid, 1, -1, false, [-50, 0, 0]));</code> | A |
| 4628 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 4647 | addr | <code>auto origin = newCreationContext(db, &amp;configure), owner = newCreationContext(db, &amp;configure);</code> | F |
| 4872 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 4928 | lookup | <code>assert(session.castSpell((finisher in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid),</code> | A |
| 4935 | lookup | <code>session.castSpell((builder in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid), false, 0);</code> | A |
| 4941 | lookup | <code>session.castSpell((builder in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid), false, 0);</code> | A |
| 4946 | lookup | <code>assert(session.castSpell((finisher in context.data.spells.spells), SpellTargets(TargetFlags.unit, keeper.guid),</code> | A |
| 5064 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 5073 | deref | <code>with (*context.data.spells.spells.edit(drain))</code> | D |
| 5151 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 5160 | deref | <code>with (*context.data.spells.spells.edit(fishing))</code> | D |
| 5245 | addr | <code>auto hole = context.makeGameObject(&amp;context.data.gameObjectSpawns[$ - 1]);</code> | GO |
| 5308 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 5372 | lookup | <code>auto aura = makeAura((power in context.data.spells.spells), me.guid, 1, -1, true, [35, 0, 0]);</code> | A |
| 5386 | lookup | <code>auto healAura = makeAura((healing in context.data.spells.spells), me.guid, 1, -1, true, [35, 0, 0]);</code> | A |
| 5477 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 5573 | lookup | <code>const spell = (29100 in context.data.spells.spells);</code> | A |
| 5643 | lookup | <code>me.auras.apply(makeAura((29103 in context.data.spells.spells), me.guid, 10, -1, true, [-50, 0, 0]), me.values, isNew);</code> | A |
| 5645 | lookup | <code>assert(mage.session.inWorld.castSpell((29101 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 5649 | lookup | <code>assert(mage.session.inWorld.castSpell((29102 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 5655 | lookup | <code>auto charged = makeAura((29103 in context.data.spells.spells), me.guid, 10, -1, true, [-50, 0, 0]);</code> | A |
| 5659 | lookup | <code>assert(mage.session.inWorld.castSpell((29102 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 5663 | lookup | <code>assert(mage.session.inWorld.castSpell((29101 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 5668 | lookup | <code>assert(mage.session.inWorld.castSpell((29101 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 5695 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 5733 | lookup | <code>session.addAura(makeAura(thorns in context.data.spells.spells, me.guid, 1, -1, true, [3, 0, 0]));</code> | A |
| 5740 | lookup | <code>session.addAura(makeAura(shield in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));</code> | A |
| 5753 | deref | <code>with (*context.data.spells.spells.edit(echo))</code> | D |
| 5760 | lookup | <code>session.addAura(makeAura(echo in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));</code> | A |
| 5801 | lookup, return, type | <code>const(SpellInfo)* s(uint id) { return id in context.data.spells.spells; }</code> | R |
| 5865 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 5872 | deref | <code>with (*context.data.spells.spells.edit(shot))</code> | D |
| 5889 | lookup | <code>session.castSpell(shot in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);</code> | A |
| 5911 | deref | <code>with (*context.data.spells.spells.edit(hawk))</code> | D |
| 5918 | lookup | <code>session.addAura(makeAura(hawk in context.data.spells.spells, me.guid, 1, -1, true, [0, 0, 0]));</code> | A |
| 5919 | lookup | <code>session.castSpell(shot in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);</code> | A |
| 5946 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 5953 | deref | <code>with (*context.data.spells.spells.edit(shot))</code> | D |
| 5989 | lookup | <code>session.castSpell(shot in context.data.spells.spells, SpellTargets(TargetFlags.unit, keeper.guid), false, 0);</code> | A |
| 6110 | lookup | <code>assert(session.castSpell(missiles in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);</code> | A |
| 6114 | lookup | <code>assert(session.castSpell(missiles in context.data.spells.spells, self, false, 0) == SpellCastResult.notReady,</code> | A |
| 6117 | lookup | <code>assert(session.castSpell(aimed in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);</code> | A |
| 6128 | lookup | <code>assert(session.castSpell(frostbolt in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);</code> | A |
| 6182 | lookup | <code>session.addAura(makeAura(improved in context.data.spells.spells, me.guid, 1, -1, true, [-600_000, 0, 0]));</code> | A |
| 6224 | lookup | <code>assert(session.castSpell(bloodrage in context.data.spells.spells, self, false, 0) == SpellCastResult.ok);</code> | A |
| 6227 | lookup | <code>assert(session.castSpell(bloodrage in context.data.spells.spells, self, false, 0)</code> | A |
| 6273 | lookup | <code>assert(session.castSpell(funnel in context.data.spells.spells, SpellTargets(TargetFlags.self, me.guid), false, 0)</code> | A |
| 6319 | lookup | <code>auto aura = makeAura((power in context.data.spells.spells), anduin.session.character.guid, 1, -1, true, [35, 0, 0]);</code> | A |
| 6324 | lookup | <code>anduin.session.inWorld.spellDamageToPlayer(fire in context.data.spells.spells, jaina.session.inWorld, 20);</code> | A |
| 6355 | lookup | <code>anduin.session.inWorld.weaponSpellDamage(strike in context.data.spells.spells, 0, victim, 10);</code> | A |
| 6377 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 6444 | lookup | <code>me.auras.apply(makeAura((1784 in context.data.spells.spells), me.guid, 10, -1, true, [0, 0, 0]), me.values, isNew);</code> | A |
| 6445 | lookup | <code>assert(rogue.session.inWorld.castSpell((921 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 6449 | lookup | <code>assert(rogue.session.inWorld.castSpell((29104 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 6478 | lookup | <code>const spell = 12043 in context.data.spells.spells;</code> | A |
| 6524 | lookup | <code>session.addAura(makeAura((29103 in context.data.spells.spells), 7, 10, -1, true, [-10, 0, 0]));</code> | A |
| 6530 | addr, deref, type | <code>assert(mods[0][0] == 0 &amp;&amp; mods[0][1] == SpellModOp.cost &amp;&amp; *cast(int*) &amp;mods[0][2] == -10);</code> | P |
| 6563 | lookup | <code>assert(session.castSpell((2050 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)</code> | A |
| 6609 | lookup | <code>keeper.auras.apply(makeAura((90071 in context.data.spells.spells), 0, 60, -1, true, [300, 0, 0]), keeper.values, isNew);</code> | A |
| 6612 | lookup | <code>session.addAura(makeAura((90072 in context.data.spells.spells), 7, 60, 60_000, true, [300, 0, 0]));</code> | A |
| 6647 | lookup | <code>session.applyAuraEffect((1098 in context.data.spells.spells), 0, keeper.guid);</code> | A |

### `source/dmangos/world/spellmods.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 101 | addr | <code>auto talent = makeAura(&amp;improved, 1, 60, -1, true, [-200, 0, 0]);</code> | P |
| 108 | addr | <code>auto cheaper = makeAura(&amp;clearcasting, 1, 60, -1, true, [-50, 0, 0]);</code> | P |

### `source/dmangos/world/spells.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 286 | return, type | <code>const(SpellProcEvent)* procEvent(uint id) const</code> | R |
| 288 | lookup | <code>if (auto event = id in procEvents)</code> | A |
| 290 | lookup | <code>if (const node = id in chains)</code> | A |
| 291 | lookup | <code>return node.first in procEvents;</code> | R |
| 296 | return, type | <code>const(SpellInfo)* spell(uint id) const</code> | R |
| 298 | lookup | <code>return id in spells;</code> | R |
| 304 | lookup | <code>if (auto node = id in chains)</code> | A |
| 312 | lookup | <code>if (auto node = id in chains)</code> | A |
| 336 | return, type | <code>const(SpellLearnSkillNode)* learnedSkill(uint id) const</code> | R |
| 338 | lookup | <code>return id in learnSkills;</code> | R |
| 432 | lookup | <code>const firstSpell = first in spells;</code> | A |
| 448 | lookup | <code>const entry = (id in spells);</code> | A |
| 496 | lookup | <code>if (forward in chains &#124;&#124; forward in prevRanks)</code> | B |
| 498 | lookup | <code>if (auto prevNode = spellId in chains)</code> | A |
| 519 | lookup | <code>if (auto existing = row.spell in chains)</code> | A |
| 560 | lookup | <code>if (spellId in chains)</code> | B |
| 562 | lookup | <code>if (auto prevNode = prevId in chains)</code> | A |
| 567 | lookup | <code>auto before = prevId in prevRanks;</code> | A |
| 579 | deref | <code>abilityChainHelper(prevRanks, prevId, *before, depth - 1);</code> | D |
| 580 | lookup | <code>if (auto prevNode = prevId in chains)</code> | A |
| 599 | lookup | <code>const entry = (id in spells);</code> | A |

### `source/dmangos/world/spellsummons.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 17 | type | <code>void summonWildObject(ref Caster caster, const(SpellInfo)* spell, size_t i, const ref SpellTargets targets)</code> | P |
| 25 | lookup | <code>if (entry !in context.data.gameObjectTemplates)</code> | B |
| 37 | deref | <code>const ms = caster.modDuration(spell, duration(*spell, context.client, caster.level));</code> | D |
| 48 | type | <code>imported!"dmangos.world.creature".Creature summonTotem(ref Caster caster, const(SpellInfo)* spell, size_t i,</code> | P |
| 65 | lookup | <code>if (entry !in context.data.creatureTemplates)</code> | B |
| 75 | deref | <code>const ms = caster.modDuration(spell, duration(*spell, context.client, level));</code> | D |
| 80 | addr | <code>auto v = &amp;totem.values;</code> | P |
| 99 | lookup | <code>if (const s = entry in context.data.creatureFirstSpell)</code> | A |
| 100 | deref | <code>if (const info = context.data.spells.spell(*s))</code> | D |
| 102 | deref | <code>totem.totemSpell = *s;</code> | D |
| 103 | deref | <code>totem.totemActive = castTime(*info, context.client, level) &gt; 0;</code> | D |
| 110 | deref | <code>? caster.character.effectMod(info, j, effectValue(*info, j, level, 0))</code> | D |
| 111 | deref | <code>: effectValue(*info, j, level, 0);</code> | D |
| 144 | deref | <code>const reach = range(*info, context.client)[1];</code> | D |

### `source/dmangos/world/stats.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 78 | type | <code>const(ItemTemplate)*[equipmentSlotEnd] equipment;</code> | P |
| 81 | type | <code>const(ItemTemplate)* ammo;</code> | P |
| 89 | type | <code>DamageRange ammoDps(const(ItemTemplate)* weapon, const(ItemTemplate)* ammo) pure nothrow @nogc @safe</code> | P |
| 198 | type | <code>addStatBonus(result, cast(Stat) i, result.stats[i] * (input.auras.statTotal[i] - 1));</code> | P |
| 352 | addr | <code>input.equipment[equipmentSlotMainhand] = &amp;sword;</code> | P |
| 353 | addr | <code>input.equipment[4] = &amp;shirt;</code> | P |
| 395 | addr | <code>input.equipment[4] = &amp;chest;</code> | P |
| 396 | addr | <code>input.equipment[equipmentSlotOffhand] = &amp;dagger;</code> | P |
| 549 | addr | <code>input.equipment[equipmentSlotRanged] = &amp;bow;</code> | P |
| 551 | addr | <code>input.ammo = &amp;arrows;</code> | P |

### `source/dmangos/world/talenthandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 217 | type | <code>package void applyPassive(const(SpellInfo)* spell)</code> | P |
| 234 | deref | <code>values[i] = effectValue(*spell, i, player.data.level, 0);</code> | D |
| 272 | lookup | <code>if (const effects = item.enchantment(enchantSlot) in context.data.enchantmentEffects)</code> | A |
| 273 | deref | <code>foreach (ref e; *effects)</code> | D |
| 299 | lookup | <code>if (id in equipSpells)</code> | B |
| 310 | deref | <code>values[i] = effectMod(spell, i, effectValue(*spell, i, player.data.level, 0)) * cast(int) count;</code> | D |
| 334 | type | <code>private static bool formBound(const(SpellInfo)* spell)</code> | P |
| 351 | type | <code>void set(const(SpellInfo)* spell, bool wanted, int[3] values)</code> | P |
| 371 | deref | <code>values[i] = effectMod(spell, i, effectValue(*spell, i, player.data.level, 0));</code> | D |
| 389 | type | <code>bool worn(const(SpellInfo)* spell)</code> | P |
| 417 | deref | <code>values[i] = effectValue(*spell, i, player.data.level, 0);</code> | D |

### `source/dmangos/world/taxi.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 61 | lookup | <code>if (id !in client.taxiNetwork)</code> | B |
| 74 | type | <code>uint taxiMountCreature(const(TaxiNodesEntry)* node, Team team) pure nothrow @nogc @safe</code> | P |
| 214 | lookup | <code>const toward = nodes[i] in client.taxiPathBetween;</code> | A |
| 215 | deref, lookup | <code>const path = toward is null ? null : nodes[i + 1] in *toward;</code> | A |
| 218 | deref | <code>const entry = client.taxiPaths.lookup(*path);</code> | D |
| 220 | deref | <code>foreach (point; client.taxiPathPoints.get(*path, null))</code> | D |
| 228 | deref | <code>flight.pathPoints ~= PathPoint(*path, point.index);</code> | D |
| 240 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |

### `source/dmangos/world/taxihandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 183 | lookup | <code>const mountTemplate = mountCreature in context.data.creatureTemplates;</code> | A |
| 184 | deref | <code>const display = mountTemplate is null ? 0 : chooseDisplay(*mountTemplate, map.random);</code> | D |
| 268 | lookup | <code>const mountTemplate = mountCreature in context.data.creatureTemplates;</code> | A |
| 269 | deref | <code>const display = mountTemplate is null ? 0 : chooseDisplay(*mountTemplate, map.random);</code> | D |
| 378 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |
| 478 | addr, deref, type | <code>uint bits(float f) { return *cast(uint*) &amp;f; }</code> | U |

### `source/dmangos/world/teleport.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 102 | type | <code>package bool teleportTo(uint mapId, Position destination, const(AreaTriggerTeleport)* trigger = null,</code> | P |
| 133 | deref | <code>const status = lockStatus(*trigger, mapEntry, requirement);</code> | D |
| 136 | deref | <code>sendLockStatus(*trigger, status, requirement);</code> | D |
| 235 | lookup | <code>if (const most = mapId in context.data.instanceMaxPlayers)</code> | A |
| 237 | deref | <code>if (there.population &gt;= *most)</code> | D |
| 329 | type | <code>AreaLockStatus lockStatus(const ref AreaTriggerTeleport trigger, const(MapEntry)* mapEntry, out uint requirement)</code> | P |
| 361 | lookup | <code>if (trigger.requiredQuest &amp;&amp; trigger.requiredQuest !in player.data.rewardedQuests)</code> | B |
| 386 | lookup | <code>const item = requirement in context.data.items;</code> | A |
| 532 | lookup | <code>if (const quest = request.id in context.data.quests.triggerQuests)</code> | A |
| 533 | deref | <code>if (player.deathState == DeathState.alive &amp;&amp; questState(*quest) == QuestState.incomplete)</code> | D |
| 534 | deref | <code>areaExploredOrEventHappens(*quest);</code> | D |
| 537 | lookup | <code>if (request.id in context.data.taverns)</code> | B |
| 546 | lookup | <code>const trigger = request.id in context.data.areaTriggers;</code> | A |
| 760 | addr | <code>auto a = context.makeCreature(&amp;defias), b = context.makeCreature(&amp;defias);</code> | CS |
| 814 | addr | <code>auto creature = context.makeCreature(&amp;rager);</code> | CS |
| 880 | lookup | <code>if (auto s = account in mesh.remotes.require(owner, null))</code> | A |
| 1028 | addr | <code>auto hurt = a.makeCreature(&amp;a.data.creatureSpawns[$ - 1]);</code> | CS |

### `source/dmangos/world/terrain.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 664 | type | <code>const(AreaTableEntry)* found;</code> | P |

### `source/dmangos/world/testclient.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 131 | lookup | <code>auto known = guid in fields;</code> | A |
| 135 | lookup | <code>known = guid in fields;</code> | A |
| 139 | deref | <code>(*known)[i] = r.read!uint;</code> | D |
| 147 | lookup | <code>if (auto known = guid in fields)</code> | A |
| 148 | deref | <code>return (*known).get(slot, 0);</code> | D |

### `source/dmangos/world/testdata.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 162 | addr, deref, type | <code>return *cast(uint*)&amp;value;</code> | U |

### `source/dmangos/world/tooltipmasks.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 47 | lookup | <code>const node = id in data.chains;</code> | A |

### `source/dmangos/world/tradehandlers.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 496 | type | <code>const(imported!"dmangos.world.spells".SpellInfo)* spell, const ref imported!"dmangos.world.spellcast".SpellTargets targets,</code> | P |
| 659 | lookup | <code>assert(jerky.guid in db.itemRows, "saved again under its taker");</code> | A |

### `source/dmangos/world/transports.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 312 | addr | <code>const k = &amp;frames[current];</code> | P |
| 347 | type | <code>this(const(GameObjectTemplate)* t, uint period, Position at, uint delegate() clock)</code> | P |

### `source/dmangos/world/unit.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 204 | return, type | <code>@property imported!"dmangos.world.auras".AuraSet* auraSet()</code> | R |
| 209 | addr | <code>case UnitKind.player: return session.player is null ? null : &amp;session.player.auras;</code> | R |
| 210 | addr | <code>case UnitKind.creature: return &amp;creature.auras;</code> | R |
| 215 | return, type | <code>@property imported!"dmangos.world.objects".UpdateValues* fields()</code> | R |
| 220 | addr | <code>case UnitKind.player: return session.player is null ? null : &amp;session.player.values;</code> | R |
| 221 | addr | <code>case UnitKind.creature: return &amp;creature.values;</code> | R |
| 689 | lookup | <code>&#124;&#124; aura.caster in shardGiven)</code> | A |

### `source/dmangos/world/wareffort.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 715 | addr | <code>host.provide!WarEffortHost(&amp;make);</code> | F |
| 744 | addr | <code>other.provide!WarEffortHost(&amp;make);</code> | F |

### `source/dmangos/world/warsong.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 161 | lookup | <code>auto m = who in copy.members;</code> | A |
| 193 | lookup | <code>auto m = who in copy.members;</code> | A |
| 481 | addr | <code>foreach (p; [&amp;anduin, &amp;thrall])</code> | P |

### `source/dmangos/world/worlddata.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 508 | return, type | <code>const(AreaTriggerTeleport)* mapEntranceTrigger(uint map, const ClientData client) const</code> | R |
| 514 | addr | <code>return &amp;trigger;</code> | R |
| 522 | return, type | <code>const(GameTele)* findTeleport(string name) const</code> | R |
| 528 | type | <code>const(GameTele)* partial;</code> | P |
| 533 | addr | <code>return &amp;tele;</code> | R |
| 535 | addr | <code>partial = &amp;tele;</code> | P |
| 555 | lookup | <code>return (raceClassKey(race, classId) in playerInfo) !is null;</code> | A |
| 559 | return, type | <code>const(PlayerInfo)* createInfo(ubyte race, ubyte classId) const</code> | R |
| 561 | lookup | <code>return raceClassKey(race, classId) in playerInfo;</code> | A |
| 653 | lookup | <code>if (row.get!uint(0) in data.formations &amp;&amp; row.get!int(2) &gt;= 0)</code> | B |
| 915 | lookup | <code>if (auto entries = row.guid in spawnEntries)</code> | A |
| 916 | deref | <code>row.entry = (*entries)[uniform(0, entries.length, rng)];</code> | D |
| 920 | lookup | <code>if (row.entry !in creatureTemplates &#124;&#124; !client.isValidMapCoord(row.map, row.x, row.y, row.z))</code> | B |
| 962 | lookup | <code>if (auto entries = s.guid in objectSpawnEntries)</code> | A |
| 963 | deref | <code>s.entry = (*entries)[uniform(0, entries.length, rng)];</code> | D |
| 967 | lookup | <code>const t = s.entry in gameObjectTemplates;</code> | A |
| 1018 | lookup | <code>if (row.get!uint(0) !in spawnGuids &#124;&#124; !valid(n))</code> | B |
| 1027 | lookup | <code>if (row.get!uint(0) !in creatureTemplates &#124;&#124; !valid(n))</code> | B |
| 1065 | lookup | <code>if (auto e = cast(ushort) row.get!uint(0) in byId)</code> | A |
| 1094 | lookup | <code>const t = entry in gameObjectTemplates;</code> | A |
| 1169 | lookup | <code>else if (row.requiredItem &amp;&amp; row.requiredItem !in items &#124;&#124; row.requiredItem2 &amp;&amp; row.requiredItem2 !in items)</code> | B |
| 1215 | lookup | <code>auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;</code> | A |
| 1217 | lookup | <code>if (player is null &#124;&#124; (item in items) is null &#124;&#124; amount == 0)</code> | A |
| 1254 | lookup | <code>if (auto player = raceClassKey(race, classId) in playerInfo)</code> | A |
| 1262 | lookup | <code>auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;</code> | A |
| 1271 | lookup | <code>auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;</code> | A |
| 1283 | addr | <code>auto table = &amp;classLevelStats.require(classId);</code> | P |
| 1286 | deref | <code>(*table)[level - 1] = ClassLevelStats(row.get!uint(2), row.get!uint(3));</code> | D |
| 1295 | lookup | <code>auto player = raceClassKey(row.get!ubyte(0), row.get!ubyte(1)) in playerInfo;</code> | A |
| 1320 | lookup | <code>return (action.action in items) !is null;</code> | A |
| 1447 | lookup | <code>const byKind = kind in poolOf;</code> | A |
| 1448 | deref, lookup | <code>return byKind !is null &amp;&amp; (id in *byKind) !is null;</code> | R |
| 1503 | lookup | <code>if (pool !in childPools)</code> | B |
| 1510 | lookup | <code>const inPool = kind in pooled;</code> | A |
| 1511 | deref, lookup | <code>if (inPool is null &#124;&#124; id !in *inPool)</code> | B |
| 1513 | lookup | <code>const picked = kind in chosen;</code> | A |
| 1514 | deref, lookup | <code>return picked !is null &amp;&amp; (id in *picked) !is null;</code> | R |
| 1634 | lookup | <code>if (auto group = id in groups)</code> | A |
| 1645 | lookup | <code>if (auto group = id in groups)</code> | A |
| 1738 | lookup | <code>return guid !in groupOf[type] &#124;&#124; (guid in active[type]) !is null;</code> | B |
| 1746 | lookup | <code>if (const entry = guid in assigned)</code> | A |
| 1747 | deref | <code>return *entry;</code> | D |
| 1749 | lookup | <code>if (const id = guid in groupOf[type])</code> | A |
| 1751 | deref | <code>const group = groups[*id];</code> | D |

### `source/dmangos/world/worldpvp.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 719 | addr | <code>host.provide!WorldPvpHost(&amp;make);</code> | F |
| 772 | addr | <code>other.provide!WorldPvpHost(&amp;make);</code> | F |
| 973 | addr | <code>const t = &amp;towers[Tower.plaguewood];</code> | P |
| 992 | addr | <code>const t = &amp;towers[tower];</code> | P |
| 1036 | addr | <code>const t = &amp;towers[tower];</code> | P |
| 1235 | addr | <code>const state = &amp;context.worldPvp.state;</code> | P |
| 1348 | return, type | <code>package const(imported!"dmangos.world.clientdata".WorldSafeLocsEntry)* worldPvpGraveyard(uint area)</code> | R |

### `source/dmangos/world/worldspelltests.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 27 | return, type | <code>private const(SpellInfo)* scripted(imported!"dmangos.world.context".WorldContext context, uint id, SpellEffect effect,</code> | R |
| 39 | lookup | <code>return id in context.data.spells.spells;</code> | R |
| 52 | addr | <code>auto creature = context.makeCreature(&amp;spawn);</code> | CS |
| 208 | addr | <code>auto v = &amp;session.player.values;</code> | P |
| 233 | addr | <code>auto v = &amp;session.player.values;</code> | P |
| 259 | addr | <code>auto v = &amp;session.player.values;</code> | P |
| 315 | addr | <code>auto v = &amp;hero.session.inWorld.player.values;</code> | P |
| 344 | lookup | <code>assert(8063 !in context.data.spellScriptNames);</code> | B |

### `source/dmangos/world/writebehind.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 126 | fn | <code>void function(WorldDatabase, const(ubyte)[]) carryOut;</code> | F |
| 137 | lookup | <code>assert(signature!fun !in table, "two queued methods with one signature: " ~ __traits(identifier, fun));</code> | B |
| 138 | addr | <code>table[signature!fun] = Method(__traits(identifier, fun), &amp;carryOut!fun);</code> | F |
| 195 | lookup | <code>const method = w.signature in bySignature;</code> | A |
| 292 | addr | <code>thread = new Thread(&amp;run);</code> | F |
| 320 | lookup | <code>auto bySig = write.signature in latest;</code> | A |
| 324 | lookup | <code>bySig = write.signature in latest;</code> | A |
| 326 | deref, lookup | <code>if (auto older = key in *bySig)</code> | A |
| 328 | deref | <code>queue[*older].replaced = true;</code> | D |
| 331 | deref | <code>(*bySig)[key] = queue.length;</code> | D |
| 564 | addr | <code>appendToLog(path, (&amp;w)[0 .. 1]);</code> | P |
| 571 | lookup | <code>if (auto m = signature in bySignature)</code> | A |

### `thirdparty/dmnav/dmnav.cpp`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 41 | native | <code>int dmnav_build_tile(const dmBuildConfig* c, const float* verts, int nverts, const int* tris,</code> | CC |
| 42 | native | <code>const unsigned char* areas, int ntris, unsigned char** data, int* size)</code> | CC |
| 44 | native | <code>*data = nullptr;</code> | CC |
| 45 | native | <code>*size = 0;</code> | CC |
| 49 | native | <code>rcCalcBounds(verts, nverts, bmin, bmax);</code> | CC |
| 50 | native | <code>bmin[0] = c-&gt;bmin[0]; bmin[2] = c-&gt;bmin[2];</code> | CC |
| 51 | native | <code>bmax[0] = c-&gt;bmax[0]; bmax[2] = c-&gt;bmax[2];</code> | CC |
| 53 | native | <code>unsigned char* walkable = new (std::nothrow) unsigned char[ntris &gt; 0 ? ntris : 1];</code> | CC |
| 56 | native | <code>std::memcpy(walkable, areas, ntris);</code> | CC |
| 57 | native | <code>rcClearUnwalkableTriangles(&amp;ctx, c-&gt;walkableSlope, verts, nverts, tris, ntris, walkable);</code> | CC |
| 59 | native | <code>const int border = c-&gt;walkableRadius + 3;</code> | CC |
| 60 | native | <code>const int tileCells = int((bmax[0] - bmin[0]) / c-&gt;cellSize + 0.5f);</code> | CC |
| 61 | native | <code>const int pieces = (tileCells + c-&gt;subTileCells - 1) / c-&gt;subTileCells;</code> | CC |
| 62 | native | <code>rcPolyMesh** meshes = new rcPolyMesh*[pieces * pieces]();</code> | CA |
| 63 | native | <code>rcPolyMeshDetail** details = new rcPolyMeshDetail*[pieces * pieces]();</code> | CA |
| 71 | native | <code>std::memset(&amp;cfg, 0, sizeof(cfg));</code> | CC |
| 72 | native | <code>cfg.cs = c-&gt;cellSize;</code> | CC |
| 73 | native | <code>cfg.ch = c-&gt;cellSize;</code> | CC |
| 74 | native | <code>cfg.walkableSlopeAngle = c-&gt;walkableSlope;</code> | CC |
| 75 | native | <code>cfg.walkableHeight = c-&gt;walkableHeight;</code> | CC |
| 76 | native | <code>cfg.walkableClimb = c-&gt;walkableClimb;</code> | CC |
| 77 | native | <code>cfg.walkableRadius = c-&gt;walkableRadius;</code> | CC |
| 78 | native | <code>cfg.maxEdgeLen = c-&gt;subTileCells + 1;</code> | CC |
| 79 | native | <code>cfg.maxSimplificationError = c-&gt;maxSimplificationError;</code> | CC |
| 80 | native | <code>cfg.minRegionArea = c-&gt;minRegionArea;</code> | CC |
| 81 | native | <code>cfg.mergeRegionArea = c-&gt;mergeRegionArea;</code> | CC |
| 83 | native | <code>cfg.tileSize = c-&gt;subTileCells;</code> | CC |
| 85 | native | <code>cfg.detailSampleDist = c-&gt;detailSampleDist;</code> | CC |
| 86 | native | <code>cfg.detailSampleMaxError = c-&gt;detailSampleMaxError;</code> | CC |
| 87 | native | <code>cfg.width = cfg.tileSize + 2 * border;</code> | CC |
| 88 | native | <code>cfg.height = cfg.tileSize + 2 * border;</code> | CC |
| 89 | native | <code>const float piece = c-&gt;subTileCells * c-&gt;cellSize;</code> | CC |
| 90 | native | <code>cfg.bmin[0] = bmin[0] + px * piece - border * c-&gt;cellSize;</code> | CC |
| 92 | native | <code>cfg.bmin[2] = bmin[2] + py * piece - border * c-&gt;cellSize;</code> | CC |
| 93 | native | <code>cfg.bmax[0] = bmin[0] + (px + 1) * piece + border * c-&gt;cellSize;</code> | CC |
| 95 | native | <code>cfg.bmax[2] = bmin[2] + (py + 1) * piece + border * c-&gt;cellSize;</code> | CC |
| 97 | native | <code>rcHeightfield* solid = rcAllocHeightfield();</code> | CC |
| 98 | native | <code>if (!solid &#124;&#124; !rcCreateHeightfield(&amp;ctx, *solid, cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch))</code> | CC |
| 100 | native | <code>rcFreeHeightField(solid);</code> | CC |
| 104 | native | <code>if (!rcRasterizeTriangles(&amp;ctx, verts, nverts, tris, walkable, ntris, *solid, cfg.walkableClimb))</code> | CC |
| 106 | native | <code>rcFreeHeightField(solid);</code> | CC |
| 110 | native | <code>rcFilterLowHangingWalkableObstacles(&amp;ctx, cfg.walkableClimb, *solid);</code> | CC |
| 111 | native | <code>rcFilterLedgeSpans(&amp;ctx, cfg.walkableHeight, cfg.walkableClimb, *solid);</code> | CC |
| 112 | native | <code>rcFilterWalkableLowHeightSpans(&amp;ctx, cfg.walkableHeight, *solid);</code> | CC |
| 114 | native | <code>rcCompactHeightfield* chf = rcAllocCompactHeightfield();</code> | CC |
| 115 | native | <code>const bool compact = chf &amp;&amp; rcBuildCompactHeightfield(&amp;ctx, cfg.walkableHeight, cfg.walkableClimb, *solid, *chf);</code> | CC |
| 116 | native | <code>rcFreeHeightField(solid);</code> | CC |
| 119 | native | <code>rcFreeCompactHeightfield(chf);</code> | CC |
| 123 | native | <code>if (!rcErodeWalkableArea(&amp;ctx, cfg.walkableRadius, *chf) &#124;&#124; !rcBuildDistanceField(&amp;ctx, *chf)</code> | CC |
| 124 | native | <code>&#124;&#124; !rcBuildRegions(&amp;ctx, *chf, cfg.borderSize, cfg.minRegionArea, cfg.mergeRegionArea))</code> | CC |
| 126 | native | <code>rcFreeCompactHeightfield(chf);</code> | CC |
| 130 | native | <code>rcContourSet* contours = rcAllocContourSet();</code> | CC |
| 131 | native | <code>if (!contours &#124;&#124; !rcBuildContours(&amp;ctx, *chf, cfg.maxSimplificationError, cfg.maxEdgeLen, *contours))</code> | CC |
| 133 | native | <code>rcFreeContourSet(contours);</code> | CC |
| 134 | native | <code>rcFreeCompactHeightfield(chf);</code> | CC |
| 138 | native | <code>rcPolyMesh* mesh = rcAllocPolyMesh();</code> | CC |
| 139 | native | <code>if (!mesh &#124;&#124; !rcBuildPolyMesh(&amp;ctx, *contours, cfg.maxVertsPerPoly, *mesh))</code> | CC |
| 141 | native | <code>rcFreePolyMesh(mesh);</code> | CC |
| 142 | native | <code>rcFreeContourSet(contours);</code> | CC |
| 143 | native | <code>rcFreeCompactHeightfield(chf);</code> | CC |
| 147 | native | <code>rcPolyMeshDetail* detail = rcAllocPolyMeshDetail();</code> | CC |
| 148 | native | <code>if (!detail &#124;&#124; !rcBuildPolyMeshDetail(&amp;ctx, *mesh, *chf, cfg.detailSampleDist, cfg.detailSampleMaxError, *detail))</code> | CC |
| 150 | native | <code>rcFreePolyMeshDetail(detail);</code> | CC |
| 151 | native | <code>rcFreePolyMesh(mesh);</code> | CC |
| 152 | native | <code>rcFreeContourSet(contours);</code> | CC |
| 153 | native | <code>rcFreeCompactHeightfield(chf);</code> | CC |
| 157 | native | <code>rcFreeContourSet(contours);</code> | CC |
| 158 | native | <code>rcFreeCompactHeightfield(chf);</code> | CC |
| 159 | native | <code>meshes[built] = mesh;</code> | CC |
| 160 | native | <code>details[built] = detail;</code> | CC |
| 164 | native | <code>rcPolyMesh* merged = nullptr;</code> | CC |
| 165 | native | <code>rcPolyMeshDetail* mergedDetail = nullptr;</code> | CC |
| 170 | native | <code>if (!merged &#124;&#124; !mergedDetail &#124;&#124; !rcMergePolyMeshes(&amp;ctx, meshes, built, *merged)</code> | CC |
| 171 | native | <code>&#124;&#124; !rcMergePolyMeshDetails(&amp;ctx, details, built, *mergedDetail))</code> | CC |
| 176 | native | <code>rcFreePolyMesh(meshes[i]);</code> | CC |
| 177 | native | <code>rcFreePolyMeshDetail(details[i]);</code> | CC |
| 179 | native | <code>delete[] meshes;</code> | CC |
| 180 | native | <code>delete[] details;</code> | CC |
| 181 | native | <code>delete[] walkable;</code> | CC |
| 183 | native | <code>if (result == 0 &amp;&amp; merged-&gt;npolys == 0)</code> | CC |
| 187 | native | <code>for (int i = 0; i &lt; merged-&gt;npolys; ++i)</code> | CC |
| 188 | native | <code>merged-&gt;flags[i] = merged-&gt;areas[i] ? (unsigned short)(1u &lt;&lt; (merged-&gt;areas[i] - 1)) : 0;</code> | CC |
| 191 | native | <code>std::memset(&amp;p, 0, sizeof(p));</code> | CC |
| 192 | native | <code>p.verts = merged-&gt;verts;</code> | CC |
| 193 | native | <code>p.vertCount = merged-&gt;nverts;</code> | CC |
| 194 | native | <code>p.polys = merged-&gt;polys;</code> | CC |
| 195 | native | <code>p.polyAreas = merged-&gt;areas;</code> | CC |
| 196 | native | <code>p.polyFlags = merged-&gt;flags;</code> | CC |
| 197 | native | <code>p.polyCount = merged-&gt;npolys;</code> | CC |
| 198 | native | <code>p.nvp = merged-&gt;nvp;</code> | CC |
| 199 | native | <code>p.detailMeshes = mergedDetail-&gt;meshes;</code> | CC |
| 200 | native | <code>p.detailVerts = mergedDetail-&gt;verts;</code> | CC |
| 201 | native | <code>p.detailVertsCount = mergedDetail-&gt;nverts;</code> | CC |
| 202 | native | <code>p.detailTris = mergedDetail-&gt;tris;</code> | CC |
| 203 | native | <code>p.detailTriCount = mergedDetail-&gt;ntris;</code> | CC |
| 204 | native | <code>p.walkableHeight = c-&gt;walkableHeight * c-&gt;cellSize;</code> | CC |
| 205 | native | <code>p.walkableRadius = c-&gt;walkableRadius * c-&gt;cellSize;</code> | CC |
| 206 | native | <code>p.walkableClimb = c-&gt;walkableClimb * c-&gt;cellSize;</code> | CC |
| 207 | native | <code>p.tileX = c-&gt;tileX;</code> | CC |
| 208 | native | <code>p.tileY = c-&gt;tileY;</code> | CC |
| 210 | native | <code>rcVcopy(p.bmin, merged-&gt;bmin);</code> | CC |
| 211 | native | <code>rcVcopy(p.bmax, merged-&gt;bmax);</code> | CC |
| 212 | native | <code>p.cs = c-&gt;cellSize;</code> | CC |
| 213 | native | <code>p.ch = c-&gt;cellSize;</code> | CC |
| 215 | native | <code>if (!dtCreateNavMeshData(&amp;p, data, size))</code> | CC |
| 218 | native | <code>rcFreePolyMesh(merged);</code> | CC |
| 219 | native | <code>rcFreePolyMeshDetail(mergedDetail);</code> | CC |
| 224 | native | <code>void dmnav_free(void* p)</code> | CC |
| 226 | native | <code>dtFree(p);</code> | CC |
| 230 | native | <code>void* dmnav_mesh_create(const float* origin, float tileWidth, int maxTiles, int maxPolys)</code> | CC |
| 233 | native | <code>std::memset(&amp;params, 0, sizeof(params));</code> | CC |
| 234 | native | <code>rcVcopy(params.orig, origin);</code> | CC |
| 239 | native | <code>dtNavMesh* mesh = dtAllocNavMesh();</code> | CC |
| 240 | native | <code>if (!mesh &#124;&#124; dtStatusFailed(mesh-&gt;init(&amp;params)))</code> | CC |
| 242 | native | <code>dtFreeNavMesh(mesh);</code> | CC |
| 245 | native | <code>return mesh;</code> | CC |
| 248 | native | <code>void dmnav_mesh_free(void* mesh)</code> | CC |
| 250 | native | <code>dtFreeNavMesh(static_cast&lt;dtNavMesh*&gt;(mesh));</code> | CC |
| 254 | native | <code>int dmnav_mesh_add_tile(void* mesh, const unsigned char* data, int size)</code> | CC |
| 256 | native | <code>unsigned char* copy = static_cast&lt;unsigned char*&gt;(dtAlloc(size, DT_ALLOC_PERM));</code> | CC |
| 259 | native | <code>std::memcpy(copy, data, size);</code> | CC |
| 260 | native | <code>const dtStatus status = static_cast&lt;dtNavMesh*&gt;(mesh)-&gt;addTile(copy, size, DT_TILE_FREE_DATA, 0, nullptr);</code> | CC |
| 263 | native | <code>dtFree(copy);</code> | CC |
| 270 | native | <code>void dmnav_mesh_remove_tile(void* mesh, int tileX, int tileY)</code> | CC |
| 272 | native | <code>dtNavMesh* m = static_cast&lt;dtNavMesh*&gt;(mesh);</code> | CC |
| 273 | native | <code>const dtTileRef ref = m-&gt;getTileRefAt(tileX, tileY, 0);</code> | CC |
| 275 | native | <code>m-&gt;removeTile(ref, nullptr, nullptr);</code> | CC |
| 279 | native | <code>void* dmnav_query_create(void* mesh, int maxNodes)</code> | CC |
| 281 | native | <code>dtNavMeshQuery* query = dtAllocNavMeshQuery();</code> | CC |
| 282 | native | <code>if (!query &#124;&#124; dtStatusFailed(query-&gt;init(static_cast&lt;dtNavMesh*&gt;(mesh), maxNodes)))</code> | CC |
| 284 | native | <code>dtFreeNavMeshQuery(query);</code> | CC |
| 287 | native | <code>return query;</code> | CC |
| 290 | native | <code>void dmnav_query_free(void* query)</code> | CC |
| 292 | native | <code>dtFreeNavMeshQuery(static_cast&lt;dtNavMeshQuery*&gt;(query));</code> | CC |
| 299 | native | <code>int dmnav_find_path(void* query, const float* start, const float* end, const float* extents,</code> | CC |
| 300 | native | <code>unsigned short include, unsigned short exclude, float* points, int maxPoints, int* partial)</code> | CC |
| 303 | native | <code>dtNavMeshQuery* q = static_cast&lt;dtNavMeshQuery*&gt;(query);</code> | CC |
| 307 | native | <code>*partial = 0;</code> | CC |
| 311 | native | <code>if (dtStatusFailed(q-&gt;findNearestPoly(start, extents, &amp;filter, &amp;startRef, startPoint)) &#124;&#124; !startRef)</code> | CC |
| 313 | native | <code>if (dtStatusFailed(q-&gt;findNearestPoly(end, extents, &amp;filter, &amp;endRef, endPoint)) &#124;&#124; !endRef)</code> | CC |
| 318 | native | <code>const dtStatus found = q-&gt;findPath(startRef, endRef, startPoint, endPoint, &amp;filter, polys, &amp;polyCount, maxPolys);</code> | CC |
| 322 | native | <code>rcVcopy(target, endPoint);</code> | CC |
| 325 | native | <code>*partial = 1;</code> | CC |
| 327 | native | <code>q-&gt;closestPointOnPoly(polys[polyCount - 1], endPoint, target, &amp;overPoly);</code> | CC |
| 330 | native | <code>if (dtStatusFailed(q-&gt;findStraightPath(startPoint, target, polys, polyCount, points, nullptr, nullptr,</code> | CC |
| 331 | native | <code>&amp;count, maxPoints, 0)))</code> | CC |
| 337 | native | <code>int dmnav_height(void* query, const float* point, const float* extents, unsigned short include, float* height)</code> | CC |
| 339 | native | <code>dtNavMeshQuery* q = static_cast&lt;dtNavMeshQuery*&gt;(query);</code> | CC |
| 344 | native | <code>if (dtStatusFailed(q-&gt;findNearestPoly(point, extents, &amp;filter, &amp;ref, nearest)) &#124;&#124; !ref)</code> | CC |
| 346 | native | <code>*height = nearest[1];</code> | CC |

### `tools/mapbench.d`

| Line | Operations | Source | Verdict key |
|---:|---|---|---|
| 84 | addr | <code>auto map = new Map(0, MapSettings.init, () =&gt; 1000u, &amp;spawner);</code> | F |
