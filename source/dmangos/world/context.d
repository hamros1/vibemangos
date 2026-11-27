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
import dmangos.world.gameobject : GameObject, GameObjectSpawn, GameObjectTemplate, GameObjectType, GoLootState;
import dmangos.world.gameobjectpools : GameObjectPools;
import dmangos.world.auctionhouse;
import dmangos.world.database : MailRecord;
import dmangos.world.movement : Position;
import dmangos.world.migration : Migrant, MigrantKind, encodeBundle;
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
import dmangos.world.map : Map;
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
import dmangos.world.database : DungeonFightCheckpoint, InstanceChestRecord, InstanceCorpseRecord, PickpocketRecord,
    QuestActorCheckpoint, WorldDatabase;
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
import dmangos.world.loot : Loot, LootItem, maxLootItems;
import dmangos.world.map : Inhabitant, Map, MapObject, MapSettings, VisibilityFacts;
import dmangos.world.online : OnlinePlayer;
import dmangos.world.character : Character;
import dmangos.world.player : Player;
import dmangos.world.playercreate : CreationSettings;
import dmangos.world.spellids : ImplicitTarget, SpellEffect, noEffect;
import dmangos.world.worlddata : EventCreature, EventMail, PoolMember, Ship, SpawnGroupCondition, SpellListEntry, WorldData;

/// A cluster member has no ids of a kind left (`WorldContext.nextItemGuid`): the coordinator's next block has not come.
class IdsExhausted : Exception
{
    import std.exception : basicExceptionCtors;

    mixin basicExceptionCtors;
}

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
    staff = 8,        /// its account has staff access
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
final class WorldContext : GroupDirectory, IdCounters, SessionHandler
{
    import dmangos.world.ships : Ships;

    /// See `dmangos.world.ships`.
    Ships fleet;

    import dmangos.world.postoffice : PostOffice;

    /// See `dmangos.world.postoffice`.
    PostOffice postOffice;

    import dmangos.world.dungeons : Dungeons;

    /// The dungeon copies this node hosts and the binds to them (`dmangos.world.dungeons`).
    Dungeons dungeons;

    import dmangos.world.dbscripts : DbScriptRunner;

    mixin DbScriptRunner; // `dbscripts_on_*` under way

    import dmangos.world.weatherservice : WeatherHost, WeatherNotice, ZoneWeather;

    /// The realm's weather as this node knows it (`dmangos.world.weatherservice.ZoneWeather`).
    ZoneWeather weather;

    import dmangos.world.worldcatalog : CatalogFollower;

    /// The world catalogs (vendors, trainers, quests, ...) as staff edits on any node change them.
    CatalogFollower catalogs;

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
    package InstanceScript[uint] instanceScripts; // by instance id: the scripts of the copies loaded here
    private InstanceScript[uint] worldScripts;    // by map id, the continents' scripts here

    /// Next free character, item and mail ids.
    GuidCounters next;

    /// Authenticated sessions by account id; one per account.
    private Kickable[uint] sessions;

    /// The maps that have players on them, by map id.
    package Map[uint] maps;
    private Terrain[uint] terrains;
    private ModelCache vmapModels;     // the buildings and doodads all maps share
    private GameObjectModels gameObjectModels;

    /// Players in the world, by guid and by lower-cased name.
    package Character[ulong] online;
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

    /// Sends a packet to every other node's players (with `staffOnly`, staff announcement recipients); null standalone.
    void delegate(ushort opcode, bool staffOnly, const(ubyte)[] body_) toEveryoneElsewhere;

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
    /// `held`: claimed again for a new coordinator after an earlier one granted it (`SessionClaim.held`).
    void delegate(uint account, ulong serial, bool held) claimSession;
    void delegate(uint account, ulong serial) releaseSession;

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
        if (announcePresence !is null)
            announcePresence(who, true);
    }

    /// A player's simulation leaves for node `next`: off the map and the lists, without a word.
    void leaveWorldForMigration(Character who, ushort next)
    {
        import dmangos.world.worlddata : toLowerName;

        mapOf(who).removeForMigration(who, next);
        lastHeard[who.character.guid] = Heard(next, MonoTime.currTime, who.character.data.level);
        online.remove(who.character.guid);
        onlineByName.remove(toLowerName(who.character.data.name));
        if (announcePresence !is null)
            announcePresence(who, false);
    }

    // Players other nodes simulate: what each node said of its own.
    private RemotePlayer[ulong][ushort] remoteByNode;
    void delegate(Character, bool) announcePresence;

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

    /// The cluster incarnation supplies a floor compatible with numbers issued before range reservations.
    ulong incarnation;
    private ulong gameplayReservedUntil;
    private enum uint gameplayBlockSize = 1 << 20;

    ulong nextGameplaySequence()
    {
        import std.datetime.systime : Clock;
        import dmangos.mysql : DatabaseException;

        if (incarnation && (!gameplayReservedUntil || gameplaySequence == gameplayReservedUntil))
        {
            const first = database.reserveGameplaySequences(config.realmId, config.cluster.nodeId,
                incarnation << 20, gameplayBlockSize);
            if (!first)
                throw new DatabaseException("could not reserve gameplay sequence numbers");
            gameplaySequence = first - 1;
            gameplayReservedUntil = gameplaySequence + gameplayBlockSize;
        }
        else if (!incarnation && !gameplaySequence)
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
            || (message.instance && !dungeons.instanceable(message.map)))
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
            const earlier = database.loadLootAward(key);
            if (earlier.decided)
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
            // A master award is for a group member: the loot's node checks the drop's members, and this node
            // refuses a player who is in no group at all.
            if (!master || (groups.of(message.player) !is null
                && (!message.condition || player.conditionMet(message.condition))))
                result.inventoryError = cast(ubyte) player.lootItemFits(message.item, message.count, !master);
            // The token is claimed before the item exists: the loot's node may expire the award at any moment,
            // and only one of the two can record it. Its refusal first: nothing is stored. The claim is not the
            // result: the item's rows turn it into stored (`saveLootAward`), so a claim whose item was never written
            // (this worker crashed, or its lease lapsed, before the write) is this recipient's to store again.
            if (result.inventoryError == InventoryResult.ok)
            {
                if (earlier.claimed || database.claimLootAward(key, unixTime))
                    result.inventoryError = cast(ubyte) player.storeLootItem(message.item, message.count,
                        message.randomProperty, !master, award: key);
                else
                {
                    const recorded = database.loadLootAward(key);
                    if (!recorded.decided)
                        return; // the claim was not written (the lease lapsed): the loot's node asks again
                    result.inventoryError = recorded.error;
                }
            }
            result.stored = result.inventoryError == InventoryResult.ok;
            if (!result.stored)
                database.saveLootAward(key, result.inventoryError, unixTime, 0, 0, null);
            if (!settleWrites())
                return; // the loot's node asks again; the token's row answers once the write is in
            // The row, not this worker's view, is the outcome: the item's write is what turned the claim into stored.
            const outcome = database.loadLootAward(key);
            if (!outcome.decided)
                return;
            result.stored = !outcome.error;
            result.inventoryError = outcome.error;
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
            // The database adds the credits to the live purse, not to its own older copy of the money, and nothing
            // runs between reading the purse and setting it to that sum: unsaved spending is not refunded, and the
            // session and the database hold the same money afterwards.
            const paid = database.redeemLootCoins(guid, player.player.money.amount, unixTime);
            if (!paid.valid)
                return;
            retryLootCoinRedemption.remove(guid);
            if (!paid.copper)
                return;
            player.player.values.set!PLAYER_FIELD_COINAGE(paid.wallet);
            player.flushPlayerChanges();
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
            // Objectives' rewards during matches, to the players here: those online, and crash-offline ones back.
            foreach (ref event; database.pendingBattlegroundEventRewards())
                if (auto who = onlinePlayer(playerGuid(event.reward.player)))
                    if (who.player !is null && !who.transferring)
                        who.payBattlegroundEventReward(event);
        }
        catch (DatabaseException error)
            warning!"could not deliver battleground rewards: %s"(error.msg);
        catch (IdsExhausted error) // nothing was paid: the reward waits for the next poll, the tick goes on
            warning!"could not deliver battleground rewards yet: %s"(error.msg);
    }

    private void pollLootCoinCredits(MonoTime now)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if ((sendRemoteLootCoins is null && !retryLootCoinRedemption.length) || !online.length
            || now < nextLootCoinPoll || !canWrite())
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
        const duration = cast(int) (pulse.expires - fleet.transportNow());
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
        if (effect == noEffect || !spellScriptTargets(spell.id).length || spellScript(spell.id))
            return noEffect;
        if (databaseSpellEffect(spell.effect[effect]) && !data.dbScripts.targetsOnly(spell.id))
            return noEffect;
        return effect;
    }

    /// The first applicable effect in a shared target group, including auras when damage is excluded.
    package size_t namedCreatureEffectFor(const(SpellInfo)* spell, size_t first, uint entry)
    {
        import dmangos.world.spelldamage : remoteTargetAuraEffects;

        if (first == noEffect)
            return noEffect;
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
        return noEffect;
    }

    package const(uint)[] namedCreatureEntries(const(SpellInfo)* spell, size_t first)
    {
        const entries = spellScriptTargets(spell.id);
        if (spell.id !in data.spellScriptTargetMasks)
            return entries;
        uint[] eligible;
        foreach (entry; entries)
            if (namedCreatureEffectFor(spell, first, entry) != noEffect)
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
        return effect != noEffect && namedCreatureEntries(spell, effect).length && !spellScript(spell.id)
            && (ms > 0 || (ms < 0 && permanentNamedCreatureVisual(spell.id)))
            && (namedChannelTriggerEffect(*spell) == noEffect || namedChannelCompletionSpell(spell) !is null)
            ? effect : noEffect;
    }

    /// A single terminal dummy hit with no spell script of its own can run where its creature is owned.
    private const(SpellInfo)* namedChannelCompletionSpell(const(SpellInfo)* spell)
    {
        import dmangos.world.dbscripts : DbScriptType;
        import dmangos.world.spellcast : duration;
        import dmangos.world.spelldamage : crystalPrisonCompletion, namedChannelTriggerEffect, namedCreatureShape;
        import dmangos.world.spellids : SpellEffect;

        const effect = namedChannelTriggerEffect(*spell);
        if (effect == noEffect || spell.casting.amplitude[effect] != duration(*spell, client, spell.spellLevel))
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

    /// A trap (game object `entry`) at `at` on `map` for `seconds`, its fuse lit for `fuseMs` (0: none); false if it
    /// could not be made.
    package bool placeFusedTrap(Map map, uint entry, Position at, uint seconds, uint fuseMs)
    {
        auto trap = summonWildGameObject(map, entry, at, seconds);
        if (trap is null)
            return false;
        if (fuseMs)
        {
            trap.restoreTimer = fuseMs;
            map.wake(trap.guid);
        }
        return true;
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
        {
            // A trap: its spell; a button (Celebras's staff): used.
            if (object.template_.type == GameObjectType.trap)
                return disturbEncounterTrap(map_, object);
            if (object.template_.type != GameObjectType.button)
                return false;
            usedBySpell(object, map_, casterGuid);
        }
        else if (spell.miscValue[effect] == GameObjectAction.open && !object.doorOrButton)
        {
            if (object.template_.type != GameObjectType.goober)
                return false;
            usedBySpell(object, map_, casterGuid); // a cage, an egg: used as a player uses it
        }
        else if (spell.miscValue[effect] == GameObjectAction.despawn)
            map_.removeObject(object.guid);
        else
        {
            if (!object.applySpellState(map_, cast(GameObjectAction) spell.miscValue[effect]))
                return false;
            map_.wake(object.guid);
        }
        return true;
    }

    /**
     * `object` used by a spell of `casterGuid`'s (a creature's open or disturb): what a player's use does but what is
     * the player's own (quest credit, page, the goober's spell on its user): its script, its use scripts, and a
     * button's or a goober's own use with its event.
     */
    private void usedBySpell(GameObject object, Map map_, ulong casterGuid)
    {
        import dmangos.world.dbscripts : DbScriptType;

        if (gameObjectUsed(object, map_, casterGuid))
            return;
        startScript(DbScriptType.goTemplateUse, object.spawn.entry, map_, casterGuid, object.guid);
        startScript(DbScriptType.goUse, object.spawn.guid, map_, casterGuid, object.guid);
        if (object.template_.type == GameObjectType.button)
            object.useDoorOrButton(map_);
        else
        {
            object.activateGoober(map_);
            if (const event = object.template_.data[2])
                scriptedEvent(event, map_, casterGuid, object.guid);
        }
        map_.wake(object.guid);
    }

    /// Cast a dungeon trap's spell at the trap. The egg creates a second proximity trap and each
    /// plague fissure casts its own short-range Eruption at its location on the floor.
    package bool disturbEncounterTrap(Map map_, GameObject object)
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
        bool retired; // omitted from checkpoints before committing the impact
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
            queueReplicaSpellImpact(ReplicaSpellImpact(due, hit, due + replicaImpactGrace));
        }
    }

    /// Move queued impacts with the caster. The deadlines use the shared node clock.
    package void writeReplicaImpacts(ulong caster, ref ByteWriter writer, bool departing = true)
    {
        import dmangos.serialization : serialize;

        const count = replicaImpactCount(caster);
        writer.put(count);
        if (!count)
            return;

        const now = clock();
        const transferTime = fleet.transportNow();
        foreach (ref impact; replicaSpellImpacts)
        {
            if (impact.retired || impact.hit.caster != caster)
                continue;
            writer.put(transferTime + cast(uint)(impact.due - now).total!"msecs");
            const waiting = impact.retryUntil != MonoTime.init;
            writer.put(waiting);
            if (waiting)
                writer.put(transferTime + cast(uint)(impact.retryUntil - now).total!"msecs");
            writer.put(impact.sentTo);
            serialize(writer, impact.hit);
            if (departing)
                impact.retired = true;
        }
    }

    package uint replicaImpactCount(ulong caster) const
    {
        uint count;
        foreach (ref impact; replicaSpellImpacts)
            if (!impact.retired && impact.hit.caster == caster)
                ++count;
        return count;
    }

    package bool discardReplicaImpacts(ulong caster)
    {
        bool discarded;
        foreach (ref impact; replicaSpellImpacts)
            if (!impact.retired && impact.hit.caster == caster)
            {
                impact.retired = true;
                discarded = true;
            }
        return discarded;
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
        const arrived = fleet.transportNow();
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
                queueReplicaSpellImpact(ReplicaSpellImpact(clock(), hit, MonoTime.init, hit.redirectOwner));
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
                    queueReplicaSpellImpact(ReplicaSpellImpact(clock() + (cast(int) time).msecs, hit));
                    return true;
                }
            }
        return sendReplicaSpellImpact(map_, peer, hit);
    }

    private void queueReplicaSpellImpact(ReplicaSpellImpact impact)
    {
        replicaSpellImpacts ~= impact;
        if (auto caster = onlinePlayer(impact.hit.caster))
            caster.checkpointSummons(true);
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
        import std.algorithm.mutation : SwapStrategy, remove;
        import dmangos.world.unit : UnitKind;

        const queued = replicaSpellImpacts.length;
        if (!queued)
            return;
        foreach (i; 0 .. queued)
        {
            auto impact = replicaSpellImpacts[i];
            if (impact.retired || impact.due > now)
                continue;
            auto map_ = existingMap(impact.hit.map, impact.hit.instance);
            auto caster = onlinePlayer(impact.hit.caster);
            bool retire()
            {
                replicaSpellImpacts[i].retired = true;
                if (caster is null || caster.checkpointSummons(true))
                    return true;
                replicaSpellImpacts[i].retired = false;
                replicaSpellImpacts[i].due = now + 1.seconds;
                return false;
            }
            if (map_ is null || !map_.unit(impact.hit.caster) || !canWrite()
                || (impact.retryUntil != MonoTime.init && impact.retryUntil <= now))
            {
                retire();
                continue;
            }
            const completion = impact.hit.channelOperation == AreaDamage.ChannelUpdate.complete;
            if (auto copy = cast(Replica) map_.findObject(impact.hit.target))
            {
                if (copy.owner != impact.sentTo)
                {
                    if (!retire())
                        continue;
                    if (sendReplicaSpellImpact(map_, copy.owner, impact.hit, !completion))
                    {
                        if (!completion)
                            continue;
                        impact.sentTo = copy.owner;
                    }
                    impact.retired = false;
                }
            }
            else
            {
                auto target = map_.unit(impact.hit.target);
                if (target && (target.kind != UnitKind.player || !target.session.transferring))
                {
                    if (retire())
                        applyAreaDamage(0, map_, impact.hit);
                    continue;
                }
                if (completion)
                    impact.sentTo = 0;
            }
            if (impact.retryUntil == MonoTime.init)
                impact.retryUntil = now + replicaImpactGrace;
            const retry = replicaSpellImpacts[i].retired;
            replicaSpellImpacts[i] = impact;
            if (retry && caster !is null)
                caster.checkpointSummons(true);
        }
        replicaSpellImpacts = replicaSpellImpacts.remove!(impact => impact.retired, SwapStrategy.stable);
    }

    bool delegate(ushort, const ref CreatureSwing) sendCreatureSwing;
    private ulong[ushort] lastCreatureSwing, lastCreatureSwingReply;

    package bool queueCreatureSwing(Creature attacker, UnitRef target, uint spell, int spellValue, float spellThreat,
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
        import dmangos.world.spellselection : inSpellCone, namedCreatureCenter, spellCone,
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
        const hostile = canAttack(attacker, victim.relating(), client,
            groups.sameGroup(message.caster, message.target));
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

            const named = message.namedCreature ? namedCreatureChannel(spell) : noEffect;
            const actorCanChannel = attacker.player ? !message.creatureCast : message.creatureCast && message.namedCreature;
            if (!actorCanChannel || message.triggered || message.creatureArea
                || (message.namedCreature ? named == noEffect : !isRemoteLeechChannel(*spell)))
                return;
            size_t targetEffect = noEffect;
            if (message.namedCreature)
            {
                if (victim.kind != UnitKind.creature || !spellScriptTargets(spell.id).canFind(victim.creature.spawn.entry))
                    return replyCreatureCast(peer, message, SpellMissInfo.evade);
                targetEffect = namedCreatureEffectFor(spell, named, victim.creature.spawn.entry);
                if (targetEffect == noEffect)
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
            if (shape == ImplicitTarget.enumUnitsScriptInCone60 && !inSpellCone(
                Position(message.x, message.y, message.z, message.facing), p, spellCone(data, spell.id)))
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
            if (shape == ImplicitTarget.enemiesInCone && !imported!"dmangos.world.spellselection".inSpellCone(origin,
                    victim.position, imported!"dmangos.world.spellselection".spellCone(data, spell.id)))
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
                namedChannelTriggerEffect(*spell), fleet.transportNow(), victim.map))
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
            // Only a caster still on the drained target's map takes the life (as a local drain's does).
            if (auto drainedOn = existingMap(message.map, message.instance))
                if (drainedOn is source.currentMap)
                {
                    const factor = spell.casting.multipleValue[i] > 0 ? spell.casting.multipleValue[i] : 1.0f;
                    spellHeal(caster, spell, caster.unit, cast(int)(message.drained
                        * caster.spellMod(SpellModOp.multipleValue, spell, factor)), SpellHeal(true));
                }
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
            // Like the life drain above: only a caster still on the drained target's map takes the power.
            auto drainedFrom = existingMap(message.map, message.instance);
            if (drainedFrom !is null && drainedFrom is source.currentMap
                && spell.miscValue[i] >= 0 && spell.miscValue[i] <= Power.happiness)
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

    /// A database script's quest credit for a player another node simulates (`ScriptQuestCredit`).
    void delegate(ushort node, const ref imported!"dmangos.cluster.protocol".ScriptQuestCredit credit)
        scriptQuestCreditElsewhere;
    private MonoTime nextScriptCreditPoll;

    /// The message speeds up delivery. The realm's character database keeps the credit until its owner applies it.
    package void scriptQuestCreditArrived(const ref imported!"dmangos.cluster.protocol".ScriptQuestCredit credit)
    {
        auto player = onlinePlayer(credit.player);
        if (player is null || player.player is null || player.transferring || !canWrite())
            return;
        applyScriptCredit(player, credit);
    }

    private void pollScriptCredits(MonoTime now)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!online.length || now < nextScriptCreditPoll || !canWrite())
            return;
        nextScriptCreditPoll = now + 1.seconds;
        try
        {
            foreach (ref credit; database.pendingScriptQuestCredits(config.realmId))
                scriptQuestCreditArrived(credit);
        }
        catch (DatabaseException error)
            warning!"could not deliver a script quest credit: %s"(error.msg);
    }

    private void applyScriptCredit(Character player, const ref imported!"dmangos.cluster.protocol".ScriptQuestCredit credit)
    {
        import dmangos.cluster.protocol : ScriptQuestCredit;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.dbscripts : ScriptQuestEffect;
        import dmangos.world.quests : QuestStatus;

        if (player.savedUnread)
            return;
        alias Kind = ScriptQuestEffect.Kind;
        const kind = credit.kind == ScriptQuestCredit.Kind.explored ? Kind.explored
            : credit.kind == ScriptQuestCredit.Kind.failed ? Kind.failed : Kind.kill;
        auto effect = ScriptQuestEffect(player, kind, credit.quest, credit.rewarder);
        QuestStatus[uint] proposed;
        effect.apply(&proposed);
        player.saveQuests();
        if (!settleWrites())
            return;
        try
        {
            if (!database.consumeScriptQuestCredit(config.realmId, credit, proposed.values))
                return;
        }
        catch (DatabaseException error)
        {
            // A lost reply may hide a successful payment. Re-read the durable quest log on login.
            player.connection.kick("lost the connection while saving quest credit");
            throw error;
        }
        effect.apply();
        player.flushPlayerChanges();
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
            foreach (peer, ref known; remoteByNode)
                if (peer != node)
                    known.remove(e.guid);
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
    package long startUnixMillis; /// the same, to the millisecond (ships' schedules)
    package MonoTime startClock;

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


    /// Lines written to the GM command log (tests read them; the file gets them too).
    string[] gmLogLines;

    ///
    this(WorldConfig config, WorldDatabase database, WorldData data, ClientData client,
        LoginDatabase accounts = null, Battlegroup sharedBattles = null)
    in (database !is null && data !is null && client !is null)
    {
        fleet = new Ships(this);
        postOffice = new PostOffice(this);
        dungeons = new Dungeons(this);
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

            transportClockSource = &fleet.transportNow;
        }
        this.next = database.highestGuids();
        this.groups = new Groups(database, this, next.group, config.battlegroup.length ? config.realmId : 0);
        groupService = new GroupService(this);
        respawnAt = database.loadCreatureRespawns();
        creaturePools = new CreaturePools(() => this.database, config.realmId, data, respawnAt);
        gameObjectRespawnAt = database.loadGameObjectRespawns();
        gameObjectPools = new GameObjectPools(() => this.database, config.realmId, data, gameObjectRespawnAt,
            config.cluster.enabled);
        groups.load(database.loadGroups());
        guilds = new Guilds;
        guilds.load(database.loadGuilds());
        scripts = ScriptRuntime.of!scriptModules();
        reportScripts();
        signalSequence = ulong(startUnixTime) << 20; // above what an earlier run of this node sent
        dungeons.loadInstances();
        if (config.cluster.enabled && !config.cluster.gateway)
            readOutdoorWorldStates();
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
        weather = ZoneWeather(this);
        services.listen!(WeatherHost, WeatherNotice)(&weather.heard);
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
    package const(CreatureSpawn)* creatureSpawnOf(uint guid)
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
    package void linkedEvent(Map m, Creature source, LinkEvent event, ulong enemy)
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

    /// A dead creature of dungeon copy `m` (its corpse `corpse`, or none: gone already) is back
    /// now, as a linked boss's wipe brings its adds back; the copy's script hears of it as of any creature.
    package void respawnInCopy(Map m, const(CreatureSpawn)* spawn, Creature corpse)
    {
        if (corpse !is null && m.findObject(corpse.guid) is corpse)
            m.corpseExpired(corpse);
        if (auto state = m.instanceId in dungeons.instances)
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
                                if (auto state = master.instanceId in dungeons.instances)
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
    package void queueLinked(uint mapId, uint instance, Creature c)
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
    package bool cantSpawnWhileBossDead(const ref CreatureSpawn spawn, const(dungeons.InstanceState)* state)
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
        if (const link = slave.spawnId in data.creatureLinks.bySlaveGuid)
            if (link.hasOffset && link.masterGuid == master.spawnId)
            {
                slave.generator = new FollowMovement(master.guid, link.distance, link.angle);
                m.wake(slave.guid);
                return;
            }
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
        if (kind == PoolMember.Kind.gameObject && gameObjectPools.manages(guid))
            return gameObjectPools.selected(guid);
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
        postOffice.postMail(mail, 0);
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
                                    || !dungeons.groupSpawnAllowed(m, 0, spawn.guid) || !upInPool(PoolMember.Kind.creature, spawn.guid))
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
        foreach (m; dungeons.instanceMaps.values)
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

    package bool mapConditionMet(Map where, uint id)
    {
        import dmangos.world.conditions : ConditionSubject;

        ConditionSubject subject;
        subject.worldCondition = &conditionWorldScript;
        subject.worldState = (uint state) => conditionMapWorldState(where, state);
        subject.completedEncounter = (uint encounter) => conditionEncounterCompleted(where, encounter);
        if (auto instance = instanceScript(where.instanceId))
            subject.instanceCondition = &instance.condition;
        return data.npcs.conditions.satisfied(id, subject, client);
    }

    private int[uint][uint] outdoorWorldStates;
    private MonoTime nextOutdoorWorldStatePoll;

    private void readOutdoorWorldStates()
    {
        int[uint][uint] current;
        foreach (ref state; database.loadOutdoorWorldStates(config.realmId))
            current[state.map][state.id] = state.value;
        outdoorWorldStates = current;
    }

    package int conditionMapWorldState(Map where, uint id)
    {
        if (auto value = id in where.scriptedWorldStates)
            return *value;
        if (!where.instanceId)
            if (const value = id in outdoorWorldStates.get(where.id, null))
                return *value;
        if (auto copy = battlegrounds.find(where.instanceId))
            if (copy.mapId == where.id)
                return cast(int) copy.worldStates.get(id, 0);
        if (where.instanceId)
        {
            if (where.id == 70 && id == 700001)
            {
                if (!data.annoraScorpidSpawns.length)
                    return 0;
                foreach (guid; data.annoraScorpidSpawns)
                    if (!dungeons.deadInInstance(where.instanceId, guid))
                        return 0;
                return 1;
            }
            if (const states = where.id in data.encounterCreatureByWorldState)
                if (const boss = id in *states)
                    return dungeons.entryKilledInInstance(where.instanceId, *boss);
        }
        return conditionRealmState(id);
    }

    bool worldStateExpressionMet(Map world, uint expression)
    {
        auto where = world;
        if (where is null)
            return false;
        const now = unixTime;
        // Map-wide random expressions give the same result to every worker evaluating the same second.
        const seed = cast(uint) now ^ (where.id * 31) ^ where.instanceId ^ (expression * 16777619u);
        return data.worldStateExpressions.matches(expression, id => conditionMapWorldState(where, id),
            &gameEvents.holidayActive, now, seed);
    }

    package bool conditionEncounterCompleted(Map where, uint id)
    {
        if (where.instanceId)
            if (const encounters = where.id in data.encounterCreatureById)
                if (const boss = id in *encounters)
                    return dungeons.entryKilledInInstance(where.instanceId, *boss);
        return false;
    }

    package int conditionRealmState(uint id)
    {
        import dmangos.world.scourge : invasionZones;
        import dmangos.world.wareffort : resources, worldStateDaysLeft;

        if (id == worldStateDaysLeft)
            return cast(int) warEffort.daysLeft(unixTime);
        foreach (i, ref resource; resources)
        {
            if (resource.nowState == id)
                return cast(int) warEffort.counters[i];
            if (resource.goalState == id)
                return cast(int) resource.goal;
        }
        foreach (i, ref zone; invasionZones)
        {
            if (zone.marker == id)
                return invasion.remaining(i) != 0;
            if (zone.remaining == id)
                return cast(int) invasion.remaining(i);
        }
        return 0;
    }

    package bool conditionWorldScript(uint id, uint expected)
    {
        import dmangos.world.scourge : invasionZones;
        import dmangos.world.wareffort : resources, worldStateDaysLeft;

        if (id == worldStateDaysLeft)
            return warEffort.daysLeft(unixTime) == expected;
        foreach (i, ref resource; resources)
            if (resource.nowState == id)
                return warEffort.counters[i] >= resource.goal;
        foreach (i, ref zone; invasionZones)
            if (zone.marker == id)
                return invasion.remaining(i) != 0;
        return false;
    }

    /// The war effort: what quest `quest` asked for counts as `resource` (`dmangos.world.wareffort`): the quest's
    /// first required items, for the service to count.
    void warEffortHandIn(uint quest, uint resource)
    {
        import dmangos.world.wareffort : AqResource, resourceCount, WarEffortContribution;

        const q = data.quests.quest(quest);
        if (q is null || resource >= resourceCount)
            return;
        services.call!(WarEffortHost.contribute)(WarEffortContribution(cast(AqResource) resource, q.reqItemCount[0]));
    }

    /// The war effort: a Colossus of Silithus fell (`Colossus`).
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
        dungeons.instances.remove(instance);
        dungeons.dropInstanceMap(instance);
    }

    /// The channels, if this node hosts them (standalone it does); null if another node does.
    @property ChannelService channelService()
    {
        if (auto host = services.local!ChannelsHost())
            return host.channels;
        return null;
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
        if (auto found = instance in dungeons.instanceMaps)
            return *found;
        if (instance !in dungeons.instances)
            dungeons.instances[instance] = dungeons.InstanceState(id, 0, unixTime);
        auto created = dungeons.instanceMaps[instance] = makeMap(id, instance);
        if (!dungeons.copyArriving)
        {
            restoreInstanceCorpses(created);
            if (ownsDungeonFights(created))
                restoreDungeonFights(created, false);
        }
        return created;
    }

    /// The map `who` is on.
    Map mapOf(const OnlinePlayer who)
    {
        return map(who.character.data.map, who.instanceId);
    }

    /// Spell `spell` teleports player `guid` to its `spell_target_position` (a creature's cast: a boss's room).
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
            owns = (ulong cell) => ownsCell(id, cell) && !recoveryHolds(id, cell);
        else if (config.cluster.enabled)
            owns = (ulong cell) => !recoveryHolds(id, cell);
        MapObject[] delegate(uint, ulong) spawner = &spawnCell;
        if (instance)
            spawner = (uint m, ulong cell) => dungeons.spawnCellIn(m, instance, cell);
        auto mapTerrain = terrain(id);
        auto created = new Map(id, MapSettings(config.visibilityDistance, config.visibilityRelocationLimit,
            config.gridCleanUpDelay * 1000),
            &serverTime, spawner, mapTerrain, owns, gameObjectModels is null ? null :
                new GameObjectCollision(gameObjectModels, client, &fleet.transportNow));
        created.instanceId = instance;
        created.questSpawnPhases = data.questSpawnPhases;
        created.gameObjectTemplate = (uint entry) => entry in data.gameObjectTemplates;
        created.elevatorPath = &fleet.elevatorPathOf;
        created.elevatorClock = &fleet.transportNow;
        created.elevatorHomes = fleet.elevatorHomesFor(id);
        if (instance == 0) // a dungeon's copies are all on one node: nobody else needs replicas of them
            created.replicator = replicator;
        created.world = this; // what happens beyond the map is this world's, called from the map where it happens
        created.visibilityFacts = (ulong viewer, ulong seen, Position seenAt) => visibilityFacts(created, viewer,
            seen, seenAt);
        if (instance)
            if (const name = id in data.instanceScriptNames)
            {
                auto state = instance in dungeons.instances;
                auto script = InstanceScript.make(scripts, *name, instance, id, state is null ? null : state.data,
                    (string saved, bool checkpoint) {
                        const durable = checkpoint && config.cluster.enabled && dungeons.hostsDungeon(id) && canWrite();
                        // The gateway picks the recovery map from the saved character's position. The quest credit
                        // the script gave (Ysida saved, "Dead Man's Plea" done) is kept with the checkpoint that
                        // records it, or a crash would leave the encounter done and the credit lost for the lockout.
                        if (durable)
                            foreach (who; created.playersNow())
                                if (auto session = cast(Character) who)
                                {
                                    if (!session.savedUnread)
                                        session.saveQuests();
                                    const progress = who.character.progress(session.secondsInWorld());
                                    database.saveProgress(progress);
                                }
                        if (auto st = instance in dungeons.instances)
                            st.data = saved;
                        database.saveInstanceData(instance, saved);
                        if (durable && settleWrites())
                        {
                            import dmangos.log : info;

                            info!"instance %s of map %s saved an encounter checkpoint"(instance, id);
                        }
                    }, (MigrantKind kind, uint guid) {
                        if (kind == MigrantKind.gameObject)
                        {
                            const spawn = gameObjectSpawnOf(guid);
                            return spawn is null || spawn.map != id ? EntityRef.init
                                : EntityRef(makeGuid(HighGuid.gameObject, spawn.entry, guid));
                        }
                        const spawn = creatureSpawnOf(guid);
                        return spawn is null || spawn.map != id || dungeons.deadInInstance(instance, guid) ? EntityRef.init
                            : EntityRef(makeGuid(HighGuid.unit, spawn.entry, guid));
                    }, (uint guid) => dungeons.deadInInstance(instance, guid));
                if (script !is null)
                {
                    script.map = created;
                    script.lore = this;
                    script.spawnObjects = &spawnDungeonObjects;
                    script.captureSummon = (EntityRef ref_) {
                        auto object = created.findObject(ref_.guid);
                        if (auto creature = cast(Creature) object)
                        {
                            if (!creature.alive || creature.petOwner || creature.meleeController)
                                return Migrant.init;
                            auto migrant = saveMigratingObject(creature, false);
                            migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
                            return migrant;
                        }
                        if (auto go = cast(GameObject) object)
                        {
                            const expires = scriptedGameObjects.get(GameObjectOnMap(created, go.guid), 0L);
                            auto migrant = saveMigratingObject(go, false, expiresOverride: expires);
                            migrant.home = cellKeyAt(go.spawn.x, go.spawn.y);
                            return migrant;
                        }
                        return Migrant.init;
                    };
                    script.restoreSummon = (const ref Migrant migrant) {
                        import dmangos.log : warning;

                        try
                        {
                            auto object = restoreWorldMigrant(migrant, created);
                            if (object !is null && !config.cluster.enabled && migrant.spawn >= temporaryCounterStart)
                            {
                                import std.algorithm.comparison : max;

                                summonsMade = max(summonsMade, migrant.spawn - temporaryCounterStart);
                            }
                            return object;
                        }
                        catch (Exception error)
                        {
                            warning!"instance %s: could not restore encounter summon %s: %s"(instance,
                                migrant.spawn, error.msg);
                            return cast(MapObject) null;
                        }
                    };
                    script.captureScriptRuns = (const(uint)[] selected) {
                        ByteWriter work;
                        saveDungeonScriptRuns(id, work, false, instance, selected);
                        return work.data;
                    };
                    script.restoreScriptRuns = (const(ubyte)[] saved) {
                        auto work = ByteReader(saved);
                        restoreDungeonScriptRuns(id, work, true);
                    };
                    script.startDatabaseEvent = (uint event, EntityRef source, EntityRef target) {
                        startScript(imported!"dmangos.world.dbscripts".DbScriptType.event, event,
                            created, source.guid, target.guid);
                    };
                    script.entryKilled = &dungeons.entryKilledInInstance;
                    script.spawnKilled = (uint copy, ulong guid) => dungeons.deadInInstance(copy, cast(uint)(guid & 0xFF_FFFF));
                    script.respawnKilled = &dungeons.respawnKilledInCopy;
                    script.signalObject = &gameObjectSignalled;
                    script.respawnObjectOf = &respawnObjectOfEntry;
                    script.summonObjectAt = &summonGameObjectAt;
                    instanceScripts[instance] = script;
                    if (!dungeons.copyArriving) // a copy from another node brings its creatures: their fights go on
                        script.restored();
                }
            }
        if (instance == 0) // the continent's script (`world_template`)
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
            foreach (ref ship; fleet.ships)
                if (ship.map == id)
                    created.addEverywhere(ship.object);
        return created;
    }

    // -----------------------------------------------------------------------
    // What a map tells its world of (`Map.world`): each called by the map where it happens.
    // -----------------------------------------------------------------------

    /// The group player `player` is in (0: none), for what a `PerViewer` shows it.
    package uint groupIdOf(ulong player)
    {
        auto group = groups.of(player);
        return group is null ? 0 : group.id;
    }

    /**
     * Whether `object` keeps its cell of `map` loaded with nobody near: in a dungeon, a game object its script keeps
     * in its checkpoint; outdoors on a clustered server, a quest's actor that lasts (a timed summon, one whose
     * faction a quest changed) or its game object.
     */
    package bool keepsIdleObjectLoaded(Map map, MapObject object)
    {
        if (map.instanceId)
        {
            auto script = map.instanceId in instanceScripts;
            return script !is null && cast(GameObject) object !is null
                && script.keepsCheckpoint(EntityRef(object.guid));
        }
        if (!config.cluster.enabled || object.guid !in outdoorQuestActors)
            return false;
        if (auto creature = cast(Creature) object)
            return creature.alive && (creature.summon.timed || hasOutdoorFactionChange(creature));
        return (cast(GameObject) object) !is null;
    }

    /// A freshly spawned object became `map`'s own (loaded with its cell or put there by a script): a scripted game
    /// object's `Spawned` is raised in the world's phase.
    package void objectArrived(Map map, MapObject object)
    {
        if (auto go = cast(GameObject) object)
            if (go.behaviour && scripts.handles!(imported!"dmangos.script.api".Spawned)(go.behaviour))
                objectArrivals ~= GameObjectArrival(go, map);
    }

    /// An object left `map` for good (gone, or handed to another node) after its state was saved: what the world
    /// held of it goes.
    package void objectLeft(Map map, MapObject object)
    {
        if (auto creature = cast(Creature) object)
            ownedSummonGone(map, creature);
        else if (auto trap = cast(GameObject) object)
            if (trap.type == GameObjectType.trap && trap.owner)
                if (auto session = onlinePlayer(trap.owner))
                    if (session.currentMap is map)
                        session.checkpointSummons(true, trap.guid);
        objectGone(map, object);
    }

    /// A creature of `map` died of something no player is credited with: it dies, and its death is queued for the
    /// deaths phase.
    package void creatureDies(Map map, Creature c)
    {
        linkedDeath(map, c); // its pack's part first, while it is still known
        c.die(map, unixTime);
        if (const checkpoint = c.guid in outdoorQuestActors)
            if (!checkpoint.player)
                discardQuestActor(c);
        ownedSummonGone(map, c);
        map.creatureDeaths.put(c);
        battlegroundCreatureKilled(map, c.template_.entry, 0);
    }

    /// A creature of `map` was hurt and lives: its fight is kept for a crash (a clustered server's).
    package void checkpointCreatureFight(Map map, Creature creature)
    {
        if (!config.cluster.enabled)
            return;
        if (!map.instanceId)
            checkpointOutdoorFight(creature);
        else if (!battlegroundOfMap(map.id))
            checkpointDungeonFight(map, creature);
    }

    /// A quest's actor on `map` did something its script's state follows: kept for a crash (outdoors, clustered).
    package void questActorChanged(Map map, Creature creature, ulong player, bool immediate)
    {
        if (!map.instanceId && config.cluster.enabled)
            checkpointQuestActor(map, creature, player, immediate);
    }

    /// Whether a creature of `map` may ask another node's creatures for help, and send its swings to a target there
    /// (the open world of a clustered server).
    package bool lendsCreatures(const Map map) const
    {
        return !map.instanceId && sendCreatureLoan !is null;
    }

    package bool swingsRemotely(const Map map) const /// ditto
    {
        return !map.instanceId && sendCreatureSwing !is null;
    }

    /// A creature of `map` reached a waypoint with a script: the script starts, the creature its source and target.
    package void waypointScript(Map map, Creature creature, uint scriptId)
    {
        import dmangos.world.dbscripts : DbScriptType;

        startScript(DbScriptType.creatureMovement, scriptId, map, creature.guid, creature.guid);
    }

    /// A player was put on `map`: its dungeon's script hears of it, and the rolls under way on what lies there are
    /// the player's to join again.
    package void playerAdded(Map map, Inhabitant who)
    {
        import dmangos.script.api : PlayerEntered;

        const instance = map.instanceId, id = map.id;
        if (!instance && !config.cluster.enabled)
            return;
        auto created = map;
        if (auto s = instance in instanceScripts)
            s.raise(PlayerEntered(EntityRef(who.character.guid)));
        if (const state = instance in dungeons.instances)
            if (state.corpses.length || state.chests.length)
                created.forEachObject((MapObject object) {
                    if (auto corpse = cast(Creature) object)
                        if (corpse.loot !is null && corpse.spawn.guid in state.corpses)
                            corpse.loot.resumeRollsFor(who.character.guid);
                    if (auto chest = cast(GameObject) object)
                        if (chest.loot !is null && chest.spawn.guid in state.chests)
                            chest.loot.resumeRollsFor(who.character.guid);
                });
        if (!instance)
        {
            foreach (ref corpse; outdoorCorpses.byValue)
            {
                const spawn = outdoorCorpseSpawn(corpse);
                if (spawn.guid && spawn.map == id)
                    if (auto creature = created.creatureAt(loanGuid(&spawn)))
                        if (creature.loot !is null)
                            creature.loot.resumeRollsFor(who.character.guid);
            }
            foreach (guid; outdoorChests.byKey)
                if (const index = guid in gameObjectSpawnIndex)
                {
                    const spawn = &data.gameObjectSpawns[*index];
                    if (spawn.map == id)
                        if (auto chest = created.gameObjectAt(makeGuid(HighGuid.gameObject, spawn.entry, guid)))
                            if (chest.loot !is null)
                                chest.loot.resumeRollsFor(who.character.guid);
                }
        }
    }

    /// Per-viewer faction for an opposite-faction party member. The authoritative faction never changes.
    package uint groupViewerFaction(ulong target, const ref UpdateValues fields, const Player viewer) const
    {
        import dmangos.world.updatefields : UNIT_FIELD_BYTES_0, UNIT_FIELD_FACTIONTEMPLATE;

        if (!config.allowTwoSideInteractionGroup
            || client.teamForRace(fields.getByte!UNIT_FIELD_BYTES_0(0)) == client.teamForRace(viewer.data.race)
            || !groups.sameGroup(target, viewer.guid))
            return 0;
        return viewer.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    }

    package bool battlegroundPaused(Map map)
    {
        if (map.instanceId)
            if (auto copy = battlegrounds.find(map.instanceId))
                return copy.mapId == map.id && copy.paused;
        return false;
    }

    /// Battleground objectives use the player credited with the killing blow, independently of the loot tap.
    package void battlegroundCreatureKilled(Map map, uint entry, ulong killer)
    {
        if (map.instanceId)
            if (auto copy = battlegrounds.find(map.instanceId))
                if (copy.mapId == map.id && !copy.paused)
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
        return instance ? dungeons.instanceMaps.get(instance, null) : existingMap(id);
    }


    /// An object left its map for good (`objectLeft`): its script's state goes.
    package void objectGone(Map map, MapObject object)
    {
        if (auto creature = cast(Creature) object)
        {
            discardQuestActor(creature);
            creature.ai.releaseBehaviour();
        }
        else if (auto go = cast(GameObject) object)
        {
            const checkpoint = go.guid in outdoorQuestActors;
            if (checkpoint !is null && canWrite()
                && (ownsCell is null || ownsCell(go.spawn.map, checkpoint.home)))
            {
                outdoorQuestActors.remove(go.guid);
                if (go.type == GameObjectType.chest)
                {
                    outdoorChests.remove(go.spawn.guid);
                    database.finishScriptedOutdoorChest(config.realmId, go.guid, go.spawn.guid);
                }
                else
                    database.deleteQuestActor(config.realmId, go.guid);
                settleWrites();
            }
            auto key = GameObjectOnMap(map, go.guid);
            tickingObjects.remove(key);
            scriptedGameObjects.remove(key);
            scripts.destroy(go.behaviour);
        }
    }

    private void ownedSummonGone(Map map, Creature creature)
    {
        const owner = creature.totemOwner ? creature.totemOwner : creature.guardianOwner;
        if (owner)
            if (auto session = onlinePlayer(owner))
                if (session.currentMap is map)
                    session.checkpointSummons(true, creature.guid);
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
    const(dungeons.InstanceState)* instanceState(uint id) const
    {
        return id in dungeons.instances;
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
        return maps.values ~ dungeons.instanceMaps.values;
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
        forgetQuestActors(lost);
        foreach (ref r; lost)
            pendingRegionRecovery.remove(r.id);

        // Retire a returned creature before handing over any newly revoked physical home region.
        foreach (ref r; lost)
            if (r.creature.spawn)
                creatureLoanLost(r);

        foreach (ref r; lost)
            if (dungeons.instanceable(r.map) || physicalWorldRegion(r))
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
            if (dungeons.instanceable(r.map))
            {
                if (r.next)
                    leaving[r.id] = cast(ubyte[]) dungeons.dungeonCopiesOut(r.map, r.next);
                dungeons.dungeonLost(r.map);
            }
        foreach (ref r; gained)
            if (dungeons.instanceable(r.map))
            {
                dungeons.dungeonGained(r.map);
                if (auto copies = r.id in arriving)
                    dungeons.dungeonCopiesIn(r.map, *copies);
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
        bool recoveryRead = refreshRegionRespawns(gained, arriving);
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
        recoveryRead &= refreshOutdoorCorpses(gained, lost);
        recoveryRead &= refreshOutdoorChests(gained, lost);
        if (!recoveryRead)
            holdRegionRecovery(gained, arriving);
        queueQuestActorRecovery(gained, arriving);
        restoreOutdoorScripts(gained);
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
        return !region.creature.spawn && client.maps.lookup(region.map) !is null && !dungeons.instanceable(region.map);
    }

    private bool outdoorRegionCovers(Spawn)(const(Spawn)* spawn, const(Region)[] regions)
    {
        import std.algorithm.searching : any;

        return regions.any!(r => physicalWorldRegion(r) && r.map == spawn.map
            && r.rect.containsKey(cellKeyAt(spawn.x, spawn.y)));
    }

    private QuestActorCheckpoint[ulong] outdoorQuestActors;
    private struct QuestActorRegionGrant
    {
        Region region;
        bool clean;
    }
    private QuestActorRegionGrant[uint] pendingQuestActorRegions;
    private long retryQuestActorRecoveryAt;

    /// A gained region whose corpses, chests or respawn timers could not be read yet (`retryRegionRecovery`).
    private struct RegionRecovery
    {
        Region region;
        bool clean; // its bundle arrived: only the database's corpses and chests are still to read
    }
    private RegionRecovery[uint] pendingRegionRecovery;
    private long retryRegionRecoveryAt;

    /**
     * Whether a gained cell waits for its region's recovery reads before it loads. Loaded first, the cell would
     * spawn afresh what the database still holds: an opened chest with new loot, a dead creature alive, an
     * escort's NPC without its escort (which the quest-actor recovery would then take for the escort's own).
     */
    private bool recoveryHolds(uint map, ulong cell) const
    {
        foreach (const ref pending; pendingRegionRecovery)
            if (pending.region.map == map && pending.region.rect.containsKey(cell))
                return true;
        foreach (const ref grant; pendingQuestActorRegions)
            if (!grant.clean && grant.region.map == map && grant.region.rect.containsKey(cell))
                return true;
        return false;
    }

    private void holdRegionRecovery(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        import dmangos.log : warning;

        foreach (ref region; gained)
            if (physicalWorldRegion(region))
                pendingRegionRecovery[region.id] = RegionRecovery(region, arriving.get(region.id, null).length != 0);
        retryRegionRecoveryAt = unixTime + 1;
        warning!"migration: %s gained region(s) wait to load until their corpses, chests and respawn timers are read"(
            pendingRegionRecovery.length);
    }

    /// Reads again what a gained region's recovery could not (`holdRegionRecovery`), then loads its cells.
    private void retryRegionRecovery()
    {
        import dmangos.log : info;

        if (!pendingRegionRecovery.length || unixTime < retryRegionRecoveryAt)
            return;
        Region[] all, cold;
        foreach (ref pending; pendingRegionRecovery)
        {
            all ~= pending.region;
            if (!pending.clean)
                cold ~= pending.region;
        }
        if (!syncColdRespawns(cold) || !refreshOutdoorCorpses(all, null) || !refreshOutdoorChests(all, null))
        {
            retryRegionRecoveryAt = unixTime + 1;
            return;
        }
        pendingRegionRecovery = null;
        info!"migration: %s gained region(s) read their corpses, chests and respawn timers and load now"(all.length);
        loadHeldCells(all);
    }

    /// Loads, near players and peers, the cells of `regions` that waited for their recovery.
    private void loadHeldCells(const(Region)[] regions)
    {
        bool[uint] looked;
        foreach (ref r; regions)
            if (r.map !in looked) // cells another recovery still holds stay as they are (`recoveryHolds`)
            {
                looked[r.map] = true;
                if (auto m = r.map in maps)
                    m.ownershipGained();
            }
    }

    private bool ownsQuestActor(const Creature creature)
    {
        return canWrite() && !creature.instanceId && !creatureOnLoan(creature.spawn.guid)
            && (ownsCell is null || ownsCell(creature.spawn.map, cellKeyAt(creature.spawn.x, creature.spawn.y)));
    }

    private void discardQuestActor(const Creature creature)
    {
        if (const actor = creature.guid in outdoorQuestActors)
            if (ownsQuestActor(creature))
            {
                const owner = actor.player;
                if (auto player = onlinePlayer(owner))
                    player.saveQuests();
                outdoorQuestActors.remove(creature.guid);
                database.deleteQuestActor(config.realmId, creature.guid);
                if (!owner)
                    settleWrites();
            }
    }

    private void checkpointQuestActor(Map map, Creature creature, ulong player, bool immediate)
    {
        import dmangos.world.instancescripting : toHex;

        if (!creature.alive)
            return discardQuestActor(creature);
        if (!ownsQuestActor(creature))
            return;
        const previous = outdoorQuestActors.get(creature.guid, QuestActorCheckpoint.init);
        if (!player)
        {
            if (previous.player)
            {
                if (creature.summon.type != TempSpawnType.none || hasOutdoorFactionChange(creature))
                    checkpointOutdoorCreature(creature);
                else
                    discardQuestActor(creature);
            }
            return;
        }
        if (!immediate && previous.player == player && previous.savedAt + 2 > unixTime)
            return;
        auto root = saveMigratingObject(creature, false);
        root.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        Migrant[] actors = [root];
        foreach (child; map.creaturesNear(creature.position, 150))
            if (child.alive && child.summon.summoner == creature.guid && ownsQuestActor(child))
            {
                auto snapshot = saveMigratingObject(child, false);
                snapshot.home = cellKeyAt(child.spawn.x, child.spawn.y);
                actors ~= snapshot;
            }
        if (auto session = onlinePlayer(player))
            if (session.character !is null && session.currentMap is map && !session.transferring)
            {
                session.saveQuests();
                const progress = session.character.progress(session.secondsInWorld());
                database.saveProgress(progress);
            }
        const state = QuestActorCheckpoint(map.id, creature.guid, root.home, player, unixTime,
            toHex(encodeBundle(null, actors)));
        outdoorQuestActors[creature.guid] = state;
        database.saveQuestActor(config.realmId, state);
    }

    private void checkpointOutdoorFight(Creature creature)
    {
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

        if (creature.spawn.guid >= temporaryCounterStart || creature.summon.type != TempSpawnType.none
            || creature.ai is null || !creature.alive || !ownsQuestActor(creature) || controlledByPlayer(creature))
            return; // (held by a player: as `checkpointDungeonFight`)
        const saved = creature.guid in outdoorQuestActors;
        if (saved !is null && saved.player)
            return; // the active escort or follower also owns this creature's checkpoint
        if ((saved is null || !hasOutdoorFactionChange(creature)) && !creature.ai.inCombat
            && creature.values.get!UNIT_FIELD_HEALTH >= creature.values.get!UNIT_FIELD_MAXHEALTH)
            return discardQuestActor(creature);
        if (saved is null || saved.savedAt + 2 <= unixTime)
            checkpointOutdoorCreature(creature);
    }

    /// Whether a player charms or possesses `creature` (Mind Control, the Orb of Domination's Razorgore).
    private static bool controlledByPlayer(const Creature creature)
    {
        import dmangos.world.updatefields : UNIT_FIELD_CHARMEDBY;

        return creature.petOwner || creature.meleeController || creature.values.get!UNIT_FIELD_CHARMEDBY != 0;
    }

    private static bool hasOutdoorFactionChange(const Creature creature)
    {
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

        return creature.summon.type == TempSpawnType.none
            && creature.values.get!UNIT_FIELD_FACTIONTEMPLATE != creature.template_.faction;
    }

    private struct ActiveDungeonFight
    {
        ulong guid;
        long savedAt;
    }
    package ActiveDungeonFight[uint][uint] dungeonFights;
    package bool[uint] pendingDungeonFights; // whether the map already has its live handoff bundle
    private long retryDungeonFightsAt;

    package bool ownsDungeonFights(Map where)
    {
        return config.cluster.enabled && where.instanceId && !battlegroundOfMap(where.id)
            && canWrite() && dungeons.hostsDungeon(where.id);
    }

    private void checkpointDungeonFight(Map where, Creature creature)
    {
        import dmangos.world.instancescripting : toHex;
        import dmangos.world.updatefields : UNIT_FIELD_HEALTH, UNIT_FIELD_MAXHEALTH;

        const spawn = creature.spawn.guid, instance = where.instanceId;
        if (!ownsDungeonFights(where) || spawn >= temporaryCounterStart || creature.summon.type != TempSpawnType.none
            || creature.ai is null || !creature.alive)
            return;
        // Held by a player (charmed, possessed): its state now is the player's faction, flags and charm aura, which a
        // restore would bring back with no one holding it. Its last snapshot from before stays.
        if (controlledByPlayer(creature))
            return;
        const current = dungeonFights.get(instance, null);
        const tracked = spawn in current;
        if (auto script = instanceScripts.get(instance, null))
            if (script.keepsCheckpoint(EntityRef(creature.guid)))
            {
                if (tracked !is null)
                    discardDungeonFight(instance, spawn);
                return; // the encounter supplies the creature and its phase together
            }
        if (!creature.ai.inCombat && creature.values.get!UNIT_FIELD_HEALTH >= creature.values.get!UNIT_FIELD_MAXHEALTH)
        {
            if (tracked !is null)
                discardDungeonFight(instance, spawn);
            return;
        }
        if (tracked !is null && tracked.savedAt + 2 > unixTime)
            return;
        auto migrant = saveMigratingObject(creature, false);
        migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        dungeonFights[instance][spawn] = ActiveDungeonFight(creature.guid, unixTime);
        database.saveDungeonFight(instance, DungeonFightCheckpoint(spawn, toHex(encodeBundle(null, [migrant]))));
        if (tracked is null)
        {
            foreach (who; where.playersNow())
                if (auto session = cast(Character) who)
                {
                    const progress = who.character.progress(session.secondsInWorld());
                    database.saveProgress(progress);
                }
            settleWrites();
        }
    }

    private void discardDungeonFight(uint instance, uint spawn)
    {
        if (auto fights = instance in dungeonFights)
            if ((*fights).remove(spawn))
                database.deleteDungeonFight(instance, spawn);
    }

    package void restoreDungeonFights(Map where, bool clean)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.instancescripting : fromHex;

        const instance = where.instanceId;
        DungeonFightCheckpoint[] records;
        try
            records = database.loadDungeonFights(instance);
        catch (DatabaseException error)
        {
            warning!"instance %s: could not read native fights: %s"(instance, error.msg);
            pendingDungeonFights[instance] = clean;
            retryDungeonFightsAt = unixTime + 1;
            return;
        }
        pendingDungeonFights.remove(instance);
        ulong[] restored;
        foreach (ref saved; records)
        {
            const spawn = creatureSpawnOf(saved.spawn);
            if (spawn is null || spawn.map != where.id || dungeons.deadInInstance(instance, saved.spawn)
                || !creatureInEvents(saved.spawn) || !upInPool(PoolMember.Kind.creature, saved.spawn)
                || cantSpawnWhileBossDead(*spawn, instance in dungeons.instances))
            {
                database.deleteDungeonFight(instance, saved.spawn);
                continue;
            }
            const guid = makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
            if (auto script = instance in instanceScripts)
                if (script.restoringEntity(EntityRef(guid)))
                {
                    database.deleteDungeonFight(instance, saved.spawn);
                    continue; // the encounter's own snapshot carries this creature and its encounter state
                }
            if (clean)
            {
                if (auto creature = where.creatureAt(guid))
                {
                    dungeonFights[instance][saved.spawn] = ActiveDungeonFight(guid, unixTime - 2);
                    checkpointDungeonFight(where, creature);
                }
                else
                    database.deleteDungeonFight(instance, saved.spawn);
                continue;
            }
            if (saved.spawn in dungeonFights.get(instance, null))
                continue; // a new fight already superseded the checkpoint while the read was retried
            try
                where.migrateIn(fromHex(saved.state), (const ref Migrant migrant) {
                    if (migrant.kind != MigrantKind.creature || migrant.spawn != saved.spawn)
                        return null;
                    auto creature = cast(Creature) restoreWorldMigrant(migrant, where);
                    if (creature is null || !creature.alive)
                        return null;
                    waitForCombatPlayer(creature);
                    dungeonFights[instance][saved.spawn] = ActiveDungeonFight(guid, unixTime);
                    restored ~= guid;
                    return cast(MapObject) creature;
                });
            catch (Exception error)
                warning!"instance %s: could not restore creature %s: %s"(instance, saved.spawn, error.msg);
        }
        // Its cell skips a creature already back (`spawnCellIn`): the script learns it here, or it would hold no
        // reference to a boss that came back from his fight.
        if (auto script = instanceScripts.get(instance, null))
            foreach (guid; restored)
            {
                import dmangos.script.api : CreatureLoaded, EntityRef;

                script.raise(CreatureLoaded(EntityRef(guid)));
            }
    }

    private void updateDungeonFights()
    {
        if (pendingDungeonFights.length && unixTime >= retryDungeonFightsAt)
            foreach (instance; pendingDungeonFights.keys)
                if (auto where = dungeons.instanceMaps.get(instance, null))
                    if (ownsDungeonFights(where))
                        restoreDungeonFights(where, pendingDungeonFights[instance]);
        foreach (instance, ref active; dungeonFights)
            if (auto where = dungeons.instanceMaps.get(instance, null))
                if (ownsDungeonFights(where))
                    foreach (spawn; active.keys)
                    {
                        const saved = active[spawn];
                        if (saved.savedAt + 2 <= unixTime)
                        {
                            auto creature = where.creatureAt(saved.guid);
                            if (creature is null)
                                discardDungeonFight(instance, spawn);
                            else if (creature.alive)
                                checkpointDungeonFight(where, creature);
                        }
                    }
    }

    private void waitForCombatPlayer(Creature creature)
    {
        if (creature.ai !is null && creature.ai.inCombat)
            foreach (target; creature.ai.threatList.byKey)
                if (highGuidOf(target) == HighGuid.player)
                {
                    creature.questActorWait = cast(int)((long(config.cluster.leaseMs) + config.cluster.failureTimeoutMs + 10_000));
                    creature.questActorWaitFor = target;
                    break;
                }
    }

    /// The player field is zero for a living scripted summon or native outdoor combatant.
    private void checkpointOutdoorCreature(Creature creature, bool immediate = false)
    {
        const state = outdoorCreatureCheckpoint(creature);
        if (state.actor)
            saveOutdoorScriptActor(state, immediate);
    }

    private QuestActorCheckpoint outdoorCreatureCheckpoint(Creature creature, scope const uint* faction = null)
    {
        if (!config.cluster.enabled || !creature.alive || !ownsQuestActor(creature))
            return QuestActorCheckpoint.init;
        auto migrant = saveMigratingObject(creature, false, carryImpacts: false, factionOverride: faction);
        if (migrant.kind != MigrantKind.summonedCreature && migrant.kind != MigrantKind.creature)
            return QuestActorCheckpoint.init;
        migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        return outdoorScriptActorState(creature.spawn.map, creature.guid, migrant);
    }

    private void checkpointOutdoorScriptObject(Map map, GameObject go, bool immediate = false)
    {
        const expires = scriptedGameObjects.get(GameObjectOnMap(map, go.guid), 0L);
        const state = outdoorObjectCheckpoint(map, go, expires);
        if (state.actor)
            saveOutdoorScriptActor(state, immediate);
    }

    private bool durableOutdoorObject(Map map, uint type)
    {
        import std.algorithm.comparison : among;

        return config.cluster.enabled && !map.instanceId && type.among(GameObjectType.generic, GameObjectType.spellFocus);
    }

    private static bool durableScriptedSpawn(const ref GameObjectSpawn spawn, const ref GameObjectTemplate proto)
    {
        import std.algorithm.comparison : among;

        return spawn.guid < temporaryCounterStart && spawn.respawnSeconds < 0
            && (proto.type.among(GameObjectType.generic, GameObjectType.spellFocus, GameObjectType.questGiver,
                    GameObjectType.goober, GameObjectType.button)
                || (proto.type == GameObjectType.chest && proto.data[3] && !proto.data[4] && !proto.data[5]));
    }

    private QuestActorCheckpoint outdoorObjectCheckpoint(Map map, GameObject go, long expires)
    {
        const nativeSpawn = durableScriptedSpawn(go.spawn, *go.template_);
        if ((!nativeSpawn && !durableOutdoorObject(map, go.type)) || map.instanceId || !config.cluster.enabled
            || !canWrite() || go.owner)
            return QuestActorCheckpoint.init;
        const home = cellKeyAt(go.spawn.x, go.spawn.y);
        if (expires <= unixTime || (ownsCell !is null && !ownsCell(map.id, home)))
            return QuestActorCheckpoint.init;
        auto migrant = saveMigratingObject(go, false, expiresOverride: expires);
        if (migrant.kind != (nativeSpawn ? MigrantKind.gameObject : MigrantKind.summonedGameObject))
            return QuestActorCheckpoint.init;
        migrant.home = home;
        return outdoorScriptActorState(map.id, go.guid, migrant);
    }

    private bool durableStaticDespawn(const ref GameObjectSpawn spawn, const ref GameObjectTemplate proto)
    {
        return spawn.guid < temporaryCounterStart && spawn.respawnSeconds >= 0
            && proto.type != GameObjectType.transport && proto.type != GameObjectType.moTransport
            && spawn.guid !in unsavedGameObjectSpawns && !gameObjectPools.manages(spawn.guid)
            && (data.pools is null || !data.pools.inPool(PoolMember.Kind.gameObject, spawn.guid));
    }

    private QuestActorCheckpoint outdoorScriptActorState(uint map, ulong guid, ref Migrant migrant)
    {
        import dmangos.world.instancescripting : toHex;

        return QuestActorCheckpoint(map, guid, migrant.home, 0, unixTime,
            toHex(encodeBundle(null, [migrant])));
    }

    private void saveOutdoorScriptActor(const ref QuestActorCheckpoint state, bool immediate)
    {
        outdoorQuestActors[state.actor] = state;
        database.saveQuestActor(config.realmId, state);
        if (immediate)
            settleWrites();
    }

    private void updateOutdoorScriptActors()
    {
        import dmangos.world.gameobject : GoLootState;

        if (unixTime < nextScriptActorCheckpoint || !outdoorQuestActors.length || !canWrite())
            return;
        nextScriptActorCheckpoint = unixTime + 1;
        foreach (actor; outdoorQuestActors.values)
            if (!actor.player && actor.savedAt + 2 <= unixTime)
                if (auto where = existingMap(actor.map))
                {
                    if (auto creature = where.creatureAt(actor.actor))
                    {
                        if (creature.summon.type == TempSpawnType.none)
                            checkpointOutdoorFight(creature);
                        else
                            checkpointOutdoorCreature(creature);
                    }
                    else if (auto object = where.gameObjectAt(actor.actor))
                    {
                        if (!outdoorOpenableActor(actor))
                        {
                            // Opened chests save their loot atomically with item claims. Their actor row holds placement.
                            if (object.type != GameObjectType.chest)
                                checkpointOutdoorScriptObject(where, object);
                        }
                        else if (object.lootState == GoLootState.ready)
                        {
                            if (GameObjectOnMap(where, object.guid) in scriptedGameObjects)
                                checkpointOutdoorScriptObject(where, object);
                            else
                            {
                                outdoorQuestActors.remove(actor.actor);
                                database.deleteQuestActor(config.realmId, actor.actor);
                            }
                        }
                    }
                }
    }

    private bool outdoorOpenableActor(const ref QuestActorCheckpoint actor)
    {
        import dmangos.world.objects : counterOf;
        import std.algorithm.comparison : among;

        if (!savedOpenableToggle(actor.state))
            return false;
        const guid = actor.actor;
        const counter = counterOf(guid);
        if (highGuidOf(guid) != HighGuid.gameObject || counter >= temporaryCounterStart)
            return false;
        indexSpawns();
        if (const index = counter in gameObjectSpawnIndex)
            if (const proto = data.gameObjectSpawns[*index].entry in data.gameObjectTemplates)
                return proto.type.among(GameObjectType.door, GameObjectType.button) != 0;
        return false;
    }

    private long nextScriptActorCheckpoint;

    private bool questActorRegion(const ref Region region, uint map, ulong home)
    {
        return physicalWorldRegion(region) && region.map == map && region.rect.containsKey(home);
    }

    private void forgetQuestActors(const(Region)[] lost)
    {
        import std.algorithm.searching : any;

        if (!lost.length)
            return;
        foreach (ref region; lost)
            pendingQuestActorRegions.remove(region.id);
        foreach (guid; outdoorQuestActors.keys)
        {
            const actor = outdoorQuestActors[guid];
            if (lost.any!(r => questActorRegion(r, actor.map, actor.home)))
                outdoorQuestActors.remove(guid);
        }
    }

    private void queueQuestActorRecovery(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        if (!config.cluster.enabled)
            return;
        foreach (ref region; gained)
            if (physicalWorldRegion(region))
                pendingQuestActorRegions[region.id] = QuestActorRegionGrant(region, arriving.get(region.id, null).length != 0);
        refreshQuestActors();
    }

    private void refreshQuestActors(bool retry = false)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.world.objects : counterOf;
        import std.algorithm.searching : any;

        if (!pendingQuestActorRegions.length || unixTime < retryQuestActorRecoveryAt || !canWrite())
            return;
        QuestActorCheckpoint[] actors;
        try
            actors = database.loadQuestActors(config.realmId);
        catch (DatabaseException error)
        {
            warning!"migration: could not load outdoor quest actors: %s"(error.msg);
            retryQuestActorRecoveryAt = unixTime + 1;
            return;
        }
        const grants = pendingQuestActorRegions.values;
        pendingQuestActorRegions = null;
        scope (exit)
            if (retry)
            {
                Region[] done;
                foreach (ref grant; grants)
                    if (grant.region.id !in pendingQuestActorRegions)
                        done ~= grant.region;
                loadHeldCells(done);
            }
        foreach (actor; actors)
        {
            if (!grants.any!(grant => questActorRegion(grant.region, actor.map, actor.home)))
                continue;
            const spawn = counterOf(actor.actor);
            const openable = outdoorOpenableActor(actor);
            const nativeFight = !actor.player && highGuidOf(actor.actor) == HighGuid.unit && spawn < temporaryCounterStart;
            if (highGuidOf(actor.actor) != HighGuid.gameObject
                && ((actor.player && actor.savedAt + 300 <= unixTime) || awaitingRespawn(spawn) || spawn in outdoorCorpses
                || (nativeFight && (creatureOnLoan(spawn) || !creatureInEvents(spawn)
                    || !upInPool(PoolMember.Kind.creature, spawn)))))
            {
                database.deleteQuestActor(config.realmId, actor.actor);
                continue;
            }
            auto where = map(actor.map);
            const clean = grants.any!(grant => grant.clean && questActorRegion(grant.region, actor.map, actor.home));
            if (!clean && openable)
            {
                restoreOutdoorOpenable(where, actor);
                continue;
            }
            if ((where.creatureAt(actor.actor) !is null || where.gameObjectAt(actor.actor) !is null)
                && (!nativeFight || clean || actor.actor in outdoorQuestActors))
            {
                outdoorQuestActors[actor.actor] = actor;
                continue;
            }
            if (clean)
            {
                database.deleteQuestActor(config.realmId, actor.actor);
                continue; // the clean bundle has the newer state and did not carry this actor
            }
            try
                restoreQuestActor(where, actor, nativeFight,
                    home => grants.any!(grant => !grant.clean && questActorRegion(grant.region, actor.map, home)));
            catch (DatabaseException error)
            {
                warning!"migration: could not load loot for outdoor actor %s: %s"(actor.actor, error.msg);
                foreach (ref grant; grants)
                    if (questActorRegion(grant.region, actor.map, actor.home))
                        pendingQuestActorRegions[grant.region.id] = grant;
                retryQuestActorRecoveryAt = unixTime + 1;
            }
        }
    }

    private bool restoreQueuedSummon(Map where, const ref QuestActorCheckpoint actor)
    {
        import dmangos.world.objects : counterOf;

        const spawn = counterOf(actor.actor);
        if (highGuidOf(actor.actor) == HighGuid.gameObject || (!awaitingRespawn(spawn) && spawn !in outdoorCorpses))
            return restoreQuestActor(where, actor, false, home => home == actor.home);
        database.deleteQuestActor(config.realmId, actor.actor);
        return true;
    }

    private bool restoreQuestActor(Map where, const ref QuestActorCheckpoint actor, bool nativeFight,
        scope bool delegate(ulong) ownsHome)
    {
        import dmangos.log : warning;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.objects : counterOf;

        const spawn = counterOf(actor.actor);
        InstanceChestRecord savedChest;
        if (highGuidOf(actor.actor) == HighGuid.gameObject && spawn < temporaryCounterStart)
            if (const placement = gameObjectSpawnOf(spawn))
                if (const proto = placement.entry in data.gameObjectTemplates)
                    if (proto.type == GameObjectType.chest)
                        savedChest = database.loadOutdoorChest(spawn);
        try
        {
            bool restoredActor;
            const recoveryWait = cast(int)((long(config.cluster.leaseMs) + config.cluster.failureTimeoutMs + 10_000));
            where.migrateIn(fromHex(actor.state), (const ref Migrant saved) {
                const root = saved.spawn == spawn;
                const kind = highGuidOf(actor.actor) == HighGuid.gameObject
                    ? (spawn < temporaryCounterStart ? MigrantKind.gameObject : MigrantKind.summonedGameObject)
                    : nativeFight ? MigrantKind.creature : MigrantKind.summonedCreature;
                if ((!root && !restoredActor) || (!actor.player && (!root || saved.kind != kind))
                    || !ownsHome(saved.home))
                    return null;
                auto object = restoreWorldMigrant(saved, where);
                if (auto go = cast(GameObject) object)
                {
                    if (actor.player || go.guid != actor.actor)
                    {
                        objectGone(where, go);
                        return null;
                    }
                    if (savedChest.spawn)
                    {
                        outdoorChests[spawn] = savedChest;
                        restoreOutdoorChest(go, savedChest);
                    }
                    restoredActor = true;
                    return object;
                }
                auto creature = cast(Creature) object;
                if (creature is null || !creature.alive)
                    return null;
                if (root)
                {
                    if (creature.guid != actor.actor || (actor.player ? creature.ai.questActorPlayer() != actor.player
                            : creature.summon.update(creature, 0)))
                    {
                        creature.ai.releaseBehaviour();
                        return null;
                    }
                    restoredActor = true;
                }
                else if (where.creatureAt(creature.guid) !is null)
                {
                    creature.ai.releaseBehaviour();
                    return null;
                }
                if (actor.player)
                {
                    creature.questActorWait = recoveryWait;
                    creature.questActorWaitFor = actor.player;
                }
                else if (nativeFight)
                    waitForCombatPlayer(creature);
                return cast(MapObject) creature;
            });
            if (restoredActor)
                outdoorQuestActors[actor.actor] = actor;
            else if (savedChest.spawn)
            {
                outdoorChests.remove(spawn);
                database.finishScriptedOutdoorChest(config.realmId, actor.actor, spawn);
            }
            else if (!actor.player)
                database.deleteQuestActor(config.realmId, actor.actor);
            return true;
        }
        catch (Exception error)
            warning!"map %s: could not restore quest actor %s: %s"(actor.map, actor.actor, error.msg);
        return false;
    }

    /// False if the corpses could not be read (`holdRegionRecovery`).
    private bool refreshOutdoorCorpses(const(Region)[] gained, const(Region)[] lost)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import std.algorithm.searching : any;

        if (!config.cluster.enabled)
            return true;
        foreach (guid; outdoorCorpses.keys)
        {
            const spawn = outdoorCorpseSpawn(outdoorCorpses[guid]);
            if (spawn.guid && outdoorRegionCovers(&spawn, lost))
                outdoorCorpses.remove(guid);
        }
        if (!gained.any!(r => physicalWorldRegion(r)))
            return true;
        InstanceCorpseRecord[] records;
        try
            records = database.loadOutdoorCorpses();
        catch (DatabaseException error)
        {
            warning!"migration: could not refresh outdoor corpses: %s"(error.msg);
            return false;
        }
        foreach (corpse; records)
        {
            const spawn = outdoorCorpseSpawn(corpse);
            if (!spawn.guid || corpse.expiresAt <= unixTime || !outdoorRegionCovers(&spawn, gained))
                continue;
            if (spawn.guid < temporaryCounterStart && (creatureOnLoan(spawn.guid) || !hasOutdoorRespawn(spawn.guid)))
                continue;
            auto where = map(spawn.map);
            outdoorCorpses[corpse.spawn] = corpse;
            if (where.creatureAt(loanGuid(&spawn)) !is null)
                continue; // the clean bundle contains the newer live state
            try
            {
                const migrant = outdoorCorpseMigrant(spawn, corpse);
                where.migrateIn(encodeBundle(null, [migrant]), (const ref Migrant saved) => restoreSavedCorpse(where, saved));
            }
            catch (Exception error)
                warning!"migration: could not read outdoor corpse %s: %s"(corpse.spawn, error.msg);
        }
        return true;
    }

    private CreatureSpawn outdoorCorpseSpawn(const ref InstanceCorpseRecord corpse)
    {
        import dmangos.log : warning;
        import dmangos.serialization : deserialize;
        import dmangos.world.instancescripting : fromHex;

        if (corpse.spawn < temporaryCounterStart)
        {
            const spawn = creatureSpawnOf(corpse.spawn);
            return spawn is null ? CreatureSpawn.init : *spawn;
        }
        try
        {
            auto bytes = ByteReader(fromHex(corpse.state));
            const spawn = deserialize!CreatureSpawn(bytes);
            if (spawn.guid == corpse.spawn && client.isValidMapCoord(spawn.map, spawn.x, spawn.y, spawn.z))
                return spawn;
        }
        catch (Exception error)
            warning!"migration: could not read outdoor summon %s: %s"(corpse.spawn, error.msg);
        return CreatureSpawn.init;
    }

    private bool hasOutdoorRespawn(uint spawn) const
    {
        return creaturePools.manages(spawn) ? creaturePools.waiting(spawn) : (spawn in respawnAt) !is null;
    }

    private static Migrant outdoorCorpseMigrant(const ref CreatureSpawn spawn, const ref InstanceCorpseRecord corpse)
    {
        import dmangos.world.instancescripting : fromHex;

        const kind = corpse.spawn < temporaryCounterStart ? MigrantKind.creature : MigrantKind.summonedCreature;
        return Migrant(kind, corpse.spawn, cellKeyAt(spawn.x, spawn.y), fromHex(corpse.state));
    }

    /// False if the opened chests could not be read (`holdRegionRecovery`).
    private bool refreshOutdoorChests(const(Region)[] gained, const(Region)[] lost)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import std.algorithm.searching : any;

        if (!config.cluster.enabled)
            return true;
        foreach (guid; outdoorChests.keys)
            if (const index = guid in gameObjectSpawnIndex)
                if (outdoorRegionCovers(&data.gameObjectSpawns[*index], lost))
                    outdoorChests.remove(guid);
        if (!gained.any!(r => physicalWorldRegion(r)))
            return true;
        try
        {
            foreach (chest; database.loadOutdoorChests())
                if (const index = chest.spawn in gameObjectSpawnIndex)
                    if (outdoorRegionCovers(&data.gameObjectSpawns[*index], gained))
                        outdoorChests[chest.spawn] = chest;
        }
        catch (DatabaseException error)
        {
            warning!"migration: could not refresh outdoor chests: %s"(error.msg);
            return false;
        }
        return true;
    }

    private void releaseRegionCharms(const ref Region region)
    {
        import dmangos.world.objects : highGuidOf;

        const wholeMap = dungeons.instanceable(region.map);
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
                fleet.longElevatorHomes.remove(mapId);
                if (auto m = existingMap(mapId))
                    m.elevatorHomes = fleet.elevatorHomesFor(mapId);
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

    /**
     * A clean handoff supplies its timers in the bundle. A crash only leaves the database rows. False if they
     * could not be read (`holdRegionRecovery`).
     */
    private bool refreshRegionRespawns(const(Region)[] gained, const(ubyte)[][uint] arriving)
    {
        if (!gained.length)
            return true;
        creaturePools.refresh();
        gameObjectPools.refresh();
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
        return syncColdRespawns(cold);
    }

    /// The respawn timers of regions gained without a bundle, from the database. False if they could not be read.
    private bool syncColdRespawns(const(Region)[] cold)
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!cold.length)
            return true;
        indexSpawns();
        void sync(Spawn)(ref long[uint] cached, const(long[uint]) saved, const(Spawn)[] spawns,
            const(size_t[uint]) index)
        {
            import std.algorithm.searching : any;

            bool here(uint guid)
            {
                static if (is(Spawn == CreatureSpawn))
                {
                    if (creaturePools.manages(guid))
                        return false; // the durable pool row owns this deadline
                }
                else
                    if (gameObjectPools.manages(guid))
                        return false;
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
            return false;
        }
        return true;
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
                const spawn = &data.creatureSpawns[index];
                if (creatureOnLoan(spawn.guid))
                    continue;
                if (const corpse = spawn.guid in outdoorCorpses)
                    if (corpse.expiresAt > unixTime)
                    {
                        auto where = existingMap(mapId);
                        if (where is null || where.creatureAt(loanGuid(spawn)) !is null)
                            continue;
                        try
                        {
                            const migrant = outdoorCorpseMigrant(*spawn, *corpse);
                            if (auto restored = restoreSavedCorpse(where, migrant))
                            {
                                spawned ~= restored;
                                continue;
                            }
                        }
                        catch (Exception error)
                        {
                            import dmangos.log : warning;
                            warning!"map %s: could not read outdoor corpse %s: %s"(mapId, spawn.guid, error.msg);
                        }
                    }
                if (awaitingRespawn(spawn.guid))
                    continue; // dead: it comes back when its time is up
                if (!creatureInEvents(spawn.guid) || !dungeons.groupSpawnAllowed(existingMap(mapId), 0, spawn.guid))
                    continue; // its game event or spawn group says it is away
                if (!upInPool(PoolMember.Kind.creature, spawn.guid))
                    continue; // another of its pool is up
                if (auto creature = makeCreature(spawn))
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

    package GameObject spawnWorldGameObject(const ref GameObjectSpawn spawn)
    {
        // Negative respawn times reserve the spawn for an event, a script or world PvP.
        if ((spawn.respawnSeconds < 0 && !eventActivatesObject(spawn.guid)) || gameObjectAwaitingRespawn(spawn.guid)
            || !gameObjectInEvents(spawn.guid) || !upInPool(PoolMember.Kind.gameObject, spawn.guid)
            || !dungeons.groupSpawnAllowed(existingMap(spawn.map), 1, spawn.guid))
            return null;
        auto object = makeGameObject(spawn);
        if (const saved = spawn.guid in outdoorChests)
            restoreOutdoorChest(object, *saved);
        return object;
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

    /// `creature` becomes a creature of `entry` (`Creature.changeEntry`); false if there is no such entry.
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
    // What creatures' scripts need
    // -----------------------------------------------------------------------

    /// The spell; null if there is none.
    const(SpellInfo)* spellInfo(uint id)
    {
        return data.spells.spell(id);
    }

    /// The client's tables.
    @property const(ClientData) clientData()
    {
        return client;
    }

    /// A `broadcast_text`; null if there is none.
    const(BroadcastText)* broadcastText(uint id)
    {
        return id in data.npcs.broadcastTexts;
    }

    /// `ListenRange.Say`, `.Yell`, `.TextEmote` in yards.
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

    package Migrant savePlayerSummon(Creature creature, bool departing)
    {
        if (!(creature.guardianOwner || creature.totemOwner) || creature.summon.type == TempSpawnType.none
            || creature.spawn.guid < temporaryCounterStart)
            return Migrant.init;
        auto migrant = saveMigratingObject(creature, departing, carryImpacts: departing);
        migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
        return migrant;
    }

    package Migrant saveMigratingObject(MapObject object, bool departing = true,
        const LootItem claimed = null, ulong looter = 0, long expiresOverride = 0, bool carryImpacts = true,
        scope const uint* factionOverride = null)
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
            const now = fleet.transportNow();
            auto kind = MigrantKind.creature;
            if (creature.spawn.guid >= temporaryCounterStart && creature.summon.type != TempSpawnType.none)
            {
                kind = MigrantKind.summonedCreature;
                serialize(w, creature.spawn);
                serialize(w, creature.summon);
                w.put(now);
            }
            ByteWriter state;
            creature.saveState(state, now, claimed, looter, factionOverride);
            w.put(cast(uint) state.data.length);
            w.putBytes(state.data);
            if (carryImpacts)
                writeReplicaImpacts(creature.guid, w, departing);
            else
                w.put(0u);
            if (departing)
                creature.ai.detachGroundHandoff();
            return Migrant(kind, creature.spawn.guid, 0, w.data);
        }
        auto gameObject = cast(GameObject) object;
        if (gameObject is null)
            return Migrant.init;
        if (gameObject.owner && (gameObject.type == GameObjectType.fishingNode
            || gameObject.type == GameObjectType.summoningRitual || gameObject.type == GameObjectType.trap))
            return Migrant.init; // follows its player's handoff
        if (departing && gameObject.loot !is null)
            gameObject.loot.sendReleaseForAll();
        long expires = expiresOverride;
        if (!gameObject.instanceId && !expires)
            if (auto active = existingMap(gameObject.spawn.map))
                expires = scriptedGameObjects.get(GameObjectOnMap(active, gameObject.guid), 0L);
        auto kind = MigrantKind.gameObject;
        if ((gameObject.instanceId || expires) && !gameObject.owner && gameObject.spawn.guid >= temporaryCounterStart)
        {
            kind = MigrantKind.summonedGameObject;
            serialize(w, gameObject.spawn);
        }
        gameObject.saveState(w, fleet.transportNow(), expires);
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
        const summon = deserialize!TempSpawn(reader);
        const elapsed = cast(int) (fleet.transportNow() - reader.read!uint);
        if (summon.summoner != owner || (summon.timed && summon.timer <= elapsed))
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
            loadMigrantCreature(creature, instance, fleet.transportNow(), r);
            return creature;
        }
        const at = m.spawn in gameObjectSpawnIndex;
        if (at is null)
        {
            warning!"migration: game object spawn %s is not known here"(m.spawn);
            return null;
        }
        auto gameObject = makeGameObject(data.gameObjectSpawns[*at]);
        gameObject.loadState(r, fleet.transportNow());
        return gameObject;
    }

    private void loadMigrantCreature(Creature creature, uint instance, uint now, ref ByteReader reader)
    {
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE;

        auto state = ByteReader(reader.readBytes(reader.read!uint));
        creature.instanceId = instance;
        creature.loadState(state, now, &spellInfo, data.waypoints);
        creature.factionTemplate = client.factionTemplates.lookup(creature.values.get!UNIT_FIELD_FACTIONTEMPLATE);
        readReplicaImpacts(creature.guid, creature.spawn.map, instance, reader);
    }

    /// A region may bring a saved GM spawn created after this node loaded its world data.
    package MapObject restoreWorldMigrant(const ref Migrant migrant, Map destination)
    {
        import dmangos.bytes : ByteReader;
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;
        import dmangos.serialization : deserialize;
        import dmangos.world.migration : MigrantKind;

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
            restored.loadState(state, fleet.transportNow());
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
            const now = fleet.transportNow();
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
                    fleet.refreshElevatorHomes(destination);
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
                            fleet.refreshElevatorHomes(destination);
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
            if (loot.rule != LootRule.notGroup || loot.checkpoint !is null)
                bindLootDelivery(this, destination, loot,
                    loot.rule == LootRule.groupLoot || loot.rule == LootRule.needBeforeGreed, loot.rule == LootRule.masterLoot);
            loot.resumeQuestLootChecks(destination.id, sendQuestLootCheck);
        }
    }

    package size_t[uint] spawnIndex, gameObjectSpawnIndex; // spawn guid -> its place in the world data
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
                    fleet.longElevatorHomes.remove(saved.map);
                    if (auto map_ = saved.map in maps)
                        (*map_).elevatorHomes = fleet.elevatorHomesFor(saved.map);
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

    package bool creatureOnLoan(uint spawn)
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

    package void askCreatureLoans(Map map_, Creature caller, UnitRef enemy, float radius)
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
            if (auto corpse = map_.creatureAt(guid))
                if (canCheckpointCorpse(corpse) && (corpse.loot !is null || corpse.skinnable))
                    database.saveInstanceCorpse(checkpointCorpse(corpse), 0);
        }
        else if (r.creature.returning && ownsCell(spawn.map, cellKey(r.rect.x0, r.rect.y0))
            && map_.creatureAt(guid) is null)
        {
            // The borrower sent nothing back: it crashed (no state at all), or it lost the creature without a clean
            // release when its lease lapsed or the term changed (a deadline at most). Its death, and the corpse
            // with its loot, are in the database: re-read them before rebuilding the spawn.
            if (!until)
            {
                if (creaturePools.manages(spawn.guid))
                {
                    if (!creaturePools.refresh())
                        return;
                }
                else
                {
                    const saved = database.loadCreatureRespawns().get(spawn.guid, 0);
                    if (saved)
                        respawnAt[spawn.guid] = saved;
                }
            }
            if (hasOutdoorRespawn(spawn.guid) && restoreLoanCorpse(map_, *spawn))
                return;
            if (!awaitingRespawn(spawn.guid) && creatureInEvents(spawn.guid)
                && dungeons.groupSpawnAllowed(map_, 0, spawn.guid) && upInPool(PoolMember.Kind.creature, spawn.guid))
                if (auto creature = makeCreature(spawn))
                    map_.addObject(creature);
        }
        if (!r.creature.returning && bundle.length)
            if (auto helper = map_.creatureAt(guid))
                if (helper.ai !is null)
                    helper.ai.answerRemoteAssistance(map_.creatureAt(r.creature.caller), map_.unit(r.creature.enemy), map_);
    }

    private bool restoreLoanCorpse(Map where, const ref CreatureSpawn spawn)
    {
        import dmangos.log : warning;

        try
        {
            foreach (corpse; database.loadOutdoorCorpses())
                if (corpse.spawn == spawn.guid && corpse.expiresAt > unixTime)
                {
                    const migrant = outdoorCorpseMigrant(spawn, corpse);
                    outdoorCorpses[spawn.guid] = corpse;
                    where.migrateIn(encodeBundle(null, [migrant]),
                        (const ref Migrant saved) => restoreSavedCorpse(where, saved));
                    return true; // the same death still owns this spawn
                }
        }
        catch (Exception error)
            warning!"migration: could not read borrowed corpse %s: %s"(spawn.guid, error.msg);
        return false;
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
            else
            {
                outdoorCorpses.remove(spawn.guid);
                if (map_.creatureAt(guid) !is null)
                    map_.removeObject(guid); // lease expired without a clean release
            }
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
        if (announcePresence !is null)
            announcePresence(who, true);
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
        if (announcePresence !is null)
            announcePresence(who, false);
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
     * `staffOnly`, only for staff announcement recipients.
     */
    void toEveryone(Opcode opcode, const(ubyte)[] body_, bool staffOnly = 0)
    {
        deliverToOwn(opcode, body_, staffOnly);
        if (toEveryoneElsewhere !is null)
            toEveryoneElsewhere(cast(ushort) opcode, staffOnly, body_);
    }

    /// `toEveryone`, for this node's players only.
    void deliverToOwn(Opcode opcode, const(ubyte)[] body_, bool staffOnly = 0)
    {
        foreach (other; online)
            if (!staffOnly || other.allowsStaff("staff.announce"))
                other.deliver(opcode, body_);
    }

    // -----------------------------------------------------------------------
    // Dead creatures and their respawning
    // -----------------------------------------------------------------------

    /// Creatures that are dead now: spawn guid -> when they come back (Unix time), as `creature_respawn` has it.
    private long[uint] respawnAt;
    private MonoTime lastRespawnCheck;
    private InstanceCorpseRecord[uint] outdoorCorpses;

    package bool moltenCoreTrash(const ref CreatureSpawn spawn)
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
            // A script can flush a checkpoint in its death handler. Queue the spawn death first.
            if (!summoned)
                if (auto state = creature.instanceId in dungeons.instances)
                {
                    const guid = creature.spawn.guid;
                    state.dead[guid] = true;
                    if (auto copy = battlegrounds.find(creature.instanceId))
                        copy.objectiveChanged();
                    else if (guid !in state.corpses)
                    {
                        database.saveInstanceRespawn(false, guid, creature.instanceId,
                            instanceDeathDeadline(*state, creature));
                    }
                    discardDungeonFight(creature.instanceId, guid);
                }
            // What the script makes of the death is a checkpoint: the death is queued already, and a crash between
            // the two writes would leave the creature dead but its encounter waiting on it (a door shut for good).
            if (auto script = creature.instanceId in instanceScripts)
                script.raiseCheckpointed(CreatureDied(EntityRef(creature.guid), EntityRef(creature.lootRecipient),
                    summoned));
            return;
        }
        if (auto script = creature.spawn.map in worldScripts)
            script.raise(CreatureDied(EntityRef(creature.guid), EntityRef(creature.lootRecipient), summoned));
        if (summoned)
            return;
        if (creature.spawn.guid in outdoorCorpses)
            return; // saved alongside the original loot
        if (creaturePools.manages(creature.spawn.guid))
            creaturePools.dead(creature.spawn.guid, creature.respawnAt);
        else
        {
            respawnAt[creature.spawn.guid] = creature.respawnAt;
            database.saveCreatureRespawn(creature.spawn.guid, creature.respawnAt);
        }
    }

    package bool canCheckpointCorpse(const Creature creature)
    {
        if (creature.alive || creature.corpseTimer <= 0 || creature.petOwner || creature.guardianOwner || creature.totemOwner)
            return false;
        if (creature.instanceId)
            return (creature.instanceId in dungeons.instances) !is null && !battlegroundOfMap(creature.spawn.map);
        return config.cluster.enabled;
    }

    private long instanceDeathDeadline(ref dungeons.InstanceState state, const Creature creature)
    {
        auto until = state.resetAt ? state.resetAt : unixTime + 86_400;
        if (moltenCoreTrash(creature.spawn) && creature.respawnAt < until)
            state.trashRespawns[creature.spawn.guid] = until = creature.respawnAt;
        return until;
    }

    /// Record the original loot and the death before exposing the loot to players.
    package void saveNewCorpse(Creature creature)
    {
        if (!canCheckpointCorpse(creature))
            return;
        if (auto state = creature.instanceId in dungeons.instances)
        {
            state.dead[creature.spawn.guid] = true;
            database.saveInstanceCorpse(checkpointCorpse(creature), instanceDeathDeadline(*state, creature));
        }
        else
        {
            saveOutdoorLootPositions(existingMap(creature.spawn.map), creature.loot);
            const record = checkpointCorpse(creature);
            if (creature.summon.type != TempSpawnType.none)
                database.saveInstanceCorpse(record, 0);
            else if (creaturePools.manages(record.spawn))
                creaturePools.dead(record.spawn, creature.respawnAt, false, record);
            else
            {
                respawnAt[record.spawn] = creature.respawnAt;
                database.saveInstanceCorpse(record, creature.respawnAt);
            }
        }
    }

    private void saveOutdoorLootPositions(Map map, Loot loot)
    {
        if (loot is null)
            return;
        foreach (guid; loot.owners.byKey)
            if (auto session = onlinePlayer(guid))
                if (session.character !is null && session.currentMap is map && !session.transferring)
                {
                    const progress = session.character.progress(session.secondsInWorld());
                    database.saveProgress(progress);
                }
    }

    package bool canCheckpointPickpocket(const Creature creature)
    {
        return config.cluster.enabled && creature.alive && creature.summon.type == TempSpawnType.none
            && !creature.petOwner && creature.spawn.guid < temporaryCounterStart
            && (!creature.instanceId || (creature.instanceId in dungeons.instances && !battlegroundOfMap(creature.spawn.map)));
    }

    package PickpocketRecord checkpointPickpocket(Creature creature, const LootItem claimed = null, ulong looter = 0)
    {
        import dmangos.world.instancescripting : toHex;
        import std.algorithm.searching : all;

        ByteWriter state;
        auto loot = creature.loot;
        loot.saveHandoff(state, claimed, looter, true);
        auto restock = creature.pocketsRestockAt;
        if (!restock && !loot.gold && loot.items.all!(item => item is claimed || !item.allowed.length))
            restock = unixTime + config.creaturePickpocketRestockDelay;
        return PickpocketRecord(creature.instanceId, creature.spawn.guid, restock, toHex(state.data));
    }

    package void restorePickpocket(Map map, Creature creature)
    {
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.loothandlers : bindCreatureLoot;

        if (!canCheckpointPickpocket(creature))
            return;
        const record = database.loadPickpocket(creature.instanceId, creature.spawn.guid);
        if (!record.spawn || (record.restockAt && record.restockAt <= unixTime))
            return;
        auto state = ByteReader(fromHex(record.loot));
        creature.loot = Loot.loadHandoff(creature.guid, state, true);
        creature.pocketsRestockAt = record.restockAt;
        creature.pocketsEmptied = record.restockAt != 0;
        bindCreatureLoot(this, map, creature, creature.loot);
    }

    package InstanceCorpseRecord checkpointCorpse(Creature creature, const LootItem claimed = null, ulong looter = 0)
    {
        import dmangos.world.instancescripting : toHex;

        const expiresAt = unixTime + (creature.corpseTimer + 999L) / 1000;
        const record = InstanceCorpseRecord(creature.instanceId, creature.spawn.guid, expiresAt,
            toHex(saveMigratingObject(creature, false, claimed, looter).state));
        if (auto state = creature.instanceId in dungeons.instances)
            state.corpses[record.spawn] = record;
        else if (!creature.instanceId)
            outdoorCorpses[record.spawn] = record;
        return record;
    }

    package void saveCorpseLoot(Creature creature)
    {
        auto state = creature.instanceId in dungeons.instances;
        if (creature.instanceId && state is null)
            return;
        auto corpses = state is null ? &outdoorCorpses : &state.corpses;
        if (creature.spawn.guid !in *corpses)
            return;
        if (creature.loot is null && !creature.skinnable)
        {
            (*corpses).remove(creature.spawn.guid);
            database.deleteInstanceCorpse(creature.instanceId, creature.spawn.guid);
        }
        else
            database.saveInstanceCorpse(checkpointCorpse(creature), 0);
    }

    private void restoreInstanceCorpses(Map map)
    {
        import dmangos.log : warning;
        import dmangos.serialization : deserialize;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.migration : MigrantKind;

        const state = map.instanceId in dungeons.instances;
        if (state is null)
            return;
        Migrant[] corpses;
        foreach (guid, corpse; state.corpses)
        {
            if (corpse.expiresAt <= unixTime || guid !in state.dead)
                continue;
            try
            {
                const bytes = fromHex(corpse.state);
                if (guid >= temporaryCounterStart)
                {
                    auto reader = ByteReader(bytes);
                    const spawn = deserialize!CreatureSpawn(reader);
                    if (spawn.map == map.id && spawn.guid == guid)
                        corpses ~= Migrant(MigrantKind.summonedCreature, guid, cellKeyAt(spawn.x, spawn.y), bytes);
                }
                else if (const spawn = creatureSpawnOf(guid))
                {
                    if (spawn.map == map.id)
                        corpses ~= Migrant(MigrantKind.creature, guid, cellKeyAt(spawn.x, spawn.y), bytes);
                }
            }
            catch (Exception error)
                warning!"instance %s: could not read corpse %s: %s"(map.instanceId, guid, error.msg);
        }
        if (corpses.length)
            map.migrateIn(encodeBundle(null, corpses), (const ref Migrant saved) => restoreSavedCorpse(map, saved));
    }

    private MapObject restoreSavedCorpse(Map map, const ref Migrant migrant)
    {
        import dmangos.log : warning;

        try
        {
            auto creature = cast(Creature) restoreWorldMigrant(migrant, map);
            if (creature is null || creature.alive || creature.summon.update(creature, 0))
                return null;
            // The inventory transaction may have committed before the corpse was cleared.
            if (creature.loot !is null && creature.loot.lootedForEveryone())
                creature.lootedOut();
            if (creature.loot !is null)
                creature.loot.resumeRemoteRolls();
            return creature.loot !is null || creature.skinnable ? cast(MapObject) creature : null;
        }
        catch (Exception error)
        {
            warning!"map %s copy %s: could not restore corpse %s: %s"(map.id, map.instanceId, migrant.spawn, error.msg);
            return null;
        }
    }

    /// A corpse went; if it died elsewhere, restore the original respawn deadline.
    package void corpseRemoved(Creature creature)
    {
        import std.algorithm.comparison : max;

        if (creature.petOwner)
        {
            if (auto owner = onlinePlayer(creature.petOwner))
                if (owner.character !is null)
                    owner.petCorpseGone(creature);
            return;
        }
        if (creature.instanceId)
        {
            if (auto state = creature.instanceId in dungeons.instances)
                if (state.corpses.remove(creature.spawn.guid))
                    database.deleteInstanceCorpse(creature.instanceId, creature.spawn.guid);
            return;
        }
        if (outdoorCorpses.remove(creature.spawn.guid))
            database.deleteInstanceCorpse(0, creature.spawn.guid);
        if (creature.summon.type != TempSpawnType.none)
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

    package uint summonsMade; // standalone counters
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
    Creature summonCreature(Map world, uint entry, Position at, TempSpawnType type, uint durationMs,
        ulong summoner)
    {
        auto map = world;
        if (map is null)
            return null;
        auto creature = prepareCreatureSummon(map, entry, at, type, durationMs, summoner);
        if (creature !is null)
            publishCreatureSummon(map, creature);
        return creature;
    }

    /// Makes a summon that can be checkpointed before the map or clients see it.
    private Creature prepareCreatureSummon(Map map, uint entry, Position at, TempSpawnType type, uint durationMs,
        ulong summoner)
    {
        if (entry !in data.creatureTemplates || !resolveCreatureSummonPosition(map, summoner, at))
            return null;
        const counter = nextTemporaryCounter();
        CreatureSpawn spawn = {guid: counter, entry: entry, map: map.id, x: at.x, y: at.y, z: at.z,
            orientation: at.orientation};
        auto creature = makeCreature(&spawn);
        if (creature is null)
            return null;
        creature.summon = TempSpawn(type, durationMs, durationMs, summoner);
        creature.instanceId = map.instanceId;
        return creature;
    }

    private void publishCreatureSummon(Map map, Creature creature)
    {
        map.addObject(creature);
        map.wake(creature.guid);
        if (map.instanceId) // the dungeon's script hears of it as of any creature of the copy
            if (auto script = map.instanceId in instanceScripts)
            {
                import dmangos.script.api : CreatureLoaded, EntityRef;

                script.raise(CreatureLoaded(EntityRef(creature.guid), true));
            }
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

    /// Summons a creature of `entry` at `at` (all zeros: near `summoner`), going as `type`

    /// (`TempSpawnType`) says after `durationMs`; null if it could not be made.
    Creature summon(Map world, uint entry, Position at, uint type, uint durationMs, ulong summoner)
    {
        auto summoned = summonCreature(world, entry, at, cast(TempSpawnType) type, durationMs, summoner);
        if (summoned !is null && summoner) // its summoner's script hears of it (`EVENT_T_SUMMONED_UNIT`)
            if (auto by = world.creatureAt(summoner))
                if (by.ai !is null)
                    by.ai.summonedCreature(world, summoned);
        return summoned;
    }

    /// Whether two players are in one group.
    bool sameGroup(ulong a, ulong b)
    {
        return groups.sameGroup(a, b);
    }

    /// A `creature_ai_summons` row: where, and for how long; false if there is none.
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
    package void replicaNoticing(Inhabitant who, Replica replica)
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
            fleet.refreshElevatorHomes(map);
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
            fleet.refreshElevatorHomes(map);
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
            fleet.refreshElevatorHomes(map);
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
     * up after them (and comes back with its spawn's respawn time). A scripted trap with no spell of its
     * own (Sapphiron's birth) is sprung for its script alone.
     */
    package void trapSprung(Map map, Inhabitant who, GameObject trap)
    {
        import dmangos.world.gameobject : GoLootState;

        if (unixTime < trap.trapReadyAt || trap.lootState != GoLootState.ready)
            return;
        const spell = cast(uint) trap.template_.data[3];
        if (trap.owner)
        {
            import dmangos.world.relations : canAttack;

            // A creature's (`summonCreatureTrap`): its owner's spell at the enemy that stepped in, from the trap.
            // A hunter's is its owner's to spring (`Character.updateTraps`).
            auto owner = map.creatureAt(trap.owner);
            import dmangos.world.character : Character;

            auto victim = UnitRef.of(cast(Character) who);
            if (owner is null || owner.ai is null || !owner.alive || spell == 0 || !victim || !victim.alive
                || !canAttack(owner.ai.relatingOf, victim.relating, client))
                return;
            trap.trapReadyAt = unixTime + (trap.template_.data[5] > 0 ? trap.template_.data[5] : 4);
            owner.ai.castFor(map, spell, victim.combatGuid, true);
            const charges = trap.template_.data[4];
            if (charges > 0 && ++trap.trapUses >= charges)
                map.gameObjectUsedUp(trap);
            return;
        }
        if (spell == 0 && !trap.behaviour)
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
        // The trap's script may keep it from springing for this one.
        if (trap.behaviour)
        {
            import dmangos.script.api : TrapSprung;

            if (raiseObject(trap, map, TrapSprung(EntityRef(session.character.guid))))
                return;
        }
        // A trap with a script is asked first (one only its creature springs refuses players).
        if (trap.behaviour && gameObjectUsed(trap, map, session.character.guid))
            return;
        trap.trapReadyAt = unixTime + (trap.template_.data[5] > 0 ? trap.template_.data[5] : 1);
        if (spell == 0)
            return;
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

    /// A `script_texts` row; null if there is none. Its sound (0: none).
    const(BroadcastText)* scriptText(int entry)
    {
        return entry in data.scriptTexts;
    }

    /// ditto
    uint scriptTextSound(int entry)
    {
        return data.scriptTextSounds.get(entry, 0);
    }

    /// What a creature holding item `entry` shows (nothing for 0 or an unknown item).
    VirtualItem virtualItem(uint entry)
    {
        if (const item = entry in data.items)
            return VirtualItem(item.displayId, cast(ubyte) item.itemClass, cast(ubyte) item.subClass,
                cast(ubyte) item.details.material, item.inventoryType, cast(ubyte) item.details.sheath);
        return VirtualItem.init;
    }

    /// The server's scripts, and the script of spell `id` (no handle if none serves it).
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

    /// The script of item `entry` (`item_template.ScriptName`); no handle if none serves it.
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
     * A `Signal` for creature `to` on `world`: its script here, or
     * (a replica here: another node simulates it) a `ScriptSignal` to that node.
     */
    ActionResult signalCreature(Map world, EntityRef from, EntityRef to, uint id, int value)
    {
        import dmangos.script.api : ActionResult;
        import dmangos.world.replication : Replica;

        auto map = world;
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

    import dmangos.world.guildmutation : GuildWriter;

    /// On a cluster member, guild changes made one at a time across the cluster (`GuildWriter`).
    GuildWriter guildWriter;

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
                if (guildWriter.active)
                    recipients ~= session;
                else
                    session.deliver(opcode, body_);
            }
        if (recipients.length)
            guildWriter.after({
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

    /// The escort path (`script_waypoint`) of creature `entry`; empty if it has none.
    const(Waypoint)[] escortPath(uint entry)
    {
        return data.escortPaths.get(entry, null);
    }

    /// A game object's use, for its script: the object's script hears of `player` using it; true if
    /// it handled the use (the usual use does not follow).
    bool gameObjectUsed(GameObject go, Map map, ulong player)
    {
        import dmangos.script.api : GameObjectContext, ObjectUsed;

        if (go.instanceId) // the copy's script hears of it first
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
    // Game object scripts' arrival, quests, traps and schedules
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
    package void noteTickingObject(GameObject go, Map map)
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
            else // its continent's script
                signalWorld(map.id, EntityRef(go.guid), id, value);
        }

        void hostLog(string text)
        {
            import dmangos.log : info;

            info!"script %s (%s %s): %s"(scripts.nameOf(go.behaviour), go.template_.name, go.spawn.guid, text);
        }


        int hostAskDungeon(uint id)
        {
            return go.instanceId ? askDungeon(go.instanceId, EntityRef(go.guid), id) : 0;
        }


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

    /// The guid of the nearest game object of `entry` within `range` yards of `center` on `world`; 0 if none.
    ulong gameObjectNear(Map world, Position center, uint entry, float range)
    {
        auto map = world;
        return map is null ? 0 : nearestGameObject(map, center, entry, range);
    }

    /// Uses game object `guid` on `world` as a door or button is used: open for its time.
    ActionResult useGameObject(Map world, ulong guid)
    {
        auto map = world;
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

    /// A `Signal` for the script of dungeon copy `instance` (nothing if it has none).
    /// Spell list `id`'s spells (`creature_spell_list`); empty if none.
    const(SpellListEntry)[] spellList(uint id)
    {
        return data.creatureSpellLists.get(id, null);
    }

    /// A model of creature `entry` (its template's first); 0 if none.
    uint displayOf(uint entry)
    {
        if (const t = entry in data.creatureTemplates)
            foreach (model; t.modelIds)
                if (model)
                    return model;
        return 0;
    }

    /// The game object of the first spawn of `entry` on `map` (one not there by default) put
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

    /// A game object of `entry` at `at` on `map`, of no spawn of the map's (it is in no
    /// other copy, and comes back nowhere), gone after `seconds` (0: with the map); null if there is no such object.
    /// A game object nobody owns (a spell's, `dmangos.world.guardians`) at `at`, for `seconds` (0: for good).
    GameObject summonWildGameObject(Map map, uint entry, Position at, uint seconds)
    {
        return summonGameObjectAt(map, entry, Location(at.x, at.y, at.z, at.orientation), seconds);
    }

    /**
     * A creature's trap (`SPELL_EFFECT_SUMMON_OBJECT_SLOT1` .. 4 of a creature's cast: a hunter mob's Immolation
     * Trap): `entry` at `at` for `seconds` (0: until it goes), made by `owner` at its level, so that its owner casts
     * the trap's spell at an enemy that steps in (`trapSprung`) and players see it as they see a hunter's.
     */
    package GameObject summonCreatureTrap(Map map, Creature owner, uint entry, Position at, uint seconds)
    {
        import dmangos.world.updatefields : GAMEOBJECT_LEVEL, OBJECT_FIELD_CREATED_BY, UNIT_FIELD_LEVEL;

        auto go = prepareGameObjectSummon(map, entry, Location(at.x, at.y, at.z, at.orientation));
        if (go is null)
            return null;
        go.owner = owner.guid;
        go.values.set!OBJECT_FIELD_CREATED_BY(owner.guid);
        go.values.set!GAMEOBJECT_LEVEL(owner.values.get!UNIT_FIELD_LEVEL);
        publishGameObjectSummon(map, go, seconds ? unixTime + seconds : 0);
        return go;
    }

    private GameObject summonGameObjectAt(Map map, uint entry, Location at, uint seconds)
    {
        auto go = prepareGameObjectSummon(map, entry, at);
        if (go !is null)
            publishGameObjectSummon(map, go, seconds ? unixTime + seconds : 0);
        return go;
    }

    private GameObject prepareGameObjectSummon(Map map, uint entry, Location at)
    {
        import std.math : cos, sin;

        if (entry !in data.gameObjectTemplates)
            return null;
        auto spawn = GameObjectSpawn(nextTemporaryCounter(), entry, map.id, at.x, at.y, at.z);
        spawn.orientation = at.orientation;
        spawn.rotation = [0, 0, sin(at.orientation / 2), cos(at.orientation / 2)];
        auto go = makeGameObject(spawn);
        go.instanceId = map.instanceId;
        return go;
    }

    private void publishGameObjectSummon(Map map, GameObject go, long expires)
    {
        if (expires)
            scriptedGameObjects[GameObjectOnMap(map, go.guid)] = expires;
        map.addObject(go);
    }

    /// The answer of dungeon copy `instance`'s script to question `id` from `from` (0: none).
    int askDungeon(uint instance, EntityRef from, uint id)
    {
        if (auto script = instance in instanceScripts)
            return script.ask(from, id);
        return 0;
    }

    /// `creature`, not fighting, goes back to its spawn point and then moves as it does by itself.
    void sendCreatureHome(Map world, Creature c)
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

    /// A `Signal` for the script of continent `map` (nothing if it has none here).
    void signalWorld(uint map, EntityRef from, uint id, int value)
    {
        import dmangos.script.api : Signal;

        if (auto script = map in worldScripts)
            script.raise(Signal(from, id, value));
    }

    /// A `Signal` from `from` for the script of the continent `world` is (nothing in a dungeon, or without one).
    void signalWorldMap(Map world, EntityRef from, uint id, int value)
    {
        if (auto map = world)
            if (map.instanceId == 0)
                signalWorld(map.id, from, id, value);
    }

    /// The creature entries `spell_script_target` gives spell `spell` (type 1); empty if none.
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

    /// Whether the player `player` (a pet's owner for a pet) meets condition `id` (`conditions`); false if the

    /// player is not online here.
    bool conditionMet(uint id, ulong player)
    {
        auto c = onlinePlayer(player);
        if (c is null || c.player is null)
            return false;
        return c.conditionMet(id);
    }

    /// The zone and area at `at` on map `map`; zeros where the terrain is not known.
    uint[2] zoneAndAreaAt(uint map, Position at)
    {
        auto t = terrain(map);
        return t is null || !t.knows(at.x, at.y) ? [0u, 0u] : t.zoneAndArea(at.x, at.y, at.z);
    }

    /// A creature's base damage at `level` for its class (`creature_template_classlevelstats`); 0 if none.
    float creatureBaseDamage(uint level, uint unitClass)
    {
        import dmangos.world.creature : classStatsKey;

        const stats = classStatsKey(level, unitClass) in data.creatureClassStats;
        return stats is null ? 0 : stats.baseDamage;
    }

    /// The waypoint path a creature of `entry` (spawn `guid`) walks by default; none if it has none.
    const(imported!"dmangos.world.motion".WaypointNode)[] creaturePath(uint entry, uint guid, uint pathId = 0)
    {
        return data.waypoints is null ? null : data.waypoints.pathFor(entry, guid, pathId, false);
    }

    /// `defender`'s zone is under attack by `attacker` (a player, or a pet): the players of the other side

    /// on this node are told (`SMSG_ZONE_UNDER_ATTACK`; the client writes it in its defense channel).
    void zoneUnderAttack(Map world, Creature defender, ulong attacker)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.unit : UnitKind;

        auto map = world;
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

    /// A `Signal` for the script of dungeon copy `instance` (nothing if it has none).
    void signalDungeon(uint instance, EntityRef from, uint id, int value)
    {
        import dmangos.script.api : Signal;

        if (auto script = instance in instanceScripts)
            script.raise(Signal(from, id, value));
    }

    /// A creature of dungeon copy `instance` began fighting `enemy`, or (no enemy) gave its fight up:

    /// the copy's script hears of it (`CreatureEngaged`, `CreatureEvaded`).
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

    /// Scripted event `event` (a creature's `SEND_EVENT`) happens on `world`, `source` starting it at


    /// See `AreaTriggerContext.respawnObjectsNear` (a used-up object, or one not there by default).
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

    /// Starts relay script `id` (`DbScriptType.relay`) on `world` (negative `id`: one of the relay group -`id`).
    void startRelay(int id, Map world, ulong source, ulong target)
    {
        import dmangos.world.dbscripts : DbScriptType;

        const relay = id < 0 ? data.dbScripts.randomRelay(-id) : id;
        if (relay)
            startScript(DbScriptType.relay, relay, world, source, target);
    }

    /// `.respawn`: the corpse goes now, and the creature comes back in a second.
    void respawnSoon(Creature corpse, Map map)
    {
        if (corpse.instanceId)
        {
            // In an instance: it comes back now, there.
            if (auto state = corpse.instanceId in dungeons.instances)
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
    private GameObjectPools gameObjectPools;
    private InstanceChestRecord[uint] outdoorChests;

    /// A game object from its spawn, with what it needs to show players their quests' objects.
    GameObject makeGameObject(scope const ref GameObjectSpawn spawn)
    {
        auto go = new GameObject(spawn, spawn.entry in data.gameObjectTemplates);
        go.setElevator(fleet.elevatorPathOf(go.guid, go.fields), &fleet.transportNow);
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

    /// Persistent rewards are one-shot dungeon chest spawns with no gathering refills.
    package bool isInstanceReward(const GameObject go)
    {
        import dmangos.world.gameobject : GameObjectType;

        return go.instanceId in dungeons.instances && go.spawn.guid < temporaryCounterStart
            && go.type == GameObjectType.chest && go.consumable && go.spawn.respawnSeconds < 0
            && !go.template_.data[4] && !go.template_.data[5];
    }

    package bool canCheckpointChest(const GameObject go)
    {
        if (go.instanceId)
            return isInstanceReward(go);
        if (!config.cluster.enabled || go.spawn.guid >= temporaryCounterStart || go.type != GameObjectType.chest
            || !go.consumable || go.spawn.guid in unsavedGameObjectSpawns)
            return false;
        if (go.spawn.respawnSeconds < 0)
            return durableScriptedSpawn(go.spawn, *go.template_)
                && GameObjectOnMap(existingMap(go.spawn.map), go.guid) in scriptedGameObjects;
        return gameObjectPools.manages(go.spawn.guid)
            || data.pools is null || !data.pools.inPool(PoolMember.Kind.gameObject, go.spawn.guid);
    }

    package void saveOpenedChest(Map map, GameObject go)
    {
        if (!canCheckpointChest(go))
            return;
        if (!go.instanceId)
            saveOutdoorLootPositions(map, go.loot);
        database.saveInstanceChest(checkpointReward(map, go));
    }

    package void saveRefilledChest(Map map, GameObject go)
    {
        if (!go.instanceId && go.spawn.guid in outdoorChests)
            database.saveInstanceChest(checkpointReward(map, go));
    }

    package InstanceChestRecord checkpointReward(Map map, GameObject go,
        const imported!"dmangos.world.loot".LootItem claimed = null, ulong looter = 0)
    {
        import dmangos.bytes : ByteWriter;
        import dmangos.world.instancescripting : toHex;

        if (!go.instanceId)
        {
            import std.algorithm.comparison : min;

            const visibleUntil = scriptedGameObjects.get(GameObjectOnMap(map, go.guid), long.max);
            ByteWriter w;
            go.saveState(w, fleet.transportNow(), 0, claimed, looter);
            const previous = outdoorChests.get(go.spawn.guid, InstanceChestRecord.init);
            const openedUntil = go.despawnTimer > 0 ? unixTime + (go.despawnTimer + 999L) / 1000 : 0;
            auto record = InstanceChestRecord(0, go.spawn.guid,
                min(visibleUntil, openedUntil && previous.expiresAt ? previous.expiresAt : openedUntil), toHex(w.data));
            outdoorChests[go.spawn.guid] = record;
            return record;
        }
        auto state = go.instanceId in dungeons.instances;
        if (state is null)
            return InstanceChestRecord.init;
        const now = unixTime;
        const visibleUntil = scriptedGameObjects.get(GameObjectOnMap(map, go.guid), long.max);
        const openedUntil = now + (go.despawnTimer + 999) / 1000;
        const previous = state.chests.get(go.spawn.guid, InstanceChestRecord.init);
        ByteWriter w;
        w.put(ubyte(1));
        go.loot.saveHandoff(w, claimed, looter);
        auto record = InstanceChestRecord(go.instanceId, go.spawn.guid,
            previous.loot.length ? previous.expiresAt : visibleUntil < openedUntil ? visibleUntil : openedUntil,
            toHex(w.data));
        state.chests[go.spawn.guid] = record;
        return record;
    }

    private void rememberUnopenedReward(GameObject go, long deadline)
    {
        if (!isInstanceReward(go))
            return;
        auto record = InstanceChestRecord(go.instanceId, go.spawn.guid, deadline, null);
        dungeons.instances[go.instanceId].chests[go.spawn.guid] = record;
        database.saveInstanceChest(record);
    }

    package bool restoreReward(GameObject go, const ref InstanceChestRecord reward)
    {
        import dmangos.bytes : ByteReader, PacketException;
        import dmangos.log : warning;
        import dmangos.world.gameobject : GoLootState;
        import dmangos.world.instancescripting : fromHex;
        import dmangos.world.loot : Loot;
        import std.algorithm.searching : all;

        const remaining = reward.expiresAt - unixTime;
        if (remaining <= 0 || !isInstanceReward(go))
            return false;
        if (!reward.loot.length)
        {
            scriptedGameObjects[GameObjectOnMap(dungeons.instanceMaps[go.instanceId], go.guid)] = reward.expiresAt;
            return true;
        }
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
            bindMigrantLoot(go, dungeons.instanceMaps[go.instanceId]);
            return true;
        }
        catch (PacketException e)
        {
            warning!"could not restore reward chest %s of instance %s: %s"(reward.spawn, reward.instance, e.msg);
            return false;
        }
    }

    private void restoreOutdoorChest(GameObject go, const ref InstanceChestRecord chest)
    {
        import dmangos.log : warning;
        import dmangos.world.instancescripting : fromHex;

        if (!canCheckpointChest(go))
            return;
        try
        {
            auto bytes = ByteReader(fromHex(chest.loot));
            go.loadState(bytes, fleet.transportNow());
            if (chest.expiresAt && chest.expiresAt <= unixTime)
            {
                go.loot = null;
                go.lootState = GoLootState.justDeactivated;
                return;
            }
            if (go.loot is null)
                return;
            go.despawnTimer = cast(int)((chest.expiresAt - unixTime) * 1000);
            bindMigrantLoot(go, existingMap(go.spawn.map));
            if (go.lootState == GoLootState.activated && go.loot.lootedForEveryone())
                go.loot.lootedForAll();
            else
                go.loot.resumeRemoteRolls();
        }
        catch (Exception error)
            warning!"map %s: could not restore outdoor chest %s: %s"(go.spawn.map, chest.spawn, error.msg);
    }

    /// A game object used up: it comes back after its spawn's respawn time.
    package void gameObjectUsedUp(GameObject go)
    {
        if (go.spawn.guid >= temporaryCounterStart)
            return;
        if (go.instanceId)
        {
            if (auto state = go.instanceId in dungeons.instances)
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
        const at = outdoorObjectRespawnDeadline(go);
        const hadChest = outdoorChests.remove(go.spawn.guid);
        if (gameObjectPools.manages(go.spawn.guid))
            return gameObjectPools.exhausted(go.spawn.guid, at, hadChest);
        gameObjectRespawnAt[go.spawn.guid] = at;
        if (hadChest)
            database.finishOutdoorChest(go.spawn.guid, at);
        else
            database.saveGameObjectRespawn(go.spawn.guid, at);
    }

    private long outdoorObjectRespawnDeadline(const GameObject go)
    {
        const saved = go.spawn.guid in outdoorChests;
        const finished = saved !is null && saved.expiresAt && saved.expiresAt < unixTime ? saved.expiresAt : unixTime;
        return finished + (go.spawn.respawnSeconds > 0 ? go.spawn.respawnSeconds : 0);
    }

    /// Whether a game object spawn is used up and waiting to come back.
    bool gameObjectAwaitingRespawn(uint spawnGuid)
    {
        if (gameObjectPools.manages(spawnGuid))
            return gameObjectPools.waiting(spawnGuid);
        if (auto at = spawnGuid in gameObjectRespawnAt)
            return *at > unixTime;
        return false;
    }

    /// The game objects whose time has come, made anew where their cell is loaded.
    private void gameObjectsDue()
    {
        const time = unixTime;
        gameObjectPoolsDue(time);
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

    private uint[uint] rollsInDoubt; // pool -> the placement a refused roll kept (`gameObjectPoolsDue`)

    private void gameObjectPoolsDue(long time)
    {
        import std.algorithm.searching : canFind;
        import dmangos.world.database : GameObjectPoolPlacement, GameObjectPoolState;

        if (!gameObjectPools.refresh())
            return;
        // A roll that kept its placement whose answer was lost reads as refused, though it committed: the saved
        // selection, read again, says so, and the object comes back now rather than when its cell next loads.
        foreach (pool, kept; rollsInDoubt)
            if (const state = pool in gameObjectPools.states())
                if (state.placements.canFind!(slot => slot.spawn == kept && !slot.due))
                    if (const spawn = gameObjectSpawnOf(kept))
                    {
                        const home = cellKeyAt(spawn.x, spawn.y);
                        auto where = existingMap(spawn.map);
                        if (where !is null && where.cellLoaded(home) && (ownsCell is null || ownsCell(spawn.map, home))
                            && where.gameObjectAt(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid)) is null)
                            if (auto object = spawnWorldGameObject(*spawn))
                                where.addObject(object);
                    }
        rollsInDoubt = null;
        foreach (pool, state; gameObjectPools.states())
            foreach (i, slot; state.placements)
            {
                if (!slot.due || slot.due > time)
                    continue;
                const spawn = gameObjectSpawnOf(slot.spawn);
                if (spawn is null)
                    continue;
                const home = cellKeyAt(spawn.x, spawn.y);
                if (ownsCell !is null && !ownsCell(spawn.map, home))
                    continue;
                const next = gameObjectSpawnOf(gameObjectPools.roll(pool, slot.spawn, state, spawnRandom));
                if (next is null)
                    continue;
                const due = next.guid == slot.spawn ? 0 : time + next.respawnSeconds;
                auto placements = state.placements.dup;
                placements[i] = GameObjectPoolPlacement(next.guid, due);
                const selection = GameObjectPoolState(state.revision, placements);
                if (!gameObjectPools.change(pool, selection))
                {
                    if (!due)
                        rollsInDoubt[pool] = next.guid;
                    continue;
                }
                if (!due)
                    if (auto where = existingMap(spawn.map))
                        if (where.cellLoaded(home))
                            if (auto object = spawnWorldGameObject(*spawn))
                                where.addObject(object);
                break;
            }
    }

    // -----------------------------------------------------------------------
    // Mail and auctions settled outside a session
    // -----------------------------------------------------------------------









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
            if (outdoorCorpses.remove(guid))
                database.deleteInstanceCorpse(0, guid);
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
            if (there is null || !there.cellLoaded(home) || !dungeons.groupSpawnAllowed(there, 0, spawn.guid))
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
        foreach (id, map; dungeons.instanceMaps)
            if (auto state = id in dungeons.instances)
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
                if (outdoorCorpses.remove(state.spawn))
                    database.deleteInstanceCorpse(0, state.spawn);
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
            if (there !is null && there.cellLoaded(home) && creatureInEvents(spawn.guid)
                && dungeons.groupSpawnAllowed(there, 0, spawn.guid))
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
        tickMaps(dungeons.instanceMaps);
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
            bool savedCorpse;
            foreach (creature; map_.creatureDeaths.take())
            {
                creatureDied(creature);
                if (config.cluster.enabled)
                    if (const state = creature.instanceId in dungeons.instances)
                        savedCorpse |= (creature.spawn.guid in state.corpses) !is null;
            }
            if (savedCorpse && canWrite())
            {
                foreach (who; map_.playersNow())
                    if (auto session = cast(Character) who)
                    {
                        const progress = who.character.progress(session.secondsInWorld());
                        database.saveProgress(progress);
                    }
                settleWrites();
            }
        }
        foreach (map_; maps)
            drain(map_);
        foreach (map_; dungeons.instanceMaps)
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

    private MonoTime lastConditionalSpawnCheck;

    private long nextOutdoorCorpsePurge;

    /**
     * Once an hour, the outdoor corpses that expired over an hour ago go from the database. A native spawn's row
     * is replaced at its next death, but a scripted summon's counter is never used again, and the row of one whose
     * corpse expired while no worker held it (a takeover, or a restore that failed) would otherwise stay for good.
     */
    private void purgeExpiredOutdoorCorpses()
    {
        import dmangos.log : warning;
        import dmangos.mysql : DatabaseException;

        if (!config.cluster.enabled || config.cluster.gateway || unixTime < nextOutdoorCorpsePurge || !canWrite())
            return;
        nextOutdoorCorpsePurge = unixTime + 3600;
        try
            database.purgeExpiredOutdoorCorpses(unixTime - 3600);
        catch (DatabaseException error)
            warning!"outdoor corpses: could not delete the expired ones: %s"(error.msg);
    }

    private void worldPhase(MonoTime now, Duration elapsed)
    {
        if (dungeons.instances.length)
            dungeons.unloadEmptyInstances(now);
        refreshQuestActors(true);
        retryRegionRecovery();
        purgeExpiredOutdoorCorpses();
        if (config.cluster.enabled && !config.cluster.gateway && now >= nextOutdoorWorldStatePoll)
        {
            nextOutdoorWorldStatePoll = now + 1.seconds;
            try
                readOutdoorWorldStates();
            catch (imported!"dmangos.mysql".DatabaseException error)
                imported!"dmangos.log".warning!"outdoor world states: could not refresh persisted values: %s"(error.msg);
        }
        updateScripts(cast(uint) elapsed.total!"msecs");
        updateOutdoorScriptActors();
        updateDungeonFights();
        foreach (script; instanceScripts) // the dungeon scripts' own timers
            script.tick(cast(int) elapsed.total!"msecs");
        foreach (script; worldScripts) // the continents'
            script.tick(cast(int) elapsed.total!"msecs");
        gameObjectScriptsTick(cast(int) elapsed.total!"msecs");
        weather.poll(now);
        catalogs.poll(this, now);
        guildWriter.poll(this, now);
        addPendingNavigation();
        checkHonorWeek(now);
        services.tick(elapsed);
        pollLootCoinCredits(now);
        pollScriptCredits(now);
        releaseSettledSessions();
        pollBattlegroundRewards(now);
        worldPvp.tick(elapsed);
        if (battlegroup is null || battlegroup.host is this) battlegrounds.tick(elapsed);
        landObjectAnimations(now);
        updateGameEvents(now);
        if (lastConditionalSpawnCheck == MonoTime.init || now - lastConditionalSpawnCheck >= 1.seconds)
        {
            lastConditionalSpawnCheck = now;
            dungeons.refreshConditionalSpawns();
        }
        removeExpiredBones();
        if (forwardGroup is null) // the coordinator, or alone (not while starting: who coordinates is not known yet)
        {
            eventMails();
            groupService.meetingStonesTick(elapsed); // the meeting stones' queue is the groups' keeper's
        }
        fleet.updateShips();
        linkFollowers();
        scriptedGameObjectsDue();
        respawnDue(now);
        if (forwardGroup is null) // by one node
            postOffice.update(now);
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
            throw new IdsExhausted("no " ~ kind.to!string ~ " ids: the coordinator's next block has not come");
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
            claimSession(accountId, serial, false);
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
                // Another node may load the account's characters next: they are saved first. While the
                // database stalls, the release waits for the writes (`releaseSettledSessions`), not the game.
                if (releasesAfterWrites.length || !settleWrites())
                {
                    releasesAfterWrites ~= PendingRelease(accountId, *serial);
                    imported!"dmangos.log".info!"account %s left before its saves were written; its release waits for them"(
                        accountId);
                }
                else
                    releaseSession(accountId, *serial);
            }
            grantedSerials.remove(*serial);
            serials.remove(session);
        }
    }

    private static struct PendingRelease
    {
        uint account;
        ulong serial;
    }
    private PendingRelease[] releasesAfterWrites;

    /// Releases, in order, the accounts `removeSession` kept once nothing written for them waits.
    private void releaseSettledSessions()
    {
        if (!releasesAfterWrites.length || (writer !is null && !writer.settled))
            return;
        auto pending = releasesAfterWrites;
        releasesAfterWrites = null;
        foreach (release; pending)
        {
            imported!"dmangos.log".info!"account %s released now that its saves are written"(release.account);
            releaseSession(release.account, release.serial);
        }
    }

    /**
     * Waits until every write queued so far is in the database (docs/DESIGN.md, step 6): before another
     * node may load what this one saved. False if the database refused one of them (it is kept in the
     * file of failed writes, `dmangos.world.writebehind.failedPath`), or if the writer does not get through
     * them soon (the database is away or slow: `Writer.settle`); the game goes on meanwhile.
     */
    bool settleWrites()
    {
        if (writer is null)
            return true;
        const failedBefore = writer.statistics.failed;
        if (writer.settle())
            return true;
        if (writer.statistics.failed != failedBefore)
            imported!"dmangos.log".error!"the database refused a write while waiting for the writes (kept in the file of failed writes)"();
        else if (MonoTime.currTime - lastSettleWarning >= 5.seconds)
        {
            lastSettleWarning = MonoTime.currTime;
            imported!"dmangos.log".warning!"the database is slow or away: going on without waiting for %s queued write(s)"(
                writer.statistics.waiting);
        }
        return false;
    }
    private MonoTime lastSettleWarning;

    /// See `SessionHandler.sessionGranted`.
    void sessionGranted(uint account, ulong serial)
    {
        if (auto session = account in sessions)
            if (serials.get(*session, 0) == serial)
            {
                grantedSerials[serial] = true;
                session.admit();
            }
    }

    private bool[ulong] grantedSerials; // the sessions a coordinator let into the world

    /// See `SessionHandler.sessionEvicted`.
    void sessionEvicted(uint account, ulong serial)
    {
        foreach (session, s; serials)
            if (s == serial)
                return session.kick("logged in on another node of the realm");
    }

    /**
     * A cluster node: whether its database has taken none of its writes for a while
     * (`ClusterNode.databaseStalledAfter`). It refuses logins and holds arrivals meanwhile: what it loaded could
     * miss its own unwritten saves, and what it saved of the player could not be written. Null: never.
     */
    bool delegate() writesStalled;

    /// ditto
    bool databaseStalled()
    {
        return writesStalled !is null && writesStalled();
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
                claimSession(account, *serial, (*serial in grantedSerials) !is null);
    }

    private CreaturePools creaturePools;
}

/// A scripted world-state gate can spawn and remove an eligible creature in a cell that is already loaded.
unittest
{
    import dmangos.world.conditions : Condition, Conditions, ConditionType;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto context = newCreationContext(newDatabase());
    const ref spawn = context.data.creatureSpawns[0];
    const home = cellKeyAt(spawn.x, spawn.y);
    const guid = makeGuid(HighGuid.unit, spawn.entry, spawn.guid);
    enum uint condition = 88, flag = 99;
    context.data.npcs.conditions = new Conditions([Condition(condition, ConditionType.worldState, flag, 1, 1)]);
    context.data.conditionalSpawns[spawn.map] = WorldData.ConditionalSpawns([0], null);
    context.data.spawnConditions[0][spawn.guid] = SpawnGroupCondition(condition);
    auto where = context.map(spawn.map);
    where.loadCell(home);
    assert(where.creatureAt(guid) is null);
    where.scriptedWorldStates[flag] = 1;
    context.dungeons.refreshConditionalSpawns();
    auto shown = where.creatureAt(guid);
    assert(shown !is null);
    context.dungeons.refreshConditionalSpawns();
    assert(where.creatureAt(guid) is shown);
    where.scriptedWorldStates[flag] = 0;
    context.dungeons.refreshConditionalSpawns();
    assert(where.creatureAt(guid) is null);
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
    from.dungeons.instances[instance].dead[64] = true;
    from.dungeons.instances[instance].usedUp[65] = true;
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
    assert(64 in to.dungeons.instances[instance].dead && 65 in to.dungeons.instances[instance].usedUp);
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

// A loot-bearing outdoor summon can lose its worker while its original corpse is still available.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient : newCreationContext, newDatabase;
    import dmangos.world.testdata : creatureInnkeeper;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto db = newDatabase();
    auto owner = newCreationContext(db, (ref config) { config.cluster.nodeId = 1; });
    auto replacement = newCreationContext(db, (ref config) { config.cluster.nodeId = 2; });
    const spot = Position(-8949.95f, -132.49f, 83.53f);
    auto source = owner.map(0);
    auto summon = owner.summonCreature(source, creatureInnkeeper, spot, TempSpawnType.timed, 120_000, 0);
    summon.values.set!UNIT_FIELD_HEALTH(0u);
    summon.die(source, owner.unixTime);
    assert(summon.retainSummonedLootCorpse());
    auto loot = new Loot(summon.guid, null);
    loot.owners[7] = true;
    loot.gold = 25;
    summon.loot = loot;
    owner.saveNewCorpse(summon);
    assert(db.loadOutdoorCorpses().length == 1 && summon.spawn.guid !in db.creatureRespawns);

    const x = cellCoordinate(spot.x), y = cellCoordinate(spot.y);
    const region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 2, 1, RegionState.granted);
    ubyte[][uint] unused;
    replacement.regionsChanged([region], null, null, unused);
    auto destination = replacement.map(0);
    auto same = destination.creatureAt(summon.guid);
    assert(same !is null && same !is summon && !same.alive && same.spawn == summon.spawn);
    assert(same.loot.gold == 25 && same.loot.owners[7]);
    destination.corpseExpired(same);
    assert(db.loadOutdoorCorpses().length == 0);
    assert(destination.creatureAt(summon.guid) is null && summon.spawn.guid !in db.creatureRespawns);
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

    enum Scenario { standalone, split, clean, cold, coldWithLoot }
    foreach (scenario; [Scenario.standalone, Scenario.split, Scenario.clean, Scenario.cold, Scenario.coldWithLoot])
    {
        const recoverLoot = scenario == Scenario.coldWithLoot;
        const cold = scenario == Scenario.cold || recoverLoot;
        auto db = newDatabase();
        auto oldOwner = newNode(db);
        auto remote = scenario == Scenario.standalone ? oldOwner : newNode(db);
        auto winner = scenario == Scenario.clean || cold ? newNode(db) : oldOwner;
        foreach (node; [oldOwner, remote, winner])
        {
            node.startClock = clock;
            node.startUnixTime = oldOwner.startUnixTime;
        }
        if (recoverLoot)
        {
            oldOwner.config.cluster.nodeId = 1;
            winner.config.cluster.nodeId = 2;
        }
        const first = oldOwner.upInPool(kind, placements[0].guid) ? 0 : 1;
        const second = 1 - first;
        const start = placements[first].guid, alternate = placements[second].guid;
        const startingGuid = makeGuid(HighGuid.unit, creatureInnkeeper, start);
        const alternateGuid = makeGuid(HighGuid.unit, creatureInnkeeper, alternate);
        bool moved;
        if (scenario != Scenario.standalone)
        {
            oldOwner.ownsCell = (uint mapId, ulong cell) => (!moved || cold)
                && !mapId && cell == homes[first];
            remote.ownsCell = (uint mapId, ulong cell) => !mapId && cell == homes[second];
            if (cold)
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
        if (recoverLoot)
        {
            rare.die(firstMap, oldOwner.unixTime);
            rare.loot = new Loot(rare.guid, null);
            rare.loot.gold = 25;
            rare.loot.owners[7] = true;
            oldOwner.saveNewCorpse(rare);
            const corpse = db.loadOutdoorCorpses();
            assert(corpse.length == 1 && corpse[0].spawn == start && start !in db.creatureRespawns);
            assert(!db.updateCreaturePoolState(realm, pool, 0, alternate, 0,
                InstanceCorpseRecord(0, alternate, corpse[0].expiresAt, corpse[0].state)));
            assert(db.loadOutdoorCorpses() == corpse, "a rejected pool write must not create a corpse");
        }
        else
        {
            firstMap.creatureDeath(rare);
            firstMap.corpseExpired(rare);
        }
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
            auto destination = winner.map(0);
            destination.loadCell(homes[first]);
            assert(winner.awaitingRespawn(start));
            auto restored = destination.creatureAt(startingGuid);
            if (recoverLoot)
            {
                assert(restored !is null && !restored.alive && restored.loot !is null);
                assert(restored.loot.gold == 25 && 7 in restored.loot.owners);
                assert(secondMap.creatureAt(alternateGuid) is null);
                destination.corpseExpired(restored);
                assert(db.loadOutdoorCorpses().length == 0);
            }
            else
                assert(restored is null);
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

// Opened chests and concurrent uses in a multi-slot pool survive replacement of their workers.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient;
    import dmangos.world.worlddata : PoolChooser;
    import std.algorithm.searching : all;

    enum uint pool = 100, entry = 8010, realm = 9;
    enum kind = PoolMember.Kind.gameObject;
    auto db = newDatabase();
    auto clock = MonoTime.currTime;
    auto epoch = 2_000_000_000L;
    immutable GameObjectSpawn[] placements = [
        GameObjectSpawn(91, entry, 0, -8930, -120, 83.53, respawnSeconds: 30),
        GameObjectSpawn(92, entry, 0, -8930, -180, 83.53, respawnSeconds: 30),
        GameObjectSpawn(93, entry, 0, -8930, -240, 83.53, respawnSeconds: 30),
    ];

    WorldContext worker(ushort id)
    {
        auto client = testClientData();
        auto data = testWorldData(client);
        GameObjectTemplate chest = {entry: entry, type: GameObjectType.chest};
        chest.data[3] = 1;
        data.gameObjectTemplates[entry] = chest;
        data.pools = new PoolChooser;
        data.pools.limits[pool] = 2;
        foreach (spawn; placements)
        {
            data.pools.add(pool, PoolMember(kind, spawn.guid));
            data.gameObjectCells[0][cellKeyAt(spawn.x, spawn.y)] ~= data.gameObjectSpawns.length;
            data.gameObjectSpawns ~= spawn;
        }
        auto rng = Random(13);
        data.pools.choose(rng);
        WorldConfig config;
        config.realmId = realm;
        config.cluster.nodeId = id;
        auto node = new WorldContext(config, db, data, client);
        node.startUnixTime = epoch;
        node.startClock = clock;
        node.clock = () => clock;
        return node;
    }

    auto original = worker(1), other = worker(2);
    GameObjectSpawn[] active;
    foreach (spawn; placements)
        if (original.upInPool(kind, spawn.guid))
            active ~= spawn;
    assert(active.length == 2);
    GameObject place(WorldContext node, const ref GameObjectSpawn spawn)
    {
        auto map = node.map(0);
        map.loadCell(cellKeyAt(spawn.x, spawn.y));
        return map.gameObjectAt(makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid));
    }
    auto opened = place(original, active[0]);
    auto neighboring = place(other, active[1]);
    assert(opened !is null && neighboring !is null);
    opened.loot = new Loot(opened.guid, null);
    opened.loot.gold = 25;
    opened.loot.owners[7] = true;
    opened.lootState = GoLootState.activated;
    opened.despawnTimer = 300_000;
    original.saveOpenedChest(original.map(0), opened);
    assert(db.loadOutdoorChests().length == 1);

    auto replacement = worker(3);
    const x = cellCoordinate(active[0].x), y = cellCoordinate(active[0].y);
    ubyte[][uint] unused;
    replacement.regionsChanged([Region(1, 0, CellRect(x, y, x + 1, y + 1), 3, 1, RegionState.granted)],
        null, null, unused);
    auto resumed = place(replacement, active[0]);
    assert(resumed !is null && resumed.loot.gold == 25 && resumed.loot.owners[7]);
    replacement.map(0).gameObjectUsedUp(resumed);
    assert(db.loadOutdoorChests().length == 0, "depletion and its cooldown commit together");

    other.map(0).gameObjectUsedUp(neighboring); // its cached pool revision predates the first use
    assert(db.loadGameObjectPoolStates(realm)[pool].revision == 1);
    assert(other.gameObjectPools.refresh());
    const state = db.loadGameObjectPoolStates(realm)[pool];
    assert(state.revision == 2 && state.placements.length == 2 && state.placements.all!(slot => slot.due == epoch + 30));

    auto restarted = worker(4);
    foreach (spawn; placements)
        assert(place(restarted, spawn) is null, "no placement may appear during the saved cooldown");
    clock += 31.seconds;
    restarted.respawnDue(clock);
    const next = db.loadGameObjectPoolStates(realm)[pool];
    assert(next.revision == 3 && next.placements.length == 2 && next.placements[0].spawn != next.placements[1].spawn);
}

// A takeover that cannot read the opened chests yet keeps the chest's cell unloaded, and loads it once they are
// read: the chest comes back opened with what was left in it, not unopened with new loot.
unittest
{
    import dmangos.cluster.regions : CellRect;
    import dmangos.mysql : DatabaseException;
    import dmangos.world.database : WorldDatabase;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient;
    import std.typecons : AutoImplement;

    static abstract class ChestsAway : WorldDatabase
    {
        WorldDatabase inner;
        int failures;

        this(WorldDatabase inner) { this.inner = inner; }

        override InstanceChestRecord[] loadOutdoorChests()
        {
            if (failures > 0)
            {
                --failures;
                throw new DatabaseException("the characters database is away");
            }
            return inner.loadOutdoorChests();
        }
    }
    enum string forward(C, alias method) = "return inner." ~ __traits(identifier, method) ~ "(args);";
    alias Failing = AutoImplement!(ChestsAway, forward);

    enum uint entry = 8011;
    auto db = newDatabase();
    auto clock = MonoTime.currTime;
    const spawn = GameObjectSpawn(95, entry, 0, -8930, -120, 83.53, respawnSeconds: 30);

    WorldContext worker(ushort id, WorldDatabase database)
    {
        auto client = testClientData();
        auto data = testWorldData(client);
        GameObjectTemplate chest = {entry: entry, type: GameObjectType.chest};
        chest.data[3] = 1;
        data.gameObjectTemplates[entry] = chest;
        data.gameObjectCells[0][cellKeyAt(spawn.x, spawn.y)] ~= data.gameObjectSpawns.length;
        data.gameObjectSpawns ~= spawn;
        WorldConfig config;
        config.realmId = 9;
        config.cluster.nodeId = id;
        auto node = new WorldContext(config, database, data, client);
        node.startUnixTime = 2_000_000_000L;
        node.startClock = clock;
        node.clock = () => clock;
        return node;
    }
    const guid = makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
    const home = cellKeyAt(spawn.x, spawn.y);

    auto original = worker(1, db);
    original.map(0).loadCell(home);
    auto opened = original.map(0).gameObjectAt(guid);
    opened.loot = new Loot(opened.guid, null);
    opened.loot.gold = 25;
    opened.loot.owners[7] = true;
    opened.lootState = GoLootState.activated;
    opened.despawnTimer = 300_000;
    original.saveOpenedChest(original.map(0), opened);
    assert(db.loadOutdoorChests().length == 1);

    auto away = new Failing(db);
    away.failures = 2;
    auto replacement = worker(3, away);
    const x = cellCoordinate(spawn.x), y = cellCoordinate(spawn.y);
    ubyte[][uint] unused;
    replacement.regionsChanged([Region(1, 0, CellRect(x, y, x + 1, y + 1), 3, 1, RegionState.granted)],
        null, null, unused);
    replacement.map(0).loadCell(home);
    assert(replacement.map(0).gameObjectAt(guid) is null, "the cell waits for the opened chests");
    replacement.retryRegionRecovery(); // too soon: no read
    assert(away.failures == 1);
    clock += 1.seconds;
    replacement.retryRegionRecovery(); // read, and fails again
    assert(replacement.map(0).gameObjectAt(guid) is null);
    clock += 1.seconds;
    replacement.retryRegionRecovery();
    replacement.map(0).loadCell(home);
    auto resumed = replacement.map(0).gameObjectAt(guid);
    assert(resumed !is null && resumed.loot !is null && resumed.loot.gold == 25 && resumed.loot.owners[7],
        "the chest comes back opened, with what was left in it");
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

// In a dungeon copy too a linked creature comes back (a boss's wipe or death brings its
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
    auto m = context.dungeons.instanceMap(hero.session.inWorld.instanceId);
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
    assert(!add.alive && context.dungeons.deadInInstance(m.instanceId, 90080));
    kill(boss);
    now += 1100.msecs;
    context.update(now);
    auto back = cast(Creature) m.findObject(addGuid);
    assert(back !is null && back.alive && !context.dungeons.deadInInstance(m.instanceId, 90080), "the add came back");
}

// A helper that died on the node that borrowed it keeps its corpse and loot when that node loses the loan without a
// clean release (its lease lapsed, or the quorum's term changed) and gives it back with nothing in hand: the
// helper's home reads the death back from the database instead of losing the corpse.
unittest
{
    import dmangos.cluster.regions : CellRect, CreatureLease, Region, RegionState, creatureLeaseMap;
    import dmangos.world.grid : cellCoordinate;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_HEALTH;

    auto db = newDatabase();
    auto clock = MonoTime.currTime;
    Region lease;
    WorldContext node(ushort id)
    {
        auto n = newCreationContext(db, (ref config) { config.cluster.nodeId = id; });
        n.clock = () => clock;
        n.creatureLease = (uint spawn) => spawn == lease.creature.spawn ? lease : Region.init;
        n.sendCreatureLoan = (CreatureLoan) {};
        return n;
    }
    auto home = node(1), borrower = node(2);
    borrower.startClock = home.startClock;
    borrower.startUnixTime = home.startUnixTime;
    const spawn = home.loanSpawn(innkeeperSpawn, 0);
    assert(spawn !is null);
    const guid = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    const homeCell = cellKeyAt(spawn.x, spawn.y);
    home.ownsCell = (uint mapId, ulong cell) => !mapId && cell == homeCell;
    borrower.ownsCell = (uint, ulong) => false;
    home.map(0).loadCell(homeCell);
    assert(home.map(0).creatureAt(guid) !is null);

    const x = cellCoordinate(spawn.x), y = cellCoordinate(spawn.y);
    const loan = Region(50, creatureLeaseMap, CellRect(x, y, x + 1, y + 1), 2, 1, RegionState.granted, 0,
        CreatureLease(innkeeperSpawn, 0));
    Region lending = loan;
    lending.owner = 1;
    lending.state = RegionState.revoking;
    lending.next = 2;
    lease = lending;
    const lent = home.releaseCreatureLoan(lending);
    assert(lent.length, "lent alive");
    lease = loan;
    ubyte[][uint] leaving;
    borrower.regionsChanged([loan], null, [loan.id: lent], leaving);
    auto there = borrower.map(0);
    auto helper = there.creatureAt(guid);
    assert(helper !is null && helper.alive);

    helper.values.set!UNIT_FIELD_HEALTH(0u);
    helper.die(there, borrower.unixTime);
    helper.loot = new Loot(helper.guid, null);
    helper.loot.gold = 25;
    helper.loot.owners[7] = true;
    helper.corpseTimer = 60_000; // the test innkeeper's spawn has no respawn time to keep a corpse for
    helper.respawnAt = borrower.unixTime + 300;
    borrower.saveNewCorpse(helper);
    assert(db.loadOutdoorCorpses().length == 1);

    // The borrower's lease lapses and comes back (or the term changes): it loses the loan, then holds it again.
    borrower.regionsChanged(null, [loan], null, leaving);
    assert(there.creatureAt(guid) is null);
    borrower.regionsChanged([loan], null, null, leaving);

    // The coordinator sends the helper home; the borrower has nothing to send with it.
    Region returning = loan;
    returning.creature.returning = true;
    returning.state = RegionState.revoking;
    returning.next = 1;
    lease = returning;
    const back = borrower.releaseCreatureLoan(returning);
    returning.owner = 1;
    returning.state = RegionState.granted;
    returning.next = 0;
    lease = returning;
    home.regionsChanged([returning], null, [returning.id: back], leaving);
    auto corpse = home.map(0).creatureAt(guid);
    assert(corpse !is null && !corpse.alive, "dead at home, not risen");
    assert(corpse.loot !is null && corpse.loot.gold == 25 && 7 in corpse.loot.owners, "with its loot");
}

// A database script's quest credit for a player another worker simulates (the player's region and the script's went
// to two different survivors) reaches the player there, once: a kill credit, and an explored area.
unittest
{
    import dmangos.cluster.protocol : ScriptQuestCredit;
    import dmangos.world.dbscripts : DbScriptStep, DbScriptType, ScriptCommand;
    import dmangos.world.quests : Quest, QuestState;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    enum uint relay = 530, explore = 531, questId = 9420, area = 9421, credited = 12346;
    auto db = newDatabase();
    auto scripted = newCreationContext(db, (ref config) { config.cluster.nodeId = 1; });
    auto elsewhere = newCreationContext(db, (ref config) { config.cluster.nodeId = 2; });
    Quest q = {id: questId, method: 2, maxLevel: 60, title: "Greet", specialFlags: 0x20};
    q.reqCreatureOrGoId[0] = credited;
    q.reqCreatureOrGoCount[0] = 2;
    Quest witness = {id: area, method: 2, maxLevel: 60, title: "Witness", specialFlags: 0x02};
    foreach (node; [scripted, elsewhere])
    {
        node.data.quests.quests[questId] = q;
        node.data.quests.quests[area] = witness;
    }
    scripted.data.dbScripts.add(DbScriptType.relay, DbScriptStep(relay, 0, 0, ScriptCommand.killCredit, credited));
    scripted.data.dbScripts.add(DbScriptType.relay, DbScriptStep(explore, 0, 0, ScriptCommand.questExplored, area));
    auto anduin = loggedIn(elsewhere, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.session.inWorld.addQuest(elsewhere.data.quests.quests[questId]);
    anduin.session.inWorld.addQuest(elsewhere.data.quests.quests[area]);
    const player = anduin.session.character.guid;

    ScriptQuestCredit[] sent;
    ushort[] to;
    scripted.scriptQuestCreditElsewhere = (ushort node, const ref ScriptQuestCredit credit) {
        to ~= node;
        sent ~= credit;
    };
    scripted.lastHeard[player] = WorldContext.Heard(2, MonoTime.currTime, 10); // presence: the player is on node 2
    auto map = scripted.map(0);
    const spawn = scripted.loanSpawn(innkeeperSpawn, 0);
    map.loadCell(cellKeyAt(spawn.x, spawn.y));
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    assert(keeper !is null);
    assert(scripted.startScript(DbScriptType.relay, relay, map, keeper.guid, player));
    assert(scripted.startScript(DbScriptType.relay, explore, map, keeper.guid, player));
    scripted.updateScripts(0);
    assert(sent.length == 2 && to == [2, 2] && sent[0].player == player && sent[1].player == player);
    assert(sent[0].kind == ScriptQuestCredit.Kind.kill && sent[0].quest == credited);
    assert(sent[1].kind == ScriptQuestCredit.Kind.explored && sent[1].quest == area);
    // The direct notification overtakes the older one after a handoff.
    elsewhere.scriptQuestCreditArrived(sent[1]);
    elsewhere.scriptQuestCreditArrived(sent[0]);
    const me = anduin.session.character;
    assert(me.questStatus[questId].mobCount[0] == 1, "the kill, credited where the player plays");
    assert(me.questStatus[area].status == QuestState.complete, "and the explored area");

    // Sent again (a resend after a reconnect), the kill is not counted twice.
    elsewhere.scriptQuestCreditArrived(sent[0]);
    assert(me.questStatus[questId].mobCount[0] == 1 && me.questStatus[questId].status != QuestState.complete);

    // A delayed step is checkpointed outdoors. Lose the sender's notification after its final cursor commits.
    enum delayed = relay + 2;
    scripted.data.dbScripts.add(DbScriptType.relay, DbScriptStep(delayed, 1000, 0, ScriptCommand.killCredit, credited));
    assert(scripted.startScript(DbScriptType.relay, delayed, map, keeper.guid, player));
    scripted.updateScripts(0);
    assert(db.loadOutdoorScripts(scripted.config.realmId).length == 1);
    scripted.updateScripts(1000);
    assert(!db.loadOutdoorScripts(scripted.config.realmId).length);
    const pending = db.pendingScriptQuestCredits(scripted.config.realmId);
    assert(pending.length == 1 && sent.length == 3 && sent[2] == pending[0]);
    elsewhere.scriptQuestCreditElsewhere = scripted.scriptQuestCreditElsewhere;
    elsewhere.pollScriptCredits(MonoTime.currTime);
    assert(me.questStatus[questId].mobCount[0] == 2 && me.questStatus[questId].status == QuestState.complete);
    assert(db.questRows[7][questId].mobCount[0] == 2 && !db.pendingScriptQuestCredits(scripted.config.realmId).length);
    elsewhere.scriptQuestCreditArrived(sent[2]);
    assert(!db.consumeScriptQuestCredit(scripted.config.realmId, sent[2], null));
}

// A node's gameplay messages are numbered from its incarnation, not the wall clock: a start after the clock stepped
// back (its recorded incarnation one above the last) still numbers above everything the last start sent.
unittest
{
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto db = newDatabase();
    auto before = newCreationContext(db, (ref config) { config.cluster.nodeId = 3; });
    before.nextGameplaySequence(); // a value issued before joining the cluster
    before.incarnation = 1_795_631_257_169;
    ulong last;
    foreach (_; 0 .. 1_100_000)
        last = before.nextGameplaySequence();
    auto after = newCreationContext(db, (ref config) { config.cluster.nodeId = 3; });
    after.incarnation = before.incarnation + 1;
    assert(after.nextGameplaySequence() > last);
    assert(newCreationContext(db).nextGameplaySequence() != 0, "outside a cluster, from the clock as before");
}

// A gathering node's roll that keeps its placement, committed though its answer was lost, still brings the node back:
// the next pass reads the selection again instead of leaving the node away until its cell next loads.
unittest
{
    import dmangos.world.database : GameObjectPoolState, WorldDatabase;
    import dmangos.world.gameobject : GameObjectTemplate;
    import dmangos.world.testclient;
    import dmangos.world.worlddata : PoolChooser;
    import std.typecons : AutoImplement;

    static abstract class AnswerLost : WorldDatabase
    {
        WorldDatabase inner;
        bool loseNext;

        this(WorldDatabase inner) { this.inner = inner; }

        override bool updateGameObjectPoolState(uint realm, uint pool, const ref GameObjectPoolState state,
            uint exhaustedChest)
        {
            const changed = inner.updateGameObjectPoolState(realm, pool, state, exhaustedChest);
            if (loseNext && changed)
            {
                loseNext = false;
                return false; // the retry on a new connection matched no row: the first attempt had committed
            }
            return changed;
        }
    }
    enum string forward(C, alias method) = "return inner." ~ __traits(identifier, method) ~ "(args);";
    alias Flaky = AutoImplement!(AnswerLost, forward);

    enum uint pool = 101, entry = 8012, realm = 9;
    enum kind = PoolMember.Kind.gameObject;
    auto db = newDatabase();
    auto flaky = new Flaky(db);
    auto clock = MonoTime.currTime;
    const spawn = GameObjectSpawn(96, entry, 0, -8930, -120, 83.53, respawnSeconds: 30);
    auto client = testClientData();
    auto data = testWorldData(client);
    GameObjectTemplate vein = {entry: entry, type: GameObjectType.chest};
    vein.data[3] = 1;
    data.gameObjectTemplates[entry] = vein;
    data.pools = new PoolChooser;
    data.pools.limits[pool] = 1;
    data.pools.add(pool, PoolMember(kind, spawn.guid));
    data.gameObjectCells[0][cellKeyAt(spawn.x, spawn.y)] ~= data.gameObjectSpawns.length;
    data.gameObjectSpawns ~= spawn;
    auto rng = Random(13);
    data.pools.choose(rng);
    WorldConfig config;
    config.realmId = realm;
    config.cluster.nodeId = 1;
    auto node = new WorldContext(config, flaky, data, client);
    node.startUnixTime = 2_000_000_000L;
    node.startClock = clock;
    node.clock = () => clock;
    const guid = makeGuid(HighGuid.gameObject, spawn.entry, spawn.guid);
    const home = cellKeyAt(spawn.x, spawn.y);
    auto map = node.map(0);
    map.loadCell(home);
    auto used = map.gameObjectAt(guid);
    assert(used !is null);
    map.gameObjectUsedUp(used);
    assert(map.gameObjectAt(guid) is null);

    clock += 31.seconds;
    flaky.loseNext = true;
    node.respawnDue(clock); // the only member is rolled again, kept, and the answer lost
    assert(db.loadGameObjectPoolStates(realm)[pool].placements[0].due == 0, "the roll committed");
    assert(map.gameObjectAt(guid) is null);
    clock += 1.seconds;
    node.respawnDue(clock);
    assert(map.gameObjectAt(guid) !is null, "back, by the selection read again");
}

// An outdoor summon's corpse row that expired with no worker to release it goes from the database within the hour.
unittest
{
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto db = newDatabase();
    auto clock = MonoTime.currTime;
    auto node = newCreationContext(db, (ref config) { config.cluster.nodeId = 1; });
    node.clock = () => clock;
    const now = node.unixTime;
    db.saveInstanceCorpse(InstanceCorpseRecord(0, temporaryCounterStart + 5, now - 7200, ""), 0);
    db.saveInstanceCorpse(InstanceCorpseRecord(0, temporaryCounterStart + 6, now + 60, ""), 0);
    node.purgeExpiredOutdoorCorpses();
    const kept = db.loadOutdoorCorpses();
    assert(kept.length == 1 && kept[0].spawn == temporaryCounterStart + 6, "only the expired one goes");
    db.saveInstanceCorpse(InstanceCorpseRecord(0, temporaryCounterStart + 7, now - 7200, ""), 0);
    node.purgeExpiredOutdoorCorpses();
    assert(db.loadOutdoorCorpses().length == 2, "once an hour");
    clock += 3601.seconds;
    node.purgeExpiredOutdoorCorpses();
    assert(db.loadOutdoorCorpses().length == 1);
}
