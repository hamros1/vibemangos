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
