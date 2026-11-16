# GM commands

Typed in chat, starting with `.` (or `!`). The set follows ArcEmu and Ascent: ArcEmu's groups
(`.modify hp`, `.ban account`, `.lookup item`, ...), with Ascent's flat names for the same commands as
aliases (`.gmon`, `.kickplayer`, `.additem`, ...). CMaNGOS names are kept where they existed already
(`.go xyz`, `.tele`, `.recall`).

* **Shortening:** every word may be shortened, `.lookup it linen` for `.lookup item linen`. Whole
  words win over abbreviations, and longer commands over shorter ones.
* **Groups:** a group name alone (`.modify`, `.ban`, `.character`) lists its commands, and
  `.help NAME` shows a command's syntax and aliases. `.commands` lists everything your level allows.
* **Target:** "the selected player" means the player you have targeted, or yourself if nobody is,
  as with ArcEmu's `getSelectedChar`.
* **Levels** are CMaNGOS's account levels (`account.gmlevel`): 0 player, 1 moderator, 2 game
  master, 3 administrator. A player's message that is not one of its commands is said aloud.
* **What lasts:** level, money, explored zones, skills, spells, items, bans, mutes, accounts and
  `game_tele` places are saved. Other `.modify` changes last until the character's stats are
  computed again, at the next login, as in ArcEmu.

## The commands

| Command | Level | Arguments | What it does | Also |
|---|---|---|---|---|
| `.account create` | 3 administrator | name password | Creates an account. | `.createaccount` |
| `.account level` | 3 administrator | name level | Sets an account's level: 0 player, 1 moderator, 2 game master, 3 administrator. |  |
| `.account mute` | 2 game master | account duration | Turns an account's chat off for a while. |  |
| `.account password` | 3 administrator | name password | Sets an account's password. | `.changepassword` |
| `.account unmute` | 2 game master | account | Turns an account's chat on again. |  |
| `.admin masssummon` | 3 administrator |  | Summons every player online to you. | `.masssummon` |
| `.admin playall` | 3 administrator | sound | Plays a sound (SoundEntries.dbc) to everyone online. | `.playall` |
| `.announce` | 1 moderator | text | Sends a message to everyone online, in the chat window. |  |
| `.appear` | 1 moderator | [name] | Teleports you to a player, or to the one you have selected. |  |
| `.ban account` | 2 game master | account duration reason | Bans an account; duration like 1d2h30m, or perm. | `.account ban` |
| `.ban character` | 2 game master | name duration reason | Bans a character's account (CMaNGOS bans accounts, not characters). | `.banchar` |
| `.ban ip` | 2 game master | address duration reason | Bans an address. | `.addipban` |
| `.battleground playsound` | 2 game master | sound | Plays a sound (SoundEntries.dbc) to you. | `.playsound` |
| `.battleground setworldstate` | 2 game master | state value | Sends you a world state. | `.setworldstate` |
| `.character additem` | 2 game master | item [count] | Gives the selected player items. | `.additem` |
| `.character additemset` | 2 game master | set | Gives the selected player every item of an item set. | `.additemset` |
| `.character advanceallskills` | 2 game master | [points] | Raises every skill of the selected player. | `.advanceallskills` |
| `.character advanceskill` | 2 game master | skill [points] | Raises one of the selected player's skills. | `.advanceskill` |
| `.character getskillinfo` | 1 moderator |  | Lists the selected player's skills. | `.getskillinfo`, `.character showskills` |
| `.character learn` | 2 game master | spell | Teaches the selected player a spell. | `.learn` |
| `.character learnskill` | 2 game master | skill [value] [max] | Gives the selected player a skill. | `.learnskill` |
| `.character removeitem` | 2 game master | item [count] | Takes items away from the selected player. | `.removeitem` |
| `.character removeskill` | 2 game master | skill | Takes a skill away from the selected player. | `.removeskill` |
| `.character rename` | 2 game master | name new-name | Renames a character that is not online. | `.renamechar` |
| `.character repairitems` | 2 game master |  | Repairs every item of the selected player. | `.repairitems` |
| `.character showitems` | 1 moderator |  | Lists the selected player's items. | `.showitems` |
| `.character unlearn` | 2 game master | spell | Makes the selected player forget a spell. | `.unlearn` |
| `.cheat explore` | 2 game master |  | Reveals the whole map to the selected player. |  |
| `.cheat status` | 2 game master |  | Shows the selected player's cheats. |  |
| `.cheat triggerpass` | 2 game master |  | Lets the selected player through area triggers regardless of their requirements. |  |
| `.commands` | 0 player |  | Lists the commands you can use. |  |
| `.debug dist` | 3 administrator |  | Shows the distance to the selected player. | `.debug rangecheck` |
| `.debug getbytes` | 3 administrator | slot | Shows the four bytes of an update field slot. |  |
| `.debug getvalue` | 3 administrator | slot | Shows an update field slot of the selected player. | `.debug getUint32Value` |
| `.debug knockback` | 3 administrator | [speed] | Knocks you back (and up). |  |
| `.debug landwalk` | 3 administrator |  | The selected player sinks in water again. |  |
| `.debug sendpacket` | 3 administrator | opcode [hex body] | Sends yourself a packet (opcode 0x...). |  |
| `.debug setbit` | 3 administrator | slot bit | Sets a bit (0-31) of an update field slot. |  |
| `.debug setbytes` | 3 administrator | slot b0 b1 b2 b3 | Sets the four bytes of an update field slot. |  |
| `.debug setvalue` | 3 administrator | slot value | Sets an update field slot of the selected player to a number (0x... for hex). |  |
| `.debug waterwalk` | 3 administrator |  | The selected player walks on water. |  |
| `.demorph` | 2 game master |  | Gives the selected player its own model back. |  |
| `.dismount` | 1 moderator |  | Takes the selected player off its mount. |  |
| `.getskilllevel` | 1 moderator | skill | Shows the selected player's value in a skill. |  |
| `.gm` | 1 moderator | [on&#124;off] | Shows game master mode, or turns it on or off. |  |
| `.gm allowwhispers` | 1 moderator | name | Lets a player whisper you while you block whispers. | `.allowwhispers` |
| `.gm blockwhispers` | 1 moderator | name | Takes back `.gm allowwhispers`. | `.blockwhispers` |
| `.gm chat` | 1 moderator | [on&#124;off] | Shows or hides the GM badge in chat. |  |
| `.gm list` | 0 player |  | Shows the game masters online. |  |
| `.gm off` | 1 moderator |  | Leaves game master mode. | `.gmoff` |
| `.gm on` | 1 moderator |  | Game master mode: the <GM> tag, no entry requirements, no movement checks. | `.gmon` |
| `.gm whisperblock` | 1 moderator |  | Blocks, or unblocks, whispers from players. |  |
| `.gmannounce` | 1 moderator | text | Sends a message to the game masters online. |  |
| `.go xyz` | 1 moderator | x y z [map] | Teleports you to a position, on this map or another. |  |
| `.gotrig` | 1 moderator | id | Teleports you to an area trigger of AreaTrigger.dbc. |  |
| `.gps` | 1 moderator |  | Shows where you, or the selected player, are. | `.getpos` |
| `.help` | 0 player | [command] | Shows the commands you can use, or how to use one. |  |
| `.kick byaccount` | 2 game master | account | Disconnects the session of an account. | `.killbyaccount` |
| `.kick byip` | 2 game master | address | Disconnects every session from an address. |  |
| `.kick byplayer` | 2 game master | name [reason] | Disconnects a player. | `.kickplayer`, `.killbyplayer` |
| `.levelup` | 2 game master | [levels] | Raises the selected player's level, by one or by levels. |  |
| `.logcomment` | 1 moderator | text | Writes a comment to the server log, for the administrators. |  |
| `.lookup creature` | 1 moderator | text | Finds creatures by name. | `.lookupcreature` |
| `.lookup item` | 1 moderator | text | Finds items by name. | `.lookupitem` |
| `.lookup object` | 1 moderator | text | Finds game objects by name. |  |
| `.lookup quest` | 1 moderator | text | Finds quests by title. | `.lookupquest`, `.quest lookup` |
| `.lookup skill` | 1 moderator | text | Finds skills by name. |  |
| `.lookup spell` | 1 moderator | text | Finds spells by name. |  |
| `.modify agility` | 2 game master | value | Sets agility. |  |
| `.modify ap` | 2 game master | value | Sets attack power. |  |
| `.modify arcane` | 2 game master | value | Sets arcane resistance. |  |
| `.modify armor` | 2 game master | value | Sets armor. |  |
| `.modify boundingradius` | 2 game master | value | Sets the bounding radius. |  |
| `.modify bytes` | 2 game master | value | Sets UNIT_FIELD_BYTES_0: race, class, gender, power. |  |
| `.modify combatreach` | 2 game master | value | Sets the combat reach. |  |
| `.modify damage` | 2 game master | value | Sets the main hand's minimum and maximum damage. |  |
| `.modify displayid` | 2 game master | value | Sets the model shown. |  |
| `.modify dynamicflags` | 2 game master | value | Sets the dynamic flags. |  |
| `.modify energy` | 2 game master | value | Sets energy and maximum energy. |  |
| `.modify faction` | 2 game master | value | Sets the faction template. |  |
| `.modify fire` | 2 game master | value | Sets fire resistance. |  |
| `.modify flags` | 2 game master | value | Sets the unit flags. |  |
| `.modify frost` | 2 game master | value | Sets frost resistance. |  |
| `.modify gender` | 2 game master | 0&#124;1 | Changes the selected player's gender (0 male, 1 female), until the next login. |  |
| `.modify gold` | 2 game master | copper | Gives (or with a minus, takes) money, in copper. | `.modify money` |
| `.modify holy` | 2 game master | value | Sets holy resistance. |  |
| `.modify hp` | 2 game master | value | Sets health and maximum health. |  |
| `.modify intelligence` | 2 game master | value | Sets intelligence. |  |
| `.modify level` | 2 game master | level | Sets the level of the selected player. |  |
| `.modify mana` | 2 game master | value | Sets mana and maximum mana. |  |
| `.modify nativedisplayid` | 2 game master | value | Sets the native model. |  |
| `.modify nature` | 2 game master | value | Sets nature resistance. |  |
| `.modify npcemotestate` | 2 game master | value | Sets the looping emote. | `.modify emotestate` |
| `.modify rage` | 2 game master | value | Sets rage and maximum rage (tenths). |  |
| `.modify rangeap` | 2 game master | value | Sets ranged attack power. |  |
| `.modify scale` | 2 game master | value | Sets the model's scale. |  |
| `.modify shadow` | 2 game master | value | Sets shadow resistance. |  |
| `.modify speed` | 2 game master | yards per second | Sets the running and swimming speed (7 is normal). |  |
| `.modify spirit` | 2 game master | value | Sets spirit. |  |
| `.modify stamina` | 2 game master | value | Sets stamina. |  |
| `.modify strength` | 2 game master | value | Sets strength. |  |
| `.modify talentpoints` | 2 game master | value | Sets the unspent talent points. |  |
| `.mount` | 2 game master | display id | Mounts the selected player on a creature model (the look only). |  |
| `.paralyze` | 2 game master |  | Roots the selected player to the spot. | `.debug root` |
| `.playerinfo` | 1 moderator | [name] | Shows who a player, or the selected one, is: account, level, place, time played. |  |
| `.recall` | 1 moderator |  | Teleports you back to where you were before your last teleport command. |  |
| `.recall add` | 2 game master | name | Saves where you stand as a game_tele place (CMaNGOS .tele add). |  |
| `.recall del` | 2 game master | name | Deletes a game_tele place (CMaNGOS .tele del). |  |
| `.recall list` | 1 moderator | [text] | Lists the game_tele places, or those whose name contains text. |  |
| `.recall portplayer` | 2 game master | player place | Teleports a player to a game_tele place. |  |
| `.save` | 0 player |  | Saves your character. |  |
| `.server cancelshutdown` | 3 administrator |  | Cancels a shutdown or restart. |  |
| `.server info` | 0 player |  | Shows how many players are online. | `.info` |
| `.server netstatus` | 1 moderator |  | Shows the connections and your latency. |  |
| `.server reloadtable` | 3 administrator | areatrigger_teleport&#124;game_tele | Reads a world table again. | `.reloadtable` |
| `.server restart` | 3 administrator | [seconds] | Stops the server with exit code 2, for a script that starts it again. | `.serverrestart` |
| `.server save` | 2 game master |  | Saves the selected character, or yours. |  |
| `.server saveall` | 2 game master |  | Saves every character online. | `.saveall` |
| `.server setmotd` | 2 game master | text | Sets the message of the day ('@' starts a new line), until a restart. | `.setmotd` |
| `.server shutdown` | 3 administrator | [seconds] | Stops the server, counting down (5 seconds by default). | `.servershutdown` |
| `.start` | 1 moderator | [race] | Teleports you to where your race, or the one named (human, orc, dwarf, nightelf, undead, tauren, gnome, troll), starts. |  |
| `.summon` | 1 moderator | [name] | Teleports a player, or the one you have selected, to you. |  |
| `.tele` | 1 moderator | name | Teleports you to a place of the game_tele table. | `.recall port` |
| `.unban account` | 2 game master | account | Lifts an account's bans. | `.account unban` |
| `.unban character` | 2 game master | name | Lifts the bans of a character's account. | `.unbanchar` |
| `.unban ip` | 2 game master | address | Lifts an address's ban. | `.delipban` |
| `.unparalyze` | 2 game master |  | Lets the selected player move again. | `.debug unroot` |
| `.wannounce` | 1 moderator | text | Sends a message to everyone online, in the middle of the screen. |  |
| `.worldport` | 1 moderator | map x y z | Teleports you to a position on a map. |  |

## Not implemented, and why

ArcEmu has about 320 commands and Ascent about 280. These need parts of the server that do not
exist yet, or belong to later expansions:

| ArcEmu/Ascent commands | Needs |
|---|---|
| `.npc *`, `.waypoint *`, `.gobject *`, `.npcfollow`, `.formation*`, `.respawn` | creatures and game objects (roadmap milestone 3) |
| `.kill`, `.killplr`, `.revive`, `.reviveplr`, `.invincible`, `.cheat god`, `.removesickness` | death and combat (milestone 6) |
| `.castspell`, `.castall`, `.dispelall`, `.removeauras`, `.clearcooldowns`, `.cheat cooldown/casttime/power/stack` | spell casting, auras and cooldowns (milestone 6) |
| `.quest *` (except `.quest lookup`) | quests (milestone 7) |
| `.guild *`, `.renameguild` | guilds (milestone 7) |
| `.gmTicket *` | the GM ticket system |
| `.battleground *` (except `playsound` and `setworldstate`), `.honor *`, `.arena *` | battlegrounds and honor; arenas are not in vanilla |
| `.pet *` | pets |
| `.instance *`, `.exitinstance`, `.character showinstances` | instance ids and binds |
| `.invisible`, `.cheat fly`, `.cheat flyspeed`, `.cheat taxi` | GM invisibility, flying (not in vanilla), taxi nodes |
| `.character resetreputation/getstanding/setstanding` | reputation |
| `.character resetspells/resettalents/resetskills`, `.addtrainerspell` | talents and trainers |
| `.character settitle`, `.forcerename` | titles and the rename dialog, which the 1.12 client does not have |
| `.debug` AI, threat, line of sight, height, `.getheight`, `.testlos`, `.testindoor` | creature AI and map data (milestone 4) |
| `.server rehash`, `.reloadscripts`, `.debug sqlquery`, `.renameallinvalidchars`, `.modperiod`, `.fixscale` | not worth having: configuration reloads, scripting, raw SQL from chat, transports |
| `.account email`, `.account flags` | columns CMaNGOS's `account` table does not have |

Each command is one `@Command` method (see DEVELOPING.md), so these can be added as their systems
arrive.
