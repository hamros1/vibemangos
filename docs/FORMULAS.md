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
- **Last Stand:** 30% of the maximum health, granted as health too, and taken back when it ends ("temporarily grants
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
