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

import core.time : Duration, MonoTime, msecs;
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
        immutable ulong epochBase;
        uint epochCount;
        ulong tableVersion = 1;
        bool[ushort] members;          // live members, the coordinator included
        ushort[uint] movingTo;         // region id -> its next owner, while it is being revoked
        MonoTime[uint] heldUntil;      // region id -> when its lost owner's lease has surely run out
        MonoTime grantsFrom;
        Duration lease;
        MonoTime delegate() clock;
        bool changed_ = true;
    }

    /**
     * `regions` from `partition`, with what each costs; `incarnation` is the coordinator's (epochs
     * start above anything an earlier coordinator granted).
     */
    this(Region[] regions, ulong[uint] cost, ushort self, ulong incarnation, Duration lease,
        MonoTime delegate() clock)
    {
        regions_ = regions;
        this.cost = cost;
        this.self = self;
        epochBase = incarnation << 20;
        this.lease = lease;
        this.clock = clock;
        grantsFrom = clock() + lease + leaseMargin;
        members[self] = true;
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

    /// A member joined: once grants are allowed, regions move to it so that the load evens out.
    void joined(ushort node)
    {
        members[node] = true;
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
        immutable bool authority;    // the coordinator: its own grants need no lease
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
                }
                else
                    gained ~= r;
            }
        uint[] gone;
        foreach (id, r; owned)
            if (id !in nowOwned)
            {
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
    assert(pool.wanted() == [IdKind.character, IdKind.item, IdKind.mail, IdKind.group]);
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
