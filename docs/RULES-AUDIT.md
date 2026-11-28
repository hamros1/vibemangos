# Rules audit

For reproducible differences against original 1.12.1 behaviour, see the [gameplay fidelity audit](research/GAMEPLAY-FIDELITY.md).

An inventory of the game rules dmangos took from emulators (CMaNGOS-classic, vmangos, ArcEmu), made from
PROVENANCE.md and from reading the modules it names (2026-11-20). For each rule it names where the rule lives, what it
does, and the best primary source found for re-deriving it: Blizzard's data (the 1.12.1 DBC files, Classic Era's DB2
tables), Blizzard's statements, documented 1.12 research, or measured Classic Era behaviour. Rules with no source
found stay as they are, documented here. It lists facts only, no fixes. docs/FORMULAS.md records what has been
re-derived so far.

**Scope.** Items were split into:

- **plumbing:** loading the CMaNGOS-schema database, packet layouts and opcodes, networking, persistence, object
  bookkeeping, GM commands. Kept on purpose, and only counted (see [Plumbing](#plumbing)).
- **game rules:** formulas, chances, timers, thresholds and decisions the server makes. 436 are listed below, plus
  about 1,650 hard-coded timers and chances in the encounter and zone scripts, which are counted per module only.
- **class pass:** class-specific spell and talent code, being redone separately. Counted only.

**Sources, as written in the lists.**

- *DB2 `Table.Column`*: Classic Era's client data, build 1.15.9.70576, published at
  `https://wago.tools/db2/<Table>/csv?build=1.15.9.70576`. Every table named here was checked to exist by fetching its
  CSV header (2026-11-20). Classic Era was built from the 1.12 data, but some values were changed after 1.12, so
  compare against 1.12 data where both exist.
- *`File.dbc`*: the 1.12.1 client's DBC, in `dmangos-server/data/dbc`.
- *Wowpedia "Page"*: warcraft.wiki.gg. "(checked)" means the page was read and the formula it gives was compared.
  "(page exists)" means only the page's existence was confirmed. "(verify)" means the page title is expected but
  was not fetched, because the wiki rate-limited the checks. Many Wowpedia pages describe retail: "Attack table" and
  "Rage" no longer give the 1.12 formulas, so check which version a page describes.
- *Magey "Page"*: `https://github.com/magey/classic-warrior/wiki/<Page>`, the community's measurements on Classic Era
  (builds 1.13.x), with the Blizzard statements they quote. Pages read: Attack-table, Threat-Mechanics. Parry-haste
  exists.
- *none found*: no primary source identified. These rules stay as they are.

The risk column: **H** means the rule acts on every player all the time or is likely wrong, **M** means it shows or
is probably approximate, **L** means it matches data, is minor, or is cosmetic.

## Summary by area

"Strong" sources are Blizzard data tables, a checked page, Magey's measurements, or a Wowpedia page confirmed to
exist. "Weak" sources are pages not yet fetched ("verify").

| area | rules | H-risk | strong source | weak source | none found | priority |
|---|---|---|---|---|---|---|
| combat | 92 | 28 | 52 | 14 | 26 | **1**: the melee table, spell hit and resistances act on every hit; Magey's measured table covers most of it |
| procs | 9 (+ 4 emulator tables) | 4 | 8 | 0 | 1 | **1**: SpellAuraOptions + SpellEffect replace spell_proc_event and spell_affect outright; PPM has no data |
| experience | 16 | 7 | 13 | 1 | 2 | **1**: every kill and quest; Wowpedia "Mob experience" (checked), QuestXP, Exhaustion |
| stats/regen | 25 | 13 | 5 | 11 | 9 | **1**: every player all the time, but weak sources (no 1.12 gt tables); needs Classic Era measurement |
| creatures/AI | 28 (+ ~1,650 script constants) | 6 | 10 | 3 | 15 | **2**: aggro, leash and evade show on every pull; few sources beyond measurement |
| honor | 16 | 6 | 7 | 6 | 3 | **2**: Wowpedia "Honor system (pre-2.0 formulas)" (checked) documents the per-kill and weekly rules |
| professions | 21 | 7 | 9 | 6 | 6 | **2**: skill-up colours in SkillLineAbility; gathering never fails here |
| reputation | 6 | 1 | 3 | 2 | 1 | **2**: the group kill split differs from both CMaNGOS and Classic Era |
| pets | 21 | 4 | 11 | 5 | 5 | **2**: happiness matches PetPersonality; loyalty and pet XP tables have weak sources |
| rules & timers | 57 | 9 | 15 | 17 | 25 | **3**: death, PvP flag and corpse timers; mostly documented on Wowpedia only |
| loot | 27 | 3 | 2 | 10 | 15 | **3**: group-loot mechanics; loot tables themselves are emulator data with no Blizzard source |
| instances/battlegrounds | 41 | 2 | 10 | 16 | 15 | **3**: but two outliers come first: the missing 5-instances-per-hour limit, and per-raid reset intervals (MapDifficulty) |
| movement/environment | 20 | 5 | 8 | 1 | 11 | **3**: fall damage, breath, speed stacking |
| economy | 32 | 2 | 13 | 12 | 7 | **3**: mostly DBC-backed already (repair, bank slots, auction cuts) |
| other | 25 | 3 | 10 | 4 | 11 | **3**: aura stacking across casters (H) belongs with combat in practice |
| **total** | **436** | **100** | **176** | **108** | **152** | |

## Blizzard tables that replace an emulator-made table

| emulator table or code | Blizzard replacement (Classic Era DB2 unless noted) | coverage |
|---|---|---|
| `spell_proc_event` (proc flags, chance, cooldown, charges) | SpellAuraOptions: ProcTypeMask_0/1, ProcChance, ProcCategoryRecovery (internal cooldown, ms), ProcCharges, CumulativeAura | Outright, except PPM: SpellProcsPerMinuteID is 0 on every row of this build, so PPM rates (e.g. Crusader, weapon procs) still need Blizzard posts or measurement. 1759 rows carry a proc mask. Example: Lightning Shield (324) has a 3 s cooldown in the emulator row and ProcCategoryRecovery 3500 ms in the DB2. The ProcTypeMask bits are the later encoding, so they need mapping to 1.12's ProcFlags |
| `spell_affect` (family masks of talents) | SpellEffect.EffectSpellClassMask_0..3, SpellClassOptions (SpellClassSet, SpellClassMask) | Outright (also the family part of `spell_proc_event`) |
| `spell_facing` | SpellCastingRequirements.FacingCasterFlags (1326 spells set) | Outright |
| `spell_chain` | SkillLineAbility.SupercedesSpell (1.12 DBC and DB2) | Outright (the 1.12 DBC already has it) |
| Quest XP from `RewMoneyMaxLevel` (quests.d:questXp) | QuestXP: XP by quest level × Difficulty_0..9 (level 60 row: 660/1650/3300/4950/6600/8300/9950) | Table outright. Each quest's difficulty index is server data the DB2 doesn't hold (Classic Era sends it in quest packets) |
| Max-level quest money | QuestMoneyReward (by level × difficulty) | As QuestXP |
| `disenchant_loot_template` | ItemDisenchantLoot: Class, Subclass, Quality, MinLevel, MaxLevel, SkillRequired → result | Which items can be disenchanted and the skill they need. The DB2 doesn't give drop chances |
| Quest reputation amounts | QuestFactionReward (by difficulty index) | As QuestXP |
| Raid reset delay (`instance_template.reset_delay`) | MapDifficulty.ResetInterval (an enum: 40-man raids 2, ZG/AQ20 3, Onyxia 4), MaxPlayers | Outright, once the enum is mapped |
| BG level brackets (template min/max, 10-level steps) | PVPDifficulty (MapID, MinLevel, MaxLevel: WSG 10–19…60, AB 20–29…60, AV 51–60); BattlemasterList (Min/MaxPlayers, Min/MaxLevel) | Outright |
| Rested XP rates (player.d:computeRest) | Exhaustion (also 1.12 DBC): Xp, Factor, InnHours, OutdoorHours, Threshold | Outright |
| Rage decay, energy regen | PowerType: RegenPeace/RegenCombat (rage −12.5/s in tenths = −1.25/s, energy and focus 10/s) | Outright (already matches) |
| Talent points per level | NumTalentsAtLevel | Outright (already matches) |
| Pet happiness thresholds and damage | PetPersonality (also 1.12 DBC) | Outright (already matches) |
| Creature level range | CreatureDifficulty.MinLevel/MaxLevel | Partial: the DB2 holds Classic Era's levels |
| `spell_template` (an emulator-edited copy of Spell.dbc) | Spell.dbc (1.12, present) and the DB2 Spell* tables | Outright for the data; the emulator's edits would need listing |

No Blizzard table was found for: player and pet base stats per level (`player_levelstats`, `player_classlevelstats`,
`pet_levelstats`), XP per level (`player_xp_for_level`), creature base stats (`creature_template_classlevelstats`;
ExpectedStat is not in Classic Era), exploration XP (`exploration_basexp`), reputation spillover and rates
(`reputation_spillover_template`, `reputation_reward_rate`), fishing zone skill (`skill_fishing_base_level`), loot tables,
graveyard links, and the agility/intellect → crit and spirit → regen tables (the gt* game tables start in 2.0 and are
not on wago.tools). These are the measured values of emulator projects, with no Blizzard source found.

## Re-derive first

1. **Done** (FORMULAS.md "The melee attack table", "Ranged attacks: no dodge"; crushing blows have no source).
   **The melee attack table**: combat.d `missChance`, `dodgeChance`, `parryChance`, `glanceChance`, `glanceAmount`,
   `critChance`, `crushChance`, `rollMeleeOutcome`, plus creature.d `fighter` (flat 5% creature crit/dodge/parry/block).
   Source: Magey "Attack-table" (measured Classic Era formulas for miss, dodge, glance chance and damage, and crit
   suppression), and the Blizzard statements it quotes (+3 creature parry 14%, crit −1% per level). Already known to
   differ: the miss rate past a 10-point skill deficit (0.6%/pt here, 0.2%/pt measured). No published source for
   crushing blows.
2. **Done** as far as the data goes (FORMULAS.md "Procs": the cooldowns are Blizzard's, the flags 1.12's; hit
   kinds, school and family masks and PPM have no Blizzard data; `spell_affect` stays, Classic Era's masks being
   renumbered). **Procs**: spells.d `spell_proc_event`, `spell_affect`; procs.d `procEventMatches`, `ppmChance`, `runProcs`;
   combathandlers.d `castItemCombatSpells`. Source: SpellAuraOptions (ProcTypeMask, ProcChance, ProcCategoryRecovery,
   ProcCharges) and SpellEffect.EffectSpellClassMask. PPM rates have no DB2 data. Also note that PPM procs here use the
   hasted attack time while item procs use the base time.
3. **Done** (FORMULAS.md "Experience": elites ×2, ×2.5 in five-player instances; the raid rate has no source).
   **Kill XP multipliers**: experience.d `killGain` gives elites ×2.5 everywhere but raids; `groupRate` gives raids
   1 − 0.05n. Source: Wowpedia "Mob experience" (checked): elites give double XP (2.5× is cited only for soloed
   dungeon elites, unverified), party factors 1/1/1.166/1.3/1.4, raids lose XP with no formula given.
4. **Done** (FORMULAS.md "Quest experience": 1.12's money / 0.6 per quest, which Classic Era's QuestXP re-rounds;
   the falloff to fives; quests of no level). **Quest XP**: quests.d `questXp` derives XP from RewMoneyMaxLevel. Source: DB2 QuestXP. Level −1 (player-level)
   quests give 0 XP here, and Blizzard's values are rounded.
5. **Done** (FORMULAS.md "Spell resistance": Blizzard's 2006 resistance page; the level miss table stays documented
   research). **Spell hit and resistance**: spellcast.d `spellMissChance`, combat.d `partialResistRows`, `effectiveResistPercent`,
   `fullResistChance`. Source: Wowpedia "Spell hit" and "Resistance" (verify which version they describe). The
   101×5 partial-resist table is an emulator fit; the binary-DoT "1/10 resist per tick" rule looks emulator-only.
6. **Done** as far as the sources go (FORMULAS.md "Health and mana from spirit", "Spell crit from intellect", "Attack power, crit and dodge from agility": health regen was doubled, the mage's spell crit the paladin's; below level 60 no source). **Base stats → derived stats**: stats.d `agilityPerPercent` (a linear lvl 1→60 fit per class),
   spellhandlers.d `spellCrit` (an INT fit), player.d `healthRegenPerSecond`, `spiritManaPerSecond`.
   No 1.12 data exists. Source: Classic Era's character sheet (measured), and Wowpedia "Spirit" (page exists) for the
   per-class 1.12 regen table.
7. **Done** (FORMULAS.md "Honor", with the battleground units and the 1.12 standing). **Honor per kill**: honor.d `honorableKillPoints`, `greyForHonor`, `dishonorableKillPoints`. Source: Wowpedia
   "Honor system (pre-2.0 formulas)" (checked). It gives contribution points as a table by the victim's rank
   (198 at rank 1 … 398 at rank 14) and diminishing returns of 10 kills per victim per 24 hours, 10% less each. That
   page links Blizzard's "Official Honor Guide". The level-based emulator formula here is a reconstruction, and its
   grey table differs from the XP grey level (≤47 vs ≤51 at 60). The weekly side (20% decay, the brackets) already
   matches.
8. **Profession skill-ups and gathering** (**done** except the gathering failure rate: FORMULAS.md "Crafting
   skill-ups", "Skinning", "Fishing"): enchanting.d `craftSkillChance` (the green midpoint is assumed),
   gameobjecthandlers.d `updateGatherSkill`, `checkGameObjectTarget` (gathering never fails), spellhandlers.d
   `checkSkinning` (two formulas that disagree), `useBobber`. Source: SkillLineAbility TrivialSkillLineRankHigh/Low
   (1.12 DBC and DB2), Lock.dbc Skill; measured Classic Era for the failure chance.
9. **Creature evade and aggro** (**done** but call for help, no source: FORMULAS.md "Aggro radius", "Leash",
   "Evade"): creatureai.d `enterEvadeMode` (no full heal on evade; health comes back at 1/3 per
   5 s), `attackDistance` (no 45 yd cap), `callAssistance`, `updateCombatManager` (leash). Source: measured
   Classic Era (mobs are widely reported to reset to full health on evade; verify), Wowpedia "Aggro radius" (page exists); Magey "Threat-Mechanics"
   confirms the 110%/130% and 0.5-per-heal rules already used.
10. **Instance limits and resets** (**done**: FORMULAS.md "Instances per hour", "Raid resets"): the missing 5-instances-per-hour limit (only the transfer-abort code exists), and
    context.d `nextRaidReset` taking each raid's delay from emulator data. Source: MapDifficulty.ResetInterval (DB2),
    and Blizzard's 1.x patch notes for the hourly instance limit (verify).

Also likely wrong, found on the way: loothandlers.d `rewardAtKill` splits kill reputation 1/n in a
group in the open world (**done**: all to each, FORMULAS.md "Reputation"; CMaNGOS also splits 1/n); battleground.d
`bonusHonor` uses level 60 for every bracket (**done**: by bracket, FORMULAS.md "Honor"); taxihandlers.d compared the
start distance with `(2·5)^3` (**fixed**: the flight master within 10 yd of its node, squared; every flight master in
the data stands within 7.1 yd); no fix made for the rest: spellcast.d `powerCost` applies
`manaCostPerLevel × (level/5 − baseLevel)`. **Done:** there were no
diminishing returns on crowd control (now the 1.x patch notes', FORMULAS.md "Diminishing returns"); auto-shot could
be dodged while ranged abilities couldn't (now neither, by the 1.12 Dodge tooltip: "enemy melee attacks").

## Encounter and zone scripts

Counted only: hard-coded timers (`N.msecs/seconds`, `between(...)`) plus chances and health thresholds per module,
counted by pattern (about ±30%). They come from ScriptDev2/CMaNGOS script ports. Their primary source is measured
Classic Era behaviour (combat logs, boss-timer addons); none was checked here.

| module | constants | module | constants |
|---|---|---|---|
| scripts/naxxramas.d | ~187 | scripts/darkshore.d | ~24 |
| scripts/templeofahnqiraj.d | ~165 | scripts/azshara.d, barrens.d, zulfarrak.d | ~21 each |
| scripts/moltencore.d | ~111 | scripts/ashenvale.d, feralas.d | ~20 each |
| scripts/ruinsofahnqiraj.d | ~106 | scripts/felwood.d, silithus.d | ~18 each |
| scripts/blackwinglair.d | ~96 | scripts/stormwind.d | ~17 |
| scripts/blackrockdepths.d | ~86 | scripts/burningsteppes.d, desolace.d, shadowfang.d, winterspring.d, worldobjects.d | ~14 each |
| scripts/gnomeregan.d, stratholme.d | ~56 each | scripts/blastedlands.d | ~13 |
| scripts/blackrockspire.d | ~47 | scripts/uldaman.d | ~12 |
| scripts/scarletmonastery.d, zulgurub.d | ~40 each | scripts/easternplaguelands.d | ~11 |
| scripts/onyxia.d, westernplaguelands.d | ~36 each | scripts/diremaul.d, sunkentemple.d, tanaris.d, wailingcaverns.d | ~10 each |
| scripts/moonglade.d | ~35 | scripts/razorfendowns.d | ~9 |
| scripts/itemeffects.d | ~29 | scripts/hinterlands.d | ~8 |
| scripts/npcs.d, scholomance.d | ~27 each | scripts/arathi.d, maraudon.d, westfall.d, worldmaps.d | ~7 each |
| scripts/ungoro.d | ~26 | scripts/deadmines.d, durotar.d, dustwallow.d, script/schedule.d | ~5 each |
| scripts/emeralddragons.d | ~25 | the rest of scripts/ and script/ | 0–3 each |

## Class pass

Class-specific code, being redone separately, so not listed: classspells.d (all of it), combat.d 1, unit.d 2,
procs.d 4, auras.d 2, aurahandlers.d 6, effecthandlers.d 1, spellhandlers.d 5, death.d 2, player.d 1,
playercreate.d 1, petai.d/pethandlers.d 2.

## Plumbing

Kept on purpose (the CMaNGOS database schema, packets checked against emulators, networking, persistence). Counts are
approximate.

- **Reviewed modules:** combat.d 7, combathandlers.d 9, spellcast.d 13, unit.d ~30, stats.d 3, procs.d 3,
  spellmods.d 1, crowdcontrol.d 3, auras.d 7, aurahandlers.d 11, aurastate.d 2, spells.d 9; effecthandlers.d 9,
  spellhandlers.d 45, itemuse.d 8, durability.d 5, death.d 12, environment.d 10, duelhandlers.d 8, pvp.d 6,
  mounting.d 3, moveorders.d 12, corpse.d 5; creatureai.d 26, creature.d 30, creatureevents.d 14,
  creaturecasting.d 38, eventai.d 25, creaturelinking.d 8, petai.d 8, pet.d 20, pethandlers.d 45, guardians.d 8,
  map.d 40, grid.d 3; exploration.d 7, player.d ~28, inworld.d ~20, playercreate.d ~15, questhandlers.d ~25,
  quests.d 6, reputationhandlers.d 8, reputation.d 5, relations.d 3, talenthandlers.d 6, npchandlers.d ~15,
  homebind.d 2, weather.d 3, worlddata.d ~25, conditions.d 1 (an evaluator for ~35 condition types); loot.d ~20,
  loothandlers.d ~16, gameobjecthandlers.d ~20, professions.d 3, enchanting.d 6, enchantments.d 4, inventory.d ~60,
  itemhandlers.d ~20, tradehandlers.d ~12, auctionhouse.d ~6, auctionhandlers.d ~8, mailhandlers.d ~10, money.d 2,
  rituals.d 4, group.d 4 (loot part), taxi.d ~8, taxihandlers.d ~8; honor.d ~12, honorweek.d ~3,
  battleground.d ~45, bgqueue.d ~20, alterac.d ~8, warsong.d ~8, arathi.d ~6, meetingstone.d ~5, wareffort.d ~12,
  teleport.d ~20, gameevents.d ~4, gminstance.d ~8, cluster/protocol.d ~50.
- **Plumbing only** (PROVENANCE entries): auth/ 10, crypto/srp6.d 2, dbc.d 2, mapfile.d 7, navigation.d 3,
  extractor/ 34, vmap/ 77; world/: addons 2, channel 29, channelhandlers 2, character 16, characterdb 27,
  characters 2, clientdata 18, commands 25, commandtable 2, config 2, database 33, dbscripts 13, defines 12,
  dynobject 3, gameobject 10, gm* 52, grouphandlers 5, groupservice 8, guild 7, guildhandlers 18, main 1,
  motion 14, movement 5, names 3, npcdata 4, objects 19, online 6, opcodes 8, packets 107, queries 11, realm 3,
  realspellsweep 3, session 9, social 8, spellscripting 5, spline 15, terrain 30, updatefields 9, whisper 1.
  Exceptions with rules, listed above: context.d (raid and dungeon resets, mail expiry, auction mail) and
  charscreen.d (offline rest).

## Rules by area

Columns: where it lives, what it does, the emulator function it reproduces, the best primary source found, and the
risk.

### Combat (92)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| combat.d:missChance | 5% base, +19% dual wield; ±0.04%/skill pt; vs NPC def>skill: ≤10 pts 0.1/pt, >10: +1 then 0.6/pt (0.2+0.4); minus hit | CalculateEffectiveMissChance | Magey "Attack-table" (measured Classic Era: 0.1%/pt, 0.2%/pt past 10, DW +19% flat) | H: every swing. **Done:** 8% at +3, hit suppression, low-level creatures (FORMULAS.md "The melee attack table") |
| combat.d:dodgeChance | Victim dodge + diff×0.04 (NPC def>skill: 0.1) | CalculateEffectiveDodgeChance | Magey "Attack-table": 5% + (5×TL − skill)×0.1% | H: every swing. **Done:** 0.1%/pt both ways for creatures |
| combat.d:parryChance | Parry + diff×0.04; NPC diff>0: 0.1, >10: 0.6; never vs ranged | CalculateEffectiveParryChance | Blizzard statement quoted on Magey "Attack-table": +3 creatures parry 14%; measured 13.5–14% | H. **Done:** by the capped skill (14% at +3 whatever the weapon skill) |
| combat.d:crushChance | Creature vs player-controlled: skill − min(def, 5×lvl) ≥ 15 → 2×deficit − 15 % | CalculateEffectiveCrushChance | none found published for 1.12 (Magey wiki lacks it); measured Classic Era logs | H: constant for tanks. **Done:** no source found (FORMULAS.md), unchanged |
| combat.d:glanceChance | Player vs creature lvl>10: 10 + 2×(def − capped skill)%; wand classes min(lvl,30) + 2×diff | CalculateEffectiveGlanceChance | Magey "Attack-table": 10% + (5×TL − min(5×AL, skill))×2% (10/20/30/40%) | H: 40% vs boss. **Done:** already matched; casters' no source |
| combat.d:glanceAmount | High 1.2−0.03d (casters 0.9), low 1.3−0.05d (casters 0.6); clamps 0.2–0.99 / 0.01–0.91 | glance damage reduction | Magey "Attack-table" (same formula, measured) | H: every glance. **Done:** already matched |
| combat.d:critChance | Crit + diff×0.2 vs NPC (weapon − def) or 0.04 vs player; + attackerCrit | CalculateEffectiveCritChance | Magey "Attack-table" (0.2%/pt below, 0.04%/pt above; Blizzard: −1% per level); aura-crit suppression ~1.8% unconfirmed | H. **Done:** capped skill, 0.04%/pt above, 1.8% of aura crit at +3 |
| combat.d:rollMeleeOutcome | One roll, order miss→dodge→parry→block→glance→crit→crush; sitting player always crit | RollMeleeOutcomeAgainst | Magey "Attack-table" (single-roll table, measured) | H: core table. **Done:** ranged never dodged (1.12 tooltips) |
| combat.d:armorReducedDamage | DR = A/(A+400+85×attackerLevel), cap 75% | CalcArmorReducedDamage | Wowpedia "Armor" (pre-2.x formula; verify version) | H: every physical hit. **Checked 2026-11-28 against CMaNGOS:** the same (its 0.1A/(8.5L+40) over one plus itself is A/(A+85L+400), capped 75%) |
| combat.d:calculateMeleeDamage | Crit ×2, crushing ×1.5, block subtracts block value; flat/pct taken | CalculateMeleeDamage | Wowpedia "Critical strike", "Crushing blow" (verify) | HH. **Checked 2026-11-28 against CMaNGOS** (`CalculateMeleeDamage`, `GetCritMultiplier`): the same (armor before the roll; crit ×2 by the Slaying talents' `MOD_CRIT_PERCENT_VERSUS`, `MOD_CRIT_DAMAGE_BONUS` on no 1.12 spell; crushing ×1.5; block value off, a full block shown as blocked). One difference, kept: CMaNGOS rolls the victim's dodge against ranged attacks and shows it as a miss; here ranged attacks are not dodged at all, as the 1.12 Dodge tooltip has it ("enemy melee attacks") - for the owner to decide |
| combat.d:rageReward | c = 0.0091107836L² + 3.225598133L + 4.2652911; rage = dmg/c × 7.5 dealt, × 2.5 taken | Player::RewardRage | current Wowpedia "Rage" lacks the pre-2.4 formula (checked); Blizzard 1.x posts on rage conversion (none found online) | H: every warrior swing |
| combat.d:partialResistRows | 101×5 table of 0/25/50/75/100% resist chances by resist% | SPELL_PARTIAL_RESIST_DISTRIBUTION | Wowpedia "Resistance" (verify; classic binomial distribution) | H: every magic hit; emulator-fitted table. **Done:** Blizzard's five published rows match exactly (worldofwarcraft.com "Resistances", 2006; tested); the rows between stay the fit |
| combat.d:effectiveResistPercent | R/max(5×attLvl,100)×0.75, +0.4/pt level-skill for creatures, cap 75 | CalculateEffectiveMagicResistancePercent | Wowpedia "Resistance" (verify) | H. **Done:** Blizzard's page confirms the average and 75% cap; the level bonus stays documented research |
| combat.d:fullResistChance / rollPartialResist | Binary: whole resist = percent; partial interpolated; binary DoT ticks at 1/10 resist; negative resist adds damage | RollMagicResistanceMultiplierOutcomeAgainst | Wowpedia "Resistance" (verify) | H: binary-tick 1/10 rule looks emulator-only. **Done:** binary ticks never resisted in part; no bump above 54% (Blizzard: 1% land whole) |
| spellcast.d:spellMissChance | 4% + (vL−cL) up to +2; beyond +2: 11%/level (NPC) or 7%/level (player); min 1% | MagicSpellHitResult | Wowpedia "Spell hit" (verify; 96/95/94/83% table is widely cited) | H: every spell. **Done:** Blizzard gives only the 1% minimum; the table stays documented research (FORMULAS.md) |
| spellcast.d:magicMissChance | Miss − hit + mechanic resist + full-resist chance | MagicSpellHitResult | Wowpedia "Spell hit" (verify) | HH. **Checked 2026-11-28 against CMaNGOS** (`CalculateSpellMissChance`, `CalculateSpellResistChance`): the same (4% + level difference, 11%/7% a level beyond two; mechanic resistance and the full resist by resistance on the same roll; `MOD_DEBUFF_RESISTANCE` on no 1.12 spell). Fixed: the 1% floor comes after the caster's hit (before, +5% hit at the same level made spells never miss) |
| spellcast.d:rollSpellHit | Evade/immune; melee/ranged abilities miss→dodge/parry (ranged never dodged); block only if fully blocked; magic miss/resist | MeleeSpellHitResult, CanBlockAbility | SpellCategories.DefenseType; SpellMisc Attributes | H: inconsistent with auto-shot. **Done:** consistent: no ranged dodge either way |
| effecthandlers.d:feignDeathAura | FD resist = level-based spell-miss chance vs highest attacker | HandleFeignDeath | none found | H: emulator guess. **Checked 2026-11-28 against CMaNGOS:** the same (the greatest `CalculateSpellMissChance` of the hunter against each attacker not player-controlled, one roll); no period source found |
| spellhandlers.d:damagedWhileCasting (cast) | Pushback 1000/800/600/400/200 ms then 200; DoTs don't push | InterruptOrDelaySpell, Spell::Delayed | Wowpedia "Pushback" (verify) | H: constant in combat. **Checked 2026-11-27, kept:** no source gives 1.12's numbers; the two hits of 0.5 s (and a channel's 25%) some wikis give are the Wrath beta's change (Engadget, 2008-08-11); players recall vanilla's pushback as diminishing, so a cast still finished (Blizzard forums, "Spell Pushback is Broken"), as this series does |
| spellhandlers.d:damagedWhileCasting (channel) | Channel shortened by same series; counter not reset at channel start | Spell::DelayedChannel | Wowpedia "Pushback" (verify; classic channel loses 25%?) | H. **Checked 2026-11-27, kept:** the 25% a hit is the Wrath beta's (Engadget, 2008-08-11), not 1.12's |
| spellhandlers.d:checkTarget (range/LoS) | Range = max + both reaches; melee max(5, reaches + 4/3) | Spell::CheckRange | SpellRange.dbc | H: every cast |
| spellhandlers.d:critDamage / heal | Abilities crit ×2, spells and heals ×1.5 | SpellCriticalDamageBonus | Wowpedia "Critical strike" (verify) | H. **Checked 2026-11-28 against CMaNGOS** (`GetCritMultiplier`): 2 for melee and ranged damage classes, 1.5 for magic and none, times `MOD_CRIT_PERCENT_VERSUS` (the Slaying talents: it was a crit chance here, made a damage bonus in 430ca1f), the spell modifiers on the bonus part |
| spellhandlers.d:spellDamage / spellDamageBonus | SP × coefficient; school %, versus, taken; armor; partial resist; absorb | SpellDamageBonusDone | SpellEffect.EffectBonusCoefficient | H |
| spellhandlers.d:heal | Healing power × coefficient × % done, crit ×1.5, heal threat | SpellHealingBonusDone | SpellEffect.EffectBonusCoefficient | H |
| creatureai.d:selectNextVictim | Highest threat, current kept unless exceeded by 110% (melee) / 130% (range); taunt forces | ThreatContainer::selectNextVictim | Magey "Threat-Mechanics" (measured Classic Era: 110%/130%) | H: constant |
| creatureai.d:damageTaken / addThreat | Threat = damage × MOD_THREAT; first contact 0 threat | ThreatManager::addThreat | Magey "Threat-Mechanics" | HH. **Checked 2026-11-28 against CMaNGOS** (`HandleDamageDealt`, `ThreatCalcHelper`): the same (damage dealt × spell_threat multiplier × `SPELLMOD_THREAT` × `MOD_THREAT` by school, `MOD_CRITICAL_THREAT` on crits). Fixed: a spell with `SPELL_ATTR_EX_NO_THREAT` (13 that deal damage: Twin Empathy, Elune's Candle, Blood Siphon) gives its damage no threat |
| creatureai.d:assistThreat | Healing: 0.5 × heal split evenly among creatures fighting the target | HostileRefManager::threatAssist | Magey "Threat-Mechanics" (0.5 per point healed) | H: every healer. **Checked 2026-11-28 against CMaNGOS:** the same (half, split among those fighting the healed that are not crowd-controlled and may attack the healer); not done: `SPELL_ATTR_EX4_NO_HELPFUL_THREAT` |
| creature.d:fighter | Creature crit/dodge/parry/block flat 5% regardless of level diff | creature defaults | Magey "Attack-table" (dodge/parry vs mobs scale with level/skill) | H: ignores level for crit/block. **Done:** the 5% bases agree with Blizzard; the level scaling is in combat.d |
| combat.d:levelFor | World boss (rank 3) counts as target level +3 (cap 255) | CONFIG_UINT32_WORLD_BOSS_LEVEL_DIFF | Wowpedia "Boss" (verify); Magey "Attack-table" treats bosses as level 63 | M: sets every boss roll |
| combat.d:weaponSkillValue / defenseSkillValue / skillMaxForLevel | Creature skill = 5×level; vs a player a player uses max(skill, maxSkill) | GetWeaponSkillValue, GetDefenseSkillValue | Magey "Attack-table" (measured Classic Era) | M: constant in PvP |
| combat.d:meleeReach / canReachWithMelee | Reach = both combat reaches + 1.33, min 5 yd; +8/3 yd if both moving; players 3D, creatures 2D | ATTACK_DISTANCE, BASE_MELEERANGE_OFFSET, MELEE_LEEWAY | CreatureModelData.CombatReach (DB2); none found for offset/leeway | M: every swing |
| combat.d:hasInArc (+ combathandlers swing check) | Swing needs target in 120° front arc; "front" for dodge/parry/block = 180° | WorldObject::HasInArc | none found | M |
| combat.d:blockChance | Block + diff×0.04; NPC with diff>0: factor 0 | CalculateEffectiveBlockChance | Magey "Attack-table" (verify) | M. **Done:** a creature's at most 5%, 0.1%/pt less for skill above |
| combat.d:canDodge / canParry / canBlock | Player dodges only from the front, creature from anywhere; parry front only; block physical + front + shield; auto-shot can be dodged (no attack-type check) | CanDodge, CanParry, CanBlock | none found (Wowpedia "Attack table" is retail) | M: decides behind-attacks. **Done:** no dodge or parry of ranged attacks (1.12 tooltips) |
| combat.d:parryHasted | Parry haste: timer >60% → −40% of speed; 20–60% → set to 20% | DealMeleeDamage | Magey "Parry-haste" (measured Classic Era) | M |
| combat.d:damageFactor / DamageMods.of | Done%, versus-type% and taken% multiply | TOTAL_PCT mods | none found for stacking rule | M |
| combathandlers.d:takeBlow | Non-periodic hit stands sitter up; warrior rage from damage taken | Unit::DealDamage | none found | M |
| combathandlers.d:attack / attackPlayer | No melee mounted; off hand starts half a swing late; damage interrupts auras | Unit::Attack | none found | M |
| spellcast.d:powerCost | manaCost + manaCostPerLevel×(level/5 − baseLevel); % of base mana | Spell::CalculatePowerCost | Spell.dbc / SpellPower (ManaCostPerLevel) | M: per-level term looks wrong |
| spellcast.d:isBinarySpell | Binary = non-damage, all auras, all DoT, or non-damage effect sharing targets of direct damage | IsBinarySpell (pre-WotLK) | Wowpedia "Resistance" (binary spells) (verify) | M. **Done:** Blizzard's rule: direct damage in part unless a debuff rides on it (Earth Shock in part) |
| spellcast.d:heartbeatResistChance | HEARTBEAT_RESIST auras break with the miss/resist chance at each heartbeat | heartbeat resist | none found | M |
| spellmods.d:applySpellMod / affects | Same family + mask; (value+flat)×(100+Σpct)/100 (percents add) | ApplySpellMod, isAffectedOnSpell | SpellEffect.EffectSpellClassMask | M: every talent |
| auras.d:setHeartbeatResist | Chance×(1+DR), interval duration/(2+DR); no diminishing returns at all (DR always 0) | SetHeartbeatResist | Blizzard 1.x patch notes on diminishing returns (verify) | M: no DR exists. **Done:** patch 1.4.0–1.11.0 categories (FORMULAS.md "Diminishing returns", diminishing.d); the heartbeat's DR factor stays 0 |
| auras.d:attackTimeFactor / castTimeFactor | Haste → 100/(100+a); slow (100−a)/100; slow on main hand only | ApplyAttackTimePercentMod | none found | M |
| aurahandlers.d:applyAuraEffect | DoT/HoT get power × coefficient per tick; buff on someone in combat adds 0-threat assist | EffectApplyAura | SpellEffect.EffectBonusCoefficient | M |
| aurahandlers.d:absorbIncoming | Absorb up to remaining; mana shield costs multipleValue mana/pt | CalculateDamageAbsorbAndResist | Spell.dbc EffectMultipleValue | M |
| aurahandlers.d:damageShields | Thorns-type flat damage to every melee attacker, no roll | DamageShield handling | none found | M |
| aurahandlers.d:auraEffects (interrupts) | Food/drink sit; immunities purge mechanics; stun/fear/confuse interrupt cast | RemoveAurasAtMechanicImmunity | SpellCategories.Mechanic/PreventionType | M |
| aurahandlers.d:selfTick | Creature physical DoT armor-reduced at caster level; leech × multipleValue; HoT threat | Aura::PeriodicTick | Spell.dbc | M |
| aurahandlers.d:auraTick | Player DoT on creature: physical → armor; partial resist (binary 1/10); no DoT crits | Aura::PeriodicTick | Wowpedia "Resistance" (verify) | M |
| spellhandlers.d:takeAmmo | One ammo per shot; thrown weapons lose durability or stack | Spell::TakeAmmo | none found | M |
| mounting.d (MountRules) | No melee mounted | Unit::CanAttackNow | none found | M |
| effecthandlers.d:chargeEffect | Charge at spell speed else 27 yd/s; stop at reach | EffectCharge, BASE_CHARGE_SPEED | Spell.dbc Speed | M |
| effecthandlers.d:leechTick / manaLeechTick | Leech heal = min(dmg,HP)×mult, no SP; mana leech threat 0.5×gain | PeriodicTick LEECH | Spell.dbc EffectMultipleValue | M |
| effecthandlers.d:addExtraAttacksEffect | At most 5 owed extra swings; extra swings grant none | EffectAddExtraAttacks | none found | M |
| effecthandlers.d:summonTrapEffect / updateTraps | One trap per slot; fires on first enemy; re-arm 4 s | GameObject::Update (traps) | none found | M |
| spellhandlers.d:lockOutSchool | Interrupt locks school only for PreventionType=silence spells | IsSpellReady | SpellCategories.PreventionType | M |
| spellhandlers.d:checkCast / crowdControlRefusal | Refusals when dead, stunned, silenced, fleeing, sitting, wrong equipment | CheckCast, CheckCasterAuras | SpellMisc Attributes, SpellCategories | M |
| spellhandlers.d:checkCastAttributes | Stance masks, outdoors via vmaps, stealth-only, behind/front from attribute heuristics, spell_facing | CheckCast | SpellCastingRequirements.FacingCasterFlags (DB2), SpellShapeshift | M: heuristics replaceable by data |
| spellhandlers.d:go (discountPowerOnMiss) | Miss/dodge/parry refunds 80% | Spell::finish | SpellMisc Attributes; Wowpedia (verify 1.12: 80% refund) | M |
| spellhandlers.d:updateAutoRepeat | First shot after 500 ms; interval = ranged time + recovery; moving resets | Spell::update (autorepeat) | none found | M |
| spellhandlers.d:critChanceOf / spellCritOf | Weapon abilities melee crit; spells spellCrit + mods | RollSpellCritOutcome | none found | M |
| spellhandlers.d:weaponSpellDamage | First weapon effect deals; fixed × pct; block 0 | EffectWeaponDmg | none found | M |
| spellhandlers.d:dispelEffect | Random auras of dispel type | EffectDispel | SpellCategories.DispelType | M |
| spellhandlers.d:areaTargets | 3D radius; cone ±60°; party spells subgroup | SetTargetMap | SpellTargetRestrictions.ConeDegrees (DB2) | M: cone hard-coded |
| spellhandlers.d:chainTargets | Chain jumps within 10 yd; chain heal lowest HP% | SetTargetMap | SpellEffect.EffectChainTargets (count only) | M |
| spellhandlers.d:addComboPoints | Max 5, reset on new target, spent unless missed | AddComboPoints | none found | M |
| spellhandlers.d:spendChargedMods | Charged mods lose a charge per cast | RemoveSpellMods | SpellAuraOptions.ProcCharges | M |
| creatureai.d:taunt | Taunt sets threat to top and forces target while aura lasts | EffectTaunt | Wowpedia "Taunt" (verify) | M |
| creatureai.d:forget | Feign Death/Vanish/Divine Intervention drop from threat list | Unit::CombatStop | none found | M |
| creatureai.d:meleeAttackIfReady | Creature swings only in reach and 120° front arc; retry 100 ms | UpdateMeleeAttackingState | none found | M |
| creatureai.d:parried | Parry haste unless NO_PARRY_HASTEN flag | CREATURE_EXTRA_FLAG_NO_PARRY_HASTEN | Magey "Parry-haste" | M |
| creature.d:refreshAuraMovement | Speed × strongest increase × strongest decrease | speed mods | SpellEffect values | M |
| creaturecasting.d:castSpell | No casting while evading/CC; school lockout; OOM in ranged mode → melee | Spell::prepare | SpellCategories.PreventionType | M |
| creaturecasting.d:inRangeFor | Creature spell range = max + reach + 1.5 yd | Spell::CheckRange | SpellRange | M |
| creaturecasting.d:go / spellDamageTo | Creature spells roll like player spells; physical armor-reduced | Spell::cast | SpellEffect | M |
| pethandlers.d:updateTotems | Totem 2 yd from owner by slot angle; casts at nearest enemy | EffectSummonTotem, TotemAI | SpellRange | M |
| player.d:fighter / statsInput | Broken items give no stats; empty main hand = Unarmed | _ApplyItemMods | none found | M |
| combat.d:weaponDamage | Uniform int min..max; no max → 5 | CalculateDamage | none found | L |
| combathandlers.d:updateMeleeAttackingState | MH/OH swings ≥ 200 ms apart; retry 100 ms; extra attacks all at once | ATTACK_DISPLAY_DELAY, DoExtraAttacks | none found | L |
| spellcast.d:usesWeaponSkill | Non-weapon abilities roll at 5×level skill | IsSpellUseWeaponSkill | none found | L |
| spellcast.d:bonusCoefficient (fallback) | Without DB2 coefficient: cast time/3.5, DoT dur/15, <lvl 20 penalty | not emulator (docs/FORMULAS.md) | SpellEffect.EffectBonusCoefficient (already used) | L: fallback only |
| aurastate.d:healthless20Percent | <20% health aura state | ModifyAuraState | Spell.dbc CasterAuraState/TargetAuraState | L |
| effecthandlers.d:splitDamage / powerBurn / powerDrain / healthLeech / healMaxHealth | Effect arithmetic: multipliers from data; no spell power | EffectPowerBurn etc. | Spell.dbc EffectMultipleValue | L |
| effecthandlers.d:dispelMechanicEffect | Remove up to value random auras of mechanic | EffectDispelMechanic | SpellCategories.Mechanic | L |
| spellhandlers.d:spellsOnMovement | Movement interrupts per SpellInterrupts flags | SPELL_INTERRUPT_FLAG_MOVEMENT | SpellInterrupts (DB2) | L: matches data |
| spellhandlers.d:makePersistentArea | Default amplitude 1 s | EffectPersistentAA | Spell.dbc EffectAmplitude | L |
| spellhandlers.d:castSpell / go (interrupts) | Aura interrupt flags at cast start/end | Spell::Prepare | SpellInterrupts.AuraInterruptFlags | L |
| spellhandlers.d:rollHit | Friendly targets never missed | SpellHitResult | none found | L |
| creatureai.d:modifyThreatPercent | Threat × (100+pct)/100 | modifyThreatPercent | SpellEffect values | L |
| creaturecasting.d:scriptThreatPercent | EventAI threat ±pct | ACTION_T_THREAT_*_PCT | none found | L |
| relations.d:factionReaction / canAttack | Reactions from FactionTemplate, war state, duel, FFA, forced reactions | GetReactionTo, CanAttack | FactionTemplate/Faction (DBC) | L: mirrors client |

### Procs (9)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| combathandlers.d:castItemCombatSpells | Chance-on-hit: PPM → base speed×ppm/600, else ProcChance; enchant: spell_proc_item_enchant PPM, else amount%, else speed×1.8/1000 (OH 1.6) | CastItemCombatSpell, GetWeaponProcChance | SpellAuraOptions.ProcChance, SpellItemEnchantment (DB2); PPM: none in DB2 (SpellProcsPerMinuteID all 0) | H: every weapon proc |
| procs.d:procEventMatches | Kill always procs; ticks proc only for periodic/harmful auras; school/family filter; default procEx hit/crit | IsSpellProcEventCanTriggeredBy | SpellAuraOptions.ProcTypeMask (1759 rows with a mask) | H: all procs. **Done:** the flags are 1.12's Spell.dbc's, which Classic Era's mask confirms (bits 0–20, FORMULAS.md "Procs"); hit kinds have no Blizzard data |
| procs.d:ppmChance / runProcs | PPM chance = hasted attackTime×ppm/600; else row CustomChance or ProcChance; cooldown from row; one charge per proc | GetPPMProcChance, ProcDamageAndSpell | SpellAuraOptions ProcChance / ProcCategoryRecovery / ProcCharges; PPM: Blizzard posts per item (none in DB2) | H: PPM uses hasted speed (item procs use base speed). **Done:** cooldown from ProcCategoryRecovery (`procRule`); PPM and the hasted speed unchanged (no data) |
| spells.d:spell_proc_event | Per-spell override of proc flags/procEx/school/family mask/PPM/chance/cooldown | LoadSpellProcEvents | SpellAuraOptions (ProcTypeMask, ProcChance, ProcCategoryRecovery, ProcCharges) + SpellEffect.EffectSpellClassMask; PPM: none in DB2 | H: emulator-authored; e.g. Lightning Shield 324 cooldown 3 s here, ProcCategoryRecovery 3500 ms in DB2. **Done:** its cooldowns replaced where Classic Era has the aura as 1.12 (100 auras); procEx, school, family masks, PPM stay (no Blizzard data) |
| procs.d:spellProcFlags | Spell → proc flag by dmgClass, auto-repeat, ability, positive | PrepareMasksForProcSystem | SpellAuraOptions.ProcTypeMask_0/1 | M |
| procs.d:effectProcsOn / affectMaskOf | Row family mask, else spell_affect/EffectItemType mask | IsTriggeredAtSpellProcEvent | SpellEffect.EffectSpellClassMask_0..3 | M. **Checked:** Classic Era renumbered the family flags; no source for 1.12's masks (FORMULAS.md "Procs") |
| spells.d:spell_affect | Talent → spell family mask per effect, copied to higher ranks | LoadSpellAffects | SpellEffect.EffectSpellClassMask_0..3 | M. **Checked:** translated back, 62 of 132 rows disagree both ways: not a 1.12 source; kept with tooltipmasks.d |
| effecthandlers.d:blockDamageProcs | PROC_TRIGGER_DAMAGE on swing taken procs only on block | HandleProcTriggerDamageAuraProc (spell_proc_event) | SpellAuraOptions ProcTypeMask/ProcChance | M |
| combathandlers.d:killedCreature | Kill procs only for non-grey kills | Unit::Kill (PROC_FLAG_KILL) | none found | L |

### Experience (16)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| experience.d:baseGain | Kill XP = 5×level + 45; +5%/level above, cap +4; below: × (1 − diff/ZD) | MaNGOS::XP::BaseGain | Wowpedia "Mob experience" (checked: 5×L+45, +5%/level up to +4, ZD falloff) | H: every kill; **Done** (FORMULAS.md "Experience") |
| experience.d:zeroDifference | ZD table 5/6/7/8/9/11/12/13/14/15/16/17 | XP::GetZeroDifference | Wowpedia "Mob experience" (checked: same table) | H; **Done** (FORMULAS.md "Experience") |
| experience.d:killGain | Elite ×2.5 everywhere except raid maps (×2.0) | XP::Gain | Wowpedia "Mob experience" (checked: elites double XP; 2.5× only for dungeon elites soloed, unverified) | H: open-world elites likely +25% too much; **Done** (FORMULAS.md "Experience"). **Not done, 2026-11-28:** CMaNGOS also takes off a kill's XP the share of its health dealt by those outside the tapping group (`GetModifierXpBasedOnDamageReceived`: guards, other players), its own comment calling the evidence pre-MoP; no 1.12 source found (a search of patch notes, Wowpedia), so a guard's help still costs nothing here |
| experience.d:groupRate | 1–2: 1.0, 3: 1.166, 4: 1.3, 5: 1.4; 6+: 1 − 0.05n | XP::xp_in_group_rate | Wowpedia "Mob experience" (checked: 1/1/1.166/1.3/1.4; raids lose XP, no formula) | H: raid formula looks invented; **Done: the party rates; the raid rate has no source** (FORMULAS.md "Experience") |
| loothandlers.d:rewardAtKill (group XP) | XP at highest non-gray level × rate × level/sumLevel; gray-top ×0.5+1; pet half | Group::RewardGroupAtKill | Wowpedia "Mob experience" (checked: level-ratio split) | H: every group kill; **Done** (FORMULAS.md "Experience") |
| player.d:computeRest (+ inworld.d) | Accrual: one level per 1 152 000 s (5% per 8 h) at inn | Player::ComputeRest | Exhaustion.InnHours (8) / OutdoorHours (DBC/DB2) | H: every player; **Done** (FORMULAS.md "Experience") |
| quests.d:questXp | Quest XP = RewMoneyMaxLevel/0.6 (/1.2…/6 above 60); full to qL+5, then ×.8/.6/.4/.2, ×.1 at +10; ceil; level ≤0 → 0 | Quest::XPValue | QuestXP (DB2): XP by quest level × Difficulty_0..9 (values rounded to 5/10/50); per-quest difficulty index not in DB2 (server data); Wowpedia "Experience point" (quest % falloff) | H: every quest; −1-level quests give 0, rounding differs; **Done** (FORMULAS.md "Quest experience") |
| experience.d:grayLevel | ≤5→0; ≤39: L−5−L/10; ≤59: L−1−L/5; else L−9 | XP::GetGrayLevel | Wowpedia "Mob experience" (checked: same) | M; **Done** (FORMULAS.md "Experience") |
| experience.d:isTrivialLevelDifference / questGreenRange | Second gray table by level/5 [4,4,5,5,6,6,7,7,8,9,10,11], else 12; differs at 60 (≤47 vs ≤51) | IsTrivialLevelDifference, GetQuestGreenRange | Wowpedia "Mob experience" | M: two gray definitions; **Done** (FORMULAS.md "Experience") |
| experience.d:groupXpDistance | Kill share 74 yd; whole map in dungeons (used by honor, quests, loot) | CONFIG_FLOAT_GROUP_XP_DISTANCE | none found | M |
| exploration.d:giveXP | Rested bonus on kills = min(rest, xp) | Player::GiveXP | Exhaustion.dbc / DB2 (Factor 2 for Rested) | M; **Done** (FORMULAS.md "Experience") |
| exploration.d:checkAreaExplore | Exploration XP from exploration_basexp by area level with ±5 level rules | CheckAreaExploreAndOutdoor | AreaTable.ExplorationLevel (DBC/DB2); exploration_basexp none found (emulator table) | M |
| player.d:setRestBonus | Rest pool cap 1.5 levels of double XP | SetRestBonus | Exhaustion (DBC/DB2: Rested threshold); Wowpedia "Rest" (verify) | M; **Done** (FORMULAS.md "Experience") |
| charscreen.d:makePlayer | Offline rest outside inn ×1/4 | LoadFromDB | Exhaustion.OutdoorHours | M; **Done** (FORMULAS.md "Experience") |
| player.d:changeLevel | Level up: full HP/mana, stats from levelstats | GiveLevel | none for stats (player_levelstats is emulator data) | M |
| loothandlers.d:killValue | No XP for critters or NO_XP; elite = rank not normal/rare | CreatureStaticFlags::NO_XP | CreatureType (DB2) | L |

### Stats/regen (25)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| stats.d:healthBonusFromStamina / manaBonusFromIntellect | First 20 STA = 1 HP each, then 10; first 20 INT = 1 mana, then 15 | GetHealthBonusFromStamina, GetManaBonusFromIntellect | Wowpedia "Stamina", "Intellect" (verify) | H: every player. **Done:** 10 and 15 a point are Blizzard's; the first 20 at 1 has no source (FORMULAS.md "Attack power, crit and dodge from agility") |
| stats.d:meleeAttackPower | War/Pal/Dru 3L+2STR−20; Rog/Hun 2L+STR+AGI−20; Sha 2L+2STR−20; casters STR−10 | UpdateAttackPowerAndDamage | Wowpedia "Attack power" (verify; classic table) | H: every melee hit. **Done:** agrees with the 1.x and 2008 WoWWiki tables (FORMULAS.md "Attack power, crit and dodge from agility") |
| stats.d:rangedAttackPower | Hunter 2L+2AGI−10; Rogue/Warrior L+AGI−10; others AGI−10 | UpdateAttackPowerAndDamage | Wowpedia "Attack power" (verify) | H. **Done:** agrees (hunters 2 a point before 2.0.1); one 2006 page's 2 a point for warriors and rogues left documented |
| stats.d:weaponDamage | + AP/14 × base weapon speed; ammo DPS × speed if ammo fits | CalculateMinMaxDamage | Wowpedia "Attack power" (verify) | H. **Done:** AP/14 a second agrees |
| stats.d:agilityPerPercent | AGI per 1% crit/dodge interpolated linearly lvl 1→60 per class (e.g. Rogue 2.2→29, Hunter 3.5→53, others →20) | GetMeleeCritFromAgility | none in 1.12 data (gtChanceToMeleeCrit is 2.0+); Classic Era measured (character sheet) | H: emulator-fitted linear table, wrong at mid levels likely. **Done** at level 60 (Blizzard's 20/29/53 and 20/14.5/26.5 agree); below 60 the straight line stays, no source |
| stats.d:meleeChances | Base dodge per class (War 0, Pal .75, Hun .64, Rog 0, Pri 3, Sha 1.75, Mag 3.25, Wlk 2, Dru .75); parry/block 5%; skill ×0.04; block value STR/20−1 | UpdateCritPercentage | Classic Era character sheet (measured); Wowpedia "Dodge" (verify) | H. **Done:** the base dodge agrees with WoWWiki "Dodge" (2006-11) |
| spellhandlers.d:spellCrit | Spell crit = base + INT/(a + b×level) per-class fitted table | fit replacing gtChanceToSpellCrit | none in 1.12 data; Classic Era character sheet (measured) | H. **Done** at level 60 (Tseric's figures; the mage's row was the paladin's, fixed); bases and slope no source (FORMULAS.md "Spell crit from intellect") |
| creatureai.d:regenerate | OOC: +1/3 max health and mana every 5 s (pets too); in combat mana +1/20 every 5 s, none within 5 s of spending | Creature::RegenerateAll, RegeneratePower | none found | H: tick length emulator guess. **Checked 2026-11-28 against CMaNGOS:** the 5 s and the thirds agree; its in-combat mana (a creature without intellect: max / 20 a tick, not under the five-second rule) was missing here and is done (1900bf0); no period source found |
| creature.d:selectLevel | HP/mana/armor = classlevelstats base × multipliers; weapon (baseDamage×variance + AP/14)×atkTime×mult, max ×1.5; AP added again; off hand 50% | Creature::SelectLevel, UpdateDamagePhysical | none found for 1.12 (ExpectedStat absent from Classic Era DB2); creature_template_classlevelstats is emulator-collected | H: all creature damage/armor/HP; AP counted twice |
| player.d:healthRegenPerSecond | OOC HP/s from spirit per class (e.g. warrior 1.26s−22.6, rogue 0.84s−13) | OCTRegenHPPerSpirit | none in 1.12 data (gt tables 2.0+); Wowpedia "Spirit" (page exists; verify 1.12 section) | H: every player. **Done:** the 1.x per-tick table, a tick every 2 s (it was CMaNGOS's per-tick lines taken a second: twice); mage/paladin/priest constants none found (FORMULAS.md "Health and mana from spirit") |
| player.d:healthRegenNow | No regen in combat except % auras; ×1.5 sitting | RegenerateHealth | Wowpedia "Spirit" (verify) | H. **Done:** a third more sitting (was half again) |
| player.d:spiritManaPerSecond | Mana per 2 s tick: s/5+15 (druid/hunter/paladin/warlock), s/4+12.5 (mage/priest), s/5+17 (shaman) | OCTRegenMPPerSpirit | Wowpedia "Spirit" (verify; the 1.12 per-class table is widely cited) | H. **Done:** agrees (paladin / 5 + 15, by the 2006 item comparison) |
| player.d:manaSpent / manaRegenPerSecond | Five-second rule: 5 s no spirit regen after mana spend | Player::Regenerate | Wowpedia "Five second rule" (verify) | H. **Done:** a channel paid at its start pauses it as long as it channels, if longer than 5 s |
| stats.d:computeStats (base) | Unarmed 2000 ms, 1–2 dmg; off hand ×0.5 | CalculateMinMaxDamage | Wowpedia "Dual wield" (verify) | M |
| stats.d:computeStats (stacking) | Flat stats, then % stat, then total %; armor += 2×AGI | _ApplyItemBonuses, UpdateArmor | Wowpedia "Agility" (verify) | M |
| auras.d:multiplier / total | % auras multiply, flat amounts add | TOTAL_PCT | none found | M |
| auras.d:healingTaken / strongest | Flat then % healing taken; exclusive resist highest only; speed strongest only | SpellHealingBonusTaken | none found | M |
| aurahandlers.d:updateAuras | Heartbeat every 5 s; drink MOD_POWER_REGEN per 5 s | Unit::Heartbeat | none found | M |
| spellhandlers.d:costOf / go (power) | Cost mods; health-cost limit; mana spend starts the 5-second rule | CheckPower, TakePower | SpellPower | M |
| spellhandlers.d:spellPowerFromSpirit | MOD_SPELL_*_OF_STAT_PERCENT assumed spirit | CMaNGOS | Spell.dbc EffectMiscValue (stat) | M |
| creature.d:setFields | Power type: warrior rage, rogue energy, else mana | Unit::SetPowerType | ChrClassesXPowerTypes (DB2) | L |
| player.d:regenerate | Tick 2 s; energy 10/s; rage decay 1.25/s OOC | RegenerateAll | PowerType (DB2): RegenPeace energy 10, rage −12.5 (= −1.25/s) | L: matches DB2 |
| playercreate.d:create | Health/mana from base + stamina/intellect | Player::Create | none for base values (player_classlevelstats is emulator data) | L |
| talenthandlers.d:applyEquipSpells | Equip spells/set bonuses only from unbroken worn items | _ApplyAllItemMods | ItemSet/ItemSetSpell | L |
| enchantments.d:EnchantmentBonus.add | Enchant bonuses only while worn | not in PROVENANCE | SpellItemEnchantment | L |

### Creatures/AI (28)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| combat.d:stealthDetectRange / detects | (30 + 5(lvl−1) + detect − stealth)×0.3 yd, player cap 30 yd, alert +8% +1.5 yd; front arc only | GetStealthVisibilityDistance | Wowpedia "Stealth" (verify) | H: every rogue/druid; formula looks arbitrary |
| creatureai.d:attackDistance | Aggro radius = template Detection − (target lvl − own lvl), diff floored at −25, min 5 yd, + MOD_DETECT_RANGE; no 45 yd cap (only map notice 50 yd) | Unit::GetAttackDistance | Wowpedia "Aggro radius" (page exists) | H: every pull. **Done:** 45 yd cap (FORMULAS.md "Aggro radius") |
| creatureai.d:moveInLineOfSight | Aggro on sight: aggressive, not neutral-to-all, enemy, in radius and LOS; stealth needs detection | UnitAI::MoveInLineOfSight, DetectOrAttack | none found | HH. **Checked 2026-11-28 against CMaNGOS** (`UnitAI::MoveInLineOfSight`, `DetectOrAttack`): the same (react, victim outside dungeons, neutral to all, check for help, radius, LOS, stealth alert; `AssistPlayerInCombat` is false in the base AI). Fixed: only a target where it can follow (`isInAccessablePlaceFor`): a creature of the land alone (InhabitType 1, 19,361 spawns) leaves swimmers be, one of the water alone walkers; "in water" here is swimming, not CMaNGOS's any liquid under the target (a bridge). Not done: CMaNGOS's height limit on flying targets (no flying players in 1.12) |
| creatureai.d:callAssistance | Once per fight, allies within template CallForHelp yd (default 5) with LOS arrive after 1500 ms; no chain calls | Creature::CallAssistance | Wowpedia "Aggro" (page exists; verify) | H: radius/delay emulator config. **Checked 2026-11-28 against CMaNGOS:** the same (template `CallForHelp`, else `CreatureFamilyAssistanceRadius` 5; `CreatureFamilyAssistanceDelay` 1500 ms; once a fight) |
| creatureai.d:updateCombatManager | Pursuit timer; leash check every 1200 ms: victim >30 yd from start → evade (not in dungeons); template Leash distance | CombatManager::Update, LEASH_RADIUS | measured Classic Era (Warcraft Tavern), Blizzard post 2019-10-23 | H: every chase. **Done:** time by level (FORMULAS.md "Leash"); the 30 yd stays |
| creatureai.d:enterEvadeMode / reachedHome | Evade clears threat and tap, removes auras, runs home; no instant full heal (regen 1/3 per 5 s) | EnterEvadeMode, HomeMovementGenerator::Finalize | Warcraft Wiki "Evade" (checked: regenerates as out of combat, no instant heal) | H. **Done:** already matches (FORMULAS.md "Evade") |
| unit.d:dealDamage / creatureDamaged | Any damage wears gear; parry haste; 0 damage still aggros; tap credit to owner of pet/totem/guardian | Unit::DealDamage | none found | M |
| effecthandlers.d:threatEffect | Threat × MOD_THREAT; reduction capped | EffectThreat | Spell.dbc | M |
| effecthandlers.d:attackMeEffect | Taunt sets top target | EffectTaunt | none found | M |
| effecthandlers.d:fadeThreat | MOD_TOTAL_THREAT removed while active, returned at end | threatTemporaryFade | Spell.dbc | M |
| creatureai.d:canAssistAgainst / answersCallsForHelp | Helper must be aggressive, friendly to caller, free; in dungeons/BGs any able creature joins; answers only with FactionTemplate flag 0x01 | CanAssistInCombatAgainst, OnCallForHelp | FactionTemplate.Flags (DBC/DB2) | M |
| creatureai.d:checkForHelp | Fighting creature pulls free allies within 5 yd every 1000 ms, first after 2000 ms | UnitAI::CheckForHelp | none found | M |
| creatureai.d:updateReachability | Unreachable victim: evade after 10 s if sole enemy, else switch | EvadeTimerExpired | none found | M |
| creatureai.d:spellListTick | creature_spell_list timers/weights; retry 1000/500 ms; heal-target thresholds 10/50/90/25% | creature_spell_list | none found | M |
| creatureevents.d:removedOnEvade | Evade removes auras except a hard list of 128 passive spell ids and attribute exceptions | IsSpellRemovedOnEvade | SpellMisc Attributes | M: hard-coded list |
| creatureevents.d:levelScaledValue | SCALES_WITH_CREATURE_LEVEL spells × baseDamage(level)/baseDamage(spellLevel) | CalculateSpellEffectValue | SpellMisc Attributes, SpellLevels | M |
| creatureevents.d:levelScaledCost | Mana cost / (1.117×spellLevel/level − 0.1327) | CalculatePowerCost | none found | M: magic constants |
| creaturecasting.d:scriptFlee / panic | Flee only via EventAI: 10 s panic; no generic low-health flee | DoFlee | measured Classic Era (humanoids flee at ~15%; verify) | M |
| map.d:playerNoticed | Creatures notice players within 50 yd (cap); relocation re-check 1 s | Unit::OnRelocated | none found | M: 50 yd effective aggro cap |
| worlddata.d:PoolChooser.choosePool / reroll | Pool spawn picks; reroll compares non-cumulatively (biased) | PoolGroup::RollOne, UpdatePool | none found | M: rare-spawn rotation |
| creatureai.d:this | NO_AGGRO_ON_SIGHT extra flag makes it defensive | CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT | none found (DB data) | L |
| creatureai.d:distract | Distract: OOC creature faces point for duration | MoveDistract | SpellEffect | L |
| creature.d:chooseLevel | Uniform level in [min,max] | SelectLevel | CreatureDifficulty.MinLevel/MaxLevel (DB2) | L |
| creatureevents.d:scriptSaw | OOC_LOS events up to 100 yd; front/back 5 yd | CreatureEventAI | none found | L |
| creaturecasting.d:summonBySpell | Wild summons capped at 5, 3 yd around caster | EffectSummon | SpellEffect | L |
| creaturecasting.d:critterFleeAtAggro | NO_MELEE_FLEE creature flees 30 s then evades | ORDER_CRITTER_FLEE | none found | L |
| eventai.d:update | EventAI timers every 500 ms; ranged-mode distance 20 yd | EVENT_UPDATE_TIME | none found | L |
| worlddata.d:SpawnGroups.choose | Spawn group members/entries by chance | CMaNGOS spawn groups | none found | L |

### Honor (16)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| honor.d:greyForHonor | No honor for grey victims; step table [4..12] by level/5 (at 60 ≤47 grey) — differs from XP grey (≤51) | MaNGOS::Honor, Unit::Kill | Wowpedia "Honor system (pre-2.0 formulas)" (page exists, checked) | H; **Done** (FORMULAS.md "Honor") |
| honor.d:honorableKillPoints | Honor = (10−killsToday)×0.25×(killerLvl + rank×5 + 1)×(1 + 0.05×(…))×(victimLvl/killerLvl), cap 400, ÷ group; −10%/kill/day | MaNGOS::Honor | Wowpedia "Honor system (pre-2.0 formulas)" (checked: CP by victim rank table, 198 at R1 … 398 at R14; 10 kills/24 h at −10% each); links Blizzard's "Official Honor Guide" | H: emulator reconstruction differs from documented per-rank table; **Done: by rank and level; unequal levels are still CMaNGOS's** (FORMULAS.md "Honor") |
| honor.d:dishonorableKillPoints | DK RP penalty by level bands, cap 100; only for grey PvP-flagged civilians | MaNGOS::Honor | Wowpedia "Dishonorable kill" (verify) | H: grey-only condition looks wrong; **Done** (FORMULAS.md "Honor") |
| honorweek.d:standingScores | Bracket fractions [1, .858, … .002]; bracket RP 0, 400, 1000 … 13000 | GenerateScores | Wowpedia "Honor system (pre-2.0 formulas)" (checked: breakpoints as fractions of NR, CP→RP piecewise to 13000) | H; **Done** (FORMULAS.md "Honor") |
| honorweek.d:rankPointEarning | Linear interpolation of RP between brackets | CalculateRpEarning | Wowpedia "Honor system (pre-2.0 formulas)" (checked) | H; **Done** (FORMULAS.md "Honor") |
| battleground.d:bonusHonor | BG bonus honor curve fixed at level 60 for all brackets | MaNGOS::Honor | none found | H: low brackets get level-60 honor; **Done** (FORMULAS.md "Honor") |
| pvp.d:pvpZoneChanged | Honorless Target 2479 on arrival in enforced zone | UpdateZone | Spell.dbc 2479 | M |
| honor.d:killsTodayOf | DR count per victim per server-local day | CalculateTotalKills | Wowpedia "Honor system (pre-2.0 formulas)" (checked: 24 h) | M; **Done** (FORMULAS.md "Honor") |
| honor.d:playerKilledByMe | Honor shared within 74 yd, equal shares | RewardGroupAtKill, RewardHonor | none found | M |
| honor.d:racialLeaderHonor | Racial leader kill 398 honor | MaNGOS::Honor | Wowpedia "Honor system (pre-2.0 formulas)" (verify) | M |
| honor.d:rankOf / rankBar | RP → rank: <2000 R1; then RP/5000 + 2; >60000 R14 | GetRankPoints, UpdateHonor | Wowpedia "Honor system (pre-2.0 formulas)" (verify) | M; **Done** (FORMULAS.md "Honor") |
| honor.d:lastMaintenanceDay | Honor week starts Wednesday, server local | GetDateLastMaintenanceDay | Blizzard regional maintenance schedule | M |
| honorweek.d:runHonorMaintenance | ≥15 HKs to be ranked; per faction | FlushRankPoints | Wowpedia (verify 15 HK) | M; **Done** (FORMULAS.md "Honor") |
| honor.d:rewardHonorForPlayer | No honor vs Honorless Target, same faction, grey | RewardHonor | Wowpedia "Honorless Target" (verify) | L |
| honor.d:updateHonor | Highest rank tracking; day/week totals | UpdateHonor | none found | L |
| honorweek.d:decayedRankPoints | Decay 20%; negative delta halved, capped −2500 | CalculateRpDecay | Wowpedia "Honor system (pre-2.0 formulas)" (checked: same) | L: matches; **Done** (FORMULAS.md "Honor") |

### Professions (21)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| combathandlers.d:updateCombatSkills | Weapon/defense skill-up chance = max(room/5,1)/(cap/5)×100, +2%/INT pt; extra rise gate | Player::UpdateCombatSkills | Wowpedia "Weapon skill" (verify) | H: every swing while levelling; looks emulator-invented. **Not changed, 2026-11-28 (the owner's call):** CMaNGOS replaced this formula (PR 628, January 2026) by a tuned curve (logarithmic catch-up while 7+ points behind, quadratic near the cap, intellect bonus up to 10%) and removed `UpdateSkill`'s second roll as an unintended double gate, our "extra rise gate"; its reasons are how levelling felt, no period source, so one guess would replace another |
| spellhandlers.d:useBobber | Catch if roll ≤ skill − zone + 5; skill-up (skill<75 ? 100 : 2500/(skill−50)) | UpdateFishingSkill | Warcraft Wiki "Fishing" (pre-3.1: no skill-up on a getaway); measured Classic Era catches per point | H. **Done:** FORMULAS.md "Fishing" (zone skills stay emulator data) |
| spellhandlers.d:checkSkinning / skinCreature | Required skill skill<100 ? (lvl−10)×10 : lvl×5; skill-up requirement formula differs | CheckCast skinning, UpdateGatherSkill | Wowpedia "Skinning" (1 / 10L−100 / 5L) | H. **Done:** one formula (FORMULAS.md "Skinning") |
| player.d:updateSkillsForLevel | Weapon/defense max = 5×level | UpdateSkillsForLevel | SkillRaceClassInfo flags; SkillTiers.dbc | H: feeds combat table |
| gameobjecthandlers.d:updateGatherSkill | Gather skill-up chance vs required: grey 0, green 25%, yellow 75%, orange 100% (+100/+50/+25 bands) | UpdateGatherSkill | Warcraft Wiki "Forever mining techniques" (checked: veins 1/25/50/100, Tin 65/90/115/165: the +25/+50/+100 bands); Lock.dbc Skill | H: bands match; the 75%/25% chances have no source (left) |
| gameobjecthandlers.d:checkGameObjectTarget / openLock | Herb/mining nodes never fail (CMaNGOS has an orange failure roll) | CheckCast (open lock) | Patch 3.1.0 notes ("You can no longer fail when Mining, Herbing, and Skinning": failing existed); no failure rate found | H. **Left:** no source for the chance |
| enchanting.d:craftSkillChance / updateCraftSkill | Craft skill-up: ≥grey 0, ≥green ((grey+yellow)/2) 25%, ≥yellow 75%, else 100% | UpdateCraftSkill | SkillLineAbility TrivialSkillLineRankHigh/Low (DBC/DB2); in-between chance: community formula only | H. **Done:** (grey−skill)/(grey−yellow) (FORMULAS.md "Crafting skill-ups") |
| spellhandlers.d:castBobber / updateBobber | Bobber placement; bite at duration − {3,7,13,17} s; 5 s hook | EffectTransmitted | none found | M |
| playercreate.d:learnDefaultSkills | Starting skill values: languages 300, level-range 1/5×L, tiered from SkillTiers | Player::Create | SkillTiers.dbc, SkillRaceClassInfo.dbc | M |
| gameobjecthandlers.d:canOpenLock | Lock opens with key or skill ≥ Lock Skill; value via spell effect at level skill/5 | CanOpenLock, GetSpellRank | Lock.dbc Skill/Type | M |
| gameobjecthandlers.d:updateSkillPro | Roll 1..1000 against the chance | UpdateSkillPro | none found | M |
| gameobjecthandlers.d:gatherAgain | Vein re-open chance 100×0.8^(4u/max) + mining/(lock+25) | not in PROVENANCE | none found | M: arbitrary formula |
| professions.d:checkItemTarget / lockResists | Lockbox fails if required > rand[skill−25, skill+37] | Spell::CheckCast | Wowpedia "Lockpicking" (verify) | M |
| professions.d:disenchantItem | Disenchant loot from disenchant_loot_template; no server skill check | EffectDisEnchant | ItemDisenchantLoot (DB2: class, subclass, quality, level range, SkillRequired) | M: emulator table replaceable |
| spells.d:buildLearnSkills | SKILL effect teaches skill at step = base points + dice | LoadSpellLearnSkills | SkillLineAbility / SkillRaceClassInfo | L |
| creature.d:skinningSkill | Skin with herbalism/mining by creature flags 0x100/0x200 | Creature skinning | creature_template type flags (emulator DB); none found | L |
| playercreate.d:initPrimaryProfessions | 2 primary professions | InitPrimaryProfessions | Wowpedia "Profession" (verify) | L |
| professions.d:checkSpellFocus | Spell focus within GO data1 + reach | GameObjectFocusCheck | none found | L |
| professions.d:openItemLock | Lockpicking skill-up once per lockbox | EffectOpenLock | Lock.dbc | L |
| enchanting.d:enchantItem | Temporary enchant runs only online; default 1 h | not in PROVENANCE | SpellDuration.dbc | L |
| tradehandlers.d (non-traded slot) | Enchant via trade slot pays costs | TradeData::SetSpell | none found | L |

### Reputation (6)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| loothandlers.d:rewardAtKill (reputation share) | Group kill rep ×1/nearCount in open world, full in dungeons (CMaNGOS uses level share) | Group::RewardGroupAtKill | none found (measured Classic Era: full rep per member) | H: differs from both origin and likely Blizzard; **Done** (FORMULAS.md "Reputation") |
| reputationhandlers.d:reputationGain | Racial %, low-level kill/quest falloff 0.2/level, per-faction rates | CalculateReputationGain | Spell.dbc 20599; QuestFactionReward (DB2); reputation_reward_rate is emulator data | M; **Done: grey kills; the quest falloff and the rates have no source** (FORMULAS.md "Reputation") |
| reputationhandlers.d:rewardKillReputation | creature_onkill_reputation caps; parent faction gets half | RewardReputation | Faction.dbc parent; none found for the half | M |
| reputation.d:change | Spillover via reputation_spillover_template; standing clamp −42000..42999 | ModifyReputation | Faction.dbc / DB2 (ParentFactionMod, ParentFactionCap — verify 1.12 fields) | M |
| reputation.d:changeOne / setAtWar | Hostile forces war; rising to neutral ends it | SetAtWar | Faction.ReputationFlags | M |
| relations.d:reputationToRank | Rank thresholds 36000/3000/3000/3000/6000/12000/21000/1000 | ReputationToRank | Faction.ReputationMax; Wowpedia "Reputation" (verify) | L |

### Pets (21)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| pet.d:petStats | Hunter pet weapon d = atkTime×level/2000, 0.75d–1.125d; AP 2×STR−20; scale (lvl−min)/maxLvl | Pet::InitStatsForLevel | CreatureFamily MinScale/MaxScale/levels (DBC); none found for damage; pet_levelstats is emulator data | H: all pet damage; scale formula suspect |
| pethandlers.d:updatePetMood | Happiness loss every 7.5 s = (140>>loyalty)×125, ×1.5 in combat; loyalty ticks every 12 s +20/+10/−20 | Pet::Update (LoyaltyTimer) | PetPersonality.HappinessDamage (DBC/DB2; partly) | H: constant for hunters. **Checked 2026-11-28 against CMaNGOS:** the same (`(140 >> loyalty) * 125` a 7.5 s, ×1.5 in combat, its own "multiplier guess"; loyalty every 12 s +20/+10/−20; a happiness level lost at a death outside battlegrounds); no period source |
| pethandlers.d:modifyLoyalty | Loyalty point tables [5500..39500], [2000..17500]; XP gate; TP changes; run away 1/3 chance at loyalty 1 | Pet::ModifyLoyalty | PetLoyalty.dbc (names only); Wowpedia "Pet loyalty" (verify) | H: emulator tables. **Checked 2026-11-28:** CMaNGOS's `ModifyLoyalty` the same (gains by the loyalty rate, the best friend's cap) |
| pethandlers.d:petGainsXp / petXpForLevel | Pet XP to level = player XP/4; level-up +(loyalty−1) TP; kill loyalty gain formula | Pet::GivePetXP, GetXPForPetLevel | Wowpedia "Pet experience" (verify) | HH. **Checked 2026-11-28 against CMaNGOS** (`Pet::GivePetXP`, `RewardGroupAtKill_helper`): XP to level, training points and the kill's loyalty the same. Fixed: a kill's XP is the pet's level's (`XP::Gain(pet, victim)`), not its owner's; in a group by its owner's share (CMaNGOS multiplies by the share twice, taken as a slip: once here); a pet at its owner's level still gets the kill's loyalty. A member on another node: its pet still gets none |
| petai.d:petUpdate / petLookAround | Aggressive pet scans every 1 s within 45 yd; follows 1.5 yd at 90° | PetAI::UpdateAI | none found | M |
| pethandlers.d:tameCreature | Tame rules; start happiness 166 500, loyalty 1, 1000 points | EffectTameCreature | CreatureFamily.dbc; Wowpedia "Tame Beast" (verify) | M |
| loothandlers.d:petGainsXp (caller) | Pet gets full kill XP solo, half owner's share in a group | GivePetXP callers | Wowpedia "Pet experience" (verify) | M |
| pethandlers.d:learnCreateSpells / trainingCost | TP accounting; teach cost from SkillLineAbility reqTrainPoints | InitPetCreateSpells | SkillLineAbility.dbc | M |
| pethandlers.d:petCastSpell | 10% chance per cast to learn ability (Beast Training) | LearnPetSpell | Wowpedia "Beast Training" (verify) | M: number looks arbitrary |
| pethandlers.d:foodBenefit | Food happiness 35 000 / 17 000 / 8000 by item level gap; refused beyond +14 | EffectFeedPet | Wowpedia "Feed Pet" (verify); ItemPetFood.dbc (diet only) | M |
| pethandlers.d:ownPetDied | Pet death −333 000 happiness (not in BG); corpse 60 s | Pet::SetDeathState | Wowpedia "Pet happiness" (verify) | M |
| guardians.d:guardianLevel / spawn | Guardian level clamped to owner; engineering trinket = skill/5; follow 1.5 yd | EffectSummonGuardian | SpellEffect, SpellCategories | M |
| mounting.d:petModeAtMount | Pet bar disabled while riding | Mount/Unmount | none found | L |
| petai.d:startPetCooldown | Pet cooldown = max(Recovery, CategoryRecovery) | Creature::AddCooldown | SpellCooldowns (DB2) | L: matches data |
| pet.d:maxStableSlots | 2 stable slots | MAX_PET_STABLES | StableSlotPrices.dbc | L: matches |
| pethandlers.d:moodOf / moodDamageFactor | Happiness max 1 050 000; 333 000 / 666 000 thresholds; damage ×0.75/1/1.25 | GetHappinessState | PetPersonality.dbc (matches) | L |
| pethandlers.d:canTeachPet | Spell level ≤ pet level and enough TP | Spell::CheckCast | SpellLevels | L |
| pethandlers.d:reviveDeadPet | Revive Pet restores effect % health | EffectSummonDeadPet | SpellEffect | L |
| pethandlers.d:petOwnerLevelChanged | Demon level = owner; hunter pet lowered only if above | SynchronizeLevelWithOwner | none found | L |
| pethandlers.d:validPetName | Pet name 2–12 letters; one rename | CheckPetName | none found | L |
| taxihandlers.d:takeOff / landTaxi | Pet unsummoned during flight | Mount/Unmount | none found | L |

### Rules & timers (57)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| combathandlers.d:takeBlow (durability) | On death gear loses 10% durability unless killed by player side or in a BG | Unit::DealDamage | Wowpedia "Durability" (verify); 1.12 patch-era Blizzard FAQ | H: every PvE death. **Checked 2026-11-28 against CMaNGOS** (`Unit::Kill`): the same (10%, not by the player side, not in a battleground); `SPELL_ATTR_EX3_NO_DURABILITY_LOSS` not done, on 4 spells none of which slays a player |
| death.d:corpseReclaimDelay | Reclaim delay 30/60/120 s by recent deaths; 5 min step; max count 3 | UpdateCorpseReclaimDelay, CORPSE_RECLAIM_DELAY | Wowpedia "Death" (verify) | H: every death. Checked: no 1.12 number found (WoWWiki "Death" 2006 has none); kept |
| death.d:handleReclaimCorpse (+ corpse.d:corpseReclaimRadius) | Reclaim within 39 yd after delay; back with 50% health/mana, rage 0 | CORPSE_RECLAIM_RADIUS, ResurrectPlayer(0.5) | Wowpedia "Corpse" (verify) | H: every corpse run. **Checked 2026-11-28 against CMaNGOS:** the same (`CORPSE_RECLAIM_RADIUS` 39; `ResurrectPlayer(0.5)`: health, mana and energy by half, rage none) |
| death.d:handleSpiritHealerActivate | Spirit healer: 50% health/mana; 25% durability on worn and carried; res sickness | HandleSpiritHealerActivate | Wowpedia "Spirit healer" (verify) | H. **Done:** 25% of maximum, worn and carried, agrees (WoWWiki "Spirit Healer" 2006-11) |
| death.d:applyResurrectionSickness | Spell 15007; none below level 11; 1 min per level above 10, 10 min max | ResurrectPlayer (death sickness config) | Spell.dbc 15007 + SpellDuration; Wowpedia "Resurrection sickness" (verify) | H: level scaling is emulator config. **Done:** none to 10, a minute a level over 10, 10 minutes from 20: agrees (WoWWiki "Spirit Healer") |
| pvp.d:update | PvP flag lasts 5 min after leaving PvP | UpdatePvPFlagTimer | Wowpedia "PvP flag" (verify); Blizzard 1.x patch notes | H. **Done:** 5 minutes agrees (WoWWiki "PvP flag" 2006-10) |
| pvp.d:enforcedPvPZone / isPvPRealm | Enemy capital flags; PvP realms flag in enemy/contested zones | UpdateZone | AreaTable.dbc Flags/team | H. **Done:** the other side's land flags on every realm (WoWWiki "PvP flag" 2006-10; it was PvP realms only), contested on PvP realms |
| pvp.d:pvpHitBy | Hitting flagged player flags attacker; flagged attacker flags victim | SetInCombatWith(Aggressor) | none found | HH. **Checked 2026-11-28 against CMaNGOS** (`SetInCombatWithAggressor`, `SetInCombatWithVictim`): the same, for players and their pets. Fixed: attacking a flagged player's pet flags (and contests) its attacker too (unit.d `flaggedPetAttacked`) |
| pvp.d:pvpAssisted | Healing/buffing a flagged player in combat flags helper | SetInCombatWithAssisted | none found | H. **Done:** a heal flags the healer in combat or not (was: only when the healed was in combat); buffs left (FORMULAS.md "The PvP flag") |
| combathandlers.d:enterCombatFor / updateMelee | In combat until 5 s after last swing/hit and no creature has it on threat | Unit::Update | none found | M |
| death.d:autoReleaseMs / deathOnLogout | Unreleased body auto-released after 6 min | Player::Update | Wowpedia "Death" (verify) | M. Checked: no number found; kept |
| death.d:closestGraveyard | Nearest own-team graveyard by area→zone→map links; instance: nearest the entrance | GetClosestGraveYard | WorldSafeLocs.dbc (positions); links none found (game_graveyard_zone is emulator data) | M |
| itemuse.d:applyEquipCooldowns | Equipping an on-use item: 30 s cooldown | ApplyEquipCooldown | none found | M |
| duelhandlers.d:handleDuelAccepted | 3 s countdown | Player::Update (duel) | Wowpedia "Duel" (verify) | M |
| duelhandlers.d:update (bounds) | >50 yd warns; back in 40 yd; 10 s out = fled | CheckDuelDistance | Wowpedia "Duel" (verify) | M |
| duelhandlers.d:duelLost / end | Lethal blow leaves 1 HP; loser begs; cancel after start = loss | DuelComplete | none found | M |
| pvp.d:updatePvPContested | Contested 30 s after attacking a flagged player | UpdatePvPContested | none found | M |
| pvp.d:pvpAreaChanged | FFA flag in arena areas | UpdateArea | AreaTable.dbc Flags | M |
| mounting.d:mountedCastError | Mounted: only ALLOW_WHILE_MOUNTED spells | Spell::CheckCast | Spell.dbc Attributes | M |
| creature.d:die | Corpse decay: normal 60 s, elite/rare 300 s, boss 3600 s, ≤90% of respawn | CORPSE_DECAY_* config | none found | M |
| map.d:playerSees | Ghost sees living within 45 yd of corpse; stealth seen by group/detected | IsVisibleInGridForPlayer | none found | M |
| questhandlers.d:canSeeStartQuest / dialogStatus | Quests shown up to 7 levels above; gray when >4 above quest level | getDialogStatus config | Wowpedia "Quest" (verify) | M |
| questhandlers.d:questAllowedHere | Non-raid quests give no credit in a raid | Quest::IsAllowedInRaid | Wowpedia "Raid" (verify) | M |
| loothandlers.d:tapCreature / rewardKill | First damage taps for the group | DealDamage, Kill | Wowpedia "Tapping" (verify) | M |
| inventory.d:canEquip / canChangeEquipStateInCombat | In combat only weapons etc. can change; unique-equipped; dual wield | CanEquipItem | Wowpedia "Equipment" (verify) | M |
| taxihandlers.d:activateTaxiPathTo | Not in combat/mounted; allowed forms; start distance (2·5)^3 looks like typo for ^2 | ActivateTaxiPathTo | SpellShapeshiftForm flags | M |
| gameevents.d:schedule types | Darkmoon Faire rotation, Lunar New Year moon rule, Easter | custom/CMaNGOS-derived | Wowpedia "Darkmoon Faire" (verify) | M |
| combathandlers.d:takeBlow (duel) | Lethal duel blow → duel lost, no death | Unit::DealDamage | none needed (client behaviour) | L |
| aurahandlers.d:interruptAurasOnCast / removeAurasOnDeath | Exceptions for own aura/stealth; non-passive auras removed on death | RemoveAurasOnCast | SpellMisc Attributes; SpellInterrupts | L |
| death.d:buildPlayerRepop | Release: ghost with 1 HP; quests that fail on death fail | BuildPlayerRepop | none found | L |
| death.d:selfResurrect / handleResurrectResponse | Res by spell: amounts capped; energy full; rage 0 | EffectSelfResurrect | Spell.dbc effect values | L |
| corpse.d:bonesLifetime | Bones last 1 h | Corpse::IsExpired | none found | L. Checked: no source found; kept |
| itemuse.d:useItemError | Required level, worn, NOT_IN_COMBAT checks | HandleUseItemOpcode | Spell.dbc Attributes | L |
| itemuse.d:loadItemDurations | Timed items count while online (real-time offline) | UpdateItemDuration | none found | L |
| spellhandlers.d:resurrectEffect | Res amounts from data; NO_RES_TIMER | EffectResurrect | Spell.dbc | L |
| map.d:objectVisibleTo | Spirit healers hidden from living | UpdateVisibilityOf | none needed (client) | L |
| exploration.d:updateZone | Capital flag → city rest | UpdateZone | AreaTable.dbc flags | L |
| player.d:talentPointsForLevel | Level − 9 from 10 | UpdateFreeTalentPoints | NumTalentsAtLevel (DB2) | L |
| questhandlers.d:handlePushQuestToParty | Share within 10 yd | CanShareQuest | none found | L |
| questhandlers.d:failQuestsOnDeath / timed quests | Stay-alive quests fail on release; one timed quest | FailQuestsOnDeath | none found | L |
| questhandlers.d:rewardPlayerAndGroupAtCast | Cast credit to group in range | RewardPlayerAndGroupAtCast | none found | L |
| quests.d:maxQuestLogSize | 20 quests | MAX_QUEST_LOG_SIZE | 1.12 client | L |
| npchandlers.d:prepareGossipMenu | Talent unlearn at own class trainer from 10 | PrepareGossipMenu | none found | L |
| npchandlers.d:handleBinderActivate | Bind at own position; not in instances | HandleBinderActivateOpcode | Spell.dbc 3286 | L |
| talenthandlers.d:handleLearnTalent | 5 points per row; prerequisites | LearnTalent | Talent.dbc | L |
| inworld.d:handleLogoutRequest | 20 s logout unless resting | HandleLogoutRequestOpcode | Wowpedia "Logout" (verify) | L. Checked: no 1.12 page found; kept |
| gameobjecthandlers.d:withinInteraction | GO range 5 yd + size (+2/+5); bobbers and chairs 100 yd | INTERACTION_DISTANCE | none found | L |
| inventory.d:canUse | Class/race/skill/rank/level/reputation requirements | CanUseItem | item_template data | L |
| inventory.d:bindsWhenStored | BoP/quest bind on store; BoE on equip | SetBinding | none needed | L |
| tradehandlers.d:handleInitiateTrade / accept | Same team, 11.11 yd, 6+1 slots | TRADE_DISTANCE | none found | L |
| tradehandlers.d:canBeTraded | Bound/equipped/non-empty bags untradable | Item::CanBeTraded | none needed | L |
| rituals.d:joinRitual | Ritual group/channel/participant rules | TriggerSummoningRitual | Wowpedia "Ritual of Summoning" (verify) | L |
| rituals.d:summonAcceptSeconds | Summons valid 120 s | MAX_PLAYER_SUMMON_DELAY | none found | L |
| rituals.d:summonPlayerEffect | Evil Twin aura ignores summons | EffectSummonPlayer | none found | L |
| honor.d:handleInspectHonorStats | Inspect within 28 yd | HandleInspectHonorStatsOpcode | none found | L |
| teleport.d:handleAreaTrigger | Area trigger within 5 yd of box; one request per 5 s | HandleAreaTriggerOpcode | AreaTrigger.dbc radius | L |
| gameevents.d:activeAt | Event windows by occurrence/length | GameEventMgr | none found | L |

### Loot (27)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| creature.d:setLootRecipient / tappedBy | Tap: first player and group; evade clears tap | SetLootRecipient, IsTappedBy | Wowpedia "Tapping" (verify) | H: every kill |
| loot.d:Loot.fill / LootItem.slotTypeFor | Visibility per loot method (FFA, RR, group, NBG, master) | GetSlotTypeForSharedLoot | Wowpedia "Loot" (verify) | H: every group loot. **Done:** agrees with WoWWiki "Loot"/"Party" (2006) (FORMULAS.md "Group loot") |
| loothandlers.d:setLootRights | Owners: group in reward distance or on threat list; RR turn; master falls back | SetGroupLootRight | Wowpedia "Loot" (verify) | H: every group kill. **Done:** out-of-range members get no share or roll, as WoWWiki "Party" says; chests keep the group's rules (left, FORMULAS.md "Group loot") |
| spellhandlers.d:pickPocket | Gold = 10×(rand(0..clvl/2)+rand(0..plvl/2)) copper | pickpocket loot | none found | M |
| creature.d:inspectingLoot / lootedOut | Looting extends corpse to ≥2 min; looted-out shortened to ≤2 min unless skinnable | InspectingLoot | none found | M |
| loot.d:Loot.rollGroup | Group drops at most one entry; shuffled walk; already-dropped entry skipped with 50% | LootGroup::Roll | none found | M: emulator choices |
| loot.d:questItems (+ loothandlers prepareBodyLoot) | Quest drops shown only to those who need them; never rolled; shared, not per-player copies | HasQuestDrop, FillLoot | Wowpedia "Quest item" (verify) | M. **Done:** agrees with WoWWiki "Loot" (multi-drop: each with the quest; else free to those who need it) |
| loot.d:Loot.sendGold | Group money split evenly; remainder lost | Loot::SendGold | Wowpedia "Loot" (verify) | M. **Done:** "as evenly as possible": the copper over goes one each (was lost) |
| loot.d:Loot.canLoot | When a corpse sparkles for a member | Loot::CanLoot | none found | M |
| loot.d:Loot.release | Closing window frees items to all owners | Loot::Release | Wowpedia "Loot" (verify) | M. **Done:** agrees ("freely lootable" once passed or released) |
| loot.d:LootRoll.tryToStart | Roll only with >1 present owner; quest items never roll | GroupLootRoll::TryToStart | none found | M |
| loot.d:lootRollSeconds | Roll lasts 60 s; ends when all voted | LOOT_ROLL_TIMEOUT | Wowpedia "Group loot" (verify) | M |
| loot.d:LootRoll.sendStartRoll | NBG hides Need when unusable | TryToStart | Wowpedia "Need before greed" (verify) | M. **Done:** "'Pass' is automatically selected" for who cannot use it, its weapon or armor skill counted (was: Need hidden, greed allowed) |
| loot.d:LootRoll.vote / allVoted | Need > greed, then 1–100; ties by hash order | PlayerVote, AllPlayerVoted | none found | M: tie handling arbitrary. **Done:** need before greed, highest 1-100 agrees; ties no source |
| loot.d:Loot.threshold / group.d:Group.create | Threshold uncommon; new group = group loot | Group::Create | Wowpedia "Loot" (verify) | M. **Done:** group loot the default (WoWWiki "Party") |
| group.d:setLoot | Threshold/master looter unvalidated | loot-method handling | none found | M. **Done:** threshold uncommon..epic, master a member; else refused |
| loothandlers.d:handleLoot | Loot reach max(5, reaches + 4/3); bones 10 yd; standing | LootHandler | none found | M |
| loot.d:LootStoreItem.roll | Ungrouped entries drop independently with DB chance | LootStoreItem::Roll | none found (loot tables are emulator-collected data) | L |
| loot.d:Loot.process | Reference entries; count uniform min..max; ≤16 items | LootTemplate::Process | none found | L |
| loot.d:Loot.add | Multi-drop flag: each looter gets a copy | ITEM_FLAG_MULTI_DROP | item_template Flags | L |
| loot.d:Loot.generateMoney | Money uniform min..max; 256-copper steps above 32 700 | GenerateMoneyLoot | none found | L |
| loot.d:LootRoll.finish | All pass → released | GroupLootRoll::Finish | none found | L |
| loothandlers.d:handleLootMasterGive | Master gives to allowed owners only | LOOT_MASTER_GIVE | none found | L |
| loothandlers.d:prepareBodyLoot | NO_LOOT flag; no template → looted out | NO_LOOT | none found | L |
| loothandlers.d:handleOpenItem | Opening needs required level; skill locks need picking | Item::m_loot | Lock.dbc | L |
| gameobjecthandlers.d:makeGameObjectLoot | Chest despawns 5 min after opening | GameObject::Use | none found | L |
| enchantments.d:chooseRandomProperty | Random property by item_enchantment_template chance | GetItemEnchantMod | ItemRandomProperties (DBC/DB2); chances none found (emulator table) | L |

### Instances/battlegrounds (41)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| arathi.d:tick | Resource ticks 10 per 12/9/6/3 s, 30 per 1 s at 5 bases; win 2000 | BattleGroundAB::Update | Wowpedia "Arathi Basin" (verify) | H: decides every AB. **Left:** the 1.x page measured 11 s and 10 s for one and two nodes (FORMULAS.md "Battlegrounds"); unchanged |
| (missing) 5 instances per hour | Not implemented; only the transfer-abort enum exists | — | Blizzard (Kaivax 2020-06-16: "the current limit of 5 instances per hour", realm-wide, not battlegrounds) | H. **Done:** FORMULAS.md "Instances per hour" (per node, in memory) |
| death.d:removedInsignia | Insignia gold = rand(50..150)×0.016×(level/5.76)^2.5 | RemovedInsignia | none found | M: arbitrary formula |
| mounting.d:dismountOnArrival | Dungeon with mountAllowed=0 dismounts | Map::IsMountAllowed | none found (instance_template) | M |
| homebind.d:update | Ungrouped player in instance ported out after 60 s | UpdateHomebindTime | Wowpedia "Instance" (verify) | M |
| rituals.d:useMeetingStoneToSummon | Meeting stone summon within level range | MEETINGSTONE | Wowpedia "Meeting Stone" (verify) | M |
| battleground.d:end | 2 min end delay; mark spells winner/loser | EndBattleGround | Spell.dbc 24950–24955 | M |
| battleground.d:checkPrematureEnd | Under min players 300 s → ends | BattleGround::Update | none found | M. **Done:** 5 minutes agrees (WoWWiki "Warsong Gulch") |
| battleground.d:spiritHealInterval | Spirit guide resurrects every 30 s | BG spirit healer | Wowpedia "Spirit Guide" (verify) | M. **Done:** 30 s agrees (WoWWiki "Warsong Gulch") |
| battleground.d:leaveBattleground | Deserter 26013 on leaving | LeaveBattleground | Spell.dbc 26013 | M |
| bgqueue.d:bracketOf | 10-level brackets from template minLevel; AV 51–60 | GetBattleGroundBracketIdFromLevel | PVPDifficulty (DB2: MapID, MinLevel, MaxLevel) | M |
| bgqueue.d:inviteTime | Invitation 80 s; reminder 60 s | INVITE_ACCEPT_WAIT_TIME | none found | M |
| bgqueue.d:update | Fill running copies first; minPerTeam to start | BattleGroundQueueItem::Update | BattlemasterList MinPlayers/MaxPlayers (DB2) | M |
| alterac.d:reinforcements | 600 each; death −1, captain −100, tower −75 | UpdateScore | Wowpedia "Alterac Valley" (verify; changed by 1.x patches) | M. **Left, reported:** reinforcements came with patch 2.3.0; 1.12 had none (FORMULAS.md "Battlegrounds") **Done:** reinforcements removed (patch 2.3.0's), docs/FORMULAS.md "Battlegrounds". |
| alterac.d:generals / captains | General ends BG; honor/rep values | HandleKillUnit | Wowpedia "Alterac Valley" (verify) | M; **Done: the honor units; not the reputation** (FORMULAS.md "Honor") |
| alterac.d:assault / defend / destroyed | Node falls 4 min after assault (Snowfall 5) | ProcessPlayerAssaultsPoint | Wowpedia "Alterac Valley" (verify) | M. **Done:** five minutes (2.3.0 cut it to four) |
| alterac.d:mines | +1 reinforcement per 45 s; revert after 20 min | ChangeMineOwner | Wowpedia "Alterac Valley" (verify) | M **Done:** reinforcements removed (patch 2.3.0's), docs/FORMULAS.md "Battlegrounds". |
| alterac.d:ending | End-of-match honor/rep per surviving tower/captain/node/mine | EndBattleGround | Wowpedia "Alterac Valley" (verify) | M. **Left, reported:** the end-of-match honor for towers/captains is 2.3.0's |
| warsong.d:capture / ending | 3 captures; honor and rep per capture | EventPlayerCapturedFlag | Wowpedia "Warsong Gulch" (verify) | M; **Done: the honor units; not the reputation** (FORMULAS.md "Honor"). **Done: the reputation** 35, 45 on the holiday, agrees (WoWWiki "Warsong Gulch" 2006-11) |
| warsong.d:tick / flags | Dropped flag returns after 10 s; respawn 23 s | BG_WS_FLAG_DROP_TIME | Wowpedia "Warsong Gulch" (verify) | M |
| arathi.d:objectUsed / taken | Base captured 60 s after assault | BG_AB_FLAG_CAPTURING_TIME | Wowpedia "Arathi Basin" (verify) | M |
| arathi.d:tick (rewards) / ending | Honor per 260 resources, rep per 160; end bonuses | BattleGroundAB::Update | Wowpedia "Arathi Basin" (verify) | M; **Done: the honor units; not the reputation** (FORMULAS.md "Honor"). **Done: the reputation** every 200 (150 holiday; was 160/120) |
| meetingstone.d:rolesOf / priorityOf | Class role priorities | vmangos LFGMgr::CalculateRoles | none found | M: vmangos invention |
| meetingstone.d:update / fillRoles | 1 tank + 1 healer + 3 damage; queue rules | vmangos LFGQueue::Update | Wowpedia "Meeting Stone" (verify); LFGDungeons (DB2) for levels | M |
| teleport.d:teleportTo (raid lock) | Bound to a different raid copy → refused | InstanceMap::CanEnter | none found | M |
| context.d:raidResetAt / nextRaidReset | All raids reset together at 04:00 every reset_delay days (default 7) | MapPersistentStateMgr | MapDifficulty.ResetInterval (DB2), patch 1.9.0 days | M. **Done:** FORMULAS.md "Raid resets" (the old data already agreed) |
| context.d (dungeon reset) | Dungeon resets when empty for 1800 s | InstanceMap unload | none found | M |
| creatureai.d:attackStart | AGGRO_ZONE flag: pulled in dungeon → zone-wide combat | CREATURE_EXTRA_FLAG_AGGRO_ZONE | none found | L |
| battleground.d:playerKilled | HK to teammates within 74 yd | HandleKillPlayer | none found | L |
| battleground.d:tick / start | Start delay 2 min; countdown 1 min / 30 s | BattleGround::Update | Wowpedia BG pages (verify) | L |
| battleground.d:offlineLimit | Logged-out member removed after 300 s | MAX_OFFLINE_TIME | none found | L |
| battleground.d:closeIfEmpty | Empty copy closes after 5 s | BattleGroundMap::Update | none found | L |
| battleground.d:joinBattlegroundAsGroup | Group queue checks | CanJoinBattleGroundQueue | BattlemasterList.MaxPlayers | L |
| battleground.d:canTalkToBattlemaster | Level range check | CanInteractWithBattleMaster | BattlemasterList MinLevel/MaxLevel; PVPDifficulty | L |
| battleground.d:ctor weekend | Call to Arms holidays switch reward tables | CMaNGOS BG weekend | Holidays (verify) | L |
| battleground.d:portIn | Dead player entering BG revived | SendToBattleGround | none found | L |
| bgqueue.d:queueSlots / averageWait | 3 queues; average of last 10 | PLAYER_MAX_BATTLEGROUND_QUEUES | none found | L |
| alterac.d:prematureWinner | More reinforcements wins | GetPrematureWinner | none found | L **Done:** reinforcements removed (patch 2.3.0's), docs/FORMULAS.md "Battlegrounds". |
| teleport.d:lockStatus | Instance entry requirements; Halls need rank 6 | GetAreaTriggerLockStatus | Map.dbc; areatrigger_teleport is emulator data | L |
| teleport.d:teleportTo (max players) | Copy full at instance_template max players | InstanceMap::CanEnter | MapDifficulty.MaxPlayers (DB2) / Map.dbc | L |
| teleport.d:updateRaidReset | Raid reset warnings 60/15/5/1 min | RAID_INSTANCE_MESSAGE | none found | L |

### Movement/environment (20)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| environment.d:breathingInterval | Breath 60 s × MOD_WATER_BREATHING; water breathing unlimited | GetWaterBreathingInterval | Wowpedia "Breath" (page exists) | H. Checked: WoWWiki "Breath" (2006-11) gives no length (Undead "three times longer" is their aura); kept |
| environment.d:suffocationDamage | Drowning/fatigue damage maxHP/5 + rand(0..level−1) per 2 s | OnMirrorTimerExpirationPulse | Wowpedia "Breath" (verify %); EnvironmentalDamage.dbc holds visuals only | HH. **Checked 2026-11-28 against CMaNGOS** (`OnMirrorTimerExpirationPulse`): the same (`GetMaxHealth() / 5 + urand(0, level - 1)`, its own "TODO: Check this formula"; a 2 s pulse once the 60 s bar is out) |
| environment.d:environmentalDamage (lava) | Lava: 1 s delay, then 605–610 fire every 2 s, partially resisted | EnvironmentalDamage config | Wowpedia "Lava" (verify) | HH. **Checked 2026-11-28 against CMaNGOS:** the same (`MirrorTimer.Environmental.Max` 1 s, then the 2 s pulse; `EnvironmentalDamage.Min/Max` 605/610; fire absorb and resist; slime's damage commented out there too) |
| environment.d:fallDamage / landed | Safe under 14.57 yd; dmg = (0.018×(h−safe) − 0.2426)×maxHP | Player::HandleFall | Wowpedia "Fall damage" (page exists) | H. Checked: WoWWiki "Fall damage" (2006-09) has no formula; Safe Fall's -17 is data; kept |
| moveorders.d:speedRate | Speed = strongest increase × max(stacking always, non-stacking); swim; strongest decrease; caps | Unit::UpdateSpeed | none found | H: every move |
| crowdcontrol.d:walkOn / updateCrowdControl | Fear: 10 yd away ±0.6 rad at run speed; confuse 3–6 yd random at walk speed | Fleeing/ConfusedMovementGenerator | none found | M: visible |
| death.d:setGhost + moveorders.d:refreshSpeeds | Ghost run/swim ×1.25 (wisp ×1.5), water walk; hard-coded instead of from the auras | HandleAuraGhost; spells 8326/20584 | Spell.dbc 8326 and 20584 effect base points | M: copy of data |
| environment.d:mirrorTimerStarts (fatigue) | Fatigue 60 s in deep water | MirrorTimer Fatigue | Wowpedia "Fatigue" (page exists) | M |
| environment.d:MirrorTimer.update | Refill ×10; 2 s pulse after expiry | MirrorTimer | none found | M |
| environment.d:updateLiquidSpell (slime) | Slime does no damage; LiquidType spell cast while in liquid | UpdateTerainEnvironmentFlags | LiquidType.SpellID (DBC/DB2) | M: slime choice is CMaNGOS's |
| environment.d:environmentChanges | Swim depth = floor + 0.75 × collision height; water cancels mounts | UpdateTerainEnvironmentFlags | none found | M |
| environment.d:FallStart.moved / trackFall | Fall start = highest Z since landing | UpdateFallInformationIfNeed | none found | M |
| effecthandlers.d:leapEffect | Blink 2 yd steps; slope >50°, 10 yd drop, LoS stops | FRONT_LEAP target | Spell.dbc radius | M |
| creaturecasting.d:updateControlledWalk | Creature fear ~10 yd steps ±0.6 rad; confuse 3–6 yd | Fleeing/ConfusedMovementGenerator | none found | M |
| taxi.d:flightSpeed | 32 yd/s | PLAYER_FLIGHT_SPEED | none found (measure) | M |
| environment.d:fellUnderMap | Below z −500 killed and released | HandleMoverRelocation | none found | L |
| creatureai.d:chase | Move to reach−1, re-path when target moved ≥1 yd | ChaseMovementGenerator | none found | L |
| creaturelinking.d:formationPlace | Formation spread 2 yd, layouts | spawn_group_formation | none found | L |
| weather.d:Weather.regenerate | Weather changes every 10 min with fixed transition odds | Weather::ReGenerate | Weather (DB2) visuals only; none found for odds | L: cosmetic |
| weather.d:seasonOf | Season = (dayOfYear − 78)/91 | Weather seasons | none found | L |

### Economy (32)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| death.d:playerDied | Killed by a creature: 10% durability on worn gear; PvP deaths none | KillPlayer → DurabilityLossAll(0.10) | Wowpedia "Durability" (page exists) | H: every PvE death. **Done:** agrees; also drowning/fatigue/lava deaths now cost it (FORMULAS.md "Durability") |
| itemuse.d:wearOnHit | Each hit dealt/taken: 0.5% chance a random slot loses 1 durability | DurabilityLossChance.Damage | Wowpedia "Durability" (verify) | H: constant in combat |
| durability.d:durabilityLoss / durabilityPointsLoss | % loss = floor(max×pct), ≥1 pt; at 0 the item's stats go | DurabilityLoss, DurabilityPointsLoss | Wowpedia "Durability" (page exists) | M |
| environment.d:environmentalDamage (died) | Fatal fall costs 10% durability; others none | Player::EnvironmentalDamage | none found | M. **Done:** every environmental death but the fall through the world (WoWWiki "Death": only PvP and self-inflicted are free) |
| pethandlers.d:petUntrainCost | Untrain 10 s first, then 50 s, 1 g, +1 g, max 10 g | Pet::resetTalentsCost | Wowpedia "Pet trainer" (verify) | M |
| questhandlers.d:rewardQuest | At max level RewMoneyMaxLevel paid as money | RewardQuest | QuestMoneyReward (DB2) | M |
| reputationhandlers.d:reputationPriceDiscount | 10% off at Honored; +10% at PvP rank ≥3; repair −5%/−5% by rank | GetReputationPriceDiscount | Wowpedia "Reputation", "Honor system (pre-2.0 formulas)" (verify) | M |
| npchandlers.d:sendTrainerList / handleTrainerBuySpell | Lesson cost × discount; availability by level/race/class/rank/skill | GetTrainerSpellState | SkillLineAbility; trainer data is emulator DB | M |
| talenthandlers.d:talentResetCost | 1, 5, 10 g then +5 g to 50 g; −5 g per 30 days | resetTalentsCost | Wowpedia "Respec" (page exists; verify classic section) | M. **Done** in part: +5 g a reset to 50 g agrees (WoWWiki "Talent" 2006); the first steps and the decay no source |
| inventory.d:Item.sellPrice | SellPrice prorated by charges, minus base repair cost | Item::GetSellPrice | none found | M: damaged items sell for less |
| itemhandlers.d:handleRepairItem | Repair discount 10% at Honored; PvP rank discounts | DurabilityRepair | Wowpedia "Repair" (verify) | M |
| itemhandlers.d:buyItemFromVendor | Price × discount; reputation and honor-rank requirements | BuyItemFromVendor | Wowpedia "Honor system (pre-2.0 formulas)" (verify) | M |
| auctionhouse.d:auctionDeposit | Deposit = SellPrice × count × (duration/2 h) × deposit% | AuctionHouseMgr deposit | AuctionHouse.dbc depositPercent | M: no minimum. **Done:** the 2-hour base rounded down, then times the spans (WoWWiki "Auction House" 2006); AuctionHouse.dbc 5/25% |
| auctionhouse.d:AuctionRecord.outBid | Minimum raise 5% (integer steps) | GetAuctionOutBid | Wowpedia "Auction House" (verify) | M |
| auctionhandlers.d:handleAuctionRemoveItem | Cancel costs the cut; deposit kept | AuctionHouseHandler | Wowpedia "Auction House" (verify) | M. **Done:** agrees (deposit + cut of the bid) |
| auctionhouse.d:auctionHouseFor | Hard-coded faction template → house table | GetAuctionHouseEntry | AuctionHouse.dbc, FactionTemplate | M |
| context.d:auctionSold / auctionMail | Sale mail delay 1 h only when mail has no item/money (looks reversed) | SendAuctionSuccessfulMail | Wowpedia "Auction House" (verify) | M. Mail from the AH "arrives immediately, even with items" (WoWWiki "Mail"): not changed here (another agent's area), left |
| mailhandlers.d:handleSendMail | Postage 30 c; COD only with item; 1 h delay to other accounts | MailDraft::SendMailTo | Wowpedia "Mail" (verify) | M. **Done:** money alone and returned mail at once, items an hour (WoWWiki "Mail"); postage none found |
| context.d:postMail / settleOldMail | Mail expires 30 days (3 with COD); money-only mail deleted | not in PROVENANCE | Wowpedia "Mail" (verify) | M. **Done:** read: 3 days left; expired money mail returned (was lost); COD's 3 days none found |
| durability.d:durabilityDamageEffect | DURABILITY_DAMAGE(_PCT) by slot misc value | EffectDurabilityDamage(PCT) | Spell.dbc EffectMiscValue/BasePoints | L: data-driven |
| itemuse.d:takeCastItem / hasChargesLeft | Charge consumption; negative charges destroy | TakeCastItem | none found | L |
| creature.d:VendorStock | Limited items restock per incrTime | GetVendorItemCurrentCount | none found (npc_vendor data) | L |
| npchandlers.d:canSeeVendorItem | Hide BoP of other classes, wrong race | CanSeeVendorItem | none found | L |
| inventory.d:baseRepairCost / repairCost | Repair = lost durability × DurabilityQuality × DurabilityCosts | CalculateDurabilityRepairCost | DurabilityCosts, DurabilityQuality (DBC/DB2) | L: matches data. **Done:** data-driven, unchanged |
| itemhandlers.d:handleSellItem / inventory.d:addToBuyback | 12 buyback slots, 30 h | AddItemToBuyBackSlot | Wowpedia "Buyback" (verify) | L |
| itemhandlers.d:handleBuyBankSlot | Bank slot price | HandleBuyBankSlotOpcode | BankBagSlotPrices (DBC) | L: matches data |
| auctionhouse.d:handleAuctionSellItem | Durations 2/8/24 h; no conjured/timed items | MIN_AUCTION_TIME | Wowpedia "Auction House" (verify) | L. **Done:** 2/8/24 h agree (WoWWiki "Auction House") |
| auctionhouse.d:AuctionRecord.cut | Cut = cutPercent × bid | AuctionHouseMgr cut | AuctionHouse.dbc cutPercent | L. **Done:** agrees (5/15%) |
| auctionhandlers.d:handleAuctionPlaceBid | Bid rules | AuctionHouseHandler | none found | L |
| mailhandlers.d:handleMailTakeItem / delete | COD payment; mailbox 10 yd; list 50 | MailHandler | none found | L |
| money.d:Copper.max | Money cap int.max | not in PROVENANCE | 1.12 client field | L |
| taxi.d:planFlight / activateTaxiPathTo | Fare = Σ TaxiPath.price × discount (10% at Honored) | ActivateTaxiPathTo | TaxiPath.dbc price | L |

### Other (25)

| where | what | emulator origin | primary source | risk |
|---|---|---|---|---|
| auras.d:stacksAcrossCasters | Per-aura-type rules for whether one spell from two casters coexists; ids 5320, 15366 exempt | SpellStacker::IsSpellStackableWithSpellForDifferentCasters | SpellAuraOptions.CumulativeAura (partial); SpellMisc Attributes | H: raid buff/debuff stacking |
| auras.d:AuraSet.apply / displacedBy | Same caster refreshes; stack +1 to StackAmount; non-stacking replace other caster's | AddSpellAuraHolder | SpellAuraOptions.CumulativeAura | H |
| spells.d:spell_template | Whole spell rows from CMaNGOS's spell_template (emulator-edited DBC copy), not Spell.dbc | CMaNGOS world DB | Spell.dbc (1.12, present in data/dbc) | H: every spell number; diff against Spell.dbc |
| auras.d:maxAuras | 32 positive + 16 negative slots; 17th debuff gets none | MAX_AURAS | 1.12 client update fields (UNIT_FIELD_AURA) | M: raid debuff cap |
| aurahandlers.d:updateAreaAuras | Party area auras refreshed every 1 s for group members in radius | AreaAura update | SpellRadius.dbc | M |
| spells.d:spell_learn_spell | Spells taught with a spell; LEARN_SPELL auto-learn rules | LoadSpellLearnSpells | Spell.dbc learn effects; no SpellLearnSpell DB2 | M |
| worlddata.d:spell_facing / spell_proc_item_enchant | Facing requirement per spell; enchant PPM | CMaNGOS tables | SpellCastingRequirements.FacingCasterFlags (1326 rows set); SpellItemEnchantment | M |
| death.d:selfResurrectionSpell | Twisting Nether (23701) gives self-res 10% of the time | GetResurrectionSpellId | Spell.dbc 23701 (verify proc chance) | M: 10% is the emulator's |
| map.d:MapSettings | Visibility 100 yd; re-check after 10 yd; stealth re-check 1 s | visibility config | none found | M |
| wareffort.d:resources table | 30 War Effort resource goals | CMaNGOS WorldState | Wowpedia "Ahn'Qiraj War Effort" (verify) | M |
| wareffort.d:enter / advance / ringGong | Phases: 5-day transport, gong, 10-hour war | HandleWarEffortPhaseTransition | Wowpedia "Ahn'Qiraj War Effort" (verify) | M |
| combat.d:seesThrough | Invisible if summed invisibility > strongest detection of the type | CanDetectInvisibilityOf | Spell.dbc EffectBasePoints | L |
| spells.d:spell_chain | Ranks from Talent.dbc, SkillLineAbility, then spell_chain; hard-coded Herb Gathering 2366→2368 | SpellMgr chain loading | SkillLineAbility.SupercedesSpell (DBC/DB2) | L |
| mounting.d:usableMounted | Which GOs are usable mounted | IsUsableMounted | none found (GO data) | L |
| effecthandlers.d:stuckEffect | Stuck: ghost → graveyard; else hearthstone; else 10 yd | EffectStuck | none found | L |
| spellhandlers.d:summonCompanion | Companion follows 2 yd; recast dismisses | EffectSummonCritter | none found | L |
| npchandlers.d:interactableNpc | NPC range 5 yd + reaches; GO gossip 10 yd | INTERACTION_DISTANCE | none found | L |
| inworld.d:handleInspect | Inspect within 28 yd | inspect distance | none found | L |
| inworld.d:whisper | Same-faction whispers | Player::Whisper | none needed (client) | L |
| gameobjecthandlers.d:useGameObject | Goober quest credit; spellcaster party-only and charges | GameObject::Use | none found (GO data) | L |
| gameobjecthandlers.d:sitOnChair | Nearest chair slot | CHAIR | none found | L |
| inventory.d:keyringSize | Keyring slots by level [4,4,4,4,8,12,12] | GetMaxKeyringClientSize | Wowpedia "Keyring" (verify) | L. **Done:** 4 to level 40, 8 to 50, 12 to 60 (Blizzard 1.11; it gave 8 at 40, 12 at 50) |
| taxi.d:taxiMountCreature | Mount by node and team | GetNearestTaxiNode | TaxiNodes.MountCreatureID | L |
| wareffort.d:pileTier | Pile tiers at 10/30/50/70/90% | GetResourceTier | none found | L |
| wareffort.d:daysLeft | Days shown = ceil(remaining/86400) | GetDaysRemaining | none found | L |
