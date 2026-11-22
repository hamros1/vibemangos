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

## Two follow-up tests

- **Hunter Auto Shot after moving.** Blizzard describes a weapon timer that can mature while moving, followed by retries every 500 ms. In `world/spellhandlers.d`, `updateAutoRepeat` returns during movement before reducing the remaining timer. The first stationary update enforces a wind-up. Record shot timestamps after moving for longer than a whole weapon swing and stopping at different points in the retry cycle. This is a code-level discrepancy pending timed reproduction. [Blizzard’s Auto Shot explanation](https://us.forums.blizzard.com/en/wow/t/175887)
- **Patchwerk’s Hateful Strike target.** The encounter script compares health *percentages* among melee threat candidates. The existing raid scenario exercises the ability, but does not distinguish a tank at 8,000/10,000 HP from one at 6,000/6,000 HP. Establish eligible threat ranks and absolute-versus-percentage health from a period log or controlled reference encounter before changing selection. See `scripts/naxxramas.d` and `world/realscripts_raids.d`. [Blizzard’s Naxxramas findings](https://us.forums.blizzard.com/en/wow/t/175887)

## Reproduce

With the repository harness database and extracted client data configured, run from the project root:

```sh
tools/harness/check.sh --quick
tools/harness/trainer-spells.sh --gameplay
```

The first command builds the release binaries and runs the ordinary unit suite. The second links the opt-in comparison against those objects and runs with the harness database and synthetic player state. Search its output for `gameplay-audit`. It returns a failing exit status while any comparison differs. The controls distinguish a genuine rule difference from failure to equip weapons, fill debuff slots, deliver mail or establish a local lockout. No live character is needed.
