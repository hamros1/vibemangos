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
    import dmangos.world.objectrespawns : ObjectRespawns;

    /// See `dmangos.world.objectrespawns`.
    ObjectRespawns objectRespawns;

    import dmangos.world.objectscripts : ObjectScripts;

    /// See `dmangos.world.objectscripts`.
    ObjectScripts objectScripts;

    import dmangos.world.grouprelay : GroupRelay;

    /// See `dmangos.world.grouprelay`.
    GroupRelay groupRelay;

    import dmangos.world.remotespells : RemoteSpells;

    /// See `dmangos.world.remotespells`.
    RemoteSpells remoteSpells;

    import dmangos.world.migration : MigrantKeeper;

    /// See `dmangos.world.migration`.
    MigrantKeeper migrants;

    import dmangos.world.creatureloans : CreatureLoans;

    /// See `dmangos.world.creatureloans`.
    CreatureLoans loans;

    import dmangos.world.regionrecovery : RegionRecoverer;

    /// See `dmangos.world.regionrecovery`.
    RegionRecoverer recovery;

    import dmangos.world.creaturedeath : DeadCreatures;

    /// See `dmangos.world.creaturedeath`.
    DeadCreatures deadCreatures;

    import dmangos.world.spawnediting : SpawnEditor;

    /// See `dmangos.world.spawnediting`.
    SpawnEditor spawnEditor;

    import dmangos.world.scourge : InvasionFollower;

    /// See `dmangos.world.scourge`.
    InvasionFollower invasionHere;

    import dmangos.world.gameevents : EventCalendar;

    /// See `dmangos.world.gameevents`.
    EventCalendar calendar;

    import dmangos.world.creaturelinking : Linking;

    /// What the links of this node's creatures do (`dmangos.world.creaturelinking.Linking`).
    Linking links;

    import dmangos.world.wareffort : WarEffortFollower;

    /// See `dmangos.world.wareffort`.
    WarEffortFollower warEffortHere;

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
    package InstanceScript[uint] worldScripts;    // by map id, the continents' scripts here

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
    package enum presenceGrace = 3.seconds; // presence says where a player is within a second or two


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

    bool delegate(ushort, const ref PartyQuest) sendPartyQuest;

    import dmangos.cluster.protocol : PartySummon;
    bool delegate(ushort, const ref PartySummon) sendPartySummon;


    bool delegate(ushort, const ref PartyHeal) sendPartyHeal;
    bool delegate(ushort, const ref imported!"dmangos.cluster.protocol".PartyAreaAura) sendPartyAreaAura;
    import dmangos.cluster.protocol : TotemWeaponEnchant;
    bool delegate(ushort, const ref TotemWeaponEnchant) sendTotemWeaponEnchant;
    import dmangos.cluster.protocol : MindVisionTarget;
    bool delegate(ushort, const ref MindVisionTarget) sendMindVisionTarget;

    bool delegate(ushort, const ref AreaDamage) sendAreaDamage;

    bool delegate(ushort, const ref GameObjectSpell) sendGameObjectSpell;

    bool delegate(ushort, const ref CreatureSwing) sendCreatureSwing;

    void delegate(ushort, const ref PeriodicResult) sendPeriodicResult;

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

    package const(Heard)* recentHandoff(ulong guid)
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
            return player.killShared(share);
        if (share.victim && share.victim <= uint.max && share.victim != share.target)
            player.playerKilledByMe(HonorVictim(share.victim, share.level, share.race, share.rank, share.visualRank,
                share.honorless, Position(share.x, share.y, share.z)), share.map, share.instance);
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
    package Random spawnRandom;

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
        objectRespawns = new ObjectRespawns(this);
        objectScripts = new ObjectScripts(this);
        groupRelay = new GroupRelay(this);
        remoteSpells = new RemoteSpells(this);
        migrants = new MigrantKeeper(this);
        loans = new CreatureLoans(this);
        recovery = new RegionRecoverer(this);
        deadCreatures = new DeadCreatures(this);
        spawnEditor = new SpawnEditor(this);
        invasionHere = new InvasionFollower(this);
        calendar = new EventCalendar(this);
        links = new Linking(this);
        warEffortHere = new WarEffortFollower(this);
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
        deadCreatures.respawnAt = database.loadCreatureRespawns();
        creaturePools = new CreaturePools(() => this.database, config.realmId, data, deadCreatures.respawnAt);
        objectRespawns.gameObjectRespawnAt = database.loadGameObjectRespawns();
        objectRespawns.gameObjectPools = new GameObjectPools(() => this.database, config.realmId, data, objectRespawns.gameObjectRespawnAt,
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
        calendar.gameEvents = new GameEvents;
        data.npcs.conditions.eventActive = (uint id) => calendar.gameEvents.isActive(id);
        data.npcs.conditions.holidayActive = (uint holiday) => calendar.gameEvents.holidayActive(holiday);
        calendar.updateGameEvents(clock(), true); // before any cell loads, so its spawns follow the events now
        services.provide!ChannelsHost((const(ubyte)[] state) => ChannelsHost(new ChannelService(this, client,
            ChannelSettings(config.allowTwoSideInteractionChannel), state)));
        services.provide!InvasionHost(&invasionHere.newInvasionHost);
        services.listen!(InvasionHost, InvasionState)(&invasionHere.invasionHeard);
        services.provide!WeatherHost((const(ubyte)[] state) => WeatherHost(this, state));
        weather = ZoneWeather(this);
        services.listen!(WeatherHost, WeatherNotice)(&weather.heard);
        services.provide!WarEffortHost(&warEffortHere.newWarEffortHost);
        services.listen!(WarEffortHost, WarEffort)(&warEffortHere.warEffortHeard); // before it starts: it tells as it does
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
        links.queueLinked(m.id, m.instanceId, back);
        if (auto script = m.instanceId in instanceScripts)
        {
            import dmangos.script.api : CreatureLoaded, EntityRef;

            script.raise(CreatureLoaded(EntityRef(back.guid)));
        }
    }

    /// Spawn `guid`, dead and waiting, is due now.
    package void respawnSpawnNow(uint guid)
    {
        if (creaturePools.manages(guid))
        {
            if (creaturePools.waiting(guid))
                creaturePools.dead(guid, unixTime, true);
            return;
        }
        if (auto at = guid in deadCreatures.respawnAt)
            if (*at > unixTime)
            {
                *at = unixTime;
                database.saveCreatureRespawn(guid, unixTime);
            }
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









    /// Whether a spawn is up in its pool (`pool_*`): in none, or rolled.
    bool upInPool(PoolMember.Kind kind, uint guid)
    {
        if (kind == PoolMember.Kind.creature && creaturePools.manages(guid))
            return creaturePools.selected(guid);
        if (kind == PoolMember.Kind.gameObject && objectRespawns.gameObjectPools.manages(guid))
            return objectRespawns.gameObjectPools.selected(guid);
        return data.pools is null || data.pools.spawns(kind, guid);
    }

    /**
     * A pooled spawn's respawn time is up: its pool rolls again (CMaNGOS's `UpdatePool`). True if it comes back
     * itself; otherwise the member rolled in its place comes after a respawn time of its own (`respawnIn`, given
     * the member: saved as its respawn), and this one stays away.
     */
    package bool rerolledBack(PoolMember.Kind kind, uint guid, scope void delegate(uint member) respawnIn)
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



    import dmangos.world.scourgelayout : InvasionLayout;




    // -----------------------------------------------------------------------
    // The Ahn'Qiraj war effort (`dmangos.world.wareffort`)
    // -----------------------------------------------------------------------






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
            &calendar.gameEvents.holidayActive, now, seed);
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
            return cast(int) warEffortHere.warEffort.daysLeft(unixTime);
        foreach (i, ref resource; resources)
        {
            if (resource.nowState == id)
                return cast(int) warEffortHere.warEffort.counters[i];
            if (resource.goalState == id)
                return cast(int) resource.goal;
        }
        foreach (i, ref zone; invasionZones)
        {
            if (zone.marker == id)
                return invasionHere.invasion.remaining(i) != 0;
            if (zone.remaining == id)
                return cast(int) invasionHere.invasion.remaining(i);
        }
        return 0;
    }

    package bool conditionWorldScript(uint id, uint expected)
    {
        import dmangos.world.scourge : invasionZones;
        import dmangos.world.wareffort : resources, worldStateDaysLeft;

        if (id == worldStateDaysLeft)
            return warEffortHere.warEffort.daysLeft(unixTime) == expected;
        foreach (i, ref resource; resources)
            if (resource.nowState == id)
                return warEffortHere.warEffort.counters[i] >= resource.goal;
        foreach (i, ref zone; invasionZones)
            if (zone.marker == id)
                return invasionHere.invasion.remaining(i) != 0;
        return false;
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
        calendar.gameEventSpawnsChanged();
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
            deadCreatures.restoreInstanceCorpses(created);
            if (recovery.ownsDungeonFights(created))
                recovery.restoreDungeonFights(created, false);
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
            owns = (ulong cell) => ownsCell(id, cell) && !recovery.recoveryHolds(id, cell);
        else if (config.cluster.enabled)
            owns = (ulong cell) => !recovery.recoveryHolds(id, cell);
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
                            auto migrant = migrants.saveMigratingObject(creature, false);
                            migrant.home = cellKeyAt(creature.spawn.x, creature.spawn.y);
                            return migrant;
                        }
                        if (auto go = cast(GameObject) object)
                        {
                            const expires = scriptedGameObjects.get(GameObjectOnMap(created, go.guid), 0L);
                            auto migrant = migrants.saveMigratingObject(go, false, expiresOverride: expires);
                            migrant.home = cellKeyAt(go.spawn.x, go.spawn.y);
                            return migrant;
                        }
                        return Migrant.init;
                    };
                    script.restoreSummon = (const ref Migrant migrant) {
                        import dmangos.log : warning;

                        try
                        {
                            auto object = migrants.restoreWorldMigrant(migrant, created);
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
                    script.signalObject = &objectScripts.gameObjectSignalled;
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
                    script.signalObject = &objectScripts.gameObjectSignalled;
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
        if (!config.cluster.enabled || object.guid !in recovery.outdoorQuestActors)
            return false;
        if (auto creature = cast(Creature) object)
            return creature.alive && (creature.summon.timed || recovery.hasOutdoorFactionChange(creature));
        return (cast(GameObject) object) !is null;
    }

    /// A freshly spawned object became `map`'s own (loaded with its cell or put there by a script): a scripted game
    /// object's `Spawned` is raised in the world's phase.
    package void objectArrived(Map map, MapObject object)
    {
        if (auto go = cast(GameObject) object)
            if (go.behaviour && scripts.handles!(imported!"dmangos.script.api".Spawned)(go.behaviour))
                objectScripts.objectArrivals ~= objectScripts.GameObjectArrival(go, map);
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
        links.linkedDeath(map, c); // its pack's part first, while it is still known
        c.die(map, unixTime);
        if (const checkpoint = c.guid in recovery.outdoorQuestActors)
            if (!checkpoint.player)
                recovery.discardQuestActor(c);
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
            recovery.checkpointOutdoorFight(creature);
        else if (!battlegroundOfMap(map.id))
            recovery.checkpointDungeonFight(map, creature);
    }

    /// A quest's actor on `map` did something its script's state follows: kept for a crash (outdoors, clustered).
    package void questActorChanged(Map map, Creature creature, ulong player, bool immediate)
    {
        if (!map.instanceId && config.cluster.enabled)
            recovery.checkpointQuestActor(map, creature, player, immediate);
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
            foreach (ref corpse; deadCreatures.outdoorCorpses.byValue)
            {
                const spawn = recovery.outdoorCorpseSpawn(corpse);
                if (spawn.guid && spawn.map == id)
                    if (auto creature = created.creatureAt(loans.loanGuid(&spawn)))
                        if (creature.loot !is null)
                            creature.loot.resumeRollsFor(who.character.guid);
            }
            foreach (guid; objectRespawns.outdoorChests.byKey)
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
            recovery.discardQuestActor(creature);
            creature.ai.releaseBehaviour();
        }
        else if (auto go = cast(GameObject) object)
        {
            const checkpoint = go.guid in recovery.outdoorQuestActors;
            if (checkpoint !is null && canWrite()
                && (ownsCell is null || ownsCell(go.spawn.map, checkpoint.home)))
            {
                recovery.outdoorQuestActors.remove(go.guid);
                if (go.type == GameObjectType.chest)
                {
                    objectRespawns.outdoorChests.remove(go.spawn.guid);
                    database.finishScriptedOutdoorChest(config.realmId, go.guid, go.spawn.guid);
                }
                else
                    database.deleteQuestActor(config.realmId, go.guid);
                settleWrites();
            }
            auto key = GameObjectOnMap(map, go.guid);
            objectScripts.tickingObjects.remove(key);
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
                if (loans.creatureOnLoan(spawn.guid))
                    continue;
                if (const corpse = spawn.guid in deadCreatures.outdoorCorpses)
                    if (corpse.expiresAt > unixTime)
                    {
                        auto where = existingMap(mapId);
                        if (where is null || where.creatureAt(loans.loanGuid(spawn)) !is null)
                            continue;
                        try
                        {
                            const migrant = recovery.outdoorCorpseMigrant(*spawn, *corpse);
                            if (auto restored = deadCreatures.restoreSavedCorpse(where, migrant))
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
                if (deadCreatures.awaitingRespawn(spawn.guid))
                    continue; // dead: it comes back when its time is up
                if (!calendar.creatureInEvents(spawn.guid) || !dungeons.groupSpawnAllowed(existingMap(mapId), 0, spawn.guid))
                    continue; // its game event or spawn group says it is away
                if (!upInPool(PoolMember.Kind.creature, spawn.guid))
                    continue; // another of its pool is up
                if (auto creature = makeCreature(spawn))
                {
                    spawned ~= creature;
                    links.queueLinked(mapId, 0, creature);
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
        if ((spawn.respawnSeconds < 0 && !calendar.eventActivatesObject(spawn.guid)) || objectRespawns.gameObjectAwaitingRespawn(spawn.guid)
            || !calendar.gameObjectInEvents(spawn.guid) || !upInPool(PoolMember.Kind.gameObject, spawn.guid)
            || !dungeons.groupSpawnAllowed(existingMap(spawn.map), 1, spawn.guid))
            return null;
        auto object = makeGameObject(spawn);
        if (const saved = spawn.guid in objectRespawns.outdoorChests)
            objectRespawns.restoreOutdoorChest(object, *saved);
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
                    if (calendar.gameEvents.isActive(e.event))
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
        // Its spawn's data (`creature_spawn_data`): a model, equipment, faction, flags of its own.
        const spawnData = petNumber ? null : spawnDataFor(spawn.guid);
        const display = spawnData !is null && spawnData.modelId ? spawnData.modelId : chooseDisplay(*template_, spawnRandom);
        if (display == 0)
            return null;
        const level = chooseLevel(*template_, spawnRandom);
        const equipment = shape !is null && shape.equipment ? shape.equipment
            : spawnData !is null && spawnData.equipmentId != -1 ? cast(uint) spawnData.equipmentId : template_.equipmentTemplateId;
        auto parts = creatureParts(*template_, spawn.guid, display, level, equipment);
        auto creature = new Creature(*spawn, template_, display, level, parts, client, petNumber);
        if (const set = spawn.entry in data.creatureImmunities)
            creature.immunitySet = *set;
        if (spawnData !is null)
            applySpawnData(creature, *spawnData);
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
    /// The `creature_spawn_data_template` row spawn `guid` is bound to, if any.
    const(imported!"dmangos.world.worlddata".SpawnDataTemplate)* spawnDataFor(uint guid) const
    {
        if (const id = guid in data.spawnDataOf)
            return *id in data.spawnDataTemplates;
        return null;
    }

    /**
     * What a spawn's data gives it (CMaNGOS's `Creature::LoadFromDB` and `UpdateEntry` with its spawn template): a
     * faction, NPC and unit flags, health and mana of its own; running, hovering or floating as it comes (its
     * relay starts as its cell loads: `Map.loadCell`).
     */
    private void applySpawnData(Creature creature, const ref imported!"dmangos.world.worlddata".SpawnDataTemplate d)
    {
        import dmangos.world.movement : MovementFlags;
        import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE, UNIT_FIELD_FLAGS, UNIT_FIELD_HEALTH,
            UNIT_FIELD_MAXHEALTH, UNIT_FIELD_MAXPOWER1, UNIT_FIELD_POWER1, UNIT_NPC_FLAGS;

        if (d.faction)
            if (const entry = client.factionTemplates.lookup(d.faction))
            {
                creature.factionTemplate = entry;
                creature.values.set!UNIT_FIELD_FACTIONTEMPLATE(d.faction);
            }
        if (d.npcFlags != -1)
            creature.values.set!UNIT_NPC_FLAGS(cast(uint) d.npcFlags);
        if (d.unitFlags != -1)
            creature.values.set!UNIT_FIELD_FLAGS(cast(uint) d.unitFlags);
        if (d.curHealth)
        {
            const most = creature.values.get!UNIT_FIELD_MAXHEALTH;
            creature.values.set!UNIT_FIELD_HEALTH(d.curHealth < most ? d.curHealth : most);
        }
        if (d.curMana)
        {
            const most = creature.values.get!UNIT_FIELD_MAXPOWER1;
            creature.values.set!UNIT_FIELD_POWER1(d.curMana < most ? d.curMana : most);
        }
        enum uint runOnSpawn = 0x01, hover = 0x02, gravityOff = 0x04;
        if (d.spawnFlags & runOnSpawn)
            creature.movement.flags &= ~MovementFlags.walkMode;
        if (d.spawnFlags & hover)
        {
            creature.spawnHover = true;
            creature.movement.flags |= MovementFlags.hover;
        }
        if (d.spawnFlags & gravityOff)
        {
            creature.movement.flags |= MovementFlags.levitating;
            creature.scriptFlying = true;
        }
        creature.values.clearChanges();
    }

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
    package ushort eventShapeOf(uint guid)
    {
        if (auto list = guid in data.eventCreatures)
            foreach (ref e; *list)
                if (calendar.gameEvents.isActive(e.event))
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











    package size_t[uint] spawnIndex, gameObjectSpawnIndex; // spawn guid -> its place in the world data
    private size_t indexedCreatureSpawns, indexedGameObjectSpawns;
    private uint initialCreatureSpawn, initialGameObjectSpawn;

    /// Saved GM additions can predate a takeover without appearing in the old owner's bundle.
    package void discoverSavedSpawns(const(Region)[] gained)
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
                    spawnEditor.registerCreatureSpawn(saved);
            foreach (ref saved; database.savedGameObjectSpawnsAfter(initialGameObjectSpawn))
            {
                if (saved.guid >= temporaryCounterStart || saved.guid in gameObjectSpawnIndex
                    || !gainedHome(saved.map, saved.x, saved.y, saved.z, saved.orientation))
                    continue;
                const template_ = saved.entry in data.gameObjectTemplates;
                if (template_ is null || template_.type == GameObjectType.moTransport)
                    continue;
                spawnEditor.registerGameObjectSpawn(saved);
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

    package void indexSpawns()
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

            if (objectScripts.raiseObject(trap, map, TrapSprung(EntityRef(session.character.guid))))
                return;
        }
        // A trap with a script is asked first (one only its creature springs refuses players).
        if (trap.behaviour && objectScripts.gameObjectUsed(trap, map, session.character.guid))
            return;
        trap.trapReadyAt = unixTime + (trap.template_.data[5] > 0 ? trap.template_.data[5] : 1);
        if (spell == 0)
            return;
        session.castTriggeredAt(spell, session.character.guid);
        const charges = trap.template_.data[4];
        if (charges > 0 && ++trap.trapUses >= charges)
            map.gameObjectUsedUp(trap);
    }

    package auto trapTarget(GameObject trap, Inhabitant who)
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

        return objectScripts.raiseObject(go, map, TrapDisarmed(EntityRef(player)));
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

    /// A game object on its map, as the busy scripts (`ObjectScripts`), migration and recovery key it.
    package static struct GameObjectOnMap
    {
        Map map;
        ulong guid; // distinct copies of a dungeon use the same spawn GUIDs
    }

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
            deadCreatures.respawnAt[corpse.spawn.guid] = unixTime + 1;
            database.saveCreatureRespawn(corpse.spawn.guid, deadCreatures.respawnAt[corpse.spawn.guid]);
        }
        map.corpseExpired(corpse);
    }


    /// A game object from its spawn, with what it needs to show players their quests' objects.
    GameObject makeGameObject(scope const ref GameObjectSpawn spawn)
    {
        auto go = new GameObject(spawn, spawn.entry in data.gameObjectTemplates);
        // A door or button its spawn's addon has open or shut (`gameobject_addon.state`, -1 its template's way).
        if (const state = spawn.guid in data.gameObjectAddonStates)
            if (go.template_ !is null && (go.template_.type == GameObjectType.door || go.template_.type == GameObjectType.button))
            {
                import dmangos.world.updatefields : GAMEOBJECT_STATE;

                go.values.set!GAMEOBJECT_STATE(*state);
                go.values.clearChanges();
            }
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
            if (!loans.localCreatureLoans.length || canWrite())
                mapsPhase(elapsed);
        });
        timed(TickPhase.deaths, () => deathsPhase());
        timed(TickPhase.world, () {
            loans.updateCreatureLoans(now);
            remoteSpells.deliverReplicaSpells(now);
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
                deadCreatures.creatureDied(creature);
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
        recovery.refreshQuestActors(true);
        recovery.retryRegionRecovery();
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
        recovery.updateOutdoorScriptActors();
        recovery.updateDungeonFights();
        foreach (script; instanceScripts) // the dungeon scripts' own timers
            script.tick(cast(int) elapsed.total!"msecs");
        foreach (script; worldScripts) // the continents'
            script.tick(cast(int) elapsed.total!"msecs");
        objectScripts.gameObjectScriptsTick(cast(int) elapsed.total!"msecs");
        weather.poll(now);
        catalogs.poll(this, now);
        guildWriter.poll(this, now);
        addPendingNavigation();
        checkHonorWeek(now);
        services.tick(elapsed);
        groupRelay.pollLootCoinCredits(now);
        pollScriptCredits(now);
        releaseSettledSessions();
        groupRelay.pollBattlegroundRewards(now);
        worldPvp.tick(elapsed);
        if (battlegroup is null || battlegroup.host is this) battlegrounds.tick(elapsed);
        remoteSpells.landObjectAnimations(now);
        calendar.updateGameEvents(now);
        if (lastConditionalSpawnCheck == MonoTime.init || now - lastConditionalSpawnCheck >= 1.seconds)
        {
            lastConditionalSpawnCheck = now;
            dungeons.refreshConditionalSpawns();
        }
        removeExpiredBones();
        if (forwardGroup is null) // the coordinator, or alone (not while starting: who coordinates is not known yet)
        {
            calendar.eventMails();
            groupService.meetingStonesTick(elapsed); // the meeting stones' queue is the groups' keeper's
        }
        fleet.updateShips();
        links.linkFollowers();
        scriptedGameObjectsDue();
        deadCreatures.respawnDue(now);
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

    package CreaturePools creaturePools;
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
    context.calendar.gameEvents.events[5] = GameEvent(5, ScheduleType.date, now + 3600, now + 7200, 1440, 60, 0, "test");
    context.calendar.updateGameEvents(context.clock(), true);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const guid = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    assert(context.map(0).findObject(guid) is null, "its event has not started");

    context.calendar.gameEvents.events[5].start = now - 60; // it is on now
    context.calendar.updateGameEvents(context.clock(), true);
    assert(context.calendar.gameEvents.isActive(5) && context.map(0).findObject(guid) !is null, "it came with its event");

    context.calendar.gameEvents.events[5].end = now - 1; // and over
    context.calendar.updateGameEvents(context.clock(), true);
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
    context.calendar.gameEvents.events[6] = GameEvent(6, ScheduleType.date, now + 3600, now + 7200, 1440, 60, 0, "test");
    context.calendar.updateGameEvents(context.clock(), true);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    const guid = makeGuid(HighGuid.unit, creatureBanker, bankerSpawn);
    auto m = context.map(0);
    const usual = (cast(Creature) m.findObject(guid)).values.get!UNIT_FIELD_DISPLAYID;
    assert(usual != 4242);

    context.calendar.gameEvents.events[6].start = now - 60;
    context.calendar.updateGameEvents(context.clock(), true);
    auto dressed = cast(Creature) m.findObject(guid);
    assert(dressed.values.get!UNIT_FIELD_DISPLAYID == 4242 && dressed.eventShape == 6, "the event's model");

    context.calendar.gameEvents.events[6].end = now - 1;
    context.calendar.updateGameEvents(context.clock(), true);
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
    context.calendar.gameEvents.events[5] = GameEvent(5, ScheduleType.date, now + 3600, now + 7200, 1440, 60, 0, "test");
    context.data.gameEventMails[5] = [EventMail(0x1, 0, 0, 16285)]; // to humans
    context.data.gameEventMails[-5] = [EventMail(0x2, 0, 0, 16285)]; // to orcs, as it ends: none here
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    context.calendar.updateGameEvents(context.clock(), true);
    context.calendar.eventMails();
    assert(db.mails.length == 0, "not on yet");

    context.calendar.gameEvents.events[5].start = now - 60;
    context.calendar.updateGameEvents(context.clock(), true);
    context.calendar.eventMails();
    context.calendar.eventMails();
    assert(db.mails.length == 1 && db.mails.values[0].receiver == 7 && db.mails.values[0].sender == 16285, "one letter");
    assert(db.gameEventStatusRows.keys == [ushort(5)]);

    auto restarted = newCreationContext(db); // the same database: the event was on
    restarted.calendar.gameEvents.events[5] = context.calendar.gameEvents.events[5];
    restarted.data.gameEventMails = context.data.gameEventMails;
    restarted.calendar.updateGameEvents(restarted.clock(), true);
    restarted.calendar.eventMails();
    assert(db.mails.length == 1, "nothing again after a restart");

    restarted.calendar.gameEvents.events[5].end = now - 1;
    restarted.calendar.updateGameEvents(restarted.clock(), true);
    restarted.calendar.eventMails();
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
    auto ground = from.spawnEditor.spawnGameObjectAt(field, template_.entry, at, true);
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
    from.recovery.regionsChanged(null, [region], null, leaving);
    assert(from.battlegrounds.find(instance) is null);
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    to.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
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
    auto flag = from.spawnEditor.spawnGameObjectAt(map, banner.entry, Position(1500, 1480, 353), true);
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
    auto focus = from.spawnEditor.spawnGameObjectAt(oldMap, template_.entry, at, true);
    focus.forceDespawn(oldMap, 700);
    focus.tick(oldMap, 100);

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(91, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    from.recovery.regionsChanged(null, [region], null, leaving);
    assert(oldMap.isReplica(summon.guid) && oldMap.isReplica(focus.guid));
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    to.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
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
    auto creature = oldOwner.spawnEditor.spawnCreatureAt(oldMap, creatureInnkeeper, at);
    auto object = oldOwner.spawnEditor.spawnGameObjectAt(oldMap, door.entry, at, true);
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

    auto wrongCell = oldOwner.migrants.saveMigrant(object);
    wrongCell.home = cellKeyAt(at.x + 100, at.y);
    assert(newOwner.migrants.restoreWorldMigrant(wrongCell, newMap) is null);
    assert(object.spawn.guid !in newOwner.gameObjectSpawnIndex);

    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    oldOwner.recovery.regionsChanged(null, [region], null, leaving);
    assert(oldMap.isReplica(creature.guid) && oldMap.isReplica(object.guid));
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    newOwner.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
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
    assert(oldOwner.migrants.saveMigrant(summon).kind == MigrantKind.none, "totems use their existing owner lifecycle");
    summon.totemOwner = 0;

    auto wrongHome = oldOwner.migrants.saveMigrant(summon);
    wrongHome.home = cellKeyAt(at.x + 100, at.y);
    assert(newOwner.migrants.restoreWorldMigrant(wrongHome, destination) is null);
    const x = cellCoordinate(at.x), y = cellCoordinate(at.y);
    auto region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    oldOwner.recovery.regionsChanged(null, [region], null, leaving);
    assert(source.isReplica(summon.guid));
    now += 300.msecs;
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    newOwner.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
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
    cold.recovery.regionsChanged([region], null, null, unused);
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
    owner.deadCreatures.saveNewCorpse(summon);
    assert(db.loadOutdoorCorpses().length == 1 && summon.spawn.guid !in db.creatureRespawns);

    const x = cellCoordinate(spot.x), y = cellCoordinate(spot.y);
    const region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 2, 1, RegionState.granted);
    ubyte[][uint] unused;
    replacement.recovery.regionsChanged([region], null, null, unused);
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
    auto chest = source.spawnEditor.spawnGameObjectAt(oldMap, template_.entry, at, true);
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
    source.recovery.regionsChanged(null, [region], null, leaving);
    assert(oldMap.isReplica(chest.guid) && opcodesOf(client.read()).canFind(Opcode.SMSG_LOOT_RELEASE_RESPONSE));
    now += 2.seconds;
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    destination.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
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
        world.spawnEditor.registerGameObjectSpawn(original);
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
    assert(from.spawnEditor.respawnGameObjectAs(source, old, changed) is null);
    assert(db.savedGameObjectSpawn(original.guid).get == original && source.gameObjectAt(old.guid) is old);
    // Both cells are now on the same owner. The command can move the object between them.
    from.ownsCell = (uint, ulong) => true;
    auto moved = from.spawnEditor.respawnGameObjectAs(source, old, changed);
    assert(moved !is null && moved.spawn == changed && db.savedGameObjectSpawn(original.guid).get == changed);
    moved.useDoorOrButton(source);

    const x = cellCoordinate(changed.x), y = cellCoordinate(changed.y);
    Region region = Region(1, 0, CellRect(x, y, x + 1, y + 1), 1, 1, RegionState.revoking, 2);
    ubyte[][uint] leaving, unused;
    from.recovery.regionsChanged(null, [region], null, leaving);
    assert(source.isReplica(old.guid));
    region.owner = 2;
    region.state = RegionState.granted;
    region.next = 0;
    to.recovery.regionsChanged([region], null, [region.id: cast(const(ubyte)[]) leaving[region.id]], unused);
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
        world.spawnEditor.registerGameObjectSpawn(original);
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
    assert(from.spawnEditor.respawnGameObjectAs(oldMap, oldMap.gameObjectAt(guid), changed) !is null);

    // The replacement gets the new cell first. Its copy of the row still points into the old cell.
    auto replacement = to.map(0);
    bool ownsOld;
    to.ownsCell = (uint, ulong cell) => cell == newHome || (ownsOld && cell == oldHome);
    const x = cellCoordinate(changed.x), y = cellCoordinate(changed.y);
    const gained = Region(1, 0, CellRect(x, y, x + 1, y + 1), 2, 2, RegionState.granted);
    ubyte[][uint] leaving;
    to.recovery.regionsChanged([gained], null, null, leaving);
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
            node.spawnEditor.registerCreatureSpawn(creature);
            node.spawnEditor.registerGameObjectSpawn(object);
            node.data.gameObjectTemplates[door.entry] = door;
        }
        bool moving;
        oldOwner.ownsCell = (uint map, ulong cell) => !moving && map == 0 && cell == home;
        newOwner.ownsCell = (uint map, ulong cell) => moving && map == 0 && cell == home;
        bystander.ownsCell = (uint, ulong) => false;
        const deadline = oldOwner.unixTime + 10;
        oldOwner.deadCreatures.respawnAt[creature.guid] = deadline;
        oldOwner.objectRespawns.gameObjectRespawnAt[object.guid] = deadline;
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
            oldOwner.recovery.regionsChanged(null, [region], null, leaving);
            assert(leaving[region.id].length > 8);
        }
        region.owner = 2;
        region.state = RegionState.granted;
        region.next = 0;
        const(ubyte)[][uint] arriving = clean ? [region.id: cast(const(ubyte)[]) leaving[region.id]] : null;
        newOwner.recovery.regionsChanged([region], null, arriving, unused);
        assert(newOwner.deadCreatures.awaitingRespawn(creature.guid) && newOwner.objectRespawns.gameObjectAwaitingRespawn(object.guid));
        auto map = newOwner.map(0);
        map.loadCell(home);
        const creatureGuid = makeGuid(HighGuid.unit, creature.entry, creature.guid);
        const objectGuid = makeGuid(HighGuid.gameObject, object.entry, object.guid);
        assert(map.findObject(creatureGuid) is null && map.findObject(objectGuid) is null);

        db.saveCreatureRespawn(creature.guid, deadline); // by then the departing writer has settled
        db.saveGameObjectRespawn(object.guid, deadline);
        bystander.deadCreatures.respawnAt[creature.guid] = deadline;
        bystander.objectRespawns.gameObjectRespawnAt[object.guid] = deadline;
        now += 11.seconds;
        bystander.deadCreatures.respawnDue(now);
        assert(db.creatureRespawns[creature.guid] == deadline && db.gameObjectRespawns[object.guid] == deadline,
            "another node cannot clear the owning node's timers");
        newOwner.deadCreatures.respawnDue(now);
        auto alive = map.creatureAt(creatureGuid);
        auto ready = map.gameObjectAt(objectGuid);
        assert(alive !is null && alive.alive && ready !is null);
        assert(creature.guid !in db.creatureRespawns && object.guid !in db.gameObjectRespawns);
        now += 2.seconds;
        newOwner.deadCreatures.respawnDue(now);
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
            oldOwner.deadCreatures.saveNewCorpse(rare);
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
                oldOwner.recovery.regionsChanged(null, [region], null, leaving);
            region.owner = 2;
            region.state = RegionState.granted;
            region.next = 0;
            const(ubyte)[][uint] arriving = scenario == Scenario.clean
                ? [region.id: cast(const(ubyte)[]) leaving[region.id]] : null;
            winner.recovery.regionsChanged([region], null, arriving, unused);
            auto destination = winner.map(0);
            destination.loadCell(homes[first]);
            assert(winner.deadCreatures.awaitingRespawn(start));
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
            oldOwner.deadCreatures.respawnDue(clock);
        if (remote !is winner)
            remote.deadCreatures.respawnDue(clock);
        assert(db.loadCreaturePoolStates(realm)[pool] == dead, "only the owner of the selected home can roll");
        expectRoll(winner, start, alternate);
        winner.deadCreatures.respawnDue(clock);
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
        finalOwner.deadCreatures.respawnDue(clock);
        auto destination = finalOwner.map(0);
        destination.loadCell(homes[second]);
        assert(!finalOwner.upInPool(kind, start) && finalOwner.deadCreatures.awaitingRespawn(alternate));
        assert(destination.creatureAt(alternateGuid) is null);

        clock += 11.seconds;
        expectRoll(finalOwner, alternate, alternate);
        finalOwner.deadCreatures.respawnDue(clock);
        const live = db.loadCreaturePoolStates(realm)[pool];
        auto placed = destination.creatureAt(alternateGuid);
        assert(live.spawn == alternate && !live.due && live.revision == 3 && placed !is null && placed.alive);
        clock += 2.seconds;
        finalOwner.deadCreatures.respawnDue(clock);
        if (remote !is winner && remote !is finalOwner)
            remote.deadCreatures.respawnDue(clock);
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
    assert(upgraded.upInPool(kind, unseeded) && upgraded.deadCreatures.awaitingRespawn(unseeded));
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
    original.objectRespawns.saveOpenedChest(original.map(0), opened);
    assert(db.loadOutdoorChests().length == 1);

    auto replacement = worker(3);
    const x = cellCoordinate(active[0].x), y = cellCoordinate(active[0].y);
    ubyte[][uint] unused;
    replacement.recovery.regionsChanged([Region(1, 0, CellRect(x, y, x + 1, y + 1), 3, 1, RegionState.granted)],
        null, null, unused);
    auto resumed = place(replacement, active[0]);
    assert(resumed !is null && resumed.loot.gold == 25 && resumed.loot.owners[7]);
    replacement.map(0).gameObjectUsedUp(resumed);
    assert(db.loadOutdoorChests().length == 0, "depletion and its cooldown commit together");

    other.map(0).gameObjectUsedUp(neighboring); // its cached pool revision predates the first use
    assert(db.loadGameObjectPoolStates(realm)[pool].revision == 1);
    assert(other.objectRespawns.gameObjectPools.refresh());
    const state = db.loadGameObjectPoolStates(realm)[pool];
    assert(state.revision == 2 && state.placements.length == 2 && state.placements.all!(slot => slot.due == epoch + 30));

    auto restarted = worker(4);
    foreach (spawn; placements)
        assert(place(restarted, spawn) is null, "no placement may appear during the saved cooldown");
    clock += 31.seconds;
    restarted.deadCreatures.respawnDue(clock);
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
    original.objectRespawns.saveOpenedChest(original.map(0), opened);
    assert(db.loadOutdoorChests().length == 1);

    auto away = new Failing(db);
    away.failures = 2;
    auto replacement = worker(3, away);
    const x = cellCoordinate(spawn.x), y = cellCoordinate(spawn.y);
    ubyte[][uint] unused;
    replacement.recovery.regionsChanged([Region(1, 0, CellRect(x, y, x + 1, y + 1), 3, 1, RegionState.granted)],
        null, null, unused);
    replacement.map(0).loadCell(home);
    assert(replacement.map(0).gameObjectAt(guid) is null, "the cell waits for the opened chests");
    replacement.recovery.retryRegionRecovery(); // too soon: no read
    assert(away.failures == 1);
    clock += 1.seconds;
    replacement.recovery.retryRegionRecovery(); // read, and fails again
    assert(replacement.map(0).gameObjectAt(guid) is null);
    clock += 1.seconds;
    replacement.recovery.retryRegionRecovery();
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
    context.recovery.regionsChanged([region], null, null, leaving);
    auto map_ = context.map(0);
    map_.loadCell(cellKeyAt(at.x, at.y));
    const creatureGuid = makeGuid(HighGuid.unit, creature.entry, creature.guid);
    const objectGuid = makeGuid(HighGuid.gameObject, object.entry, object.guid);
    assert(cast(Creature) map_.findObject(creatureGuid) !is null);
    assert(cast(GameObject) map_.findObject(objectGuid) !is null);
    assert(outside.guid !in context.spawnIndex);
    const creatureCount = context.data.creatureSpawns.length, objectCount = context.data.gameObjectSpawns.length;
    context.recovery.regionsChanged([region], null, null, leaving);
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
    const spawn = home.loans.loanSpawn(innkeeperSpawn, 0);
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
    const lent = home.loans.releaseCreatureLoan(lending);
    assert(lent.length, "lent alive");
    lease = loan;
    ubyte[][uint] leaving;
    borrower.recovery.regionsChanged([loan], null, [loan.id: lent], leaving);
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
    borrower.deadCreatures.saveNewCorpse(helper);
    assert(db.loadOutdoorCorpses().length == 1);

    // The borrower's lease lapses and comes back (or the term changes): it loses the loan, then holds it again.
    borrower.recovery.regionsChanged(null, [loan], null, leaving);
    assert(there.creatureAt(guid) is null);
    borrower.recovery.regionsChanged([loan], null, null, leaving);

    // The coordinator sends the helper home; the borrower has nothing to send with it.
    Region returning = loan;
    returning.creature.returning = true;
    returning.state = RegionState.revoking;
    returning.next = 1;
    lease = returning;
    const back = borrower.loans.releaseCreatureLoan(returning);
    returning.owner = 1;
    returning.state = RegionState.granted;
    returning.next = 0;
    lease = returning;
    home.recovery.regionsChanged([returning], null, [returning.id: back], leaving);
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
    const spawn = scripted.loans.loanSpawn(innkeeperSpawn, 0);
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
    node.deadCreatures.respawnDue(clock); // the only member is rolled again, kept, and the answer lost
    assert(db.loadGameObjectPoolStates(realm)[pool].placements[0].due == 0, "the roll committed");
    assert(map.gameObjectAt(guid) is null);
    clock += 1.seconds;
    node.deadCreatures.respawnDue(clock);
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
