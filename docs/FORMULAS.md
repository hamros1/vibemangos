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
  Fear, Psychic Scream, Howl of Terror, Frostbite), by its `ProcChance` (100 in the data).
- Shadow Vulnerability (Improved Shadow Bolt) lasts its four charges, one a damaging hit of the kinds its proc flags
  take ("until 4 non-periodic damage sources are applied").
- Spirit of Redemption: the killing blow leaves the priest at 1 health in the spirit's form (27827, with 27792 and
  27795) for its 10 seconds; then the priest dies. Its holy spells cost nothing (27792's
  `MOD_POWER_COST_SCHOOL_PCT`, -100% for holy).
- Create Healthstone with Improved Healthstone: the stone whose own spell heals 10% or 20% more (the item data's
  stones 19004 to 19013).
