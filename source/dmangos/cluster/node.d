/**
 * A world server's membership in a cluster (docs/CLUSTER.md, phases 1 and 2).
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
 * Regions (phase 2, `dmangos.cluster.ownership`): the coordinator holds the `RegionAuthority` and
 * publishes its table whenever it changes; every node keeps a `RegionView`, renews its lease from the
 * coordinator's heartbeat echoes, and tells the world server (`onOwnership`) which regions it gained
 * and lost, then answers the releases the coordinator waits for. Ids come in blocks from the
 * coordinator's counters (`IdPool`, `IdCounters`).
 */
module dmangos.cluster.node;

import core.time : Duration, MonoTime, msecs, seconds;

import dmangos.cluster.config : ClusterConfig, splitAddress;
import dmangos.cluster.link;
import dmangos.cluster.ownership;
import dmangos.cluster.protocol;
import dmangos.cluster.regions;
import dmangos.cluster.sessions;
import dmangos.log;
import dmangos.net.server : NetSession;

/// Opens a connection for `session` to `host:port`; a failure ends in `session.disconnected()`.
alias Dialer = void delegate(string host, ushort port, NetSession session);

/// What the coordinator starts with: the world divided into regions, and the id counters it hands out from.
struct CoordinatorSetup
{
    Region[] regions;     /// from `partition`
    ulong[uint] cost;     /// what each region costs, by id
    IdCounters ids;
}

/**
 * What a node does with replication messages (phase 3): the world server implements it. Peers are
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
}

/// What a node does with session decisions (phase 3b): the world server implements it.
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

    /// Where session decisions go (phase 3b).
    SessionHandler sessions;

    /**
     * The world server starts simulating `gained` and stops simulating `lost` (phase 2). For a gained
     * region whose last owner handed over its objects, `arriving` has their state (by region id); for a
     * lost region on its way to another node (`Region.next`), the world puts its objects' state in
     * `leaving`, and it goes with the release (phase 4).
     */
    void delegate(const(Region)[] gained, const(Region)[] lost, const(ubyte)[][uint] arriving,
        ref ubyte[][uint] leaving) onOwnership;

    /// Where replication messages go (phase 3); null: they are dropped.
    ReplicationHandler replication;

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
            return act(directory.claim(account, SessionRef(id, serial)));
        if (auto link = coordinatorId in links)
            link.send(SessionClaim(account, serial));
        else
            claimsWaiting ~= SessionClaim(account, serial);
    }

    /// Session `serial` of `account` ended, its character saved.
    void releaseSession(uint account, ulong serial)
    {
        if (isCoordinator)
            return act(directory.released(account, SessionRef(id, serial)));
        if (auto link = coordinatorId in links)
            link.send(SessionReleased(account, serial));
        else
            releasesWaiting ~= SessionReleased(account, serial);
    }

    /**
     * The client address of the node with the fewest players (by their heartbeats; this node's own
     * load from `load`), for the realm list; empty if none has one.
     */
    string leastBusyClientAddress()
    {
        string best = config.clientAddress;
        uint fewest = load is null ? 0 : load().players;
        foreach (link; links)
            if (link.peer.clientAddress.length && link.peerLoad.players < fewest)
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
        LoadReport delegate() load = null, CoordinatorSetup setup = CoordinatorSetup.init)
    in (config.enabled && clock !is null && dialer !is null)
    {
        this.config = config;
        this.id = config.nodeId;
        this.incarnation = incarnation;
        this.clock = clock;
        this.dialer = dialer;
        this.load = load;
        own = Hello(protocolVersion, config.name, id, incarnation, config.advertised, config.clientAddress,
            config.isCoordinator, 0);
        const lease = config.leaseMs.msecs;
        regions_ = new RegionView(id, isCoordinator, lease);
        if (isCoordinator)
        {
            viewCoordinator = incarnation;
            members = [self];
            viewVersion = 1;
            authority = new RegionAuthority(setup.regions, setup.cost, id, incarnation, lease, clock);
            ids = setup.ids;
            idGrantsFrom = clock() + lease + leaseMargin;
            directory = new SessionDirectory;
        }
        else
        {
            dials[coordinatorKey] = Dial(config.coordinator, 0, clock());
            pool_ = new IdPool(config.idBlock);
        }
    }

    /// What this node owns (phase 2).
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

    /// Whether this node is the coordinator.
    @property bool isCoordinator() const @safe
    {
        return config.isCoordinator;
    }

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

    /// A new connection from another node (the cluster listener's session factory).
    NetSession accept(string remoteAddress)
    {
        auto link = makeLink(false, remoteAddress, 0);
        handshaking ~= link;
        return link;
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
        updateOwnership(now);
        if (fenced_)
            return;
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
        if (isCoordinator)
        {
            if (const known = hello.nodeId in highestIncarnation)
                if (hello.incarnation < *known)
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
                old.close("replaced by a newer link");
        links[peer] = link;
        foreach (ref dial; dials)
            if (dial.pending is link)
            {
                dial.pending = null;
                dial.backoff = firstBackoff;
            }
        if (link.peer.coordinator)
            coordinatorId = peer;
        info!"cluster: linked to node %s at %s (incarnation %s)"(peer, link.peer.address, link.peer.incarnation);
        if (replication !is null)
            replication.peerLinked(peer);
        if (isCoordinator)
            directory.back(peer);
        else if (link.peer.coordinator)
        {
            foreach (claim; claimsWaiting)
                link.send(claim);
            foreach (release; releasesWaiting)
                link.send(release);
            claimsWaiting = null;
            releasesWaiting = null;
            if (sessions !is null)
                sessions.claimAll(); // a new coordinator knows nothing of them
        }

        if (isCoordinator)
        {
            highestIncarnation[peer] = link.peer.incarnation;
            setMember(ViewMember(peer, link.peer.incarnation, link.peer.address, false));
            link.send(RegionTable(incarnation, authority.version_, authority.regions.dup));
            authority.joined(peer);
        }
        else if (link.peer.coordinator)
        {
            link.send(IdReport(pool_.highest(IdKind.character), pool_.highest(IdKind.item),
                pool_.highest(IdKind.mail), pool_.highest(IdKind.group)));
            pool_.reset();
        }
    }

    void received(Link link, MessageType type, const(ubyte)[] payload)
    {
        const peer = link.peer.nodeId;
        if (type >= MessageType.sessionClaim && type <= MessageType.sessionReleased)
            return session(peer, link, type, payload);
        if (type >= MessageType.interestUpdate && type <= MessageType.replicaRemove)
            return replicate(peer, type, payload);
        if (!isCoordinator && link.peer.coordinator)
            switch (type)
            {
            case MessageType.view:
                return takeView(decode!View(payload));
            case MessageType.regionTable:
                auto table = decode!RegionTable(payload);
                if (table.coordinatorIncarnation == link.peer.incarnation)
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
                authority.released(peer, release.region, release.epoch);
                return handOver(release.region, release.objects);
            case MessageType.idRequest:
                idRequests[peer] ~= decode!IdRequest(payload);
                return;
            case MessageType.idReport:
                if (ids is null)
                    return;
                const report = decode!IdReport(payload);
                ids.raise(IdKind.character, report.character);
                ids.raise(IdKind.item, report.item);
                ids.raise(IdKind.mail, report.mail);
                ids.raise(IdKind.group, report.group);
                return;
            default:
                return;
            }
    }

    void closed(Link link)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

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
            dials[coordinatorKey].due = now + dials[coordinatorKey].backoff;
        }
        if (isCoordinator)
        {
            dropMember(peer);
            authority.lost(peer, link.lastHeard);
            directory.lost(peer, link.lastHeard + config.leaseMs.msecs + leaseMargin);
            idRequests.remove(peer);
        }
    }

private:
    /// A session message: claims and releases on the coordinator, grants and evictions on members.
    void session(ushort peer, Link link, MessageType type, const(ubyte)[] payload)
    {
        if (isCoordinator)
        {
            if (type == MessageType.sessionClaim)
            {
                const m = decode!SessionClaim(payload);
                act(directory.claim(m.account, SessionRef(peer, m.serial)));
            }
            else if (type == MessageType.sessionReleased)
            {
                const m = decode!SessionReleased(payload);
                act(directory.released(m.account, SessionRef(peer, m.serial)));
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
                const table = RegionTable(incarnation, authority.version_, authority.regions.dup);
                regions_.take(incarnation, table.version_, table.regions.dup);
                foreach (link; links)
                    link.send(table);
            }
            if (now >= idGrantsFrom && ids !is null)
            {
                foreach (peer, requests; idRequests)
                    if (auto link = peer in links)
                        foreach (request; requests)
                            link.send(IdGrant(request.kind, ids.take(request.kind, request.count), request.count));
                idRequests = null;
            }
        }
        else if (coordinatorId)
            if (auto link = coordinatorId in links)
                if (link.peer.incarnation == regions_.coordinator)
                    regions_.confirm(link.confirmedAt);

        Region[] gained, lost;
        regions_.refresh(now, gained, lost);
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
        foreach (ref r; regions_.releases())
        {
            auto objects = leaving.get(r.id, null);
            if (isCoordinator)
            {
                authority.released(id, r.id, r.epoch);
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
            const member = find(peer);
            if (member is null || member.incarnation != link.peer.incarnation)
                link.close("no longer in the view");
        }
        // Peers with a higher id are dialed; dials to nodes that left are dropped.
        const now = clock();
        foreach (ref m; members)
            if (!m.coordinator && m.nodeId > id)
            {
                auto dial = &dials.require(m.nodeId, Dial(m.address, m.nodeId, now));
                dial.address = m.address;
            }
        ushort[] gone;
        foreach (key, ref dial; dials)
            if (key != coordinatorKey && find(key) is null)
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
        static struct Wire { Link a, b; ClusterNode from, to; }
        Wire[] wires;

        ClusterNode add(ushort id, ushort port, ulong incarnation = 1, CoordinatorSetup setup = CoordinatorSetup.init)
        {
            import std.format : format;

            ClusterConfig c;
            c.nodeId = id;
            c.listenPort = port;
            c.coordinator = "127.0.0.1:9000";
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
            if (target is null || address in down || from in isolated || target in isolated)
            {
                link.disconnected();
                return;
            }
            wires ~= Wire(link, cast(Link) target.accept("peer"), from, target);
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
        uint[4] next = [10, 100, 1000, 5];

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
    // Every node hands a region's "objects" to its next owner (phase 4): [region id, the old owner].
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
