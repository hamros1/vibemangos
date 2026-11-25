# Pointer purposes and lifetimes

## Which existing pointers earn their place?

### Takeaway

Keep single-probe table lookups, existing nullable references, array-backed handles and ABI pointers. None require changing tick semantics, entity layout or frozen-data lifetime. The complete inventory is [D server pointer inventory](/home/hampus/dmangos/reports/D%20server%20pointer%20inventory.md).

### Cited Findings

- D syntax walk covered 326 current tracked D files including tests and tools, zero parser errors. The appendix records all explicit typed pointer, address, dereference, in/!in and .ptr sites, including typed function pointers, generated MySQL signatures and native C++ shim. It omits vendored Recast implementation, compiler-generated indirections and repeated implicit reads of a previously inventoried variable. A separate pointer-return section inventories escapes across function boundaries. [Appendix](/home/hampus/dmangos/reports/D%20server%20pointer%20inventory.md)
- Call-scoped network copies and explicit ownership are justified. Kernel poller stores a Connection address as integer, while the typed Connection[] roots it until poller deregistration after processing the ready batch. MariaDB rows are copied before the scope guard frees the result. Detour copies incoming tile data and D duplicates the outgoing tile before native release. [Poller](/home/hampus/dmangos/source/dmangos/net/server.d:221) [Reaping](/home/hampus/dmangos/source/dmangos/net/server.d:533) [MySQL](/home/hampus/dmangos/source/dmangos/mysql/connection.d:451) [Tile](/home/hampus/dmangos/source/dmangos/navigation.d:122)
- The frozen arena uses process-lifetime native blocks, recursive deep copy, a plain-data gate and selective GC.addRange registration for edited rows. Registering only the outer row is insufficient if a returned value is subsequently used to install a GC pointer in an arena-backed child allocation. Deep-thaw indirect children into traced storage before exposing writable access, or replace edited rows through a controlled deep-copy API. Removal or clear drops the bookkeeping, leaving older registered ranges and any indirect GC data they contain rooted. This is consistent with issued pointers staying readable. Measure admin reload frequency and old references before reclaiming any storage. [Allocation](/home/hampus/dmangos/source/dmangos/frozen.d:52) [Edit](/home/hampus/dmangos/source/dmangos/frozen.d:319) [Removal](/home/hampus/dmangos/source/dmangos/frozen.d:353)
- Keep generational identity and the immediate nullable result of slot lookup. Store grows and Side compacts, so a raw element address can remain physically valid on the GC heap while denoting stale game state. A retained handle should be resolved again after container mutation. Script chunks avoid relocation on growth. [Store](/home/hampus/dmangos/source/dmangos/store.d:56) [Side](/home/hampus/dmangos/source/dmangos/store.d:156) [Script pool](/home/hampus/dmangos/source/dmangos/script/registry.d:274)
- Keep retained Inventory update-field pointers at the production call sites. Player and CharacterBuilder pass fields of the owner object that Inventory itself references. Adding scope on the constructor parameter would contradict this design. [Inventory](/home/hampus/dmangos/source/dmangos/world/inventory.d:710) [Player](/home/hampus/dmangos/source/dmangos/world/player.d:226) [Builder](/home/hampus/dmangos/source/dmangos/world/playercreate.d:357)

### Inferences

A local lookup returning a pointer can be clear independently of @nogc. Slices and ref parameters also need no allocation. Express optional identity with a pointer, definite call-local input with ref, and persistent entity identity with the existing handles. The shuffle of temporary pointer arrays for loot is a real allocation. Preserve the number/order of random draws if profiling supports reusable scratch. [Loot](/home/hampus/dmangos/source/dmangos/world/loot.d:621)

### Gaps

Whether live GM edits must appear immediately to holders of old frozen row pointers is an owner question. No production GC pause or unsafe lifetime event was measured.

## Where does a smaller interface or check improve the code?

### Takeaway

Prioritize the decoder's trust boundary and context matching before erased tick dispatch. The current ordinary callers examined use mutable storage and construct matching script contexts.

### Cited Findings

- Public generic decode casts away top-level qualifiers before writing. Limit the public destination to writable storage, preserving private initialization of owned nested qualified fields. [Decoder](/home/hampus/dmangos/source/dmangos/plaindata.d:92)
- Runtime.raise checks event context type and runtime kind before the erased call. Runtime.tick chooses a thunk by handle but converts its independent Ctx address without the same correspondence check. Enforce kind/context consistency before calling the registered thunk, preserving the pool and ABI. [Tick](/home/hampus/dmangos/source/dmangos/script/registry.d:614) [Typed thunk](/home/hampus/dmangos/source/dmangos/script/registry.d:435) [Normal caller](/home/hampus/dmangos/source/dmangos/world/instancescripting.d:163)
- Store.opIndex checks bounds and generation but omits the occupancy bit used elsewhere. The generation and slot are public. Include holds(r.slot) in the successful-lookup predicate to keep lookup/removal coherent for all values of Ref, as the script pool already does. [Lookup](/home/hampus/dmangos/source/dmangos/store.d:56) [Holds](/home/hampus/dmangos/source/dmangos/store.d:69)
- ModelInstance.locate sends &this through an output record without a contract tying the record to its source. The current query on the internal array consumes it immediately. Restrict lower-level visibility or express the lifetime. Annotate the returned element borrow into LootGroup and the test helper borrowing NewCharacter when DIP1000 verifies it. regionAt is a working local example. [VMap](/home/hampus/dmangos/source/dmangos/vmap/maptree.d:132) [Consumer](/home/hampus/dmangos/source/dmangos/vmap/maptree.d:390) [Loot](/home/hampus/dmangos/source/dmangos/world/loot.d:615) [Character test](/home/hampus/dmangos/source/dmangos/world/playercreate.d:1317) [Region](/home/hampus/dmangos/source/dmangos/cluster/regions.d:239)
- The exhaustive counter switch always returns a mutable field. A ref uint result fits all three callers. The game-object constructor wrapper reads and copies a mandatory spawn, so scope const ref reduces address-taking without a copy or null case. Creature spawning has an event-specific local pointer rebind, a meaningful distinction. Consolidate raw scalar bit reinterpretation with the existing safe union implementation. [Counters](/home/hampus/dmangos/source/dmangos/world/context.d:3775) [Spawn](/home/hampus/dmangos/source/dmangos/world/context.d:5751) [Scalar helper](/home/hampus/dmangos/source/dmangos/vmap/math.d:328)
- C++ tile build allocates two temporary pointer arrays with throwing new[] among manual allocations and an error-code API. Use the existing failure discipline for those allocations, cleaning up partial acquisition. [Shim](/home/hampus/dmangos/thirdparty/dmnav/dmnav.cpp:62)

### Inferences

These are narrow API, storage-invariant or documentation fixes. The source does not establish a runtime incident or authorize an architectural rewrite.

### Gaps

This is source review, not full compiler escape analysis across all templates or configurations. Syntax-level coverage does not constitute proof that every indirect downstream user respects the borrows.
