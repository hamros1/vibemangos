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

import dmangos.cluster.protocol : PartyQuest;
import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.cluster.services : ServiceHost, ServiceKind;
import dmangos.world.writebehind : Writer;
static import dmangos.world.updatefields;
import core.time : Duration, minutes, MonoTime, msecs, seconds;

import std.path : buildPath;
import std.random : Random, unpredictableSeed;
import std.typecons : Nullable, Tuple;

import dmangos.auth.accounts : AccountLevel;
import dmangos.auth.database : LoginDatabase, MemoryLoginDatabase;
import dmangos.cluster.node : SessionHandler;
import dmangos.cluster.ownership : IdCounters, IdKind, IdPool;
import dmangos.cluster.protocol : PresenceEntry;
import dmangos.world.whisper : WhisperFrom;
import dmangos.cluster.regions : Region, RegionState;
import dmangos.world.creature : Creature, CreatureParts, CreatureSpawn, CreatureTemplate, Npc, NpcStandIn, TempSpawn, TempSpawnType, VirtualItem;
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectType;
import dmangos.world.auctionhouse;
import dmangos.world.database : MailRecord;
import dmangos.world.movement : Position;
import dmangos.world.migration : Migrant, encodeBundle;
import dmangos.world.replication : Replica, Replicator;
import dmangos.world.channel : ChannelSettings;
import dmangos.world.grid : cellKeyAt;
import dmangos.world.channelservice : channelCommand, ChannelCall, ChannelOp, ChannelService, ChannelsHost;
import dmangos.world.battleground : Battlegrounds;
import dmangos.world.gameevents : GameEvents, scheduleFor;
import dmangos.world.creaturelinking : CreatureLink, inLinkRange, LinkFlag;
import dmangos.world.creatureai : LinkEvent;
import dmangos.world.objects : HighGuid, highGuidOf, makeGuid, temporaryCounterStart, UpdateValues;
import dmangos.world.unit : UnitKind, UnitRef;
import dmangos.world.bgqueue : battlegroundOfMap, BattlegroundQueue, BattlegroundQueueHost;
import dmangos.world.scourge : InvasionHost, InvasionState;
import dmangos.world.wareffort : WarEffort, WarEffortHost;
import dmangos.world.worldpvp : WorldPvp, WorldPvpFollower, WorldPvpHost;
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
import dmangos.world.database : InstanceChestRecord, WorldDatabase;
import dmangos.world.creaturepools : CreaturePools;
import dmangos.vmap.gameobjectmodels : GameObjectModels;
import dmangos.world.gameobjectcollision : GameObjectCollision;
import dmangos.world.elevators : ElevatorPath;
import dmangos.vmap.maptree : ModelCache;
import dmangos.world.terrain : Terrain;
import dmangos.world.group : GroupDirectory, Groups, memberStatus, MemberStatus;
import dmangos.world.groupservice : groupCommand, GroupOp, GroupService;
import dmangos.cluster.protocol : AreaDamage, CreatureLoan, CreatureSwing, GameObjectSpell, GmRemote, GroupCommand, GroupLootRoll,
    KillShare, LootCoinShare, PartyHeal, PeriodicResult, QuestLootCheck, ScriptSignal, SwingRetaliation;
import dmangos.world.loot : Loot, maxLootItems;
import dmangos.world.map : Inhabitant, Map, MapObject, MapSettings, VisibilityFacts;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.character : Character;
import dmangos.world.playercreate : CreationSettings;
import dmangos.world.spellids : ImplicitTarget, SpellEffect;
import dmangos.world.worlddata : EventCreature, EventMail, PoolMember, Ship, SpellListEntry, WorldData;

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

/// A dungeon or raid copy an account went into, and when (Unix time).
struct InstanceEntry
{
    uint instance; /// 0: one not known where it was counted (a copy another node was to make)
    long at;
}

/// The most dungeon and raid copies an account goes into in an hour (docs/FORMULAS.md, "Instances per hour").
enum maxInstancesPerHour = 5;

/// The entries of `entries` made less than an hour before `now`.
InstanceEntry[] withinTheHour(InstanceEntry[] entries, long now) pure nothrow @safe
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    return entries.filter!(e => now - e.at < 3600).array;
}

/// Whether, having gone into `recent` within the hour, going into copy `instance` (0: a new one) is one too many.
bool tooManyInstances(const(InstanceEntry)[] recent, uint instance) pure nothrow @nogc @safe
{
    import std.algorithm.searching : canFind;

    if (instance && recent.canFind!(e => e.instance == instance))
        return false;
    return recent.length >= maxInstancesPerHour;
}

unittest
{
    InstanceEntry[] recent = [InstanceEntry(11, 1000), InstanceEntry(12, 1100), InstanceEntry(13, 1200),
        InstanceEntry(14, 1300)];
    assert(!tooManyInstances(recent, 0), "a fifth");
    recent ~= InstanceEntry(15, 1400);
    assert(tooManyInstances(recent, 0) && tooManyInstances(recent, 16), "a sixth new copy within the hour");
    assert(!tooManyInstances(recent, 12), "back into one of the five");
    assert(withinTheHour(recent, 4600).length == 4 && !tooManyInstances(withinTheHour(recent, 4600), 0),
        "the first an hour old: room for another");
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

    import dmangos.world.weatherservice : WeatherHost, WeatherNotice, WeatherWatch;

    private WeatherNotice[uint] realmWeather;
    private MonoTime[uint] nextWeatherRequest;
    private MonoTime nextWeatherPoll;
    private ushort lastWeatherHost;

    /**
     * Weather for a player entering a zone. The service sends the current state if the worker
     * has not heard it yet. Zones without a `game_weather` row are always fine.
     */
    ubyte[] weatherFor(uint zone)
    {
        import dmangos.world.weather : fineWeatherPacket;

        if (zone !in data.weatherChances)
            return fineWeatherPacket();
        if (auto host = services.local!WeatherHost())
        {
            const request = WeatherWatch(zone);
            const current = host.watch(request);
            realmWeather[zone] = current;
            return current.packet();
        }
        watchWeather(zone, clock());
        if (const current = zone in realmWeather)
            return current.packet();
        return fineWeatherPacket();
    }

    private void watchWeather(uint zone, MonoTime now)
    {
        import core.time : seconds;

        if (now < nextWeatherRequest.get(zone, MonoTime.init))
            return;
        nextWeatherRequest[zone] = now + 30.seconds;
        const host = weatherHostNode();
        const before = realmWeather.get(zone, WeatherNotice.init);
        services.call!(WeatherHost.watch)(WeatherWatch(zone), (WeatherNotice current) {
            if (host == weatherHostNode() && before == realmWeather.get(zone, WeatherNotice.init))
                weatherHeard(current);
        });
    }

    private ushort weatherHostNode()
    {
        return services.placement is null ? 0 : services.placement(ServiceKind.weather);
    }

    private void pollWeather(MonoTime now)
    {
        import core.time : seconds;

        const host = weatherHostNode();
        if (lastWeatherHost != host)
        {
            lastWeatherHost = host;
            nextWeatherRequest = null;
            nextWeatherPoll = MonoTime.init;
        }
        if (now < nextWeatherPoll || !data.weatherChances.length)
            return;
        nextWeatherPoll = now + 5.seconds;
        foreach (player; online)
            if (player.character !is null && player.character.data.zone in data.weatherChances)
                watchWeather(player.character.data.zone, now);
    }

    private void weatherHeard(const ref WeatherNotice current)
    {
        import dmangos.world.opcodes : Opcode;

        if (current.zone !in data.weatherChances || realmWeather.get(current.zone, WeatherNotice.init) == current)
            return;
        realmWeather[current.zone] = current;
        const body_ = current.packet();
        foreach (player; online.values)
            if (player.character !is null && player.character.data.zone == current.zone)
                player.deliver(Opcode.SMSG_WEATHER, body_);
    }

    import dmangos.world.worldcatalog : WorldCatalog, WorldCatalogKey;

    private MonoTime nextCatalogPoll;
    private ulong[WorldCatalogKey] loadedCatalogVersions;

    private void pollWorldCatalog(MonoTime now)
    {
        import core.time : seconds;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!config.cluster.nodeId || now < nextCatalogPoll)
            return;
        nextCatalogPoll = now + 5.seconds;
        try
        {
            foreach (ref version_; database.worldCatalogVersions())
            {
                const key = version_.key;
                if (!version_.pending && loadedCatalogVersions.get(key, 0) == version_.revision)
                    continue;
                final switch (key.catalog)
                {
                case WorldCatalog.vendor:
                    data.npcs.vendors[key.entry] = database.loadVendorItems(key.entry);
                    break;
                case WorldCatalog.questStarter:
                    data.quests.creatureStarts[key.entry] = database.loadCreatureQuestRelations(true, key.entry);
                    break;
                case WorldCatalog.questFinisher:
                    data.quests.creatureEnds[key.entry] = database.loadCreatureQuestRelations(false, key.entry);
                    break;
                case WorldCatalog.creatureScale:
                    const scale = database.loadCreatureScale(key.entry);
                    if (!scale.isNull)
                        if (auto creature = data.creatureTemplates.edit(key.entry))
                            creature.scale = scale.get;
                    break;
                case WorldCatalog.teleports:
                    data.setTeleports(database.loadAreaTriggerTeleports(), database.loadTeleports(), client);
                    break;
                }
                loadedCatalogVersions[key] = version_.revision;
            }
        }
        catch (DatabaseException error)
            warning!"world catalog updates will be retried: %s"(error.msg);
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
    private GameObjectModels gameObjectModels;

    /// Players in the world, by guid and by lower-cased name.
    private Character[ulong] online;
    private Character[dstring] onlineByName;

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
        uint level;  // known if the player just migrated from this node
    }
    private Heard[ulong] lastHeard;   // temporary routing until presence catches up with a player
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
    bool delegate(ushort) gatewayReachable; /// whether a gateway can receive a saved handoff

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
    void enterWorldMigrated(Character who, const(ulong)[] known)
    {
        import dmangos.world.worlddata : toLowerName;

        online[who.character.guid] = who;
        onlineByName[toLowerName(who.character.data.name)] = who;
        mapOf(who).addMigrated(who, known);
    }

    /// A player's simulation leaves for node `next`: off the map and the lists, without a word.
    void leaveWorldForMigration(Character who, ushort next)
    {
        import dmangos.world.worlddata : toLowerName;

        mapOf(who).removeForMigration(who, next);
        lastHeard[who.character.guid] = Heard(next, MonoTime.currTime, who.character.data.level);
        online.remove(who.character.guid);
        onlineByName.remove(toLowerName(who.character.data.name));
    }

    // Players other nodes simulate: what each node said of its own.
    private RemotePlayer[ulong][ushort] remoteByNode;

    /**
     * Reserves limited vendor stock on the creature's node, or reads it when `wanted` is zero.
     * `then` gets whether it was available and the current count. Null standalone.
     */
    void delegate(ushort owner, uint map, ulong creature, uint item, uint maxCount, uint incrTime, uint buyCount,
        uint wanted, void delegate(bool reserved, uint left) then) reserveStock;

    /// Gives reserved stock back to the node simulating the creature (a purchase that did not complete).
    void delegate(ushort owner, uint map, ulong creature, uint item, uint maxCount, uint count) releaseStock;

    /// Sends a whisper to a player another node simulates, which checks it there; null standalone.
    void delegate(ushort node, ulong guid, WhisperFrom from, string text) whisperRemote;

    /// The corpse's node owns the roll. Only the winner's node writes the award to inventory.
    bool delegate(ushort, const ref GroupLootRoll) sendRemoteGroupLoot;
    bool delegate(ushort) canSendLootCoins;
    bool delegate(ushort, const ref LootCoinShare) sendRemoteLootCoins;
    bool delegate(ushort, const ref QuestLootCheck) sendQuestLootCheck;
    private ulong gameplaySequence;
    private MonoTime nextLootCoinPoll;
    private MonoTime nextBattlegroundRewardPoll;
    private bool[uint] retryLootCoinRedemption;

    ulong nextGameplaySequence()
    {
        import std.datetime.systime : Clock;

        if (!gameplaySequence)
            gameplaySequence = cast(ulong) Clock.currStdTime;
        return ++gameplaySequence;
    }

    void groupLootRollArrived(ushort peer, const ref GroupLootRoll message)
    {
        if (!peer || !message.roll || message.slot >= maxLootItems || !canWrite())
            return;
        final switch (message.action)
        {
        case GroupLootRoll.Action.offer:
            if (auto player = onlinePlayer(message.player))
                if (player.character !is null && player.currentMap.id == message.map)
                    player.offerRemoteLoot(peer, message);
            return;
        case GroupLootRoll.Action.award:
        case GroupLootRoll.Action.masterAward:
            receiveGroupLootAward(peer, message);
            return;
        case GroupLootRoll.Action.vote:
        case GroupLootRoll.Action.result:
            auto loot = lootOnMap(message.map, message.loot);
            if (loot is null)
                return;
            if (message.action == GroupLootRoll.Action.vote)
                loot.remoteVote(peer, message);
            else
                loot.remoteAwardResult(peer, message);
            return;
        }
    }

    private Loot lootOnMap(uint mapId, ulong target)
    {
        auto map_ = existingMap(mapId);
        if (map_ is null)
            return null;
        auto object = map_.findObject(target);
        if (auto creature = cast(Creature) object)
            return creature.loot;
        if (auto go = cast(GameObject) object)
            return go.loot;
        return null;
    }

    bool delegate(ushort, const ref PartyQuest) sendPartyQuest;

    void routePartyQuest(const ref PartyQuest message)
    {
        const guid = message.action == PartyQuest.Action.confirm ? message.sharer : message.member;
        if (onlinePlayer(guid) !is null)
            receivePartyQuest(message);
        else if (sendPartyQuest !is null && canWrite())
            if (const remote = remotePlayer(guid))
                sendPartyQuest(remote.node, message);
    }

    void receivePartyQuest(const ref PartyQuest message)
    {
        const guid = message.action == PartyQuest.Action.confirm ? message.sharer : message.member;
        auto session = onlinePlayer(guid);
        if (session !is null && !session.transferring)
            session.receivePartyQuest(message);
    }

    import dmangos.cluster.protocol : PartySummon;
    bool delegate(ushort, const ref PartySummon) sendPartySummon;

    package void routePartySummon(const ref PartySummon message, ushort peer = 0)
    {
        import dmangos.world.rituals : summonAcceptSeconds;

        const now = unixTime;
        if (!canWrite() || !message.sequence || !message.summoner || message.summoner == message.target
            || message.expires <= now || message.expires > now + summonAcceptSeconds + 5
            || !client.isValidMapCoord(message.map, message.x, message.y, message.z)
            || (message.instance && !instanceable(message.map)))
            return;
        auto group = groups.of(message.target);
        if (group is null || group.id != message.group || !group.isMember(message.summoner))
            return;
        if (auto member = onlinePlayer(message.target))
            if (member.player !is null && !member.transferring)
                return member.offerPartySummon(message);
        if (sendPartySummon is null || message.forwarded)
            return;
        ushort owner;
        if (const hint = recentHandoff(message.target))
            owner = hint.node;
        else if (const presence = remotePlayer(message.target))
            owner = presence.node;
        if (owner && owner != peer && owner != nodeId)
        {
            PartySummon onward = message;
            onward.forwarded = peer != 0;
            sendPartySummon(owner, onward);
        }
    }

    void questLootCheckArrived(ushort peer, const ref QuestLootCheck message)
    {
        if (!peer || !message.sequence || !canWrite())
            return;
        if (message.reply)
        {
            if (auto loot = lootOnMap(message.map, message.loot))
                loot.acceptQuestLootCheck(peer, message);
            return;
        }
        if (sendQuestLootCheck is null || message.items.length == 0 || message.items.length > maxLootItems)
            return;
        auto player = onlinePlayer(message.player);
        if (player is null || player.character is null || player.transferring || player.currentMap.id != message.map)
            return;
        auto reply = QuestLootCheck(message.map, message.loot, message.player, message.sequence, true);
        foreach (slot, entry; message.items)
            if (entry && player.hasQuestForItem(entry))
                reply.eligible |= cast(ushort)(1u << slot);
        sendQuestLootCheck(peer, reply);
    }

    private void receiveGroupLootAward(ushort peer, const ref GroupLootRoll message)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.inventory : InventoryResult;
        import dmangos.world.loot : lootAwardKey;

        const key = lootAwardKey(message);
        if (sendRemoteGroupLoot is null || !key.player || playerGuid(key.player) != message.player
            || !message.loot || !message.item || !message.count)
            return;
        auto player = onlinePlayer(message.player);
        if (player is null || player.character is null || player.transferring || player.currentMap.id != message.map
            || !settleWrites())
            return;
        try
        {
            if (database.loadLootAward(key).recorded)
                return; // the loot owner can read the original result even after both workers change
            const master = message.action == GroupLootRoll.Action.masterAward;
            auto localLoot = peer == nodeId ? lootOnMap(message.map, message.loot) : null;
            const localDrop = localLoot !is null && localLoot.hasPendingRemoteAward(message);
            if (peer == nodeId && !localDrop)
                return;
            if (!master && !player.acceptRemoteLootAward(peer, message, localDrop))
                return;

            GroupLootRoll result = message;
            result.action = GroupLootRoll.Action.result;
            result.inventoryError = InventoryResult.itemNotFound;
            if (!master || !message.condition || player.conditionMet(message.condition))
                result.inventoryError = cast(ubyte) player.storeLootItem(message.item, message.count,
                    message.randomProperty, !master, award: key);
            result.stored = result.inventoryError == InventoryResult.ok;
            if (!result.stored)
                database.saveLootAward(key, result.inventoryError, unixTime, 0, 0, null);
            if (!settleWrites())
                return;
            if (localDrop)
                localLoot.remoteAwardResult(peer, result);
            else
                sendRemoteGroupLoot(peer, result);
        }
        catch (DatabaseException error)
            warning!"group loot award %s could not be completed yet: %s"(key.token, error.msg);
    }

    /// The link only speeds up delivery. The database holds the credit if this player moves.
    void lootCoinShareArrived(ushort peer, const ref LootCoinShare message)
    {
        import dmangos.world.objects : lowGuid;

        if (!peer || !message.sequence || !message.copper || playerGuid(lowGuid(message.player)) != message.player)
            return;
        redeemLootCoinShare(lowGuid(message.player));
    }

    package void redeemLootCoinShare(uint guid)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.loot : tellLootCoinShare;
        import dmangos.world.updatefields : PLAYER_FIELD_COINAGE;

        auto player = onlinePlayer(playerGuid(guid));
        if (player is null || player.player is null || player.transferring || !canWrite())
            return;
        if (!settleWrites())
        {
            retryLootCoinRedemption[guid] = true;
            return;
        }
        try
        {
            const paid = database.redeemLootCoins(guid, unixTime);
            if (!paid.valid)
                return;
            retryLootCoinRedemption.remove(guid);
            player.player.values.set!PLAYER_FIELD_COINAGE(paid.wallet);
            player.flushPlayerChanges();
            if (paid.copper)
                tellLootCoinShare(player, paid.copper);
        }
        catch (DatabaseException error)
        {
            retryLootCoinRedemption[guid] = true;
            warning!"could not redeem group coins for character %s: %s"(guid, error.msg);
        }
    }

    private void pollBattlegroundRewards(MonoTime now)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!battlegrounds.durable || !online.length || now < nextBattlegroundRewardPoll || !canWrite())
            return;
        nextBattlegroundRewardPoll = now + 1.seconds;
        try
        {
            foreach (ref reward; database.pendingBattlegroundRewards())
                if (auto who = onlinePlayer(playerGuid(reward.player)))
                    if (who.player !is null && !who.transferring)
                        who.payBattlegroundReward(reward);
        }
        catch (DatabaseException error)
            warning!"could not deliver battleground rewards: %s"(error.msg);
    }

    private void pollLootCoinCredits(MonoTime now)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (sendRemoteLootCoins is null || !online.length || now < nextLootCoinPoll || !canWrite())
            return;
        nextLootCoinPoll = now + 1.seconds;
        try
        {
            foreach (guid; database.pendingLootCoinPlayers())
                redeemLootCoinShare(guid);
            foreach (guid; retryLootCoinRedemption.keys)
                if (onlinePlayer(playerGuid(guid)) is null)
                    retryLootCoinRedemption.remove(guid);
                else
                    redeemLootCoinShare(guid);
        }
        catch (DatabaseException error)
            warning!"could not look up pending group coins: %s"(error.msg);
    }

    bool delegate(ushort, const ref PartyHeal) sendPartyHeal;
    bool delegate(ushort, const ref imported!"dmangos.cluster.protocol".PartyAreaAura) sendPartyAreaAura;
    private ulong[ushort] lastPartyHeal, lastPartyHealReply;

    package bool sameAuraSubgroup(ulong controller, ulong recipient, uint groupId)
    {
        auto group = groups.of(recipient);
        return group !is null && group.id == groupId && group.isMember(controller)
            && group.subGroupOf(controller) == group.subGroupOf(recipient);
    }

    void partyAreaAuraArrived(ushort peer, const ref imported!"dmangos.cluster.protocol".PartyAreaAura renewal)
    {
        import dmangos.world.replication : Replica;
        import dmangos.world.updatefields : TypeId, UNIT_FIELD_HEALTH, UNIT_FIELD_SUMMONEDBY;

        if (!peer || !canWrite() || !sameAuraSubgroup(renewal.controller, renewal.target, renewal.group))
            return;
        auto member = onlinePlayer(renewal.target);
        if (member is null || member.player is null || !member.player.alive || member.transferring)
            return;
        auto map_ = member.currentMap;
        if (map_.id != renewal.map || map_.instanceId != renewal.instance)
            return;
        auto source = cast(Replica) map_.findObject(renewal.source);
        if (source is null || source.owner != peer || !source.fields.get!UNIT_FIELD_HEALTH)
            return;
        if (renewal.controller == renewal.source ? source.fields.type != TypeId.player
            : source.fields.type != TypeId.unit || source.fields.get!UNIT_FIELD_SUMMONEDBY != renewal.controller)
            return;
        if (const spell = data.spells.spell(renewal.spell))
            member.renewPartyAreaAura(spell, renewal);
    }

    import dmangos.cluster.protocol : TotemWeaponEnchant;
    bool delegate(ushort, const ref TotemWeaponEnchant) sendTotemWeaponEnchant;

    import dmangos.cluster.protocol : MindVisionTarget;
    bool delegate(ushort, const ref MindVisionTarget) sendMindVisionTarget;

    void mindVisionTargetArrived(ushort peer, const ref MindVisionTarget message)
    {
        import dmangos.world.replication : encodePlayerState;
        import dmangos.world.spellids : AuraType;

        if (!peer || !message.sequence || !message.caster || !message.target || !canWrite())
            return;
        if (message.reply)
        {
            if (auto caster = onlinePlayer(message.caster))
                caster.mindVisionTargetFound(peer, message);
            return;
        }
        if (message.state.length || sendMindVisionTarget is null)
            return;
        auto reply = MindVisionTarget(message.caster, message.target, message.sequence, message.map, message.instance, true);
        if (auto target = onlinePlayer(message.target))
            if (target.player !is null && !target.transferring && target.player.alive && !target.player.gmInvisible
                && !target.player.auras.hasType(AuraType.modStealth) && !target.player.auras.hasType(AuraType.modInvisibility)
                && target.currentMap.id == message.map && target.currentMap.instanceId == message.instance)
                reply.state = encodePlayerState(target.player, 0).dup;
        sendMindVisionTarget(peer, reply);
    }

    void totemWeaponEnchantArrived(ushort peer, const ref TotemWeaponEnchant pulse)
    {
        import dmangos.world.replication : Replica;
        import dmangos.world.spellcast : radius;
        import dmangos.world.spellids : AuraType;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId, UNIT_FIELD_HEALTH, UNIT_FIELD_SUMMONEDBY;

        if (!peer || !canWrite() || pulse.auraEffect >= 3 || pulse.weaponEffect >= 3
            || !sameAuraSubgroup(pulse.controller, pulse.target, pulse.group))
            return;
        auto member = onlinePlayer(pulse.target);
        if (member is null || member.player is null || !member.player.alive || member.transferring
            || member.duelingWith(pulse.controller))
            return;
        auto map_ = member.currentMap;
        if (map_.id != pulse.map || map_.instanceId != pulse.instance)
            return;
        auto totem = cast(Replica) map_.findObject(pulse.totem);
        if (totem is null || totem.owner != peer || totem.fields.type != TypeId.unit
            || !totem.fields.get!UNIT_FIELD_HEALTH || totem.fields.get!UNIT_FIELD_SUMMONEDBY != pulse.controller)
            return;
        const totemSpells = totem.fields.get!OBJECT_FIELD_ENTRY in data.creatureControlSpells;
        if (totemSpells is null || (*totemSpells)[0] != pulse.aura)
            return;
        const aura = spellInfo(pulse.aura);
        if (aura is null || aura.casting.applyAuraName[pulse.auraEffect] != AuraType.periodicTriggerSpell)
            return;
        const spell = spellInfo(aura.triggerSpell[pulse.auraEffect]);
        if (spell is null || spell.effect[pulse.weaponEffect] != SpellEffect.enchantHeldItem)
            return;
        const duration = cast(int) (pulse.expires - transportNow());
        if (duration <= 0 || duration > aura.casting.amplitude[pulse.auraEffect] * 2)
            return;
        const reach = radius(*spell, pulse.weaponEffect, client);
        const at = totem.position, where = member.player.position;
        if ((at.x - where.x) ^^ 2 + (at.y - where.y) ^^ 2 + (at.z - where.z) ^^ 2 <= reach * reach)
            member.enchantWeaponFromTotem(spell.miscValue[pulse.weaponEffect], duration);
    }

    void partyHealArrived(ushort peer, const ref PartyHeal message)
    {
        import std.algorithm.comparison : max;
        import dmangos.world.replication : Replica;
        import dmangos.world.spelldamage : applyHealAmount, isChainHealEffect, isPartyHealEffect, spellJumpRadius,
            withinPartyHealRadius;
        import dmangos.world.spellids : SpellEffect;
        import dmangos.world.unit : UnitRef;
        import dmangos.world.updatefields : TypeId;

        if (!peer || !message.sequence || !canWrite())
            return;
        if (message.landed)
            return partyHealLanded(peer, message);
        if (message.sequence <= lastPartyHeal.get(peer, 0))
            return;
        // Record refused deliveries too: a recipient moving or rejoining cannot revive an old heal.
        lastPartyHeal[peer] = message.sequence;
        auto target = onlinePlayer(message.target);
        if (target is null || target.player is null || !target.player.alive || target.transferring
            || target.currentMap.id != message.map || target.currentMap.instanceId != message.instance
            || !withinPartyHealRadius(message, target.player.position))
            return;
        auto group = groups.of(message.caster);
        if (group is null || group.id != message.group || !group.isMember(message.target)
            || message.caster == message.target)
            return;
        const spell = data.spells.spell(message.spell);
        if (spell is null || !message.amount)
            return;
        if (message.previous)
        {
            if (!isChainHealEffect(*spell, message.effect) || message.radius != spellJumpRadius
                || message.previous == message.target || !group.isMember(message.previous)
                || target.duelingWith(message.caster))
                return;
        }
        else if (!isPartyHealEffect(*spell, message.effect)
            || group.subGroupOf(message.caster) != group.subGroupOf(message.target))
            return;
        enum uint noImmunities = 0x20000000;
        const immune = target.unit.fighter.immune;
        if (!(spell.attributes & noImmunities) && immune.any && immune.toEffect(SpellEffect.heal,
            spell.casting.effectMechanic[message.effect], spell.casting.applyAuraName[message.effect]))
            return;
        PartyHeal result = message;
        uint restored;
        result.amount = applyHealAmount(spell, target.unit, message.amount, restored);
        target.flushPlayerChanges();
        if (auto copy = cast(Replica) target.currentMap.findObject(message.caster))
            if (copy.owner == peer && copy.fields.type == TypeId.player)
            {
                const helper = copy.playerRelations(client);
                const threat = cast(uint) max(0, restored * message.threatFactor + message.threatFlat);
                result.causedThreat = imported!"dmangos.world.creatureai".assistThreat(target.currentMap, target.threateners,
                    UnitRef.observed(copy, target.currentMap), threat, *spell, &helper);
            }
        result.landed = true;
        result.pvp = target.isPvP;
        result.contested = target.isPvPContested;
        result.inPvPCombat = target.inPvPCombat;
        if (sendPartyHeal !is null)
            sendPartyHeal(peer, result);
    }

    private void partyHealLanded(ushort peer, const ref PartyHeal message)
    {
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;
        import dmangos.world.replication : Replica;
        import dmangos.world.spellcast : healLog;
        import dmangos.world.unit : UnitRef;

        if (message.sequence <= lastPartyHealReply.get(peer, 0))
            return;
        lastPartyHealReply[peer] = message.sequence;
        auto caster = onlinePlayer(message.caster);
        if (caster is null || caster.player is null || caster.transferring
            || caster.currentMap.id != message.map || caster.currentMap.instanceId != message.instance)
            return;
        caster.pvpAssisted(message.pvp, message.contested, message.inPvPCombat);
        if (message.causedThreat && caster.player.alive)
            caster.enterCombatFor(Character.combatLinger);
        caster.flushPlayerChanges();
        caster.currentMap.sendToWatchers(caster, Opcode.SMSG_SPELLHEALLOG,
            healLog(message.target, message.caster, message.spell, message.amount, message.critical), true);
        if (message.suppressProcs)
            return;
        if (const spell = data.spells.spell(message.spell))
            if (auto copy = cast(Replica) caster.currentMap.findObject(message.target))
                if (copy.owner == peer)
                    caster.procAuras(spellProcFlags(*spell, true, false), UnitRef.observed(copy, caster.currentMap),
                        ProcHit(spell, message.critical ? ProcEx.criticalHit : ProcEx.normalHit, message.amount,
                            0, message.amount != 0));
    }

    bool delegate(ushort, const ref AreaDamage) sendAreaDamage;
    private ulong[ushort] lastAreaDamage, lastAreaDamageReply;

    /// The first named effect with an implementation available on the chosen target's node.
    package size_t namedCreatureRouting(const(SpellInfo)* spell)
    {
        import dmangos.world.spelldamage : databaseSpellEffect, namedCreatureEffect;

        const effect = namedCreatureEffect(*spell);
        if (effect == size_t.max || !spellScriptTargets(spell.id).length || spellScript(spell.id))
            return size_t.max;
        if (databaseSpellEffect(spell.effect[effect]) && !data.dbScripts.targetsOnly(spell.id))
            return size_t.max;
        return effect;
    }

    /// The first applicable effect in a shared target group, including auras when damage is excluded.
    package size_t namedCreatureEffectFor(const(SpellInfo)* spell, size_t first, uint entry)
    {
        import dmangos.world.spelldamage : remoteTargetAuraEffects;

        if (first == size_t.max)
            return size_t.max;
        const excluded = scriptTargetExclusions(spell.id, entry);
        if (!(excluded & (1u << first)))
            return first;
        if (spell.effect[first] == SpellEffect.schoolDamage || spell.effect[first] == SpellEffect.applyAura)
        {
            const auras = remoteTargetAuraEffects(*spell, first) & ~excluded;
            foreach (i; first + 1 .. spell.effect.length)
                if (auras & (1u << i))
                    return i;
        }
        return size_t.max;
    }

    package const(uint)[] namedCreatureEntries(const(SpellInfo)* spell, size_t first)
    {
        const entries = spellScriptTargets(spell.id);
        if (spell.id !in data.spellScriptTargetMasks)
            return entries;
        uint[] eligible;
        foreach (entry; entries)
            if (namedCreatureEffectFor(spell, first, entry) != size_t.max)
                eligible ~= entry;
        return eligible;
    }

    package size_t namedCreatureChannel(const(SpellInfo)* spell)
    {
        import dmangos.world.spellcast : duration;
        import dmangos.world.spelldamage : namedChannelTriggerEffect, namedCreatureChannelEffect,
            permanentNamedCreatureVisual;

        const effect = namedCreatureChannelEffect(*spell);
        const ms = duration(*spell, client, spell.spellLevel);
        return effect != size_t.max && namedCreatureEntries(spell, effect).length && !spellScript(spell.id)
            && (ms > 0 || (ms < 0 && permanentNamedCreatureVisual(spell.id)))
            && (namedChannelTriggerEffect(*spell) == size_t.max || namedChannelCompletionSpell(spell) !is null)
            ? effect : size_t.max;
    }

    /// A single terminal dummy hit with no spell script of its own can run where its creature is owned.
    private const(SpellInfo)* namedChannelCompletionSpell(const(SpellInfo)* spell)
    {
        import dmangos.world.dbscripts : DbScriptType;
        import dmangos.world.spellcast : duration;
        import dmangos.world.spelldamage : crystalPrisonCompletion, namedChannelTriggerEffect, namedCreatureShape;
        import dmangos.world.spellids : SpellEffect;

        const effect = namedChannelTriggerEffect(*spell);
        if (effect == size_t.max || spell.casting.amplitude[effect] != duration(*spell, client, spell.spellLevel))
            return null;
        const child = data.spells.spell(spell.triggerSpell[effect]);
        if (child is null || (child.casting.speed != 0 && child.id != crystalPrisonCompletion)
            || (child.attributesEx & (0x04 | 0x40))
            || child.effect[0] != SpellEffect.dummy || child.effect[1] || child.effect[2]
            || namedCreatureShape(*child, 0) != ImplicitTarget.unitScriptNearCaster || child.casting.chainTarget[0] > 1
            || !spellScriptTargets(child.id, 0).length || spellScript(child.id)
            || data.dbScripts.steps(DbScriptType.spell, child.id).length)
            return null;
        return child;
    }

    package ImplicitTarget namedGameObjectRouting(const(SpellInfo)* spell, size_t effect)
    {
        import dmangos.world.spellselection : namedGameObjectShape;

        const shape = namedGameObjectShape(*spell, effect);
        if (shape != ImplicitTarget.none && !spellScript(spell.id) && data.spellScriptObjects.get(spell.id, null).length)
            return shape;
        return ImplicitTarget.none;
    }

    package bool onlyNamedGameObjectEffects(const(SpellInfo)* spell)
    {
        bool found;
        foreach (i, effect; spell.effect)
        {
            if (effect == SpellEffect.none)
                continue;
            if (namedGameObjectRouting(spell, i) == ImplicitTarget.none)
                return false;
            found = true;
        }
        return found;
    }

    bool delegate(ushort, const ref GameObjectSpell) sendGameObjectSpell;
    private ulong[ushort] lastGameObjectSpell, lastGameObjectSpellReply;

    private bool namedGameObjectGeometry(Map map_, const(SpellInfo)* spell, size_t effect, ImplicitTarget shape,
        Position origin, out Position center, out float reach)
    {
        import std.math : isFinite;
        import dmangos.world.spellcast : radius;
        import dmangos.world.spellselection : namedCreatureRange;

        center = origin;
        if (spell.implicitTargetA[effect] == ImplicitTarget.database)
        {
            const location = spell.id in data.spellTargets;
            if (location is null || location.map != map_.id)
                return false;
            center = location.at;
        }
        reach = shape == ImplicitTarget.gameobjectScriptNearCaster
            ? namedCreatureRange(*spell, client) : radius(*spell, effect, client);
        return isFinite(reach) && reach > 0 && client.isValidMapCoord(map_.id, center.x, center.y, center.z);
    }

    package ulong[] namedGameObjectTargets(Map map_, const(SpellInfo)* spell, size_t effect, ImplicitTarget shape,
        Position origin, out Position center, scope bool delegate(ulong) visible = null)
    {
        import dmangos.world.spellselection : namedGameObjectsInArea, nearestNamedGameObject;

        float reach;
        if (!namedGameObjectGeometry(map_, spell, effect, shape, origin, center, reach))
            return null;
        const entries = data.spellScriptObjects.get(spell.id, null);
        const acrossNodes = sendGameObjectSpell !is null;
        if (shape != ImplicitTarget.gameobjectScriptNearCaster)
            return namedGameObjectsInArea(map_, center, reach, effect, entries, acrossNodes, spell.casting.maxAffectedTargets,
                visible);
        auto object = nearestNamedGameObject(map_, center, reach, effect, entries, acrossNodes, visible);
        return object is null ? null : [object.guid];
    }

    package void activateNamedGameObject(UnitRef caster, const(SpellInfo)* spell, size_t effect, ulong guid,
        Position origin, bool triggered)
    {
        import dmangos.world.replication : Replica;

        const shape = namedGameObjectRouting(spell, effect);
        if (!canWrite() || caster.kind == UnitKind.none || shape == ImplicitTarget.none)
            return;
        auto map_ = caster.map;
        if (auto copy = cast(Replica) map_.findObject(guid))
        {
            if (sendGameObjectSpell is null || copy.owner == nodeId)
                return;
            const message = GameObjectSpell(nextGameplaySequence(), caster.combatGuid, guid,
                spell.id, map_.id, map_.instanceId, cast(ubyte) effect, origin.x, origin.y, origin.z, triggered);
            sendGameObjectSpell(copy.owner, message);
        }
        else if (auto object = map_.gameObjectAt(guid))
            applyNamedGameObject(map_, spell, effect, shape, object, origin, caster.combatGuid);
    }

    private struct ObjectAnimationImpact
    {
        MonoTime arrives;
        Map map;
        GameObject object;
        uint animation;
    }
    private ObjectAnimationImpact[] objectAnimations;

    package void placeKurinnaxxTrap(Map map, Position at)
    {
        if (auto trap = summonWildGameObject(map, 180647, at, 10))
        {
            trap.restoreTimer = 4000;
            map.wake(trap.guid);
        }
    }

    private void landObjectAnimations(MonoTime now)
    {
        import dmangos.world.gameobject : gameObjectAnimation;
        size_t kept;
        foreach (impact; objectAnimations)
            if (impact.arrives > now)
                objectAnimations[kept++] = impact;
            else if (impact.map.gameObjectAt(impact.object.guid) is impact.object && canWrite())
                impact.map.sendToObservers(impact.object.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM,
                    gameObjectAnimation(impact.object.guid, impact.animation));
        objectAnimations.length = kept;
    }

    private bool applyNamedGameObject(Map map_, const(SpellInfo)* spell, size_t effect, ImplicitTarget shape,
        GameObject object, Position origin, ulong casterGuid)
    {
        import dmangos.world.gameobject : gameObjectAnimation, GameObjectAction;
        import dmangos.world.spellselection : namedGameObjectAnimation, namedGameObjectEntry;

        if (!namedGameObjectEntry(data.spellScriptObjects.get(spell.id, null), effect, object.spawn.entry))
            return false;
        Position center;
        float reach;
        if (!namedGameObjectGeometry(map_, spell, effect, shape, origin, center, reach))
            return false;
        const at = object.position;
        if (!((at.x - center.x) ^^ 2 + (at.y - center.y) ^^ 2 + (at.z - center.z) ^^ 2 <= reach ^^ 2))
            return false;
        const animation = namedGameObjectAnimation(*spell, effect);
        if (animation >= 0 && spell.casting.speed > 0)
        {
            import core.time : msecs;
            import std.math : sqrt;
            const distance = sqrt((at.x-origin.x) ^^ 2 + (at.y-origin.y) ^^ 2 + (at.z-origin.z) ^^ 2);
            objectAnimations ~= ObjectAnimationImpact(clock() + (cast(int)(1000 * distance / spell.casting.speed)).msecs,
                map_, object, cast(uint) animation);
        }
        else if (animation >= 0)
            map_.sendToObservers(object.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM,
                gameObjectAnimation(object.guid, cast(uint) animation));
        else if (spell.id == 19873)
        {
            auto dragon = map_.creatureAt(casterGuid);
            if (dragon is null || dragon.spawn.entry != 12435 || !dragon.petOwner || !dragon.alive
                || map_.id != 469 || object.spawn.entry != 177807)
                return false;
            gameObjectUsed(object, map_, casterGuid);
        }
        else if (spell.miscValue[effect] == GameObjectAction.disturb)
            return disturbEncounterTrap(map_, object);
        else
        {
            if (!object.applySpellState(map_, cast(GameObjectAction) spell.miscValue[effect]))
                return false;
            map_.wake(object.guid);
        }
        return true;
    }

    /// Cast a dungeon trap's spell at the trap. The egg creates a second proximity trap and each
    /// plague fissure casts its own short-range Eruption at its location on the floor.
    private bool disturbEncounterTrap(Map map_, GameObject object)
    {
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.gameobject : GoLootState, gameObjectAnimation;
        import dmangos.world.spellcast : duration;
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE, UNIT_FIELD_FLAGS;

        const proto = object.template_;
        if (proto.type != GameObjectType.trap || object.lootState != GoLootState.ready)
            return false;
        const spell = data.spells.spell(cast(uint) proto.data[3]);
        if (spell is null)
            return false;
        if (spell.effect[0] == SpellEffect.summonObjectWild)
        {
            const ms = duration(*spell, client, cast(uint) proto.data[1]);
            if (summonWildGameObject(map_, cast(uint) spell.miscValue[0], object.position,
                    ms > 0 ? cast(uint)(ms / 1000) : 0) is null)
                return false;
        }
        else
        {
            enum worldTrigger = 15384;
            auto trigger = summonCreature(map_, worldTrigger, object.position, TempSpawnType.timed, 1000, 0);
            if (trigger is null || trigger.ai is null)
                return false;
            trigger.factionTemplate = client.factionTemplates.lookup(proto.faction);
            trigger.values.set!UNIT_FIELD_FACTIONTEMPLATE(proto.faction);
            // The invisible proxy is spawning an environmental hazard that can hit players and NPCs.
            trigger.values.set!UNIT_FIELD_FLAGS(trigger.values.get!UNIT_FIELD_FLAGS
                & ~(UnitFlags.immuneToPlayer | UnitFlags.immuneToNpc));
            if (trigger.ai.castFor(map_, spell.id, trigger.guid, true) != ActionResult.ok)
                return false;
        }
        if (proto.extraFlags & 1)
            map_.sendToObservers(object.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM, gameObjectAnimation(object.guid, 0));
        object.trapReadyAt = unixTime + (proto.data[5] > 0 ? proto.data[5] : 4);
        if (proto.data[4] > 0 && ++object.trapUses >= proto.data[4])
            map_.gameObjectUsedUp(object);
        return true;
    }

    void gameObjectSpellArrived(ushort peer, const ref GameObjectSpell message)
    {
        import dmangos.world.replication : Replica;
        import dmangos.world.updatefields : TypeId;

        if (!peer || !message.sequence || !canWrite())
            return;
        auto map_ = existingMap(message.map, message.instance);
        const spell = data.spells.spell(message.spell);
        if (map_ is null || map_.id != message.map || spell is null)
            return;
        const shape = namedGameObjectRouting(spell, message.effect);
        if (shape == ImplicitTarget.none)
            return;
        if (message.reply)
        {
            if (message.sequence <= lastGameObjectSpellReply.get(peer, 0))
                return;
            lastGameObjectSpellReply[peer] = message.sequence;
            if (auto caster = map_.unit(message.caster))
                if (caster.kind == UnitKind.player && !caster.session.transferring)
                    caster.session.rewardPlayerAndGroupAtCast(message.target, message.spell, peer);
            return;
        }
        if (message.sequence <= lastGameObjectSpell.get(peer, 0))
            return;
        lastGameObjectSpell[peer] = message.sequence;
        const high = highGuidOf(message.caster);
        const playerCast = high == HighGuid.player;
        if (!message.caster || (!playerCast && high != HighGuid.unit && high != HighGuid.pet))
            return;
        // An idle object owner may have no interest in the caster's cell. The casting node
        // checked the cast before sending it. Any locally known authority must agree.
        if (auto copy = cast(Replica) map_.findObject(message.caster))
        {
            if (copy.owner != peer || copy.fields.type != (playerCast ? TypeId.player : TypeId.unit)
                || (!UnitRef.observed(copy, map_).alive && !(message.triggered && !playerCast)))
                return;
        }
        else if (map_.unit(message.caster))
            return;
        auto object = map_.gameObjectAt(message.target);
        if (object is null || !client.isValidMapCoord(map_.id, message.x, message.y, message.z))
            return;
        const origin = Position(message.x, message.y, message.z);
        if (applyNamedGameObject(map_, spell, message.effect, shape, object, origin, message.caster)
            && playerCast && sendGameObjectSpell !is null)
        {
            auto reply = cast(GameObjectSpell) message;
            reply.reply = true;
            sendGameObjectSpell(peer, reply);
        }
    }

    private struct ReplicaSpellImpact
    {
        MonoTime due;
        AreaDamage hit;
        MonoTime retryUntil; // time allowed to resolve the target across a handoff
        ushort sentTo; // a completed channel can follow a replica to a different owner
    }

    private enum replicaImpactGrace = 2.seconds;
    private ReplicaSpellImpact[] replicaSpellImpacts;

    /// Only a caster that completed its channel can authorize its terminal spell.
    package void completeNamedChannel(Map map_, UnitRef caster, ulong target, const(SpellInfo)* spell, ulong token)
    {
        import std.algorithm.comparison : max;
        import std.math : sqrt;

        const child = namedChannelCompletionSpell(spell);
        if (!token || !canWrite() || child is null)
            return;
        auto hit = AreaDamage(caster: caster.combatGuid, target: target, spell: spell.id,
            map: map_.id, instance: map_.instanceId, creatureCast: caster.creature !is null,
            namedCreature: true, channelled: true, channelUpdate: true,
            auraMs: AreaDamage.completedChannel, channelToken: token);
        const local = map_.creatureAt(target) !is null;
        Position at;
        int delay;
        if (child.casting.speed > 0 && map_.positionOf(target, at))
        {
            const from = caster.position;
            const yards = sqrt((at.x - from.x) ^^ 2 + (at.y - from.y) ^^ 2 + (at.z - from.z) ^^ 2);
            delay = cast(int) (max(5.0f, yards) / child.casting.speed * 1000);
        }
        if (local && delay == 0)
            applyAreaDamage(0, map_, hit);
        else if (local || sendAreaDamage !is null)
        {
            const due = clock() + delay.msecs;
            replicaSpellImpacts ~= ReplicaSpellImpact(due, hit, due + replicaImpactGrace);
        }
    }

    /// Move queued impacts with the caster. The deadlines use the shared node clock.
    package void writeReplicaImpacts(ulong caster, ref ByteWriter writer, bool departing = true)
    {
        import dmangos.serialization : serialize;

        uint count;
        foreach (ref impact; replicaSpellImpacts)
            if (impact.hit.caster == caster)
                ++count;
        writer.put(count);
        if (!count)
            return;

        const now = clock();
        const transferTime = transportNow();
        size_t kept;
        foreach (impact; replicaSpellImpacts)
        {
            if (impact.hit.caster != caster)
            {
                if (departing)
                    replicaSpellImpacts[kept++] = impact;
                continue;
            }
            writer.put(transferTime + cast(uint)(impact.due - now).total!"msecs");
            const waiting = impact.retryUntil != MonoTime.init;
            writer.put(waiting);
            if (waiting)
                writer.put(transferTime + cast(uint)(impact.retryUntil - now).total!"msecs");
            writer.put(impact.sentTo);
            serialize(writer, impact.hit);
        }
        if (departing)
            replicaSpellImpacts.length = kept;
    }

    /// Adopt impacts for the caster on the same map and instance from which they were launched.
    package void readReplicaImpacts(ulong caster, uint mapId, uint instance, ref ByteReader reader)
    {
        import std.algorithm.comparison : max;
        import dmangos.serialization : deserialize;

        const count = reader.read!uint;
        if (!count)
            return;
        const now = clock();
        const arrived = transportNow();
        ReplicaSpellImpact[] restored;
        foreach (_; 0 .. count)
        {
            const deadline = reader.read!uint;
            const waiting = reader.read!bool;
            const expiresIn = waiting ? cast(int)(reader.read!uint - arrived) : 0;
            const sentTo = reader.read!ushort;
            auto hit = deserialize!AreaDamage(reader);
            if (hit.caster != caster || hit.reply || hit.benefits.length || hit.map != mapId || hit.instance != instance
                || (waiting && expiresIn <= 0))
                continue;
            const remaining = max(0, cast(int)(deadline - arrived));
            const due = now + remaining.msecs;
            restored ~= ReplicaSpellImpact(due, hit, waiting ? now + expiresIn.msecs : MonoTime.init, sentTo);
        }
        replicaSpellImpacts ~= restored;
    }

    /// Commit a cross-node effect now, or when its projectile reaches the target.
    package bool sendReplicaSpell(Map map_, ushort peer, const(SpellInfo)* spell, AreaDamage hit)
    {
        import std.math : isFinite, sqrt;
        import dmangos.world.spelldamage : namedCreatureShape;
        import dmangos.world.spellids : ImplicitTarget;

        if (sendAreaDamage is null || !canWrite())
            return false;
        if (hit.playerProjectile)
        {
            if (!sendReplicaSpellImpact(map_, peer, hit, true))
                replicaSpellImpacts ~= ReplicaSpellImpact(clock(), hit, MonoTime.init, hit.redirectOwner);
            return true;
        }
        if (!hit.channelled && spell.casting.speed > 0)
            if (auto copy = cast(Replica) map_.findObject(hit.target))
            {
                auto from = Position(hit.x, hit.y, hit.z), to = copy.position;
                if (hit.namedCreature && namedCreatureShape(*spell, hit.effect) == ImplicitTarget.enumUnitsScriptAoeAtDestLoc)
                {
                    auto caster = map_.unit(hit.caster);
                    if (!caster)
                        return false;
                    to = from;
                    from = caster.position;
                }
                const time = sqrt((to.x - from.x) ^^ 2 + (to.y - from.y) ^^ 2 + (to.z - from.z) ^^ 2)
                    / spell.casting.speed * 1000;
                if (!isFinite(time) || time >= int.max)
                    return false;
                if (time >= 1)
                {
                    replicaSpellImpacts ~= ReplicaSpellImpact(clock() + (cast(int) time).msecs, hit);
                    return true;
                }
            }
        return sendReplicaSpellImpact(map_, peer, hit);
    }

    private bool sendReplicaSpellImpact(Map map_, ushort peer, AreaDamage hit, bool projectile = false)
    {
        import std.algorithm.comparison : max;

        if (sendAreaDamage is null)
            return false;
        if (hit.channelled)
            map_.holdCasterReplica(hit.caster, peer, cast(uint) max(0, hit.auraMs) + 5_000,
                (hit.creatureCast && !hit.channelUpdate) || hit.channelOperation == AreaDamage.ChannelUpdate.complete);
        else if (hit.namedCreature || projectile)
            map_.holdCasterReplica(hit.caster, peer, 5_000, projectile);
        if (!hit.sequence || !hit.channelled)
            hit.sequence = nextGameplaySequence();
        return sendAreaDamage(peer, hit);
    }

    private void deliverReplicaSpells(MonoTime now)
    {
        import dmangos.world.unit : UnitKind;

        if (!replicaSpellImpacts.length)
            return;
        auto pending = replicaSpellImpacts;
        replicaSpellImpacts = null;
        foreach (impact; pending)
        {
            if (impact.due > now)
            {
                replicaSpellImpacts ~= impact;
                continue;
            }
            auto map_ = existingMap(impact.hit.map, impact.hit.instance);
            if (map_ is null || !map_.unit(impact.hit.caster) || !canWrite())
                continue;
            const completion = impact.hit.channelOperation == AreaDamage.ChannelUpdate.complete;
            if (impact.retryUntil != MonoTime.init && impact.retryUntil <= now)
                continue;
            if (auto copy = cast(Replica) map_.findObject(impact.hit.target))
            {
                if (copy.owner != impact.sentTo && sendReplicaSpellImpact(map_, copy.owner, impact.hit, !completion))
                {
                    if (!completion)
                        continue;
                    impact.sentTo = copy.owner;
                }
            }
            else
            {
                auto target = map_.unit(impact.hit.target);
                if (target && (target.kind != UnitKind.player || !target.session.transferring))
                {
                    applyAreaDamage(0, map_, impact.hit);
                    continue;
                }
                if (completion)
                    impact.sentTo = 0;
            }
            if (impact.retryUntil == MonoTime.init)
                impact.retryUntil = now + replicaImpactGrace;
            replicaSpellImpacts ~= impact;
        }
    }

    bool delegate(ushort, const ref CreatureSwing) sendCreatureSwing;
    private ulong[ushort] lastCreatureSwing, lastCreatureSwingReply;

    private bool queueCreatureSwing(Creature attacker, UnitRef target, uint spell, int spellValue, float spellThreat,
        bool secondary)
    {
        import dmangos.world.combat : creatureTypeHumanoid;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

        if (!canWrite() || target.replica.owner == nodeId)
            return false;
        uint targetType = creatureTypeHumanoid;
        if (target.replica.fields.type == TypeId.unit)
        {
            const template_ = target.replica.fields.get!OBJECT_FIELD_ENTRY in data.creatureTemplates;
            if (template_ is null)
                return false;
            targetType = template_.creatureType;
        }
        const fighter = attacker.fighter;
        const damageVersus = targetType < fighter.damageVersus.length ? fighter.damageVersus[targetType] : 1;
        const critVersus = targetType < fighter.critVersus.length ? fighter.critVersus[targetType] : 0;
        const request = CreatureSwing(sequence: nextGameplaySequence(), attacker: attacker.guid,
            target: target.combatGuid, controller: attacker.meleeController, map: target.map.id, instance: target.map.instanceId,
            destination: target.replica.owner,
            facing: fighter.position.orientation, running: fighter.runningAround, school: fighter.damageSchool[0],
            armorIgnored: fighter.armorIgnored, minDamage: fighter.damage[0][0], maxDamage: fighter.damage[0][1],
            damageFactor: fighter.damageDone[0] * damageVersus, crit: fighter.crit,
            critVersus: critVersus, hitBonus: fighter.hitBonus, spell: spell, spellValue: spellValue,
            spellThreat: spellThreat, secondary: secondary);
        return sendCreatureSwing(request.destination, request);
    }

    /// The target's node resolves the attack table, armor and absorbs against the unit it simulates now.
    void creatureSwingArrived(ushort peer, const ref CreatureSwing request)
    {
        import std.math : isFinite;
        import dmangos.world.combat : attackerStateUpdate, AttackType, calculateMeleeDamage, creatureSwingInReach,
            HitInfo;
        import dmangos.world.creaturecasting : creatureWeaponSpellDamage, nextWeaponSwingEffect, weaponSpellMiss;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.relations : canAttackNow;
        import dmangos.world.spelldamage : creatureTargetInRange, weaponRolledAmount;
        import dmangos.world.unit : Blow, combatRelations, dealDamage;
        import dmangos.world.updatefields : OBJECT_FIELD_ENTRY, TypeId;

        if (!peer || !request.sequence || !canWrite())
            return;
        if (request.reply)
            return creatureSwingReply(peer, request);
        if (request.destination != nodeId || request.sequence <= lastCreatureSwing.get(peer, 0))
            return;
        lastCreatureSwing[peer] = request.sequence;
        if (request.retaliation.length)
            return;
        if (request.school >= 7 || !isFinite(request.facing) || !isFinite(request.minDamage)
            || !isFinite(request.maxDamage) || !isFinite(request.damageFactor) || !isFinite(request.crit)
            || !isFinite(request.critVersus) || !isFinite(request.hitBonus) || request.minDamage < 0
            || request.maxDamage < 0 || request.minDamage >= uint.max || request.maxDamage >= uint.max)
            return;
        auto map_ = existingMap(request.map, request.instance);
        if (map_ is null || map_.id != request.map || map_.instanceId != request.instance)
            return;
        auto victim = map_.unit(request.target);
        if (!victim.alive || victim.untouchable || (victim.kind == UnitKind.player && victim.session.transferring)
            || (victim.kind == UnitKind.creature && victim.creature.ai is null))
            return;
        auto copy = cast(Replica) map_.findObject(request.attacker);
        if (copy is null || copy.owner != peer || copy.fields.type != TypeId.unit)
            return;
        auto source = UnitRef.observed(copy, map_);
        const relation = source.combatRelations(client);
        const controller = copy.meleeController;
        enum disabled = UnitFlags.pacified | UnitFlags.stunned | UnitFlags.confused | UnitFlags.fleeing;
        if (request.controller != controller
            || (!controller && (relation.playerControlled
                || (victim.kind == UnitKind.creature && !victim.creature.meleeController)))
            || (controller && victim.kind == UnitKind.player && victim.session.duelingWith(controller))
            || (relation.unitFlags & disabled) || !canAttackNow(relation, victim.relating(), client))
            return;
        const template_ = copy.fields.get!OBJECT_FIELD_ENTRY in data.creatureTemplates;
        if (template_ is null)
            return;
        auto attacker = copy.meleeGeometry();
        attacker.position.orientation = request.facing; // A facing change alone may not have sent movement yet.
        attacker.runningAround = request.running;
        auto defender = victim.fighter;
        if (!creatureSwingInReach(attacker, defender))
            return;
        const spell = request.spell ? data.spells.spell(request.spell) : null;
        const weaponEffect = spell is null ? -1 : nextWeaponSwingEffect(*spell);
        if (request.spell && (weaponEffect < 0 || !isFinite(request.spellThreat) || request.spellThreat < 0
            || !creatureTargetInRange(spell, attacker, defender, client)
            || !map_.inLineOfSight(attacker.position, defender.position)))
            return;
        attacker.worldBoss = template_.rank == 3;
        attacker.armorIgnored = request.armorIgnored;
        attacker.damage[0] = [request.minDamage, request.maxDamage];
        attacker.damageSchool[0] = request.school;
        attacker.damageDone[0] = request.damageFactor;
        attacker.crit = request.crit;
        if (defender.creatureType < attacker.critVersus.length)
            attacker.critVersus[defender.creatureType] = request.critVersus;
        attacker.hitBonus = request.hitBonus;

        auto hit = calculateMeleeDamage(attacker, defender, AttackType.mainHand, map_.random);
        auto result = cast(CreatureSwing) request;
        result.reply = true;
        result.spellMiss = 0;
        Blow blow;
        SwingRetaliation[] retaliation;
        if (spell is null)
        {
            if ((hit.absorbed = victim.absorb(hit.school, hit.damage)) != 0)
                hit.hitInfo |= HitInfo.absorb;
            const packet = attackerStateUpdate(hit);
            if (victim.kind == UnitKind.player)
                map_.sendToWatchers(victim.session, Opcode.SMSG_ATTACKERSTATEUPDATE, packet, true);
            else
                map_.sendToObservers(request.target, Opcode.SMSG_ATTACKERSTATEUPDATE, packet);
            blow = Blow.swing(hit);
            blow.retaliate = (uint damage, uint school, uint procSpell, float threatFactor) {
                retaliation ~= SwingRetaliation(damage, school, procSpell, threatFactor);
            };
        }
        else
        {
            result.spellMiss = cast(ubyte) weaponSpellMiss(hit);
            if (!result.spellMiss)
            {
                if (victim.kind == UnitKind.creature)
                    victim.creature.ai.spellHitBy(request.attacker, spell.id, 1u << spell.casting.school, map_);
                victim.hostileSpellLanded();
                const current = victim.fighter;
                hit.damage = creatureWeaponSpellDamage(spell.effect[weaponEffect], hit.damage, request.spellValue,
                    attacker.level, current.armor);
                hit.damage = weaponRolledAmount(hit.damage, 0, current);
                hit.absorbed = victim.absorb(0, hit.damage);
                blow = Blow.spell();
                blow.threat = request.spellThreat;
            }
            else
                hit.damage = 0;
        }
        if (!result.spellMiss)
        {
            blow.remotePlayer = controller;
            blow.remotePlayerPvP = relation.hasFlag(UnitFlags.pvp);
            const honor = controller && victim.kind == UnitKind.player ? victim.session.describeHonorVictim()
                : HonorVictim.init;
            if (controller)
            {
                if (dealRemoteDamage(source, victim, hit.damage, blow) && honor.guid)
                    reportRemotePlayerKill(controller, honor, map_);
            }
            else
                dealDamage(source, victim, hit.damage, blow);
        }

        if (sendCreatureSwing !is null)
        {
            result.outcome = cast(ubyte) hit.outcome;
            result.damage = hit.damage;
            result.absorbed = hit.absorbed;
            result.killed = !victim.alive;
            result.targetPvP = victim.kind == UnitKind.player && victim.session.character !is null && victim.session.isPvP;
            result.retaliation = retaliation;
            sendCreatureSwing(peer, result);
        }
    }

    private void creatureSwingReply(ushort peer, const ref CreatureSwing reply)
    {
        import std.math : isFinite;
        import dmangos.bytes : ByteWriter;
        import dmangos.world.combat : MeleeHitOutcome;
        import dmangos.world.objects : highGuidOf;
        import dmangos.world.spellcast : nonMeleeDamageLog, spellGoPacket, spellMissLog, SpellMissInfo, SpellTargets,
            TargetFlags, TargetResult;
        import dmangos.world.unit : Blow;

        if (reply.destination != peer || reply.sequence <= lastCreatureSwingReply.get(peer, 0)
            || reply.outcome > MeleeHitOutcome.max)
            return;
        lastCreatureSwingReply[peer] = reply.sequence;
        auto map_ = existingMap(reply.map, reply.instance);
        if (map_ is null || map_.id != reply.map || map_.instanceId != reply.instance)
            return;
        auto attacker = map_.creatureAt(reply.attacker);
        if (attacker is null || !attacker.alive || attacker.ai is null
            || attacker.meleeController != reply.controller || reply.sequence <= attacker.charmSequence)
            return;
        auto target = attacker.ai.combatTarget(map_, reply.target);
        if (reply.targetPvP && reply.controller)
            if (auto owner = onlinePlayer(reply.controller))
                owner.attackedFlaggedPlayer();
        if (reply.spell)
        {
            const spell = data.spells.spell(reply.spell);
            if (spell is null || reply.spellMiss > SpellMissInfo.reflect)
                return;
            const miss = cast(SpellMissInfo) reply.spellMiss;
            const targets = SpellTargets(TargetFlags.unit, reply.target);
            if (!reply.secondary)
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELL_GO,
                    spellGoPacket(reply.attacker, reply.spell, [TargetResult(reply.target, miss)], targets));
            if (miss)
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLLOGMISS,
                    spellMissLog(reply.spell, reply.attacker, reply.target, miss));
            else
            {
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLNONMELEEDAMAGELOG,
                    nonMeleeDamageLog(reply.target, reply.attacker, reply.spell, reply.damage, 0, reply.absorbed,
                        0, false, 0, false));
                if (target)
                    attacker.ai.remoteWeaponSpellFinished(spell, target, cast(MeleeHitOutcome) reply.outcome,
                        reply.damage, reply.killed);
            }
            return;
        }
        foreach (ref hit; reply.retaliation)
        {
            if (!hit.damage || hit.school >= 7 || !isFinite(hit.threatFactor) || hit.threatFactor < 0
                || (hit.spell && reply.outcome != MeleeHitOutcome.block))
                continue;
            if (hit.spell)
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLNONMELEEDAMAGELOG,
                    nonMeleeDamageLog(reply.attacker, reply.target, hit.spell, hit.damage, hit.school,
                        0, 0, false, 0, false));
            else
            {
                ByteWriter log;
                log.put(reply.target);
                log.put(reply.attacker);
                log.put(hit.damage);
                log.put(hit.school);
                map_.sendToObservers(reply.attacker, Opcode.SMSG_SPELLDAMAGESHIELD, log.data);
            }
            auto blow = Blow.spell(hit.spell ? hit.school : 0); // Thorns uses the same damage path as on one node.
            if (highGuidOf(reply.target) == HighGuid.player)
                blow.remotePlayer = reply.target;
            blow.threat = hit.threatFactor;
            if (dealRemoteDamage(map_.unitOf(attacker), hit.damage, blow))
                return;
        }
        if (target)
            attacker.ai.remoteSwingFinished(target, cast(MeleeHitOutcome) reply.outcome, reply.damage, reply.killed);
    }

    void areaDamageArrived(ushort peer, const ref AreaDamage message)
    {
        if (!peer || !message.sequence || !canWrite())
            return;
        if (message.reply)
            return areaDamageLanded(peer, message);
        if (message.benefits.length || message.sequence <= lastAreaDamage.get(peer, 0))
            return;
        lastAreaDamage[peer] = message.sequence;
        if (auto map_ = existingMap(message.map, message.instance))
            if (map_.id == message.map)
                applyAreaDamage(peer, map_, message);
    }

    /// Resolve a prepared hit using the target now owned here. Peer zero is a local projectile impact.
    private void applyAreaDamage(ushort peer, Map map_, const ref AreaDamage message)
    {
        import std.math : isFinite, PI, sqrt;
        import dmangos.world.combat : hasInArc;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;
        import dmangos.world.relations : canAttack;
        import dmangos.world.replication : Replica;
        import dmangos.world.spellareas : admitGroundDamage, damagingGroundEffect, refreshGroundAura;
        import dmangos.world.spellcast : radius, SpellMissInfo;
        import dmangos.world.spelldamage : creatureAreaShape, creatureTargetInRange, databaseSpellEffect,
            isCreatureTargetEffect, isHostileAreaEffect, isHostileChainEffect, isRemoteLeechChannel, isTargetedProcEffect,
            namedCreatureShape, remoteTargetAuraEffects, rollRemoteAreaDamage, spellJumpRadius, unblockedAuraEffects;
        import dmangos.world.spellselection : inNamedCreatureCone, namedCreatureCenter, namedCreatureCone,
            namedCreatureRadius;
        import dmangos.world.spellids : ImplicitTarget, SpellEffect;
        import dmangos.world.unit : Blow, UnitKind, UnitRef, combatRelations;
        import dmangos.world.updatefields : TypeId, UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT, UNIT_FIELD_LEVEL;

        auto victim = map_.unit(message.target);
        if ((message.groundTick || message.playerProjectile) && !victim)
        {
            if (!message.redirectOwner)
                redirectAreaImpact(peer, map_, message);
            return;
        }
        if (!victim.alive || (victim.kind == UnitKind.player
            && (victim.session.transferring || victim.session.duelingWith(message.caster)))
            || (victim.kind == UnitKind.creature && (victim.creature.ai is null || victim.creature.ai.evading)))
            return;
        const p = victim.position;
        if ((!message.creatureCast || message.creatureArea || message.namedCreature) && !message.channelled
            && !message.playerProjectile
            && !(message.radius > 0
            && (p.x - message.x) ^^ 2 + (p.y - message.y) ^^ 2 + (p.z - message.z) ^^ 2 <= message.radius ^^ 2))
            return;
        UnitRef caster;
        if (peer)
        {
            auto copy = cast(Replica) map_.findObject(message.caster);
            if (copy is null || copy.owner != peer || (copy.fields.type != TypeId.player
                && ((!message.triggered && !message.creatureCast && !message.groundTick && !message.namedCreature)
                    || copy.fields.type != TypeId.unit)))
                return;
            caster = UnitRef.observed(copy, map_);
        }
        else
        {
            caster = map_.unit(message.caster);
            if (!caster)
                return;
        }
        const attacker = caster.combatRelations(client);
        const casterFields = caster.replica is null ? caster.fields : &caster.replica.fieldsOf();
        const hostile = canAttack(attacker, victim.relating(), client);
        const spell = data.spells.spell(message.spell);
        if (spell is null)
            return;
        if (message.namedCreature && (message.groundTick || message.creatureArea
            || message.previous))
            return;
        if ((message.channelToken != 0) != (message.namedCreature && message.channelled))
            return;
        if (message.playerProjectile && message.channelled)
            return;
        if (message.channelled)
        {
            import std.algorithm.searching : canFind;
            import dmangos.world.spellselection : namedCreatureRange;

            const named = message.namedCreature ? namedCreatureChannel(spell) : size_t.max;
            const actorCanChannel = attacker.player ? !message.creatureCast : message.creatureCast && message.namedCreature;
            if (!actorCanChannel || message.triggered || message.creatureArea
                || (message.namedCreature ? named == size_t.max : !isRemoteLeechChannel(*spell)))
                return;
            size_t targetEffect = size_t.max;
            if (message.namedCreature)
            {
                if (victim.kind != UnitKind.creature || !spellScriptTargets(spell.id).canFind(victim.creature.spawn.entry))
                    return replyCreatureCast(peer, message, SpellMissInfo.evade);
                targetEffect = namedCreatureEffectFor(spell, named, victim.creature.spawn.entry);
                if (targetEffect == size_t.max)
                    return replyCreatureCast(peer, message, SpellMissInfo.evade);
            }
            const operation = message.channelOperation;
            if (operation != AreaDamage.ChannelUpdate.none)
                return applyRemoteChannelUpdate(peer, message, operation, caster, victim, spell);
            const validEffect = message.namedCreature
                ? message.effect == targetEffect && message.radius == namedCreatureRange(*spell, client)
                    && message.auraMs > 0
                : isTargetedProcEffect(*spell, message.effect);
            if (!validEffect || casterFields.get!UNIT_CHANNEL_SPELL != message.spell
                || casterFields.get!UNIT_FIELD_CHANNEL_OBJECT != message.target)
                return;
            const origin = caster.fighter;
            const at = origin.position;
            const distance = sqrt((p.x - at.x) ^^ 2 + (p.y - at.y) ^^ 2 + (p.z - at.z) ^^ 2);
            if ((!message.namedCreature && !hostile) || !attacker.alive || victim.untouchable
                || !isFinite(message.radius) || message.radius <= 0
                || distance > message.radius + origin.combatReach + victim.fighter.combatReach
                || !map_.inLineOfSight(caster.position, victim.position))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            const capture = spell.id == imported!"dmangos.world.spelldamage".crystalPrison;
            if (capture && !hostile)
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            return remoteProcEffect(peer, message, spell, victim, !message.namedCreature || capture,
                attacker.hasFlag(UnitFlags.pvp));
        }
        if (message.playerProjectile)
        {
            if (!attacker.player || spell.casting.speed <= 0 || message.previous || message.creatureCast
                || message.namedCreature || message.creatureArea || message.groundTick || !message.alwaysHits
                || !isTargetedProcEffect(*spell, message.effect))
                return;
            const effect = spell.effect[message.effect];
            const shape = spell.implicitTargetA[message.effect];
            if ((shape == ImplicitTarget.enemy || effect == SpellEffect.schoolDamage) && !hostile)
                return;
            if ((effect == SpellEffect.heal || shape == ImplicitTarget.friend || shape == ImplicitTarget.unitRaid)
                && hostile)
                return;
            if (effect != SpellEffect.schoolDamage)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
        }
        else if (message.namedCreature)
        {
            import std.algorithm.searching : canFind;

            if (victim.kind != UnitKind.creature
                || message.effect != namedCreatureEffectFor(spell, namedCreatureRouting(spell), victim.creature.spawn.entry)
                || message.radius != namedCreatureRadius(*spell, message.effect, client)
                || !spellScriptTargets(spell.id).canFind(victim.creature.spawn.entry))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            const shape = namedCreatureShape(*spell, message.effect);
            if (!attacker.alive && !(message.triggered && casterFields.type == TypeId.unit
                && shape != ImplicitTarget.unitScriptNearCaster))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            if (shape == ImplicitTarget.enumUnitsScriptInCone60 && !inNamedCreatureCone(
                Position(message.x, message.y, message.z, message.facing), p, namedCreatureCone(data, spell.id)))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            if (shape == ImplicitTarget.enumUnitsScriptAoeAtDestLoc)
            {
                if (!client.isValidMapCoord(map_.id, message.x, message.y, message.z, 0))
                    return;
                if (spell.implicitTargetA[message.effect] == ImplicitTarget.database)
                {
                    Position expected;
                    if (!namedCreatureCenter(*spell, message.effect, client, map_.id, caster.position,
                        spell.id in data.spellTargets, null, expected) || message.x != expected.x || message.y != expected.y
                        || message.z != expected.z)
                        return;
                }
            }
            if (message.auraAbsent && victim.hasAuraOf(spell.id))
                return;
            const effect = spell.effect[message.effect];
            if (databaseSpellEffect(effect))
                return applyRemoteSpellScript(peer, message, spell, victim, hostile);
            if (effect != SpellEffect.schoolDamage)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
            if (!hostile)
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
        }
        else if (message.groundTick)
        {
            if (message.triggered || message.creatureCast || message.creatureArea || message.previous
                || !validGroundTick(spell, message) || !hostile || !attacker.alive || victim.untouchable)
                return;
            if (!damagingGroundEffect(*spell, message.effect))
            {
                if (refreshGroundAura(victim, spell, message.effect, message.caster, message.casterLevel,
                    message.auraMs, message.auraValues) && victim.kind == UnitKind.creature)
                {
                    const blow = Blow.spell();
                    dealRemoteDamage(caster, victim, 0, blow);
                }
                return;
            }
            if (!admitGroundDamage(victim, spell, message.caster, message.casterLevel, message.auraMs > 0 ? message.auraMs : 1))
                return;
        }
        else if (message.creatureArea)
        {
            if (casterFields.type != TypeId.unit || !hostile || !attacker.alive || victim.untouchable)
                return;
            const shape = creatureAreaShape(*spell, message.effect);
            if (shape == ImplicitTarget.none || message.radius != radius(*spell, message.effect, client)
                || !isFinite(message.facing))
                return;
            auto origin = caster.position;
            origin.orientation = message.facing;
            if (shape == ImplicitTarget.enemiesInCone && !hasInArc(origin, victim.position, PI / 2))
                return;
            if (message.auraAbsent && victim.hasAuraOf(spell.id))
                return;
            if (spell.effect[message.effect] == SpellEffect.applyAura)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
        }
        else if (message.creatureCast)
        {
            if (casterFields.type != TypeId.unit || message.triggered || message.previous
                || !isCreatureTargetEffect(*spell, message.effect))
                return;
            if (!hostile || !attacker.alive || victim.untouchable
                || (message.auraAbsent && victim.hasAuraOf(spell.id))
                || !creatureTargetInRange(spell, caster.fighter, victim.fighter, client)
                || !map_.inLineOfSight(caster.position, victim.position))
                return replyCreatureCast(peer, message, SpellMissInfo.evade);
            if (spell.effect[message.effect] == SpellEffect.applyAura)
                return remoteProcEffect(peer, message, spell, victim, hostile, false);
        }
        else if (message.triggered)
        {
            if (message.previous || !isTargetedProcEffect(*spell, message.effect))
                return;
            const effect = spell.effect[message.effect];
            const shape = spell.implicitTargetA[message.effect];
            if ((shape == ImplicitTarget.enemy || effect == SpellEffect.schoolDamage) && !hostile)
                return;
            if ((effect == SpellEffect.heal || shape == ImplicitTarget.friend || shape == ImplicitTarget.unitRaid)
                && hostile)
                return;
            if (effect != SpellEffect.schoolDamage)
                return remoteProcEffect(peer, message, spell, victim, hostile, attacker.hasFlag(UnitFlags.pvp));
        }
        else if (!hostile)
            return;
        else if (message.previous)
        {
            if (!isHostileChainEffect(*spell, message.effect) || message.radius != spellJumpRadius
                || message.previous == message.target || message.previous == message.caster)
                return;
        }
        else if (!isHostileAreaEffect(*spell, message.effect))
            return;

        auto result = cast(AreaDamage) message; // the request holds no benefits to share with the reply
        result.reply = true;
        rollRemoteAreaDamage(result, spell, victim);
        if (!result.miss)
        {
            const honor = victim.kind == UnitKind.player ? victim.session.describeHonorVictim() : HonorVictim.init;
            auto blow = message.groundTick ? Blow.periodic(spell.casting.school)
                : Blow.spell(spell.casting.school, result.critical);
            if (peer)
                blow.remotePlayer = attacker.player ? message.caster : caster.replica.meleeController;
            blow.remotePlayerPvP = attacker.hasFlag(UnitFlags.pvp);
            blow.threat = message.threatFactor;
            blow.threatIncludesCaster = true;
            result.killed = dealRemoteDamage(peer && attacker.player ? UnitRef.init : caster, victim, result.damage, blow);
            if (victim.kind == UnitKind.player)
            {
                result.targetPvP = victim.session.isPvP;
                if (result.killed)
                {
                    result.honorless = honor.honorless;
                    result.targetRace = honor.race;
                    result.targetLevel = honor.level;
                    result.targetRank = honor.rank;
                    result.targetVisualRank = honor.visualRank;
                    result.x = honor.position.x;
                    result.y = honor.position.y;
                    result.z = honor.position.z;
                }
            }
            else if (attacker.player && result.killed && !victim.creature.petOwner)
                result.targetLevel = victim.fields.get!UNIT_FIELD_LEVEL;
            if (!message.triggered && !message.suppressProcs && victim.alive && result.damage)
            {
                const hit = ProcHit(spell, result.critical ? ProcEx.criticalHit : ProcEx.normalHit, result.damage);
                const flags = message.groundTick
                    ? imported!"dmangos.world.aurahandlers".ProcFlag.takeHarmfulPeriodic
                    : spellProcFlags(*spell, false, true);
                if (victim.kind == UnitKind.player)
                    victim.session.procAuras(flags, caster, hit);
                else
                    victim.creature.ai.procAuras(flags, caster, hit);
                result.benefits = Character.benefitsFromVictim(victim, message.caster, flags >> 1, hit);
            }
            if (message.namedCreature)
            {
                auto effects = cast(ubyte)(remoteTargetAuraEffects(*spell, message.effect)
                    & ~scriptTargetExclusions(spell.id, victim.creature.spawn.entry));
                if (effects && victim.alive)
                {
                    const immune = victim.fighter.immune;
                    effects = unblockedAuraEffects(*spell, effects, immune);
                    if (effects)
                        installRemoteAura(victim, message, spell, true, attacker.hasFlag(UnitFlags.pvp), message.auraMs,
                            effects);
                }
                namedCreatureHit(victim, message, spell);
            }
        }
        finishAreaDamage(peer, result);
    }

    private static bool validGroundTick(const(SpellInfo)* spell, const ref AreaDamage message)
    {
        import std.math : isFinite;
        import dmangos.world.spellids : SpellEffect;

        return spell !is null && message.effect < spell.effect.length
            && spell.effect[message.effect] == SpellEffect.persistentAreaAura && spell.casting.school < 7
            && message.radius > 0 && isFinite(message.radius) && isFinite(message.amount) && message.amount >= 0;
    }

    // The old owner declines without applying the impact. Only the source can issue a second request.
    private void redirectAreaImpact(ushort peer, Map map_, const ref AreaDamage message)
    {
        if (sendAreaDamage is null)
            return;
        ushort owner;
        if (const hint = recentHandoff(message.target))
            owner = hint.node;
        else if (auto copy = cast(Replica) map_.findObject(message.target))
            owner = copy.owner;
        if (!owner || owner == nodeId)
            return;
        auto redirect = cast(AreaDamage) message;
        redirect.reply = true;
        redirect.redirectOwner = owner;
        sendAreaDamage(peer, redirect);
    }

    private void retryGroundTick(ushort peer, const ref AreaDamage message)
    {
        import dmangos.world.caster : Caster;
        import dmangos.world.spellareas : admitGroundDamage, damagingGroundEffect, hitGroundTarget, refreshGroundAura, withinGroundArea;
        import dmangos.world.unit : UnitKind;

        auto map_ = existingMap(message.map, message.instance);
        const spell = data.spells.spell(message.spell);
        if (map_ is null || !validGroundTick(spell, message))
            return;
        auto unit = map_.unit(message.caster);
        if (!unit.alive)
            return;
        if (message.redirectOwner != nodeId)
        {
            if (sendAreaDamage !is null && message.redirectOwner != peer)
            {
                auto retry = cast(AreaDamage) message;
                retry.reply = false;
                retry.redirectOwner = peer;
                retry.sequence = nextGameplaySequence();
                sendAreaDamage(message.redirectOwner, retry);
            }
            return;
        }
        auto target = map_.unit(message.target);
        auto caster = unit.kind == UnitKind.player ? Caster.of(unit.session) : Caster.of(unit.creature, map_, this);
        if (!caster || !target.alive || target.untouchable
            || (target.kind == UnitKind.player && target.session.transferring)
            || (target.kind == UnitKind.creature && target.creature.ai is null)
            || !withinGroundArea(target.position, Position(message.x, message.y, message.z), message.radius)
            || !caster.hostileTo(target))
            return;
        if (damagingGroundEffect(*spell, message.effect))
        {
            if (admitGroundDamage(target, spell, caster.guid, caster.level, message.auraMs > 0 ? message.auraMs : 1))
                hitGroundTarget(caster, spell, target, message.groundAmount);
        }
        else
            refreshGroundAura(target, spell, message.effect, caster.guid, message.casterLevel,
                message.auraMs, message.auraValues);
    }

    private void applyRemoteChannelUpdate(ushort peer, const ref AreaDamage message,
        AreaDamage.ChannelUpdate operation, UnitRef caster, UnitRef victim, const(SpellInfo)* spell)
    {
        import dmangos.world.spellcast : SpellMissInfo;
        import dmangos.world.updatefields : UNIT_CHANNEL_SPELL, UNIT_FIELD_CHANNEL_OBJECT;

        final switch (operation)
        {
        case AreaDamage.ChannelUpdate.none, AreaDamage.ChannelUpdate.invalid:
            return;
        case AreaDamage.ChannelUpdate.complete:
            if (message.namedCreature && caster.alive)
                applyNamedChannelCompletion(caster, victim, spell, message.channelToken);
            return;
        case AreaDamage.ChannelUpdate.cancel:
            updateRemoteChannelAura(victim, message, true);
            return;
        case AreaDamage.ChannelUpdate.shorten:
            const fields = caster.replica is null ? caster.fields : &caster.replica.fieldsOf();
            if (message.namedCreature && (fields.get!UNIT_CHANNEL_SPELL != message.spell
                || fields.get!UNIT_FIELD_CHANNEL_OBJECT != message.target))
                return;
            if (updateRemoteChannelAura(victim, message, false) && message.namedCreature)
                replyCreatureCast(peer, message, SpellMissInfo.none);
            return;
        }
    }

    private bool updateRemoteChannelAura(UnitRef victim, const ref AreaDamage message, bool cancel)
    {
        auto aura = victim.auraSet.find(message.spell, message.caster);
        if (aura is null || aura.detachedChannel || (message.namedCreature && aura.channelToken != message.channelToken))
            return false;
        if (cancel)
        {
            if (victim.kind == UnitKind.player)
                victim.session.removeAura(aura);
            else
            {
                victim.creature.loseAura(aura, victim.map);
                victim.map.flushCreature(victim.creature);
            }
        }
        else if (aura.duration > message.auraMs
            || (message.namedCreature && imported!"dmangos.world.spelldamage".permanentNamedCreatureVisual(message.spell)))
        {
            aura.duration = message.auraMs;
            if (victim.kind == UnitKind.player)
                victim.session.sendAuraDuration(aura);
        }
        return true;
    }

    private void applyNamedChannelCompletion(UnitRef caster, UnitRef victim, const(SpellInfo)* spell, ulong token)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.spelldamage : namedChannelTriggerEffect;
        import dmangos.world.spellselection : namedCreatureRange;

        const child = namedChannelCompletionSpell(spell);
        if (child is null || !spellScriptTargets(child.id, 0).canFind(victim.creature.spawn.entry))
            return;
        const from = caster.position, to = victim.position;
        const reach = namedCreatureRange(*spell, client) + caster.fighter.combatReach + victim.fighter.combatReach;
        if (!((from.x - to.x) ^^ 2 + (from.y - to.y) ^^ 2 + (from.z - to.z) ^^ 2 <= reach ^^ 2)
            || !victim.map.inLineOfSight(from, to))
            return;
        if (!victim.creature.consumeChannelCompletion(spell.id, caster.combatGuid, token,
                namedChannelTriggerEffect(*spell), transportNow(), victim.map))
            return;
        import dmangos.world.spelldamage : crystalPrisonCompletion, crystalPrisonConjure;

        auto creature = victim.creature;
        if (child.id == crystalPrisonCompletion && !creature.petOwner)
        {
            import dmangos.world.eventai : castTriggered;

            creature.ai.bind(victim.map);
            if (creature.ai.castSpell(spellInfo(crystalPrisonConjure), creature.guid, castTriggered))
            {
                creature.ai.scriptDespawn(0);
                victim.map.wake(creature.guid);
            }
        }
        else
            creature.ai.spellHitBy(caster.combatGuid, child.id, 1u << child.casting.school, victim.map);
    }

    private void replyCreatureCast(ushort peer, const ref AreaDamage message,
        imported!"dmangos.world.spellcast".SpellMissInfo miss)
    {
        if (!message.creatureCast && !message.namedCreature && !message.playerProjectile && !(message.channelled && miss))
            return;
        auto result = cast(AreaDamage) message;
        result.reply = true;
        result.miss = miss;
        finishAreaDamage(peer, result);
    }

    private void finishAreaDamage(ushort peer, AreaDamage result)
    {
        result.redirectOwner = 0;
        if (!peer)
            areaDamageLanded(0, result);
        else if (sendAreaDamage !is null)
            sendAreaDamage(peer, result);
    }

    /// Apply damage only at the target's authority. A lethal creature hit settles its tap once here.
    private bool dealRemoteDamage(UnitRef victim, uint damage, const ref imported!"dmangos.world.unit".Blow blow)
    {
        return dealRemoteDamage(UnitRef.init, victim, damage, blow);
    }

    private bool dealRemoteDamage(UnitRef attacker, UnitRef victim, uint damage,
        const ref imported!"dmangos.world.unit".Blow blow)
    {
        import dmangos.world.dbscripts : DbScriptType;
        import dmangos.world.unit : dealDamage;

        if (!victim.alive)
            return false;
        auto creature = victim.creature;
        if (blow.remotePlayer && damage && creature !is null && !creature.petOwner && !creature.lootRecipient)
        {
            auto group = groups.of(blow.remotePlayer);
            creature.setLootRecipient(blow.remotePlayer, group is null ? 0 : group.id);
        }
        dealDamage(attacker, victim, damage, blow);
        if (victim.alive)
            return false;
        if (blow.remotePlayer && creature !is null && !creature.petOwner)
        {
            Character.rewardCreatureKillFor(this, victim.map, creature, creature.lootRecipient);
            startScript(DbScriptType.creatureDeath, creature.template_.entry, victim.map, creature.guid,
                blow.remotePlayer);
        }
        return true;
    }

    /// A damage aura keeps the player who applied it as its source after their handoff.
    package void dealRemotePeriodicDamage(UnitRef victim, imported!"dmangos.world.auras".Aura aura, uint damage,
        size_t effect = 0, uint drained = 0)
    {
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.aurahandlers : ProcFlag;
        import dmangos.world.procs : ProcEx, ProcHit;
        import dmangos.world.unit : Blow;
        import dmangos.world.updatefields : TypeId, UNIT_FIELD_FLAGS;

        if (!victim.alive || !canWrite())
            return;
        auto blow = Blow.periodic(aura.spell.casting.school);
        blow.remotePlayer = aura.caster;
        blow.remotePlayerPvP = aura.periodicCasterPvP;
        blow.threat = aura.periodicThreat;
        auto copy = cast(Replica) victim.map.findObject(aura.caster);
        if (copy !is null && copy.fields.type == TypeId.player)
            blow.remotePlayerPvP = (copy.fields.get!UNIT_FIELD_FLAGS & UnitFlags.pvp) != 0;
        const honor = victim.kind == UnitKind.player ? victim.session.describeHonorVictim() : HonorVictim.init;
        const health = victim.health;
        const killed = dealRemoteDamage(victim, damage, blow);
        const loss = health > victim.health ? health - victim.health : 0;
        if (drained > loss)
            drained = loss;
        imported!"dmangos.cluster.protocol".RemoteSpellBenefit[] benefits;
        if (!killed && damage)
        {
            const hit = ProcHit(aura.spell, ProcEx.normalHit, damage);
            if (copy !is null && copy.fields.type == TypeId.player)
            {
                auto source = UnitRef.observed(copy, victim.map);
                if (victim.kind == UnitKind.player)
                    victim.session.procAuras(ProcFlag.takeHarmfulPeriodic, source, hit);
                else if (victim.creature.ai !is null)
                    victim.creature.ai.procAuras(ProcFlag.takeHarmfulPeriodic, source, hit);
            }
            benefits = Character.benefitsFromVictim(victim, aura.caster, ProcFlag.dealHarmfulPeriodic, hit);
        }
        reportPeriodicResult(victim, aura, effect, damage, drained, benefits);
        if (!killed || victim.kind != UnitKind.player)
            return;
        reportRemotePlayerKill(aura.caster, honor, victim.map);
    }

    private void reportRemotePlayerKill(ulong attacker, const ref imported!"dmangos.world.honor".HonorVictim honor, Map map_)
    {
        const share = KillShare(target: attacker, victim: honor.guid, level: honor.level,
            map: map_.id, instance: map_.instanceId, x: honor.position.x, y: honor.position.y,
            z: honor.position.z, race: honor.race, rank: honor.rank, visualRank: honor.visualRank,
            honorless: honor.honorless);
        if (onlinePlayer(attacker) !is null)
            killShareArrived(share);
        else if (killShareElsewhere !is null)
            if (const owner = remoteKillRecipient(attacker, map_).node)
                killShareElsewhere(owner, share);
    }

    void delegate(ushort, const ref PeriodicResult) sendPeriodicResult;
    private ulong[ushort] lastPeriodicResult;

    package void reportPeriodicResult(UnitRef victim, imported!"dmangos.world.auras".Aura aura, size_t effect,
        uint damage, uint drained, imported!"dmangos.cluster.protocol".RemoteSpellBenefit[] benefits = null)
    {
        if ((!damage && !drained) || !canWrite())
            return;
        const message = PeriodicResult(sequence: nextGameplaySequence(), caster: aura.caster,
            target: victim.combatGuid, map: victim.map.id, instance: victim.map.instanceId, spell: aura.spell.id,
            effect: cast(ubyte) effect, damage: damage, drained: drained, targetAlive: victim.alive,
            detached: aura.detachedChannel, benefits: benefits);
        if (onlinePlayer(aura.caster) !is null)
            return applyPeriodicResult(message);
        if (sendPeriodicResult !is null)
            if (const owner = remoteKillRecipient(aura.caster, victim.map).node)
                sendPeriodicResult(owner, message);
    }

    void periodicResultArrived(ushort peer, const ref PeriodicResult message)
    {
        if (!peer || !message.sequence || !canWrite() || message.sequence <= lastPeriodicResult.get(peer, 0))
            return;
        lastPeriodicResult[peer] = message.sequence;
        if (onlinePlayer(message.caster) !is null)
            return applyPeriodicResult(message);
        if (!message.forwarded && sendPeriodicResult !is null)
            if (const hint = recentHandoff(message.caster))
            {
                auto onward = cast(PeriodicResult) message;
                onward.sequence = nextGameplaySequence();
                onward.forwarded = true;
                sendPeriodicResult(hint.node, onward);
            }
    }

    private void applyPeriodicResult(const ref PeriodicResult message)
    {
        import dmangos.world.auras : AuraType;
        import dmangos.world.caster : Caster;
        import dmangos.world.defines : Power;
        import dmangos.world.spelldamage : changeUnitPower, effectMultiplier, SpellHeal, spellHeal;
        import dmangos.world.spellmods : SpellModOp;
        import dmangos.world.updatefields : UNIT_FIELD_MAXPOWER1;

        auto source = onlinePlayer(message.caster);
        const spell = data.spells.spell(message.spell);
        if (source is null || source.player is null || !source.player.alive || spell is null
            || message.effect >= spell.effect.length || message.target == message.caster)
            return;
        if ((spell.attributesEx & (0x04 | 0x40)) && !message.detached
            && source.channelledAt(spell) != message.target)
            return;
        foreach (ref benefit; message.benefits)
            source.applySpellBenefit(benefit);
        auto caster = Caster.of(source);
        const i = message.effect;
        switch (spell.casting.applyAuraName[i])
        {
        case AuraType.periodicLeech:
            const factor = spell.casting.multipleValue[i] > 0 ? spell.casting.multipleValue[i] : 1.0f;
            spellHeal(caster, spell, caster.unit, cast(int)(message.drained
                * caster.spellMod(SpellModOp.multipleValue, spell, factor)), SpellHeal(true));
            goto case AuraType.periodicDamage;
        case AuraType.periodicDamage:
            auto map_ = existingMap(message.map, message.instance);
            if (message.targetAlive && map_ !is null && map_ is source.currentMap)
            {
                auto target = map_.unit(message.target);
                if (!target)
                    if (auto copy = cast(Replica) map_.findObject(message.target))
                        target = UnitRef.observed(copy, map_);
                caster.damageDealt(spell, target, false, message.damage, true);
            }
            break;
        case AuraType.periodicManaLeech:
            if (spell.miscValue[i] >= 0 && spell.miscValue[i] <= Power.happiness)
            {
                const power = cast(Power) spell.miscValue[i];
                if (caster.fields.get!UNIT_FIELD_MAXPOWER1(power))
                {
                    const gain = cast(int)(message.drained * effectMultiplier(caster, spell, i));
                    if (gain > 0)
                    {
                        changeUnitPower(caster, caster.unit, power, gain);
                        caster.flush();
                    }
                }
            }
            break;
        default:
            break;
        }
    }

    /// Find a remote solo recipient even when it has no replica near the victim.
    package Tuple!(ushort, "node", uint, "level") remoteKillRecipient(ulong guid, Map map_)
    {
        import dmangos.world.updatefields : TypeId, UNIT_FIELD_LEVEL;

        alias Route = typeof(return);
        if (const hint = recentHandoff(guid))
            return Route(hint.node, hint.level);
        if (const owner = remotePlayer(guid))
            return Route(owner.node, owner.entry.level);
        if (auto copy = cast(Replica) map_.findObject(guid))
            if (copy.fields.type == TypeId.player)
                return Route(copy.owner, copy.fields.get!UNIT_FIELD_LEVEL);
        return Route.init;
    }

    private const(Heard)* recentHandoff(ulong guid)
    {
        if (const hint = guid in lastHeard)
            if (hint.level && MonoTime.currTime - hint.at < presenceGrace)
                return hint;
        return null;
    }

    package void killShareArrived(const ref KillShare share)
    {
        import dmangos.world.honor : HonorVictim;

        auto player = onlinePlayer(share.target);
        if (player is null || player.character is null)
        {
            // A peer sent the credit before its presence caught up with our handoff.
            if (!share.forwarded && killShareElsewhere !is null)
                if (const hint = recentHandoff(share.target))
                {
                    auto onward = cast(KillShare) share;
                    onward.forwarded = true;
                    killShareElsewhere(hint.node, onward);
                }
            return;
        }
        if (share.entry)
            return player.killShared(share.entry, share.victim, share.level, share.xp, share.rate, share.reputationRate);
        if (share.victim && share.victim <= uint.max && share.victim != share.target)
            player.playerKilledByMe(HonorVictim(share.victim, share.level, share.race, share.rank, share.visualRank,
                share.honorless, Position(share.x, share.y, share.z)), share.map, share.instance);
    }

    private void applyRemoteSpellScript(ushort peer, const ref AreaDamage message, const(SpellInfo)* spell,
        UnitRef victim, bool hostile)
    {
        import dmangos.world.combat : Fighter;
        import dmangos.world.spellcast : rollSpellHit, SpellMissInfo;

        const i = message.effect;
        const school = spell.casting.school;
        const target = victim.fighter;
        enum uint noImmunities = 0x20000000;
        if (!(spell.attributes & noImmunities) && (target.immune.toSpell(school, spell.casting.dispel, spell.casting.mechanic)
            || target.immune.toEffect(spell.effect[i], spell.casting.effectMechanic[i], spell.casting.applyAuraName[i])))
            return replyCreatureCast(peer, message, SpellMissInfo.immune);
        if (hostile && !message.alwaysHits)
        {
            const player = message.caster <= uint.max;
            const caster = Fighter(guid: message.caster, player: player, playerControlled: player, level: message.casterLevel);
            const miss = rollSpellHit(caster, target, *spell, victim.resistance(school), message.hitBonus, victim.map.random());
            if (miss)
                return replyCreatureCast(peer, message, miss);
        }
        applyTargetSpellScript(spell.id, victim.map, message.caster, message.target);
        if (victim.map.creatureAt(message.target) is victim.creature)
            namedCreatureHit(victim, message, spell);
        replyCreatureCast(peer, message, SpellMissInfo.none);
    }

    private void remoteProcEffect(ushort peer, const ref AreaDamage message, const(SpellInfo)* spell,
        UnitRef victim, bool hostile, bool casterPvP)
    {
        import std.algorithm.comparison : max;
        import dmangos.world.combat : Fighter;
        import dmangos.world.spellcast : rollSpellHit, SpellMissInfo;
        import dmangos.world.spelldamage : applyHealAmount, remoteTargetAuraEffects, unblockedAuraEffects;
        import dmangos.world.spellids : SpellEffect;
        import dmangos.world.unit : UnitKind;

        const i = message.effect;
        const school = spell.casting.school;
        const immune = victim.fighter.immune;
        enum uint noImmunities = 0x20000000;
        const checksImmunity = !(spell.attributes & noImmunities);
        if (checksImmunity && immune.toSpell(school, spell.casting.dispel, spell.casting.mechanic))
            return replyCreatureCast(peer, message, SpellMissInfo.immune);
        if (spell.effect[i] == SpellEffect.heal)
        {
            if (checksImmunity && immune.toEffect(SpellEffect.heal, spell.casting.effectMechanic[i],
                spell.casting.applyAuraName[i]))
                return;
            auto result = cast(AreaDamage) message;
            result.reply = true;
            uint restored;
            result.damage = applyHealAmount(spell, victim, cast(uint) max(0, message.amount), restored);
            if (victim.kind == UnitKind.player)
            {
                if (restored && (spell.implicitTargetA[i] == ImplicitTarget.friend
                    || (spell.implicitTargetA[i] == ImplicitTarget.unitFriendChainHeal && spell.casting.chainTarget[i] <= 1)))
                    victim.session.outsideQuestAid(message.caster);
                victim.session.flushPlayerChanges();
            }
            else
                victim.map.flushObjectChanges(victim.creature);
            if (message.namedCreature)
                namedCreatureHit(victim, message, spell);
            finishAreaDamage(peer, result);
            return;
        }
        if (hostile && !message.alwaysHits)
        {
            const isPlayer = message.caster <= uint.max;
            const caster = Fighter(guid: message.caster, player: isPlayer, playerControlled: isPlayer,
                level: message.casterLevel);
            if (school >= 7)
                return replyCreatureCast(peer, message, SpellMissInfo.immune);
            const missed = rollSpellHit(caster, victim.fighter, *spell, victim.resistance(school),
                message.hitBonus, victim.map.random());
            if (missed)
                return replyCreatureCast(peer, message, missed);
        }
        int lasts = message.auraMs;
        if (hostile && lasts > 0 && message.caster <= uint.max && victim.kind == UnitKind.player)
        {
            lasts = victim.session.diminishedDuration(spell, lasts);
            if (!lasts)
                return;
        }
        auto mask = remoteTargetAuraEffects(*spell, i);
        if (message.namedCreature)
            mask &= cast(ubyte) ~scriptTargetExclusions(spell.id, victim.creature.spawn.entry);
        const effects = unblockedAuraEffects(*spell, mask, immune);
        if (!effects)
            return replyCreatureCast(peer, message, SpellMissInfo.immune);
        installRemoteAura(victim, message, spell, hostile, casterPvP, lasts, effects);
        if (message.namedCreature && spell.id == imported!"dmangos.world.spelldamage".crystalPrison
            && victim.kind == UnitKind.creature && !victim.creature.petOwner && message.amount > 0)
        {
            auto ai = victim.creature.ai;
            if (auto source = victim.map.unit(message.caster))
            {
                ai.attackedBy(source, victim.map);
                ai.addThreat(source, message.amount);
            }
            else if (auto mirror = cast(imported!"dmangos.world.replication".Replica) victim.map.findObject(message.caster))
            {
                ai.attackedBy(UnitRef.observed(mirror, victim.map), victim.map);
                ai.addRemoteThreat(message.caster, message.amount);
            }
            victim.map.wake(victim.creature.guid);
        }
        if (message.namedCreature)
            namedCreatureHit(victim, message, spell);
        replyCreatureCast(peer, message, SpellMissInfo.none);
    }

    private static void installRemoteAura(UnitRef victim, const ref AreaDamage message, const(SpellInfo)* spell,
        bool hostile, bool casterPvP, int lasts, ubyte effects)
    {
        import dmangos.world.auras : AuraType, makeAura;
        import dmangos.world.unit : UnitKind;

        auto aura = makeAura(spell, message.caster, message.casterLevel, lasts, !hostile, message.auraValues);
        aura.effects = effects;
        aura.detachedChannel = message.triggered;
        aura.channelToken = message.channelToken;
        if (aura.has(AuraType.periodicDamage) || aura.has(AuraType.periodicLeech))
        {
            aura.periodicThreat = message.threatFactor;
            aura.periodicResistanceMod = message.resistanceModifier;
            aura.periodicCasterPvP = casterPvP;
        }
        if (victim.kind == UnitKind.player)
        {
            if (message.creatureCast)
                victim.hostileSpellLanded();
            victim.session.addAura(aura);
        }
        else
        {
            bool added;
            victim.creature.receiveAura(aura, victim.map, added);
            victim.map.flushObjectChanges(victim.creature);
        }
    }

    private static void namedCreatureHit(UnitRef victim, const ref AreaDamage message, const(SpellInfo)* spell)
    {
        if (victim.creature.alive)
            victim.creature.ai.spellHitBy(message.caster, spell.id, 1u << spell.casting.school, victim.map);
    }

    private void areaDamageLanded(ushort peer, const ref AreaDamage message)
    {
        import dmangos.world.aurahandlers : ProcFlag;
        import dmangos.world.experience : grayLevel;
        import dmangos.world.honor : HonorVictim;
        import dmangos.world.procs : ProcEx, ProcHit, spellProcFlags;
        import dmangos.world.replication : Replica;
        import dmangos.world.spellcast : healLog, nonMeleeDamageLog, spellMissLog, SpellMissInfo;
        import dmangos.world.spellids : SpellEffect;
        import dmangos.world.spelldamage : databaseSpellEffect;
        import dmangos.world.unit : UnitRef;

        if (peer)
        {
            if (message.sequence <= lastAreaDamageReply.get(peer, 0))
                return;
            lastAreaDamageReply[peer] = message.sequence;
        }
        if (message.groundTick && message.redirectOwner)
            return retryGroundTick(peer, message);
        if (message.playerProjectile && message.redirectOwner)
        {
            if (auto map_ = existingMap(message.map, message.instance))
                if (map_.unit(message.caster) && message.redirectOwner != peer)
                {
                    auto retry = cast(AreaDamage) message;
                    retry.reply = false;
                    retry.redirectOwner = peer;
                    if (message.redirectOwner == nodeId)
                        applyAreaDamage(0, map_, retry);
                    else if (const spell = data.spells.spell(message.spell))
                        sendReplicaSpell(map_, message.redirectOwner, spell, retry);
                }
            return;
        }
        if ((message.triggered || message.creatureCast || message.groundTick || message.namedCreature)
            && message.caster > uint.max)
            return creatureProcLanded(peer, message);
        auto caster = onlinePlayer(message.caster);
        if (caster is null || caster.player is null || caster.transferring
            || caster.currentMap.id != message.map || caster.currentMap.instanceId != message.instance)
            return;
        const spell = data.spells.spell(message.spell);
        if (spell is null || message.miss > SpellMissInfo.reflect)
            return;
        auto map_ = caster.currentMap;
        if (message.channelled)
        {
            if (message.namedCreature && !caster.namedChannelActiveAt(spell, message.target, message.channelToken))
                return;
            if (message.miss && caster.channelActiveAt(spell, message.target))
            {
                map_.sendToWatchers(caster, Opcode.SMSG_SPELLLOGMISS,
                    spellMissLog(message.spell, message.caster, message.target, cast(SpellMissInfo) message.miss), true);
                caster.endChannel(true);
            }
            else if (message.namedCreature && !message.miss)
                caster.remoteChannelAccepted(spell, message.target, peer);
            return;
        }
        if (message.namedCreature && !message.miss && message.effect < spell.effect.length)
        {
            caster.rewardPlayerAndGroupAtCast(message.target, spell.id, peer);
            if (spell.effect[message.effect] == SpellEffect.applyAura || databaseSpellEffect(spell.effect[message.effect]))
                return;
        }
        if (!message.miss && (message.triggered || message.namedCreature || message.playerProjectile)
            && message.effect < spell.effect.length
            && spell.effect[message.effect] == SpellEffect.heal)
            return map_.sendToWatchers(caster, Opcode.SMSG_SPELLHEALLOG,
                healLog(message.target, message.caster, message.spell, message.damage, message.critical), true);
        if (message.miss)
            return map_.sendToWatchers(caster, Opcode.SMSG_SPELLLOGMISS,
                spellMissLog(message.spell, message.caster, message.target, cast(SpellMissInfo) message.miss), true);
        if (message.playerProjectile && message.effect < spell.effect.length
            && spell.effect[message.effect] == SpellEffect.applyAura)
            return;
        if (caster.player.alive)
        {
            caster.enterCombatFor(Character.combatLinger);
            if (message.targetPvP)
                caster.attackedFlaggedPlayer();
            if (peer && message.damage && !message.groundTick)
                caster.wearOnHit();
        }
        if (peer && message.killed && message.target <= uint.max)
            caster.playerKilledByMe(HonorVictim(message.target, message.targetLevel, message.targetRace,
                message.targetRank, message.targetVisualRank, message.honorless, Position(message.x, message.y, message.z)));
        else if (peer && !message.triggered && !message.suppressProcs && message.killed
            && message.targetLevel > grayLevel(caster.player.data.level))
            caster.procAuras(ProcFlag.kill, UnitRef.init);
        map_.sendToWatchers(caster, Opcode.SMSG_SPELLNONMELEEDAMAGELOG,
            nonMeleeDamageLog(message.target, message.caster, message.spell, message.damage, spell.casting.school,
                message.absorbed, message.resisted, false, 0, message.critical), true);
        if (message.groundTick)
        {
            foreach (ref benefit; message.benefits)
                caster.applySpellBenefit(benefit);
            if (!message.killed)
                if (auto copy = cast(Replica) map_.findObject(message.target))
                    if (copy.owner == peer)
                    {
                        auto target = UnitRef.observed(copy, map_);
                        caster.procAuras(ProcFlag.dealHarmfulPeriodic, target,
                            ProcHit(spell, ProcEx.normalHit, message.damage, 0, message.damage != 0));
                        caster.classAreaTick(spell, target);
                    }
            return;
        }
        if (!message.triggered && !message.suppressProcs && !message.killed)
            if (auto other = spellImpactTarget(map_, peer, message.target))
            {
                caster.procAuras(spellProcFlags(*spell, false, false), other,
                    ProcHit(spell, message.critical ? ProcEx.criticalHit : ProcEx.normalHit, message.damage,
                        0, message.damage != 0));
                foreach (ref benefit; message.benefits)
                    caster.applySpellBenefit(benefit);
                caster.targetTriggers(spell, [message.target], other);
            }
    }

    private static UnitRef spellImpactTarget(Map map_, ushort peer, ulong guid)
    {
        import dmangos.world.replication : Replica;

        if (!peer)
            return map_.unit(guid);
        if (auto copy = cast(Replica) map_.findObject(guid))
            if (copy.owner == peer)
                return UnitRef.observed(copy, map_);
        return UnitRef.init;
    }

    private void creatureProcLanded(ushort peer, const ref AreaDamage message)
    {
        import dmangos.world.spellcast : healLog, nonMeleeDamageLog, spellGoPacket, spellMissLog, SpellMissInfo,
            SpellTargets, TargetFlags, TargetResult;
        import dmangos.world.spellids : SpellEffect;

        auto map_ = existingMap(message.map, message.instance);
        if (map_ is null || map_.id != message.map)
            return;
        auto caster = map_.creatureAt(message.caster);
        if (message.channelled)
        {
            if (message.miss && caster !is null && caster.ai !is null)
                caster.ai.namedCreatureChannelRejected(message.channelToken);
            return;
        }
        auto target = spellImpactTarget(map_, peer, message.target);
        const spell = data.spells.spell(message.spell);
        if (caster is null || !target || spell is null || message.effect >= spell.effect.length
            || message.miss > SpellMissInfo.reflect)
            return;
        if (message.creatureCast && !message.creatureArea && !message.namedCreature)
        {
            const targets = SpellTargets(TargetFlags.unit, message.target);
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELL_GO, spellGoPacket(message.caster, message.spell,
                [TargetResult(message.target, cast(SpellMissInfo) message.miss)], targets));
        }
        if (message.namedCreature && !message.miss && caster.ai !is null)
            caster.ai.remoteNamedSpellHit(message.target, spell);
        if (message.miss)
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELLLOGMISS,
                spellMissLog(message.spell, message.caster, message.target, cast(SpellMissInfo) message.miss));
        else if (spell.effect[message.effect] == SpellEffect.heal)
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELLHEALLOG,
                healLog(message.target, message.caster, message.spell, message.damage, message.critical));
        else if (spell.effect[message.effect] == SpellEffect.schoolDamage || message.groundTick)
        {
            map_.sendToObservers(message.caster, Opcode.SMSG_SPELLNONMELEEDAMAGELOG, nonMeleeDamageLog(message.target,
                message.caster, message.spell, message.damage, spell.casting.school, message.absorbed,
                message.resisted, false, 0, message.critical));
            if ((message.creatureCast || message.groundTick) && caster.alive && caster.ai !is null)
                caster.ai.remoteSpellDamageDealt(spell, target, message.critical, message.damage,
                    message.killed);
        }
    }

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
        if (battlegroup !is null)
            battlegroup.queue.nodeLost(config.realmId, node);
        else if (!config.battlegroup.length)
            if (auto queue = battlegroundQueue)
                queue.nodeLost(0, node);
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
        LoginDatabase accounts = null, Battlegroup sharedBattles = null)
    in (database !is null && data !is null && client !is null)
    {
        this.accounts = accounts is null ? new MemoryLoginDatabase : accounts;
        this.config = config;
        this.database = database;
        this.data = data;
        this.client = client;
        foreach (ref spawn; data.creatureSpawns)
            if (spawn.guid > initialCreatureSpawn)
                initialCreatureSpawn = spawn.guid;
        foreach (ref spawn; data.gameObjectSpawns)
            if (spawn.guid > initialGameObjectSpawn)
                initialGameObjectSpawn = spawn.guid;
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
        this.groups = new Groups(database, this, next.group, config.battlegroup.length ? config.realmId : 0);
        groupService = new GroupService(this);
        respawnAt = database.loadCreatureRespawns();
        creaturePools = new CreaturePools(() => this.database, config.realmId, data, respawnAt);
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
        import dmangos.world.groupservice : LootTurnHost;

        services.provide!LootTurnHost((const(ubyte)[]) => LootTurnHost(groups, this));
        services.provide!BattlegroundQueueHost((const(ubyte)[] state) =>
            BattlegroundQueueHost(battlegroup is null ? newBattlegroundQueue() : battlegroup.queue, state,
                battlegroup is null || battlegroup.host is this, this));
        battlegrounds = new Battlegrounds(this);
        if (sharedBattles !is null) sharedBattles.attach(this);
        gameEvents = new GameEvents;
        data.npcs.conditions.eventActive = (uint id) => gameEvents.isActive(id);
        data.npcs.conditions.holidayActive = (uint holiday) => gameEvents.holidayActive(holiday);
        updateGameEvents(clock(), true); // before any cell loads, so its spawns follow the events now
        services.provide!ChannelsHost((const(ubyte)[] state) => ChannelsHost(new ChannelService(this, client,
            ChannelSettings(config.allowTwoSideInteractionChannel), state)));
        services.provide!InvasionHost(&newInvasionHost);
        services.listen!(InvasionHost, InvasionState)(&invasionHeard);
        services.provide!WeatherHost((const(ubyte)[] state) => WeatherHost(this, state));
        services.listen!(WeatherHost, WeatherNotice)(&weatherHeard);
        services.provide!WarEffortHost(&newWarEffortHost);
        services.listen!(WarEffortHost, WarEffort)(&warEffortHeard); // before it starts: it tells as it does
        worldPvp = new WorldPvpFollower(this);
        services.provide!WorldPvpHost(&newWorldPvpHost);
        services.listen!(WorldPvpHost, WorldPvp)(&worldPvp.heard);
        startAllServices();
    }

    /// The battleground copies this node runs.
    Battlegrounds battlegrounds;
    import dmangos.world.battlegroup : Battlegroup, battlegroupInstance, realmPlayerGuid;
    Battlegroup battlegroup;
    string realmDisplayName;

    ulong playerGuid(uint local) const
    {
        return realmPlayerGuid(config.battlegroup.length ? config.realmId : 0, local);
    }

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
        {
            state.trashRespawns.remove(spawn.guid);
            if (state.dead.remove(spawn.guid))
                database.deleteInstanceRespawn(spawn.guid, m.instanceId);
        }
        if (m.findObject(makeGuid(HighGuid.unit, spawn.entry, spawn.guid)) !is null)
            return;
        auto back = makeCreature(spawn);
        if (back is null)
            return;
        back.instanceId = m.instanceId;
        m.addObject(back);
        queueLinked(m.id, m.instanceId, back);
        if (auto script = m.instanceId in instanceScripts)
        {
            import dmangos.script.api : CreatureLoaded, EntityRef;

            script.raise(CreatureLoaded(EntityRef(back.guid)));
        }
    }

    /// Spawn `guid`, dead and waiting, is due now.
    private void respawnSpawnNow(uint guid)
    {
        if (creaturePools.manages(guid))
        {
            if (creaturePools.waiting(guid))
                creaturePools.dead(guid, unixTime, true);
            return;
        }
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
     * In a dungeon copy, a slave that waits on its master: `cantSpawnIfBossDead` while its master
     * is dead, `cantSpawnIfBossAlive` while it lives.
     */
    private bool cantSpawnWhileBossDead(const ref CreatureSpawn spawn, const(InstanceState)* state)
    {
        if (state is null)
            return false;
        const link = data.creatureLinks.linkOf(spawn.guid, spawn.entry, spawn.map);
        if (link is null || !(link.flags & (LinkFlag.cantSpawnIfBossDead | LinkFlag.cantSpawnIfBossAlive)))
            return false;
        uint master = link.masterGuid;
        if (!master)
        {
            float nearest = float.infinity;
            foreach (indices; data.creatureCells.get(spawn.map, null))
                foreach (index; indices)
                {
                    const ref candidate = data.creatureSpawns[index];
                    if (candidate.entry != link.masterEntry || candidate.guid == spawn.guid
                        || !inLinkRange(spawn.x, spawn.y, candidate.x, candidate.y, link.range))
                        continue;
                    const distance = (spawn.x - candidate.x) ^^ 2 + (spawn.y - candidate.y) ^^ 2;
                    if (distance < nearest || (distance == nearest && candidate.guid < master))
                    {
                        master = candidate.guid;
                        nearest = distance;
                    }
                }
        }
        if (!master)
            return false;
        const bossDead = master in state.dead;
        return ((link.flags & LinkFlag.cantSpawnIfBossDead) && bossDead)
            || ((link.flags & LinkFlag.cantSpawnIfBossAlive) && !bossDead);
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
                leader.generator = new WaypointMovement(path, f.movementType == 4, f.pathId, true);
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
        if (invasionLayout !is null)
            if (const site = guid in invasionLayout.creatures)
                if (!site.present(invasion)) return false;
        if (const e = guid in data.creatureGameEvents)
            return gameEvents.spawnIn(*e);
        return true;
    }

    /// Whether game object spawn `guid` is in the world as its game event (if any) stands, or as the war
    /// effort does (its piles of supplies).
    bool gameObjectInEvents(uint guid)
    {
        import dmangos.world.wareffort : isSupplyPile;

        if (invasionLayout !is null)
            if (const site = guid in invasionLayout.objects)
                if (!site.present(invasion)) return false;
        if (isSupplyPile(guid))
            return warEffort.pileUp(guid);
        if (WorldPvp.follows(guid))
            return worldPvp.state.spawnUp(guid);
        if (const e = guid in data.gameObjectGameEvents)
            return gameEvents.spawnIn(*e);
        return true;
    }

    private bool eventActivatesObject(uint guid)
    {
        return WorldPvp.follows(guid) || (invasionLayout !is null && guid in invasionLayout.objects
            && invasionLayout.objects[guid].present(invasion));
    }

    /// Whether a spawn is up in its pool (`pool_*`): in none, or rolled.
    bool upInPool(PoolMember.Kind kind, uint guid)
    {
        if (kind == PoolMember.Kind.creature && creaturePools.manages(guid))
            return creaturePools.selected(guid);
        return data.pools is null || data.pools.spawns(kind, guid);
    }

    /**
     * A pooled spawn's respawn time is up: its pool rolls again (CMaNGOS's `UpdatePool`). True if it comes back
     * itself; otherwise the member rolled in its place comes after a respawn time of its own (`respawnIn`, given
     * the member: saved as its respawn), and this one stays away.
     */
    private bool rerolledBack(PoolMember.Kind kind, uint guid, scope void delegate(uint member) respawnIn)
    {
        if (data.pools is null || !data.pools.inPool(kind, guid))
            return true;
        const next = data.pools.reroll(kind, guid, spawnRandom);
        if (next == guid)
            return true;
        if (next)
            respawnIn(next);
        return false;
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
                    templateLetter(m.mailTemplate, m.sender, guid);
        }
    }

    /**
     * A letter of `MailTemplate.dbc` from creature `sender` to character `guid` (a `game_event_mail`'s, a
     * `mail_level_reward`'s): its template's text and the first item its loot gives.
     */
    package void templateLetter(uint mailTemplate, uint sender, uint guid)
    {
        import std.random : rndGen;
        import dmangos.world.database : MailRecord;
        import dmangos.world.inventory : Item;
        import dmangos.world.loot : Loot;
        import dmangos.world.objects : HighGuid, makeGuid;

        enum ubyte mailCreature = 3;
        MailRecord mail;
        mail.messageType = mailCreature;
        mail.sender = sender;
        mail.receiver = guid;
        mail.templateId = mailTemplate;
        if (const template_ = data.loot.mail[mailTemplate])
        {
            auto loot = new Loot(0, null);
            loot.fill(template_, data.loot, data.items, rndGen, (uint c) => true, null);
            foreach (lootItem; loot.items)
                if (auto proto = lootItem.itemId in data.items)
                {
                    auto item = new Item(nextItemGuid(), proto, playerGuid(guid));
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
                    if (!creatureInEvents(c.spawnId) || (invasionLayout !is null && c.summon.type != TempSpawnType.none
                        && !invasionLayout.actorPresent(c.template_.entry, c.spawn, invasion)))
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
                    if ((eventObject(go.spawn.guid) && !gameObjectInEvents(go.spawn.guid)) ||
                        (invasionLayout !is null && go.template_.entry == 181142 &&
                         !invasionLayout.actorPresent(16230, go.spawn, invasion)))
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
                            if (spawn.guid !in data.creatureGameEvents || !creatureInEvents(spawn.guid)
                                    || !upInPool(PoolMember.Kind.creature, spawn.guid))
                                continue;
                            if (awaitingRespawn(spawn.guid) || creatureOnLoan(spawn.guid))
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
                                || (spawn.respawnSeconds < 0 && !eventActivatesObject(spawn.guid))
                                || !upInPool(PoolMember.Kind.gameObject, spawn.guid))
                                continue;
                            auto go = makeGameObject(*spawn);
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

        return (guid in data.gameObjectGameEvents) !is null || isSupplyPile(guid) || WorldPvp.follows(guid);
    }

    import dmangos.world.scourgelayout : InvasionLayout;
    InvasionLayout invasionLayout;
    InvasionState invasion;

    private InvasionHost newInvasionHost(const(ubyte)[] moved)
    {
        import dmangos.plaindata : decode;
        import dmangos.world.scourge : invasionSaveId;
        InvasionHost host;
        if (moved.length)
            decode(moved, host.state);
        if (!host.state.campaign)
            host.restore(database.worldState(invasionSaveId));
        host.clock = () => unixTime;
        host.save = (string text) { database.saveWorldState(invasionSaveId, text); };
        host.announce = (const ref InvasionState s) { services.announce!InvasionHost(s); };
        return host;
    }

    void askInvasion()
    {
        import dmangos.world.scourge : InvasionQuery;
        services.call!(InvasionHost.current)(InvasionQuery(nodeId), (InvasionState s) { invasionHeard(s); });
    }

    void invasionHeard(const ref InvasionState state)
    {
        import dmangos.world.map : packetBody;
        import dmangos.world.packets : ServerUpdateWorldState;
        if (state.campaign < invasion.campaign ||
            (state.campaign == invasion.campaign && state.revision <= invasion.revision))
            return;
        if (state.running && invasionLayout is null) invasionLayout = new InvasionLayout(data);
        const before = invasion;
        invasion = state;
        bool changed;
        foreach (ushort id; 17 .. 100)
            if ((id == 17 || id >= 89) && gameEvents.started(id) != state.eventOn(id))
            {
                gameEvents.start(id, state.eventOn(id));
                changed = true;
            }
        if (changed)
            updateGameEvents(clock(), true);
        if (invasionLayout !is null && !changed) gameEventSpawnsChanged();
        const previous = before.worldStates();
        foreach (i, field; state.worldStates())
            if (field[1] != previous[i][1])
                foreach (player; online.values)
                    if (player.character !is null)
                        player.deliver(Opcode.SMSG_UPDATE_WORLD_STATE,
                            packetBody(ServerUpdateWorldState(field[0], field[1])));
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

    // -----------------------------------------------------------------------
    // World PvP: the Eastern Plaguelands' towers, Silithus's Silithyst (`dmangos.world.worldpvp`)
    // -----------------------------------------------------------------------

    /// World PvP as this node follows it: the state it last heard, and what it does with it.
    WorldPvpFollower worldPvp;

    /// World PvP's service, on the node the cluster places it on: from the state it moved with, or anew (it was not
    /// saved in 1.12: a restart began it again).
    private WorldPvpHost newWorldPvpHost(const(ubyte)[] moved)
    {
        import dmangos.plaindata : decode;

        WorldPvpHost host;
        if (moved.length)
            decode(moved, host.state);
        host.announce = (const ref WorldPvp w) { services.announce!WorldPvpHost(w); };
        return host;
    }

    /// The shrines world PvP brings and takes away: the spawns of loaded cells made to agree with it.
    void worldPvpSpawnsChanged()
    {
        gameEventSpawnsChanged();
    }

    /// The battleground queues, as the service on this node runs them (docs/SERVICES.md).
    package BattlegroundQueue newBattlegroundQueue()
    {
        import dmangos.cluster.ownership : IdKind;

        auto q = new BattlegroundQueue;
        foreach (type, t; data.battlegroundTemplates)
            q.templates[type] = t;
        q.clock = () => clock();
        q.newInstanceId = (out uint id) => takeId(IdKind.instance, id);
        q.deliver = &deliverQueuePacket;
        q.currentNode = &queuePlayerNode;
        return q;
    }

    package ushort queuePlayerNode(ulong guid)
    {
        if (onlinePlayer(guid) !is null)
            return nodeId;
        if (auto remote = remotePlayer(guid))
            return remote.node;
        return 0;
    }

    package void deliverQueuePacket(ulong guid, ushort node, Opcode opcode, const(ubyte)[] body_)
    {
        if (auto local = onlinePlayer(guid))
            return local.deliver(opcode, body_);
        if (deliverRemote is null) return;
        if (auto remote = remotePlayer(guid))
            node = remote.node;
        if (node && node != nodeId)
            deliverRemote(node, guid, cast(ushort) opcode, body_);
    }

    /// The battleground queue service, if it runs on this node (standalone it does).
    @property BattlegroundQueue battlegroundQueue()
    {
        if (auto host = services.local!BattlegroundQueueHost())
            return host.queue;
        return null;
    }

    /// The fencing token of a battleground map's current grant, or zero during revocation.
    ulong delegate(uint map) battlegroundMapEpoch;

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

    private struct ElevatorAnimation
    {
        uint entry;
        float[4] rotation;
        ElevatorPath path;
    }

    private ElevatorAnimation[ulong] elevatorAnimations;
    private bool[ulong][uint] longElevatorHomes;

    /// Keep routes longer than a grid cell available while this map is active.
    private bool[ulong] elevatorHomesFor(uint mapId)
    {
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.grid : cellSize;

        if (auto homes = mapId in longElevatorHomes)
            return *homes;
        bool[ulong] homes;
        foreach (cell, indices; data.gameObjectCells.get(mapId, null))
            foreach (index; indices)
            {
                const spawn = &data.gameObjectSpawns[index];
                const proto = spawn.entry in data.gameObjectTemplates;
                if (proto is null || proto.type != GameObjectType.transport || proto.data[1] || spawn.respawnSeconds < 0)
                    continue;
                const path = ElevatorPath(client.transportFrames(spawn.entry), spawn.worldRotation);
                if (path.travelsAcross(cellSize))
                {
                    homes[cell] = true;
                    break;
                }
            }
        longElevatorHomes[mapId] = homes;
        return homes;
    }

    private void refreshElevatorHomes(Map map_)
    {
        longElevatorHomes.remove(map_.id);
        map_.elevatorHomes = elevatorHomesFor(map_.id);
    }

    private ElevatorPath elevatorPathOf(ulong guid, const ref UpdateValues fields)
    {
        import dmangos.world.gameobject : GameObjectType;
        import dmangos.world.updatefields;

        if (fields.type != TypeId.gameObject || fields.get!GAMEOBJECT_TYPE_ID != GameObjectType.transport
            || fields.get!GAMEOBJECT_LEVEL != 0)
            return ElevatorPath.init;
        const entry = fields.get!OBJECT_FIELD_ENTRY;
        float[4] rotation;
        foreach (i, ref component; rotation)
            component = fields.get!GAMEOBJECT_ROTATION(i);
        auto animation = guid in elevatorAnimations;
        if (animation is null || animation.entry != entry || animation.rotation != rotation)
        {
            elevatorAnimations[guid] = ElevatorAnimation(entry, rotation, ElevatorPath(client.transportFrames(entry), rotation));
            animation = guid in elevatorAnimations;
        }
        return animation.path;
    }

    /// The current pose of a loaded elevator (local object or replica).
    package bool elevatorPose(Map map_, ulong guid, out Position at, out float maxSpeed)
    {
        import dmangos.world.updatefields;

        auto platform = map_.findObject(guid);
        if (platform is null)
            return false;
        const fields = &platform.fields();
        const path = elevatorPathOf(guid, *fields);
        if (!path.valid)
            return false;

        const stationary = Position(fields.get!GAMEOBJECT_POS_X, fields.get!GAMEOBJECT_POS_Y,
            fields.get!GAMEOBJECT_POS_Z, fields.get!GAMEOBJECT_FACING);
        at = path.positionAt(stationary, transportNow());
        maxSpeed = path.maxSpeed;
        return at.isFinite;
    }

    /**
     * Each tick: each ship is where its schedule says. One that came to another map leaves the old one (its
     * players forget it) for the new one (its players get it), and the players aboard cross with it.
     * Ships on dungeon maps are not sailed.
     */
    private void updateShips()
    {
        import dmangos.log : info;
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
        {
            const directory = buildPath(config.dataDir, "vmaps");
            vmapModels = new ModelCache(directory);
            gameObjectModels = GameObjectModels.load(directory, vmapModels);
        }
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
        if (battlegroup !is null && battlegroup.host !is this && (instance & battlegroupInstance) && battlegroundOfMap(id))
            return battlegroup.host.map(id, instance);
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
        if (const to = spell in data.spellTargets)
            if (auto c = onlinePlayer(guid))
                c.spellTeleport(to.map, to.at);
    }

    /// What `Map`'s `playerSees` needs of the world: a group, a side, the viewer's corpse.
    private VisibilityFacts visibilityFacts(Map map_, ulong viewer, ulong seen, Position seenAt)
    {
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
        // Stealth: whether the viewer detects the other (both players here; another node's are taken as seen).
        {
            auto watcher = onlinePlayer(viewer), hidden = onlinePlayer(seen);
            if (watcher !is null && hidden !is null && watcher.player !is null && hidden.player !is null)
            {
                import dmangos.world.combat : detects, maxPlayerStealthDetectRange;

                import dmangos.world.combat : seesThrough;

                const watcherFighter = watcher.player.fighter, hiddenFighter = hidden.player.fighter;
                f.detected = (!hiddenFighter.stealthed || detects(watcherFighter, hiddenFighter, maxPlayerStealthDetectRange))
                    && seesThrough(watcherFighter, hiddenFighter);
            }
        }
        if (auto local = onlinePlayer(viewer))
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
        auto mapTerrain = terrain(id);
        auto created = new Map(id, MapSettings(config.visibilityDistance, config.visibilityRelocationLimit,
            config.gridCleanUpDelay * 1000),
            &serverTime, spawner, mapTerrain, owns, gameObjectModels is null ? null :
                new GameObjectCollision(gameObjectModels, client, &transportNow));
        created.instanceId = instance;
        created.questSpawnPhases = data.questSpawnPhases;
        created.gameObjectTemplate = (uint entry) => entry in data.gameObjectTemplates;
        created.elevatorPath = &elevatorPathOf;
        created.elevatorClock = &transportNow;
        created.elevatorHomes = elevatorHomesFor(id);
        if (instance == 0) // a dungeon's copies are all on one node: nobody else needs replicas of them
            created.replicator = replicator;
        created.onCorpseRemoved = &corpseRemoved;
        created.visibilityFacts = (ulong viewer, ulong seen, Position seenAt) => visibilityFacts(created, viewer,
            seen, seenAt);
        created.onReplicaNoticing = &replicaNoticing;
        if (!instance && sendCreatureSwing !is null)
            created.remoteCreatureSwing = &queueCreatureSwing;
        if (!instance && sendCreatureLoan !is null)
            created.remoteAssistance = (Creature caller, UnitRef enemy, float radius) {
                askCreatureLoans(created, caller, enemy, radius);
            };
        created.onTrap = (Inhabitant who, GameObject trap) { trapSprung(created, who, trap); };
        created.onTimedTrap = (GameObject trap) { disturbEncounterTrap(created, trap); };
        created.onWaypointScript = (Creature creature, uint scriptId) {
            import dmangos.world.dbscripts : DbScriptType;

            startScript(DbScriptType.creatureMovement, scriptId, created, creature.guid, creature.guid);
        };
        created.onGameObjectUsedUp = &gameObjectUsedUp;
        created.onObjectGone = (MapObject object) => objectGone(created, object);
        created.onObjectArrived = (MapObject o) { // open-world round 2: a scripted game object's `Spawned`
            if (auto go = cast(GameObject) o)
                if (go.behaviour && scripts.handles!(imported!"dmangos.script.api".Spawned)(go.behaviour))
                    objectArrivals ~= GameObjectArrival(go, created);
        };
        created.onCreatureDeath = (Creature c) {
            linkedDeath(created, c); // its pack's part first, while it is still known
            c.die(created, unixTime);
            created.creatureDeaths.put(c);
            battlegroundCreatureKilled(created, c.template_.entry, 0);
        };
        created.remotePeriodicTick = (UnitRef victim, imported!"dmangos.world.auras".Aura aura, size_t effect) {
            imported!"dmangos.world.spellauras".remotePeriodicCreatureTick(this, victim, aura, effect);
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
                    script.entryKilled = &entryKilledInInstance;
                    script.respawnKilled = &respawnKilledInCopy;
                    script.signalObject = &gameObjectSignalled;
                    script.respawnObjectOf = &respawnObjectOfEntry;
                    script.summonObjectAt = &summonGameObjectAt;
                    instanceScripts[instance] = script;
                    if (!copyArriving) // a copy from another node brings its creatures: their fights go on
                        script.restored();
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

    /// Battleground objectives use the player credited with the killing blow, independently of the loot tap.
    package void battlegroundCreatureKilled(Map map, uint entry, ulong killer)
    {
        if (map.instanceId)
            if (auto copy = battlegrounds.find(map.instanceId))
                if (copy.mapId == map.id)
                    copy.rules.creatureKilled(copy, entry, killer);
    }

    /// The map `id` if it exists; null otherwise.
    Map existingMap(uint id)
    {
        return maps.get(id, null);
    }

    /// Map `id`'s instance `instance` if it exists (0: the map itself); null otherwise.
    Map existingMap(uint id, uint instance)
    {
        if (battlegroup !is null && battlegroup.host !is this && (instance & battlegroupInstance) && battlegroundOfMap(id))
            return battlegroup.host.existingMap(id, instance);
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
        bool[uint] dead;       /// creature spawns killed there
        bool[uint] usedUp;     /// game object spawns used up there
        string data;           /// its dungeon script's state (`instance.data`)
        InstanceChestRecord[uint] chests; /// scripted reward loot, by spawn
        long[uint] trashRespawns;         /// Molten Core trash deadlines, by spawn
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
    uint instanceFor(ulong player, uint mapId, scope bool delegate(uint) admit = null)
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
        const fresh = chosen == 0;
        if (fresh)
        {
            // Ids are the cluster's (each node makes the copies of its own dungeons).
            if (!takeId(IdKind.instance, chosen) || chosen == 0)
            {
                warning!"instance of map %s not made: no instance ids (the coordinator's next block has not come)"(mapId);
                return 0;
            }
        }
        if (admit !is null && !admit(chosen))
            return 0;
        if (fresh)
        {
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

    bool instanceLimitReached(uint account, uint instance)
    {
        return database.instanceLimitReached(account, instance, unixTime);
    }

    bool enteredInstance(uint account, uint instance)
    {
        return database.admitInstance(account, instance, unixTime);
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
     * `raidResetDays` days, counted on from the last, kept in `instance_reset`.
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
        const t2 = nextRaidReset(t, now, raidResetDays(mapId), config.instanceResetTimeHour);
        raidResets_[mapId] = t2;
        database.saveRaidReset(mapId, t2);
        return t2;
    }

    /**
     * How many days apart raid `mapId`'s copies reset: Blizzard's interval (`ClientData.resetIntervalDays`), else
     * (no data/instance-resets.csv) `instance_template.reset_delay`, else a week.
     */
    uint raidResetDays(uint mapId) const
    {
        bool known;
        const days = client.resetIntervalDays(mapId, known);
        return known && days ? days : data.instanceResetDays.get(mapId, 7);
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
                    {
                        state.dead[r.spawnGuid] = true;
                        if (const spawn = creatureSpawnOf(r.spawnGuid))
                            if (moltenCoreTrash(*spawn) && r.until > 0 && (!state.resetAt || r.until < state.resetAt))
                                state.trashRespawns[r.spawnGuid] = r.until;
                    }
                }
        foreach (chest; saved.chests)
            if (auto state = chest.instance in instances)
                if (which(state.mapId))
                    state.chests[chest.spawn] = chest;
    }

    /**
     * A dungeon's copies are another node's now (its region moved): what this node knew of them goes
     * from memory (not from the database, which the new host reads). A copy with players in it stays
     * until they have moved on (`unloadEmptyInstances`).
     */
    private void dungeonLost(uint mapId)
    {
        if (battlegroundOfMap(mapId))
            battlegrounds.forgetMap(mapId);
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

    /// The copies of dungeon `mapId` and their pending database actions for the next owner.
    private const(ubyte)[] dungeonCopiesOut(uint mapId, ushort next)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.log : info;
        import dmangos.world.battlegroundstate : BattlegroundState;
        import dmangos.world.migration : encodeBundle;
        import std.algorithm.searching : canFind;

        ByteWriter w;
        ByteWriter deadlines;
        saveDungeonObjectDeadlines(mapId, deadlines); // before migrateOut removes the local objects and their timers
        uint[] ids;
        foreach (id, m; instanceMaps)
            if (instances.get(id, InstanceState.init).mapId == mapId && m.instanceId == id)
                ids ~= id;
        const bg = battlegroundOfMap(mapId);
        if (bg)
            foreach (copy; battlegrounds.all)
                if (copy.mapId == mapId && !ids.canFind(copy.instance))
                    ids ~= copy.instance; // its first player may still be acknowledging the world port
        w.put(cast(uint) ids.length);
        foreach (id; ids)
        {
            auto m = instanceMaps.get(id, null);
            const before = m is null ? 0 : m.objectCount - m.replicaCount;
            const bundle = m is null ? encodeBundle(null, null) : m.migrateOut((ulong) => true, next, &saveMigrant);
            w.put(id);
            w.put(cast(uint) bundle.length);
            w.putBytes(bundle);
            if (bg)
            {
                ByteWriter match;
                if (auto copy = battlegrounds.find(id))
                {
                    auto state = BattlegroundState(clock(), writer: &match);
                    copy.transferState(state);
                    auto stored = instances.get(id, InstanceState.init);
                    state.transfer(stored.dead, stored.usedUp);
                }
                w.put(cast(uint) match.data.length);
                w.putBytes(match.data);
            }
            info!"migration: instance %s of map %s leaves for node %s with %s objects"(id, mapId, next,
                m is null ? 0 : before - (m.objectCount - m.replicaCount));
        }
        saveDungeonScriptRuns(mapId, w, true);
        w.putBytes(deadlines.data);
        return w.data;
    }

    /// A copy being made for `dungeonCopiesIn` (its script's `Restored` is not raised: its creatures come along).
    private bool copyArriving;

    /// The same object and match data used for a clean handoff, captured without releasing the live map.
    package const(ubyte)[] snapshotBattleground(imported!"dmangos.world.battleground".Battleground copy)
    {
        import dmangos.world.battlegroundstate : BattlegroundState;
        import dmangos.world.migration : encodeBundle;

        auto m = existingMap(copy.mapId, copy.instance);
        const bundle = m is null ? encodeBundle(null, null) : m.snapshotObjects((MapObject object) {
            if (auto creature = cast(Creature) object)
                if (creature.meleeController || creature.totemOwner || creature.guardianOwner)
                    return Migrant.init;
            return saveMigratingObject(object, false);
        });
        ByteWriter w, match;
        auto state = BattlegroundState(clock(), writer: &match);
        copy.transferState(state, durableSnapshot: true);
        w.put(cast(uint) match.length);
        w.putBytes(match.data);
        w.put(cast(uint) bundle.length);
        w.putBytes(bundle);
        auto stored = instances.get(copy.instance, InstanceState.init);
        state.writer = &w;
        state.transfer(stored.dead, stored.usedUp);
        saveDungeonScriptRuns(copy.mapId, w, false, copy.instance);
        saveDungeonObjectDeadlines(copy.mapId, w, copy.instance);
        return w.data;
    }

    package void restoreBattleground(uint mapId, uint id, const(ubyte)[] bytes, uint formatVersion = 3)
    {
        import dmangos.world.battlegroundstate : BattlegroundState;

        auto r = ByteReader(bytes);
        auto match = ByteReader(r.readBytes(r.read!uint));
        const bundle = r.readBytes(r.read!uint);
        auto stored = InstanceState(mapId, 0, unixTime);
        auto state = BattlegroundState(clock(), reader: &r);
        state.transfer(stored.dead, stored.usedUp);
        auto copy = battlegrounds.restore(id, battlegroundOfMap(mapId), match, formatVersion);
        instances[id] = stored;
        restoreDungeonCopy(mapId, id, bundle);
        restoreDungeonScriptRuns(mapId, r);
        restoreDungeonObjectDeadlines(mapId, r);
        copy.recoveredAfterCrash();
    }

    /// What `dungeonCopiesOut` sent: each copy made here and its objects as they were.
    private void dungeonCopiesIn(uint mapId, const(ubyte)[] copies)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : info;
        import dmangos.world.battlegroundstate : BattlegroundState;

        if (copies.length < 4)
            return;
        auto r = ByteReader(copies);
        const bg = battlegroundOfMap(mapId);
        foreach (_; 0 .. r.read!uint)
        {
            const id = r.read!uint;
            const bundle = r.readBytes(r.read!uint);
            if (bg)
            {
                const match = r.readBytes(r.read!uint);
                if (!match.length)
                    continue;
                auto reader = ByteReader(match);
                battlegrounds.restore(id, bg, reader);
                auto stored = InstanceState(mapId, 0, unixTime);
                auto state = BattlegroundState(clock(), reader: &reader);
                state.transfer(stored.dead, stored.usedUp);
                instances[id] = stored;
            }
            if (id !in instances)
                continue; // reset meanwhile
            info!"migration: instance %s of map %s arrived with %s objects"(id, mapId,
                restoreDungeonCopy(mapId, id, bundle));
        }
        if (!r.empty) // older owners sent only the copy/object pairs
        {
            restoreDungeonScriptRuns(mapId, r);
            restoreDungeonObjectDeadlines(mapId, r);
        }
    }

    private size_t restoreDungeonCopy(uint mapId, uint id, const(ubyte)[] bundle)
    {
        import dmangos.world.gameobject : GameObject;

        Map m;
        {
            copyArriving = true;
            scope (exit) copyArriving = false;
            m = map(mapId, id);
        }
        const before = m.objectCount - m.replicaCount;
        m.migrateIn(bundle, (const ref Migrant migrant) {
            auto object = restoreWorldMigrant(migrant, m);
            if (auto creature = cast(Creature) object)
                creature.instanceId = id;
            else if (auto go = cast(GameObject) object)
                go.instanceId = id;
            return object;
        });
        return m.objectCount - m.replicaCount - before;
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

    private bool entryKilledInInstance(uint instance, uint entry)
    {
        if (auto state = instance in instances)
            foreach (guid; state.dead.byKey)
                if (const idx = guid in spawnIndex)
                    if (data.creatureSpawns[*idx].entry == entry)
                        return true;
        return false;
    }

    private void respawnKilledInCopy(Map map, uint entry)
    {
        if (auto state = map.instanceId in instances)
            foreach (guid; state.dead.keys)
                if (const idx = guid in spawnIndex)
                {
                    const spawn = &data.creatureSpawns[*idx];
                    if (spawn.entry == entry)
                        respawnInCopy(map, spawn, cast(Creature) map.findObject(makeGuid(HighGuid.unit, entry, guid)));
                }
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
                if (!creatureInEvents(data.creatureSpawns[index].guid)
                        || !upInPool(PoolMember.Kind.creature, data.creatureSpawns[index].guid))
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
                const reward = state is null ? null : spawn.guid in state.chests;
                if ((spawn.respawnSeconds < 0 && reward is null) || (state !is null && spawn.guid in state.usedUp)
                    || !gameObjectInEvents(spawn.guid))
                    continue;
                const available = copy !is null && spawn.battlegroundPowerUp ? copy.powerUpAvailable(spawn.guid)
                    : upInPool(PoolMember.Kind.gameObject, spawn.guid);
                if (!available)
                    continue;
                const event = spawn.guid in data.gameObjectBattleEvents;
                if (copy !is null && !copy.spawnAllowed(event))
                    continue;
                auto go = makeGameObject(*spawn);
                go.instanceId = instance;
                if (reward !is null && !restoreReward(go, *reward))
                {
                    scripts.destroy(go.behaviour);
                    continue;
                }
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
            m.forEachObject((MapObject o) => objectGone(m, o));
        instanceMaps.remove(id);
        if (auto script = id in instanceScripts)
        {
            script.release();
            instanceScripts.remove(id);
        }
    }

    /// An object left its map for good (`Map.onObjectGone`): its script's state goes.
    private void objectGone(Map map, MapObject object)
    {
        if (auto creature = cast(Creature) object)
            creature.ai.releaseBehaviour();
        else if (auto go = cast(GameObject) object)
        {
            auto key = GameObjectOnMap(map, go.guid);
            tickingObjects.remove(key);
            scriptedGameObjects.remove(key);
            scripts.destroy(go.behaviour);
        }
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
        info!"scripts: %s spells served by id (what CMaNGOS's core scripts by id)"(scripts.spellsServedById.length);
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
        import dmangos.world.migration : encodeBundle;
        import std.format : format;

        // Load additions before restoring live bundles or loading newly owned cells.
        discoverSavedSpawns(gained);

        // Retire a returned creature before handing over any newly revoked physical home region.
        foreach (ref r; lost)
            if (r.creature.spawn)
                creatureLoanLost(r);

        foreach (ref r; lost)
            if (instanceable(r.map) || physicalWorldRegion(r))
                releaseRegionCharms(r);

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
                if (battlegroundOfMap(r.map) && battlegroundMapEpoch !is null
                    && (battlegroup is null || battlegroup.host is this))
                    battlegrounds.recoverMap(r.map, (r.id in arriving) !is null);
            }
        foreach (ref r; lost)
            if (physicalWorldRegion(r))
            {
                auto timers = takeRegionRespawns(r);
                if (auto m = r.map in maps)
                {
                    timers ~= takeRegionScriptRuns(*m, r);
                    if (r.next) // moving to another node: its objects and timers go along
                    {
                        const before = m.objectCount - m.replicaCount;
                        leaving[r.id] = cast(ubyte[]) m.migrateOut((ulong cell) => r.rect.containsKey(cell), r.next,
                            &saveMigrant, timers);
                        info!"migration: region %s leaves for node %s with %s objects (%s KiB)"(r.id, r.next,
                            before - (m.objectCount - m.replicaCount), leaving[r.id].length / 1024);
                    }
                    else
                        m.release((ulong cell) => r.rect.containsKey(cell));
                }
                else if (r.next)
                    leaving[r.id] = cast(ubyte[]) encodeBundle(null, timers);
            }
        const editedSpawns = refreshSavedGameObjectPlacements(gained, arriving);
        refreshRegionRespawns(gained, arriving);
        // Every arrival first: a map that looks around for gained cells would otherwise spawn afresh what is
        // still on its way in another region's bundle.
        foreach (ref r; gained)
            if (auto objects = r.id in arriving)
            {
                if (!physicalWorldRegion(r))
                    continue; // its copies' bundles, read above
                auto m = map(r.map);
                const before = m.objectCount - m.replicaCount;
                m.migrateIn(*objects, (const ref Migrant migrant) => restoreRegionMigrant(migrant, m, r));
                info!"migration: region %s arrived with %s objects"(r.id, m.objectCount - m.replicaCount - before);
            }
        foreach (index; editedSpawns)
        {
            const spawn = &data.gameObjectSpawns[index];
            if (auto m = existingMap(spawn.map))
            {
                const guid = makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
                if (auto live = m.gameObjectAt(guid))
                {
                    if (live.spawn == *spawn)
                        continue; // a clean bundle in the same batch already restored it
                    m.removeObject(guid);
                }
                const home = cellKeyAt(spawn.x, spawn.y);
                if (m.cellLoaded(home) && (ownsCell is null || ownsCell(spawn.map, home)))
                    if (auto object = spawnWorldGameObject(*spawn))
                        m.addObject(object);
            }
        }
        foreach (ref r; gained)
            if (r.creature.spawn)
                creatureLoanGained(r, arriving.get(r.id, null));
        bool[uint] looked;
        foreach (ref r; gained)
            if (r.map !in looked)
            {
                looked[r.map] = true;
                if (auto m = r.map in maps)
                    m.ownershipGained();
            }
    }

    private bool physicalWorldRegion(const ref Region region)
    {
        return !region.creature.spawn && client.maps.lookup(region.map) !is null && !instanceable(region.map);
    }

    private void releaseRegionCharms(const ref Region region)
    {
        import dmangos.world.objects : highGuidOf;

        const wholeMap = instanceable(region.map);
        foreach (who; online.values)
            if (auto controller = cast(Character) who)
                if (auto creature = controller.charmed)
                    if (highGuidOf(creature.guid) == HighGuid.unit && creature.spawn.map == region.map
                        && (wholeMap || region.rect.containsKey(cellKeyAt(creature.spawn.x, creature.spawn.y))))
                        controller.releaseCharmForHandoff();
    }

    /// With no live bundle, refresh previously known placements before loading the gained cells.
    private size_t[] refreshSavedGameObjectPlacements(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        import std.algorithm.searching : any;
        import dmangos.cluster.regions : CellRect;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        CellRect[][uint] coldCells;
        foreach (ref region; gained)
            if (physicalWorldRegion(region) && !arriving.get(region.id, null).length)
                coldCells.require(region.map, null) ~= region.rect;
        if (!coldCells.length)
            return null;

        indexSpawns();
        size_t[] edited;
        foreach (mapId, cells; coldCells)
        {
            bool contains(float x, float y)
            {
                const key = cellKeyAt(x, y);
                return cells.any!(cell => cell.containsKey(key));
            }
            bool movedElevator;
            try
            {
                foreach (saved; database.savedGameObjectSpawnsOnMap(mapId))
                {
                    const index = saved.guid in gameObjectSpawnIndex;
                    if (index is null || saved.guid >= temporaryCounterStart
                        || !client.isValidMapCoord(mapId, saved.x, saved.y, saved.z, saved.orientation))
                        continue;
                    const old = data.gameObjectSpawns[*index];
                    if (old.map != mapId)
                        continue;
                    // Only the saved transform changes. A spawn group can supply the entry.
                    saved.entry = old.entry;
                    saved.respawnSeconds = old.respawnSeconds;
                    if (saved == old || (!contains(old.x, old.y) && !contains(saved.x, saved.y)))
                        continue;
                    replaceGameObjectSpawn(*index, saved);
                    edited ~= *index;
                    if (const template_ = old.entry in data.gameObjectTemplates)
                        movedElevator |= template_.type == GameObjectType.transport;
                }
            }
            catch (DatabaseException error)
                warning!"migration: could not refresh saved game-object placements on map %s: %s"(mapId, error.msg);
            if (movedElevator)
            {
                longElevatorHomes.remove(mapId);
                if (auto m = existingMap(mapId))
                    m.elevatorHomes = elevatorHomesFor(mapId);
            }
        }
        return edited;
    }

    private bool timerHome(Spawn)(const ref Region region, uint guid, const(Spawn)[] spawns, const(size_t[uint]) index,
        out ulong cell)
    {
        if (const slot = guid in index)
        {
            const spawn = &spawns[*slot];
            cell = cellKeyAt(spawn.x, spawn.y);
            return region.map == spawn.map && region.rect.containsKey(cell);
        }
        return false;
    }

    /// Timed-out-of-world spawns move with their home cells even when there is no live object.
    private Migrant[] takeRegionRespawns(const ref Region region)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.migration : MigrantKind;

        indexSpawns();
        Migrant[] timers;
        void take(Spawn)(ref long[uint] cached, const(Spawn)[] spawns, const(size_t[uint]) index, MigrantKind kind)
        {
            foreach (guid; cached.keys)
            {
                ulong home;
                if (!timerHome(region, guid, spawns, index, home))
                    continue;
                if (region.next)
                {
                    ByteWriter state;
                    state.put(cached[guid]);
                    timers ~= Migrant(kind, guid, home, state.data);
                }
                cached.remove(guid);
            }
        }
        take(respawnAt, data.creatureSpawns, spawnIndex, MigrantKind.creatureRespawn);
        take(gameObjectRespawnAt, data.gameObjectSpawns, gameObjectSpawnIndex, MigrantKind.gameObjectRespawn);
        return timers;
    }

    /// A clean handoff supplies its timers in the bundle. A crash only leaves the database rows.
    private void refreshRegionRespawns(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!gained.length)
            return;
        creaturePools.refresh();
        const(Region)[] cold;
        foreach (ref region; gained)
        {
            if (!physicalWorldRegion(region))
                continue;
            if (arriving.get(region.id, null).length)
                takeRegionRespawns(region); // discard any cached timers from an earlier ownership
            else
                cold ~= region;
        }
        if (!cold.length)
            return;
        indexSpawns();
        void sync(Spawn)(ref long[uint] cached, const(long[uint]) saved, const(Spawn)[] spawns,
            const(size_t[uint]) index)
        {
            import std.algorithm.searching : any;

            bool here(uint guid)
            {
                static if (is(Spawn == CreatureSpawn))
                    if (creaturePools.manages(guid))
                        return false; // the durable pool row owns this deadline
                ulong home;
                return cold.any!(region => timerHome(region, guid, spawns, index, home));
            }
            foreach (guid; cached.keys)
                if (guid !in saved && here(guid))
                    cached.remove(guid);
            foreach (guid, at; saved)
                if (here(guid))
                    cached[guid] = at;
        }
        try
        {
            sync(respawnAt, database.loadCreatureRespawns(), data.creatureSpawns, spawnIndex);
            sync(gameObjectRespawnAt, database.loadGameObjectRespawns(), data.gameObjectSpawns, gameObjectSpawnIndex);
        }
        catch (DatabaseException error)
        {
            warning!"migration: could not refresh respawn timers: %s"(error.msg);
        }
    }

    private MapObject restoreRegionMigrant(const ref Migrant migrant, Map destination, const ref Region region)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.migration : MigrantKind;

        if (migrant.kind == MigrantKind.scriptRun)
        {
            if (region.rect.containsKey(migrant.home))
                restoreRegionScriptRun(destination.id, migrant);
            return null;
        }
        const creature = migrant.kind == MigrantKind.creatureRespawn;
        if (migrant.kind == MigrantKind.summonedCreature && !region.rect.containsKey(migrant.home))
            return null;
        if (!creature && migrant.kind != MigrantKind.gameObjectRespawn)
            return restoreWorldMigrant(migrant, destination);
        ulong home;
        const inside = creature ? timerHome(region, migrant.spawn, data.creatureSpawns, spawnIndex, home)
            : timerHome(region, migrant.spawn, data.gameObjectSpawns, gameObjectSpawnIndex, home);
        if (!inside || home != migrant.home)
            return null;
        auto state = ByteReader(migrant.state);
        const at = state.read!long;
        if (at > 0)
        {
            if (creature && !creaturePools.manages(migrant.spawn))
                respawnAt[migrant.spawn] = at;
            else if (!creature)
                gameObjectRespawnAt[migrant.spawn] = at;
        }
        return null;
    }

    /// `IdCounters.take`: a block of ids for a cluster member, from this server's counters.
    uint take(IdKind kind, uint count)
    {
        uint takeFrom(ref uint counter)
        {
            const first = counter;
            counter += count;
            return first;
        }
        return takeFrom(counterOf(kind));
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
        import std.algorithm.comparison : max;

        counterOf(kind) = max(counterOf(kind), atLeast);
    }

    private ref uint counterOf(IdKind kind) return
    {
        final switch (kind)
        {
        case IdKind.character: return next.character;
        case IdKind.item: return next.item;
        case IdKind.mail: return next.mail;
        case IdKind.group: return groups.nextId; // the groups keep their own counter
        case IdKind.instance: return next.instance;
        case IdKind.pet: return next.pet;
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
                if (awaitingRespawn(data.creatureSpawns[index].guid) || creatureOnLoan(data.creatureSpawns[index].guid))
                    continue; // dead: it comes back when its time is up
                if (!creatureInEvents(data.creatureSpawns[index].guid))
                    continue; // its game event says it is away
                if (!upInPool(PoolMember.Kind.creature, data.creatureSpawns[index].guid))
                    continue; // another of its pool is up
                if (auto creature = makeCreature(&data.creatureSpawns[index]))
                {
                    spawned ~= creature;
                    queueLinked(mapId, 0, creature);
                }
            }
        if (auto cells = mapId in data.gameObjectCells)
            foreach (index; (*cells).get(cell, null))
                if (auto object = spawnWorldGameObject(data.gameObjectSpawns[index]))
                    spawned ~= object;
        return spawned;
    }

    private GameObject spawnWorldGameObject(const ref GameObjectSpawn spawn)
    {
        // Negative respawn times reserve the spawn for an event, a script or world PvP.
        if ((spawn.respawnSeconds < 0 && !eventActivatesObject(spawn.guid)) || gameObjectAwaitingRespawn(spawn.guid)
            || !gameObjectInEvents(spawn.guid) || !upInPool(PoolMember.Kind.gameObject, spawn.guid))
            return null;
        return makeGameObject(spawn);
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
        if (creature.canSwim && !petNumber)
            if (auto ground = terrain(spawn.map))
            {
                import dmangos.vmap.math : Vector3;
                import dmangos.world.terrain : LiquidData;

                LiquidData liquid;
                if (ground.swimmingVolume(Vector3(spawn.x, spawn.y, spawn.z), creature.collisionHeight, liquid))
                {
                    creature.setSwimming(true);
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

    /// `creature` at `level`: its health, mana, armor and damage the class stats' for it (`InitStatsForLevel`).
    void setCreatureLevel(Creature creature, uint level)
    {
        import dmangos.world.updatefields : UNIT_FIELD_DISPLAYID, UNIT_FIELD_LEVEL;

        const t = creature.template_;
        const display = creature.values.get!UNIT_FIELD_DISPLAYID;
        creature.values.set!UNIT_FIELD_LEVEL(level);
        auto parts = creatureParts(*t, creature.spawn.guid, display, level, t.equipmentTemplateId);
        creature.changeEntry(t, display, parts, client);
        creature.values.set!(dmangos.world.updatefields.UNIT_FIELD_HEALTH)(
            creature.values.get!(dmangos.world.updatefields.UNIT_FIELD_MAXHEALTH));
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
        if (auto creature = cast(Creature) object)
            if (creature.meleeController || creature.totemOwner)
                return Migrant.init; // controlled creatures follow their owner's rules
        return saveMigratingObject(object);
    }

    package Migrant savePlayerSummon(Creature creature)
    {
        if (!(creature.guardianOwner || creature.totemOwner) || creature.summon.type == TempSpawnType.none
            || creature.spawn.guid < temporaryCounterStart)
            return Migrant.init;
        auto migrant = saveMigratingObject(creature);
        migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        return migrant;
    }

    private Migrant saveMigratingObject(MapObject object, bool departing = true)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.serialization : serialize;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : MigrantKind;

        ByteWriter w;
        if (auto creature = cast(Creature) object)
        {
            if (departing && creature.loot !is null)
                creature.loot.sendReleaseForAll();
            const now = transportNow();
            auto kind = MigrantKind.creature;
            if (creature.spawn.guid >= temporaryCounterStart && creature.summon.type != TempSpawnType.none)
            {
                kind = MigrantKind.summonedCreature;
                serialize(w, creature.spawn);
                serialize(w, creature.summon);
                w.put(now);
            }
            ByteWriter state;
            creature.saveState(state, now);
            w.put(cast(uint) state.data.length);
            w.putBytes(state.data);
            writeReplicaImpacts(creature.guid, w, departing);
            if (departing)
                creature.ai.detachGroundHandoff();
            return Migrant(kind, creature.spawn.guid, 0, w.data);
        }
        auto gameObject = cast(GameObject) object;
        if (gameObject is null)
            return Migrant.init;
        if (gameObject.owner && (gameObject.type == GameObjectType.fishingNode
            || gameObject.type == GameObjectType.summoningRitual))
            return Migrant.init; // follows its player's handoff
        if (departing && gameObject.loot !is null)
            gameObject.loot.sendReleaseForAll();
        long expires;
        if (!gameObject.instanceId)
            if (auto active = existingMap(gameObject.spawn.map))
                expires = scriptedGameObjects.get(GameObjectOnMap(active, gameObject.guid), 0L);
        auto kind = MigrantKind.gameObject;
        if ((gameObject.instanceId || expires) && !gameObject.owner && gameObject.spawn.guid >= temporaryCounterStart)
        {
            kind = MigrantKind.summonedGameObject;
            serialize(w, gameObject.spawn);
        }
        gameObject.saveState(w, transportNow(), expires);
        return Migrant(kind, gameObject.spawn.guid, 0, w.data);
    }

    package Creature restorePlayerSummon(Map destination, const ref Migrant migrant, ulong owner)
    {
        import dmangos.serialization : deserialize;
        import dmangos.world.migration : MigrantKind;

        if (migrant.kind != MigrantKind.summonedCreature)
            return null;
        auto reader = ByteReader(migrant.state);
        deserialize!CreatureSpawn(reader);
        if (deserialize!TempSpawn(reader).summoner != owner)
            return null;
        return cast(Creature) restoreWorldMigrant(migrant, destination);
    }

    /// An object rebuilt from its spawn and the state its last owner sent; null if the spawn is unknown here.
    MapObject restoreMigrant(const ref Migrant m)
    {
        return restoreMigrantInInstance(m, 0);
    }

    private MapObject restoreMigrantInInstance(const ref Migrant m, uint instance)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : warning;
        import dmangos.world.gameobject : GameObject;
        import dmangos.world.migration : MigrantKind;

        indexSpawns();
        auto r = ByteReader(m.state);
        if (m.kind == MigrantKind.creature)
        {
            const at = m.spawn in spawnIndex;
            if (at is null)
                return null;
            auto creature = makeCreature(&data.creatureSpawns[*at]);
            if (creature is null)
                return null;
            loadMigrantCreature(creature, instance, transportNow(), r);
            return creature;
        }
        const at = m.spawn in gameObjectSpawnIndex;
        if (at is null)
        {
            warning!"migration: game object spawn %s is not known here"(m.spawn);
            return null;
        }
        auto gameObject = makeGameObject(data.gameObjectSpawns[*at]);
        gameObject.loadState(r, transportNow());
        return gameObject;
    }

    private void loadMigrantCreature(Creature creature, uint instance, uint now, ref ByteReader reader)
    {
        auto state = ByteReader(reader.readBytes(reader.read!uint));
        creature.instanceId = instance;
        creature.loadState(state, now, &spellInfo, data.waypoints);
        readReplicaImpacts(creature.guid, creature.spawn.map, instance, reader);
    }

    /// A region may bring a saved GM spawn created after this node loaded its world data.
    private MapObject restoreWorldMigrant(const ref Migrant migrant, Map destination)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.serialization : deserialize;
        import dmangos.world.migration : MigrantKind;
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

        indexSpawns();
        const durable = migrant.spawn < temporaryCounterStart;
        bool atHome(uint mapId, float x, float y, float z)
        {
            return mapId == destination.id && client.isValidMapCoord(mapId, x, y, z) && cellKeyAt(x, y) == migrant.home;
        }
        if (migrant.kind == MigrantKind.summonedGameObject)
        {
            auto state = ByteReader(migrant.state);
            const spawn = deserialize!GameObjectSpawn(state);
            const template_ = spawn.entry in data.gameObjectTemplates;
            if (durable || migrant.spawn > 0xFF_FFFF || spawn.guid != migrant.spawn
                || template_ is null || template_.type == GameObjectType.moTransport
                || !atHome(spawn.map, spawn.x, spawn.y, spawn.z)
                || !client.isValidMapCoord(spawn.map, spawn.x, spawn.y, spawn.z, spawn.orientation))
                return null;
            auto restored = makeGameObject(spawn);
            restored.instanceId = destination.instanceId;
            restored.loadState(state, transportNow());
            if (!registerMigratedExpiry(restored, destination, !destination.instanceId))
                return null;
            bindMigrantLoot(restored, destination);
            return restored;
        }
        if (migrant.kind == MigrantKind.summonedCreature)
        {
            auto state = ByteReader(migrant.state);
            const spawn = deserialize!CreatureSpawn(state);
            const summon = deserialize!TempSpawn(state);
            const now = transportNow();
            const transit = cast(int)(now - state.read!uint);
            if (durable || migrant.spawn > 0xFF_FFFF || spawn.guid != migrant.spawn
                || spawn.entry !in data.creatureTemplates || summon.type > TempSpawnType.timedOutOfCombatOrCorpse
                || !atHome(spawn.map, spawn.x, spawn.y, spawn.z)
                || !client.isValidMapCoord(spawn.map, spawn.x, spawn.y, spawn.z, spawn.orientation))
                return null;
            auto restored = makeCreature(&spawn);
            if (restored is null)
                return null;
            restored.summon = summon;
            loadMigrantCreature(restored, destination.instanceId, now, state);
            restored.factionTemplate = client.factionTemplates.lookup(restored.values.get!UNIT_FIELD_FACTIONTEMPLATE);
            if (transit > 0)
                restored.summon.update(restored, transit);
            bindMigrantLoot(restored, destination);
            return restored;
        }
        try
        {
            if (durable && migrant.kind == MigrantKind.creature && migrant.spawn !in spawnIndex)
            {
                const saved = database.savedCreatureSpawn(migrant.spawn);
                if (saved.isNull || saved.get.entry !in data.creatureTemplates
                    || !atHome(saved.get.map, saved.get.x, saved.get.y, saved.get.z))
                    return null;
                registerCreatureSpawn(saved.get);
            }
            else if (durable && migrant.kind == MigrantKind.gameObject && migrant.spawn !in gameObjectSpawnIndex)
            {
                const saved = database.savedGameObjectSpawn(migrant.spawn);
                if (saved.isNull || !atHome(saved.get.map, saved.get.x, saved.get.y, saved.get.z))
                    return null;
                const template_ = saved.get.entry in data.gameObjectTemplates;
                if (template_ is null || template_.type == GameObjectType.moTransport)
                    return null;
                registerGameObjectSpawn(saved.get);
                if (template_.type == GameObjectType.transport)
                    refreshElevatorHomes(destination);
            }
        }
        catch (DatabaseException error)
        {
            warning!"migration: could not load the saved spawn %s: %s"(migrant.spawn, error.msg);
            return null;
        }
        if (durable && migrant.kind == MigrantKind.gameObject)
            if (const index = migrant.spawn in gameObjectSpawnIndex)
            {
                const previous = &data.gameObjectSpawns[*index];
                const placement = GameObject.migrantPlacement(*previous, migrant.state);
                if (!atHome(placement.map, placement.x, placement.y, placement.z)
                    || !client.isValidMapCoord(placement.map, placement.x, placement.y, placement.z, placement.orientation))
                    return null;
                if (placement != *previous)
                {
                    replaceGameObjectSpawn(*index, placement);
                    if (const template_ = placement.entry in data.gameObjectTemplates)
                        if (template_.type == GameObjectType.transport)
                            refreshElevatorHomes(destination);
                }
            }
        auto restored = restoreMigrantInInstance(migrant, destination.instanceId);
        if (auto go = cast(GameObject) restored)
        {
            go.instanceId = destination.instanceId;
            if (!registerMigratedExpiry(go, destination, false))
                return null;
        }
        bindMigrantLoot(restored, destination);
        return restored;
    }

    private bool registerMigratedExpiry(GameObject go, Map destination, bool requiresExpiry)
    {
        const at = go.carriedExpiry;
        if (at > unixTime)
        {
            scriptedGameObjects[GameObjectOnMap(destination, go.guid)] = at;
            return true;
        }
        if (!at && !requiresExpiry)
            return true;
        scripts.destroy(go.behaviour);
        return false;
    }

    private void bindMigrantLoot(MapObject restored, Map destination)
    {
        import dmangos.world.gameobjecthandlers : bindChestLoot;
        import dmangos.world.loothandlers : bindCreatureLoot, bindLootDelivery;
        import dmangos.world.loot : Loot, LootRule;

        Loot loot;
        if (auto chest = cast(GameObject) restored)
        {
            if ((loot = chest.loot) !is null)
                bindChestLoot(this, destination, chest, loot);
        }
        else if (auto creature = cast(Creature) restored)
        {
            if ((loot = creature.loot) !is null)
                bindCreatureLoot(this, destination, creature, loot);
        }
        if (loot !is null)
        {
            if (loot.rule != LootRule.notGroup)
                bindLootDelivery(this, destination, loot,
                    loot.rule == LootRule.groupLoot || loot.rule == LootRule.needBeforeGreed, loot.rule == LootRule.masterLoot);
            loot.resumeQuestLootChecks(destination.id, sendQuestLootCheck);
        }
    }

    private size_t[uint] spawnIndex, gameObjectSpawnIndex; // spawn guid -> its place in the world data
    private size_t indexedCreatureSpawns, indexedGameObjectSpawns;
    private uint initialCreatureSpawn, initialGameObjectSpawn;

    /// Saved GM additions can predate a takeover without appearing in the old owner's bundle.
    private void discoverSavedSpawns(const(Region)[] gained)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import std.algorithm.iteration : filter;
        import std.algorithm.searching : any;

        auto world = gained.filter!(r => !r.creature.spawn && client.maps.lookup(r.map) !is null);
        if (world.empty)
            return;
        indexSpawns();
        bool gainedHome(uint mapId, float x, float y, float z, float facing)
        {
            if (!client.isValidMapCoord(mapId, x, y, z, facing))
                return false;
            const key = cellKeyAt(x, y);
            return world.any!(r => r.map == mapId && r.rect.containsKey(key));
        }
        try
        {
            // Keep the snapshot bounds fixed. Concurrent inserts can become visible out of ID order.
            foreach (ref saved; database.savedCreatureSpawnsAfter(initialCreatureSpawn))
                if (saved.guid < temporaryCounterStart && saved.guid !in spawnIndex && saved.entry in data.creatureTemplates
                    && gainedHome(saved.map, saved.x, saved.y, saved.z, saved.orientation))
                    registerCreatureSpawn(saved);
            foreach (ref saved; database.savedGameObjectSpawnsAfter(initialGameObjectSpawn))
            {
                if (saved.guid >= temporaryCounterStart || saved.guid in gameObjectSpawnIndex
                    || !gainedHome(saved.map, saved.x, saved.y, saved.z, saved.orientation))
                    continue;
                const template_ = saved.entry in data.gameObjectTemplates;
                if (template_ is null || template_.type == GameObjectType.moTransport)
                    continue;
                registerGameObjectSpawn(saved);
                if (template_.type == GameObjectType.transport)
                {
                    longElevatorHomes.remove(saved.map);
                    if (auto map_ = saved.map in maps)
                        (*map_).elevatorHomes = elevatorHomesFor(saved.map);
                }
            }
        }
        catch (DatabaseException error)
            warning!"could not discover newly saved spawns for gained regions: %s"(error.msg);
    }

    private void indexSpawns()
    {
        foreach (i; indexedCreatureSpawns .. data.creatureSpawns.length)
            spawnIndex[data.creatureSpawns[i].guid] = i;
        foreach (i; indexedGameObjectSpawns .. data.gameObjectSpawns.length)
            gameObjectSpawnIndex[data.gameObjectSpawns[i].guid] = i;
        indexedCreatureSpawns = data.creatureSpawns.length;
        indexedGameObjectSpawns = data.gameObjectSpawns.length;
    }

    package const(GameObjectSpawn)* gameObjectSpawnOf(uint guid)
    {
        indexSpawns();
        if (const index = guid in gameObjectSpawnIndex)
            return &data.gameObjectSpawns[*index];
        return null;
    }

    /// The coordinator owns the loan lifecycle. A table entry reserves its spawn on every node.
    void delegate(CreatureLoan) sendCreatureLoan;
    Region delegate(uint) creatureLease;
    private Region[uint] localCreatureLoans;
    private MonoTime nextCreatureLoanCheck;

    private bool creatureOnLoan(uint spawn)
    {
        return creatureLease !is null && creatureLease(spawn).creature.spawn != 0;
    }

    private const(CreatureSpawn)* loanSpawn(uint spawn, uint mapId)
    {
        indexSpawns();
        if (const at = spawn in spawnIndex)
            if (data.creatureSpawns[*at].map == mapId)
                return &data.creatureSpawns[*at];
        return null;
    }

    private void askCreatureLoans(Map map_, Creature caller, UnitRef enemy, float radius)
    {
        import dmangos.world.grid : cellKeyAt;
        import dmangos.world.defines : UnitFlags;
        import dmangos.world.objects : counterOf;
        import dmangos.world.relations : reactionTo, Relating, ReputationRank;
        import dmangos.world.updatefields;

        foreach (replica; map_.creatureReplicasNear(caller.position, radius))
        {
            const spawn = counterOf(replica.guid);
            // Event spawns can disappear or change their template and GUID during the loan.
            if (creatureLease(spawn).creature.spawn || replica.owner == nodeId
                || spawn in data.creatureGameEvents || spawn in data.eventCreatures)
                continue;
            const values = &replica.fields();
            const flags = values.get!UNIT_FIELD_FLAGS;
            if (!values.get!UNIT_FIELD_HEALTH || flags & (UnitFlags.inCombat | UnitFlags.spawning | UnitFlags.uninteractible))
                continue;
            const faction = client.factionTemplates.lookup(values.get!UNIT_FIELD_FACTIONTEMPLATE);
            if (reactionTo(Relating(flags, faction, false, 0, 0, true), caller.ai.relatingOf(), client)
                < ReputationRank.friendly || !map_.inLineOfSight(caller.position, replica.position))
                continue;
            const row = loanSpawn(spawn, map_.id);
            if (row !is null && loanGuid(row) == replica.guid)
                sendCreatureLoan(CreatureLoan(CreatureLoan.Action.lend, spawn, map_.id, cellKeyAt(row.x, row.y),
                    caller.guid, enemy.combatGuid));
        }
    }

    private ulong loanGuid(const(CreatureSpawn)* spawn)
    {
        import dmangos.world.objects : HighGuid, makeGuid;

        return makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
    }

    ubyte[] releaseCreatureLoan(const ref Region r)
    {
        import dmangos.bytes : ByteWriter;

        const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
        if (spawn is null)
            return null;
        auto map_ = existingMap(spawn.map);
        if (map_ is null)
            return null;
        const guid = loanGuid(spawn);
        if (r.id !in localCreatureLoans)
        {
            // The initial release can be refused if the creature became busy in transit.
            auto creature = map_.creatureAt(guid);
            if (creature is null || !creature.alive || creature.ai is null || creature.ai.inCombat
                || creature.ai.evading || creature.petOwner)
                return null;
        }
        const bundle = map_.releaseCreatureLoan(guid, r.next, (MapObject object) {
            if (!r.next)
                (cast(Creature) object).ai.finishCreatureChannel(true);
            return saveMigrant(object);
        });
        if (!bundle.length && r.id !in localCreatureLoans)
            return null;
        ByteWriter state;
        state.put(respawnAt.get(spawn.guid, 0L));
        state.putBytes(bundle);
        return cast(ubyte[]) state.data;
    }

    private void creatureLoanGained(const ref Region r, const(ubyte)[] state)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.world.grid : cellKey, noCell;
        import dmangos.world.migration : decodeBundle;

        localCreatureLoans[r.id] = r;
        const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
        if (spawn is null)
            return;
        auto map_ = map(spawn.map);
        const guid = loanGuid(spawn);
        auto reader = ByteReader(state);
        const until = state.length ? reader.read!long : 0L;
        const bundle = reader.readBytes(reader.remaining);
        if (until > unixTime)
            if (!creaturePools.manages(spawn.guid))
                respawnAt[spawn.guid] = until;
        if (bundle.length)
        {
            ulong[] cells;
            Migrant[] migrants;
            decodeBundle(bundle, cells, migrants);
            foreach (ref migrant; migrants)
                migrant.home = noCell; // physical ownership stays reserved until the lease is retired
            map_.migrateIn(encodeBundle(null, migrants), (const ref Migrant migrant) {
                auto restored = restoreMigrant(migrant);
                bindMigrantLoot(restored, map_);
                return restored;
            });
        }
        else if (r.creature.returning && ownsCell(spawn.map, cellKey(r.rect.x0, r.rect.y0))
            && map_.creatureAt(guid) is null)
        {
            // A crashed borrower left no state. Re-read saved deaths before rebuilding its spawn.
            if (!state.length)
            {
                if (creaturePools.manages(spawn.guid))
                {
                    if (!creaturePools.refresh())
                        return;
                }
                else
                {
                    const saved = database.loadCreatureRespawns().get(spawn.guid, 0);
                    if (saved > unixTime)
                        respawnAt[spawn.guid] = saved;
                }
            }
            if (!awaitingRespawn(spawn.guid) && creatureInEvents(spawn.guid)
                && upInPool(PoolMember.Kind.creature, spawn.guid))
                if (auto creature = makeCreature(spawn))
                    map_.addObject(creature);
        }
        if (!r.creature.returning && bundle.length)
            if (auto helper = map_.creatureAt(guid))
                if (helper.ai !is null)
                    helper.ai.answerRemoteAssistance(map_.creatureAt(r.creature.caller), map_.unit(r.creature.enemy), map_);
    }

    private void creatureLoanLost(const ref Region r)
    {
        import dmangos.world.grid : cellKey;

        const local = localCreatureLoans.get(r.id, Region.init);
        if (!localCreatureLoans.remove(r.id))
            return;
        const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
        if (spawn is null)
            return;
        if (auto map_ = existingMap(spawn.map))
        {
            const guid = loanGuid(spawn);
            if (!creatureLease(spawn.guid).creature.spawn && local.creature.returning && canWrite())
                map_.giveCreatureHome(guid, cellKey(r.rect.x0, r.rect.y0));
            else if (map_.creatureAt(guid) !is null)
                map_.removeObject(guid); // lease expired without a clean release
        }
    }

    private void updateCreatureLoans(MonoTime now)
    {
        import dmangos.world.grid : cellKey;

        if (!localCreatureLoans.length || now < nextCreatureLoanCheck || !canWrite())
            return;
        nextCreatureLoanCheck = now + 1.seconds;
        foreach (ref local; localCreatureLoans)
        {
            const r = creatureLease(local.creature.spawn);
            if (r.owner != nodeId || r.state != RegionState.granted || r.epoch != local.epoch)
                continue;
            const spawn = loanSpawn(r.creature.spawn, r.creature.homeMap);
            auto map_ = existingMap(r.creature.homeMap);
            auto creature = map_ is null || spawn is null ? null : map_.creatureAt(loanGuid(spawn));
            if (r.creature.returning && ownsCell(r.creature.homeMap, cellKey(r.rect.x0, r.rect.y0)))
            {
                // Load the other spawns while this creature's reservation still suppresses its row.
                if (map_ !is null)
                    map_.loadCell(cellKey(r.rect.x0, r.rect.y0));
                local.creature.returning = true;
                sendCreatureLoan(CreatureLoan(CreatureLoan.Action.retire, r.creature.spawn, epoch: r.epoch));
            }
            // A defeated helper's corpse stays available to loot on the fight's node.
            else if (creature is null || (creature.alive && (creature.ai is null
                || (!creature.ai.inCombat && !creature.ai.evading))))
                sendCreatureLoan(CreatureLoan(CreatureLoan.Action.returnHome, r.creature.spawn, epoch: r.epoch));
        }
    }

    /// Puts a player in the world: on its map and in the lists of who is online.
    void enterWorld(Character who, bool shipsShown = false)
    in (who.character.guid !in online, "a character is in the world once")
    {
        import dmangos.world.worlddata : toLowerName;

        online[who.character.guid] = who;
        onlineByName[toLowerName(who.character.data.name)] = who;
        mapOf(who).add(who, shipsShown);
    }

    /// A player in the world was renamed (`.character rename`): it is found by its new name.
    void renamed(Character who, string oldName)
    {
        import dmangos.world.worlddata : toLowerName;

        onlineByName.remove(toLowerName(oldName));
        onlineByName[toLowerName(who.character.data.name)] = who;
    }

    /// Takes a player out of the world.
    void leaveWorld(Character who, Map from = null)
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
    Character onlinePlayer(ulong guid)
    {
        return online.get(guid, null);
    }

    /// The player in the world with this name (any case), or null.
    Character onlinePlayer(string name)
    {
        import dmangos.world.worlddata : toLowerName;

        return onlineByName.get(toLowerName(name), null);
    }

    /// Every player in the world.
    Character[] onlinePlayers()
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

    private bool moltenCoreTrash(const ref CreatureSpawn spawn)
    {
        enum moltenCore = 409, lockout = 7 * 24 * 60 * 60, worldBossRank = 3, instanceBind = 0x01;
        if (spawn.map != moltenCore || spawn.respawnSeconds == 0 || spawn.respawnSeconds >= lockout)
            return false;
        const template_ = spawn.entry in data.creatureTemplates;
        return template_ !is null && template_.rank != worldBossRank && !(template_.extraFlags & instanceBind);
    }

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
                const guid = creature.spawn.guid;
                state.dead[guid] = true;
                if (auto copy = battlegrounds.find(creature.instanceId))
                    return copy.objectiveChanged(); // the match checkpoint includes its dead spawns
                long until = state.resetAt ? state.resetAt : unixTime + 86_400;
                if (moltenCoreTrash(creature.spawn) && creature.respawnAt < until)
                    state.trashRespawns[guid] = until = creature.respawnAt;
                database.saveInstanceRespawn(false, guid, creature.instanceId, until);
            }
            return;
        }
        if (creaturePools.manages(creature.spawn.guid))
            creaturePools.dead(creature.spawn.guid, creature.respawnAt);
        else
        {
            respawnAt[creature.spawn.guid] = creature.respawnAt;
            database.saveCreatureRespawn(creature.spawn.guid, creature.respawnAt);
        }
    }

    /// A corpse went; if it died elsewhere, restore the original respawn deadline.
    private void corpseRemoved(Creature creature)
    {
        import std.algorithm.comparison : max;

        if (creature.petOwner)
        {
            if (auto owner = onlinePlayer(creature.petOwner))
                if (owner.character !is null)
                    owner.petCorpseGone(creature);
            return;
        }
        if (creature.summon.type != TempSpawnType.none || creature.instanceId)
            return;
        if (creaturePools.manages(creature.spawn.guid))
        {
            const next = creature.respawnAt ? max(unixTime, creature.respawnAt) : unixTime + creature.spawn.respawnSeconds;
            creaturePools.dead(creature.spawn.guid, next);
            return;
        }
        if (creature.spawn.guid !in respawnAt)
        {
            const next = creature.respawnAt ? max(unixTime, creature.respawnAt) : unixTime + creature.spawn.respawnSeconds;
            respawnAt[creature.spawn.guid] = next;
            database.saveCreatureRespawn(creature.spawn.guid, respawnAt[creature.spawn.guid]);
        }
    }

    private uint summonsMade; // standalone counters
    private ulong nextClusterTemporary, clusterTemporaryEnd; // reserved by the realm database

    /// Bones lying on a map here, with when they go (`bonesLifetime` after they were left).
    private struct LyingBones
    {
        uint map, instance;
        ulong guid;
        long goesAt;
    }

    private LyingBones[] bones_;

    /// `bones` were left on `where`: they go in an hour (`removeExpiredBones`).
    package void bonesLeft(Map where, imported!"dmangos.world.corpse".Corpse bones)
    {
        import dmangos.world.corpse : bonesLifetime;

        bones_ ~= LyingBones(where.id, bones.instanceId, bones.guid, unixTime + bonesLifetime);
    }

    /// Takes away the bones whose hour is up (they lie in time order).
    private void removeExpiredBones()
    {
        size_t gone;
        while (gone < bones_.length && bones_[gone].goesAt <= unixTime)
        {
            if (auto there = existingMap(bones_[gone].map, bones_[gone].instance))
                there.removeObject(bones_[gone].guid);
            ++gone;
        }
        if (gone)
            bones_ = bones_[gone .. $].dup;
    }

    /// A GUID counter for a temporary object (a summon, a fishing bobber).
    uint nextTemporaryCounter()
    {
        if (!config.cluster.enabled)
            return temporaryCounterStart + (++summonsMade & 0xFFFF);
        enum uint block = 1024, count = 0x100_0000 - temporaryCounterStart;
        if (nextClusterTemporary == clusterTemporaryEnd)
        {
            import dmangos.mysql : DatabaseException;

            const first = database.reserveTemporaryCounters(config.realmId, block);
            if (first.isNull)
                throw new DatabaseException("temporary object ID reservation was fenced");
            nextClusterTemporary = first.get;
            clusterTemporaryEnd = nextClusterTemporary + block;
        }
        return temporaryCounterStart + cast(uint)(nextClusterTemporary++ % count);
    }

    /**
     * Summons a creature of `entry` at `at` on `world` (near `summoner` when
     * `at` is all zeros), not saved and never respawned, gone as `type` says after `durationMs`.
     */
    Creature summonCreature(CombatWorld world, uint entry, Position at, TempSpawnType type, uint durationMs,
        ulong summoner)
    {
        auto map = cast(Map) world;
        if (map is null || entry !in data.creatureTemplates || !resolveCreatureSummonPosition(map, summoner, at))
            return null;
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

    private bool resolveCreatureSummonPosition(Map map, ulong summoner, ref Position at)
    {
        import std.math : cos, sin, PI;
        import std.random : uniform01;

        if (at.x != 0 || at.y != 0 || at.z != 0)
            return true;
        // A zero destination means a couple of yards from the summoner, on the ground.
        Position from;
        if (auto who = map.find(summoner))
            from = who.character.position;
        else if (auto o = map.findObject(summoner))
            from = o.position;
        else
            return false;
        const angle = uniform01(spawnRandom) * 2 * PI;
        at = Position(from.x + 2 * cos(angle), from.y + 2 * sin(angle), from.z, from.orientation);
        const ground = map.groundHeight(at.x, at.y, from.z + 2, false);
        if (ground > -100_000)
            at.z = ground;
        return true;
    }

    /**
     * A pet's creature: of `entry`, at `at` on `map`, not yet on the map (the owner's
     * session makes it its pet and adds it). Null if there is no such creature or model.
     */
    Creature makePetCreature(Map map, uint entry, uint number, Position at, uint handedOffCounter = 0)
    {
        if (map is null || entry !in data.creatureTemplates)
            return null;
        const counter = handedOffCounter ? handedOffCounter : nextTemporaryCounter();
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
        auto summoned = summonCreature(world, entry, at, cast(TempSpawnType) type, durationMs, summoner);
        if (summoned !is null && summoner) // its summoner's script hears of it (`EVENT_T_SUMMONED_UNIT`)
            if (auto by = world.creatureAt(summoner))
                if (by.ai !is null)
                    by.ai.summonedCreature(world, summoned);
        return summoned;
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
        if (!canAttack(self, other, client) || !isEnemy(self, other, client) || !session.player.alive
            || session.untouchable)
            return;
        // The creature's aggro radius against the player (as `CreatureAI.attackDistance`).
        const at = session.player.position, from = replica.position;
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

    private bool[uint] unsavedGameObjectSpawns;

    /**
     * A new `creature` row of `entry` at `at` on `map` (saved, in the world data and its cell, so that
     * it comes back when the cell loads again), and its creature there now; null if it cannot be made.
     */
    Creature spawnCreatureAt(Map map, uint entry, Position at)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!canWrite() || entry !in data.creatureTemplates)
            return null;
        CreatureSpawn spawn = {entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation, respawnSeconds: 120, respawnSecondsMax: 120};
        try
            spawn.guid = database.createCreatureSpawn(spawn);
        catch (DatabaseException error)
        {
            warning!"could not save the new creature spawn %s: %s"(entry, error.msg);
            return null;
        }
        if (!spawn.guid)
            return null;
        // Load the other spawns first so addObject installs and returns this creature.
        map.loadCell(cellKeyAt(spawn.x, spawn.y));
        const index = registerCreatureSpawn(spawn);
        auto creature = makeCreature(&data.creatureSpawns[index]);
        if (creature is null)
            return null;
        creature.instanceId = map.instanceId;
        map.addObject(creature);
        return creature;
    }

    private size_t registerCreatureSpawn(const ref CreatureSpawn spawn)
    {
        const index = data.creatureSpawns.length;
        data.creatureSpawns ~= spawn;
        data.creatureCells.require(spawn.map, null).require(cellKeyAt(spawn.x, spawn.y), null) ~= index;
        spawnIndex[spawn.guid] = index;
        return index;
    }

    /// The creature's spawn deleted: gone from the map, the world data's cell and the database.
    bool deleteCreatureSpawn(Map map, Creature creature)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.grid : cellKeyAt;

        const s = creature.spawn;
        if (!canWrite())
            return false;
        indexSpawns();
        if (s.guid in spawnIndex && !eraseSavedSpawn(s.guid, false))
            return false;
        if (auto cells = s.map in data.creatureCells)
            if (auto list = cellKeyAt(s.x, s.y) in *cells)
                foreach (i, index; *list)
                    if (data.creatureSpawns[index].guid == s.guid)
                    {
                        *list = (*list).remove(i);
                        break;
                    }
        respawnAt.remove(s.guid);
        spawnIndex.remove(s.guid);
        map.removeObject(creature.guid);
        return true;
    }

    /// A new `gameobject` row of `entry` at `at` (facing as it), and its object there now; null if unknown.
    GameObject spawnGameObjectAt(Map map, uint entry, Position at, bool save)
    {
        import std.math : cos, sin;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!canWrite() || entry !in data.gameObjectTemplates)
            return null;
        GameObjectSpawn spawn = {entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation, rotation: [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)]};
        if (save)
        {
            try
                spawn.guid = database.createGameObjectSpawn(spawn);
            catch (DatabaseException error)
            {
                warning!"could not save the new game object spawn %s: %s"(entry, error.msg);
                return null;
            }
            if (!spawn.guid)
                return null;
        }
        else
        {
            spawn.guid = nextTemporaryCounter();
            unsavedGameObjectSpawns[spawn.guid] = true;
        }
        map.loadCell(cellKeyAt(spawn.x, spawn.y));
        const index = registerGameObjectSpawn(spawn);
        auto go = makeGameObject(data.gameObjectSpawns[index]);
        go.instanceId = map.instanceId;
        if (go.type == GameObjectType.transport)
            refreshElevatorHomes(map);
        map.addObject(go);
        return go;
    }

    private size_t registerGameObjectSpawn(const ref GameObjectSpawn spawn)
    {
        const index = data.gameObjectSpawns.length;
        data.gameObjectSpawns ~= spawn;
        data.gameObjectCells.require(spawn.map, null).require(cellKeyAt(spawn.x, spawn.y), null) ~= index;
        gameObjectSpawnIndex[spawn.guid] = index;
        return index;
    }

    /**
     * The game object's spawn changed (moved, turned): its row and the world data rewritten, and the
     * object made anew from it, so that the clients see it there. Returns null if it could not save.
     */
    GameObject respawnGameObjectAs(Map map, GameObject go, GameObjectSpawn changed)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!canWrite())
            return null;
        const home = cellKeyAt(changed.x, changed.y);
        if (!map.instanceId && ownsCell !is null && !ownsCell(changed.map, home))
            return null;
        indexSpawns();
        const at = go.spawn.guid in gameObjectSpawnIndex;
        if (at is null)
            return null;
        if (changed.guid !in unsavedGameObjectSpawns)
            try
            {
                if (!database.updateGameObjectPlacement(changed))
                    return null;
            }
            catch (DatabaseException error)
            {
                warning!"could not save changes to game object %s: %s"(changed.guid, error.msg);
                return null;
            }
        if (home != cellKeyAt(go.spawn.x, go.spawn.y))
            map.loadCell(home);
        replaceGameObjectSpawn(*at, changed);
        map.removeObject(go.guid);
        auto made = makeGameObject(data.gameObjectSpawns[*at]);
        made.instanceId = map.instanceId;
        if (made.type == GameObjectType.transport)
            refreshElevatorHomes(map);
        map.addObject(made);
        return made;
    }

    /// Adjust a saved spawn and its cell index together, on a GM edit or at region arrival.
    private void replaceGameObjectSpawn(size_t at, const ref GameObjectSpawn changed)
    {
        import std.algorithm.mutation : remove;

        const old = data.gameObjectSpawns[at];
        const oldCell = cellKeyAt(old.x, old.y), newCell = cellKeyAt(changed.x, changed.y);
        if (old.map != changed.map || oldCell != newCell)
        {
            if (auto cells = old.map in data.gameObjectCells)
                if (auto list = oldCell in *cells)
                    foreach (i, index; *list)
                        if (index == at)
                        {
                            *list = (*list).remove(i);
                            break;
                        }
            data.gameObjectCells.require(changed.map, null).require(newCell, null) ~= at;
        }
        data.gameObjectSpawns[at] = changed;
    }

    /// The game object's spawn deleted: gone from the map, the world data's cell and the database.
    bool deleteGameObjectSpawn(Map map, GameObject go)
    {
        import std.algorithm.mutation : remove;
        import dmangos.world.grid : cellKeyAt;

        const s = go.spawn;
        if (!canWrite())
            return false;
        indexSpawns();
        if (s.guid in gameObjectSpawnIndex && s.guid !in unsavedGameObjectSpawns && !eraseSavedSpawn(s.guid, true))
            return false;
        if (auto cells = s.map in data.gameObjectCells)
            if (auto list = cellKeyAt(s.x, s.y) in *cells)
                foreach (i, index; *list)
                    if (data.gameObjectSpawns[index].guid == s.guid)
                    {
                        *list = (*list).remove(i);
                        break;
                    }
        gameObjectRespawnAt.remove(s.guid);
        gameObjectSpawnIndex.remove(s.guid);
        unsavedGameObjectSpawns.remove(s.guid);
        map.removeObject(go.guid);
        if (go.type == GameObjectType.transport)
            refreshElevatorHomes(map);
        return true;
    }

    private bool eraseSavedSpawn(uint guid, bool gameObject)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        try
            return database.eraseSavedSpawn(guid, gameObject);
        catch (DatabaseException error)
        {
            warning!"could not delete world spawn %s: %s"(guid, error.msg);
            return false;
        }
    }

    /**
     * A trap (`GAMEOBJECT_TYPE_TRAP`) a player stepped near: one not friendly
     * to the player casts its spell at the player, then waits its cooldown; one with charges is used
     * up after them (and comes back with its spawn's respawn time).
     */
    package void trapSprung(Map map, Inhabitant who, GameObject trap)
    {
        import dmangos.world.gameobject : GoLootState;

        if (unixTime < trap.trapReadyAt || trap.lootState != GoLootState.ready)
            return;
        if (trap.owner)
            return; // a hunter's: its owner's spell, sprung on its owner's enemies (`Character.updateTraps`)
        const spell = cast(uint) trap.template_.data[3];
        if (spell == 0)
            return;
        if (trap.spawn.battlegroundPowerUp)
        {
            import dmangos.world.character : Character;

            if (auto copy = battlegrounds.find(map.instanceId))
                if (auto player = cast(Character) who)
                    if (player.player !is null && data.spells.spell(spell) !is null
                        && copy.takePowerUp(map, trap, player.player.guid))
                        player.castTriggeredAt(spell, player.player.guid);
            return;
        }
        auto session = trapTarget(trap, who);
        if (session is null)
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

    private auto trapTarget(GameObject trap, Inhabitant who)
    {
        import dmangos.world.relations : isFriend, Relating;

        auto session = cast(Character) who;
        if (session is null || session.character is null || !session.player.alive)
            return null;
        const faction = client.factionTemplates.lookup(trap.template_.faction);
        if (faction !is null && isFriend(Relating(0, faction, false, 0, 0, true), session.relating, client))
            return null;
        return session;
    }

    package bool gameObjectTrapDisarmed(GameObject go, Map map, ulong player)
    {
        import dmangos.script.api : TrapDisarmed;

        return raiseObject(go, map, TrapDisarmed(EntityRef(player)));
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
        // Where `spell_scripts` names none, a script serving the spell by id (what CMaNGOS's core scripts by id).
        if (id in data.spellScriptNames)
            return statelessScript(ScriptKind.spell, id, data.spellScriptNames, spellScripts);
        return statelessScript(ScriptKind.spell, id, scripts.spellsServedById, spellScripts);
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

    private bool guildWriteActive, guildWriteChanged;
    private ulong mirroredGuildRevision;
    private void delegate()[] guildAfterCommit;
    private MonoTime nextGuildPoll;

    package bool serializesGuildWrites() const
    {
        return config.cluster.nodeId && regionOwnerAround !is null;
    }

    /// Run the regular guild handler with the current guilds and the transaction's database.
    package bool commitGuildChange(scope void delegate() change)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.fencing : FencedBase;

        if (!serializesGuildWrites() || guildWriteActive)
        {
            change();
            return true;
        }
        if (!canWrite() || !settleWrites())
            return false;
        auto original = database;
        auto published = guilds;
        guildWriteActive = true;
        guildWriteChanged = false;
        bool committed, refreshed;
        scope (exit)
        {
            guildWriteActive = false;
            guildAfterCommit = null;
            if (!committed)
            {
                guilds = published;
                mirroredGuildRevision = 0;
                nextGuildPoll = MonoTime.init;
            }
        }
        try
        {
            const revision = original.commitGuildChange((WorldDatabase transaction, ulong current) {
                refreshed = mirroredGuildRevision != current;
                if (refreshed)
                {
                    guilds = new Guilds;
                    guilds.load(transaction.loadGuilds());
                }
                else
                    guilds = published.copy();

                database = transaction;
                scope (exit) database = original;
                change();
                if (auto fenced = cast(FencedBase) original)
                    if (!fenced.writesAllowedNow)
                        throw new DatabaseException("the guild writer's lease lapsed");
                return guildWriteChanged;
            });
            if (!revision)
                return false;
            if (!refreshed && !guildWriteChanged)
                guilds = published;
            mirroredGuildRevision = revision;
            committed = true;
        }
        catch (DatabaseException error)
        {
            warning!"guild change could not be committed: %s"(error.msg);
            return false;
        }
        guildWriteActive = false;
        foreach (effect; guildAfterCommit)
            effect();
        if (refreshed || guildWriteChanged)
            guildFieldsHere();
        return true;
    }

    package void afterGuildWrite(void delegate() effect)
    {
        if (guildWriteActive)
            guildAfterCommit ~= effect;
        else
            effect();
    }

    package void guildChangedHere(uint id)
    {
        if (guildWriteActive)
            guildWriteChanged = true;
        else
            guildFieldsHere();
        if (guildReloadElsewhere !is null)
            afterGuildWrite(() => guildReloadElsewhere(id));
    }

    private void pollGuildMirror(MonoTime now)
    {
        import core.time : seconds;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!serializesGuildWrites() || now < nextGuildPoll)
            return;
        nextGuildPoll = now + 5.seconds;
        try
        {
            const current = database.guildRevision();
            if (current && mirroredGuildRevision != current)
            {
                guilds.load(database.loadGuilds());
                mirroredGuildRevision = current;
                guildFieldsHere();
            }
        }
        catch (DatabaseException error)
            warning!"guild mirror will be refreshed again: %s"(error.msg);
    }

    /// A guild's packet for its members online here whose rank has `right` (0: all).
    void guildToMembersHere(uint guild, Opcode opcode, const(ubyte)[] body_, uint right)
    {
        auto g = guilds.find(guild);
        Character[] recipients;
        foreach (session; onlinePlayers)
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
                if (guildWriteActive)
                    recipients ~= session;
                else
                    session.deliver(opcode, body_);
            }
        if (recipients.length)
            afterGuildWrite({
                foreach (session; recipients)
                    session.deliver(opcode, body_);
            });
    }

    /// The guild fields of every player here, from their guilds now.
    void guildFieldsHere()
    {
        foreach (session; onlinePlayers)
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
        if (auto session = onlinePlayer(target))
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

                if (script.raise(ObjectUsedHere(EntityRef(go.guid), EntityRef(player))))
                    return true;
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

    private bool[GameObjectOnMap] tickingObjects;
    private GameObjectArrival[] objectArrivals; // scripted game objects put in the world, for `Spawned`

    private static struct GameObjectOnMap
    {
        Map map;
        ulong guid; // distinct copies of a dungeon use the same spawn GUIDs
    }

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
            tickingObjects[GameObjectOnMap(map, go.guid)] = true;
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
        foreach (key, _; tickingObjects.dup)
        {
            auto map = key.map;
            auto go = cast(GameObject) map.findObject(key.guid);
            if (go is null || !go.behaviour || !scripts.busy(go.behaviour))
            {
                tickingObjects.remove(key);
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
                tickingObjects.remove(key);
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

        void hostPulseTrap()
        {
            import dmangos.world.auras : makeAura;
            import dmangos.world.spellcast : duration, effectValue, radius;
            import dmangos.world.spellids : SpellEffect;

            const spell = data.spells.spell(cast(uint) go.template_.data[3]);
            if (spell is null)
                return;
            // Suppression Aura targets enemies around its caster's location. The device is the
            // source of the debuff, so players must not cast the area effect on one another.
            const level = spell.spellLevel;
            const lasts = duration(*spell, client, level);
            int[3] amounts;
            float range = 0;
            foreach (i; 0 .. spell.effect.length)
                if (spell.effect[i] == SpellEffect.applyAura)
                {
                    amounts[i] = effectValue(*spell, i, level, 0);
                    const effectRadius = radius(*spell, i, client);
                    if (range < effectRadius)
                        range = effectRadius;
                }
            if (range <= 0)
                return;
            foreach (who; map.near(go.position, range))
                if (auto session = trapTarget(go, who))
                    session.addAura(makeAura(spell, go.guid, level, lasts, false, amounts));
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
            import dmangos.world.gameobject : gameObjectAnimation;
            import dmangos.world.opcodes : Opcode;

            map.sendToObservers(go.guid, Opcode.SMSG_GAMEOBJECT_CUSTOM_ANIM, gameObjectAnimation(go.guid, 0));
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
            auto session = onlinePlayer(player.guid);
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
            import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;

            if (auto creature = map.creatureAt(caster.guid))
                return creature.ai.castFor(map, spell, target.guid, true);
            auto session = onlinePlayer(caster.guid);
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
    /// A game object nobody owns (a spell's, `dmangos.world.guardians`) at `at`, for `seconds` (0: for good).
    GameObject summonWildGameObject(Map map, uint entry, Position at, uint seconds)
    {
        return summonGameObjectAt(map, entry, Location(at.x, at.y, at.z, at.orientation), seconds);
    }

    private GameObject summonGameObjectAt(Map map, uint entry, Location at, uint seconds)
    {
        import std.math : cos, sin;

        if (entry !in data.gameObjectTemplates)
            return null;
        auto spawn = GameObjectSpawn(nextTemporaryCounter(), entry, map.id, at.x, at.y, at.z);
        spawn.orientation = at.orientation;
        spawn.rotation = [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)];
        auto go = makeGameObject(spawn);
        go.instanceId = map.instanceId;
        map.addObject(go);
        if (seconds)
            scriptedGameObjects[GameObjectOnMap(map, go.guid)] = unixTime + seconds;
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

    /// See `CreatureLore.spellScriptTargets`.
    const(uint)[] spellScriptTargets(uint spell, size_t effect = size_t.max)
    {
        const entries = data.spellScriptTargets.get(spell, null);
        if (effect >= 3 || spell !in data.spellScriptTargetMasks)
            return entries;
        uint[] allowed;
        foreach (entry; entries)
            if (!(scriptTargetExclusions(spell, entry) & (1u << effect)))
                allowed ~= entry;
        return allowed;
    }

    package uint scriptTargetExclusions(uint spell, uint entry) const
    {
        if (const mask = spell in data.spellScriptTargetMasks)
            return (*mask).get(entry, 0);
        return 0;
    }

    /// See `CreatureLore.conditionMet`.
    bool conditionMet(uint id, ulong player)
    {
        import dmangos.world.conditions : ConditionSubject;

        auto c = onlinePlayer(player);
        if (c is null || c.player is null)
            return false;
        const subject = ConditionSubject(c.player, null);
        return data.npcs.conditions.satisfied(id, subject, client);
    }

    /// See `CreatureLore.zoneAndAreaAt`.
    uint[2] zoneAndAreaAt(uint map, Position at)
    {
        auto t = terrain(map);
        return t is null || !t.knows(at.x, at.y) ? [0u, 0u] : t.zoneAndArea(at.x, at.y, at.z);
    }

    /// See `CreatureLore.creatureBaseDamage`.
    float creatureBaseDamage(uint level, uint unitClass)
    {
        import dmangos.world.creature : classStatsKey;

        const stats = classStatsKey(level, unitClass) in data.creatureClassStats;
        return stats is null ? 0 : stats.baseDamage;
    }

    /// Open-world round 2: see `CreatureLore.creaturePath`.
    const(imported!"dmangos.world.motion".WaypointNode)[] creaturePath(uint entry, uint guid, uint pathId = 0)
    {
        return data.waypoints is null ? null : data.waypoints.pathFor(entry, guid, pathId, false);
    }

    /// Open-world round 2: see `CreatureLore.zoneUnderAttack`.
    void zoneUnderAttack(CombatWorld world, Creature defender, ulong attacker)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.unit : UnitKind;

        auto map = cast(Map) world;
        if (map is null)
            return;
        auto unit = map.unit(attacker);
        Character session;
        if (unit.kind == UnitKind.player)
            session = unit.session;
        else if (unit.kind == UnitKind.creature && unit.creature.petOwner)
            session = onlinePlayer(unit.creature.petOwner);
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
            auto player = onlinePlayer(source);
            if (player is null)
                player = onlinePlayer(target);
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
        if (creaturePools.manages(corpse.spawn.guid))
            creaturePools.dead(corpse.spawn.guid, unixTime + 1, true);
        else
        {
            respawnAt[corpse.spawn.guid] = unixTime + 1;
            database.saveCreatureRespawn(corpse.spawn.guid, respawnAt[corpse.spawn.guid]);
        }
        map.corpseExpired(corpse);
    }

    /// Game objects used up: spawn guid -> when they come back (Unix time), as `gameobject_respawn` has it.
    private long[uint] gameObjectRespawnAt;

    /// A game object from its spawn, with what it needs to show players their quests' objects.
    GameObject makeGameObject(scope const ref GameObjectSpawn spawn)
    {
        auto go = new GameObject(spawn, spawn.entry in data.gameObjectTemplates);
        go.setElevator(elevatorPathOf(go.guid, go.fields), &transportNow);
        if (const kit = worldPvp is null ? 0 : worldPvp.artKitOf(spawn.entry, spawn.x, spawn.y, spawn.z))
        {
            import dmangos.world.updatefields : GAMEOBJECT_ARTKIT;

            go.values.set!GAMEOBJECT_ARTKIT(kit); // a tower's banner in its holder's colours
        }
        if (isQuestObject(go))
            go.activatesFor = (ulong viewer) {
                auto session = onlinePlayer(viewer);
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

    /// Persistent rewards are one-shot database-spawned dungeon chests with no gathering refills.
    package bool isInstanceReward(const GameObject go)
    {
        import dmangos.world.gameobject : GameObjectType;

        return go.instanceId in instances && go.spawn.guid < temporaryCounterStart
            && go.type == GameObjectType.chest && go.consumable && go.spawn.respawnSeconds < 0
            && !go.template_.data[4] && !go.template_.data[5];
    }

    package InstanceChestRecord checkpointReward(Map map, GameObject go,
        const imported!"dmangos.world.loot".LootItem claimed = null, ulong looter = 0)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.instancescripting : toHex;

        auto state = go.instanceId in instances;
        if (state is null)
            return InstanceChestRecord.init;
        const now = unixTime;
        const visibleUntil = scriptedGameObjects.get(GameObjectOnMap(map, go.guid), long.max);
        const openedUntil = now + (go.despawnTimer + 999) / 1000;
        const deadline = state.chests.get(go.spawn.guid, InstanceChestRecord.init).expiresAt;
        ByteWriter w;
        w.put(ubyte(1));
        go.loot.saveHandoff(w, claimed, looter);
        auto record = InstanceChestRecord(go.instanceId, go.spawn.guid,
            deadline ? deadline : visibleUntil < openedUntil ? visibleUntil : openedUntil, toHex(w.data));
        state.chests[go.spawn.guid] = record;
        return record;
    }

    private bool restoreReward(GameObject go, const ref InstanceChestRecord reward)
    {
        import dmangos.bytes : ByteReader, PacketException;
        import dmangos.log : warning;
        import dmangos.world.gameobject : GoLootState;
        import dmangos.world.gameobjecthandlers : bindChestLoot;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.loot : Loot;
        import std.algorithm.searching : all;

        const remaining = reward.expiresAt - unixTime;
        if (remaining <= 0 || !isInstanceReward(go))
            return false;
        auto r = ByteReader(fromHex(reward.loot));
        try
        {
            if (r.read!ubyte != 1)
                throw new PacketException("unknown instance reward version");
            auto loot = Loot.loadHandoff(go.guid, r);
            if (!loot.gold && loot.items.all!(item => item.allowed.length == 0))
                return false;
            go.loot = loot;
            go.lootState = GoLootState.activated;
            go.despawnTimer = cast(int)(remaining > int.max / 1000 ? int.max : remaining * 1000);
            bindChestLoot(this, instanceMaps[go.instanceId], go, loot);
            return true;
        }
        catch (PacketException e)
        {
            warning!"could not restore reward chest %s of instance %s: %s"(reward.spawn, reward.instance, e.msg);
            return false;
        }
    }

    /// A game object used up: it comes back after its spawn's respawn time.
    private void gameObjectUsedUp(GameObject go)
    {
        if (go.spawn.guid >= temporaryCounterStart)
            return;
        if (go.instanceId)
        {
            if (auto state = go.instanceId in instances)
            {
                state.usedUp[go.spawn.guid] = true;
                if (auto copy = battlegrounds.find(go.instanceId))
                    return copy.objectiveChanged();
                database.saveInstanceRespawn(true, go.spawn.guid, go.instanceId,
                    state.resetAt ? state.resetAt : unixTime + 86_400);
            }
            return;
        }
        if (go.spawn.respawnSeconds < 0)
            return;
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
        if (due.length)
            indexSpawns();
        foreach (guid; due)
        {
            const index = guid in gameObjectSpawnIndex;
            const spawn = index is null ? null : &data.gameObjectSpawns[*index];
            gameObjectRespawnAt.remove(guid);
            if (ownsCell !is null && (spawn is null || !ownsCell(spawn.map, cellKeyAt(spawn.x, spawn.y))))
                continue;
            database.saveGameObjectRespawn(guid, 0);
            if (spawn is null)
                continue;
            if (!rerolledBack(PoolMember.Kind.gameObject, guid, (uint member) {
                    if (const i = member in gameObjectSpawnIndex)
                    {
                        gameObjectRespawnAt[member] = time + data.gameObjectSpawns[*i].respawnSeconds;
                        database.saveGameObjectRespawn(member, gameObjectRespawnAt[member]);
                    }
                }))
                continue;
            auto there = existingMap(spawn.map);
            if (there !is null && there.cellLoaded(cellKeyAt(spawn.x, spawn.y)))
                there.addObject(makeGameObject(*spawn));
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
        const cut = house is null ? 0 : a.cut(*house, config.rateAuctionCut);
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
            // "After the expiry period the mail is returned to the sender" with its item or money; the auction
            // house's and NPCs' is discarded (WoWWiki "Mail", 2006-11; docs/FORMULAS.md "Mail").
            if ((m.itemGuid || m.money) && m.messageType == 0 && m.sender
                && !(m.checked & (checkReturned | checkCodPayment)))
            {
                MailRecord back;
                back.money = m.money;
                back.sender = m.receiver;
                back.receiver = m.sender;
                back.subject = m.subject;
                back.itemTextId = m.itemTextId;
                back.itemGuid = m.itemGuid;
                back.itemEntry = m.itemEntry;
                back.checked = checkReturned;
                if (back.itemGuid)
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
        if (creaturePools.manages(spawnGuid))
            return creaturePools.waiting(spawnGuid);
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

        if (now - lastRespawnCheck < 1.seconds || !canWrite())
            return;
        lastRespawnCheck = now;
        gameObjectsDue();
        const time = unixTime;
        respawnCreaturePools(time);
        respawnMoltenCoreTrash(time);
        uint[] due;
        foreach (guid, at; respawnAt)
            if (at <= time && !creatureOnLoan(guid))
                due ~= guid;
        if (due.length == 0)
            return;
        indexSpawns();
        foreach (guid; due)
        {
            const index = guid in spawnIndex;
            const spawn = index is null ? null : &data.creatureSpawns[*index];
            const home = spawn is null ? ulong.max : cellKeyAt(spawn.x, spawn.y);
            if (ownsCell !is null && (spawn is null || !ownsCell(spawn.map, home)))
            {
                respawnAt.remove(guid);
                continue;
            }
            auto there = spawn is null ? null : existingMap(spawn.map);
            if (there !is null)
                if (auto corpse = there.creatureAt(loanGuid(spawn)))
                    if (!corpse.alive)
                        continue;
            respawnAt.remove(guid);
            database.saveCreatureRespawn(guid, 0);
            if (spawn is null)
                continue;
            if (!rerolledBack(PoolMember.Kind.creature, guid, (uint member) {
                    if (const i = member in spawnIndex)
                    {
                        respawnAt[member] = time + data.creatureSpawns[*i].respawnSeconds;
                        database.saveCreatureRespawn(member, respawnAt[member]);
                    }
                }))
                continue;
            if (there is null || !there.cellLoaded(home))
                continue;
            if (auto creature = makeCreature(spawn))
            {
                there.addObject(creature);
                linkedRespawn(there, creature);
            }
        }
    }

    private void respawnMoltenCoreTrash(long now)
    {
        foreach (id, map; instanceMaps)
            if (auto state = id in instances)
                foreach (guid; state.trashRespawns.keys)
                {
                    const readyAt = guid in state.trashRespawns;
                    if (readyAt is null || *readyAt > now)
                        continue;
                    const spawn = creatureSpawnOf(guid);
                    if (spawn is null || cantSpawnWhileBossDead(*spawn, state))
                    {
                        state.trashRespawns.remove(guid);
                        database.saveInstanceRespawn(false, guid, id, state.resetAt ? state.resetAt : now + 86_400);
                        continue;
                    }
                    const at = cellKeyAt(spawn.x, spawn.y);
                    if (map.cellLoaded(at))
                    {
                        auto corpse = map.creatureAt(makeGuid(HighGuid.unit, spawn.entry, guid));
                        respawnInCopy(map, spawn, corpse is null || corpse.alive ? null : corpse);
                    }
                    else
                    {
                        state.trashRespawns.remove(guid);
                        state.dead.remove(guid);
                        database.deleteInstanceRespawn(guid, id);
                    }
                }
    }

    /// Only the selected placement's owner may roll it. Once a placement is ready, its owner loads it once.
    private void respawnCreaturePools(long time)
    {
        import std.random : uniform;

        if (!creaturePools.refresh())
            return;
        foreach (pool, state; creaturePools.states())
        {
            if (state.due > time || !creaturePools.contains(pool, state.spawn) || creatureOnLoan(state.spawn))
                continue;
            const spawn = creatureSpawnOf(state.spawn);
            if (spawn is null)
                continue;
            const home = cellKeyAt(spawn.x, spawn.y);
            if (ownsCell !is null && !ownsCell(spawn.map, home))
                continue;
            auto there = existingMap(spawn.map);
            if (there !is null && there.creatureAt(loanGuid(spawn)) !is null)
                continue; // a corpse is still waiting for loot or the live creature is already here
            if (state.due)
            {
                const next = creatureSpawnOf(creaturePools.roll(pool, state.spawn, spawnRandom));
                if (next is null)
                    continue;
                long due;
                if (next.guid != state.spawn)
                    due = time + (next.respawnSecondsMax > next.respawnSeconds
                        ? uniform!"[]"(next.respawnSeconds, next.respawnSecondsMax, spawnRandom) : next.respawnSeconds);
                if (!creaturePools.change(pool, state.revision, next.guid, due) || due)
                    continue;
            }
            if (there !is null && there.cellLoaded(home) && creatureInEvents(spawn.guid))
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
        timed(TickPhase.maps, () {
            // Ownership notifications run after the world tick. A stalled borrower can resume
            // after its lease expires, so fence its combat before ticking borrowed creatures.
            if (!localCreatureLoans.length || canWrite())
                mapsPhase(elapsed);
        });
        timed(TickPhase.deaths, () => deathsPhase());
        timed(TickPhase.world, () {
            updateCreatureLoans(now);
            deliverReplicaSpells(now);
            worldPhase(now, elapsed);
        });
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
            map_.snapshotPlayers(mapTickPlayers);
            scope (exit) clearTickSnapshot(mapTickPlayers);
            foreach (who; mapTickPlayers)
                if (auto player = cast(OnlinePlayer) who)
                    if (player.character !is null && player.character.guid !in updatedPlayers)
                    {
                        updatedPlayers[player.character.guid] = true;
                        isolated(player, () => player.update(elapsed));
                    }
            isolated(map_, () => map_.update(elapsed));
        }
        void tickMaps(Key)(Map[Key] active)
        {
            snapshotValues(active, tickMapsNow);
            scope (exit) clearTickSnapshot(tickMapsNow);
            foreach (map_; tickMapsNow)
                tickMap(map_);
        }
        tickMaps(maps);
        tickMaps(instanceMaps);
        snapshotValues(online, tickPlayersNow);
        scope (exit) clearTickSnapshot(tickPlayersNow);
        foreach (player; tickPlayersNow) // an update may log a player out
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
        pollWeather(now);
        pollWorldCatalog(now);
        pollGuildMirror(now);
        addPendingNavigation();
        checkHonorWeek(now);
        services.tick(elapsed);
        pollLootCoinCredits(now);
        pollBattlegroundRewards(now);
        worldPvp.tick(elapsed);
        if (battlegroup is null || battlegroup.host is this) battlegrounds.tick(elapsed);
        landObjectAnimations(now);
        updateGameEvents(now);
        removeExpiredBones();
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
    private Map[] tickMapsNow;
    private Inhabitant[] mapTickPlayers;
    private Character[] tickPlayersNow;

    private static void snapshotValues(T, Key)(T[Key] source, ref T[] snapshot)
    {
        snapshot.length = source.length;
        size_t i;
        foreach (value; source)
            snapshot[i++] = value;
    }

    private static void clearTickSnapshot(T)(ref T[] snapshot)
    {
        // Release the objects while keeping capacity for the next snapshot.
        snapshot[] = null;
        snapshot.length = 0;
        snapshot.assumeSafeAppend();
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
        id = counterOf(kind)++;
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

    /// The coordinator's serial for this particular login, even if a replacement is waiting.
    package ulong sessionSerial(Kickable session)
    {
        return serials.get(session, 0);
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

    private CreaturePools creaturePools;
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

// A whole battleground moves with its objectives, timers, scores and objects on the ground.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.battleground : Battleground;
    import dmangos.world.bgqueue : BattlegroundType, BattlegroundStatus;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : mapWarsongGulch;
    import dmangos.world.warsong : WarsongRules;

    enum instance = 123;
    auto db = newDatabase();
    auto from = newCreationContext(db), to = newCreationContext(db);
    const now = MonoTime.currTime, later = now + 60.seconds;
    from.clock = () => now;
    to.clock = () => later;
    const at = Position(1500, 1480, 353);
    const template_ = GameObjectTemplate(entry: 9009, type: GameObjectType.door);
    from.data.gameObjectTemplates[template_.entry] = template_;
    to.data.gameObjectTemplates[template_.entry] = template_;
    auto copy = from.battlegrounds.open(instance, BattlegroundType.warsongGulch);
    auto field = from.map(mapWarsongGulch, instance);
    auto ground = from.spawnGameObjectAt(field, template_.entry, at, true);
    assert(ground !is null);
    copy.status = BattlegroundStatus.inProgress;
    copy.testing = true;
    copy.made = now - 31.seconds;
    copy.activeEvents[9] = 2;
    from.instances[instance].dead[64] = true;
    from.instances[instance].usedUp[65] = true;
    copy.members[42] = Battleground.Member(0, now - 4.seconds, 6);
    copy.awaitingResurrection[42] = 123;
    auto rules = cast(WarsongRules) copy.rules;
    rules.dropped[0] = ground.guid;
    rules.dropLeft[0] = 12.seconds;
    rules.carrier[1] = 42;

    auto region = Region(200, mapWarsongGulch, CellRect(-256, -256, 256, 256), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    from.regionsChanged(null, [region], null, leaving);
    assert(from.battlegrounds.find(instance) is null);
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    to.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto restored = to.battlegrounds.find(instance);
    assert(restored !is null && restored.status == BattlegroundStatus.inProgress && restored.testing);
    assert(restored.made == later - 31.seconds && restored.untilSpiritHeal == 29.seconds);
    assert(restored.members[42].offlineSince == later - 4.seconds && restored.members[42].killingBlows == 6);
    assert(restored.awaitingResurrection[42] == 123 && restored.activeEvents[9] == 2);
    assert(64 in to.instances[instance].dead && 65 in to.instances[instance].usedUp);
    auto moved = cast(WarsongRules) restored.rules;
    assert(moved.carrier[1] == 42 && moved.dropped[0] == ground.guid && moved.dropLeft[0] == 12.seconds);
    assert(to.existingMap(mapWarsongGulch, instance).gameObjectAt(ground.guid) !is null);
}

// A cold map grant restores the same snapshot without touching the running map or accepting its stale writes.
unittest
{
    import dmangos.world.bgqueue : BattlegroundType, BattlegroundStatus;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : mapWarsongGulch;
    import dmangos.world.warsong : WarsongRules, flagOnGround, stateCapturesAlliance, stateFlagHorde;

    enum instance = 123;
    auto db = newDatabase();
    auto from = newCreationContext(db), to = newCreationContext(db);
    const now = MonoTime.currTime;
    from.clock = () => now;
    to.clock = () => now + 25.seconds;
    from.battlegroundMapEpoch = map => map == mapWarsongGulch ? 4UL : 0UL;
    to.battlegroundMapEpoch = map => map == mapWarsongGulch ? 5UL : 0UL;
    const banner = GameObjectTemplate(entry: 179786, type: GameObjectType.flagDrop);
    from.data.gameObjectTemplates[banner.entry] = banner;
    to.data.gameObjectTemplates[banner.entry] = banner;
    auto match = from.battlegrounds.open(instance, BattlegroundType.warsongGulch);
    auto map = from.map(mapWarsongGulch, instance);
    auto flag = from.spawnGameObjectAt(map, banner.entry, Position(1500, 1480, 353), true);
    assert(flag !is null);
    match.status = BattlegroundStatus.inProgress;
    match.setWorldState(stateCapturesAlliance, 1);
    match.setWorldState(stateFlagHorde, flagOnGround);
    auto rules = cast(WarsongRules) match.rules;
    rules.dropped[1] = flag.guid;
    rules.dropLeft[1] = 8.seconds;
    from.battlegrounds.flushCheckpoints();
    const realm = from.config.realmId;
    const saved = db.loadBattlegroundCheckpoints(realm, mapWarsongGulch, long.min)[0];
    assert(map.gameObjectAt(flag.guid) is flag);

    to.battlegrounds.recoverMap(mapWarsongGulch, false);
    auto restored = to.battlegrounds.find(instance);
    assert(restored !is null && restored.status == BattlegroundStatus.inProgress);
    assert(restored.worldStates[stateCapturesAlliance] == 1 && restored.worldStates[stateFlagHorde] == flagOnGround);
    auto recovered = cast(WarsongRules) restored.rules;
    assert(recovered.dropLeft[1] == 8.seconds && recovered.dropped[1] == flag.guid);
    assert(to.existingMap(mapWarsongGulch, instance).gameObjectAt(flag.guid) !is null);
    assert(!db.saveBattlegroundCheckpoint(realm, mapWarsongGulch, saved));
    to.battlegrounds.closed(restored);
    assert(db.loadBattlegroundCheckpoints(realm, mapWarsongGulch, long.min).length == 0);
    assert(db.highestGuids().instance > instance);
}

// Outdoor scripted objects keep their expiry and scheduled forced despawn through a transfer.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto db = newDatabase();
    auto from = newCreationContext(db), to = newCreationContext(db);
    auto now = MonoTime.currTime;
    from.clock = () => now;
    to.clock = () => now;
    const template_ = GameObjectTemplate(entry: 9010, type: GameObjectType.spellFocus);
    from.data.gameObjectTemplates[template_.entry] = template_;
    to.data.gameObjectTemplates[template_.entry] = template_;
    const at = Position(-8930, -120, 83.53f);
    auto oldMap = from.map(0), newMap = to.map(0);
    auto summon = from.summonWildGameObject(oldMap, template_.entry, at, 5);
    auto focus = from.spawnGameObjectAt(oldMap, template_.entry, at, true);
    focus.forceDespawn(oldMap, 700);
    focus.tick(oldMap, 100);

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(91, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    from.regionsChanged(null, [region], null, leaving);
    assert(oldMap.isReplica(summon.guid) && oldMap.isReplica(focus.guid));
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    to.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto movedFocus = newMap.gameObjectAt(focus.guid);
    assert(movedFocus !is null && newMap.gameObjectAt(summon.guid) !is null);
    movedFocus.tick(newMap, 500);
    assert(newMap.gameObjectAt(focus.guid) is movedFocus);
    movedFocus.tick(newMap, 150);
    assert(newMap.gameObjectAt(focus.guid) is null);
    to.scriptedGameObjectsDue();
    assert(newMap.gameObjectAt(summon.guid) !is null);
    now += 6.seconds;
    to.scriptedGameObjectsDue();
    assert(newMap.gameObjectAt(summon.guid) is null);
}

unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.auras : AuraType, makeAura;
    import dmangos.world.gameobject : GameObjectTemplate, goStateActive;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.movement : MoveType;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : creatureInnkeeper;
    import dmangos.world.updatefields : UNIT_FIELD_AURA, UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

    auto db = newDatabase();
    auto oldOwner = newCreationContext(db), newOwner = newCreationContext(db);
    const at = Position(-8930, -120, 83.53f);
    const door = GameObjectTemplate(entry: 9010, type: GameObjectType.door);
    enum uint heal = 40001, slow = 40002;
    auto hot = testSpell(heal, SpellEffect.applyAura, ImplicitTarget.caster, 10);
    hot.casting.applyAuraName[0] = AuraType.periodicHeal;
    hot.casting.amplitude[0] = 500;
    auto snare = testSpell(slow, SpellEffect.applyAura, ImplicitTarget.caster, -50);
    snare.casting.applyAuraName[0] = AuraType.modDecreaseSpeed;
    foreach (context; [oldOwner, newOwner])
    {
        context.data.gameObjectTemplates[door.entry] = door;
        context.data.spells.spells[heal] = hot;
        context.data.spells.spells[slow] = snare;
    }
    auto oldMap = oldOwner.map(0), newMap = newOwner.map(0);
    auto creature = oldOwner.spawnCreatureAt(oldMap, creatureInnkeeper, at);
    auto object = oldOwner.spawnGameObjectAt(oldMap, door.entry, at, true);
    assert(oldMap.findObject(creature.guid) is creature && oldMap.findObject(object.guid) is object);
    creature.values.set!UNIT_FIELD_MAXHEALTH(100u);
    creature.values.set!UNIT_FIELD_HEALTH(1u);
    object.useDoorOrButton(oldMap);
    bool added;
    auto healAura = makeAura(oldOwner.spellInfo(heal), 7, 60, 1000, true, [10, 0, 0]);
    healAura.periodTimer[0] = 125;
    creature.receiveAura(healAura, oldMap, added);
    const normalRun = creature.speeds[MoveType.run];
    creature.receiveAura(makeAura(oldOwner.spellInfo(slow), 8, 60, 750, false, [-50, 0, 0]), oldMap, added);
    creature.refreshAuraMovement(oldMap);
    assert(creature.speeds[MoveType.run] == normalRun * 0.5f);

    auto wrongCell = oldOwner.saveMigrant(object);
    wrongCell.home = cellKeyAt(at.x + 100, at.y);
    assert(newOwner.restoreWorldMigrant(wrongCell, newMap) is null);
    assert(object.spawn.guid !in newOwner.gameObjectSpawnIndex);

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    oldOwner.regionsChanged(null, [region], null, leaving);
    assert(oldMap.isReplica(creature.guid) && oldMap.isReplica(object.guid));
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    newOwner.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto restoredCreature = cast(Creature) newMap.findObject(creature.guid);
    auto restoredDoor = cast(GameObject) newMap.findObject(object.guid);
    assert(restoredCreature !is null && restoredCreature.values.get!UNIT_FIELD_HEALTH == 1);
    assert(restoredDoor !is null && restoredDoor.goState == goStateActive);
    auto restoredAura = restoredCreature.auras.find(heal, 7);
    assert(restoredAura !is null && restoredAura !is healAura && restoredAura.periodTimer[0] == 125
        && restoredAura.duration == 1000 && restoredAura.slot == healAura.slot);
    const auraSlot = restoredAura.slot;
    assert(restoredCreature.values.get!UNIT_FIELD_AURA(auraSlot) == heal);
    restoredCreature.refreshAuraMovement(newMap);
    assert(restoredCreature.speeds[MoveType.run] == normalRun * 0.5f, "the snare is applied only once");
    restoredCreature.updateAuras(newMap, 124);
    assert(restoredCreature.values.get!UNIT_FIELD_HEALTH == 1);
    restoredCreature.updateAuras(newMap, 1);
    assert(restoredCreature.values.get!UNIT_FIELD_HEALTH == 11, "the next tick heals on the destination");
    restoredCreature.updateAuras(newMap, 875);
    restoredCreature.refreshAuraMovement(newMap);
    assert(restoredCreature.auras.find(heal, 7) is null && !restoredCreature.values.get!UNIT_FIELD_AURA(auraSlot));
    assert(restoredCreature.speeds[MoveType.run] == normalRun, "the snare expires on the destination");
    const key = cellKeyAt(at.x, at.y);
    size_t creatureCopies, objectCopies;
    foreach (index; newOwner.data.creatureCells[0][key])
        creatureCopies += newOwner.data.creatureSpawns[index].guid == creature.spawn.guid;
    foreach (index; newOwner.data.gameObjectCells[0][key])
        objectCopies += newOwner.data.gameObjectSpawns[index].guid == object.spawn.guid;
    assert(creatureCopies == 1 && objectCopies == 1);
    assert(!newMap.isReplica(creature.guid) && !newMap.isReplica(object.guid));
}

// The new owner keeps a scripted summon and expires it at the original time.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.migration : MigrantKind;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : creatureInnkeeper;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto db = newDatabase();
    void clustered(ref WorldConfig config) { config.cluster.nodeId = 1; }
    auto oldOwner = newCreationContext(db, &clustered), newOwner = newCreationContext(db, &clustered);
    auto cold = newCreationContext(db, &clustered);
    auto now = MonoTime.currTime;
    foreach (owner; [oldOwner, newOwner, cold])
    {
        owner.clock = () => now;
        owner.startClock = now;
        owner.startUnixMillis = oldOwner.startUnixMillis;
    }
    auto source = oldOwner.map(0), destination = newOwner.map(0);
    const at = Position(-8930, -120, 83.53f);
    auto summon = oldOwner.summonCreature(source, creatureInnkeeper, at, TempSpawnType.timed, 3000, 5);
    assert(summon !is null && source.findObject(summon.guid) is summon);
    summon.values.set!UNIT_FIELD_HEALTH(1u);
    source.update(1700.msecs);
    now += 1700.msecs;
    assert(summon.summon.timer == 1300);
    summon.totemOwner = 7;
    assert(oldOwner.saveMigrant(summon).kind == MigrantKind.none, "totems use their existing owner lifecycle");
    summon.totemOwner = 0;

    auto wrongHome = oldOwner.saveMigrant(summon);
    wrongHome.home = cellKeyAt(at.x + 100, at.y);
    assert(newOwner.restoreWorldMigrant(wrongHome, destination) is null);
    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    oldOwner.regionsChanged(null, [region], null, leaving);
    assert(source.isReplica(summon.guid));
    now += 300.msecs;
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    newOwner.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto restored = destination.creatureAt(summon.guid);
    assert(restored !is null && restored !is summon && !destination.isReplica(summon.guid));
    assert(restored.spawn == summon.spawn && restored.values.get!UNIT_FIELD_HEALTH == 1);
    assert(restored.summon == TempSpawn(TempSpawnType.timed, 1000, 3000, 5));
    auto restarted = newCreationContext(db, &clustered);
    assert(newOwner.nextTemporaryCounter() != summon.spawn.guid);
    assert(restarted.nextTemporaryCounter() != summon.spawn.guid, "reusing a node ID leaves old live GUIDs reserved");
    destination.update(999.msecs);
    assert(destination.creatureAt(summon.guid) is restored);
    destination.update(1.msecs);
    assert(destination.findObject(summon.guid) is null);
    assert(db.savedCreatureSpawn(summon.spawn.guid).isNull);
    cold.regionsChanged([region], null, null, unused);
    assert(cold.map(0).findObject(summon.guid) is null);
}

// The same player can reopen a partially emptied chest on its new owner, without rerolling it.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : lockFormat;
    import dmangos.world.gameobject : GameObjectTemplate, GoLootState;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.loot : lootRow;
    import dmangos.world.loothandlers : ClientLootSlot;
    import dmangos.world.player : Player;
    import dmangos.world.playercreate : NewSpell, NewSkill;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : DamageClass;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto source = newCreationContext(db), destination = newCreationContext(db);
    auto relay = new TestPlayerRelay(source, destination);
    destination.next.item = 10_000; // distinct blocks, as on cluster workers
    const at = Position(-8949.95f, -132.49f, 83.53f);
    auto now = MonoTime.currTime;
    source.clock = destination.clock = () => now;
    source.startClock = destination.startClock = now;
    destination.startUnixMillis = source.startUnixMillis;
    enum uint lock = 999, gather = 2366;
    GameObjectTemplate template_ = {entry: 9011, type: GameObjectType.chest};
    template_.data[0] = lock;
    template_.data[1] = 555;
    auto lockRow = new uint[lockFormat.length];
    lockRow[0] = lock;
    lockRow[1] = 2;
    lockRow[9] = 2;
    auto opening = testSpell(gather, 33, 26, 0);
    opening.miscValue[0] = 2;
    opening.casting.dmgClass = DamageClass.none;
    foreach (node; [source, destination])
    {
        node.data.gameObjectTemplates[template_.entry] = template_;
        node.data.spells.spells[gather] = opening;
        node.client.locks = typeof(node.client.locks).parse(buildDbc(lockFormat, [lockRow]), "Lock.dbc");
    }
    source.data.loot.gameObject.add(555, lootRow(itemJerky, 100, 0, 1, 1, 0));
    source.data.loot.gameObject.add(555, lootRow(itemSword, 100, 0, 1, 1, 0));
    auto client = loggedIn(source, db, 7, "Anduin", at, setup: (ref row) {
        row.spells = [NewSpell(gather, true)];
        row.skills = [NewSkill(182, 10, 75)];
    });
    auto oldMap = source.map(0), newMap = destination.map(0);
    auto chest = source.spawnGameObjectAt(oldMap, template_.entry, at, true);
    assert(chest !is null);
    auto character = cast(Player) client.session.character;
    ByteWriter open;
    open.put(gather);
    SpellTargets target;
    target.mask = TargetFlags.gameObject;
    target.gameObject = chest.guid;
    target.write(open);
    const jerky = character.inventory.count(itemJerky), sword = character.inventory.count(itemSword);
    client.read();
    client.write(Opcode.CMSG_CAST_SPELL, open.data);
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
    assert(chest.loot.items.length == 2 && chest.loot.items[0].itemId == itemJerky);
    client.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
    assert(character.inventory.count(itemJerky) == jerky + 1);
    assert(chest.loot.items[0].allowed.length == 0 && chest.loot.items[1].allowed[character.guid]);
    chest.gatherUses = 2;
    chest.gatherSkill = 157;
    chest.skilledUp[character.guid] = true;
    chest.despawnTimer = 12_000;
    client.read();

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    Region region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    source.regionsChanged(null, [region], null, leaving);
    assert(oldMap.isReplica(chest.guid) && opcodesOf(client.read()).canFind(Opcode.SMSG_LOOT_RELEASE_RESPONSE));
    now += 2.seconds;
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    destination.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto restored = cast(GameObject) newMap.findObject(chest.guid);
    assert(restored !is null && restored.loot !is null && restored.lootState == GoLootState.activated);
    assert(restored.gatherUses == 2 && restored.gatherSkill == 157 && restored.skilledUp[character.guid]);
    assert(restored.despawnTimer == 10_000);
    assert(restored.loot.items[0].allowed.length == 0 && restored.loot.items[1].allowed[character.guid]);

    // SQL reloads the inventory written by the previous owner. The memory fixture keeps them separately.
    foreach (guid, ref row; db.itemRows)
        if (db.itemOwners[guid] == character.guid)
            db.loadable[cast(uint) character.guid].items ~= row;
    client.write(Opcode.CMSG_CAST_SPELL, open.data);
    assert(relay.remote !is null);
    relay.remote.update(50.msecs);
    assert(relay.remote.character.knowsSpell(gather));
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
    client.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(0));
    assert(!opcodesOf(client.read()).canFind(Opcode.SMSG_ITEM_PUSH_RESULT));
    client.write(Opcode.CMSG_CAST_SPELL, open.data);
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_LOOT_RESPONSE));
    client.write(Opcode.CMSG_AUTOSTORE_LOOT_ITEM, ClientLootSlot(1));
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_ITEM_PUSH_RESULT));
    assert(relay.remote.character.inventory.count(itemJerky) == jerky + 1
        && relay.remote.character.inventory.count(itemSword) == sword + 1);
    assert(restored.lootState == GoLootState.justDeactivated);
}

// A receiver that loaded the old row uses the saved move and rotation in the handoff.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.gameobject : GameObjectTemplate, goStateActive;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto db = newDatabase();
    const template_ = GameObjectTemplate(entry: 9012, type: GameObjectType.door);
    const original = GameObjectSpawn(guid: 9_000_020, entry: template_.entry, x: -8930, y: -120, z: 83.5f,
        respawnSeconds: 123);
    db.insertGameObjectSpawn(original);
    auto from = newCreationContext(db), to = newCreationContext(db);
    foreach (world; [from, to])
    {
        world.data.gameObjectTemplates[template_.entry] = template_;
        world.registerGameObjectSpawn(original);
    }
    auto source = from.map(0);
    const oldHome = cellKeyAt(original.x, original.y);
    source.loadCell(oldHome);
    auto old = source.gameObjectAt(from.makeGameObject(original).guid);
    assert(old !is null);
    GameObjectSpawn changed = original;
    changed.x += 80;
    changed.orientation = 1.5f;
    changed.rotation = [0, 0, 0.68f, 0.73f];
    const newHome = cellKeyAt(changed.x, changed.y);
    from.ownsCell = (uint, ulong cell) => cell == oldHome;
    assert(from.respawnGameObjectAs(source, old, changed) is null);
    assert(db.savedGameObjectSpawn(original.guid).get == original && source.gameObjectAt(old.guid) is old);
    // Both cells are now on the same owner. The command can move the object between them.
    from.ownsCell = (uint, ulong) => true;
    auto moved = from.respawnGameObjectAs(source, old, changed);
    assert(moved !is null && moved.spawn == changed && db.savedGameObjectSpawn(original.guid).get == changed);
    moved.useDoorOrButton(source);

    const x = cellCoordinate(changed.x), y = cellCoordinate(changed.y);
    Region region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    from.regionsChanged(null, [region], null, leaving);
    assert(source.isReplica(old.guid));
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    to.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
    auto destination = to.map(0);
    auto carried = destination.gameObjectAt(old.guid);
    assert(carried !is null && carried.spawn == changed && carried.position.x == changed.x
        && carried.goState == goStateActive);
    assert(to.data.gameObjectCells[0][oldHome].length == 0 && to.data.gameObjectCells[0][newHome].length == 1);
    destination.release(cell => cell == newHome);
    destination.loadCell(oldHome);
    assert(destination.gameObjectAt(old.guid) is null, "there is no spawn at the old position after reloading the cell");
    destination.loadCell(newHome);
    assert(destination.gameObjectAt(old.guid).spawn == changed);
}

// A crash leaves no bundle, even when a saved object moved across cells after both nodes started.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto db = newDatabase();
    const door = GameObjectTemplate(entry: 9012, type: GameObjectType.door);
    const original = GameObjectSpawn(guid: 9_000_020, entry: door.entry, x: -8930, y: -120, z: 83.5f);
    GameObjectSpawn row = original;
    row.entry = 0; // the world loader picked this entry through a spawn group
    db.insertGameObjectSpawn(row);
    auto from = newCreationContext(db), to = newCreationContext(db);
    foreach (world; [from, to])
    {
        world.data.gameObjectTemplates[door.entry] = door;
        world.registerGameObjectSpawn(original);
    }
    const guid = makeGuid(HighGuid.gameObject, door.entry, original.guid);
    const oldHome = cellKeyAt(original.x, original.y);
    auto oldMap = from.map(0);
    oldMap.loadCell(oldHome);
    GameObjectSpawn changed = original;
    changed.x += 80;
    changed.orientation = 1.5f;
    changed.rotation = [0, 0, 0.68f, 0.73f];
    const newHome = cellKeyAt(changed.x, changed.y);
    assert(from.respawnGameObjectAs(oldMap, oldMap.gameObjectAt(guid), changed) !is null);

    // The replacement gets the new cell first. Its copy of the row still points into the old cell.
    auto replacement = to.map(0);
    bool ownsOld;
    to.ownsCell = (uint, ulong cell) => cell == newHome || (ownsOld && cell == oldHome);
    const x = cellCoordinate(changed.x), y = cellCoordinate(changed.y);
    const gained = Region(1, 0, CellRect(x, y, x + 1, y + 1), 2, 2, RegionState.granted);
    ubyte[][uint] leaving;
    to.regionsChanged([gained], null, null, leaving);
    replacement.loadCell(newHome);
    auto recovered = replacement.gameObjectAt(guid);
    assert(recovered !is null && recovered.spawn == changed && recovered.position.x == changed.x);

    // Loading the former cell cannot put the object back there.
    ownsOld = true;
    replacement.loadCell(oldHome);
    size_t copies;
    replacement.forEachObject((MapObject object) { if (object.guid == guid) ++copies; });
    assert(copies == 1 && replacement.gameObjectAt(guid) is recovered);
    assert(to.data.gameObjectCells[0][oldHome].length == 0 && to.data.gameObjectCells[0][newHome].length == 1);
}

// Absent spawns resume their original timers after either a clean transfer or a lost owner.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : creatureInnkeeper;

    foreach (clean; [true, false])
    {
        auto db = newDatabase();
        auto oldOwner = newCreationContext(db), newOwner = newCreationContext(db), bystander = newCreationContext(db);
        const at = Position(-8930, -120, 83.53f);
        const home = cellKeyAt(at.x, at.y);
        const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
        const creature = CreatureSpawn(9_000_001, creatureInnkeeper, 0, at.x, at.y, at.z);
        const door = GameObjectTemplate(entry: 9011, type: GameObjectType.door);
        const object = GameObjectSpawn(guid: 9_000_001, entry: door.entry, x: at.x, y: at.y, z: at.z);
        auto now = MonoTime.currTime;
        foreach (node; [oldOwner, newOwner, bystander])
        {
            node.clock = () => now;
            node.startClock = now;
            node.startUnixTime = oldOwner.startUnixTime;
            node.registerCreatureSpawn(creature);
            node.registerGameObjectSpawn(object);
            node.data.gameObjectTemplates[door.entry] = door;
        }
        bool moving;
        oldOwner.ownsCell = (uint map, ulong cell) => !moving && map == 0 && cell == home;
        newOwner.ownsCell = (uint map, ulong cell) => moving && map == 0 && cell == home;
        bystander.ownsCell = (uint, ulong) => false;
        const deadline = oldOwner.unixTime + 10;
        oldOwner.respawnAt[creature.guid] = deadline;
        oldOwner.gameObjectRespawnAt[object.guid] = deadline;
        if (!clean)
        {
            db.saveCreatureRespawn(creature.guid, deadline);
            db.saveGameObjectRespawn(object.guid, deadline);
        }

        Region region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
        ubyte[][uint] leaving, unused;
        moving = true;
        if (clean)
        {
            assert(oldOwner.existingMap(0) is null, "the departing owner never loaded these spawns");
            oldOwner.regionsChanged(null, [region], null, leaving);
            assert(leaving[region.id].length > 8);
        }
        region.owner = 2;
        region.state = RegionState.granted;
        region.next = 0;
        const(ubyte)[][uint] arriving = clean ? [region.id: cast(const(ubyte)[]) leaving[region.id]] : null;
        newOwner.regionsChanged([region], null, arriving, unused);
        assert(newOwner.awaitingRespawn(creature.guid) && newOwner.gameObjectAwaitingRespawn(object.guid));
        auto map = newOwner.map(0);
        map.loadCell(home);
        const creatureGuid = makeGuid(HighGuid.unit, creature.entry, creature.guid);
        const objectGuid = makeGuid(HighGuid.gameObject, object.entry, object.guid);
        assert(map.findObject(creatureGuid) is null && map.findObject(objectGuid) is null);

        db.saveCreatureRespawn(creature.guid, deadline); // by then the departing writer has settled
        db.saveGameObjectRespawn(object.guid, deadline);
        bystander.respawnAt[creature.guid] = deadline;
        bystander.gameObjectRespawnAt[object.guid] = deadline;
        now += 11.seconds;
        bystander.respawnDue(now);
        assert(db.creatureRespawns[creature.guid] == deadline && db.gameObjectRespawns[object.guid] == deadline,
            "another node cannot clear the owning node's timers");
        newOwner.respawnDue(now);
        auto alive = map.creatureAt(creatureGuid);
        auto ready = map.gameObjectAt(objectGuid);
        assert(alive !is null && alive.alive && ready !is null);
        assert(creature.guid !in db.creatureRespawns && object.guid !in db.gameObjectRespawns);
        now += 2.seconds;
        newOwner.respawnDue(now);
        assert(map.creatureAt(creatureGuid) is alive && map.gameObjectAt(objectGuid) is ready);
    }
}

// As with Akubar, two cells can host one rare. The deadline, the roll, and its new location outlive a node.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.fencing : FencedDatabase;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.testclient : newDatabase;
    import dmangos.world.testdata : creatureInnkeeper, testClientData, testWorldData;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;
    import dmangos.world.worlddata : PoolChooser;

    enum uint realm = 37, pool = 1031;
    enum kind = PoolMember.Kind.creature;
    const placements = [
        CreatureSpawn(guid: 9_000_001, entry: creatureInnkeeper, x: -8900, y: -120, z: 84, respawnSeconds: 10),
        CreatureSpawn(guid: 9_000_002, entry: creatureInnkeeper, x: -6500, y: -120, z: 84, respawnSeconds: 10),
    ];
    const homes = [cellKeyAt(placements[0].x, placements[0].y), cellKeyAt(placements[1].x, placements[1].y)];
    assert(homes[0] != homes[1]);

    auto clock = MonoTime.currTime;
    WorldContext newNode(WorldDatabase db, uint seed = 13)
    {
        auto client = testClientData();
        auto world = testWorldData(client);
        world.pools = new PoolChooser;
        world.pools.limits[pool] = 1;
        foreach (i, ref spawn; placements)
        {
            world.pools.add(pool, PoolMember(kind, spawn.guid));
            world.creatureCells[0][homes[i]] ~= world.creatureSpawns.length;
            world.creatureSpawns ~= spawn;
        }
        auto rng = Random(seed);
        world.pools.choose(rng);
        WorldConfig config;
        config.realmId = realm;
        auto node = new WorldContext(config, db, world, client);
        node.clock = () => clock;
        return node;
    }

    void expectRoll(WorldContext node, uint original, uint wanted)
    {
        foreach (seed; 0u .. 32u)
        {
            auto rng = Random(seed);
            if (node.data.pools.rollSingleCreature(pool, original, rng) == wanted)
            {
                node.spawnRandom = Random(seed);
                return;
            }
        }
        assert(false, "no test seed chose the wanted pool member");
    }

    enum Scenario { standalone, split, clean, cold }
    foreach (scenario; [Scenario.standalone, Scenario.split, Scenario.clean, Scenario.cold])
    {
        auto db = newDatabase();
        auto oldOwner = newNode(db);
        auto remote = scenario == Scenario.standalone ? oldOwner : newNode(db);
        auto winner = scenario == Scenario.clean || scenario == Scenario.cold ? newNode(db) : oldOwner;
        foreach (node; [oldOwner, remote, winner])
        {
            node.startClock = clock;
            node.startUnixTime = oldOwner.startUnixTime;
        }
        const first = oldOwner.upInPool(kind, placements[0].guid) ? 0 : 1;
        const second = 1 - first;
        const start = placements[first].guid, alternate = placements[second].guid;
        const startingGuid = makeGuid(HighGuid.unit, creatureInnkeeper, start);
        const alternateGuid = makeGuid(HighGuid.unit, creatureInnkeeper, alternate);
        bool moved;
        if (scenario != Scenario.standalone)
        {
            oldOwner.ownsCell = (uint mapId, ulong cell) => (!moved || scenario == Scenario.cold)
                && !mapId && cell == homes[first];
            remote.ownsCell = (uint mapId, ulong cell) => !mapId && cell == homes[second];
            if (scenario == Scenario.cold)
                oldOwner.database = new FencedDatabase(oldOwner.database, () => !moved);
            if (winner !is oldOwner)
                winner.ownsCell = (uint mapId, ulong cell) => moved && !mapId && cell == homes[first];
        }
        auto firstMap = oldOwner.map(0), secondMap = remote.map(0);
        firstMap.loadCell(homes[first]);
        secondMap.loadCell(homes[second]);
        auto rare = firstMap.creatureAt(startingGuid);
        assert(rare !is null && secondMap.creatureAt(alternateGuid) is null);
        rare.values.set!UNIT_FIELD_HEALTH(0u);
        firstMap.creatureDeath(rare);
        firstMap.corpseExpired(rare);
        const dead = db.loadCreaturePoolStates(realm)[pool];
        assert(dead.spawn == start && dead.due == oldOwner.unixTime + 10 && dead.revision == 1);
        assert(!db.updateCreaturePoolState(realm, pool, 0, alternate, 0), "a stale initial claim loses");

        if (winner !is oldOwner)
        {
            import dmangos.cluster.regions : Region, RegionState;

            const x = cellCoordinate(placements[first].x), y = cellCoordinate(placements[first].y);
            Region region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
            ubyte[][uint] leaving, unused;
            moved = true;
            if (scenario == Scenario.clean)
                oldOwner.regionsChanged(null, [region], null, leaving);
            region.owner = 2;
            region.state = RegionState.granted;
            region.next = 0;
            const(ubyte)[][uint] arriving = scenario == Scenario.clean
                ? [region.id: cast(const(ubyte)[]) leaving[region.id]] : null;
            winner.regionsChanged([region], null, arriving, unused);
            winner.map(0).loadCell(homes[first]);
            assert(winner.awaitingRespawn(start) && winner.map(0).creatureAt(startingGuid) is null);
        }

        clock += 11.seconds;
        if (winner !is oldOwner)
            oldOwner.respawnDue(clock);
        if (remote !is winner)
            remote.respawnDue(clock);
        assert(db.loadCreaturePoolStates(realm)[pool] == dead, "only the owner of the selected home can roll");
        expectRoll(winner, start, alternate);
        winner.respawnDue(clock);
        const waiting = db.loadCreaturePoolStates(realm)[pool];
        assert(waiting.spawn == alternate && waiting.due == winner.unixTime + 10 && waiting.revision == 2);
        assert(!db.updateCreaturePoolState(realm, pool, dead.revision, start, 0), "a stale winner cannot undo the roll");
        assert(secondMap.creatureAt(alternateGuid) is null, "the alternate keeps its own delay");

        // An already running destination learns the choice, and a restarted destination loads the same choice.
        assert(db.loadCreaturePoolStates(realm + 1).length == 0);
        auto finalOwner = scenario == Scenario.split ? remote : newNode(db, 55);
        if (finalOwner !is remote)
        {
            finalOwner.startClock = clock;
            finalOwner.startUnixTime = winner.unixTime;
            if (scenario != Scenario.standalone)
            {
                remote.ownsCell = (uint, ulong) => false;
                finalOwner.ownsCell = (uint mapId, ulong cell) => !mapId && cell == homes[second];
            }
        }
        clock += 2.seconds;
        finalOwner.respawnDue(clock);
        auto destination = finalOwner.map(0);
        destination.loadCell(homes[second]);
        assert(!finalOwner.upInPool(kind, start) && finalOwner.awaitingRespawn(alternate));
        assert(destination.creatureAt(alternateGuid) is null);

        clock += 11.seconds;
        expectRoll(finalOwner, alternate, alternate);
        finalOwner.respawnDue(clock);
        const live = db.loadCreaturePoolStates(realm)[pool];
        auto placed = destination.creatureAt(alternateGuid);
        assert(live.spawn == alternate && !live.due && live.revision == 3 && placed !is null && placed.alive);
        clock += 2.seconds;
        finalOwner.respawnDue(clock);
        if (remote !is winner && remote !is finalOwner)
            remote.respawnDue(clock);
        assert(destination.creatureAt(alternateGuid) is placed);
        assert(destination is secondMap || secondMap.creatureAt(alternateGuid) is null);
        assert(!db.updateCreaturePoolState(realm, pool, dead.revision, start, 0));
    }

    // Upgrade from a pre-pool-state database whose pending spawn disagrees with the fresh seed.
    auto legacy = newDatabase();
    auto seeded = newNode(legacy);
    const unseeded = seeded.upInPool(kind, placements[0].guid) ? placements[1].guid : placements[0].guid;
    const inherited = seeded.unixTime + 10;
    legacy.saveCreatureRespawn(unseeded, inherited);
    auto upgraded = newNode(legacy);
    assert(upgraded.upInPool(kind, unseeded) && upgraded.awaitingRespawn(unseeded));
    assert(legacy.loadCreaturePoolStates(realm)[pool].due == inherited);
}

// A lost node supplies no bundle, but its durable additions still belong to the next owner.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : creatureInnkeeper;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(-8930, -120, 83.53f);
    const creature = CreatureSpawn(9_000_001, creatureInnkeeper, 0, at.x, at.y, at.z);
    const outside = CreatureSpawn(9_000_002, creatureInnkeeper, 0, at.x + 100, at.y, at.z);
    const door = GameObjectTemplate(entry: 9010, type: GameObjectType.door);
    context.data.gameObjectTemplates[door.entry] = door;
    const object = GameObjectSpawn(guid: 9_000_001, entry: door.entry, x: at.x, y: at.y, z: at.z);
    db.insertCreatureSpawn(creature);
    db.insertCreatureSpawn(outside);
    db.insertGameObjectSpawn(object);
    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    const region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 2, 2, RegionState.granted);
    ubyte[][uint] leaving;
    context.regionsChanged([region], null, null, leaving);
    auto map_ = context.map(0);
    map_.loadCell(cellKeyAt(at.x, at.y));
    const creatureGuid = makeGuid(HighGuid.unit, creature.entry, creature.guid);
    const objectGuid = makeGuid(HighGuid.gameObject, object.entry, object.guid);
    assert(cast(Creature) map_.findObject(creatureGuid) !is null);
    assert(cast(GameObject) map_.findObject(objectGuid) !is null);
    assert(outside.guid !in context.spawnIndex);
    const creatureCount = context.data.creatureSpawns.length, objectCount = context.data.gameObjectSpawns.length;
    context.regionsChanged([region], null, null, leaving);
    assert(context.data.creatureSpawns.length == creatureCount && context.data.gameObjectSpawns.length == objectCount);
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
