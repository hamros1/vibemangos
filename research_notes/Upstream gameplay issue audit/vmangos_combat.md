# vMaNGOS combat, spells and class mechanics

## Which totem reports apply to DMaNGOS?

### Takeaway

Searing Totem was pulling idle creatures and joining unrelated fights. A moved totem was also eligible to draw proximity aggro. DMaNGOS now has focused coverage for both rules and for the difference between player and creature owner death. [Searing Totem #2862](https://github.com/vmangos/core/issues/2862), [proximity aggro #2863](https://github.com/vmangos/core/issues/2863), [owner death #2864](https://github.com/vmangos/core/issues/2864).

### Cited Findings

- `totemsAct` used the nearest hostile creature regardless of its threat list. Player-owned active totems now require a threat entry from the owner, a group member, or a pet or guardian belonging to either. A zero-threat entry still counts as engagement. Existing raid group membership and GUID-based threat references cover the same criterion. [Classic video linked by the reporter](https://youtu.be/Bf3lbfSsNKs?list=PLdYVrYJB1PTHV-apnXYXkRhCI-oFR6QIc&t=2325), [vMaNGOS initial targeting fix](https://github.com/vmangos/core/pull/2867).
- `Map.creatureNoticeable` accepted summoned creatures or creatures with another faction, both of which could apply to a totem. The exclusion applies only to proximity detection. A defensive response to a direct attack still follows the combat path. The regression also checks that a hostile creature still notices an escortee. [vMaNGOS proximity fix](https://github.com/vmangos/core/pull/2866).
- `Character.playerDied` calls `petsOnLeave`, which removes player-owned totems. The dead creature path in `Creature.tick` skips `CreatureAI.update` and its `updateTotems` cleanup branch. A creature-owned totem remains spawned after owner death and its own temporary spawn timer determines despawn. [vMaNGOS creature-owned totem fix](https://github.com/vmangos/core/pull/2943).

### Inferences

- The #2862 issue describes the player or party already fighting the enemy. Checking the enemy's threat list captures that directly, including an enemy that has acquired a target before any damage lands. The original vMaNGOS patch tested only the victim's general combat state. [Issue #2862](https://github.com/vmangos/core/issues/2862), [vMaNGOS initial targeting fix](https://github.com/vmangos/core/pull/2867).

### Gaps

- A creature-owned active totem is scheduled by its owner's AI. Its ability to cast independently after its owner's death was outside the survival check in #2864. [Issue #2864](https://github.com/vmangos/core/issues/2864).

## Does Net reduce the victim's threat?

### Takeaway

Net rooted the victim but did not change threat. Net Guard now reduces the victim's threat on the casting creature by 50%. [Issue #2737](https://github.com/vmangos/core/issues/2737).

### Cited Findings

- The installed Classic world data gives Net `6533` an Apply Aura root and a Trigger Spell effect for Net Guard `11920`. Net Guard applies a dummy aura. The SQL spell script `spell_hate_to_half` belongs to `19707`, and there were no `spell_scripts` or `dbscripts_on_spell` rows for Net or Net Guard. A spell ID binding now processes the Net Guard aura application. [vMaNGOS Net Guard change](https://github.com/vmangos/core/commit/619b0d7278dcf084b98876a4c597d8deb635ea4c).
- Blackrock Outrunner `485` has a real EventAI Net entry. The regression casts real Net and checks both auras, 200 to 100 threat for its victim and 150 remaining threat for a second player. [Issue #2737](https://github.com/vmangos/core/issues/2737).

### Inferences

- Net Guard is the appropriate application hook because the original Net root and dummy trigger may be resolved separately from threat modification. [vMaNGOS Net Guard change](https://github.com/vmangos/core/commit/619b0d7278dcf084b98876a4c597d8deb635ea4c).

### Gaps

- The focused test exercises one successful cast. It does not exercise a forced reapplication with Net Guard already active. [Issue #2737](https://github.com/vmangos/core/issues/2737).

## Which other spell issues have a corresponding DMaNGOS path?

### Takeaway

Relentless Strikes now restores energy on a lethal five-point finisher. Furious Howl adds rolled damage to queued weapon abilities, and a shield that takes all the damage also prevents Sweeping Strikes from spending a charge. Chain Heal's most-injured group-member targeting is already implemented. [Relentless Strikes #2331](https://github.com/vmangos/core/issues/2331), [Furious Howl #3172](https://github.com/vmangos/core/issues/3172), [Sweeping Strikes #2654](https://github.com/vmangos/core/issues/2654), [Chain Heal #3059](https://github.com/vmangos/core/issues/3059).

### Cited Findings

- `classAfterEffects` dispatches add-target-trigger auras after damage. `targetTriggers` previously required the struck unit to be alive even when the triggered spell restores energy to the rogue. The finisher path already snapshots `castCombo`. Relentless Strikes now restores the rogue's own energy when a finisher kills its target. The real-data regression verifies one 25-energy return from a five-point Eviscerate on a creature with 1 health. [Relentless Strikes #2331](https://github.com/vmangos/core/issues/2331), [vMaNGOS fix](https://github.com/vmangos/core/commit/4b0bbe2eb67c4fca8a82716442e591d25684892c).
- Furious Howl player buffs `24597`, `24603`, `24604` and `24605` have one charge and a physical `modDamageDone` aura in the installed world data. DMaNGOS now includes flat physical damage modifiers in the player's base weapon roll. The seeded comparisons verify the exact bonus on Raptor Strike and Heroic Strike and check the next attack after the charge is spent. The upstream migration removes old `spell_mod` rows specific to vMaNGOS. [Furious Howl #3172 with Classic evidence](https://github.com/vmangos/core/issues/3172), [vMaNGOS fix](https://github.com/vmangos/core/commit/eb2124617a54d67e83e6ad26d1a7f87e1e03e5ab), [CMaNGOS weapon calculation](https://github.com/cmangos/mangos-classic/blob/master/src/game/Entities/Unit.cpp).
- The original Sweeping Strikes report uses an NPC with Power Word: Shield. DMaNGOS now uses the same shield calculation for creatures and players, and it applies the remaining damage and absorbed amount on melee swings and weapon abilities. The test checks that a white swing and Heroic Strike absorbed in full leave all five charges, while a partial absorb spends one charge and copies the remaining damage. [Sweeping Strikes #2654 with Classic evidence](https://github.com/vmangos/core/issues/2654).
- Chain Heal's cast builds the group when the primary target is in it. `friendlyChainTargets` selects eligible candidates by greatest health deficit, including eligible replicas. This covers the central priority rule in the report. [Chain Heal #2851](https://github.com/vmangos/core/issues/2851), [Chain Heal #3059](https://github.com/vmangos/core/issues/3059).

### Inferences

- Treat Furious Howl's rank data and the queued weapon path as a separate DMaNGOS case. The upstream SQL deletion is specific to vMaNGOS. [vMaNGOS fix](https://github.com/vmangos/core/commit/eb2124617a54d67e83e6ad26d1a7f87e1e03e5ab).

### Gaps

- Further work should reproduce candidate class issues in the local combat harness before changing shared proc or mitigation semantics. The tagged spells examined here came from the first 100 open and closed issues returned by the vMaNGOS `spell` label query. [vMaNGOS spell issues](https://github.com/vmangos/core/issues?q=is%3Aissue+label%3Aspell).
