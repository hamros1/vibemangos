# The original Scourge Invasion on a realm

## Which zones are attacked and when?

### Takeaway

The six eligible zones had fixed necropolis sites. A June 2006 player saw all six zones under attack together near launch. CMaNGOS supports that opening and allows fewer simultaneous attacks after the first successful defense. [June 2006 account](https://wowpedia.fandom.com/wiki/Talk%3AScourge_Invasion#Some_notes) · [CMaNGOS start conditions](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1030-L1056)

### Cited Findings

The following counts agree between the event-linked necropolis controllers in the project's ClassicDB release and CMaNGOS's site list. The two client field columns give decimal world-state IDs. [ClassicDB release data](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz) · [CMaNGOS site list](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1062-L1115) · [World-state IDs](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldStateDefines.h#L137-L152) · [Area IDs](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.h#L30-L39)

| Zone | Area ID | DB event | Necropolises | Map icon field | Remaining field |
| --- | ---: | ---: | ---: | ---: | ---: |
| Winterspring | 618 | 90 | 3 | 2259 | 2284 |
| Tanaris | 440 | 91 | 3 | 2263 | 2283 |
| Azshara | 16 | 92 | 2 | 2260 | 2279 |
| Blasted Lands | 4 | 93 | 2 | 2261 | 2280 |
| Eastern Plaguelands | 139 | 94 | 2 | 2264 | 2282 |
| Burning Steppes | 46 | 95 | 2 | 2262 | 2281 |

- After a realm has at least one victory, CMaNGOS declines to start a zone when two other zones are already active or when the candidate is the most recently defended zone. It schedules individual zone attempts with a random 45–60 minute delay. A timer can expire while another condition still prevents the attack. [Start conditions](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1030-L1056) · [Timing constants](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.h#L280-L285) · [Zone timer handling](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1501-L1552)
- Each zone event in ClassicDB has one creature 16401 and one creature 16421 per necropolis, and each necropolis has three entries each of creatures 16398 and 16386. The zone events own 14 floating game objects in total. Base event 17 already owns six Mouth of Kel’Thuzad spawns, entry 16995. [ClassicDB release data](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)

### Inferences

- Test initial simultaneous eligibility for all six zones, then finish one while several remain active. Those existing attacks should finish normally. Once only one remains, test that another eligible zone can begin and the last defended zone cannot immediately repeat. This is a test of the CMaNGOS reconstruction.

### Gaps

- The launch observation establishes that six simultaneous attacks were possible. It does not establish the precise server timer distribution, the steady-state concurrency rule, or the exact opening schedule on every original realm.

## What counts as a victory and what does the client see?

### Takeaway

A realm earns one victory when it finishes defending an entire zone. A shard or a single necropolis in an otherwise active zone gives no realm victory. Blizzard explicitly describes the original threshold unit as zones defended. [Blizzard’s account of the original rules](https://us.forums.blizzard.com/en/wow/t/naxxramas-opening-time-and-scourge-invasion-adjustments/741200/1)

### Cited Findings

- In the CMaNGOS invasion script, destruction of a necropolis controller decrements the zone’s remaining count. The realm progression script increments victories when the zone is exhausted. CMaNGOS stores the realm win total, per-zone remaining counts and timers across restarts. [Necropolis destruction](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L498-L517) · [Zone completion](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1501-L1552) · [Persistent state](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1143-L1165)
- Client world state 2219 is the realm defense count. Each zone’s map icon reflects whether its remaining necropolis count is positive, and its remaining field reports the integer count. Players logging in get the current fields. Players already connected receive updates. [State definitions](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldStateDefines.h#L137-L152) · [Initial states](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1668-L1696) · [Updates](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1248-L1283)

### Inferences

- In Winterspring, finish the three distinct necropolises. Expect remaining counts of 2, 1 and 0, with the icon clearing and world state 2219 incrementing on the third. Compare a player who watched the defense with a fresh login on another node in the same realm.
- Replay the same site's destruction from two nodes, then deliver it again after a restart or a new invasion at that site. Check that the defense is credited only once to its original realm and activation. A distinct active realm should retain its own count.

### Gaps

- Available original sources establish zone-level credit. The numeric packet fields and persistence details above come from emulator source and client-era data. The clustered failure cases are suggested tests for this project.

## What are the original milestones and when do activities end?

### Takeaway

The original realm milestones were 50, 100 and 150 defended zones. The 150th victory permanently ended further outdoor attacks. Blizzard separately describes a three-week window from event launch for vendors, quest givers and additional dungeon bosses. [Blizzard’s original-versus-Classic explanation](https://us.forums.blizzard.com/en/wow/t/naxxramas-opening-time-and-scourge-invasion-adjustments/741200/1)

### Cited Findings

- Each original stage made a consumable available in capitals that granted a one-hour stamina buff. A June 24, 2006 player account describes receiving three Lesser Marks of the Dawn. The item IDs in tier order are 23194, 23195 and 23196. [Blizzard’s original rules](https://us.forums.blizzard.com/en/wow/t/naxxramas-opening-time-and-scourge-invasion-adjustments/741200/1) · [Contemporary player account](https://casualwow.blogspot.com/2006/06/lesser-mark-of-dawn.html) · [ClassicDB release data](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)
- ClassicDB uses event 17 for the umbrella event, 89 for additional dungeon spawns, 96–98 for milestone NPCs and 99 for post-victory vendors. Events 96, 97 and 98 supply Initiates/Paladins, Crusaders/Clerics and Champions/Priests respectively. Event 99 supplies outfitters and quartermasters. Event 17 also owns separate vendor spawns. These events have no `game_event_time` rows in the inspected dump. [ClassicDB release data](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz) · [CMaNGOS milestone transitions](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/World/WorldState.cpp#L1285-L1305)
- Blizzard changed the December 2020 Classic rerun to 100, 200 and 300 victories, with a four-week overall window and up to one further week of invasions after 300. Those values date to the 2020 rerelease. [Blizzard’s change announcement](https://us.forums.blizzard.com/en/wow/t/naxxramas-opening-time-and-scourge-invasion-adjustments/741200/1)

### Inferences

- Check transitions at 49→50, 99→100 and 149→150. At the final transition, verify that all outdoor attack scheduling ceases across nodes, including pending starts restored after a restart. Verify vendors, quests and bonus dungeon content remain available at day 20 and expire on the three-week deadline. Check that the realm’s final stage does not duplicate vendor NPCs.

### Gaps

- Blizzard describes a three-week deadline for the rest of the event and immediate outdoor shutdown at 150. Its account does not say precisely how an original realm that still had fewer than 150 defenses after three weeks handled outdoor attacks.
