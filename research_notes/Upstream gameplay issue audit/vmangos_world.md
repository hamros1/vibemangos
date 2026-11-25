# vMaNGOS world, quest, and instance issues

The review started from dmangos `0615d15` and scanned titles and metadata for 370 issue reports from the first ten pages of the all-state vMaNGOS tracker. The issue sample spans April 7, 2024 to November 22, 2026. That sample guided targeted checks against the D server, the running harness’s Classic-DB installation, and the 1.12 Faction DBC. [vMaNGOS tracker](https://github.com/vmangos/core/issues?q=is%3Aissue)

## Which vMaNGOS issues also appear in dmangos?

### Takeaway

First-time blacksmithing specialization bypassed its trainer quests. Grey quests reduced negative reputation alongside rewards, and looting Blackwood food stores could make an extra warrior appear. All three symptoms had identifiable paths in the server. This work corrects the blacksmithing and Blackwood behavior and adds focused regression tests.

### Cited findings

- **Blacksmithing specialization.** Both hidden factions start at 0 in the 1.12 Faction DBC. Selector spells `17451` and `17452` add 6,000 to the chosen faction and subtract 3,000 from the other. Classic-DB already gives quests `5283` and `5301` the armorsmith lesson and quests `5284` and `5302` the weaponsmith lesson. All four quests were set to level 40 and skill 200 with no minimum reputation. Myolor and Krathok’s scripts originally cast the lesson wrappers themselves. The issue includes an in-game recording showing the trainer quest appear after the selection and an independent vMaNGOS contributor’s migration confirms the prerequisites, reputation gate, referral lines, and relearning a previously earned specialization. [vMaNGOS #3451](https://github.com/vmangos/core/issues/3451), [Classic player recording](https://www.youtube.com/watch?v=qoHGKYkbrWM&t=789s), [vMaNGOS contributor’s proposed migration](https://github.com/FlagFlayer/core/blob/38955c96e0300c14270f6028d303adaeca135f20/sql/migrations/20250304163250_world.sql#L188-L281), [professions.d](/home/hampus/dmangos/source/dmangos/scripts/professions.d), [quests.d](/home/hampus/dmangos/source/dmangos/world/quests.d)
- **Reputation losses from grey quests.** A Classic Era 1.15 level-60 player handing in Strange Alliance received the full −500 Magram penalty and a reduced Gelkis reward. The local quest gives +250 Gelkis and −500 Magram. Starting dmangos code multiplied both by the grey-quest rate, which produced −100 Magram with default rates. [vMaNGOS #3387 and Classic screenshot](https://github.com/vmangos/core/issues/3387), [reputationhandlers.d](/home/hampus/dmangos/source/dmangos/world/reputationhandlers.d), [config.d](/home/hampus/dmangos/source/dmangos/world/config.d)
- **Blackwood food-store guards.** The Classic Hardcore recording shows looting the food stores with their existing guards. All three local food-store objects used `go_furbolg_food`, which summoned warrior `2168` if there was none within 20 yards. The event at the bonfire independently summons warriors when the purification begins. [vMaNGOS #3444](https://github.com/vmangos/core/issues/3444), [Classic Hardcore recording](https://youtu.be/1DVeKSMy2m0?t=4867), [darkshore.d](/home/hampus/dmangos/source/dmangos/scripts/darkshore.d)
- **Jeziba’s Catalogue of the Wayward scene.** The issue links player footage showing Jeziba face the book, point, and direct the player to read it on quest accept. In the harness, quest `5164` has no start or end script. NPC `10976` is its quest giver and has neither an attached script nor a matching D implementation. [vMaNGOS #3587](https://github.com/vmangos/core/issues/3587), [player recording](https://youtu.be/3q6K8nRMtWc?t=598)
- **Hidden Treasures scene.** The issue links player footage of a quest scene for `5942`. In the harness, the quest has no start or end script and Pamela Redpath `10926` has no script binding. [vMaNGOS #2999](https://github.com/vmangos/core/issues/2999), [first player recording](https://youtu.be/nef_hw-23nk?t=962), [second player recording](https://youtu.be/mgsMh8klozg?t=491)
- **Magmadar’s bomb timers match the upstream symptom.** The local script schedules Flame Bomb `19411` for non-mana targets and `20474` for mana targets on separate recurring timers, starting at 12 and 18 seconds. The real-data regression expects both casts within 35 seconds. The upstream reporter references two original-vanilla recordings and claims the boss picks one target per cadence. [vMaNGOS #2648](https://github.com/vmangos/core/issues/2648), [first vanilla recording](https://youtu.be/TXnDMvT7ZJs), [second vanilla recording](https://youtu.be/rF5cpAMYx9U), [moltencore.d](/home/hampus/dmangos/source/dmangos/scripts/moltencore.d), [realscripts_raids.d](/home/hampus/dmangos/source/dmangos/world/realscripts_raids.d)

### Inferences

- Blacksmithing’s first selection should give the referral and leave learning to quest turn-in. Hidden reputation tracks an unfinished choice. The rewarded quest records who can relearn the corresponding earned specialization. The server now uses the ordinary quest reputation requirement for that gate, supplies missing Classic-DB defaults at load time, and honors an explicit database requirement. The existing weapon mastery and specialty unlearn paths are preserved.
- Removing the Blackwood food-store script sends all three objects through the ordinary chest path, which reads their guaranteed quest loot directly from Classic-DB. The regression opens and loots a quest chest with the old database script name. The bonfire’s separate purification event still summons its two warriors.
- The NPC scene reports point to missing content. Confirm the exact timing and text from player recordings and check for matching `broadcast_text` rows before writing scene scripts.

### Gaps

- The blacksmithing tests verify the gossip actions, referral speech, eligibility, and loaded quest requirements. A live walk through both factions’ specialization quests would verify the complete client interaction. Separate broadcast rows suggest cross-specialization retraining for veterans, but the checked contributor implementation supports retraining the same earned specialty and the supplied contemporaneous comment describes weapon mastery. Cross-specialization retraining needs stronger documentation.
- The Magmadar script confirms two timers locally. Raid footage without a cast log can miss targets outside the camera view. Check encounter-wide logs or count casts with corroborating footage before choosing one timer or changing spell targeting.
- Mother Smolderweb locally has skinning loot `100003`, so the code supports the same skinnability reported upstream. The report links a database profile and infers wrong behavior from other spiders. Vanilla-era player evidence is needed before removing the drop. [vMaNGOS #2663](https://github.com/vmangos/core/issues/2663)

## Which reviewed issues already appear covered?

### Takeaway

The data already includes the Dobbins vendor item and Tammra Windfield’s planting event. The summon implementation already avoids randomized object placement.

### Cited findings

- **Skin of Sweet Rum.** Classic-DB explicitly stocks item `1939` on Barkeep Dobbins `465`, with unlimited stock and no condition. [vMaNGOS #3442](https://github.com/vmangos/core/issues/3442)
- **Cycle of Rebirth.** Quest `6301` starts a populated completion script. Tammra casts her sapling spell, points, kneels, and activates the planted object before regaining her quest-giver flag. [vMaNGOS #2785](https://github.com/vmangos/core/issues/2785)
- **Toxic Fogger and Nimboya’s Pike.** `summonWildObject` uses the cast’s explicit destination when supplied and a deterministic point one yard in front otherwise. The vMaNGOS randomized-location symptom for Toxic Fogger `6620` has no matching code. Nimboya’s Pike `11547` already spawns in front, independent of the proposed radius workaround. [vMaNGOS #3210](https://github.com/vmangos/core/issues/3210), [vMaNGOS #3212](https://github.com/vmangos/core/issues/3212), [spellsummons.d](/home/hampus/dmangos/source/dmangos/world/spellsummons.d)

### Gaps

- The placement checks verify deterministic coordinates in code. The pike’s model footprint could still overlap the caster and warrants an in-game collision check.
