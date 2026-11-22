# Classic Scourge Invasion bindings

Baseline is dmangos commit 780ff19. The installed classicmangos tables were queried read-only. The original Blizzard event description verifies the player-facing progression. Individual numeric spell IDs, spawn timers and NPC callbacks below come from ClassicDB and the CMaNGOS reconstruction. [Blizzard’s event description](https://us.forums.blizzard.com/en/wow/t/ptr-scourge-invasion-test-is-underway/679484) · [Pinned ClassicDB full data](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

## What do the thirteen NPC templates do?

### Takeaway

Thirteen templates use nine distinct creature script names. The two shard states, three transient wave spawners and two combat minions share handlers. Two additional game-object scripts and a spell callback connect the creatures to their physical camps and the player's interaction. [CMaNGOS script and registration](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp) · [NPCs, spells and broadcast text identifiers](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.h)

### Cited Findings

All script suffixes below follow the literal prefix `scourge_invasion_`. Static counts come from installed creature placements. Camp combatants and minion spawners have zero static placements. [ClassicDB](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

| Entry and creature | Script suffix | Behaviour |
|---|---|---|
| 16136 Necrotic Shard | necrotic_shard | Chooses one of three camp themes through 28201, drives finder waves and receives 28032 on surrounding undead deaths. When destroyed it creates the damaged shard at its own position with the same camp theme. [Shard](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L638-L897) |
| 16172 Damaged Necrotic Shard | necrotic_shard | Creates four cultists. On 28056 deals one-quarter maximum health to itself. Final death emits Soul Revival 28681 and the camp-destruction message 28351. [Shard](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L638-L897) |
| 16306 ghost/ghoul spawner | minion_spawner | Chooses 16298 Spectral Soldier or 16141 Ghoul Berserker, with rare 16379 Spirit of the Damned or 14697 Lumbering Horror. [Wave selection](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L899-L930) |
| 16336 ghost/skeleton spawner | minion_spawner | Chooses 16298 or 16299 Skeletal Shocktrooper, with rare 16379 or 16380 Bone Witch. [Wave selection](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L899-L930) |
| 16338 ghoul/skeleton spawner | minion_spawner | Chooses 16141 or 16299, with rare 14697 or 16380. All three transient spawners summon after 2–5 seconds and show 28234. The used finder recycles after 150–200 seconds. [Finder and spawner](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L870-L930) |
| 16230 Cultist Engineer | cultist_engineer | Spawns shield 181142, channels 28078 and offers gossip menu 7166 option 0 under DB condition 3745. Using eight Necrotic Runes invokes player spell 31315, summons 16143 and kills the cultist. Cultist death removes the shield and triggers 28041 against the damaged shard. Spell 31315 has reagent 22484 ×8 and summon effect 41 for entry 16143. The upstream triggered-cast path explicitly removes the runes in its summon callback. [Cultist and summon implementation](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp) |
| 16143 Shadow of Doom | minion | Announces itself, shows smoke 10389, becomes attackable, engages its summoner, uses Mind Flay 16568 and Fear 12542 and triggers 28056 on death. [Combat and death](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L995-L1128) |
| 16383 Flameshocker | minion | City-assault mob. Applies visual 28330, uses Touch of Flame, retaliates on death using 28323 and has a fade/despawn path. The Pallid Horror that drives the city assault has its own script. [City minion and boss](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L995-L1239) |
| 16386 Necropolis Relay | necropolis_relay | 42 fixed placements. Outgoing 28366 becomes 28326 toward the camp. Returning 28281 becomes 28365 toward the proxy. Forwards destruction 28351 and disappears. [Relay](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L585-L636) |
| 16398 Necropolis Proxy | necropolis_proxy | 42 fixed placements. Outgoing 28373 becomes 28366 toward the relay. Returning 28365 becomes 28367 toward the necropolis. Forwards destruction to the health controller. [Proxy](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L542-L584) |
| 16401 Necropolis | necropolis | 14 fixed placements. Periodically casts 28373, receives the return delivery 28367 and applies 28395. The reference restores its altitude if it falls. [Necropolis](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L347-L377) |
| 16421 Necropolis health | necropolis_health | 14 fixed placements. Each destroyed camp reaching it with 28351 produces the 28386 zap. Three camp destructions bring down one necropolis, clean up the associated ship and update zone progress. [Health controller](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L379-L537) |
| 16995 Mouth of Kel’Thuzad | mouth | Six fixed capital placements under event 17. The zone controller creates additional outdoor mouths for battlefield yells and weather on start/stop. [Mouth AI](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L303-L343) · [World controller](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1370-L1465) |

### Inferences

Validate the ritual through the normal gossip entry point. A player with seven runes retains them, a successful interaction consumes exactly eight, and two players selecting the same engineer produce a single Shadow. Exercise ordinary undead deaths through EventAI. All six common/rare templates have death event type 6, action 11, spell 28032 in installed ClassicDB. Implementing a second direct kill hook could apply duplicate shard damage. [Database](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz) · [Cultist callback](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L934-L993)

### Gaps

Blizzard’s public description does not specify the spell timings, individual IDs, spawn probabilities or all weather effects. Those details are identified here as reconstructed behaviour. No live realm was changed or played to confirm the audiovisual presentation. [Blizzard](https://us.forums.blizzard.com/en/wow/t/ptr-scourge-invasion-test-is-underway/679484)

## Which coordinates and database associations should drive camps?

### Takeaway

The installed data places 42 ground circles, 14 visible outdoor ships and 14 fixed health controllers. Assigning each circle to its nearest health controller in three dimensions within its event gives exactly three circles per ship at all fourteen sites. Use game-object and creature spawn GUIDs for persistent identity. [ClassicDB](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

### Cited Findings

The table gives one health-controller position per zone and the largest 3D distance, rounded to the nearest yard, from any circle to its assigned controller in that zone. Coordinates and counts were measured from installed game_event_creature, game_event_gameobject, creature and gameobject data. Each zone includes fixed finder NPCs (16356), 1,129 across these events. [ClassicDB full data](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

| Event and zone | Map | Ship/circle/finder counts | Example health GUID and (X, Y, Z) | Most distant assigned circle |
|---|---:|---:|---|---:|
| 90 Winterspring | 1 | 3 / 9 / 222 | 83916 (6184.28, −4913.32, 807.76) | 260 yd |
| 91 Tanaris | 1 | 3 / 9 / 252 | 97407 (−8633.21, −2499.82, 114.10) | 253 yd |
| 92 Azshara | 1 | 2 / 6 / 168 | 97592 (3299.55, −4301.30, 177.891) | 273 yd |
| 93 Blasted Lands | 0 | 2 / 6 / 168 | 97776 (−11402.10, −3316.55, 111.272) | 289 yd |
| 94 Eastern Plaguelands | 0 | 2 / 6 / 156 | 97941 (1766.67, −3033.34, 132.888) | 255 yd |
| 95 Burning Steppes | 0 | 2 / 6 / 163 | 103182 (−8232.78, −1099.86, 201.572) | 256 yd |

Trap 181136, literally “Circle”, is the outdoor ground template, script scourge_invasion_go_circle. Its data3 is 28344 and the reference casts it as soon as the GO spawns. Template 181273 “Summoning Circle” has no static placements. Five visible necropolis templates (181154, 181215, 181223, 181373, 181374) share scourge_invasion_go_necropolis. Their counts are 6, 3, 3, 1 and 1. They link to trap 181214. Spell 27866 has guardian-summon effects for both 16401 and 16421, which installed data already places. The six 181172 capital necropoli are separate. [Circle and ship callbacks](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L277-L301) · [ClassicDB](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

Event 17 is the overall invasion, 89 the dungeon event, 90–95 the outdoor zones, and 96–99 the 50, 100, 150 and completed stages. The installed tables already associate spawn GUIDs with their regional events. [ClassicDB](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

### Inferences

Initialize the shard at its circle’s stored ground coordinates and preserve DB Z on airborne controllers and visible ships. Area activation should choose one physical controller pair and create each shard once, even if the linked trap, active GO and fixed controller are loaded on different ticks. A cell-local player search cannot reliably find assets hundreds of yards away. Match stable configured owners before runtime visibility is evaluated. [Health-controller association and altitude handling](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L379-L537)

### Gaps

Circle-to-controller associations above are inferred geometrically because the queried tables give an event assignment and coordinates, without an explicit owner GUID. These checks establish database topology. They do not establish collision heights on a particular client's terrain extraction or that the client renders all the purple bolts. [ClassicDB](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

## Where should runtime registration and durable progress be tested?

### Takeaway

The baseline already binds three invasion spells, handles world-event spawn associations and has a cluster-owned persistent world-state service for the war effort. A regression test must observe a camp in the world and the shared state change through normal gameplay events to prove these pieces are connected. [Existing spells](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/worldspells.d#L149-L185) · [World services](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/context.d#L3094-L3150)

### Cited Findings

- Script modules are registered explicitly. Entity callbacks include Spawned, Died, SpellHit, GossipSelect and SummonedDied, with ObjectLoaded for game objects. Existing spell scripts cover 28265 Scourge Strike, 28345 Communique Trigger (sends 28281) and 28091 Despawner Self. Summon Boss 31315 is a distinct script binding. [Registration](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/package.d#L82) · [Event API](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/script/api.d) · [Implemented spells](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/worldspells.d#L149-L185)
- WorldData loads associations. GameEvents.start(id, on) controls the event override, and the WorldContext scheduler periodically reconciles starts/stops, spawns and mail. Character DB game_event_status is already used to remember mailed events. [Event loading](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/worlddata.d#L1072) · [GameEvents](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/gameevents.d#L210-L280) · [Scheduler and event mail](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/context.d#L2900-L3010)
- Character DB supports worldState(id) and saveWorldState(id, serializedText), backed by MySQL and a memory implementation. WarEffortHost restores live migrated service bytes in preference to saved DB state, has a single writer and publishes status for other nodes. Existing tests model two nodes. [Persistence interface](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/database.d#L795-L804) · [MySQL implementation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/characterdb.d#L1274-L1290) · [Service integration](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/context.d#L3094-L3150) · [Service and cluster tests](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/wareffort.d#L604-L880)

### Inferences

Use a distinct invasion world-state key and persist each active invasion generation, zone, ship spawn GUID and completed circle GUID. Include the damaged shard phase and already-used engineer slots if progress through one battle must survive a restart. Exercise duplicate death delivery, an owner move before and after a write, and off-screen/map-cell reloads. Verify that three unique camps remove exactly their one ship and a retry cannot increment defended-zone progress twice. Track a second live ship as a control. CMaNGOS itself notes its count-only reload can restore a different necropolis. [Reference reload behaviour](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1419) · [Existing cluster test pattern](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/wareffort.d#L694-L880)

### Gaps

A script-name coverage count establishes registration only. Critical remaining runtime checks include the trap casting on initial load, EventAI routing a dead mob's spell to the associated shard, ritual cost ownership, visible ship removal across nodes, and continuity of the same site after a process restart. Original Blizzard documentation establishes the outcome of defending zones but does not describe server persistence. [Blizzard](https://us.forums.blizzard.com/en/wow/t/ptr-scourge-invasion-test-is-underway/679484)
