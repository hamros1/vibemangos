/**
 * Entry point of the world server.
 *
 * ---
 * worldserver [--config FILE]
 * ---
 */
module dmangos.world.main;

import core.time : Duration, minutes, MonoTime, msecs, seconds;
import std.conv : to;
import std.getopt : defaultGetoptPrinter, getopt, GetOptException, GetoptResult;
import std.stdio : stderr;

import dmangos.cluster.link : LoadReport;
import dmangos.cluster.node : ClusterNode, CoordinatorSetup;
import dmangos.world.clusterbridge : ClusterBridge;
import dmangos.world.movement : Position;
import dmangos.world.fencing : FencedDatabase;
import dmangos.world.writebehind : replayLog, WriteBehind, Writer;
import dmangos.log;
import dmangos.metrics : ServerMetrics;
import dmangos.mysql : ConnectionInfo, MySqlConnection;
import dmangos.auth.mysqldb : MySqlLoginDatabase;
import dmangos.net.server : installShutdownHandlers, NetSession, requestShutdown, ServerOptions, TcpServer;
import dmangos.world.clientdata : ClientData;
import dmangos.world.config : loadWorldConfig, WorldConfig;
import dmangos.world.context : WorldContext;
import dmangos.world.database : MySqlWorldDatabase;
import dmangos.world.realm : RealmRegistration;
import dmangos.world.session : WorldSession;
import dmangos.world.worlddata : WorldData;

private enum usage = "dmangos world server for 1.12.x clients, on CMaNGOS databases

Usage:
  worldserver [--config FILE]
";

/*
 * The collector marks on one thread (docs/DESIGN.md, step 7): with one thread per core (the default),
 * marking the same heap took 57 ms on 32 cores against 20 on one; the threads mostly wait on each other.
 * `--DRT-gcopt=parallel:N` on the command line still overrides it.
 */
extern (C) __gshared string[] rt_options = ["gcopt=parallel:0"];

int main(string[] args)
{
    string configPath = "worldserver.json";
    GetoptResult options;
    try
        options = getopt(args, "config|c", "Configuration file (default: worldserver.json)", &configPath);
    catch (GetOptException e)
    {
        stderr.writeln(e.msg);
        return 2;
    }
    if (options.helpWanted || args.length > 1)
    {
        defaultGetoptPrinter(usage, options.options);
        return options.helpWanted ? 0 : 2;
    }

    try
    {
        auto config = loadWorldConfig(configPath);
        setLogLevel(config.logLevel);
        return run(config, configPath);
    }
    catch (Exception e)
    {
        error!"%s"(e.msg);
        return 1;
    }
}

/// The exit code for a restart (2, as CMaNGOS restart scripts expect), for a script that starts it again.
private enum restartExitCode = 2;

private int run(WorldConfig config, string configPath)
{
    auto login = connect(config.loginDatabase, config.mysqlLibrary, "login");
    scope (exit)
        login.close();
    auto characters = connect(config.characterDatabase, config.mysqlLibrary, "character");
    scope (exit)
        characters.close();
    auto world = connect(config.worldDatabase, config.mysqlLibrary, "world");
    scope (exit)
        world.close();

    auto client = ClientData.load(config.dataDir);
    // The nodes of a cluster must choose the same pooled and grouped spawns: they share a seed made from the
    // cluster's name and the realm (docs/CLUSTER.md). Standalone, the choice is new at every start.
    ulong spawnSeed;
    if (config.cluster.enabled)
    {
        import std.digest.crc : crc32Of;

        const crc = crc32Of(config.cluster.name ~ "/" ~ to!string(config.realmId));
        spawnSeed = (ulong(crc[0]) | crc[1] << 8 | crc[2] << 16 | ulong(crc[3]) << 24) | 1;
    }
    auto data = WorldData.load(world, client, spawnSeed);
    {
        // Out of the collector's heap (docs/DESIGN.md, step 7): it no longer marks them at every collection.
        import dmangos.frozen : arenaPlaced, freezeAll;

        freezeAll(data);
        info!"static data: %s MiB moved out of the collector's heap"(arenaPlaced >> 20);
    }
    // Nodes of a cluster started in one directory keep logs of their own.
    if (config.cluster.enabled && config.writeLog == WorldConfig.init.writeLog)
        config.writeLog = "writes-" ~ to!string(config.cluster.nodeId) ~ ".log";
    // Writes go behind the game loop (docs/DESIGN.md, step 6): to a thread with connections of its own,
    // logged first. What the log still holds from the last run is written before anything else.
    auto writerLogin = connect(config.loginDatabase, config.mysqlLibrary, "login (writer)");
    auto writerCharacters = connect(config.characterDatabase, config.mysqlLibrary, "character (writer)");
    auto writerWorld = connect(config.worldDatabase, config.mysqlLibrary, "world (writer)");
    scope (exit)
    {
        writerLogin.close();
        writerCharacters.close();
        writerWorld.close();
    }
    auto writerDatabase = new MySqlWorldDatabase(writerLogin, writerCharacters, writerWorld);
    // The stream of writes this server's ledger row counts (`WriteLedger`): one per realm and node.
    const uint writeStream = config.realmId << 16 | (config.cluster.enabled ? config.cluster.nodeId : 0);
    if (config.writeLog.length)
        replayLog(config.writeLog, writerDatabase, writeStream);
    auto writer = new Writer(writerDatabase, config.writeLog, true, writeStream);
    scope (exit)
    {
        writer.stop(); // what the last sessions saved is written before the connections close
        const s = writer.statistics;
        info!"writes: %s queued, %s written, %s replaced by newer ones, %s refused (lease), %s failed, %s retried"(
            s.queued, s.written, s.replaced, s.refused, s.failed, s.retried);
    }
    auto behind = new WriteBehind(new MySqlWorldDatabase(login, characters, world), writer, null);
    auto context = new WorldContext(config, behind, data, client, new MySqlLoginDatabase(login));
    context.writer = writer;
    context.configPath = configPath;
    // Every node serves clients (docs/CLUSTER.md); only a standalone server or a cluster's coordinator speaks
    // for the realm: its row in the realm list, and marking everyone offline at start.
    bool speaksForRealm = !config.cluster.enabled || config.cluster.isCoordinator; // the standby may take it over
    context.keepsHonorWeek = speaksForRealm; // the honor week is reckoned once, by the realm's speaker
    if (speaksForRealm)
        context.database.markAllOffline(config.realmId); // nobody is online after a restart
    if (config.cluster.enabled && config.cluster.clientAddress.length == 0)
        config.cluster.clientAddress = "127.0.0.1:" ~ to!string(config.port);
    info!"next ids: character %s, item %s, mail %s"(context.next.character, context.next.item, context.next.mail);
    auto realm = new RealmRegistration(login, config.realmId);
    if (speaksForRealm)
        realm.markOnline(config.allowedBuilds, config.gameType, config.realmZone);
    scope (exit)
        if (speaksForRealm)
            realm.markOffline();
    string realmAddress;     // where the realm list sends clients now (a cluster's coordinator chooses)
    auto lastSteering = MonoTime.currTime;

    auto lastPopulation = MonoTime.currTime;
    auto lastUptime = MonoTime.currTime;
    const uptimeInterval = config.uptimeUpdateMinutes.minutes;

    ServerMetrics metrics;
    auto lastMetrics = MonoTime.currTime;
    const metricsInterval = config.metricsIntervalSeconds.seconds;
    double tickAverageUs = 0; // a moving average, for the cluster's load reports

    TcpServer server;
    ClusterNode cluster;
    ClusterBridge bridge;
    bool leaseHeld;
    if (config.cluster.enabled)
        context.services.stopAll(); // in a cluster, only those whose regions it is granted (docs/SERVICES.md)
    if (config.cluster.enabled)
    {
        const linkIdle = (2 * config.cluster.failureTimeoutMs).msecs; // the links time out first, on heartbeats
        CoordinatorSetup setup;
        if (config.cluster.isCoordinator || config.cluster.standby) // the standby keeps it for a takeover
            setup = coordinatorSetup(config.cluster.regionCount, data, client, context);
        cluster = new ClusterNode(config.cluster, ClusterNode.newIncarnation(), () => MonoTime.currTime,
            (host, port, session) => server.connect(host, port, session, linkIdle),
            () => LoadReport(cast(uint) tickAverageUs, cast(uint) context.sessionCount, cast(uint) context.objectCount),
            setup);
        // The world simulates only what this node owns: maps ask, and are told of changes.
        context.ownsCell = (uint map, ulong cell) => cluster.regions.ownsCell(map, cell);
        cluster.onOwnership = &context.regionsChanged;
        cluster.onCreatureRelease = &context.releaseCreatureLoan;
        context.sendCreatureLoan = &cluster.creatureLoan;
        context.creatureLease = &cluster.regions.creatureRegion;
        // Replicas go both ways between nodes.
        bridge = new ClusterBridge(cluster, context, config.cluster.leaseMs);
        cluster.replication = bridge;
        context.replicator = bridge;
        // Players move to the node that owns the ground they stand on, their clients staying put.
        cluster.players = bridge;
        context.playerRelay = bridge;
        // Whispers to players other nodes simulate.
        context.whisperRemote = &bridge.whisperRemote;
        context.deliverRemote = &bridge.deliverRemote;
        context.requestMemberStats = &bridge.requestMemberStats;
        context.toEveryoneElsewhere = &bridge.toEveryoneElsewhere;
        context.gmRemote = &bridge.sendGmRemote;
        context.killShareElsewhere = &bridge.sendKillShare;
        context.sendRemoteGroupLoot = &bridge.sendGroupLootRoll;
        context.signalElsewhere = &bridge.sendScriptSignal;
        context.askDungeonEntry = &bridge.askDungeonEntry;
        context.announceFriendElsewhere = &bridge.announceFriend;
        context.guildReloadElsewhere = &bridge.sendGuildReload;
        context.guildBroadcastElsewhere = &bridge.sendGuildBroadcast;
        context.guildInviteElsewhere = &bridge.sendGuildInvitation;
        if (cluster.isCoordinator)
        {
            context.groups.changes = &bridge.groupChanged;
            context.groups.removed = &bridge.groupRemoved;
        }
        else
        {
            context.forwardGroup = &bridge.forwardGroup;
        }
        context.reserveStock = &bridge.reserveStock;
        context.releaseStock = &bridge.releaseStock;
        context.nodeId = cluster.id;
        context.regionOwnerAround = (uint map, Position at, float radius) {
            import dmangos.world.grid : cellKeyAt;

            const owner = cluster.regions.ownerAt(map, cellKeyAt(at.x, at.y));
            foreach (offset; [[radius, 0], [-radius, 0], [0, radius], [0, -radius]])
                if (cluster.regions.ownerAt(map, cellKeyAt(at.x + offset[0], at.y + offset[1])) != owner)
                    return ushort(0);
            return owner;
        };
        // A node whose lease lapsed writes nothing: by the time its accounts and regions go elsewhere it has
        // certainly stopped, and writes after that could overwrite theirs.
        context.database = new FencedDatabase(context.database, () => cluster.regions.leaseHolds(MonoTime.currTime));
        // Cluster services (docs/SERVICES.md): where each runs is in the region table; calls go over the links.
        {
            import dmangos.cluster.protocol : ServiceCall, ServiceNews, ServiceReply;
            import dmangos.cluster.services : serviceMap, ServiceKind;

            context.services.self = cluster.id;
            context.services.placement = (ServiceKind kind) => cluster.regions.ownerAt(serviceMap(kind), 0);
            context.services.sendCall = (ushort node, const ref ServiceCall c) => cluster.sendTo(node, c);
            context.services.sendReply = (ushort node, const ref ServiceReply r) => cluster.sendTo(node, r);
            cluster.onServiceCall = (ushort peer, const ref ServiceCall c) { context.services.receiveCall(peer, c); };
            cluster.onServiceReply = (ushort peer, const ref ServiceReply r) { context.services.receiveReply(peer, r); };
            context.services.sendNews = (const ref ServiceNews n) { cluster.broadcast(n); };
            cluster.onServiceNews = (ushort peer, const ref ServiceNews n) { context.services.receiveNews(peer, n); };
            context.askWarEffort(); // how it stands, once its service is placed (and every change after)
            context.worldPvp.ask(); // the same for world PvP
        }
        // And a queued write is dropped if the writer reaches it after the lease lapsed (step 6).
        behind.writableUntil = () {
            import std.datetime.systime : Clock;

            const ends = cluster.regions.leaseEnds, at = MonoTime.currTime;
            if (ends == MonoTime.max)
                return long.max;
            return Clock.currStdTime + (ends > at ? (ends - at).total!"hnsecs" : -1);
        };
        // One login per account across the cluster, and members' ids from the coordinator's blocks.
        cluster.sessions = context;
        context.claimSession = (uint account, ulong serial) => cluster.claimSession(account, serial);
        context.releaseSession = (uint account, ulong serial) => cluster.releaseSession(account, serial);
        if (!cluster.isCoordinator)
        {
            context.idPool = cluster.pool;
            // Groups are the coordinator's: this node mirrors them.
            context.groups.clear();
        }
        // Phase 7: the standby, become the coordinator, takes up the coordinator's part of the world server.
        cluster.onPromoted = () {
            context.forwardGroup = null;
            context.groups.clear();        // the groups too, from the database the old coordinator kept them in
            context.groups.load(context.database.loadGroups());
            context.groups.changes = &bridge.groupChanged;
            context.groups.removed = &bridge.groupRemoved;
            bridge.broadcastGroups();
            context.takeOverIds();
            speaksForRealm = true;
            context.keepsHonorWeek = true;
            realm.markOnline(config.allowedBuilds, config.gameType, config.realmZone);
            info!"cluster: this node is the coordinator now: groups, channels, ids and the realm are kept here"();
        };
        info!"cluster: node %s, incarnation %s, %s; clients at %s"(cluster.id, cluster.incarnation,
            cluster.isCoordinator ? "coordinator" : "member of " ~ config.cluster.coordinator,
            config.cluster.clientAddress);
    }

    installShutdownHandlers();
    MonoTime lastLoadReport;
    Duration lastBusy;
    server = new TcpServer(
        ServerOptions(config.bindAddress, config.port, config.idleTimeoutSeconds.seconds,
            config.maxConnections, config.updateIntervalMs.msecs),
        (string address) => cast(NetSession) new WorldSession(context, address),
        (MonoTime now) {
            if (context.update(now))
                requestShutdown();
            if (cluster !is null)
            {
                bridge.tick();
                cluster.tick();
                // A lapsed lease ends every session; their characters are not saved (the database is fenced).
                const holds = cluster.regions.leaseHolds(MonoTime.currTime);
                if (leaseHeld && !holds)
                {
                    error!"cluster: this node's lease lapsed: every session ends, and nothing more is written"();
                    writer.leaseLapsed(imported!"std.datetime.systime".Clock.currStdTime); // what was queued before is never written
                    context.kickAll("this server lost contact with the rest of the realm");
                }
                else if (holds)
                    writer.renewLease(behind.writableUntil()); // a write waiting for the database stays writable
                leaseHeld = holds;
            }
            const took = MonoTime.currTime - now;
            metrics.recordTick(took);
            tickAverageUs = tickAverageUs * 0.95 + took.total!"usecs" * 0.05;
            if (metricsInterval > Duration.zero && now - lastMetrics >= metricsInterval)
            {
                lastMetrics = now;
                const writes = writer.statistics;
                info!"%s; world: %s players, %s objects, %s ticking; writes: %s waiting, %s written, %s replaced, %s failed, %s retried%s"(
                    metrics.report(&server.busy), context.sessionCount, context.objectCount, context.tickingCount,
                    writes.waiting, writes.written, writes.replaced, writes.failed, writes.retried,
                    writes.stalled ? " (the database is unavailable)" : "");
                if (cluster !is null)
                {
                    foreach (line; cluster.describe())
                        info!"%s"(line);
                    info!"%s"(context.services.describe());
                }
            }
            // What this node's regions cost it, for the coordinator's balancing.
            if (cluster !is null && now - lastLoadReport >= 10.seconds)
            {
                const busyNow = server.busyTotal;
                if (lastLoadReport != MonoTime.init)
                    cluster.reportLoads(bridge.regionLoads(busyNow - lastBusy, now - lastLoadReport));
                lastBusy = busyNow;
                lastLoadReport = now;
            }
            // The coordinator sends new clients to the node with the fewest players.
            if (cluster !is null && cluster.isCoordinator && now - lastSteering >= 10.seconds)
            {
                lastSteering = now;
                const target = cluster.leastBusyClientAddress();
                if (target.length && target != realmAddress)
                {
                    import dmangos.cluster.config : splitAddress;

                    string host;
                    ushort port;
                    splitAddress(target, host, port);
                    realm.setAddress(host, port);
                    realmAddress = target;
                }
            }
            // Timed before the call: while the login database is unavailable, tried again at the interval,
            // not at every tick.
            if (speaksForRealm && now - lastPopulation >= 1.minutes)
            {
                lastPopulation = now;
                realm.updatePopulation(context.sessionCount, config.playerLimit);
            }
            if (speaksForRealm && now - lastUptime >= uptimeInterval)
            {
                lastUptime = now;
                realm.updateUptime(cast(uint) context.peakSessions);
            }
        });
    if (cluster !is null && !cluster.isCoordinator)
    {
        // A clean stop drains first: the regions go to the others with their objects, and the players
        // visiting from other nodes move on; then the node stops (at most `drainLimit` later).
        enum drainLimit = 20.seconds;
        MonoTime drainStarted;
        server.mayStop = () {
            if (cluster.isCoordinator)
                return true; // the standby that took over: a coordinator does not drain
            const now = MonoTime.currTime;
            if (drainStarted == MonoTime.init)
            {
                drainStarted = now;
                if (!cluster.drain())
                    return true; // no coordinator to hand them to: stop as if failed
                context.draining = true;
                info!"cluster: shutting down: handing this node's regions to the others first"();
                return false;
            }
            if (cluster.ownsNothing && bridge.visitors == 0)
            {
                info!"cluster: drained in %s ms; stopping"((now - drainStarted).total!"msecs");
                return true;
            }
            if (now - drainStarted >= drainLimit)
            {
                warning!"cluster: not drained after %s (%s region(s), %s visiting player(s) left); stopping anyway"(
                    drainLimit, cluster.regions.ownedRegions.length, bridge.visitors);
                return true;
            }
            return false;
        };
    }
    if (cluster !is null)
        server.addListener(config.cluster.listenAddress, config.cluster.listenPort,
            (string address) => cluster.accept(address), (2 * config.cluster.failureTimeoutMs).msecs);
    server.run();
    if (speaksForRealm)
        realm.updateUptime(cast(uint) context.peakSessions);
    return context.restartRequested ? restartExitCode : 0;
}

/**
 * The coordinator's start (docs/CLUSTER.md): every map of `Map.dbc` divided into about
 * `regionCount` regions by where creatures and game objects spawn, and the counters ids come from.
 */
private CoordinatorSetup coordinatorSetup(uint regionCount, WorldData data, ClientData client, WorldContext context)
{
    import dmangos.cluster.regions : CellCosts, costOf, partition;

    CellCosts costs;
    foreach (cells; [data.creatureCells, data.gameObjectCells])
        foreach (map, byCell; cells)
            foreach (cell, spawns; byCell)
                costs[map][cell] = costs.get(map, null).get(cell, 0) + cast(uint) spawns.length;
    uint[] maps;
    CoordinatorSetup setup;
    foreach (ref entry; client.maps.rows)
    {
        maps ~= entry.mapId;
        if (entry.isDungeon || entry.isBattleground)
            setup.whole[entry.mapId] = true; // one node hosts all of a dungeon's (or a battleground's) copies
    }
    setup.regions = partition(maps, costs, regionCount, setup.whole);
    foreach (ref r; setup.regions)
        setup.cost[r.id] = costOf(costs, r.map, r.rect);
    // The cluster services, a region each on maps of their own (docs/SERVICES.md): placed as regions are.
    {
        import dmangos.cluster.services : clusterServiceKinds, serviceRegions;

        uint next;
        foreach (ref r; setup.regions)
            next = r.id >= next ? r.id + 1 : next;
        foreach (r; serviceRegions(clusterServiceKinds, next))
        {
            setup.regions ~= r;
            setup.cost[r.id] = 1;
        }
    }
    setup.ids = context;
    size_t split;
    foreach (ref r; setup.regions)
        split += r.map == 0 || r.map == 1;
    info!"cluster: the world is divided into %s regions (%s of them on the two continents)"(setup.regions.length, split);
    foreach (ref r; setup.regions)
        if (setup.cost[r.id])
            info!"cluster:   region %s: map %s, cells x %s..%s, y %s..%s, %s spawns"(r.id, r.map, r.rect.x0, r.rect.x1 - 1,
                r.rect.y0, r.rect.y1 - 1, setup.cost[r.id]);
    return setup;
}

private MySqlConnection connect(string connectionString, string library, string what)
{
    const connection = ConnectionInfo.parse(connectionString);
    info!"%s database: %s"(what, connection.toString);
    return new MySqlConnection(connection, library);
}
