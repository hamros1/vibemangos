# World systems and PvP

## What is missing from Alterac Valley?

### Takeaway

The match, resource turn-ins and faction lords exist. Three assault systems and the summoning ritual represent distinct missing player activities.

### Cited Findings

- Cavalry requires capturing mounts and delivering hides, then an eligible player orders the charge. Mine-supply deliveries unlock a ground assault. Wing Commander rescues and faction drops unlock aerial support. The emulator identifies all three as unfinished and its actual turn-in handler only advances armor upgrades and faction-lord offerings. The installed Classic-DB includes Wing Commander Slidore (13438) and Stormpike Ram Rider Commander (13577). The missing outcome is deployment of the assault. [Wowhead's original Classic strategy guide](https://www.wowhead.com/classic/guide/alterac-valley-battleground-strategy-wow-classic) · [Alterac rules and current scope](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/alterac.d#L22) · [Quest-reward implementation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/alterac.d#L282)
- A second problem affects a feature marked implemented. The 200th offering calls Ivus or Lokholar immediately. Classic's final hand-in instead starts an escort to the Field of Strife followed by a ten-player summoning ritual. [Faction Lords in the Classic guide](https://www.wowhead.com/classic/guide/alterac-valley-battleground-strategy-wow-classic) · [Threshold handler](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/alterac.d#L298) · [Immediate summon](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/alterac.d#L490)

### Inferences

- Acceptance tests. In separate matches, supply each branch, give the faction order, and verify the correct units deploy and attack. For Ivus and Lokholar, verify the summoners start walking after 200 offerings, nine ritual participants cannot summon and the tenth completes exactly one summon.

### Gaps

- Resource costs and deployment cooldowns should be checked against the 1.12 data when implementing. Examples in the Classic strategy guide are useful behavioral references.

## What is missing from shared-world events and matchmaking?

### Takeaway

The original Scourge Invasion needs its zone encounters. Cross-realm battlegrounds need matchmaking across distinct realms.

### Cited Findings

- Blizzard describes the patch 1.11 event as destroying undead and crystals to clear a necropolis in six possible zones. Local read-only data inspection found game_event 17 and 89–99 for this content, including the six zones and victory milestones. Thirteen creature_template rows bind to scourge_invasion_* names, including Necrotic Shard (16136), Damaged Necrotic Shard (16172), Cultist Engineer (16230), Necropolis Relay (16386) and Necropolis (16401). No source module registers these named creature scripts. The module registry and three existing support spells show why the event is partial. [Blizzard's description and six zones](https://us.forums.blizzard.com/en/wow/t/ptr-scourge-invasion-test-is-underway/679484) · [Registered script modules](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/package.d#L82) · [Existing invasion spells](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/worldspells.d#L150) · [Project scope](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/docs/ROADMAP.md#L233)
- Blizzard expressly places cross-realm battlegrounds in original 1.12. This emulator's queue pools teams and level brackets within one cluster. Separate realms use separate clusters and character DBs, and the cluster handshake rejects a mismatched realm ID. This is a missing multi-realm feature, independent of working handoffs within one realm. [Blizzard's Classic FAQ](https://worldofwarcraft.blizzard.com/en-us/news/23090136) · [Realm isolation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/docs/CLUSTER.md#L788) · [Cluster handshake](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/cluster/link.d#L523) · [Queue key](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/bgqueue.d#L190)

### Inferences

- Invasion test. Activate the historical event on a test realm, weaken a shard, complete the defense, and verify the necropolis disappears and realm progress advances once. The event is phase-limited, so its absence on an ordinary post-event realm alone proves nothing.
- Matchmaking test. Configure two realms in the same battlegroup and fill one battleground from both. Verify realm-tagged identities even for identical names or numeric GUIDs, team assignment, rewards and return to each home realm.

### Gaps

- This was a source and database audit. The annual/event schedules, auction pricing and every transport itinerary were not exhaustively replayed. Taxi route code rejects cross-map paths, but the live client DBC shows many such paths are boats or zeppelins, served by a separate working implementation. The two cross-map non-transport-labelled paths 312/314 involve Dun Baldar and would need era evidence for public availability before filing an ordinary flight-path bug. [Flight planning](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/taxi.d#L218) · [Transport paths](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/transports.d#L7)

## What smaller rules differ and what old backlog entries should be retired?

### Takeaway

The server's inspect eligibility differs from the original faction rule in a specific case. Two familiar backlog entries have since acquired implementations.

### Cited Findings

- Blizzard dates inspecting opposite-faction gear to patch 2.4. Here the gear-inspect handler rejects attackable targets, but an opposing player without a PvP flag is unattackable outside free-for-all or a duel. A nearby such player on the same node passes the server's eligibility check. The vanilla UI might suppress that request independently. [Blizzard Classic FAQ](https://worldofwarcraft.blizzard.com/en-us/news/23090136) · [Inspect handler](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/inworld.d#L1257) · [Player target rules](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/relations.d#L241)
- Five-unique-instances-per-hour is already checked through the shared character database. Old notes calling it per-node are stale. Similarly mail expiration has a real database scan and settlement path, despite mailhandlers.d's introductory comment. [Realm instance accounting](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/context.d#L3782) · [Current scope](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/docs/FORMULAS.md#L399) · [Mail expiry settlement](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/context.d#L7090) · [Mail expiry query](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/characterdb.d#L1879)

### Inferences

- Verify gear-inspect eligibility in a neutral town on a PvE realm using ordinary, unflagged Horde and Alliance accounts. Test same-faction gear inspection as a control, distinguish whether the client offers Inspect from whether the server answers.

### Gaps

- The client UI impact of the inspect rule still needs an original client check. The rule applies to gear inspection. Do not automatically generalize it to inspection of PvP rank.
