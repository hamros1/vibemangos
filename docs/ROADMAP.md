# Status and roadmap

## What works

| Area | State | Where |
|---|---|---|
| Login server | Complete: SRP6, reconnect, realm list, bans, throttling, account CLI | `auth/` |
| DBC extraction | Complete for DBCs; maps, vmaps and mmaps not started | `extractor/`, `mpq/` |
| World handshake | Complete: session key proof, header encryption, addons, ping | `world/session.d` |
| Character list, creation, deletion | Full parity with CMaNGOS, incl. guild, group, auction and mail cleanup on delete | `world/charscreen.d`, `playercreate.d`, `characterdb.d` |
| Entering the world | Character, inventory, skills, spellbook, action bars, stats with gear; same packet sequence as mangosd | `world/charscreen.d`, `player.d`, `stats.d` |
| In the world | Movement saved, name, item, time and played-time queries, stand state, target selection, action buttons, tutorials, logout | `world/inworld.d` |
| Other players | A shared map per map id: players see each other within 100 yards (created, out of range, destroyed), movement and field changes are relayed, say/yell/emote/text emotes reach those in range, whispers reach anyone online, names of online players | `world/map.d`, `world/inworld.d`, `world/context.d` |
| Teleports | Near and far teleports with the client's acknowledgements, area trigger teleports with CMaNGOS's entry checks, `worldport` | `world/teleport.d` |
| Groups | Parties and raids, saved and reloaded; invitations, leaders, assistants, sub-groups, kicks, loot settings, icons, ready checks, rolls, pings, member stats, group chat, real health for members | `world/group.d`, `world/grouphandlers.d` |
| Chat | Channels (built-in ones following the zone, custom ones with moderation), AFK/DND with replies and chat tags, raid warnings | `world/channel.d`, `world/channelhandlers.d`, `world/inworld.d` |
| GM system | ArcEmu's: its command tables, permission letters (from `gmlevel` via `gm_permissions`), lookup, messages, GM tag, whisper blocking, GM log. 135 of its 298 commands work: teleports, `.modify`, levels, items, spells, skills, lookups, accounts, bans, kicks, mutes, shutdowns, announcements, cheats, debugging (docs/COMMANDS.md) | `world/commandtable.d`, `world/commands.d`, `world/gm*.d` |
| Update loop | A 50 ms tick: 20-second logout, regeneration, rested XP in inns and capitals (and offline), periodic saves, timed shutdowns | `net/server.d`, `context.d`, `inworld.d`, `timer.d` |
| Creatures and game objects | Every spawn (with pools, spawn groups and game events), loaded per grid cell when players come near, with levels, health, models, equipment, mounts and emotes; creature and game object queries; `.npc info` | `creature.d`, `gameobject.d`, `map.d`, `worlddata.d` |
| NPC services | Gossip menus with their texts, conditions and map flags; trainers (lists with each spell's state, lessons that teach spells, ranks and profession skills); innkeepers (binding the hearthstone); bankers (opening the bank); vendors' lists | `npchandlers.d`, `npcdata.d`, `conditions.d` |
| Inventory and trade | CMaNGOS's inventory rules, shared by creation and the world: moving, swapping, splitting, equipping (two-handers, dual wield, quivers, unique items), bags, the bank and its bag slots, the keyring, destroying, ammo; buying (with vendors' limited stock), selling, buyback and repairs; every change saved at once with the money | `inventory.d`, `itemhandlers.d` |
| Movement checks | Speed checked against running speed; offenders put back. Positions outside the map disconnect | `world/inworld.d` |

### Known gaps in what exists

* **Stats:** auras, talents' effects and racial passives are not applied. Crit, dodge, parry and
  block chances are 0. Item stat bonuses, armor, attack power and weapon damage are applied.
* **Not loaded:** reputation (needs `Faction.dbc` and `character_reputation`), guild membership
  (`PLAYER_GUILDID`), quests, auras, cooldowns, pets, corpses and death. A dead character loads
  alive.
* **Creatures** stand still and never die, so they never respawn. There is no quest dialog yet. Flight masters,
  auctioneers, stable masters, battlemasters and guild NPCs are not offered in menus yet. Conditions
  that need auras, reputation, quests in the log, world states or scripts are never met. Elevators
  are created but do not move. Ships and zeppelins are not
  spawned. Cells are never unloaded (mangosd unloads idle grids after a while).
* **Rested XP** is earned but not spent, because there is no XP gain yet.
* **Movement:** the speed check assumes running speed; it must learn mounts, speed auras,
  knockbacks and taxis when those exist. Explored zones are not updated; that needs map data.
* **Teleports:** there is one map per map id, so everyone entering a dungeon shares one copy.
  Instance ids, binds (`character_instance`, `group_instance`) and resets come with milestone 3's
  map updates. Area triggers with a `condition_id` stay closed until conditions are loaded;
  taverns (rest) and quest triggers do nothing yet. Battlegrounds cannot be entered.
* **Groups:** an offline leader is not replaced after a while (that needs a timer). Loot
  settings are stored but nothing drops yet. The ignore list does not exist, so nobody can be
  ignored. Two-faction groups do not show the other faction as friendly.
* **Chat:** no ignore list or `Channel.RestrictedLanguageMode`.
  LocalDefense and WorldDefense need PvP ranks, which do not exist, so WorldDefense is read-only.
  The GM tag and `.gm allowwhispers` are not kept between logins (nor are they in ArcEmu).
* **Inventory:** prices have no reputation or honor discounts, and items that need a reputation or
  an honor rank cannot be bought or used (there are neither). An off-hand item with no room left
  when a two-hander is put on stays worn, where CMaNGOS mails it: there is no mail. Item
  enchantments, random properties, item sets, item spells, readable items, wrapping and loot in
  items (lockboxes, clams) are not done. A broken worn item's stats come back when it is repaired,
  but nothing breaks it yet.
* **GM system:** ArcEmu's commands that need missing systems answer "Not yet implemented."
  (COMMANDS.md lists them); GM invisibility (`.invisible`) needs sight to be one-sided first. The
  `c` letter makes speech universal but does not teach the language skills ArcEmu adds.

## Next milestones

The order follows dependencies: almost everything after milestone 2 needs a map with visibility
and an update loop.

### 1. Other players: done

Players see each other (`world/map.d`), teleport between maps (`world/teleport.d`), group up
(`world/group.d`), talk in channels (`world/channel.d`) and are checked for speed. See
ARCHITECTURE.md's sections on maps, teleports, groups, channels and commands, and the gaps
listed above. Transports (boats, zeppelins) need game objects and come with milestone 3.

### 2. An update loop and timers: done

See ARCHITECTURE.md's "The update loop". Still to do here: AFK kicks, the online-time
`played` update while in the world, mail and auction timers, weather.

### 3. Creatures and game objects: started

Spawned and visible, with queries (ARCHITECTURE.md, "Creatures and game objects"), and gossip,
trainers, innkeepers, bankers and vendors ("Talking to NPCs", and "Items" for trading). Next:
creature movement (random and waypoint, `creature_movement`), flight masters, using game objects
(doors, chests, mailboxes), respawn timers, and unloading idle cells. CMaNGOS references:
`MotionGenerators/`, `Entities/GossipDef.cpp`, `GossipHandler.cpp`, `NPCHandler.cpp`,
`TaxiHandler.cpp`.

### 4. Map data

CMaNGOS references: `contrib/extractor`, `contrib/vmap_extractor`, `contrib/mmap`,
`src/game/Maps/GridMap.cpp`.

* Extend the extractor to write CMaNGOS's `maps/*.map` files: heights, areas and liquids from ADT
  and WDT. The MPQ reader already handles the archives.
* Load them for ground height, area ids (explored zones, `CMSG_ZONEUPDATE` checks), and later
  line of sight (vmaps) and pathfinding (mmaps, via recast/detour or the mmaps CMaNGOS writes).

### 5. Inventory: done

See ARCHITECTURE.md's "Items" and the gaps above. What items do when used (food, potions,
hearthstones, opening bags of loot) comes with milestone 6's spells and loot.

### 6. Spells, auras and combat

The largest area. CMaNGOS references: `Spells/`, `Entities/Unit.cpp`, `Combat/`, `AI/`.

* Spell casting with effects, auras (feeding `stats.d`), cooldowns and the attack swing loop.
* Creature AI, threat, death, loot (`LootHandler.cpp`), XP and level-up (`Player::GiveXP`, then
  `InitStatsForLevel`).

### 7. Social and progression

* Friends and ignore lists, guilds, mail, auction house and trade, each a handler group and
  module of its own, like `grouphandlers.d`.
* Quests (`QuestHandler.cpp`, `ObjectMgr::LoadQuests`).
* The rest of ArcEmu's GM commands, as their systems arrive (COMMANDS.md lists them): each is one
  method named after ArcEmu's handler.

### Infrastructure, as needed

* An epoll/kqueue loop beyond `select`'s 1024-descriptor limit.
* Asynchronous database calls, or a worker thread for saves, once saves become frequent.
* The rest of the login server: `crcHash` file integrity, PIN/TOTP (`account.token`) and patch
  transfer.
