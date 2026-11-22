# Gameplay fidelity audit

Target: original World of Warcraft 1.12.1. Audited server revision `d6ba4e8` on 2026-11-22. This is a targeted comparison across combat, instances, mail, battleground objectives, loot, progression and scripted content. The [rules inventory](../RULES-AUDIT.md) covers the larger project. A passing build alone cannot establish historical accuracy.

## Five differences reproduced on the original revision

| Priority | Rule and player impact | What the server did | Historical evidence |
|---|---|---|---|
| 1 | The 16-debuff limit constrains raid damage and debuff selection. | Separate priests cast rank 1 Shadow Word: Pain on one creature. Sixteen effects had visible slots, but **17** periodic effects were due on the next tick. The aura list keeps the overflow effect active. The test measures scheduled ticks, before damage delivery. | [Blizzard on preserving the 16-debuff limit](https://worldofwarcraft.blizzard.com/en-gb/news/22646759) |
| 2 | An account can enter five distinct dungeon or raid copies per hour on a realm. Changing world nodes should preserve that history. | After five entries, the admission check allowed re-entry into an existing copy and refused a sixth on the first world context. A second context sharing its database allowed the sixth for the same account. This exercises the admission methods directly. A live portal handoff remains to be tested. | [Blizzard on the original realm scope and later change](https://us.forums.blizzard.com/en/wow/t/wow-classic-hotfixes-updated-november-16/361448/381) |
| 3 | A dual-wielding warrior’s off hand loses the extra dual-wield miss penalty while Heroic Strike is queued. This affects sustained warrior damage. | Using the same weapons, target, weapon skill and random seed, the off hand missed **220 of 1,000** swings both with and without a queued rank 1 Heroic Strike. The probe reads actual melee outcome packets. | [Blizzard’s reference-client findings](https://us.forums.blizzard.com/en/wow/t/175887) |
| 4 | A critical hit caused by deliberately sitting should not activate Enrage. | A warrior with rank 1 Enrage sat through the client opcode. A creature’s calculated melee crit was delivered to the warrior and activated aura 12880. Blizzard also names Blood Craze and Reckoning. Those talents need separate tests before applying a shared fix. | [Blizzard’s sitting-crit rule](https://us.forums.blizzard.com/en/wow/t/175887) |
| 5 | Mailing an item to an alt takes one hour in the target version. | A mailbox send containing an actual inventory item produced a delivery delay of **0 seconds** to a same-account alt and **3,600 seconds** to another account. Both used an offline recipient. | [November 2006 mail evidence in the project](../FORMULAS.md#mail) and [Blizzard’s later Anniversary change](https://us.forums.blizzard.com/en/wow/t/2007834/682) |

## Results after the fixes

- Shadow Word: Pain filled all 16 slots, with exactly 16 effects due to tick. An existing caster could refresh, and a character save and reload preserved all 16 harmful effects. At capacity, periodic damage could replace a peer, and Fear and Sunder Armor could displace plain periodic damage. A Blizzard ground effect occupied a slot without showing a debuff icon or scheduling a second tick. For eligible effects at the same priority, the server selects the oldest in application order. The full 1.12 eviction order and historical tie-break remain unverified. [Player observations of combat logs](https://www.reddit.com/r/classicwow/comments/e6h4wx/debuff_priorities/) · [Blizzard’s hidden debuff findings](https://us.forums.blizzard.com/en/wow/t/175887)
- The destination host admits an actual instance ID against the shared character database. Two MariaDB connections competed for the fifth slot. Exactly one succeeded, a new connection could re-enter, and a sixth became eligible at the one-hour boundary. A simulated cluster portal handoff counted the destination copy once. For the live test, use a regular player account, enter five distinct copies within an hour, cross to another node, and attempt a sixth. Expect a refusal for the sixth and successful re-entry into an existing copy. [History of the hourly limit](https://us.forums.blizzard.com/en/wow/t/361448/381)
- With the same seed, the off hand missed 220 of 1,000 ordinary swings and 51 while Heroic Strike was queued.
- Sitting melee crits left Enrage, Blood Craze and Reckoning inactive. A subsequent standing crit activated rank 5 Reckoning.
- Both item mail deliveries were scheduled 3,600 seconds after sending.

## Other mechanics checked

| Area | Result and extent of comparison |
|---|---|
| Warsong Gulch | The 10-player team limit, level brackets and three captures to win match the published rules. See the queue definitions and the scoring tests in `world/bgqueue.d` and `world/warsong.d`. [Blizzard’s battleground guide](https://worldofwarcraft.blizzard.com/en-gb/news/23237900) |
| Arathi Basin | The 15-player team limit, five resource bases and 2,000-resource victory condition match the published Classic rules. The scoring path and win condition are in `world/arathi.d`. [Blizzard’s Arathi Basin guide](https://worldofwarcraft.blizzard.com/en-us/news/23320961/) |
| Party loot | The Need Before Greed path checks item usability and resolves eligible Need rolls before Greed. The eligibility and resolution cases are in `world/loot.d`. [Blizzard’s Classic primer](https://worldofwarcraft.blizzard.com/en-us/news/23090134) |
| Rest and resurrection | The rest and XP paths award the rested bonus on kills and accumulate rest faster at an inn. The spirit healer path applies gear damage and level-dependent resurrection sickness. These broad rules agree with the manual. This comparison does not validate every rate, level cutoff or item slot. See `world/experience.d`, `world/charscreen.d` and `world/death.d`. [Original game manual](https://us.media.blizzard.com/manuals/wow/wow-classic-manual-enUS.pdf) |
| Escorts and quest events | The existing world-data survey reached its expected outcome for 36 of 44 escort scenarios and 9 of 19 quest events. The remaining cases mix incomplete test setups and possible script defects. Reproduce with the correct faction, map, player interactions and end-of-quest credit before counting a defect. See `world/realscripts_world.d`. |

## Auto Shot timing

The timed harness reproduced a paused weapon timer. A level 60 hunter fired a Worn Shortbow at a stationary target with 10 ms character updates. The stationary control fired the first shot after 510 ms and the next after another 2,300 ms. For the movement trials, scripted client packets started and stopped movement. Each sample measured the next arrow spent.

| Movement began after first shot | Stopped after the next shot was normally due | Delay before the fix | Delay after the fix |
|---:|---:|---:|---:|
| 300 ms | 100 ms | 2,010 ms | 900 ms |
| 300 ms | 350 ms | 2,010 ms | 650 ms |
| 300 ms | 600 ms | 2,010 ms | 900 ms |
| 2,000 ms | 100 ms | 510 ms | 900 ms |
| 2,000 ms | 350 ms | 510 ms | 650 ms |
| 2,000 ms | 600 ms | 510 ms | 900 ms |

Before the fix, the remaining weapon time at movement start determined the delay. Changing when the player stopped had no effect within either group. Blizzard describes the weapon timer reaching its due time during movement, then checking every 500 ms for a stop before resuming Auto Shot. The reference description establishes when the retry check runs. The harness measures when the arrow fires, which can also include a wind-up. [Blizzard’s Auto Shot explanation](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887)

The fix keeps the weapon timer running and schedules retries from the original due time. On a retry that finds the hunter stationary, the server starts its existing 500 ms wind-up. This preserves a server behavior whose exact duration the reference description does not establish. The harness also confirms the stationary cadence, the original due time after a short move, and cancellation of a real wand’s Shoot on movement. The wand fired again after a fresh cast.

## Hateful Strike targeting

At revision `a62fd08`, the harness loaded Patchwerk in Naxxramas and read the target from the first Hateful Strike cast packet in each six-player trial. Every tank had scripted threat and health. The active tank and melee ranges were checked in each setup. The packet gives the chosen target even if the strike misses.

| Trial | Before | After |
|---|---|---|
| Rank 2 at 8,000/10,000 HP and rank 3 at 6,000/6,000 HP | Rank 3 at 6,000 HP | Rank 2 at 8,000 HP |
| Active tank is rank 1 and has the highest health, with other tanks in melee | Rank 1, the active tank | Rank 2 |
| Rank 5 has more HP than rank 4 and everyone is in melee | Rank 4 | Rank 4 |
| Rank 2 is out of melee range and rank 5 is healthiest in melee | Rank 5 | Rank 4 |
| Only the active tank is in melee | Rank 1, the active tank | Rank 1, the active tank |
| The active tank is rank 2 on threat and has the highest health | Rank 2, the active tank | Rank 1 |

Before the fix, the script filtered for melee players before taking four threat ranks, kept the active tank eligible, and ranked that pool by health percentage. Blizzard confirms that threat and HP both matter. A period raider account describes three secondary tanks and selection by highest HP. A 2020 raider explicitly describes highest current HP and excluding the main tank. Together these support a raw-current-HP comparison and a separate rule for the active tank. The period account is available on a wiki talk page and the 2020 account is a player report. [Blizzard’s Naxxramas findings](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887) · [2006 raider discussion](https://warcraft.wiki.gg/wiki/Talk%3APatchwerk) · [2020 raider report](https://www.reddit.com/r/classicwow/comments/kbi90g/patchwerk_threat/)

A separate 2020 guild observation reports that a ranged player at threat rank 3 left ranks 2 and 4 as the only recipients. That favors applying a global threat cutoff before the melee filter, although the report does not provide synchronized threat and health data. The fix considers the top four living, targetable players by threat, then requires melee reach and chooses the greatest current HP among the secondary targets. When ranks and aggro differ, it prefers excluding the active victim. It keeps the active tank as a fallback when no secondary target qualifies. Those fallback and split-aggro choices lack a controlled reference test. [2020 guild observation](https://www.wowhead.com/classic/guide/patchwerk-naxxramas-raid-strategy#comments)

## Flamestrike and the debuff cap

Flamestrike’s ground effect was missing from the hidden-debuff list. All six player ranks now use the existing ground-effect cap accounting. A cast beside a target with 15 Shadow Word: Pain debuffs filled its sixteenth slot without displaying an icon and released the slot when the area expired. [Blizzard’s hidden-debuff findings](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887)

## Quest completion

- **Suntara Stones** now starts the marksman’s relay when the database summon specifies a spawn template with a relay. The loader corrects the stock relay’s source and target selection and directs the dummy shot to Dorius. His script awards group quest credit when it receives the shot. The real-data fixture lets the marksman act instead of treating him as a regular ambusher. [Database script command reference](https://github.com/cmangos/mangos-classic/blob/master/doc/script_commands.txt)
- **In Dreams** now records Isillien’s defeat even if it happens before Tirion’s challenge. Tirion moves into the epilogue after the challenge in that case. A death during the duel also schedules the epilogue through the same path.
- **Wandering Shay** and **Tooga’s Quest** pass with fixture changes. The player uses Shay’s Bell when the follower wanders, and advances toward Torta with a following distance that lets Tooga catch up. Both checks still require the actual quest script to award completion.
- **The Sleeper Has Awakened** and **A Little Help From My Friends** now run through the Horn of Awakening and Spraggle’s Canteen in the fixture. The player waits within range for each cast before leading the follower onward.
- **Freedom for All Creatures** now runs through the cage key in the player’s keyring. The fixture approaches the cage and waits for the freed sprites to complete the event.
- **Triage** keeps the event active when the last patients have been admitted. A regression test confirms that a patient already in a bunk can still provide the last required save. The full clinic playthrough still needs verification.
- **Extinguishing the Idol**, **Willix the Importer**, and **A Fine Mess** run in the same dungeon copy as the player. The last fixture leads Kernobee to the clean-zone door before checking quest credit.
- **Jail Break!** runs through all five prison stops in Blackrock Depths. The player opens the cells and frees Dughal and Tobias through their gossip options. The test defeats the hostile prisoners and waits for Windsor to reach the exit and award quest credit.

The sweep now passes 41 of 44 escort cases and 15 of 19 quest-event cases. It checks quest state and verifies the leave-behind failure path for escorted NPCs. The remaining setup gaps involve dynamic summons, First Aid and reputation.

## Reproduce

With the repository harness database and extracted client data configured, run from the project root:

```sh
tools/harness/check.sh --quick
tools/harness/trainer-spells.sh --gameplay
```

The first command builds the release binaries and runs the ordinary unit suite. The second links the opt-in comparison against those objects and runs with the harness database and synthetic player state. Search its output for `gameplay-audit` for the regression checks, `auto-shot` for the timing measurements, and `hateful-strike` for the encounter observations. The timing probe verifies each observed delay against the expected retry and wind-up. A failed regression check returns a failing exit status. The controls distinguish a genuine rule difference from failure to equip weapons, fill debuff slots, deliver mail or establish a local lockout. No live character is needed.
