# Combat and professions

## Which class abilities have identifiable gaps?

### Takeaway
Hunter trap concealment, rogue Disarm Trap and mage Detect Magic have distinct missing behaviors. The first two form a single practical PvP milestone. These are source and database findings, not live reproductions.

### Cited Findings

- **Rogue Disarm Trap (1842) does not deactivate a hunter trap.** The 1.12.1 client describes a two-second disarm with Thieves' Tools. A read-only query of the installed classicmangos spell_template found effect 33 (open lock), misc value 4. Freezing Trap game-object templates 2561, 164876 and 164877 all have type 6 (trap) and lock 12. The handler checks the lock and calls sendGameObjectLoot, whose switch returns for trap objects without deactivating or removing them. This is narrower than a general lockpicking issue. [Classic spell record](https://www.wowhead.com/classic/spell=1842/disarm-trap) · [1.12 client tooltip](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/docs/spells/rogue.md#L412) · [handler](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/gameobjecthandlers.d#L413) · [missing target case](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/gameobjecthandlers.d#L431).
- **Enemy hunter traps bypass stealth detection.** The 1.10 patch notes put hunter traps under stealth detection rules and update Detect Traps accordingly. The server checks player and creature visibility, but game objects, including replicated game objects, pass the visibility predicate unconditionally once in range. The installed Freezing Trap templates above set data9 to 1. Detect Traps (2836) is in the data as a stealth-detection aura. Ordinary creatures already *can spring hunter-placed traps*, a distinction worth preserving when reading old docs. [Patch 1.10 notes](https://warcraft.wiki.gg/wiki/Patch_1.10.0) · [contemporary patch-note copy](https://www.wowinterface.com/forums/showpost.php?p=19010&postcount=9) · [visibility decision](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/map.d#L1026) · [object-create filtering](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/map.d#L3183) · [trap activation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/effecthandlers.d#L721).
- **Mage Detect Magic (2855) lacks server-side support for revealing beneficial effects.** The local DBC-derived tooltip and Classic spell record say it reveals beneficial magic for two minutes. The installed spell row applies aura 100; the repository lists that specific aura and client-visible effect as its remaining static spell-audit exception. The missing piece is the visible result on the target, rather than learning the spell. Exact initial display and viewer scope deserve a clean 1.12 client capture. [Classic spell record](https://www.wowhead.com/classic/spell=2855/detect-magic) · [DBC-derived tooltip](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/docs/spells/mage.md#L470) · [audit exception](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/tools/harness/spell-audit-known.txt#L3).

### Inferences
- Test a hostile hunter and rogue with a third character as control. Record object visibility at two distances before and after the rogue learns Detect Traps. Disarm from outside trigger range with tools, then walk across and confirm the trap cannot fire. Repeat with a fresh armed trap as control. [Disarm Trap](https://www.wowhead.com/classic/spell=1842/disarm-trap) · [trap activation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/effecthandlers.d#L692).
- Test Detect Magic against a hostile target with a known magic buff, comparing target-frame visibility before cast, during the debuff and after expiration. [Spell 2855](https://www.wowhead.com/classic/spell=2855/detect-magic).

### Gaps
- The exact detection distance and whether a specific client UI suppresses already-delivered trap objects have not been measured. The code-level gap is specifically the missing per-viewer server check. [Visibility code](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/map.d#L1026).

## Which stateful combat behavior is lost between nodes?

### Takeaway
Partially spent proc charges reset when persistent player auras are rebuilt. This changes actual combat output during routine world-node handoffs.

### Cited Findings
- **Shaman Lightning Shield is a concrete example.** Spell 324 grants three balls, one expended on an eligible hit. The installed world database gives procCharges=3. Character aura saving writes zero into the SQL remaincharges column. Loading does not select that column. Reconstructing the aura restores the spell's full procCharges. Handoffs use these same save/load functions. [Classic spell record](https://www.wowhead.com/classic/spell=324/lightning-shield) · [actual SQL save](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/characterdb.d#L421) · [SQL load](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/characterdb.d#L753) · [reconstruction](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/auras.d#L929) · [migration departure](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/inworld.d#L275) · [migration arrival](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/inworld.d#L449).

### Inferences
- Trigger Lightning Shield twice at intervals greater than its internal cooldown, transfer nodes without recasting, then verify exactly one more retaliation. A player should never gain a charge merely by walking to a new simulation owner. Run the equivalent logout round trip for a still-active buff. [Existing test for the within-session case](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realclass_paladin_shaman_druid.d#L1635).

### Gaps
- The save/load mechanism applies to other charge-limited persistent buffs, but each buff's persistence flags should be checked before naming it as affected. [Persistence eligibility](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/aurahandlers.d#L833).

## What do existing spell and profession checks establish?

### Takeaway
The recorded run passed all 1,983 player casts in its sweep. The assertions do not cover every behavior observable by a client. I did not establish a separate profession-wide omission.

### Cited Findings
- The sweep tests selected cast outcomes, aura presence, duration, spell costs, etc.; it includes fishing with extracted terrain. The last available real-data log (previous run, not rerun for this research) reports 1,983/1,983. These counters cannot establish that client buff display and cross-node aura persistence work. [Sweep scope](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realspellsweep.d#L2) · recorded run (`$DMANGOS_HARNESS/unittest/real.log`).
- Hunter happiness, loyalty loss, and an unhappy pet leaving or turning on the owner have a source implementation. Blizzard describes that feature. It should not be counted as wholly missing. [Blizzard manual](https://us.media.blizzard.com/manuals/wow/wow-classic-manual-enUS.pdf) · [pet behavior](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/pethandlers.d#L1236).

### Inferences
- Useful new coverage checks the observer's packets or UI, trap state after a cast, and whether an already-consumed charge stays consumed. [Cast sweep scope](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realspellsweep.d#L8).

### Gaps
- No exhaustive item-by-item engineering, recipe source, or pet ability inventory was performed here. No claim of profession or pet completeness follows from the sampled coverage. [Sweep definition](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realspellsweep.d#L4).
