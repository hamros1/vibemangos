# Gluth’s Decimate trigger

## What did Blizzard establish?

### Takeaway

Blizzard explicitly ruled out elapsed time as the cause. The studio did not disclose the controlling event, resource, or threshold. The emulator’s first and recurring 105-second timers remain a confirmed discrepancy. [Blizzard’s Abomination Quarter notes](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887) · [Pinned encounter implementation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1521)

### Cited Findings

- Blizzard’s Naxxramas reference findings say “Gluth’s Decimate casts are not based on time, and its interaction is consistent with design.” The entry gives no positive trigger. [Blizzard’s original](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887)
- A Classic raider reported a successful pull with all the zombies kited across the room at Decimate and none reaching Gluth. This is a firsthand account, with no event log attached to this observation. Another December 2020 player estimated a range of 90–100 seconds from experience. [Kiter’s account](https://www.reddit.com/r/classicwow/comments/k4u650/gluth_mage_kiting/) · [Progression players’ discussion](https://www.reddit.com/r/classicwow/comments/ki9pwe/)
- Modern BigWigs starts a 105-second warning at engagement, then resets it after observing spell 28375 damage or miss. DBM also observes Decimate damage and counts the casts. Those are client predictions and detections. The CMaNGOS and vMaNGOS scripts separately use a 105-second scheduling value. [BigWigs encounter source](https://github.com/BigWigsMods/BigWigs_Classic/blob/master/Naxxramas_Classic/Gluth.lua) · [DBM encounter source](https://github.com/DeadlyBossMods/DBM-Vanilla/blob/master/DBM-Raids-Vanilla/VanillaNaxx/ConstructQuarter/Gluth.lua) · [CMaNGOS encounter source](https://github.com/cmangos/mangos-classic/blob/master/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_gluth.cpp) · [vMaNGOS encounter source](https://github.com/vmangos/core/blob/development/src/scripts/eastern_kingdoms/eastern_plaguelands/naxxramas/boss_gluth.cpp)
- A BigWigs revision posted August 1, 2006 distinguishes the engagement countdown from the cast alert. At engagement it displays a 105-second bar. Its Decimate alert listens for the combat message “Gluth gains Decimate.” Independently, the installed spell table gives spell 28374 a stun aura on the caster, and duration record 27 in `SpellDuration.dbc` specifies three seconds. The cast and self-aura therefore give two more markers to search for in a complete log. [August 2006 BigWigs source](https://pastebin.ca/110785)


### Inferences

- Replacing the timer with a random interval repeats the same conceptual error. Requiring Gluth to eat a zombie or reach one conflicts with the kiter’s report. Counting summoned zombies, counting surviving zombies, boss health thresholds and melee-event counts remain distinguishable hypotheses. [Blizzard](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887) · [Firsthand kiting account](https://www.reddit.com/r/classicwow/comments/k4u650/gluth_mage_kiting/)

### Gaps

- No positive original-game trigger met the evidence threshold for implementation.

## Can available spell data and recordings identify the trigger?

### Takeaway

The spell records explain portions of the zombie behavior and the effect once Decimate fires. Accessible records inspected here did not supply a causal engagement-to-cast sequence. [CMaNGOS spell and encounter implementation](https://github.com/cmangos/mangos-classic/blob/master/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_gluth.cpp) · [Public raid archive index](https://classic.warcraftlogs.com/guild/reports-list/489695?page=3)

### Cited Findings

- Read-only inspection of the installed Classic-DB found spell 28216 periodically triggers summon spell 28217 at six-second intervals. Spell 28235 triggers zombie search 28236 at three seconds and 29681 triggers call 29682 at three seconds. Decimate 28374 has a script effect and zero recovery time. These are distinct spell records. CMaNGOS identifies the same spell IDs and implements the 5%-health effect via 28375. [CMaNGOS encounter and spell definitions](https://github.com/cmangos/mangos-classic/blob/master/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_gluth.cpp) · [Classic-DB](https://github.com/cmangos/classic-db)
- A December 2020 Warcraft Logs guild archive indexes Naxxramas reports. Access to individual event streams through this archive was unavailable here. The DBM public Gluth replay is labeled Season of Discovery Heroic. A separate public 1.12 raid parser uses Turtle WoW tooling and its sample files lack Blizzard Classic provenance. [December 2020 index](https://classic.warcraftlogs.com/guild/reports-list/489695?page=3) · [DBM replay inventory](https://github.com/DeadlyBossMods/DBM-Test-Results) · [1.12 parser and examples](https://github.com/melbaa/summarize_consumes)
- A Classic Era Warcraft Logs analysis repository contains Gluth ranking fixtures and stores its event exports in Git LFS. The ranking summaries omit the ordered events. The raw export findings appear below. [Classic Era repository](https://github.com/David-c0degeek/necropsy/tree/2b7e7f16a84fc40b1366b56f7d942f4a79f5fcf5) · [Strategy provenance](https://github.com/David-c0degeek/necropsy/blob/2b7e7f16a84fc40b1366b56f7d942f4a79f5fcf5/tasks/naxx-completion/research/naxx-strategy-proposal.yaml#L1028)

### Inferences

- A six-second summoning aura can correlate count with elapsed time in a typical pull even if neither a timer nor summon count is the rule. A warning bar or a single tightly timed pull cannot establish which event caused Decimate. [CMaNGOS spell definitions](https://github.com/cmangos/mangos-classic/blob/master/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_gluth.cpp) · [BigWigs timing model](https://github.com/BigWigsMods/BigWigs_Classic/blob/master/Naxxramas_Classic/Gluth.lua)

### Gaps

- The available event streams do not include a verified Decimate. A complete stream spanning a cast and independent pulls with different boss and add states are still needed to test a proposed trigger.

## What would justify a fix?

### Takeaway

Capture multiple Blizzard Classic Era pulls lasting through Decimate, including a later Decimate in the same attempt. Compare event counts and game states before changing the scheduler. Warcraft Logs documents the advanced combat logging process. [Warcraft Logs recording instructions](https://classic.warcraftlogs.com/help/start)

### Cited Findings

- Modern BigWigs detects damage or misses from 28375 and coalesces simultaneous raid-member events. A successful 28374 cast or its self-stun application can mark Decimate when target damage is absent. [BigWigs encounter source](https://github.com/BigWigsMods/BigWigs_Classic/blob/master/Naxxramas_Classic/Gluth.lua)

### Inferences

- Design a discrimination test with comparable boss DPS but different numbers of living chows, and comparable chow counts but different boss DPS, attack uptime or Frenzy dispels. Record each distinct chow GUID, its first appearance, deaths and devours, boss health, boss swings including misses, successful casts and Decimate. Missing summon events must be marked unknown. Distinguish the first damage event from the causal event. [Warcraft Logs](https://classic.warcraftlogs.com/help/start) · [BigWigs Decimate detector](https://github.com/BigWigsMods/BigWigs_Classic/blob/master/Naxxramas_Classic/Gluth.lua)
- Once a candidate survives these comparisons, reserve independent pulls to falsify it. Test one event below the proposed threshold, its crossing more than once, issue of exactly one cast, a wipe and immediate repull, and a full pull passing 105 seconds without the proposed state. [Current scheduling and encounter tests](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1500)

### Gaps

- Acceptance for a replacement remains pending reference evidence. The original evidence review left the scheduler unchanged. The damage implementation is recorded below.


## Implementation follow-up

Spell 28374 now calls damage spell 28375 for eligible targets above the health floor. The installed spell data marks 28375 as physical, with damage class zero, caster modifier exclusion and target modifier exclusion. Its real-data check includes an armored target. The documented cast-trigger discrepancy remains open. ClassicThreat and the public BigWigs Transcriptor repository did not provide raw Gluth pulls for an independent event-count test. Eden’s December 2020 recording identifies a Classic progression pull at 26:06. A video chapter alone cannot establish a threshold. [Eden’s progression recording](https://www.youtube.com/watch?v=VXm4G33-DTk&t=1566s) · [ClassicThreat](https://github.com/jvd33/ClassicThreat) · [Transcriptor](https://github.com/BigWigsMods/Transcriptor)


The public Era threat viewer lists **Gluth, fight 39** in the raid report from December 15, 2020. It returned a fetch error for the fight. Warcraft Logs prompted for human verification before displaying the events. The encounter list confirms the pull exists. Its chow counts and boss casts could not be recovered. The open parses.gg bracket index returned only Retail entries at the time of this check, and the published bulk dataset excludes raw combat logs and wipes. [Open dataset description](https://parses.gg/developers) [Era viewer](https://voomlz.github.io/era/?id=dGfwz9g6RJaVLPN7&fight=39) · [Original raid report](https://classic.warcraftlogs.com/reports/dGfwz9g6RJaVLPN7#fight=39)

## Raw event exports and original footage

The Git LFS archives contain **41 complete Classic Era Gluth kills** and 444,697 combat events. Kill durations range from 43.323 to 104.603 seconds. I checked each paginated encounter stream for a matching encounter start and end, a terminal page cursor, and any event with spell ID 28374 or 28375. None contained either spell. The two longest complete pulls recorded different numbers of boss melee events and Frenzy casts.

| Report and fight | Duration | Boss melee events | Frenzy casts | Observed Zombie Chow instances |
|---|---:|---:|---:|---:|
| [qZ8tk1Nw9G2hzPBJ, fight 45](https://vanilla.warcraftlogs.com/reports/qZ8tk1Nw9G2hzPBJ#fight=45) | 104.603 s | 83 | 10 | 24 |
| [HfzqpdRtC4Jxv3cP, fight 81](https://vanilla.warcraftlogs.com/reports/HfzqpdRtC4Jxv3cP#fight=81) | 99.258 s | 87 | 9 | 24 |

For those counts, I matched the report's actor IDs using NPC IDs 15932 and 16360, counted boss melee damage events and Frenzy cast events, and deduplicated zombies by actor and instance. Observed zombies may miss spawns outside the recorder’s coverage. Ten visible Frenzy casts and 24 observed zombies can occur without a recorded Decimate. These kills cannot establish what happens during a longer pull. [Archive manifests and event exports](https://github.com/David-c0degeek/necropsy/tree/2b7e7f16a84fc40b1366b56f7d942f4a79f5fcf5/tests/golden/raids/raw)

A separate archive lists a 153.197-second Classic Era kill. Its raid-wide events reach only 94.531 seconds. The first page advertises a continuation and the exported next page is empty, so the capture cannot establish whether or when Decimate happened later. [Archive provenance](https://github.com/David-c0degeek/necropsy/blob/2b7e7f16a84fc40b1366b56f7d942f4a79f5fcf5/tests/golden/haplina_naxx/PROVENANCE.md) · [Report and fight](https://vanilla.warcraftlogs.com/reports/JG9Ncxdwh3VXnzmr#fight=30)

A 2006 warrior recording shows the addon announcing the encounter and displaying a Decimate warning together during the opening wipe, before the warrior dies from a fall. The visible log identifies fall damage. It does not show a legible Decimate damage line, and the footage does not establish when the rest of the raid first engaged. A combat-log capture could establish whether the warning coincides with a spell event. [Syndicate tank recording, 0:27–0:34](https://www.youtube.com/watch?v=DSD7xsm1eEE&t=27s)

With a raw, English-language Blizzard Classic combat log, run the following from the repository. For another game language, set `--encounter-name` to the encounter name in the file.

```sh
python3 tools/harness/gluth_trace.py WoWCombatLog*.txt > gluth-pulls.csv
```

Each Decimate produces one row even when it hits many players. The `marker` column shows the first event used to count it, which can be a successful cast or self-aura from spell 28374 or damage or a miss from 28375. The encounter-end row includes pulls with zero Decimates. Counts are cumulative per pull and include observed boss swings, Frenzy and Mortal Wound casts, distinct chows, summons, deaths and successful devour casts. Incomplete recording or limited combat-log range can hide events. Compare pulls with different counts and durations, and check the original health and position events before inferring a cause.
