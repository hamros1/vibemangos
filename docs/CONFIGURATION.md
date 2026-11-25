# Configuration reference

Use the [setup guide](SETUP.md) to get a local realm running. Read [clustering](CLUSTER.md)
for multi-host clusters, gateways and failover.

dmangos uses the CMaNGOS Classic realm, character and world schemas. The world server creates
`dmangos_write_applied` in the characters database if needed to track writes already applied.
Use a separate characters database for each standalone realm. Nodes of a single cluster
share a characters database and draw IDs from their coordinator.

The servers load MariaDB Connector/C (`libmariadb3`) or `libmysqlclient` at run time. Set
`mysql_library` to load a specific file. The database connection string is
`host;port;user;password;db`. For a Unix socket, use `.;/path/to/mysql.sock;user;password;db`.

## Console logging

Both servers color their logs when standard error goes to a supported terminal.
`INFO` labels and messages are green. Warning labels are bold yellow and error labels are bold red.
Redirected logs are plain text. Set `NO_COLOR=1` to disable colors in a terminal.

## Login server settings

| Key | Meaning | Default |
|---|---|---|
| `login_database` | `host;port;user;password;db` (`.;socket;…` for a Unix socket) | `127.0.0.1;3306;mangos;mangos;classicrealmd` |
| `bind_address`, `port` | where it listens | `0.0.0.0`, `3724` |
| `realms_state_update_delay` | seconds between re-reads of `realmlist` | `20` |
| `wrong_pass_max_count` | wrong passwords before an automatic ban (0 = off) | `0` |
| `wrong_pass_ban_time` | that ban's length, in seconds | `600` |
| `wrong_pass_ban_type` | what it bans: `"ip"` or `"account"` | `"ip"` |
| `allowed_builds` | client builds accepted | `[5875, 6005, 6141]` |
| `max_failed_logins`, `failed_login_block` | an in-memory per-IP throttle: failures, then seconds blocked (0 = off) | `5`, `900` |
| `mysql_library`, `idle_timeout`, `max_connections`, `log_level` | the client library file, idle seconds, connection cap, logging | |

## World server settings

| Key | Meaning | Default |
|---|---|---|
| `realm_id` | the `realmlist` row this server is | `1` |
| `login_database`, `world_database`, `character_database` | `host;port;user;password;db` of each database | `…classicrealmd`, `…classicmangos`, `…classiccharacters` |
| `bind_address`, `port` | where it listens | `0.0.0.0`, `8085` |
| `game_type`, `realm_zone` | the realm's type and zone; a PvP realm (1, 8, 16) flags players in enemy and contested land | `1`, `1` |
| `player_limit` | used for the population shown | `100` |
| `max_overspeed_pings` | pings too close together, in a row, before a player is kicked (0 = off) | `2` |
| `uptime_update_interval` | minutes between `uptime` updates | `10` |
| `data_dir` | the folder holding `dbc/`, `maps/`, `vmaps/` and `mmaps/` | `.` |
| `characters_creating_disabled`, `characters_per_account`, `characters_per_realm` | bit 0 blocks creating Alliance characters, bit 1 Horde (player accounts); character limits | `0`, `50`, `10` |
| `allow_two_side_accounts`, `skip_cinematics` | both factions on one account on PvP realms; the race intro: 0 always shown, 1 skipped if the account has a character of that race, 2 never shown | `false`, `0` |
| `motd` | the message of the day (`@` starts a new line) | a short welcome |
| `visibility_distance`, `visibility_relocation_lower_limit` | how far players see (yards); how far one moves before what it sees is worked out again | `100`, `10` |
| `instance_unload_delay_seconds` | an empty dungeon copy resets after so long | `1800` |
| `instance_reset_time_hour` | the hour of the day (UTC) raids reset at, every `reset_delay` days | `4` |
| `grid_cleanup_delay_seconds` | a cell no player has been near for so long unloads its creatures and game objects; `0` never | `300` |
| `listen_range_say`, `listen_range_text_emote`, `listen_range_yell` | how far each is heard (yards) | `25`, `25`, `300` |
| `allow_two_side_interaction_chat` | whispers between factions | `false` |
| `allow_two_side_interaction_channel`, `allow_two_side_interaction_group` | one set of channels for both factions; groups across factions | `false`, `false` |
| `allow_two_side_interaction_auction` | one auction house for both factions | `false` |
| `rate_auction_deposit`, `rate_auction_cut`, `rate_auction_time`, `auction_deposit_min` | the auction houses' deposits, cuts and auction times, times these; the least deposit in copper | `1`, `1`, `1`, `0` |
| `allow_two_side_add_friend` | friends of the other faction | `false` |
| `allow_two_side_interaction_guild` | guilds of both factions | `false` |
| `chat_restricted_raid_warnings` | raid warnings only in raids | `false` |
| `allow_two_side_who_list` | the other faction in /who | `false` |
| `gm_level_in_who_list` | the highest account level players see in /who | `3` |
| `max_who_list_returns` | the most matches /who counts (it lists at most 49) | `49` |
| `instance_ignore_level`, `instance_ignore_raid` | skip the level and raid-group checks of instance entrances | `false`, `false` |
| `update_interval` | the world tick, in ms | `50` |
| `compression` | zlib level of update packets, 1 (fastest) to 9 | `1` |
| `metrics_interval_seconds` | seconds between log lines with tick times and GC figures; 0 for none | `60` |
| `honor_maintenance_day`, `min_honor_kills` | the day the honor week turns (0 Sunday); honorable kills needed for a place in the standing | `3`, `15` |
| `creature_pickpocket_restock_delay` | seconds before an emptied creature's pockets hold something again | `600` |
| `battleground_cast_deserter`, `battleground_premature_finish` | Deserter for leaving a battleground early; seconds a side may be short of players before it loses (0 never) | `true`, `300` |
| `battlegroup`, `battlegroup_node` | Optional shared battleground name and the node that hosts matches for this realm. [Setup](CLUSTER.md#cross-realm-battlegrounds) | Empty, `1` |
| `battleground_score_statistics` | each battle's scoreboard kept in `pvpstats_battlegrounds` and `pvpstats_players` | `false` |
| `max_pending_output_kb` | a client with more than this not yet sent to it (it is not reading) is disconnected; 0 no limit | `4096` |
| `mmaps` | creatures find their way over `data_dir/mmaps`, where there are movement maps | `true` |
| `write_log` | where writes wait, flushed to disk, until MySQL has them; written again at start-up (skipping what `dmangos_write_applied` says MySQL has); refused writes go to `<write_log>.failed`; empty for none | `"writes.log"` (`"writes-<node_id>.log"` in a cluster) |
| `disabled_transports` | ships and zeppelins (`transports.entry`) that do not sail, e.g. one a client cannot show | `[]` |
| `packet_log` | a directory where every packet sent to each client is written (time, opcode, body in hex), for finding what a client cannot take; empty for none | `""` |
| `cluster` | this node's place in the [cluster](CLUSTER.md#configuration) | example config starts node 1; omitted means standalone |
| `logout_delay`, `player_save_interval` | seconds a logout takes (GMs and resting players: none); seconds between saves of each character | `20`, `900` |
| `gm_permissions` | legacy command permissions for unenrolled accounts at levels 1, 2 and 3 | `{"1": "bcghiltuv", "2": "a", "3": "az"}` |
| `command_overrides` | other permission letters for commands: `[{"command": "gm on", "group": "m"}]` | none |
| `allow_player_commands`, `gm_command_log` | allows players to use public commands, and configures the log file for audited staff actions | `false`, none |
| `gamemaster_list_only_active_gms`, `gamemaster_hide_permissions` | `.gm list` shows players only GMs with the tag on; it hides GMs' permissions from players | `false`, `false` |
| `send_stats_on_join`, `gm_client_channel` | everyone, not only GMs, is told the population on entering the world; a channel only accounts with permissions may join | `true`, none |
| `flood_lines`, `flood_seconds`, `flood_message` | lines a player without permissions may say per period, and whether it is told (0 = off) | `0`, `0`, `false` |
| `announce_tag`, `announce_gm_admin_tag`, `announce_name_in_announce`, `announce_name_in_wannounce` | how `.announce` and `.wannounce` look | `Staff`, `false`, `true`, `true` |
| `announce_tag_color`, `announce_gm_tag_color`, `announce_name_color`, `announce_message_color` | their colours: 1 light red, 2 light blue, 3 blue, 4 green, 5 red, 6 gold, 7 grey, 8 white, 9 magenta, 10 yellow | `2`, `1`, `4`, `10` |
| `rate_health`, `rate_mana`, `rate_rage_loss`, `rate_energy` | regeneration rates | `1` |
| `rate_rest_ingame`, `rate_rest_offline_in_tavern_or_city`, `rate_rest_offline_in_wilderness` | rested experience rates | `1` |
| `rate_xp_explore` | exploration experience rate | `1` |
| `rate_reputation_gain`, `rate_reputation_lowlevel_kill`, `rate_reputation_lowlevel_quest` | reputation rates; the least share for grey kills and low quests | `1`, `0.2`, `0.2` |
| `max_player_level` | the level cap | `60` |
| `movement_speed_check`, `movement_speed_tolerance`, `movement_speed_slack` | the movement check: allow this factor over running speed, plus these yards | `true`, `1.5`, `15` |
| `rate_damage_fall` | falling damage rate | `1` |
| `mirror_timer_fatigue_max`, `mirror_timer_breath_max`, `mirror_timer_environmental_max` | seconds in deep water, under water and in lava before they hurt | `60`, `60`, `1` |
| `environmental_damage_min`, `environmental_damage_max` | lava's damage each time | `605`, `610` |
| `start_player_level`, `start_gm_level`, `start_player_money` | new characters' level; their level on moderator accounts and up; their money in copper | `1`, `1`, `0` |
| `max_primary_trade_skill`, `trade_skill_gm_ignore_max_primary` | primary professions a character may learn; the account level from which the limit is ignored | `2`, `4` |
| `strict_player_names`, `min_player_name` | the character name rules (0 any one script, bit 0 basic Latin, bit 1 the realm zone's script); the shortest name | `0`, `2` |
| `char_delete_method`, `char_delete_min_level`, `mail_delivery_delay` | delete (0) or unlink (1) characters, from which level; seconds before mail with an attached item arrives on a different account | `0`, `0`, `3600` |
| `allowed_builds`, `mysql_library`, `idle_timeout`, `max_connections`, `log_level` | client builds accepted; the client library file; idle seconds; connection cap (up to 60,000 on Linux, 1,000 elsewhere); logging | |

## CMaNGOS configuration equivalents

For operators moving a configuration over, the options of those files that have an equivalent here.
Times the old files give in milliseconds are seconds here.

| mangosd.conf / realmd.conf | Here |
|---|---|
| `RealmID`, `BindIP`, `WorldServerPort` / `RealmServerPort` | `realm_id`, `bind_address`, `port` |
| `LoginDatabaseInfo`, `WorldDatabaseInfo`, `CharacterDatabaseInfo` (same format) | `login_database`, `world_database`, `character_database` |
| `RealmsStateUpdateDelay`, `WrongPass.MaxCount`, `.BanTime`, `.BanType` (0 = ip, 1 = account) | `realms_state_update_delay`, `wrong_pass_max_count`, `wrong_pass_ban_time`, `wrong_pass_ban_type` |
| `GameType`, `RealmZone`, `PlayerLimit`, `MaxOverspeedPings`, `UpdateUptimeInterval`, `DataDir`, `Motd` | `game_type`, `realm_zone`, `player_limit`, `max_overspeed_pings`, `uptime_update_interval`, `data_dir`, `motd` |
| `CharactersCreatingDisabled`, `CharactersPerAccount`, `CharactersPerRealm`, `SkipCinematics` | `characters_creating_disabled`, `characters_per_account`, `characters_per_realm`, `skip_cinematics` |
| `AllowTwoSide.Accounts`, `.Interaction.Chat`, `.Interaction.Channel`, `.Interaction.Group`, `.Interaction.Auction`, `.Interaction.Guild`, `.AddFriend`, `.WhoList` | `allow_two_side_accounts`, `allow_two_side_interaction_chat`, `…_channel`, `…_group`, `…_auction`, `…_guild`, `allow_two_side_add_friend`, `allow_two_side_who_list` |
| `Visibility.Distance.Continents`, `Visibility.RelocationLowerLimit` | `visibility_distance`, `visibility_relocation_lower_limit` |
| `Instance.UnloadDelay` (ms), `GridCleanUpDelay` (ms), `Instance.IgnoreLevel`, `Instance.IgnoreRaid` | `instance_unload_delay_seconds`, `grid_cleanup_delay_seconds`, `instance_ignore_level`, `instance_ignore_raid` |
| `ListenRange.Say`, `.TextEmote`, `.Yell`, `Chat.RestrictedRaidWarnings` | `listen_range_say`, `listen_range_text_emote`, `listen_range_yell`, `chat_restricted_raid_warnings` |
| `GM.InWhoList.Level`, `MaxWhoListReturns`, `GM.StartLevel` | `gm_level_in_who_list`, `max_who_list_returns`, `start_gm_level` |
| `Compression`, `mmap.enabled`, `PlayerSave.Interval` (ms) | `compression`, `mmaps`, `player_save_interval` |
| `MaintenanceDay`, `MinHonorKills`, `Battleground.CastDeserter`, `BattleGround.PrematureFinishTimer` (ms) | `honor_maintenance_day`, `min_honor_kills`, `battleground_cast_deserter`, `battleground_premature_finish` |
| `Battleground.ScoreStatistics` | `battleground_score_statistics` |
| `Rate.Health`, `.Mana`, `.Rage.Loss`, `.Energy`, `Rate.Rest.*`, `Rate.XP.Explore`, `Rate.Reputation.Gain`, `.LowLevel.Kill`, `.LowLevel.Quest` | `rate_health`, `rate_mana`, `rate_rage_loss`, `rate_energy`, `rate_rest_*`, `rate_xp_explore`, `rate_reputation_gain`, `rate_reputation_lowlevel_kill`, `rate_reputation_lowlevel_quest` |
| `MaxPlayerLevel`, `StartPlayerLevel`, `StartPlayerMoney`, `MaxPrimaryTradeSkill`, `TradeSkill.GMIgnore.MaxPrimarySkillsCount` | `max_player_level`, `start_player_level`, `start_player_money`, `max_primary_trade_skill`, `trade_skill_gm_ignore_max_primary` |
| `StrictPlayerNames`, `MinPlayerName`, `CharDelete.Method`, `CharDelete.MinLevel`, `MailDeliveryDelay` | `strict_player_names`, `min_player_name`, `char_delete_method`, `char_delete_min_level`, `mail_delivery_delay` |

## Account administration

Run these commands from the installation directory or pass `--config FILE` before `account`
or `ip`. The login server can be running while you make these changes.

```
./bin/authserver account create NAME PASSWORD [player|moderator|gameMaster|administrator]
./bin/authserver account password NAME PASSWORD
./bin/authserver account level NAME LEVEL
./bin/authserver account ban NAME [DAYS] [REASON]   # no DAYS, or 0 = permanent
./bin/authserver account unban NAME
./bin/authserver account list
./bin/authserver ip ban ADDRESS [DAYS] [REASON]
./bin/authserver ip unban ADDRESS
```

## Move an existing world database

To preserve custom world data when moving an existing installation, export the world database
on the old host. The export uses `mariadb-dump` and takes read locks on the world tables.

```bash
sudo tools/database.sh export-world sql/local/classicmangos.sql.gz
```

For a MariaDB instance using a custom Unix socket, pass its socket path and use a database
account with read and lock permissions.

```bash
tools/database.sh export-world sql/local/classicmangos.sql.gz --socket=/path/to/mysql.sock
```

Use the exported archive in [step 2 of setup](SETUP.md#2-download-the-world-database-and-extract-client-data)
in place of the public download. The archive transfers world data. Accounts and characters
stay in their separate databases.

## Protocol notes

* Supported builds: 5875 (1.12.1), 6005 (1.12.2), 6141 (1.12.3). A failed logon proof is
  2 bytes for 5875/6005 and 4 bytes for 6141. A successful reconnect proof is 2 bytes.
* SRP6 is the variant the client uses. The session key interleave strips leading zero bytes
  of the little-endian `S`, plus one more byte when that leaves an odd count.
* Login decisions: a banned IP gets "no access"; an account
  locked to another IP, or temporarily banned, gets "suspended"; broken `s`/`v` values get
  "no access"; a permanent ban gets "banned". An unknown account gets a decoy challenge that
  is stable per name, so names cannot be enumerated. An unknown account and a wrong password
  both return the client's invalid-credentials dialog. Wrong passwords for known accounts count
  toward the automatic ban (`wrong_pass_max_count`).
* The login server's database queries are synchronous. A lost database connection is
  re-established automatically.
* Not implemented yet: client file integrity (`crcHash`), PIN/TOTP (`account.token`), patch
  transfer (`XFER_*`). The login server does not use the `antispam_*`, `uptime` and
  `system_fingerprint_usage` tables.
