# Status and roadmap

## What works

| Area | State | Where |
|---|---|---|
| Login server | Complete: SRP6, reconnect, realm list, bans, throttling, account CLI | `auth/` |
| DBC extraction | Complete for DBCs; maps, vmaps and mmaps not started | `extractor/`, `mpq/` |
| World handshake | Complete: session key proof, header encryption, addons, ping | `world/session.d` |
| Character list, creation, deletion | Full parity with CMaNGOS, incl. guild, group, auction and mail cleanup on delete | `world/charscreen.d`, `playercreate.d`, `characterdb.d` |
| Entering the world | Character, inventory, skills, spellbook, action bars, stats with gear; same packet sequence as mangosd | `world/charscreen.d`, `player.d`, `stats.d` |
| In the world | Movement remembered and saved, name, item, time and played-time queries, say/yell/emote echo, stand state, action buttons, tutorials, logout | `world/inworld.d` |

### Known gaps in what exists

* **Stats:** auras, talents' effects and racial passives are not applied. Crit, dodge, parry and
  block chances are 0. Item stat bonuses, armor, attack power and weapon damage are applied.
* **Not loaded:** reputation (needs `Faction.dbc` and `character_reputation`), guild membership
  (`PLAYER_GUILDID`), quests, auras, cooldowns, pets, corpses and death. A dead character loads
  alive.
* **Logout is instant** for everyone (mangosd: 20 seconds unless resting), because there is no
  timer loop yet.
* **Movement** is not validated. Explored zones and area triggers are not updated; both need map
  data.

## Next milestones

The order follows dependencies: almost everything after milestone 2 needs a map with visibility
and an update loop.

### 1. Other players: a map with visibility

The point at which two people can see each other. CMaNGOS references: `Maps/Map.cpp`, `Grids/`,
`Entities/Object.cpp` (`UpdateVisibilityOf`), `MotionGenerators/MovementHandler.cpp`,
`Chat/ChatHandler.cpp`.

* A `Map` per map id, holding the players on it. CMaNGOS uses grids and cells; a cell grid keyed by
  position (an associative array of cell → players) is enough to start with.
* On login, `Map.add`. Send the newcomer's create block, using `seenByEveryone`, to players in
  range (`Visibility.Distance.Continents`, 90 yards by default), and theirs to the newcomer.
  Remove them with `UPDATETYPE_OUT_OF_RANGE_OBJECTS` when they leave range or log out.
* Relay `MSG_MOVE_*` to observers, with the mover's packed guid first. Recompute visibility after
  significant moves.
* Say (25 yards), yell (300 yards) and emotes go to nearby players, plus whispers by name.
* `CMSG_NAME_QUERY` answers from online players first.
* Health to non-group viewers: the `DYNAMIC` percentage rule from `Object::BuildValuesUpdate`.

### 2. An update loop and timers

CMaNGOS references: `World/World.cpp` (`World::Update`), `Server/WorldSession.cpp`
(`WorldSession::Update`), `Entities/Player.cpp` (`Player::Update`, `RegenerateAll`).

* A tick in `net/server.d` (`select` with a timeout), calling `WorldContext.update(diff)`, then each
  session's update.
* The 20-second logout and the in-combat check. Health, mana and energy regeneration. Rest state
  and rested XP. Periodic saves (`PlayerSaveInterval`).
* Map updates for milestones 1 and 3.

### 3. Creatures and game objects

CMaNGOS references: `Entities/Creature.cpp`, `GameObject.cpp`, `Globals/ObjectMgr.cpp`
(`LoadCreatures`, `LoadGameObjects`), and `QueryHandler.cpp` (creature and game object queries).

* Load `creature`/`creature_template` and `gameobject`/`gameobject_template` into `WorldData`, and
  spawn them into maps by cell.
* Create blocks with the `UNIT`/`GAMEOBJECT` field ranges; `updatefields.d` already has them.
* `CMSG_CREATURE_QUERY`, `CMSG_GAMEOBJECT_QUERY`, and `SMSG_*_QUERY_RESPONSE`.
* NPC interaction follows: gossip, vendors, trainers, flight masters, bankers, innkeepers
  (`GossipHandler.cpp`, `NPCHandler.cpp`, `TaxiHandler.cpp`).

### 4. Map data

CMaNGOS references: `contrib/extractor`, `contrib/vmap_extractor`, `contrib/mmap`,
`src/game/Maps/GridMap.cpp`.

* Extend the extractor to write CMaNGOS's `maps/*.map` files: heights, areas and liquids from ADT
  and WDT. The MPQ reader already handles the archives.
* Load them for ground height, area ids (explored zones, `CMSG_ZONEUPDATE` checks), and later
  line of sight (vmaps) and pathfinding (mmaps, via recast/detour or the mmaps CMaNGOS writes).

### 5. Inventory

CMaNGOS reference: `Entities/ItemHandler.cpp`, `Player.cpp` (`CanStoreItem`, `CanEquipItem`,
`SwapItem`, ...).

* Swap, split, equip, unequip, destroy and auto-store, with item create and values updates.
* `playercreate.d` already ports `CanStoreItem`, `CanEquipItem` and friends for creation. Move
  them to a shared inventory module used by both creation and the handlers.
* Saving item changes (`Item::SaveToDB` states).

### 6. Spells, auras and combat

The largest area. CMaNGOS references: `Spells/`, `Entities/Unit.cpp`, `Combat/`, `AI/`.

* Spell casting with effects, auras (feeding `stats.d`), cooldowns and the attack swing loop.
* Creature AI, threat, death, loot (`LootHandler.cpp`), XP and level-up (`Player::GiveXP`, then
  `InitStatsForLevel`).

### 7. Social and progression

* Friends and ignore lists, channels, groups, guilds, mail, auction house and trade, each a
  handler group and module of its own.
* Quests (`QuestHandler.cpp`, `ObjectMgr::LoadQuests`). GM commands (`Chat/Level*.cpp`), parsed
  from chat messages that start with `.`.

### Infrastructure, as needed

* An epoll/kqueue loop beyond `select`'s 1024-descriptor limit.
* Asynchronous database calls, or a worker thread for saves, once saves become frequent.
* The rest of the login server: `crcHash` file integrity, PIN/TOTP (`account.token`) and patch
  transfer.
