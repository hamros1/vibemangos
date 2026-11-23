# Gameplay reference

See the [roadmap](ROADMAP.md) for open work, the [spell audit](SPELLS.md) for spell coverage, and
[clustering](CLUSTER.md#what-crosses-nodes-feature-by-feature) for interactions across nodes.

## Login and characters

* `SMSG_AUTH_CHALLENGE` / `CMSG_AUTH_SESSION`, checked against `account.sessionkey`, with a reply
  for each failure: unknown account, IP lock, missing key, bans, wrong proof, unsupported build.
  Connections are logged in `account_logons` with `loginSource` 1.
* Header encryption with the session key, the addon reply, `CMSG_PING`/`SMSG_PONG` (a player
  account that pings too often more than `max_overspeed_pings` times in a row is kicked), and one
  session per account (a new login kicks the old one).
* The character list (`SMSG_CHAR_ENUM`), built from `characters`,
  `character_pet` and `guild_member`, with equipment from `equipmentCache` and
  `item_template`, and pets from `creature_template`.
* Character creation (`CMSG_CHAR_CREATE`):
  * **Checks:** creation-disabled mask, race and class, appearance against
    `CharSections`, name normalization and `strict_player_names`/`min_player_name`, reserved names,
    name in use, per-account and per-realm limits, and faction rules on PvP realms.
  * **Character:** start position, level and stats, health and mana, the race's taxi nodes, and
    the default skills and spells, including every skill and spell they teach in turn.
  * **Items and bars:** the action bars, and the `CharStartOutfit` and `playercreateinfo_item`
    items, equipped or stored in the slots the client expects. A hunter's arrows end up in
    the quiver.
  * **Rows written:** every table a character save writes, plus `realmcharacters` and the
    account's first `character_tutorial` row.
* Character deletion (`CMSG_CHAR_DELETE`):
  * **Who:** only the account's own characters, and never a guild leader.
  * **What it does:** leaves or disbands the guild and the group, passing on the group lead if
    needed. Removes petitions. Cancels the character's auctions and refunds bidders by mail.
    Returns unpaid COD mail with items to its senders. Deletes pets and every row of the
    character in the characters database.
  * `char_delete_method` 1 (unlink) and `char_delete_min_level` are supported.
* Entering the world (`CMSG_PLAYER_LOGIN`):
  * **Loading:** the character, its inventory (`character_inventory` and `item_instance`), skills,
    spells, action bars, home and the account's tutorial flags. Default spells and the spells
    skills teach are not saved but learned again at every login. A character without a
    home is bound where its race starts.
  * **Packets:** in the order the client expects: `SMSG_LOGIN_VERIFY_WORLD`, account data times, the
    message of the day (`motd`), rest state, bind point, tutorials, spellbook, action buttons,
    factions, game time, weapon and armor proficiencies, the race's intro on the first login, then
    one update packet creating every item, bag and the player, and the friend, ignore and world
    state lists.
  * **The player object:** every update field a login fills: looks, display id and model
    scale, faction, level, health and powers, stats with item bonuses, armor and resistances,
    attack power, weapon damage and speed, skills, explored zones, money and XP, with its auras,
    talents and crit, dodge, parry and block chances.
  * **Update packets:** `SMSG_UPDATE_OBJECT` blocks built from a field mask, compressed over 100
    bytes.

## Movement and instances

* **Other players:** players on the same map see each other within 100 yards: they appear,
  move, sit and emote for each other, and disappear when out of sight or logged out. Strangers
  see health in percent, group members the real values.
* **Movement** (`MSG_MOVE_*`) is shown to those who see the player and saved. It is checked
  against the player's speed (`movement_speed_check`): a player that moves faster than it can
  run is put back.
* **Movement orders:** speed changes (auras, mounts, snares, which slow running backwards too),
  roots, knockbacks, water walking, slow fall and hover are ordered to the client and, once it
  acknowledges them, shown to those who see the player (`MSG_MOVE_SET_*_SPEED`, `MSG_MOVE_ROOT`,
  `MSG_MOVE_KNOCK_BACK`, ...), as CMaNGOS does.
* **Environment:** breath under water (the breath bar; Water Breathing, Underwater Breathing),
  fatigue in deep water, drowning and exhaustion, lava, falling damage (Safe Fall, Slow Fall) and
  falling under the world, with `SMSG_ENVIRONMENTALDAMAGELOG`. Slime does nothing (as in CMaNGOS)
  but Naxxramas's, whose spell is cast.
* **Teleports:** near and far teleports with the client's acknowledgements
  (`MSG_MOVE_TELEPORT_ACK`, `SMSG_TRANSFER_PENDING`, `SMSG_NEW_WORLD`, `MSG_MOVE_WORLDPORT_ACK`).
  Instance portals and the other `areatrigger_teleport` triggers check level, raid group, items and
  quests handed in, with the trigger's own message. The client's `worldport`
  command works for administrators.
* **Dungeon instances:** each group (or player on its own) gets its own copy of a dungeon or
  raid: a raid's bound copy first (its lockout), else its group's, else its own bind's, else a new
  one, to which it and its group are bound. Copies, binds and what was killed or used up in them
  are saved (`instance`, `character_instance`, `group_instance`, and `creature_respawn` and
  `gameobject_respawn` by instance) and read back at start-up. A dungeon copy nobody has been in
  for `instance_unload_delay_seconds` resets with its binds (or at once from the party menu's Reset
  Instances, by a player alone or its group's leader, unless someone is inside); a raid copy lasts until its reset, so its
  players stay locked to it. A raid's copies all reset together, every `reset_delay` days
  (`instance_template`) at `instance_reset_time_hour`, counted on from the last (`instance_reset`); a
  player entering one is told when, is warned an hour, 15, 5 and 1 minute(s) before, and at the reset
  is sent to its home. One bound to another copy than its group's is turned away.
  A player logging back in inside a
  dungeon returns to its copy; a GM's `.appear` and `.summon` go into the other's copy, and the
  `.instance` commands and `.character showinstances` work on the copies; a full copy
  (`instance_template.maxPlayers`) turns others away, game masters aside. Not yet: encounter
  state. In a cluster each dungeon is one region
  and its node hosts every copy of it; a player going in from another node moves there first
  as described in [clustering](CLUSTER.md#dungeons-and-battlegrounds).

## Social and administration

* **Groups:** invitations, parties and raids of up to 40 in eight sub-groups, leaders and
  assistants, kicking, leaving, loot settings, raid target icons, ready checks, rolls, minimap
  pings, and member stats for members out of sight. Groups are kept in `groups` and
  `group_member` and survive restarts. Logging out of a party leaves it.
* **Meeting stones** (looking for group, `world/meetingstone.d`): at a dungeon's stone a player
  alone, or a party's leader, queues for the stone's dungeon. Once a second the queue fills waiting
  parties with the tank, healer and up to three damage dealers they lack (the class best suited
  first, then who waited longest; after 30 minutes anyone who has waited goes first), and five
  waiting alone for one dungeon make a party of the first two, which then fills like any other. A
  party of five is complete and leaves the queue; one still waiting is told so every five minutes; a
  new leader, a raid or a disband takes it out. The rules are vmangos's. In a cluster the queue is
  the coordinator's, beside the groups. A player alone who logs out keeps its place, matched with nobody
  until it is back (its stone window asks at login), its time waited kept. Roles are by class: 1.12 has
  no roles to choose, and the talent-based roles of vmangos's own option are not Blizzard's.
* **Guilds:** a guild charter
  bought from a guild master for 10 silver, signed by nine others of the faction (once an account)
  and turned in founds the guild with five ranks; invitations (of the faction unless
  `allow_two_side_interaction_guild`, not from someone ignored), the roster (online members, the
  others' last zone and days away, officers' notes for those allowed), the information window,
  promotions and demotions by rank, leaving, removing, disbanding, handing over leadership (a
  leaving master's best-ranked member takes over), the message of the day, the guild information,
  public and officer notes, ranks' names and rights (5 to 10 ranks), the tabard (10 gold, the
  master's, at a tabard designer), guild and officer chat by rank rights, and members signing on
  and off. Saved in `guild`, `guild_member`, `guild_rank`, `petition` and `petition_sign`; the event log
  (invitations, joining, promotions, demotions, removals, leaving: the newest 100) in `guild_eventlog`, as
  CMaNGOS keeps it (the 1.12 client has no window for it, `MSG_GUILD_EVENT_LOG_QUERY` came with 2.0). The
  client's `/gcreate` (`CMSG_GUILD_CREATE`) founds a guild for game masters only.
* **Pets:** a hunter tames a beast of its level or
  lower (Tame Beast's twenty-second channel), dismisses it, calls it back and revives it; a warlock
  summons a demon (a new one named from `pet_name_generation`, or the one it had before, at full
  health). A pet follows its owner, fights what it is told to (its bar: attack, follow, stay,
  dismiss; aggressive, defensive, passive) and what attacks it or its owner, casts its spells by
  itself where they are set to (the imp from 25 yards), and its kills are its owner's. Its stats
  come from `pet_levelstats` and the family's size; a hunter pet gains experience with its owner
  up to its owner's level, takes a name once, and can be abandoned. A hunter stables up to two
  pets (slots bought at `StableSlotPrices.dbc`'s prices). Pets are saved in `character_pet` and
  `pet_spell`, go with their owner at logout, on teleports and moves between nodes, and come back
  after. A hunter pet's happiness falls with time (Feed Pet raises it), its mood sets how hard it
  hits, and its loyalty rises with content days and kills (a rebellious pet that falls further runs
  away). It is taught spells by the Beast Training window's teaching spells for its training points
  (from its level and loyalty); its owner learns the teaching spells of a tamed beast's passive
  abilities at once, and of its others one time in ten as the pet uses them. A hunters' pet trainer
  untrains the pet (10 silver, then 50, then a gold more each time the same day, at most 10 gold). The owner's death
  sends the pet away until the owner lives again. Hostile creatures notice a pet that comes within
  their aggro radius and attack it. A pet's auras (with the time they have left) and its
  cooldowns are saved with it (`pet_aura`, `pet_spell_cooldown`) and are back on it when it comes back.
* **Friends and ignore lists:** up to 50 friends and 25 ignored players,
  in `character_social`; the friend list shows who is online (zone, level, class, away or busy),
  on this node or another; friends hear of a login and a logout (across nodes too); a friend of
  the other faction only with `allow_two_side_add_friend` (or GM permissions). An ignored
  player's whispers are refused (`CHAT_MSG_IGNORED`), and so are its group invitations.
* **Client settings:** what the client saves on the server (macros, key bindings, ...) is kept per
  account (`account_data`) or per character (`character_account_data`) and given back on request.
* **Chat:** say, yell and emotes reach those in range; whispers reach anyone online of the same
  faction; party, raid, raid leader and raid warning messages reach the group. `/afk` and `/dnd`
  set the flag, the chat tag and the reply to whispers. `/who` lists who is online, filtered by
  faction, level range, class, race, zone, and parts of names, guilds and zone names.
* **Channels:** the built-in ones (General, Trade, LocalDefense, ...), which follow the zone,
  and custom ones with owners, moderators, passwords, muting, kicks, bans, invitations,
  announcements and moderation. One set per faction, unless
  `allow_two_side_interaction_channel` is on.
* **The GM system:** GM commands behave exactly as ArcEmu 2.4.3's: the same command tables,
  permission letters, lookup and replies, word for word. This is a compatibility contract. An
  account's `gmlevel` is mapped to letters by `gm_permissions`. 229 of the 295
  commands work: teleports and `game_tele` recall places, `.modify` (health, stats, speed, money,
  level, looks, ...), `.levelup`, `.character learn`, skills, items, lookups, kicks, bans, mutes,
  account levels, timed shutdowns and restarts, announcements, the GM tag and whisper blocking,
  killing and reviving, casting, clearing cooldowns and auras, resetting talents, respawning, the
  cheats (cooldown, cast time, god mode, power, explore, triggerpass), `.invincible`, instances,
  quests (status, starting, completing, quest givers and their lists), reputation, spawning and
  deleting creatures and game objects, vendors' wares, resetting spells and skills, and debugging.
  GM tickets work too: a player's help request is a ticket (`gm_tickets`), and the `.gmTicket`
  commands answer in the GM channel (`gm_client_channel`) as ArcEmu's do. The others (waypoint
  editing, possession, arenas, ...) say "Not yet implemented." See [GM commands](COMMANDS.md).

## NPCs, items and the world

* **NPCs:** gossip menus with their texts and conditions, trainers (lists and lessons, with
  ranks and professions), innkeepers binding the hearthstone, bankers, and vendors.
* **Items:** moving, stacking, splitting, equipping, bags, the bank and
  its bag slots, the keyring, destroying, ammo; buying (with limited stock), selling, buyback and
  repairs. Every change is saved to `character_inventory` and `item_instance` as it happens. A two-hander put
  on with no room left for the off hand sends the off hand by mail (the "problems with equipping" letter).
  Items asking for a reputation (`RequiredReputationFaction`/`Rank`) are worn by the player's real rank.
  Using an item checks it may be used (worn if it is to be worn, class, skill, reputation, out-of-combat
  spells) and binds one that binds on use. Charges count down (`ITEM_FIELD_SPELL_CHARGES`): out of them,
  a used-up item goes and one with positive charges stays ("No charges remain"). Putting on an item with
  an on-use spell starts its 30-second equip cooldown (`SMSG_ITEM_COOLDOWN`). Timed items
  (`Duration`) run down by the second while carried and go at 0, the client told their time
  (`SMSG_ITEM_TIME_UPDATE`); those flagged real-time lose the time logged out too. Damage dealt or
  taken wears a random worn item now and then (0.5%), a thrown weapon that does not stack each throw.
  Ammunition adds its damage per second, times the weapon's speed, to a bow's, crossbow's or gun's
  damage; a quiver's or ammo pouch's haste applies while it is in a bag slot.
* **Queries:** name, item (`SMSG_ITEM_QUERY_SINGLE_RESPONSE`, from every `item_template`
  column), time and played time.
* **Settings:** sitting and standing, target selection, action bar buttons and toggles, and
  tutorial flags, saved as they change.
* **Creatures and game objects:** every `creature` and `gameobject` spawn of the world database
  (pools, spawn groups and game events decide which; a spawn group's members without an entry of
  their own get its entries by their `MinCount`, `MaxCount` and chances; each time a pool's member is due
  to respawn the pool rolls again, so a rare spawn comes back at one of its places, the one rolled after a
  respawn time of its own), created when a player first comes near
  their cell, with their levels, health, models, equipment, mounts and emotes. Their names come
  from `CMSG_CREATURE_QUERY` and `CMSG_GAMEOBJECT_QUERY`. Game objects whose `spawntimesecs` is
  below 0 wait for events and scripts to spawn them.
* **Linked creatures** (`creature_linking`, `creature_linking_template`):
  * A pack's members join the fight when their master is attacked, and the other way round.
  * They follow their master out of combat, as their spawns stood.
  * They evade with it, die or go when it dies, and go when it is made to go (despawned).
  * In a dungeon they stay away once their boss is dead, or (for some) until it is.
* **Formations** (`spawn_group_formation`): a spawn group's leader (slot 0) walks the formation's path
  (`waypoint_path`). The others keep their places around it, in slot order: single file, side by
  side, like geese, fanned out behind or in front, or around the leader, `FormationSpread` yards
  apart.
* **Game events** (`game_event`):
  * The holidays, the Darkmoon Faire, fishing contests, Call to Arms weekends, day and night.
  * Each runs in its repeating windows: fixed dates, the same days every year, Easter week, Lunar
    New Year's three weeks (from the second new moon after 21 December, in China time), or a
    Darkmoon Faire week (the first whole week of every third month) and its building days.
  * An event linked to another runs only inside it.
  * While an event is on, its creatures and objects (`game_event_creature`, `game_event_gameobject`)
    are in the world, and those listed against it are away. They come and go as it starts and ends.
  * Conditions on events and holidays follow them.
  * An event's quests (`game_event_quest`) are given only while it is on.
  * A battleground made during its Call to Arms weekend gives more: Warsong Gulch 45 reputation a
    capture and three kills' honor for a win; Arathi Basin honor every 160 resources and reputation
    every 120.
  * While an event is on, the creatures it changes (`game_event_creature_data`) are of its entry,
    model or equipment, with its spell's auras (costumes: a transformation takes the named creature's
    look); when it starts or ends, those alive and out of a fight are made again.
  * Their letters (`game_event_mail`): as an event starts (or, for negative rows, ends) every character
    of its races (and, if it names a quest, rewarded for it) gets its templated letter from its creature,
    with the first item the template's loot gives. Sent by one node; `game_event_status` remembers which
    events were on, so a restart sends nothing for one still on.
* **Ships and zeppelins** (`transports`, `world/transports.d`): each sails its taxi path round, on the
  schedule the client computes too (its speed, acceleration, stops and crossings), from the wall
  clock, so every node of a cluster agrees. A ship is seen from anywhere on its map. At a crossing it
  leaves for the other continent, and the players aboard go with it (the loading screen names the
  ship, and they arrive on its deck). Ships whose path is in a dungeon (Naxxramas) do not sail.
* **Using game objects:** doors and buttons open
  for their time and close again; chairs seat the player at the nearest slot; goobers are in use
  for their time, show their page (the client asks for its text, `page_text`, page after page; a
  carried letter or book is read the same way), count for the quests that need them (for the group near them
  too) and cast their spell on the user; cameras play their cinematic. Locks (`Lock.dbc`) open to
  their key item or to a spell of their lock type with the skill they need (lockpicking,
  herbalism, mining), which may rise the first time each object is
  opened. A chest (herbs and veins too) shows its `gameobject_loot_template` loot with a group's
  loot rights and quest items for those whose quests need them; a consumable one is gone once
  emptied (or 5 minutes after opening) and comes back after its respawn time, kept in
  `gameobject_respawn` across restarts. Quest objects sparkle for the players whose quests need
  them, and game objects give and take back quests (`gameobject_questrelation`,
  `gameobject_involvedrelation`) as creatures do. A trap springs on a player who steps within its
  radius (half its diameter) and is not its faction's friend: its spell at the player, then its
  cooldown; one with charges is used up after them. A vein or herb with least and most
  opens (`minSuccessOpens`, `maxSuccessOpens`) fills again after it is emptied: always before its
  least, never at its most, and in between by a chance that falls with its uses and rises with the
  gatherer's mining skill. A button, chest, spell focus or goober with a linked
  trap springs it on its user when used (the trap standing at it, else the trap's spell). A quest
  giver object with a gossip menu (`gossipID`) shows it, with its quests; its options open further
  menus, points of interest and scripts. Not yet: a goober's gossip, stealthed traps' visibility, creatures springing traps,
  another node's objects in a cluster.
* **Fishing:** the fishing spell
  channels at a bobber cast between its least and greatest range in front of the angler, on the
  water (or "not fishable"); the fish bites 3, 7, 13 or 17 seconds before the channel would end
  (the bobber splashes) and waits 5 seconds. Used in time, the catch depends on the fishing skill
  against `skill_fishing_base_level` of the area (or zone), every try may raise the skill, and a
  catch is looted from `fishing_loot_template`; too early nothing is hooked, too late the fish got
  away; it takes a fishing pole worn. A school of fish (`GAMEOBJECT_TYPE_FISHINGHOLE`) within 20
  yards of the bobber gives the catch from its own loot, and is fished out after a few catches.
  A failed catch gives junk (`fishing_loot_template` entry 0) if `skill_fail_loot_fishing` is on (off by
  default: the fish escapes).
* **Creature movement:** creatures move as their spawn's `MovementType` says:
  wandering within `spawndist` of their spawn point (type 1), or walking their `creature_movement`
  or `creature_movement_template` path (type 2 round and round, type 4 back and forth), waiting
  and facing where the path says. Clients get `SMSG_MONSTER_MOVE`, and a creature that comes into
  sight mid-walk arrives with its walk in its create block. Paths are straight lines; a wander's
  end is put on the ground from the maps and vmaps. AI and waypoint scripts come next.

## Combat and creature AI

* **Melee:** players auto-attack creatures they may attack (by `FactionTemplate.dbc` and
  `Faction.dbc`'s base reputations: not friendly), with the swing loop, swing errors (out of reach, facing, dead target)
  and the dual-wield off hand. Each swing rolls the attack table (miss, dodge, parry, block,
  glancing, crit) from weapon and defense skills and levels, takes off armor, shows the client
  `SMSG_ATTACKERSTATEUPDATE`, gives warriors rage, and takes the creature's health; a creature at
  none dies. Creatures have the damage, attack power and armor of `creature_template` and
  `creature_template_classlevelstats`, players their crit (agility), dodge, parry and block
  chances and shield block. Players are in combat while a creature fights them and for 5 seconds
  after a swing (no health regeneration or rage decay meanwhile). Swings at creatures (critters
  aside) raise the weapon skill, and theirs at the player its defense, by a roll (likelier the farther below the maximum; intellect helps weapons).
* **Creatures fight:** attacked, they fight back; aggressive ones
  (not `CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT`) attack a hostile player that comes within their
  aggro radius (`Detection`, a yard more for each level the player is below them) and in sight.
  Charm and possession (Enslave Demon, Mind Control, Eyes of the Beast): the creature is the player's pet
  while the aura lasts (its spells on the bar, the player's faction, out of its fights); possessed, the client
  moves it and sees as it. When it ends the creature is its own again and turns on the player.
  Crowd control: a stunned, feared or disoriented creature neither fights nor casts (a cast under way
  stops); feared it runs from whoever feared it, disoriented it wanders; silenced it casts no spell that silence
  prevents, pacified it does not swing. A feared or disoriented player loses control of its character
  (`SMSG_CLIENT_CONTROL_UPDATE`) and the server walks it; stunned, silenced, pacified, feared or disoriented,
  its casts are refused with the client's reasons, and Disarm takes its main-hand weapon's damage.
  A stealthed player (Stealth, Prowl) is seen only in front of them and near enough: CMaNGOS's 30
  points, 5 a level above the first and detection auras, less the stealth's strength, three tenths
  of a yard a point (a level 60 monster sees Stealth rank 4 at 7.5 yards); a little further, a
  script hears a `StealthAlert`. Players see a stealthed player of their group or side; an enemy by
  the same rule, worked out again once a second.
  Far Sight, Eagle Eye and Mind Vision move the player's sight to their spot or target (`PLAYER_FARSIGHT`)
  while the channel lasts; others still see the player where it stands.
  They keep a threat list (damage is threat; a new victim needs 110% of the current one's in melee
  reach, 130% elsewhere), chase in straight lines, swing with the attack table (crushing
  blows included), and give warriors rage. They give up (evade) when nobody is left to fight, or
  (outside dungeons) when their victim is 30 yards beyond where their `Pursuit` time last started, or
  past their `Leash` from where the fight began; they run back there, evading attacks, losing their
  auras (their enemies' debuffs and damage over time, their own buffs; not their passives), and get a
  third of their health back every 5 seconds out of combat. In a dungeon a fighting creature also takes
  on those who come within its aggro radius, and one with `CREATURE_EXTRA_FLAG_AGGRO_ZONE` fights everyone
  in the dungeon once a player pulls it. Healing (and buffing) one a creature fights puts the healer in
  its fight, with half the heal shared out as threat among the creatures fighting the one healed
  (none for `SPELL_ATTR_EX_NO_THREAT` spells). Starting a fight, a creature calls for help: allies
  within 5 yards (or its `CallForHelp`) that would attack the enemy on sight join in a moment and a
  half later, if their faction answers calls (`FACTION_TEMPLATE_RESPOND_TO_CALL_FOR_HELP`; in a dungeon
  any creature that may attack the enemy, fighting or not); and a fighting creature that passes within 5
  yards of an idle ally pulls it in. A creature's spells made for a lower level
  (`SPELL_ATTR_SCALES_WITH_CREATURE_LEVEL`) do damage, heals and absorbs as its level's base damage is to
  the spell level's, and cost mana as CMaNGOS scales it.
* **Scripts in D** ([scripting](SCRIPTING.md)): gameplay the database cannot describe is written as D
  structs in `source/dmangos/scripts/`, bound by the world database's `ScriptName` columns
  (`creature_template`, `instance_template`) and found at compile time. A script handles typed
  events (`EnteredCombat`, `Damaged`, `Died`, `CreatureDied`, ...) and acts through a context that
  holds no pointers (cast, say a `script_texts` row, equip, stand, summon, signal another script,
  open a door); its timers are data (`Schedule`), so its whole state is saved: with the creature
  when it moves to another node, and in `instance.data` for a dungeon's script. Dispatch allocates
  nothing. Game objects (`gameobject_template.ScriptName`), spells (`spell_scripts`) and area
  triggers (`scripted_areatrigger`) have scripts too; creature scripts hear of gossip (and show
  menus of their own), quests taken and rewarded, and the end of their own walks; an `Escort`
  component walks a `script_waypoint` path with a player; a script's signal reaches creatures on
  other nodes of a cluster, once. Written so far: the Deadmines (its doors open as
  their guardians fall and stay open after a restart; the Defias Cannon blows the Iron Clad Door
  open and Mr. Smite raises the alarm), Mr. Smite (a slam on a timer; at two thirds and one third
  of his health a stomp, a line, kneeling to take up two axes, then a hammer) and the Defias
  Traitor's escort to Moonbrook ("The Defias Brotherhood": his lines on the way, the quest's event
  at the hideout, the quest failed if he is left behind or killed), Lady Katrana Prestor's
  conversation for "The True Masters", the scent of Lar'korwi's mate in Un'Goro, Life Tap
  (health into mana), Curse of Agony's growing ticks, Hate to Zero (a creature's threat wipe), the spell
  scripts of items, quests and the world (food's chewing, the enemies an opening calls on, the Muisek
  vessels and the Super Snapper FX only at their creatures, the Wondervolt's shapes and the Orb of
  Deception's looks, the stone skin of statues, the end of the Hex of Jammal'an, the Mark of Kazzak's
  burst) and the item and holiday spells CMaNGOS's core scripts by id (the Deviate Fish, the
  Noggenfogger Elixir, the engineers' gadgets, the Six Demon Bag, the Hallow's End treats and costumes,
  the tributes, the heart candies, Elune's Candle), and
  Shadowfang Keep (its doors with their guardians, the prisoners who lead the way to the courtyard
  and open it, Archmage Arugal's bolts, curse and Thundershock), and Wailing Caverns (once the
  four Fanglords are slain, the Disciple of Naralex leads the way through two ambushes and
  awakens Naralex while his nightmares, Mutanus last, come for him). Escort paths come from
  `script_waypoint` or `waypoint_path`. A creature whose `ScriptName`
  no script serves yet runs its EventAI as before; the server logs how many names are served.
* **Database scripts** (`dbscripts_on_*`): a quest's start and complete scripts, a
  gossip option's, a game object's when used (by its template and by its spawn), a waypoint's
  when a walking creature gets there (Northshire's peasants chop wood), a creature's when it is
  killed, a spell's event (`SPELL_EFFECT_SEND_EVENT`), a spell's own (`dbscripts_on_spell`, for its
  dummy and script effects), and relay scripts started from them, run their steps on the map at their delays, with the quest giver, NPC or
  player as source and target, or a buddy found near (by entry or spawn), turned about by the
  step's flags, behind its condition: talking (a `broadcast_text`, one of several, or one of a
  group), emotes, a quest's place explored (or failed when too far), kill credit, spawning a game
  object for a while, summoning a creature, taking an aura off, casting a spell, despawning, a
  faction, models and mounts, stand states, NPC flags, other flags, facing someone, and stopping
  the script when a creature is (or is not) near, opening and closing doors, and moving: walking to a point (a relay script
  once there) or back to its spawn point, turning, teleporting, a movement type (standing,
  wandering, its path round or there and back, by path id: its entry's or `waypoint_path`'s), pausing
  and resuming its path, AI events.
* **Spell lists** (`creature_spell_list`, a template's `SpellList`): in a fight a creature casts its
  list's spells as their timers come round (first after their initial time, then their repeat time;
  those with no probability first, else by their probabilities; each used at all by its
  availability), at the target its `creature_spell_targeting` names (its victim, itself, a random
  player it fights, a friend missing health, ...); a ranged main attack makes it keep its distance.
* **Creature scripts** (EventAI, `creature_ai_scripts`, for each creature entry or
  spawn): their events (timers in and out of combat, health, mana and the victim's health between
  two percentages, the victim within a range or casting, aggro, a kill, death, evading, spawning,
  reaching home, an aura of their own (or their victim's) there with so many stacks or missing, a spell
  hitting them or their spell hitting another, a player's emote at them, a friend near them hurt, held
  (rooted, stunned, slowed, feared) or missing a buff, another creature's AI event, a player or creature
  coming into their sight out of combat, a creature they summoned or its death, their victim's mana, an
  enemy at a range, standing behind or before their victim, a victim they cannot reach, a timer in and
  out of combat alike) run their actions by chance and phase, repeating after their repeat timers
  (at the target types CMaNGOS has, the nearest within a spell's radius and the farthest out of melee
  reach included): casting a spell (healing that friend too), saying, yelling, emoting or whispering
  a `broadcast_text` (or one of a `dbscript_random_templates` group, or by a chance), emotes,
  sounds, phases, fleeing in fear for 7 seconds, calling for help, combat movement, swings on or
  off, ranged mode (keeping a distance to cast, coming in to melee when out of mana), stand states,
  unit flags, taking auras off, despawning, not dying of damage, react states, factions, random
  phases, quest events and kill credit for the players fighting it, relay scripts (the database
  scripts below), AI events to the friendly creatures around, summoning creatures (beside it or at a `creature_ai_summons` spot, attacking
  its target), evading, attacking, chasing at a distance and angle, standing, wandering or walking its
  waypoints, and pausing them. Summoned creatures are never saved and never come back: they
  go as their summon type says (after their time, out of combat only, when they die, or
  when their corpse goes). A creature casts only
  when it can (not while casting another, in range, with the mana): cast
  times stand it still facing its target (`SMSG_SPELL_START`, then `SMSG_SPELL_GO`); a spell on the
  next swing waits for the swing. Its spells do school damage (a magic one resisted by the level
  difference), weapon damage, auras (debuffs on players, damage over time included; buffs on
  itself), heal it, and trigger other spells, at its target, itself, or the enemies in their area
  or cone. Creatures get their mana back with their health out of combat. Their
  casts are interrupted by interrupting spells (Pummel's `SPELL_EFFECT_INTERRUPT_CAST`), which lock
  the interrupted spell's school for the interrupt's duration (a player's too, shown as cooldowns), and
  theirs interrupt a player's.

## Death, loot and professions

* **Death:** a player killed loses a tenth
  of its gear's durability and lies rooted until it releases its spirit (or six minutes pass, or it
  logs out). Released, it is a ghost at the nearest graveyard of its team (`game_graveyard_zone`:
  the area's, else the zone's, else the map's; an instance's from its entrance), 25% faster (night
  elves a wisp, 50%), walking on water, and its corpse lies where it fell, saved in `corpse`. Within
  39 yards of the corpse, after 30 seconds (60 and 120 for deaths less than five minutes apart), it
  takes its body back with half its health and mana; or a spirit healer, whom only the dead see,
  brings it back at once for a quarter of its gear's durability and, from level 11
  (`death_sickness_level`), resurrection sickness: a minute for each level from 11, ten minutes from
  level 20. Another player's resurrection spell (Resurrection, Redemption, Ancestral Spirit,
  Rebirth), at the dead or their corpse, offers to bring them back beside its caster with the
  spell's health and mana; accepted, the corpse goes. A player who dies with a Soulstone's aura, or
  knowing Reincarnation (ready, with an Ankh), is offered to come back by itself (the Ankh and the
  cooldown taken). A ghost that logs out is one again
  at its next login. A creature killed leaves its corpse for a minute (5 for elites and rares, an
  hour for bosses, at most 90% of its respawn time) and comes back at its spawn point after
  `spawntimesecs` (to `spawntimesecsmax`), kept in `creature_respawn` across restarts. Ghosts
  (`Map`'s `playerSees`, CMaNGOS's rule): the living, and the dead not yet released, do not see
  them; a ghost sees the ghosts of its side and the living within 45 yards of its corpse; group
  members see each other whatever they are, and a game master with the `.gm on` tag sees ghosts
  (as ArcEmu has it). In a cluster another node's players follow the same rule.
* **Experience and loot:** the first
  player to hurt a creature taps it (others see it grey) for itself and its group. A kill gives
  experience (by the level difference, elites and `ExperienceMultiplier`; doubled from
  the rested pool), shared in a group by level among the living members within 74 yards, with a
  bonus from three members on. The corpse sparkles for those who may loot it: its money
  (`MinLootGold`..`MaxLootGold`) and items from `creature_loot_template` and
  `reference_loot_template` (entries, groups, references, conditions). In a group the loot method
  applies: free for all, round robin (the turn moves on), master loot (the master hands out what is
  over the threshold), group loot and need before greed (need, greed or pass for a minute; need
  wins, then the higher roll); money is shared. A looted corpse goes within two minutes, unless it has
  a skin to take.
  * **Skinning:** a looted beast with a skin is skinnable; the skin is its skinner's loot, raising the
    skill (herbalism or mining for the creatures that need them).
  * **Pickpocketing:** a living creature's pockets are a rogue's loot, with some money; emptied, they
    are empty for `creature_pickpocket_restock_delay` seconds.

  An item with random properties drops with one of them (`item_enchantment_template`, shown in
  the loot window) or gets one when it is made. Worn, its enchantments count: stats, resistances,
  weapon damage and equip spells (most "of the Bear" stats are these), as many times as items give
  them.
* **Enchanting:**
  * A permanent enchantment (the enchanting profession) goes into an item's permanent slot.
  * A temporary one (sharpening stones, weightstones, oils, poisons) lasts the spell's time, an hour
    if it gives none. It runs down, is saved with its item, and comes off when the time is up; the
    client shows the time left.
  * A weapon enchantment that casts a spell on a hit (a poison, Crusader, Fiery Weapon) does so by its
    procs a minute at the weapon's speed, else its own percent, else the weapon's normal chance.
* **Crafting** (an item made, an enchantment) may raise the profession: always while the recipe is
  orange, three times in four yellow, one in four green, never grey. Items with loot (clams, sacks, boxes of
  supplies) open in the bags (`CMSG_OPEN_ITEM`, unless a lock needs picking) to their
  `item_loot_template` loot and money; emptied, they are gone (an item left half looted keeps its
  loot until logout, not across it: `item_loot` is not used). A recipe needing a spell focus (an anvil,
  a forge, a cooking fire: `RequiresSpellFocus`) is refused away from one ("Requires ...") and one needing
  tools (`Totem1/2`: a hammer, a mining pick, thieves' tools) without them in the bags. Disenchanting
  opens an uncommon to epic weapon's or armor's `disenchant_loot_template` loot (what is left goes into
  the bags on release) and destroys it. A lockbox is picked open by Pick Lock with the lockpicking skill
  its lock asks for (an orange one may resist: "Failed attempt"), raising the skill, then opens as any.

## Spells and auras

* **Spells:** a known spell is checked (alive, not busy, its cooldown and category cooldown and the global
  cooldown over, standing, the power and reagents it costs, an enemy or friend in range and in
  sight), shown with its cast time (`SpellCastTimes.dbc`; moving interrupts most), then goes: its
  cooldowns start (saved in `character_spell_cooldown` at logout, at each save and before a move to
  another node, and shown in `SMSG_INITIAL_SPELLS` at login), its cost is taken, the hit rolled (magic: 4% and the level difference; melee
  abilities: the attack table), and its effects done: school damage (crits from intellect),
  weapon damage with a bonus or percentage (Heroic Strike waits for the next swing and replaces
  it; Auto Shot and a wand's Shoot fire at the target again and again, each ranged weapon's time,
  held while moving, until cancelled or the target can no longer be shot; each shot of a bow, gun or
  crossbow uses one of the ammunition set, and of a stacking thrown weapon one of it), heals, energize, teleports home (the hearthstone), creating items, learning and triggering
  spells. Items cast their on-use spells (with the item's own cooldowns; food and drink are used
  up); an item's on-equip spells, and its item set's bonuses for as many of the set's items as are
  worn (ItemSet.dbc), are on as auras while it is worn (and unbroken); a weapon's or other worn
  item's chance-on-hit spell is cast when a swing hits (its procs a minute at the weapon's speed, or
  the spell's chance), and a spell that
  needs an item worn (a weapon of some kind, a shield, a fishing pole) is
  refused without it. A channelled spell goes on for its duration (`MSG_CHANNEL_START`, the caster's channel fields),
  ending at its time, when the player cancels it, or when it moves if the spell says so (its auras on
  the target ending with it). Creatures cast through their scripts (below), and players at each
  other where the relations allow (duels, PvP). Area spells take every creature they may attack
  (and enemy players) within their radius of the caster or of the point chosen, or in a cone in
  front; party spells the party members near; a chained spell jumps on to the nearest attackable
  creature within 10 yards, as many times as it says. A persistent area aura (Blizzard,
  Consecration, Rain of Fire) puts a dynamic object on the ground at the spot chosen (or under the
  caster) that hurts every creature the caster may attack within its radius each tick, for the
  spell's duration (or until its channel is cut short). A missile (a spell with a speed: Frostbolt,
  Shoot) does its effects when it reaches each target, after its flight. Spell power: the caster's
  "damage done by spells" of the spell's school (items' and talents' auras) adds to a direct spell's
  damage, times its cast time over 3.5 seconds (1.5 at least), and its "healing done" to a heal
  alike; over time, the bonus times the duration over 15 seconds is shared among the ticks. A spell's
  damage to a creature is partly resisted (none, a quarter, a half, three quarters) by a
  distribution drawn from the creature's resistance of the school and its level above the caster's; a
  binary spell (one with a non-damage effect on its target, such as Frostbolt's slow, or only
  auras) is resisted whole or not at all, its resistance added to its chance to miss; damage over
  time ticks are partly resisted too. A player's resistances work the same against spells, players' and
  creatures' (without the creature's level bonus). Ground effects (persistent area auras:
  Consecration, Blizzard, a frost trap) hurt the enemies inside every tick, players it may fight
  too, or hold their other aura (a slow) on them while they stay.
* **Effects beyond damage and healing** (`effecthandlers.d`; the combat log's lines in
  `SMSG_SPELLLOGEXECUTE`): threat (Distracting Shot adds it, Cower and Feint take it, never below none) and
  taunts (Growl, Taunt: the creature's threat raised to the top's and attacked at once; a taunt aura, with
  Challenging Shout and Mocking Blow, keeps it on the taunter whatever the threat while it lasts); charges
  (Charge, Intercept, Feral Charge: the player runs to its target at the spell's speed, shown to everyone
  and its own client by `SMSG_MONSTER_MOVE`, stops at the target's reach and attacks it); Blink (20 yards
  ahead by a near teleport, two yards at a time, stopping before walls, cliffs' edges and slopes over 50
  degrees); power burns (Mana Burn: mana burned, and half of it as arcane damage), drains (Dark Pact) and
  leeches (Death Coil heals its caster by its damage), Lay on Hands (the caster's whole health); Sword
  Specialization's and Reckoning's extra swings (at most five owed, swung at the next melee update, granting
  no more); Escape Artist (auras of a mechanic removed); Vanish and Divine Intervention (every creature
  fighting the player forgets it, out of combat; Vanish frees of roots too); Distract (creatures out of
  combat stop and face the spot for its seconds); Stuck (a ghost to its graveyard, else the Hearthstone if
  ready, else a nudge ten yards ahead); the hunters' traps (one per slot, replacing the old, the hunter's
  level, for the spell's duration; it springs on the first enemy creature or player within its radius, its
  spell cast by the hunter at it from the trap's place, then waits its cooldown and goes after its charges).
* **Auras:** buffs and debuffs fill the aura fields
  (positive slots 0..31, negative 32..47) and the buff bar's durations, refresh and stack, and end
  when their time is up, when clicked off, at death, or by their interrupt flags (standing up ends
  food and drink, moving, damage, casting, attacking). What they do: stats, percentages of
  stats, resistances and armor, attack power, health and mana (the stats are worked out again),
  speeds and mounts, stances and forms (which spells check), roots and stuns, damage and heals
  over time (on creatures too, as the caster's spell: threat, tapping, the kill), food's health
  every 5 seconds and drink's mana, energize, triggered spells. Auras are saved (`character_aura`)
  at logout and with each save, and come back with the time they had left; a cluster's hand-off
  carries them. A player's shields (Power Word: Shield, Ice Barrier, Mana Shield at its mana per
  point) take damage of their schools until used up; the log shows what they absorbed. Damage
  shields (Thorns) hurt whoever hits the player in melee. Procs (`procs.d`): auras that proc on a swing,
  an ability, a spell, a heal or a tick, dealt or taken, on a dodge, parry or block, or on a kill worth
  experience do so as their spell and its `spell_proc_event` row say (its school, family and spells, crits
  only, a rate a minute at the weapon's speed, a cooldown), by their chance, using their charges: a Proc
  Trigger Spell casts its spell, a dummy or an override
  class script does its talent's thing (Ignite, Seal of Righteousness, Nightfall); what a proc casts sets
  off no procs. The class abilities whose behaviour is code (`classspells.d`, by class there; and the spell
  scripts `spell_scripts` binds: Execute, Life Tap, Preparation) work as CMaNGOS has them: the aura states
  the client needs to allow Execute, Revenge, Overpower, Judgement and Counterattack, one seal at a time and
  Judgement, Conflagrate, Bloodthirst, Cold Snap, Ferocious Bite, Swiftmend, Weakened Soul and Forbearance,
  Lightning Shield, Flametongue, Windfury's extra attacks, Wyvern Sting, and the rest the module lists. A party area aura (a paladin's Devotion
  Aura) is on its caster and, refreshed each second, on its group's members within its radius. A
  shaman's totems stand beside it, one of each element (a new one replaces the old), with its level,
  their health and the spell's duration, and go when it dies or leaves: a passive one holds its
  spell's aura (`creature_template_spells`), given to its owner and party within its radius; an
  active one (Searing Totem) casts its spell at the nearest enemy already fighting the shaman or the group.
  Their kills are their owner's. Dispels (Dispel Magic, Cleanse, Remove Curse, Purge) take random auras of their type:
  harmful magic off friends, helpful magic off enemies. Creatures are slowed and sped up by their
  auras, and stand still while rooted or stunned. Drains over time: Drain Life and Siphon Life hurt
  (`SMSG_SPELLNONMELEEDAMAGELOG`, periodic) and heal their caster by it, Drain Mana and Viper Sting take
  mana and give it (`SMSG_PERIODICAURALOG` with the gain); between players too. Feign Death looks dead
  (`UNIT_DYNFLAG_DEAD`) and, unless the highest-level creature fighting the hunter sees through it (its spell
  miss chance; `SMSG_FEIGN_DEATH_RESISTED`), leaves every fight and creatures let it be until it stands; Fade
  takes its amount of threat with every creature while it lasts. Tracking (`PLAYER_TRACK_CREATURES`,
  `PLAYER_TRACK_RESOURCES`), Hunter's Mark (the track-unit flag, and its attack power for ranged attacks at the
  target), Aspect of the Beast (untrackable), Bestial Wrath's size. Regeneration's auras: Innervate, Evocation
  and Adrenaline Rush multiply their power's regeneration, Regeneration's health out of combat, its share in
  combat, Demon Armor's health every second whatever; Bloodrage and Enrage stop regeneration (and rage's decay)
  as combat does. Holy Shield and Blessing of Sanctuary strike back at whoever's swing the player blocks
  (their charges used); Blessing of Sacrifice passes up to its amount of each blow to its paladin; Curse of
  Recklessness keeps a creature from fleeing. A seal, a blessing, an aspect, a sting, a curse puts out its
  caster's other one, and a buff's higher rank its lower. Not yet: procs on a creature's own auras (beside
  Judgement of Light, of Wisdom, Vampiric Embrace and Stormstrike), the stacking rules of other spells.

## Questing and travel

* **Quests:** quest givers (`creature_questrelation`, `creature_involvedrelation`) show what they have for the player
  (the exclamation and question marks), list their quests in their gossip (or open the only one),
  and give them as `quest_template` says who may take them (class, race, level, skill, condition,
  the quests before, exclusive groups (a negative one asks for every quest of the group), done unless
  repeatable). The quest log holds 20 quests with
  their kill counters. An escort for the party (`QuestFlags` 0x2) taken by one member is offered to
  the others who could take it. Kills count for the player and its group near the kill; the items asked
  for count as they are carried (and quest drops are looted only while a quest asks for them); a
  quest whose objectives are met is complete, and its ender takes the items back and gives its
  experience (`Quest::XPValue`), money, items (one of the choices) and spell, then offers the
  next of the chain, and its reputations. A quest may ask for a standing to be taken, or have one
  as its objective. Places to find (`areatrigger_involvedrelation`) count when the player walks
  into them; items that begin a quest (`startquest`) offer it from the bags and go when it is
  taken; a sharable quest is offered to the group's members within 10 yards who may take it, and
  the one who shared it hears who took it. A timed quest shows its end in the log (one at a time)
  and fails when its time is up. A list of several quests is headed by the giver's
  `questgiver_greeting` and its emote. Progress is saved in `character_queststatus`.
  A spell cast at a quest's creature or object counts for an objective that names it (`ReqSpellCast`,
  for the group near too; a channel's when it ends), as a quest-complete spell effect completes its
  quest and closing a gossip menu counts "speak to" objectives. An abandoned quest takes its source item
  back; a quest to be done alive (`QUEST_FLAGS_STAY_ALIVE`) fails when the player releases its spirit; a
  flag quest (`QUEST_FLAGS_AUTO_REWARDED`) is turned in as it completes. In a raid group only raid quests
  count kills, quest drops and quest objects. Quest objects' sparkle is sent again as the quests change.
  Reward and source items are "received", not "created" (rewards with no chat line of their own).
* **Flight masters:** a flight master's node (`TaxiNodes.dbc`) is learned at the first talk and saved in `taximask`; then the
  master shows the known nodes. A flight to one, directly or over several legs (`TaxiPath.dbc`,
  `TaxiPathNode.dbc`), costs the paths' prices (10% less at honored with the master's faction),
  mounts the player on its node's flying mount and flies it along the path at 32 yards a second
  (`SMSG_MONSTER_MOVE` for everyone), the server following so that its place on the map and its
  sight change as it goes; at the end it lands at the destination. Busy, mounted, in a form other
  than a stance, too far, out of money or not knowing a node, it is refused.
  A flight is saved as it goes (`taxi_path`, CMaNGOS's format `resumenode#pathid`): logged out in
  flight, or after a crash, the character comes back at the path point ahead and flies on, unpaid,
  to the end of the leg it was on (as CMaNGOS does by default; a flight of several legs ends
  there). In a cluster the node a flight starts on flies it to the end, the player moving on once
  landed. `.cheat taxi` gives or takes every node. Not yet: flights across maps, a flight's pauses.

## Economy and progression

* **Auctions:** auctioneers open
  their city's house (`AuctionHouse.dbc`; the goblins' for the neutral towns; one for both
  factions with `allow_two_side_interaction_auction`). An item that may be traded is put up for 2,
  8 or 24 hours for a deposit (the house's share of its sell price for each 2 hours: 5% at the factions'
  houses, 25% at the goblins'), using the [auction house formulas](FORMULAS.md). Bids start
  at the start bid and rise by 5% at least, not on one's own auctions or another character's of the
  account; a bid at the buyout buys it. The buyer gets the item by mail, the seller the price and
  the deposit less the house's cut (5%, the goblins' 15%), an outbid bidder the money back, each told if online; a seller
  may take an auction back (paying the cut of a bid) and gets the item by mail. When the time is up
  the highest bid buys it, or the item goes back. Searches filter by name, level, slot, class,
  sub-class, quality and usability, 50 at a time; sellers and bidders list theirs. The `auction`
  table is the one place: every node of a cluster lists from it and changes a row only as it saw
  it (so two nodes cannot both sell one auction), and the coordinator settles those over.
* **Reputation:** each character's standing with the factions of the
  reputation list, from its race's and class's base (`Faction.dbc`), saved in
  `character_reputation`. Kills give `creature_onkill_reputation`'s (shared by a group as
  experience is, half to the faction's team where it says so, up to its rank cap), quests their
  `RewRepFaction` ones; a fifth at least for kills grey to the player and quests far below it;
  `reputation_spillover_template` passes shares on to related factions, `reputation_reward_rate`
  scales them. A faction gained with shows in the client's list; falling to hostile is war, rising
  to neutral peace, and the client sets war (where allowed), inactive and the watched faction.
  Creatures react to a player by its standing and its wars; honored and above get 10% off at
  vendors, trainers and repairs; items, conditions and quests that ask for a rank check it. Auras may force a
  faction's reaction (`SMSG_SET_FORCED_REACTIONS`): disguises, the Corrupted Ashbringer (the Scarlet Crusade friendly).
* **Weather:** a zone with a `game_weather` row has rain, snow or
  storms by the season's chances, changing every 10 minutes (better, worse, or anew) while players
  are in it; they see it (`SMSG_WEATHER`) on entering the zone and when it changes, and fine
  weather in zones without a row.
* **Talents:** a talent point a level from 10 on; a talent of the
  player's class is learned a rank at a time, if its tree has 5 points for each row above it and
  what it depends on is known, the new rank's spell replacing the rank before. Passive spells
  (talents, racials) put their aura effects on the player for good, at login and when learned (as
  far as those auras are done; those bound to a kind of weapon are not applied yet). Talents that
  are spell modifiers (`SPELL_AURA_ADD_FLAT_MODIFIER`, `ADD_PCT_MODIFIER`) change the spells of
  their family and mask: damage and healing, damage over time, cost, cast time, cooldowns,
  durations, range, radius, effect values and crit chance (`spellmods.d`). A class trainer of the
  player's class offers to unlearn them from level 10, for 1 gold, 5, 10, then 5
  more each time up to 50, 5 less for each month without a reset, saved with the character.
* **Mail:** at a mailbox, letters to a character of the faction
  (30 copper) with an item, money or cash on delivery; the inbox (50 letters), taking money and
  items (cash on delivery paid and mailed to the sender), reading bodies, copying them as Plain
  Letters, returning and deleting. An attached item sent to another account arrives after
  `mail_delivery_delay` (an hour by default). Same-account mail, plain letters, and money-only mail
  arrive at once. It all lives in the database (`mail`, `mail_items`, `item_text`), read each time, so a player's mail is the same
  on any node of a cluster. Once an hour (on one node of a cluster) letters whose time is up are
  settled: a player's letter with an item goes back to
  its sender once, every other one is deleted with its item. Auctions, quest rewards, level
  rewards and game events can also send mail.
* **Gift wrapping:** an item wrapped in gift paper (a sheet used) becomes the wrapped gift, what it
  was kept in `character_gifts`; opened, it is that item again. Bags, equipped, bound, stackable,
  unique and wrapped items cannot be wrapped.

## Trade, duels and battlegrounds

* **Trading:** two players of a faction within 11 yards trade up
  to six items and money each; any change takes back both acceptances; when both accept, it goes
  through if both can pay and carry it (the items keep their guids and change owners, their
  giver's rows deleted and their taker's inserted). Enchanting through the seventh slot is supported.
  See [cross-node trading](CLUSTER.md#what-crosses-nodes-feature-by-feature) for the cluster path.
* **Duels:** the Duel spell plants a
  flag between two players and asks the other; accepted, both count down 3 seconds and are then
  enemies of each other, in melee and with spells (players can attack players: duelists, and
  enemies flagged for PvP). A blow that would kill leaves 1 health and loses the duel (the loser
  begs); 50 yards from the flag for 10 seconds flees it; declining, logging out or teleporting
  ends it; everyone around hears who won, and the debuffs each put on the other go.
* **Battlegrounds** (`bgqueue.d`, `battleground.d`, `warsong.d`, `arathi.d`): Warsong Gulch, Arathi Basin and Alterac Valley.
  * **Queueing:** at a battlemaster, alone or as a group, in brackets of ten levels; up to three
    queues at once; invitations last 80 seconds. The queues are a cluster service.
  * **A copy of the battleground** is made when enough of both sides wait, and runs on the node
    hosting its map. It counts down two minutes; then its doors open and its objectives spawn.
  * **During the battle:** kills, deaths and objectives count on the scoreboard (`MSG_PVP_LOG_DATA`, asked
    for at any time; its columns `WorldStateUI.dbc`'s: Warsong Gulch's flags captured and returned, Arathi
    Basin's bases assaulted and defended, Alterac Valley's graveyards and towers assaulted and defended,
    mines captured, leaders killed and secondary objectives); spirit guides resurrect every 30 seconds.
  * **The end:** a winner, marks of honor, bonus honor and reputation, the scoreboard shown (and kept in
    `pvpstats_battlegrounds` and `pvpstats_players` with `battleground_score_statistics`); everyone is sent
    back two minutes later.
  * **Leaving early** gives Deserter (15 minutes without queueing). A side short of players for five
    minutes loses.
  * **Warsong Gulch:** three flag captures win. **Arathi Basin:** five bases and their resources;
    2000 resources win. **Alterac Valley** (`alterac.d`), as 1.12 had it (reinforcements came with patch 2.3.0): a
    general's death wins, the only way to; graveyards and towers assaulted from their banners and taken (a
    tower destroyed, its marshal gone) five minutes later unless defended; two mines taken by killing
    their bosses, held for 20 minutes; honor and reputation for towers destroyed and captains killed, and
    reputation for graveyards and mines held at the end. Every 500 armor scraps upgrade a side's defenders by one rank, through champion.
    At 200 Storm Crystals or Stormpike Soldier's Blood the summoners set out. Escort them and gather
    ten allies at their altar to call Ivus or Lokholar. Provide hides and mounts to deploy cavalry,
    return mine supplies to order a ground assault, or rescue a Wing Commander and deliver the
    enemy soldiers' drops to unlock air support. The herald's lines appear as battleground messages.
  * The players of a team who came alone are in one raid in the copy (its raid frames), made as the
  second arrives and left as they leave; those who came with a group stay in it.
  * Taking an objective (a flag, a banner, a capture) ends Stealth, Divine Shield and the like
  (`AURA_INTERRUPT_FLAG_PVP_ACTIVE_CANCELS`); a carried flag falls when its aura goes otherwise (clicked off,
  or purged as its carrier becomes immune).
  * A player killed there may have their insignia taken by an enemy (Remove Insignia, from the body or the
  corpse): released if not yet, the corpse turns to bones the enemy loots (a little money by level, the
  battleground's `PlayerSkinReflootId`). Elsewhere a body taken back or healed leaves bones for an hour.

## Saving and logout

* **The update tick** (every 50 ms, `update_interval`): health, mana, rage and energy regenerate
  (health and the loss of rage only out of combat, and only for the living); inns and capitals give rested XP, also while offline; characters are saved every
  15 minutes (`player_save_interval`).
* **Logout** takes 20 seconds, sitting and rooted, unless the player rests or its account level
  reaches `instant_logout`; it can be cancelled. It saves the position, zone, level, money, health
  and powers, rest, played time and settings. A connection that drops is saved the same way.
* At start-up, every character and account of the realm is marked offline.

## Scourge Invasion

A GM can run `.scourge start` to launch the original patch 1.11 event on a realm, `.scourge status` to see its zone victories, and `.scourge stop` to end it early. Starting an active campaign preserves its progress. Each realm keeps its own progress in its character database.

Look for the skulls on the world map. Kill undead around a Necrotic Shard until four Cultist Engineers appear. Bring eight Necrotic Runes to one engineer and defeat the Shadow of Doom it summons. Four Shadows can destroy the damaged shard before the engineers repair it. Clear all three camps under a necropolis to bring down the ship. Defending every ship in a zone earns one realm victory. The capital rewards change at 50, 100 and 150 victories. The 150th victory ends outdoor attacks. The event's dungeon bosses and reward vendors end three weeks after launch. [Original and Classic schedules compared by Blizzard](https://us.forums.blizzard.com/en/wow/t/naxxramas-opening-time-and-scourge-invasion-adjustments/741200/1)

The later zone activation delays and hourly engineer refresh follow the CMaNGOS reconstruction. The original repair rate is uncertain. [Historical evidence and database bindings](../reports/The%20original%20Scourge%20Invasion.md)
