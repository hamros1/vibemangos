# Formulas

The 1.12.1 client's data (DBC files, the world database) says what a spell does; the server's formulas, which Blizzard
kept on its servers, are not in it. This file lists each formula dmangos uses that is not in the data. For each one
it gives the source: Blizzard's own data or statements first, then documented research on 1.12. Emulators (CMaNGOS,
vmangos) are only a second opinion, compared after an implementation is tested. Where a formula's source is an
emulator, it says so and is a candidate to replace.

## Spell power coefficients

**What:** the share of the caster's spell power (`MOD_DAMAGE_DONE` for the spell's school, `MOD_HEALING_DONE`, and
spirit's share via `MOD_SPELL_*_OF_STAT_PERCENT`, each stack counted) that a spell effect adds. For an effect over
time the share applies to each tick.

**Source: Blizzard's data.** Classic Era's client data (SpellEffect.db2, `EffectBonusCoefficient`) has the coefficient
of every effect. Classic Era was built from the 1.12 game data, and its values are the known 1.12 ones:

- Frostbolt is 0.814, its cast time's 3/3.5 less the slow's share.
- Shadow Word: Pain rank 1 is 0.067 a tick: 1.0 for its 18 seconds, less the level penalty (0.4), over 6 ticks.
- Absorbs (Power Word: Shield, Ice Barrier, Mana Shield) are 0: absorbs took spell power only from 2.0 on.

`tools/fetch-coefficients.py DATA_DIR` takes them from the public export of that table (wago.tools, one pinned build)
into `DATA_DIR/coefficients.csv`, beside `dbc/`. It is Blizzard's data, so it is not committed. The server
(`ClientData.spellCoefficients`, `bonusCoefficient` in world/spellcast.d) uses an effect's coefficient only where
Classic Era has the effect as 1.12 has it (same effect and aura type).

**Fallback, without the file or for a rebuilt effect:** the 1.12 rules as Blizzard described them (cast time over 3.5,
1.5 to 3.5 seconds; over time, duration over 15 seconds, at most whole, shared by the ticks), less 3.75% a level for
spells learned before level 20.

**What the data showed that we had wrong (2026-11-20):**

- Holy Light's first three ranks heal by spells of their own (19982, 19981, 19980: 0.205, 0.339, 0.554). Every rank
  had used 19968's 0.714.
- Mana Shield got half the spell power, and Seal of Righteousness and Flametongue Weapon a share by weapon speed, on
  top of what every spell got. The data gives Mana Shield none, and the proc spells a flat 0.1 (Seal of
  Righteousness's less below level 20).

**Still from an emulator (to replace when a primary source is found):** Seal of Righteousness's base damage by weapon
speed (`sealOfRighteousnessAmount`, CMaNGOS's formula). Flametongue's base damage by weapon speed.

## Experience

**What:** the experience of a kill, how a group shares it, and rest (experience.d, loothandlers.d `rewardAtKill`,
exploration.d `giveXP`, player.d `setRestBonus`/`computeRest`).

**Source: documented 1.x research, and Blizzard's data for rest.** Wowpedia "Mob experience" (its pre-4.0.3 text;
4.0.3 changed the base to the creature's level) and "Experience point", "Rest"; the 1.12.1 client's Exhaustion.dbc.

- **Base:** a creature of the player's level gives `5 × level + 45` (the player's level), 5% more a level above it
  ("verified up to +4 levels"), and below it `base × (1 − difference / ZD)`, ZD 5 (levels 1–7), 6, 7, 8, 9, 11
  (20–29), 12, 13, 14, 15, 16, 17 (60). The page's duo example: a level 35 on a level 30, "MXP = 128".
- **Grey:** levels 1–5 none; 6–39 `level − level/10 − 5`; 40–60 `level − level/5 − 1`. At 60 that is 47: "The Gray
  Level for a level 60 character changed from the previously known 47 to 51" with the Burning Crusade. The same
  grey decides honor and reputation (it was 51 at 60 for kills here, and a second table for reputation and honor).
- **Elites:** "Elite XP = 2 × XP". In five-player instances 2.5 ("Mobs in 5-man instances give slightly more XP";
  "elites in instances give 2.5 × XP when solo-ed", one player's note).
- **Groups:** a party's total is the solo experience of its highest member to whom the creature is not grey, times
  1, 1, 1.166, 1.3, 1.4 for one to five members, shared by level ("XP1 = MXP × CL1 / (CL1 + CL2)"); a member to whom
  it is grey gets none.
- **Rest:** "One bubble of rested XP (5% of your current level) is earned for every 8 hours spent resting. A maximum
  of 30 bubbles (150% of your current level)"; logged out outside an inn or a city, "a quarter of the speed".
  Exhaustion.dbc's Rested row agrees (InnHours 8, Factor 2). A kill gives as much again ("Rested XP = 2 × XP"), "never
  exceed[ing] the amount of future XP points stored", and "the amount of rested bonus consumed is equal to the total
  amount of XP gained". The server keeps the bonus left, half that distance: the client shows
  `PLAYER_REST_STATE_EXPERIENCE` doubled, its rested mark up to a level and a half on (CMaNGOS's note, "Client
  automatically double the value sent"; client behaviour, kept).

**What changed (2026-11-20):** elites gave 2.5 everywhere but raids (open-world elites 25% too much: Hogger to a
level 11, 250 for 200). Level 60's grey was 51 for kills and procs and 47 for honor and reputation; now 47 for
all. Rest already followed the sources (now in experience.d, `restEarned`, `restCap`, `restedBonus`).

**Still from an emulator (no source found):** a raid group's rate, `1 − 0.05 × members` (Wowpedia: "Raid-sized
groups dramatically decrease experience gained (the party bonus does not apply)", no numbers); elites in raids
×2; the experience of the members below a highest member to whom the creature is grey (half, plus one); the
74-yard share distance; the pet's half; `exploration_basexp`.

**Second opinion (CMaNGOS-classic, compared afterwards):** elites 2.5 outside raids (`XP::Gain`: `IsNoRaid`), against
the source's 2 in the open world; 51 as grey at 60 (`GetGrayLevel`) beside 47 for `IsTrivialLevelDifference`, against
the source's 47 for both; rest the same (`ComputeRest`, `GetXPRestBonus`, `SetRestBonus`); group shares the same
(`RewardGroupAtKill_helper`).

## Quest experience

**What:** the experience a quest gives (quests.d `questXp`).

**Source: Blizzard's 1.12 quest data, Wowpedia for the falloff.** A quest's money at the highest level
(`RewMoneyMaxLevel`) is 60% of its experience in copper: Wowpedia's pages of 1.x quests give both, e.g. Shipment to
Stormwind "800 (or 4s 80c at max level)". Five levels above the quest its experience falls to 80%, 60%, 40%, 20%,
and 10% from ten above, `ROUND(Full_Quest_XP × p / 5) × 5` (Wowpedia "Experience point", "Quest XP"). A quest of no
level is of the player's (`QuestLevel` −1).

**Classic Era's QuestXP (DB2) and the difficulty index.** QuestXP gives a quest's experience by its level and a
difficulty index 1–7 (level 60: 660, 1650, 3300, 4950, 6600, 8300, 9950); the index is server data, in no DB2.
It can be derived: for 2807 of the 3492 quests with money and a level, money / 0.6 is a QuestXP cell of the
quest's level (index 5 is the most common, 1169 quests), so that index is the cell's. For the other 685 the
nearest cell is a rounding step off (Bounty on Garrick Padfoot: 340 against the table's 335; Brotherhood of Thieves
360 against 355; Report to Goldshire 230 against 225), and Wowpedia's 1.x pages give the 1.12 numbers, money /
0.6: 340, 360, 230, 800. Classic Era re-rounded the values in its table, so the per-quest 1.12 value is used and
QuestXP is not fetched. (One page, The Stockade Riots, gives 2350, the table's, against money's 2650: its level-70
money shows a later revision.)

**Second opinion (CMaNGOS-classic):** `Quest::XPValue` is the money over 0.6 too (ceil, and the later expansion's
divisors above 60), with `ceil` for the falloff and level 0 for a quest of no level.

**What changed (2026-11-20):** the falloff was `ceil(full × p)` (272 for 340's 80%, now 270); quests of no level gave
nothing (Desert Survival Kits: 650 now); levels 61 and up divided the money by 1.2–6 (a later expansion's ratios,
gone: no 1.12 quest gives experience above 60).

## Honor

**What:** honor for kills and battlegrounds, the weekly standing (honor.d, honorweek.d, battleground.d
`bonusHonor`, and the battlegrounds' bonus units).

**Source: documented 1.x research and Blizzard's statements.** Wowpedia "Honor system (pre-2.0 formulas)" (with
Blizzard's Official Honor Guide among its references), "Civilian".

- **A kill:** by the victim's rank, at 60: 198, 210, 221, 233, 246, 260, 274, 289, 305, 321, 339, 357, 377, 398
  (ranks 1–14, "CP for Kill (1.8+)"). By level: "The BHU is determined by the CP that would be awarded to the
  highest level in the range, if they made an honorable kill on a Rank 1 target": 24 (19), 41 (29), 68 (39), 113
  (49), 189 (59), 198 (60). Between those levels by the same ratio a level (each ten levels are about 0.6 of the
  next); below 19, by 19–29's.
- **The same victim:** "Within a 24 hour period you will only get credit for 10 HKs against a given player",
  100%, 90% … 10%, then nothing.
- **Shared:** "The CP per HK are divided among all the groups that caused damage".
- **Grey:** the experience grey (47 at 60, see Experience).
- **Dishonorable kills:** a civilian of the other side, any level ("a type of NPC that would garner a dishonorable
  kill if killed"); rank points by the killer's level: 10 to 29, 11.5, 13, 14.5, 16, 17.5, 19, 21, 23, 25, 27, 29,
  31, 34.2, 37.4, 40.7, 43.9, 47.1, 50.3, 53.6, 56.8, 60, 64, 68 … 100 at 60.
- **Battlegrounds:** each objective is worth bonus honor units of the bracket's value above (Alterac Valley's
  51–60: 198). Warsong Gulch: 2 a capture, 1 for the win; on its holiday 3 more to both and 2 more to the winner.
  Arathi Basin: 1 each 330 resources (200 on its holiday), 1 for the win. Alterac Valley: the general 4; a
  captain, a tower destroyed, a tower or the captain left standing at the end, 1 each.
- **The week:** the 1.12 breakpoints of the standing, 0.003, 0.008, 0.020, 0.035, 0.060, 0.100, 0.159, 0.228,
  0.327, 0.436, 0.566, 0.697, 0.845, 1 (group 14 to 1), at 12,000 … 400, 0 rank points and 13,000 for the top;
  20% decay, a loss halved and at most 2500; 15 kills to stand; ranks at 2000 and `(rank − 2) × 5000`.

**What changed (2026-11-20):** a kill was CMaNGOS's level formula (160 for a level 60 on a level 60 of no rank,
now 198; 55 at 20, now 25), capped at 400, and none for the tenth kill (now 10%); battleground units were 15 at
every level (CMaNGOS's later honor curve at 60), now 24 to 198 by bracket; Arathi Basin gave a unit each 260
resources (160 on its holiday) and one to both sides at the end; Alterac Valley's captain and towers gave 2–3
units; Warsong Gulch's holiday gave the winner 3 and the loser nothing; dishonorable kills counted only grey
civilians; level 50's penalty was 59.8; the standing used the breakpoints before 1.12.

**Second opinion (CMaNGOS-classic):** `MaNGOS::Honor::HonorableKillPoints` (a formula by both levels and both
ranks' points, capped at 400) and `hk_honor_at_level` (15 a unit at 60) disagree with the documented tables;
`IsCivilianForTarget` counts only grey civilians; AB's 260/160 resources; the standing's pre-1.12 breakpoints.

**Still from an emulator (no source found):** the victim's level over the killer's when they differ (the sources
give equal levels only); a victim of no rank as rank 1; the 74-yard share and equal shares within the group (the
page notes a group bonus from three members, "contrary to official Blizzard statements", without numbers); a
racial leader's 398 (one report gives Thrall 488); the rank-point caps below 60 ("Level Limits") are not
applied.

## Reputation

**What:** reputation from kills (loothandlers.d `rewardAtKill`, reputationhandlers.d `reputationGain`).

**Source:** Wowpedia "Reputation": "Grey mobs used to give 20% of the normal reputation until the release of Patch
3.0.8" (whose note: "Reputation rewarded for killing mobs will no longer automatically decrease"). A group's kill:
each member near it gets the reputation as alone; players' reports from Classic Era ("it works the same as solo",
"you still get positives in a Raid", "You have to be near mob when it dies"), no Blizzard statement found.

**What changed (2026-11-20):** grey kills tapered from 80% by a fifth a level to 20% (Captain Keelhaul to a level 60:
20 of its 25 Booty Bay, now 5); a group's kill in the open world gave each member `1/n` of it (full in dungeons), now all
of it to each.

**Second opinion (CMaNGOS-classic):** `RewardGroupAtKill_helper` gives `1/count` outside dungeons (as dmangos did);
`CalculateReputationGain` tapers grey kills by a fifth a level down to `Rate.Reputation.LowLevel.Kill`.

**Still from an emulator (no source found):** quests five levels below the player losing a fifth a level, down to
20%; a team faction getting half of a kill's reputation; `reputation_spillover_template` and
`reputation_reward_rate`.
