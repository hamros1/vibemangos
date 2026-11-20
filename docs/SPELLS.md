# One spell pipeline for every caster

How a spell is cast, whoever casts it: a player, a creature, a pet, a totem. The design, how it maps
onto the modules, and the steps by which the server was moved to it (with what each measured). It
continues docs/DESIGN.md's "One unit core": damage already reached every unit through one path
(`dealDamage`); this does the same for the rest of a spell.

## The problem

Before this work a spell had a pipeline per kind of caster:

* **A player's**: the `Character` mixins. `spellhandlers.d` (checks, cast time, `go`: cooldowns, cost,
  targets, hit rolls, `SMSG_SPELL_GO`, the effect switch `doEffect`), `effecthandlers.d` (threat, charges,
  drains, extra attacks, ...), `aurahandlers.d` (auras on players and on the creatures players cast at,
  their ticks), `classspells.d` and `physicalclasses.d` (the class rules), `procs.d` (the proc engine).
* **A creature's**: `creaturecasting.d` (mixed into `CreatureAI`) with a `go` and an effect switch of its
  own, two dozen effects done and the rest in an explicit list of effects "not done by a creature's cast
  yet"; `creatureprocs.d` (a pet's procs only).
* **A pet's and a totem's**: the creature's, with their owner's talents patched in at each use.

Every fix had to be made twice, and creatures lacked most of what players had. The NPC sweep
(`realnpcsweep.d`, its known failures in `tools/harness/realnpc-known.txt`) measures the gap: 630 spells
creatures cast did not do what their data says.

## The stages

A cast goes through the same stages whoever casts it:

| Stage | What happens | Kind-specific |
|---|---|---|
| **Cast** | checked (alive, not busy, crowd control, range, power, the target), its cast time counted down, `SMSG_SPELL_START` | a player's cooldowns, reagents, items, client errors (`SMSG_CAST_FAILED`); a creature's cast flags (`castTriggered`, `castAuraNotPresent`, ...) |
| **Go** | the cost paid, `SMSG_SPELL_GO` with who was hit and missed, the misses logged | a player's cooldowns, reagents, ammunition, combo points, `SMSG_CAST_RESULT`; a creature's mana |
| **Targets** | each effect's implicit targets resolved to units (the caster, its target, an area, a cone, a chain, its master, its pet, a script's targets) | none: units are units |
| **Hit roll** | each hostile target rolls once: the spell hit table (magic), the attack table (weapons), reflects and full resists | none |
| **Effects** | each effect on each target it reached, through one `final switch` | the few effects that need what only one kind has (a player's inventory, spellbook, client) |
| **Auras** | values (the caster's spell power, its talents), duration, applied to a unit; ticks done by whoever cast them | what an aura does to a player (stats, forms) or a creature (its movement, its look) is the target's side |
| **Procs** | the caster's auras that proc on what it did, and the victim's | a player's class rules (Seals, Nightfall) |

## The caster

`dmangos.world.caster.Caster` is a value naming who casts, as `UnitRef` names a unit: its kind, the
`Character` or the `CreatureAI` (with its `Creature`), its map and the world (`WorldContext`). It is made
where a cast needs it (`Caster.of(character)`, `Caster.of(ai)`) and never kept. Like `UnitRef`, what
differs by kind is a method with a `final switch`, so the compiler says when a kind is missing; there
are no virtual interfaces.

What every caster has, the same for each kind:

* who it is and where: `guid`, `unit` (its `UnitRef`), `level`, `position`, `fields`, `auras`, `fighter`,
  `relating` (for `canAttack`), `alive`, `map`, `context`;
* telling who sees it: `sendAround` (a player's client too), `flush` (its changed fields);
* the numbers its spells get: `effectMod`, `spellMod`, `modDuration` (a player's talents; a pet's or a
  totem's owner's, as `modOwner` names it; none for any other creature), `spellPower`, `healingPower`,
  `spellCritChance`, `hitBonus`, `targetResistance`, `damageDone` (its `MOD_DAMAGE_PERCENT_DONE`);
* casting again: `castTriggered` (a triggered spell at a unit).

The hooks a kind supplies, everything else being written once:

| Hook | Player (`Character`) | Creature (`CreatureAI`, a pet's and a totem's too) |
|---|---|---|
| paying for a cast | power (or health), reagents, an item's charges, ammunition | mana; none if it has no mana pool (see "Decisions") |
| cooldowns | its spellbook's, by spell, category and the global one; saved | its AI's own timers (EventAI, spell lists) |
| what its client is told | `SMSG_CAST_RESULT`, `SMSG_CAST_FAILED`, combo points | nothing |
| its class rules | `classspells.d`, `physicalclasses.d`, `petauras.d` | none |
| scripts and AI | its spell scripts, quest credit at a cast | its EventAI and script hear whom it hit and killed (`spellHitTarget`, `KilledUnit`) |
| what only it has | inventory, spellbook, pets, duels, far sight, totems in slots | none of those |

Where a target's kind matters (an aura on a player changes its stats; on a creature its flags and
movement), the code branches on the target's `UnitRef`, not on the caster.

## The modules

| Module | What it is |
|---|---|
| `caster.d` | `Caster`: the caster abstraction and its hooks |
| `spelleffects.d` | the effect stage: `applyEffect`, the one `final switch` over `SpellEffect` for every caster, and the effects that need no more than a caster and units (damage, heals, power, auras, threat, interrupts, dispels, summons, movement, teleports, ...) |
| `spellhandlers.d` | the player's side of the stages that stay its own: the opcodes, `checkCast`, cooldowns, `go`'s costs and client packets; it calls the shared stages |
| `creaturecasting.d` | the creature's side: its cast flags and checks, cast time, mana, its script's notifications; it calls the shared stages |
| `effecthandlers.d`, `aurahandlers.d`, `classspells.d`, `physicalclasses.d`, `procs.d` | what is a player's own: its auras' effects on its stats, its class rules, its proc engine's class hooks |

## Steps

Each step passes the whole test suite: the unit tests, the real-data tests (`realspelltests.d`,
`realclass*.d`, `realrules*.d`), the player sweep (`realspellsweep.d`) with no new failure, and the NPC
sweep with no new failure.

1. **The caster and one effect switch.** `Caster`; the player's `doEffect` and the creature's switch
   become one `applyEffect` in `spelleffects.d`. For the effects both had, both bodies first sit in the
   one case behind the caster's kind, then are merged one by one into a body written once.
2. **Damage, heals and power, once.** Spell damage to a unit (`spellDamage`: the caster's spell power,
   modifiers, the victim's, crit, armor or resistance, absorbs, the log, `dealDamage`, procs) replaces the
   player's two paths (to a creature, to a player) and the creature's; heals, energize, drains, burns and
   leeches the same.
3. **Auras, once.** The values of a cast aura (the caster's spell power over time, its talents), its
   duration and its application to a unit; and each periodic tick done for whoever cast it: a creature's
   damage over time on itself, a friend or another creature ticks.
4. **The effects creatures lacked**, each written once over the caster: persistent areas, summoned
   objects, totems, charges, dispels, transforms on creatures, energize, extra attacks and the rest of
   the NPC sweep's causes.
5. **Targets and the hit roll, once.**
6. **Procs, once.**

## Decisions

Where the behaviour had to be decided, the tooltip and the data are the specification, then the
primary sources (docs/FORMULAS.md); CMaNGOS and vmangos are second opinions.

* **A creature without a mana pool casts its mana spells.** Lucifron (warrior class, no mana) casts Shadow
  Shock (19460, 85 mana) in every account of the fight, as do the other 37 such spells' casters. vmangos
  lets a creature that is not a pet cast a spell of a power it has none of (`Spell::CheckPower`: "creature
  without mana (unit class warrior)", and any power other than mana); CMaNGOS refuses it. A pet pays.

* **A creature's spells crit** at the 5% base CMaNGOS gives every unit that is not a player
  (`Unit::GetCritChance`), more by its auras; a weapon ability as its melee does.
* **Only a player's cast gains combo points** (CMaNGOS's `EffectAddComboPoints`); a creature's Backstab
  and Gouge do the rest of what they do.
* **A creature's create-item and learn-spell effects** give the item to, and teach the spell to, the player
  they are aimed at (CMaNGOS's `DoCreateItem`, `EffectLearnSpell`: `unitTarget`).
* **A dead target gets no aura and is not drained** (CMaNGOS); a creature's spell whose damage kills the
  NPC sweep's player before its debuff lands is listed with that note.
* **A creature's active totems** cast at the players and creatures it fights; a player's at creatures, as
  before.

## Status

| Step | State | NPC sweep's known failures |
|---|---|---|
| before | two pipelines | 630 (101 with no creature to cast them) |
| 1. the caster, one effect switch | done | 621 |
| 2. damage, heals, power | done | 606 |
| 3. auras and their ticks | done | 556 |
| 4. what creatures lacked: wild objects, persistent areas, pets, items, spells taught, spawn, dispels, charges, extra attacks, totems, mana; the hit roll shared | done | 204 (101 with no creature to cast them) |
| 5. targets once | not yet: a creature still resolves its implicit targets in `creaturecasting.d` (`targetsFor`), a player in `spellhandlers.d` (`go`, `areaTargets`) |  |
| 6. procs once | in part: every creature's auras proc now (a mob's Thrash, not only a pet's), through `creatureprocs.d`; a player's are `procs.d`'s, with its class rules, cooldowns and weapon checks |  |

Not done by a creature's cast yet (`doneBy`): activating game objects, teleports facing the caster,
leaps, taxis, inebriation, pulls, and the effects only a player's spellbook, inventory or client make sense
for (duels, taming, pickpocketing, enchanting, far sight...).
