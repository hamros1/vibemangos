# Status and roadmap

## Open work

- **Clustering.** Route script-selected spell targets across nodes. See
  [spell routing limits](CLUSTER.md#spell-routing-limits) and the
  [cross-node feature list](CLUSTER.md#what-crosses-nodes-feature-by-feature).
- **Terrain.** Include moving game objects such as doors and elevators in line-of-sight checks.
- **Gameplay coverage.** See the [spell audit](SPELLS.md) for gaps by class and the
  battleground notes below for remaining Alterac Valley events.

The rest of this page records progress and gaps by subsystem. The [gameplay reference](GAMEPLAY.md)
describes how players use the systems available today.

## What works

| Area | State | Where |
|---|---|---|
| Login server | Complete: SRP6, reconnect, realm list, bans, throttling, account CLI | `auth/` |
| Client data extraction | DBC files, terrain as `.map` files, buildings and doodads as vmaps, movement maps (Recast) | `extractor/`, `mpq/`, `mapfile.d`, `vmap/` |
| Terrain | Ground heights, areas and liquids from the `.map` files and the vmaps (floors, bridges, roofs, the areas of buildings, indoors, line of sight); the server decides zones and areas, explored areas give experience | `world/terrain.d`, `vmap/`, `world/exploration.d` |
| World handshake | Complete: session key proof, header encryption, addons, ping | `world/session.d` |
| Character list, creation, deletion | Complete, incl. the creation checks, starting items and spells, and guild, group, auction and mail cleanup on delete | `world/charscreen.d`, `playercreate.d`, `characterdb.d` |
| Entering the world | Character, inventory, skills, spellbook, action bars, stats with gear; the full login packet sequence | `world/charscreen.d`, `player.d`, `stats.d` |
| In the world | Movement saved, name, item, time and played-time queries, stand state, target selection, action buttons, tutorials, logout | `world/inworld.d` |
| Other players | A shared map per map id: players see each other within 100 yards (created, out of range, destroyed), movement and field changes are relayed, say/yell/emote/text emotes reach those in range, whispers reach anyone online, names of online players | `world/map.d`, `world/inworld.d`, `world/context.d` |
| Teleports | Near and far teleports with the client's acknowledgements, area trigger teleports with their entry checks (level, raid, items, quests), `worldport` | `world/teleport.d` |
| Groups | Parties and raids, saved and reloaded; invitations, leaders, assistants, sub-groups, kicks, loot settings, icons, ready checks, rolls, pings, member stats, group chat, real health for members; meeting stones (the looking-for-group queue, on the coordinator) | `world/group.d`, `world/grouphandlers.d`, `world/meetingstone.d` |
| Chat | Channels (built-in ones following the zone, custom ones with moderation), AFK/DND with replies and chat tags, raid warnings | `world/channel.d`, `world/channelhandlers.d`, `world/inworld.d` |
| GM system | Behaves exactly as ArcEmu 2.4.3's GM system (the compatibility contract): its command tables, permission letters (from `gmlevel` via `gm_permissions`), lookup, messages, GM tag, whisper blocking, GM log. 217 of its 298 commands work: teleports, `.modify`, levels, items, spells, skills, lookups, accounts, bans, kicks, mutes, shutdowns, announcements, cheats, debugging (docs/COMMANDS.md) | `world/commandtable.d`, `world/commands.d`, `world/gm*.d` |
| Update loop | A 50 ms tick: 20-second logout, regeneration, rested XP in inns and capitals (and offline), periodic saves, timed shutdowns | `net/server.d`, `context.d`, `inworld.d`, `timer.d` |
| Creatures and game objects | Every spawn (with pools, spawn groups and game events), loaded per grid cell when players come near, with levels, health, models, equipment, mounts and emotes; creature and game object queries; `.npc info` | `creature.d`, `gameobject.d`, `map.d`, `worlddata.d` |
| Creature movement | Wandering (`spawndist`) and waypoint paths (`creature_movement`, `creature_movement_template`; round, or back and forth) with waits and facings; `SMSG_MONSTER_MOVE`; walks in create blocks; moving creatures change cell and come into and out of sight | `spline.d`, `motion.d`, `map.d` |
| NPC services | Gossip menus with their texts, conditions, map flags and scripts (`gossip_menu.script_id`, options' `action_script_id`; `box_money` is TBC's and unused, as in CMaNGOS classic); trainers (lists with each spell's state, lessons that teach spells, ranks and profession skills); innkeepers (binding the hearthstone); bankers (opening the bank); vendors' lists | `npchandlers.d`, `npcdata.d`, `conditions.d` |
| Inventory and trade | The inventory rules, shared by creation and the world: moving, swapping, splitting, equipping (two-handers, dual wield, quivers, unique items), bags, the bank and its bag slots, the keyring, destroying, ammo; buying (with vendors' limited stock), selling, buyback and repairs; every change saved at once with the money; reputation-gated items, item use checks, bind on use, charges, the equip cooldown, timed items, wear on hit, ammo damage and quiver haste | `inventory.d`, `itemhandlers.d`, `itemuse.d` |
| Movement checks | Speed checked against running speed; offenders put back. Positions outside the map disconnect | `world/inworld.d` |
| Movement orders and environment | Speeds (auras, mounts, snares), roots, knockbacks, water walk, slow fall and hover ordered and shown to others on the client's acknowledgement; breath, fatigue, drowning, lava, falling damage; riding's rules (no casting but `ALLOW_WHILE_MOUNTED` spells, no melee, dismounted by game objects and mountless dungeons, the pet's bar greyed out) | `world/moveorders.d`, `world/environment.d`, `world/mounting.d` |

### Known gaps in what exists

* **Stats:** item bonuses, auras (talents' and racials' passive ones included) and the crit, dodge,
  parry and block chances are applied; passives bound to a kind of weapon or armour are not yet.
* **Creatures** wander, walk their waypoints (running their scripts), fight, die and respawn. Type 3 paths (flying) are walked as waypoints; linked creatures
  (`creature_linking`) aggro together and follow their master, and formations (`spawn_group_formation`) walk their
  path with their members in place, and water creatures spawned in deep enough water swim. Conditions
  that need world states or scripts are never met. Elevators
  are created but do not move. Ships and zeppelins sail and carry their passengers across
  (`transports.d`); elevators and ships give the client one transport clock (the wall clock). Idle cells unload after `grid_cleanup_delay_seconds`.
* **Terrain:** heights put wandering creatures on the ground; line of sight decides aggro and
  spells. Game objects' models (doors, elevators) are extracted but
  do not block sight (that needs a dynamic tree of game object models). Movement maps give creatures paths round buildings
  and hills; doors are not in them, and swimmers path over the ground under the water.
* **Movement:** the speed check assumes running speed; it must learn mounts, speed auras,
  knockbacks and taxis when those exist.
* **Environment:** the feign death timer (dying of feigning too long) is not run; mirror timers are not
  frozen for game masters (they take no damage instead) and start afresh after moving between nodes.
  Creatures do not hover, water walk or slow fall (`SMSG_SPLINE_MOVE_*`).
* **Instances:** each group gets its own copy of a dungeon, saved with its binds and dead; a raid's
  copies reset together at fixed times, with warnings; encounters are not tracked. In a cluster a dungeon's copies are all on the node owning its one region, and move
  with it (their creatures as they were); only after a node's crash do they start from their spawns.
  Battlegrounds: see "Battlegrounds" below.
* **Groups:** an offline leader is not replaced after a while (that needs a timer). Loot
  settings decide who loots. Two-faction groups do not show the other faction as friendly.
* **Chat:** channels have no restricted language mode (one language per faction); the ignore list stops whispers and invitations
  (the client hides an ignored player's other chat itself).
  LocalDefense and WorldDefense need PvP ranks, which do not exist, so WorldDefense is read-only.
  The GM tag and `.gm allowwhispers` are not kept between logins (as the GM contract specifies).
* **Inventory:** an off-hand item with no room left when a two-hander is put on is mailed to the player
  (`AutoUnequipOffhandIfNeed`'s letter); at character creation, where there is no mail, it stays worn.
  * Random properties are done, and so are enchantments' stats, resistances, weapon damage and equip
    spells.
  * Enchanting is done: permanent enchantments, and temporary ones (stones, oils, poisons) that
    run down and expire. Crafting raises professions. Spell foci and tools are enforced; disenchanting
    and picking lockboxes are done.
  * Weapon enchantments' procs (poisons, Crusader) are done.
  * Enchanting another player's item through trade and gift wrapping are implemented.
    Readable items and pages (`page_text`): done. Loot in items is done (`CMSG_OPEN_ITEM`). Dying and the spirit healer
    wear gear down (the spirit healer what is in the bags too); a broken worn item's stats come back when it is repaired.
    Unlearning a primary profession forgets all its spells and gives its slot back.
* **GM system:** commands that need missing systems answer "Not yet implemented."
  (COMMANDS.md lists them); GM invisibility (`.invisible`) needs sight to be one-sided first. The
  `c` letter makes speech universal but does not also teach the language skills, as the GM contract does.

## Next milestones

The order follows dependencies: almost everything after milestone 2 needs a map with visibility
and an update loop.

### 1. Other players: done

Players see each other (`world/map.d`), teleport between maps (`world/teleport.d`), group up
(`world/group.d`), talk in channels (`world/channel.d`) and are checked for speed. See
ARCHITECTURE.md's sections on maps, teleports, groups, channels and commands, and the gaps
listed above. Ships and zeppelins: done (`transports.d`).

### 2. An update loop and timers: done

See ARCHITECTURE.md's "The update loop". Played time (total and at this level), auctions
settled once a minute, old mail once an hour, and weather (`world/weather.d`) are done; silent connections are dropped
by the event loop after `idle_timeout`.

### 3. Creatures and game objects: started

Spawned and visible, with queries (ARCHITECTURE.md, "Creatures and game objects"), and gossip,
trainers, innkeepers, bankers and vendors ("Talking to NPCs", and "Items" for trading), and
movement, flight masters and interactive objects. Traps, fishing and idle cell unloading are
implemented. See [NPCs, items and the world](GAMEPLAY.md#npcs-items-and-the-world) and
[questing and travel](GAMEPLAY.md#questing-and-travel).

### 4. Map data: started

Done: `.map` files and vmaps, extracted and read; zones and areas, explored areas. See
ARCHITECTURE.md's "Terrain". Movement maps (Recast and Detour) for paths: done. Next: game
objects' models in line of sight (a dynamic tree of their models).

### 5. Inventory: done

See ARCHITECTURE.md's "Items" and the gaps above. What items do when used (food, potions,
hearthstones, opening bags of loot) comes with milestone 6's spells and loot.

### 6. Spells, auras and combat

The largest area. In order:

1. **Melee auto-attack: done** (`combat.d`, `combathandlers.d`, `relations.d`).
   Weapon and defense skills rise with use. Parry haste: done (`combat.parryHasted`; not for a creature with
   `CREATURE_EXTRA_FLAG_NO_PARRY_HASTEN`). PvP and cross-node melee are implemented. See the
   [cross-node combat paths](CLUSTER.md#what-crosses-nodes-feature-by-feature).
2. **Creatures fighting back: done** (`creatureai.d`), calling for help
   included, and EventAI scripts with creatures' spells, texts and fleeing (`eventai.d`,
   `creaturecasting.d`), and database scripts for quests, gossip and
   game objects (`dbscripts.d`). Temporary summons (EventAI's and the scripts'). EventAI's morphs, mounts and
   instance data, and paths by id in scripts: done. Every event, action and target type the database's
   `creature_ai_scripts` uses: done (conditions of `EVENT_T_OOC_LOS` and `EVENT_T_DEATH` not looked at).
   Dungeon rules (no pursuit leash, those who come near join the fight, `AGGRO_ZONE`), auras lost on evade,
   creature spells scaled to the caster's level, threat from heals and buffs, pools rolled again at each
   respawn: done. Movement maps support chasing. Clusters share a seed for spawn pools and can
   [borrow helpers across nodes](CLUSTER.md#creature-assistance). Remaining gaps include migration
   of summoned creatures and mana regeneration in combat.
3. **Death: done** (`death.d`, `corpse.d`), resurrection sickness and battleground
   spirit guides included, and ghosts hidden from the living. Bones (an hour where a body was, bare; CMaNGOS's
   `Death.Bones` on): done. Not yet: the ghost's own auras (applied by
   hand), corpses of a player on another node of a cluster (a corpse is put on
   the map its player's node simulates; a node that does not own the cell keeps it anyway).
4. **Experience and loot: done** (`experience.d`, `loot.d`, `loothandlers.d`). Quest drops,
   skinning, pickpocketing and random properties are implemented. A cluster
   supports group loot rolls, coin splits, round-robin pickup, quest drops and Master Loot across
   nodes (docs/CLUSTER.md).
5. Spells, cooldowns and auras. **Casting and auras: done** (`spellcast.d`, `spellhandlers.d`,
   `auras.d`, `aurahandlers.d`); creatures' spells come with their
   scripts (above), talents with milestone 7. Channelled spells, area, cone, party and chain targets, persistent area auras, missiles' flight, items'
   equip spells, spell and healing power (direct and over time), creatures' partial resists: done.
   Binary spells and resisted ticks, and resists against players: done. The effects and aura types of the
   classes' trainable spells beyond damage and healing (threat, taunts, charges, Blink, burns, drains and
   leeches, extra swings, Vanish, Feign Death, Fade, Distract, the hunters' traps, tracking, Hunter's Mark,
   regeneration's auras, Holy Shield, Blessing of Sacrifice; `effecthandlers.d`): done. Players'
   guardians (engineering dragonlings, dummies, the sheep; `guardians.d`), wild objects,
   and wear by spells (`durability.d`), Ritual of Summoning and the meeting stones' summons (`rituals.d`): done; a guardian's evade walks back to where it was summoned before it follows
   again. Not yet: Eye of Kilrogg (`SUMMON_POSSESSED`), invisibility and its
   detection, traps hidden from those not in the hunter's group.
6. **Duels and trades: done** (`tradehandlers.d`, `duelhandlers.d`). Players fight players in
   melee and with spells where the relations allow (duelists,
   PvP-flagged enemies). The PvP flag (`pvp.d`): `/pvp`, enforced zones, contested players, free-for-all
   arenas, Honorless Target. Honor (`honor.d`): kills, dishonorable kills, racial leaders, ranks, the fields,
   inspecting, the weekly standing (`honorweek.d`), what ranks bring (rank items at vendors and to equip,
   price and repair discounts, the defense channels, the Halls, `CONDITION_PVP_RANK`), the `.honor`
   commands. Honor in battlegrounds and the off hand against players: done.
7. **Battlegrounds: started** (`bgqueue.d`, `battleground.d`).
   * Milestone A, queue and entry: **done**.
     * The queues are a cluster service, with brackets, three slots, invitations of 80 s and their
       reminder, and the average wait.
     * Battlemasters' lists, by hello or gossip.
     * Copies run on the node hosting the map, made when their first player comes in through the queue.
     * Teams' starts, the two-minute countdown, the scoreboard.
     * Leaving goes back to where the player was; leaving while the battle is on gives Deserter.
     * A player who logs out keeps their place for five minutes; one who comes back to a closed copy is
       sent back.
     * `.battleground forcestart` and `.battleground leave`.
   * Milestone B, the shared framework: **done** (`battleground.d`). Each battleground's rules plug into
     `BattlegroundRules`.
     * The spawn events and doors; world states; kills and deaths on the scoreboard.
     * The end: marks of honor, bonus honor and reputation to a team, two minutes before everyone leaves.
     * The premature end; battleground chat; spirit guides every 30 s; the copy's own graveyards.
     * Queueing as a group, across nodes.
   * Milestone C, Warsong Gulch: **done** (`warsong.d`): flags taken, dropped, returned, captured, three to
     win, the exit portals.
   * Milestone D, Arathi Basin: **done** (`arathi.d`): five bases, claims, assaults, defences, resources,
     2000 to win.
   * Milestone E, Alterac Valley: **done** (`alterac.d`, as 1.12: no reinforcements, those are 2.3.0's): graveyards and towers, mines,
     captains and generals; the turn-ins: armor scraps upgrading the defenders (and the general's warcry), the
     elemental lords called. Not yet: the cavalry, the fleets, the ground assault (no gossip for their orders in
     the database), the lords' summoning rituals and march.
   * The scoreboard's columns, `WorldStateUI.dbc`'s (Alterac Valley's mines captured and leaders killed too), and
     the scores kept (`pvpstats_*`, `battleground_score_statistics`): done.
   * Planned queue service moves preserve queues and invitations, and running copies can still be
     refilled. Losing the queue host without a handoff starts the service empty.

* Spell casting with effects, auras (feeding `stats.d`), cooldowns and the attack swing loop.
* Creature AI, threat, death, loot, XP and level-up (stats recomputed for the new level).

### Quests

**Done** (`quests.d`, `questhandlers.d`): givers, the log, kill and item
objectives, rewards, saving, game objects and items as givers, sharing, exploration objectives,
timed quests, `questgiver_greeting`, quest scripts (`dbscripts_on_quest_*`). Next: escort quests
(with the D scripts' waypoint and gossip events), quest POIs.

**Scripting** (docs/SCRIPTING.md): the framework in D is done for creatures, dungeons, game objects,
spells, area triggers and scripted events (typed events, schedules as data, state saved by reflection,
migration, `instance.data`, gossip and quest events, script movement, the `Escort`, `Follower`, `Walk` and
`Pack` components, signals across nodes). Ported from CMaNGOS's ScriptDevAI (2026-11-19): the quest and
event scripts of Kalimdor's and the Eastern Kingdoms' zones, every five-player dungeon, and the raids
(Molten Core, Onyxia, Zul'Gurub, Blackwing Lair, both Ahn'Qiraj, Naxxramas), then the dungeons' and
raids' scripted events, the profession specializations, the Emerald Dragons, the Ahn'Qiraj opening, the
guards, world objects, item and world map scripts, and the Ahn'Qiraj war effort (its server-wide state a
cluster service, docs/SERVICES.md: phases, counters, piles, the capitals' world states, the gong); the server logs 444 script rows served. The spell
scripts of items, quests and the world (2026-11-20): 25 more of the 167 `spell_scripts` names (32 served), with
the cast check, cast start, aura heartbeat, aura end, tick end and target check events, players' transforms and
creatures' mana drains on players; and 32 item and holiday spells CMaNGOS's core scripts by id (`@spellIds`:
the Deviate Fish, the engineers' gadgets, the costumes, ...). Of the spell scripts, not yet: those needing
creatures to cast as they die (the tribal deaths), summons and destinations a script shapes (the Lunar
Festival's fireworks, which need players' game object summons too), effect chances (the silithid egg), and the raids'. Not yet
(about 20 names, each module's documentation and SCRIPTING.md say why): what needs stealth detection
(Venture Co. lookouts, Gallywix), the Scourge Invasion, caravans,
the Eastern Kingdoms' world map script, and the mechanics the raids approximate (possession, mind
control, Heigan's floor).
Reputation is done (`reputation.d`, `reputationhandlers.d`): kills, quests,
spillover, war and peace, discounts, requirements, reactions forced by auras (`SMSG_SET_FORCED_REACTIONS`: the
disguises, the Corrupted Ashbringer's Scarlet Crusade). Reputation from spells (effect 103) and the PvP rank's
discount: done.

### Talents

**Done** (`talenthandlers.d`, `spellmods.d`): learning ranks, passive auras,
the spell modifiers most talents are, unlearning them at a class trainer. The auras talents (and buffs)
use for stats and combat: crit, dodge, parry, block and hit chances; percentages of stats, health, power,
armor and resistances, attack power and the off hand's damage (`stats.d`); weapon and defense skill
bonuses; damage done and taken by school and by creature type, crit by creature type, threat
(`combat.d`'s `DamageMods`); the five-second rule and Meditation; resistance to a mechanic; spell power
from spirit (Spiritual Guidance); shield block value; lowering the target's resistances; modifiers with
charges (Clearcasting, Presence of Mind, Nature's Swiftness: spent by the cast they change); procs by
`spell_proc_event` (`procs.d`) and the talents whose procs or effects are code (`classspells.d`: Ignite,
Deep Wounds, Seal Fate, Ruthlessness, Illumination, Blessed Recovery, Nightfall, Combustion, Master of
Elements, Shatter, Frostbite and the other Add Target Triggers). Not yet: the remaining override class scripts
(Improved Blizzard, Arcane Concentration's script), procs of a creature's own auras, Pyroclasm.

### Mail

**Done** (`mailhandlers.d`), auctions' mail and expiry included, quest and game event letters, and
`mail_level_reward`'s letter at a new level (TBC CMaNGOS's; only for templates a 1.12 client has, so none of the
classic database's TBC rows is sent).

### Auctions

**Done** (`auctionhouse.d`, `auctionhandlers.d`): selling, searching, bidding,
buyouts, cancelling, expiry, the mails, the houses' rates (`AuctionHouse.dbc`'s, and the server's own over them;
docs/FORMULAS.md). Not yet: an auction bot. There is no `.auction` command (the
GM command set has none).

### 7. Social and progression

* Friends and ignore lists (`social.d`) and guilds (`guild.d`, `guildhandlers.d`), the guild event log
  (`guild_eventlog`, kept for the server: the 1.12 client cannot ask for it): done. Like `grouphandlers.d`
  (mail, auctions and trade are done). The guild tabard needs nothing of the server: the client draws the
  wearer's guild's emblem (`SMSG_GUILD_QUERY_RESPONSE`), and the vendors' Guild Tabard (5976) is one item for all.
* Pets (`pet.d`, `petai.d`, `pethandlers.d`): taming, summoning, calling,
  dismissing, reviving, the bar and its commands, following and fighting, experience, renaming,
  abandoning, stables, saving. Loyalty and happiness over time and Feed Pet: done. The `.pet` GM commands and pet training (teaching spells, training points, the hunter
  learning a beast's abilities as it uses them): done. Not yet: a pet's spells beyond its autocast and
  ordered casts (opener spells). Creatures noticing pets on sight: done. The owner's death sends the pet
  away until the owner lives again: done.
* Quests: done (above).
* The rest of the GM commands, as their systems arrive (COMMANDS.md lists them): each is one
  method of the handler group it belongs to.

### Earlier test failures

* **A rare stop in release builds.** It was seen twice on the test server, never reproduced, and
  never in a debug build:
  * the loop hung right after a Tame Beast channel ended;
  * the process exited silently after a kill and loot.
  The pattern suggests memory corruption or something the collector freed while still in use. Live
  tests run under gdb until one leaves a backtrace.
  DMD's optimizer has since been caught miscompiling one template (`frozenCopy!(float[3])`, without
  `-inline`; docs/BENCHMARKS.md): a miscompile is now a suspect too.
* **A start that stalled.** Once a benchmark's server stopped at start-up inside its third database
  connection (the world database) and never listened. The game loop also talks to the database
  synchronously (saves, pets, mail), so a stalled database call stalls the loop. That may explain the
  hang above. The [save writer](ARCHITECTURE.md#writes-behind-the-loop) now handles regular saves.

### Login server

Open items include `crcHash` file integrity, PIN/TOTP (`account.token`) and patch transfer.
