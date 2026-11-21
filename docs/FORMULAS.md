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

## Damage by weapon speed: Seal of Righteousness, Flametongue

**What:** the holy damage Seal of Righteousness adds to a swing, and the fire damage of a Flametongue Weapon or Totem
hit, by the speed of the weapon.

**Source: the 1.12 tooltips (Blizzard's own expressions in Spell.dbc).** Seal of Righteousness rank 8's description
says "an additional `$/87;20286s3` to `$/25;20286s3` Holy damage. Slower weapons cause more", and Flametongue Weapon's
"`$/77;16344m1` to `$/25;16344M1` additional Fire damage, based on the speed of the weapon": the amount divided by 100
over the speed, from the fastest weapon (1.15 and 1.3 seconds: 100/87, 100/77) to the slowest (4.0: 100/25). So each
is the amount times the speed in seconds, over 100 (`sealOfRighteousnessAmount`, `flametongue` in world/classspells.d;
a fist swings at 2.0). Rank 8's 1786 is 20.5 a swing with a 1.15 weapon, 71.4 with a 4.0 one. Spell power comes on top
by the damage spell's own coefficient (above).

Until 2026-11-20 Seal of Righteousness used CMaNGOS's formula (0.85 of the amount by 1.2 * 1.03 for a one-handed
weapon, 1.2 for a two-handed one, plus 3% of the weapon's damage), which matches measurements of the Burning Crusade
(warcraft.wiki.gg's talk page on the seal), not the 1.12 tooltip; Flametongue was already the tooltip's.

## Seal of the Crusader's slower damage

**What:** its swings are 40% quicker (its second amount) and each deals 1/1.4 of its damage, so its damage a second
stays (`crusaderDamageFactor`). The tooltip says only "deals less damage with each attack". **Source: CMaNGOS**
(`spell_seal_of_the_crusader`); a candidate to replace.

## Holy Shield's threat

**What:** its damage causes 20% more threat. **Source: the tooltip** ("Damage caused by Holy Shield causes 20% additional
threat"). The world database's `spell_threat` (flat 20, 30, 40 for the ranks) is not used.

## Eye for an Eye

**What:** a spell's crit against the paladin deals 15% (30% at rank 2) of its damage back as holy damage (25997), at
most half the paladin's health. **Source: the tooltip** and the talent's amount.

## Totem enchantments

**What:** Flametongue Totem and Windfury Totem enchant the main hand weapons of the party within the spell's radius at
each of their periods (5 seconds), for two periods: the enchantment lasts while its bearer stays near. **Source: the
tooltips** ("enchants all party members' main-hand weapons with fire if they are within 20 yards"); how long one lasts
once out of reach is not said, and is this server's choice.

## A druid's attack power

**What:** a druid's melee attack power is its strength's (twice, less 20), none of its level; in Cat Form its agility's
too (`meleeAttackPower` in world/stats.d). The forms add their passives' amounts, which grow with the level as their
data has it (Cat Form's 40 at level 20, 2 more a level: 120 at 60), Predatory Strikes a share of the level in them (50,
100, 150%).

**Source: the tooltips** (Cat Form: "increasing melee attack power by 40 plus Agility"; Predatory Strikes: "by 150% of
your level") and documented 1.12 research (warcraft.wiki.gg's Attack Power page: a druid's base is Strength x 2 - 20).
Until 2026-11-20 a druid had a warrior's three a level as well.

## Heart of the Wild in the forms

**What:** its percent of stamina in Bear and Dire Bear Form, of strength in Cat Form: its effects of no amount of their
own, 24899 and 24900, by the talent's (`classFormPassives` in world/classspells.d). **Source: the tooltip** ("while in
Bear or Dire Bear Form your Stamina is increased by 20% and while in Cat Form your Strength"); the talent's own data has
only the intellect.

## Spell modifiers (talents) in the damage, the crit, the hit and the threat

**What:** where a talent's `SPELL_AURA_ADD_FLAT_MODIFIER` or `ADD_PCT_MODIFIER` (its misc value the property) comes in.

**Source: the talents' tooltips, on the data's own modifiers.** Each was tested on every rank of the mage's, the
warlock's and the priest's talents (source/dmangos/world/realclass_magewarlockpriest.d):

- `SPELLMOD_DAMAGE` (direct damage) and `SPELLMOD_DOT` (each tick) apply to the damage with the spell power's share
  in it: "Increases the damage done by your Fire spells by 10%" is of the damage done, not of the spell's base. The
  data gives the two to separate masks (Fire Power's damage mask and its damage over time mask), so a tick is not
  changed by the direct one. A drain's tick (`PERIODIC_LEECH`) is damage over time ("the damage dealt or life drained
  by your Shadow spells").
- `SPELLMOD_CRIT_DAMAGE_BONUS` changes the bonus, not the whole: Ice Shards' "critical strike damage bonus ... by
  100%" makes a spell's half again a whole again (double damage), Ruin's likewise.
- `SPELLMOD_RESIST_MISS_CHANCE` ("reduces the chance that the opponent can resist") is a hit chance more for the
  spell: Arcane Focus, Elemental Precision, Suppression, Shadow Focus.
- `SPELLMOD_THREAT` is a factor of the spell's threat (Shadow Affinity's "reduces the threat generated").
- `SPELLMOD_MULTIPLE_VALUE` of Mana Shield is its mana a point absorbed (Improved Mana Shield: 2 less 20%).
- A modifier's every stack counts (Combustion's 10% a fire spell).
- The slows' talents name the second effect (`SPELLMOD_EFFECT2`) where a spell's slow is its first (Frostbolt's,
  Cone of Cold's) or its only one (Curse of Exhaustion's): Permafrost, Improved Curse of Exhaustion and Amplify Curse
  "reduce the target's speed", so their amount goes to the slow, never to the damage (`classEffectMod`).
- Masks of the world database that leave out spells a tooltip names are completed by the tooltip
  (`world/tooltipmasks.d`): Arcane Instability's spell damage (the fire spells), Elemental Precision and Combustion
  (Blast Wave), Shadow Mastery (Death Coil; Curse of Doom's and Drain Soul's ticks), Suppression (Drain Soul).

## Ticks of a persistent area

**What:** Blizzard's, Rain of Fire's, Flamestrike's burn on the ground.

**Source: 1.12's rules and Blizzard's coefficients.** A tick is damage over time: it never crits (no periodic damage
crits in 1.12), it takes its effect's spell power coefficient (Classic Era's SpellEffect.db2, as every tick), and the
damage over time modifiers (Piercing Ice's on Blizzard). It procs as a tick (`tickProcs`), not as a spell's hit.

## Class rules from the tooltips

**Source: the tooltips (numbers filled in from the data where it has them).**

- Arcane Concentration: Blizzard's ticks (its rank's override script, mask Blizzard) may give Clearcasting, by the
  talent's own proc chance (2% a rank), a tick that hits.
- Fire Ward's and Frost Ward's reflection: their aura's amount (none) and their talent's dummy effect (Improved Fire
  Ward, Frost Warding: 10%, 20%) for a magic spell of the ward's school.
- Magic Absorption: a spell resisted whole gives back its first effect's share of the maximum mana (1% a rank), once a
  second at most (its `spell_proc_event` cooldown).
- Pyroclasm: 13% (rank 1) or 26% (rank 2) to stun (18093) a spell: a Soul Fire's whole, shared by Rain of Fire's
  ticks (its four) and Hellfire's (its fifteen), as the data gives their duration and period.
- Improved Drain Mana: 15% or 30% of the mana drained, as damage of Drain Mana's school (no crit: a tick's).
- Damage taken breaks a hold whose spell's proc flags take it ("Damage caused may interrupt the effect": Frost Nova,
  Fear, Psychic Scream, Howl of Terror, Frostbite), by its `ProcChance` (100 in the data): the first hit breaks it.
  CMaNGOS rolls a chance by the damage (damage / (25 × level − 150)); no primary source for either, and the project
  chose the data's (2026-11-20).
- Shadow Vulnerability (Improved Shadow Bolt) lasts its four charges, one a damaging hit of the kinds its proc flags
  take ("until 4 non-periodic damage sources are applied").
- Spirit of Redemption: the killing blow leaves the priest at 1 health in the spirit's form (27827, with 27792 and
  27795) for its 10 seconds; then the priest dies. Its holy spells cost nothing (27792's
  `MOD_POWER_COST_SCHOOL_PCT`, -100% for holy).
- Create Healthstone with Improved Healthstone: the stone whose own spell heals 10% or 20% more (the item data's
  stones 19004 to 19013).

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

## Crafting skill-ups

**What:** the chance that making a recipe raises its profession by one (enchanting.d `craftSkillChance`).

**Source: Blizzard's data for the levels, community research for the chance.** SkillLineAbility.dbc (1.12.1) gives
each recipe its yellow level (`TrivialSkillLineRankLow`) and grey level (`TrivialSkillLineRankHigh`); the client
colours it green from halfway between. Linen Bandage (3275): yellow 30, grey 60, so green from 45. Blizzard has said
only that orange always and grey never gives a point (Warcraft Wiki "Skill up", oldid 6686282: "The only certain
values are for Orange (guaranteed skillup) and Grey (no skillup)"). Between them the community's formula, used by
guides and skill-up calculators since 2008, is a chance falling evenly from yellow to grey:
`(grey − skill) / (grey − yellow)`. Linen Bandage at 45 is 50%, at 54 20%, at 59 3.3%.

**Old rule (CMaNGOS):** 75% anywhere in yellow, 25% anywhere in green. These are the averages of the linear chance
over each band, so a profession takes about as many crafts as before; the steps within a band are what changed.

**Weak point:** no Blizzard statement of the in-between chance was found; the formula is measured by players, not
published.

## Skinning

**What:** the skinning skill a creature asks for (professions.d `skinningSkillFor`), used both to allow skinning
(spellhandlers.d `checkSkinning`) and for the skill-up colours (`skinCreature`).

**Source: Wowpedia "Skinning"** (wowpedia.fandom.com, its table as search engines quote it; the page refused
automated fetches, and warcraft.wiki.gg's current revision, oldid 6919755, no longer has the table): skill 1 for
creatures of level 1–10, `10 × level − 100` for levels 11–20 (100 at 20), `5 × level` for levels 21–73 (300 at level
60). Classic Era guides give the same (skill / 5 is the highest level skinnable above 100). Gathering could fail
before patch 3.1.0 ("You can no longer fail when Mining, Herbing, and Skinning"), but no failure rate was found
(see RULES-AUDIT.md).

**Old rule:** two formulas. Allowing used the *player's* skill to pick the branch (`skill < 100 ? (level − 10) × 10 :
level × 5`), so a level 10 creature needed nothing at all and a level 25 creature 150 below skill 100 but 125 from it;
the skill-up used another (`level < 10 ? 0 : level < 20 ? (level − 10) × 10 : level × 5`).

## Fishing

**What:** catching and skill-ups (spellhandlers.d `useBobber`, professions.d `fishingSkillUpChance`).

**Sources:**

- Warcraft Wiki "Fishing" (oldid 6982255) on the system before patch 3.1.0: "there was a chance your fish could 'get
  away'; you would catch nothing and receive no skill-up for that cast". Patch 3.1.0's notes: "Fish can no longer get
  away", "There is no longer a minimum skill requirement to fish in any zone".
- Measured on Classic Era (Warcraft Tavern, "WoW Classic Fishing Guide 1-300"): "To fish without ever losing a fish
  requires a skill differential of 95 above the minimum"; pole and lure bonuses help against escapes but "don't change
  how you will skill up"; catches for a skill-up: 1 to 100, 2 at 100–115, 3 at 115–140, then one more every 25 points
  (10 at 290–300).

**Rule:** the catch chance is `skill − zone skill + 5` percent (5% at the zone's minimum, all from 95 above it), the
skill counting the pole's and lure's bonus. Only a catch may raise the skill, by one in `n` where `n` is 1 below 100
and `(skill − 90) / 25 + 2` (integer division) from 100, with the skill without bonuses.

**Old rule (CMaNGOS):** every cast, caught or not, rolled for a skill-up at `2500 / (skill − 50)` percent (all below
75), and the catch used the skill without the pole's or lure's bonus. The curve is close to the measured table; the
escapes giving skill and lures not helping were the errors.

**Still from an emulator:** the zones' minimum skills (`skill_fishing_base_level`, no Blizzard table), and the
linear 5%-to-100% catch chance between the minimum and 95 above it (only its ends are measured).

## Aggro radius

**What:** how near a player may come before a hostile creature attacks (creatureai.d `aggroRadius`).

**Source: Warcraft Wiki "Aggro radius"** (oldid 1536962): "roughly 20 yards" at the same level, varying "at a rate of
roughly 1 yard/level", a minimum of "combat range (5 yards)", and "capped at a maximum of 45 yards, that is, when the
mob is 25 or more levels higher than the player".

**Rule:** the creature's detection range (`creature_template.Detection`, 18 for nearly every creature) less the
levels its target is above it, at least 5 and at most 45 yards. A template whose own range is wider than 45 (a few
scripted creatures, 50 to 95 yards) keeps it. Mind Soothe's `MOD_DETECT_RANGE` applies after.

**Old rule:** the level difference was limited to 25, so a creature of range 18 reached only 43 yards, and one of 30
reached 55. **Not changed:** the database's 18 yards at the same level against the wiki's "roughly 20".

## Leash

**What:** how long a creature chases a victim it cannot hit before it gives up and evades (creatureai.d
`pursuitTime`, `updateCombatManager`).

**Sources:** measured on Classic Era (Warcraft Tavern, "Leash Behavior & Kiting Mobs"): about 11 s for creatures of
levels 1–29, 12 s for 30–39, 13 s for 40–44, 14 s for 45–49, 15 s for 50–60, by the lowest level the creature spawns
at; damage and other hostile actions start the time again, as does the creature's first melee hit after a chase.
Blizzard (Kaivax, 2019-10-23, on the leash fix for linked groups): "The bugfix to leash behavior of groups of enemies
makes the game behave like it did in original WoW."

**Rule:** the pursuit time by the template's least level, restarted by damage taken or dealt. **Old rule:** the
template's `Pursuit`, 15 s for every creature in the database (a default). **Not changed:** the 30 yards a victim
must be from where the time last started (the measurement says "roughly 10–15 yards", unsure), and no restart for
hostile spells that deal no damage.

## Evade

**Source: Warcraft Wiki "Evade"** (oldid 358501): an evading creature "becomes immune to any and all attacks and
spells" and "will regenerate health as though it was out of combat". dmangos already does this (no instant full heal;
the out-of-combat regeneration starts as it turns for home). The rate (a third every 5 seconds) has no source.

## Raid resets

**What:** how many days apart a raid's copies reset (context.d `raidResetDays`, `raidResetAt`).

**Sources:** Blizzard's data: Classic Era's MapDifficulty.db2 `ResetInterval` (build 1.15.9.70576): 2 for Molten
Core, Blackwing Lair, the Temple of Ahn'Qiraj and Naxxramas, 3 for Zul'Gurub and the Ruins of Ahn'Qiraj, 4 for Onyxia's
Lair, 0 for the dungeons. Patch 1.9.0's notes (Warcraft Wiki "Lockout", oldid 6566102) give the days: "Molten Core:
Every 7 Days", "Onyxia: Every 5 Days", "Zul'Gurub: Every 3 Days", "Ruins of Ahn'Qiraj (20-man): Every 3 Days", the
40-player raids every 7. So 1 is a day (the retail meaning), 2 a week, 3 three days, 4 five days.

`tools/fetch-instance-resets.py DATA_DIR` writes the table to `DATA_DIR/instance-resets.csv` (not committed);
`ClientData.resetIntervalDays` reads it. **Fallback without the file:** `instance_template.reset_delay`, which holds
the same days for the raids.

## Instances per hour

**What:** an account may go into at most five new dungeon or raid copies an hour (context.d `tooManyInstances`,
`instanceLimitReached`; teleport.d refuses with `TRANSFER_ABORT_TOO_MANY_INSTANCES`).

**Sources:** the 1.12.1 client's transfer-abort reason 3, "too many instances"; Blizzard (Kaivax, 2020-06-16, "New
Instance Limit in WoW Classic"): the new daily limit "complements the current limit of 5 instances per hour", "the
game checks to see if they have entered 5 instances in the last hour", "across all of your characters on your realm",
"These limits only apply to dungeon and raid instances, and do not apply to PvP battlegrounds". The daily limit of 30
came with Classic in 2020 and is not 1.12's.

**Rule:** going into a copy that is not one of the account's last hour's, with five of those already, is refused;
going back into one of them is not. Game masters aside. Kept in memory by each node: in a cluster, each node counts
the entries made from it.

## Warrior, rogue and hunter rules

**What:** what these classes' tooltips claim that the data does not compute (world/physicalclasses.d and the cast
pipeline; each tested in world/realclass_warrior_rogue_hunter.d). **Source: the 1.12.1 tooltips and the spell data**
(docs/spells/warrior.md, rogue.md, hunter.md); none from an emulator.

- **Crit damage bonus modifiers** (`SPELLMOD_CRIT_DAMAGE_BONUS`: Impale, Lethality, Mortal Shots): "increases the
  critical strike damage bonus by 20%" scales the bonus, not the damage: a melee or ranged crit's 100% more becomes
  120% (2.2 times the hit), a spell's 50% would become 60%.
- **Weapon abilities** take their crit chance modifiers (Improved Overpower, Improved Backstab, Cold Blood), their
  damage modifiers on the whole strike (Aggression: "increases the damage of your Sinister Strike by 6%"), and the
  damage done and taken auras a swing takes (Enrage's 25% more, Hemorrhage's 7 more).
- **Stances:** a stance ends the one before; changing stance loses the rage but what Tactical Mastery keeps ("You
  retain up to 25 of your rage points": 5 for each rank, its override script numbers 831 to 835 being ranks 1 to 5).
- **Last Stand:** 30% of the maximum health, granted as health too (its aura only, 12976), and taken back when it ends ("temporarily grants
  you 30% of your maximum hit points... After the effect expires, the hit points are lost").
- **Deep Wounds:** the share of the weapon's average damage over the bleed's 12 seconds, split over its ticks (12721:
  every 3 seconds, 4 ticks).
- **Unbridled Wrath, Mace Specialization:** the tooltip's flat chance ("a 40% chance", "a 6% chance": the spells'
  `ProcChance`), not the world database's spell_proc_event rate a minute (its 3-second proc cooldown is kept).
- **Shield Specialization:** its rank's `ProcChance` (20% to 100%) for the rage point at a block.
- **`MaxAffectedTargets`** (Intimidating Shout's "up to 5 total nearby enemies", Thunder Clap's "up to 4 targets"):
  the target aimed at, then the nearest.
- **Finishing moves' aura amounts** take `EffectPointsPerComboPoint` for each combo point as their direct damage does
  (Expose Armor's 340 armor a point, Rupture's 8 a tick a point).
- **Eviscerate's attack power:** 3% of it for each combo point. Its tooltip says only "increased by Attack Power";
  the share is documented 1.12 research and measured Classic Era behaviour (and agrees with what the server had,
  taken from CMaNGOS). **Rupture's:** 1% of it a tick for each combo point up to 3 (4%, 10%, 18%, 21%, 24% in all):
  the same research; also what the server had.
- **Add Target Trigger talents** (Relentless Strikes' "20% chance per combo point", Initiative, Improved Sprint)
  roll once for each unit the spell struck, the caster only when it struck no other (Eviscerate's dummy effect on the
  rogue is no second target).
- **Ruthlessness, Seal Fate:** their point after the finishing move, once (not also during it).
- **Serrated Blades:** the armor ignored is its effect's amount at the rogue's level (`EffectRealPointsPerLevel`:
  -1.67, -3.34, -5 a level: 100, 200, 300 armor at 60), off the victim's armor for every physical blow.
- **Hemorrhage:** each physical blow at its target uses one of its 30 charges.
- **Improved Poisons:** its chance modifier adds to the poison's chance on a hit (Instant Poison VI's 20%, 30% with it).
- **Improved Sap:** "return to stealth mode": the highest Stealth known, its cooldown ended (its trigger spell, 14093,
  is no stealth). **Improved Sprint:** its 30918 removes the movement impairing effects on the rogue.
- **Pathfinding:** its 3% and 6% on Aspect of the Cheetah's and the Pack's speed, the first effect (the talent's data
  names their second, the daze's trigger; the tooltip wins).
- **A creature's auras that damage ends** (`AuraInterruptFlags` 0x2: Wyvern Sting's "Any damage will cancel the
  effect", Sap, Freezing Trap, Blind) end at any damage it takes.
- **Improved Aspect of the Hawk:** Aspect of the Hawk's own chance (0) and the talent's modifier (1% to 5%) for Quick
  Shots on a normal ranged attack.
- **Entrapment:** procs only as a trap's effect lands (Immolation, Explosive and Frost Trap's: the tooltip's three,
  not Freezing Trap's), on each target; its higher ranks' other proc flags (any harmful spell) are not taken.

## Effects only a tooltip gives

Some auras do more than their 1.12 data has room for: Blizzard's server added the rest. Where the tooltip states it
plainly, `dmangos.world.tooltipeffects` adds it as a hidden effect of the aura, counted by the aura totals as if the
data had it, quoting the tooltip:

- Barkskin (22812): "Physical damage taken is reduced by 20%" and "melee combat is slowed by 25%". Its data has only
  the pushback immunity and the second longer casts.
- Demonic Sacrifice (18788): its data only kills the demon. What the warlock gets is its tooltip's, by demon: the Imp
  Burning Wish (18789), the Voidwalker Fel Stamina (18790), the Succubus Touch of Shadow (18791), the Felhunter Fel
  Energy (18792), each of which the aura's own tooltip describes alike; a demon summoned cancels it.

## The melee attack table

**What:** the chances of one swing or weapon ability (combat.d `missChance`, `dodgeChance`, `parryChance`,
`blockChance`, `glanceChance`, `glanceAmount`, `critChance`, `crushChance`, `rollMeleeOutcome`): one roll through
miss, dodge, parry, block, glance, crit, crush, hit.

**Sources:** Blizzard's statements of 2019 on Classic (forum thread "Bug: Hit Tables", posts 12 and 32; "Bug: Berserker
Stance", post 8), as Magey's wiki quotes them (github.com/magey/classic-warrior/wiki/Attack-table, commit f385839), and
the measurements on that page (Classic Era 1.13, tens of thousands of white swings per row), which agree with Beaza's
1.x formulas (wowwiki "Miss", oldid 347982; "Dodge", 347957; "Block", 349026; "Critical strike", 349108; "Weapon skill",
349241). Blizzard:

- "Creatures at your level have a **5%** chance to Dodge your attacks. Each additional level the target has over the
  player grants them **0.5%** additional chance to dodge."
- "Creatures that are 3 levels above the player have a **14%** Parry chance."
- "Players have an **8%** chance to miss a creature that is 3 levels above them."
- "Critical Strike chance is reduced by **1%** per each additional level the target has over the player."
- "the **first 1%** of +hit gained from talents or gear to be **ignored** against monsters with more than **10**
  Defense Skill above the attacking player's Weapon Skill ... the so-called 'hit cap' is in effect **9%**".
- "Modifiers to Critical Strike chance are reduced against enemies 3 levels higher than the player-character. There is
  a single modifier placed on total Critical Strike gained from auras".

**Rule** (gap = the victim's defense less the attacker's weapon skill; a creature's defense and skill are five a
level; "capped" skill is at most five times the attacker's level):

- **Miss:** against a creature 5% + 0.1% a point of gap, 0.2% a point past 10 (8% at 15); past 10 the attacker's hit
  loses `(gap − 10) × 0.2`% (the first 1% at 15); below level 10 the creature is missed its level in tenths as often.
  Against a player 5% + 0.04% a point. Dual wield +19% (measured: "the dual-wield miss penalty in Classic is indeed a
  flat 19%"). Never below 0.
- **Dodge:** a creature's 5% + 0.1% a point of gap (6.5% three levels above; 6% with +5 skill, measured 6.04%), a
  player's own + 0.04% a point.
- **Parry:** a creature's by the capped skill: 5% + 0.1% a point, 0.6% a point past 10 (14% at 15). Measured: 13.97%
  at +3, and 13.49% with +5 weapon skill (where a parry by the weapon skill would be 6%). A player's own + 0.04%.
- **Block:** a creature's at most its 5% ("mobs cannot block more than 5% of attacks regardless of rating
  difference"; measured 4.94% at +3), less 0.1% a point of skill above its defense; a player's own + 0.04%.
- **Glance:** 10% + 2% a point of the victim's defense over the capped skill (40% at +3, measured 40.36%); glancing
  damage 1.3 − 0.05·gap (at most 0.91) to 1.2 − 0.03·gap (0.2 to 0.99) by the uncapped skill (35% less at +3, 15% with
  +5 skill: measured 35.12% and 14.82%). Unchanged.
- **Crit:** against a creature by the capped skill: 0.2% less a point of gap (1% a level), 0.04% more a point under;
  three or more levels above, 1.8% less of the crit auras give (talents, buffs, gear's crit; not agility), at most what
  they give (measured: "~4.84% average suppression ... the suppression to aura crit is likely ~1.8%"; with 1% aura crit
  it was all suppressed). Against a player 0.04% a point.

**What changed (2026-11-20):** a creature three levels above was missed 9% (CMaNGOS's 0.2% + 0.4% a point past
10), and at least 1% whatever the hit: now 8%, and 0% at 9% hit. A creature's parry went by the weapon skill: +5 skill
cut a +3 creature's parry from 14% to 6%; now 14%. A creature's dodge moved 0.04% a point when the skill was above its
defense, now 0.1%; its block did not fall with skill above, now 0.1% a point. Crit against creatures went by the
uncapped weapon skill, and no crit from auras was suppressed. Creatures below level 10 were missed 5%.

**Unchanged, with no source:** crushing blows, `(skill − capped defense) × 2 − 15`% from a gap of 15 (15% from a
level 63 at 300 defense): no Blizzard statement and no Classic Era measurement was found (the warcraft.wiki.gg page
gives only the post-3.0 rule, its talk page's pre-3.0 posts disagree whether defense above the cap counts; a 2024
Blizzard forum thread has only players' claims). Casters' glancing (their chance from `min(level, 30)%`, their damage
0.6 to 0.9): Magey's page says only that "non-melee formula [is] slightly different". Creatures below level 10 block
less (Beaza) by no stated amount. A creature's own 5% crit, dodge, parry and block (creature.d `fighter`) agree with
Blizzard's 5% at the same level and the community's 440 defense to be uncrittable by a boss (5% + 15 × 0.04%).

**Second opinion (CMaNGOS-classic, compared afterwards):** `CalculateEffectiveMissChance` the 9% and 1% minimum;
`CalculateEffectiveParryChance` and `CalculateEffectiveBlockChance` by the weapon skill, block not falling;
`CalculateEffectiveCritChance` by the weapon skill against creatures (its own comment: "weapon skill does not benefit
crit% vs NPCs", the code the reverse), no aura-crit suppression.

## Ranged attacks: no dodge

**Source: the 1.12.1 tooltips** (Spell.dbc): Dodge (81) "Gives a chance to dodge enemy melee attacks", Parry (3127)
"Gives a chance to parry enemy melee attacks", Block (107) "Gives a chance to block enemy melee and ranged attacks";
and patch 5.0.4 (Warcraft Wiki "Dodge", oldid 6594641): "Ranged attacks can now be dodged". **Rule:** a ranged attack
(Auto Shot, a wand) and a ranged ability are never dodged nor parried; they may be blocked from the front. **What
changed:** an Auto Shot could be dodged (`rollMeleeOutcome` asked no attack type) while Aimed Shot could not.
CMaNGOS-classic: `CanDodgeAbility` melee abilities only, `CanDodgeInCombat` for swings and shots alike, as dmangos had.

## Spell resistance

**What:** a hostile spell's chance to be resisted whole, and the share of a direct-damage spell resisted
(combat.d `effectiveResistPercent`, `resistDistribution`, `fullResistChance`, `rollPartialResist`,
`partiallyResisted`; spellcast.d `spellMissChance`, `isBinarySpell`).

**Source: Blizzard's own page** (worldofwarcraft.com/info/basics/resistances.html, the 2006-07-21 copy in the Internet
Archive): "When hit by a spell, you have two chances to resist the spell. The first chance is based on your level ...
(minimum of 1%). If you make this resistance chance, you are completely unaffected by the spell. The second chance to
resist is based on your resistance score and the level of the caster ... up to a maximum of 75%. Against most spells,
this resistance percentage is the straight % chance to completely resist the spell. Against direct-damage spells
(spells that deliver their full damage upon impact, such as Fireball, Mind Blast, and Earth Shock), this resistance is
the percentage of damage you will resist on average. When you are hit by a direct-damage spell, you have a chance to
resist 100%, 75%, 50%, 25%, or 0% of the spell's damage". Its table against level-50 spells:

| resistance | 50 | 100 | 150 | 200 | 250 |
|---|---|---|---|---|---|
| average resisted | 15% | 30% | 45% | 60% | 75% |
| 100% resisted | 0% | 1% | 1% | 11% | 25% |
| 75% | 2% | 6% | 18% | 34% | 55% |
| 50% | 11% | 24% | 48% | 40% | 16% |
| 25% | 33% | 49% | 26% | 14% | 3% |
| none | 54% | 20% | 7% | 1% | 1% |

**Rule:** the average is `resistance / (5 × caster level, at least 100) × 0.75`, at most 75% (Blizzard's 50 and 250
against level 50: 15% and 75%). The table `partialResistRows` holds Blizzard's five columns exactly (tested); its rows
between are an emulator's fit, interpolated. A direct-damage spell is resisted whole by the table's last column (in the
hit roll), and otherwise in part by the other four, renormalized: at 75% one cast in 75 not resisted whole lands
whole. A spell with no direct damage, or whose direct damage lays a debuff on the same targets (Frostbolt's slow, Frost
Nova's root: "spells which deal a debuff", the documented 1.x research of Wowpedia "Resistance", oldid 6675993), is
binary: resisted whole by the average, never in part, its ticks included. Earth Shock's interrupt is no aura, and
Fireball's burn is damage: both in part, as Blizzard names them. Negative resistance adds the same share.

**The level miss (no Blizzard numbers):** 4%, 5%, 6% at 0 to 2 levels above, then 11% a level against creatures and 7%
against players, 1% at least (Wowpedia "Resistance", "Spell hit": documented research; Blizzard's page gives only the
1% minimum). A creature above the caster has 2% more average resistance a level for spells that are not binary
(Wowpedia: "8 resist (believed ...) ... not apply to binary spells"; 8 points are 2% at 60). Both unchanged.

**What changed (2026-11-20):** a direct hit above 54% average was never let land whole (Blizzard: 1%); a direct hit
not resisted whole drew from all five columns and turned the 100% column into 75% (more 75% resists than the table);
a binary spell's ticks were resisted in part at a tenth of the resistance (an emulator rule; Blizzard: resisted whole
or not at all); Earth Shock, and any direct damage with a non-aura extra (an interrupt), was binary.

**Second opinion (CMaNGOS-classic):** `IsBinarySpell` makes any non-damage effect on the targets of the damage binary
(Earth Shock binary); the partial roll bumps 0% to 25% above 54% for direct damage, and binary periodic damage rolls
partial resists at a tenth.

## Procs

**What:** what an aura procs on, how often, and how long it waits (procs.d `procRule`, `procFlagsOf`, `runProcs`).

**Sources: Blizzard's data.** The 1.12.1 Spell.dbc has each aura's `ProcFlags`, `ProcChance` and `ProcCharges` (the
world database's `spell_template` holds them as the DBC has them). Classic Era's SpellAuraOptions (wago.tools, build
1.15.9.70576) has the same three, and `ProcCategoryRecovery`, the milliseconds before an aura may proc again, which
1.12's client data lacks. `tools/fetch-procs.py DATA_DIR` writes it to `DATA_DIR/procs.csv` (not committed);
`ClientData.procOptions` reads it.

**The encoding.** `ProcTypeMask_0` is the later encoding. Compared with 1.12's `ProcFlags` over the 1065 auras with a
flag in either: 951 have the same mask; bits 0 to 20 (a kill 0x2 to any damage taken 0x100000) co-occur one to one;
0x80000000 rides on all 68 auras of damage over time taken (a later event); bit 21, 1.12's trap going off (Entrapment
only), is in Classic Era on damage over time dealt (Nightfall 0x250000, Pyroclasm 0x240000). So a mask is taken as its
bits 0 to 20 (`procFlagsOf`). Verified on the real data (dmangos.world.realrules_combat) on Lightning Shield, Blood
Craze, Flurry, Seal of Command, Ignite, Arcane Concentration, Nightfall, Pyroclasm, Vampiric Embrace and Spinal Reaper.

**Rule:** the flags, chance and charges are the aura's spell's (1.12's); the cooldown is Blizzard's
`ProcCategoryRecovery` where Classic Era has the aura as 1.12 has it (the same flags, chance and charges: 100 of the 102
auras with a recovery), else the world database's. Classic Era changed some auras after 1.12: Omen of Clarity procs
from spells there (0x14014, 10 s; its 1.12 tooltip: "Each of the Druid's melee attacks"), so it keeps the database's.

| aura | `spell_proc_event` | Blizzard |
|---|---|---|
| Lightning Shield, Shadowguard | 3 s | 3.5 s |
| Seal of Command | 3 s | 1 s |
| Hand of Justice | 3 s | 2 s |
| Unbridled Wrath, Mace Specialization, Seals of Justice, Light, Wisdom, Reckoning, Expose Weakness, Bloodfang, Lightning Strike, Heroism, Decapitate | 3 s | none |
| Sword Specialization | none | 0.2 s |
| Setup, Arcane Concentration's ranks, Magic Absorption, Force Reactive Disk, Mana Surge | none (or 1 s) | 1 s |
| Seal Fate, Flurry (shaman), Head Rush | none | 0.5 s |
| Thrash, Ironfoe, the Absorption items and other item and creature auras | none | 0.2 to 240 s |

**Still from the world database (no Blizzard data):** what hits an aura takes (`procEx`: a crit only, a dodge, a
block), its school and spell family masks, the flags it gives where the spell has none (Improved Blizzard, Improved
Mend Pet, Improved Aspect of the Hawk) or narrows (Arcane Concentration without ranged attacks; Illusion Passive), and
rates a minute: SpellAuraOptions' `SpellProcsPerMinuteID` is 0 on every row, so the rates (Seal of Command 7, Crusader
1, ...) stay the database's. Where a talent's tooltip gives a flat chance the class passes took it (Unbridled Wrath,
Mace Specialization: "a 40% chance"), and Blizzard's `ProcChance` agrees (8% to 40%, 1% to 6%).

**`spell_affect` stays.** SpellEffect's `EffectSpellClassMask` is in Classic Era's own family-flag numbering, rebuilt
since 1.12 (2335 of 3060 effect masks differ from 1.12's `EffectItemType`). Translated through the spells each names
(SpellClassOptions) back to 1.12's flags, 70 of the 132 `spell_affect` rows agree and 62 do not, both ways (Fire
Power's would take in Frostbolt, Polymorph and the conjures, whose 1.12 flag 0x40000000 a fire spell shares, and lose Ignite's 0x8000000). It is no source for 1.12's masks;
`spell_affect` and the tooltip fixes (`world/tooltipmasks.d`) stay.

## Diminishing returns

**What:** crowd control in PvP lasting less when repeated (diminishing.d; aurahandlers.d `diminishedDuration`, a
player's own and a pet's or totem's on a player, character.d `auraFrom`).

**Source: Blizzard's 1.x patch notes** (Warcraft Wiki "Patch 1.4.0", oldid 6971245, and 1.8.0, 1.9.0, 1.10.0, 1.11.0).
1.4.0: "When a spell with diminishing returns is used against a target in PvP, the first effect has full duration. On
the second use of the same category of spell (e.g. slowing), that spell's duration is reduced by 50%. On the third use,
the duration is reduced by 75%. On the fourth attempt, the target becomes immune to the spell. Spells must be used on
the same target within 15 seconds of the *end* of the duration in order to be diminished." It added "Frost Shock"
("considered a slowing effect"), "Entangling Roots", "Frost Nova" ("an immobilizing effect"), and "Seduction (Succubus) -
Is now considered a Fear effect". 1.8.0: "Death Coil ... now causes a short Fear effect that is not diminished";
"Gnomish Mind Control Cap - Is now subject to diminishing returns in the Charm category". 1.9.0: the stuns of
Improved Starfire, Improved Concussive Shot, Impact, Seal of Justice, Blackout, Mace Specialization, Pyroclasm and
Improved Revenge "no longer diminish or [are] diminished by controlled stun abilities and spells (e.g. Cheap Shot,
Hammer of Justice, Charge etc.)". 1.10.0: "Freezing Traps are now affected by diminishing returns". 1.11.0: "Grenades
and Mortars now are set to use the 'Controlled Stun' mechanic".

**Rule:** PvP only (a player's, or its pet's or totem's, hostile aura on a player). Categories: controlled stuns (the
stun mechanic, but the eight proc stuns of 1.9.0), fear (the fear mechanic, and Seduction), charm (the charm mechanic),
immobilizing (Entangling Roots, Frost Nova), slowing (Frost Shock), Freezing Trap (the freeze mechanic). Full, half, a
quarter, then immune until 15 s after the last one's end (its break counts as its end). Other crowd control is not
diminished: the notes say "It is our goal to set as few spells as possible to be diminished".

**Not from a source:** whether the 1.9.0 proc stuns diminish among themselves (taken: not at all); the immune
attempt shows nothing (no "Immune" in the combat log yet). Classic Era resets "dynamically between 15-20 seconds"
(Warcraft Wiki "Diminishing returns"), a later implementation; 1.12's 15 s is kept.

**Second opinion (CMaNGOS-classic):** `GetDiminishingReturnsGroupForSpell` diminishes by mechanic far beyond the notes
(polymorph, sleep, every root, knockout, Blind, Kidney Shot apart, banish, horror, silence, disarm) and splits
triggered stuns and roots into groups of their own.

## Pets

**What:** what a pet has of its own and of its owner (world/petauras.d, pet.d, creatureprocs.d; each talent tested in
world/realclass_pets.d). **Source: the 1.12.1 client's data and the tooltips** (docs/spells/warlock.md, hunter.md),
except where said.

- **A pet's passive auras** are the spells `SkillLineAbility.dbc` has learned on getting its family's skill lines
  (`CreatureFamily.dbc`: "Pet - Boar", "Pet - Generic"; "Pet - Imp"...): a hunter pet's Tamed Pet Passives 8875, 19580
  .. 19591, 20784, its family's own (a boar's 7000: 10% less physical damage, 9% more armor, 4% more health); a
  demon's 18727 .. 18742. Their amounts are 0 but for the family's own: the talents are modifiers of their effects.
- **The owner's spell modifiers** count for its pet's spells and auras (its effects, damage, cast time, cooldown,
  duration, proc chance), as for its own: Fel Stamina's "15% more maximum Health" is 15 added to all effects of 18735
  .. 18738 ("Max Health increased by 0%"). A modifier of an outdoors-only talent (Bestial Swiftness,
  `SPELL_ATTR_OUTDOORS_ONLY`) counts while the pet is outdoors.
- **A pet's stats with its auras** are made as a player's are: `MOD_STAT` and its percentages; health 10 and mana 15
  for each point of stamina and intellect above its level's (`pet_levelstats`), 2 armor for each point of agility above
  it; then the percentages (`MOD_INCREASE_HEALTH_PERCENT`, `_ENERGY_PERCENT`, `MOD_BASE_RESISTANCE_PCT` and
  `MOD_RESISTANCE_PCT` on its armor, all base armor). The 10, 15 and 2 are the player's for points above 20; nothing
  primary gives a pet's (not from an emulator).
- **Crit, dodge, parry and block** of a creature: 5% each and what its auras add (Ferocity's 19591).
- **`SPELL_EFFECT_APPLY_AREA_AURA_PET`:** the aura is its caster's and its caster's pet's, or (cast by a pet) its
  owner's: Master Demonologist ("Grants both the Warlock and the summoned demon"), Spirit Bond ("you and your pet"),
  Soul Link.
- **`SPELL_AURA_SPLIT_DAMAGE_PCT`:** its share of the damage its bearer takes goes to the aura's caster. Soul Link's
  aura is cast by the demon, so on the warlock it sends 30% to the demon ("30% of all damage taken by the caster is
  taken by your ... demon instead"); on the demon (its caster itself) it does nothing.
- **Which aura a pet gets for its owner's talent** where the data does not link them (dummy auras and effects:
  Master Demonologist by demon, Spirit Bond, Soul Link): the world database's `spell_pet_auras`, CMaNGOS's table, the
  only source; each aura's own tooltip agrees ("Reduces threat caused by 20%", "Regenerate 2% of total health every
  10 sec", "30% of damage taken by master is split with demon").
- **A pet's procs** (Frenzy's 20784 "Chance to proc frenzy", Intimidation): its Proc Trigger Spell auras on its hits,
  their chance by its owner's `SPELLMOD_CHANCE_OF_SUCCESS` (Frenzy adds 20% a rank to 20784's 0%), only at a crit for
  Frenzy as `spell_proc_event` and the tooltip ("after dealing a critical strike") have it.
- **Improved Mend Pet:** the chance a tick is the talent's amount (15%, 50%); what cleanses is 24406, which the
  tooltip names (`$24406s1`).
- **Improved Scorpid Sting:** 10%, 20%, 30% (the tooltip's; its override scripts 2388 .. 2390 carry no amount) of the
  sting's strength reduction, as 19486's stamina reduction ("Stamina reduced by $s1").

## World PvP

**What:** the Eastern Plaguelands' four towers and Silithus's Silithyst, added in 1.12 (world/worldpvp.d).

**Source: the 1.12.1 client's data and the world database first.** Most of the rules are data:

- **The capture points** (`gameobject_template` 181899, 182096, 182097, 182098, type 29), all four alike: radius 80
  (data 0); the capture bar's world states 2426 (shown), 2427 (the slider), 2428 (the neutral band; data 2, 3, 13);
  the neutral band 20% (12); superiority counted from 1 to 5 (14, 15); 480 and 1200 seconds (16, 17); start 50 (20).
  Their events: data 4, 5 "win", 6, 7 "contested", 8, 9 "progress", 10, 11 "neutral" (the type's field names). Only the
  progress events have database scripts, and those are what a capture brings (`dbscripts_on_event` 10691, 10692:
  Eastwall's squads; 10700, 10701: Plaguewood's flight master): a tower is taken at its progress event.
  `WorldStateUI.dbc` row 138 is the bar ("CAPTUREPOINT", 2427 and 2428), rows 136 and 137 the towers each side holds
  (2327, 2328). `AreaPOI.dbc` gives each tower seven map states: nobody's; each side's "Progressing" (drawn with the
  side's banner), "Contested" (drawn with the grey one) and held. Plaguewood's "Horde, Contested" has no point of
  interest; its state is taken as the gap in its run (2367).
- **The banners:** `GameObjectArtKit.dbc` 1, 2, 21 are `BattlefieldBanner_State_Flag{H,A,N}_Plaguelands`: the capture
  point and the two `Tower Banner`s (182106) at each tower show their holder's.
- **The rewards:** Echoes of Lordaeron (`Increases ... damage dealt to Undead by $s1%`), four ranks a side by icon
  (`INV_BannerPVP_02` the Alliance's 11413, 11414, 11415, 1386; `_01` the Horde's 30880, 30683, 30682, 29520): 1%, 2%,
  3%, 5%. The quests "Establishing New Outposts" (9664) and "Bolstering Our Defenses" (9665) count each tower's
  capture credit (17689, 17690, 17696, 17698). Crown Guard's graveyard is `WorldSafeLocs.dbc` 927 ("Graveyard CG
  Tower"). Northpass's shrines (181682 with the Alliance's faction template 1315, 181955 with the Horde's 1314) are
  spawned but not in the world (`spawntimesecs` -180). The flight master William Kielar's template has the Alliance's
  faction 84; the Horde's holds him with its counterpart 83. The zone is told "... has been taken by the Alliance!" and
  "All four towers are now in control of ..." (`broadcast_text` 13629 to 13638).
- **Silithyst:** the geysers (181598) cast "Sillithus Flag Click"; the carrier's aura, Silithyst (29519), is an
  immunity to being summoned, ends on mounting, stealth and invulnerability (`AuraInterruptFlags` 0x3A0000), and its
  periodic "ToWoW - Sillithus PvP Flag" (30176, no effect) is the flag kept up while it is carried. "Sillithus Flag
  Drop (DND)" (29533) makes the mound (181597) for three minutes (`SpellDuration.dbc` 25). The camps are
  `AreaTrigger.dbc` 4162 (by "Sillithus Flag Stand, Alliance") and 4168 (the Horde's), their quest credit 17090 and
  18199 ("Scouring the Desert", 9419, 9422). Traces of Silithyst (29534, 5% damage for 30 minutes). The counters are
  `WorldStateUI.dbc` 126 and 127, "%2313w/%2317w" and "%2314w/%2317w". Cenarion Favor (30754) is 25% more Cenarion
  Circle reputation from kills.

**Source: documented research** (warcraft.wiki.gg "A Game of Towers", "Echoes of Lordaeron", "Northpass Tower",
"Silithyst", "The Silithyst Must Flow", "Cenarion Favor"; Patch 1.12.1's notes) where the data is silent:

- 189 bonus honor to each player of the side "directly taking part" in a capture; the towers' roles (the graveyard, the
  squad marching on Northpass "regardless of which faction controls the tower", the shrine, the flight master's free
  flights); the message in the local defense channel. 1.12.1: "Players who die in the Fungal Vale will now port to the
  Crown Guard Tower graveyard if their faction controls that tower"; stealthed players get no honor for a capture
  (dmangos counts only players seen: not stealthed or invisible, alive, not on a flight, and flagged for PvP, "A player
  must have PvP enabled").
- Echoes of Lordaeron in the Eastern Plaguelands and Stratholme, to the whole side; 1.12.1 kept it through death (dmangos
  gives it again at the next second's check, alive).
- Silithyst: "The first faction to collect 200 Silithyst wins the race"; Cenarion Favor to the winners in Silithus and
  the Ahn'Qiraj raids until the other side wins; "A server reboot will reset the battle"; a carrier who loses it drops a
  mound anyone may take; each turn-in "20 Cenarion Circle reputation, 1 Honor Point" (the honor taken as one bonus
  honor unit at the player's level: 198 at 60, see Honor). The data's Silithyst Cap Reward (31247, triggered by
  Traces of Silithyst) names faction 609 and 10 through an effect 1.12 does not have (122); it is not counted on top.

**Interpretations (no source found):**

- The slider moves the whole length (0 to 100) in 1200 seconds at a lead of one and 480 at five or more, linearly
  between (out of the neutral band from the middle: 120 and 48 seconds); it moves once a second. Nobody (or even
  numbers) leaves it where it is.
- A held tower is "Progressing" while its side last pushed and the slider is short of the end, "Contested" while the
  other side last pushed; it is lost when the slider enters the neutral band.
- Neither zone's state is saved: the wiki says so of Silithus; nothing says the towers outlived a restart.
- After a race is won both counts start again at 0. Cenarion Favor also holds at the Gates of Ahn'Qiraj (a zone of its
  own in Silithus).
- A lost tower takes its flight master and its side's squad away.
- Silithus's announcers are the camps' quest givers, Marshal Bluewall (17080) and General Kirika (17079): the data's
  texts 13479 .. 13481 and 13476 .. 13478 (male and female, as the two are) say "one quarter", "half" and "almost all";
  they are said (the rows' `ChatTypeID` 0) at 50, 100 and 150 of 200, and 13470, 13469 ("Victory ...") at the win, as
  vmangos's `DoSilithystYell` does; the win is also "The Alliance (Horde) has collected 200 silithyst!" in the zone's
  defense channel (`mangos_string` 1636, 1635, as CMaNGOS sends it). A carrier who leaves the world (a logout, a lost
  connection) drops a mound where it was, as one who dies does: the aura ends on leaving the world (its
  `AuraInterruptFlags`), and the dust must not vanish with the carrier.

**Second opinion (CMaNGOS-classic, `OutdoorPvP/OutdoorPvPEP.cpp`, `OutdoorPvPSI.cpp`, `GameObject::TickCapturePoint`),
compared after the implementation:** it agrees on the capture's rate, its taking at the progress events and losing in
the neutral band, the 189 honor (its comment: "guessed, same factor as silithus"), the buffs, the graveyard, the
shrines, the flight master's and the squads' removal, the 200 and the reset of both counts. It differs:

- it moves the slider every 5 seconds (its note: "On retail: Ticks every 5.2 seconds"); dmangos every second, at the same
  rate;
- it counts players on a PvP realm without the flag, and not game masters;
- it shows only three map states per tower (nobody's, each side's), never "Progressing" or "Contested";
- it summons Eastwall's squad only when Northpass is not the capturing side's; dmangos always (the wiki's "regardless");
- it gives the flight master factions 774 and 775 and a particle aura; dmangos the template's 84 and its Horde
  counterpart 83, no particles;
- it does not send "All four towers ..." (marked not yet implemented) nor port the Fungal Vale's dead to Crown Guard;
- it sends the defense message to every player in the open world; dmangos to those in the zone (the zone's channel);
- Echoes of Lordaeron also in Scholomance, Cenarion Favor also at the Gates of Ahn'Qiraj (dmangos agrees on the gates);
- a turn-in's honor is 199 (dmangos 198, the unit at 60); reputation 20 (agrees).

dmangos's first implementation took a tower only at the slider's end, with "Progressing" for a tower nobody held; the
progress events' scripts and the map's banners showed otherwise, and the comparison agreed: changed before commit.

## Auction houses

**What:** the deposit and the cut of each auction house, and how the duration counts (world/auctionhouse.d).

**Source: the 1.12.1 client's data.** `AuctionHouse.dbc` gives each house a deposit percentage and a cut: the six
factions' houses (Stormwind, Alliance, Darnassus, Undercity, Thunder Bluff, Horde) 5 and 5, the goblins' Blackwater house (7)
25 and 15. The client shows the deposit from the same row (`CalculateAuctionDeposit`), so the server must charge what
it shows: the item's sell price times the stack, times the house's percentage, for each 2 hours of the 2, 8 or 24 the
client offers (1, 4 or 12 times). A faction's house so takes 5%, 20% and 60% of the sell price, the goblins' five times
that (25%, 100%, 300%); the cut is the house's share of the winning bid (5%, 15%). Tested on the real file
(world/realsystems.d).

**Documented research** agrees: the Classic Era guides give 5%, 20% and 60% at a faction's house and "five times that"
at a neutral one; the cut 5% and 15% (warcraft.wiki.gg "Auction House" for the cut, the deposit refunded with a sale
and kept when an auction expires or is cancelled). One guide's neutral 75% and 150% for 2 and 8 hours matches neither
the data nor its own "five times"; the data is taken.

**The server's own rates** (`rate_auction_deposit`, `rate_auction_cut`, `rate_auction_time`, `auction_deposit_min`:
CMaNGOS's `Rate.Auction.*` and `Auction.Deposit.Min`) multiply the deposit and the cut, stretch an auction's time and
set a least deposit; their defaults (1, 1, 1, none) are the client's numbers. **Second opinion (CMaNGOS-classic,
`AuctionHouseMgr::GetAuctionDeposit`, `AuctionEntry::GetAuctionCut`):** the same formula and order (the least deposit
before the rate).

## Alterac Valley's turn-ins

**What:** what the battle's repeatable quests bring about (world/alterac.d).

**Source: the data.** The quests (`quest_template`, zone 2597) take 20 Armor Scraps (17422: Murgot Deepforge's 7223,
6781; Smith Regzar's 7224, 6741), one or five Storm Crystals (17423: Arch Druid Renferal's 6881, 7386) or Stormpike
Soldier's Blood (17306: Primalist Thurloga's 6801, 7385). Each graveyard's defenders are spawned by battleground events
(`creature_battleground`: event1 15 + the node, event2 the side * 4 + the kind): Stormpike Defenders and Frostwolf
Guardians, then Seasoned, Veteran and Champion ones, four of each kind at each graveyard. General's Warcry (28418,
28419, 28420) is 10%, 20%, 30% more damage done (aura 79) for two minutes (`SpellDuration.dbc` 4). The lords are
`creature_template` 13419 and 13256, with their own EventAI.

**Documented research** (warcraft.wiki.gg "Alterac Valley (original)"): "Each upgrade costs 500 Armor Scraps, or 1,500
for all three"; only the stationary troops (the graveyards') are upgraded; since 1.11 an upgrade also gives the general
"a periodic melee and spell damage buff: 10% at Seasoned, 20% at Veteran, and 30% at Champion"; 200 Storm Crystals or
Stormpike Soldier's Blood, "turned in in batches of 1 or 5", summon Ivus or Lokholar, who "fight on the Field of
Strife". The same page gives the cavalry (25 tamed mounts and 25 hides, Honored to launch), the fleets (120, 60, 30 of
the soldiers', lieutenants' and commanders' medals or flesh, Revered for the beacons) and the ground assault (280
supplies of one's own mine, 70 of the other's, Honored).

**Interpretations (no source found):**

- The upgrade comes when the scraps reach it (the wiki has an Honored player ask the blacksmith; the database's
  blacksmiths have no such gossip, only "How many more supplies are needed for the next upgrade?", without an answer).
- The general cries the warcry at each upgrade and every two minutes after (its duration): "periodic".
- The lord comes at once, on the Field of Strife, halfway between the graveyards where its summoner would stop
  (`WorldSafeLocs.dbc` 729 and 169 for Ivus, 169 and 749 for Lokholar); once a battle. The wiki's escort and its ten
  players at a circle are not done (the Circle of Calling, `gameobject_template` 178670, needs ten; it has no spawn),
  nor the lord's march on the enemy base.
- The turn-in that calls a lord is a "secondary unit activated" on the scoreboard.

**Second opinion (vmangos, `BattleGroundAV::HandleQuestComplete`, `UpgradeArmor`):** 20 scraps a turn-in, upgrades at
500, 1000 and 1500 with 28418 .. 28420 (its automatic call is commented out); its lords, cavalry and fleets only count.
CMaNGOS-classic does nothing with the turn-ins.


## Health and mana from spirit

**What:** out of combat a player regenerates health from spirit every two-second tick (world/player.d
`healthRegenPerTick`, a second half of it); mana from spirit too, in and out of combat, but none for five seconds after
mana is spent (`spiritManaPerSecond`, `manaSpent`).

**Sources: documented 1.x research**, read at warcraft.wiki.gg, which keeps WoWWiki's history (the last revisions
before patch 2.0.1, 2006-12-05, unless said).

- Health, a tick (WoWWiki "Health regeneration", revision 1723894, 2007-11, its table marked "Pre-BC" for warriors,
  unchanged since the 1.x measurements): druid spirit × 0.09 + 6.5, hunter × 0.25 + 6, mage × 0.10 + ?, paladin × 0.25
  + ?, priest × 0.10 + ?, rogue × 0.50 + 2 ("Confirmed at level 60 patch 1.09"), shaman × 0.11 + 7, warlock × 0.07 + 6,
  warrior × 0.80 + 6. "There is 1 tick of regeneration every 2 seconds" (revision 1723817, 2006-08-25). The talk page
  (Talk:Health regeneration/Archive01) holds the measurements of 2006: a level 60 warrior "with 58 spirit gained 53
  health a tick" and "With 44 spirit he gained 41/42"; a level 48 warlock "With 173 spirit I gained 17 health a tick
  and with 101 spirit I gained 13".
- Sitting: "Health Regeneration is increased by 33% while sitting" (same revision; added 2007-02, so after 2.0; a
  Classic Era player in 2020: "close to 30% but i'm not sure").
- Mana, a tick (WoWWiki "Mana regeneration", revision 1569850, 2006-03): druid, hunter, warlock spirit / 5 + 15;
  mage, priest / 4 + 12.5; shaman / 5 + 17. Its paladin line (/ 4 + 8) disagrees with the same page's comparison of
  2006-06 ("1.6 spi for 1 mana/5 for priests and mages, and 2 spi for all others", that is / 4 for those two and / 5
  for the rest) and with the 2.x Armory fits (paladin 0.5 a point of spirit every 5 seconds, / 5 a tick).
- The five-second rule (WoWWiki "Five second rule", revision 3630837, 2006-11-03; "Mana regeneration", 2006-11-09):
  "After expending mana to cast a spell, a character does not regenerate mana for 5 seconds"; spells that cost no
  mana (Clearcasting, Inner Focus, Nature's Swiftness) do not start it; "Channeled spells ... The five second rule
  starts when the spell's channeling starts; i.e. when you pay the mana for it. The rule continues for at least five
  seconds, and longer if the spell is channeled for more than five seconds ... Tranquility channels for 10 seconds and
  interrupts your regeneration for the full 10 seconds"; Mod Power Regen effects (water, Anathema) and periodic
  energize effects are not subject to it.

**Rule:** health a tick by the table; a mage's (spirit × 0.11 + 1), a paladin's (× 0.25) and a priest's (× 0.15 + 1.4)
lines, whose constants were never found, stay CMaNGOS's (the paladin's agrees with the 1.x slope). A third more not
standing. Mana by the table (the paladin's / 5 + 15). Mana spent pauses spirit's mana for 5 seconds, or for the
channel's length if longer.

**What changed (2026-11-21):** health came from CMaNGOS's `OCTRegenHPPerSpirit` lines (e.g. warrior spirit × 1.26 −
22.6), taken as a second, so a tick gave twice the line: a level 60 warrior with 58 spirit regenerated 101 a tick, the
1.x warrior 53 (the table: 52). Sitting gave half again. A channel paused the regeneration for five seconds from its
start whatever its length.

**Left:** the tick's dependence on the level. A Classic Era warrior of level 15 with 30 spirit was shown "21 hp per
tick" (Blizzard forums, "Passive health regeneration (warrior)", 2020-04-01), the table's 30, CMaNGOS's 30; a level 37
warrior of 2006 measured 0.83 a point of spirit, the level 60 ones 0.9. That looks like a per-level rate (as 2.0's
game tables have), but too few points were found to fit one.

**Second opinion (CMaNGOS-classic, `Unit::OCTRegenHPPerSpirit`, `Player::RegenerateHealth`), compared afterwards:** the
lines above, applied as health a second (`ModifyHealth(addvalue * diff / 1000)`); × 1.5 sitting; the mana table as
dmangos has it (paladin / 5 + 15, its comment "the above addvalue are given per tick"). No channel rule.

## Spell crit from intellect

**What:** a player's spell crit, base + intellect / (a + b × level) by class (world/spellhandlers.d `spellCrit`).

**Source: Blizzard's statement** (the community manager Tseric, 2006, quoted on WoWWiki "Attributes (pre-6.0)",
revision 462389, 2006-11-13; the post: forums.worldofwarcraft.com thread 8532806): "exact figures at level 60 for
spell crit": warlock 60.6 intellect a percent, druid 60.0, shaman 59.5, mage 59.5, priest 59.2. The paladin's was not
given; Classic Era's guides give 54.

**Rule:** at level 60 a, b give those figures: CMaNGOS's fit already does for the priest (59.23), shaman (59.51),
warlock (60.5), druid (59.81) and paladin (53.77). The mage's row was the paladin's (53.77); it is now 14.673 + 0.7471
× level (59.5 at 60, the old row's 15.42 at level 1). The bases (3.70 a mage, 2.97 a priest, ...) and the slope by
level have no source (no 1.12 table; gtChanceToSpellCrit starts in 2.0): CMaNGOS's, its comment "from mangos 3462 for
1.12 MUST BE CHECKED". A Classic Era mage of level 34 with 164 intellect saw 2.76% (Blizzard forums, "About Mage
Stats"), where the formula gives 8.1%: the bases are likely too high, but nothing gives better ones.

## Attack power, crit and dodge from agility

**Sources: Blizzard's statements**, quoted on WoWWiki "Attributes (pre-6.0)" (revision 462389, 2006-11-13, "From the
Developers"): "For most level 60 character classes, approximately 20 points of AGI will increase your critical hit
chance by approximately 1%. Rogues require 29 AGI ... and Hunters require 53 AGI"; dodge: "approximately 20 points ...
Rogues only require 14.5 AGI ... Hunters require 26.5 AGI". Base dodge (WoWWiki "Dodge", revision 3537383,
2006-11-30): druid 0.75%, hunter 0.64%, mage 3.25%, paladin 0.75%, priest 3%, rogue 0%, shaman 1.75%, warlock 2%,
warrior 0%. Attack power: "Attack Power increases your base DPS by 1 for every 14 attack power" and strength gives 2
melee attack power, rogues and hunters 1 and 1 per agility (WoWWiki "Attack power", revision 781971, 2006-11-30);
"Before patch 2.0.1, hunters received 2 Ranged AP per agility" (warcraft.wiki.gg "Attack power"); the level terms (3 a
level for warriors and paladins, 2 for rogues, hunters and shamans; ranged 1 a level for warriors and rogues, 2 for
hunters) are the 2008 WoWWiki table (revision 1317844), whose non-druid rows 2.0 did not change; a druid has none (see
"A druid's attack power").

**Rule:** all as dmangos had it (world/stats.d `meleeChances`, `meleeAttackPower`, `rangedAttackPower`,
`weaponDamage`): the level 60 figures agree. The ratios below 60 are CMaNGOS's straight line from a level 1 figure,
with no source. One disagreement left: the same Attributes revision says "Warriors, Hunters and Rogues gain 2 ranged
attack power for each point of agility", where dmangos (and the 2008 table) give warriors and rogues 1; Blizzard's
2.0 hunter notes name only hunters' change, so 1 stays. Health 10 a point of stamina, mana 15 a point of intellect
(the same revision); the first 20 points giving 1 each has no source found.

## Group loot

**What:** who takes what from a group's kill (world/loot.d, loothandlers.d, group.d).

**Sources: documented 1.12 play**, WoWWiki "Loot" (revision 3270605, 2006-10-19) and "Party" (revision 5183327,
2006-11-20), read at warcraft.wiki.gg:

- The methods: "Free-for-all ... Master Loot: One person in the group, designated by the leader, loots all corpses and
  distributes loot ... Round-robin: Party members take turns looting corpses ... Group Loot: Like Round-robin, except
  that there is a threshold set by the leader for which items must be rolled off ... Need before Greed: 'Pass' is
  automatically selected for party members who can't use an item." "Group Loot: This is the default type for a group."
  "the threshold can be set to Uncommon, Rare, or Epic"; the master looter is "set by the party leader by
  right-clicking on any member's portrait".
- Rolls: need, greed or pass, 1 to 100; "The looting will first resolve all NEED rolls, if none then Greed rolls. The
  member with the highest roll will get the item"; "If everyone passes on a rollable item, the item becomes freely
  lootable to anyone in the party".
- Money: "In all loot settings, money on the corpse is distributed as evenly as possible among all party members";
  "if a party member is out of range when a monster is killed ... he will not receive a share of any gold ... and will
  not be able to roll".
- Quest items: an item each member with the quest may take (the multi-drop flag); otherwise "if the current looter
  can't collect the items ... the quest loot is FFA for those members who can still pick up the quest items".
- Chests: "containers like chests ... are always treated by the game as 'free for all'".

**Rule:** need before greed passes for a member who cannot use the item (its class, race, level, skill and spell
requirements and its weapon or armor skill: a mage and mail): no roll window, an automatic pass shown to the group,
and no other choice taken from it. Money: the share is the whole copper, and the copper over is one each, the
looter first, then by guid. The threshold is uncommon to epic and the master a member; another setting is refused.
The rest agreed already: the methods, need over greed, all passing frees it, the out-of-range members, quest items.

**What changed (2026-11-21):** need before greed hid the Need button but let a member who could not use the item greed
(as 2.0 later did), and took only the item's own requirements as "use" (a mage could need mail). The copper left over
a split was lost. Any threshold and any master were taken.

**Left:** chests stay under the group's rules: the 1.12 chest data has a "group loot rules" field (`data15`, set on 29
of 770 chests in the world database, not on Cache of the Firelord), and raid chests were master-looted in 1.12 play,
so "always free for all" is not taken as is. A tie between two equal rolls (by the order of the votes) and the minute
to roll have no source.

**Second opinion (CMaNGOS-classic, `GroupLootRoll`, `Loot::SendGold`, `Group::SetLootMethod`), compared
afterwards:** need before greed takes the Need button away from who cannot use the item (`ROLL_VOTE_MASK_NEED`)
and lets it greed, as dmangos had; the money is `m_gold / m_ownerSet.size()` each, the rest lost.

**Second opinion on auctions and mail (CMaNGOS-classic `AuctionHouseMgr::GetAuctionDeposit`,
`WorldSession::HandleSendMail`, `Mail::SendReturnToSender`, `HandleMailMarkAsRead`), compared afterwards:** the deposit
rounded once at the end, with a configured minimum; the delivery delay "always applied, even if we're sending mails to
our own characters" (its own comment), so money and words take it too; returned mail with items to another account
takes it; reading changes no expiry. On durability (`Player::EnvironmentalDamage`): only a fall to death costs it.

## Auctions

**What:** the deposit, the house's cut, cancelling (world/auctionhouse.d `auctionDeposit`, `AuctionRecord.cut`;
auctionhandlers.d).

**Sources:** Blizzard's data, AuctionHouse.dbc (1.12.1): the six city houses deposit 5, cut 5; Blackwater (Booty
Bay, Gadgetzan, Everlook) deposit 25, cut 15. WoWWiki "Auction House" (revision 4674101, 2006-10-16): "Deposit (2hr
auction) = 0.05 * MSV" (0.25 neutral), "the base deposit is rounded first, and then multiplied ... Deposit (8hr
auction) = 4 * Deposit (2hr auction), Deposit (24hr auction) = 12 * Deposit (2hr auction)"; "if an item has no sell
value ... there will be no deposit"; its example: "The base deposit on 1 fish is 0. (0.05 * 4cp < 1cp) ... you can list
single fish for any length of time with no deposit". Cut "0.05 * Winning Bid" (0.15 neutral); the seller gets the bid
less the cut plus the deposit; unsold, "your deposit will not be refunded"; cancelled, "Cancellation Fee = Deposit"
and with a bid "Deposit + Cut".

**Rule:** deposit = floor(sell price × count × deposit% / 100) × (duration / 2 hours). **What changed (2026-11-21):**
the product was rounded once at the end (a 4-copper item for a day: 2 copper, now none). The rest agreed (the cut,
the cancel fee, the durations). The minimum raise (5% of the bid) has no source.

## Mail

**Sources:** WoWWiki "Mail" (revision 3830942, 2006-11-26): "Simple messages (including those with money attached)
arrive immediately. One hour delivery if items are attached. Mail from the Auction House arrives immediately, even
with items. Return mail arrives immediately." "Mail recieved stays in your mailbox for 30 days, but if you read the
mail, it'll only last for 3 days. After the expiry period the mail is returned to the sender. If the mail comes from
the Auction House, a quest NPC, or anything similar it is simply discarded".

**Rule:** a letter with an item to another account comes an hour later; with money only, at once; returned, at once.
Read, a letter has at most 3 days left. Expired, a player's letter goes back with its item or its money.

**What changed (2026-11-21):** money alone took the hour (to another account), and so did returned mail; reading
changed nothing; an expired letter with money only was deleted, the money lost.

**Left, no source:** the 30 copper postage; the 3 days of a letter with cash on delivery; letters with items to the
same account coming at once (no 1.12 statement either way).

## Durability

**Sources:** WoWWiki "Durability" (revision 671373, 2006-10-03) and "Death" (revision 2632986, 2006-07-25): "When you
die, 10% durability is lost on all equipped items ... You will not lose 10% durability if you are killed in PvP combat";
"When you use the services of a Spirit Healer you lose 25% durability on all equipped items and items in your bags"
("25% of maximum, not current", "Spirit Healer", 2006-11-22); "If you are killed by self-inflicted death ... you will
not suffer any durability damage"; "When your ghost is killed, you suffer another 10% durability loss". Resurrection
sickness: none to level 10, "one minute of sickness for each level they are above 10", ten minutes from 20.

**Rule:** a death costs a tenth of the worn gear's maximum durability, but by a player's side (dmangos's "killed by a
player" covers pets and battlegrounds) or by one's own hand; drowning, fatigue and lava cost it as a fall does; the
spirit healer a quarter of everything. **What changed (2026-11-21):** only a fall to death cost it among the
environment's deaths. The rest agreed. A ghost dying of fatigue is not modelled (dmangos's ghosts do not die).

## The PvP flag

**Source:** WoWWiki "PvP flag" (revision 33320, 2006-10-05): the flag goes up when "You engage another player of an
opposing faction in combat other than dueling", "You cast a spell on a player whose flag is up ... If you cast a
healing spell or resurrect a flagged player, your flag will go up", "You enter a territory that is one of the
beginning zones for the opposite faction", "Only applies to PvP Realms: You enter a contested territory", "You enter
an opposing factions capital city ... This applies even on PvE Realms"; "There is a five-minute delay to pulling down
your PvP flag ... after that five-minute delay from when you last performed an action that would bring up the flag".

**Rule:** the other side's capitals and the zones its races begin in (playercreateinfo's zones: Elwynn Forest, Dun
Morogh, Teldrassil / Durotar, Mulgore, Tirisfal Glades) flag on every realm; the rest of its land (AreaTable.dbc's
team) and contested land on PvP realms; healing a
flagged player flags the healer, in combat or not; five minutes to come down. **What changed (2026-11-21):** the
other side's beginning zones flagged only on PvP realms (its capitals on every realm), and a heal flagged only when the healed player was
in combat. **Left:** buffs flag too by the same page, but buffs do not reach the PvP code yet (the aura path is the
spell pipeline's); the 30 seconds of "contested" have no source.

**Second opinion (CMaNGOS-classic, `Player::UpdateZone`, `Unit::SetInCombatWithAssisted`), compared afterwards:**
enemy land only on PvP realms or in capitals, as dmangos had; a heal flags only a helper of someone in combat.

## Battlegrounds

**Sources:** WoWWiki "Arathi Basin" (revision 3151467, 2006-11-30; the same table since 2006-02), "Warsong Gulch"
(revision 5298624, 2006-11-13), "Alterac Valley" (revision 4644035, 2006-11-25), and warcraft.wiki.gg "Alterac Valley"
(its patch history, Blizzard's notes).

- Arathi Basin: "Collecting multiples of 200 resources (at 200, 400, 600, ...) = 10 rep (total 100 rep if you win)";
  on the holiday "multiples of 150 ... (total 130 rep if you win)". Ticks: 1 node 10 every 11 s, 2 nodes 10 every
  10 s, 3 every 6 s, 4 every 3 s, 5 nodes 30 every second; 2000 to win.
- Warsong Gulch: "Flag Capture - 35 reputation for entire team (10 extra reputation on a Battlegrounds Holiday for a
  total of 45)"; "Each side needs at least 5 players or the game will end after 5 minutes"; the spirit guide "casts a
  resurrection every 30 seconds".
- Alterac Valley, patch 2.3.0: "The Horde and Alliance now have a limited number of reinforcements available";
  "Bonus Honor in Alterac Valley is now only awarded during the battle for destroying enemy towers and slaying the
  enemy Captain. Upon conclusion of the battle, bonus honor is also awarded for intact towers, a surviving Captain,
  and for victory"; "Towers and Graveyards in Alterac Valley are now captured in 4 minutes (down from 5)"; patch
  2.4.0: "The time required for the first capture of Snowfall graveyard has been reduced from five minutes to four".
  The 1.12 page (2006-11) has no reinforcements: the battle ends when a general dies.

**Rule:** Arathi Basin's reputation every 200 resources (150 on the holiday); Alterac Valley's nodes fall five
minutes after an assault. **What changed (2026-11-21):** 160 and 120; four minutes (2.3.0's).

**Left (reported, not changed):** Alterac Valley's reinforcements (600 each, deaths, towers and captains costing them,
the mines' +1) and its end-of-match honor for surviving towers and captains are 2.3.0's design; in 1.12 the general's
death ends the battle and there is no count. Removing them reshapes alterac.d, a battleground module another
pass owns. Arathi Basin's ticks for one and two nodes: the 1.x page measured 11 s and 10 s where dmangos (and
CMaNGOS) have 12 s and 9 s; the page's per-second column (0.9, 1.0) is rounded, so the difference may be measurement;
unchanged. Warsong Gulch's flag times (10 s on the ground, 23 s to respawn) have no source.

## Smaller rules checked

- **The keyring** (world/inventory.d `keyringSize`): Blizzard's announcement of patch 1.11 (quoted on WoWWiki
  "Keyring", revision 3903237, 2006-11-17): "Level 1-40 = 4 slots, Level 41-50 = 8 slots, Level 51-60 = 12 slots".
  It went by level / 10, so a level 40 had 8 and a level 50 had 12; now by (level − 1) / 10.
- **Talent reset** (talenthandlers.d `talentResetCost`): WoWWiki "Talent" (2006-09): "a modest fee (which increases by
  5g each use, to a maximum 50g)": agrees with the 5-gold steps and the cap; the first 1 and 5 gold and the monthly
  decay have no source found.
- **Not found** for 1.12 (kept, documented in RULES-AUDIT.md): the corpse reclaim delay and radius, the six minutes to
  an automatic release, bones' hour, the 20 seconds of logging out, the duel's countdown and range, breath and
  fatigue's minute, drowning's and lava's damage, the fall damage formula, the flight speed, the speed stacking.
  WoWWiki's 1.x pages on these ("Death", "Breath", "Fatigue", "Fall damage", "Dueling") describe them without numbers.
