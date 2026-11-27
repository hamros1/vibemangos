# Source layout

One dub package. Module names follow the directories, as in dub and D-Scanner.

```
dub.json                    configurations: authserver, worldserver, extractor and loadgen
config/                     example configuration
sql/                        fresh-install schema and realm seed
docs/                       architecture, design, developer guide, roadmap
tools/testclient.py         scripted 1.12.1 client for live tests
tools/setup-local.sh        import fresh databases and generate a two-node server config
source/dmangos/             code shared by every server
  bytes.d                     ByteReader / ByteWriter (little-endian, slicing, no copies)
  dbc.d                       DBC reader generated at compile time from per-file format strings
  mpq/                        MPQ archive reader: crypt.d (tables, hashing), explode.d (PKWare DCL), archive.d
  serialization.d             UDA-driven packet (de)serializer and wireSize, generated at compile time
  json.d                      struct <-> JSON mapping by introspection (configuration)
  hex.d                       hex <-> bytes, usable in CTFE (hexLiteral!"...")
  log.d                       leveled logger with compile-time checked format strings
  timer.d                     IntervalTimer: periods of the update tick
  crypto/                     SRP6, SHA-1 helpers, BigInt <-> little-endian, OS randomness
  mysql/                      run-time loaded MySQL C API binding; connection with compile-time checked queries
  net/                        epoll event loop, select elsewhere (server.d); compile-time packet dispatch (dispatch.d)
source/dmangos/script/      the scripting framework (docs/SCRIPTING.md): api.d (handles, events, contexts,
                              host interfaces), registry.d (UDAs, compile-time discovery, generated dispatch,
                              pools), schedule.d (timers as data), state.d (state saved by reflection),
                              escort.d (the escort component)
source/dmangos/scripts/     the gameplay scripts, one module per dungeon or area (deadmines.d, westfall.d,
                              stormwind.d, ungoro.d, shadowfang.d, wailingcaverns.d) and spells.d
source/dmangos/auth/        the login server
  main.d                      entry point: run the server, administer accounts
  protocol.d                  opcodes, result codes, every packet as a struct
  session.d                   per-client protocol state machine (sans-I/O)
  accounts.d                  accounts; the s/v/sessionkey encoding of the account table; decoy credentials
  database.d                  LoginDatabase interface and an in-memory implementation for tests
  mysqldb.d                   LoginDatabase on the realm database
  config.d                    configuration and validation
  realms.d                    realmlist rules: build checks, security levels, categories, refresh
  throttle.d                  per-IP brute-force protection
source/dmangos/world/       the world server
  main.d                      entry point
  session.d                   a client's connection: framing, encryption, handshake, ping, the character screen (sans-I/O)
  charscreen.d                handlers: character list, creation, deletion, entering the world
  inworld.d                   handlers: logout, movement and its check, queries, settings, chat, emotes
  teleport.d                  handlers and TeleportTo: near and far teleports, area triggers
  grouphandlers.d             handlers: invitations, raids, loot settings, icons, ready checks, rolls
  meetingstone.d              the meeting stones' queue (looking for group): roles, matching, packets
  channelhandlers.d           handlers: chat channels
  npchandlers.d               handlers: gossip, NPC texts, trainers, innkeepers, bankers, vendors
  npcdata.d                   gossip menus, texts, trainer and vendor lists from the world database
  itemhandlers.d              handlers: moving, equipping, banking and destroying items; buying, selling, repairs
  terrain.d                   the .map files: ground heights, areas, liquids per tile, and zones from them
  exploration.d               zones and areas from the map, explored areas, experience
  environment.d               breath, fatigue, lava, falling: mirror timers and environmental damage
  guardians.d                 a player's guardians (dragonlings, dummies, the sheep) and wild objects
  durability.d                wear by spells and death: points or shares, worn or carried (bags too)
  rituals.d                   Ritual of Summoning, meeting stones' summons, the summons request and answer
  homebind.d                  out of a dungeon a minute after leaving its group (SMSG_RAID_GROUP_ONLY)
  mounting.d                  riding: casts refused mounted, no melee, dismounting for objects and dungeons
  moveorders.d                speed, root, knockback, water walk, slow fall, hover orders and their acknowledgements
  inventory.d                 items and bags, and the rules for storing, equipping, swapping, saving them
  conditions.d                the conditions table: requirements of menus, lessons and wares
  commandtable.d              command names, arguments, help and permission declarations
  commands.d                  shared command lookup, argument parsing and dispatch
  chatstyle.d                 chat palettes and hyperlink formatting
  gmaccess.d                  staff role inspection and administration
  gmcontent.d                 saved creature links, AI tests and transport schedules
  gmactions.d                 shared actions for levels, speeds, items, skills and saving
  gmlearn.d, gmcheat.d, gmguild.d, gmwaypoint.d and other gm modules group handlers by task: each a
                              function taking the player who typed the command first, not a part of Character
  gmstate.d                   what a player's commands keep between one and the next (a waypoint draft, ...)
  gminstance.d                GM commands: .instance
  gmquest.d                   GM commands: .quest (those quests support)
  gmdebug.d                   GM commands: debugging, .recall, .battleground
  bgqueue.d                   the battleground queues (a cluster service): brackets, slots, invitations
  battleground.d              battleground copies and the players' battleground opcodes
  ../cluster/                 several world servers as one (docs/CLUSTER.md): config.d, protocol.d (framing,
                              messages), link.d (a link between nodes), node.d (membership, fencing, routing),
                              regions.d and ownership.d (regions, leases, ids), sessions.d (one login per account),
                              services.d (cluster services: docs/SERVICES.md)
  replication.d               replicas of other nodes' creatures, game objects and players
  migration.d                 objects moving to another node with their region (their state)
  fencing.d                   a cluster node writes nothing once its lease has lapsed
  writebehind.d               writes to the database from a thread of their own, through a log
  clusterbridge.d             replication between the maps and the cluster's links
  ../metrics.d                tick, event loop and GC measurements
  ../frozen.d                 static tables in memory the collector does not scan (StaticMap, the arena)
  ../plaindata.d              plain data: encoded as bytes, its layout described (writes, services)
  ../navigation.d             movement maps: Recast and Detour (thirdparty/) through a small C interface
  ../loadgen/                 the load generator: headless clients (bot.d) and scenarios (main.d)
  map.d                       players, creatures and game objects on a map: cells, sight, broadcasting,
                              the tick that moves creatures
  motion.d                    creature movement generators (idle, wander, waypoints) and waypoint paths
  spline.d                    walks along a path in time, SMSG_MONSTER_MOVE and its create block part
  grid.d                      grid cells shared by maps and the spawn index
  creature.d, gameobject.d    creature_template/creature and gameobject_template/gameobject: the objects
  creatureai.d                creatures fighting: threat, chasing, evading, calling for help (CreatureAI)
  creaturecasting.d           creatures casting, fleeing, and what their scripts do (mixed into CreatureAI)
  eventai.d                   EventAI: creature_ai_scripts events, phases and actions
  creaturescripting.d         a creature's D script: its events, schedules, state, and the host it acts through
  instancescripting.d         a dungeon copy's D script, saved in instance.data
  sessionscripting.d          the player's session as the host of spell and area trigger scripts
  social.d                    friends and ignore lists
  guild.d, guildhandlers.d    guilds: ranks, members and packets; charters, invitations, roster, chat
  pet.d, petai.d              pets: types, action bar, stats, tables, packets; following and fighting (in CreatureAI)
  pethandlers.d               a player's pet: taming, summoning, saving, its bar's commands, stables
  character.d                 a character in the world: the player and every gameplay handler group
  unit.d                      the rules every unit shares: UnitRef (a player or a creature), dealDamage
  pettests.d                  pets end to end (tests only)
  scripttests.d               the scripts in the world (tests only)
  dbscripts.d                 dbscripts_on_*: script steps run by the world at their delays
  combat.d, relations.d       melee formulas (the attack table, damage) and who may attack or help whom
  combathandlers.d            handlers: attack swings, melee against creatures and players, kills
  spellcast.d, spellhandlers.d  spell checks, targets and packets; casting, channels, effects, fishing
  auras.d, aurahandlers.d     auras: their fields, ticks, removal; applying them, cancelling them
  aurastate.d                 aura states (`UNIT_FIELD_AURASTATE`): what the client needs to allow a spell
  procs.d                     procs: what sets an aura off (`spell_proc_event`), and what it does
  classspells.d               the class abilities whose behaviour is code (CMaNGOS's spell-family cases)
  dynobject.d                 the spot of a persistent area aura (a dynamic object)
  death.d, corpse.d           dying, releasing, ghosts, the spirit healer, corpses and reclaiming them
  experience.d, loot.d        experience for kills and a group's share; loot tables, rolls, the loot window
  loothandlers.d              handlers: looting creatures, game objects and items; group loot
  gameobjecthandlers.d        handlers: using game objects (doors, chests, chairs, traps, quest objects)
  quests.d, questhandlers.d   quest_template and its givers; the quest log, objectives, rewards, sharing
  reputation.d                factions' standings; reputationhandlers.d: changes, rewards
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
  defines.d                   shared game constants: classes, powers, item classes, slots
  packets.d                   world packet layouts and framing
  opcodes.d                   opcode and result code values
  crypt.d                     header encryption with the session key
  addons.d                    addon list parsing and SMSG_ADDON_INFO
  characters.d                character list entries
  playercreate.d              character creation: skills, spells, starting items;
                              also the skills and spells re-learned at login
  player.d                    a character in the world: loading, item and player objects, saving
  stats.d                     derived stats: item bonuses, health, mana, armor, attack power, damage
  updatefields.d              the client's update field table; constants and per-type tables derived from it
  objects.d                   guids, update field values, SMSG_UPDATE_OBJECT blocks
  movement.d                  movement info and speeds
  queries.d                   item query and chat message bodies
  characterdb.d               character save and delete statements, incl. guild, group, auction, mail
  names.d                     character name rules
  clientdata.d                DBC records and the indexes derived from them
  spells.d                    spell_template, spell chains, spell-learn links
  spellmods.d                 spell modifiers (most talents): flat and percent changes to spells of a family
  testdata.d, testclient.d    test fixtures and a scripted client (unittest builds only)
  database.d                  login/characters database access; in-memory version for tests
  worlddata.d                 items, creatures, playercreateinfo_*, level stats from the world database
  realm.d                     realmlist/uptime registration
  config.d, context.d         configuration; state shared by sessions
  dungeons.d                  the dungeon copies this node hosts, their saved state and the binds to them
                              (`WorldContext.dungeons`)
  postoffice.d                mail posted outside a session, auctions over and old mail settled (`WorldContext.postOffice`)
  ships.d                     the ships at sea, the transport clock, and elevators' homes and paths (`WorldContext.fleet`)
source/dmangos/extractor/   the client data extractor: main.d, dbc.d (DBC files), maps.d (terrain to .map files),
                              vmaps.d and assembler.d (buildings and doodads to vmaps), mmaps.d (movement maps)
source/dmangos/vmap/        the vmap format and queries: math.d (vectors, boxes, rays), bih.d (the tree), model.d, maptree.d
```

Each program is a dub configuration with its own `main.d`, which the other configurations
exclude.
