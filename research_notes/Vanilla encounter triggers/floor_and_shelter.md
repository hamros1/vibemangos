# Sapphiron shelter and Heigan eruptions

## How does Sapphiron’s shelter work?

### Takeaway

A successful Icebolt can put a block on the targeted player. When the seven-second Frost Breath finishes, the frozen player and players behind the block survive. An exposed player or one standing beside the same block can take lethal damage. [Classic raid guide](https://www.wowhead.com/classic/guide/sapphiron-naxxramas-raid-strategy) · [Classic raider’s account](https://www.reddit.com/r/classicwow/comments/kdp4c4/sapphiron_strategy/) · [Classic Frost Breath](https://www.wowhead.com/classic/spell=28524/frost-breath)

### Cited Findings

- Blizzard verified that Icebolt does not show a visible boss target, never selects a pet or totem and can produce fewer than five blocks. A player hit by the splash of another player’s Icebolt becomes ineligible for their own bolt. Friendly spells also lose line of sight to the frozen player. A rogue can avoid Frost Breath with Vanish. [Blizzard reference-client findings](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887)
- The installed spell and client records give Icebolt 28522 a 10-yard splash. The bolt has a 25-second stun/periodic aura record. Spell 28535 summons Ice Block 181247 for up to 22 seconds. The comparison implementation puts the block and immunity on a living victim, then removes the immunity, stun, and block after breath. [Classic Icebolt](https://www.wowhead.com/classic/spell=28522/icebolt) · Client radii (`data/dbc/SpellRadius.dbc`) · Client durations (`data/dbc/SpellDuration.dbc`) · [CMaNGOS spell handling](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_sapphiron.cpp#L237)
- In the installed Classic-DB, object 181247 is a door, display 6752, scale 1. The extracted display table maps it to G_IceBlock.mdx. The collision model has local bounds x −2.128 to 1.599, y −1.856 to 1.698, z −4.821 to 24.113. These bound the model; the mesh determines which rays hit. The emulator already indexes and intersects door geometry, including geometry added to a live instance. [Classic-DB](https://github.com/cmangos/classic-db) · Client display table (`data/dbc/GameObjectDisplayInfo.dbc`) · Extracted model bounds (`data/vmaps/temp_gameobject_models`) · [World object collision](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/gameobjectcollision.d#L87) · [Map line of sight](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/map.d#L2261)
- The installed spell tables give the primary 28524 a 7-second cast, 200-yard radius and 75,000–125,000 raw Frost damage. It also triggers 29318 and cleanup 30132. The triggered spell has a 70-yard radius and a fixed database destination on map 533 at (3493.45, −5375.38, 138.168). That destination is about 142 yards from the boss’s flight point (3522.386, −5236.784, 137.709). The intended in-room cover test must exercise the primary spell. [Classic Frost Breath](https://www.wowhead.com/classic/spell=28524/frost-breath) · [Classic-DB](https://github.com/cmangos/classic-db) · Client cast times (`data/dbc/SpellCastTimes.dbc`) · Client radii (`data/dbc/SpellRadius.dbc`) · [Lift-off coordinates](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_sapphiron.cpp#L65)

### Inferences

- Place the actual GO at the frozen target and check the ray from Sapphiron’s flight point at impact. A deterministic test can put one player in the block, another 10 yards behind, one beside it and a fourth in front. A second case should move a player into cover during the cast. Trigger cleanup after all damage has resolved and verify that the same ray is open on the next ground phase. Verify cleanup independently on wipe or encounter end. [Classic raider’s observations](https://www.reddit.com/r/classicwow/comments/kdp4c4/sapphiron_strategy/) · [Collision query](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/map.d#L2261)
- Separate splash eligibility from block creation. A raid spread more than 10 yards apart can offer five distinct targets, while choosing candidates already caught in splash can produce fewer. Add checks for immunity to the incoming breath, unobstructed healing after release, and Vanish during the windup. [Blizzard reference notes](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887)

### Gaps

- Blizzard confirms Vanish works but does not give an exact frame or latency window. Historical accounts reviewed do not specify a universal shelter radius, block orientation, or exact earliest frame of cleanup. The local extracted mesh provides a reproducible source for geometry. [Blizzard reference notes](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887) · Extracted model (`data/vmaps/G_Iceblock.m2.vmo`)

## How does Heigan’s safe floor move?

### Takeaway

Three floor sections erupt while one remains safe. The safe section moves 1, 2, 3, 4, 3, 2, then repeats. The slow and fast controllers have 10-second and 3-second periods respectively. Individual fissures supply the hazardous positions and damage. [Classic encounter guide](https://www.wowhead.com/classic/guide/heigan-the-unclean-naxxramas-raid-strategy) · [Controller implementation](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_heigan.cpp#L280)

### Cited Findings

- The ground phase lasts about 90 seconds. During the 45-second platform phase the raid leaves the platform and dances the faster pattern. CMaNGOS restarts the corresponding controller at each transition. Blizzard confirmed a Classic hotfix for an unintended permanent safe spot in December 2020. [Ground and platform phases](https://www.wowhead.com/classic/guide/heigan-the-unclean-naxxramas-raid-strategy) · [Phase transitions](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_heigan.cpp#L145) · [Blizzard hotfix confirmation](https://us.forums.blizzard.com/en/wow/t/heigan-the-unclean-naxx-bug-spot/762563/5)
- The two installed controller auras are 29351 (10,000 ms) and 30114 (3,000 ms). The six-step cycle casts 30116, 30117, 30118, 30119, 30118, 30117. In the installed Classic-DB, map 533 has 115 candidate fissure spawns, and the four wave spells address 88, 82, 88 and 87 respectively. Each targeted GO's inverse effect mask suppresses two of the three activate effects. A Plague Fissure is a trap with spell 29371. That spell deals 3,500–4,500 raw Nature damage with a six-yard radius. [Wave controller](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_heigan.cpp#L280) · [Classic-DB](https://github.com/cmangos/classic-db) · [Eruption](https://www.wowhead.com/classic/spell=29371/eruption) · Client radii (`data/dbc/SpellRadius.dbc`)

### Inferences

A reproducible four-character test can use these actual fissure centers. On the indicated safe wave the nearest active fissure is more than six yards away. On each other wave an active fissure is centered on that character. Coordinates come from joining map 533 game objects with the type-zero spell_script_target rows for spells 30116–30119. Compare the cast/animation, each character’s health and the next safe section. Repeat across the platform transition, then verify reset clears scheduled waves. [Classic-DB](https://github.com/cmangos/classic-db) · [Target-mask logic](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/spellselection.d#L54)

| Safe wave | Player position (x, y, z) | Distance to closest active fissure |
|---|---|---:|
| 30116 | 2803.58, −3675.67, 273.666 | 21.4 yd |
| 30117 | 2765.45, −3663.31, 273.667 | 20.2 yd |
| 30118 | 2747.13, −3684.35, 274.352 | 12.6 yd |
| 30119 | 2765.76, −3718.73, 274.317 | 17.6 yd |

### Gaps

- The official hotfix does not publish revised fissure coordinates or an algorithm for sub-yard boundary decisions. Phase-start grace delays in CMaNGOS are comparison evidence. The sourced periodic intervals and verified safe-wave locations can be tested independently of the exact first eruption delay. [Blizzard hotfix](https://us.forums.blizzard.com/en/wow/t/heigan-the-unclean-naxx-bug-spot/762563/5) · [Comparison timing](https://github.com/cmangos/mangos-classic/blob/28a26c388a3c817f34cdb4737847a345841b6a08/src/game/AI/ScriptDevAI/scripts/eastern_kingdoms/naxxramas/boss_heigan.cpp#L120)
