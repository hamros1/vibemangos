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
  and emotes, and can whisper. Creatures and game objects are spawned; creatures wander and walk
  their waypoints, and vendors, trainers, innkeepers and bankers serve.
* **extractor** copies the DBC files out of a 1.12 client's MPQ archives into a `dbc/` folder, and
  converts its terrain into CMaNGOS's `.map` files in a `maps/` folder.
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
dub build -c loadgen           # -> bin/loadgen: headless clients for load tests (docs/BENCHMARKS.md)
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

`data_dir` must point at a directory containing a `dbc/` folder extracted from your client, and
preferably a `maps/` folder too. Use dmangos's own extractor (below), or point it at mangosd's
`DataDir`, which works as is. Without `maps/` the server takes the client's word for which zone it
is in, and nothing is explored. With `vmaps/` too, buildings count: heights on floors, bridges and
roofs, the areas inside buildings, indoors and outdoors, and what blocks a line of sight. Character creation reads
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
    attack power, weapon damage and speed, skills, explored zones, money and XP, with its auras,
    talents and crit, dodge, parry and block chances. Guild membership is not applied yet.
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
  * **Dungeon instances:** each group (or player on its own) gets its own copy of a dungeon or
    raid: a raid's bound copy first (its lockout), else its group's, else its own bind's, else a new
    one, to which it and its group are bound. Copies, binds and what was killed or used up in them
    are saved (`instance`, `character_instance`, `group_instance`, and `creature_respawn` and
    `gameobject_respawn` by instance) and read back at start-up. A dungeon copy nobody has been in
    for `instance_unload_delay_seconds` resets with its binds; a raid copy lasts until its reset
    (`instance_template.reset_delay` days after it was made), so its players stay locked to it, and
    one bound to another copy than its group's is turned away. A player logging back in inside a
    dungeon returns to its copy; a GM's `.appear` and `.summon` go into the other's copy, and ArcEmu's
    `.instance` commands and `.character showinstances` work on the copies; a full copy
    (`instance_template.maxPlayers`) turns others away, game masters aside. Not yet: encounter
    state, resets at fixed weekly times, the reset warnings; a cluster keeps one shared copy of
    each dungeon.
  * **Groups:** invitations, parties and raids of up to 40 in eight sub-groups, leaders and
    assistants, kicking, leaving, loot settings, raid target icons, ready checks, rolls, minimap
    pings, and member stats for members out of sight. Groups are kept in `groups` and
    `group_member` and survive restarts. Logging out of a party leaves it, as in CMaNGOS.
  * **Chat:** say, yell and emotes reach those in range; whispers reach anyone online of the same
    faction; party, raid, raid leader and raid warning messages reach the group. `/afk` and `/dnd`
    set the flag, the chat tag and the reply to whispers. `/who` lists who is online, filtered as
    in CMaNGOS.
  * **Channels:** the built-in ones (General, Trade, LocalDefense, ...), which follow the zone,
    and custom ones with owners, moderators, passwords, muting, kicks, bans, invitations,
    announcements and moderation. One set per faction, unless
    `allow_two_side_interaction_channel` is on.
  * **The GM system is ArcEmu's:** its command tables, permission letters, lookup and replies,
    word for word, with CMaNGOS's `gmlevel` mapped to letters by `gm_permissions`. 210 of its 298
    commands work: teleports and `game_tele` recall places, `.modify` (health, stats, speed, money,
    level, looks, ...), `.levelup`, `.character learn`, skills, items, lookups, kicks, bans, mutes,
    account levels, timed shutdowns and restarts, announcements, the GM tag and whisper blocking,
    killing and reviving, casting, clearing cooldowns and auras, resetting talents, respawning, the
    cheats (cooldown, cast time, god mode, power, explore, triggerpass), `.invincible`, instances,
    quests (status, starting, completing, quest givers and their lists), reputation, spawning and
    deleting creatures and game objects, vendors' wares, resetting spells and skills, and debugging.
    The others (pets, guilds, battlegrounds, tickets, waypoint editing, ...) say "Not yet
    implemented." See [docs/COMMANDS.md](docs/COMMANDS.md).
  * **NPCs:** gossip menus with their texts and conditions, trainers (lists and lessons, with
    ranks and professions), innkeepers binding the hearthstone, bankers, and vendors.
  * **Items:** CMaNGOS's inventory rules: moving, stacking, splitting, equipping, bags, the bank and
    its bag slots, the keyring, destroying, ammo; buying (with limited stock), selling, buyback and
    repairs. Every change is saved to `character_inventory` and `item_instance` as it happens.
  * **Queries:** name, item (`SMSG_ITEM_QUERY_SINGLE_RESPONSE`, from every `item_template`
    column), time and played time.
  * **Settings:** sitting and standing, target selection, action bar buttons and toggles, and
    tutorial flags, saved as they change.
  * **Creatures and game objects:** every `creature` and `gameobject` spawn of the world database
    (pools, spawn groups and game events decide which), created when a player first comes near
    their cell, with CMaNGOS's levels, health, models, equipment, mounts and emotes. Their names come
    from `CMSG_CREATURE_QUERY` and `CMSG_GAMEOBJECT_QUERY`. Game objects whose `spawntimesecs` is
    below 0 wait for events and scripts to spawn them, as in CMaNGOS.
  * **Using game objects** (CMaNGOS's `GameObject::Use`, `EffectOpenLock`): doors and buttons open
    for their time and close again; chairs seat the player at the nearest slot; goobers are in use
    for their time, show their page, count for the quests that need them (for the group near them
    too) and cast their spell on the user; cameras play their cinematic. Locks (`Lock.dbc`) open to
    their key item or to a spell of their lock type with the skill they need (lockpicking,
    herbalism, mining), which may rise by CMaNGOS's gathering chances the first time each object is
    opened. A chest (herbs and veins too) shows its `gameobject_loot_template` loot with a group's
    loot rights and quest items for those whose quests need them; a consumable one is gone once
    emptied (or 5 minutes after opening) and comes back after its respawn time, kept in
    `gameobject_respawn` across restarts. Quest objects sparkle for the players whose quests need
    them, and game objects give and take back quests (`gameobject_questrelation`,
    `gameobject_involvedrelation`) as creatures do. A trap springs on a player who steps within its
    radius (half its diameter) and is not its faction's friend: its spell at the player, then its
    cooldown; one with charges is used up after them. Not yet: their own gossip, mining
    veins' extra uses, linked traps, stealthed traps' visibility, creatures springing traps,
    another node's objects in a cluster.
  * **Fishing** (CMaNGOS's `EffectTransmitted` and `GameObject::Use` of a bobber): the fishing spell
    channels at a bobber cast between its least and greatest range in front of the angler, on the
    water (or "not fishable"); the fish bites 3, 7, 13 or 17 seconds before the channel would end
    (the bobber splashes) and waits 5 seconds. Used in time, the catch depends on the fishing skill
    against `skill_fishing_base_level` of the area (or zone), every try may raise the skill, and a
    catch is looted from `fishing_loot_template`; too early nothing is hooked, too late the fish got
    away; it takes a fishing pole worn. A school of fish (`GAMEOBJECT_TYPE_FISHINGHOLE`) within 20
    yards of the bobber gives the catch from its own loot, and is fished out after a few catches.
    Not yet: junk on a failed catch.
  * **Creature movement:** creatures move as their spawn's `MovementType` says, as in CMaNGOS:
    wandering within `spawndist` of their spawn point (type 1), or walking their `creature_movement`
    or `creature_movement_template` path (type 2 round and round, type 4 back and forth), waiting
    and facing where the path says. Clients get `SMSG_MONSTER_MOVE`, and a creature that comes into
    sight mid-walk arrives with its walk in its create block. Paths are straight lines; a wander's
    end is put on the ground from the maps and vmaps. AI and waypoint scripts come next.
  * **Melee** (CMaNGOS's `CombatHandler.cpp` and `Unit`'s melee): players auto-attack creatures they
    may attack (CMaNGOS's relations API over `FactionTemplate.dbc` and `Faction.dbc`'s base
    reputations: not friendly), with the swing loop, swing errors (out of reach, facing, dead target)
    and the dual-wield off hand. Each swing rolls CMaNGOS's attack table (miss, dodge, parry, block,
    glancing, crit) from weapon and defense skills and levels, takes off armor, shows the client
    `SMSG_ATTACKERSTATEUPDATE`, gives warriors rage, and takes the creature's health; a creature at
    none dies. Creatures have CMaNGOS's damage, attack power and armor (`creature_template` and
    `creature_template_classlevelstats`), players their crit (agility), dodge, parry and block
    chances and shield block. Players are in combat while a creature fights them and for 5 seconds
    after a swing (no health regeneration or rage decay meanwhile). Swings at creatures (critters
    aside) raise the weapon skill, and theirs at the player its defense, as CMaNGOS's
    `UpdateCombatSkills` rolls it (likelier the farther below the maximum; intellect helps weapons).
  * **Creatures fight** (CMaNGOS's base creature AI): attacked, they fight back; aggressive ones
    (not `CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT`) attack a hostile player that comes within their
    aggro radius (`Detection`, a yard more for each level the player is below them) and in sight.
    They keep a threat list (damage is threat; a new victim needs 110% of the current one's in melee
    reach, 130% elsewhere), chase in straight lines, swing with CMaNGOS's attack table (crushing
    blows included), and give warriors rage. They give up (evade) when nobody is left to fight, or
    when their victim is 30 yards beyond where their `Pursuit` time last started; they run back to
    where the fight began, evading attacks, and get a third of their health back every 5 seconds out
    of combat. Starting a fight, a creature calls for help (CMaNGOS's `CallAssistance`): allies
    within 5 yards (or its `CallForHelp`) that would attack the enemy on sight join in a moment and a
    half later; and a fighting creature that passes within 5 yards of an idle ally pulls it in.
  * **Database scripts** (CMaNGOS's `dbscripts_on_*`): a quest's start and complete scripts, a
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
    wandering, its path), pausing and resuming its path, AI events. Not yet: paths by id.
  * **Creature scripts** (CMaNGOS's EventAI, `creature_ai_scripts`, for each creature entry or
    spawn): their events (timers in and out of combat, health, mana and the victim's health between
    two percentages, the victim within a range or casting, aggro, a kill, death, evading, spawning,
    reaching home, an aura of their own there or missing, a spell hitting them, a player's emote at
    them, a friend near them hurt, another creature's AI event) run their actions by chance and phase, repeating after their
    repeat timers: casting a spell (healing that friend too), saying, yelling, emoting or whispering
    a `broadcast_text` (or one of a `dbscript_random_templates` group, or by a chance), emotes,
    sounds, phases, fleeing in fear for 7 seconds, calling for help, combat movement, swings on or
    off, ranged mode (keeping a distance to cast, coming in to melee when out of mana), stand states,
    unit flags, taking auras off, despawning, not dying of damage, react states, factions, random
    phases, quest events and kill credit for the players fighting it, relay scripts (the database
    scripts below), AI events to the friendly creatures around, summoning creatures (beside it or at a `creature_ai_summons` spot, attacking
    its target), evading, attacking. Summoned creatures are never saved and never come back: they
    go as CMaNGOS's `TempSpawnType` says (after their time, out of combat only, when they die, or
    when their corpse goes). A creature casts as
    CMaNGOS's `DoCastSpellIfCan` allows (not while casting another, in range, with the mana): cast
    times stand it still facing its target (`SMSG_SPELL_START`, then `SMSG_SPELL_GO`); a spell on the
    next swing waits for the swing. Its spells do school damage (a magic one resisted by the level
    difference), weapon damage, auras (debuffs on players, damage over time included; buffs on
    itself), heal it, and trigger other spells, at its target, itself, or the enemies in their area
    or cone. Creatures get their mana back with their health out of combat. Not yet: the other
    events and actions (summons, morphs, AI events between creatures, quest events, relay scripts),
    spell lists (`creature_template_spells`), spell school lockouts. Their
    casts are interrupted by interrupting spells (Pummel's `SPELL_EFFECT_INTERRUPT_CAST`), and
    theirs interrupt a player's.
  * **Death** (CMaNGOS's `KillPlayer`, repop, reclaim and spirit healer): a player killed loses a tenth
    of its gear's durability and lies rooted until it releases its spirit (or six minutes pass, or it
    logs out). Released, it is a ghost at the nearest graveyard of its team (`game_graveyard_zone`:
    the area's, else the zone's, else the map's; an instance's from its entrance), 25% faster (night
    elves a wisp, 50%), walking on water, and its corpse lies where it fell, saved in `corpse`. Within
    39 yards of the corpse, after 30 seconds (60 and 120 for deaths less than five minutes apart), it
    takes its body back with half its health and mana; or a spirit healer, whom only the dead see,
    brings it back at once for a quarter of its gear's durability. A ghost that logs out is one again
    at its next login. A creature killed leaves its corpse for a minute (5 for elites and rares, an
    hour for bosses, at most 90% of its respawn time) and comes back at its spawn point after
    `spawntimesecs` (to `spawntimesecsmax`), kept in `creature_respawn` across restarts. Not yet:
    resurrection sickness, ghosts hidden from the living, skinnable corpses.
  * **Experience and loot** (CMaNGOS's `XP::Gain`, `RewardGroupAtKill` and `LootMgr`): the first
    player to hurt a creature taps it (others see it grey) for itself and its group. A kill gives
    CMaNGOS's experience (by the level difference, elites and `ExperienceMultiplier`; doubled from
    the rested pool), shared in a group by level among the living members within 74 yards, with a
    bonus from three members on. The corpse sparkles for those who may loot it: its money
    (`MinLootGold`..`MaxLootGold`) and items from `creature_loot_template` and
    `reference_loot_template` (entries, groups, references, conditions). In a group the loot method
    applies: free for all, round robin (the turn moves on), master loot (the master hands out what is
    over the threshold), group loot and need before greed (need, greed or pass for a minute; need
    wins, then the higher roll); money is shared. A looted corpse goes within two minutes. Not yet:
    random enchantments, skinning and pickpocketing. Items with loot (clams, sacks, boxes of
    supplies) open in the bags (`CMSG_OPEN_ITEM`, unless a lock needs picking) to their
    `item_loot_template` loot and money; emptied, they are gone (an item left half looted keeps its
    loot until logout, not across it as CMaNGOS's `item_loot` does).
  * **Spells** (CMaNGOS's `Spell::SpellStart`, `CheckCast`, `cast` and `SpellEffects.cpp`): a
    known spell is checked (alive, not busy, its cooldown and category cooldown and the global
    cooldown over, standing, the power and reagents it costs, an enemy or friend in range and in
    sight), shown with its cast time (`SpellCastTimes.dbc`; moving interrupts most), then goes: its
    cooldowns start, its cost is taken, the hit rolled (magic: 4% and the level difference; melee
    abilities: the attack table), and its effects done: school damage (crits from intellect),
    weapon damage with a bonus or percentage (Heroic Strike waits for the next swing and replaces
    it), heals, energize, teleports home (the hearthstone), creating items, learning and triggering
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
    damage to a creature is partly resisted (none, a quarter, a half, three quarters) by CMaNGOS's
    distribution, from the creature's resistance of the school and its level above the caster's; a
    binary spell (one with a non-damage effect on its target, such as Frostbolt's slow, or only
    auras) is resisted whole or not at all, its resistance added to its chance to miss; damage over
    time ticks are partly resisted too. Not yet: resists against players, the area auras' other effects (slows) and their hitting players.
  * **Auras** (CMaNGOS's `SpellAuraHolder` and `Aura`): buffs and debuffs fill the aura fields
    (positive slots 0..31, negative 32..47) and the buff bar's durations, refresh and stack, and end
    when their time is up, when clicked off, at death, or by their interrupt flags (standing up ends
    food and drink, moving, damage, casting, attacking). What they do: stats, percentages of
    stats, resistances and armor, attack power, health and mana (the stats are worked out again),
    speeds and mounts, stances and forms (which spells check), roots and stuns, damage and heals
    over time (on creatures too, as the caster's spell: threat, tapping, the kill), food's health
    every 5 seconds and drink's mana, energize, triggered spells. Auras are saved (`character_aura`)
    at logout and with each save, and come back with the time they had left; a cluster's hand-off
    carries them. Not yet: dispels, procs, absorbs, auras on creatures slowing or rooting them.
  * **Quests** (CMaNGOS's `QuestHandler.cpp`, `GossipDef.cpp` and `Player`'s quest functions): quest
    givers (`creature_questrelation`, `creature_involvedrelation`) show what they have for the player
    (the exclamation and question marks), list their quests in their gossip (or open the only one),
    and give them as `quest_template` says who may take them (class, race, level, skill, condition,
    the quests before, exclusive groups, done unless repeatable). The quest log holds 20 quests with
    their kill counters. Kills count for the player and its group near the kill; the items asked
    for count as they are carried (and quest drops are looted only while a quest asks for them); a
    quest whose objectives are met is complete, and its ender takes the items back and gives its
    experience (`Quest::XPValue`), money, items (one of the choices) and spell, then offers the
    next of the chain, and its reputations. A quest may ask for a standing to be taken, or have one
    as its objective. Places to find (`areatrigger_involvedrelation`) count when the player walks
    into them; items that begin a quest (`startquest`) offer it from the bags and go when it is
    taken; a sharable quest is offered to the group's members within 10 yards who may take it, and
    the one who shared it hears who took it. A timed quest shows its end in the log (one at a time)
    and fails when its time is up. A list of several quests is headed by the giver's
    `questgiver_greeting` and its emote. Progress is saved in `character_queststatus`. Not yet: escort
    quests.
  * **Flight masters** (CMaNGOS's `TaxiHandler.cpp`, `Taxi.cpp`, `ActivateTaxiPathTo`): a flight
    master's node (`TaxiNodes.dbc`) is learned at the first talk and saved in `taximask`; then the
    master shows the known nodes. A flight to one, directly or over several legs (`TaxiPath.dbc`,
    `TaxiPathNode.dbc`), costs the paths' prices (10% less at honored with the master's faction),
    mounts the player on its node's flying mount and flies it along the path at 32 yards a second
    (`SMSG_MONSTER_MOVE` for everyone), the server following so that its place on the map and its
    sight change as it goes; at the end it lands at the destination. Busy, mounted, in a form other
    than a stance, too far, out of money or not knowing a node, it is refused as CMaNGOS refuses it.
    Logging out in flight saves the character at the destination. `.cheat taxi` gives or takes
    every node. Not yet: flights across maps, a flight's pauses, resuming a flight at login,
    flying on to another node of a cluster mid-flight.
  * **Auctions** (CMaNGOS's `AuctionHouseMgr` and `AuctionHouseHandler.cpp`): auctioneers open
    their city's house (`AuctionHouse.dbc`; the goblins' for the neutral towns; one for both
    factions with `allow_two_side_interaction_auction`). An item that may be traded is put up for 2,
    8 or 24 hours for a deposit (the house's share of its sell price for each 2 hours); bids start
    at the start bid and rise by 5% at least, not on one's own auctions or another character's of the
    account; a bid at the buyout buys it. The buyer gets the item by mail, the seller the price and
    the deposit less the house's cut, an outbid bidder the money back, each told if online; a seller
    may take an auction back (paying the cut of a bid) and gets the item by mail. When the time is up
    the highest bid buys it, or the item goes back. Searches filter by name, level, slot, class,
    sub-class, quality and usability, 50 at a time; sellers and bidders list theirs. The `auction`
    table is the one place: every node of a cluster lists from it and changes a row only as it saw
    it (so two nodes cannot both sell one auction), and the coordinator settles those over.
  * **Reputation** (CMaNGOS's `ReputationMgr`): each character's standing with the factions of the
    reputation list, from its race's and class's base (`Faction.dbc`), saved in
    `character_reputation`. Kills give `creature_onkill_reputation`'s (shared by a group as
    experience is, half to the faction's team where it says so, up to its rank cap), quests their
    `RewRepFaction` ones; a fifth at least for kills grey to the player and quests far below it;
    `reputation_spillover_template` passes shares on to related factions, `reputation_reward_rate`
    scales them. A faction gained with shows in the client's list; falling to hostile is war, rising
    to neutral peace, and the client sets war (where allowed), inactive and the watched faction.
    Creatures react to a player by its standing and its wars; honored and above get 10% off at
    vendors, trainers and repairs; items, conditions and quests that ask for a rank check it.
  * **Weather** (CMaNGOS's `Weather.cpp`): a zone with a `game_weather` row has rain, snow or
    storms by the season's chances, changing every 10 minutes (better, worse, or anew) while players
    are in it; they see it (`SMSG_WEATHER`) on entering the zone and when it changes, and fine
    weather in zones without a row.
  * **Talents** (CMaNGOS's `LearnTalent`): a talent point a level from 10 on; a talent of the
    player's class is learned a rank at a time, if its tree has 5 points for each row above it and
    what it depends on is known, the new rank's spell replacing the rank before. Passive spells
    (talents, racials) put their aura effects on the player for good, at login and when learned (as
    far as those auras are done; those bound to a kind of weapon are not applied yet). Not yet:
    unlearning talents at a trainer.
  * **Mail** (CMaNGOS's `MailHandler.cpp`): at a mailbox, letters to a character of the faction
    (30 copper) with an item, money or cash on delivery; the inbox (50 letters), taking money and
    items (cash on delivery paid and mailed to the sender), reading bodies, copying them as Plain
    Letters, returning and deleting. Items and money to another account arrive after
    `mail_delivery_delay` (an hour), the rest at once with "you have new mail". It all lives in
    the database (`mail`, `mail_items`, `item_text`), read each time, so a player's mail is the same
    on any node of a cluster. Once an hour (on one node of a cluster) letters whose time is up are
    settled as CMaNGOS's `ReturnOrDeleteOldMails` does: a player's letter with an item goes back to
    its sender once, every other one is deleted with its item. Auction houses send mail too. Not
    yet: mail from NPCs and quests (`mail_template`).
  * **Trading** (CMaNGOS's `TradeHandler.cpp`): two players of a faction within 11 yards trade up
    to six items and money each; any change takes back both acceptances; when both accept, it goes
    through if both can pay and carry it (the items keep their guids and change owners, their
    giver's rows deleted and their taker's inserted). Not yet: the seventh slot's enchanting spell,
    trading across a cluster's nodes.
  * **Duels** (CMaNGOS's `DuelHandler.cpp`, `EffectDuel`, `DuelComplete`): the Duel spell plants a
    flag between two players and asks the other; accepted, both count down 3 seconds and are then
    enemies of each other, in melee and with spells (players can attack players: duelists, and
    enemies flagged for PvP). A blow that would kill leaves 1 health and loses the duel (the loser
    begs); 50 yards from the flag for 10 seconds flees it; declining, logging out or teleporting
    ends it; everyone around hears who won, and the debuffs each put on the other go.
  * **The update tick** (every 50 ms, `update_interval`): health, mana, rage and energy regenerate
    as in CMaNGOS (health and the loss of rage only out of combat, and only for the living); inns and capitals give rested XP, also while offline; characters are saved every
    15 minutes (`player_save_interval`).
  * **Logout** takes 20 seconds, sitting and rooted, unless the player rests or its account level
    reaches `instant_logout`; it can be cancelled. It saves the position, zone, level, money, health
    and powers, rest, played time and settings. A connection that drops is saved the same way.
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
| `instance_unload_delay_seconds` | `Instance.UnloadDelay` (ms there): an empty dungeon copy resets after so long | `1800` |
| `grid_cleanup_delay_seconds` | `GridCleanUpDelay` (ms there): a cell no player has been near for so long unloads its creatures and game objects; `0` never | `300` |
| `listen_range_say`, `listen_range_text_emote`, `listen_range_yell` | `ListenRange.Say`, `ListenRange.TextEmote`, `ListenRange.Yell` | `25`, `25`, `300` |
| `allow_two_side_interaction_chat` | `AllowTwoSide.Interaction.Chat` (whispers between factions) | `false` |
| `allow_two_side_interaction_channel`, `allow_two_side_interaction_group` | `AllowTwoSide.Interaction.Channel`, `AllowTwoSide.Interaction.Group` | `false`, `false` |
| `allow_two_side_interaction_auction` | `AllowTwoSide.Interaction.Auction` | `false` |
| `chat_restricted_raid_warnings` | `Chat.RestrictedRaidWarnings` | `false` |
| `allow_two_side_who_list` | `AllowTwoSide.WhoList` (the other faction in /who) | `false` |
| `gm_level_in_who_list` | `GM.InWhoList.Level` (the highest account level players see in /who) | `3` |
| `max_who_list_returns` | `MaxWhoListReturns` (the most matches /who counts; it lists at most 49) | `49` |
| `instance_ignore_level`, `instance_ignore_raid` | `Instance.IgnoreLevel`, `Instance.IgnoreRaid` | `false`, `false` |
| `update_interval` | the world tick, in ms (mangosd's `WORLD_SLEEP_CONST`) | `50` |
| `compression` | `Compression`: zlib level of update packets, 1 (fastest) to 9 | `1` |
| `metrics_interval_seconds` | n/a: seconds between log lines with tick times and GC figures; 0 for none | `60` |
| `cluster` | n/a: this node's place in a cluster (docs/CLUSTER.md); standalone without it | none |
| `logout_delay`, `player_save_interval` | seconds a logout takes (GMs and resting players: none), `PlayerSave.Interval` (seconds here) | `20`, `900` |
| `gm_permissions` | ArcEmu's permission letters for `account.gmlevel` 1, 2 and 3 | `{"1": "bcghiltuv", "2": "a", "3": "az"}` |
| `command_overrides` | ArcEmu's `command_overrides` table: `[{"command": "gm on", "group": "m"}]` | none |
| `allow_player_commands`, `gm_command_log` | ArcEmu's `Server.AllowPlayerCommands`, `Log.GMCommands` (a file name here) | `false`, none |
| `gamemaster_list_only_active_gms`, `gamemaster_hide_permissions` | ArcEmu's `GameMaster.ListOnlyActiveGMs`, `.HidePermissions` | `false`, `false` |
| `send_stats_on_join`, `gm_client_channel` | ArcEmu's `Server.SendStatsOnJoin`, `GMClient.GmClientChannel` | `true`, none |
| `flood_lines`, `flood_seconds`, `flood_message` | ArcEmu's `FloodProtection.*` (0 = off) | `0`, `0`, `false` |
| `announce_tag`, `announce_gm_admin_tag`, `announce_name_in_announce`, `announce_name_in_wannounce` | ArcEmu's `Announce.*` | `Staff`, `false`, `true`, `true` |
| `announce_tag_color`, `announce_gm_tag_color`, `announce_name_color`, `announce_message_color` | ArcEmu's `Color.Ann*Color` (1-10) | `2`, `1`, `4`, `10` |
| `rate_health`, `rate_mana`, `rate_rage_loss`, `rate_energy` | `Rate.Health`, `Rate.Mana`, `Rate.Rage.Loss`, `Rate.Energy` | `1` |
| `rate_rest_ingame`, `rate_rest_offline_in_tavern_or_city`, `rate_rest_offline_in_wilderness` | `Rate.Rest.*` | `1` |
| `rate_xp_explore` | `Rate.XP.Explore` | `1` |
| `rate_reputation_gain`, `rate_reputation_lowlevel_kill`, `rate_reputation_lowlevel_quest` | `Rate.Reputation.Gain`, `.LowLevel.Kill`, `.LowLevel.Quest` | `1`, `0.2`, `0.2` |
| `max_player_level` | `MaxPlayerLevel` | `60` |
| `movement_speed_check`, `movement_speed_tolerance`, `movement_speed_slack` | n/a (CMaNGOS leaves it to its anticheat module): allow this factor over running speed, plus these yards | `true`, `1.5`, `15` |
| `start_player_level`, `start_gm_level`, `start_player_money` | `StartPlayerLevel`, `GM.StartLevel`, `StartPlayerMoney` | `1`, `1`, `0` |
| `max_primary_trade_skill`, `trade_skill_gm_ignore_max_primary` | `MaxPrimaryTradeSkill`, `TradeSkill.GMIgnore.MaxPrimarySkillsCount` | `2`, `4` |
| `strict_player_names`, `min_player_name` | `StrictPlayerNames`, `MinPlayerName` | `0`, `2` |
| `char_delete_method`, `char_delete_min_level`, `mail_delivery_delay` | `CharDelete.Method`, `CharDelete.MinLevel`, `MailDeliveryDelay` | `0`, `0`, `3600` |
| `allowed_builds`, `mysql_library`, `idle_timeout`, `max_connections`, `log_level` | n/a | |

## Extracting client data

```sh
./bin/extractor -i "/path/to/WoW 1.12.1" -o /path/to/data   # writes data/dbc/*.dbc and data/maps/*.map
./bin/extractor -i "/path/to/WoW 1.12.1" -o /path/to/data -e 1   # maps only (-e 2: DBC files only)
./bin/extractor -i "/path/to/WoW 1.12.1" -o /path/to/data -e 4   # vmaps: buildings and doodads
```

The extractor follows CMaNGOS's `ad` extractor:

* It opens `model`, `dbc`, `terrain`, `patch` and `patch-2.MPQ` from the client's `Data` folder,
  and looks files up newest archive first, so patches win.
* It copies every `.dbc` named in the archives' listfiles unchanged. The output works for
  mangosd too.
* It checks that each file is a complete DBC, and skips one-byte placeholders that patches use
  for removed files.

* It converts every map's terrain tiles (`World\Maps\NAME\NAME_X_Y.adt`, as each map's WDT lists
  them) into `maps/MMMYYXX.map`: area flags, ground heights packed as CMaNGOS packs them, liquids
  and holes. The files are CMaNGOS's version "z1.4", so either extractor's output serves either
  server.

* With `-e 4` it extracts the buildings and doodads as CMaNGOS's `vmap_extractor` does, into
  `Buildings/`, and assembles them as its `vmap_assembler` does, into `vmaps/`: a tree over each
  map's models, a file per tile, and each model with trees over its groups and triangles
  (version "VMAP_7.0"). `Buildings/` is kept: CMaNGOS's mmap generator reads it.

A 1.12.1 client yields 158 DBC files in well under a second, 2429 map tiles of 44 maps (150 MB)
in about 13 seconds, and vmaps of 815 buildings and 3138 doodads, placed 505,837 times
(276 MB, with 152 MB of `Buildings/`), in about 30 seconds. The MPQ reader (`source/dmangos/mpq/`)
handles plain, encrypted, sector and single-unit files, compressed with zlib or PKWare DCL, which
are the encodings 1.12 data files use. Mmaps (paths) are not generated or read yet.

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
  timer.d                     IntervalTimer: periods of the update tick
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
  npchandlers.d               handlers: gossip, NPC texts, trainers, innkeepers, bankers, vendors
  npcdata.d                   gossip menus, texts, trainer and vendor lists from the world database
  itemhandlers.d              handlers: moving, equipping, banking and destroying items; buying, selling, repairs
  terrain.d                   the .map files: ground heights, areas, liquids per tile, and zones from them
  exploration.d               zones and areas from the map, explored areas, experience
  inventory.d                 items and bags, and CMaNGOS's rules for storing, equipping, swapping, saving them
  conditions.d                the conditions table: requirements of menus, lessons and wares
  commandtable.d              ArcEmu's GM command tables, row for row
  commands.d                  ArcEmu's command lookup, permission letters, messages, .modify fields
  gmactions.d                 what GM commands do to players: levels, speeds, items, skills, saving
  gmlevel0.d .. gmlevel3.d    GM commands from ArcEmu's Level0.cpp .. Level3.cpp
  gminstance.d                ArcEmu's InstanceCommands.cpp
  gmquest.d                   ArcEmu's QuestCommands.cpp (those quests support)
  gmdebug.d                   GM commands from debugcmds.cpp, RecallCommands.cpp, BattlegroundCommands.cpp
  ../cluster/                 several world servers as one (docs/CLUSTER.md): config.d, protocol.d (framing,
                              messages), link.d (a link between nodes), node.d (membership, fencing, routing),
                              regions.d and ownership.d (regions, leases, ids), sessions.d (one login per account)
  replication.d               replicas of other nodes' creatures, game objects and players
  migration.d                 objects moving to another node with their region (their state)
  fencing.d                   a cluster node writes nothing once its lease has lapsed
  clusterbridge.d             replication between the maps and the cluster's links
  ../metrics.d                tick, event loop and GC measurements
  ../loadgen/                 the load generator: headless clients (bot.d) and scenarios (main.d)
  map.d                       players, creatures and game objects on a map: cells, sight, broadcasting,
                              the tick that moves creatures
  motion.d                    creature movement generators (idle, wander, waypoints) and waypoint paths
  spline.d                    walks along a path in time, SMSG_MONSTER_MOVE and its create block part
  grid.d                      grid cells shared by maps and the spawn index
  creature.d, gameobject.d    creature_template/creature and gameobject_template/gameobject: the objects
  creatureai.d                creatures fighting: threat, chasing, evading, calling for help (CreatureAI)
  creaturecasting.d           creatures casting, fleeing, and what their scripts do (mixed into CreatureAI)
  eventai.d                   CMaNGOS's EventAI: creature_ai_scripts events, phases and actions
  dbscripts.d                 dbscripts_on_*: script steps run by the world at their delays
  combat.d, relations.d       melee formulas (the attack table, damage) and who may attack or help whom
  combathandlers.d            handlers: attack swings, melee against creatures and players, kills
  spellcast.d, spellhandlers.d  spell checks, targets and packets; casting, channels, effects, fishing
  auras.d, aurahandlers.d     auras: their fields, ticks, removal; applying them, cancelling them
  dynobject.d                 the spot of a persistent area aura (a dynamic object)
  death.d, corpse.d           dying, releasing, ghosts, the spirit healer, corpses and reclaiming them
  experience.d, loot.d        experience for kills and a group's share; loot tables, rolls, the loot window
  loothandlers.d              handlers: looting creatures, game objects and items; group loot
  gameobjecthandlers.d        handlers: using game objects (doors, chests, chairs, traps, quest objects)
  quests.d, questhandlers.d   quest_template and its givers; the quest log, objectives, rewards, sharing
  reputation.d                factions' standings (ReputationMgr); reputationhandlers.d: changes, rewards
  talenthandlers.d            talents learned and reset
  tradehandlers.d, duelhandlers.d  trading between players; duels
  mailhandlers.d              mail: sending, the mailbox, items and money, returns
  auctionhouse.d, auctionhandlers.d  auctions in the `auction` table; the auctioneer's handlers
  taxi.d, taxihandlers.d      flight paths: the network, known nodes, flying
  whisper.d, channelservice.d, groupservice.d  whispers, channels and groups across a cluster
  gmtargets.d                 what GM commands that name a player do to it, wherever it is simulated
  weather.d                   zones' weather from game_weather: its changes by season, SMSG_WEATHER
  online.d                    OnlinePlayer and Directory: what groups and channels see of players
  group.d                     groups: members, leaders, raids, the group list, member stats
  channel.d                   chat channels: members, owners, moderation, notices
  defines.d                   shared game constants (SharedDefines.h): classes, powers, item classes, slots
  packets.d                   world packet layouts and framing
  opcodes.d                   opcode and result code values (CMaNGOS names)
  crypt.d                     header encryption with the session key
  addons.d                    addon list parsing and SMSG_ADDON_INFO
  characters.d                character list entries (Player::BuildEnumData)
  playercreate.d              character creation (Player::Create): skills, spells, starting items;
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
source/dmangos/extractor/   the client data extractor: main.d, dbc.d (DBC files), maps.d (terrain to .map files),
                              vmaps.d and assembler.d (buildings and doodads to vmaps)
source/dmangos/vmap/        the vmap format and queries: math.d (G3D's), bih.d (the tree), model.d, maptree.d
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
* [docs/COMMANDS.md](docs/COMMANDS.md): the GM system, every ArcEmu command with its permission
  letter, which work yet, and where this server differs from ArcEmu.
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

Next: the cluster's remaining gaps.
See [docs/ROADMAP.md](docs/ROADMAP.md).
