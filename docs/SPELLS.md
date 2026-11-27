# One spell pipeline for every caster

How a spell is cast, whoever casts it: a player, a creature, a pet, a totem. The design, how it maps
onto the modules, and the steps by which the server was moved to it (with what each measured). It
continues docs/DESIGN.md's "One unit core": damage already reached every unit through one path
(`dealDamage`); this does the same for the rest of a spell.

For class trainer coverage, known gameplay discrepancies and a check for each affected rule, see the [1.12.1 trainer spell audit](research/TRAINER-SPELL-AUDIT.md).

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
* **What CMaNGOS does nothing with for a creature's cast is done as nothing**: a temporary enchantment
  (Crippling Poison), a lock (Opening Cage's), a skill step (Beast Tracking), Portal (unused since 1.2).
* **EventAI's `CAST_FORCE_TARGET_SELF` at another unit makes that unit cast the spell on itself**, triggered
  (CMaNGOS's `DoCastSpellIfCan`): a Death Talon Captain's Mark of Detonation marks the random player it picks.
  A player so made may cast a harmful spell at itself (`castForcedOnSelf`); no other cast may.
* **A creature's persistent area is made at its destination even with nobody there yet** (CMaNGOS's
  `EffectPersistentAA`): its Blizzard at a player's place, Starfall around itself.
* **A creature's crowd control sets its unit flags as the aura lands**, not at its next tick (CMaNGOS's
  `SetStunned`): a tenth of a second's stun (Arcane Explosion's on its caster) is seen.
* **A creature's trap** (`SUMMON_OBJECT_SLOT1` .. 4: a hunter mob's Immolation Trap) is its own: made by it at
  its level, sprung by its enemies stepping in, its spell cast by it at them.
* **Drunkenness** (`SPELL_EFFECT_INEBRIATE`, 256 a point: Booze Spit, Intoxicating Venom) is kept beside the
  gender in `PLAYER_BYTES_3`, wears off by 256 every 10 seconds, ends with death, is saved (`characters.drunk`)
  and comes back less for the time away (sober after 15 minutes), as CMaNGOS's `SetDrunkValue`. Its drunk-only
  invisibility detection is not done.
* **A spell's flight** (`SPELL_EFFECT_SEND_TAXI`: William Kielar's to Naxxramas) is free, starts within
  CMaNGOS's bound of the path's first node (a squared distance of 1000), takes the mount and a shapeshift off.
* **Every cone is as wide as `spell_cone` says** (by the spell's first rank; CMaNGOS's data, 60 degrees in front
  where it has no row), a player's and a creature's alike, and a negative angle is behind the caster (a dragon's
  Tail Sweep and Tail Lash, -82). Before, a player's cone was 120 degrees whatever the spell (Cone of Cold is 90)
  and a creature's 90, always in front.
* **An area spell's `MaxAffectedTargets` limits a creature's as it does a player's**: the one aimed at, then the
  nearest (`mostAffected`). A creature's area reached everyone in it before.
* **A creature's enemy area strikes what the players control in it**: their pets, guardians and totems, as it
  strikes the players (before, a boss's area passed a hunter's pet by). It does not strike the world's other
  creatures it is hostile to: CMaNGOS would, but the scripted fights between them are written for what they
  do now (Isillien's Mana Burn at Taelan and Tirion would stop "In Dreams"). A player's totem's area strikes every
  creature its owner may fight, as before.
* **A creature's spell at its friends around it or a destination** (Battle Command, Frenzied Command, Commanding
  Shout) reaches every creature there that is not its enemy and every player friendly to it, itself too, at most
  `MaxAffectedTargets` (CMaNGOS's assistable area targets); it reached its one target before. A party spell
  (Battle Shout) is a creature's own: it has no party (CMaNGOS's `FillRaidOrPartyTargets`).
* **A spell's reach is one rule for every caster** (`spellRangeResult`): its range and the two combat reaches; a
  melee ability (range 5 at most, of the melee class) as far as a melee swing, 5 yards at least; a range of 0 at
  another unit as far as the two reaches. A creature's reached its range, its own reach and a fixed 1.5 yards,
  a melee ability farther than a player's.
* **A creature's chained spell jumps** (Chain Lightning; Chain Heal to the most hurt friend), as a player's does,
  to units near the one before (`chainFrom`): at its enemies, the players and what they control; each jump struck
  less by the spell's multiplier. It struck its first target only before. The jumps are to units on its node.
* **A creature's area at the destination at itself** (`TARGET_LOCATION_CASTER_DEST`, then the enemies or friends
  there: Torch, Starfall, Mana Burn 22936) is around it even when it casts it at a player away from it: a creature's
  cast at a unit gives no destination, so CMaNGOS sets the destination at the caster. It was around the player.
* **A creature's area at its place in the database** (`TARGET_LOCATION_DATABASE`, `spell_target_position`) is
  there, on its map, as CMaNGOS's is: Onyxia's Deep Breath, each Breath of its chain at the next point across her
  lair. It was around her (or its target) unless a `SpellRule` said otherwise (Sapphiron's Frost Breath).
* **A creature swings its off hand** as CMaNGOS's does: when it holds a weapon there (310 creatures' equipment),
  its template forces it (`CREATURE_EXTRA_FLAG_DUAL_WIELD_FORCED`, 14) or Dual Wield (674) taught it
  (`Creature.canDualWield`). The off hand has its own timer, never within 200 ms of the main hand's, hits for half
  (the off-hand damage fields), shows as a left swing, and a parry hastens whichever hand swings next. Both hands
  miss 19% more, as a player's do with two weapons. A swing at a unit on another node says which hand and whether
  it dual wields (protocol 130). Not kept yet: a Dual Wield taught by a spell is lost in a crash or a migration
  (the template's flag and the off-hand weapon are not).

## Status

| Step | State | NPC sweep's known failures |
|---|---|---|
| before | two pipelines | 630 (101 with no creature to cast them) |
| 1. the caster, one effect switch | done | 621 |
| 2. damage, heals, power | done | 606 |
| 3. auras and their ticks | done | 556 |
| 4. what creatures lacked: wild objects, persistent areas, pets, items, spells taught, spawn, dispels, charges, extra attacks, totems, mana; the hit roll shared | done | 204 (101 with no creature to cast them) |
| 4b. the rest of the sweep's: object open, disturb and despawn, resurrection, quest credit, sanctuary, traps, Infernals, flights, drunkenness, Thundercrash, the cone of 54; the sweep's own misreadings (its player dying, debuffs seen as friendly, stunned casters) | done | 107: 101 with no creature to cast them, and six rockets whose object (180856) is not in the world database |
| 5. targets once | in part: one walk of an area's units (`unitsInArea`), one cone (`spellCone`, `inSpellCone`) and one target limit (`mostAffected`), one reach (`spellRangeResult`) and chains (`chainFrom`) for every caster, each saying only whom its spell is for; friends' areas for creatures; a creature still resolves its other implicit targets in `creaturecasting.d` (`targetsFor`), a player in `spellhandlers.d` (`go`, `areaTargets`) |  |
| 6. procs once | in part: every creature's auras proc now (a mob's Thrash, not only a pet's), through `creatureprocs.d`; a player's are `procs.d`'s, with its class rules, cooldowns and weapon checks |  |

Performance: the 500-player crowd (`tools/harness/bench.sh LABEL crowd 500`, release builds, run in turn
three times each on a machine with no compiler running) is the same before and after: loop busy 7.5, 7.5,
7.6% before and 7.6, 7.6, 7.5% after; tick 0.387, 0.391, 0.385 ms before and 0.389, 0.400, 0.386 ms
after; 113 to 114 KB allocated a tick both. The crowd casts few spells: the abstraction's cost there is
`Caster` values made per effect and per hit, with no allocation of their own.

Players and creatures can affect game objects named in `spell_script_target`, including
objects on another node. The selector honors each row's effect exclusions and applies a
shared target limit to local and remote objects. It supports nearest-object, caster-area
and database-destination selection. The object can play animation slots 0–3 or Onyxia's
Eruption animation, change its lock flag, or apply a door or button state such as the
alternate state used when the Zul'Farrak door is blown open. These effects can run
alongside other spell effects. A creature's open (a goober: Sharpbeak's cage, a spider egg) and
disturb (a trap's spell, or a button: Celebras's staff) use the object as a player's use does, without
what is the player's own (quest credit, a page); despawn takes it away (Despawn Putrid Mushrooms).

What a creature's cast does not do yet: effects that need a player's
spellbook, inventory or client.
