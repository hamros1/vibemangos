/// State shared by every session on a world server.
module dmangos.world.context;

import core.time : Duration, MonoTime, msecs, seconds;

import std.path : buildPath;
import std.random : Random, unpredictableSeed;
import std.typecons : Nullable;

import dmangos.auth.accounts : AccountLevel;
import dmangos.auth.database : LoginDatabase, MemoryLoginDatabase;
import dmangos.cluster.node : SessionHandler;
import dmangos.cluster.ownership : IdCounters, IdKind, IdPool;
import dmangos.cluster.protocol : PresenceEntry;
import dmangos.world.whisper : WhisperFrom;
import dmangos.cluster.regions : Region;
import dmangos.world.creature : Creature, CreatureSpawn, Npc, NpcStandIn;
import dmangos.world.movement : Position;
import dmangos.world.migration : Migrant;
import dmangos.world.replication : Replicator;
import dmangos.world.channel : ChannelSettings;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.channelservice : channelCommand, ChannelOp, ChannelService;
import dmangos.cluster.protocol : ChannelCommand;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.creatureai : CreatureLore;
import dmangos.world.npcdata : BroadcastText;
import dmangos.world.spells : SpellInfo;
import dmangos.world.characterdb : DeleteOptions, GuidCounters;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : WorldConfig;
import dmangos.world.database : WorldDatabase;
import dmangos.vmap.maptree : ModelCache;
import dmangos.world.terrain : Terrain;
import dmangos.world.group : GroupDirectory, Groups, memberStatus, MemberStatus;
import dmangos.world.groupservice : groupCommand, GroupOp, GroupService;
import dmangos.cluster.protocol : GmRemote, GroupCommand;
import dmangos.world.map : Inhabitant, Map, MapObject, MapSettings;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.playercreate : CreationSettings;
import dmangos.world.worlddata : WorldData;

/// How a player simulated on another node than its client's talks to the other node (phase 4b).
interface PlayerRelay
{
    void toHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_);
    void toOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_);
    void disconnect(ushort owner, uint account);
    void migrate(ushort target, uint account, const(ubyte)[] state);
    void left(ushort home, uint account, bool toCharacterScreen);
    /// To the home: the player's simulation moved on from this node to `next`, a third node.
    void moved(ushort home, uint account, ushort next);
    /// The owner-side session of `account` is done (its player left the world or moved on).
    void remoteDone(uint account);
}

/// A player another node of the cluster simulates (phase 5), as its node described it.
struct RemotePlayer
{
    ushort node;
    PresenceEntry entry;
}

/// What a `PresenceEntry.flags` says of a player.
enum PresenceFlags : uint
{
    gmTag = 1,
    afk = 2,
    dnd = 4,
    permissions = 8,  /// it has GM permissions (understands every language, ignores factions)
}

/// Implemented by sessions so the context can kick a duplicate login.
interface Kickable
{
    /// Closes the session.
    void kick(string reason);

    /// The session may enter the world (at once standalone; in a cluster once the account is its: phase 3b).
    void admit();

    /// The client's address.
    @property string address() const;
}

/// A shutdown or restart counting down (`World::ShutdownServ`).
struct ShutdownTimer
{
    MonoTime at;        /// when the server stops
    bool restart;       /// stop with the restart exit code
    long lastAnnounced = long.max; /// seconds left at the last warning
}

/**
 * Configuration, databases, static data and the authenticated sessions.
 *
 * The server runs a single-threaded event loop, so none of this needs locking.
 */
final class WorldContext : GroupDirectory, IdCounters, SessionHandler, CreatureLore
{
    WorldConfig config;
    WorldDatabase database;
    WorldData data;
    ClientData client;

    /// Next free character, item and mail ids.
    GuidCounters next;

    /// Authenticated sessions by account id; one per account.
    private Kickable[uint] sessions;

    /// The maps that have players on them, by map id.
    private Map[uint] maps;
    private Terrain[uint] terrains;
    private ModelCache vmapModels;     // the buildings and doodads all maps share

    /// Players in the world, by guid and by lower-cased name.
    private OnlinePlayer[ulong] online;
    private OnlinePlayer[dstring] onlineByName;

    /// Parties and raids, online or not (`ObjectMgr`'s groups).
    Groups groups;

    /// The chat channels (on the coordinator; other nodes send it their players' commands).
    ChannelService channelService;

    /// This node is shutting down cleanly (a drain): players visiting it move on at once (phase 4b).
    bool draining;

    /// The rules of what changes groups (on the coordinator; other nodes send it their players' commands).
    GroupService groupService;

    /// Sends a group command to the coordinator; null standalone and on the coordinator.
    void delegate(const ref GroupCommand command) forwardGroup;

    /// Sends a packet to every other node's players (with `permission`, those who have it); null standalone.
    void delegate(ushort opcode, char permission, const(ubyte)[] body_) toEveryoneElsewhere;

    /// Sends a GM command to the node simulating its target; null standalone.
    void delegate(ushort node, const ref GmRemote command) gmRemote;

    /// Asks node `node` for its player `member`'s full stats, for `requester` here; null standalone.
    void delegate(ushort node, ulong requester, ulong member) requestMemberStats;

    private static struct Heard
    {
        ushort node;
        MonoTime at;
    }
    private Heard[ulong] lastHeard;   // players of other nodes by the node their last command came from
    private enum presenceGrace = 3.seconds; // presence says where a player is within a second or two

    /// Sends a channel command to the coordinator; null standalone and on the coordinator.
    void delegate(const ref ChannelCommand command) forwardChannel;

    /// Sends a packet to a player another node simulates; null standalone.
    void delegate(ushort node, ulong guid, ushort opcode, const(ubyte)[] body_) deliverRemote;

    /// Accounts and bans in the login database, as the login server manages them (GM commands).
    LoginDatabase accounts;

    /// A shutdown counting down, if any (`.server shutdown`).
    Nullable!ShutdownTimer shutdown;

    /// Set when the server stopped for a restart.
    bool restartRequested;

    /**
     * In a cluster, whether this node owns a cell of a map (docs/CLUSTER.md, phase 2); null when
     * standalone, where every cell is this server's.
     */
    bool delegate(uint map, ulong cell) ownsCell;

    /// In a cluster, where maps send replicas of their objects (phase 3); null when standalone.
    Replicator replicator;

    /// On a cluster member, the id blocks the coordinator handed out (phase 2); null otherwise.
    IdPool idPool;

    /**
     * In a cluster, where sessions are claimed when they start and released when they end (their
     * characters saved), so that an account plays on one node at a time (phase 3b); null standalone.
     */
    void delegate(uint account, ulong serial) claimSession, releaseSession;

    /// In a cluster, this node's id, and the node that owns a map's ground around a point (phase 4b):
    /// a player simulated here moves to the owner of where it stands. Null when standalone.
    ushort nodeId;
    ushort delegate(uint map, Position at, float radius) regionOwnerAround;
    PlayerRelay playerRelay; /// ditto

    void relayToHome(ushort home, uint account, ushort opcode, const(ubyte)[] body_)
    {
        playerRelay.toHome(home, account, opcode, body_);
    }

    void relayToOwner(ushort owner, uint account, ushort opcode, const(ubyte)[] body_)
    {
        playerRelay.toOwner(owner, account, opcode, body_);
    }

    void relayDisconnect(ushort owner, uint account)
    {
        playerRelay.disconnect(owner, account);
    }

    /// The session of an account on this node, if any.
    Kickable sessionOf(uint account)
    {
        return sessions.get(account, null);
    }

    /// Every session on this node.
    Kickable[] allSessions()
    {
        return sessions.values;
    }

    /// A player arrives from another node (phase 4b): in the lists of who is online, and on its map.
    void enterWorldMigrated(OnlinePlayer who, const(ulong)[] known)
    {
        import dmangos.world.worlddata : toLowerName;

        online[who.character.guid] = who;
        onlineByName[toLowerName(who.character.data.name)] = who;
        map(who.character.data.map).addMigrated(who, known);
    }

    /// A player's simulation leaves for node `next` (phase 4b): off the map and the lists, without a word.
    void leaveWorldForMigration(OnlinePlayer who, ushort next)
    {
        import dmangos.world.worlddata : toLowerName;

        map(who.character.data.map).removeForMigration(who, next);
        online.remove(who.character.guid);
        onlineByName.remove(toLowerName(who.character.data.name));
    }

    // Players other nodes simulate (phase 5): what each node said of its own.
    private RemotePlayer[ulong][ushort] remoteByNode;

    /**
     * Reserves limited vendor stock on the node simulating the creature (phase 5); `then` gets
     * whether it was there and what is left. Null standalone.
     */
    void delegate(ushort owner, uint map, ulong creature, uint item, uint maxCount, uint incrTime, uint buyCount,
        uint wanted, void delegate(bool reserved, uint left) then) reserveStock;

    /// Gives reserved stock back to the node simulating the creature (a purchase that did not complete).
    void delegate(ushort owner, uint map, ulong creature, uint item, uint maxCount, uint count) releaseStock;

    /// Sends a whisper to a player another node simulates, which checks it there; null standalone.
    void delegate(ushort node, ulong guid, WhisperFrom from, string text) whisperRemote;

    /// What node `node` said of its players: all of them (`full`), or what changed and who left.
    void presence(ushort node, bool full, const(PresenceEntry)[] entries, const(ulong)[] gone)
    {
        if (full)
            remoteByNode.remove(node);
        auto players = &remoteByNode.require(node, null);
        foreach (ref e; entries)
        {
            (*players)[e.guid] = RemotePlayer(node, e);
            lastHeard.remove(e.guid); // presence knows where it is now
        }
        foreach (guid; gone)
            (*players).remove(guid);
    }

    /// Node `node` is gone, and its players with it.
    void presenceLost(ushort node)
    {
        remoteByNode.remove(node);
        ulong[] stale;
        foreach (guid, ref hint; lastHeard)
            if (hint.node == node)
                stale ~= guid;
        foreach (guid; stale)
            lastHeard.remove(guid);
        channelService.nodeLost(node);
    }

    /// Every player other nodes simulate.
    RemotePlayer[] remotePlayers()
    {
        RemotePlayer[] all;
        foreach (node, players; remoteByNode)
            all ~= players.values;
        return all;
    }

    /// A player another node simulates, by guid; null if none.
    const(RemotePlayer)* remotePlayer(ulong guid)
    {
        foreach (node, ref players; remoteByNode)
            if (auto p = guid in players)
                return p;
        return null;
    }

    /// A player another node simulates, by name (any case); null if none.
    const(RemotePlayer)* remotePlayer(string name)
    {
        import dmangos.world.worlddata : toLowerName;

        const wanted = toLowerName(name);
        foreach (node, players; remoteByNode)
            foreach (ref p; players)
                if (toLowerName(p.entry.name) == wanted)
                    return &p;
        return null;
    }

    private ulong[Kickable] serials;   // each session's number on this node
    private ulong nextSerial = 1;

    /// When `update` last ran.
    private MonoTime lastUpdate;

    /// When the server started, in Unix time and on `MonoTime`'s clock.
    private long startUnixTime;
    private MonoTime startClock;

    /// Chooses creatures' models and levels.
    private Random spawnRandom;

    /// The most sessions that were online at once, for the `uptime` table.
    size_t peakSessions;

    /// Sessions authenticated since start-up (ArcEmu's `mAcceptedConnections`).
    size_t acceptedSessions;

    /// The time source sessions use (ping pacing); tests replace it.
    MonoTime delegate() clock;

    /// The configuration file, which `.server rehash` reads again; null when there is none (tests).
    string configPath;

    /// `command_overrides`: permission letters by full command name ("gm on").
    char[string] commandOverrides;

    /// Lines written to the GM command log (tests read them; the file gets them too).
    string[] gmLogLines;

    ///
    this(WorldConfig config, WorldDatabase database, WorldData data, ClientData client,
        LoginDatabase accounts = null)
    in (database !is null && data !is null && client !is null)
    {
        this.accounts = accounts is null ? new MemoryLoginDatabase : accounts;
        this.config = config;
        this.database = database;
        this.data = data;
        this.client = client;
        this.clock = () => MonoTime.currTime;
        {
            import dmangos.world.objects : updateCompression;

            updateCompression = config.compression;
        }
        this.spawnRandom = Random(unpredictableSeed);
        {
            import std.datetime.systime : Clock;

            startUnixTime = Clock.currTime.toUnixTime;
            startClock = MonoTime.currTime;
        }
        this.next = database.highestGuids();
        this.groups = new Groups(database, this, next.group);
        groupService = new GroupService(this);
        respawnAt = database.loadCreatureRespawns();
        groups.load(database.loadGroups());
        loadCommandOverrides();
        channelService = new ChannelService(this, client, ChannelSettings(config.allowTwoSideInteractionChannel));
    }

    /// `CommandTableStorage::Load`: the `command_overrides` setting.
    void loadCommandOverrides()
    {
        import dmangos.log : info, warning;
        import dmangos.world.commands : overrideTargets;

        commandOverrides = null;
        foreach (row; config.commandOverrides)
        {
            const paths = overrideTargets(row.command);
            if (paths.length == 0)
                warning!"command_overrides: no command '%s'"(row.command);
            foreach (path; paths)
            {
                commandOverrides[path] = row.group[0];
                info!"Changing command level of command `%s` to %s."(path, row.group[0]);
            }
        }
    }

    /// `sGMLog`: a line in the GM command log (`gm_command_log`), with the time in front.
    void writeGmLog(string line)
    {
        import dmangos.log : warning;
        import std.datetime.systime : SysTime;
        import std.file : append;
        import std.format : format;

        const now = SysTime.fromUnixTime(unixTime);
        const stamped = format!"[%04d-%02d-%02d %02d:%02d:%02d] %s"(now.year, now.month, now.day, now.hour,
            now.minute, now.second, line);
        gmLogLines ~= stamped;
        if (config.gmCommandLog.length)
        {
            try
                append(config.gmCommandLog, stamped ~ "\n");
            catch (Exception e)
                warning!"cannot write the GM command log %s: %s"(config.gmCommandLog, e.msg);
        }
    }

    /// Character creation settings from the configuration.
    @property CreationSettings creationSettings() const
    {
        return CreationSettings(config.startPlayerLevel, config.startGmLevel, config.startPlayerMoney,
            config.maxPrimaryTradeSkill, config.tradeSkillGmIgnoreMaxPrimary);
    }

    /// Character deletion settings from the configuration.
    @property DeleteOptions deleteOptions() const
    {
        return DeleteOptions(config.charDeleteMethod, config.charDeleteMinLevel, config.mailDeliveryDelay);
    }

    /// Unix time, moving with `clock` (so tests that replace the clock move it too).
    long unixTime()
    {
        return startUnixTime + (clock() - startClock).total!"seconds";
    }

    /// When the server started, in Unix time (`World::m_StartTime`).
    @property long startTime() const
    {
        return startUnixTime;
    }

    /// Milliseconds on the server's clock, as movement and create blocks carry them.
    uint serverTime()
    {
        return cast(uint)(clock() - MonoTime.init).total!"msecs";
    }

    /// The map `id`, created when its first player arrives.
    /// `TerrainManager::LoadTerrain`: a map's ground, from `data_dir`'s `.map` files.
    Terrain terrain(uint mapId)
    {
        if (vmapModels is null)
            vmapModels = new ModelCache(buildPath(config.dataDir, "vmaps"));
        return terrains.require(mapId, new Terrain(mapId, config.dataDir, client, vmapModels));
    }

    Map map(uint id)
    {
        if (auto found = id in maps)
            return *found;
        bool delegate(ulong) owns;
        if (ownsCell !is null)
            owns = (ulong cell) => ownsCell(id, cell);
        auto created = new Map(id, MapSettings(config.visibilityDistance, config.visibilityRelocationLimit),
            &serverTime, &spawnCell, terrain(id), owns);
        created.replicator = replicator;
        created.onCorpseRemoved = &corpseRemoved;
        created.groupOf = (ulong player) {
            auto group = groups.of(player);
            return group is null ? 0 : group.id;
        };
        return maps[id] = created;
    }

    /// The map `id` if it exists; null otherwise.
    Map existingMap(uint id)
    {
        return maps.get(id, null);
    }

    /**
     * What NPC services see of a map object (phase 5): a creature, or a stand-in for a replica of a
     * creature another node simulates; null for anything else.
     */
    Npc npcFor(MapObject object)
    {
        import dmangos.world.creature : NpcStandIn;
        import dmangos.world.replication : Replica;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

        if (auto creature = cast(Creature) object)
            return creature;
        auto replica = cast(Replica) object;
        if (replica is null || replica.fields.type != TypeId.unit)
            return null;
        const template_ = replica.fields[OBJECT_FIELD_ENTRY] in data.creatureTemplates;
        if (template_ is null)
            return null;
        if (auto standIn = replica.guid in standIns)
        {
            standIn.follow(replica);
            return *standIn;
        }
        return standIns[replica.guid] = new NpcStandIn(replica, template_);
    }

    private NpcStandIn[ulong] standIns; // by guid: the vendor stock they count lives on

    /// Every map that exists.
    Map[] allMaps()
    {
        return maps.values;
    }

    /**
     * The cluster moved regions (phase 2): what was lost leaves the maps, players near what was
     * gained see it load.
     */
    void regionsChanged(const(Region)[] gained, const(Region)[] lost, const(ubyte)[][uint] arriving,
        ref ubyte[][uint] leaving)
    {
        import dmangos.log : info;

        foreach (ref r; lost)
            if (auto m = r.map in maps)
            {
                if (r.next) // moving to another node: its objects go along (phase 4)
                {
                    const before = m.objectCount - m.replicaCount;
                    leaving[r.id] = cast(ubyte[]) m.migrateOut((ulong cell) => r.rect.containsKey(cell), r.next,
                        &saveMigrant);
                    info!"migration: region %s leaves for node %s with %s objects (%s KiB)"(r.id, r.next,
                        before - (m.objectCount - m.replicaCount), leaving[r.id].length / 1024);
                }
                else
                    m.release((ulong cell) => r.rect.containsKey(cell));
            }
        // Every arrival first: a map that looks around for gained cells would otherwise spawn afresh what is
        // still on its way in another region's bundle.
        foreach (ref r; gained)
            if (auto objects = r.id in arriving)
            {
                auto m = map(r.map);
                const before = m.objectCount - m.replicaCount;
                m.migrateIn(*objects, &restoreMigrant);
                info!"migration: region %s arrived with %s objects"(r.id, m.objectCount - m.replicaCount - before);
            }
        bool[uint] looked;
        foreach (ref r; gained)
            if (r.map !in looked)
            {
                looked[r.map] = true;
                if (auto m = r.map in maps)
                    m.ownershipGained();
            }
    }

    /// `IdCounters.take`: a block of ids for a cluster member, from this server's counters.
    uint take(IdKind kind, uint count)
    {
        auto counter = counterOf(kind);
        const first = *counter;
        *counter += count;
        return first;
    }

    /**
     * Phase 7: this node has become the coordinator: ids come from its counters from now on, raised
     * to what the database holds (what the old coordinator and the members saved).
     */
    void takeOverIds()
    {
        idPool = null;
        const saved = database.highestGuids();
        raise(IdKind.character, saved.character);
        raise(IdKind.item, saved.item);
        raise(IdKind.mail, saved.mail);
        raise(IdKind.group, saved.group);
        if (groups.nextId < next.group)
            groups.nextId = next.group;
    }

    /// `IdCounters.raise`: a member holds ids up to `atLeast`; they are not handed out again.
    void raise(IdKind kind, uint atLeast)
    {
        auto counter = counterOf(kind);
        if (*counter < atLeast)
            *counter = atLeast;
    }

    private uint* counterOf(IdKind kind) return
    {
        final switch (kind)
        {
        case IdKind.character: return &next.character;
        case IdKind.item: return &next.item;
        case IdKind.mail: return &next.mail;
        case IdKind.group: return &groups.nextId; // the groups keep their own counter
        }
    }

    /**
     * The creatures and game objects of one cell (`ObjectGridLoader`): each spawn's object, with a
     * level and model chosen, its addon, equipment and model data looked up.
     */
    MapObject[] spawnCell(uint mapId, ulong cell)
    {
        import dmangos.world.gameobject : GameObject;

        MapObject[] spawned;
        if (auto cells = mapId in data.creatureCells)
            foreach (index; (*cells).get(cell, null))
            {
                if (awaitingRespawn(data.creatureSpawns[index].guid))
                    continue; // dead: it comes back when its time is up
                if (auto creature = makeCreature(&data.creatureSpawns[index]))
                    spawned ~= creature;
            }
        if (auto cells = mapId in data.gameObjectCells)
            foreach (index; (*cells).get(cell, null))
            {
                const spawn = &data.gameObjectSpawns[index];
                spawned ~= new GameObject(*spawn, spawn.entry in data.gameObjectTemplates);
            }
        return spawned;
    }

    /**
     * A creature from its spawn (`Creature::Create`): a level and model chosen, its addon, equipment
     * and model data looked up, and its movement generator; null if its template has no model.
     */
    Creature makeCreature(const(CreatureSpawn)* spawn)
    {
        import dmangos.world.creature : chooseDisplay, chooseLevel, classStatsKey, CreatureParts, VirtualItem;
        import dmangos.world.motion : selectMovement;

        const template_ = spawn.entry in data.creatureTemplates;
        const display = chooseDisplay(*template_, spawnRandom);
        if (display == 0)
            return null;
        CreatureParts parts;
        const level = chooseLevel(*template_, spawnRandom);
        if (const stats = classStatsKey(level, template_.unitClass) in data.creatureClassStats)
        {
            parts.classStats = *stats;
            parts.hasClassStats = true;
        }
        parts.addon = spawn.guid in data.creatureAddons;
        if (parts.addon is null)
            parts.addon = spawn.entry in data.creatureTemplateAddons;
        if (const model = display in data.models)
        {
            parts.boundingRadius = model.boundingRadius;
            parts.combatReach = model.combatReach;
            parts.gender = model.gender;
        }
        parts.collisionHeight = client.collisionHeight(display);
        if (const equipment = template_.equipmentTemplateId in data.creatureEquipment)
            foreach (slot, entry; *equipment)
                if (const item = entry in data.items)
                    parts.equipment[slot] = VirtualItem(item.displayId, cast(ubyte) item.itemClass,
                        cast(ubyte) item.subClass, cast(ubyte) item.details.material, item.inventoryType,
                        cast(ubyte) item.details.sheath);
        auto creature = new Creature(*spawn, template_, display, level, parts, client);
        creature.generator = selectMovement(creature, data.waypoints);
        if (auto events = data.eventAi.eventsOf(spawn.entry, spawn.guid))
            creature.ai.setScript(events, data.eventAi, this);
        return creature;
    }

    // -----------------------------------------------------------------------
    // What creatures' scripts need (`CreatureLore`)
    // -----------------------------------------------------------------------

    /// See `CreatureLore`.
    const(SpellInfo)* spellInfo(uint id)
    {
        return data.spells.spell(id);
    }

    /// ditto
    @property const(ClientData) clientData()
    {
        return client;
    }

    /// ditto
    const(BroadcastText)* broadcastText(uint id)
    {
        return id in data.npcs.broadcastTexts;
    }

    /// ditto
    float listenRange(ChatType type)
    {
        switch (type)
        {
        case ChatType.CHAT_MSG_MONSTER_YELL:
            return config.listenRangeYell;
        case ChatType.CHAT_MSG_MONSTER_EMOTE:
            return config.listenRangeTextEmote;
        default:
            return config.listenRangeSay;
        }
    }

    // -----------------------------------------------------------------------
    // Migration (docs/CLUSTER.md, phase 4)
    // -----------------------------------------------------------------------

    /// An object's state for its next owner.
    Migrant saveMigrant(MapObject object)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : MigrantKind;

        ByteWriter w;
        if (auto creature = cast(Creature) object)
        {
            creature.saveState(w);
            return Migrant(MigrantKind.creature, creature.spawn.guid, 0, w.data);
        }
        auto gameObject = cast(GameObject) object;
        gameObject.saveState(w);
        return Migrant(MigrantKind.gameObject, gameObject.spawn.guid, 0, w.data);
    }

    /// An object rebuilt from its spawn and the state its last owner sent; null if the spawn is unknown here.
    MapObject restoreMigrant(const ref Migrant m)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : warning;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : MigrantKind;

        if (spawnIndex is null)
        {
            foreach (i, ref s; data.creatureSpawns)
                spawnIndex[s.guid] = i;
            foreach (i, ref s; data.gameObjectSpawns)
                gameObjectSpawnIndex[s.guid] = i;
        }
        auto r = ByteReader(m.state);
        if (m.kind == MigrantKind.creature)
        {
            const at = m.spawn in spawnIndex;
            if (at is null)
                return null;
            auto creature = makeCreature(&data.creatureSpawns[*at]);
            if (creature is null)
                return null;
            creature.loadState(r);
            return creature;
        }
        const at = m.spawn in gameObjectSpawnIndex;
        if (at is null)
        {
            warning!"migration: game object spawn %s is not known here"(m.spawn);
            return null;
        }
        const spawn = &data.gameObjectSpawns[*at];
        auto gameObject = new GameObject(*spawn, spawn.entry in data.gameObjectTemplates);
        gameObject.loadState(r);
        return gameObject;
    }

    private size_t[uint] spawnIndex, gameObjectSpawnIndex; // spawn guid -> its place in the world data

    /// Puts a player in the world: on its map and in the lists of who is online.
    void enterWorld(OnlinePlayer who)
    in (who.character.guid !in online, "a character is in the world once")
    {
        import dmangos.world.worlddata : toLowerName;

        online[who.character.guid] = who;
        onlineByName[toLowerName(who.character.data.name)] = who;
        map(who.character.data.map).add(who);
    }

    /// A player in the world was renamed (`.character rename`): it is found by its new name.
    void renamed(OnlinePlayer who, string oldName)
    {
        import dmangos.world.worlddata : toLowerName;

        onlineByName.remove(toLowerName(oldName));
        onlineByName[toLowerName(who.character.data.name)] = who;
    }

    /// Takes a player out of the world.
    void leaveWorld(OnlinePlayer who)
    {
        import dmangos.world.worlddata : toLowerName;

        if (who.character.guid !in online)
            return;
        auto current = map(who.character.data.map);
        if (current.find(who.character.guid) !is null)
            current.remove(who);
        online.remove(who.character.guid);
        onlineByName.remove(toLowerName(who.character.data.name));
    }

    /// The player in the world with this guid, or null.
    OnlinePlayer onlinePlayer(ulong guid)
    {
        return online.get(guid, null);
    }

    /// The player in the world with this name (any case), or null.
    OnlinePlayer onlinePlayer(string name)
    {
        import dmangos.world.worlddata : toLowerName;

        return onlineByName.get(toLowerName(name), null);
    }

    /// Every player in the world.
    OnlinePlayer[] onlinePlayers()
    {
        return online.values;
    }

    /**
     * A packet for every player in the world, on every node (`World::SendGlobalMessage`); with
     * `permission`, only for those with that GM permission letter.
     */
    void toEveryone(Opcode opcode, const(ubyte)[] body_, char permission = 0)
    {
        deliverToOwn(opcode, body_, permission);
        if (toEveryoneElsewhere !is null)
            toEveryoneElsewhere(cast(ushort) opcode, permission, body_);
    }

    /// `toEveryone`, for this node's players only.
    void deliverToOwn(Opcode opcode, const(ubyte)[] body_, char permission = 0)
    {
        foreach (other; online)
            if (permission == 0 || other.canUseCommand(permission))
                other.deliver(opcode, body_);
    }

    // -----------------------------------------------------------------------
    // Dead creatures and their respawning
    // -----------------------------------------------------------------------

    /// Creatures that are dead now: spawn guid -> when they come back (Unix time), as `creature_respawn` has it.
    private long[uint] respawnAt;
    private MonoTime lastRespawnCheck;

    /// `Creature::SaveRespawnTime` (`SaveRespawnTimeImmediately`): a creature died; it comes back when it says.
    void creatureDied(Creature creature)
    {
        respawnAt[creature.spawn.guid] = creature.respawnAt;
        database.saveCreatureRespawn(creature.spawn.guid, creature.respawnAt);
    }

    /// A corpse went; one that died elsewhere (handed over dead: phase 4) comes back a respawn time from now.
    private void corpseRemoved(Creature creature)
    {
        if (creature.spawn.guid !in respawnAt)
        {
            respawnAt[creature.spawn.guid] = unixTime + creature.spawn.respawnSeconds;
            database.saveCreatureRespawn(creature.spawn.guid, respawnAt[creature.spawn.guid]);
        }
    }

    /// Whether a spawn is dead and waiting to come back.
    bool awaitingRespawn(uint spawnGuid)
    {
        if (auto at = spawnGuid in respawnAt)
            return *at > unixTime;
        return false;
    }

    /**
     * `Creature::Update` for the dead (`DEAD`): once a second, the creatures whose time has come are
     * made anew at their spawn point, on maps whose cell they spawn in is loaded (elsewhere they come
     * when it loads).
     */
    void respawnDue(MonoTime now)
    {
        import core.time : seconds;

        if (now - lastRespawnCheck < 1.seconds)
            return;
        lastRespawnCheck = now;
        const time = unixTime;
        uint[] due;
        foreach (guid, at; respawnAt)
            if (at <= time)
                due ~= guid;
        if (due.length == 0)
            return;
        if (spawnIndex is null)
            foreach (i, ref spawn; data.creatureSpawns)
                spawnIndex[spawn.guid] = i;
        foreach (guid; due)
        {
            respawnAt.remove(guid);
            database.saveCreatureRespawn(guid, 0);
            const index = guid in spawnIndex;
            if (index is null)
                continue;
            const spawn = &data.creatureSpawns[*index];
            auto there = existingMap(spawn.map);
            if (there is null || !there.cellLoaded(cellKeyAt(spawn.x, spawn.y)))
                continue;
            if (auto creature = makeCreature(spawn))
                there.addObject(creature);
        }
    }

    /// `GroupDirectory.local`
    OnlinePlayer local(ulong guid)
    {
        return onlinePlayer(guid);
    }

    /**
     * Sends a packet to a player online on any node (`GroupDirectory.deliverTo`): here, or to the node
     * presence says simulates it, or (until presence says) the node its last command came from.
     */
    bool deliverTo(ulong guid, Opcode opcode, const(ubyte)[] body_)
    {
        if (auto here = onlinePlayer(guid))
        {
            here.deliver(opcode, body_);
            return true;
        }
        if (deliverRemote is null)
            return false;
        if (auto remote = remotePlayer(guid))
        {
            deliverRemote(remote.node, guid, cast(ushort) opcode, body_);
            return true;
        }
        if (auto hint = guid in lastHeard)
            if (MonoTime.currTime - hint.at < presenceGrace && hint.node != nodeId)
            {
                deliverRemote(hint.node, guid, cast(ushort) opcode, body_);
                return true;
            }
        return false;
    }

    /// `GroupDirectory.statusOf`: online, away, busy, between maps; for another node's player, by presence.
    ubyte statusOf(ulong guid)
    {
        if (auto here = onlinePlayer(guid))
            return memberStatus(here);
        if (auto remote = remotePlayer(guid))
        {
            ubyte status = MemberStatus.online;
            if (remote.entry.flags & PresenceFlags.afk)
                status |= MemberStatus.afk;
            if (remote.entry.flags & PresenceFlags.dnd)
                status |= MemberStatus.dnd;
            return status;
        }
        if (auto hint = guid in lastHeard)
            if (MonoTime.currTime - hint.at < presenceGrace && hint.node != nodeId)
                return MemberStatus.online;
        return MemberStatus.offline;
    }

    /// A command from `guid` came from `node`: it is there, until presence says otherwise.
    void heardFrom(ulong guid, ushort node)
    {
        if (node != nodeId)
            lastHeard[guid] = Heard(node, MonoTime.currTime);
    }

    /// A group command of `who`'s, run by the coordinator's groups (here, standalone or on it).
    void groupCommand(const OnlinePlayer who, GroupOp op, ulong target = 0, string text = null,
        string text2 = null, uint number = 0, uint number2 = 0)
    {
        const command = .groupCommand(who, op, target, text, text2, number, number2);
        if (forwardGroup !is null)
            forwardGroup(command);
        else
            groupService.run(command, nodeId);
    }

    /// `GroupDirectory.seeEachOther`: both on the same map, and in sight of each other.
    bool seeEachOther(ulong a, ulong b)
    {
        auto first = onlinePlayer(a), second = onlinePlayer(b);
        if (first is null || second is null || first.character.data.map != second.character.data.map)
            return false;
        if (auto onMap = first.character.data.map in maps)
            return onMap.seeEachOther(a, b);
        return false;
    }

    /// A channel command of `who`'s, run by the coordinator's channels (here, standalone or on it).
    void channelCommand(const OnlinePlayer who, ChannelOp op, string channel, string arg = null,
        Language language = Language.LANG_UNIVERSAL)
    {
        const command = .channelCommand(who, op, channel, arg, language);
        if (forwardChannel !is null)
            forwardChannel(command);
        else
            channelService.run(command, nodeId);
    }

    /// Number of players in the world.
    @property size_t worldPopulation() const
    {
        return online.length;
    }

    /// The sessions of the account, or those connected from the address (`.kick`).
    Kickable sessionOfAccount(uint accountId)
    {
        return sessions.get(accountId, null);
    }

    /// ditto
    Kickable[] sessionsFrom(string address)
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        return sessions.byValue.filter!(session => session.address == address).array;
    }

    /**
     * Called every second by the server loop: counts a shutdown down, warning everyone at the times
     * `World::ShutdownMsg` does. Returns true when the server should stop.
     */
    bool update(MonoTime now)
    {
        import dmangos.world.packets : ServerMessageType, ServerServerMessage;
        import dmangos.world.map : packetBody;
        import dmangos.world.opcodes : Opcode;

        // World::Update: every player (a copy of the list: an update may log one out).
        const elapsed = lastUpdate == MonoTime.init || now < lastUpdate ? Duration.zero : now - lastUpdate;
        if (now > lastUpdate)
            lastUpdate = now;
        // A slow tick says where its time went (net/server.d warns about it).
        import dmangos.log : warning;
        const started = MonoTime.currTime;
        Duration slowestPlayer;
        ulong slowestGuid;
        foreach (player; online.values) // a copy: an update may log a player out
        {
            const guid = player.character.guid;
            const before = MonoTime.currTime;
            player.update(elapsed);
            if (MonoTime.currTime - before > slowestPlayer)
            {
                slowestPlayer = MonoTime.currTime - before;
                slowestGuid = guid;
            }
        }
        const playersDone = MonoTime.currTime;
        foreach (map_; maps)
            map_.update(elapsed);
        respawnDue(now);
        const mapsDone = MonoTime.currTime;
        if (mapsDone - started > 500.msecs)
            warning!"slow tick: %s ms in %s players (slowest %s ms, guid %s), %s ms in %s maps"(
                (playersDone - started).total!"msecs", online.length, slowestPlayer.total!"msecs", slowestGuid & 0xFFFF_FFFF,
                (mapsDone - playersDone).total!"msecs", maps.length);

        if (shutdown.isNull)
            return false;
        auto timer = &shutdown.get();
        const left = (timer.at - now).total!"seconds";
        if (left <= 0)
        {
            restartRequested = timer.restart;
            return true;
        }
        // Every 5 minutes, then every minute under 15, every 15 s under 5 minutes, every second under 15 s:
        // a warning whenever the time left enters a new step, however late this call comes.
        static long step(long seconds)
        {
            return seconds < 15 ? seconds : seconds < 5 * 60 ? 1000 + seconds / 15 : seconds < 15 * 60
                ? 2000 + seconds / 60 : 3000 + seconds / (5 * 60);
        }
        if (timer.lastAnnounced == long.max || step(left) != step(timer.lastAnnounced))
        {
            timer.lastAnnounced = left;
            const body_ = packetBody(ServerServerMessage(timer.restart ? ServerMessageType.restartTime
                : ServerMessageType.shutdownTime, durationText(left)));
            foreach (player; online)
                player.deliver(Opcode.SMSG_SERVER_MESSAGE, body_);
        }
        return false;
    }

    /// `secsToTimeString`: "1h 2m 3s", as the shutdown message shows it.
    static string durationText(long seconds) pure @safe
    {
        import std.format : format;

        string text;
        if (seconds >= 3600)
            text ~= format!"%sh "(seconds / 3600);
        if (seconds >= 60)
            text ~= format!"%sm "(seconds / 60 % 60);
        text ~= format!"%ss"(seconds % 60);
        return text;
    }

    /**
     * The next id of `kind`: from this server's counters, or on a cluster member from its blocks;
     * false if a member has none left (its next block has not come).
     */
    bool takeId(IdKind kind, out uint id)
    {
        if (idPool !is null)
            return idPool.take(kind, id);
        auto counter = counterOf(kind);
        id = (*counter)++;
        return true;
    }

    /// Allocates the next item guid; throws if a cluster member has none (rather than reuse one).
    uint nextItemGuid()
    {
        return takeIdOrThrow(IdKind.item);
    }

    /// Allocates the next mail id; throws if a cluster member has none.
    uint nextMailId()
    {
        return takeIdOrThrow(IdKind.mail);
    }

    private uint takeIdOrThrow(IdKind kind)
    {
        import std.conv : to;

        uint id;
        if (!takeId(kind, id))
            throw new Exception("no " ~ kind.to!string ~ " ids: the coordinator's next block has not come");
        return id;
    }

    /// Creatures and game objects on every map.
    @property size_t objectCount() const
    {
        size_t count;
        foreach (map_; maps)
            count += map_.objectCount;
        return count;
    }

    /// Number of authenticated sessions.
    @property size_t sessionCount() const
    {
        return sessions.length;
    }

    /// Registers an authenticated session, kicking any earlier one of the same account.
    void addSession(uint accountId, Kickable session)
    {
        if (auto previous = accountId in sessions)
            if (*previous !is session)
                previous.kick("logged in again from elsewhere");
        sessions[accountId] = session;
        ++acceptedSessions;
        if (sessions.length > peakSessions)
            peakSessions = sessions.length;
        const serial = serials[session] = nextSerial++;
        if (claimSession is null)
            session.admit();
        else
            claimSession(accountId, serial);
    }

    /**
     * Forgets a session, unless a newer one for the account has replaced it. In a cluster its
     * account is released, whether or not a newer one replaced it: the newer one waits for that.
     */
    void removeSession(uint accountId, Kickable session)
    {
        if (auto current = accountId in sessions)
            if (*current is session)
                sessions.remove(accountId);
        if (auto serial = session in serials)
        {
            if (releaseSession !is null)
                releaseSession(accountId, *serial);
            serials.remove(session);
        }
    }

    /// See `SessionHandler.sessionGranted`.
    void sessionGranted(uint account, ulong serial)
    {
        if (auto session = account in sessions)
            if (serials.get(*session, 0) == serial)
                session.admit();
    }

    /// See `SessionHandler.sessionEvicted`.
    void sessionEvicted(uint account, ulong serial)
    {
        foreach (session, s; serials)
            if (s == serial)
                return session.kick("logged in on another node of the realm");
    }

    /// Whether this server may write to the databases (false on a cluster node whose lease lapsed).
    bool canWrite()
    {
        import dmangos.world.fencing : FencedBase;

        if (auto fenced = cast(FencedBase) database)
            return fenced.writesAllowedNow;
        return true;
    }

    /// Ends every session (a cluster node whose lease lapsed: its writes are fenced, docs/CLUSTER.md phase 4).
    void kickAll(string reason)
    {
        foreach (session; sessions.values)
            session.kick(reason);
    }

    /// See `SessionHandler.claimAll`: every session of this node, again.
    void claimAll()
    {
        if (claimSession is null)
            return;
        foreach (account, session; sessions)
            if (auto serial = session in serials)
                claimSession(account, *serial);
    }
}

/// NPC services across nodes (phase 5): a replica of a creature is served through a stand-in.
unittest
{
    import dmangos.world.creature : CreatureParts, CreatureTemplate;
    import dmangos.world.replication : encodeState, Replica;
    import dmangos.world.testclient : newContext, newDatabase;
    import dmangos.world.testdata : testClientData;
    import dmangos.world.updatefields : UNIT_NPC_FLAGS;

    auto context = newContext(newDatabase());
    auto vendor = new CreatureTemplate;
    vendor.entry = 2046;
    vendor.minLevel = vendor.maxLevel = 10;
    vendor.modelId1 = 1;
    vendor.npcFlags = 4 | 4096; // vendor, repairs
    context.data.creatureTemplates[2046] = *vendor;
    auto spawn = CreatureSpawn(80339, 2046, 0, -9464, 88, 58, 0);
    CreatureParts parts;
    auto actual = new Creature(spawn, &context.data.creatureTemplates[2046], 1, 10, parts, testClientData());

    auto replica = new Replica(actual.guid, 2, encodeState(actual, 0));
    auto npc = context.npcFor(replica);
    assert(npc !is null && npc.npcTemplate.entry == 2046 && npc.spawnId == 80339);
    assert(npc.npcValues.get!UNIT_NPC_FLAGS == (4 | 4096) && npc.position == actual.position);
    assert(context.npcFor(replica) is npc, "one stand-in per creature: its vendor stock lasts");
    assert(context.npcFor(actual) is actual && context.npcFor(null) is null);
}
