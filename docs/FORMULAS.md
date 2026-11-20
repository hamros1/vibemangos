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
