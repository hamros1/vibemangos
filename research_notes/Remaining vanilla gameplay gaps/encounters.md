# Encounter and quest fidelity

## Which raid mechanics have direct contradictions?

### Takeaway

Heigan, Sapphiron, and Gluth each have a player-visible difference with independently documented vanilla/Classic behavior. Their scripts and database bindings exist. Read-only inspection of the installed classicmangos.creature_template confirmed Heigan (15936), Sapphiron (15989), and Gluth (15932) bind to their namesake boss scripts, each with SpellList 0.

### Cited Findings

- Heigan lacks floor eruptions. The boss already teleports himself to the platform and channels Plague Cloud. The active schedule handles fever, mana burn, platform, ground and taunt. It omits the alternating hazardous floor sections that define the dance. Test with characters in two sections during ground and platform phases, checking damage and the change of the safe section. [Boss schedule and phase handler](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L896) [Blizzard's response about Heigan's dance floor](https://us.forums.blizzard.com/en/wow/t/heigan-the-unclean-naxx-bug-spot/762563) [Classic strategy](https://www.wowhead.com/classic/guide/heigan-the-unclean-naxxramas-raid-strategy) [Player's September 2006 recording](https://cdn.warcraftmovies.com/movieview.php?id=28057)
- Sapphiron casts Icebolts, then announces the breath and casts a dummy before landing. The script explicitly omits the damaging breath and shelter. The real-data encounter test deliberately ends coverage at Icebolt and landing. Test exposed versus geometrically sheltered players in the same cast, verify frozen targets and cleanup before the next cycle. Blizzard's Classic reference notes also identify Vanish as an avoidance case and explain why fewer than five blocks may spawn. [Air phase](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1893) [Coverage boundary](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realscripts_raids.d#L1210) [Classic guide](https://www.wowhead.com/classic/guide/sapphiron-naxxramas-raid-strategy) [Blizzard reference-client notes](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887?page=10)
- Gluth schedules Decimate 105 seconds after engaging and schedules it again 105 seconds after a successful cast. Blizzard specifically says Decimate is not time based. This is a behavior mismatch even though the spell is already cast and zombie chow reacts. Blizzard's post does not disclose the actual trigger. Gather original/Classic combat traces before prescribing an implementation. [First trigger](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1521) [Repeat trigger](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1551) [Blizzard, Abomination Quarter](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887?page=10)

### Inferences

- Implement and test shelter and breath as one unit. Adding only the damaging cast introduces an unavoidable raid hazard. A cast-only check would also miss Heigan's spatial pattern. [Sapphiron code](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1809)

### Gaps

- No raid with a live client was run for this audit. These findings use executable paths, bindings and sources. Exact Gluth trigger remains open.

## Which control mechanics change how raids play?

### Takeaway

Several specific encounters omit player-to-creature or boss-to-player control. Count encounter outcomes separately from whatever engine work they may share.

### Cited Findings

- Razorgore's egg phase is explicitly replaced by players clicking eggs themselves. Vanilla requires using the Orb of Domination to possess Razorgore and use Destroy Egg. The current real-data encounter test documents the substitution. Test that an ordinary click cannot break an egg, a controlled Razorgore can, and breaking the last egg ends control and starts the boss fight. [Egg use handler](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/blackwinglair.d#L299) [Current regression contract](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realscripts_raids.d#L518) [Classic raid guide](https://www.wowhead.com/classic/guide/razorgore-the-untamed-blackwing-lair-strategy)
- Faerlina's enrage exists, but the encounter script explicitly omits the mind-controlled Worshipper's Widow's Embrace. Classic players can sacrifice the controlled add to counter her frenzy. Test during an active frenzy, verifying the Worshipper dies and the frenzy is removed. [Faerlina script](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L523) [Original 40-player encounter](https://warcraft.wiki.gg/wiki/Grand_Widow_Faerlina_%28Classic%29)
- Kel'Thuzad's Chains mind control is explicitly omitted. Blizzard confirms the highest-threat player is a valid target. Test hostile control, release, faction cleanup and eligibility of the tank. [Kel'Thuzad script](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1942) [Blizzard reference-client notes](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887?page=10)
- Razuvious' script explicitly omits the mind-controlled understudy interaction. The existing real-data boss record tests two attack spell IDs. Blizzard confirms that understudies attack the boss and can miss. The control interaction is the missing part; creature template availability must be evaluated separately. [Razuvious](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/naxxramas.d#L1057) [Encounter test](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realscripts_raids.d#L1115) [Blizzard](https://us.forums.blizzard.com/en/wow/t/wow-classic-era-%E2%80%9Cnot-a-bug%E2%80%9D-list-updated-april-22-2021/175887?page=10)

### Inferences

- Razorgore makes a good first integration test for a controllable creature interacting with a game object. General charm, faction changes, possession action bars and boss-specific input handling need separate verification. [Current egg workaround](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/blackwinglair.d#L8)

### Gaps

- Do not claim all mind control or all raid encounters are absent. The local evidence specifically identifies the named mechanics.

## What do dungeon and quest checks establish?

### Takeaway

There is a data-backed Upper Blackrock Spire defect and a narrower quest-script candidate worth testing.

### Cited Findings

- Rookery Hatchers cast Disturb Rookery Egg (15746) during Solakar's waves; the NPC sweep lists that spell's object activation as unsupported, and also flags the fast variant (16556). The current core limits object activation to supported targeting shapes. Classic hatchers break eggs and release whelps, a reason to prioritize killing the hatchers. Test in the actual room with an intact egg near a Hatcher and another far away; check egg activation and whelp spawn. The installed DB binds mob 10683 to npc_rookery_hatcher. Evidence is for the NPC-triggered path, not every way a player can hatch an egg. [Hatcher script](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/blackrockspire.d#L860) [Known failure](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/tools/harness/realnpc-known.txt#L42) [Activation gate](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/spelleffects.d#L104) [Wowhead Classic UBRS, Solakar strategy](https://www.wowhead.com/classic/guide/upper-blackrock-spire-ubrs-dungeon-strategy-wow-classic)
- Quest retest candidate: The Balance of Light and Shadow (7622) implements the priest's peasant rescue, disease, archer and wave gameplay. The Eris script does not handle outside interference. Installed EventAI for the peasants and archers handles their movement, combat, disease, speech and shooting. The Cleaner is explicitly summoned in analogous hunter challenges. Vanilla player comments on the priest quest describe the Cleaner when other players interfere, with conflicting conditions for stationary healers. Reproduce an actively interfering outsider and compare with a stationary observer before deciding exact rules. [Eris handlers](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/easternplaguelands.d#L50) [Example hunter implementation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/burningsteppes.d#L319) [Firsthand player comments on the Classic quest](https://www.wowhead.com/classic/quest=7622/the-balance-of-light-and-shadow)

### Inferences

- The NPC sweep is strong coverage of isolated spell effects. Its source describes a quiet environment and scripted targets, which cannot establish overall raid movement, player control and encounter geometry. [Sweep design](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/realnpcsweep.d#L5)

### Gaps

- The entire quest catalog has not been traced. A classic quest row, named script, or individual passing spell does not establish a fully correct quest. The Cleaner finding is a verification candidate, separate from the confirmed encounter gaps above.
