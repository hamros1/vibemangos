# The original Scourge Invasion shard battle

## How did players damage a fresh shard?

### Takeaway

Players killed the undead around a Necrotic Shard. Their deaths weakened that shard until a Damaged Necrotic Shard replaced it at the same position. Direct attacks on either shard bypass the encounter if allowed.

### Cited Findings

- In June 2006, TheWesson reported following bolts from a floating necropolis to multiple invasion points in Tanaris. Players distinguished killing the surrounding undead during the first phase from dealing with the engineers in the second. [June 26 launch-week observations](https://lurkerlounge.com/forums/printthread.php?tid=4312)
- ClassicDB's three ordinary enemies are Ghoul Berserker 16141, Spectral Soldier 16298 and Skeletal Shocktrooper 16299. The installed death-event rows cast Zap Necrotic Crystal 28032, whose scripted target is the intact shard 16136. Camps choose one pair of the three creature types through spells 28197, 28198 or 28199. The three uncommon enemies are Lumbering Horror 14697, Spirit of the Damned 16379 and Bone Witch 16380. [ClassicDB snapshot](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz) · [CMaNGOS camp types, finder logic and spawn handling](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L745-L910)
- CMaNGOS blocks damage from other factions and rejects external healing. On depletion, 16136 summons damaged shard 16172, transfers its original camp type and despawns. The death notification to the necropolis occurs only after the damaged shard dies. [Shard damage and replacement](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L802-L848)

### Inferences

A useful integration test starts two camps, kills normal enemies in one, and verifies that each death damages just the intact shard in that camp once. A player attacking the shard, or killing the same camp’s remaining ordinary undead after its phase changes, should make no progress. Replacing the intact shard should preserve camp identity and leave all defenses and realm counters intact.

### Gaps

An early contemporary FAQ estimated over a hundred kills. Exact historical kill count, spawn cadence and rare spawn probability are uncertain. The installed raw zap deals 15 damage, but the count depends on effective shard health and damage calculations. CMaNGOS marks parts of its spawn logic as a reconstruction. [Contemporary FAQ](https://www.lurkerlounge.com/forums/thread-4268-post-110619.html) · [CMaNGOS reconstruction note](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L849-L873)

## What should happen when a player disrupts a Cultist Engineer?

### Takeaway

Four Cultist Engineers appear around a damaged shard. A player spends eight Necrotic Runes to disrupt one engineer and face one Shadow of Doom. Killing that elite removes about a quarter of the shard’s maximum health. Converting all four engineers promptly and killing their four Shadows should clear the camp once.

### Cited Findings

- The May test-realm account and June live accounts describe four engineers, an eight-rune interaction and four Shadows. A June 26 player also reported needing a fifth in some runs when the other engineers had time to heal the shard. Ordinary undead no longer advanced this phase. [May test account](https://www.lurkerlounge.com/forums/thread-4312.html) · [June 26 live exchange](https://lurkerlounge.com/forums/printthread.php?tid=4312)
- The four engineers use entry 16230. Their channel is Buttress Channel 28078. The installed gossip menu is 7166. Its option gates interaction through condition 3745, requiring eight Necrotic Runes, item 22484. CMaNGOS handles AI event 7166 by casting Summon Boss 31315 from the player and despawning the engineer via suicide. Its triggered summon callback consumes eight runes and creates one Shadow of Doom 16143 for up to one hour. The installed 31315 spell also has the eight-rune reagent. [Four engineer positions](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L174-L201) · [Summon and payment](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L934-L989) · [Database snapshot](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)
- Shadow of Doom uses Mind Flay 16568 and Fear 12542. Its death casts Zap Necrotic Crystal Corpse 28056. The installed spell’s raw damage is one point. CMaNGOS explicitly applies one quarter of the damaged shard's maximum health. Engineer death also triggers a separate small hit, spell 28041, on the shard. Summoning and killing the Shadow are distinct operations. [Elite spell IDs](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.h#L131-L145) · [Elite combat and death](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L1056-L1110) · [Quarter-health calculation](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L745-L754)

### Inferences

Test seven runes, exactly eight, and two players clicking the same engineer. Only a successful summon should remove eight runes once. Verify the former engineer cannot be reused, the Shadow engages the summoner, death advances only its own damaged shard, and replaying a death cannot grant progress again. In the four-Shadow scenario, use four distinct engineer interactions. Spending all 32 runes without killing the Shadows should leave that camp active.

### Gaps

A June eyewitness reported restoration during the encounter and more than one wave of engineers. The precise repair rate is unknown. CMaNGOS explicitly uses a placeholder that refreshes the damaged shard to full and recreates engineers once an hour. These are different observations and the hour is an emulator convention. [June eyewitness](https://www.lurkerlounge.com/forums/thread-4312.html) · [Upstream explanation](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L693-L708)

## What counts as a destroyed camp, necropolis or defended zone?

### Takeaway

A completed damaged shard clears one camp. A necropolis falls once its subordinate camps have been defeated. Only clearing the final necropolis in an attacked zone counts that zone once toward the realm event.

### Cited Findings

- On damaged-shard death, CMaNGOS casts Soul Revival 28681 on nearby players, propagates death spell 28351 to a relay and removes the local event objects. The installed spell lists 10,000 healing, 10,000 mana and a 10% damage bonus. Relays and proxies communicate with a necropolis health helper, whose death updates the zone’s remaining necropolis count. [Shard death](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L829-L847) · [Health, relay and proxy](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L382-L625) · [ClassicDB spell snapshot](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz)
- Read-only counts from the installed world data yielded 14 Necropolis 16401 and 14 Necropolis Health 16421 spawns, 42 Necropolis Relay 16386, 42 Necropolis Proxy 16398, 42 summoning circle objects 181136 and 1,129 minion finders 16356. Neither shard type nor Shadows have permanent spawn rows. CMaNGOS finds up to three circle locations per necropolis health helper. A June player personally saw at least two invasion points per necropolis. [ClassicDB snapshot](https://github.com/cmangos/classic-db/blob/13e933726f386399d9820138fbd1123e7cda86c8/Full_DB/ClassicDB_1_12_1_z2815.sql.gz) · [Circle discovery](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/world/scourge_invasion.cpp#L382-L439) · [Launch-week observation](https://lurkerlounge.com/forums/printthread.php?tid=4312)
- Blizzard says the original 2006 milestones were 50, 100 and 150 defended zones, ending the event at 150. The 2020 Classic relaunch raised these to 100, 200 and 300 and added time after the final milestone. [Blizzard’s comparison of both versions](https://us.forums.blizzard.com/en/wow/t/naxxramas-opening-time-and-scourge-invasion-adjustments/741200)

### Inferences

Exercise a single camp, all three camps assigned to one necropolis and the last necropolis in a zone as separate transitions. Ensure each camp’s final effect occurs once, surviving siblings stay active, and one defended-zone point appears only on the last transition. Re-entering the grid or replaying a cluster notification should preserve the completed state. The 2006 realm thresholds apply to this emulator’s vanilla target.

### Gaps

The 42-to-14 population ratio is consistent with three camps per necropolis. It does not establish which circles belong to each individual structure. Verify the local mapping against coordinates and event membership. Blizzard's 2020 post describes realm tuning and supplies no per-camp timings for the original release.
