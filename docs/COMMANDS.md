# GM commands

Type `.` or `!` before a command in chat. Use `.commands` to discover the commands you can run and
`.help <command>` for its syntax. Typing a group by itself, such as `.npc`, lists its available
subcommands. Exact names take priority and existing abbreviations still work.

| Task | Command |
|---|---|
| Show location | `.gps` or `.debug dumpcoords` |
| Travel to a map coordinate | `.travel coords <map> <x> <y> <z>` |
| Visit or summon a player | `.travel player <name>`, `.travel summon <name>` |
| Teach a spell to the selected player or yourself | `.learn <spell-id>` |
| Find a support ticket | `.gmTicket list` |
| Check your access | `.access whoami` |

## Give someone staff access

New installations include the role tables. Upgrade an existing login database from the repository
directory, then run the new worldserver binaries on every worker.

```sh
mariadb -u root -p classicrealmd < sql/gm-rbac.sql
```

Sign in to a legacy administrator account and run `.access grant <login> <role>`. Use the account's
login name. Roles are account-wide for all realms sharing this login database.

| Role | Access |
|---|---|
| `support` | Player lookup, tickets, moderation, announcements and relocation |
| `game-master` | Support, gameplay testing, events and world editing |
| `administrator` | Every capability, including role administration |

Run `.access revoke <login> <role>` to remove a role. Multiple roles combine their grants. An
enrolled account with zero roles has no staff access. Workers read current roles at login, on
handoff and before executing chat commands. Other staff behavior uses the last loaded policy.
Accounts that have never been enrolled still use `account.gmlevel`, `gm_permissions` and
`command_overrides`. The legacy `.account level` command sets that fallback policy. Configure
`gm_command_log` on every worker to record role changes and other audited staff actions.

## Create a narrow role

Run SQL against the login database to define a role, then grant it in game. For example, this role
can inspect NPCs and inherits the public commands available to staff. Broad gameplay privileges
are explicit capabilities such as `staff.access` and `staff.game_master`.

```sql
INSERT INTO dmangos_gm_role (role_name, description)
VALUES ('npc-inspector', 'Inspect selected creatures');

INSERT INTO dmangos_gm_role_permission (role_name, capability)
VALUES ('npc-inspector', 'command.npc info');
```

Then use `.access grant <login> npc-inspector`. A capability such as `world.creatures` grants
every command with that capability in the reference below. For one command, use
`command.<full command path>` with lowercase words, for example `command.character learn`.
Shortcuts share their original permission path. For `.travel coords` use `command.worldport`,
and for `.npc traineradd` use `command.addtrainerspell`.

## Edit a route or trainer

* Select a saved creature. Stand at each waypoint and use `.waypoint add [wait-ms]`. Use
  `.waypoint show` to review your draft and `.waypoint save` to commit the route. Use
  `.waypoint hide` to discard unsaved edits. Selecting a different spawn starts a new draft.
  A saved empty route makes the spawn idle. Attach existing movement scripts with
  `.waypoint script <point> <script-id>`.
* If you imported Classic-DB before this change, run
  `mariadb -u root -p classicmangos < sql/gm-waypoints.sql` against the world database.
  It converts the spawn and route tables to InnoDB. Run this migration during maintenance,
  then restart world workers after saving routes so they load the new paths.
* Select a trainer and run `.npc traineradd <teaching-spell-id> [cost-in-copper] [required-level]`.
  Use the spell that teaches the lesson. The selected worker uses it immediately, and the other
  workers pick it up on their next catalog refresh.

Use `.quest load` after updating quest definitions or giver relationships in the world database.
Workers switch to the new catalog after it loads.

## Design references

* Guild Wars lists commands in game. Final Fantasy XIV documents command groups, aliases and
  syntax. The same discovery workflow is available here through `.commands`, `.help` and group
  menus. [Guild Wars command reference](https://wiki.guildwars.com/wiki/Special_command)
  [Final Fantasy XIV command reference](https://na.finalfantasyxiv.com/lodestone/playguide/db/search/?category=text_command)
* RuneScape documents its developer cheats separately from player commands. This server gives
  testing toggles their own `testing.cheats` capability. [RuneScape developer cheats](https://developer.runescape.com/rs/cheats.html)
* Aion's location command is an example of a short, task-based shortcut. WildStar's publisher
  patch archive shows the role of chat in the player UI. That informed direct travel shortcuts
  and chat-based staff feedback. [Aion command reference](https://power.ncsoft.jp/aion/powerWiki/操作方法およびコマンド)
  [WildStar Redmoon Rising patch notes](https://store.steampowered.com/news/posts/?appids=376570&enddate=1472591462)

## Working commands (280)

Generated from the command tables by `python3 tools/commands_doc.py`.

| Command | Capability | Help |
|---|---|---|
| `.commands` | `public` | Shows Commands |
| `.help` | `public` | Shows help for command |
| `.announce` | `staff.announce` | Sends Msg To All |
| `.wannounce` | `staff.announce` | Sends Widescreen Msg To All |
| `.appear` | `world.teleport` | Teleports to x's position. |
| `.summon` | `world.teleport` | Summons x to your position |
| `.kill` | `character.combat` | .kill - Kills selected unit. |
| `.killplr` | `character.combat` | .killplr <name> - Kills specified player |
| `.revive` | `character.combat` | Revives you. |
| `.reviveplr` | `character.combat` | Revives player specified. |
| `.demorph` | `character.modify` | Demorphs from morphed model. |
| `.mount` | `character.modify` | Mounts into modelid x. |
| `.dismount` | `character.mount` | Dismounts. |
| `.gps` | `public` | Shows Position |
| `.scourge` | `staff.admin` | .scourge start\|stop\|status |
| `.worldport` | `world.teleport` |  |
| `.start` | `character.modify` | Teleport's you to a starting location |
| `.invincible` | `staff.presence` | .invincible - Toggles INVINCIBILITY (mobs won't attack you) |
| `.invisible` | `staff.presence` | .invisible - Toggles INVINCIBILITY and INVISIBILITY (mobs won't attack you and nobody can see you, but they can see your chat messages) |
| `.playerinfo` | `character.modify` | .playerinfo - Displays informations about the selected character (account...) |
| `.levelup` | `character.modify` | Levelup x lvls |
| `.modify hp` | `character.modify` | Modifies health points (HP) of selected target |
| `.modify gender` | `character.modify` | Changes gender of selected target. Usage: 0=male, 1=female. |
| `.modify mana` | `character.modify` | Modifies mana points (MP) of selected target. |
| `.modify rage` | `character.modify` | Modifies rage points of selected target. |
| `.modify energy` | `character.modify` | Modifies energy points of selected target. |
| `.modify level` | `character.modify` | Modifies the level of selected target. |
| `.modify strength` | `character.modify` | Modifies the strength value of the selected target. |
| `.modify agility` | `character.modify` | Modifies the agility value of the selected target. |
| `.modify intelligence` | `character.modify` | Modifies the intelligence value of the selected target. |
| `.modify spirit` | `character.modify` | Modifies the spirit value of the selected target. |
| `.modify armor` | `character.modify` | Modifies the armor of selected target. |
| `.modify holy` | `character.modify` | Modifies the holy resistance of selected target. |
| `.modify fire` | `character.modify` | Modifies the fire resistance of selected target. |
| `.modify nature` | `character.modify` | Modifies the nature resistance of selected target. |
| `.modify frost` | `character.modify` | Modifies the frost resistance of selected target. |
| `.modify shadow` | `character.modify` | Modifies the shadow resistance of selected target. |
| `.modify arcane` | `character.modify` | Modifies the arcane resistance of selected target. |
| `.modify damage` | `character.modify` | Modifies the damage done by the selected target. |
| `.modify ap` | `character.modify` | Modifies the attack power of the selected target. |
| `.modify rangeap` | `character.modify` | Modifies the range attack power of the selected target. |
| `.modify scale` | `character.modify` | Modifies the scale of the selected target. |
| `.modify gold` | `character.modify` | Modifies the gold amount of the selected target. Copper value. |
| `.modify speed` | `character.modify` | Modifies the movement speed of the selected target. |
| `.modify nativedisplayid` | `character.modify` | Modifies the native display identifier of the target. |
| `.modify displayid` | `character.modify` | Modifies the display identifier (DisplayID) of the target. |
| `.modify flags` | `character.modify` | Modifies the flags of the selected target. |
| `.modify faction` | `character.modify` | Modifies the faction template of the selected target. |
| `.modify dynamicflags` | `character.modify` | Modifies the dynamic flags of the selected target. |
| `.modify talentpoints` | `character.modify` | Modifies the available talent points of the selected target. |
| `.modify happiness` | `character.modify` | Modifies the happiness value of the selected target. |
| `.modify boundingraidius` | `character.modify` | Modifies the bounding radius of the selected target. |
| `.modify combatreach` | `character.modify` | Modifies the combat reach of the selected target. |
| `.modify npcemotestate` | `character.modify` | Modifies the NPC emote state of the selected target. |
| `.modify bytes` | `character.modify` | WARNING! Modifies the bytes entry of selected target. |
| `.waypoint add` | `world.waypoints` | .waypoint add [wait-ms] — Adds your position to the draft |
| `.waypoint show` | `world.waypoints` | .waypoint show — Lists the selected spawn’s draft |
| `.waypoint hide` | `world.waypoints` | .waypoint hide — Closes the draft and discards unsaved edits |
| `.waypoint delete` | `world.waypoints` | .waypoint delete <point> |
| `.waypoint movehere` | `world.waypoints` | .waypoint movehere <point> |
| `.waypoint waittime` | `world.waypoints` | .waypoint waittime <point> <milliseconds> |
| `.waypoint change` | `world.waypoints` | .waypoint change <point> <new-point> |
| `.waypoint info` | `world.waypoints` | .waypoint info <point> |
| `.waypoint movetype` | `world.waypoints` | .waypoint movetype <loop\|linear> |
| `.waypoint generate` | `world.waypoints` | .waypoint generate — Extends the draft to your position using the navigation mesh. |
| `.waypoint script` | `world.waypoints` | .waypoint script <point> <script-id\|0> — Attaches or clears a movement script |
| `.waypoint save` | `world.waypoints` | .waypoint save — Persists the selected route |
| `.waypoint deleteall` | `world.waypoints` | .waypoint deleteall — Clears the selected draft |
| `.debug infront` | `debug.use` |  |
| `.debug showreact` | `debug.use` |  |
| `.debug aimove` | `debug.use` | .debug aimove <x> <y> <z> |
| `.debug dist` | `debug.use` |  |
| `.debug face` | `debug.use` |  |
| `.debug moveinfo` | `debug.use` |  |
| `.debug setbytes` | `debug.use` |  |
| `.debug getbytes` | `debug.use` |  |
| `.debug unroot` | `debug.use` |  |
| `.debug root` | `debug.use` |  |
| `.debug landwalk` | `debug.use` |  |
| `.debug waterwalk` | `debug.use` |  |
| `.debug castspell` | `debug.use` | .castspell <spellid> - Casts spell on target. |
| `.debug castself` | `debug.use` | .castself <spellId> - Target casts spell <spellId>Â on itself. |
| `.debug castspellne` | `debug.use` | .castspellne <spellid> - Casts spell on target (only plays animations, doesnt handle effects or range/facing/etc. |
| `.debug aggrorange` | `debug.use` | .aggrorange - Shows aggro Range of the selected Creature. |
| `.debug knockback` | `debug.use` | .knockback <value> - Knocks you back. |
| `.debug fade` | `debug.use` | .debug fade <0-100> — Reduces your threat on the selected creature by a percentage. |
| `.debug threatMod` | `debug.use` | .debug threatMod <-100–100> — Adjusts your threat on the selected creature by a percentage. |
| `.debug calcThreat` | `debug.use` | .debug calcThreat <damage> <spell-id> — Estimates threat with your current modifiers. |
| `.debug threatList` | `debug.use` | .threatList  - returns all AI_Targets of the selected Creature. |
| `.debug gettptime` | `debug.use` | Shows the current ship or zeppelin circuit time. |
| `.debug itempushresult` | `debug.use` | sends item push result |
| `.debug setbit` | `debug.use` |  |
| `.debug setvalue` | `debug.use` |  |
| `.debug dumpcoords` | `debug.use` |  |
| `.debug sendpacket` | `debug.use` | <opcode ID>, <data> |
| `.debug rangecheck` | `debug.use` | Checks the 'yard' range and internal range between the player and the target. |
| `.debug testlos` | `debug.use` | tests los |
| `.debug testindoor` | `debug.use` | tests indoor |
| `.debug getheight` | `debug.use` | Gets height |
| `.debug getpos` | `debug.use` |  |
| `.debug getUint32Value` | `debug.use` |  |
| `.gm list` | `public` | Shows active GM's |
| `.gm off` | `staff.tag` | Sets GM tag off |
| `.gm on` | `staff.tag` | Sets GM tag on |
| `.gm whisperblock` | `world.objects.move` | Blocks like .gmon except without the <GM> tag |
| `.gm allowwhispers` | `staff.support` | Allows whispers from player <s> while in gmon mode. |
| `.gm blockwhispers` | `staff.support` | Blocks whispers from player <s> while in gmon mode. |
| `.gmTicket list` | `support.tickets` | Lists all active GM Tickets. |
| `.gmTicket get` | `support.tickets` | Gets GM Ticket with ID x. |
| `.gmTicket remove` | `support.tickets` | Removes GM Ticket with ID x. |
| `.gmTicket deletepermanent` | `staff.admin` | Deletes GM Ticket with ID x permanently. |
| `.gmTicket assign` | `support.tickets` | Assignes GM Ticket with id x to GM y (if empty to your self). |
| `.gmTicket release` | `support.tickets` | Releases assigned GM Ticket with ID x. |
| `.gmTicket comment` | `support.tickets` | Sets comment x to GM Ticket with ID y. |
| `.gmTicket toggle` | `staff.admin` | Toggles the ticket system status. |
| `.gobject select` | `world.objects` | Selects the nearest GameObject to you |
| `.gobject delete` | `world.objects` | Deletes selected GameObject |
| `.gobject spawn` | `world.objects` | Spawns a GameObject by ID |
| `.gobject info` | `world.objects` | Gives you informations about selected GO |
| `.gobject activate` | `world.objects` | Activates/Opens the selected GO. |
| `.gobject enable` | `world.objects` | Enables the selected GO for use. |
| `.gobject scale` | `world.objects` | Sets scale of selected GO |
| `.gobject animprogress` | `world.objects` | Sets anim progress |
| `.gobject export` | `world.objects` | Prints coordinates and rotation of the selected game object. |
| `.gobject move` | `world.objects.move` | Moves gameobject to player xyz |
| `.gobject rotate` | `world.objects.move` | <Axis> <Value> - Rotates the object. <Axis> x,y, Default o. |
| `.battleground setbgscore` | `battleground.manage` | .battleground setbgscore <alliance\|horde> <score> — Sets a below-win score in Warsong Gulch or Arathi Basin. |
| `.battleground startbg` | `battleground.manage` | Starts current battleground match. |
| `.battleground bginfo` | `battleground.manage` | Displays information about current battleground. |
| `.battleground battleground` | `battleground.manage` | Shows the current match and how to list match commands. |
| `.battleground setworldstate` | `battleground.manage` | <var> <val> - Var can be in hex. WS Value. |
| `.battleground setworldstates` | `battleground.manage` | <var> <val> - Var can be in hex. WS Value. |
| `.battleground playsound` | `battleground.manage` | <val>. Val can be in hex. |
| `.battleground setbfstatus` | `battleground.manage` | .battleground setbfstatus start — Starts the current match. |
| `.battleground leave` | `battleground.manage` | Leaves the current battleground. |
| `.battleground getqueue` | `staff.admin` | Shows queue and match counts from the battlegroup coordinator. |
| `.battleground forcestart` | `staff.admin` | Forces initialitation of all battlegrounds with active queue. |
| `.npc vendoradditem` | `world.creatures` | Adds to vendor |
| `.npc vendorremoveitem` | `world.creatures` | Removes from vendor. |
| `.npc flags` | `world.creatures` | Changes NPC flags |
| `.npc emote` | `world.creatures` | .emote - Sets emote state |
| `.npc delete` | `world.creatures` | Deletes mob from db and world. |
| `.npc info` | `world.creatures` | Displays NPC information |
| `.npc traineradd` | `world.trainers` | .npc traineradd <teaching-spell-id> [cost-in-copper] [required-level] |
| `.npc listAgent` | `world.creatures` | .npc listAgent — Shows the selected creature’s scripts and combat spells |
| `.npc say` | `world.creatures` | .npc say <text> - Makes selected mob say text <text>. |
| `.npc yell` | `world.creatures` | .npc yell <Text> - Makes selected mob yell text <text>. |
| `.npc come` | `world.creatures` | .npc come - Makes npc move to your position |
| `.npc return` | `world.creatures` | .npc return - Returns ncp to spawnpoint. |
| `.npc spawn` | `world.creatures` | .npc spawn - Spawns npc of entry <id> |
| `.npc respawn` | `world.creatures` | .respawn - Respawns a dead npc from it's corpse. |
| `.npc possess` | `world.creatures` | .npc possess - Possess an npc (mind control) |
| `.npc unpossess` | `world.creatures` | .npc unpossess - Unposses any currently possessed npc. |
| `.npc select` | `world.creatures` | .npc select - selects npc closest |
| `.npc npcfollow` | `character.modify` | Sets npc to follow you |
| `.npc nullfollow` | `character.modify` | Sets npc to not follow anything |
| `.cheat status` | `testing.cheats` | Shows active cheats. |
| `.cheat taxi` | `testing.cheats` | Enables all taxi nodes. |
| `.cheat cooldown` | `testing.cheats` | Enables no cooldown cheat. |
| `.cheat casttime` | `testing.cheats` | Enables no cast time cheat. |
| `.cheat power` | `testing.cheats` | Disables mana consumption etc. |
| `.cheat god` | `testing.cheats` | Sets god mode, prevents you from taking damage. |
| `.cheat explore` | `testing.cheats` | Reveals the unexplored parts of the map. |
| `.cheat triggerpass` | `testing.cheats` | Ignores area trigger prerequisites. |
| `.account level` | `staff.admin` | Sets gm level on account. Pass it username and 0,1,2,3,az, etc. |
| `.account mute` | `account.moderate` | Mutes account for <timeperiod>. |
| `.account unmute` | `account.moderate` | Unmutes account <x> |
| `.honor addpoints` | `character.modify` | Adds x amount of honor points/currency |
| `.honor addkills` | `character.modify` | Adds x amount of honor kills |
| `.honor globaldailyupdate` | `character.modify` | Daily honor field moves |
| `.honor singledailyupdate` | `character.modify` | Daily honor field moves for selected player only |
| `.honor pvpcredit` | `character.modify` | Sends PVP credit packet, with specified rank and points |
| `.quest addboth` | `world.quests` | Add quest <id> to the targeted NPC as start & finish |
| `.quest addfinish` | `world.quests` | Add quest <id> to the targeted NPC as finisher |
| `.quest addstart` | `world.quests` | Add quest <id> to the targeted NPC as starter |
| `.quest delboth` | `world.quests` | Delete quest <id> from the targeted NPC as start & finish |
| `.quest delfinish` | `world.quests` | Delete quest <id> from the targeted NPC as finisher |
| `.quest delstart` | `world.quests` | Delete quest <id> from the targeted NPC as starter |
| `.quest complete` | `world.quests` | Complete/Finish quest <id> |
| `.quest finisher` | `world.quests` | Lookup quest finisher for quest <id> |
| `.quest item` | `world.quests` | Lookup itemid necessary for quest <id> |
| `.quest list` | `world.quests` | Lists the quests for the npc <id> |
| `.quest load` | `world.quests` | Reloads quest definitions and giver relationships on all workers. |
| `.quest lookup` | `world.quests` | Looks up quest string x |
| `.quest giver` | `world.quests` | Lookup quest giver for quest <id> |
| `.quest remove` | `world.quests` | Removes the quest <id> from the targeted player |
| `.quest reward` | `world.quests` | Shows reward for quest <id> |
| `.quest status` | `world.quests` | Lists the status of quest <id> |
| `.quest spawn` | `world.quests` | Port to spawn location for quest <id> |
| `.quest start` | `world.quests` | Starts quest <id> |
| `.pet createpet` | `character.modify` | Creates a pet with <entry>. |
| `.pet renamepet` | `character.modify` | Renames a pet to <name>. |
| `.pet addspell` | `character.modify` | Teaches pet <spell>. |
| `.pet removespell` | `character.modify` | Removes pet spell <spell>. |
| `.recall list` | `world.quests` | List recall locations |
| `.recall port` | `world.quests` | Port to recalled location |
| `.recall add` | `world.quests` | Add recall location |
| `.recall del` | `world.quests` | Remove a recall location |
| `.recall portplayer` | `character.modify` | recall ports player |
| `.guild create` | `guild.manage` | Creates a guild. |
| `.guild rename` | `guild.manage` | Renames a guild. |
| `.guild members` | `guild.manage` | Lists guildmembers and their ranks. |
| `.guild removeplayer` | `guild.manage` | Removes a player from a guild. |
| `.guild disband` | `guild.manage` | Disbands the guild of your target. |
| `.server setmotd` | `character.modify` | Sets MOTD |
| `.server rehash` | `staff.admin` | Reloads config file. |
| `.server reloadtable` | `character.modify` | Reloads some of the database tables |
| `.server shutdown` | `staff.admin` | Initiates server shutdown in <x> seconds (5 by default). |
| `.server restart` | `staff.admin` | Initiates server restart in <x> seconds (5 by default). |
| `.server cancelshutdown` | `staff.admin` | Cancels a Server Restart/Shutdown. |
| `.server save` | `server.save` | Save's target character |
| `.server saveall` | `server.save` | Save's all playing characters |
| `.server info` | `public` | Server info |
| `.server netstatus` | `public` | Shows network status. |
| `.character learn` | `character.learn` | Learns spell |
| `.character unlearn` | `character.learn` | Unlearns spell |
| `.character getskillinfo` | `character.modify` | Gets all the skills from a player |
| `.character learnskill` | `character.learn` | .learnskill <skillid> (optional) <value> <maxvalue> - Learns skill id skillid. |
| `.character advanceskill` | `character.learn` | advanceskill <skillid> <amount, optional, default = 1> - Advances skill line x times.. |
| `.character removeskill` | `character.learn` | .removeskill <skillid> - Removes skill |
| `.character increaseweaponskill` | `character.learn` | .increaseweaponskill <count> - Increase eqipped weapon skill x times (defaults to 1). |
| `.character resetreputation` | `world.creatures` | .resetreputation - Resets reputation to start levels. (use on characters that were made before reputation fixes.) |
| `.character resetspells` | `character.learn` | .resetspells - Resets all spells to starting spells of targeted player. DANGEROUS. |
| `.character resettalents` | `character.learn` | .resettalents - Resets all talents of targeted player to that of their current level. DANGEROUS. |
| `.character resetskills` | `character.learn` | .resetskills - Resets all skills. |
| `.character additem` | `character.modify` | Adds item x count y |
| `.character removeitem` | `character.modify` | Removes item %u count %u. |
| `.character additemset` | `character.modify` | Adds item set to inv. |
| `.character advanceallskills` | `character.learn` | Advances all skills <x> points. |
| `.character getstanding` | `character.modify` | Gets standing of faction %u. |
| `.character setstanding` | `character.modify` | Sets stanging of faction %u. |
| `.character showitems` | `character.modify` | Shows items of selected Player |
| `.character showskills` | `character.modify` | Shows skills of selected Player |
| `.character showinstances` | `staff.admin` | Shows persistent instances of selected Player |
| `.character rename` | `character.modify` | Renames character x to y. |
| `.character forcerename` | `character.modify` | Forces character x to rename his char next login |
| `.character repairitems` | `world.creatures` | .repairitems - Repair all items from selected player |
| `.lookup item` | `support.lookup` | Looks up item string x. |
| `.lookup quest` | `support.lookup` | Looks up quest string x. |
| `.lookup creature` | `support.lookup` | Looks up item string x. |
| `.lookup object` | `support.lookup` | Looks up gameobject string x. |
| `.lookup spell` | `support.lookup` | Looks up spell string x. |
| `.lookup skill` | `support.lookup` | Looks up skill string x. |
| `.lookup faction` | `support.lookup` | Looks up faction string x. |
| `.admin castall` | `staff.admin` | Makes all players online cast spell <x>. |
| `.admin dispelall` | `staff.admin` | Dispels all negative (or positive w/ 1) auras on all players. |
| `.admin masssummon` | `staff.admin` | .masssummon - Summons all players. |
| `.admin playall` | `staff.admin` | Plays a sound to the entire server. |
| `.kick byplayer` | `staff.disconnect` | Disconnects the player with name <s>. |
| `.kick byaccount` | `staff.disconnect` | Disconnects the session with account name <s>. |
| `.kick byip` | `staff.disconnect` | Disconnects the session with the ip <s>. |
| `.ban ip` | `character.modify` | Adds an address to the IP ban table: <address> [duration] Duration must be a number optionally followed by a character representing the calendar subdivision to use (h>hours, d>days, w>weeks, m>months, y>years, default minutes) Lack of duration results in a permanent ban. |
| `.ban character` | `staff.discipline` | Bans character x with or without reason |
| `.ban account` | `account.moderate` | Ban account. .account ban name timeperiod |
| `.unban ip` | `character.modify` | Deletes an address from the IP ban table: <address> |
| `.unban character` | `staff.discipline` | Unbans character x |
| `.unban account` | `staff.admin` | Unbans account x. |
| `.instance reset` | `staff.admin` | Removes instance ID x from target player. |
| `.instance resetall` | `character.modify` | Removes all instance IDs from target player. |
| `.instance shutdown` | `staff.admin` | Shutdown instance with ID x (default is current instance). |
| `.instance info` | `character.modify` | Gets info about instance with ID x (default is current instance). |
| `.instance exit` | `character.modify` | Exits current instance, return to entry point. |
| `.kickplayer` | `staff.discipline` | Kicks player from server |
| `.gmannounce` | `staff.announce` | Sends Msg to all online GMs |
| `.clearcooldowns` | `character.modify` | Clears all cooldowns for your class. |
| `.removeauras` | `character.modify` | Removes all auras from target |
| `.paralyze` | `staff.discipline` | Roots/Paralyzes the target. |
| `.unparalyze` | `staff.discipline` | Unroots/Unparalyzes the target. |
| `.gotrig` | `world.teleport` | Warps to areatrigger <id> |
| `.logcomment` | `support.lookup` | Adds a comment to the GM log for the admins to read. |
| `.removesickness` | `character.modify` | Removes ressurrection sickness from the target |
| `.fixscale` | `character.modify` |  |
| `.addtrainerspell` | `world.trainers` | .addtrainerspell <teaching-spell-id> [cost-in-copper] [required-level] |
| `.travel coords` | `world.teleport` | Usage: .travel coords <map> <x> <y> <z> |
| `.travel player` | `world.teleport` | Usage: .travel player <name> |
| `.travel summon` | `world.teleport` | Usage: .travel summon <name> |
| `.access whoami` | `public` | Shows your active staff roles and capabilities. |
| `.access grant` | `staff.admin + roles.manage` | Usage: .access grant <account> <role> |
| `.access revoke` | `staff.admin + roles.manage` | Usage: .access revoke <account> <role> |
| `.learn` | `character.learn` | Usage: .learn <spell-id\|all> |

## Unavailable commands (25)

These legacy entries return “Not yet implemented.” This includes features that depend on systems
outside the 1.12 client, such as rated arena teams and player flight. Per-point animations and
model changes can use native waypoint movement scripts. SQL maintenance uses the MariaDB client.

| Command | Capability | Help |
|---|---|---|
| `.waypoint flags` | `world.waypoints` | Wp flags |
| `.waypoint emote` | `world.waypoints` | Emote at this wp |
| `.waypoint skin` | `world.waypoints` | Skin at this wp |
| `.waypoint addfly` | `world.waypoints` | Adds a flying waypoint |
| `.debug aispelltestbegin` | `debug.use` |  |
| `.debug aispelltestcontinue` | `debug.use` |  |
| `.debug aispelltestskip` | `debug.use` |  |
| `.debug sqlquery` | `debug.use` | <sql query> |
| `.debug setallratings` | `debug.use` | Sets rating values to incremental numbers based on their index. |
| `.battleground pausebg` | `battleground.manage` | Pauses current battleground match. |
| `.npc addAgent` | `world.creatures` | .npc addAgent <agent> <procEvent> <procChance> <procCount> <spellId> <spellType> <spelltargetType> <spellCooldown> <floatMisc1> <Misc2> |
| `.npc spawnlink` | `world.creatures` | .spawnlink sqlentry |
| `.npc formationlink1` | `character.modify` | Sets formation master. |
| `.npc formationlink2` | `character.modify` | Sets formation slave with distance and angle |
| `.npc formationclear` | `character.modify` | Removes formation from creature |
| `.cheat fly` | `testing.cheats` | Sets fly mode |
| `.cheat flyspeed` | `testing.cheats` | Modifies fly speed. |
| `.cheat stack` | `testing.cheats` | Enables aura stacking cheat. |
| `.pet spawnbot` | `account.moderate` | .pet spawnbot <type> - spawn a helper bot for your aid |
| `.character settitle` | `character.modify` | Adds title to a player |
| `.admin renameallinvalidchars` | `staff.admin` | Renames all invalid character names |
| `.arena createteam` | `battleground.manage` | Creates arena team |
| `.arena setteamleader` | `battleground.manage` | Sets the arena team leader |
| `.arena resetallratings` | `staff.admin` | Resets all area teams to their default rating |
| `.modperiod` | `character.modify` | Changes period of current transporter. |
