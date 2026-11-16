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
| GM commands | `.gps`, `.go xyz`, `.tele`, `.appear`, `.summon`, `.recall`, `.gm`, `.gm chat`, `.announce`, `.help`, `.commands`, `.save`, `.server info` | `world/commands.d` |
| Movement checks | Speed checked against running speed; offenders put back. Positions outside the map disconnect | `world/inworld.d` |

### Known gaps in what exists

* **Stats:** auras, talents' effects and racial passives are not applied. Crit, dodge, parry and
  block chances are 0. Item stat bonuses, armor, attack power and weapon damage are applied.
* **Not loaded:** reputation (needs `Faction.dbc` and `character_reputation`), guild membership
  (`PLAYER_GUILDID`), quests, auras, cooldowns, pets, corpses and death. A dead character loads
  alive.
* **Logout is instant** for everyone (mangosd: 20 seconds unless resting), because there is no
  timer loop yet.
* **Movement:** the speed check assumes running speed; it must learn mounts, speed auras,
  knockbacks and taxis when those exist. Explored zones are not updated; that needs map data.
* **Teleports:** there is one map per map id, so everyone entering a dungeon shares one copy.
  Instance ids, binds (`character_instance`, `group_instance`) and resets come with milestone 3's
  map updates. Area triggers with a `condition_id` stay closed until conditions are loaded;
  taverns (rest) and quest triggers do nothing yet. Battlegrounds cannot be entered.
* **Groups:** an offline leader is not replaced after a while (that needs a timer). Loot
  settings are stored but nothing drops yet. The ignore list does not exist, so nobody can be
  ignored. Two-faction groups do not show the other faction as friendly.
* **Chat:** no ignore list, mutes, spam throttle or `Channel.RestrictedLanguageMode`.
  LocalDefense and WorldDefense need PvP ranks, which do not exist, so WorldDefense is read-only.
  GM visibility, whisper blocking and the `<GM>` state are not saved between logins.

## Next milestones

The order follows dependencies: almost everything after milestone 2 needs a map with visibility
and an update loop.

### 1. Other players: done

Players see each other (`world/map.d`), teleport between maps (`world/teleport.d`), group up
(`world/group.d`), talk in channels (`world/channel.d`) and are checked for speed. See
ARCHITECTURE.md's sections on maps, teleports, groups, channels and commands, and the gaps
listed above. Transports (boats, zeppelins) need game objects and come with milestone 3.

### 2. An update loop and timers

CMaNGOS references: `World/World.cpp` (`World::Update`), `Server/WorldSession.cpp`
(`WorldSession::Update`), `Entities/Player.cpp` (`Player::Update`, `RegenerateAll`).

* A tick in `net/server.d` (`select` with a timeout), calling `WorldContext.update(diff)`, then each
  session's update.
* The 20-second logout and the in-combat check. Health, mana and energy regeneration. Rest state
  and rested XP. Periodic saves (`PlayerSaveInterval`).
* Map updates for milestone 3. Visibility is driven by movement packets today; creatures will need
  the map to update on its own.

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

* Friends and ignore lists, guilds, mail, auction house and trade, each a handler group and
  module of its own, like `grouphandlers.d`.
* Quests (`QuestHandler.cpp`, `ObjectMgr::LoadQuests`).
* More GM commands (`Chat/Level*.cpp`): each is one `@Command` method in `commands.d`.

### Infrastructure, as needed

* An epoll/kqueue loop beyond `select`'s 1024-descriptor limit.
* Asynchronous database calls, or a worker thread for saves, once saves become frequent.
* The rest of the login server: `crcHash` file integrity, PIN/TOTP (`account.token`) and patch
  transfer.
