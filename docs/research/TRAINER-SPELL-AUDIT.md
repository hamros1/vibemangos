# Classic class trainer spell audit

All five discrepancies found at `15a8429` have fixes. The trainer loader also excludes both obsolete lessons from individual and template lists, so clients cannot view or buy them even when importing the original Classic DB. Existing characters retain their spellbooks.

Chain Heal now ranks both local and remote allies by missing hit points. Cluster protocol **80** carries the exact deficit between nodes. Deploy matching binaries on every node. Polymorph checks the creature's tap at cast start and completion, Freezing Trap shares its PvP timer with Scatter Shot and Wyvern Sting, cancelling Stealth removes enhanced Vanish stealth, and switching targets clears Overpower's reactive point.

[Rank-by-rank results and Classic references](TRAINER-SPELL-RANKS.md) · [Runnable targeted checks](../../tools/harness/trainer_spell_probe.d)

## Results after the fixes

| Check | Result |
|---|---|
| Trainer spell casts, using the same input IDs as the original audit | 1,264 of 1,264 passed. The two obsolete lessons no longer enter the server's trainer inventory. |
| Targeted spell and trainer checks | 16 of 16 passed, including the list shown by each trainer and the result of a direct purchase request. |
| Full player spell sweep | 1,980 of 1,983 passed. The three known failures were Fishing ranks tested on dry land. |
| Static effect and aura audit | 3,478 entries examined in the source data. Detect Magic's client-visible effect remains open. |

The cross-node Chain Heal regression gives a local ally a lower health percentage and a smaller absolute deficit than the remote candidate. Both bounce orders (remote then local, and remote then remote) select the intended recipients. A separate replication test checks that a remote player missing 150 HP appears to strangers as 25/100.

## Original reproductions at `15a8429`

| Class and spell | Expected behavior | Observed on the server |
|---|---|---|
| Shaman · Chain Heal | Each bounce prefers the eligible ally missing the most hit points. | Cast rank 3 on the caster with three nearby injured allies. From starting health of 300/1,000, 2,400/4,000 and 400/1,000, they ended at **615, 2,400 and 552**. The ally missing 1,600 HP received nothing. Both the local-player and remote-replica paths compare health percentages. The reproduction used local players. |
| Mage · Polymorph | An ungrouped Mage cannot sheep a creature another player has tapped. | Rank 1 landed and applied the sheep aura to a Kobold Vermin with another player recorded as the tap owner. The same cast succeeded on the unclaimed control. |
| Hunter · Freezing Trap | In PvP its effect shares diminishing returns with Scatter Shot and Wyvern Sting. | The runtime category function returns a trap category for all three Freezing Trap effects. It returns no category for Scatter Shot and all three Wyvern Sting ranks. Successive effects therefore cannot share that timer. This check exercised the category function with real spell rows. |
| Rogue · Vanish | Manually cancelling Stealth after Vanish removes both buffs. | After rank 1 Vanish, both Stealth (1784) and the triggered Vanish aura (11327) were present. The client cancel request removed Stealth alone. |
| Warrior · Overpower | Switching away from the enemy that dodged clears the opportunity. | A dodge granted one reactive point on the original target. After selecting another enemy and switching back, that point was still available on the dodger. The probe inspected the reactive state directly. |

Chain Heal’s target selection is specified in the original [1.12 patch notes](https://wowpedia.fandom.com/wiki/Patch_1.12.0). The other four rules are explicitly documented in [Blizzard’s Classic Era reference-client clarifications](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887). The relevant implementations are [chain target selection](../../source/dmangos/world/spellhandlers.d), [diminishing returns](../../source/dmangos/world/diminishing.d), [aura cancellation](../../source/dmangos/world/aurahandlers.d) and [target selection](../../source/dmangos/world/inworld.d).

## Original trainer purchases and coverage gaps

- **Warrior trainers sell Elemental Fury at level 6.** A fresh Warrior bought lesson 1229 from trainer 5479, paid 100 copper and learned 877. The effect targets the caster’s pet. The Shaman talent of the same name is 16089. Spell 877 was the trainer sweep’s one known failure.
- **Paladin trainers sell zzOLDHip Shot III at level 8.** A fresh Paladin bought lesson 1998 from trainer 5491, paid 100 copper and learned 1973. The local client calls it obsolete. The generic sweep counted it as a successful Mage cast. These two purchases used the actual trainer opcode. Both lesson rows are also present in the installed server’s world database.
- **Hunter Trueshot Aura ranks 2 and 3 work in the basic Hunter cast test.** The generic sweep selected a Mage for 20905 and 20906. A separate level-60 Hunter successfully cast each rank and acquired the aura. Party-wide attack power and range remain separate assertions.
- **Mage Detect Magic remains open.** Rank 1 (2855) passed the generic aura check. The static audit lists aura type 100 as a known gap. A graphical 1.12.1 client still needs to confirm whether casting it reveals the target’s beneficial effects to the intended viewers. [Existing audit entry](../../tools/harness/spell-audit-known.txt)

## Audited inventory at `15a8429`

The inventory uses the NPC’s trainer class and combines individual and template lessons, including portal trainers and trainer-taught upgrades to talents. Each spell ID is counted once per class. Shared passives account for the difference between **1,281 class/rank entries** and **1,274 distinct IDs**. There are 407 class/name pairs. The passives excluded from the ordinary cast sweep are Dual Wield, Parry, Mail, Plate Mail, Feline Grace, Safe Fall, Detect Traps and Reincarnation.

| Class | Trainer entries | Distinct names | Additional evidence |
|---|---:|---:|---|
| Druid | 180 | 45 | Ferocious Bite’s damage calculation includes attack power, combo points and surplus energy. A focused damage test exercises that calculation. |
| Hunter | 120 | 46 | Recast both misclassified Trueshot Aura ranks as a Hunter and checked all seven spell rows involved in the trap interaction. |
| Mage | 159 | 47 | Checked Polymorph against an unclaimed and a foreign-tapped target. Existing real-data tests also exercise Frostbolt cast time, mana cost, damage and threat modifiers. |
| Paladin | 137 | 47 | Exercised the trainer buy path. Existing real-data checks cover Improved Lay on Hands armor and cooldown changes. |
| Priest | 177 | 39 | Real-data tests check the threat of Shadow Word: Pain ticks with Shadow Affinity and the armor buff triggered by a Flash Heal crit with Inspiration. |
| Rogue | 106 | 47 | Checked the two aura IDs after the client cancelled Stealth. Existing focused tests check Eviscerate against combo points and attack power. |
| Shaman | 158 | 47 | Compared three unequal health pools for Chain Heal. Separate real-data tests exercise Reincarnation through death, self-resurrection and the talent-adjusted cooldown. |
| Warlock | 145 | 55 | Real-data tests check Curse of Agony’s changing tick amounts and total damage, and Improved Life Tap’s effect on mana gained. |
| Warrior | 99 | 34 | Tested Overpower’s reactive point through a target switch and the obsolete trainer lesson through purchase. |

The original [1.12 release notes](https://warcraft.wiki.gg/wiki/Patch_1.12.0) also document Ferocious Bite’s attack-power scaling and Reincarnation’s cooldown display. The Druid test checks damage, and the Shaman test checks the resurrection and server cooldown. Client presentation needs a separate observation.

## Data and interpretation

The audit used the extracted English 1.12.1 `Spell.dbc` and `SkillLineAbility.dbc`, plus the local Classic DB **Melting Pot v2** for core z2815. For NPCs with trainer flag 0x10 and class trainer type 0, join `npc_trainer` by creature entry and `npc_trainer_template` by trainer template ID. Resolve a teaching spell to the last nonzero Learn Spell target with implicit target 0 or 1, as the server’s [trainer loader](../../source/dmangos/world/npcdata.d) does. The inventory describes available lessons across all races, levels and prerequisites. Quest rewards, talent-only ranks, pet trainers and book-only spells are outside this inventory.

The rank ledger compares local descriptions rendered by [spellspec.py](../../tools/spellspec.py) with Wowhead’s Classic tooltip for each spell ID. We retrieved **1,273 of 1,274** online records. Across class/rank entries, 824 descriptions matched after text normalization and another 351 matched after accounting for level scaling or formula rendering. Of the remainder, 88 had other text or number differences, 12 contained seasonal alternatives, five lacked comparable descriptions, and obsolete spell 1973 had no online record.

Examples from the 88 include unresolved resurrection-mana placeholders in the local documentation generator, singular/plural wording in dispels, and differently rendered weapon-speed or level-dependent amounts on Seals and Flametongue. Those rows retain a “different” result in the ledger. Reconciling the text alone cannot establish a damage, healing or targeting defect. Seasonal overrides were excluded as authorities for 1.12.1 gameplay. The audit does not exhaust every rank’s combat permutations, proc distribution, faction restriction, interaction with talents, cluster handoff or graphical UI effect.

## Repeat the tests

Run the following from the repository root on a configured harness machine. The first command builds matching unit-test objects. The second uses the private harness database and reports each targeted rule. A failing rule produces a failing exit status. The probe includes controls for the caster’s tap, a party member’s tap, a tap changing during a cast, and reselecting the same Overpower target.

```sh
tools/harness/check.sh --quick
tools/harness/trainer-spells.sh
```

To repeat the trainer-only cast count with the original input IDs, run this in Bash after building the unit suite. The filter applies to the cast sweep. The targeted rules still run.

```sh
trainer_ids=$(rg -o 'classic/spell=[0-9]+' docs/research/TRAINER-SPELL-RANKS.md | cut -d= -f2 | sort -nu | paste -sd, -)
DMANGOS_SWEEP_ONLY="$trainer_ids" tools/harness/trainer-spells.sh
```

For the standard real-data player spell sweep, run `tools/harness/check.sh`. Before the fixes the unrestricted player sweep reported **1,985 casts, 1,981 passes and four known failures**. Three were Fishing ranks cast on dry land. All three now cast over extracted terrain near Stormwind and verify the bobber, bite and fishing loot through the client. The current sweep passes **all 1,983 casts**. The separate static effect/aura audit examined 3,478 learnable entries with one known aura gap. These larger counts include other ways of learning spells and triggered spells. [Sweep implementation](../../source/dmangos/world/realspellsweep.d) · [Known failure list](../../tools/harness/realspell-known.txt)
