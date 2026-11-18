# Status and roadmap

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
| Groups | Parties and raids, saved and reloaded; invitations, leaders, assistants, sub-groups, kicks, loot settings, icons, ready checks, rolls, pings, member stats, group chat, real health for members | `world/group.d`, `world/grouphandlers.d` |
| Chat | Channels (built-in ones following the zone, custom ones with moderation), AFK/DND with replies and chat tags, raid warnings | `world/channel.d`, `world/channelhandlers.d`, `world/inworld.d` |
| GM system | Behaves exactly as ArcEmu 2.4.3's GM system (the compatibility contract): its command tables, permission letters (from `gmlevel` via `gm_permissions`), lookup, messages, GM tag, whisper blocking, GM log. 217 of its 298 commands work: teleports, `.modify`, levels, items, spells, skills, lookups, accounts, bans, kicks, mutes, shutdowns, announcements, cheats, debugging (docs/COMMANDS.md) | `world/commandtable.d`, `world/commands.d`, `world/gm*.d` |
| Update loop | A 50 ms tick: 20-second logout, regeneration, rested XP in inns and capitals (and offline), periodic saves, timed shutdowns | `net/server.d`, `context.d`, `inworld.d`, `timer.d` |
| Creatures and game objects | Every spawn (with pools, spawn groups and game events), loaded per grid cell when players come near, with levels, health, models, equipment, mounts and emotes; creature and game object queries; `.npc info` | `creature.d`, `gameobject.d`, `map.d`, `worlddata.d` |
| Creature movement | Wandering (`spawndist`) and waypoint paths (`creature_movement`, `creature_movement_template`; round, or back and forth) with waits and facings; `SMSG_MONSTER_MOVE`; walks in create blocks; moving creatures change cell and come into and out of sight | `spline.d`, `motion.d`, `map.d` |
| NPC services | Gossip menus with their texts, conditions and map flags; trainers (lists with each spell's state, lessons that teach spells, ranks and profession skills); innkeepers (binding the hearthstone); bankers (opening the bank); vendors' lists | `npchandlers.d`, `npcdata.d`, `conditions.d` |
| Inventory and trade | The inventory rules, shared by creation and the world: moving, swapping, splitting, equipping (two-handers, dual wield, quivers, unique items), bags, the bank and its bag slots, the keyring, destroying, ammo; buying (with vendors' limited stock), selling, buyback and repairs; every change saved at once with the money | `inventory.d`, `itemhandlers.d` |
| Movement checks | Speed checked against running speed; offenders put back. Positions outside the map disconnect | `world/inworld.d` |

### Known gaps in what exists

* **Stats:** item bonuses, auras (talents' and racials' passive ones included) and the crit, dodge,
  parry and block chances are applied; passives bound to a kind of weapon or armour are not yet.
* **Not loaded:** pets.
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
* **Instances:** each group gets its own copy of a dungeon, saved with its binds and dead; raids
  reset `reset_delay` days after they were made rather than at fixed weekly times, encounters are
  not tracked. In a cluster a dungeon's copies are all on the node owning its one region, and move
  with it (their creatures as they were); only after a node's crash do they start from their spawns.
  Battlegrounds: see "Battlegrounds" below.
* **Groups:** an offline leader is not replaced after a while (that needs a timer). Loot
  settings decide who loots. Two-faction groups do not show the other faction as friendly.
* **Chat:** channels have no restricted language mode (one language per faction); the ignore list stops whispers and invitations
  (the client hides an ignored player's other chat itself).
  LocalDefense and WorldDefense need PvP ranks, which do not exist, so WorldDefense is read-only.
  The GM tag and `.gm allowwhispers` are not kept between logins (as the GM contract specifies).
* **Inventory:** an off-hand item with no room left when a two-hander is put on stays worn; it should
  be mailed to the player (not yet).
  * Random properties are done, and so are enchantments' stats, resistances, weapon damage and equip
    spells.
  * Enchanting is done: permanent enchantments, and temporary ones (stones, oils, poisons) that
    run down and expire. Crafting raises professions.
  * Weapon enchantments' procs (poisons, Crusader) are done.
  * Not yet: enchanting another player's item through
    trade, readable items and wrapping. Loot in items is done (`CMSG_OPEN_ITEM`). Dying and the spirit healer wear gear
  down; a broken worn item's stats come back when it is repaired.
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
movement: wandering and waypoints ("Creature movement"), and using game objects
(`gameobject.d`, `gameobjecthandlers.d`; README's "Using game objects": doors, buttons, chairs,
goobers, locks and chests with their loot, respawns, quest givers), and flight masters
(`taxi.d`, `taxihandlers.d`; README's "Flight masters"). Next: traps, fishing, and unloading idle
cells.

### 4. Map data: started

Done: `.map` files and vmaps, extracted and read; zones and areas, explored areas. See
ARCHITECTURE.md's "Terrain". Movement maps (Recast and Detour) for paths: done. Next: game
objects' models in line of sight (a dynamic tree of their models).

### 5. Inventory: done

See ARCHITECTURE.md's "Items" and the gaps above. What items do when used (food, potions,
hearthstones, opening bags of loot) comes with milestone 6's spells and loot.

### 6. Spells, auras and combat

The largest area. In order:

1. **Melee auto-attack: done** (`combat.d`, `combathandlers.d`, `relations.d`; README's "Melee").
   Weapon and defense skills rise with use. Not yet: `NO_SKILL_GAINS` creatures (`StaticFlags2`), parry haste, PvP (no way to be
   flagged yet). Another node's creature: attacking (casting at, looting) its replica moves the
   player to that node, and a fight keeps it there (docs/CLUSTER.md).
2. **Creatures fighting back: done** (`creatureai.d`; README's "Creatures fight"), calling for help
   included, and EventAI scripts with creatures' spells, texts and fleeing (`eventai.d`,
   `creaturecasting.d`; README's "Creature scripts"), and database scripts for quests, gossip and
   game objects (`dbscripts.d`). Temporary summons (EventAI's and the scripts'). Not yet: EventAI's morphs,
   paths by id, summons handed over between nodes, spell lists, interrupting creatures' casts, movement maps for chasing, help
   from another node's creatures in a cluster.
3. **Death: done** (`death.d`, `corpse.d`; README's "Death"), resurrection sickness and battleground
   spirit guides included. Not yet: the ghost's own auras (applied by hand), ghosts hidden from the
   living, bones, corpses of a player on another node of a cluster (a corpse is put on
   the map its player's node simulates; a node that does not own the cell keeps it anyway).
4. **Experience and loot: done** (`experience.d`, `loot.d`, `loothandlers.d`; README's "Experience
   and loot"). Quest drops, skinning, pickpocketing and random
   properties: done. Not yet: loot of a creature another node of a cluster simulates.
5. Spells, cooldowns and auras. **Casting and auras: done** (`spellcast.d`, `spellhandlers.d`,
   `auras.d`, `aurahandlers.d`; README's "Spells" and "Auras"); creatures' spells come with their
   scripts (above), talents with milestone 7. Channelled spells, area, cone, party and chain targets, persistent area auras, missiles' flight, items'
   equip spells, spell and healing power (direct and over time), creatures' partial resists: done.
   Binary spells and resisted ticks: done. Next: resists against players (with PvP).
6. **Duels and trades: done** (`tradehandlers.d`, `duelhandlers.d`; README's "Trading" and
   "Duels"). Players fight players in melee and with spells where the relations allow (duelists,
   PvP-flagged enemies). The PvP flag (`pvp.d`): `/pvp`, enforced zones, contested players, free-for-all
   arenas, Honorless Target. Honor (`honor.d`): kills, dishonorable kills, racial leaders, ranks, the fields,
   inspecting, the weekly standing (`honorweek.d`), what ranks bring (rank items at vendors and to equip,
   price and repair discounts, the defense channels, the Halls, `CONDITION_PVP_RANK`), the `.honor`
   commands. Not yet: honor in battlegrounds (with them), the off hand against players.
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
   * Not yet:
     * The battleground raid group: chat works without it, but the raid frames do not show.
     * Removing stealth and the like on objectives (`AURA_INTERRUPT_FLAG_PVP_ACTIVE_CANCELS`).
     * A flag dropped when its carrier becomes immune.
     * Insignia loot from the dead.
     * pvpstats.
     * Alterac Valley (mostly data: about 1000 event spawns, captains, mines, towers).
     * A queue service that moves to another node starts empty.

* Spell casting with effects, auras (feeding `stats.d`), cooldowns and the attack swing loop.
* Creature AI, threat, death, loot, XP and level-up (stats recomputed for the new level).

### Quests

**Done** (`quests.d`, `questhandlers.d`; README's "Quests"): givers, the log, kill and item
objectives, rewards, saving, game objects and items as givers, sharing, exploration objectives,
timed quests, `questgiver_greeting`, quest scripts (`dbscripts_on_quest_*`). Next: escort quests
(with the D scripts' waypoint and gossip events), quest POIs.

**Scripting** (docs/SCRIPTING.md): the framework in D is done for creatures, dungeons and game
objects (typed events, schedules as data, state saved by reflection, migration, `instance.data`,
gossip and quest events, script movement, the `Escort` component), with the Deadmines' doors, its
cannon and Mr. Smite, and the Defias Traitor's escort; spell and area trigger scripts, gossip menus
of a script's own and signals across nodes are done too (Life Tap, Lady Katrana Prestor, the scent
of Lar'korwi), and spell scripts for creatures' casts and for auras (Curse of Agony, Hate to Zero).
Shadowfang Keep is scripted (not yet: Deathstalker Vincent and Arugal's introduction, Arugal's
teleports, which need creatures casting teleports on themselves). Wailing Caverns is scripted
(the Fanglords, the Disciple of Naralex's escort and ritual). Next: creatures' teleport spells,
world and command scripts, the other escorts, then the next dungeons (Blackfathom Deeps, the
Stockade, Gnomeregan, Razorfen Kraul; the server logs 15 of 657 script names served).
Reputation is done (`reputation.d`, `reputationhandlers.d`; README's "Reputation"): kills, quests,
spillover, war and peace, discounts, requirements. Not yet: `SMSG_SET_FORCED_REACTIONS` (spells force
none yet), the PvP rank's discount, reputation from spells.

### Talents

**Done** (`talenthandlers.d`, `spellmods.d`; README's "Talents"): learning ranks, passive auras,
the spell modifiers most talents are, unlearning them at a class trainer. Next: threat and charges
modifiers, parry, dodge and crit chance auras feeding the combat chances.

### Mail

**Done** (`mailhandlers.d`; README's "Mail"), auctions' mail and expiry included. Next: the mail
templates NPCs and quests send (`RewMailTemplateId`).

### Auctions

**Done** (`auctionhouse.d`, `auctionhandlers.d`; README's "Auctions"): selling, searching, bidding,
buyouts, cancelling, expiry, the mails. Not yet: auction rates, an auction bot. There is no `.auction` command (the
GM command set has none).

### 7. Social and progression

* Friends and ignore lists (`social.d`) and guilds (`guild.d`, `guildhandlers.d`): done. Not yet:
  the guild event log (`guild_eventlog`), guild-named tabards in the shop list. Like
  `grouphandlers.d` (mail, auctions and trade are done).
* Pets (`pet.d`, `petai.d`, `pethandlers.d`): taming, summoning, calling,
  dismissing, reviving, the bar and its commands, following and fighting, experience, renaming,
  abandoning, stables, saving. Loyalty and happiness over time and Feed Pet: done. Not yet: pet training and
  `.pet` GM commands, `pet_aura` and `pet_spell_cooldown`, a pet's spells beyond its autocast and
  ordered casts (opener spells), creatures noticing pets on sight. The owner's death sends the pet
  away until the owner lives again: done.
* Quests: done (above).
* The rest of the GM commands, as their systems arrive (COMMANDS.md lists them): each is one
  method of the handler group it belongs to.

### Known issues

* **A rare stop in release builds.** It was seen twice on the test server, never reproduced, and
  never in a debug build:
  * the loop hung right after a Tame Beast channel ended;
  * the process exited silently after a kill and loot.
  The pattern suggests memory corruption or something the collector freed while still in use. Live
  tests run under gdb until one leaves a backtrace.
* **A start that stalled.** Once a benchmark's server stopped at start-up inside its third database
  connection (the world database) and never listened. The game loop also talks to the database
  synchronously (saves, pets, mail), so a stalled database call stalls the loop. That may explain the
  hang above. Step 6 of docs/DESIGN.md (the save writer) takes saves off the loop; a connect timeout
  would make a stall at start-up fail instead of hanging.

### Infrastructure, as needed

* An epoll/kqueue loop beyond `select`'s 1024-descriptor limit.
* Asynchronous database calls, or a worker thread for saves, once saves become frequent.
* The rest of the login server: `crcHash` file integrity, PIN/TOTP (`account.token`) and patch
  transfer.
