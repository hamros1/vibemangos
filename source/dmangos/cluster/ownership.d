/**
 * Who owns which region, and the id blocks nodes allocate from (docs/CLUSTER.md, phase 2).
 *
 * The coordinator's `RegionAuthority` grants regions and takes them back. Every grant carries a new
 * epoch, larger than any before it, even across restarts of the coordinator (its incarnation is the
 * high part). Moving a region is two steps: the coordinator marks it `revoking`; the owner stops
 * simulating it and answers `RegionReleased` with the epoch; only then is it granted to the new
 * owner. So two nodes never simulate a region at once.
 *
 * A node that stops answering cannot release anything, so ownership is also a **lease**: a node may
 * act on its regions only until `lease` after the last heartbeat of its own that the coordinator
 * echoed (`RegionView.confirm`). The coordinator gives a lost node's regions away only after `lease`
 * and a margin have passed since it last heard from it, when that node has certainly stopped. Only
 * clocks that run at about the same rate are needed, not synchronized ones. For the same reason a
 * newly started coordinator grants nothing until one lease has passed: whatever the previous one
 * granted has run out by then.
 *
 * Ids (characters, items, mails, groups) must not be handed out twice in the cluster: the coordinator
 * hands blocks of them out from its counters (`IdAuthority`), and a member takes ids from its blocks,
 * asking for the next one early (`IdPool`) so the hot path never waits.
 */
module dmangos.cluster.ownership;

import core.time : Duration, MonoTime, msecs, seconds;
import std.algorithm.comparison : max;

import dmangos.cluster.regions;
import dmangos.log;

/// The margin added to a lease for clocks that do not run at quite the same rate.
enum Duration leaseMargin = 500.msecs;

/// See the module documentation.
final class RegionAuthority
{
    private
    {
        Region[] regions_;
        ulong[uint] cost;
        immutable ushort self;
        ulong epochBase;
        uint epochCount;
        ulong tableVersion = 1;
        bool[ushort] members;          // live members, the coordinator included
        bool[ushort] draining;         // members shutting down: their regions go, none come
        ushort[uint] movingTo;         // region id -> its next owner, while it is being revoked
        MonoTime[uint] heldUntil;      // region id -> when its lost owner's lease has surely run out
        MonoTime grantsFrom;
        Duration lease;
        MonoTime delegate() clock;
        bool changed_ = true;

        // Phase 6: measured costs replace spawn counts once the first report comes.
        bool measured_;
        MonoTime lastBalance;
        MonoTime[uint] movedAt;        // region id -> when it last moved for the load
        MonoTime[uint] splitAt;        // region id -> when it was last split (its halves need a measurement)
        size_t partitionSize;          // regions at start-up: merges never go below it
        uint partitionLastId;          // the start-up partition's highest id: regions above it came of splits
    }

    /// How load balancing by measured cost behaves (phase 6; `ClusterConfig`).
    static struct Balancing
    {
        Duration interval = 30.seconds;
        ulong minLoadUs = 20_000;     /// the busiest node's µs a second below which nothing moves
        Duration cooldown = 120.seconds;
        double tolerance = 0.25;      /// the gap between busiest and idlest that is tolerated, of the mean
        size_t maxMoves = 2;          /// regions moved at most per look
        size_t maxRegions = 1024;     /// splits stop at so many regions
        ulong mergeBelowUs = 1_000;   /// two neighbours that together cost less than this merge
    }

    /// ditto
    Balancing balancing;

    /// Maps never split (dungeons: one node hosts every copy of one, so its region stays whole).
    bool[uint] wholeMaps;

    /**
     * `regions` from `partition`, with what each costs; `incarnation` is the coordinator's (epochs
     * start above anything an earlier coordinator granted).
     */
    this(Region[] regions, ulong[uint] cost, ushort self, ulong incarnation, Duration lease,
        MonoTime delegate() clock)
    {
        regions_ = regions;
        partitionSize = regions.length;
        foreach (ref r; regions)
            if (r.id > partitionLastId)
                partitionLastId = r.id;
        this.cost = cost;
        this.self = self;
        epochBase = incarnation << 20;
        this.lease = lease;
        this.clock = clock;
        grantsFrom = clock() + lease + leaseMargin;
        members[self] = true;
    }

    /**
     * Phase 7: the standby takes over from a coordinator that is gone, with the last table it had.
     * Every grant stands with its epoch, so no member loses a region; a region on its way somewhere
     * still goes there; the old coordinator's regions are held until its lease has surely run out
     * (`lostHeard` is when it was last heard). New epochs start above every epoch in the table. As
     * after any start, nothing new is granted for a lease: a grant the old coordinator made that
     * the table here does not have yet has lapsed by then.
     */
    static RegionAuthority adopt(const(Region)[] table, ulong tableVersion, ulong[uint] cost, ushort self,
        const(ushort)[] members, ushort lostCoordinator, MonoTime lostHeard, Duration lease, MonoTime delegate() clock)
    {
        ulong highest;
        foreach (ref r; table)
            if (r.epoch > highest)
                highest = r.epoch;
        auto a = new RegionAuthority(table.dup, cost, self, 0, lease, clock);
        a.epochBase = highest + 1;
        a.tableVersion = tableVersion; // its tables follow the old coordinator's
        foreach (m; members)
            a.members[m] = true;
        a.members[lostCoordinator] = true;
        foreach (ref r; a.regions_)
            if (r.state == RegionState.revoking && r.next)
                a.movingTo[r.id] = r.next;
        a.lost(lostCoordinator, lostHeard);
        a.touch();
        return a;
    }

    ///
    @property const(Region)[] regions() const
    {
        return regions_;
    }

    /// Increases with every change of the table.
    @property ulong version_() const
    {
        return tableVersion;
    }

    /// Whether the table changed since the last call (it is then published).
    bool takeChanged()
    {
        const was = changed_;
        changed_ = false;
        return was;
    }

    /// Whether costs are measured ones (a report has come) rather than spawn counts.
    @property bool measured() const
    {
        return measured_;
    }

    /**
     * What `node`'s regions cost it lately, µs of loop time a second (phase 6). The first report
     * switches every cost to measured ones: a region nobody has reported costs nothing, which is
     * right, as a node loads only the cells near its players. Each cost follows its reports smoothly
     * (half the old value and half the new), so one busy moment does not move a region.
     */
    void measuredLoads(ushort node, const(uint[uint]) busyUs)
    {
        if (!measured_)
        {
            measured_ = true;
            foreach (ref c; cost)
                c = 0;
            lastBalance = clock();
        }
        foreach (ref r; regions_)
            if (r.owner == node && r.state != RegionState.unowned)
            {
                const now = busyUs.get(r.id, 0);
                cost[r.id] = (cost.get(r.id, 0) + now) / 2;
            }
    }

    /// A member joined: once grants are allowed, regions move to it so that the load evens out.
    void joined(ushort node)
    {
        members[node] = true;
        draining.remove(node);
        if (clock() >= grantsFrom)
            balance();
    }

    /**
     * A member was lost, last heard from at `lastHeard`: its regions are nobody's until its lease
     * has run out, and regions on their way to it stop at the old owner's release.
     */
    void lost(ushort node, MonoTime lastHeard)
    {
        members.remove(node);
        draining.remove(node);
        foreach (ref r; regions_)
        {
            if (r.owner == node && r.state != RegionState.unowned)
            {
                r.state = RegionState.unowned;
                r.owner = 0;
                heldUntil[r.id] = lastHeard + lease + leaseMargin;
                movingTo.remove(r.id);
                touch();
            }
            if (auto target = r.id in movingTo)
                if (*target == node)
                {
                    *target = 0;
                    r.next = 0;
                    touch();
                }
        }
    }

    /**
     * `node` is shutting down cleanly (a drain): each of its regions is revoked for the member that
     * carries least, so its objects are handed over as when the load is balanced, and no region goes
     * to it any more. With no other member, its regions stay until it is lost.
     */
    void drain(ushort node)
    {
        if (node !in members || node == self && members.length == 1)
            return;
        draining[node] = true;
        const others = memberList;
        if (others.length == 0)
            return;
        auto load = loads(regions_, cost, others);
        foreach (ref r; regions_)
        {
            if (auto target = r.id in movingTo)
                if (*target == node)
                {
                    *target = 0; // on its way there: it stops at its owner's release
                    r.next = 0;
                    touch();
                }
            if (r.owner != node || r.state != RegionState.granted)
                continue;
            ushort to = others[0];
            foreach (n; others)
                if (load[n] < load[to])
                    to = n;
            load[to] += cost.get(r.id, 0);
            r.state = RegionState.revoking;
            r.next = to;
            movingTo[r.id] = to;
            touch();
        }
    }

    /// Whether `node` is draining.
    bool isDraining(ushort node) const
    {
        return (node in draining) !is null;
    }

    /// `node` has stopped simulating a region it was asked to give up.
    void released(ushort node, uint region, ulong epoch)
    {
        foreach (ref r; regions_)
            if (r.id == region && r.owner == node && r.epoch == epoch && r.state == RegionState.revoking)
            {
                const target = movingTo.get(r.id, 0);
                movingTo.remove(r.id);
                if (target && target in members)
                    grant(r, target);
                else
                {
                    r.state = RegionState.unowned;
                    r.owner = 0;
                    r.next = 0;
                    touch();
                }
            }
    }

    /// Where a region released by `node` at `epoch` was granted; 0 if nowhere (asked after `released`).
    ushort grantedAfter(uint region)
    {
        foreach (ref r; regions_)
            if (r.id == region && r.state == RegionState.granted)
                return r.owner;
        return 0;
    }

    /// Hands out regions that are free (and no longer held for a lost owner).
    void tick()
    {
        const now = clock();
        if (now < grantsFrom)
            return;
        uint[] expired;
        foreach (id, until; heldUntil)
            if (now >= until)
                expired ~= id;
        foreach (id; expired)
            heldUntil.remove(id);
        bool[uint] held;
        foreach (id, _; heldUntil)
            held[id] = true;
        foreach (id; assign(regions_, cost, memberList, held))
            foreach (ref r; regions_)
                if (r.id == id)
                    grant(r, r.owner);
        if (measured_ && now - lastBalance >= balancing.interval)
        {
            lastBalance = now;
            balanceMeasured(now);
            mergeCold(now);
        }
    }

    /**
     * Phase 6: moves regions from the busiest node to the idlest by measured cost, when the busiest is
     * busy enough to matter and the gap is over the tolerance; at most `maxMoves` a look, and none
     * that moved within the cool-down (no region bounces between two nodes).
     */
    void balanceMeasured(MonoTime now)
    {
        const nodes = memberList;
        if (nodes.length < 2)
            return;
        auto load = loads(regions_, cost, nodes);
        ulong busiest;
        foreach (l; load)
            if (l > busiest)
                busiest = l;
        if (busiest < balancing.minLoadUs)
            return;
        bool[uint] frozen;
        foreach (id, at; movedAt)
            if (now - at < balancing.cooldown)
                frozen[id] = true;
        const moves = rebalance(regions_, cost, nodes, balancing.tolerance, frozen, balancing.maxMoves);
        splitHot(load, now);
        foreach (move; moves)
            foreach (ref r; regions_)
                if (r.id == move.region && r.state == RegionState.granted)
                {
                    import dmangos.log : info;

                    info!"cluster: balancing: region %s (%s µs/s) moves from node %s (%s µs/s) to node %s (%s µs/s)"(
                        r.id, cost.get(r.id, 0), move.from, load[move.from], move.to, load[move.to]);
                    r.state = RegionState.revoking;
                    r.next = move.to;
                    movingTo[r.id] = move.to;
                    movedAt[r.id] = now;
                    touch();
                }
    }

    /**
     * A split: when most of the busiest node's load is one region too costly to move (more than half
     * the gap: moving it would only move the load), that region is cut in two along its longer side
     * (each region at most once a balance interval, so that its halves are measured first). The old id
     * keeps one half, a new id the other, both still granted to the same node, so nothing moves now
     * and no object changes hands: the next reports measure the halves, and the next look can move
     * one (a half still too hot is split again). The half that kept the id is frozen against moves
     * for the cool-down; each half is costed at half the whole until it is measured.
     */
    private void splitHot(const ulong[ushort] load, MonoTime now)
    {
        import dmangos.log : info;

        if (regions_.length >= balancing.maxRegions)
            return;
        ushort busiest, idlest;
        foreach (node, l; load)
        {
            if (busiest == 0 || l > load[busiest])
                busiest = node;
            if (idlest == 0 || l < load[idlest])
                idlest = node;
        }
        ulong total;
        foreach (l; load)
            total += l;
        const gap = load[busiest] - load[idlest];
        if (gap <= balancing.tolerance * total / load.length)
            return;
        Region* hottest;
        foreach (ref r; regions_)
            if (r.owner == busiest && r.state == RegionState.granted && r.map !in wholeMaps
                && (r.id !in splitAt || now - splitAt[r.id] >= balancing.interval) // measured since
                && (hottest is null || cost.get(r.id, 0) > cost.get(hottest.id, 0)))
                hottest = &r;
        // Only a region too costly to move (over half the gap) that is most of its node's load.
        if (hottest is null || 2 * cost.get(hottest.id, 0) <= gap || 2 * cost.get(hottest.id, 0) <= load[busiest])
            return;
        CellRect a, b;
        if (!halve(hottest.rect, a, b))
            return;
        uint next;
        foreach (ref r; regions_)
            if (r.id > next)
                next = r.id;
        ++next;
        const whole = cost.get(hottest.id, 0), id = hottest.id, map = hottest.map;
        info!"cluster: balancing: region %s (%s µs/s, cells %s..%s × %s..%s) of node %s split, its half %s new"(id,
            whole, hottest.rect.x0, hottest.rect.x1, hottest.rect.y0, hottest.rect.y1, busiest, next);
        hottest.rect = a; // same id, owner and epoch: its node keeps simulating it
        cost[id] = whole / 2;
        movedAt[id] = now; // not moved on an estimate
        splitAt[id] = now;
        Region other = Region(next, map, b);
        cost[next] = whole - whole / 2;
        splitAt[next] = now;
        regions_ ~= other;
        grant(regions_[$ - 1], busiest);
        touch();
    }

    /**
     * A merge: two granted regions of one node on one map, side by side along a whole edge (their
     * union a rectangle), cheap together (under `mergeBelowUs`) and neither moved, split or merged
     * lately, become one. The lower id takes the union with its owner and epoch, so its node goes
     * on simulating everything without a handover; the other id leaves the table. One merge a look,
     * and only where one of the two came of a split: merges take back what splits added, never
     * the start-up partition.
     */
    private void mergeCold(MonoTime now)
    {
        import dmangos.log : info;

        if (regions_.length <= partitionSize)
            return; // splits are undone; the start-up partition stays

        bool recent(uint id)
        {
            return (id in movedAt && now - movedAt[id] < balancing.cooldown)
                || (id in splitAt && now - splitAt[id] < balancing.cooldown);
        }

        foreach (i, ref a; regions_)
        {
            if (a.state != RegionState.granted || recent(a.id))
                continue;
            foreach (j, ref b; regions_)
            {
                if (j == i || b.state != RegionState.granted || b.owner != a.owner || b.map != a.map || recent(b.id))
                    continue;
                if (cost.get(a.id, 0) + cost.get(b.id, 0) >= balancing.mergeBelowUs)
                    continue;
                if (a.id <= partitionLastId && b.id <= partitionLastId)
                    continue; // two regions of the start-up partition: not what a merge is for
                CellRect union_;
                if (!unionOf(a.rect, b.rect, union_))
                    continue;
                auto keep = a.id < b.id ? &a : &b;
                const drop = a.id < b.id ? b.id : a.id;
                info!"cluster: balancing: regions %s and %s of node %s (%s µs/s together) merged into %s"(a.id, b.id,
                    a.owner, cost.get(a.id, 0) + cost.get(b.id, 0), keep.id);
                keep.rect = union_;
                cost[keep.id] = cost.get(a.id, 0) + cost.get(b.id, 0);
                splitAt[keep.id] = now; // not split again at once
                cost.remove(drop);
                movedAt.remove(drop);
                splitAt.remove(drop);
                import std.algorithm.mutation : remove;

                regions_ = regions_.remove(regions_[i].id == drop ? i : j);
                touch();
                return;
            }
        }
    }

    /// What each member's regions cost, for the log.
    ulong[ushort] memberLoads() const
    {
        return loads(regions_, cost, memberList);
    }

private:
    ushort[] memberList() const
    {
        import std.algorithm.sorting : sort;

        ushort[] list;
        foreach (node, _; members)
            if (node !in draining)
                list ~= node;
        list.sort();
        return list;
    }

    void balance()
    {
        foreach (move; rebalance(regions_, cost, memberList))
            foreach (ref r; regions_)
                if (r.id == move.region && r.state == RegionState.granted)
                {
                    r.state = RegionState.revoking;
                    r.next = move.to;
                    movingTo[r.id] = move.to;
                    touch();
                }
    }

    void grant(ref Region r, ushort owner)
    {
        r.owner = owner;
        r.next = 0;
        r.state = RegionState.granted;
        r.epoch = epochBase + ++epochCount;
        touch();
    }

    void touch()
    {
        ++tableVersion;
        changed_ = true;
    }
}

/// What this node owns, as the latest region table and its lease say.
final class RegionView
{
    private
    {
        immutable ushort self;
        bool authority;              // the coordinator: its own grants need no lease
        Duration lease;
        ulong tableCoordinator;
        ulong tableVersion;
        Region[] table;
        MonoTime confirmed;
        Region[uint] owned;           // regions this node treats as its own, as they were granted
        ulong[uint] releaseSent;      // region id -> epoch whose release went out
    }

    ///
    this(ushort self, bool authority, Duration lease)
    {
        this.self = self;
        this.authority = authority;
        this.lease = lease;
    }

    /// This node became the coordinator (phase 7): its own grants need no lease from now on.
    void promote()
    {
        authority = true;
    }

    /// The latest table's version.
    @property ulong latestVersion() const
    {
        return tableVersion;
    }

    /// The latest table, as received.
    @property const(Region)[] latestTable() const
    {
        return table;
    }

    /// The coordinator incarnation the table comes from; 0 before the first.
    @property ulong coordinator() const pure nothrow @nogc @safe
    {
        return tableCoordinator;
    }

    /// The latest table.
    @property const(Region)[] regions() const pure nothrow @nogc @safe
    {
        return table;
    }

    /// A table from coordinator incarnation `coordinator`; kept if it is newer. A new coordinator's replaces any.
    bool take(ulong coordinator, ulong version_, Region[] regions)
    {
        if (coordinator == tableCoordinator && version_ <= tableVersion)
            return false;
        if (coordinator != tableCoordinator)
            confirmed = MonoTime.init; // a lease from another coordinator counts for nothing
        tableCoordinator = coordinator;
        tableVersion = version_;
        table = regions;
        return true;
    }

    /// The table's coordinator echoed a heartbeat this node sent at `sentAt`: the lease runs from there.
    void confirm(MonoTime sentAt)
    {
        confirmed = max(confirmed, sentAt);
    }

    /// Whether this node's lease holds at `now`.
    bool leaseHolds(MonoTime now) const
    {
        return authority || (confirmed != MonoTime.init && now < confirmed + lease);
    }

    /**
     * What this node owns now: the regions granted to it while the lease holds. Returns those
     * gained and lost since the last call; the caller starts and stops simulating them, then sends
     * the releases `releases` lists.
     */
    void refresh(MonoTime now, out Region[] gained, out Region[] lost)
    {
        const holds = leaseHolds(now);
        bool[uint] nowOwned;
        foreach (ref r; table)
            if (holds && r.owner == self && r.state == RegionState.granted)
            {
                nowOwned[r.id] = true;
                if (auto had = r.id in owned)
                {
                    if (had.epoch != r.epoch) // granted anew meanwhile: lost and gained again
                    {
                        lost ~= *had;
                        gained ~= r;
                        *had = r;
                    }
                    else
                        had.rect = r.rect; // split: the same grant, a smaller rectangle (the rest a new region)
                }
                else
                    gained ~= r;
            }
        uint[] gone;
        foreach (id, r; owned)
            if (id !in nowOwned)
            {
                // Merged into another region this node still owns (the id gone from the table, its
                // cells inside the other's rectangle): nothing is lost.
                bool merged = holds;
                foreach (ref t; table)
                    if (t.id == id)
                        merged = false;
                if (merged)
                {
                    bool covered;
                    foreach (ref t; table)
                        if (t.id in nowOwned && t.map == r.map && contains(t.rect, r.rect))
                            covered = true;
                    if (covered)
                    {
                        gone ~= id;
                        continue;
                    }
                }
                auto current = r;
                foreach (ref t; table)    // as the table has it now: revoking says where it goes
                    if (t.id == id && t.epoch == r.epoch)
                        current = t;
                lost ~= current;
                gone ~= id;
            }
        foreach (id; gone)
            owned.remove(id);
        foreach (r; gained)
            owned[r.id] = r;
    }

    /// Regions the coordinator is waiting for this node to release (not yet answered).
    Region[] releases()
    {
        Region[] due;
        foreach (ref r; table)
            if (r.owner == self && r.state == RegionState.revoking && r.id !in owned
                && releaseSent.get(r.id, 0) != r.epoch)
                due ~= r;
        return due;
    }

    /// The release of `r` was sent (or handed to the coordinator's own authority).
    void releaseDone(const ref Region r)
    {
        releaseSent[r.id] = r.epoch;
    }

    /// Whether this node owns the cell with key `cell` of `map` (as of the last `refresh`).
    bool ownsCell(uint map, ulong cell) const
    {
        foreach (ref r; owned)
            if (r.map == map && r.rect.containsKey(cell))
                return true;
        return false;
    }

    /// The node a cell of a map is granted to, as the latest table says; 0 if none.
    ushort ownerAt(uint map, ulong cell) const
    {
        foreach (ref r; table)
            if (r.map == map && r.state == RegionState.granted && r.rect.containsKey(cell))
                return r.owner;
        return 0;
    }

    /// The regions this node owns, as of the last `refresh`.
    @property const(Region)[] ownedRegions() const
    {
        return owned.values;
    }
}

/// What ids are for.
enum IdKind : ubyte
{
    character = 0,
    item = 1,
    mail = 2,
    group = 3,
    instance = 4, /// dungeon copies: each is made by its dungeon's node, so the ids must not collide
    pet = 5,      /// pet numbers (`character_pet.id`)
}

/// The coordinator's id counters, which the world server keeps (`GuidCounters`).
interface IdCounters
{
    /// Takes `count` ids of `kind`; returns the first.
    uint take(IdKind kind, uint count);

    /// No id of `kind` below `atLeast` may be handed out again.
    void raise(IdKind kind, uint atLeast);
}

/// A member's blocks of ids: the one in use, and the next, asked for before the first runs out.
final class IdPool
{
    private static struct Block
    {
        uint next, end;

        @property uint left() const pure nothrow @nogc @safe
        {
            return end - next;
        }
    }

    private
    {
        Block[IdKind.max + 1] current, spare;
        bool[IdKind.max + 1] asked;
        uint highest_;
    }

    /// The size of a block.
    immutable uint blockSize;

    ///
    this(uint blockSize)
    in (blockSize > 0)
    {
        this.blockSize = blockSize;
    }

    /// The next id of `kind`; false if none is left (the blocks have not come).
    bool take(IdKind kind, out uint id)
    {
        if (current[kind].left == 0)
        {
            current[kind] = spare[kind];
            spare[kind] = Block.init;
        }
        if (current[kind].left == 0)
            return false;
        id = current[kind].next++;
        return true;
    }

    /// The kinds to ask a block of now: a spare is missing and none was asked for.
    IdKind[] wanted()
    {
        IdKind[] kinds;
        foreach (k; IdKind.min .. IdKind.max + 1)
        {
            const kind = cast(IdKind) k;
            if (spare[kind].left == 0 && !asked[kind] && current[kind].left < blockSize / 2 + 1)
            {
                asked[kind] = true;
                kinds ~= kind;
            }
        }
        return kinds;
    }

    /// A block arrived.
    void granted(IdKind kind, uint first, uint count)
    {
        asked[kind] = false;
        if (current[kind].left == 0)
            current[kind] = Block(first, first + count);
        else
            spare[kind] = Block(first, first + count);
        highest_ = max(highest_, first + count);
    }

    /// The link to the coordinator broke: what was asked may never be answered, so ask again.
    void reset()
    {
        asked[] = false;
    }

    /// The end of the highest block of `kind` this node holds, for a new coordinator not to hand it out again.
    uint highest(IdKind kind) const
    {
        return max(current[kind].end, spare[kind].end);
    }
}

unittest
{
    import core.time : seconds;

    auto now = MonoTime.currTime;
    Region[] regions = [Region(1, 0, CellRect(0, 0, 10, 10)), Region(2, 0, CellRect(10, 0, 20, 10)),
        Region(3, 1, CellRect.init)];
    ulong[uint] cost = [1: 100, 2: 100, 3: 10];
    auto authority = new RegionAuthority(regions, cost, 1, 7, 5.seconds, () => now);

    // Nothing is granted during the first lease: an earlier coordinator's grants may still hold.
    authority.tick();
    foreach (r; authority.regions)
        assert(r.state == RegionState.unowned);
    now += 6.seconds;
    authority.tick();
    foreach (r; authority.regions)
        assert(r.owner == 1 && r.state == RegionState.granted && r.epoch > 7UL << 20);
    assert(authority.takeChanged() && !authority.takeChanged());

    // Node 2 joins: a region is revoked from node 1, and granted to 2 only when node 1 releases it.
    authority.joined(2);
    const(Region)* moving;
    foreach (ref r; authority.regions)
        if (r.state == RegionState.revoking)
            moving = &r;
    assert(moving !is null && moving.owner == 1);
    const oldEpoch = moving.epoch;
    authority.tick();
    assert(moving.state == RegionState.revoking, "never granted before it is released");
    authority.released(1, moving.id, oldEpoch - 1);
    assert(moving.state == RegionState.revoking, "a release of another epoch counts for nothing");
    authority.released(1, moving.id, oldEpoch);
    assert(moving.owner == 2 && moving.state == RegionState.granted && moving.epoch > oldEpoch);

    // Node 2 is lost: its region waits out the lease before node 1 gets it back.
    const lastHeard = now;
    authority.lost(2, lastHeard);
    assert(moving.state == RegionState.unowned);
    now += 3.seconds;
    authority.tick();
    assert(moving.state == RegionState.unowned, "node 2 may still think it owns it");
    now += 3.seconds;
    authority.tick();
    assert(moving.owner == 1 && moving.state == RegionState.granted);
    const loads = authority.memberLoads();
    assert(loads[1] == 210);
}

unittest
{
    import core.time : seconds;

    auto view = new RegionView(2, false, 5.seconds);
    auto now = MonoTime.currTime;
    Region[] table = [Region(1, 0, CellRect(0, 0, 10, 10), 2, 100, RegionState.granted),
        Region(2, 0, CellRect(10, 0, 20, 10), 3, 101, RegionState.granted)];
    assert(view.take(9, 1, table.dup));

    // No lease yet: nothing is owned.
    Region[] gained, lost;
    view.refresh(now, gained, lost);
    assert(gained.length == 0 && !view.ownsCell(0, 0));

    view.confirm(now);
    view.refresh(now + 1.seconds, gained, lost);
    assert(gained.length == 1 && gained[0].id == 1 && view.ownsCell(0, 5UL << 32 | 5) && !view.ownsCell(0, 15UL << 32));

    // The lease runs out without confirmations: everything is lost.
    view.refresh(now + 6.seconds, gained, lost);
    assert(lost.length == 1 && gained.length == 0 && !view.ownsCell(0, 0));

    // Confirmed again, then the region is revoked: it is lost and its release is due once.
    view.confirm(now + 6.seconds);
    view.refresh(now + 6.seconds, gained, lost);
    assert(gained.length == 1);
    table[0].state = RegionState.revoking;
    assert(view.take(9, 2, table.dup) && !view.take(9, 2, table.dup), "an old version is ignored");
    view.refresh(now + 7.seconds, gained, lost);
    assert(lost.length == 1);
    auto due = view.releases();
    assert(due.length == 1 && due[0].epoch == 100);
    view.releaseDone(due[0]);
    assert(view.releases().length == 0);

    // A new coordinator's table replaces the old one, and its lease starts afresh.
    table[0].state = RegionState.granted;
    assert(view.take(10, 1, table.dup));
    view.refresh(now + 7.seconds, gained, lost);
    assert(gained.length == 0, "not confirmed by the new coordinator yet");
}

unittest
{
    auto pool = new IdPool(10);
    uint id;
    assert(!pool.take(IdKind.item, id));
    assert(pool.wanted() == [IdKind.character, IdKind.item, IdKind.mail, IdKind.group, IdKind.instance, IdKind.pet]);
    assert(pool.wanted().length == 0, "asked once");
    pool.granted(IdKind.item, 100, 10);
    assert(pool.take(IdKind.item, id) && id == 100);
    foreach (_; 0 .. 5)
        pool.take(IdKind.item, id);
    assert(pool.wanted() == [IdKind.item], "half used: the next block is asked for");
    pool.granted(IdKind.item, 500, 10);
    foreach (_; 0 .. 4)
        pool.take(IdKind.item, id);
    assert(id == 109 && pool.take(IdKind.item, id) && id == 500, "on to the spare block");
    assert(pool.highest(IdKind.item) == 510);
}

/// A clean shutdown (a drain): the node's regions go to the others, the least loaded first, and none come back.
unittest
{
    import core.time : seconds;

    auto now = MonoTime.currTime;
    Region[] regions = [Region(1, 0, CellRect(0, 0, 10, 10)), Region(2, 0, CellRect(10, 0, 20, 10)),
        Region(3, 0, CellRect(20, 0, 30, 10)), Region(4, 1, CellRect.init)];
    ulong[uint] cost = [1: 100, 2: 100, 3: 100, 4: 100];
    auto authority = new RegionAuthority(regions, cost, 1, 7, 5.seconds, () => now);
    now += 6.seconds;
    authority.tick();
    authority.joined(2);
    authority.joined(3);
    // Let the balancing settle: every revoked region released to where it was going.
    foreach (_; 0 .. 3)
        foreach (ref r; authority.regions)
            if (r.state == RegionState.revoking)
                authority.released(r.owner, r.id, r.epoch);
    uint[] ofNode3;
    foreach (ref r; authority.regions)
        if (r.owner == 3)
            ofNode3 ~= r.id;
    assert(ofNode3.length, "node 3 carries something");

    // Node 3 drains: each of its regions is revoked toward 1 or 2, and granted there on release.
    authority.drain(3);
    assert(authority.isDraining(3));
    foreach (ref r; authority.regions)
        if (r.owner == 3)
        {
            assert(r.state == RegionState.revoking && (r.next == 1 || r.next == 2));
            authority.released(3, r.id, r.epoch);
            assert(r.state == RegionState.granted && r.owner != 3);
        }

    // Nothing goes to it any more, even when regions are handed out again.
    authority.tick();
    foreach (ref r; authority.regions)
        assert(r.owner != 3 && r.next != 3);

    // The only member cannot drain: there is nowhere to go.
    auto alone = new RegionAuthority(regions.dup, cost, 1, 7, 5.seconds, () => now);
    alone.drain(1);
    assert(!alone.isDraining(1));
}

/// Phase 6: balancing by measured cost, with a threshold, a cap on moves and a cool-down.
unittest
{
    auto now = MonoTime.currTime;
    Region[] regions;
    ulong[uint] cost;
    foreach (uint id; 1 .. 7)
    {
        regions ~= Region(id, 0, CellRect(cast(int) id * 10, 0, cast(int) id * 10 + 10, 10));
        cost[id] = 100;
    }
    auto authority = new RegionAuthority(regions, cost, 1, 7, 5.seconds, () => now);
    authority.balancing.interval = 30.seconds;
    authority.balancing.minLoadUs = 20_000;
    authority.balancing.cooldown = 120.seconds;
    now += 6.seconds;
    authority.tick();
    authority.joined(2);
    foreach (ref r; authority.regions)
        if (r.state == RegionState.revoking)
            authority.released(r.owner, r.id, r.epoch);
    uint[] of(ushort node)
    {
        uint[] ids;
        foreach (ref r; authority.regions)
            if (r.owner == node && r.state == RegionState.granted)
                ids ~= r.id;
        return ids;
    }
    assert(of(1).length == 3 && of(2).length == 3, "even by spawn counts");

    // Measured: node 1's regions are busy, node 2's idle; but all of it is under the threshold: nothing moves.
    uint[uint] busy1, busy2;
    foreach (id; of(1))
        busy1[id] = 5_000;
    foreach (id; of(2))
        busy2[id] = 0;
    authority.measuredLoads(1, busy1);
    authority.measuredLoads(2, busy2);
    assert(authority.measured);
    now += 31.seconds;
    authority.tick();
    foreach (ref r; authority.regions)
        assert(r.state != RegionState.revoking, "under the threshold: nothing moves");

    // Busy enough: at most two regions move to node 2 in one look.
    foreach (id; of(1))
        busy1[id] = 40_000;
    foreach (_; 0 .. 4)
        authority.measuredLoads(1, busy1); // smoothed: it takes a few reports to get there
    now += 31.seconds;
    authority.tick();
    uint[] moving;
    foreach (ref r; authority.regions)
        if (r.state == RegionState.revoking)
        {
            assert(r.owner == 1 && r.next == 2);
            moving ~= r.id;
        }
    assert(moving.length >= 1 && moving.length <= 2);
    foreach (ref r; authority.regions)
        if (r.state == RegionState.revoking)
            authority.released(1, r.id, r.epoch);

    // Now node 2 is the busy one, but what just moved stays there for the cool-down.
    uint[uint] busy2b;
    foreach (id; of(2))
        busy2b[id] = 60_000;
    foreach (_; 0 .. 4)
        authority.measuredLoads(2, busy2b);
    now += 31.seconds;
    authority.tick();
    foreach (ref r; authority.regions)
        if (r.state == RegionState.revoking)
        {
            import std.algorithm.searching : canFind;

            assert(!moving.canFind(r.id), "a region that just moved does not move back within the cool-down");
        }
}

/**
 * Phase 6's splits: one region holding all of a node's load cannot move (it would only move the
 * load), so it is cut in two on the same node; measured apart, one half then moves.
 */
unittest
{
    auto now = MonoTime.currTime;
    Region[] regions = [Region(1, 0, CellRect(0, 0, 64, 16)), Region(2, 0, CellRect(64, 0, 128, 16))];
    ulong[uint] cost = [1: 100, 2: 100];
    auto authority = new RegionAuthority(regions, cost, 1, 7, 5.seconds, () => now);
    now += 6.seconds;
    authority.tick();
    authority.joined(2);
    foreach (ref r; authority.regions)
        if (r.state == RegionState.revoking)
            authority.released(r.owner, r.id, r.epoch);
    ushort ownerOf(uint id)
    {
        foreach (ref r; authority.regions)
            if (r.id == id)
                return r.owner;
        return 0;
    }
    const hot = authority.regions[0].owner == 1 ? 1u : 2u;
    const hotNode = ownerOf(hot), coldNode = hotNode == 1 ? 2 : 1;
    const cold = hot == 1 ? 2u : 1u;
    assert(hotNode != ownerOf(cold), "one region each");

    // A crowd in one region: 80 ms/s there, nothing elsewhere. Moving it would only move the load.
    foreach (_; 0 .. 6)
    {
        authority.measuredLoads(hotNode, [hot: 80_000]);
        authority.measuredLoads(cast(ushort) coldNode, [cold: 0]);
    }
    const epoch = authority.regions[hot - 1].epoch;
    now += 31.seconds;
    authority.tick();
    assert(authority.regions.length == 3, "split");
    const halfA = authority.regions[hot - 1], halfB = authority.regions[2];
    assert(halfA.id == hot && halfA.owner == hotNode && halfA.epoch == epoch && halfA.state == RegionState.granted,
        "the old id keeps its grant: nothing moves");
    assert(halfB.id == 3 && halfB.owner == hotNode && halfB.state == RegionState.granted);
    assert(halfA.rect.x1 - halfA.rect.x0 == 32 && halfB.rect.x0 == halfA.rect.x1, "halved along the longer side");

    // Measured apart (the new half lighter): the new half moves to the idle node; the old one is frozen anyway.
    // (A half still more than half the gap would be split again instead.)
    foreach (_; 0 .. 6)
        authority.measuredLoads(hotNode, [hot: 50_000, 3: 30_000]);
    now += 31.seconds;
    authority.tick();
    bool moved;
    foreach (ref r; authority.regions)
        if (r.state == RegionState.revoking)
        {
            assert(r.id == 3 && r.next == coldNode);
            moved = true;
        }
    assert(moved, "the new half moves");

    // A node's view: the same grant with a smaller rectangle is no loss, and its owned rectangle follows.
    auto view = new RegionView(hotNode, true, 5.seconds);
    view.take(7, 1, [Region(hot, 0, CellRect(0, 0, 64, 16), hotNode, epoch, RegionState.granted)]);
    Region[] gained, lost;
    view.refresh(now, gained, lost);
    assert(gained.length == 1);
    view.take(7, 2, [halfA, Region(3, 0, halfB.rect, hotNode, halfB.epoch, RegionState.granted)]);
    view.refresh(now, gained, lost);
    assert(lost.length == 0 && gained.length == 1 && gained[0].id == 3);
    foreach (ref r; view.ownedRegions)
        if (r.id == hot)
            assert(r.rect == halfA.rect);
}

/// Merges: two cold neighbours of one node become one, with no handover; the node's view loses nothing.
unittest
{
    auto now = MonoTime.currTime;
    Region[] regions = [Region(1, 0, CellRect(0, 0, 32, 16)), Region(2, 0, CellRect(32, 0, 64, 16)),
        Region(3, 0, CellRect(64, 0, 128, 16))];
    ulong[uint] cost = [1: 100, 2: 100, 3: 100];
    auto authority = new RegionAuthority(regions, cost, 1, 7, 5.seconds, () => now);
    authority.partitionSize = 2; // as if region 2 came from a split
    authority.partitionLastId = 1;
    now += 6.seconds;
    authority.tick();
    foreach (ref r; authority.regions)
        assert(r.owner == 1 && r.state == RegionState.granted);
    const epoch1 = authority.regions[0].epoch;
    authority.measuredLoads(1, [1: 100, 2: 100, 3: 5_000]); // 3 is busy; 1 and 2 cheap
    now += 31.seconds;
    authority.tick();
    assert(authority.regions.length == 2, "one merge a look");
    const merged = authority.regions[0];
    assert(merged.id == 1 && merged.rect == CellRect(0, 0, 64, 16) && merged.epoch == epoch1 && merged.owner == 1,
        "the lower id takes both, with its grant");

    // The node's view: region 2's going is no loss, and region 1's rectangle grows.
    auto view = new RegionView(1, true, 5.seconds);
    view.take(7, 1, [Region(1, 0, CellRect(0, 0, 32, 16), 1, epoch1, RegionState.granted),
        Region(2, 0, CellRect(32, 0, 64, 16), 1, 9, RegionState.granted)]);
    Region[] gained, lost;
    view.refresh(now, gained, lost);
    assert(gained.length == 2);
    view.take(7, 2, [merged]);
    view.refresh(now, gained, lost);
    assert(gained.length == 0 && lost.length == 0, "merged: nothing changes hands");
    assert(view.ownedRegions.length == 1 && view.ownedRegions[0].rect == CellRect(0, 0, 64, 16));
}
