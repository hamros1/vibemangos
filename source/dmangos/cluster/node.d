/**
 * A world server's membership in a cluster (docs/CLUSTER.md).
 *
 * The coordinator admits nodes and keeps the **view**: the live members, with a version that
 * increases at every change. Members dial the coordinator, and each other (the lower node id dials
 * the higher, so a pair has one link); a member links only to peers in its latest view, with the
 * incarnation the view gives. A link that fails is dialed again, backing off from 250 ms to 5 s.
 *
 * Fencing: the coordinator remembers the highest incarnation of every node id it has admitted. A
 * restarted node (a higher incarnation) replaces the old one, whose link is closed; a hello from a
 * lower incarnation is refused as stale, and a node refused as stale by its coordinator stops
 * dialing and reports itself `fenced`: it gets no more lease confirmations, so its regions lapse.
 *
 * Regions (`dmangos.cluster.ownership`): the coordinator holds the `RegionAuthority` and
 * publishes its table whenever it changes; every node keeps a `RegionView`, renews its lease from the
 * coordinator's heartbeat echoes, and tells the world server (`onOwnership`) which regions it gained
 * and lost, then answers the releases the coordinator waits for. Ids come in blocks from the
 * coordinator's counters (`IdPool`, `IdCounters`).
 */
module dmangos.cluster.node;

import core.time : Duration, MonoTime, msecs, seconds, usecs;

import dmangos.cluster.config : ClusterConfig, splitAddress;
import dmangos.cluster.link;
import dmangos.cluster.ownership;
import std.exception : enforce;
import dmangos.cluster.protocol;
import dmangos.cluster.quorum : QuorumElection;
import dmangos.cluster.regions;
import dmangos.cluster.sessions;
import dmangos.log;
import dmangos.net.server : NetSession;

/// Opens a connection for `session` to `host:port`; a failure ends in `session.disconnected`.
alias Dialer = void delegate(string host, ushort port, NetSession session);

/**
 * Player messages a quorum node received while its lease had lapsed, kept for when it holds again in the
 * same term. Their sequences are consumed, so the sender never resends them, and a gateway takes a sent
 * arrival or recovery as delivered. Relayed client packets are bounded; route changes are always kept.
 */
private struct HeldPlayerMessages
{
    enum maxPackets = 4096;

    private static struct Held
    {
        ushort peer;
        ulong incarnation, term;
        immutable(ubyte)[] payload;
        bool packet;
    }

    private Held[] held;
    private size_t packets;

    @property size_t length() const { return held.length; }

    /// Keeps a message of `peer`'s process `incarnation`; false if it is a packet beyond the bound.
    bool hold(ushort peer, ulong incarnation, ulong term, const(ubyte)[] payload, bool packet)
    {
        if (packet && packets >= maxPackets)
            return false;
        held ~= Held(peer, incarnation, term, payload.idup, packet);
        if (packet)
            ++packets;
        return true;
    }

    /**
     * Delivers, in order, those from `term` whose sender is linked now as the same process. Those of
     * another term or process are dropped; those of a sender not linked now wait for its link.
     */
    void release(ulong term, scope ulong delegate(ushort) linkedIncarnation,
        scope void delegate(ushort, const(ubyte)[]) deliver)
    {
        auto pending = held;
        held = null;
        packets = 0;
        foreach (h; pending)
        {
            if (h.term != term)
                continue;
            const current = linkedIncarnation(h.peer);
            if (!current)
                hold(h.peer, h.incarnation, h.term, h.payload, h.packet);
            else if (current == h.incarnation)
                deliver(h.peer, h.payload);
        }
    }

    void clear()
    {
        held = null;
        packets = 0;
    }
}

unittest
{
    HeldPlayerMessages messages;
    ulong[ushort] linked = [2: 7];
    ubyte[][] delivered;
    ulong incarnation(ushort peer) { return linked.get(peer, 0); }
    void deliver(ushort, const(ubyte)[] payload) { delivered ~= payload.dup; }

    assert(messages.hold(2, 7, 1, [1], false) && messages.hold(3, 4, 1, [2], false));
    assert(messages.hold(2, 6, 1, [3], false) && messages.hold(2, 7, 0, [4], false));
    assert(messages.hold(2, 7, 1, [5], true));
    messages.release(1, &incarnation, &deliver);
    assert(delivered == [[1], [5]], "the same process's messages of the term, in order");
    assert(messages.length == 1, "an unlinked sender's message waits for its link");
    linked[3] = 4;
    messages.release(1, &incarnation, &deliver);
    assert(delivered == [[1], [5], [2]] && messages.length == 0);

    foreach (i; 0 .. HeldPlayerMessages.maxPackets)
        assert(messages.hold(2, 7, 1, [6], true));
    assert(!messages.hold(2, 7, 1, [6], true) && messages.hold(2, 7, 1, [7], false), "packets are bounded");
    messages.clear();
    assert(messages.length == 0);
}

/// What the coordinator starts with: the world divided into regions, and the id counters it hands out from.
struct CoordinatorSetup
{
    Region[] regions;     /// from `partition`
    ulong[uint] cost;     /// what each region costs, by id
    IdCounters ids;
    ushort[uint] pinned;   /// maps that share a battlegroup host
    bool[uint] whole;     /// maps that stay one region (dungeons: one node hosts all their copies)
}

/**
 * What a node does with replication messages: the world server implements it. Peers are
 * node ids; a peer linked anew needs this node's whole interest, a lost one's replicas go.
 */
interface ReplicationHandler
{
    void peerLinked(ushort peer);
    void peerLost(ushort peer);
    void interest(ushort peer, uint map, const(ulong)[] added, const(ulong)[] removed);
    void replicaCreate(ushort peer, uint map, ulong cell, ulong guid, const(ubyte)[] state);
    void replicaValues(ushort peer, uint map, ulong guid, const(ubyte)[] slots);
    void replicaMove(ushort peer, uint map, ulong guid, ushort opcode, const(ubyte)[] body_, const(ubyte)[] motion);
    void replicaRemove(ushort peer, uint map, ulong guid);
    void inRange(ushort peer, uint map, float x, float y, float z, float range, ushort opcode, const(ubyte)[] body_);
    void presence(ushort peer, bool full, const(PresenceEntry)[] entries, const(ulong)[] gone);
    void deliverTo(ushort peer, ulong guid, ushort opcode, const(ubyte)[] body_);
    void whisper(ushort peer, const ref WhisperMessage message);
    void stockRequest(ushort peer, const ref StockRequest message);
    void stockReply(ushort peer, const ref StockReply message);
    void stockRelease(ushort peer, const ref StockRelease message);
    void groupCommand(ushort peer, const ref GroupCommand message);
    void groupState(ushort peer, const ref GroupState message);
    void groupCatalog(ushort peer, const ref GroupCatalog message);
    void memberStatsRequest(ushort peer, const ref MemberStatsRequest message);
    void toEveryone(ushort peer, const ref ToEveryone message);
    void gmRemote(ushort peer, const ref GmRemote message);
    void killShare(ushort peer, const ref KillShare message);
    void groupLootRoll(ushort peer, const ref GroupLootRoll message);
    void lootCoinShare(ushort peer, const ref LootCoinShare message);
    void partyQuest(ushort peer, const ref PartyQuest message);
    void partySummon(ushort peer, const ref PartySummon message);
    void questLootCheck(ushort peer, const ref QuestLootCheck message);
    void partyHeal(ushort peer, const ref PartyHeal message);
    void partyAreaAura(ushort peer, const ref PartyAreaAura message);
    void totemWeaponEnchant(ushort peer, const ref TotemWeaponEnchant message);
    void mindVisionTarget(ushort peer, const ref MindVisionTarget message);
    void areaDamage(ushort peer, const ref AreaDamage message);
    void gameObjectSpell(ushort peer, const ref GameObjectSpell message);
    void scriptGameObject(ushort peer, const ref ScriptGameObject message);
    void scriptCreatureStep(ushort peer, const ref ScriptCreatureStep message);
    void creatureSwing(ushort peer, const ref CreatureSwing message);
    void periodicResult(ushort peer, const ref PeriodicResult message);

    /// A script's signal for a creature this node simulates.
    void scriptSignal(ushort peer, const ref ScriptSignal message);

    /// Guild news from another node: a guild changed, a guild's packet, an invitation.
    void guildNews(ushort peer, MessageType type, const(ubyte)[] payload);

    /// A player of another node logged in or out (its friends here hear of it).
    void friendStatus(ushort peer, const ref FriendStatusChange message);

    /// Whether a player may go into a dungeon this node hosts; and the answer to such a question.
    void dungeonEntryRequest(ushort peer, const ref DungeonEntryRequest message);
    /// ditto
    void dungeonEntryReply(ushort peer, const ref DungeonEntryReply message);
}

/// What a node does with messages about players simulated away from their client.
interface PlayerHandler
{
    void player(ushort peer, PlayerMessageKind kind, uint account, ushort opcode, const(ubyte)[] data);
    void sessionRouteResult(const ref SessionRoute route);
    GatewaySessionRoute[] gatewaySessionRoutes();
}

/// What a node does with session decisions: the world server implements it.
interface SessionHandler
{
    /// The session `serial` of `account` may enter the world.
    void sessionGranted(uint account, ulong serial);

    /// The session `serial` of `account` must end.
    void sessionEvicted(uint account, ulong serial);

    /// The coordinator is (again) linked: the sessions of this node are claimed anew.
    void claimAll();
}

/// See the module documentation.
final class ClusterNode : LinkOwner
{
    private enum Duration firstBackoff = 250.msecs, maxBackoff = 5.seconds;
    /// The dial plan key for the coordinator, whose node id is not known before its hello.
    private enum ushort coordinatorKey = 0;

    /// How long the standby waits, with no link to the coordinator, before taking over.
    enum Duration standbyGrace = 500.msecs;

    immutable ushort id;
    immutable ulong incarnation;

    private
    {
        ClusterConfig config;
        MonoTime delegate() clock;
        Dialer dialer;
        LoadReport delegate() load;
        Hello own;

        // The view: authoritative on the coordinator, the latest received on members.
        ulong viewCoordinator;  // the coordinator incarnation the view comes from
        ulong viewVersion;
        ViewMember[] members;

        ulong[ushort] highestIncarnation; // coordinator: fencing
        PeerSequences[ushort] sequences;   // by peer node id
        Link[ushort] links;                // open links, by peer node id
        Link[] handshaking;
        Dial[ushort] dials;                // peers this node dials, and the coordinator (`coordinatorKey`)
        ushort coordinatorId;              // members: the coordinator's id, once known
        bool fenced_;
        QuorumElection election;
        ulong quorumId, electedTerm;
        HeldPlayerMessages heldPlayers;    // received while the lease had lapsed
        SimulationOwner termLeader;
        MonoTime nextWorkerLease;
        ulong appliedOwnership;
        ulong[ushort] readyOwnership;

        // Phase 7: the coordinator role can move to the standby.
        bool coordinatorNow;               // whether this node is the coordinator now
        CoordinatorSetup standbySetup;     // the standby: what it takes over with
        ushort lostCoordinator;            // members: the coordinator whose link closed last, and when
        MonoTime lostCoordinatorAt;
        MonoTime lostCoordinatorHeard;
        bool[ushort] takeoverPending;      // new coordinator: members that have not accepted it yet
        MonoTime lastTakeoverSent;
        MonoTime promotedAt;               // lower bound for fencing leases granted by the old coordinator
        bool[ushort] takeoverGateways;     // gateways whose original client routes must be restored first
        SessionChange[] deferredSessionChanges;

        RegionAuthority authority;         // coordinator
        RegionView regions_;
        IdCounters ids;                    // coordinator
        MonoTime idGrantsFrom;             // coordinator: members' reports come in first
        IdRequest[][ushort] idRequests;    // coordinator: waiting for `idGrantsFrom`, by member
        IdPool pool_;                      // members
        SessionDirectory directory;        // coordinator
        ubyte[][uint] arriving;            // region id -> its objects' state, from its last owner
        ubyte[][uint] leaving;             // region id -> its objects' state, for its next owner
        SessionClaim[] claimsWaiting;      // members: sent once the coordinator is linked
        SessionReleased[] releasesWaiting; // ditto
    }

    /// Where session decisions go.
    SessionHandler sessions;

    /// Where messages about players simulated on another node go.
    PlayerHandler players;

    /**
     * The world server starts simulating `gained` and stops simulating `lost`. For a gained
     * region whose last owner handed over its objects, `arriving` has their state (by region id); for a
     * lost region on its way to another node (`Region.next`), the world puts its objects' state in
     * `leaving`, and it goes with the release.
     */
    void delegate(const(Region)[] gained, const(Region)[] lost, const(ubyte)[][uint] arriving,
        ref ubyte[][uint] leaving) onOwnership;

    /// Where replication messages go; null: they are dropped.
    ReplicationHandler replication;

    /// Phase 7: this node, the standby, has just become the coordinator; the world server takes up its part.
    void delegate() onPromoted;
    /// Quorum authority ended. The node can follow a subsequently elected coordinator.
    void delegate() onDemoted;
    /// The previous term's writes and local simulation must end before following a new one.
    void delegate() onTermChanged;

    /// A cluster service's call or reply from a peer (docs/SERVICES.md).
    void delegate(ushort peer, const ref ServiceCall call) onServiceCall;

    /// ditto
    void delegate(ushort peer, const ref ServiceReply reply) onServiceReply;

    /// ditto: a service's news for every node.
    void delegate(ushort peer, const ref ServiceNews news) onServiceNews;

    /**
     * Sends a message to node `peer` if it is linked; false if not (replication is resent in full when
     * a link opens, so a message that cannot go now is not needed later).
     */
    bool sendTo(M)(ushort peer, auto ref const M message)
    {
        if (auto link = peer in links)
        {
            link.send(message);
            return true;
        }
        return false;
    }

    /// A world node requests a loan, return, or retirement from the coordinator.
    void creatureLoan(CreatureLoan request)
    {
        if (isCoordinator)
            applyCreatureLoan(id, request);
        else
            sendToCoordinator(request);
    }

    private void applyCreatureLoan(ushort peer, const ref CreatureLoan request)
    {
        if (auto link = peer in links)
            if (link.peer.gateway)
                return;
        final switch (request.action)
        {
        case CreatureLoan.Action.lend:
            authority.lendCreature(peer, request.spawn, request.map, request.cell, request.caller, request.enemy);
            break;
        case CreatureLoan.Action.returnHome:
            authority.returnCreature(peer, request.spawn, request.epoch);
            break;
        case CreatureLoan.Action.retire:
            authority.retireCreature(peer, request.spawn, request.epoch);
            break;
        }
    }

    /// Initial creature loan releases have no earlier grant to the creature's home node.
    ubyte[] delegate(const ref Region) onCreatureRelease;

    /// What this node's regions cost it lately, for the coordinator's balancing.
    void reportLoads(RegionLoad[] loads)
    {
        if (isCoordinator)
            authority.measuredLoads(id, byRegion(loads));
        else
            sendToCoordinator(RegionLoads(loads));
    }

    private static uint[uint] byRegion(const(RegionLoad)[] loads)
    {
        uint[uint] busy;
        foreach (l; loads)
            busy[l.region] = l.busyUs;
        return busy;
    }

    /**
     * Starts this node's clean shutdown: the coordinator hands its regions, with their objects, to the
     * others. False if there is nobody to tell (the coordinator itself, or no link to it).
     */
    bool drain()
    {
        return sendToCoordinator(Drain(incarnation));
    }

    /// Whether this node owns no region any more (a drain is over).
    @property bool ownsNothing()
    {
        return regions_.ownedRegions.length == 0;
    }

    /// Sends a message to the coordinator; false if this node is it, or not linked to it.
    bool sendToCoordinator(M)(auto ref const M message)
    {
        if (isCoordinator)
            return false;
        if (auto link = coordinatorId in links)
        {
            link.send(message);
            return true;
        }
        return false;
    }

    /// Sends a message to every linked node.
    void broadcast(M)(auto ref const M message)
    {
        foreach (link; links)
            link.send(message);
    }

    /// This node accepted session `serial` for `account`: the coordinator decides whether it may play.
    void claimSession(uint account, ulong serial)
    {
        if (isCoordinator)
            return applySessionChange(SessionChange(account, SessionRef(id, serial, incarnation)));
        if (auto link = coordinatorId in links)
            link.send(SessionClaim(account, serial));
        else
            claimsWaiting ~= SessionClaim(account, serial);
    }

    /// Session `serial` of `account` ended, its character saved.
    void releaseSession(uint account, ulong serial)
    {
        if (isCoordinator)
            return applySessionChange(SessionChange(account, SessionRef(id, serial, incarnation), true));
        if (auto link = coordinatorId in links)
            link.send(SessionReleased(account, serial));
        else
            releasesWaiting ~= SessionReleased(account, serial);
    }

    /// The incarnation in the coordinator's latest view, including this process.
    SimulationOwner simulationOwner(ushort node) const
    {
        if (node == id)
            return SimulationOwner(id, incarnation);
        if (const member = find(node))
            return SimulationOwner(member.nodeId, member.incarnation);
        return SimulationOwner.init;
    }

    bool requestSessionRoute(const ref SessionRoute route)
    {
        auto link = linkTo(coordinatorId);
        if (link is null || link.wantsClose)
            return false;
        link.send(route);
        return true;
    }

    /// Queues a gateway packet for the same process, including during a direct-link outage.
    void sendToGateway(SimulationOwner gateway, const ref PlayerMessage message)
    {
        import dmangos.bytes : ByteWriter;

        if (auto link = linkTo(gateway.node))
            if (link.peer.incarnation == gateway.incarnation && !link.wantsClose)
                return link.send(message);
        if (auto stream = sequences.get(gateway.node, null))
            if (stream.incarnation == gateway.incarnation)
            {
                ByteWriter frame;
                const sequence = stream.nextSend++;
                putMessage(frame, sequence, message, electedTerm);
                stream.retain(sequence, frame.data);
            }
    }

    /// Tells the coordinator a gateway's simulation here stopped, its writes settled; false if it cannot hear now.
    bool simulationStopped(uint account, uint character, ulong token)
    {
        if (isCoordinator)
        {
            directory.stopped(account, character, token, simulationOwner(id));
            return true;
        }
        return sendToCoordinator(SessionRoute(kind: SessionRouteKind.stopped, account: account, character: character,
            token: token));
    }

    /**
     * The client address of the node with the fewest players (by their heartbeats; this node's own
     * load from `load`), for the realm list; empty if none has one.
     */
    string leastBusyClientAddress()
    {
        // Where there are gateways (docs/SERVICES.md), clients go to one of them, the least busy.
        bool anyGateway = config.gateway;
        foreach (link; links)
            anyGateway = anyGateway || link.peer.gateway;
        string best;
        uint fewest = uint.max;
        if (!anyGateway || config.gateway)
        {
            best = config.clientAddress;
            fewest = load is null ? 0 : load().players;
        }
        foreach (link; links)
            if (link.peer.clientAddress.length && (!anyGateway || link.peer.gateway) && link.peerLoad.players < fewest)
            {
                fewest = link.peerLoad.players;
                best = link.peer.clientAddress;
            }
        return best;
    }

    /// The nodes linked to this one now.
    ushort[] linkedPeers()
    {
        return links.keys;
    }

    private static struct Dial
    {
        string address;
        ushort expected;    // node id; 0: the coordinator
        MonoTime due;
        Duration backoff = firstBackoff;
        Link pending;       // a dial under way
    }

    /**
     * `incarnation` must be larger than any earlier start of this node's (`newIncarnation`). `load`
     * fills the heartbeats; null sends zeros.
     */
    this(ClusterConfig config, ulong incarnation, MonoTime delegate() clock, Dialer dialer,
        LoadReport delegate() load = null, CoordinatorSetup setup = CoordinatorSetup.init, uint realmId = 1)
    in (config.enabled && realmId && clock !is null && dialer !is null)
    {
        this.config = config;
        this.id = config.nodeId;
        this.incarnation = incarnation;
        this.clock = clock;
        this.dialer = dialer;
        this.load = load;
        quorumId = config.quorumId();
        coordinatorNow = config.isCoordinator;
        own = Hello(protocolVersion, config.name, id, incarnation, config.advertised, config.clientAddress,
            config.isCoordinator, 0, config.gateway, quorumId, realmId);
        enforce(!config.gateway || (!config.isCoordinator && !config.standby),
            "cluster: a gateway can be neither the coordinator nor the standby");
        const lease = config.leaseMs.msecs;
        regions_ = new RegionView(id, isCoordinator, lease);
        if (config.standby || config.voter(id) !is null)
            standbySetup = setup;
        if (isCoordinator)
        {
            viewCoordinator = incarnation;
            members = [self];
            viewVersion = 1;
            authority = new RegionAuthority(setup.regions, setup.cost, id, incarnation, lease, clock);
            authority.wholeMaps = setup.whole;
            authority.pinnedMaps = setup.pinned;
            authority.balancing.interval = config.balanceIntervalSeconds.seconds;
            authority.balancing.minLoadUs = config.balanceMinLoadUs;
            authority.balancing.cooldown = config.regionCooldownSeconds.seconds;
            ids = setup.ids;
            idGrantsFrom = clock() + lease + leaseMargin;
            directory = new SessionDirectory;
        }
        else
        {
            pool_ = new IdPool(config.idBlock);
            if (quorumId)
            {
                size_t rank;
                const voting = config.voter(id) !is null;
                foreach (const voter; config.voters)
                {
                    if (voter.nodeId < id)
                        ++rank;
                    if (voting ? voter.nodeId > id : voter.nodeId != id)
                        dials[voter.nodeId] = Dial(voter.address, voter.nodeId, clock());
                }
                if (voting)
                    election = new QuorumElection(SimulationOwner(id, incarnation), config.voters.length, rank,
                        lease, config.heartbeatMs.msecs, clock(), config.voteFile, quorumId);
            }
            else
                dials[coordinatorKey] = Dial(config.coordinator, 0, clock());
        }
    }

    /// What this node owns.
    @property RegionView regions()
    {
        return regions_;
    }

    /// A member's id blocks; null on the coordinator, which takes ids from its own counters.
    @property IdPool pool()
    {
        return pool_;
    }

    /// An incarnation for a process starting now: milliseconds since the Unix epoch.
    static ulong newIncarnation()
    {
        import std.datetime.systime : Clock, SysTime;

        return cast(ulong)(Clock.currTime - SysTime.fromUnixTime(0)).total!"msecs";
    }

    /// Whether this node is the coordinator (the configured one, or the standby since it took over).
    @property bool isCoordinator() const
    {
        return coordinatorNow && (!quorumId || election.term(clock()) == electedTerm);
    }

    ulong messageTerm() { return electedTerm; }

    /// Whether the coordinator refused this node as an older start of itself.
    @property bool fenced() const pure nothrow @nogc @safe
    {
        return fenced_;
    }

    /// The view's version (0 before a member has received one).
    @property ulong version_() const pure nothrow @nogc @safe
    {
        return viewVersion;
    }

    /// The live members, as the view lists them.
    @property const(ViewMember)[] view() const pure nothrow @nogc @safe
    {
        return members;
    }

    /// The open link to a peer node, or null.
    Link linkTo(ushort node)
    {
        return links.get(node, null);
    }

    @property ushort coordinatorNode() const
    {
        return isCoordinator ? id : coordinatorId;
    }

    /// A new connection from another node (the cluster listener's session factory).
    NetSession accept(string remoteAddress)
    {
        auto link = makeLink(false, remoteAddress, 0);
        handshaking ~= link;
        return link;
    }

    /// Update the designated host also on voters that may take over as coordinator.
    void pinMaps(const(uint)[] maps, ushort node)
    {
        foreach (map; maps)
            standbySetup.pinned[map] = node;
        if (isCoordinator)
            authority.pinMaps(maps, node);
    }

    /// Heartbeats, failure detection and dialing; called every world tick.
    void tick()
    {
        const now = clock();
        const report = load is null ? LoadReport.init : load();
        foreach (link; links)
            link.tick(now, report);
        foreach (link; handshaking)
            link.tick(now, report);
        if (quorumId)
            tickQuorum(now);
        updateOwnership(now);
        if (heldPlayers.length && regions_.leaseHolds(now))
            releaseHeldPlayers();
        if (fenced_)
            return;
        if (!quorumId && config.standby && !isCoordinator && lostCoordinator && coordinatorId == 0
            && now - lostCoordinatorAt >= standbyGrace)
            promote(now);
        if (isCoordinator && takeoverPending.length && now - lastTakeoverSent >= 1.seconds)
        {
            lastTakeoverSent = now;
            foreach (peer, _; takeoverPending)
                sendTo(peer, Takeover(incarnation));
        }
        foreach (key, ref dial; dials)
            if (dial.pending is null && now >= dial.due && (key == coordinatorKey || key !in links))
            {
                if (key == coordinatorKey && coordinatorId && coordinatorId in links)
                    continue;
                dial.pending = makeLink(true, dial.address, dial.expected);
                handshaking ~= dial.pending;
                string host;
                ushort port;
                splitAddress(dial.address, host, port);
                dialer(host, port, dial.pending);
            }
    }

    /// One line per link: who, its round trip and duplicates, for the log.
    string[] describe()
    {
        import std.algorithm.sorting : sort;
        import std.format : format;

        const leaseHolds = regions_.leaseHolds(clock());
        string[] lines = [format!"cluster: node %s%s, view %s with %s member(s)%s; owns %s region(s), lease %s"(id,
            isCoordinator ? " (coordinator)" : "", viewVersion, members.length, fenced_ ? ", FENCED" : "",
            regions_.ownedRegions.length, leaseHolds ? "holds" : "LAPSED")];
        if (isCoordinator)
        {
            auto loads = authority.memberLoads();
            auto nodes = loads.keys;
            nodes.sort();
            foreach (node; nodes)
                lines ~= format!"cluster:   node %s carries cost %s"(node, loads[node]);
        }
        auto ids = links.keys;
        ids.sort();
        foreach (peer; ids)
        {
            const link = links[peer];
            const rtt = link.roundTrip == Duration.max ? "?" : format!"%.2f ms"(link.roundTrip.total!"usecs" / 1000.0);
            lines ~= format!"cluster:   link to node %s at %s: round trip %s, %s duplicate(s) dropped"(peer,
                link.peer.address, rtt, link.duplicates);
        }
        return lines;
    }

    // LinkOwner

    RejectReason admit(Link link, const ref Hello hello, out PeerSequences peerSequences)
    {
        if (hello.nodeId == id || hello.nodeId == 0)
            return RejectReason.duplicateNode;
        const voter = config.voter(hello.nodeId);
        if (voter !is null && (hello.address != voter.address || hello.gateway))
            return RejectReason.notInView;
        if (isCoordinator)
        {
            if (takeoverGateways.length && hello.nodeId !in links)
                return RejectReason.notInView; // an absent incarnation may be fenced by a gateway's report
            if (const known = hello.nodeId in highestIncarnation)
                if (hello.incarnation < *known)
                    return RejectReason.staleIncarnation;
            if (!directory.mayAdmit(SimulationOwner(hello.nodeId, hello.incarnation)))
                return RejectReason.staleIncarnation;
        }
        else if (quorumId && (voter !is null || election !is null))
        {
            if (hello.expected != id && !link.dialed)
                return RejectReason.unexpectedNode;
            if (const previous = hello.nodeId in highestIncarnation)
                if (hello.incarnation < *previous)
                    return RejectReason.staleIncarnation;
        }
        else if (!link.dialed)
        {
            // A peer member dialing this one: it must be the incarnation the view admitted.
            if (hello.expected != id)
                return RejectReason.unexpectedNode;
            const member = find(hello.nodeId);
            if (member is null || member.incarnation != hello.incarnation)
                return RejectReason.notInView;
        }
        else if (!hello.coordinator)
        {
            const member = find(hello.nodeId);
            if (member is null || member.incarnation != hello.incarnation)
                return RejectReason.notInView;
        }
        peerSequences = sequences.require(hello.nodeId, new PeerSequences);
        return RejectReason.none;
    }

    void opened(Link link)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        const peer = link.peer.nodeId;
        const at = handshaking.countUntil!"a is b"(link);
        if (at >= 0)
            handshaking = handshaking.remove(at);
        if (auto old = peer in links)
            if (*old !is link)
            {
                if (isCoordinator && (*old).peer.incarnation != link.peer.incarnation)
                    noteLostProcess(*old);
                old.close("replaced by a newer link");
            }
        links[peer] = link;
        if (quorumId)
        {
            highestIncarnation[peer] = link.peer.incarnation;
            link.markCoordinator(peer == coordinatorId);
        }
        foreach (ref dial; dials)
            if (dial.pending is link)
            {
                dial.pending = null;
                dial.backoff = firstBackoff;
            }
        if (!quorumId && link.peer.coordinator)
            coordinatorId = peer;
        info!"cluster: linked to node %s at %s (incarnation %s)"(peer, link.peer.address, link.peer.incarnation);
        // In quorum mode the peer can discard messages from this term until it accepts the leader.
        if (replication !is null && !(quorumId && isCoordinator))
            replication.peerLinked(peer);
        if (isCoordinator)
            directory.back(peer, link.peer.incarnation);
        else if (!quorumId && link.peer.coordinator)
            coordinatorLinked(link);
        else if (quorumId && peer == coordinatorId)
            link.markCoordinator();

        if (isCoordinator)
        {
            highestIncarnation[peer] = link.peer.incarnation;
            setMember(ViewMember(peer, link.peer.incarnation, link.peer.address, false));
            if (quorumId)
            {
                takeoverPending[peer] = true;
                if (link.peer.gateway)
                    takeoverGateways[peer] = true;
                link.send(Takeover(incarnation));
            }
            link.send(RegionTable(viewCoordinator, authority.version_, authority.regions.dup));
            if (!link.peer.gateway) // a gateway simulates nothing: no regions, no services
                authority.joined(peer);
        }
    }

    /// A member has a coordinator (anew, or the standby that took over): it learns what this node holds.
    private void coordinatorLinked(Link link)
    {
        foreach (claim; claimsWaiting)
            link.send(claim);
        foreach (release; releasesWaiting)
            link.send(release);
        claimsWaiting = null;
        releasesWaiting = null;
        if (sessions !is null)
            sessions.claimAll(); // a new coordinator knows nothing of them
        link.send(IdReport(pool_.highest(IdKind.character), pool_.highest(IdKind.item),
            pool_.highest(IdKind.mail), pool_.highest(IdKind.group), pool_.highest(IdKind.instance),
            pool_.highest(IdKind.pet)));
        pool_.reset();
    }

    private void tickQuorum(MonoTime now)
    {
        if (election !is null)
        {
            if (coordinatorNow && !isCoordinator)
            {
                coordinatorNow = own.coordinator = false;
                regions_.revokeLease();
                takeoverPending = null;
                takeoverGateways = null;
                deferredSessionChanges = null;
                idRequests = null;
                if (onDemoted !is null)
                    onDemoted();
                warning!"cluster: node %s lost its majority lease for term %s"(id, electedTerm);
            }
            const vote = election.tick(now);
            if (vote.term)
                foreach (const voter; config.voters)
                    if (auto link = linkTo(voter.nodeId))
                        link.sendQuorum(vote);
            const term = election.term(now);
            if (term > electedTerm)
            {
                advanceTerm(term, SimulationOwner(id, incarnation));
                promote(now);
            }
            if (isCoordinator)
            {
                regions_.grantUntil(election.validUntil(now));
                return;
            }
        }
        if (auto link = linkTo(coordinatorId))
            if (electedTerm && now >= nextWorkerLease)
            {
                nextWorkerLease = now + config.heartbeatMs.msecs;
                const stamp = cast(ulong)(now - MonoTime.init).total!"usecs";
                const applied = regions_.leaseHolds(now) ? appliedOwnership : 0;
                link.sendQuorum(QuorumWorkerLease(electedTerm, stamp, 0, false, applied));
            }
    }

    private void quorumVoteReceived(Link link, const QuorumVote message)
    {
        const peer = link.peer.nodeId;
        if (election is null || config.voter(peer) is null || linkTo(peer) !is link)
            return;
        if (message.reply)
            election.reply(peer, message, clock());
        else
        {
            const answer = election.request(SimulationOwner(peer, link.peer.incarnation), message, clock());
            link.sendQuorum(answer);
        }
    }

    private void quorumLeaseReceived(Link link, const QuorumWorkerLease message)
    {
        if (!message.term || message.term != electedTerm || !message.stamp)
            return;
        const now = clock();
        if (!message.reply)
        {
            if (isCoordinator && linkTo(link.peer.nodeId) is link)
            {
                readyOwnership[link.peer.nodeId] = message.appliedVersion;
                const remaining = (election.validUntil(now) - now).total!"msecs";
                if (remaining > 0)
                    link.sendQuorum(QuorumWorkerLease(electedTerm, message.stamp, cast(uint) remaining, true));
            }
        }
        else if (linkTo(coordinatorId) is link && regions_.coordinator == electedTerm
            && message.remainingMs && message.remainingMs <= config.leaseMs)
        {
            const sent = MonoTime.init + usecs(cast(long) message.stamp);
            const until = sent + message.remainingMs.msecs;
            if (sent <= now && now < until)
            {
                regions_.grantUntil(until);
                if (election !is null)
                    election.follow(electedTerm, until);
            }
        }
    }

    private void followQuorumLeader(Link link, ulong term, const Takeover message)
    {
        const peer = link.peer.nodeId;
        const leader = SimulationOwner(peer, link.peer.incarnation);
        if (!term || term < electedTerm || config.voter(peer) is null || linkTo(peer) !is link
            || message.incarnation != leader.incarnation || isCoordinator
            || (term == electedTerm && leader != termLeader))
            return;
        if (term > electedTerm)
            advanceTerm(term, leader);
        if (coordinatorId != peer)
        {
            coordinatorId = peer;
            link.markCoordinator();
            info!"cluster: node %s leads quorum term %s"(peer, term);
            sendTakeoverAccepted(link);
            coordinatorLinked(link);
            if (replication !is null)
                replication.peerLinked(peer);
        }
        else
            sendTakeoverAccepted(link);
    }

    private void advanceTerm(ulong term, SimulationOwner leader)
    {
        if (auto former = linkTo(coordinatorId))
            former.markCoordinator(false);
        coordinatorId = 0;
        coordinatorNow = own.coordinator = false;
        regions_.revokeLease();
        if (electedTerm)
        {
            if (onTermChanged !is null)
                onTermChanged();
            updateOwnership(clock());
        }
        arriving = null;
        leaving = null;
        electedTerm = term;
        heldPlayers.clear();
        termLeader = leader;
        nextWorkerLease = MonoTime.init;
        appliedOwnership = 0;
        readyOwnership = null;
    }

    /**
     * Phase 7: the standby has had no coordinator for `standbyGrace` after losing it, and takes over:
     * the table it had stands, the members it is linked to are the view, and they are told
     * (`Takeover`, again each second until each accepts).
     */
    private void promote(MonoTime now)
    {
        const old = quorumId ? 0 : lostCoordinator;
        if (quorumId)
            warning!"cluster: node %s elected coordinator for term %s"(id, electedTerm);
        else
            warning!"cluster: the coordinator (node %s) is gone: node %s, the standby, takes over"(old, id);
        coordinatorNow = true;
        own.coordinator = true;
        promotedAt = now;
        dials.remove(coordinatorKey);
        // The view and table go on from the old coordinator's versions: newer than anything members have.
        viewCoordinator = quorumId ? electedTerm : incarnation;
        ++viewVersion;
        members = [self];
        ushort[] live = [id];
        foreach (peer, link; links)
        {
            highestIncarnation[peer] = link.peer.incarnation;
            setMember(ViewMember(peer, link.peer.incarnation, link.peer.address, false));
            if (!link.peer.gateway)
                live ~= peer;
            else
                takeoverGateways[peer] = true;
            takeoverPending[peer] = true;
        }
        const lease = config.leaseMs.msecs;
        if (quorumId && !regions_.latestTable.length)
        {
            authority = new RegionAuthority(standbySetup.regions.dup, standbySetup.cost.dup, id, electedTerm,
                lease, clock);
            foreach (peer; live)
                authority.joined(peer);
        }
        else
            authority = RegionAuthority.adopt(regions_.latestTable, regions_.latestVersion, standbySetup.cost.dup, id,
                live, cast(ushort) old, lostCoordinatorHeard, lease, clock);
        authority.wholeMaps = standbySetup.whole;
        foreach (map, node; standbySetup.pinned)
            authority.pinMaps([map], node);
        authority.balancing.interval = config.balanceIntervalSeconds.seconds;
        authority.balancing.minLoadUs = config.balanceMinLoadUs;
        authority.balancing.cooldown = config.regionCooldownSeconds.seconds;
        if (quorumId)
        {
            regions_.take(viewCoordinator, authority.version_, authority.regions.dup);
            regions_.grantUntil(election.validUntil(clock()));
        }
        else
            regions_.promote();
        directory = new SessionDirectory;
        ids = standbySetup.ids;
        idGrantsFrom = now + lease + leaseMargin;
        if (onPromoted !is null)
            onPromoted();
        if (ids !is null && pool_ !is null)
            foreach (kind; [IdKind.character, IdKind.item, IdKind.mail, IdKind.group, IdKind.instance, IdKind.pet])
                ids.raise(kind, pool_.highest(kind));
        if (sessions !is null)
            sessions.claimAll();
        lastTakeoverSent = now;
        foreach (peer, _; takeoverPending)
            sendTo(peer, Takeover(incarnation));
        publish();
    }

    private void holdPlayer(Link link, ulong term, const(ubyte)[] payload)
    {
        const kind = decode!PlayerMessage(payload).kind;
        const packet = kind == PlayerMessageKind.toHome || kind == PlayerMessageKind.toOwner;
        if (!heldPlayers.hold(link.peer.nodeId, link.peer.incarnation, term, payload, packet))
            warning!"cluster: node %s dropped a player packet from node %s while its lease had lapsed"(id,
                link.peer.nodeId);
    }

    private void releaseHeldPlayers()
    {
        if (!heldPlayers.length)
            return;
        heldPlayers.release(electedTerm, (ushort peer) {
            if (auto link = peer in links)
                return (*link).peer.incarnation;
            return 0UL;
        }, (ushort peer, const(ubyte)[] payload) {
            if (players is null)
                return;
            const m = decode!PlayerMessage(payload);
            players.player(peer, m.kind, m.account, m.opcode, m.data);
        });
    }

    void received(Link link, MessageType type, ulong term, const(ubyte)[] payload)
    {
        const peer = link.peer.nodeId;
        if (quorumId)
        {
            if (type == MessageType.quorumVote)
                return quorumVoteReceived(link, decode!QuorumVote(payload));
            if (type == MessageType.quorumWorkerLease)
                return quorumLeaseReceived(link, decode!QuorumWorkerLease(payload));
            if (type == MessageType.takeover)
                return followQuorumLeader(link, term, decode!Takeover(payload));
            if (!term || term != electedTerm)
                return;
            if (type == MessageType.player)
            {
                if (!regions_.leaseHolds(clock()))
                    return holdPlayer(link, term, payload);
                releaseHeldPlayers(); // the sender's earlier messages first
            }
        }
        else if (term)
            return;
        if (type >= MessageType.stockRequest && type <= MessageType.stockRelease)
        {
            if (replication is null)
                return;
            if (type == MessageType.stockRequest)
            {
                const m = decode!StockRequest(payload);
                replication.stockRequest(peer, m);
            }
            else if (type == MessageType.stockReply)
            {
                const m = decode!StockReply(payload);
                replication.stockReply(peer, m);
            }
            else
            {
                const m = decode!StockRelease(payload);
                replication.stockRelease(peer, m);
            }
            return;
        }
        if (type >= MessageType.guildReload && type <= MessageType.guildInvitation)
        {
            if (replication !is null)
                replication.guildNews(peer, cast(MessageType) type, payload);
            return;
        }
        if (type == MessageType.friendStatus)
        {
            if (replication !is null)
            {
                const m = decode!FriendStatusChange(payload);
                replication.friendStatus(peer, m);
            }
            return;
        }
        if (type == MessageType.dungeonEntryRequest || type == MessageType.dungeonEntryReply)
        {
            if (replication is null)
                return;
            if (type == MessageType.dungeonEntryRequest)
            {
                const m = decode!DungeonEntryRequest(payload);
                replication.dungeonEntryRequest(peer, m);
            }
            else
            {
                const m = decode!DungeonEntryReply(payload);
                replication.dungeonEntryReply(peer, m);
            }
            return;
        }
        if (type == MessageType.serviceCall || type == MessageType.serviceReply)
        {
            // Cluster services (docs/SERVICES.md): the world's service host answers and receives them.
            if (type == MessageType.serviceCall)
            {
                if (onServiceCall !is null)
                {
                    const m = decode!ServiceCall(payload);
                    onServiceCall(peer, m);
                }
            }
            else if (onServiceReply !is null)
            {
                const m = decode!ServiceReply(payload);
                onServiceReply(peer, m);
            }
            return;
        }
        if (type == MessageType.serviceNews)
        {
            if (onServiceNews !is null)
            {
                const m = decode!ServiceNews(payload);
                onServiceNews(peer, m);
            }
            return;
        }
        if (type == MessageType.scriptSignal)
        {
            if (replication !is null)
            {
                const m = decode!ScriptSignal(payload);
                replication.scriptSignal(peer, m);
            }
            return;
        }
        if (type == MessageType.killShare)
        {
            if (replication !is null)
            {
                const m = decode!KillShare(payload);
                replication.killShare(peer, m);
            }
            return;
        }
        if (type == MessageType.groupLootRoll)
        {
            if (replication !is null)
            {
                const m = decode!GroupLootRoll(payload);
                replication.groupLootRoll(peer, m);
            }
            return;
        }
        if (type == MessageType.lootCoinShare)
        {
            if (replication !is null)
            {
                const m = decode!LootCoinShare(payload);
                replication.lootCoinShare(peer, m);
            }
            return;
        }
        if (type == MessageType.partyQuest)
        {
            if (replication !is null)
            {
                const message = decode!PartyQuest(payload);
                replication.partyQuest(peer, message);
            }
            return;
        }
        if (type == MessageType.questLootCheck)
        {
            if (replication !is null)
            {
                const m = decode!QuestLootCheck(payload);
                replication.questLootCheck(peer, m);
            }
            return;
        }
        if (type == MessageType.partyHeal)
        {
            if (replication !is null)
            {
                const m = decode!PartyHeal(payload);
                replication.partyHeal(peer, m);
            }
            return;
        }
        if (type == MessageType.areaDamage)
        {
            if (replication !is null)
            {
                const m = decode!AreaDamage(payload);
                replication.areaDamage(peer, m);
            }
            return;
        }
        if (type == MessageType.creatureSwing)
        {
            if (replication !is null)
            {
                const m = decode!CreatureSwing(payload);
                replication.creatureSwing(peer, m);
            }
            return;
        }
        if (type == MessageType.gameObjectSpell)
        {
            if (replication !is null)
            {
                const m = decode!GameObjectSpell(payload);
                replication.gameObjectSpell(peer, m);
            }
            return;
        }
        if (type == MessageType.scriptGameObject)
        {
            if (replication !is null)
            {
                const m = decode!ScriptGameObject(payload);
                replication.scriptGameObject(peer, m);
            }
            return;
        }
        if (type == MessageType.partySummon)
        {
            if (replication !is null)
            {
                const m = decode!PartySummon(payload);
                replication.partySummon(peer, m);
            }
            return;
        }
        if (type == MessageType.scriptCreatureStep)
        {
            if (replication !is null)
            {
                const m = decode!ScriptCreatureStep(payload);
                replication.scriptCreatureStep(peer, m);
            }
            return;
        }
        if (type == MessageType.totemWeaponEnchant)
        {
            if (replication !is null)
            {
                const m = decode!TotemWeaponEnchant(payload);
                replication.totemWeaponEnchant(peer, m);
            }
            return;
        }
        if (type == MessageType.mindVisionTarget)
        {
            if (replication !is null)
            {
                const message = decode!MindVisionTarget(payload);
                replication.mindVisionTarget(peer, message);
            }
            return;
        }
        if (type == MessageType.partyAreaAura)
        {
            if (replication !is null)
            {
                const m = decode!PartyAreaAura(payload);
                replication.partyAreaAura(peer, m);
            }
            return;
        }
        if (type == MessageType.periodicResult)
        {
            if (replication !is null)
            {
                const m = decode!PeriodicResult(payload);
                replication.periodicResult(peer, m);
            }
            return;
        }
        if (type == MessageType.toEveryone || type == MessageType.gmRemote)
        {
            if (replication is null)
                return;
            if (type == MessageType.toEveryone)
            {
                const m = decode!ToEveryone(payload);
                replication.toEveryone(peer, m);
            }
            else
            {
                const m = decode!GmRemote(payload);
                replication.gmRemote(peer, m);
            }
            return;
        }
        if (type >= MessageType.groupCommand && type <= MessageType.memberStatsRequest)
        {
            if (replication is null)
                return;
            if (type == MessageType.groupCommand)
            {
                if (!isCoordinator)
                    return;
                const m = decode!GroupCommand(payload);
                replication.groupCommand(peer, m);
            }
            else if (type == MessageType.groupState)
            {
                if (isCoordinator || peer != coordinatorId)
                    return;
                const m = decode!GroupState(payload);
                replication.groupState(peer, m);
            }
            else
            {
                const m = decode!MemberStatsRequest(payload);
                replication.memberStatsRequest(peer, m);
            }
            return;
        }
        if (type == MessageType.groupCatalog)
        {
            if (replication !is null && !isCoordinator && peer == coordinatorId)
            {
                const m = decode!GroupCatalog(payload);
                replication.groupCatalog(peer, m);
            }
            return;
        }
        if (type == MessageType.whisper)
        {
            if (replication !is null)
            {
                const m = decode!WhisperMessage(payload);
                replication.whisper(peer, m);
            }
            return;
        }
        if (type == MessageType.inRange || type == MessageType.presence || type == MessageType.deliverTo)
        {
            if (replication is null)
                return;
            if (type == MessageType.inRange)
            {
                const m = decode!InRange(payload);
                replication.inRange(peer, m.map, m.x, m.y, m.z, m.range, m.opcode, m.body_);
            }
            else if (type == MessageType.presence)
            {
                const m = decode!Presence(payload);
                replication.presence(peer, m.full, m.entries, m.gone);
            }
            else
            {
                const m = decode!DeliverTo(payload);
                replication.deliverTo(peer, m.guid, m.opcode, m.body_);
            }
            return;
        }
        if (type == MessageType.player)
        {
            if (players !is null)
            {
                const m = decode!PlayerMessage(payload);
                players.player(peer, m.kind, m.account, m.opcode, m.data);
            }
            return;
        }
        if (type >= MessageType.sessionClaim && type <= MessageType.sessionReleased)
            return session(peer, link, type, payload);
        if (type == MessageType.sessionRoute)
        {
            const m = decode!SessionRoute(payload);
            if (isCoordinator && !m.reply)
            {
                if (m.kind == SessionRouteKind.stopped)
                    directory.stopped(m.account, m.character, m.token, SimulationOwner(peer, link.peer.incarnation));
                else if (link.peer.gateway)
                {
                    auto reply = cast(SessionRoute) m;
                    reply.reply = true;
                    const destination = linkTo(m.next.node);
                    const canRoute = simulationOwner(m.next.node) == m.next && (m.next.node == id
                        || (destination !is null && !destination.peer.gateway && !destination.wantsClose
                            && (!quorumId || readyOwnership.get(m.next.node, 0) == authority.version_)));
                    reply.result = takeoverGateways.length ? SessionRouteResult.retry
                        : directory.route(SessionRef(peer, m.serial, link.peer.incarnation), m, clock(), canRoute);
                    sendTo(peer, reply);
                }
            }
            else if (m.reply && peer == coordinatorId && players !is null)
                players.sessionRouteResult(m);
            return;
        }
        if (type >= MessageType.interestUpdate && type <= MessageType.replicaRemove)
            return replicate(peer, type, payload);
        if (type == MessageType.takeover)
        {
            // Phase 7: the standby took over. Taken once this node has lost the old coordinator too.
            const m = decode!Takeover(payload);
            if (isCoordinator || m.incarnation != link.peer.incarnation)
                return;
            if (coordinatorId && coordinatorId in links && coordinatorId != peer)
                return; // the old one is still there for this node: not yet
            if (coordinatorId != peer)
            {
                info!"cluster: node %s took over as the coordinator"(peer);
                coordinatorId = peer;
                link.markCoordinator();
                if (auto dial = coordinatorKey in dials)
                    dial.address = link.peer.address; // if this link breaks, dial the new coordinator
                sendTakeoverAccepted(link);
                coordinatorLinked(link);
            }
            else
                sendTakeoverAccepted(link);
            return;
        }
        if (type == MessageType.takeoverAccepted)
        {
            const m = decode!TakeoverAccepted(payload);
            if (isCoordinator && m.incarnation == link.peer.incarnation && takeoverPending.remove(peer))
            {
                if (takeoverGateways.remove(peer))
                {
                    const gateway = SimulationOwner(peer, m.incarnation);
                    foreach (ref route; m.gatewayRoutes)
                    {
                        const oldTerm = quorumId && route.term < electedTerm;
                        if (directory.restoreGatewayRoute(gateway, route, oldTerm)
                            && !oldTerm && simulationOwner(route.owner.node) != route.owner)
                            directory.lost(route.owner.node, promotedAt + config.leaseMs.msecs + leaseMargin,
                                route.owner.incarnation);
                    }
                    finishTakeoverSessions();
                }
                // It ignored what came before it took this node as its coordinator: the view and table again.
                link.send(View(viewCoordinator, viewVersion, members));
                link.send(RegionTable(viewCoordinator, authority.version_, authority.regions.dup));
                if (replication !is null)
                    replication.peerLinked(peer);
            }
            return;
        }
        if (!isCoordinator && link.peer.coordinator)
            switch (type)
            {
            case MessageType.view:
                return takeView(decode!View(payload));
            case MessageType.regionTable:
                auto table = decode!RegionTable(payload);
                if ((quorumId ? electedTerm : link.peer.incarnation) == table.coordinatorIncarnation
                    && (!quorumId || peer == coordinatorId))
                    regions_.take(table.coordinatorIncarnation, table.version_, table.regions);
                return;
            case MessageType.idGrant:
                const grant = decode!IdGrant(payload);
                return pool_.granted(grant.kind, grant.first, grant.count);
            case MessageType.regionHandover:
                const handover = decode!RegionHandover(payload);
                arriving[handover.region] = handover.objects.dup;
                return;
            default:
                return;
            }
        if (isCoordinator)
            switch (type)
            {
            case MessageType.regionReleased:
                const release = decode!RegionReleased(payload);
                if (authority.released(peer, release.region, release.epoch))
                    handOver(release.region, release.objects);
                return;
            case MessageType.creatureLoan:
                const request = decode!CreatureLoan(payload);
                return applyCreatureLoan(peer, request);
            case MessageType.idRequest:
                idRequests[peer] ~= decode!IdRequest(payload);
                return;
            case MessageType.regionLoads:
                const report = decode!RegionLoads(payload);
                authority.measuredLoads(peer, byRegion(report.loads));
                return;
            case MessageType.drain:
                const drain = decode!Drain(payload);
                if (const member = find(peer))
                    if (member.incarnation == drain.incarnation)
                    {
                        info!"cluster: node %s is shutting down: its regions go to the others"(peer);
                        authority.drain(peer);
                    }
                return;
            case MessageType.idReport:
                if (ids is null)
                    return;
                const report = decode!IdReport(payload);
                ids.raise(IdKind.character, report.character);
                ids.raise(IdKind.item, report.item);
                ids.raise(IdKind.mail, report.mail);
                ids.raise(IdKind.group, report.group);
                ids.raise(IdKind.instance, report.instance);
                ids.raise(IdKind.pet, report.pet);
                return;
            default:
                return;
            }
    }

    void closed(Link link)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil, startsWith;

        const at = handshaking.countUntil!"a is b"(link);
        if (at >= 0)
            handshaking = handshaking.remove(at);
        const now = clock();
        foreach (key, ref dial; dials)
            if (dial.pending is link)
            {
                dial.pending = null;
                dial.due = now + dial.backoff;
                dial.backoff = dial.backoff * 2 > maxBackoff ? maxBackoff : dial.backoff * 2;
                if (key == coordinatorKey && link.closeReason == "refused: staleIncarnation")
                {
                    fenced_ = true;
                    error!"cluster: the coordinator refused this node (id %s) as an older start of it: fenced"(id);
                }
                else if (link.closeReason.startsWith("refused: "))
                    warning!"cluster: link to %s %s"(link.address, link.closeReason);
            }

        const peer = link.peer.nodeId;
        if (link.state != Link.State.closed || peer == 0)
            return;
        if (auto current = peer in links)
        {
            if (*current !is link)
                return; // an old link that was replaced
            links.remove(peer);
        }
        else
            return; // never opened
        warning!"cluster: link to node %s at %s closed: %s"(peer, link.peer.address, link.closeReason);
        if (replication !is null)
            replication.peerLost(peer);
        if (auto dial = peer in dials)
            dial.due = now + dial.backoff;
        if (peer == coordinatorId)
        {
            coordinatorId = 0;
            if (auto dial = coordinatorKey in dials)
                dial.due = now + dial.backoff;
            lostCoordinator = peer;
            lostCoordinatorAt = now;
            lostCoordinatorHeard = link.lastHeard;
        }
        takeoverPending.remove(peer);
        if (isCoordinator)
        {
            dropMember(peer);
            noteLostProcess(link);
            idRequests.remove(peer);
            if (takeoverGateways.remove(peer))
                finishTakeoverSessions();
        }
    }

private:
    void sendTakeoverAccepted(Link link)
    {
        auto routes = config.gateway && players !is null ? players.gatewaySessionRoutes() : null;
        link.send(TakeoverAccepted(incarnation, routes));
    }

    void noteLostProcess(Link link)
    {
        import std.algorithm.comparison : max;

        const lastHeard = max(link.lastHeard, promotedAt);
        readyOwnership.remove(link.peer.nodeId);
        authority.lost(link.peer.nodeId, lastHeard);
        directory.lost(link.peer.nodeId, lastHeard + config.leaseMs.msecs + leaseMargin, link.peer.incarnation);
    }

    struct SessionChange
    {
        uint account;
        SessionRef session;
        bool release;
    }

    void applySessionChange(SessionChange change)
    {
        if (takeoverGateways.length)
            deferredSessionChanges ~= change;
        else if (change.release)
            act(directory.released(change.account, change.session));
        else if (simulationOwner(change.session.node) == change.session.process)
            act(directory.claim(change.account, change.session));
    }

    void finishTakeoverSessions()
    {
        if (takeoverGateways.length)
            return;
        const changes = deferredSessionChanges;
        deferredSessionChanges = null;
        foreach (change; changes)
            applySessionChange(change);
    }

    /// A session message: claims and releases on the coordinator, grants and evictions on members.
    void session(ushort peer, Link link, MessageType type, const(ubyte)[] payload)
    {
        if (isCoordinator)
        {
            if (type == MessageType.sessionClaim)
            {
                const m = decode!SessionClaim(payload);
                applySessionChange(SessionChange(m.account, SessionRef(peer, m.serial, link.peer.incarnation)));
            }
            else if (type == MessageType.sessionReleased)
            {
                const m = decode!SessionReleased(payload);
                applySessionChange(SessionChange(m.account, SessionRef(peer, m.serial, link.peer.incarnation), true));
            }
            return;
        }
        if (!link.peer.coordinator || sessions is null)
            return;
        if (type == MessageType.sessionGrant)
        {
            const m = decode!SessionGrant(payload);
            sessions.sessionGranted(m.account, m.serial);
        }
        else if (type == MessageType.sessionEvict)
        {
            const m = decode!SessionEvict(payload);
            sessions.sessionEvicted(m.account, m.serial);
        }
    }

    /**
     * The coordinator passes a released region's objects to the node it was granted to, ahead of the
     * table that grants it, on the same link: the new owner has them before it may simulate the region.
     */
    void handOver(uint region, const(ubyte)[] objects)
    {
        if (objects.length == 0)
            return;
        const target = authority.grantedAfter(region);
        if (target == id)
            arriving[region] = objects.dup;
        else if (target)
            sendTo(target, RegionHandover(region, cast(ubyte[]) objects));
    }

    /// The directory's decisions, to the sessions they are about: this node's directly, others' by message.
    void act(const(SessionAction)[] actions)
    {
        foreach (a; actions)
        {
            if (simulationOwner(a.session.node) != a.session.process)
                continue;
            if (a.kind == SessionAction.Kind.evict)
                info!"cluster: account %s logged in again; its session on node %s is ended, and the new one waits for it"(
                    a.account, a.session.node);
            else
                verbose!"cluster: account %s may enter the world on node %s"(a.account, a.session.node);
            if (a.session.node == id)
            {
                if (sessions is null)
                    continue;
                if (a.kind == SessionAction.Kind.grant)
                    sessions.sessionGranted(a.account, a.session.serial);
                else
                    sessions.sessionEvicted(a.account, a.session.serial);
            }
            else if (a.kind == SessionAction.Kind.grant)
                sendTo(a.session.node, SessionGrant(a.account, a.session.serial));
            else
                sendTo(a.session.node, SessionEvict(a.account, a.session.serial));
        }
    }

    /// A replication message from `peer`, to the handler.
    void replicate(ushort peer, MessageType type, const(ubyte)[] payload)
    {
        if (replication is null)
            return;
        switch (type)
        {
        case MessageType.interestUpdate:
            const m = decode!InterestUpdate(payload);
            return replication.interest(peer, m.map, m.added, m.removed);
        case MessageType.replicaCreate:
            const m = decode!ReplicaCreate(payload);
            return replication.replicaCreate(peer, m.map, m.cell, m.guid, m.state);
        case MessageType.replicaValues:
            const m = decode!ReplicaValues(payload);
            return replication.replicaValues(peer, m.map, m.guid, m.slots);
        case MessageType.replicaMove:
            const m = decode!ReplicaMove(payload);
            return replication.replicaMove(peer, m.map, m.guid, m.opcode, m.body_, m.motion);
        case MessageType.replicaRemove:
            const m = decode!ReplicaRemove(payload);
            return replication.replicaRemove(peer, m.map, m.guid);
        default:
            return;
        }
    }

    /**
     * Regions: the coordinator hands out and publishes; every node renews its lease, tells the world
     * what it gained and lost, and answers releases. Ids: members ask for blocks, the coordinator
     * grants them once members have had time to report what they hold.
     */
    void updateOwnership(MonoTime now)
    {
        if (isCoordinator)
        {
            act(directory.tick(now));
            authority.tick();
            if (authority.takeChanged())
            {
                const table = RegionTable(viewCoordinator, authority.version_, authority.regions.dup);
                regions_.take(viewCoordinator, table.version_, table.regions.dup);
                foreach (link; links)
                    link.send(table);
            }
            if (quorumId)
                regions_.grantUntil(election.validUntil(now));
            if (now >= idGrantsFrom && ids !is null)
            {
                foreach (peer, requests; idRequests)
                    if (auto link = peer in links)
                        foreach (request; requests)
                            link.send(IdGrant(request.kind, ids.take(request.kind, request.count), request.count));
                idRequests = null;
            }
        }
        else if (!quorumId && coordinatorId)
            if (auto link = coordinatorId in links)
                if (link.peer.incarnation == regions_.coordinator)
                    regions_.confirm(link.confirmedAt);

        Region[] gained, lost;
        regions_.refresh(now, gained, lost);
        auto releases = regions_.releases();
        if (onCreatureRelease !is null)
            foreach (ref r; releases)
                if (r.creature.spawn && r.id !in leaving && regions_.leaseHolds(now))
                    leaving[r.id] = onCreatureRelease(r);
        if (gained.length || lost.length)
        {
            info!"cluster: regions gained %s, lost %s; this node owns %s"(regionIds(gained), regionIds(lost),
                regionIds(regions_.ownedRegions));
            const(ubyte)[][uint] arrived;
            foreach (ref r; gained)
                if (auto objects = r.id in arriving)
                {
                    arrived[r.id] = *objects;
                    arriving.remove(r.id);
                }
            if (onOwnership !is null)
                onOwnership(gained, lost, arrived, leaving);
        }
        foreach (ref r; releases)
        {
            auto objects = leaving.get(r.id, null);
            if (isCoordinator)
            {
                if (authority.released(id, r.id, r.epoch))
                    handOver(r.id, objects);
            }
            else if (auto link = coordinatorId in links)
                link.send(RegionReleased(r.id, r.epoch, objects));
            else
                continue; // sent once the coordinator is back
            leaving.remove(r.id);
            regions_.releaseDone(r);
        }

        if (!isCoordinator && coordinatorId in links)
            foreach (kind; pool_.wanted())
                links[coordinatorId].send(IdRequest(kind, config.idBlock));
        if (quorumId)
            appliedOwnership = regions_.leaseHolds(now) ? regions_.latestVersion : 0;
    }

    /// Region ids for the log; with where they are, when there are only a few.
    static string regionIds(const(Region)[] list)
    {
        import std.algorithm.iteration : map;
        import std.algorithm.sorting : sort;
        import std.array : array, join;
        import std.format : format;

        auto sorted = list.dup;
        sorted.sort!((a, b) => a.id < b.id);
        if (sorted.length > 8)
            return "[" ~ sorted.map!(r => format!"%s"(r.id)).join(", ") ~ "]";
        return "[" ~ sorted.map!(r => format!"%s (map %s, cells x %s..%s, y %s..%s)"(r.id, r.map, r.rect.x0,
            r.rect.x1 - 1, r.rect.y0, r.rect.y1 - 1)).join(", ") ~ "]";
    }

    @property ViewMember self() const
    {
        return ViewMember(id, incarnation, config.advertised, isCoordinator);
    }

    Link makeLink(bool dialed, string address, ushort expected)
    {
        auto hello = own;
        hello.expected = expected;
        return new Link(this, clock, hello, dialed, address, config.heartbeatMs.msecs, config.failureTimeoutMs.msecs);
    }

    const(ViewMember)* find(ushort node) const
    {
        foreach (ref m; members)
            if (m.nodeId == node)
                return &m;
        return null;
    }

    // Coordinator: the view changes, and every member hears of it.

    void setMember(ViewMember member)
    {
        foreach (ref m; members)
            if (m.nodeId == member.nodeId)
            {
                if (m == member)
                    return publish(); // the same process reconnected: it needs the view again
                m = member;
                return changed();
            }
        members ~= member;
        changed();
    }

    void dropMember(ushort node)
    {
        import std.algorithm.mutation : remove;

        const before = members.length;
        members = members.remove!(m => m.nodeId == node);
        if (members.length != before)
            changed();
    }

    void changed()
    {
        ++viewVersion;
        info!"cluster: view %s: %s"(viewVersion, memberList());
        publish();
    }

    void publish()
    {
        const view = View(viewCoordinator, viewVersion, members);
        foreach (link; links)
            link.send(view);
    }

    // Members: a newer view, and the links it calls for.

    void takeView(View view)
    {
        if (view.coordinatorIncarnation == viewCoordinator && view.version_ <= viewVersion)
            return;
        viewCoordinator = view.coordinatorIncarnation;
        viewVersion = view.version_;
        members = view.members;
        info!"cluster: view %s: %s"(viewVersion, memberList());

        // Links to nodes gone from the view, or to an incarnation it no longer lists, close.
        foreach (peer, link; links)
        {
            if (link.peer.coordinator)
                continue;
            if (quorumId && (election !is null || config.voter(peer) !is null))
                continue;
            const member = find(peer);
            if (member is null || member.incarnation != link.peer.incarnation)
                link.close("no longer in the view");
        }
        // Peers with a higher id are dialed; dials to nodes that left are dropped.
        const now = clock();
        foreach (ref m; members)
            if (!m.coordinator && m.nodeId > id && (!quorumId || (election is null && config.voter(m.nodeId) is null)))
            {
                auto dial = &dials.require(m.nodeId, Dial(m.address, m.nodeId, now));
                dial.address = m.address;
            }
        ushort[] gone;
        foreach (key, ref dial; dials)
            if (key != coordinatorKey && (!quorumId || config.voter(key) is null) && find(key) is null)
                gone ~= key;
        foreach (key; gone)
            dials.remove(key);
    }

    string memberList() const
    {
        import std.algorithm.iteration : map;
        import std.array : join;
        import std.conv : to;

        return members.map!(m => m.nodeId.to!string ~ (m.coordinator ? " (coordinator)" : "") ~ " at " ~ m.address)
            .join(", ");
    }
}

version (unittest)
{
    import dmangos.cluster.config : ClusterConfig;

    /// Nodes wired back to back in memory, with one clock.
    private final class TestCluster
    {
        MonoTime now;
        this() { now = MonoTime.currTime; }
        ClusterNode[string] listening;      // by advertised address
        bool[string] down;                  // addresses that refuse connections
        bool[ClusterNode] isolated;         // nodes cut off from the network: their bytes are lost
        bool[uint] cutLinks;               // a direct link can fail while both nodes still reach the coordinator
        static struct Wire { Link a, b; ClusterNode from, to; }
        Wire[] wires;

        ClusterNode add(ushort id, ushort port, ulong incarnation = 1, CoordinatorSetup setup = CoordinatorSetup.init,
            bool standby = false, bool gateway = false, ushort coordinatorPort = 9000,
            void delegate(ref ClusterConfig) customize = null)
        {
            import std.format : format;

            ClusterConfig c;
            c.nodeId = id;
            c.listenPort = port;
            c.coordinator = format!"127.0.0.1:%s"(coordinatorPort);
            c.standby = standby;
            c.gateway = gateway;
            c.clientAddress = format!"127.0.0.1:%s"(8000 + id);
            if (customize !is null)
                customize(c);
            ClusterNode node;
            node = new ClusterNode(c, incarnation, () => now, (h, p, s) => dial(node, h, p, s), null, setup);
            listening[c.advertised] = node;
            down.remove(c.advertised);
            return node;
        }

        void dial(ClusterNode from, string host, ushort port, NetSession session)
        {
            import std.format : format;

            auto link = cast(Link) session;
            const address = format!"%s:%s"(host, port);
            auto target = listening.get(address, null);
            if (target is null || address in down || from in isolated || target in isolated
                || linkKey(from, target) in cutLinks)
            {
                link.disconnected();
                return;
            }
            wires ~= Wire(link, cast(Link) target.accept("peer"), from, target);
        }

        private static uint linkKey(ClusterNode a, ClusterNode b)
        {
            return a.id < b.id ? (uint(a.id) << 16) | b.id : (uint(b.id) << 16) | a.id;
        }

        void cut(ClusterNode a, ClusterNode b)
        {
            cutLinks[linkKey(a, b)] = true;
            if (auto link = a.linkTo(b.id))
                link.close("test direct link failure");
            pump();
        }

        void restore(ClusterNode a, ClusterNode b)
        {
            cutLinks.remove(linkKey(a, b));
        }

        /// Moves bytes until nothing moves, then closes what wants closing (as the server does).
        void pump()
        {
            foreach (_; 0 .. 50)
            {
                bool moved;
                foreach (w; wires)
                {
                    if (w.from in isolated || w.to in isolated)
                    {
                        w.a.takeOutput();
                        w.b.takeOutput();
                        continue;
                    }
                    moved |= carry(w.a, w.b);
                    moved |= carry(w.b, w.a);
                }
                if (!moved)
                    break;
            }
            Wire[] kept;
            foreach (w; wires)
                if (w.a.wantsClose || w.b.wantsClose)
                {
                    carry(w.a, w.b);
                    carry(w.b, w.a);
                    w.a.disconnected();
                    w.b.disconnected();
                }
                else
                    kept ~= w;
            wires = kept;
        }

        static bool carry(Link from, Link to)
        {
            const bytes = from.takeOutput().dup;
            if (bytes.length == 0)
                return false;
            if (!to.wantsClose)
                to.receive(bytes);
            return true;
        }

        /// `ms` of time in 50 ms ticks of every node.
        void run(int ms, ClusterNode[] nodes...)
        {
            for (int t = 0; t < ms; t += 50)
            {
                now += 50.msecs;
                foreach (node; nodes)
                    node.tick();
                pump();
            }
        }

        /// A node's process dies: its links break, and its address refuses connections.
        void kill(ClusterNode node)
        {
            Wire[] kept;
            foreach (w; wires)
                if (w.from is node || w.to is node)
                {
                    w.a.disconnected();
                    w.b.disconnected();
                }
                else
                    kept ~= w;
            wires = kept;
            down[node.config.advertised] = true;
        }
    }

    private ushort[] ids(const ClusterNode node)
    {
        import std.algorithm.iteration : map;
        import std.algorithm.sorting : sort;
        import std.array : array;

        ushort[] found = node.view.map!(m => cast(ushort) m.nodeId).array;
        return found.sort.release;
    }
}

/// Joining: everyone gets the same view, and the members link to each other.
unittest
{
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000);
    auto b = cluster.add(2, 9001), c = cluster.add(3, 9002);
    assert(coordinator.isCoordinator && !b.isCoordinator);

    cluster.run(500, coordinator, b, c);
    foreach (node; [coordinator, b, c])
        assert(ids(node) == [1, 2, 3] && node.version_ == coordinator.version_);
    assert(b.linkTo(1) !is null && b.linkTo(3) !is null && c.linkTo(2) !is null && coordinator.linkTo(3) !is null);
    assert(b.linkTo(3).dialed && !c.linkTo(2).dialed, "the lower id dials");

    // Heartbeats measure round trips (zero here: the clock does not move within a tick).
    cluster.run(1000, coordinator, b, c);
    assert(b.linkTo(3).roundTrip == Duration.zero && b.describe().length == 3);
}

/// Failure: a dead node leaves the view; it comes back with a new incarnation and is let in again.
unittest
{
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000);
    auto b = cluster.add(2, 9001), c = cluster.add(3, 9002);
    cluster.run(500, coordinator, b, c);
    const before = coordinator.version_;

    cluster.kill(c);
    cluster.run(100, coordinator, b);
    assert(ids(coordinator) == [1, 2] && ids(b) == [1, 2] && coordinator.version_ == before + 1);
    assert(b.linkTo(3) is null);

    auto c2 = cluster.add(3, 9002, 2);
    cluster.run(6000, coordinator, b, c2); // b's dial to node 3 is backing off
    assert(ids(coordinator) == [1, 2, 3] && ids(b) == [1, 2, 3]);
    assert(b.linkTo(3) !is null && b.linkTo(3).peer.incarnation == 2);
}

/// Silence: a link that hears nothing for the failure timeout closes, though the connection stays.
unittest
{
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000);
    auto b = cluster.add(2, 9001);
    cluster.run(500, coordinator, b);
    assert(ids(coordinator) == [1, 2]);

    // Node 2 hangs: it neither ticks nor answers, but its socket is open.
    cluster.run(3100, coordinator);
    assert(ids(coordinator) == [1], "dropped after three seconds of silence");
}

/// Fencing: an older start of a node is refused, and knows it.
unittest
{
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000);
    auto fresh = cluster.add(2, 9001, 20);
    cluster.run(500, coordinator, fresh);
    assert(coordinator.view[1].incarnation == 20);

    // The old process (incarnation 10) wakes up and dials the coordinator.
    auto stale = cluster.add(2, 9001, 10);
    cluster.run(500, coordinator, stale);
    assert(stale.fenced && coordinator.view[1].incarnation == 20);
    assert(stale.describe()[0].length > 0);

    // A newer start replaces a live one.
    auto newer = cluster.add(2, 9001, 30);
    cluster.run(500, coordinator, newer, fresh);
    assert(coordinator.view[1].incarnation == 30 && coordinator.linkTo(2).peer.incarnation == 30);
}

/// Sequences: a frame delivered twice is applied once, also across a reconnect to the same incarnation.
unittest
{
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000);
    auto b = cluster.add(2, 9001);
    cluster.run(1000, coordinator, b);

    auto link = coordinator.linkTo(2);
    auto peerLink = b.linkTo(1);
    link.send(Heartbeat(1, 0, 0, 0, 0, 0));
    const frame = link.takeOutput().dup;
    peerLink.receive(frame);
    peerLink.receive(frame);
    assert(peerLink.duplicates == 1);

    // The connection breaks; on the new link the numbers go on, so the old frame is still a duplicate.
    cluster.kill(b);
    cluster.listening.remove("127.0.0.1:9001");
    cluster.listening["127.0.0.1:9001"] = b;
    cluster.down.remove("127.0.0.1:9001");
    cluster.run(1000, coordinator, b);
    auto again = b.linkTo(1);
    assert(again !is null && again !is peerLink);
    again.receive(frame);
    assert(again.duplicates == 2);

    // Rubbish closes the link.
    ubyte[16] junk = 0xFF;
    again.receive(junk[]);
    assert(again.wantsClose && again.closeReason.length > 0);
}

version (unittest)
{
    /// The coordinator's counters, as the world server keeps them.
    private final class TestCounters : IdCounters
    {
        uint[IdKind.max + 1] next = [10, 100, 1000, 5, 1, 1];

        uint take(IdKind kind, uint count)
        {
            const first = next[kind];
            next[kind] += count;
            return first;
        }

        void raise(IdKind kind, uint atLeast)
        {
            if (next[kind] < atLeast)
                next[kind] = atLeast;
        }
    }

    /// The node owning cell (x, y) of map 0 in its own view; 0 if none or more than one.
    private ushort ownerSeen(ClusterNode[] nodes, int x, int y)
    {
        import dmangos.world.grid : cellKey;

        ushort owner;
        foreach (node; nodes)
            if (node.regions.ownsCell(0, cellKey(x, y)))
            {
                if (owner)
                    return 0;
                owner = node.id;
            }
        return owner;
    }
}

/// Regions: granted after a lease, handed over on join, taken back from a hung node only after its lease.
unittest
{
    import dmangos.world.grid : cellKey;

    CellCosts costs;
    foreach (x; -40 .. 40)
        costs[0][cellKey(x, x % 7)] = 10;
    auto regions = partition([0u], costs, 8);
    ulong[uint] cost;
    foreach (r; regions)
        cost[r.id] = costOf(costs, r.map, r.rect);
    auto counters = new TestCounters;

    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000, 1, CoordinatorSetup(regions, cost, counters));
    auto b = cluster.add(2, 9001);
    string[] events;
    b.onOwnership = (const(Region)[] gained, const(Region)[] lost, const(ubyte)[][uint], ref ubyte[][uint]) {
        import std.format : format;

        events ~= format!"+%s -%s"(gained.length, lost.length);
    };
    // Every node hands a region's "objects" to its next owner: [region id, the old owner].
    const(ubyte)[][uint][ushort] received;
    void handsOver(ClusterNode node)
    {
        node.onOwnership = (const(Region)[] gained, const(Region)[] lost, const(ubyte)[][uint] arriving,
            ref ubyte[][uint] leaving) {
            foreach (ref r; lost)
                if (r.next)
                    leaving[r.id] = [cast(ubyte) r.id, cast(ubyte) node.id];
            foreach (id, objects; arriving)
                received[node.id][id] = objects;
            if (node is b)
                events ~= "handover";
        };
    }
    handsOver(coordinator);

    // Within the first lease nothing is anyone's.
    cluster.run(4000, coordinator, b);
    assert(ownerSeen([coordinator, b], 0, 0) == 0 && coordinator.regions.ownedRegions.length == 0);

    // Then all eight are dealt out, every cell to exactly one node.
    cluster.run(2000, coordinator, b);
    assert(coordinator.regions.ownedRegions.length + b.regions.ownedRegions.length == 8);
    assert(b.regions.ownedRegions.length >= 3 && coordinator.regions.ownedRegions.length >= 3);
    foreach (x; [-40, -20, 0, 20, 39])
        assert(ownerSeen([coordinator, b], x, x % 7) != 0);
    assert(events.length == 1);

    // A third node joins: regions move to it, each released before it is granted, with its objects.
    handsOver(b);
    auto c = cluster.add(3, 9002);
    handsOver(c);
    cluster.run(2000, coordinator, b, c);
    assert(c.regions.ownedRegions.length >= 1);
    foreach (ref r; c.regions.ownedRegions)
    {
        const bundle = received.get(3, null).get(r.id, null);
        assert(bundle.length == 2 && bundle[0] == r.id && (bundle[1] == 1 || bundle[1] == 2),
            "the old owner's objects came ahead of the grant");
    }
    assert(coordinator.regions.ownedRegions.length + b.regions.ownedRegions.length
        + c.regions.ownedRegions.length == 8);
    foreach (x; [-40, -20, 0, 20, 39])
        assert(ownerSeen([coordinator, b, c], x, x % 7) != 0);

    // Node 3 is cut off. Its lease runs out before anyone else may take its regions, and on no tick
    // does any cell have two owners (each node judged by its own view and clock).
    const before = c.regions.ownedRegions.length;
    cluster.isolated[c] = true;
    void runChecked(int ms)
    {
        import dmangos.world.grid : cellKey;

        foreach (_; 0 .. ms / 50)
        {
            cluster.run(50, coordinator, b, c);
            foreach (x; -40 .. 40)
            {
                size_t owners;
                foreach (node; [coordinator, b, c])
                    owners += node.regions.ownsCell(0, cellKey(x, x % 7));
                assert(owners <= 1, "two nodes own one cell");
            }
        }
    }
    runChecked(4000);
    assert(coordinator.version_ > 3, "the coordinator dropped it after the failure timeout");
    assert(c.regions.ownedRegions.length == before, "4 s in, its 5 s lease still holds");
    assert(coordinator.regions.ownedRegions.length + b.regions.ownedRegions.length == 8 - before,
        "so nobody else has its regions yet");
    runChecked(2000);
    assert(c.regions.ownedRegions.length == 0, "the lease has run out: it stopped by itself");
    assert(coordinator.regions.ownedRegions.length + b.regions.ownedRegions.length == 8,
        "and its regions went to the others after the lease and margin");
    foreach (x; [-40, -20, 0, 20, 39])
        assert(ownerSeen([coordinator, b, c], x, x % 7) != 0);

    // Ids: b asked for blocks and got them once the coordinator had waited for reports.
    uint id1, id2;
    assert(b.pool.take(IdKind.item, id1) && b.pool.take(IdKind.item, id2) && id2 == id1 + 1);
    assert(id1 >= 100 && counters.next[IdKind.item] >= id1 + 1000, "the coordinator never hands it out again");
}

version (unittest)
{
    /// Records what the coordinator decides about this node's sessions.
    private final class TestSessions : SessionHandler
    {
        string[] events;
        void sessionGranted(uint account, ulong serial)
        {
            import std.format : format;

            events ~= format!"grant %s/%s"(account, serial);
        }
        void sessionEvicted(uint account, ulong serial)
        {
            import std.format : format;

            events ~= format!"evict %s/%s"(account, serial);
        }
        void claimAll() {}
    }
}

/// One login per account across nodes: a second login evicts the first, and plays only once it released.
unittest
{
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000);
    auto b = cluster.add(2, 9001);
    auto here = new TestSessions, there = new TestSessions;
    coordinator.sessions = here;
    b.sessions = there;
    cluster.run(500, coordinator, b);

    b.claimSession(7, 100);
    cluster.run(100, coordinator, b);
    assert(there.events == ["grant 7/100"]);

    // The account logs in on the coordinator: b's session is evicted, the new one waits.
    coordinator.claimSession(7, 5);
    cluster.run(100, coordinator, b);
    assert(there.events == ["grant 7/100", "evict 7/100"] && here.events.length == 0);

    // b's session ends, its character saved: the coordinator's may play.
    b.releaseSession(7, 100);
    cluster.run(100, coordinator, b);
    assert(here.events == ["grant 7/5"]);

    // b logs it in again and is cut off before it can release: the account is freed after b's lease.
    coordinator.releaseSession(7, 5);
    b.claimSession(7, 101);
    cluster.run(100, coordinator, b);
    assert(there.events[$ - 1] == "grant 7/101");
    cluster.isolated[b] = true;
    coordinator.claimSession(7, 6);
    cluster.run(4000, coordinator, b);
    assert(here.events[$ - 1] == "grant 7/5", "not yet: b's lease may still hold");
    cluster.run(2000, coordinator, b);
    assert(here.events[$ - 1] == "grant 7/6");
}

/**
 * Phase 7: the coordinator dies; the standby takes over with the table it had, the other member
 * follows it, and nobody's lease lapses: every region stays where it was, and the dead
 * coordinator's regions are dealt out once its lease is surely over.
 */
unittest
{
    import dmangos.world.grid : cellKey;

    CellCosts costs;
    foreach (x; -40 .. 40)
        costs[0][cellKey(x, x % 7)] = 10;
    auto regions = partition([0u], costs, 8);
    ulong[uint] cost;
    foreach (r; regions)
        cost[r.id] = costOf(costs, r.map, r.rect);

    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000, 1, CoordinatorSetup(regions.dup, cost.dup, new TestCounters));
    auto standbyCounters = new TestCounters;
    auto standby = cluster.add(2, 9001, 1, CoordinatorSetup(regions.dup, cost.dup, standbyCounters), true);
    auto member = cluster.add(3, 9002);
    bool promoted;
    standby.onPromoted = () { promoted = true; };
    cluster.run(8000, coordinator, standby, member);
    assert(!standby.isCoordinator && standby.regions.ownedRegions.length && member.regions.ownedRegions.length);
    const standbyHad = standby.regions.ownedRegions.length, memberHad = member.regions.ownedRegions.length;
    const coordinatorHad = coordinator.regions.ownedRegions.length;
    assert(standbyHad + memberHad + coordinatorHad == 8);

    // The coordinator's process dies. Within the failure timeout and the grace the standby takes over;
    // the member follows; their leases hold the whole time, and they keep what they had.
    cluster.kill(coordinator);
    foreach (_; 0 .. 120) // 6 seconds, longer than a lease
    {
        cluster.run(50, standby, member);
        assert(standby.regions.leaseHolds(cluster.now) && member.regions.leaseHolds(cluster.now),
            "no lease lapses while the standby takes over");
        assert(standby.regions.ownedRegions.length >= standbyHad && member.regions.ownedRegions.length >= memberHad);
    }
    assert(standby.isCoordinator && promoted && !member.isCoordinator);
    assert(member.linkTo(2).peer.coordinator, "the member takes the standby as its coordinator");
    assert(ids(standby) == [2, 3] && ids(member) == [2, 3]);

    // Once the old coordinator's lease is surely over, its regions are dealt out again.
    cluster.run(4000, standby, member);
    assert(standby.regions.ownedRegions.length + member.regions.ownedRegions.length == 8);
    foreach (x; [-40, -20, 0, 20, 39])
        assert(ownerSeen([standby, member], x, x % 7) != 0);

    // Ids: the member's blocks now come from the new coordinator's counters (items start at 100 there).
    uint taken;
    assert(member.pool.take(IdKind.item, taken), "a block came from the new coordinator");
    assert(taken >= 100 && taken < standbyCounters.next[IdKind.item]);
}


// A service is a region of a map of its own (docs/SERVICES.md): dealt to one node, and moved, after the
// lease, off a node that was lost; never on two at once.
unittest
{
    import dmangos.cluster.services : isServiceMap, serviceMap, ServiceKind, serviceRegions;
    import dmangos.world.grid : cellKey;

    CellCosts costs;
    foreach (x; -40 .. 40)
        costs[0][cellKey(x, x % 7)] = 10;
    auto regions = partition([0u], costs, 4);
    ulong[uint] cost;
    foreach (r; regions)
        cost[r.id] = costOf(costs, r.map, r.rect);
    uint next;
    foreach (r; regions)
        next = r.id >= next ? r.id + 1 : next;
    foreach (r; serviceRegions([ServiceKind.example], next))
    {
        regions ~= r;
        cost[r.id] = 1;
    }

    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000, 1, CoordinatorSetup(regions.dup, cost.dup, new TestCounters));
    auto b = cluster.add(2, 9001), c = cluster.add(3, 9002);
    ushort[] hosts(ClusterNode[] nodes...)
    {
        ushort[] found;
        foreach (node; nodes)
            foreach (ref r; node.regions.ownedRegions)
                if (r.map == serviceMap(ServiceKind.example))
                    found ~= node.id;
        return found;
    }
    cluster.run(8000, coordinator, b, c);
    const first = hosts(coordinator, b, c);
    assert(first.length == 1, "one node hosts the service");
    assert(coordinator.regions.ownerAt(serviceMap(ServiceKind.example), 0) == first[0], "and every node knows which");

    // Its host (a member, as the dealing falls) is cut off: after its lease the service is another
    // node's, and on no tick has it two hosts.
    assert(first[0] != 1, "dealt to a member");
    auto lostNode = first[0] == 2 ? b : c;
    cluster.isolated[lostNode] = true;
    foreach (_; 0 .. 140)
    {
        cluster.run(50, coordinator, b, c);
        assert(hosts(coordinator, b, c).length <= 1, "two hosts of one service");
    }
    const now = hosts(coordinator, b, c);
    assert(now.length == 1 && now[0] != first[0], "moved off the lost node");
}

// A gateway (docs/SERVICES.md): no regions are dealt to it, and clients are sent to it.
unittest
{
    import dmangos.world.grid : cellKey;

    CellCosts costs;
    foreach (x; -40 .. 40)
        costs[0][cellKey(x, x % 7)] = 10;
    auto regions = partition([0u], costs, 4);
    ulong[uint] cost;
    foreach (r; regions)
        cost[r.id] = costOf(costs, r.map, r.rect);
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000, 1, CoordinatorSetup(regions.dup, cost.dup, new TestCounters));
    auto member = cluster.add(2, 9001);
    auto gateway = cluster.add(3, 9002, 1, CoordinatorSetup.init, false, true);
    cluster.run(8000, coordinator, member, gateway);
    assert(gateway.regions.ownedRegions.length == 0, "a gateway simulates nothing");
    assert(coordinator.regions.ownedRegions.length + member.regions.ownedRegions.length == 4);
    assert(coordinator.leastBusyClientAddress() == "127.0.0.1:8003", "clients go to the gateway");
}

// A gateway keeps its client's socket through a direct-link fault and a separately verified owner crash.
unittest
{
    import std.algorithm.searching : canFind;
    import dmangos.world.character : Character;
    import dmangos.world.clusterbridge : ClusterBridge;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.fencing : FencedDatabase;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientPing;
    import dmangos.world.player : Player;
    import dmangos.world.session : WorldState;
    import dmangos.world.testclient;

    enum uint guid = 7;
    auto cluster = new TestCluster;
    auto coordinator = cluster.add(1, 9000, 1, CoordinatorSetup([
        Region(1, 0, CellRect(-256, -256, 0, 256), 3, 10, RegionState.granted),
        Region(2, 0, CellRect(0, -256, 256, 256), 1, 11, RegionState.granted)],
        [1u: 10UL, 2u: 10UL], new TestCounters));
    auto gateway = cluster.add(2, 9001, 1, CoordinatorSetup.init, false, true);
    auto owner = cluster.add(3, 9002);
    auto db = newDatabase();
    WorldContext[ushort] worlds;
    ClusterBridge[ushort] bridges;
    void connect(ClusterNode bound, bool isGateway)
    {
        auto world = newCreationContext(db, (ref WorldConfig settings) { settings.cluster.gateway = isGateway; });
        world.clock = () => cluster.now;
        world.nodeId = bound.id;
        world.ownsCell = (uint map, ulong cell) => bound.regions.ownsCell(map, cell);
        world.database = new FencedDatabase(db, () => bound.regions.leaseHolds(cluster.now));
        bound.onOwnership = &world.regionsChanged;
        auto bridge = new ClusterBridge(bound, world, 5000);
        bound.sessions = world;
        bound.players = bridge;
        bound.replication = bridge;
        world.replicator = bridge;
        world.playerRelay = bridge;
        world.releaseSession = &bound.releaseSession;
        worlds[bound.id] = world;
        bridges[bound.id] = bridge;
    }
    connect(coordinator, false);
    connect(gateway, true);
    connect(owner, false);
    void ticks(int ms, ClusterNode[] active...)
    {
        foreach (_; 0 .. ms / 50)
        {
            cluster.run(50, active);
            foreach (n; active)
            {
                worlds[n.id].update(cluster.now);
                bridges[n.id].tick();
            }
            cluster.pump();
        }
    }

    ticks(8000, coordinator, gateway, owner);
    const at = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    const cell = cellKeyAt(at.x, at.y);
    assert(gateway.regions.ownerAt(0, cell) == owner.id);
    auto client = loggedIn(worlds[gateway.id], db, guid, "Anduin", at);
    const account = db.loadable[guid].account;
    gateway.claimSession(account, 1);
    ticks(150, coordinator, gateway, owner);
    auto originalSocket = client.session;
    worlds[gateway.id].regionOwnerAround = (uint map, Position p, float radius) =>
        radius == 0 ? gateway.regions.ownerAt(map, cellKeyAt(p.x, p.y)) : ushort.init;
    originalSocket.update(1100.msecs);
    ticks(300, coordinator, gateway, owner);
    auto simulated = cast(Character) worlds[owner.id].onlinePlayer(guid);
    assert(simulated !is null && originalSocket.state == WorldState.elsewhere && originalSocket.owner == owner.id);
    client.read();

    cluster.cut(gateway, owner);
    simulated.deliver(Opcode.SMSG_NOTIFICATION, cast(const(ubyte)[]) "Buffered during the link outage.\0");
    ticks(6500, coordinator, gateway, owner);
    assert(coordinator.simulationOwner(owner.id).node == owner.id && originalSocket.owner == owner.id);
    assert(!originalSocket.wantsClose && worlds[owner.id].onlinePlayer(guid) is simulated);
    client.write(Opcode.CMSG_PING, ClientPing(7, 0));
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_PONG), "the gateway answers while the owner link is down");
    cluster.restore(gateway, owner);
    ticks(8000, coordinator, gateway, owner);
    assert(gateway.linkTo(owner.id) !is null && worlds[owner.id].onlinePlayer(guid) is simulated);
    auto resumed = opcodesOf(client.read());
    assert(resumed.canFind(Opcode.SMSG_NOTIFICATION) && !resumed.canFind(Opcode.SMSG_NEW_WORLD));

    // A subsequent handoff goes through the gateway too. The directory's crash proof must follow it.
    worlds[owner.id].regionOwnerAround = (uint, Position, float) => coordinator.id;
    ticks(1800, coordinator, gateway, owner);
    assert(originalSocket.owner == coordinator.id && worlds[owner.id].onlinePlayer(guid) is null);
    worlds[owner.id].regionOwnerAround = null;
    worlds[coordinator.id].regionOwnerAround = (uint, Position, float) => owner.id;
    ticks(11500, coordinator, gateway, owner);
    worlds[coordinator.id].regionOwnerAround = null;
    simulated = cast(Character) worlds[owner.id].onlinePlayer(guid);
    assert(simulated !is null && originalSocket.owner == owner.id
        && worlds[coordinator.id].onlinePlayer(guid) is null);

    auto oldPlayer = cast(Player) simulated.character;
    oldPlayer.movement.position.x += 5;
    ticks(15500, coordinator, gateway, owner);
    const checkpoint = db.progressSaves[$ - 1].position;
    assert(checkpoint.x == at.x + 5, "gateway-hosted players periodically checkpoint");
    db.loadable[guid].position = checkpoint; // the in-memory database records writes separately from reads
    oldPlayer.movement.position.x += 5;
    client.read();
    cluster.kill(owner);
    ticks(3500, coordinator, gateway);
    assert(worlds[coordinator.id].onlinePlayer(guid) is null && !originalSocket.wantsClose);
    assert(!opcodesOf(client.read()).canFind(Opcode.SMSG_NEW_WORLD), "no recovery before the lease expires");

    ticks(4000, coordinator, gateway);
    bridges[owner.id].fenceGatewaySimulations();
    assert(worlds[owner.id].onlinePlayer(guid) is null, "the former worker cannot keep simulating with an expired lease");
    assert(gateway.regions.ownerAt(0, cell) == coordinator.id);
    assert(client.session is originalSocket && !originalSocket.wantsClose && originalSocket.owner == coordinator.id);
    const transfer = opcodesOf(client.read());
    assert(transfer.canFind(Opcode.SMSG_TRANSFER_PENDING) && transfer.canFind(Opcode.SMSG_NEW_WORLD));
    assert(worlds[coordinator.id].onlinePlayer(guid) is null, "wait for the client to load the map");
    client.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    ticks(250, coordinator, gateway);
    auto restored = worlds[coordinator.id].onlinePlayer(guid);
    assert(restored !is null && restored.character.position == checkpoint);
    assert(!opcodesOf(client.read()).canFind(Opcode.SMSG_LOGIN_VERIFY_WORLD));

    auto stale = cluster.add(owner.id, 9002, owner.incarnation);
    cluster.run(1000, coordinator, gateway, stale);
    assert(stale.fenced && coordinator.simulationOwner(stale.id).node == 0, "the old process cannot renew its lease");
}

// The old coordinator remains connected to a worker, but loses permission to renew either lease.
version (linux) unittest
{
    import dmangos.cluster.config : ClusterVoter;
    import dmangos.world.clusterbridge : ClusterBridge;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.fencing : FencedDatabase;
    import dmangos.world.grid : cellKey, cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.testclient;
    import std.algorithm.searching : canFind, count;
    import std.conv : to;
    import std.file : mkdir, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const path = buildPath(tempDir(), "dmangos-quorum-" ~ randomUUID().to!string);
    mkdir(path);
    scope (exit) rmdirRecurse(path);
    auto cluster = new TestCluster;
    auto regions = new Region[12];
    ulong[uint] cost;
    foreach (i, ref region; regions)
    {
        const x = -200 + cast(int) i * 10;
        region = Region(cast(uint) i + 1, 0, CellRect(x, -256, x + 10, 256));
        cost[region.id] = 10;
    }
    void configure(ref ClusterConfig settings)
    {
        settings.voters = [ClusterVoter(1, "127.0.0.1:9000"), ClusterVoter(2, "127.0.0.1:9001"),
            ClusterVoter(3, "127.0.0.1:9002")];
        settings.voteFile = buildPath(path, settings.nodeId.to!string);
        settings.validate();
    }
    ClusterNode voter(ushort id, ushort port)
    {
        return cluster.add(id, port, id, CoordinatorSetup(regions.dup, cost.dup, new TestCounters),
            false, false, 9000, &configure);
    }
    auto primary = voter(1, 9000);
    auto second = voter(2, 9001);
    auto third = voter(3, 9002);
    auto isolatedWorker = cluster.add(4, 9003, 4, CoordinatorSetup.init, false, false, 9000, &configure);
    auto gateway = cluster.add(5, 9004, 5, CoordinatorSetup.init, false, true, 9000, &configure);
    auto nodes = [primary, second, third, isolatedWorker, gateway];
    auto db = newDatabase();
    WorldContext[ushort] worlds;
    ClusterBridge[ushort] bridges;
    void connect(ClusterNode node)
    {
        auto world = newCreationContext(db, (ref WorldConfig settings) { settings.cluster = node.config; });
        world.clock = () => cluster.now;
        world.nodeId = node.id;
        world.ownsCell = (uint map, ulong cell) => node.regions.ownsCell(map, cell);
        world.database = new FencedDatabase(db, () => node.regions.leaseHolds(cluster.now));
        node.onOwnership = &world.regionsChanged;
        auto bridge = new ClusterBridge(node, world, 5000);
        node.onTermChanged = &bridge.fenceGatewaySimulations;
        node.sessions = world;
        node.players = bridge;
        node.replication = bridge;
        world.replicator = bridge;
        world.playerRelay = bridge;
        world.releaseSession = &node.releaseSession;
        worlds[node.id] = world;
        bridges[node.id] = bridge;
    }
    foreach (node; nodes)
        connect(node);

    void run(int milliseconds)
    {
        foreach (_; 0 .. milliseconds / 50)
        {
            cluster.run(50, nodes);
            foreach (node; nodes)
            {
                bridges[node.id].fenceGatewaySimulations();
                worlds[node.id].update(cluster.now);
                bridges[node.id].tick();
            }
            cluster.pump();
            assert(nodes.count!(n => n.isCoordinator) <= 1, "only one coordinator may hold authority");
            foreach (ref region; regions)
            {
                const cell = cellKey(region.rect.x0, region.rect.y0);
                assert(nodes.count!(n => n.regions.leaseHolds(cluster.now) && n.regions.ownsCell(0, cell)) <= 1,
                    "no cell may have two owners across election terms");
            }
        }
    }

    run(8000);
    assert(primary.isCoordinator && !primary.regions.ownedRegions.length);
    primary.reportLoads([]);
    isolatedWorker.reportLoads([]);
    run(6000);
    assert(primary.isCoordinator && primary.messageTerm() && isolatedWorker.regions.ownedRegions.length);
    assert(isolatedWorker.coordinatorNode == primary.id && gateway.coordinatorNode == primary.id);
    enum uint guid = 7;
    const at = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
    const cell = cellKeyAt(at.x, at.y);
    assert(gateway.regions.ownerAt(0, cell) == third.id);
    auto client = loggedIn(worlds[gateway.id], db, guid, "Anduin", at);
    auto socket = client.session;
    gateway.claimSession(db.loadable[guid].account, 1);
    run(150);
    worlds[gateway.id].regionOwnerAround = (uint map, Position p, float) =>
        gateway.regions.ownerAt(map, cellKeyAt(p.x, p.y));
    socket.update(1100.msecs);
    run(300);
    auto before = worlds[third.id].onlinePlayer(guid);
    assert(before !is null && socket.owner == third.id);
    client.read();

    const term = primary.messageTerm();
    foreach (isolated; [primary, isolatedWorker])
        foreach (remaining; [second, third, gateway])
            cluster.cut(isolated, remaining);

    run(7000);
    assert(primary.linkTo(isolatedWorker.id) !is null, "the isolated coordinator still reaches its worker");
    assert(!primary.isCoordinator && !primary.regions.leaseHolds(cluster.now)
        && !isolatedWorker.regions.leaseHolds(cluster.now) && !isolatedWorker.regions.ownedRegions.length);
    run(9000);
    auto leader = second.isCoordinator ? second : third;
    assert(leader.isCoordinator && leader.messageTerm() > term && gateway.coordinatorNode == leader.id);
    assert(leader.regions.ownedRegions.length && gateway.regions.leaseHolds(cluster.now));
    assert(gateway.regions.ownerAt(0, cell) == third.id && worlds[third.id].onlinePlayer(guid) is null);
    assert(opcodesOf(client.read()).canFind(Opcode.SMSG_NEW_WORLD),
        "the old simulation expired even though its worker stayed in the majority");
    client.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    run(300);
    auto after = worlds[third.id].onlinePlayer(guid);
    assert(after !is null && after !is before && !socket.wantsClose && client.session is socket);
    foreach (isolated; [primary, isolatedWorker])
        foreach (remaining; [second, third, gateway])
            cluster.restore(isolated, remaining);
    run(12000);
    assert(leader.isCoordinator && !primary.isCoordinator && primary.coordinatorNode == leader.id);
    assert(isolatedWorker.coordinatorNode == leader.id && isolatedWorker.regions.leaseHolds(cluster.now));
}

// Gateway recovery during takeover with the worker missing before or after the old coordinator.
unittest
{
    import std.algorithm.searching : canFind, count;
    import dmangos.world.clusterbridge : ClusterBridge;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.fencing : FencedDatabase;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.packets : ClientPing;
    import dmangos.world.testclient;

    foreach (workerFirst; [true, false])
    {
        enum uint guid = 7;
        auto cluster = new TestCluster;
        auto setup = CoordinatorSetup([
            Region(1, 0, CellRect(-256, -256, 0, 256), 3, 10, RegionState.granted),
            Region(2, 0, CellRect(0, -256, 256, 256), 1, 11, RegionState.granted)],
            [1u: 10UL, 2u: 10UL], new TestCounters);
        auto primary = cluster.add(1, 9000, 1, setup);
        setup.ids = new TestCounters;
        auto standby = cluster.add(2, 9001, 2, setup, true);
        auto worker = cluster.add(3, 9002, 3);
        auto gateway = cluster.add(4, 9003, 4, CoordinatorSetup.init, false, true);
        auto db = newDatabase();
        WorldContext[ushort] worlds;
        ClusterBridge[ushort] bridges;
        void connect(ClusterNode node)
        {
            auto world = newCreationContext(db, (ref WorldConfig settings) {
                settings.cluster.gateway = node is gateway;
            });
            world.clock = () => cluster.now;
            world.nodeId = node.id;
            world.ownsCell = (uint map, ulong cell) => node.regions.ownsCell(map, cell);
            world.database = new FencedDatabase(db, () => node.regions.leaseHolds(cluster.now));
            node.onOwnership = &world.regionsChanged;
            auto bridge = new ClusterBridge(node, world, 5000);
            node.sessions = world;
            node.players = bridge;
            node.replication = bridge;
            world.replicator = bridge;
            world.playerRelay = bridge;
            world.releaseSession = &node.releaseSession;
            worlds[node.id] = world;
            bridges[node.id] = bridge;
        }
        connect(primary);
        connect(standby);
        connect(worker);
        connect(gateway);
        void ticks(int ms, ClusterNode[] active...)
        {
            foreach (_; 0 .. ms / 50)
            {
                cluster.run(50, active);
                foreach (node; active)
                {
                    bridges[node.id].fenceGatewaySimulations();
                    worlds[node.id].update(cluster.now);
                    bridges[node.id].tick();
                }
                cluster.pump();
            }
        }

        ticks(8000, primary, standby, worker, gateway);
        const at = Position(-8949.95f, -132.49f, 83.53f, 1.97f);
        const cell = cellKeyAt(at.x, at.y);
        assert(gateway.regions.ownerAt(0, cell) == worker.id);
        auto client = loggedIn(worlds[gateway.id], db, guid, "Anduin", at);
        auto socket = client.session;
        const account = db.loadable[guid].account;
        gateway.claimSession(account, 1);
        ticks(150, primary, standby, worker, gateway);
        worlds[gateway.id].regionOwnerAround = (uint map, Position p, float) =>
            gateway.regions.ownerAt(map, cellKeyAt(p.x, p.y));
        socket.update(1100.msecs);
        ticks(300, primary, standby, worker, gateway);
        assert(socket.owner == worker.id && worlds[worker.id].onlinePlayer(guid) !is null);
        assert(bridges[gateway.id].gatewaySessionRoutes().length == 1);
        client.read();

        if (workerFirst)
        {
            cluster.kill(worker);
            assert(standby.regions.ownerAt(0, cell) == worker.id, "the last replicated table still names the worker");
            cluster.kill(primary);
        }
        else
        {
            cluster.kill(primary);
            ticks(200, standby, worker, gateway);
            cluster.kill(worker);
        }
        ticks(2000, standby, gateway);
        assert(standby.isCoordinator && gateway.coordinatorNode == standby.id);
        assert(gateway.regions.ownerAt(0, cell) == 0 && worlds[standby.id].onlinePlayer(guid) is null);
        assert(!socket.wantsClose && !opcodesOf(client.read()).canFind(Opcode.SMSG_NEW_WORLD));
        client.write(Opcode.CMSG_PING, ClientPing(1, 0));
        assert(opcodesOf(client.read()).canFind(Opcode.SMSG_PONG));

        // A shared map grant can reach the gateway before the replacement can apply it.
        bool canApplyGrant;
        standby.regions.allowMap = (uint) => canApplyGrant;
        ticks(5000, standby, gateway);
        bridges[worker.id].fenceGatewaySimulations();
        assert(worlds[worker.id].onlinePlayer(guid) is null);
        assert(gateway.regions.ownerAt(0, cell) == standby.id && socket.owner == standby.id && !socket.wantsClose);
        assert(!opcodesOf(client.read()).canFind(Opcode.SMSG_NEW_WORLD), "wait for the grant to take effect");
        client.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        ticks(200, standby, gateway);
        assert(worlds[standby.id].onlinePlayer(guid) is null, "an early acknowledgement cannot start gameplay");

        canApplyGrant = true;
        ticks(300, standby, gateway);
        const transfer = opcodesOf(client.read());
        assert(transfer.count(Opcode.SMSG_NEW_WORLD) == 1 && transfer.canFind(Opcode.SMSG_TRANSFER_PENDING));
        assert(worlds[standby.id].onlinePlayer(guid) is null, "the client has not acknowledged the transfer yet");
        client.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
        ticks(300, standby, gateway);
        auto restored = worlds[standby.id].onlinePlayer(guid);
        assert(restored !is null && restored.character.position == at && client.session is socket);
        assert(!opcodesOf(client.read()).canFind(Opcode.SMSG_LOGIN_VERIFY_WORLD));

        auto stale = cluster.add(worker.id, 9002, worker.incarnation, CoordinatorSetup.init, false, false, 9001);
        cluster.run(1000, standby, gateway, stale);
        assert(stale.fenced && standby.simulationOwner(worker.id).node == 0);
        assert(worlds[standby.id].onlinePlayer(guid) is restored && !socket.wantsClose);
    }
}

// Live helpers and their loot can return home even after the borrower or home owner fails.
unittest
{
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.replication : encodeState;
    import dmangos.world.testclient;
    import dmangos.world.updatefields : UNIT_FIELD_FACTIONTEMPLATE, UNIT_FIELD_HEALTH;

    foreach (scenario; 0 .. 5)
    {
        enum uint worldMap = 0;
        const homeCell = cellKeyAt(-8948, -134);
        const callerGuid = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
        const helperGuid = makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn);
        auto cluster = new TestCluster;
        auto coordinator = cluster.add(1, 9000, 1, CoordinatorSetup([
            Region(1, worldMap, CellRect(-256, -256, 0, -2), 3, 10, RegionState.granted),
            Region(2, worldMap, CellRect(-256, -2, 0, 0), 2, 11, RegionState.granted),
            Region(3, worldMap, CellRect(0, -256, 256, 256), 1, 12, RegionState.granted)],
            [1u: 10UL, 2u: 10UL, 3u: 1UL], new TestCounters));
        auto borrower = cluster.add(2, 9001), original = cluster.add(3, 9002);
        auto db = newDatabase();
        WorldContext[ushort] worlds;
        foreach (node; [coordinator, borrower, original])
        {
            auto world = newCreationContext(db, (ref config) { config.cluster.nodeId = node.id; });
            worlds[node.id] = world;
            world.clock = () => cluster.now;
            world.nodeId = node.id;
            // Capture this node in its own activation record.
            void connect(ClusterNode bound, WorldContext context)
            {
                context.ownsCell = (uint map, ulong cell) => bound.regions.ownsCell(map, cell);
                context.creatureLease = &bound.regions.creatureRegion;
                context.sendCreatureLoan = &bound.creatureLoan;
                bound.onCreatureRelease = &context.releaseCreatureLoan;
                bound.onOwnership = &context.regionsChanged;
            }
            connect(node, world);
            foreach (ref spawn; world.data.creatureSpawns)
                if (spawn.guid == trainerSpawn)
                {
                    spawn.y = -134;
                    spawn.respawnSeconds = 300;
                }
            world.data.creatureCells[worldMap] = null;
            foreach (i, ref spawn; world.data.creatureSpawns)
                world.data.creatureCells.require(worldMap, null).require(cellKeyAt(spawn.x, spawn.y), null) ~= i;
            world.data.creatureTemplates.edit(creatureTrainer).faction = 14;
            world.data.creatureTemplates.edit(creatureTrainer).detection = 0;
            world.data.creatureTemplates.edit(creatureTrainer).minLootGold = 25;
            world.data.creatureTemplates.edit(creatureTrainer).maxLootGold = 25;
            world.data.creatureTemplates.edit(creatureInnkeeper).faction = 14;
        }

        cluster.run(8000, coordinator, borrower, original);
        auto battlefield = worlds[2];
        auto client = loggedIn(battlefield, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
        const humans = client.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
        foreach (world; worlds)
            world.client.factionTemplates = typeof(world.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
                [[humans, 1, 0, 3, 2, 8, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 1, 8, 8, 1, 0, 0,
                0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
        auto homeMap = worlds[3].map(worldMap);
        homeMap.peerInterest(2, [homeCell], null);
        auto helper = homeMap.creatureAt(helperGuid);
        auto field = battlefield.map(worldMap);
        auto caller = field.creatureAt(callerGuid);
        assert(helper !is null, "helper starts under its physical home owner");
        assert(caller !is null, "caller starts on the borrower's side of the border");
        caller.factionTemplate = battlefield.client.factionTemplates.lookup(14);
        field.replicaCreated(3, homeCell, helperGuid, encodeState(helper, 0));

        client.write(Opcode.CMSG_ATTACKSWING, ClientGuid(callerGuid));
        foreach (_; 0 .. 40)
        {
            battlefield.update(cluster.now);
            cluster.run(50, coordinator, borrower, original);
        }
        assert(borrower.regions.creatureRegion(trainerSpawn).owner == 2);
        assert(homeMap.creatureAt(helperGuid) is null);
        helper = field.creatureAt(helperGuid);
        assert(helper !is null && helper.ai.inCombat && helper.ai.currentVictim == 7);

        const died = scenario >= 3;
        const playerGuid = client.session.character.guid;
        if (died)
        {
            helper.setLootRecipient(playerGuid, 0);
            helper.values.set!UNIT_FIELD_HEALTH(0);
            battlefield.onlinePlayer(playerGuid).killedCreature(helper);
            assert(helper.loot !is null && helper.loot.gold == 25);
            assert(db.loadOutdoorCorpses().length == 1 && trainerSpawn in db.creatureRespawns);
        }
        const homeMoved = scenario == 0 || scenario == 1 || scenario == 4;
        if (scenario == 0 || scenario == 4)
            coordinator.authority.drain(original.id);
        else if (scenario == 1)
            cluster.isolated[original] = true; // its process still ticks until its lease expires
        else
            cluster.isolated[borrower] = true;
        if (homeMoved)
        {
            cluster.run(12000, coordinator, borrower, original);
            const newHome = coordinator.regions.ownerAt(worldMap, homeCell);
            assert(newHome == coordinator.id, "the home moved to the third node while the loan stayed on node 2");
            assert(borrower.regions.creatureRegion(trainerSpawn).owner == 2);
            auto newHomeMap = worlds[newHome].map(worldMap);
            newHomeMap.peerInterest(2, [homeCell], null);
            assert(newHomeMap.creatureAt(helperGuid) is null, "the moved home cannot spawn an active loan");
            if (died)
                cluster.isolated[borrower] = true;
            else
                client.session.clientGone();
        }

        foreach (_; 0 .. 480)
        {
            cluster.run(50, coordinator, borrower, original);
            foreach (world; worlds)
                world.update(cluster.now);
            size_t copies;
            foreach (world; worlds)
                copies += world.map(worldMap).creatureAt(helperGuid) !is null;
            assert(copies <= 1, "at most one node may simulate the helper");
            if (!coordinator.regions.creatureRegion(trainerSpawn).creature.spawn)
                break;
        }
        const home = coordinator.regions.ownerAt(worldMap, homeCell);
        assert(home);
        auto returned = worlds[home].map(worldMap).creatureAt(helperGuid);
        assert(returned !is null, "the creature returned home");
        if (died)
        {
            assert(!returned.alive && returned.loot !is null && returned.loot.gold == 25);
            assert(returned.loot.owners[playerGuid]);
            assert(worlds[home].awaitingRespawn(trainerSpawn), "the same death still owns the spawn");
        }
        else
            assert(returned.alive);
        assert(!coordinator.regions.creatureRegion(trainerSpawn).creature.spawn, "the temporary lease was retired");
    }
}
