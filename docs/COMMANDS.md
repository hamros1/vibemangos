# GM commands

Type a command in chat with a leading `.` or `!`. Start with `.commands` or open a group such as
`.wp` to see the actions you can use. Use `.help <command>` to see its arguments and what it does.
The catalog shows the shorter spellings first. Existing spellings and their abbreviations still work.

| Task | Command |
|---|---|
| Show your location | `.where` |
| Travel to a map coordinate | `.go coords <map> <x> <y> <z>` |
| Visit or summon a player | `.go player <name>`, `.go summon <name>` |
| Teach a spell to the selected player or yourself | `.learn <spell-id>` |
| Find a support ticket | `.ticket list` |
| Check your access | `.access status` |
| Inspect the battleground queue | `.bg queue` |
| See uptime and player counts | `.server status` |

Use `.modify hp 400` to set both health and maximum health to 400. Use
`.modify hp 300 400` to set them separately.

## Give someone staff access

New installations include the role tables. For an existing cluster, stop the login server and
all world processes, then run these migrations from the repository directory before starting
the new binaries together. Substitute your login database name if it differs.

```sh
mariadb -u root -p classicrealmd < sql/gm-rbac.sql
mariadb -u root -p classicrealmd < sql/gm-role-upgrade.sql
```

The upgrade preserves existing role assignments and migrates old staff accounts to the
corresponding built-in role. Reapplying it respects accounts whose roles were revoked.
Recreate any customized permissions as named grants. The servers read staff access from the
role tables.

Run `./bin/authserver account grant <login> administrator` to give your first administrator
access. In game, use `.access grant <login> <role>`. Roles apply to the account across all
realms that share this login database.

| Role | Access |
|---|---|
| `support` | Player lookup, tickets, moderation, announcements and relocation |
| `game-master` | Support, gameplay testing, events and world editing |
| `administrator` | Every capability, including role administration |

Run `.access revoke <login> <role>` to remove a role. Multiple roles combine their grants.
An account with zero roles has no staff access. Workers refresh roles at login, on handoff
and before executing chat commands. Configure `gm_command_log` on every worker to record
role changes and audited staff actions.

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
Shortcuts share their original permission path. For `.go coords` use `command.worldport`,
and for `.npc traineradd` use `command.addtrainerspell`.

## Edit a route or trainer

* Select a saved creature. Stand at each waypoint and use `.wp add [wait-ms]`. Use
  `.wp list` to review your draft and `.wp save` to commit the route. Use
  `.wp discard` to discard unsaved edits. Selecting a different spawn starts a new draft.
  A saved empty route makes the spawn idle. Use `.wp gait`, `.wp emote` or `.wp model` to
  customize a point, or `.wp script <point> <script-id>` to attach an existing script.
  Use `.wp add-air` for a creature whose template supports flight.
* If you imported Classic-DB before this change, run
  `mariadb -u root -p classicmangos < sql/gm-waypoints.sql` against the world database.
  Run `mariadb -u root -p classicmangos < sql/gm-content.sql` for NPC spawn links.
  The waypoint migration converts the spawn and route tables to InnoDB. Run both during maintenance,
  then restart world workers after saving routes so they load the new paths.
* Select a trainer and run `.npc traineradd <teaching-spell-id> [cost-in-copper] [required-level]`.
  Use the spell that teaches the lesson. The selected worker uses it immediately, and the other
  workers pick it up on their next catalog refresh.

Use `.quest reload` after updating quest definitions or giver relationships in the world database.
Workers switch to the new catalog after it loads.

## Test encounters and edit spawn links

* Select a saved leader and use `.npc formation-leader`. Select a follower and use
  `.npc formation-add [yards] [degrees]`. Use `.npc link-info` to inspect the saved link and
  `.npc formation-remove` to clear it. Restart world workers to load saved changes.
* Select an NPC with a spell list. Use `.debug ai-test` to inspect its spells and
  `.debug ai-next` to cast the next spell on its normal targets.
* Use `.bg pause on` in a battleground to pause the match clock, scoring and objectives.
  Use `.bg pause off` to resume the same match.

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

## Working commands (298)

Generated from the command tables by `python3 tools/commands_doc.py`.

| Command | Effect | Capability |
|---|---|---|
| `.access grant <account> <role>` | Assign a role to an account. | `staff.admin + roles.manage` |
| `.access revoke <account> <role>` | Remove a role from an account. | `staff.admin + roles.manage` |
| `.access status` (also `.access whoami`) | Show your roles and capabilities. | `public` |
| `.account mute <account> <duration>` | Mute an account for a duration. | `account.moderate` |
| `.account unmute <account>` | Remove an account mute. | `account.moderate` |
| `.addtrainerspell <teaching-spell-id> [copper] [level]` | Add a lesson to the selected trainer. | `world.trainers` |
| `.admin audit-names [preview\|apply]` (also `.admin renameallinvalidchars`) | Review invalid offline names and mark them for rename. | `staff.admin` |
| `.admin castall <spell-id>` | Make online players on this worker cast a spell. | `staff.admin` |
| `.admin dispelall [all: 0\|1]` | Remove harmful or helpful auras from players on this worker. | `staff.admin` |
| `.admin masssummon` | Summon online players to your position. | `staff.admin` |
| `.admin playall <sound-id>` | Play a sound for all players. | `staff.admin` |
| `.announce [message]` | Send a realm-wide chat announcement. | `staff.announce` |
| `.appear <name>` | Teleport to a player. | `world.teleport` |
| `.ban account <account> <duration> [reason]` | Ban an account. | `account.moderate` |
| `.ban character <character> <duration> <reason>` | Ban a character's account. | `account.moderate` |
| `.ban ip <ip-address> <duration> [reason]` | Ban an IP address. | `character.modify` |
| `.bg battleground` (also `.battleground battleground`) | Show the current match and available tools. | `battleground.manage` |
| `.bg forcestart` (also `.battleground forcestart`) | Start all queued battlegrounds. | `staff.admin` |
| `.bg leave` (also `.battleground leave`) | Leave the current battleground. | `battleground.manage` |
| `.bg pause [on\|off]` (also `.battleground pausebg`) | Pause or resume the countdown, combat, and objectives. | `battleground.manage` |
| `.bg queue` (also `.battleground getqueue`) | Show battlegroup queue and match counts. | `staff.admin` |
| `.bg score <alliance\|horde> <score>` (also `.battleground setbgscore`) | Set a below-win score in Warsong Gulch or Arathi Basin. | `battleground.manage` |
| `.bg setbfstatus start` (also `.battleground setbfstatus`) | Start the current battleground with the start action. | `battleground.manage` |
| `.bg setworldstates <id> <value>` (also `.battleground setworldstates`) | Set a world state in the current battleground. | `battleground.manage` |
| `.bg sound <sound-id>` (also `.battleground playsound`) | Play a sound in the current battleground. | `battleground.manage` |
| `.bg start` (also `.battleground startbg`) | Start the current battleground. | `battleground.manage` |
| `.bg status` (also `.battleground bginfo`) | Show the current match and its status. | `battleground.manage` |
| `.bg worldstate <id> <value>` (also `.battleground setworldstate`) | Set a world state in the current battleground. | `battleground.manage` |
| `.character additemset <set-id>` | Give an item set to the selected player. | `character.modify` |
| `.character advanceallskills <points>` | Raise all skills by the given number of points. | `character.learn` |
| `.character advanceskill <skill-id> [points]` | Raise a skill by the given number of points. | `character.learn` |
| `.character forcerename <name>` | Require a character to take a new name at login. | `character.modify` |
| `.character getskillinfo` | Show the selected player's skills. | `character.modify` |
| `.character getstanding <faction-id>` | Show standing with a faction. | `character.modify` |
| `.character give <item-id> [count] [random-property]` (also `.character additem`) | Give items to the selected player. | `character.modify` |
| `.character increaseweaponskill [points]` | Raise the equipped weapon skill. | `character.learn` |
| `.character items` (also `.character showitems`) | List the selected player's items. | `character.modify` |
| `.character learn <spell-id\|all>` | Teach a spell or the character's class spells. | `character.learn` |
| `.character learnskill <skill-id> <value> [max]` | Teach a skill and set its value and cap. | `character.learn` |
| `.character removeskill <skill>` | Remove a skill. | `character.learn` |
| `.character rename <old-name> <new-name>` | Rename a character. | `character.modify` |
| `.character repair` (also `.character repairitems`) | Repair the selected player's equipment. | `world.creatures` |
| `.character resetreputation` | Reset reputation to starting values. | `world.creatures` |
| `.character resetskills` | Restore the character's starting skills. | `character.learn` |
| `.character resetspells` | Restore the character's starting spells. | `character.learn` |
| `.character resettalents` | Reset the character's talents. | `character.learn` |
| `.character setstanding <faction-id> <standing>` | Set standing with a faction. | `character.modify` |
| `.character showinstances` | List the selected player's saved instances. | `staff.admin` |
| `.character skills` (also `.character showskills`) | List the selected player's skills. | `character.modify` |
| `.character take <item-id> [count]` (also `.character removeitem`) | Remove items from the selected player. | `character.modify` |
| `.character unlearn <spell-id>` | Remove a spell from the selected player. | `character.learn` |
| `.cheat casttime [on\|off]` | Toggle instant casts. | `testing.cheats` |
| `.cheat cooldown [on\|off]` | Toggle spell cooldowns. | `testing.cheats` |
| `.cheat explore <on\|off>` | Reveal or clear map exploration. | `testing.cheats` |
| `.cheat god [on\|off]` | Toggle damage immunity. | `testing.cheats` |
| `.cheat power [on\|off]` | Toggle free spell casts. | `testing.cheats` |
| `.cheat skip-requirements [on\|off]` (also `.cheat triggerpass`) | Toggle bypass of area trigger requirements. | `testing.cheats` |
| `.cheat stack <spell-id> <stacks>` | Set the stack count of an active aura on a player. | `testing.cheats` |
| `.cheat status` | Show active testing toggles. | `testing.cheats` |
| `.cheat taxi <on\|off>` | Toggle access to all flight paths. | `testing.cheats` |
| `.clearcooldowns` | Clear the selected player's spell cooldowns. | `character.modify` |
| `.commands [command or prefix]` | Find commands you can use. | `public` |
| `.debug aggro` (also `.debug aggrorange`) | Show the selected creature's aggro range. | `debug.use` |
| `.debug ai-next` (also `.debug aispelltestcontinue`) | Attempt the next test spell using the creature’s targeting rule. | `debug.use` |
| `.debug ai-skip` (also `.debug aispelltestskip`) | Skip the current test spell. | `debug.use` |
| `.debug ai-test` (also `.debug aispelltestbegin`) | Start a test of the selected creature’s combat spells. | `debug.use` |
| `.debug aimove <x> <y> <z>` | Move the selected creature to coordinates on this map. | `debug.use` |
| `.debug calcThreat <damage> <spell-id>` | Estimate spell threat from damage and your modifiers. | `debug.use` |
| `.debug cast <spell-id>` (also `.debug castspell`) | Cast a spell on the selected unit. | `debug.use` |
| `.debug castself <spell-id>` | Make the selected unit cast a spell on itself. | `debug.use` |
| `.debug castspellne <spell-id>` | Preview a spell's animation. | `debug.use` |
| `.debug database <npc\|object> <spawn-id>` (also `.debug sqlquery`) | Read a saved spawn’s placement from the world database. | `debug.use` |
| `.debug distance` (also `.debug dist`) | Show the distance to the selected unit. | `debug.use` |
| `.debug face <degrees>` | Turn the selected creature to an angle in degrees. | `debug.use` |
| `.debug fade <percent>` | Reduce your threat by a percentage. | `debug.use` |
| `.debug getbytes <field>` | Read the four bytes of a unit field. | `debug.use` |
| `.debug getheight` | Show terrain and collision heights at your position. | `debug.use` |
| `.debug getpos <area-id>` | Show coordinates for a world area. | `debug.use` |
| `.debug gettptime` | Show the circuit time of the ship or zeppelin aboard. | `debug.use` |
| `.debug getUint32Value <field>` | Read a unit update field as an unsigned integer. | `debug.use` |
| `.debug infront` | Check whether the target is in front of you. | `debug.use` |
| `.debug itempushresult <item-id> [count] [type] [flag-1] [flag-2] [flag-3]` | Send a test item acquisition notification. | `debug.use` |
| `.debug knockback [speed]` | Apply a knockback for testing. | `debug.use` |
| `.debug landwalk` | Send a land-walking movement order. | `debug.use` |
| `.debug los` (also `.debug testlos`) | Check line of sight to the selected unit. | `debug.use` |
| `.debug moveinfo` | Inspect the selected creature's movement. | `debug.use` |
| `.debug packet notification` (also `.debug sendpacket`) | Send a test notification to your own client. | `debug.use` |
| `.debug position` (also `.debug dumpcoords`) | Show map, instance, coordinates and facing. | `debug.use` |
| `.debug rangecheck` | Show distance and combat reach against the selected unit. | `debug.use` |
| `.debug root` | Send a root movement order. | `debug.use` |
| `.debug setbit <field> <bit>` | Toggle a bit in an update field. | `debug.use` |
| `.debug setbytes <index> <b0> <b1> <b2> <b3>` | Set four bytes in a unit field. | `debug.use` |
| `.debug setvalue <field> <value>` | Set a unit update field. | `debug.use` |
| `.debug showreact <reaction-id>` | Preview a reaction on the selected unit. | `debug.use` |
| `.debug testindoor` | Check whether your position is indoors. | `debug.use` |
| `.debug threatList` | List the selected creature's threat entries. | `debug.use` |
| `.debug threatMod <percent>` | Change your threat by a signed percentage. | `debug.use` |
| `.debug unroot` | Send an unroot movement order. | `debug.use` |
| `.debug waterwalk` | Send a water-walking movement order. | `debug.use` |
| `.demorph` | Restore your normal appearance. | `character.modify` |
| `.dismount` | Dismount the selected unit or yourself. | `character.mount` |
| `.fixscale [scale]` | Set the selected unit's scale. | `character.modify` |
| `.gm allow <name>` (also `.gm allowwhispers`) | Allow whispers from a player while in GM mode. | `staff.support` |
| `.gm block <name>` (also `.gm blockwhispers`) | Remove a player's whisper exception. | `staff.support` |
| `.gm list` | List online staff. | `public` |
| `.gm off` | Turn off the GM tag and whisper blocking. | `staff.tag` |
| `.gm on` | Turn on the GM tag and whisper blocking. | `staff.tag` |
| `.gm quiet` (also `.gm whisperblock`) | Block whispers while keeping the visible GM tag off. | `world.objects.move` |
| `.gmannounce <message>` | Send a message to online staff. | `staff.announce` |
| `.go coords <map> <x> <y> <z>` (also `.travel coords`) | Teleport to map coordinates. | `world.teleport` |
| `.go player <name>` (also `.travel player`) | Teleport to a player. | `world.teleport` |
| `.go summon <name>` (also `.travel summon`) | Bring a player to your location. | `world.teleport` |
| `.gotrig <trigger-id> [instance-id]` | Teleport to an area trigger. | `world.teleport` |
| `.guild create <name>` | Create a guild for the selected player. | `guild.manage` |
| `.guild disband` | Disband the selected player's guild. | `guild.manage` |
| `.guild members` | List members and ranks in the selected player's guild. | `guild.manage` |
| `.guild removeplayer` | Remove the selected player from their guild. | `guild.manage` |
| `.guild rename <name>` | Rename the selected player's guild. | `guild.manage` |
| `.help [command]` | Show syntax and details for a command. | `public` |
| `.honor addkills <kills>` | Add honorable kills to the selected player. | `character.modify` |
| `.honor addpoints <points>` | Add honor to the selected player. | `character.modify` |
| `.honor globaldailyupdate` | Run the daily honor update for the realm. | `character.modify` |
| `.honor pvpcredit <points> [rank]` | Send a test PvP credit notification. | `character.modify` |
| `.honor singledailyupdate` | Run the daily honor update for the selected player. | `character.modify` |
| `.instance exit` | Return to the instance entrance. | `character.modify` |
| `.instance info [instance-id]` | Inspect an instance by ID, or the current instance. | `character.modify` |
| `.instance reset [instance-id]` | Remove one saved instance from the selected player. | `staff.admin` |
| `.instance resetall` | Remove all saved instances from the selected player. | `character.modify` |
| `.instance shutdown [instance-id]` | Close an instance by ID, or the current instance. | `staff.admin` |
| `.invincible` | Toggle invincibility. | `staff.presence` |
| `.invisible` | Toggle invisibility and invincibility. | `staff.presence` |
| `.kick account <account>` (also `.kick byaccount`) | Disconnect a session by account name. | `staff.disconnect` |
| `.kick ip <ip-address>` (also `.kick byip`) | Disconnect sessions from an IP address. | `staff.disconnect` |
| `.kick player <character>` (also `.kick byplayer`) | Disconnect a player by character name. | `staff.disconnect` |
| `.kickplayer <name> [kick-reason]` | Disconnect a player with an optional reason. | `staff.discipline` |
| `.kill` | Kill the selected unit. | `character.combat` |
| `.killplr <character>` | Kill a player by name. | `character.combat` |
| `.learn <spell-id\|all>` | Teach a spell or the character's class spells. | `character.learn` |
| `.levelup [levels]` | Raise the selected player's level. | `character.modify` |
| `.logcomment <comment>` | Write a note to the GM log. | `support.lookup` |
| `.lookup creature <search>` | Search creature templates by name. | `support.lookup` |
| `.lookup faction <search>` | Search factions by name. | `support.lookup` |
| `.lookup item <search>` | Search items by name. | `support.lookup` |
| `.lookup object <search>` | Search game object templates by name. | `support.lookup` |
| `.lookup quest <search>` | Search quests by title. | `support.lookup` |
| `.lookup skill <search>` | Search skills by name. | `support.lookup` |
| `.lookup spell <search>` | Search spells by name. | `support.lookup` |
| `.modify agility <value>` | Set agility. | `character.modify` |
| `.modify ap <value>` | Set melee attack power. | `character.modify` |
| `.modify arcane <value>` | Set Arcane resistance. | `character.modify` |
| `.modify armor <value>` | Set armor. | `character.modify` |
| `.modify bytes <value>` | Set the first packed unit field. | `character.modify` |
| `.modify damage <min> <max>` | Set minimum and maximum melee damage. | `character.modify` |
| `.modify displayid <value>` | Set the current display ID. | `character.modify` |
| `.modify dynamicflags <value>` | Set dynamic flags. | `character.modify` |
| `.modify energy <value> [max]` | Set energy and maximum energy. | `character.modify` |
| `.modify faction <value>` | Set the faction template ID. | `character.modify` |
| `.modify fire <value>` | Set Fire resistance. | `character.modify` |
| `.modify flags <value>` | Set unit flags. | `character.modify` |
| `.modify frost <value>` | Set Frost resistance. | `character.modify` |
| `.modify gender [0\|1]` | Set the selected player's gender. | `character.modify` |
| `.modify gold <copper>` | Adjust money by an amount in copper. | `character.modify` |
| `.modify happiness <value> [max]` | Set pet happiness and its maximum. | `character.modify` |
| `.modify holy <value>` | Set Holy resistance. | `character.modify` |
| `.modify hp <value> [max]` | Set health and maximum health. | `character.modify` |
| `.modify intelligence <value>` | Set intellect. | `character.modify` |
| `.modify level <level>` | Set the selected unit's level. | `character.modify` |
| `.modify mana <value> [max]` | Set mana and maximum mana. | `character.modify` |
| `.modify nativedisplayid <value>` | Set the native display ID. | `character.modify` |
| `.modify nature <value>` | Set Nature resistance. | `character.modify` |
| `.modify npcemotestate <value>` | Set the NPC's emote state. | `character.modify` |
| `.modify radius <value>` (also `.modify boundingraidius`) | Set the unit's bounding radius. | `character.modify` |
| `.modify rage <value> [max]` | Set rage and maximum rage. | `character.modify` |
| `.modify rangeap <value>` | Set ranged attack power. | `character.modify` |
| `.modify reach <value>` (also `.modify combatreach`) | Set the unit's combat reach. | `character.modify` |
| `.modify scale <value>` | Set object scale. | `character.modify` |
| `.modify shadow <value>` | Set Shadow resistance. | `character.modify` |
| `.modify speed <speed>` | Set movement speed. | `character.modify` |
| `.modify spirit <value>` | Set spirit. | `character.modify` |
| `.modify strength <value>` | Set strength. | `character.modify` |
| `.modify talentpoints <value>` | Set unspent talent points. | `character.modify` |
| `.mount <display-id>` | Mount the selected player with a display ID. | `character.modify` |
| `.npc ai` (also `.npc listAgent`) | Show the selected creature's scripts and combat spells. | `world.creatures` |
| `.npc ai-add <spell-id> <self\|victim> <repeat-ms>` (also `.npc addAgent`) | Add a spell to the selected NPC’s shared combat list. | `world.creatures` |
| `.npc come` | Move the selected NPC to your position. | `world.creatures` |
| `.npc delete` | Delete the selected creature and its saved spawn. | `world.creatures` |
| `.npc emote [emote]` | Set the selected NPC's emote state. | `world.creatures` |
| `.npc flags <flags>` | Set the selected NPC's flags. | `world.creatures` |
| `.npc follow` (also `.npc npcfollow`) | Make the selected NPC follow you. | `character.modify` |
| `.npc formation-add [yards] [degrees]` (also `.npc formationlink2`) | Save the selected creature as a follower of the chosen leader. | `world.creatures` |
| `.npc formation-leader` (also `.npc formationlink1`) | Select the leader for a formation edit. | `world.creatures` |
| `.npc formation-remove` (also `.npc formationclear`) | Clear the selected spawn’s saved formation link. | `world.creatures` |
| `.npc info` | Inspect the selected NPC. | `world.creatures` |
| `.npc link <leader-spawn\|0> [flags]` (also `.npc spawnlink`) | Save a link to a leader spawn, or clear it with 0. | `world.creatures` |
| `.npc link-info` | Inspect the selected creature’s active spawn links. | `world.creatures` |
| `.npc possess` | Take control of the selected NPC. | `world.creatures` |
| `.npc respawn` | Respawn the selected creature. | `world.creatures` |
| `.npc return` | Send the selected NPC back to its spawn point. | `world.creatures` |
| `.npc say <message>` | Make the selected NPC say a message. | `world.creatures` |
| `.npc select` | Select the closest NPC. | `world.creatures` |
| `.npc sell <item-id> [quantity] [extended-cost-id]` (also `.npc vendoradditem`) | Add an item to the selected vendor. | `world.creatures` |
| `.npc spawn <entry-id>` | Create a saved creature spawn. | `world.creatures` |
| `.npc traineradd <teaching-spell-id> [copper] [level]` | Add a lesson to the selected trainer. | `world.trainers` |
| `.npc unfollow` (also `.npc nullfollow`) | Stop the selected NPC from following. | `character.modify` |
| `.npc unpossess` | Release control of a possessed NPC. | `world.creatures` |
| `.npc unsell <item-id>` (also `.npc vendorremoveitem`) | Remove an item from the selected vendor. | `world.creatures` |
| `.npc yell <message>` | Make the selected NPC yell a message. | `world.creatures` |
| `.object activate` (also `.gobject activate`) | Activate the selected game object. | `world.objects` |
| `.object animation [progress]` (also `.gobject animprogress`) | Set the selected game object's animation progress. | `world.objects` |
| `.object delete` (also `.gobject delete`) | Delete the selected game object. | `world.objects` |
| `.object enable` (also `.gobject enable`) | Toggle whether the selected game object is usable. | `world.objects` |
| `.object export` (also `.gobject export`) | Show the selected game object's placement and rotation. | `world.objects` |
| `.object info` (also `.gobject info`) | Inspect the selected game object. | `world.objects` |
| `.object move` (also `.gobject move`) | Move the selected game object to your position. | `world.objects.move` |
| `.object rotate <x\|y\|o> <degrees>` (also `.gobject rotate`) | Set rotation around an axis in degrees. | `world.objects.move` |
| `.object scale <scale>` (also `.gobject scale`) | Set the selected game object's scale. | `world.objects` |
| `.object select [name]` (also `.gobject select`) | Select the nearest game object. | `world.objects` |
| `.object spawn <entry-id> [save: 0\|1]` (also `.gobject spawn`) | Spawn a game object by entry ID. | `world.objects` |
| `.paralyze` | Root the selected player. | `staff.discipline` |
| `.pet create <creature-entry>` (also `.pet createpet`) | Create a persistent pet for the selected hunter. | `character.modify` |
| `.pet forget <spell-id>` (also `.pet removespell`) | Remove a spell from the selected player's pet. | `character.modify` |
| `.pet helper <creature-entry> [seconds]` (also `.pet spawnbot`) | Summon a temporary guardian that follows you. | `account.moderate` |
| `.pet rename <name>` (also `.pet renamepet`) | Rename your pet. | `character.modify` |
| `.pet teach <spell-id>` (also `.pet addspell`) | Teach a spell to the selected player's pet. | `character.modify` |
| `.playerinfo [name]` | Inspect a character and their account. | `character.modify` |
| `.quest add-both <quest-id>` (also `.quest addboth`) | Make the selected NPC start and finish a quest. | `world.quests` |
| `.quest add-finish <quest-id>` (also `.quest addfinish`) | Make the selected NPC finish a quest. | `world.quests` |
| `.quest add-start <quest-id>` (also `.quest addstart`) | Make the selected NPC start a quest. | `world.quests` |
| `.quest complete <quest-id>` | Complete a quest for the selected player. | `world.quests` |
| `.quest finisher <quest-id>` | Find NPCs or objects that finish a quest. | `world.quests` |
| `.quest giver <quest-id>` | Find NPCs or objects that start a quest. | `world.quests` |
| `.quest item <quest-id>` | List the items a quest requires. | `world.quests` |
| `.quest list [entry-id]` | List quests for a player or quest giver. | `world.quests` |
| `.quest lookup <search>` | Search quests by title. | `world.quests` |
| `.quest reload` (also `.quest load`) | Reload quest definitions and giver relationships. | `world.quests` |
| `.quest remove <quest-id>` | Remove a quest from the selected player's log. | `world.quests` |
| `.quest remove-both <quest-id>` (also `.quest delboth`) | Remove both quest relationships from the selected NPC. | `world.quests` |
| `.quest remove-finish <quest-id>` (also `.quest delfinish`) | Remove a quest's finish relationship from the selected NPC. | `world.quests` |
| `.quest remove-start <quest-id>` (also `.quest delstart`) | Remove a quest's start relationship from the selected NPC. | `world.quests` |
| `.quest reward <quest-id>` | Show a quest's rewards. | `world.quests` |
| `.quest spawn <quest-id>` | Teleport to a spawn associated with a quest. | `world.quests` |
| `.quest start <quest-id>` | Start a quest for the selected player. | `world.quests` |
| `.quest status <quest-id>` | Show the selected player's status for a quest. | `world.quests` |
| `.recall add <name>` | Save your current location. | `world.quests` |
| `.recall delete <name>` (also `.recall del`) | Delete a saved location. | `world.quests` |
| `.recall go <name>` (also `.recall port`) | Teleport to a saved location. | `world.quests` |
| `.recall list` | List saved locations. | `world.quests` |
| `.recall portplayer <name> <location>` | Send a player to a saved location. | `character.modify` |
| `.removeauras` | Remove auras from the selected unit. | `character.modify` |
| `.removesickness` | Remove resurrection sickness. | `character.modify` |
| `.revive` | Resurrect the selected player or yourself. | `character.combat` |
| `.reviveplr <character>` | Resurrect a player by name. | `character.combat` |
| `.scourge [status\|start\|stop]` | Check or control the Scourge Invasion. | `staff.admin` |
| `.server cancel` (also `.server cancelshutdown`) | Cancel a scheduled shutdown or restart. | `staff.admin` |
| `.server motd [message]` (also `.server setmotd`) | Set the message of the day. | `character.modify` |
| `.server network` (also `.server netstatus`) | Show connection counts. | `public` |
| `.server reload-config` (also `.server rehash`) | Reload server configuration. | `staff.admin` |
| `.server reload-data <table>` (also `.server reloadtable`) | Reload supported world data. | `character.modify` |
| `.server restart [seconds]` | Schedule a server restart in seconds. | `staff.admin` |
| `.server save` | Save the selected player. | `server.save` |
| `.server save-all` (also `.server saveall`) | Save online characters. | `server.save` |
| `.server shutdown [seconds]` | Schedule a server shutdown in seconds. | `staff.admin` |
| `.server status` (also `.server info`) | Show uptime and player counts. | `public` |
| `.start [race]` | Teleport to a racial starting area. | `character.modify` |
| `.summon <name>` | Bring a player to your location. | `world.teleport` |
| `.ticket assign <id> [character]` (also `.gmTicket assign`) | Assign a ticket to a staff member or yourself. | `support.tickets` |
| `.ticket close <id>` (also `.gmTicket remove`) | Close a ticket. | `support.tickets` |
| `.ticket comment <id> <note>` (also `.gmTicket comment`) | Add a note to a ticket. | `support.tickets` |
| `.ticket delete <id>` (also `.gmTicket deletepermanent`) | Permanently delete a ticket. | `staff.admin` |
| `.ticket list [all]` (also `.gmTicket list`) | List open player tickets. | `support.tickets` |
| `.ticket release <id>` (also `.gmTicket release`) | Clear a ticket's assignment. | `support.tickets` |
| `.ticket show <id>` (also `.gmTicket get`) | Read a ticket by ID. | `support.tickets` |
| `.ticket toggle` (also `.gmTicket toggle`) | Enable or disable player tickets. | `staff.admin` |
| `.transport-period <period-ms>` (also `.modperiod`) | Save the current ship or zeppelin’s circuit time. | `character.modify` |
| `.unban account <account>` | Remove a ban from an account. | `staff.admin` |
| `.unban character <character>` | Remove a ban from a character's account. | `staff.admin` |
| `.unban ip <ip-address>` | Remove a ban from an IP address. | `character.modify` |
| `.unparalyze` | Release the selected player's root. | `staff.discipline` |
| `.wannounce <message>` | Send a realm-wide on-screen announcement. | `staff.announce` |
| `.where` (also `.gps`) | Show your position or the selected unit’s position. | `public` |
| `.worldport <map> <x> <y> <z>` | Teleport to map coordinates. | `world.teleport` |
| `.wp add [wait-ms]` (also `.waypoint add`) | Add your position to the route draft. | `world.waypoints` |
| `.wp add-air [wait-ms]` (also `.waypoint addfly`) | Add an airborne point for a creature that can fly. | `world.waypoints` |
| `.wp clear` (also `.waypoint deleteall`) | Remove all points from the draft. | `world.waypoints` |
| `.wp delete <point>` (also `.waypoint delete`) | Remove a point from the draft. | `world.waypoints` |
| `.wp discard` (also `.waypoint hide`) | Discard unsaved route edits. | `world.waypoints` |
| `.wp emote <point> <emote-id\|0>` (also `.waypoint emote`) | Set or clear an emote played at a draft point. | `world.waypoints` |
| `.wp gait <point> <default\|walk\|run>` (also `.waypoint flags`) | Set the movement into a draft point. | `world.waypoints` |
| `.wp generate` (also `.waypoint generate`) | Extend the draft to your position using the navigation mesh. | `world.waypoints` |
| `.wp info <point>` (also `.waypoint info`) | Show one draft point. | `world.waypoints` |
| `.wp list` (also `.waypoint show`) | List points in the route draft. | `world.waypoints` |
| `.wp mode <loop\|linear>` (also `.waypoint movetype`) | Set the route to loop or run in a line. | `world.waypoints` |
| `.wp model <point> <display-id\|0>` (also `.waypoint skin`) | Set or clear a model applied at a draft point. | `world.waypoints` |
| `.wp move <point>` (also `.waypoint movehere`) | Move a draft point to your position. | `world.waypoints` |
| `.wp renumber <point> <replacement>` (also `.waypoint change`) | Renumber a draft point. | `world.waypoints` |
| `.wp save` (also `.waypoint save`) | Save the route for the selected spawn. | `world.waypoints` |
| `.wp script <point> <script-id\|0>` (also `.waypoint script`) | Attach a movement script to a point or clear it with 0. | `world.waypoints` |
| `.wp wait <point> <wait-ms>` (also `.waypoint waittime`) | Set a point's wait time in milliseconds. | `world.waypoints` |

## Unavailable commands (7)

These actions depend on features absent from the supported client. Calling one directly
shows the client restriction. In-game command menus list working actions.

| Command | Effect | Capability |
|---|---|---|
| `.arena createteam` | Rated arena teams are unavailable in this client. | `battleground.manage` |
| `.arena resetallratings` | Rated arena teams are unavailable in this client. | `staff.admin` |
| `.arena setteamleader` | Rated arena teams are unavailable in this client. | `battleground.manage` |
| `.character settitle` | Custom character titles are unavailable in this client. | `character.modify` |
| `.cheat fly` | Player flight is unavailable in this client. | `testing.cheats` |
| `.cheat flyspeed` | Player flight is unavailable in this client. | `testing.cheats` |
| `.debug setallratings` | Combat ratings are unavailable in this client. | `debug.use` |
