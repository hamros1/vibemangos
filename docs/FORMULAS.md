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
