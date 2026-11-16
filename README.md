# dmangos

A World of Warcraft **1.12.x (vanilla)** server written in **D**, modelled on
[CMaNGOS Classic](https://github.com/cmangos/mangos-classic) and
[Ember](https://github.com/EmberEmu/Ember). It has two programs:

* **authserver**, the login server (CMaNGOS's `realmd`): SRP6 authentication, reconnects and
  the realm list. It is complete.
* **worldserver** (CMaNGOS's `mangosd`), in progress. Clients can connect, authenticate with the
  session key from the login server, list, create and delete characters, and enter the world
  with them: the character has its gear, bags, skills, spellbook and action bars, and is saved on
  logout. Players on the same map see each other move, sit and emote, hear each other's say, yell
  and emotes, and can whisper. There are no creatures or objects yet.
* **extractor** copies the DBC files out of a 1.12 client's MPQ archives into a `dbc/` folder.
  That folder is the client data the world server reads.

Both run on **unmodified CMaNGOS MySQL/MariaDB databases** (`classicrealmd`,
`classiccharacters`, `classicmangos`), so they can take over from CMaNGOS, or run beside it,
against the same data.

## Building

You need a D compiler and `dub`. The quickest install, with no root needed, goes into `~/dlang`:

```sh
curl -fsS https://dlang.org/install.sh | bash -s dmd
source ~/dlang/dmd-*/activate
```

Then:

```sh
dub build -c authserver        # -> bin/authserver (the default configuration)
dub build -c worldserver       # -> bin/worldserver
dub build -c extractor         # -> bin/extractor
dub test                       # every unit test
```

## Database

The server needs a MySQL or MariaDB database with the CMaNGOS realmd schema. An
existing CMaNGOS `classicrealmd` database works as is. For a new one:

```sh
mysql -u root -p -e "CREATE DATABASE classicrealmd"
mysql -u root -p classicrealmd < mangos-classic/sql/base/realmd.sql
```

The schema ships four sample accounts (ADMINISTRATOR, GAMEMASTER, MODERATOR, PLAYER), each
with the password equal to its name. Change those passwords before exposing the server.

The MySQL client library is loaded at run time, so building needs no MySQL headers. Running
needs `libmariadb3` (MariaDB Connector/C) or `libmysqlclient` installed; any authentication
plugin they support works, including MySQL 8's `caching_sha2_password`. Set `mysql_library`
in the configuration to use a specific file.

## Running the login server

```sh
cp config/authserver.example.json authserver.json   # then edit login_database
./bin/authserver account create myname mypassword
./bin/authserver                                     # listens on 0.0.0.0:3724
```

Point the client's `realmlist.wtf` at the machine with `set realmlist 127.0.0.1`.

As in CMaNGOS, a realm is shown **offline** unless its `realmlist.realmbuilds` column lists
the client's build. The world server fills that column in when it starts. Changes to
`realmlist` are picked up every `realms_state_update_delay` seconds.

Administration (writes the same rows as CMaNGOS's own account commands):

```
authserver account create NAME PASSWORD [player|moderator|gameMaster|administrator]
authserver account password NAME PASSWORD
authserver account level NAME LEVEL
authserver account ban NAME [DAYS] [REASON]   # no DAYS, or 0 = permanent
authserver account unban NAME
authserver account list
authserver ip ban ADDRESS [DAYS] [REASON]
authserver ip unban ADDRESS
```

### Configuration

| Key | realmd.conf equivalent | Default |
|---|---|---|
| `login_database` | `LoginDatabaseInfo` (same `host;port;user;password;db` format, `.;socket;…` for a Unix socket) | `127.0.0.1;3306;mangos;mangos;classicrealmd` |
| `bind_address`, `port` | `BindIP`, `RealmServerPort` | `0.0.0.0`, `3724` |
| `realms_state_update_delay` | `RealmsStateUpdateDelay` | `20` |
| `wrong_pass_max_count` | `WrongPass.MaxCount` (0 = off) | `0` |
| `wrong_pass_ban_time` | `WrongPass.BanTime` (seconds) | `600` |
| `wrong_pass_ban_type` | `WrongPass.BanType` (`"ip"` = 0, `"account"` = 1) | `"ip"` |
| `allowed_builds` | n/a | `[5875, 6005, 6141]` |
| `max_failed_logins`, `failed_login_block` | n/a: an extra in-memory per-IP throttle (0 = off) | `5`, `900` |
| `mysql_library`, `idle_timeout`, `max_connections`, `log_level` | n/a | |

Passwords given on the command line end up in shell history, so treat
`account create` as a development convenience.

## Running the world server

```sh
cp config/worldserver.example.json worldserver.json # then edit the *_database entries and data_dir
./bin/worldserver                                   # listens on 0.0.0.0:8085
```

`data_dir` must point at a directory containing a `dbc/` folder extracted from your client. Use
dmangos's own extractor (below), or point it at mangosd's `DataDir`, which works as is. Character creation reads
`ChrClasses`, `ChrRaces`, `CharStartOutfit`, `CharSections`, `CharacterFacialHairStyles`,
`SkillLine`, `SkillLineAbility`, `SkillRaceClassInfo`, `SkillTiers`, `Talent` and `TalentTab`
from it. Entering the world also reads `CreatureDisplayInfo`, `CreatureModelData`, `Emotes`,
`EmotesText`, `Map`, `AreaTable`, `AreaTrigger` and `ChatChannels`.

As mangosd does, at start-up it marks its realm (`realm_id`) online in `realmlist`, writes
`realmbuilds`, the realm type and the zone, and opens an `uptime` row. While running it
updates `population` and `uptime`, and at shutdown it marks the realm offline again. The
`realmlist` row's `address` and `port` must point at this server.

What works now:

* `SMSG_AUTH_CHALLENGE` / `CMSG_AUTH_SESSION`, checked against `account.sessionkey`, with the same
  checks and replies as CMaNGOS: unknown account, IP lock, missing key, bans, wrong proof,
  unsupported build. Connections are logged in `account_logons` with `loginSource` 1.
* Header encryption with the session key, the addon reply, `CMSG_PING`/`SMSG_PONG` with
  CMaNGOS's over-speed kick (`max_overspeed_pings`), and one session per account (a new
  login kicks the old one).
* The character list (`SMSG_CHAR_ENUM`), built as CMaNGOS's `Player::BuildEnumData` does: from
  `characters`, `character_pet` and `guild_member`, with equipment from `equipmentCache` and
  `item_template`, and pets from `creature_template`.
* Character creation (`CMSG_CHAR_CREATE`), a port of `HandleCharCreateOpcode` and
  `Player::Create`:
  * **Checks:** the same as CMaNGOS: creation-disabled mask, race and class, appearance against
    `CharSections`, name normalization and `StrictPlayerNames`/`MinPlayerName`, reserved names,
    name in use, per-account and per-realm limits, and faction rules on PvP realms.
  * **Character:** start position, level and stats, health and mana, the race's taxi nodes, and
    the default skills and spells, including every skill and spell they teach in turn.
  * **Items and bars:** the action bars, and the `CharStartOutfit` and `playercreateinfo_item`
    items, equipped or stored exactly where mangosd would put them. A hunter's arrows end up in
    the quiver.
  * **Rows written:** the same as `SaveToDB`, plus `realmcharacters` and the account's first
    `character_tutorial` row.
* Character deletion (`CMSG_CHAR_DELETE`), a port of `Player::DeleteFromDB`:
  * **Who:** only the account's own characters, and never a guild leader.
  * **What it does:** leaves or disbands the guild and the group, passing on the group lead if
    needed. Removes petitions. Cancels the character's auctions and refunds bidders by mail.
    Returns unpaid COD mail with items to its senders. Deletes pets and every table CMaNGOS
    deletes from.
  * `CharDelete.Method` 1 (unlink) and `CharDelete.MinLevel` are supported.
* Entering the world (`CMSG_PLAYER_LOGIN`), a port of `HandlePlayerLogin` and `Player::LoadFromDB`:
  * **Loading:** the character, its inventory (`character_inventory` and `item_instance`), skills,
    spells, action bars, home and the account's tutorial flags. As in CMaNGOS, default spells and
    the spells skills teach are not saved but learned again at every login. A character without a
    home is bound where its race starts.
  * **Packets:** the same sequence as mangosd: `SMSG_LOGIN_VERIFY_WORLD`, account data times, the
    message of the day (`motd`), rest state, bind point, tutorials, spellbook, action buttons,
    factions, game time, weapon and armor proficiencies, the race's intro on the first login, then
    one update packet creating every item, bag and the player, and the friend, ignore and world
    state lists.
  * **The player object:** all update fields CMaNGOS fills on login: looks, display id and model
    scale, faction, level, health and powers, stats with item bonuses, armor and resistances,
    attack power, weapon damage and speed, skills, explored zones, money and XP. Auras, talents'
    effects, crit/dodge/parry chances, reputation and guild membership are not applied yet.
  * **Update packets:** `SMSG_UPDATE_OBJECT` blocks built from a field mask, compressed over 100
    bytes, as CMaNGOS's `UpdateData` does.
* In the world:
  * **Other players:** players on the same map see each other within 100 yards: they appear,
    move, sit and emote for each other, and disappear when out of sight or logged out. Strangers
    see health in percent, group members the real values.
  * **Movement** (`MSG_MOVE_*`) is shown to those who see the player and saved. It is checked
    against the player's speed (`movement_speed_check`): a player that moves faster than it can
    run is put back.
  * **Teleports:** near and far teleports with the client's acknowledgements
    (`MSG_MOVE_TELEPORT_ACK`, `SMSG_TRANSFER_PENDING`, `SMSG_NEW_WORLD`, `MSG_MOVE_WORLDPORT_ACK`).
    Instance portals and the other `areatrigger_teleport` triggers apply CMaNGOS's checks (level,
    raid group, items, quests handed in) with the trigger's own message. The client's `worldport`
    command works for administrators.
  * **Groups:** invitations, parties and raids of up to 40 in eight sub-groups, leaders and
    assistants, kicking, leaving, loot settings, raid target icons, ready checks, rolls, minimap
    pings, and member stats for members out of sight. Groups are kept in `groups` and
    `group_member` and survive restarts. Logging out of a party leaves it, as in CMaNGOS.
  * **Chat:** say, yell and emotes reach those in range; whispers reach anyone online of the same
    faction; party, raid, raid leader and raid warning messages reach the group. `/afk` and `/dnd`
    set the flag, the chat tag and the reply to whispers.
  * **Channels:** the built-in ones (General, Trade, LocalDefense, ...), which follow the zone,
    and custom ones with owners, moderators, passwords, muting, kicks, bans, invitations,
    announcements and moderation. One set per faction, unless
    `allow_two_side_interaction_channel` is on.
  * **Commands** typed in chat: for moderators and up `.gps`, `.go xyz`, `.tele`, `.appear`,
    `.summon`, `.recall`, `.gm on|off`, `.gm chat on|off` and `.announce`; for everyone `.help`,
    `.commands`, `.save` and `.server info`.
  * **Queries:** name, item (`SMSG_ITEM_QUERY_SINGLE_RESPONSE`, from every `item_template`
    column), time and played time.
  * **Settings:** sitting and standing, target selection, action bar buttons and toggles, and
    tutorial flags, saved as they change.
  * **Logout** saves the position, zone, health and powers, played time and settings. It is
    instant for everyone, since there are no timers yet; mangosd makes players wait 20 seconds
    unless they are resting. A connection that drops in the world is saved the same way.
  * At start-up, every character and account of the realm is marked offline, as mangosd does.

Character, item, mail and group ids are allocated from `MAX(id) + 1` at start-up, as mangosd does. Never
run two world servers, or a world server and mangosd, on the same characters database at the same
time.

| Key | mangosd.conf equivalent | Default |
|---|---|---|
| `realm_id` | `RealmID` | `1` |
| `login_database`, `world_database`, `character_database` | `LoginDatabaseInfo`, `WorldDatabaseInfo`, `CharacterDatabaseInfo` | `…classicrealmd`, `…classicmangos`, `…classiccharacters` |
| `bind_address`, `port` | `BindIP`, `WorldServerPort` | `0.0.0.0`, `8085` |
| `game_type`, `realm_zone` | `GameType`, `RealmZone` | `1`, `1` |
| `player_limit` | `PlayerLimit` (used for the population shown) | `100` |
| `max_overspeed_pings` | `MaxOverspeedPings` | `2` |
| `uptime_update_interval` | `UpdateUptimeInterval` (minutes) | `10` |
| `data_dir` | `DataDir` | `.` |
| `characters_creating_disabled`, `characters_per_account`, `characters_per_realm` | `CharactersCreatingDisabled`, `CharactersPerAccount`, `CharactersPerRealm` | `0`, `50`, `10` |
| `allow_two_side_accounts`, `skip_cinematics` | `AllowTwoSide.Accounts`, `SkipCinematics` | `false`, `0` |
| `motd` | `Motd` (`@` starts a new line) | a short welcome |
| `visibility_distance`, `visibility_relocation_lower_limit` | `Visibility.Distance.Continents`, `Visibility.RelocationLowerLimit` | `100`, `10` |
| `listen_range_say`, `listen_range_text_emote`, `listen_range_yell` | `ListenRange.Say`, `ListenRange.TextEmote`, `ListenRange.Yell` | `25`, `25`, `300` |
| `allow_two_side_interaction_chat` | `AllowTwoSide.Interaction.Chat` (whispers between factions) | `false` |
| `allow_two_side_interaction_channel`, `allow_two_side_interaction_group` | `AllowTwoSide.Interaction.Channel`, `AllowTwoSide.Interaction.Group` | `false`, `false` |
| `gm_level_channel_moderation`, `gm_level_channel_silent_join` | `GM.ChannelModerationLevel`, `GM.ChannelSilentJoinLevel` (0 = nobody) | `1`, `0` |
| `chat_restricted_raid_warnings` | `Chat.RestrictedRaidWarnings` | `false` |
| `instance_ignore_level`, `instance_ignore_raid` | `Instance.IgnoreLevel`, `Instance.IgnoreRaid` | `false`, `false` |
| `movement_speed_check`, `movement_speed_tolerance`, `movement_speed_slack` | n/a (CMaNGOS leaves it to its anticheat module): allow this factor over running speed, plus these yards | `true`, `1.5`, `15` |
| `start_player_level`, `start_gm_level`, `start_player_money` | `StartPlayerLevel`, `GM.StartLevel`, `StartPlayerMoney` | `1`, `1`, `0` |
| `max_primary_trade_skill`, `trade_skill_gm_ignore_max_primary` | `MaxPrimaryTradeSkill`, `TradeSkill.GMIgnore.MaxPrimarySkillsCount` | `2`, `4` |
| `strict_player_names`, `min_player_name` | `StrictPlayerNames`, `MinPlayerName` | `0`, `2` |
| `char_delete_method`, `char_delete_min_level`, `mail_delivery_delay` | `CharDelete.Method`, `CharDelete.MinLevel`, `MailDeliveryDelay` | `0`, `0`, `3600` |
| `allowed_builds`, `mysql_library`, `idle_timeout`, `max_connections`, `log_level` | n/a | |

## Extracting client data

```sh
./bin/extractor -i "/path/to/WoW 1.12.1" -o /path/to/data   # writes /path/to/data/dbc/*.dbc
```

The extractor follows CMaNGOS's `ad` extractor:

* It opens `model`, `dbc`, `terrain`, `patch` and `patch-2.MPQ` from the client's `Data` folder,
  and looks files up newest archive first, so patches win.
* It copies every `.dbc` named in the archives' listfiles unchanged. The output works for
  mangosd too.
* It checks that each file is a complete DBC, and skips one-byte placeholders that patches use
  for removed files.

A 1.12.1 client yields 158 files in well under a second. The MPQ reader (`source/dmangos/mpq/`)
handles plain, encrypted, sector and single-unit files, compressed with zlib or PKWare DCL, which
are the encodings 1.12 data files use. Maps, vmaps and mmaps still come from CMaNGOS's tools;
nothing in dmangos reads them yet.

## Layout

One dub package. Module names follow the directories, as in dub and D-Scanner.

```
dub.json                    configurations: "authserver", "worldserver" and "extractor"
config/                     example configuration
docs/                       architecture, design, developer guide, roadmap
tools/testclient.py         scripted 1.12.1 client for live tests
source/dmangos/             code shared by every server
  bytes.d                     ByteReader / ByteWriter (little-endian, slicing, no copies)
  dbc.d                       DBC reader generated at compile time from CMaNGOS format strings
  mpq/                        MPQ archive reader: crypt.d (tables, hashing), explode.d (PKWare DCL), archive.d
  serialization.d             UDA-driven packet (de)serializer and wireSize, generated at compile time
  json.d                      struct <-> JSON mapping by introspection (configuration)
  hex.d                       hex <-> bytes, usable in CTFE (hexLiteral!"...")
  log.d                       leveled logger with compile-time checked format strings
  crypto/                     SRP6, SHA-1 helpers, BigInt <-> little-endian, OS randomness
  mysql/                      run-time loaded MySQL C API binding; connection with compile-time checked queries
  net/                        select() event loop (server.d); compile-time packet dispatch (dispatch.d)
source/dmangos/auth/        the login server (realmd)
  main.d                      entry point: run the server, administer accounts
  protocol.d                  opcodes, result codes, every packet as a struct
  session.d                   per-client protocol state machine (sans-I/O)
  accounts.d                  accounts; CMaNGOS s/v/sessionkey encoding; decoy credentials
  database.d                  LoginDatabase interface and an in-memory implementation for tests
  mysqldb.d                   LoginDatabase on the CMaNGOS realmd schema
  config.d                    configuration and validation
  realms.d                    realmlist rules: build checks, security levels, categories, refresh
  throttle.d                  per-IP brute-force protection
source/dmangos/world/       the world server (mangosd)
  main.d                      entry point
  session.d                   per-client state machine: framing, handshake, ping (sans-I/O)
  charscreen.d                handlers: character list, creation, deletion, entering the world
  inworld.d                   handlers: logout, movement and its check, queries, settings, chat, emotes
  teleport.d                  handlers and TeleportTo: near and far teleports, area triggers
  grouphandlers.d             handlers: invitations, raids, loot settings, icons, ready checks, rolls
  channelhandlers.d           handlers: chat channels
  commands.d                  chat commands (.tele, .gps, ...), a table built from @Command attributes
  map.d                       players on a map: cells, who sees whom, broadcasting
  online.d                    OnlinePlayer and Directory: what groups and channels see of players
  group.d                     groups: members, leaders, raids, the group list, member stats
  channel.d                   chat channels: members, owners, moderation, notices
  defines.d                   shared game constants (SharedDefines.h): classes, powers, item classes, slots
  packets.d                   world packet layouts and framing
  opcodes.d                   opcode and result code values (CMaNGOS names)
  crypt.d                     header encryption with the session key
  addons.d                    addon list parsing and SMSG_ADDON_INFO
  characters.d                character list entries (Player::BuildEnumData)
  playercreate.d              character creation (Player::Create): skills, spells, outfit, inventory;
                              also the skills and spells re-learned at login
  player.d                    a character in the world: loading, item and player objects, saving
  stats.d                     derived stats: item bonuses, health, mana, armor, attack power, damage
  updatefields.d              the client's update field table; constants and per-type tables derived from it
  objects.d                   guids, update field values, SMSG_UPDATE_OBJECT blocks
  movement.d                  movement info and speeds
  queries.d                   item query and chat message bodies
  characterdb.d               SaveToDB / DeleteFromDB statements, incl. guild, group, auction, mail
  names.d                     character name rules
  clientdata.d                DBC records and CMaNGOS's derived indexes
  spells.d                    spell_template, spell chains, spell-learn links
  testdata.d, testclient.d    test fixtures and a scripted client (unittest builds only)
  database.d                  login/characters database access; in-memory version for tests
  worlddata.d                 items, creatures, playercreateinfo_*, level stats from the world database
  realm.d                     realmlist/uptime registration, as mangosd does
  config.d, context.d         configuration; state shared by sessions
source/dmangos/extractor/   the client data extractor: main.d, dbc.d (DBC extraction)
```

Each program is a dub configuration with its own `main.d`, which the other configuration
excludes. This is how DCD builds `dcd-server` and `dcd-client` from one package.

## Documentation

* [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how the programs and modules fit together, the
  life of a packet, session states, static data, databases, entering the world, update fields.
* [docs/DESIGN.md](docs/DESIGN.md): which D features are used for what, and why. CMaNGOS's
  behaviour, D's structure.
* [docs/DEVELOPING.md](docs/DEVELOPING.md): recipes (new packet, handler group, DBC, table,
  config key), testing (unit and live), and pitfalls found so far.
* [docs/ROADMAP.md](docs/ROADMAP.md): what works, known gaps, and the next milestones with their
  CMaNGOS references.

In short, protocol tables (update fields, packet layouts, DBC formats, SQL statements, opcode
routes) are compile-time data, and the code that uses them is generated and checked by the
compiler. `UpdateValues.set!UNIT_FIELD_STAT0(22.5f)` does not compile, because stats are integers.

## Protocol notes

* Supported builds: 5875 (1.12.1), 6005 (1.12.2), 6141 (1.12.3). The packet layouts
  follow CMaNGOS's `BUILD_6005` variants. A failed logon proof is 2 bytes for 5875/6005
  and 4 bytes for 6141.
* SRP6 follows CMaNGOS `SRP6.cpp`. The session key interleave strips leading zero bytes
  of the little-endian `S`, plus one more byte when that leaves an odd count.
* Login decisions follow CMaNGOS `AuthSocket.cpp`. A banned IP gets "no access"; an account
  locked to another IP, or temporarily banned, gets "suspended"; broken `s`/`v` values get
  "no access"; a permanent ban gets "banned". An unknown account gets a decoy challenge that
  is stable per name, so names cannot be enumerated. A wrong password is answered with
  "unknown account" and counts toward the `WrongPass` autoban.
* Database queries are synchronous, as CMaNGOS's are on this path. A lost database
  connection is re-established automatically.
* Not implemented yet: client file integrity (`crcHash`), PIN/TOTP (`account.token`), patch
  transfer (`XFER_*`), the `antispam_*`, `uptime` and `system_fingerprint_usage` tables
  (they belong to mangosd).

## Roadmap

Next: an update loop with timers, then creatures and game objects.
See [docs/ROADMAP.md](docs/ROADMAP.md).
