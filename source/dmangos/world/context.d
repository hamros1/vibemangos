/**
 * The state every session on a world server shares: `WorldContext`.
 *
 * A world node has one `WorldContext`. It owns the configuration, the world and login databases
 * (and the write-behind writer), the static world and client data, the scripts, the authenticated
 * sessions and the players online, the maps with their terrain, the dungeon instances with their
 * binds, groups, guilds, battlegrounds, weather, shutdown countdown, and the cluster's view of this
 * node (its regions, the players other nodes simulate, the delegates that reach other nodes).
 *
 * It runs the world's tick (`update`): each map's players, creatures and game objects, then the
 * deaths, then what belongs to no one map (instances, scripts, weather, respawns, auctions, mail,
 * the honor week). It also makes creatures, pets, summons and spawns, and settles what happens
 * outside any session. The server loop is single-threaded, so none of this needs locking.
 */
module dmangos.world.context;

import dmangos.cluster.services : ServiceHost;
import dmangos.world.writebehind : Writer;
import core.time : Duration, minutes, MonoTime, msecs, seconds;

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
import dmangos.world.creature : Creature, CreatureParts, CreatureSpawn, CreatureTemplate, Npc, NpcStandIn, TempSpawn, TempSpawnType, VirtualItem;
import dmangos.world.gameobject : GameObject, GameObjectSpawn;
import dmangos.world.auctionhouse;
import dmangos.world.database : MailRecord;
import dmangos.world.movement : Position;
import dmangos.world.migration : Migrant;
import dmangos.world.replication : Replica, Replicator;
import dmangos.world.channel : ChannelSettings;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.channelservice : channelCommand, ChannelCall, ChannelOp, ChannelService, ChannelsHost;
import dmangos.world.battleground : Battlegrounds;
import dmangos.world.gameevents : GameEvents, scheduleFor;
import dmangos.world.creaturelinking : CreatureLink, inLinkRange, LinkFlag;
import dmangos.world.creatureai : LinkEvent;
import dmangos.world.objects : HighGuid, makeGuid;
import dmangos.world.unit : UnitKind;
import dmangos.world.bgqueue : battlegroundOfMap, BattlegroundQueue, BattlegroundQueueHost;
import dmangos.world.wareffort : WarEffort, WarEffortHost;
import dmangos.cluster.protocol : ChannelCommand;
import dmangos.world.opcodes : ChatType, Language, Opcode;
import dmangos.world.creatureai : CombatWorld, CreatureLore;
import dmangos.world.npcdata : BroadcastText;
import dmangos.world.spells : SpellInfo;
import dmangos.script.api : ActionResult, EntityRef, GameObjectHost, Location, QuestProgress, Waypoint;
import dmangos.script.registry : ScriptHandle, ScriptKind, ScriptRuntime;
import dmangos.scripts : scriptModules;
import dmangos.world.instancescripting : InstanceScript;
import dmangos.world.guild : Guilds, Guild, GuildRight;
import dmangos.world.characterdb : DeleteOptions, GuidCounters;
import dmangos.world.transports : ShipObject, mapAt, transportClock;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : WorldConfig;
import dmangos.world.database : WorldDatabase;
import dmangos.vmap.maptree : ModelCache;
import dmangos.world.terrain : Terrain;
import dmangos.world.group : GroupDirectory, Groups, memberStatus, MemberStatus;
import dmangos.world.groupservice : groupCommand, GroupOp, GroupService;
import dmangos.cluster.protocol : GmRemote, GroupCommand, KillShare, ScriptSignal;
import dmangos.world.map : Inhabitant, Map, MapObject, MapSettings, VisibilityFacts;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.playercreate : CreationSettings;
import dmangos.world.worlddata : EventCreature, EventMail, Ship, SpellListEntry, WorldData;

/// How a player simulated on another node than its client's talks to the other node.
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

/// A player another node of the cluster simulates, as its node described it.
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

    /// The session may enter the world (at once standalone; in a cluster once the account is its).
    void admit();

    /// The client's address.
    @property string address() const;
}

/// The phases of a tick, in their order (docs/DESIGN.md, step 4; `WorldContext.update`).
enum TickPhase : ubyte
{
    maps,   /// on each map: its players, then its creatures and game objects
    deaths, /// the creatures that died: their dungeon's scripts, their respawn
    world,  /// what belongs to no one map: dungeon copies, scripts, weather, respawns, auctions, mail
}

/// A shutdown or restart counting down.
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
    import dmangos.world.dbscripts : DbScriptRunner;

    mixin DbScriptRunner; // `dbscripts_on_*` under way

    import dmangos.world.weather : Weather;

    private Weather[uint] weathers; // by zone, while players are in it

    /**
     * The weather of `zone`, for a player entering it: its weather's `SMSG_WEATHER`
     * body (made and generated the first time), or fine weather where it has no `game_weather` row.
     */
    ubyte[] weatherFor(uint zone)
    {
        import dmangos.world.weather : fineWeatherPacket, seasonOf;

        if (auto w = zone in weathers)
            return w.packet();
        const chances = zone in data.weatherChances;
        if (chances is null)
            return fineWeatherPacket();
        Weather w;
        w.chances = *chances;
        w.regenerate(spawnRandom, seasonOf(unixTime));
        weathers[zone] = w;
        return weathers[zone].packet();
    }

    /// Each zone's weather changes when due, shown to the players in it; a zone
    /// nobody is in any more forgets its weather.
    private void updateWeathers(int diff)
    {
        import dmangos.world.opcodes : Opcode;
        import dmangos.world.weather : seasonOf;

        if (weathers.length == 0)
            return;
        foreach (zone; weathers.keys)
        {
            auto w = zone in weathers;
            w.timer -= diff;
            if (w.timer > 0)
                continue;
            w.timer = typeof(*w).init.timer;
            bool anyone;
            foreach (player; online.values)
                if (player.character !is null && player.character.data.zone == zone)
                    anyone = true;
            if (!anyone)
            {
                weathers.remove(zone);
                continue;
            }
            if (!w.regenerate(spawnRandom, seasonOf(unixTime)))
                continue;
            const body_ = w.packet();
            foreach (player; online.values)
                if (player.character !is null && player.character.data.zone == zone)
                    player.deliver(Opcode.SMSG_WEATHER, body_);
        }
    }

    /// The weather of `zone` now, if it has some (tests).
    package Weather* weatherOf(uint zone)
    {
        return zone in weathers;
    }

    WorldConfig config;
    WorldDatabase database;
    /// The thread `database` writes through (`dmangos.world.writebehind`); null: writes are immediate.
    Writer writer;
    /**
     * The cluster services this node hosts and calls (docs/SERVICES.md). Standalone, it hosts them all
     * (`startAllServices`); in a cluster, those whose regions it was granted (`regionsChanged`).
     */
    ServiceHost services;
    WorldData data;
    ClientData client;

    /// The guilds, all of them, as saved (`dmangos.world.guild`).
    Guilds guilds;

    /// The gameplay scripts (docs/SCRIPTING.md), found in `dmangos.scripts` at compile time.
    ScriptRuntime scripts;
    private InstanceScript[uint] instanceScripts; // by instance id: the scripts of the copies loaded here
    private InstanceScript[uint] worldScripts;    // open-world round 2: by map id, the continents' scripts here

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

    /// Parties and raids, online or not.
    Groups groups;

    /// The chat channels (on the coordinator; other nodes send it their players' commands).

    /// This node is shutting down cleanly (a drain): players visiting it move on at once.
    bool draining;

    /// The rules of what changes groups (on the coordinator; other nodes send it their players' commands).
    GroupService groupService;

    /// Sends a group command to the coordinator; null standalone and on the coordinator.
    void delegate(const ref GroupCommand command) forwardGroup;

    /// Sends a packet to every other node's players (with `permission`, those who have it); null standalone.
    void delegate(ushort opcode, char permission, const(ubyte)[] body_) toEveryoneElsewhere;

    /// Sends a GM command to the node simulating its target; null standalone.
    void delegate(ushort node, const ref GmRemote command) gmRemote;

    /// Sends a group member's share of a kill here to the node that simulates it; null when standalone.
    void delegate(ushort node, const ref KillShare share) killShareElsewhere;

    /// Asks node `node` for its player `member`'s full stats, for `requester` here; null standalone.
    void delegate(ushort node, ulong requester, ulong member) requestMemberStats;

    private static struct Heard
    {
        ushort node;
        MonoTime at;
    }
    private Heard[ulong] lastHeard;   // players of other nodes by the node their last command came from
    private enum presenceGrace = 3.seconds; // presence says where a player is within a second or two


    /// Sends a packet to a player another node simulates; null standalone.
    void delegate(ushort node, ulong guid, ushort opcode, const(ubyte)[] body_) deliverRemote;

    /// Accounts and bans in the login database, as the login server manages them (GM commands).
    LoginDatabase accounts;

    /// A shutdown counting down, if any (`.server shutdown`).
    Nullable!ShutdownTimer shutdown;

    /// Set when the server stopped for a restart.
    bool restartRequested;

    /**
     * In a cluster, whether this node owns a cell of a map (docs/CLUSTER.md); null when
     * standalone, where every cell is this server's.
     */
    bool delegate(uint map, ulong cell) ownsCell;

    /// In a cluster, where maps send replicas of their objects; null when standalone.
    Replicator replicator;

    /// On a cluster member, the id blocks the coordinator handed out; null otherwise.
    IdPool idPool;

    /**
     * In a cluster, where sessions are claimed when they start and released when they end (their
     * characters saved), so that an account plays on one node at a time; null standalone.
     */
    void delegate(uint account, ulong serial) claimSession, releaseSession;

    /// In a cluster, this node's id, and the node that owns a map's ground around a point:
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

    /// A player arrives from another node: in the lists of who is online, and on its map.
    void enterWorldMigrated(OnlinePlayer who, const(ulong)[] known)
    {
        import dmangos.world.worlddata : toLowerName;

        online[who.character.guid] = who;
        onlineByName[toLowerName(who.character.data.name)] = who;
        mapOf(who).addMigrated(who, known);
    }

    /// A player's simulation leaves for node `next`: off the map and the lists, without a word.
    void leaveWorldForMigration(OnlinePlayer who, ushort next)
    {
        import dmangos.world.worlddata : toLowerName;

        mapOf(who).removeForMigration(who, next);
        online.remove(who.character.guid);
        onlineByName.remove(toLowerName(who.character.data.name));
    }

    // Players other nodes simulate: what each node said of its own.
    private RemotePlayer[ulong][ushort] remoteByNode;

    /**
     * Reserves limited vendor stock on the node simulating the creature; `then` gets
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
        if (auto channels = channelService)
            channels.nodeLost(node);
    }

    /// The other nodes of the cluster that say who their players are (none standalone).
    ushort[] otherNodes()
    {
        return remoteByNode.keys;
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
    private long startUnixMillis; /// the same, to the millisecond (ships' schedules)
    private MonoTime startClock;

    /// Chooses creatures' models and levels.
    private Random spawnRandom;

    /// The most sessions that were online at once, for the `uptime` table.
    size_t peakSessions;

    /// Sessions authenticated since start-up.
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
        services = new ServiceHost;
        this.clock = () => MonoTime.currTime;
        {
            import dmangos.world.objects : updateCompression;

            updateCompression = config.compression;
        }
        this.spawnRandom = Random(unpredictableSeed);
        {
            import std.datetime.systime : Clock;

            const wall = Clock.currTime;
            startUnixTime = wall.toUnixTime;
            startUnixMillis = wall.toUnixTime!long * 1000 + wall.fracSecs.total!"msecs";
            startClock = MonoTime.currTime;
        }
        {
            import dmangos.world.gameobject : transportClockSource;

            transportClockSource = &transportNow;
        }
        this.next = database.highestGuids();
        this.groups = new Groups(database, this, next.group);
        groupService = new GroupService(this);
        respawnAt = database.loadCreatureRespawns();
        gameObjectRespawnAt = database.loadGameObjectRespawns();
        groups.load(database.loadGroups());
        guilds = new Guilds;
        guilds.load(database.loadGuilds());
        scripts = ScriptRuntime.of!scriptModules();
        reportScripts();
        signalSequence = ulong(startUnixTime) << 20; // above what an earlier run of this node sent
        loadInstances();
        loadCommandOverrides();
        // The cluster services this node can run (docs/SERVICES.md); standalone it runs them all at once.
        services.provide!BattlegroundQueueHost((const(ubyte)[]) => BattlegroundQueueHost(newBattlegroundQueue()));
        battlegrounds = new Battlegrounds(this);
        gameEvents = new GameEvents;
        data.npcs.conditions.eventActive = (uint id) => gameEvents.isActive(id);
        data.npcs.conditions.holidayActive = (uint holiday) => gameEvents.holidayActive(holiday);
        updateGameEvents(clock(), true); // before any cell loads, so its spawns follow the events now
        services.provide!ChannelsHost((const(ubyte)[]) => ChannelsHost(new ChannelService(this, client,
            ChannelSettings(config.allowTwoSideInteractionChannel))));
        services.provide!WarEffortHost(&newWarEffortHost);
        services.listen!(WarEffortHost, WarEffort)(&warEffortHeard); // before it starts: it tells as it does
        startAllServices();
    }

    /// The battleground copies this node runs.
    Battlegrounds battlegrounds;

    // -----------------------------------------------------------------------
    // Linked creatures (`dmangos.world.creaturelinking`)
    // -----------------------------------------------------------------------

    /// The spawn of creature spawn guid `guid`; null if unknown.
    private const(CreatureSpawn)* creatureSpawnOf(uint guid)
    {
        if (spawnIndex is null)
            foreach (i, ref spawn; data.creatureSpawns)
                spawnIndex[spawn.guid] = i;
        if (auto at = guid in spawnIndex)
            return &data.creatureSpawns[*at];
        return null;
    }

    /// The creatures on `m` linked to `master`, and their links.
    private Creature[] slavesOf(Map m, Creature master, out const(CreatureLink)*[] links)
    {
        Creature[] found;
        const links_ = data.creatureLinks;
        foreach (guid; links_.slavesOfGuid.get(master.spawnId, null))
            if (const spawn = creatureSpawnOf(guid))
                if (auto c = cast(Creature) m.findObject(makeGuid(HighGuid.unit, spawn.entry, guid)))
                {
                    found ~= c;
                    links ~= guid in links_.bySlaveGuid;
                }
        const entries = links_.slaveEntriesOf.get(master.template_.entry, null);
        if (entries.length)
        {
            const ms = master.spawn;
            foreach (c; m.creaturesNear(Position(ms.x, ms.y, ms.z), 120))
                foreach (entry; entries)
                    if (c.template_.entry == entry && c !is master)
                        if (auto l = links_.linkOf(c.spawnId, entry, m.id))
                            if (l.masterEntry == master.template_.entry && inLinkRange(c.spawn.x, c.spawn.y, ms.x, ms.y, l.range))
                            {
                                found ~= c;
                                links ~= l;
                            }
        }
        return found;
    }

    /// The master of `slave` on `m`, if it is here, and the link.
    private Creature masterOf(Map m, Creature slave, out const(CreatureLink)* link)
    {
        link = data.creatureLinks.linkOf(slave.spawnId, slave.template_.entry, m.id);
        if (link is null)
            return null;
        if (link.masterGuid)
        {
            if (const spawn = creatureSpawnOf(link.masterGuid))
                return cast(Creature) m.findObject(makeGuid(HighGuid.unit, spawn.entry, link.masterGuid));
            return null;
        }
        const ss = slave.spawn;
        foreach (c; m.creaturesNear(Position(ss.x, ss.y, ss.z), link.range ? link.range : 120))
            if (c.template_.entry == link.masterEntry && inLinkRange(ss.x, ss.y, c.spawn.x, c.spawn.y, link.range))
                return c;
        return null;
    }

    /// `source` was attacked by `enemy` or evades: its linked creatures follow (see the module).
    private void linkedEvent(Map m, Creature source, LinkEvent event, ulong enemy)
    {
        if (!data.creatureLinks.involves(source.spawnId, source.template_.entry))
            return;
        const(CreatureLink)*[] links;
        auto slaves = slavesOf(m, source, links);
        foreach (i, slave; slaves)
        {
            if (event == LinkEvent.evade && !slave.alive && (links[i].flags & LinkFlag.respawnOnEvade))
                respawnLinked(m, slave);
            if (!slave.alive || slave.ai is null)
                continue;
            final switch (event)
            {
            case LinkEvent.aggro:
                if (links[i].flags & LinkFlag.aggroOnAggro)
                    joinFight(m, slave, enemy);
                break;
            case LinkEvent.despawn:
                if (links[i].flags & LinkFlag.despawnOnDespawn)
                    slave.ai.despawnFor(m, 0);
                break;
            case LinkEvent.evade:
                if (links[i].flags & LinkFlag.despawnOnEvade)
                    slave.ai.despawnFor(m, 0);
                else if (links[i].flags & LinkFlag.evadeOnEvade)
                    slave.ai.evadeWithLinked(m);
                break;
            }
        }
        if (event == LinkEvent.evade)
            respawnLinkedSpawns(m, source, LinkFlag.respawnOnEvade);
        // The other way: a slave attacked brings its master in; a slave evading brings its dead master back.
        const(CreatureLink)* link;
        if (auto master = masterOf(m, source, link))
        {
            if (event == LinkEvent.aggro && (link.flags & LinkFlag.toAggroOnAggro) && master.alive && master.ai !is null)
                joinFight(m, master, enemy);
            if (event == LinkEvent.evade && (link.flags & LinkFlag.toRespawnOnEvade) && !master.alive)
                respawnLinked(m, master);
        }
    }

    /**
     * A dead creature of a pack comes back now: its corpse goes and its respawn is due at once (the next
     * second's respawns bring it). Summons and dungeon creatures are left alone.
     */
    private void respawnLinked(Map m, Creature c)
    {
        if (c.alive || c.summon.type != TempSpawnType.none || c.petOwner)
            return;
        if (c.instanceId)
            return respawnInCopy(m, &c.spawn, c);
        if (m.findObject(c.guid) is c)
            m.corpseExpired(c);
        respawnSpawnNow(c.spawn.guid);
    }

    /// Instance round 2: a dead creature of dungeon copy `m` (its corpse `corpse`, or none: gone already) is back
    /// now, as a linked boss's wipe brings its adds back; the copy's script hears of it as of any creature.
    private void respawnInCopy(Map m, const(CreatureSpawn)* spawn, Creature corpse)
    {
        if (corpse !is null && m.findObject(corpse.guid) is corpse)
            m.corpseExpired(corpse);
        if (auto state = m.instanceId in instances)
            if (state.dead.remove(spawn.guid))
                database.deleteInstanceRespawn(spawn.guid, m.instanceId);
        if (m.findObject(makeGuid(HighGuid.unit, spawn.entry, spawn.guid)) !is null)
            return;
        auto back = makeCreature(spawn);
        if (back is null)
            return;
        back.instanceId = m.instanceId;
        m.addObject(back);
        if (auto script = m.instanceId in instanceScripts)
        {
            import dmangos.script.api : CreatureLoaded, EntityRef;

            script.raise(CreatureLoaded(EntityRef(back.guid)));
        }
    }

    /// Spawn `guid`, dead and waiting, is due now.
    private void respawnSpawnNow(uint guid)
    {
        if (auto at = guid in respawnAt)
            if (*at > unixTime)
            {
                *at = unixTime;
                database.saveCreatureRespawn(guid, unixTime);
            }
    }

    /// The slaves (by spawn) of `master` linked with `flag` whose corpses are already gone come back too.
    private void respawnLinkedSpawns(Map m, Creature master, LinkFlag flag)
    {
        foreach (guid; data.creatureLinks.slavesOfGuid.get(master.spawnId, null))
            if (const l = guid in data.creatureLinks.bySlaveGuid)
                if (l.flags & flag)
                    if (const spawn = creatureSpawnOf(guid))
                        if (m.findObject(makeGuid(HighGuid.unit, spawn.entry, guid)) is null)
                        {
                            if (master.instanceId)
                            {
                                // In a copy only the dead come back (one not loaded yet is not dead).
                                if (auto state = master.instanceId in instances)
                                    if (guid in state.dead)
                                        respawnInCopy(m, spawn, null);
                            }
                            else
                                respawnSpawnNow(guid);
                        }
    }

    /// `master` has respawned: its dead slaves linked so come back with it, and those linked so go.
    private void linkedRespawn(Map m, Creature master)
    {
        if (!data.creatureLinks.involves(master.spawnId, master.template_.entry))
            return;
        const(CreatureLink)*[] links;
        foreach (i, slave; slavesOf(m, master, links))
        {
            if (!slave.alive && (links[i].flags & LinkFlag.respawnOnRespawn))
                respawnLinked(m, slave);
            else if (slave.alive && (links[i].flags & LinkFlag.despawnOnRespawn) && slave.ai !is null)
                slave.ai.despawnFor(m, 0);
        }
        respawnLinkedSpawns(m, master, LinkFlag.respawnOnRespawn);
    }

    /// `c` fights `enemy` too: attacking it, or (fighting already) counting it as a threat.
    private void joinFight(Map m, Creature c, ulong enemy)
    {
        auto who = m.unit(enemy);
        if (who.kind == UnitKind.none)
            return;
        c.ai.joinLinkedFight(who, m);
    }

    /// `master` dies: its slaves that die or go with it do.
    private void linkedDeath(Map m, Creature master)
    {
        if (!data.creatureLinks.involves(master.spawnId, master.template_.entry))
            return;
        const(CreatureLink)*[] links;
        foreach (i, slave; slavesOf(m, master, links))
        {
            if (!slave.alive)
            {
                if (links[i].flags & LinkFlag.respawnOnDeath)
                    respawnLinked(m, slave);
                continue;
            }
            if (links[i].flags & LinkFlag.selfKillOnDeath)
            {
                import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

                slave.values.set!UNIT_FIELD_HEALTH(0u);
                m.creatureDeath(slave);
            }
            else if ((links[i].flags & LinkFlag.despawnOnDeath) && slave.ai !is null)
                slave.ai.despawnFor(m, 0);
        }
    }

    /// A spawned creature of a pack waits to be linked (once its cell holds it).
    private void queueLinked(uint mapId, uint instance, Creature c)
    {
        if (!data.creatureLinks.involves(c.spawnId, c.template_.entry) && c.spawnId !in data.formationSlots)
            return;
        linkSpawned ~= c;
        linkSpawnedOn ~= instance ? map(mapId, instance) : map(mapId);
    }

    /**
     * In a dungeon copy, a slave (by spawn) that waits on its master: `cantSpawnIfBossDead` while its master
     * is dead, `cantSpawnIfBossAlive` while it lives.
     */
    private bool cantSpawnWhileBossDead(const ref CreatureSpawn spawn, const(InstanceState)* state)
    {
        if (state is null)
            return false;
        if (const l = spawn.guid in data.creatureLinks.bySlaveGuid)
        {
            const bossDead = (l.masterGuid in state.dead) !is null;
            return ((l.flags & LinkFlag.cantSpawnIfBossDead) && bossDead)
                || ((l.flags & LinkFlag.cantSpawnIfBossAlive) && !bossDead);
        }
        return false;
    }

    /// Creatures just spawned that may follow or be followed: worked out once their cell holds them.
    private Creature[] linkSpawned;
    private Map[] linkSpawnedOn;

    /// Each spawned creature of a pack follows its master (`follow`), and a master's followers follow it.
    private void linkFollowers()
    {
        if (linkSpawned.length == 0)
            return;
        auto spawned = linkSpawned, maps_ = linkSpawnedOn;
        linkSpawned = null;
        linkSpawnedOn = null;
        foreach (i, c; spawned)
        {
            auto m = maps_[i];
            if (!c.alive || m.findObject(c.guid) !is c)
                continue;
            if (const slot = c.spawnId in data.formationSlots)
            {
                arrangeFormation(m, (*slot)[0]);
                continue;
            }
            const(CreatureLink)* link;
            if (auto master = masterOf(m, c, link))
                if (link.flags & LinkFlag.follow)
                    follow(m, c, master);
            const(CreatureLink)*[] links;
            foreach (j, slave; slavesOf(m, c, links))
                if (links[j].flags & LinkFlag.follow)
                    follow(m, slave, c);
        }
    }

    private uint[][uint] formationMembers; // group -> member spawns, by slot

    /**
     * Formation `group`'s members on `m`: its leader (slot 0) walks the formation's path; the others take
     * their places around it in slot order (`formationPlace`), and follow it.
     */
    private void arrangeFormation(Map m, uint group)
    {
        import std.algorithm.sorting : sort;
        import dmangos.world.creaturelinking : formationPlace;
        import dmangos.world.motion : FollowMovement, WaypointMovement;

        if (formationMembers is null)
        {
            uint[2][][uint] bySlot;
            foreach (guid, gs; data.formationSlots)
                bySlot[gs[0]] ~= [gs[1], guid];
            foreach (g, list; bySlot)
            {
                list.sort!((a, b) => a[0] < b[0]);
                foreach (e; list)
                    formationMembers[g] ~= e[1];
            }
        }
        const f = group in data.formations;
        if (f is null)
            return;
        Creature find(uint guid)
        {
            if (const spawn = creatureSpawnOf(guid))
                return cast(Creature) m.findObject(makeGuid(HighGuid.unit, spawn.entry, guid));
            return null;
        }
        const members = formationMembers.get(group, null);
        if (members.length == 0)
            return;
        auto leader = find(members[0]);
        if (leader is null || !leader.alive)
            return;
        if (f.pathId && cast(WaypointMovement) leader.generator is null && (leader.ai is null || !leader.ai.inCombat))
            if (const path = data.waypoints.path(f.pathId))
            {
                leader.generator = new WaypointMovement(path, f.movementType == 4);
                m.wake(leader.guid);
            }
        uint index;
        foreach (guid; members[1 .. $])
        {
            auto c = find(guid);
            if (c is null || !c.alive)
                continue;
            ++index;
            if (c.ai !is null && c.ai.inCombat)
                continue;
            float distance, angle;
            formationPlace(*f, index, cast(uint) members.length, distance, angle);
            if (auto following = cast(FollowMovement) c.generator)
                if (following.leader == leader.guid && following.distance == distance && following.angle == angle)
                    continue;
            c.generator = new FollowMovement(leader.guid, distance, angle);
            m.wake(c.guid);
        }
    }

    /// `slave` follows `master` (not while fighting), at their spawns' distance and angle.
    private void follow(Map m, Creature slave, Creature master)
    {
        import std.math : atan2, sqrt;
        import dmangos.world.motion : FollowMovement;

        if (!slave.alive || !master.alive || (slave.ai !is null && slave.ai.inCombat))
            return;
        if (auto f = cast(FollowMovement) slave.generator)
            if (f.leader == master.guid)
                return;
        const s = slave.spawn, ms = master.spawn;
        const dx = s.x - ms.x, dy = s.y - ms.y;
        const distance = sqrt(dx * dx + dy * dy);
        slave.generator = new FollowMovement(master.guid, distance, atan2(dy, dx) - ms.orientation);
        m.wake(slave.guid);
    }

    /// The game events, and which are active (`dmangos.world.gameevents`).
    GameEvents gameEvents;
    private MonoTime gameEventsChecked;
    private long scheduledDay; // the day the events' dates were last worked out for

    /// Whether creature spawn `guid` is in the world as its game event (if any) stands.
    bool creatureInEvents(uint guid)
    {
        if (const e = guid in data.creatureGameEvents)
            return gameEvents.spawnIn(*e);
        return true;
    }

    /// Whether game object spawn `guid` is in the world as its game event (if any) stands, or as the war
    /// effort does (its piles of supplies).
    bool gameObjectInEvents(uint guid)
    {
        import dmangos.world.wareffort : isSupplyPile;

        if (isSupplyPile(guid))
            return warEffort.pileUp(guid);
        if (const e = guid in data.gameObjectGameEvents)
            return gameEvents.spawnIn(*e);
        return true;
    }

    /// The events made active and inactive by the clock; their spawns come and go in the loaded cells.
    private void updateGameEvents(MonoTime now, bool force = false)
    {
        import core.time : seconds;
        import dmangos.log : info;

        if (!force && gameEventsChecked != MonoTime.init && now - gameEventsChecked < 10.seconds)
            return;
        gameEventsChecked = now;
        // Yearly and Easter dates move to the new year once it comes.
        const day = unixTime / 86_400;
        if (day != scheduledDay)
        {
            scheduledDay = day;
            foreach (e; data.gameEvents)
            {
                scheduleFor(e, unixTime);
                gameEvents.events[e.id] = e;
            }
        }
        ushort[] started, stopped;
        gameEvents.update(unixTime, started, stopped);
        foreach (id; started)
            info!"game event %s (%s) starts"(id, gameEvents.events[id].description);
        foreach (id; stopped)
            info!"game event %s (%s) ends"(id, gameEvents.events[id].description);

        if (started.length || stopped.length)
            gameEventSpawnsChanged();
    }

    private bool eventStatusRead;
    private bool[ushort] eventsOnBefore; /// `game_event_status`: what was on when last looked (across restarts)

    /**
     * A game event's letters (`game_event_mail`): as it starts, and (negative rows) as it ends, compared with
     * what `game_event_status` says was on, so a restart sends nothing for an event already on; one that
     * ended while the server was down sends its ending letters when it comes back up.
     */
    private void eventMails()
    {
        if (!eventStatusRead)
        {
            eventStatusRead = true;
            foreach (id; database.gameEventStatus())
                eventsOnBefore[id] = true;
        }
        foreach (id, ref e; gameEvents.events)
        {
            const on = gameEvents.isActive(id);
            const was = (id in eventsOnBefore) !is null;
            if (on == was)
                continue;
            if (on)
                eventsOnBefore[id] = true;
            else
                eventsOnBefore.remove(id);
            database.setGameEventStatus(id, on);
            foreach (ref m; data.gameEventMails.get(on ? cast(short) id : cast(short)(-cast(int) id), null))
                foreach (guid; database.charactersFor(m.raceMask, m.quest))
                    eventLetter(m, guid);
        }
    }

    /// One `game_event_mail` letter to character `guid`: its template's text and the first item its loot gives.
    private void eventLetter(const ref EventMail m, uint guid)
    {
        import std.random : rndGen;
        import dmangos.world.database : MailRecord;
        import dmangos.world.inventory : Item;
        import dmangos.world.loot : Loot;
        import dmangos.world.objects : HighGuid, makeGuid;

        enum ubyte mailCreature = 3;
        MailRecord mail;
        mail.messageType = mailCreature;
        mail.sender = m.sender;
        mail.receiver = guid;
        mail.templateId = m.mailTemplate;
        if (const template_ = data.loot.mail[m.mailTemplate])
        {
            auto loot = new Loot(0, null);
            loot.fill(template_, data.loot, data.items, rndGen, (uint c) => true, null);
            foreach (lootItem; loot.items)
                if (auto proto = lootItem.itemId in data.items)
                {
                    auto item = new Item(nextItemGuid(), proto, makeGuid(HighGuid.player, 0, guid));
                    item.count = lootItem.count ? lootItem.count : 1;
                    const record = item.record;
                    database.saveLooseItem(record, guid);
                    mail.itemGuid = record.guid;
                    mail.itemEntry = record.entry;
                    break; // a letter holds one item
                }
        }
        postMail(mail, 0);
    }

    /// After events changed: in every loaded map, spawns now away go, and spawns now in come (where their cells are loaded).
    private void gameEventSpawnsChanged()
    {
        import dmangos.world.grid : cellKeyAt;

        void refresh(Map m)
        {
            // Those to go; and those an event changes (or changed), alive and out of a fight, to be made again.
            ulong[] gone;
            const(CreatureSpawn)*[] remade;
            m.forEachObject((MapObject o) {
                if (auto c = cast(Creature) o)
                {
                    if (!creatureInEvents(c.spawnId))
                        gone ~= c.guid;
                    else if (c.spawnId in data.eventCreatures && !c.petOwner && c.summon.type == TempSpawnType.none
                            && c.alive && (c.ai is null || !c.ai.inCombat) && eventShapeOf(c.spawnId) != c.eventShape)
                        if (const spawn = creatureSpawnOf(c.spawnId))
                        {
                            gone ~= c.guid;
                            remade ~= spawn;
                        }
                }
                else if (auto go = cast(GameObject) o)
                    if (eventObject(go.spawn.guid) && !gameObjectInEvents(go.spawn.guid))
                        gone ~= go.guid;
            });
            foreach (guid; gone)
                m.removeObject(guid);
            foreach (spawn; remade)
                if (auto c = makeCreature(spawn))
                {
                    c.instanceId = m.instanceId;
                    m.addObject(c);
                }
            // Those to come, in loaded cells.
            bool[ulong] present;
            m.forEachObject((MapObject o) { present[o.guid] = true; });
            if (auto cells = m.id in data.creatureCells)
                foreach (key, indexes; *cells)
                    if (m.cellLoaded(key))
                        foreach (index; indexes)
                        {
                            const spawn = &data.creatureSpawns[index];
                            if (spawn.guid !in data.creatureGameEvents || !creatureInEvents(spawn.guid))
                                continue;
                            if (awaitingRespawn(spawn.guid))
                                continue;
                            auto c = makeCreature(spawn);
                            if (c is null || c.guid in present)
                                continue;
                            c.instanceId = m.instanceId;
                            m.addObject(c);
                        }
            if (auto cells = m.id in data.gameObjectCells)
                foreach (key, indexes; *cells)
                    if (m.cellLoaded(key))
                        foreach (index; indexes)
                        {
                            const spawn = &data.gameObjectSpawns[index];
                            if (!eventObject(spawn.guid) || !gameObjectInEvents(spawn.guid)
                                || spawn.respawnSeconds < 0)
                                continue;
                            auto go = makeGameObject(spawn);
                            if (go.guid in present)
                                continue;
                            go.instanceId = m.instanceId;
                            m.addObject(go);
                        }
        }
        foreach (m; maps.values)
            refresh(m);
        foreach (m; instanceMaps.values)
            refresh(m);
    }

    /// Whether game object spawn `guid` comes and goes as the events (or the war effort) say.
    private bool eventObject(uint guid)
    {
        import dmangos.world.wareffort : isSupplyPile;

        return (guid in data.gameObjectGameEvents) !is null || isSupplyPile(guid);
    }

    // -----------------------------------------------------------------------
    // The Ahn'Qiraj war effort (`dmangos.world.wareffort`)
    // -----------------------------------------------------------------------

    /// The war effort as this node last heard it from its service: the events, piles and capitals follow it.
    WarEffort warEffort;

    /// The war effort's service, on the node the cluster places it on: from the state it moved with, or
    /// from the characters database's row.
    private WarEffortHost newWarEffortHost(const(ubyte)[] moved)
    {
        import dmangos.log : error, info;
        import dmangos.plaindata : decode;
        import dmangos.world.wareffort : saveId;

        WarEffortHost host;
        if (moved.length)
            decode(moved, host.state);
        else
        {
            const text = database.worldState(saveId);
            if (!WarEffort.parse(text, unixTime, host.state))
                error!"world_state %s: '%s' is not the war effort's state; it starts anew"(saveId, text);
            else
                info!"the war effort: phase %s"(host.state.phase);
        }
        host.clock = () => unixTime;
        host.save = (string text) { database.saveWorldState(saveId, text); };
        host.announce = (const ref WarEffort w) { services.announce!WarEffortHost(w); };
        return host;
    }

    /// Asks the war effort's service how it stands (a cluster node starting: wherever it is placed).
    void askWarEffort()
    {
        import dmangos.world.wareffort : WarEffortQuery;

        services.call!(WarEffortHost.current)(WarEffortQuery(nodeId), (WarEffort w) { warEffortHeard(w); });
    }

    /**
     * The war effort's service told how it stands: this node starts and stops its phases' game events,
     * brings or takes away its piles of supplies, and updates the world states of its players in the capitals.
     */
    void warEffortHeard(const ref WarEffort now)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.wareffort : colossusEvents, phaseEvents;

        const before = warEffort;
        warEffort = now;
        const on = now.events;
        bool eventsChanged;
        foreach (id; phaseEvents[] ~ colossusEvents[])
            if (on.canFind(id) != gameEvents.started(id))
            {
                gameEvents.start(id, on.canFind(id));
                eventsChanged = true;
            }
        if (eventsChanged)
            updateGameEvents(clock(), true);
        if (before.pilesUp != now.pilesUp)
            gameEventSpawnsChanged();

        // The capitals' counters and days.
        const time = unixTime;
        foreach (player; online.values)
        {
            if (player.character is null)
                continue;
            const zone = player.character.data.zone;
            uint[uint] was;
            foreach (s; before.worldStates(zone, time))
                was[s[0]] = s[1];
            foreach (s; now.worldStates(zone, time))
                if (was.get(s[0], uint.max) != s[1])
                {
                    import dmangos.world.map : packetBody;
                    import dmangos.world.packets : ServerUpdateWorldState;

                    player.deliver(Opcode.SMSG_UPDATE_WORLD_STATE, packetBody(ServerUpdateWorldState(s[0], s[1])));
                }
        }
    }

    /// The war effort's world states for a player in `zone` (`SMSG_INIT_WORLD_STATES`).
    uint[2][] warEffortWorldStates(uint zone)
    {
        return warEffort.worldStates(zone, unixTime);
    }

    /// See `CreatureLore.warEffortHandIn`: the quest's first required items, for the service to count.
    void warEffortHandIn(uint quest, uint resource)
    {
        import dmangos.world.wareffort : AqResource, resourceCount, WarEffortContribution;

        const q = data.quests.quest(quest);
        if (q is null || resource >= resourceCount)
            return;
        services.call!(WarEffortHost.contribute)(WarEffortContribution(cast(AqResource) resource, q.reqItemCount[0]));
    }

    /// See `CreatureLore.warEffortColossusFell`.
    void warEffortColossusFell(uint colossus)
    {
        import dmangos.world.wareffort : Colossus, WarEffortColossus;

        if (colossus <= Colossus.max)
            services.call!(WarEffortHost.colossusDied)(WarEffortColossus(cast(Colossus) colossus));
    }

    /// The battleground queues, as the service on this node runs them (docs/SERVICES.md).
    private BattlegroundQueue newBattlegroundQueue()
    {
        import dmangos.cluster.ownership : IdKind;

        auto q = new BattlegroundQueue;
        foreach (type, t; data.battlegroundTemplates)
            q.templates[type] = t;
        q.clock = () => clock();
        q.newInstanceId = (out uint id) => takeId(IdKind.instance, id);
        q.deliver = (ulong guid, ushort node, Opcode opcode, const(ubyte)[] body_) {
            if (auto local = onlinePlayer(guid))
                return local.deliver(opcode, body_);
            if (deliverRemote is null)
                return;
            if (auto remote = remotePlayer(guid))
                node = remote.node; // presence follows it between nodes
            if (node && node != nodeId)
                deliverRemote(node, guid, cast(ushort) opcode, body_);
        };
        return q;
    }

    /// The battleground queue service, if it runs on this node (standalone it does).
    @property BattlegroundQueue battlegroundQueue()
    {
        if (auto host = services.local!BattlegroundQueueHost())
            return host.queue;
        return null;
    }

    /// A battleground copy closed: its map goes (its players have left it).
    void closeBattlegroundMap(uint instance)
    {
        instances.remove(instance);
        dropInstanceMap(instance);
    }

    /// The channels, if this node hosts them (standalone it does); null if another node does.
    @property ChannelService channelService()
    {
        if (auto host = services.local!ChannelsHost())
            return host.channels;
        return null;
    }

    /// Reads the `command_overrides` setting: GM commands given another permission letter.
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

    /// A line in the GM command log (`gm_command_log`), with the time in front.
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

    // -----------------------------------------------------------------------
    // Ships and zeppelins (`dmangos.world.transports`)
    // -----------------------------------------------------------------------

    /// A ship sailing: its schedule, its object, and the map it is on now (`uint.max`: not placed yet).
    private struct ShipAtSea
    {
        const(Ship)* ship;
        ShipObject object;
        uint map = uint.max;
    }

    private ShipAtSea[] ships;

    /// The transport clock now: the wall clock's milliseconds, moving with `clock`.
    uint transportNow()
    {
        return transportClock(startUnixMillis + (clock() - startClock).total!"msecs");
    }

    /**
     * Each tick: each ship is where its schedule says. One that came to another map leaves the old one (its
     * players forget it) for the new one (its players get it), and the players aboard cross with it.
     * Ships on dungeon maps are not sailed.
     */
    private void updateShips()
    {
        import dmangos.log : info;
        import dmangos.world.character : Character;
        import dmangos.world.movement : MovementFlags, Position;

        if (ships.length == 0 && data.ships.length)
            foreach (ref ship; data.ships)
            {
                import std.algorithm.searching : canFind;

                if (config.disabledTransports.canFind(ship.entry))
                    continue; // left out by the configuration
                bool dungeon;
                foreach (ref k; ship.frames)
                    dungeon |= instanceable(k.node.map);
                if (dungeon)
                    continue;
                const k = ship.frames[0];
                const t = ship.entry in data.gameObjectTemplates;
                ships ~= ShipAtSea(&ship, new ShipObject(t, ship.period,
                    Position(k.node.x, k.node.y, k.node.z, k.facing), &transportNow));
            }
        const clock = transportNow();
        foreach (ref s; ships)
        {
            size_t frame;
            const map = mapAt(s.ship.frames, clock % s.ship.period, frame);
            // Arriving at a crossing, it is at the next frame, on the next map.
            auto k = &s.ship.frames[frame];
            if (k.teleport)
                k = &s.ship.frames[(frame + 1) % s.ship.frames.length];
            const at = Position(k.node.x, k.node.y, k.node.z, k.facing);
            s.object.moveTo(at);
            if (map == s.map)
                continue;
            const from = s.map;
            s.map = map;
            Character[] aboard;
            if (from != uint.max)
                if (auto old = existingMap(from))
                {
                    foreach (who; old.playersNow())
                    {
                        const move = &who.character.movement;
                        if (move.has(MovementFlags.onTransport) && move.transportGuid == s.object.guid)
                            if (auto session = cast(Character) who)
                                aboard ~= session;
                    }
                    old.removeEverywhere(s.object.guid);
                }
            if (auto there = existingMap(map))
                there.addEverywhere(s.object);
            info!"%s sails to map %s (%s aboard)"(s.ship.name, map, aboard.length);
            foreach (session; aboard)
                session.rideShipAcross(map, at, s.object.guid, s.ship.entry);
        }
    }

    // -----------------------------------------------------------------------
    // GM tickets (`gm_tickets`)
    // -----------------------------------------------------------------------

    /// Whether the ticket system takes tickets (`.gmTicket toggle`; the client's help asks).
    bool gmTicketsOn = true;
    /// The GM a ticket is assigned to, and a GM's comment on it: kept here only (the table has no columns for them).
    ulong[uint] ticketAssignedTo;
    string[uint] ticketComments; /// ditto

    /// Unix time, moving with `clock` (so tests that replace the clock move it too).
    long unixTime()
    {
        return startUnixTime + (clock() - startClock).total!"seconds";
    }

    /// When the server started, in Unix time.
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
    /// A map's ground, from `data_dir`'s `.map` files, loaded the first time it is asked for.
    Terrain terrain(uint mapId)
    {
        if (vmapModels is null)
            vmapModels = new ModelCache(buildPath(config.dataDir, "vmaps"));
        return terrains.require(mapId, new Terrain(mapId, config.dataDir, client, vmapModels, config.mmaps));
    }

    Map map(uint id)
    {
        if (auto found = id in maps)
            return *found;
        return maps[id] = makeMap(id, 0);
    }

    /// Map `id`'s instance `instance` (0: the map itself), created when its first player arrives.
    Map map(uint id, uint instance)
    {
        if (instance == 0)
            return map(id);
        if (auto found = instance in instanceMaps)
            return *found;
        if (instance !in instances)
            instances[instance] = InstanceState(id, 0, unixTime);
        return instanceMaps[instance] = makeMap(id, instance);
    }

    /// The map `who` is on.
    Map mapOf(const OnlinePlayer who)
    {
        return map(who.character.data.map, who.instanceId);
    }

    /// See `CreatureLore.teleportBySpell`.
    void teleportBySpell(ulong guid, uint spell)
    {
        import dmangos.world.character : Character;

        if (const to = spell in data.spellTargets)
            if (auto c = cast(Character) onlinePlayer(guid))
                c.spellTeleport(to.map, to.at);
    }

    /// What `Map`'s `playerSees` needs of the world: a group, a side, the viewer's corpse.
    private VisibilityFacts visibilityFacts(Map map_, ulong viewer, ulong seen, Position seenAt)
    {
        import dmangos.world.character : Character;

        VisibilityFacts f;
        f.sameGroup = groups.sameGroup(viewer, seen);
        ubyte raceOf(ulong guid)
        {
            if (auto local = onlinePlayer(guid))
                return local.character.data.race;
            if (auto remote = remotePlayer(guid))
                return remote.entry.race;
            return 0;
        }
        const a = raceOf(viewer), b = raceOf(seen);
        f.cooperate = a && b && client.teamForRace(a) == client.teamForRace(b);
        if (auto local = cast(Character) onlinePlayer(viewer))
            if (const body_ = local.ownCorpse())
                if (body_.map == map_.id)
                    f.corpseDistance = ((body_.at.x - seenAt.x) ^^ 2 + (body_.at.y - seenAt.y) ^^ 2
                        + (body_.at.z - seenAt.z) ^^ 2) ^^ 0.5f;
        return f;
    }

    private Map makeMap(uint id, uint instance)
    {
        bool delegate(ulong) owns;
        if (ownsCell !is null)
            owns = (ulong cell) => ownsCell(id, cell);
        MapObject[] delegate(uint, ulong) spawner = &spawnCell;
        if (instance)
            spawner = (uint m, ulong cell) => spawnCellIn(m, instance, cell);
        auto created = new Map(id, MapSettings(config.visibilityDistance, config.visibilityRelocationLimit,
            config.gridCleanUpDelay * 1000),
            &serverTime, spawner, terrain(id), owns);
        created.instanceId = instance;
        if (instance == 0) // a dungeon's copies are all on one node: nobody else needs replicas of them
            created.replicator = replicator;
        created.onCorpseRemoved = &corpseRemoved;
        created.visibilityFacts = (ulong viewer, ulong seen, Position seenAt) => visibilityFacts(created, viewer,
            seen, seenAt);
        created.onReplicaNoticing = &replicaNoticing;
        created.onTrap = (Inhabitant who, GameObject trap) { trapSprung(created, who, trap); };
        created.onWaypointScript = (Creature creature, uint scriptId) {
            import dmangos.world.dbscripts : DbScriptType;

            startScript(DbScriptType.creatureMovement, scriptId, created, creature.guid, creature.guid);
        };
        created.onGameObjectUsedUp = &gameObjectUsedUp;
        created.onObjectGone = &objectGone;
        created.onObjectArrived = (MapObject o) { // open-world round 2: a scripted game object's `Spawned`
            if (auto go = cast(GameObject) o)
                if (go.behaviour && scripts.handles!(imported!"dmangos.script.api".Spawned)(go.behaviour))
                    objectArrivals ~= GameObjectArrival(go, created);
        };
        created.onCreatureDeath = (Creature c) {
            linkedDeath(created, c); // its pack's part first, while it is still known
            const killer = c.lootRecipient; // before `die` forgets it
            c.die(created, unixTime);
            created.creatureDeaths.put(c);
            if (instance) // a battleground's objectives (Alterac Valley's captains, generals and mines)
                if (auto copy = battlegrounds.find(instance))
                    if (copy.mapId == id)
                        copy.rules.creatureKilled(copy, c.template_.entry, killer);
        };
        created.onLinked = &linkedEvent;
        if (instance)
            if (const name = id in data.instanceScriptNames)
            {
                auto state = instance in instances;
                auto script = InstanceScript.make(scripts, *name, instance, id, state is null ? null : state.data,
                    (string saved) {
                        if (auto st = instance in instances)
                            st.data = saved;
                        database.saveInstanceData(instance, saved);
                    });
                if (script !is null)
                {
                    script.map = created;
                    script.lore = this;
                    script.spawnObjects = &spawnDungeonObjects;
                    script.signalObject = &gameObjectSignalled;
                    script.respawnObjectOf = &respawnObjectOfEntry;
                    script.summonObjectAt = &summonGameObjectAt;
                    instanceScripts[instance] = script;
                    created.onPlayerAdded = (Inhabitant who) {
                        import dmangos.script.api : PlayerEntered;

                        if (auto s = instance in instanceScripts)
                            s.raise(PlayerEntered(EntityRef(who.character.guid)));
                    };
                }
            }
        if (instance == 0) // open-world round 2: the continent's script (`world_template`)
            if (const name = id in data.worldScriptNames)
                if (auto script = InstanceScript.makeWorld(scripts, *name, id))
                {
                    script.map = created;
                    script.lore = this;
                    script.spawnObjects = &spawnDungeonObjects;
                    script.signalObject = &gameObjectSignalled;
                    script.respawnObjectOf = &respawnObjectOfEntry;
                    script.summonObjectAt = &summonGameObjectAt;
                    worldScripts[id] = script;
                }
        if (instance == 0) // the ships on this map now
            foreach (ref ship; ships)
                if (ship.map == id)
                    created.addEverywhere(ship.object);
        created.groupOf = (ulong player) {
            auto group = groups.of(player);
            return group is null ? 0 : group.id;
        };
        return created;
    }

    /// The map `id` if it exists; null otherwise.
    Map existingMap(uint id)
    {
        return maps.get(id, null);
    }

    /// Map `id`'s instance `instance` if it exists (0: the map itself); null otherwise.
    Map existingMap(uint id, uint instance)
    {
        return instance ? instanceMaps.get(instance, null) : existingMap(id);
    }

    // -----------------------------------------------------------------------
    // Dungeon instances: their copies, saved state and players' binds
    // -----------------------------------------------------------------------

    /// What is kept of an instance: its map, when it emptied, its dead and used-up spawns.
    static struct InstanceState
    {
        uint mapId;
        long resetAt;          /// a raid's reset (Unix time): its lockout lasts till then; 0 for a dungeon
        long createdAt;        /// when it was made (or, saved, read back), Unix time
        MonoTime emptySince;   /// MonoTime.init while someone is in it
        bool[uint] dead;       /// creature spawns killed there (they do not come back while it lasts)
        bool[uint] usedUp;     /// game object spawns used up there
        string data;           /// its dungeon script's state (`instance.data`)
    }

    private Map[uint] instanceMaps;            // instance id -> its map
    private InstanceState[uint] instances;     // instance id -> its state
    private uint[uint][ulong] playerBinds;     // player guid -> map id -> instance (`character_instance`)
    private uint[uint][ulong] groupBinds;      // group leader guid -> map id -> instance (`group_instance`)

    /**
     * Whether map `mapId` is a dungeon whose groups each get a copy of it.
     * In a cluster a dungeon is one region (never split), and the node owning it hosts every copy.
     */
    bool instanceable(uint mapId)
    {
        const entry = client.maps.lookup(mapId);
        return entry !is null && (entry.isDungeon || entry.isBattleground);
    }

    /**
     * The node hosting dungeon `mapId`'s copies: the owner of its one region; this node standalone;
     * 0 while nobody owns it (a lost owner's lease not over yet).
     */
    ushort dungeonHost(uint mapId)
    {
        if (regionOwnerAround is null)
            return nodeId;
        return regionOwnerAround(mapId, Position(0, 0, 0), 0);
    }

    /// Whether this node hosts dungeon `mapId`'s copies: it decides which one a player goes into.
    bool hostsDungeon(uint mapId)
    {
        return regionOwnerAround is null || dungeonHost(mapId) == nodeId;
    }

    /**
     * The instance of `mapId` the player goes into: its group's, else its own, else a new one, to
     * which it (and its group) are bound.
     * 0 for a map that is not instanced, or (in a cluster) a dungeon another node hosts: the player
     * goes there (`InWorldHandlers.migrateTo`), and gets its copy there.
     */
    uint instanceFor(ulong player, uint mapId)
    {
        import dmangos.cluster.ownership : IdKind;
        import dmangos.log : info, warning;

        if (!instanceable(mapId) || !hostsDungeon(mapId))
            return 0;
        // A battleground's copy is the one the queue sent the player to.
        if (battlegroundOfMap(mapId))
            return database.loadBattlegroundData(cast(uint) player).instance;
        auto group = groups.of(player);
        const raid = client.maps.lookup(mapId).isRaid;
        uint chosen = boundInstance(player, mapId);
        if (!chosen)
        {
            // Ids are the cluster's (each node makes the copies of its own dungeons).
            if (!takeId(IdKind.instance, chosen) || chosen == 0)
            {
                warning!"instance of map %s not made: no instance ids (the coordinator's next block has not come)"(mapId);
                return 0;
            }
            const resetAt = raid ? raidResetAt(mapId) : 0;
            instances[chosen] = InstanceState(mapId, resetAt, unixTime);
            database.saveInstance(chosen, mapId, resetAt);
            info!"instance %s of map %s made"(chosen, mapId);
        }
        if (playerBinds.get(player, null).get(mapId, 0) != chosen)
        {
            playerBinds.require(player, null)[mapId] = chosen;
            database.saveInstanceBind(false, cast(uint) player, chosen, raid);
        }
        if (group !is null && groupBinds.get(group.leader, null).get(mapId, 0) !in instances)
        {
            groupBinds.require(group.leader, null)[mapId] = chosen;
            database.saveInstanceBind(true, cast(uint) group.leader, chosen, raid);
        }
        return chosen;
    }

    /// The copy of `mapId` the player would go into, of those that exist: a raid's lockout, its
    /// group's, its own; 0 if a new one would be made.
    uint boundInstance(ulong player, uint mapId)
    {
        const raid = client.maps.lookup(mapId).isRaid;
        auto group = groups.of(player);
        if (raid)
            if (auto bound = mapId in playerBinds.get(player, null))
                if (*bound in instances)
                    return *bound;
        if (group !is null)
            if (auto bound = mapId in groupBinds.get(group.leader, null))
                if (*bound in instances)
                    return *bound;
        if (auto bound = mapId in playerBinds.get(player, null))
            if (*bound in instances)
                return *bound;
        return 0;
    }

    /**
     * On the node hosting dungeon `mapId`: whether `player` may go in (into `toInstance`, uint.max:
     * the copy it would get); 0 if so, else `SMSG_TRANSFER_ABORTED`'s reason (a lockout, a full copy).
     */
    ubyte dungeonEntryProblem(ulong player, uint mapId, uint toInstance, bool gameMaster)
    {
        enum ubyte abortMaxPlayers = 0x01, abortNotFound = 0x02;
        if (!instanceable(mapId) || !hostsDungeon(mapId))
            return abortNotFound;
        if (toInstance == uint.max && lockedOutOfGroupRaid(player, mapId))
            return abortNotFound;
        const instance = toInstance != uint.max ? toInstance : boundInstance(player, mapId);
        if (instance && !gameMaster)
            if (const most = mapId in data.instanceMaxPlayers)
                if (auto there = existingMap(mapId, instance))
                    if (there.population >= *most)
                        return abortMaxPlayers;
        return 0;
    }

    /// Asks the node hosting a dungeon whether a player may go in (`dungeonEntryProblem` there); null standalone.
    void delegate(ushort host, ulong player, uint map, uint instance, bool gameMaster,
        void delegate(ubyte abort) then) askDungeonEntry;

    /**
     * Entering a dungeon: a player who is not a game master, sent into a copy of `mapId` (summoned,
     * appearing), is bound to it unless it is bound to a copy of that map already.
     */
    void bindOnEntering(ulong player, uint mapId, uint instance)
    {
        if (!instance || instance !in instances || mapId in playerBinds.get(player, null) || battlegroundOfMap(mapId))
            return;
        playerBinds.require(player, null)[mapId] = instance;
        database.saveInstanceBind(false, cast(uint) player, instance, instances[instance].resetAt != 0);
    }

    /**
     * A raid's lockout: whether the player is bound to another copy of raid `mapId` than its group's
     * (such a player may not enter).
     */
    bool lockedOutOfGroupRaid(ulong player, uint mapId)
    {
        const entry = client.maps.lookup(mapId);
        if (entry is null || !entry.isRaid || !instanceable(mapId))
            return false;
        auto group = groups.of(player);
        if (group is null)
            return false;
        const mine = playerBinds.get(player, null).get(mapId, 0), theirs = groupBinds.get(group.leader, null).get(mapId, 0);
        return mine && theirs && mine != theirs && mine in instances && theirs in instances;
    }

    /// The instances saved: their rows, binds and dead, read at start-up.
    private long[uint] raidResets_;   /// each raid map's next reset (Unix time), as `instance_reset` keeps it
    private bool raidResetsRead;

    /**
     * When the raid `mapId`'s copies next reset, all together: at `instance_reset_time_hour` every
     * `reset_delay` days (`instance_template`), counted on from the last, kept in `instance_reset`.
     */
    long raidResetAt(uint mapId)
    {
        if (!raidResetsRead)
        {
            raidResetsRead = true;
            raidResets_ = database.loadRaidResets();
        }
        const now = unixTime;
        auto t = raidResets_.get(mapId, 0);
        if (t > now)
            return t;
        const t2 = nextRaidReset(t, now, data.instanceResetDays.get(mapId, 7), config.instanceResetTimeHour);
        raidResets_[mapId] = t2;
        database.saveRaidReset(mapId, t2);
        return t2;
    }

    /**
     * The reset after `last` (0: none yet) that is after `now`, every `days` days at `hour` (as the reference
     * counts them: the first `days` after today).
     */
    static long nextRaidReset(long last, long now, uint days, uint hour) pure nothrow @nogc @safe
    {
        enum long day = 86_400;
        const period = (days ? days : 7) * day, diff = (hour % 24) * 3600L;
        const today = now / day * day;
        if (last == 0)
            return today + period + diff;
        long t = last / day * day;
        t += ((today - t) / period + 1) * period + diff;
        while (t <= now)
            t += period;
        return t;
    }

    /// When copy `instance` resets (Unix time); 0 for none (a dungeon, or not a copy known here).
    long instanceResetAt(uint instance)
    {
        if (auto s = instance in instances)
            return s.resetAt;
        return 0;
    }

    private void loadInstances()
    {
        loadInstancesOf((uint) => true);
    }

    /// The saved instances of the maps `which` accepts, read anew (replacing what was known of them).
    private void loadInstancesOf(scope bool delegate(uint mapId) which)
    {
        import dmangos.cluster.ownership : IdKind;

        const saved = database.loadInstances();
        foreach (r; saved.instances)
            if (which(r.map))
            {
                instances[r.id] = InstanceState(r.map, r.resetTime, unixTime);
                instances[r.id].data = r.data;
                raise(IdKind.instance, r.id + 1);
            }
        foreach (b; saved.binds)
            if (auto state = b.instance in instances)
                if (which(state.mapId))
                {
                    if (b.group)
                        groupBinds.require(b.owner, null)[state.mapId] = b.instance;
                    else
                        playerBinds.require(b.owner, null)[state.mapId] = b.instance;
                }
        foreach (r; saved.respawns)
            if (auto state = r.instance in instances)
                if (which(state.mapId))
                {
                    if (r.gameObject)
                        state.usedUp[r.spawnGuid] = true;
                    else
                        state.dead[r.spawnGuid] = true;
                }
    }

    /**
     * A dungeon's copies are another node's now (its region moved): what this node knew of them goes
     * from memory (not from the database, which the new host reads). A copy with players in it stays
     * until they have moved on (`unloadEmptyInstances`).
     */
    private void dungeonLost(uint mapId)
    {
        foreach (id; instances.keys)
            if (instances[id].mapId == mapId)
            {
                const m = instanceMaps.get(id, null);
                if (m is null || m.population == 0)
                    forgetInstance(id);
            }
    }

    /// This node hosts dungeon `mapId` now: its copies, binds and dead as the last host saved them.
    private void dungeonGained(uint mapId)
    {
        import dmangos.log : info;

        foreach (id; instances.keys)
            if (instances[id].mapId == mapId && instanceMaps.get(id, null) is null)
                forgetInstance(id);
        loadInstancesOf((uint m) => m == mapId);
        size_t count;
        foreach (ref state; instances)
            count += state.mapId == mapId;
        if (count)
            info!"cluster: dungeon map %s is hosted here now, with %s saved instances"(mapId, count);
    }

    /// The copies of dungeon `mapId` loaded here, their objects saved for node `next`: (copy, bundle) pairs.
    private const(ubyte)[] dungeonCopiesOut(uint mapId, ushort next)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.log : info;

        ByteWriter w;
        uint[] ids;
        foreach (id, m; instanceMaps)
            if (instances.get(id, InstanceState.init).mapId == mapId && m.instanceId == id)
                ids ~= id;
        w.put(cast(uint) ids.length);
        foreach (id; ids)
        {
            auto m = instanceMaps[id];
            const before = m.objectCount - m.replicaCount;
            const bundle = m.migrateOut((ulong) => true, next, &saveMigrant);
            w.put(id);
            w.put(cast(uint) bundle.length);
            w.putBytes(bundle);
            info!"migration: instance %s of map %s leaves for node %s with %s objects"(id, mapId, next,
                before - (m.objectCount - m.replicaCount));
        }
        return w.data;
    }

    /// What `dungeonCopiesOut` sent: each copy made here and its objects as they were.
    private void dungeonCopiesIn(uint mapId, const(ubyte)[] copies)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : info;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : Migrant;

        if (copies.length < 4)
            return;
        auto r = ByteReader(copies);
        foreach (_; 0 .. r.read!uint)
        {
            const id = r.read!uint;
            const bundle = r.readBytes(r.read!uint);
            if (id !in instances)
                continue; // reset meanwhile
            auto m = map(mapId, id);
            const before = m.objectCount - m.replicaCount;
            m.migrateIn(bundle, (const ref Migrant migrant) {
                auto object = restoreMigrant(migrant);
                if (auto creature = cast(Creature) object)
                    creature.instanceId = id;
                else if (auto go = cast(GameObject) object)
                    go.instanceId = id;
                return object;
            });
            info!"migration: instance %s of map %s arrived with %s objects"(id, mapId,
                m.objectCount - m.replicaCount - before);
        }
    }

    /// An instance gone from this node's memory only (another node hosts it).
    private void forgetInstance(uint id)
    {
        instances.remove(id);
        dropInstanceMap(id);
        foreach (ref binds; playerBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
        foreach (ref binds; groupBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
    }

    /// Whether creature spawn `spawnGuid` is dead in instance `instance`.
    bool deadInInstance(uint instance, uint spawnGuid)
    {
        if (auto state = instance in instances)
            return (spawnGuid in state.dead) !is null;
        return false;
    }

    /// The instances that are made.
    @property size_t instanceCount() const
    {
        return instances.length;
    }

    /// A cell of an instance loading: the cell's spawns but those killed or used up in it.
    private MapObject[] spawnCellIn(uint mapId, uint instance, ulong cell)
    {
        import dmangos.world.gameobject : GameObject;

        auto state = instance in instances;
        // A battleground's copy: only the spawns of its events now.
        auto copy = battlegroundOfMap(mapId) ? battlegrounds.find(instance) : null;
        MapObject[] spawned;
        if (auto cells = mapId in data.creatureCells)
            foreach (index; (*cells).get(cell, null))
            {
                if (state !is null && data.creatureSpawns[index].guid in state.dead)
                    continue;
                if (!creatureInEvents(data.creatureSpawns[index].guid))
                    continue;
                if (copy !is null && !copy.spawnAllowed(data.creatureSpawns[index].guid in data.creatureBattleEvents))
                    continue;
                if (cantSpawnWhileBossDead(data.creatureSpawns[index], state))
                    continue;
                if (auto creature = makeCreature(&data.creatureSpawns[index]))
                {
                    creature.instanceId = instance;
                    spawned ~= creature;
                    queueLinked(mapId, instance, creature);
                }
            }
        if (auto cells = mapId in data.gameObjectCells)
            foreach (index; (*cells).get(cell, null))
            {
                const spawn = &data.gameObjectSpawns[index];
                if (spawn.respawnSeconds < 0 || (state !is null && spawn.guid in state.usedUp)
                    || !gameObjectInEvents(spawn.guid))
                    continue;
                const event = spawn.guid in data.gameObjectBattleEvents;
                if (copy !is null && !copy.spawnAllowed(event))
                    continue;
                auto go = makeGameObject(spawn);
                go.instanceId = instance;
                if (copy !is null && event !is null && (*event)[0] == 254 && copy.doorsOpen)
                    go.setDoorOpen(true); // a door loading after the start is open
                spawned ~= go;
            }
        if (auto script = instance in instanceScripts)
        {
            import dmangos.script.api : CreatureLoaded, EntityRef, ObjectLoaded;

            script.loading = spawned;
            foreach (object; spawned)
                if (cast(Creature) object)
                    script.raise(CreatureLoaded(EntityRef(object.guid)));
                else
                    script.raise(ObjectLoaded(EntityRef(object.guid)));
            script.loading = null;
        }
        return spawned;
    }

    /// After `Instance.UnloadDelay` empty, an instance's map is unloaded, and its binds go with it.
    private void unloadEmptyInstances(MonoTime now)
    {
        import core.time : seconds;
        import dmangos.log : info;

        uint[] gone, elsewhere;
        const time = unixTime;
        foreach (id, ref state; instances)
        {
            const m = instanceMaps.get(id, null);
            if (m !is null && m.population > 0)
            {
                state.emptySince = MonoTime.init;
                continue;
            }
            if (!hostsDungeon(state.mapId))
            {
                elsewhere ~= id; // another node's (or nobody's yet): it saves and resets its copies, not this one
                continue;
            }
            if (battlegroundOfMap(state.mapId))
                continue; // a battleground's copy closes when it is over and empty (`dmangos.world.battleground`)
            if (state.emptySince == MonoTime.init)
                state.emptySince = now;
            if (state.resetAt && time >= state.resetAt)
                gone ~= id; // a raid's reset time: empty (its players were sent out), it goes now
            else if (now - state.emptySince >= config.instanceUnloadDelay.seconds)
            {
                // A raid copy outlives its emptiness until its reset (only its map goes); a dungeon's resets.
                if (state.resetAt && time < state.resetAt)
                    dropInstanceMap(id);
                else
                    gone ~= id;
            }
        }
        foreach (id; elsewhere)
            forgetInstance(id);
        foreach (id; gone)
        {
            info!"instance %s of map %s reset: empty for %s seconds"(id, instances[id].mapId, config.instanceUnloadDelay);
            resetInstance(id);
        }
    }

    /**
     * The player (or, its group's leader, the group) resets its dungeons: each copy of a dungeon (not a
     * raid) it is bound to, hosted here, with nobody in it, is reset (`reset`); one with players inside
     * is not (`busy`). By map.
     */
    void resetDungeonsOf(ulong player, out uint[] reset, out uint[] busy)
    {
        import dmangos.log : info;

        uint[uint]* binds;
        if (auto group = groups.of(player))
        {
            if (group.leader != player)
                return;
            binds = group.leader in groupBinds;
        }
        else
            binds = player in playerBinds;
        if (binds is null)
            return;
        foreach (mapId, id; (*binds).dup)
        {
            const entry = client.maps.lookup(mapId);
            if (entry is null || entry.isRaid || !hostsDungeon(mapId))
                continue;
            if (auto m = instanceMaps.get(id, null))
                if (m.population > 0)
                {
                    busy ~= mapId;
                    continue;
                }
            info!"instance %s of map %s reset by its owner"(id, mapId);
            resetInstance(id);
            reset ~= mapId;
        }
    }

    /// An instance gone for good: its map, state, saved rows and binds.
    void resetInstance(uint id)
    {
        instances.remove(id);
        dropInstanceMap(id);
        database.deleteInstance(id);
        foreach (ref binds; playerBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
        foreach (ref binds; groupBinds)
            foreach (mapId, instance; binds.dup)
                if (instance == id)
                    binds.remove(mapId);
    }

    /// A copy's map goes from memory (unloaded, reset, shut down, another node's now): its scripts too.
    private void dropInstanceMap(uint id)
    {
        if (auto m = instanceMaps.get(id, null))
            m.forEachObject((MapObject o) { objectGone(o); });
        instanceMaps.remove(id);
        if (auto script = id in instanceScripts)
        {
            script.release();
            instanceScripts.remove(id);
        }
    }

    /// An object left its map for good (`Map.onObjectGone`): its script's state goes.
    private void objectGone(MapObject object)
    {
        if (auto creature = cast(Creature) object)
            creature.ai.releaseBehaviour();
        else if (auto go = cast(GameObject) object)
            scripts.destroy(go.behaviour);
    }

    /// The script of dungeon copy `id`; null if it has none here.
    InstanceScript instanceScript(uint id)
    {
        return instanceScripts.get(id, null);
    }

    /// At start-up: which `ScriptName`s of the world database scripts serve, and which they do not.
    private void reportScripts()
    {
        import dmangos.log : info, warning;

        size_t served, unserved;
        bool[string] used;
        foreach (name; data.creatureScriptNames)
        {
            used["creature:" ~ name] = true;
            if (scripts.serves(ScriptKind.creature, name))
                ++served;
            else
                ++unserved;
        }
        foreach (name; data.instanceScriptNames)
        {
            used["instance:" ~ name] = true;
            if (scripts.serves(ScriptKind.instance, name))
                ++served;
            else
                ++unserved;
        }
        foreach (kind, names; [ScriptKind.gameObject: data.gameObjectScriptNames, ScriptKind.spell: data.spellScriptNames,
                ScriptKind.areaTrigger: data.areaTriggerScriptNames, ScriptKind.event: data.eventScriptNames,
                ScriptKind.item: data.itemScriptNames, ScriptKind.world: data.worldScriptNames])
        {
            import std.conv : to;

            bool[string] distinct;
            foreach (name; names)
                distinct[name] = true;
            foreach (name, _; distinct)
            {
                used[kind.to!string ~ ":" ~ name] = true;
                if (scripts.serves(kind, name))
                    ++served;
                else
                    ++unserved;
            }
        }
        info!"scripts: %s script names served, %s in the world database not (yet): those run as before"(served, unserved);
        import std.conv : to;

        foreach (k; [ScriptKind.creature, ScriptKind.instance, ScriptKind.gameObject, ScriptKind.spell,
                ScriptKind.areaTrigger, ScriptKind.event, ScriptKind.item, ScriptKind.world])
            foreach (name; scripts.names(k))
                if (k.to!string ~ ":" ~ name !in used)
                    warning!"scripts: no %s row names script %s"(k, name);
    }

    /// Instance `id`'s state, or null.
    const(InstanceState)* instanceState(uint id) const
    {
        return id in instances;
    }

    /// The instance's map if it is loaded, else null.
    Map instanceMap(uint id)
    {
        return instanceMaps.get(id, null);
    }

    /// The player's binds: map id -> instance.
    const(uint[uint]) bindsOf(ulong player)
    {
        return playerBinds.get(player, null);
    }

    /// Takes a player's bind to map `mapId` away.
    void revokeBind(ulong player, uint mapId)
    {
        if (auto binds = player in playerBinds)
            if (auto instance = mapId in *binds)
            {
                database.deleteInstanceBind(cast(uint) player, *instance);
                (*binds).remove(mapId);
            }
    }

    /// Shuts an instance down: its map goes (its state stays); false if it was not loaded.
    bool shutdownInstance(uint id)
    {
        auto m = instanceMaps.get(id, null);
        if (m is null)
            return false;
        dropInstanceMap(id);
        return true;
    }

    /**
     * What NPC services see of a map object: a creature, or a stand-in for a replica of a
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

    /// Every map that exists, instances included.
    Map[] allMaps()
    {
        return maps.values ~ instanceMaps.values;
    }

    /**
     * The cluster moved regions: what was lost leaves the maps, players near what was
     * gained see it load.
     */
    void regionsChanged(const(Region)[] gained, const(Region)[] lost, const(ubyte)[][uint] arriving,
        ref ubyte[][uint] leaving)
    {
        import dmangos.log : info;
        import dmangos.cluster.services : isServiceMap, serviceOfMap;
        import std.format : format;

        // A service's region (docs/SERVICES.md): it stops here, its state going along with it, or starts.
        foreach (ref r; lost)
            if (isServiceMap(r.map))
            {
                auto state = services.stop(serviceOfMap(r.map));
                if (r.next)
                    leaving[r.id] = state;
                info!"services: %s moves %s"(serviceOfMap(r.map), r.next ? format!"to node %s"(r.next) : "off");
            }
        foreach (ref r; gained)
            if (isServiceMap(r.map) && services.start(serviceOfMap(r.map), arriving.get(r.id, null)))
                info!"services: %s runs here"(serviceOfMap(r.map));

        // A dungeon's region: its copies' creatures and objects go along, copy by copy, before what was
        // known of the copies is forgotten here (the new host has read their rows by then).
        foreach (ref r; lost)
            if (instanceable(r.map))
            {
                if (r.next)
                    leaving[r.id] = cast(ubyte[]) dungeonCopiesOut(r.map, r.next);
                dungeonLost(r.map);
            }
        foreach (ref r; gained)
            if (instanceable(r.map))
            {
                dungeonGained(r.map);
                if (auto copies = r.id in arriving)
                    dungeonCopiesIn(r.map, *copies);
            }
        foreach (ref r; lost)
            if (auto m = r.map in maps)
            {
                if (instanceable(r.map))
                    continue; // a dungeon's copies went above (its map itself is never simulated)
                if (r.next) // moving to another node: its objects go along
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
                if (instanceable(r.map))
                    continue; // its copies' bundles, read above
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
        raise(IdKind.instance, saved.instance);
        raise(IdKind.pet, saved.pet);
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
        case IdKind.instance: return &next.instance;
        case IdKind.pet: return &next.pet;
        }
    }

    /**
     * The creatures and game objects of one cell, as it loads: each spawn's object, with a
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
                if (!creatureInEvents(data.creatureSpawns[index].guid))
                    continue; // its game event says it is away
                if (auto creature = makeCreature(&data.creatureSpawns[index]))
                {
                    spawned ~= creature;
                    queueLinked(mapId, 0, creature);
                }
            }
        if (auto cells = mapId in data.gameObjectCells)
            foreach (index; (*cells).get(cell, null))
            {
                const spawn = &data.gameObjectSpawns[index];
                // Not spawned by default (`spawntimesecs` < 0: events and scripts spawn it), or used up.
                if (spawn.respawnSeconds < 0 || gameObjectAwaitingRespawn(spawn.guid) || !gameObjectInEvents(spawn.guid))
                    continue;
                spawned ~= makeGameObject(spawn);
            }
        return spawned;
    }

    /**
     * A creature from its spawn: a level and model chosen, its addon, equipment
     * and model data looked up, and its movement generator; null if its template has no model.
     */
    Creature makeCreature(const(CreatureSpawn)* spawn, uint petNumber = 0)
    {
        import dmangos.world.creature : chooseDisplay, chooseLevel;
        import dmangos.world.motion : selectMovement;

        // An event on now may make it another entry, model or equipment (`game_event_creature_data`).
        const(EventCreature)* shape;
        CreatureSpawn reshaped;
        if (!petNumber)
            if (auto list = spawn.guid in data.eventCreatures)
                foreach (ref e; *list)
                    if (gameEvents.isActive(e.event))
                    {
                        shape = &e;
                        if (e.entry && e.entry in data.creatureTemplates)
                        {
                            reshaped = *spawn;
                            reshaped.entry = e.entry;
                            spawn = &reshaped;
                        }
                        break;
                    }
        const template_ = spawn.entry in data.creatureTemplates;
        const display = chooseDisplay(*template_, spawnRandom);
        if (display == 0)
            return null;
        const level = chooseLevel(*template_, spawnRandom);
        auto parts = creatureParts(*template_, spawn.guid, display, level,
            shape !is null && shape.equipment ? shape.equipment : template_.equipmentTemplateId);
        auto creature = new Creature(*spawn, template_, display, level, parts, client, petNumber);
        if (shape !is null)
            applyEventShape(creature, *shape);
        // A creature of the water spawned where it can swim swims (unless made to walk in water: crabs).
        enum uint inhabitWater = 2, walkInWater = 0x8000;
        if ((template_.inhabitType & inhabitWater) && !(template_.extraFlags & walkInWater) && !petNumber)
            if (auto ground = terrain(spawn.map))
            {
                import dmangos.world.defines : UnitFlags;
                import dmangos.world.movement : MovementFlags;
                import dmangos.world.terrain : LiquidData, LiquidStatus;
                import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

                LiquidData liquid;
                enum ubyte allLiquids = 0x0F;
                if (ground.liquidStatus(spawn.x, spawn.y, spawn.z, allLiquids, liquid) != LiquidStatus.noWater
                        && liquid.level - liquid.depthLevel > parts.collisionHeight)
                {
                    creature.movement.flags |= MovementFlags.swimming;
                    creature.values.set!UNIT_FIELD_FLAGS(creature.values.get!UNIT_FIELD_FLAGS | UnitFlags.swimming);
                    creature.values.clearChanges();
                }
            }
        creature.generator = selectMovement(creature, data.waypoints);
        creature.ai.setLore(this);
        // A script (`ScriptName`) runs it if one serves its name; else its EventAI, if it has one.
        if (const name = spawn.entry in data.creatureScriptNames)
            creature.ai.setBehaviour(scripts, *name);
        if (!creature.ai.scripted)
            if (auto events = data.eventAi.eventsOf(spawn.entry, spawn.guid))
                creature.ai.setScript(events, data.eventAi);
        return creature;
    }

    /// What making a creature of template `t` (spawn `spawnGuid`, model `display`, at `level`) needs besides.
    private CreatureParts creatureParts(const ref CreatureTemplate t, uint spawnGuid, uint display, uint level,
        uint equipmentId)
    {
        import dmangos.world.creature : classStatsKey, VirtualItem;

        CreatureParts parts;
        if (const stats = classStatsKey(level, t.unitClass) in data.creatureClassStats)
        {
            parts.classStats = *stats;
            parts.hasClassStats = true;
        }
        parts.addon = spawnGuid in data.creatureAddons;
        if (parts.addon is null)
            parts.addon = t.entry in data.creatureTemplateAddons;
        if (const model = display in data.models)
        {
            parts.boundingRadius = model.boundingRadius;
            parts.combatReach = model.combatReach;
            parts.gender = model.gender;
        }
        parts.collisionHeight = client.collisionHeight(display);
        if (const equipment = equipmentId in data.creatureEquipment)
            foreach (slot, entry; *equipment)
                if (const item = entry in data.items)
                    parts.equipment[slot] = VirtualItem(item.displayId, cast(ubyte) item.itemClass,
                        cast(ubyte) item.subClass, cast(ubyte) item.details.material, item.inventoryType,
                        cast(ubyte) item.details.sheath);
        return parts;
    }

    /// See `CreatureLore.changeEntry`.
    bool changeEntry(Creature creature, uint entry)
    {
        import dmangos.world.creature : chooseDisplay;

        const t = entry in data.creatureTemplates;
        if (t is null || creature.template_.entry == entry)
            return false;
        const display = chooseDisplay(*t, spawnRandom);
        if (display == 0)
            return false;
        const level = creature.values.get!(dmangos.world.updatefields.UNIT_FIELD_LEVEL);
        auto parts = creatureParts(*t, creature.spawn.guid, display, level, t.equipmentTemplateId);
        creature.changeEntry(t, display, parts, client);
        return true;
    }

    /**
     * A creature made while event `shape.event` is on: its model, and its spell's auras (a transformation
     * takes the named creature's model). It is marked with the event, to be made again when it ends.
     */
    private void applyEventShape(Creature creature, const ref EventCreature shape)
    {
        import dmangos.world.auras : AuraType, makeAura;
        import dmangos.world.creature : chooseDisplay;
        import dmangos.world.updatefields : UNIT_FIELD_DISPLAYID, UNIT_FIELD_NATIVEDISPLAYID;

        creature.eventShape = shape.event;
        if (shape.model)
        {
            creature.values.set!UNIT_FIELD_DISPLAYID(shape.model);
            creature.values.set!UNIT_FIELD_NATIVEDISPLAYID(shape.model);
        }
        const spell = data.spells.spell(shape.spell);
        if (spell is null)
            return;
        enum uint applyAura = 6;
        int[3] amounts;
        bool any;
        foreach (i; 0 .. 3)
            if (spell.effect[i] == applyAura)
            {
                any = true;
                amounts[i] = spell.basePoints[i] + 1;
                if (spell.casting.applyAuraName[i] == AuraType.transform)
                    if (const t = cast(uint) spell.miscValue[i] in data.creatureTemplates)
                        if (const model = chooseDisplay(*t, spawnRandom))
                            creature.values.set!UNIT_FIELD_DISPLAYID(model);
            }
        if (!any)
            return;
        bool isNew;
        creature.auras.apply(makeAura(spell, creature.guid, creature.values.get!(dmangos.world.updatefields.UNIT_FIELD_LEVEL),
            -1, true, amounts), creature.values, isNew);
        creature.values.clearChanges();
    }

    /// The event whose `game_event_creature_data` spawn `guid` should be made with now (0: none).
    private ushort eventShapeOf(uint guid)
    {
        if (auto list = guid in data.eventCreatures)
            foreach (ref e; *list)
                if (gameEvents.isActive(e.event))
                    return e.event;
        return 0;
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
    // Migration (docs/CLUSTER.md)
    // -----------------------------------------------------------------------

    /// An object's state for its next owner; kind 0 for one that does not move (a player's corpse stays with its player).
    Migrant saveMigrant(MapObject object)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : MigrantKind;

        ByteWriter w;
        if (auto creature = cast(Creature) object)
        {
            if (creature.petOwner)
                return Migrant.init; // a pet stays with its owner, and moves with it (`petsOnLeave`)
            creature.saveState(w);
            return Migrant(MigrantKind.creature, creature.spawn.guid, 0, w.data);
        }
        auto gameObject = cast(GameObject) object;
        if (gameObject is null)
            return Migrant.init;
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
        auto gameObject = makeGameObject(&data.gameObjectSpawns[*at]);
        gameObject.loadState(r);
        return gameObject;
    }

    private size_t[uint] spawnIndex, gameObjectSpawnIndex; // spawn guid -> its place in the world data

    /// Puts a player in the world: on its map and in the lists of who is online.
    void enterWorld(OnlinePlayer who, bool shipsShown = false)
    in (who.character.guid !in online, "a character is in the world once")
    {
        import dmangos.world.worlddata : toLowerName;

        online[who.character.guid] = who;
        onlineByName[toLowerName(who.character.data.name)] = who;
        mapOf(who).add(who, shipsShown);
    }

    /// A player in the world was renamed (`.character rename`): it is found by its new name.
    void renamed(OnlinePlayer who, string oldName)
    {
        import dmangos.world.worlddata : toLowerName;

        onlineByName.remove(toLowerName(oldName));
        onlineByName[toLowerName(who.character.data.name)] = who;
    }

    /// Takes a player out of the world.
    void leaveWorld(OnlinePlayer who, Map from = null)
    {
        import dmangos.world.worlddata : toLowerName;

        if (who.character.guid !in online)
            return;
        // `from`: the map it was on, when its saved place is elsewhere already (a ghost saved at its graveyard).
        auto current = from !is null ? from : mapOf(who);
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
     * A packet for every player in the world, on every node; with
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

    /// A creature died: its respawn time is saved at once; it comes back when it says.
    void creatureDied(Creature creature)
    {
        import dmangos.script.api : CreatureDied, EntityRef;

        const summoned = creature.summon.type != TempSpawnType.none;
        if (creature.instanceId)
        {
            if (auto script = creature.instanceId in instanceScripts)
                script.raise(CreatureDied(EntityRef(creature.guid), EntityRef(creature.lootRecipient), summoned));
        }
        else if (auto script = creature.spawn.map in worldScripts) // open-world round 2
            script.raise(CreatureDied(EntityRef(creature.guid), EntityRef(creature.lootRecipient), summoned));
        if (creature.summon.type != TempSpawnType.none)
            return; // a summon never comes back
        if (creature.instanceId)
        {
            if (auto state = creature.instanceId in instances)
            {
                state.dead[creature.spawn.guid] = true; // until the instance resets
                database.saveInstanceRespawn(false, creature.spawn.guid, creature.instanceId,
                    state.resetAt ? state.resetAt : unixTime + 86_400);
            }
            return;
        }
        respawnAt[creature.spawn.guid] = creature.respawnAt;
        database.saveCreatureRespawn(creature.spawn.guid, creature.respawnAt);
    }

    /// A corpse went; one that died elsewhere (handed over dead) comes back a respawn time from now.
    private void corpseRemoved(Creature creature)
    {
        if (creature.petOwner)
        {
            import dmangos.world.character : Character;

            if (auto owner = cast(Character) onlinePlayer(creature.petOwner))
                if (owner.character !is null)
                    owner.petCorpseGone(creature);
            return;
        }
        if (creature.summon.type != TempSpawnType.none || creature.instanceId)
            return;
        if (creature.spawn.guid !in respawnAt)
        {
            respawnAt[creature.spawn.guid] = unixTime + creature.spawn.respawnSeconds;
            database.saveCreatureRespawn(creature.spawn.guid, respawnAt[creature.spawn.guid]);
        }
    }

    private uint summonsMade; // the summons' guid counters: above every spawn's, 65536 for each node

    /// A guid counter for an object of this run only (a summon, a fishing bobber): this node's range.
    uint nextTemporaryCounter()
    {
        return 0x00C0_0000 + (nodeId % 64) * 0x1_0000 + (++summonsMade & 0xFFFF);
    }

    /**
     * Summons a creature of `entry` at `at` on `world` (near `summoner` when
     * `at` is all zeros), not saved and never respawned, gone as `type` says after `durationMs`.
     */
    Creature summonCreature(CombatWorld world, uint entry, Position at, TempSpawnType type, uint durationMs,
        ulong summoner)
    {
        import std.math : cos, sin, PI;
        import std.random : uniform01;

        auto map = cast(Map) world;
        if (map is null || entry !in data.creatureTemplates)
            return null;
        if (at.x == 0 && at.y == 0 && at.z == 0)
        {
            // Near the summoner: a couple of yards from it, on the ground.
            Position from;
            if (auto who = map.find(summoner))
                from = who.character.position;
            else if (auto o = map.findObject(summoner))
                from = o.position;
            else
                return null;
            const angle = uniform01(spawnRandom) * 2 * PI;
            at = Position(from.x + 2 * cos(angle), from.y + 2 * sin(angle), from.z, from.orientation);
            const ground = map.groundHeight(at.x, at.y, from.z + 2, false);
            if (ground > -100_000)
                at.z = ground;
        }
        const counter = nextTemporaryCounter();
        CreatureSpawn spawn = {guid: counter, entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation};
        auto creature = makeCreature(&spawn);
        if (creature is null)
            return null;
        creature.summon = TempSpawn(type, durationMs, durationMs, summoner);
        creature.instanceId = map.instanceId;
        map.addObject(creature);
        map.wake(creature.guid);
        if (map.instanceId) // the dungeon's script hears of it as of any creature of the copy
            if (auto script = map.instanceId in instanceScripts)
            {
                import dmangos.script.api : CreatureLoaded, EntityRef;

                script.raise(CreatureLoaded(EntityRef(creature.guid)));
            }
        return creature;
    }

    /**
     * A pet's creature: of `entry`, at `at` on `map`, not yet on the map (the owner's
     * session makes it its pet and adds it). Null if there is no such creature or model.
     */
    Creature makePetCreature(Map map, uint entry, uint number, Position at)
    {
        if (map is null || entry !in data.creatureTemplates)
            return null;
        const counter = nextTemporaryCounter();
        CreatureSpawn spawn = {guid: counter, entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation};
        auto creature = makeCreature(&spawn, number);
        if (creature is null)
            return null;
        creature.summon = TempSpawn(TempSpawnType.manual, 0, 0, 0);
        creature.instanceId = map.instanceId;
        return creature;
    }

    /// See `CreatureLore.summon`.
    Creature summon(CombatWorld world, uint entry, Position at, uint type, uint durationMs, ulong summoner)
    {
        return summonCreature(world, entry, at, cast(TempSpawnType) type, durationMs, summoner);
    }

    /// See `CreatureLore.sameGroup`.
    bool sameGroup(ulong a, ulong b)
    {
        return groups.sameGroup(a, b);
    }

    /// See `CreatureLore.summonSpot`.
    bool summonSpot(uint id, out Position at, out uint seconds)
    {
        if (const spot = id in data.eventAi.summons)
        {
            at = spot.position;
            seconds = spot.seconds;
            return true;
        }
        return false;
    }

    private NoticeThrottle noticedLately; // a player moved for a creature: not again for a while

    /**
     * A player comes into sight of another node's creature (CLUSTER.md): if it would attack the
     * player on sight (an aggressive enemy, the player within its aggro radius and in sight), the
     * player moves to the creature's node, where the creature decides for itself. A player is moved
     * for the same creature once in 30 seconds, so one that does not attack after all is not
     * followed back and forth.
     */
    private void replicaNoticing(Inhabitant who, Replica replica)
    {
        import dmangos.world.combat : levelFor;
        import dmangos.world.creatureai : isNeutralToAll;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.inworld : ArrivalAction;
        import dmangos.world.relations : canAttack, isEnemy, Relating;
        import dmangos.world.character : Character;
        import dmangos.world.updatefields;

        auto session = cast(Character) who;
        if (session is null || replica.owner == nodeId)
            return;
        const values = &replica.fields();
        const template_ = values.get!OBJECT_FIELD_ENTRY in data.creatureTemplates;
        if (template_ is null || template_.detection == 0)
            return;
        const faction = client.factionTemplates.lookup(values.get!UNIT_FIELD_FACTIONTEMPLATE);
        if (faction is null || isNeutralToAll(*faction))
            return;
        const flags = values.get!UNIT_FIELD_FLAGS;
        if (flags & (UnitFlags.spawning | UnitFlags.uninteractible))
            return;
        const self = Relating(flags, faction, false, 0, 0, true), other = session.relating;
        if (!canAttack(self, other, client) || !isEnemy(self, other, client) || !session.fighter.alive
            || session.untouchable)
            return;
        // The creature's aggro radius against the player (as `CreatureAI.attackDistance`).
        const at = session.fighter.position, from = replica.position;
        int levelDiff = int(session.fighter.level) - int(values.get!UNIT_FIELD_LEVEL);
        if (levelDiff < -25)
            levelDiff = -25;
        float radius = template_.detection - levelDiff;
        if (radius < 5)
            radius = 5;
        if ((at.x - from.x) ^^ 2 + (at.y - from.y) ^^ 2 + (at.z - from.z) ^^ 2 > radius * radius)
            return;
        auto map_ = existingMap(session.character.data.map);
        if (map_ is null || !map_.inLineOfSight(from, at))
            return;
        if (!noticedLately.mayAct(session.character.guid, replica.guid, MonoTime.currTime))
            return;
        ArrivalAction action;
        action.noticedBy = replica.guid;
        session.actAtReplica(replica.guid, action);
    }

    // -----------------------------------------------------------------------
    // Spawns made and deleted by GMs (`.npc spawn`, `.gobject spawn`, the deletes)
    // -----------------------------------------------------------------------

    private uint lastCreatureSpawn, lastGameObjectSpawn; // the highest spawn guids, once looked up

    /**
     * A new `creature` row of `entry` at `at` on `map` (saved, in the world data and its cell, so that
     * it comes back when the cell loads again), and its creature there now; null if it cannot be made.
     */
    Creature spawnCreatureAt(Map map, uint entry, Position at)
    {
        import dmangos.world.grid : cellKeyAt;

        if (entry !in data.creatureTemplates)
            return null;
        if (lastCreatureSpawn == 0)
            foreach (ref s; data.creatureSpawns)
                if (s.guid > lastCreatureSpawn)
                    lastCreatureSpawn = s.guid;
        CreatureSpawn spawn = {guid: ++lastCreatureSpawn, entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation, respawnSeconds: 120, respawnSecondsMax: 120};
        data.creatureSpawns ~= spawn;
        const index = data.creatureSpawns.length - 1;
        data.creatureCells.require(map.id, null).require(cellKeyAt(at.x, at.y), null) ~= index;
        if (spawnIndex !is null)
            spawnIndex[spawn.guid] = index;
        database.insertCreatureSpawn(spawn);
        auto creature = makeCreature(&data.creatureSpawns[index]);
        if (creature is null)
            return null;
        creature.instanceId = map.instanceId;
        map.addObject(creature);
        return creature;
    }

    /// The creature's spawn deleted: gone from the map, the world data's cell and the database.
    void deleteCreatureSpawn(Map map, Creature creature)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.grid : cellKeyAt;

        const s = creature.spawn;
        if (auto cells = s.map in data.creatureCells)
            if (auto list = cellKeyAt(s.x, s.y) in *cells)
                foreach (i, index; *list)
                    if (data.creatureSpawns[index].guid == s.guid)
                    {
                        *list = (*list).remove(i);
                        break;
                    }
        respawnAt.remove(s.guid);
        map.removeObject(creature.guid);
        database.deleteCreatureSpawn(s.guid);
    }

    /// A new `gameobject` row of `entry` at `at` (facing as it), and its object there now; null if unknown.
    GameObject spawnGameObjectAt(Map map, uint entry, Position at, bool save)
    {
        import std.math : cos, sin;
        import dmangos.world.grid : cellKeyAt;

        if (entry !in data.gameObjectTemplates)
            return null;
        if (lastGameObjectSpawn == 0)
            foreach (ref s; data.gameObjectSpawns)
                if (s.guid > lastGameObjectSpawn)
                    lastGameObjectSpawn = s.guid;
        GameObjectSpawn spawn = {guid: ++lastGameObjectSpawn, entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation, rotation: [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)]};
        data.gameObjectSpawns ~= spawn;
        const index = data.gameObjectSpawns.length - 1;
        data.gameObjectCells.require(map.id, null).require(cellKeyAt(at.x, at.y), null) ~= index;
        if (gameObjectSpawnIndex !is null)
            gameObjectSpawnIndex[spawn.guid] = index;
        if (save)
            database.insertGameObjectSpawn(spawn);
        auto go = makeGameObject(&data.gameObjectSpawns[index]);
        go.instanceId = map.instanceId;
        map.addObject(go);
        return go;
    }

    /**
     * The game object's spawn changed (moved, turned): its row and the world data rewritten, and the
     * object made anew from it, so that the clients see it there. Returns the new object.
     */
    GameObject respawnGameObjectAs(Map map, GameObject go, GameObjectSpawn changed)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.grid : cellKeyAt;

        if (gameObjectSpawnIndex is null)
            foreach (i, ref s; data.gameObjectSpawns)
                gameObjectSpawnIndex[s.guid] = i;
        const at = go.spawn.guid in gameObjectSpawnIndex;
        if (at is null)
            return go;
        const old = data.gameObjectSpawns[*at];
        const oldCell = cellKeyAt(old.x, old.y), newCell = cellKeyAt(changed.x, changed.y);
        if (oldCell != newCell)
        {
            if (auto cells = old.map in data.gameObjectCells)
                if (auto list = oldCell in *cells)
                    foreach (i, index; *list)
                        if (index == *at)
                        {
                            *list = (*list).remove(i);
                            break;
                        }
            data.gameObjectCells.require(changed.map, null).require(newCell, null) ~= *at;
        }
        data.gameObjectSpawns[*at] = changed;
        database.deleteGameObjectSpawn(changed.guid);
        database.insertGameObjectSpawn(changed);
        map.removeObject(go.guid);
        auto made = makeGameObject(&data.gameObjectSpawns[*at]);
        made.instanceId = map.instanceId;
        map.addObject(made);
        return made;
    }

    /// The game object's spawn deleted: gone from the map, the world data's cell and the database.
    void deleteGameObjectSpawn(Map map, GameObject go)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.grid : cellKeyAt;

        const s = go.spawn;
        if (auto cells = s.map in data.gameObjectCells)
            if (auto list = cellKeyAt(s.x, s.y) in *cells)
                foreach (i, index; *list)
                    if (data.gameObjectSpawns[index].guid == s.guid)
                    {
                        *list = (*list).remove(i);
                        break;
                    }
        gameObjectRespawnAt.remove(s.guid);
        map.removeObject(go.guid);
        database.deleteGameObjectSpawn(s.guid);
    }

    /**
     * A trap (`GAMEOBJECT_TYPE_TRAP`) a player stepped near: one not friendly
     * to the player casts its spell at the player, then waits its cooldown; one with charges is used
     * up after them (and comes back with its spawn's respawn time).
     */
    package void trapSprung(Map map, Inhabitant who, GameObject trap)
    {
        import dmangos.world.gameobject : GoLootState;
        import dmangos.world.relations : isFriend, Relating;
        import dmangos.world.character : Character;

        auto session = cast(Character) who;
        if (session is null || session.character is null || !session.fighter.alive)
            return;
        if (unixTime < trap.trapReadyAt || trap.lootState != GoLootState.ready)
            return;
        const spell = cast(uint) trap.template_.data[3];
        if (spell == 0)
            return;
        // Unfriendly units only: not one the trap's faction likes.
        const faction = client.factionTemplates.lookup(trap.template_.faction);
        if (faction !is null && isFriend(Relating(0, faction, false, 0, 0, true), session.relating, client))
            return;
        // Open-world round 2: the trap's script may keep it from springing for this one.
        if (trap.behaviour)
        {
            import dmangos.script.api : TrapSprung;

            if (raiseObject(trap, map, TrapSprung(EntityRef(session.character.guid))))
                return;
        }
        // Instance round 2: a trap with a script is asked first (one only its creature springs refuses players).
        if (trap.behaviour && gameObjectUsed(trap, map, session.character.guid))
            return;
        trap.trapReadyAt = unixTime + (trap.template_.data[5] > 0 ? trap.template_.data[5] : 1);
        session.castTriggeredAt(spell, session.character.guid);
        const charges = trap.template_.data[4];
        if (charges > 0 && ++trap.trapUses >= charges)
            map.gameObjectUsedUp(trap);
    }

    /// See `CreatureLore.scriptText`.
    const(BroadcastText)* scriptText(int entry)
    {
        return entry in data.scriptTexts;
    }

    /// ditto
    uint scriptTextSound(int entry)
    {
        return data.scriptTextSounds.get(entry, 0);
    }

    /// See `CreatureLore.virtualItem`.
    VirtualItem virtualItem(uint entry)
    {
        if (const item = entry in data.items)
            return VirtualItem(item.displayId, cast(ubyte) item.itemClass, cast(ubyte) item.subClass,
                cast(ubyte) item.details.material, item.inventoryType, cast(ubyte) item.details.sheath);
        return VirtualItem.init;
    }

    /// See `CreatureLore.scriptRuntime`.
    @property ScriptRuntime scriptRuntime()
    {
        return scripts;
    }

    /// The script of spell `id` (`spell_scripts`); no handle if none serves it. One per spell.
    ScriptHandle spellScript(uint id)
    {
        return statelessScript(ScriptKind.spell, id, data.spellScriptNames, spellScripts);
    }

    /// The script of area trigger `id` (`scripted_areatrigger`); no handle if none serves it. One per trigger.
    ScriptHandle areaTriggerScript(uint id)
    {
        return statelessScript(ScriptKind.areaTrigger, id, data.areaTriggerScriptNames, areaTriggerScripts);
    }

    /// The script of scripted event `id` (`scripted_event_id`); no handle if none serves it. One per event.
    ScriptHandle eventScript(uint id)
    {
        return statelessScript(ScriptKind.event, id, data.eventScriptNames, eventScripts);
    }

    /// Open-world round 2: the script of item `entry` (`item_template.ScriptName`); no handle if none serves it.
    ScriptHandle itemScript(uint entry)
    {
        return statelessScript(ScriptKind.item, entry, data.itemScriptNames, itemScripts);
    }

    private ScriptHandle[uint] spellScripts, areaTriggerScripts, eventScripts, itemScripts; // made on first use (none: no script)

    private ScriptHandle statelessScript(ScriptKind kind, uint id, const string[uint] names, ref ScriptHandle[uint] made)
    {
        if (auto found = id in made)
            return *found;
        const name = id in names;
        return made[id] = name is null ? ScriptHandle.init : scripts.create(kind, *name);
    }

    /**
     * See `CreatureLore.signalCreature`: a `Signal` for creature `to` on `world`: its script here, or
     * (a replica here: another node simulates it) a `ScriptSignal` to that node.
     */
    ActionResult signalCreature(CombatWorld world, EntityRef from, EntityRef to, uint id, int value)
    {
        import dmangos.script.api : ActionResult;
        import dmangos.world.replication : Replica;

        auto map = cast(Map) world;
        if (map is null)
            return ActionResult.notHere;
        if (auto creature = map.creatureAt(to.guid))
        {
            creature.ai.signalled(from, id, value, map);
            return ActionResult.ok;
        }
        auto replica = cast(Replica) map.findObject(to.guid);
        if (replica is null || signalElsewhere is null)
            return ActionResult.notHere;
        ScriptSignal m;
        m.to = to.guid;
        m.from = from.guid;
        m.map = map.id;
        m.instance = map.instanceId;
        m.id = id;
        m.value = value;
        m.origin = nodeId;
        m.sequence = ++signalSequence;
        signalElsewhere(replica.owner, m);
        return ActionResult.ok;
    }

    // -----------------------------------------------------------------------
    // Guilds across the node (and, through these, the cluster)
    // -----------------------------------------------------------------------

    /// A guild's packet for its members online here whose rank has `right` (0: all).
    void guildToMembersHere(uint guild, Opcode opcode, const(ubyte)[] body_, uint right)
    {
        import dmangos.world.character : Character;

        auto g = guilds.find(guild);
        foreach (other; onlinePlayers)
            if (auto session = cast(Character) other)
                if (session.character !is null)
                {
                    const low = cast(uint) session.character.guid;
                    auto m = g is null ? null : g.member(low);
                    if (m is null && opcode != Opcode.SMSG_GUILD_EVENT)
                        continue;
                    if (m is null && guilds.of(low) !is null)
                        continue;
                    if (m is null && session.guildOfField != guild)
                        continue; // a disbanded guild's last word: to those who were in it
                    if (right && m !is null && !g.hasRight(m.rank, cast(GuildRight) right))
                        continue;
                    session.deliver(opcode, body_);
                }
    }

    /// The guild fields of every player here, from their guilds now.
    void guildFieldsHere()
    {
        import dmangos.world.character : Character;

        foreach (other; onlinePlayers)
            if (auto session = cast(Character) other)
                if (session.character !is null)
                    session.refreshGuildFields();
    }

    /// Another node changed guild `id`: read again (gone if it is gone), its members' fields here updated.
    void guildReloaded(uint id)
    {
        auto record = database.loadGuild(id);
        guilds.replace(id, record.isNull ? null : new Guild(record.get));
        guildFieldsHere();
    }

    /// An invitation from another node for a player here.
    void guildInvitationArrived(ulong target, uint guild, ulong inviter, string inviterName, string guildName)
    {
        import dmangos.world.character : Character;

        if (auto session = cast(Character) onlinePlayer(target))
            if (session.character !is null)
                session.guildInvite(guild, inviter, inviterName, guildName);
    }

    /// Guild news for the other nodes; null standalone.
    void delegate(uint guild) guildReloadElsewhere;
    /// ditto
    void delegate(uint guild, uint right, ushort opcode, const(ubyte)[] body_) guildBroadcastElsewhere;
    /// ditto
    void delegate(ushort node, ulong target, uint guild, ulong inviter, string inviterName, string guildName)
        guildInviteElsewhere;

    /// Tells the other nodes a player here logged in or out (for its friends there); null standalone.
    void delegate(ulong guid, bool online, ubyte status, uint area, uint level, uint classId) announceFriendElsewhere;

    /// Sends a script's signal to another node; null standalone.
    void delegate(ushort node, const ref ScriptSignal signal) signalElsewhere;
    private ulong signalSequence; // set at start-up above anything an earlier run of this node sent
    private ulong[ushort] signalsSeen; // node -> the highest sequence applied from it

    /// A script's signal from another node (`ScriptSignal`): applied once (a resent one is dropped),
    /// passed on if its creature has moved on again.
    void scriptSignalArrived(const ref ScriptSignal m)
    {
        import dmangos.script.api : EntityRef;
        import dmangos.world.replication : Replica;

        if (m.sequence <= signalsSeen.get(m.origin, 0))
            return;
        signalsSeen[m.origin] = m.sequence;
        auto map = existingMap(m.map, m.instance);
        if (map is null)
            return;
        if (auto creature = map.creatureAt(m.to))
            return creature.ai.signalled(EntityRef(m.from), m.id, m.value, map);
        if (auto replica = cast(Replica) map.findObject(m.to))
            if (m.hops < 3 && signalElsewhere !is null && replica.owner != nodeId)
            {
                ScriptSignal next = m;
                ++next.hops;
                signalElsewhere(replica.owner, next);
            }
    }

    /// See `CreatureLore.escortPath`.
    const(Waypoint)[] escortPath(uint entry)
    {
        return data.escortPaths.get(entry, null);
    }

    /// A game object's use, for its script: the object's script hears of `player` using it; true if
    /// it handled the use (the usual use does not follow).
    bool gameObjectUsed(GameObject go, Map map, ulong player)
    {
        import dmangos.script.api : GameObjectContext, ObjectUsed;

        if (go.instanceId) // Raid scripts: the copy's script hears of it first
            if (auto script = go.instanceId in instanceScripts)
            {
                import dmangos.script.api : ObjectUsedHere;

                script.raise(ObjectUsedHere(EntityRef(go.guid), EntityRef(player)));
            }
        if (!go.behaviour)
            return false;
        goHost.go = go;
        goHost.map = map;
        auto context = GameObjectContext(goHost);
        scripts.raise(go.behaviour, context, ObjectUsed(EntityRef(player)));
        goHost.go = null;
        goHost.map = null;
        noteTickingObject(go, map);
        return context.consumed;
    }

    /// A `Signal` for game object `go`'s script (from its dungeon's script); false if it has none.
    bool gameObjectSignalled(GameObject go, Map map, EntityRef from, uint id, int value)
    {
        import dmangos.script.api : GameObjectContext, Signal;

        if (!go.behaviour)
            return false;
        // A signal may come while another object's script runs (it signalled its dungeon): theirs is kept.
        auto before = goHost.go, beforeMap = goHost.map;
        goHost.go = go;
        goHost.map = map;
        auto context = GameObjectContext(goHost);
        scripts.raise(go.behaviour, context, Signal(from, id, value));
        goHost.go = before;
        goHost.map = beforeMap;
        noteTickingObject(go, map);
        return true;
    }

    // -----------------------------------------------------------------------
    // Open-world round 2: game object scripts' arrival, quests, traps and schedules
    // -----------------------------------------------------------------------

    private Map[ulong] tickingObjects;          // scripted game objects with steps pending, and their maps
    private GameObjectArrival[] objectArrivals; // scripted game objects put in the world, for `Spawned`

    private static struct GameObjectArrival
    {
        GameObject go;
        Map map;
    }

    /// Raises `event` for game object `go`'s script on `map`; whether the script consumed it.
    private bool raiseObject(E)(GameObject go, Map map, const E event)
    {
        import dmangos.script.api : GameObjectContext;

        if (!go.behaviour || !scripts.handles!E(go.behaviour))
            return false;
        // Another object's script may be running (it signalled, it summoned): theirs is kept.
        auto before = goHost.go, beforeMap = goHost.map;
        goHost.go = go;
        goHost.map = map;
        auto context = GameObjectContext(goHost);
        scripts.raise(go.behaviour, context, event);
        goHost.go = before;
        goHost.map = beforeMap;
        noteTickingObject(go, map);
        return context.consumed;
    }

    /// A game object's script with steps pending ticks from now on.
    private void noteTickingObject(GameObject go, Map map)
    {
        if (go.behaviour && scripts.busy(go.behaviour))
            tickingObjects[go.guid] = map;
    }

    /// A player accepted quest `quest` from game object `go`: its script hears of it.
    void gameObjectQuestAccepted(GameObject go, Map map, EntityRef player, uint quest)
    {
        import dmangos.script.api : QuestAccepted;

        raiseObject(go, map, QuestAccepted(player, quest));
    }

    /// A player was rewarded for quest `quest` by game object `go` (the Scarab Gong): its script hears of it.
    void gameObjectQuestRewarded(GameObject go, Map map, EntityRef player, uint quest)
    {
        import dmangos.script.api : QuestRewarded;

        raiseObject(go, map, QuestRewarded(player, quest));
    }

    /// The scripted game objects put in the world since the last tick hear `Spawned` (once their cell has
    /// loaded: what is near them is there), and those with steps pending tick `ms` on.
    private void gameObjectScriptsTick(int ms)
    {
        import dmangos.script.api : GameObjectContext, Spawned;

        if (objectArrivals.length)
        {
            auto arrived = objectArrivals;
            objectArrivals = null;
            foreach (a; arrived)
                if (a.map.findObject(a.go.guid) is a.go)
                    raiseObject(a.go, a.map, Spawned());
        }
        if (!tickingObjects.length)
            return;
        foreach (guid, map; tickingObjects.dup)
        {
            auto go = cast(GameObject) map.findObject(guid);
            if (go is null || !go.behaviour || !scripts.busy(go.behaviour))
            {
                tickingObjects.remove(guid);
                continue;
            }
            auto before = goHost.go, beforeMap = goHost.map;
            goHost.go = go;
            goHost.map = map;
            auto context = GameObjectContext(goHost);
            scripts.tick(go.behaviour, context, ms);
            goHost.go = before;
            goHost.map = beforeMap;
            if (!scripts.busy(go.behaviour))
                tickingObjects.remove(guid);
        }
    }

    private final class GoHost : GameObjectHost
    {
        GameObject go;
        Map map;

        EntityRef hostSelf()
        {
            return EntityRef(go.guid);
        }

        void hostDoor(bool open)
        {
            go.setDoorOpen(open);
            map.flushGameObject(go);
        }

        void hostSignalDungeon(uint id, int value)
        {
            if (go.instanceId)
                signalDungeon(go.instanceId, EntityRef(go.guid), id, value);
            else // open-world round 2: its continent's script
                signalWorld(map.id, EntityRef(go.guid), id, value);
        }

        void hostLog(string text)
        {
            import dmangos.log : info;

            info!"script %s (%s %s): %s"(scripts.nameOf(go.behaviour), go.template_.name, go.spawn.guid, text);
        }

        // Raid scripts:

        int hostAskDungeon(uint id)
        {
            return go.instanceId ? askDungeon(go.instanceId, EntityRef(go.guid), id) : 0;
        }

        // Open-world round 2:

        void hostCustomAnim()
        {
            import dmangos.bytes : ByteWriter;
            import dmangos.world.opcodes : Opcode;

            ByteWriter w;
            w.put(go.guid);
            w.put(0u);
            map.sendToObservers(go.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM, w.data);
        }

        void hostPlaySound(uint sound, bool music)
        {
            import dmangos.bytes : ByteWriter;
            import dmangos.world.opcodes : Opcode;

            ByteWriter w;
            w.put(sound);
            map.sendToObservers(go.guid, music ? Opcode.SMSG_PLAY_MUSIC : Opcode.SMSG_PLAY_SOUND, w.data);
        }

        ActionResult hostMoveCreature(EntityRef creature, Location at, uint point, bool run)
        {
            auto c = map.creatureAt(creature.guid);
            if (c is null || c.ai is null || !c.alive)
                return ActionResult.notHere;
            if (c.ai.inCombat)
                return ActionResult.notAllowed;
            c.ai.bind(map);
            c.ai.hostMoveTo(at, point, run);
            map.wake(c.guid);
            return ActionResult.ok;
        }

        ActionResult hostSendHome(EntityRef creature)
        {
            auto c = map.creatureAt(creature.guid);
            if (c is null || c.ai is null || !c.alive)
                return ActionResult.notHere;
            if (c.ai.inCombat)
                return ActionResult.notAllowed;
            sendCreatureHome(map, c);
            return ActionResult.ok;
        }

        bool hostHasItem(EntityRef player, uint item)
        {
            import dmangos.world.character : Character;

            auto session = cast(Character) onlinePlayer(player.guid);
            return session !is null && session.player !is null && session.player.inventory.count(item, false) > 0;
        }

        uint hostRandom(uint below)
        {
            import std.random : uniform;

            return below == 0 ? 0 : uniform(0, below);
        }

        uint hostMinuteOfDay()
        {
            import std.datetime.systime : Clock;

            const now = Clock.currTime();
            return now.hour * 60 + now.minute;
        }

        uint hostAreaId()
        {
            auto t = terrain(map.id);
            const p = go.position;
            return t is null || !t.knows(p.x, p.y) ? 0 : t.zoneAndArea(p.x, p.y, p.z)[1];
        }

        // The war effort:

        uint hostWarEffortPhase()
        {
            return warEffort.phase;
        }

        void hostWarEffortGong(EntityRef player)
        {
            import dmangos.log : info;
            import dmangos.world.wareffort : WarEffortGong, WarEffortGongReply;

            const who = player.guid;
            services.call!(WarEffortHost.gong)(WarEffortGong(who), (WarEffortGongReply r) {
                if (r.warBegan)
                    info!"the war effort: player %s rang the Scarab Gong; the ten-hour war begins"(who & 0xFFFF_FFFF);
            });
        }

        ActionResult hostZoneNotice(uint text)
        {
            import dmangos.world.battleground : battlegroundMessage;

            const said = data.npcs.broadcastTexts.get(text, BroadcastText.init);
            auto t = terrain(map.id);
            const p = go.position;
            if (said.maleText.length == 0 && said.femaleText.length == 0)
                return ActionResult.failed;
            if (t is null || !t.knows(p.x, p.y))
                return ActionResult.notHere;
            const zone = t.zoneAndArea(p.x, p.y, p.z)[0];
            const body_ = battlegroundMessage(ChatType.CHAT_MSG_BG_SYSTEM_NEUTRAL, said.text(false));
            foreach (player; online.values) // those this node simulates (a zone across nodes: each node's own)
                if (player.character !is null && player.character.data.map == map.id
                        && player.character.data.zone == zone)
                    player.deliver(Opcode.SMSG_MESSAGECHAT, body_);
            return ActionResult.ok;
        }

        // Eastern Kingdoms scripts:

        QuestProgress hostQuestStatus(EntityRef player, uint quest)
        {
            if (auto who = map.unit(player.guid))
                return who.questStatusOf(quest);
            return QuestProgress.none;
        }

        void hostQuestEvent(EntityRef player, uint quest)
        {
            if (auto who = map.unit(player.guid))
                who.questEventHappened(quest);
        }

        EntityRef hostObjectNearby(uint entry, float range)
        {
            return EntityRef(nearestGameObject(map, go.position, entry, range, go.guid));
        }

        ActionResult hostObjectOpen(EntityRef object, bool open)
        {
            auto other = cast(GameObject) map.findObject(object.guid);
            if (other is null)
                return ActionResult.notHere;
            other.setDoorOpen(open);
            map.flushGameObject(other);
            return ActionResult.ok;
        }

        ActionResult hostObjectFlags(EntityRef object, uint flags, bool set)
        {
            import dmangos.world.updatefields : GAMEOBJECT_FLAGS;

            auto other = cast(GameObject) map.findObject(object.guid);
            if (other is null)
                return ActionResult.notHere;
            const now = other.values.get!GAMEOBJECT_FLAGS;
            other.values.set!GAMEOBJECT_FLAGS(set ? now | flags : now & ~flags);
            map.flushGameObject(other);
            return ActionResult.ok;
        }

        EntityRef hostCreatureNearby(uint entry, float range)
        {
            foreach (c; map.creaturesNear(go.position, range))
                if (c.spawn.entry == entry && c.alive)
                    return EntityRef(c.guid);
            return EntityRef.init;
        }

        EntityRef hostSummon(uint entry, Location at, uint despawnMs, EntityRef attack)
        {
            import dmangos.world.creature : TempSpawnType;

            auto summoned = summonCreature(map, entry, Position(at.x, at.y, at.z, at.orientation),
                despawnMs ? TempSpawnType.timedOutOfCombatOrDead : TempSpawnType.dead, despawnMs, go.guid);
            if (summoned is null)
                return EntityRef.init;
            if (attack)
                if (auto victim = map.unit(attack.guid))
                    summoned.ai.attackedBy(victim, map);
            return EntityRef(summoned.guid);
        }

        ActionResult hostSayAs(EntityRef speaker, uint text, EntityRef target)
        {
            if (broadcastText(text) is null)
                return ActionResult.failed;
            auto c = map.creatureAt(speaker.guid);
            if (c is null || c.ai is null)
                return ActionResult.notHere;
            c.ai.sayFor(map, text, target.guid);
            return ActionResult.ok;
        }

        void hostKillCredit(EntityRef player, uint entry)
        {
            if (auto who = map.unit(player.guid))
                who.killCreditFrom(entry, go.guid);
        }

        // Kalimdor scripts:

        Location hostObjectLocation()
        {
            const p = go.position;
            return Location(p.x, p.y, p.z, p.orientation);
        }

        ActionResult hostObjectSignal(EntityRef to, uint id, int value)
        {
            return signalCreature(map, EntityRef(go.guid), to, id, value);
        }

        size_t hostObjectCreaturesNear(uint entry, float range, EntityRef[] found)
        {
            size_t n;
            foreach (c; map.creaturesNear(go.position, range))
                if (n < found.length && c.spawn.entry == entry && c.alive)
                    found[n++] = EntityRef(c.guid);
            return n;
        }

        ActionResult hostObjectCast(EntityRef caster, uint spell, EntityRef target)
        {
            import dmangos.world.character : Character;
            import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;

            if (auto creature = map.creatureAt(caster.guid))
                return creature.ai.castFor(map, spell, target.guid, true);
            auto session = cast(Character) onlinePlayer(caster.guid);
            if (session is null || session.player is null || session.currentMap !is map)
                return ActionResult.notHere;
            const info = data.spells.spell(spell);
            if (info is null)
                return ActionResult.failed;
            const self = !target || target.guid == caster.guid;
            const result = session.castSpell(info, SpellTargets(self ? TargetFlags.self : TargetFlags.unit,
                self ? caster.guid : target.guid), true, 0);
            return result == SpellCastResult.ok ? ActionResult.ok : ActionResult.notAllowed;
        }
    }

    /// The guid of the nearest game object of `entry` within `range` yards of `center` (not `except`); 0 if none.
    private static ulong nearestGameObject(Map map, Position center, uint entry, float range, ulong except = 0)
    {
        ulong best;
        float bestDistance = float.max;
        foreach (o; map.objectsNear(center, range))
            if (auto g = cast(GameObject) o)
                if (g.template_.entry == entry && g.guid != except)
                {
                    const p = g.position;
                    const d = (p.x - center.x) ^^ 2 + (p.y - center.y) ^^ 2 + (p.z - center.z) ^^ 2;
                    if (d <= range * range && d < bestDistance)
                    {
                        bestDistance = d;
                        best = g.guid;
                    }
                }
        return best;
    }

    /// See `CreatureLore.gameObjectNear`.
    ulong gameObjectNear(CombatWorld world, Position center, uint entry, float range)
    {
        auto map = cast(Map) world;
        return map is null ? 0 : nearestGameObject(map, center, entry, range);
    }

    /// See `CreatureLore.useGameObject`.
    ActionResult useGameObject(CombatWorld world, ulong guid)
    {
        auto map = cast(Map) world;
        auto g = map is null ? null : cast(GameObject) map.findObject(guid);
        if (g is null)
            return ActionResult.notHere;
        g.useDoorOrButton(map);
        return ActionResult.ok;
    }

    private GoHost goHost_;
    private @property GoHost goHost()
    {
        if (goHost_ is null)
            goHost_ = new GoHost;
        return goHost_;
    }

    /// See `CreatureLore.signalDungeon`.
    /// See `CreatureLore.spellList`.
    const(SpellListEntry)[] spellList(uint id)
    {
        return data.creatureSpellLists.get(id, null);
    }

    /// See `CreatureLore.displayOf`.
    uint displayOf(uint entry)
    {
        if (const t = entry in data.creatureTemplates)
            foreach (model; t.modelIds)
                if (model)
                    return model;
        return 0;
    }

    /// Raid scripts: the game object of the first spawn of `entry` on `map` (one not there by default) put
    /// in the world for `seconds` (0: for good); false if the map has no spawn of it.
    private bool respawnObjectOfEntry(Map map, uint entry, uint seconds)
    {
        foreach (ref spawn; data.gameObjectSpawns)
            if (spawn.entry == entry && spawn.map == map.id)
            {
                scriptSpawnGameObject(map, spawn.guid, null, seconds);
                return true;
            }
        return false;
    }

    /// Raid scripts: a game object of `entry` at `at` on `map`, of no spawn of the map's (it is in no
    /// other copy, and comes back nowhere), gone after `seconds` (0: with the map); null if there is no such object.
    private GameObject summonGameObjectAt(Map map, uint entry, Location at, uint seconds)
    {
        import std.math : cos, sin;

        if (entry !in data.gameObjectTemplates)
            return null;
        if (lastGameObjectSpawn == 0)
            foreach (ref s; data.gameObjectSpawns)
                if (s.guid > lastGameObjectSpawn)
                    lastGameObjectSpawn = s.guid;
        auto spawn = new GameObjectSpawn;
        *spawn = GameObjectSpawn(++lastGameObjectSpawn, entry, map.id, at.x, at.y, at.z);
        spawn.orientation = at.orientation;
        spawn.rotation = [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)];
        auto go = makeGameObject(spawn);
        go.instanceId = map.instanceId;
        map.addObject(go);
        if (seconds)
            scriptedGameObjects[go.guid] = unixTime + seconds;
        return go;
    }

    /// See `CreatureLore.askDungeon`.
    int askDungeon(uint instance, EntityRef from, uint id)
    {
        if (auto script = instance in instanceScripts)
            return script.ask(from, id);
        return 0;
    }

    /// Open-world round 2: see `CreatureLore.sendCreatureHome`.
    void sendCreatureHome(CombatWorld world, Creature c)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : PointMovement, selectMovement;

        // Back to its spawn point, walking, and then as it moves by itself (`MoveTargetedHome`).
        const home = c.spawn;
        c.generator = new PointMovement(Vector3(home.x, home.y, home.z), home.orientation, true,
            selectMovement(c, data.waypoints));
        c.generator.initialize(c, world);
        world.wake(c.guid);
    }

    /// Open-world round 2: a `Signal` for the script of continent `map` (nothing if it has none here).
    void signalWorld(uint map, EntityRef from, uint id, int value)
    {
        import dmangos.script.api : Signal;

        if (auto script = map in worldScripts)
            script.raise(Signal(from, id, value));
    }

    /// Open-world round 2: see `CreatureLore.signalWorldMap`.
    void signalWorldMap(CombatWorld world, EntityRef from, uint id, int value)
    {
        if (auto map = cast(Map) world)
            if (map.instanceId == 0)
                signalWorld(map.id, from, id, value);
    }

    /// Open-world round 2: see `CreatureLore.creaturePath`.
    const(imported!"dmangos.world.motion".WaypointNode)[] creaturePath(uint entry, uint guid)
    {
        return data.waypoints is null ? null : data.waypoints.defaultPath(entry, guid);
    }

    /// Open-world round 2: see `CreatureLore.zoneUnderAttack`.
    void zoneUnderAttack(CombatWorld world, Creature defender, ulong attacker)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.character : Character;
        import dmangos.world.unit : UnitKind;

        auto map = cast(Map) world;
        if (map is null)
            return;
        auto unit = map.unit(attacker);
        Character session;
        if (unit.kind == UnitKind.player)
            session = unit.session;
        else if (unit.kind == UnitKind.creature && unit.creature.petOwner)
            session = cast(Character) onlinePlayer(unit.creature.petOwner);
        if (session is null || session.player is null)
            return;
        auto t = terrain(map.id);
        const p = defender.position;
        if (t is null || !t.knows(p.x, p.y))
            return;
        const zone = t.zoneAndArea(p.x, p.y, p.z)[0];
        const enemies = client.teamForRace(session.player.data.race);
        ByteWriter w;
        w.put(zone);
        foreach (other; online)
            if (auto c = cast(Character) other)
                if (c.player !is null && client.teamForRace(c.player.data.race) != enemies)
                    c.deliver(Opcode.SMSG_ZONE_UNDER_ATTACK, w.data);
    }

    /// See `CreatureLore.signalDungeon`.
    void signalDungeon(uint instance, EntityRef from, uint id, int value)
    {
        import dmangos.script.api : Signal;

        if (auto script = instance in instanceScripts)
            script.raise(Signal(from, id, value));
    }

    /// See `CreatureLore.dungeonFight`.
    void dungeonFight(uint instance, EntityRef creature, EntityRef enemy)
    {
        import dmangos.script.api : CreatureEngaged, CreatureEvaded;

        if (auto script = instance in instanceScripts)
        {
            if (enemy)
                script.raise(CreatureEngaged(creature, enemy));
            else
                script.raise(CreatureEvaded(creature));
        }
    }

    /// Scripted event `event` (a spell's `SEND_EVENT`, a goober's event) happens on `map`, `source` using
    /// `target`: the dungeon copy's script hears of it, then (unless it consumed it) the event's database script runs.
    void scriptedEvent(uint event, Map map, ulong source, ulong target)
    {
        import dmangos.script.api : EntityRef, EventHappened;
        import dmangos.world.dbscripts : DbScriptType;

        if (map is null || event == 0)
            return;
        // Its own script (`@scriptedEvent`), around the player who started it or is its target.
        if (const handle = eventScript(event))
        {
            import dmangos.world.character : Character;

            auto player = cast(Character) onlinePlayer(source);
            if (player is null)
                player = cast(Character) onlinePlayer(target);
            if (player !is null && player.eventScript(handle, event, source, target))
                return; // the script did what the event does
        }
        if (map.instanceId)
            if (auto script = map.instanceId in instanceScripts)
                if (script.raise(EventHappened(event, EntityRef(source), EntityRef(target))))
                    return; // the script did what the event does
        startScript(DbScriptType.event, event, map, source, target);
    }

    /// See `CreatureLore.scriptedEvent`.
    void scriptedEvent(uint event, CombatWorld world, ulong source, ulong target)
    {
        scriptedEvent(event, cast(Map) world, source, target);
    }

    /// Open-world round 2: see `AreaTriggerContext.respawnObjectsNear` (a used-up object, or one not there by default).
    uint respawnObjectsNear(Map map, uint entry, Location near, float range, uint seconds)
    {
        return spawnDungeonObjects(map, entry, seconds, near, range > 0 ? range : 1);
    }

    /// See `InstanceContext.spawnObjects`: the game objects of `entry` on `map` (near a place) not in the world come.
    private uint spawnDungeonObjects(Map map, uint entry, uint despawnSeconds, Location near, float range)
    {
        import dmangos.world.objects : makeGuid, HighGuid;

        uint count;
        foreach (ref spawn; data.gameObjectSpawns)
            if (spawn.entry == entry && spawn.map == map.id
                && (range <= 0 || (spawn.x - near.x) ^^ 2 + (spawn.y - near.y) ^^ 2 + (spawn.z - near.z) ^^ 2 <= range * range)
                && map.findObject(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid)) is null)
            {
                scriptSpawnGameObject(map, spawn.guid, null, despawnSeconds);
                count += map.findObject(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid)) !is null;
            }
        return count;
    }

    /// See `CreatureLore.startRelay`.
    void startRelay(int id, CombatWorld world, ulong source, ulong target)
    {
        import dmangos.world.dbscripts : DbScriptType;

        const relay = id < 0 ? data.dbScripts.randomRelay(-id) : id;
        if (relay)
            startScript(DbScriptType.relay, relay, cast(Map) world, source, target);
    }

    /// `.respawn`: the corpse goes now, and the creature comes back in a second.
    void respawnSoon(Creature corpse, Map map)
    {
        if (corpse.instanceId)
        {
            // In an instance: it comes back now, there.
            if (auto state = corpse.instanceId in instances)
                state.dead.remove(corpse.spawn.guid);
            map.corpseExpired(corpse);
            if (auto back = makeCreature(&corpse.spawn))
            {
                back.instanceId = corpse.instanceId;
                map.addObject(back);
            }
            return;
        }
        respawnAt[corpse.spawn.guid] = unixTime + 1;
        database.saveCreatureRespawn(corpse.spawn.guid, respawnAt[corpse.spawn.guid]);
        map.corpseExpired(corpse);
    }

    /// Game objects used up: spawn guid -> when they come back (Unix time), as `gameobject_respawn` has it.
    private long[uint] gameObjectRespawnAt;

    /// A game object from its spawn, with what it needs to show players their quests' objects.
    GameObject makeGameObject(const(GameObjectSpawn)* spawn)
    {
        import dmangos.world.character : Character;

        auto go = new GameObject(*spawn, spawn.entry in data.gameObjectTemplates);
        if (isQuestObject(go))
            go.activatesFor = (ulong viewer) {
                auto session = cast(Character) onlinePlayer(viewer);
                return session !is null && session.gameObjectActivatesForQuest(go);
            };
        if (const name = spawn.entry in data.gameObjectScriptNames)
            if (scripts !is null && scripts.serves(ScriptKind.gameObject, *name))
            {
                go.scripts = scripts;
                go.behaviour = scripts.create(ScriptKind.gameObject, *name);
            }
        return go;
    }

    /// Whether a quest may need the object: a goober with a quest, or one an objective names; a chest with quest loot.
    bool isQuestObject(const GameObject go)
    {
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.loot : questItems;

        const t = go.template_;
        if (go.type == GameObjectType.goober)
            return t.data[1] > 0 || data.quests.namesGameObject(t.entry);
        if (go.type == GameObjectType.chest && go.lootId)
            if (const template_ = data.loot.gameObject[go.lootId])
                return questItems(template_).length > 0;
        return false;
    }

    /// A game object used up: it comes back after its spawn's respawn time.
    private void gameObjectUsedUp(GameObject go)
    {
        if (go.instanceId)
        {
            if (auto state = go.instanceId in instances)
            {
                state.usedUp[go.spawn.guid] = true;
                database.saveInstanceRespawn(true, go.spawn.guid, go.instanceId,
                    state.resetAt ? state.resetAt : unixTime + 86_400);
            }
            return;
        }
        const at = unixTime + (go.spawn.respawnSeconds > 0 ? go.spawn.respawnSeconds : 0);
        gameObjectRespawnAt[go.spawn.guid] = at;
        database.saveGameObjectRespawn(go.spawn.guid, at);
    }

    /// Whether a game object spawn is used up and waiting to come back.
    bool gameObjectAwaitingRespawn(uint spawnGuid)
    {
        if (auto at = spawnGuid in gameObjectRespawnAt)
            return *at > unixTime;
        return false;
    }

    /// The game objects whose time has come, made anew where their cell is loaded.
    private void gameObjectsDue()
    {
        const time = unixTime;
        uint[] due;
        foreach (guid, at; gameObjectRespawnAt)
            if (at <= time)
                due ~= guid;
        if (due.length && gameObjectSpawnIndex is null)
            foreach (i, ref spawn; data.gameObjectSpawns)
                gameObjectSpawnIndex[spawn.guid] = i;
        foreach (guid; due)
        {
            gameObjectRespawnAt.remove(guid);
            database.saveGameObjectRespawn(guid, 0);
            const index = guid in gameObjectSpawnIndex;
            if (index is null)
                continue;
            const spawn = &data.gameObjectSpawns[*index];
            auto there = existingMap(spawn.map);
            if (there !is null && there.cellLoaded(cellKeyAt(spawn.x, spawn.y)))
                there.addObject(makeGameObject(spawn));
        }
    }

    // -----------------------------------------------------------------------
    // Mail and auctions settled outside a session
    // -----------------------------------------------------------------------

    /**
     * Posts a letter: into the database, delivered after `delay` seconds; the
     * receiver, if online on any node and it is delivered now, hears of it.
     */
    void postMail(MailRecord mail, uint delay)
    {
        import dmangos.world.opcodes : Opcode;

        const now = unixTime;
        mail.id = nextMailId();
        mail.deliverTime = now + delay;
        mail.expireTime = mail.deliverTime + (mail.cod ? 3 : 30) * 24 * 60 * 60;
        database.sendMail(mail);
        if (delay == 0)
            deliverTo(mail.receiver, Opcode.SMSG_RECEIVED_MAIL, [ubyte(0), 0, 0, 0]);
    }

    /**
     * A mail from the auction house of `a` (the house as its sender): its subject
     * says what happened; `money`, the auctioned item (handed to the receiver) and a body as given.
     * A note with neither money nor item comes an hour later.
     */
    void auctionMail(uint receiver, const ref AuctionRecord a, AuctionMail what, uint money, bool withItem,
        string body = null)
    {
        enum ubyte mailAuction = 2, stationeryAuction = 62;
        enum uint checkCopied = 0x04;
        MailRecord m;
        m.messageType = mailAuction;
        m.stationery = stationeryAuction;
        m.sender = a.houseId;
        m.receiver = receiver;
        m.subject = auctionMailSubject(a, what);
        m.money = money;
        m.checked = checkCopied;
        if (body.length)
        {
            m.itemTextId = nextMailId();
            database.saveItemText(m.itemTextId, body);
        }
        if (withItem && a.itemGuid)
        {
            m.itemGuid = a.itemGuid;
            m.itemEntry = a.itemEntry;
            auto item = database.looseItem(a.itemGuid);
            if (!item.isNull)
                database.saveLooseItem(item.get, receiver); // now the receiver's
        }
        postMail(m, !withItem && !money ? 60 * 60 : 0);
    }

    /// The house of an auction (Stormwind's if it is not known).
    const(AuctionHouseEntry)* auctionHouse(uint houseId)
    {
        auto house = client.auctionHouses.lookup(houseId);
        return house !is null ? house : client.auctionHouses.lookup(1);
    }

    /**
     * An auction won, once it is out of the table: the seller gets the bid and its
     * deposit back less the house's cut, the buyer the item, and both hear of it if they are
     * online.
     */
    void auctionSold(const ref AuctionRecord a)
    {
        import std.format : format;
        import dmangos.world.opcodes : Opcode;

        const house = auctionHouse(a.houseId);
        const cut = house is null ? 0 : a.cut(*house);
        deliverTo(a.owner, Opcode.SMSG_AUCTION_OWNER_NOTIFICATION, ownerNotification(a, true));
        auctionMail(a.owner, a, AuctionMail.successful, a.bid + a.deposit - cut, false,
            format!"%16x:%s:%s:%s:%s"(a.bidder, a.bid, a.buyout, a.deposit, cut));
        deliverTo(a.bidder, Opcode.SMSG_AUCTION_BIDDER_NOTIFICATION, bidderNotification(a, true));
        auctionMail(a.bidder, a, AuctionMail.won, 0, true, format!"%16x:%s:%s"(a.owner, a.bid, a.buyout));
    }

    /// An auction expired: nobody bid; the item goes back to the seller.
    void auctionExpired(const ref AuctionRecord a)
    {
        import dmangos.world.opcodes : Opcode;

        deliverTo(a.owner, Opcode.SMSG_AUCTION_OWNER_NOTIFICATION, ownerNotification(a, false));
        auctionMail(a.owner, a, AuctionMail.expired, 0, true);
    }

    /// Outbid: the bid of `old` (the auction as it was) back to its bidder.
    void auctionOutbid(const ref AuctionRecord old)
    {
        import dmangos.world.opcodes : Opcode;

        deliverTo(old.bidder, Opcode.SMSG_AUCTION_BIDDER_NOTIFICATION, bidderNotification(old, false));
        auctionMail(old.bidder, old, AuctionMail.outbidded, old.bid, false);
    }

    /// The auctions over are settled (here only on the coordinator, or alone).
    private void settleAuctions()
    {
        foreach (ref a; database.expiredAuctions(unixTime))
        {
            if (!database.deleteAuction(a.id, a.bid))
                continue; // settled meanwhile (bought out)
            if (a.bid)
                auctionSold(a);
            else
                auctionExpired(a);
        }
    }
    private MonoTime lastAuctionCheck, lastMailCheck;

    /**
     * Old mail: a player's letter with an item, not returned or paid for
     * before, goes back to its sender for 30 days more; every other one whose time is up is deleted,
     * with its item and its body.
     */
    private void settleOldMail()
    {
        enum uint checkReturned = 0x02, checkCodPayment = 0x08;
        foreach (ref m; database.expiredMail(unixTime))
        {
            database.deleteMail(m.id);
            if (m.itemGuid && m.messageType == 0 && m.sender && !(m.checked & (checkReturned | checkCodPayment)))
            {
                MailRecord back;
                back.sender = m.receiver;
                back.receiver = m.sender;
                back.subject = m.subject;
                back.itemTextId = m.itemTextId;
                back.itemGuid = m.itemGuid;
                back.itemEntry = m.itemEntry;
                back.checked = checkReturned;
                if (auto item = database.looseItem(back.itemGuid))
                    database.saveLooseItem(item.get, back.receiver);
                postMail(back, 0);
                continue;
            }
            if (m.itemGuid)
                database.deleteLooseItem(m.itemGuid);
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
     * Respawning the dead (`DEAD`): once a second, the creatures whose time has come are
     * made anew at their spawn point, on maps whose cell they spawn in is loaded (elsewhere they come
     * when it loads).
     */
    void respawnDue(MonoTime now)
    {
        import core.time : seconds;

        if (now - lastRespawnCheck < 1.seconds)
            return;
        lastRespawnCheck = now;
        gameObjectsDue();
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
            {
                there.addObject(creature);
                linkedRespawn(there, creature);
            }
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
        if (first is null || second is null || first.character.data.map != second.character.data.map
            || first.instanceId != second.instanceId)
            return false;
        if (auto onMap = existingMap(first.character.data.map, first.instanceId))
            return onMap.seeEachOther(a, b);
        return false;
    }

    /// A channel command of `who`'s, for the channels service wherever it runs (docs/SERVICES.md).
    void channelCommand(const OnlinePlayer who, ChannelOp op, string channel, string arg = null,
        Language language = Language.LANG_UNIVERSAL)
    {
        services.call!(ChannelsHost.run)(ChannelCall(.channelCommand(who, op, channel, arg, language), nodeId));
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
     * Called every second by the server loop: runs the tick, and counts a shutdown down, warning
     * everyone as the time left passes each step. Returns true when the server should stop.
     */
    bool update(MonoTime now)
    {
        import dmangos.world.packets : ServerMessageType, ServerServerMessage;
        import dmangos.world.map : packetBody;
        import dmangos.world.opcodes : Opcode;

        // The world's tick, in its phases (docs/DESIGN.md, step 4).
        const elapsed = lastUpdate == MonoTime.init || now < lastUpdate ? Duration.zero : now - lastUpdate;
        if (now > lastUpdate)
            lastUpdate = now;
        const started = MonoTime.currTime;
        Duration[TickPhase.max + 1] spent;
        void timed(TickPhase phase, scope void delegate() run)
        {
            const before = MonoTime.currTime;
            isolated(phase, run); // one phase's fault does not skip the others
            spent[phase] += MonoTime.currTime - before;
        }
        timed(TickPhase.maps, () => mapsPhase(elapsed));
        timed(TickPhase.deaths, () => deathsPhase());
        timed(TickPhase.world, () => worldPhase(now, elapsed));
        // A slow tick says where its time went (net/server.d warns about it).
        if (MonoTime.currTime - started > 500.msecs)
        {
            import dmangos.log : warning;

            warning!"slow tick: %s ms in maps (players and objects), %s ms in deaths, %s ms in the world's timers"(
                spent[TickPhase.maps].total!"msecs", spent[TickPhase.deaths].total!"msecs",
                spent[TickPhase.world].total!"msecs");
        }

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

    /**
     * The tick's maps phase: on each map, its players, then its creatures and game
     * objects. A map's own players and objects tick together, which is the unit a map's
     * own thread will run. A player between two maps (the halves of a far teleport) ticks after.
     */
    private void mapsPhase(Duration elapsed)
    {
        updatedPlayers.clear();
        // Each player and each map apart: one that throws does not stop the others (it is logged and counted).
        void tickMap(Map map_)
        {
            foreach (who; map_.playersNow())
                if (auto player = cast(OnlinePlayer) who)
                    if (player.character !is null && player.character.guid !in updatedPlayers)
                    {
                        updatedPlayers[player.character.guid] = true;
                        isolated(player, () => player.update(elapsed));
                    }
            isolated(map_, () => map_.update(elapsed));
        }
        foreach (map_; maps.values)
            tickMap(map_);
        foreach (map_; instanceMaps.values)
            tickMap(map_);
        foreach (player; online.values) // a copy: an update may log a player out
            if (player.character !is null && player.character.guid !in updatedPlayers)
                isolated(player, () => player.update(elapsed));
    }

    /// Exceptions a tick caught and went on past (a phase, a map or a player's part skipped), since the start.
    ulong tickFaults;

    /**
     * Runs `part` of the tick; an `Exception` it throws is logged with what threw it (`where`) and counted,
     * and the tick goes on with the rest. `Error`s still end the process.
     */
    private void isolated(T)(T where, scope void delegate() part)
    {
        import dmangos.log : error;

        try
            part();
        catch (Exception e)
        {
            ++tickFaults;
            static if (is(T : Map))
                error!"tick: map %s (instance %s) failed and was skipped this tick: %s (%s:%s)"(where.id,
                    where.instanceId, e.msg, e.file, e.line);
            else static if (is(T : OnlinePlayer))
                error!"tick: player %s's update failed and was skipped this tick: %s (%s:%s)"(
                    where.character is null ? 0 : where.character.guid, e.msg, e.file, e.line);
            else
                error!"tick: the %s phase failed and was cut short: %s (%s:%s)"(where, e.msg, e.file, e.line);
        }
    }

    /// The tick's deaths phase: each creature that died is told to its dungeon's script, and its respawn is set.
    private void deathsPhase()
    {
        void drain(Map map_)
        {
            foreach (creature; map_.creatureDeaths.take())
                creatureDied(creature);
        }
        foreach (map_; maps)
            drain(map_);
        foreach (map_; instanceMaps)
            drain(map_);
    }

    /// The tick's world phase: what is not on one map: dungeon copies unloading, scripts, weather,
    /// respawns, auctions and old mail.
    /// Movement map tiles of areas that came into use, a few milliseconds' worth a tick (`Terrain.addPendingNavigation`).
    private void addPendingNavigation()
    {
        enum budget = 3.msecs;
        const until = MonoTime.currTime + budget;
        foreach (terrain; terrains)
        {
            const now = MonoTime.currTime;
            if (now >= until)
                break;
            terrain.addPendingNavigation(until - now);
        }
    }

    private void worldPhase(MonoTime now, Duration elapsed)
    {
        if (instances.length)
            unloadEmptyInstances(now);
        updateScripts(cast(uint) elapsed.total!"msecs");
        foreach (script; instanceScripts) // the dungeon scripts' own timers
            script.tick(cast(int) elapsed.total!"msecs");
        foreach (script; worldScripts) // open-world round 2: the continents'
            script.tick(cast(int) elapsed.total!"msecs");
        gameObjectScriptsTick(cast(int) elapsed.total!"msecs"); // open-world round 2
        updateWeathers(cast(int) elapsed.total!"msecs");
        addPendingNavigation();
        checkHonorWeek(now);
        services.tick(elapsed);
        battlegrounds.tick(elapsed);
        updateGameEvents(now);
        if (forwardGroup is null) // the coordinator, or alone (not while starting: who coordinates is not known yet)
        {
            eventMails();
            groupService.meetingStonesTick(elapsed); // the meeting stones' queue is the groups' keeper's
        }
        updateShips();
        linkFollowers();
        scriptedGameObjectsDue();
        respawnDue(now);
        // Auctions over are settled once a minute, by one node; first at the first tick. (Not `now - init`:
        // MonoTime counts from the machine's start, so that is its uptime, and an hour's check would
        // wait for the first hour after a reboot.)
        if (forwardGroup is null && (lastAuctionCheck == MonoTime.init || now - lastAuctionCheck >= 60.seconds))
        {
            lastAuctionCheck = now;
            settleAuctions();
        }
        // Old mail, once an hour, by one node.
        if (forwardGroup is null && (lastMailCheck == MonoTime.init || now - lastMailCheck >= 60.minutes))
        {
            lastMailCheck = now;
            settleOldMail();
        }
    }

    private bool[ulong] updatedPlayers; // the players the maps phase has updated this tick

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

    /// Creatures and game objects in the tick now (not resting), on every map.
    @property size_t tickingCount() const
    {
        size_t count;
        foreach (map_; maps)
            count += map_.tickingCount;
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
            {
                settleWrites(); // another node may load the account's characters next: they are saved first
                releaseSession(accountId, *serial);
            }
            serials.remove(session);
        }
    }

    /**
     * Waits until every write queued so far is in the database (docs/DESIGN.md, step 6): before another
     * node may load what this one saved. False if the database refused one of them (it is kept in the
     * file of failed writes, `dmangos.world.writebehind.failedPath`).
     */
    bool settleWrites()
    {
        if (writer !is null && !writer.settle())
        {
            imported!"dmangos.log".error!"the database refused a write while waiting for the writes (kept in the file of failed writes)"();
            return false;
        }
        return true;
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

    /// Ends every session (a cluster node whose lease lapsed: its writes are fenced, docs/CLUSTER.md).
    /// A standalone server hosts every service it provides (docs/SERVICES.md).
    void startAllServices()
    {
        foreach (kind; services.provided)
            if (!services.hosts(kind))
                services.start(kind);
    }

    /// The weekly honor maintenance ran (`dmangos.world.honorweek`): online players load their honor again.
    void honorMaintained()
    {
        import dmangos.world.session : WorldSession;

        foreach (session; sessions.values)
            if (auto world = cast(WorldSession) session)
                if (auto character = world.inWorld)
                    character.honorReckoned();
    }

    /// Whether this node keeps the honor week (a standalone server, or a cluster's coordinator).
    bool keepsHonorWeek = true;
    private MonoTime nextHonorCheck;

    /// Checks every 10 minutes whether the honor week's maintenance is due, and runs it.
    private void checkHonorWeek(MonoTime now)
    {
        import core.time : minutes;
        import dmangos.log : error;
        import dmangos.world.honorweek : runHonorMaintenance;

        if (!keepsHonorWeek || now < nextHonorCheck)
            return;
        nextHonorCheck = now + 10.minutes;
        try
            runHonorMaintenance(this);
        catch (Exception e)
            error!"honor maintenance failed: %s"(e.msg);
    }

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

/// NPC services across nodes: a replica of a creature is served through a stand-in.
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
    auto actual = new Creature(spawn, (2046 in context.data.creatureTemplates), 1, 10, parts, testClientData());

    auto replica = new Replica(actual.guid, 2, encodeState(actual, 0));
    auto npc = context.npcFor(replica);
    assert(npc !is null && npc.npcTemplate.entry == 2046 && npc.spawnId == 80339);
    assert(npc.npcValues.get!UNIT_NPC_FLAGS == (4 | 4096) && npc.position == actual.position);
    assert(context.npcFor(replica) is npc, "one stand-in per creature: its vendor stock lasts");
    assert(context.npcFor(actual) is actual && context.npcFor(null) is null);
}

// Game events: a creature of an event is away while it is off, comes when it starts, and goes when it ends.
unittest
{
    import dmangos.world.gameevents : GameEvent, ScheduleType;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.creatureGameEvents[innkeeperSpawn] = 5;
    const now = context.unixTime;
    context.gameEvents.events[5] = GameEvent(5, ScheduleType.date, now + 3600, now + 7200, 1440, 60, 0, "test");
    context.updateGameEvents(context.clock(), true);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const guid = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    assert(context.map(0).findObject(guid) is null, "its event has not started");

    context.gameEvents.events[5].start = now - 60; // it is on now
    context.updateGameEvents(context.clock(), true);
    assert(context.gameEvents.isActive(5) && context.map(0).findObject(guid) !is null, "it came with its event");

    context.gameEvents.events[5].end = now - 1; // and over
    context.updateGameEvents(context.clock(), true);
    assert(context.map(0).findObject(guid) is null, "it went when the event ended");
}

// Linked creatures: a pack's follower follows its master, and joins the fight when the master is attacked.
unittest
{
    import core.time : msecs, MonoTime;
    import dmangos.world.creaturelinking : LinkFlag;
    import dmangos.world.motion : FollowMovement;
    import dmangos.world.movement : Position;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.creatureLinks.addGuid(bankerSpawn, innkeeperSpawn, LinkFlag.aggroOnAggro | LinkFlag.follow);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f)); // facing the innkeeper
    anduin.read();
    now += 100.msecs;
    context.update(now);
    auto m = context.map(0);
    auto innkeeper = cast(Creature) m.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto banker = cast(Creature) m.findObject(makeGuid(HighGuid.unit, creatureBanker, bankerSpawn));
    assert(innkeeper !is null && banker !is null);
    auto follower = cast(FollowMovement) banker.generator;
    assert(follower !is null && follower.leader == innkeeper.guid, "the follower follows its master");

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper.guid));
    foreach (_; 0 .. 20)
    {
        now += 2000.msecs;
        anduin.session.update(2000.msecs);
        if (innkeeper.ai.inCombat)
            break;
    }
    assert(innkeeper.ai.inCombat && banker.ai.inCombat, "attacking the master brings in its pack");
}

// A formation: its leader walks the formation's path, the others take their places behind it.
unittest
{
    import core.time : msecs, MonoTime;
    import std.math : isClose, PI;
    import dmangos.world.creaturelinking : Formation;
    import dmangos.world.motion : FollowMovement, WaypointMovement, WaypointNode;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.formations[1] = Formation(1, 3, 77, 2); // single file, 3 yards apart, path 77
    context.data.formationSlots[innkeeperSpawn] = [1, 0];
    context.data.formationSlots[bankerSpawn] = [1, 1];
    context.data.waypoints.addPathNode(77, WaypointNode(1, -8951, -130, 83.5f));
    context.data.waypoints.addPathNode(77, WaypointNode(2, -8960, -130, 83.5f));
    context.data.waypoints.finish();
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    now += 100.msecs;
    context.update(now);
    auto m = context.map(0);
    auto leader = cast(Creature) m.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto member = cast(Creature) m.findObject(makeGuid(HighGuid.unit, creatureBanker, bankerSpawn));
    assert(cast(WaypointMovement) leader.generator !is null, "the leader walks the path");
    auto place = cast(FollowMovement) member.generator;
    assert(place !is null && place.leader == leader.guid && isClose(place.distance, 3) && isClose(place.angle, PI),
        "the member follows three yards behind");
}

// A pack member linked to come back when its master dies does: dead before it, it respawns as the master falls.
unittest
{
    import core.time : msecs, MonoTime;
    import dmangos.world.creaturelinking : LinkFlag;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.creatureLinks.addGuid(bankerSpawn, innkeeperSpawn, LinkFlag.respawnOnDeath);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    now += 100.msecs;
    context.update(now);
    auto m = context.map(0);
    const bankerGuid = makeGuid(HighGuid.unit, creatureBanker, bankerSpawn);
    auto innkeeper = cast(Creature) m.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto banker = cast(Creature) m.findObject(bankerGuid);
    void kill(Creature c)
    {
        c.values.set!UNIT_FIELD_HEALTH(0u);
        m.creatureDeath(c);
    }
    kill(banker);
    assert(!banker.alive);
    kill(innkeeper);
    now += 1100.msecs;
    context.update(now);
    auto back = cast(Creature) m.findObject(bankerGuid);
    assert(back !is null && back.alive, "the banker came back as the innkeeper fell");
}

// Game events change creatures (`game_event_creature_data`): while one is on, its spawn is made with the event's
// model; when it ends, the creature is made again as it was.
unittest
{
    import dmangos.world.gameevents : GameEvent, ScheduleType;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_DISPLAYID;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    context.data.eventCreatures[bankerSpawn] = [EventCreature(6, 0, 4242, 0, 0)];
    const now = context.unixTime;
    context.gameEvents.events[6] = GameEvent(6, ScheduleType.date, now + 3600, now + 7200, 1440, 60, 0, "test");
    context.updateGameEvents(context.clock(), true);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const guid = makeGuid(HighGuid.unit, creatureBanker, bankerSpawn);
    auto m = context.map(0);
    const usual = (cast(Creature) m.findObject(guid)).values.get!UNIT_FIELD_DISPLAYID;
    assert(usual != 4242);

    context.gameEvents.events[6].start = now - 60;
    context.updateGameEvents(context.clock(), true);
    auto dressed = cast(Creature) m.findObject(guid);
    assert(dressed.values.get!UNIT_FIELD_DISPLAYID == 4242 && dressed.eventShape == 6, "the event's model");

    context.gameEvents.events[6].end = now - 1;
    context.updateGameEvents(context.clock(), true);
    auto plain = cast(Creature) m.findObject(guid);
    assert(plain !is dressed && plain.eventShape == 0 && plain.values.get!UNIT_FIELD_DISPLAYID != 4242, "as it was");
}

// A pack member linked to go with its master goes when its master is made to go.
unittest
{
    import core.time : msecs, MonoTime;
    import dmangos.world.creaturelinking : LinkFlag;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    context.data.creatureLinks.addGuid(bankerSpawn, innkeeperSpawn, LinkFlag.despawnOnDespawn);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    now += 100.msecs;
    context.update(now);
    auto m = context.map(0);
    const keeperGuid = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    const bankerGuid = makeGuid(HighGuid.unit, creatureBanker, bankerSpawn);
    (cast(Creature) m.findObject(keeperGuid)).ai.despawnFor(m, 0);
    now += 100.msecs;
    m.update(100.msecs);
    m.update(100.msecs);
    assert(m.findObject(keeperGuid) is null, "the master gone");
    assert(m.findObject(bankerGuid) is null, "its slave with it");
}

// A game event's letters: sent as it starts to the characters of its races, once; a restart with it on sends none.
unittest
{
    import dmangos.world.gameevents : GameEvent, ScheduleType;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.worlddata : EventMail;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const now = context.unixTime;
    context.gameEvents.events[5] = GameEvent(5, ScheduleType.date, now + 3600, now + 7200, 1440, 60, 0, "test");
    context.data.gameEventMails[5] = [EventMail(0x1, 0, 0, 16285)]; // to humans
    context.data.gameEventMails[-5] = [EventMail(0x2, 0, 0, 16285)]; // to orcs, as it ends: none here
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    context.updateGameEvents(context.clock(), true);
    context.eventMails();
    assert(db.mails.length == 0, "not on yet");

    context.gameEvents.events[5].start = now - 60;
    context.updateGameEvents(context.clock(), true);
    context.eventMails();
    context.eventMails();
    assert(db.mails.length == 1 && db.mails.values[0].receiver == 7 && db.mails.values[0].sender == 16285, "one letter");
    assert(db.gameEventStatusRows.keys == [ushort(5)]);

    auto restarted = newCreationContext(db); // the same database: the event was on
    restarted.gameEvents.events[5] = context.gameEvents.events[5];
    restarted.data.gameEventMails = context.data.gameEventMails;
    restarted.updateGameEvents(restarted.clock(), true);
    restarted.eventMails();
    assert(db.mails.length == 1, "nothing again after a restart");

    restarted.gameEvents.events[5].end = now - 1;
    restarted.updateGameEvents(restarted.clock(), true);
    restarted.eventMails();
    assert(db.mails.length == 1 && db.gameEventStatusRows.length == 0, "its end: no orcs to write to");
}

/**
 * When each player last moved to another node for a creature that noticed it: not again for the same pair
 * within `quiet`. Keyed by the pair itself (two guids XORed together collide between pairs).
 */
struct NoticeThrottle
{
    private static struct Pair
    {
        ulong player, creature;
    }

    enum quiet = 30.seconds;
    private MonoTime[Pair] last;

    /// Whether `player` may move for `creature` now; if so, it is noted.
    bool mayAct(ulong player, ulong creature, MonoTime now)
    {
        const key = Pair(player, creature);
        if (auto when = key in last)
            if (now - *when < quiet)
                return false;
        last[key] = now;
        if (last.length > 4096)
            foreach (k, when; last.dup)
                if (now - when >= quiet)
                    last.remove(k);
        return true;
    }
}

// Pairs whose guids XOR to the same value are told apart; the same pair waits its quiet time.
unittest
{
    NoticeThrottle t;
    const now = MonoTime.currTime;
    assert(t.mayAct(1, 2, now));
    assert(t.mayAct(2, 1, now), "1^2 == 2^1, but these are different pairs");
    assert(t.mayAct(3, 0, now), "and so is 3^0");
    assert(!t.mayAct(1, 2, now + 29.seconds));
    assert(t.mayAct(1, 2, now + 31.seconds));
}

// Instance round 2: in a dungeon copy too a linked creature comes back (a boss's wipe or death brings its
// adds back): alive again at once, and no longer counted dead in the copy.
unittest
{
    import core.time : msecs, MonoTime;
    import dmangos.world.creaturelinking : LinkFlag;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;
    import dmangos.auth.accounts : AccountLevel;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    const addAt = Position(-20, -383, 61), bossAt = Position(-25, -383, 61);
    context.data.creatureSpawns ~= CreatureSpawn(90080, creatureBanker, mapDeadmines, addAt.x, addAt.y, addAt.z);
    context.data.creatureCells[mapDeadmines][cellKeyAt(addAt.x, addAt.y)] ~= context.data.creatureSpawns.length - 1;
    context.data.creatureSpawns ~= CreatureSpawn(90081, creatureInnkeeper, mapDeadmines, bossAt.x, bossAt.y, bossAt.z);
    context.data.creatureCells[mapDeadmines][cellKeyAt(bossAt.x, bossAt.y)] ~= context.data.creatureSpawns.length - 1;
    context.data.creatureLinks.addGuid(90080, 90081, LinkFlag.respawnOnDeath);

    const outside = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto hero = loggedIn(context, db, 7, "Varian", outside, AccountLevel.administrator, raceHuman, mapEasternKingdoms, 60);
    hero.say(".worldport 36 -18 -381 61");
    hero.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    hero.read();
    auto m = context.instanceMap(hero.session.inWorld.instanceId);
    const addGuid = makeGuid(HighGuid.unit, creatureBanker, 90080);
    auto add = cast(Creature) m.findObject(addGuid);
    auto boss = cast(Creature) m.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, 90081));
    assert(add !is null && boss !is null);
    void kill(Creature c)
    {
        c.values.set!UNIT_FIELD_HEALTH(0u);
        m.creatureDeath(c);
    }
    kill(add);
    now += 100.msecs;
    context.update(now); // the deaths phase
    assert(!add.alive && context.deadInInstance(m.instanceId, 90080));
    kill(boss);
    now += 1100.msecs;
    context.update(now);
    auto back = cast(Creature) m.findObject(addGuid);
    assert(back !is null && back.alive && !context.deadInInstance(m.instanceId, 90080), "the add came back");
}
