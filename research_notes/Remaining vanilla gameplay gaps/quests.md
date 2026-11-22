# Outdoor and leveling quest checks

## Does ordinary party quest sharing work everywhere in a clustered realm?

### Takeaway

A nearby eligible party member on another simulation node is skipped. This affects real leveling quests even though same-node sharing works.

### Cited Findings

- The original 1.12.1 quest log exposes the Share Quest button to players. Its click handler calls QuestLogPushQuest. The Classic behavior is an offer the eligible party member can accept. [Blizzard 1.12.1 client UI, extracted source](https://github.com/MOUZU/Blizzard-WoW-Interface/blob/master/1.12.1/FrameXML/QuestLogFrame.xml#L499-L515) [Vanilla quest sharing description](https://vanilla-wow-archive.fandom.com/wiki/Quest)
- The manual share path loops through known party members, obtains the character with the current node's online lookup, and skips a missing character before distance or eligibility checks. The acceptance path also resolves the sharer locally. The automatic party-accept path used for escorts has the same local lookup. Cross-node quest loot and kill credit have distinct protocol messages. [Manual offer](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/questhandlers.d#L1156) [Accept](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/questhandlers.d#L679) [Automatic party offer](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/questhandlers.d#L1064) [Node-local map](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/context.d#L5345) [Cluster gameplay messages](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/docs/CLUSTER.md#L168)
- A read-only installed Classic-DB lookup returned quest 60 Kobold Candles and 47 Gold Dust Exchange with QuestFlags=8 (sharable) and zero StartScript/CompleteScript. Quest 155 The Defias Brotherhood and quest 219 Missing In Action carry flag 2 (party accept). The code defines the matching flag values. [Flag definitions](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/quests.d#L41)

### Inferences

- Test two eligible Alliance party members a few yards apart across a node boundary. Share Kobold Candles and require a prompt, acceptance, and returning acceptance message. Repeat on one node as a control. For the escort case start the Defias Traitor quest with an eligible member on the opposite owner and require the automatic prompt.

### Gaps

- This is a source-confirmed routing omission. No live two-client test was performed during this audit. It is not an assertion that quest loot, kill credit, or all escort objectives are missing.

## Do shared timed quests keep the same deadline?

### Takeaway

dmangos and CMaNGOS Classic disagree. Treat the rule as a reference-implementation discrepancy until a vanilla or Classic Era trace confirms the expected recipient deadline.

### Cited Findings

- dmangos sets a new deadline of now plus the full quest time when adding a quest. The normal shared accept path uses this same initializer. CMaNGOS Classic sets the recipient's time to the sharer's time remaining for a timed quest obtained from another player. [dmangos init](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/questhandlers.d#L757) [CMaNGOS Classic implementation](https://github.com/cmangos/mangos-classic/blob/master/src/game/Entities/Player.cpp#L12453-L12462)
- Installed data has eight sharable timed quests. Example: A Hunter's Boast (257), flag 8 and 900 seconds, consistent with the 15-minute time limit recorded on the Classic quest page. [Classic quest data](https://www.wowhead.com/classic/quest=257/a-hunters-boast)

### Inferences

- Test on a single owner first: wait five minutes after accepting quest 257 and offer it. Capture both clients' deadlines, including after relog. Reference behavior would leave approximately ten minutes for both. A contemporary game capture should establish the acceptance criterion.

### Gaps

- The documented 15-minute time limit alone does not establish how sharing handles time already spent. CMaNGOS corroborates a candidate, not a Blizzard guarantee.

## Does the Benediction priest event respond to an outsider?

### Takeaway

Keep The Cleaner on the verification list. The Eris script implements the actual rescue event and the installed database supplies peasant disease and archer attacks.

### Cited Findings

- Eris' script counts saved and dead peasants. The installed quest 7622 has zero StartScript and CompleteScript. Her template 14494 binds npc_eris_havenfire. Installed EventAI for the archers and both peasant entries covers combat movement, shooting, disease and dialogue; it contains no explicit Cleaner summon in those rows. The world DB does contain The Cleaner (14503), and hunter scripts summon him on outside interference. Original player accounts attached to the priest quest describe interference and stationary-player exceptions. [Eris script](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/easternplaguelands.d#L93) [Hunter implementation](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/scripts/burningsteppes.d#L319) [Firsthand quest comments](https://www.wowhead.com/classic/quest=7622/the-balance-of-light-and-shadow)

### Inferences

- Check moving an outside helper in, directly healing the priest and attacking a footsoldier in separate trials, with a stationary observer as a control.

### Gaps

- Exact historic trigger conditions are ambiguous. Do not promote this to a universal failure or implement a blanket proximity rule without observing actual behavior.
