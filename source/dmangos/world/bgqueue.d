/**
 * The battleground queues and the queue opcodes' answers, as a cluster service (docs/SERVICES.md).
 *
 * Players of any node queue for a battleground of a type (Alterac Valley, Warsong Gulch, Arathi
 * Basin) in the bracket of their level. Waiting players are kept as groups (a player alone is a group
 * of one), in the order they joined, per type, bracket and team. When a running copy of the
 * battleground has room, the first groups that fit are invited to it; when enough of both teams wait
 * (`battleground_template.MinPlayersPerTeam`), a new copy is made for them. An invitation lasts 80 s, with a reminder at
 * 60 s; accepting it (`CMSG_BATTLEFIELD_PORT`) gives the player's node what it needs to send the player
 * in. The copies themselves run on the node hosting their map (`dmangos.world.battleground`), which
 * tells the queue who leaves and how the copy is doing.
 *
 * Invitations fill greedily (the first groups that fit), and premade groups get no matching of
 * their own (none waits for an opposing premade).
 *
 * A player may wait in up to three queues (`queueSlots`), each a slot the client
 * shows; the queue keeps them, and what it tells a player (`SMSG_BATTLEFIELD_STATUS`,
 * `SMSG_BATTLEFIELD_LIST`) goes to the player's node. On a planned move the queue state follows
 * the service, including its running copies and pending invitations.
 */
module dmangos.world.bgqueue;

import core.time : Duration, MonoTime, hnsecs, msecs, seconds;

import dmangos.bytes : ByteWriter;
import dmangos.cluster.services : Call, Service, ServiceKind;
import dmangos.world.opcodes : Opcode;
import dmangos.world.servicecheckpoint : RealmServiceCheckpoint;

/// A battleground type: the index of `BattlemasterList.dbc` and of `battleground_template`.
enum BattlegroundType : ubyte
{
    none = 0,
    alteracValley = 1,
    warsongGulch = 2,
    arathiBasin = 3,
}

/// Each type's map.
immutable uint[4] battlegroundMaps = [0, 30, 489, 529];

/// The battleground on map `map`; `none` if it is none.
BattlegroundType battlegroundOfMap(uint map) pure nothrow @nogc @safe
{
    foreach (i, m; battlegroundMaps)
        if (m == map && i)
            return cast(BattlegroundType) i;
    return BattlegroundType.none;
}

/// A row of `battleground_template`.
struct BattlegroundTemplate
{
    ubyte id;
    uint minPerTeam;
    uint maxPerTeam;
    ubyte minLevel;
    ubyte maxLevel;
    uint[2] startLocations;    /// `world_safe_locs` ids: the Alliance's, the Horde's
    float startMaxDistance = 0;
    uint skinLoot;             /// `PlayerSkinReflootId`
}

/// Where a player (or a copy) stands, as `SMSG_BATTLEFIELD_STATUS` says it.
enum BattlegroundStatus : ubyte
{
    none = 0,
    waitQueue = 1,  /// waiting in a queue
    waitJoin = 2,   /// invited, or (a copy) made and not started
    inProgress = 3,
    waitLeave = 4,  /// (a copy) over: its players leave
}

/// Level brackets of a battleground (ten levels each), and queues a player may wait in at once.
enum uint bracketCount = 6, queueSlots = 3;

/// How long an invitation lasts, and when the invited are reminded.
enum Duration inviteTime = 80.seconds, remindAfter = 60.seconds;

/// Invited players whose waits make the average wait.
enum uint waitSamples = 10;

/// The bracket of `level`: ten levels each from the minimum, the last holding the rest.
ubyte bracketOf(const ref BattlegroundTemplate t, uint level) pure nothrow @nogc @safe
{
    if (level < t.minLevel)
        return 0;
    const b = (level - t.minLevel) / 10;
    return cast(ubyte)(b >= bracketCount ? bracketCount - 1 : b);
}

/// Whether a player of `level` may queue for it (asked at the battlemaster).
bool levelAllowed(const ref BattlegroundTemplate t, uint level) pure nothrow @nogc @safe
{
    return level >= t.minLevel && level <= t.maxLevel;
}

/**
 * The `SMSG_BATTLEFIELD_STATUS` body: queue slot `slot`'s state. `time1` and `time2`:
 * waiting, the average wait and the time waited; invited, the time left to accept; in a copy, the time
 * left before it sends everyone out (0 while running) and the time since it was made.
 */
const(ubyte)[] battlefieldStatus(uint slot, BattlegroundType type, uint clientInstance, BattlegroundStatus status,
    uint time1 = 0, uint time2 = 0)
{
    ByteWriter w;
    w.put(slot);
    if (status == BattlegroundStatus.none || type == BattlegroundType.none)
    {
        w.put(uint(0));
        return w.data;
    }
    w.put(battlegroundMaps[type]);
    w.put(ubyte(0));
    w.put(clientInstance);
    w.put(cast(uint) status);
    final switch (status)
    {
    case BattlegroundStatus.waitQueue:
        w.put(time1);
        w.put(time2);
        break;
    case BattlegroundStatus.waitJoin:
        w.put(time1);
        break;
    case BattlegroundStatus.inProgress:
        w.put(time1);
        w.put(time2);
        break;
    case BattlegroundStatus.none, BattlegroundStatus.waitLeave:
        break;
    }
    return w.data;
}

/// See the module documentation.
final class BattlegroundQueue
{
    /// Sends a packet to a player, on the node it was last heard from (if not found nearer).
    void delegate(ulong guid, ushort node, Opcode opcode, const(ubyte)[] body_) deliver;
    /// Looks up the player's current node, including any move since its last queue command.
    ushort delegate(ulong guid) currentNode;
    /// A new copy's instance id (the cluster's); false if none can be had now.
    bool delegate(out uint id) newInstanceId;
    MonoTime delegate() clock;
    /// `battleground_template`, by type.
    BattlegroundTemplate[ubyte] templates;
    /// Testing (`.debug bg`): one player of either team makes a copy.
    bool testing;

    /// Where a player is with one of its queue slots.
    enum Stage : ubyte { queued, invited, inside }

    /// A queue slot: a type queued for, and how far it got.
    struct Ticket
    {
        BattlegroundType type;
        Stage stage;
        uint instance;   /// invited to or inside
        Waiting group;   /// while waiting or invited
        ubyte team;      /// inside, for retries of the accepted invitation
    }

    /// Players who queued together.
    static final class Waiting
    {
        ulong[] players;
        ubyte team;           /// 0 the Alliance, 1 the Horde
        BattlegroundType type;
        ubyte bracket;
        uint desired;         /// the client instance id asked for; 0 any
        MonoTime joined;
        uint invitedTo;       /// 0: not invited
        MonoTime inviteEnds;
        bool reminded;
    }

    /// A copy of a battleground, as the queue knows it.
    struct Running
    {
        uint instance;
        BattlegroundType type;
        ubyte bracket;
        uint clientId;          /// the number players see
        uint[2] invited;        /// invited and inside, by team
        BattlegroundStatus status;
        MonoTime made;
        ulong mapEpoch;         /// the map grant which reported the live copy
    }

    private
    {
        Ticket[queueSlots][ulong] tickets;
        ushort[ulong] nodes;
        MonoTime[ulong] lostNodes; // keyed by realm ID and node ID
        Waiting[][2][bracketCount][4] waiting; // [type][bracket][team]
        Running[uint] running;
        uint[waitSamples][bracketCount][2][4] waitTimes; // [type][team][bracket]
        uint[bracketCount][2][4] waitNext;
        RealmServiceCheckpoint durable;
    }

    // Group references in tickets become one-based indexes into the ordered group list.
    private static struct SavedGroup
    {
        ulong[] players;
        ubyte team;
        BattlegroundType type;
        ubyte bracket;
        uint desired;
        long joined;
        uint invitedTo;
        long inviteEnds;
        bool reminded;
    }

    private static struct SavedTicket
    {
        BattlegroundType type;
        Stage stage;
        uint instance;
        uint group;
        ubyte team;
    }

    private static struct SavedPlayer
    {
        ulong guid;
        ushort node;
        SavedTicket[queueSlots] slots;
    }

    private static struct SavedCopy
    {
        uint instance;
        BattlegroundType type;
        ubyte bracket;
        uint clientId;
        uint[2] invited;
        BattlegroundStatus status;
        long made;
    }

    private static struct SavedQueue
    {
        SavedGroup[] groups;
        SavedPlayer[] players;
        SavedCopy[] copies;
        SavedLostNode[] lost;
        typeof(waitTimes) waitTimes_;
        typeof(waitNext) waitNext_;
        bool testing;
    }

    private static struct SavedLostNode
    {
        ulong key;
        long deadline;
    }

    private static struct SavedMapEpoch
    {
        uint instance;
        ulong epoch;
    }

    /// Capture the queue for a handoff. Times are offsets in 100 ns units from this node's clock.
    private ubyte[] saveState() const
    {
        import dmangos.plaindata : encode;

        const now = clock();
        SavedQueue state;
        uint[const(Waiting)] groupIds;
        foreach (ref byBracket; waiting)
            foreach (ref byTeam; byBracket)
                foreach (list; byTeam)
                    foreach (g; list)
                    {
                        state.groups ~= SavedGroup(g.players.dup, g.team, g.type, g.bracket, g.desired,
                            (g.joined - now).total!"hnsecs", g.invitedTo,
                            g.invitedTo ? (g.inviteEnds - now).total!"hnsecs" : 0, g.reminded);
                        groupIds[g] = cast(uint) state.groups.length;
                    }
        foreach (guid, ref slots; tickets)
        {
            SavedPlayer player;
            player.guid = guid;
            player.node = currentNode is null ? 0 : currentNode(guid);
            if (!player.node)
                player.node = nodes.get(guid, 0);
            foreach (i, ref slot; slots)
                player.slots[i] = SavedTicket(slot.type, slot.stage, slot.instance,
                    slot.group is null ? 0 : groupIds[slot.group], slot.team);
            state.players ~= player;
        }
        foreach (ref copy; running)
            state.copies ~= SavedCopy(copy.instance, copy.type, copy.bracket, copy.clientId, copy.invited,
                copy.status, (copy.made - now).total!"hnsecs");
        foreach (key, deadline; lostNodes)
            state.lost ~= SavedLostNode(key, (deadline - now).total!"hnsecs");
        state.waitTimes_ = waitTimes;
        state.waitNext_ = waitNext;
        state.testing = testing;
        ubyte[] bytes;
        encode(bytes, state);
        SavedMapEpoch[] epochs;
        foreach (ref copy; running)
            if (copy.mapEpoch)
                epochs ~= SavedMapEpoch(copy.instance, copy.mapEpoch);
        encode(bytes, epochs);
        return bytes;
    }

    /// Restore a fresh queue using this node's clock, templates and callbacks.
    private void restoreState(const(ubyte)[] bytes, Duration elapsed = Duration.zero)
    {
        import dmangos.plaindata : decode;

        if (!bytes.length)
            return;
        SavedQueue state;
        decode(bytes, state);
        tickets = null;
        nodes = null;
        running = null;
        lostNodes = null;
        waiting = typeof(waiting).init;
        const now = clock() - elapsed;
        auto groups = new Waiting[state.groups.length + 1];
        foreach (i, ref saved; state.groups)
        {
            auto g = new Waiting;
            g.players = saved.players;
            g.team = saved.team;
            g.type = saved.type;
            g.bracket = saved.bracket;
            g.desired = saved.desired;
            g.joined = now + saved.joined.hnsecs;
            g.invitedTo = saved.invitedTo;
            if (g.invitedTo)
                g.inviteEnds = now + saved.inviteEnds.hnsecs;
            g.reminded = saved.reminded;
            waiting[g.type][g.bracket][g.team] ~= g;
            groups[i + 1] = g;
        }
        foreach (ref player; state.players)
        {
            Ticket[queueSlots] slots;
            foreach (i, ref slot; player.slots)
                slots[i] = Ticket(slot.type, slot.stage, slot.instance, groups[slot.group], slot.team);
            tickets[player.guid] = slots;
            nodes[player.guid] = player.node;
        }
        foreach (ref copy; state.copies)
            running[copy.instance] = Running(copy.instance, copy.type, copy.bracket, copy.clientId, copy.invited,
                copy.status, now + copy.made.hnsecs);
        if (bytes.length) // queues saved before map-owner reconciliation have no grant stamps
        {
            SavedMapEpoch[] epochs;
            decode(bytes, epochs);
            foreach (ref stamp; epochs)
                if (auto copy = stamp.instance in running)
                    copy.mapEpoch = stamp.epoch;
        }
        foreach (ref lost; state.lost)
            lostNodes[lost.key] = now + lost.deadline.hnsecs;
        waitTimes = state.waitTimes_;
        waitNext = state.waitNext_;
        testing = state.testing;
    }

    /// Players waiting or invited in all queues.
    @property size_t queuedPlayers() const
    {
        size_t n;
        foreach (ref byBracket; waiting)
            foreach (ref byTeam; byBracket)
                foreach (list; byTeam)
                    foreach (g; list)
                        n += g.players.length;
        return n;
    }

    /// The copies known.
    @property const(Running[uint]) copies() const
    {
        return running;
    }

    /// The slots of player `guid`.
    const(Ticket)[] ticketsOf(ulong guid) const
    {
        if (auto t = guid in tickets)
            return (*t)[];
        return null;
    }

    /**
     * A player joins at a battlemaster (its node has checked it may: no Deserter): queues
     * it for `type`, in the bracket of `level`, as `team` (0 the Alliance). Silent if it already waits
     * for that type or has no free slot.
     */
    void join(ulong guid, ushort node, ubyte team, uint level, BattlegroundType type, uint desired)
    {
        const t = type in templates;
        if (t is null || team > 1)
            return;
        nodes[guid] = node;
        tickets.require(guid, (Ticket[queueSlots]).init);
        int slot = -1;
        foreach (i, ref s; tickets[guid])
        {
            if (s.type == type)
                return; // already queued
            if (s.type == BattlegroundType.none && slot < 0)
                slot = cast(int) i;
        }
        if (slot < 0)
            return; // all three slots used
        auto g = new Waiting;
        g.players = [guid];
        g.team = team;
        g.type = type;
        g.bracket = bracketOf(*t, level);
        g.desired = desired;
        g.joined = clock();
        waiting[type][g.bracket][team] ~= g;
        tickets[guid][slot] = Ticket(type, Stage.queued, 0, g);
        send(guid, battlefieldStatus(slot, type, 0, BattlegroundStatus.waitQueue, averageWait(type, team, g.bracket), 0));
        update(type, g.bracket);
    }

    /// The `SMSG_GROUP_JOINED_BATTLEGROUND` results the queue decides (the others are the group's node's).
    enum JoinError : ubyte
    {
        ok = 0,
        memberAlreadyInQueue = 6,
        allQueuesUsed = 8,
    }

    /**
     * A group joins at a battlemaster (its node has checked size, faction, levels and Deserter):
     * its members queue as one, in the bracket of `level`, unless one already waits for `type` or has
     * no free slot. Each is told its slot and `SMSG_GROUP_JOINED_BATTLEGROUND`.
     */
    JoinError joinGroup(const(ulong)[] players, const(ushort)[] playerNodes, ubyte team, uint level,
        BattlegroundType type, uint desired)
    {
        const t = type in templates;
        if (t is null || team > 1 || players.length == 0)
            return JoinError.ok;
        foreach (p; players)
        {
            if (slotOf(p, type) >= 0)
                return JoinError.memberAlreadyInQueue;
            if (auto mine = p in tickets)
            {
                bool free;
                foreach (ref s; *mine)
                    free = free || s.type == BattlegroundType.none;
                if (!free)
                    return JoinError.allQueuesUsed;
            }
        }
        auto g = new Waiting;
        g.players = players.dup;
        g.team = team;
        g.type = type;
        g.bracket = bracketOf(*t, level);
        g.desired = desired;
        g.joined = clock();
        waiting[type][g.bracket][team] ~= g;
        foreach (i, p; players)
        {
            nodes[p] = i < playerNodes.length ? playerNodes[i] : 0;
            tickets.require(p, (Ticket[queueSlots]).init);
            int slot = -1;
            foreach (j, ref s; tickets[p])
                if (s.type == BattlegroundType.none && slot < 0)
                    slot = cast(int) j;
            tickets[p][slot] = Ticket(type, Stage.queued, 0, g);
            send(p, battlefieldStatus(slot, type, 0, BattlegroundStatus.waitQueue, averageWait(type, team, g.bracket), 0));
            ByteWriter joined;
            joined.put(cast(int) battlegroundMaps[type]);
            send(p, joined.data, Opcode.SMSG_GROUP_JOINED_BATTLEGROUND);
        }
        update(type, g.bracket);
        return JoinError.ok;
    }

    /// What `port` answers: where the player goes, if it goes.
    struct Entry
    {
        bool enter;
        uint instance;
        ubyte team;
        BattlegroundType type;
        bool requiresLiveCopy;
    }

    /**
     * `CMSG_BATTLEFIELD_PORT`: player `guid` accepts (`enter`) its invitation to `type`, or leaves
     * that queue. Accepted, the player stays counted in the copy; the answer says which.
     */
    Entry port(ulong guid, ushort node, BattlegroundType type, bool enter)
    {
        nodes[guid] = node;
        const slot = slotOf(guid, type);
        if (slot < 0)
            return Entry.init;
        auto ticket = &tickets[guid][slot];
        if (!enter)
        {
            if (ticket.stage == Stage.inside)
                return Entry.init; // leaving a copy is the copy's (`CMSG_LEAVE_BATTLEFIELD`)
            leaveQueue(guid, slot, true);
            forgetIfIdle(guid);
            return Entry.init;
        }
        if (ticket.stage == Stage.inside && ticket.instance in running)
        {
            const copy = running[ticket.instance];
            return Entry(true, ticket.instance, ticket.team, type, copy.mapEpoch || copy.status >= BattlegroundStatus.inProgress);
        }
        if (ticket.stage != Stage.invited)
            return Entry.init;
        auto copy = ticket.instance in running;
        if (copy is null)
        {
            leaveQueue(guid, slot, true);
            forgetIfIdle(guid);
            return Entry.init;
        }
        const team = ticket.group.team;
        removeFromGroup(guid, ticket.group);
        *ticket = Ticket(type, Stage.inside, copy.instance, null, team);
        send(guid, battlefieldStatus(slot, type, copy.clientId, BattlegroundStatus.inProgress, 0,
            sinceMs(copy.made)));
        return Entry(true, copy.instance, team, type, copy.mapEpoch || copy.status >= BattlegroundStatus.inProgress);
    }

    /// The client asks for its queues: every slot's state, sent again.
    void status(ulong guid, ushort node)
    {
        nodes[guid] = node;
        auto mine = guid in tickets;
        // The 1.12 client clears its objective columns on an empty-slot packet, even
        // for another slot. Clear stale slots before announcing the active match.
        foreach (uint i; 0 .. queueSlots)
            if (mine is null || (*mine)[i].type == BattlegroundType.none)
                send(guid, battlefieldStatus(i, BattlegroundType.none, 0, BattlegroundStatus.none));
        if (mine is null)
            return;
        const now = clock();
        foreach (i, const ref t; *mine)
        {
            if (t.type == BattlegroundType.none)
                continue;
            final switch (t.stage)
            {
            case Stage.queued:
                send(guid, battlefieldStatus(cast(uint) i, t.type, 0, BattlegroundStatus.waitQueue,
                    averageWait(t.type, t.group.team, t.group.bracket), sinceMs(t.group.joined)));
                break;
            case Stage.invited:
                const left = t.group.inviteEnds > now ? (t.group.inviteEnds - now).total!"msecs" : 0;
                send(guid, battlefieldStatus(cast(uint) i, t.type, clientIdOf(t.instance),
                    BattlegroundStatus.waitJoin, cast(uint) left));
                break;
            case Stage.inside:
                sendMatchStatus(guid, cast(uint) i, t);
                break;
            }
        }
    }

    private void sendMatchStatus(ulong guid, uint slot, const ref Ticket ticket)
    {
        if (auto copy = ticket.instance in running)
            send(guid, battlefieldStatus(slot, ticket.type, copy.clientId, BattlegroundStatus.inProgress,
                0, sinceMs(copy.made)));
    }

    /// The player logged out: it leaves every queue (a copy it is in keeps it a while).
    void logout(ulong guid)
    {
        auto mine = guid in tickets;
        if (mine is null)
            return;
        foreach (i, ref t; *mine)
            if (t.type != BattlegroundType.none && t.stage != Stage.inside)
                leaveQueue(guid, cast(int) i, false);
        forgetIfIdle(guid);
    }

    /// Give connections and presence from a moving player time to reach this host.
    void nodeLost(uint realm, ushort node)
    {
        lostNodes[(cast(ulong) realm << 16) | node] = clock() + nodeLossGrace;
    }

    private Duration nodeLossGrace = 5.seconds;

    /// The `SMSG_BATTLEFIELD_LIST`: the copies of `type` in the bracket of `level`.
    void list(ulong guid, ushort node, ulong battlemaster, BattlegroundType type, uint level)
    {
        const t = type in templates;
        if (t is null)
            return;
        nodes[guid] = node;
        const bracket = bracketOf(*t, level);
        uint[] ids;
        foreach (ref copy; running)
            if (copy.type == type && copy.bracket == bracket && copy.status < BattlegroundStatus.waitLeave)
                ids ~= copy.clientId;
        import std.algorithm.sorting : sort;

        ids.sort();
        ByteWriter w;
        w.put(battlemaster);
        w.put(battlegroundMaps[type]);
        w.put(ubyte(0));
        w.put(cast(uint) ids.length);
        foreach (id; ids)
            w.put(id);
        send(guid, w.data, Opcode.SMSG_BATTLEFIELD_LIST);
    }

    /**
     * From the copy's node: player `guid` of `team` left copy
     * `instance`. Its slot is free again, and so is its place in the copy.
     */
    void left(uint instance, ulong guid, ubyte team)
    {
        auto copy = instance in running;
        if (auto mine = guid in tickets)
            foreach (i, ref t; *mine)
                if (t.stage == Stage.inside && t.instance == instance)
                {
                    if (copy !is null && team < 2 && copy.invited[team])
                        --copy.invited[team];
                    send(guid, battlefieldStatus(cast(uint) i, t.type, 0, BattlegroundStatus.none));
                    t = Ticket.init;
                }
        forgetIfIdle(guid);
        if (copy !is null && copy.status < BattlegroundStatus.waitLeave)
            update(copy.type, copy.bracket);
    }

    /// From the copy's node: copy `instance` started, ended (`waitLeave`) or closed (`none`).
    void changed(uint instance, BattlegroundStatus status, ulong mapEpoch = 0)
    {
        auto copy = instance in running;
        if (copy is null)
            return;
        if (status == BattlegroundStatus.none)
        {
            const type = copy.type;
            const bracket = copy.bracket;
            running.remove(instance);
            foreach (guid; tickets.keys)
            {
                const slot = slotOf(guid, type);
                if (slot < 0 || tickets[guid][slot].instance != instance)
                    continue;
                leaveQueue(guid, slot, true, false);
                forgetIfIdle(guid);
            }
            update(type, bracket);
            return;
        }
        copy.status = status;
        copy.mapEpoch = mapEpoch;
    }

    /// Reconcile the queue with the copy IDs the current map owner actually restored.
    private bool reconcileMap(BattlegroundType type, ulong epoch, const(BattlegroundChanged)[] live)
    {
        import dmangos.log : info;

        bool changed_;
        foreach (ref match; live)
            if (auto copy = match.instance in running)
                if (copy.type == type && copy.mapEpoch < epoch
                    && match.status >= BattlegroundStatus.waitJoin && match.status <= BattlegroundStatus.waitLeave)
                {
                    changed(match.instance, cast(BattlegroundStatus) match.status, epoch);
                    changed_ = true;
                }
        foreach (instance; running.keys)
        {
            auto copy = &running[instance];
            if (copy.type == type && copy.mapEpoch < epoch
                && (copy.mapEpoch || copy.status >= BattlegroundStatus.inProgress))
            {
                info!"battleground: copy %s was interrupted by loss of its map host"(instance);
                changed(instance, BattlegroundStatus.none);
                changed_ = true;
            }
        }
        return changed_;
    }

    /// From the copy's node, before it closes an empty copy: how many may still come (invited).
    uint invited(uint instance) const
    {
        if (auto copy = instance in running)
        {
            uint waitingFor;
            foreach (ref byTeam; waiting[copy.type][copy.bracket])
                foreach (g; byTeam)
                    if (g.invitedTo == instance)
                        waitingFor += cast(uint) g.players.length;
            return waitingFor;
        }
        return 0;
    }

    /**
     * `.battleground forcestart`: a copy for whoever waits, in every
     * queue, however few.
     */
    void forceStart()
    {
        const was = testing;
        testing = true;
        scope (exit)
            testing = was;
        foreach (type; 1 .. 4)
            foreach (bracket; 0 .. bracketCount)
                if (waiting[type][bracket][0].length || waiting[type][bracket][1].length)
                    update(cast(BattlegroundType) type, cast(ubyte) bracket);
    }

    /// The queue's own time: invitations reminded of and run out.
    void tick()
    {
        const now = clock();
        Waiting[] expired;
        foreach (ref byBracket; waiting)
            foreach (ref byTeam; byBracket)
                foreach (list; byTeam)
                    foreach (g; list)
                    {
                        if (!g.invitedTo)
                            continue;
                        if (now >= g.inviteEnds)
                            expired ~= g;
                        else if (!g.reminded && now >= g.inviteEnds - (inviteTime - remindAfter))
                        {
                            g.reminded = true; // the reminder of the invitation
                            foreach (p; g.players)
                            {
                                const slot = slotOf(p, g.type);
                                if (slot >= 0)
                                    send(p, battlefieldStatus(slot, g.type, clientIdOf(g.invitedTo),
                                        BattlegroundStatus.waitJoin, cast(uint)(inviteTime - remindAfter).total!"msecs"));
                            }
                        }
                    }
        foreach (g; expired) // invitations not accepted in time
            foreach (p; g.players.dup)
            {
                const slot = slotOf(p, g.type);
                if (slot >= 0)
                    leaveQueue(p, slot, true);
                forgetIfIdle(p);
            }
        foreach (key; lostNodes.keys)
            if (lostNodes[key] <= now)
            {
                pruneLostNode(cast(uint)(key >> 16), cast(ushort) key);
                lostNodes.remove(key);
            }
    }

private:
    void pruneLostNode(uint realm, ushort node)
    {
        bool[bracketCount][4] vacated;
        foreach (guid; nodes.keys)
        {
            if (guid >> 32 != realm || nodes[guid] != node)
                continue;
            if (const online = currentNode is null ? 0 : currentNode(guid))
            {
                nodes[guid] = online;
                continue;
            }
            nodes.remove(guid);
            if (auto mine = guid in tickets)
                foreach (i, ref t; *mine)
                    if (t.type != BattlegroundType.none && t.stage != Stage.inside)
                    {
                        vacated[t.type][t.group.bracket] = true;
                        leaveQueue(guid, cast(int) i, false, false);
                    }
            forgetIfIdle(guid);
        }
        foreach (type, byBracket; vacated)
            foreach (bracket, changed; byBracket)
                if (changed)
                    update(cast(BattlegroundType) type, cast(ubyte) bracket);
    }

    void send(ulong guid, const(ubyte)[] body_, Opcode opcode = Opcode.SMSG_BATTLEFIELD_STATUS)
    {
        if (deliver !is null)
            deliver(guid, nodes.get(guid, 0), opcode, body_);
    }

    int slotOf(ulong guid, BattlegroundType type) const
    {
        if (auto mine = guid in tickets)
            foreach (i, ref t; *mine)
                if (t.type == type)
                    return cast(int) i;
        return -1;
    }

    uint clientIdOf(uint instance) const
    {
        if (auto copy = instance in running)
            return copy.clientId;
        return 0;
    }

    uint sinceMs(MonoTime from)
    {
        return cast(uint)(clock() - from).total!"msecs";
    }

    void forgetIfIdle(ulong guid)
    {
        if (auto mine = guid in tickets)
        {
            foreach (ref t; *mine)
                if (t.type != BattlegroundType.none)
                    return;
            tickets.remove(guid);
            nodes.remove(guid);
        }
    }

    /// The player leaves a queue: slot `slot` emptied, the player told.
    void leaveQueue(ulong guid, int slot, bool tell, bool refill = true)
    {
        auto ticket = &tickets[guid][slot];
        const type = ticket.type;
        auto g = ticket.group;
        if (g !is null)
        {
            if (g.invitedTo)
                if (auto copy = g.invitedTo in running)
                    if (copy.invited[g.team])
                        --copy.invited[g.team]; // a place in it again
            removeFromGroup(guid, g);
        }
        *ticket = Ticket.init;
        if (tell)
        {
            send(guid, battlefieldStatus(slot, type, 0, BattlegroundStatus.none));
            // Declining or dropping another queue also clears the active scoreboard at the client.
            foreach (i, const ref t; tickets[guid])
                if (t.type != BattlegroundType.none && t.stage == Stage.inside)
                    sendMatchStatus(guid, cast(uint) i, t);
        }
        if (refill && g !is null)
            update(type, g.bracket);
    }

    void removeFromGroup(ulong guid, Waiting g)
    {
        import std.algorithm.mutation : remove;
        import std.algorithm.searching : countUntil;

        const i = g.players.countUntil(guid);
        if (i >= 0)
            g.players = g.players.remove(i);
        if (g.players.length == 0)
        {
            auto list = &waiting[g.type][g.bracket][g.team];
            const j = (*list).countUntil!(x => x is g);
            if (j >= 0)
                *list = (*list).remove(j);
        }
    }

    /// The average wait: once ten were invited, the average of their waits.
    uint averageWait(BattlegroundType type, ubyte team, ubyte bracket) const
    {
        const samples = waitTimes[type][team][bracket];
        if (samples[waitSamples - 1] == 0)
            return 0;
        ulong sum;
        foreach (s; samples)
            sum += s;
        return cast(uint)(sum / waitSamples);
    }

    /// Invites a waiting group to a copy.
    void invite(Waiting g, ref Running copy)
    {
        const now = clock();
        g.invitedTo = copy.instance;
        g.inviteEnds = now + inviteTime;
        g.reminded = false;
        copy.invited[g.team] += cast(uint) g.players.length;
        auto next = &waitNext[g.type][g.team][g.bracket];
        waitTimes[g.type][g.team][g.bracket][*next] = cast(uint)(now - g.joined).total!"msecs";
        *next = (*next + 1) % waitSamples;
        foreach (p; g.players)
        {
            const slot = slotOf(p, g.type);
            if (slot < 0)
                continue;
            tickets[p][slot].stage = Stage.invited;
            tickets[p][slot].instance = copy.instance;
            send(p, battlefieldStatus(slot, g.type, copy.clientId, BattlegroundStatus.waitJoin,
                cast(uint) inviteTime.total!"msecs"));
        }
    }

    /// A queue's turn: running copies filled, then a new one made if enough wait.
    void update(BattlegroundType type, ubyte bracket)
    {
        const t = type in templates;
        if (t is null)
            return;
        auto lists = &waiting[type][bracket];
        // Running copies with room first, the oldest made first.
        foreach (instance; runningOf(type, bracket))
        {
            auto copy = &running[instance];
            if (copy.status != BattlegroundStatus.waitJoin && copy.status != BattlegroundStatus.inProgress)
                continue;
            foreach (team; 0 .. 2)
            {
                uint room = copy.invited[team] < t.maxPerTeam ? t.maxPerTeam - copy.invited[team] : 0;
                foreach (g; (*lists)[team])
                {
                    if (room == 0)
                        break;
                    if (g.invitedTo || (g.desired && g.desired != copy.clientId) || g.players.length > room)
                        continue;
                    invite(g, *copy);
                    room -= cast(uint) g.players.length;
                }
            }
        }
        // A new copy: both teams' first groups, up to enough of each.
        const least = testing ? 1 : t.minPerTeam;
        Waiting[][2] pools;
        uint[2] counts;
        foreach (team; 0 .. 2)
            foreach (g; (*lists)[team])
            {
                if (counts[team] >= least)
                    break;
                if (g.invitedTo || g.desired || counts[team] + g.players.length > t.maxPerTeam)
                    continue;
                pools[team] ~= g;
                counts[team] += cast(uint) g.players.length;
            }
        const enough = testing ? counts[0] + counts[1] > 0 : counts[0] >= least && counts[1] >= least;
        if (!enough)
            return;
        uint instance;
        if (newInstanceId is null || !newInstanceId(instance) || instance == 0)
            return; // no id now: tried again on the next change
        running[instance] = Running(instance, type, bracket, freeClientId(type, bracket), [0, 0],
            BattlegroundStatus.waitJoin, clock());
        foreach (team; 0 .. 2)
            foreach (g; pools[team])
                invite(g, running[instance]);
    }

    uint[] runningOf(BattlegroundType type, ubyte bracket)
    {
        import std.algorithm.sorting : sort;

        uint[] ids;
        foreach (id, ref copy; running)
            if (copy.type == type && copy.bracket == bracket)
                ids ~= id;
        ids.sort();
        return ids;
    }

    /// The number the client shows for a new copy: the lowest not taken by a copy of its type and bracket.
    uint freeClientId(BattlegroundType type, ubyte bracket)
    {
        bool[uint] taken;
        foreach (ref copy; running)
            if (copy.type == type && copy.bracket == bracket)
                taken[copy.clientId] = true;
        uint id = 1;
        while (id in taken)
            ++id;
        return id;
    }
}

// --- the service --------------------------------------------------------------------------------

/// A player's request to the queues, with what they need of it.
struct BattlegroundJoin
{
    ulong guid;
    ushort node;
    ubyte team;
    ubyte level;
    ubyte type;
    uint desired;
}

/// A group's request to queue: its members and their nodes.
struct BattlegroundGroupJoin
{
    ulong[] players;
    ushort[] nodes;
    ubyte team;
    ubyte level;
    ubyte type;
    uint desired;
}

/// What `BattlegroundQueueHost.joinGroup` answers: 0, or an `SMSG_GROUP_JOINED_BATTLEGROUND` result.
struct BattlegroundJoinResult
{
    ubyte error;
}

/// ditto
struct BattlegroundPort
{
    ulong guid;
    ushort node;
    ubyte type;
    bool enter;
}

/// What `BattlegroundQueueHost.port` answers.
struct BattlegroundEntry
{
    bool enter;
    uint instance;
    ubyte team;
    ubyte type;
    bool requiresLiveCopy;
}

/// A player's request about all its slots (`status`, `logout`).
struct BattlegroundPlayer
{
    ulong guid;
    ushort node;
}

/// A battlemaster's list.
struct BattlegroundList
{
    ulong guid;
    ushort node;
    ulong battlemaster;
    ubyte type;
    ubyte level;
}

/// From a copy's node: a player left it.
struct BattlegroundLeft
{
    uint instance;
    ulong guid;
    ubyte team;
}

/// From a copy's node: its status changed.
struct BattlegroundChanged
{
    uint instance;
    ubyte status;
    ulong mapEpoch;
}

/// The copies recovered by the new holder of a battleground map's fencing token.
struct BattlegroundMapRecovered
{
    uint map;
    ulong epoch;
    BattlegroundChanged[] live;
}

struct BattlegroundMapRecoveryReply
{
    bool received;
}

/// A copy, asked about.
struct BattlegroundInstance
{
    uint instance;
}

/// How many are invited to a copy and not in it yet.
struct BattlegroundInvited
{
    uint count;
}

/// A snapshot of the battlegroup queue coordinator's live state.
struct BattlegroundQueueStats
{
    uint queuedPlayers;
    uint activeMatches;
}

/// The queues as a cluster service: on the node the cluster places it on.
@Service(ServiceKind.battlegroundQueue)
struct BattlegroundQueueHost
{
    import dmangos.world.context : WorldContext;

    BattlegroundQueue queue;
    private WorldContext context;

    bool clockOwner = true;

    this(BattlegroundQueue queue, const(ubyte)[] state, bool clockOwner = true, WorldContext context = null)
    {
        import core.time : msecs;

        this.queue = queue;
        this.context = context;
        this.clockOwner = clockOwner;
        if (!clockOwner)
            return;
        if (context !is null && context.config.cluster.enabled)
        {
            const config = context.config.cluster;
            queue.nodeLossGrace = (cast(long) config.leaseMs + config.failureTimeoutMs).msecs + 30.seconds;
        }
        queue.durable = RealmServiceCheckpoint(context, ServiceKind.battlegroundQueue);
        ushort previousNode;
        Duration elapsed;
        const recovered = queue.durable.load(!state.length, previousNode, elapsed);
        if (state.length)
            queue.restoreState(state);
        else if (recovered.length)
        {
            import dmangos.log : warning;

            try
            {
                queue.restoreState(recovered, elapsed);
                if (context.battlegroup is null)
                    queue.nodeLost(0, previousNode);
                else
                    context.battlegroup.queueHostLost(previousNode);
            }
            catch (Exception error)
                warning!"battleground queues: could not restore the saved service state: %s"(error.msg);
        }
    }

    ubyte[] saveState() const
    {
        return queue.saveState();
    }

    ///
    @Call void join(const ref BattlegroundJoin r)
    {
        queue.join(r.guid, r.node, r.team, r.level, cast(BattlegroundType) r.type, r.desired);
        queue.durable.save(true, &queue.saveState);
    }

    ///
    @Call BattlegroundJoinResult joinGroup(const ref BattlegroundGroupJoin r)
    {
        const error = queue.joinGroup(r.players, r.nodes, r.team, r.level, cast(BattlegroundType) r.type, r.desired);
        queue.durable.save(true, &queue.saveState);
        return BattlegroundJoinResult(error);
    }

    ///
    @Call BattlegroundEntry port(const ref BattlegroundPort r)
    {
        const e = queue.port(r.guid, r.node, cast(BattlegroundType) r.type, r.enter);
        queue.durable.save(true, &queue.saveState);
        return BattlegroundEntry(e.enter, e.instance, e.team, e.type, e.requiresLiveCopy);
    }

    ///
    @Call void status(const ref BattlegroundPlayer r)
    {
        queue.status(r.guid, r.node);
    }

    ///
    @Call void logout(const ref BattlegroundPlayer r)
    {
        queue.logout(r.guid);
        queue.durable.save(true, &queue.saveState);
    }

    ///
    @Call void list(const ref BattlegroundList r)
    {
        queue.list(r.guid, r.node, r.battlemaster, cast(BattlegroundType) r.type, r.level);
    }

    ///
    @Call void left(const ref BattlegroundLeft r)
    {
        queue.left(r.instance, r.guid, r.team);
        queue.durable.save(true, &queue.saveState);
    }

    ///
    @Call void changed(const ref BattlegroundChanged r)
    {
        auto copy = r.instance in queue.running;
        if (copy is null || r.status > BattlegroundStatus.waitLeave)
            return;
        if (context !is null && context.battlegroundMapEpoch !is null)
            if (!r.mapEpoch || context.battlegroundMapEpoch(battlegroundMaps[copy.type]) != r.mapEpoch)
                return;
        queue.changed(r.instance, cast(BattlegroundStatus) r.status, r.mapEpoch);
        queue.durable.save(true, &queue.saveState);
    }

    @Call BattlegroundMapRecoveryReply mapRecovered(const ref BattlegroundMapRecovered r)
    {
        const type = battlegroundOfMap(r.map);
        if (!type || context is null || context.battlegroundMapEpoch is null
            || !r.epoch || context.battlegroundMapEpoch(r.map) != r.epoch || !context.canWrite())
            return BattlegroundMapRecoveryReply(false);
        if (queue.reconcileMap(type, r.epoch, r.live))
            queue.durable.save(true, &queue.saveState);
        return BattlegroundMapRecoveryReply(true);
    }

    ///
    @Call BattlegroundInvited invited(const ref BattlegroundInstance r)
    {
        return BattlegroundInvited(queue.invited(r.instance));
    }

    /// Reads the aggregate queue and match counts without changing queue state.
    @Call BattlegroundQueueStats stats(const ref BattlegroundPlayer)
    {
        uint matches;
        foreach (ref copy; queue.copies)
            if (copy.status < BattlegroundStatus.waitLeave)
                ++matches;
        return BattlegroundQueueStats(cast(uint) queue.queuedPlayers, matches);
    }

    ///
    @Call void forceStart(const ref BattlegroundInstance)
    {
        queue.forceStart();
        queue.durable.save(true, &queue.saveState);
    }

    void tick(Duration)
    {
        if (!clockOwner)
            return;
        queue.tick();
        queue.durable.save(false, &queue.saveState);
    }
}

// --- tests ----------------------------------------------------------------------------------------

version (unittest)
{
    private struct Sent
    {
        ulong guid;
        Opcode opcode;
        const(ubyte)[] body_;

        /// `SMSG_BATTLEFIELD_STATUS`'s status, if it has one.
        uint status() const
        {
            import dmangos.bytes : ByteReader;

            auto r = ByteReader(body_);
            r.read!uint;
            if (r.read!uint == 0)
                return 0;
            r.read!ubyte;
            r.read!uint;
            return r.read!uint;
        }
    }

    private BattlegroundQueue testQueue(ref MonoTime now, ref Sent[] sent)
    {
        auto q = new BattlegroundQueue;
        q.templates[BattlegroundType.warsongGulch] = BattlegroundTemplate(2, 2, 3, 10, 60, [769, 770], 75, 0);
        q.clock = () => now;
        uint next = 100;
        q.newInstanceId = (out uint id) { id = next++; return true; };
        q.deliver = (ulong guid, ushort, Opcode op, const(ubyte)[] b) { sent ~= Sent(guid, op, b.dup); };
        return q;
    }
}

// Brackets of ten levels from the minimum; the last open-ended.
unittest
{
    const ws = BattlegroundTemplate(2, 5, 10, 10, 60);
    assert(bracketOf(ws, 10) == 0 && bracketOf(ws, 19) == 0 && bracketOf(ws, 20) == 1 && bracketOf(ws, 60) == 5);
    const av = BattlegroundTemplate(1, 20, 40, 51, 60);
    assert(bracketOf(av, 51) == 0 && bracketOf(av, 60) == 0 && bracketOf(av, 40) == 0);
    assert(!levelAllowed(av, 50) && levelAllowed(av, 51));
    assert(battlegroundOfMap(489) == BattlegroundType.warsongGulch && battlegroundOfMap(0) == BattlegroundType.none);
}

// Enough of both teams make a copy; their invitations; accepting; the rest fill it; a late one waits.
unittest
{
    auto now = MonoTime.currTime;
    Sent[] sent;
    auto q = testQueue(now, sent);
    alias WS = BattlegroundType.warsongGulch;
    q.join(1, 1, 0, 15, WS, 0);
    assert(sent.length == 1 && sent[0].status == BattlegroundStatus.waitQueue);
    q.join(2, 1, 0, 15, WS, 0);
    q.join(3, 2, 1, 15, WS, 0);
    assert(q.copies.length == 0, "one Horde player is not enough");
    q.join(4, 2, 1, 16, WS, 0);
    assert(q.copies.length == 1, "two of each: a copy");
    size_t invites;
    foreach (s; sent)
        invites += s.status == BattlegroundStatus.waitJoin;
    assert(invites == 4);
    // A level-25 player is of another bracket: not this copy's.
    q.join(5, 1, 0, 25, WS, 0);
    assert(q.ticketsOf(5)[0].stage == BattlegroundQueue.Stage.queued);
    // Room for one more of each: a fifth Alliance player of the bracket is invited at once.
    q.join(6, 1, 0, 11, WS, 0);
    assert(q.ticketsOf(6)[0].stage == BattlegroundQueue.Stage.invited);
    q.join(7, 1, 0, 11, WS, 0);
    assert(q.ticketsOf(7)[0].stage == BattlegroundQueue.Stage.queued, "the Alliance side is full (3)");

    const e = q.port(1, 1, WS, true);
    assert(e.enter && e.instance == 100 && e.team == 0);
    assert(q.ticketsOf(1)[0].stage == BattlegroundQueue.Stage.inside);
    assert(sent[$ - 1].status == BattlegroundStatus.inProgress);
    q.status(1, 1);
    assert(sent[$ - 3].status == BattlegroundStatus.none && sent[$ - 2].status == BattlegroundStatus.none
        && sent[$ - 1].status == BattlegroundStatus.inProgress, "the client keeps its objective columns");
    alias AB = BattlegroundType.arathiBasin;
    q.templates[AB] = BattlegroundTemplate(3, 2, 3, 10, 60);
    q.join(1, 1, 0, 15, AB, 0);
    assert(sent[$ - 1].status == BattlegroundStatus.waitQueue);
    q.port(1, 1, AB, false);
    assert(sent[$ - 2].status == BattlegroundStatus.none && sent[$ - 1].status == BattlegroundStatus.inProgress,
        "dropping a different queue restores the active scoreboard");
    assert(q.invited(100) == 4, "four invited (two of each, and the late fifth), not in yet");
    // Declining frees the place: the waiting seventh is invited.
    q.port(2, 1, WS, false);
    assert(q.ticketsOf(2) is null && q.ticketsOf(7)[0].stage == BattlegroundQueue.Stage.invited);
    // Leaving the copy frees a place too, and the slot.
    q.left(100, 1, 0);
    assert(q.ticketsOf(1) is null && q.copies[100].invited[0] == 2);
    q.left(100, 1, 0);
    assert(q.copies[100].invited[0] == 2, "a repeated departure cannot free another player's place");
}

// Invitations: reminded at 60 s, gone at 80 s; three slots at most; logging out leaves the queues.
unittest
{
    auto now = MonoTime.currTime;
    Sent[] sent;
    auto q = testQueue(now, sent);
    q.templates[BattlegroundType.arathiBasin] = BattlegroundTemplate(3, 8, 15, 20, 60, [890, 889], 75, 0);
    q.templates[BattlegroundType.alteracValley] = BattlegroundTemplate(1, 20, 40, 51, 60, [611, 610], 100, 1);
    q.testing = true;
    q.join(1, 1, 0, 60, BattlegroundType.warsongGulch, 0);
    assert(q.ticketsOf(1)[0].stage == BattlegroundQueue.Stage.invited, "testing: one player makes a copy");
    sent = null;
    now += 61.seconds;
    q.tick();
    assert(sent.length == 1 && sent[0].status == BattlegroundStatus.waitJoin, "reminded");
    q.tick();
    assert(sent.length == 1, "once");
    now += 20.seconds;
    q.tick();
    assert(q.ticketsOf(1) is null && sent[$ - 1].status == 0, "the invitation ran out");

    q.testing = false;
    q.join(2, 1, 0, 60, BattlegroundType.warsongGulch, 0);
    q.join(2, 1, 0, 60, BattlegroundType.arathiBasin, 0);
    q.join(2, 1, 0, 60, BattlegroundType.alteracValley, 0);
    q.join(2, 1, 0, 60, BattlegroundType.warsongGulch, 0);
    assert(q.ticketsOf(2).length == 3 && q.queuedPlayers == 3);
    q.logout(2);
    assert(q.ticketsOf(2) is null && q.queuedPlayers == 0);
}

// Hand a live queue to a service host with a different monotonic clock.
unittest
{
    import std.algorithm.searching : find;

    import dmangos.bytes : ByteReader;
    import dmangos.cluster.services : ServiceHost;

    auto now = MonoTime.currTime;
    auto otherNow = now + 3600.seconds;
    Sent[] sent;
    alias WS = BattlegroundType.warsongGulch;
    alias AV = BattlegroundType.alteracValley;
    alias Stage = BattlegroundQueue.Stage;
    enum kind = ServiceKind.battlegroundQueue;
    auto from = new ServiceHost;
    auto to = new ServiceHost;
    auto q = testQueue(now, sent);
    q.templates[AV] = BattlegroundTemplate(1, 20, 40, 51, 60);
    from.host(BattlegroundQueueHost(q, null));
    to.provide!BattlegroundQueueHost((const(ubyte)[] state) {
        auto destination = testQueue(otherNow, sent);
        destination.templates[AV] = q.templates[AV];
        return BattlegroundQueueHost(destination, state);
    });

    q.join(2, 2, 0, 60, AV, 0);
    q.joinGroup([1UL, 2], [1, 2], 0, 60, WS, 0);
    now += 10.seconds;
    q.joinGroup([3UL, 4], [2, 2], 1, 60, WS, 0);
    const inside = q.port(1, 1, WS, true);
    assert(inside.enter);
    q.join(5, 2, 0, 60, WS, 0);
    q.joinGroup([6UL, 7], [1, 2], 0, 60, WS, 1);
    q.joinGroup([8UL, 9], [2, 1], 0, 60, WS, 1);
    q.changed(inside.instance, BattlegroundStatus.inProgress);
    now += 61.seconds;
    q.tick();
    assert(q.invited(inside.instance) == 4);

    const state = from.stop(kind);
    sent = null;
    assert(!from.hosts(kind) && to.start(kind, state));
    auto moved = to.local!BattlegroundQueueHost().queue;
    assert(sent.length == 0);
    assert(moved.ticketsOf(1)[0].stage == Stage.inside);
    assert(moved.ticketsOf(2)[0].type == AV && moved.ticketsOf(2)[1].stage == Stage.invited);
    assert(moved.ticketsOf(6)[0].group is moved.ticketsOf(7)[0].group);
    assert(moved.nodes[7] == 2);
    assert(moved.waitTimes == q.waitTimes && moved.waitNext == q.waitNext);
    assert(moved.copies[inside.instance].status == BattlegroundStatus.inProgress);
    assert(moved.copies[inside.instance].invited == [3, 2]);
    assert(moved.sinceMs(moved.copies[inside.instance].made) == 61_000);
    assert(moved.invited(inside.instance) == 4);

    moved.tick();
    assert(sent.length == 0, "already-sent reminders stay sent");
    moved.status(2, 2);
    assert(sent.length == queueSlots);
    auto invitations = sent.find!(p => p.status == BattlegroundStatus.waitJoin);
    assert(invitations.length);
    auto invite = ByteReader(invitations[0].body_);
    assert(invite.read!uint == 1, "the invitation stays in the same client slot");
    invite.skip(13);
    assert(invite.read!uint == 19_000, "the client sees the invitation time remaining");
    const accepted = moved.port(2, 2, WS, true);
    assert(accepted.enter && accepted.instance == inside.instance && accepted.team == 0);

    otherNow += 18.seconds;
    moved.tick();
    assert(moved.invited(inside.instance) == 3, "invitations still valid before the deadline");
    otherNow += 1.seconds;
    moved.tick();
    assert(moved.invited(inside.instance) == 0, "invitations expire at the original remaining time");
    moved.left(inside.instance, 1, 0);
    assert(moved.ticketsOf(6)[0].stage == Stage.invited && moved.ticketsOf(7)[0].stage == Stage.invited);
    assert(moved.ticketsOf(8)[0].stage == Stage.queued, "the first waiting group refills the running copy");
}

// A worker loss removes disconnected players and refills the copy, even across realm-scoped node IDs.
unittest
{
    import dmangos.world.battlegroup : realmPlayerGuid;

    auto now = MonoTime.currTime;
    Sent[] sent;
    auto q = testQueue(now, sent);
    alias WS = BattlegroundType.warsongGulch;
    const dead = realmPlayerGuid(1, 1), moved = realmPlayerGuid(1, 2), otherRealm = realmPlayerGuid(2, 1);
    const waiting = realmPlayerGuid(1, 3), horde = realmPlayerGuid(2, 2);
    q.currentNode = (ulong guid) => guid == moved ? ushort(3) : ushort(0);
    q.join(dead, 2, 0, 60, WS, 0);
    q.join(moved, 2, 0, 60, WS, 0);
    q.join(otherRealm, 2, 0, 60, WS, 0);
    q.join(horde, 1, 1, 60, WS, 0);
    q.forceStart();
    q.join(waiting, 1, 0, 60, WS, 0);
    const instance = q.ticketsOf(moved)[0].instance;
    assert(instance && q.ticketsOf(waiting)[0].stage == BattlegroundQueue.Stage.queued);
    q.nodeLost(1, 2);
    now += 4.seconds;
    q.tick();
    assert(q.ticketsOf(dead).length, "give a replacement link or presence time to report");
    now += 1.seconds;
    q.tick();
    assert(!q.ticketsOf(dead).length);
    assert(q.ticketsOf(moved)[0].instance == instance && q.nodes[moved] == 3);
    assert(q.ticketsOf(otherRealm)[0].instance == instance);
    assert(q.ticketsOf(waiting)[0].instance == instance && q.copies[instance].invited[0] == 3);
    q.changed(instance, BattlegroundStatus.none);
    assert(!q.ticketsOf(otherRealm).length && !q.ticketsOf(waiting).length && !q.ticketsOf(moved).length);
}

// Recover without a service handoff. The queue remembers an acceptance whose reply was lost.
unittest
{
    import std.algorithm.searching : find;

    import dmangos.bytes : ByteReader;
    import dmangos.world.config : WorldConfig;
    import dmangos.world.movement : Position;
    import dmangos.world.testclient : newCreationContext, newDatabase;

    void clustered(ref WorldConfig config) { config.cluster.nodeId = 1; }
    auto db = newDatabase();
    auto previous = newCreationContext(db, &clustered), replacement = newCreationContext(db, &clustered);
    previous.nodeId = 1;
    replacement.nodeId = 2;
    previous.regionOwnerAround = (uint, Position, float) => ushort(1);
    replacement.regionOwnerAround = (uint, Position, float) => ushort(2);
    auto now = MonoTime.currTime;
    auto later = now;
    previous.clock = () => now;
    replacement.clock = () => later;
    Sent[] sent;
    alias WS = BattlegroundType.warsongGulch;
    auto original = testQueue(now, sent);
    auto first = BattlegroundQueueHost(original, null, true, previous);
    foreach (ref request; [BattlegroundJoin(1, 1, 0, 60, WS, 0), BattlegroundJoin(2, 3, 0, 60, WS, 0),
        BattlegroundJoin(3, 3, 1, 60, WS, 0), BattlegroundJoin(4, 4, 1, 60, WS, 0)])
        first.join(request);
    const port = BattlegroundPort(3, 3, WS, true);
    const accepted = first.port(port);
    assert(accepted.enter && accepted.team == 1);

    later += 20.seconds;
    auto recovered = testQueue(later, sent);
    auto second = BattlegroundQueueHost(recovered, null, true, replacement);
    const retried = second.port(port);
    assert(retried == accepted && recovered.copies[accepted.instance].invited == [2, 2]);
    sent = null;
    recovered.status(4, 4);
    assert(sent.length == queueSlots);
    auto invitations = sent.find!(p => p.status == BattlegroundStatus.waitJoin);
    assert(invitations.length);
    auto invite = ByteReader(invitations[0].body_);
    invite.skip(17);
    const remaining = invite.read!uint;
    assert(remaining >= 59_000 && remaining <= 61_000, "outage time counts against the invitation");
    later += 5.seconds;
    second.tick(5.seconds);
    assert(recovered.ticketsOf(1).length, "keep the invitation through the gateway's recovery window");
    const rest = recovered.nodeLossGrace - 5.seconds;
    later += rest;
    second.tick(rest);
    assert(!recovered.ticketsOf(1).length && recovered.ticketsOf(2)[0].instance == accepted.instance);
    assert(recovered.copies[accepted.instance].invited == [1, 2]);
}

/// A map grant closes lost battles and preserves restored copies and unused invitations.
unittest
{
    import dmangos.world.testclient : newCreationContext, newDatabase;

    auto now = MonoTime.currTime;
    Sent[] sent;
    auto world = newCreationContext(newDatabase());
    ulong epoch = 10;
    world.battlegroundMapEpoch = (uint map) => map == battlegroundMaps[BattlegroundType.warsongGulch] ? epoch : 0UL;
    auto original = testQueue(now, sent);
    auto host = BattlegroundQueueHost(original, null, true, world);
    enum type = BattlegroundType.warsongGulch;
    uint make(uint player, ubyte level)
    {
        original.join(player, 1, 0, level, type, 0);
        original.forceStart();
        return original.ticketsOf(player)[0].instance;
    }
    const lost = make(1, 20), drained = make(2, 40), unused = make(3, 60);
    foreach (ref status; [BattlegroundChanged(lost, BattlegroundStatus.waitJoin, epoch),
        BattlegroundChanged(drained, BattlegroundStatus.inProgress, epoch)])
        host.changed(status);
    assert(original.port(1, 1, type, true).requiresLiveCopy);

    ++epoch;
    auto recovered = testQueue(now, sent);
    auto successor = BattlegroundQueueHost(recovered, original.saveState(), true, world);
    const map = battlegroundMaps[type];
    const staleReport = BattlegroundMapRecovered(map, epoch - 1);
    assert(!successor.mapRecovered(staleReport).received);
    auto newest = BattlegroundChanged(unused, BattlegroundStatus.inProgress, epoch - 1);
    host.changed(newest);
    assert(original.copies[unused].status == BattlegroundStatus.waitJoin);
    const report = BattlegroundMapRecovered(map, epoch, [BattlegroundChanged(drained, BattlegroundStatus.inProgress)]);
    assert(successor.mapRecovered(report).received);
    assert(lost !in recovered.copies && !recovered.ticketsOf(1).length);
    assert(recovered.copies[drained].mapEpoch == epoch);
    assert(recovered.ticketsOf(2)[0].instance == drained);
    assert(recovered.port(3, 1, type, true) == BattlegroundQueue.Entry(true, unused, 0, type, false));
    newest.mapEpoch = epoch;
    successor.changed(newest);

    auto movedAgain = testQueue(now, sent);
    auto finalHost = BattlegroundQueueHost(movedAgain, recovered.saveState(), true, world);
    assert(finalHost.mapRecovered(report).received);
    assert(movedAgain.copies[unused].status == BattlegroundStatus.inProgress,
        "a retried report from the same grant leaves new live copies alone after a queue move");
}

// The battlemaster's list: the copies of the player's bracket, by the numbers players see.
unittest
{
    import dmangos.bytes : ByteReader;

    auto now = MonoTime.currTime;
    Sent[] sent;
    auto q = testQueue(now, sent);
    q.testing = true;
    q.join(1, 1, 0, 60, BattlegroundType.warsongGulch, 0);
    q.port(1, 1, BattlegroundType.warsongGulch, true);
    sent = null;
    q.list(9, 1, 0xF130_0000_0000_0001, BattlegroundType.warsongGulch, 60);
    auto r = ByteReader(sent[0].body_);
    assert(sent[0].opcode == Opcode.SMSG_BATTLEFIELD_LIST);
    assert(r.read!ulong == 0xF130_0000_0000_0001 && r.read!uint == 489 && r.read!ubyte == 0);
    assert(r.read!uint == 1 && r.read!uint == 1);
    sent = null;
    q.list(9, 1, 0, BattlegroundType.warsongGulch, 15);
    assert(ByteReader(sent[0].body_[13 .. $]).read!uint == 0, "none in the 10-19 bracket");
}

/// Recover the running copy and keep unused invites when the queue is restored first.
unittest
{
    auto now = MonoTime.currTime;
    Sent[] sent;
    auto queue = testQueue(now, sent);
    enum type = BattlegroundType.warsongGulch;
    queue.join(10, 1, 0, 20, type, 0);
    queue.forceStart();
    const played = queue.port(10, 1, type, true);
    assert(played.enter);
    queue.changed(played.instance, BattlegroundStatus.inProgress);
    queue.join(20, 1, 0, 40, type, 0);
    queue.forceStart();
    const invited = queue.ticketsOf(20)[0].instance;
    assert(invited && invited != played.instance);

    auto recovered = testQueue(now, sent);
    recovered.restoreState(queue.saveState(), 12.seconds);
    recovered.reconcileMap(type, 2, [BattlegroundChanged(played.instance, BattlegroundStatus.inProgress, 2)]);
    assert(recovered.ticketsOf(10)[0].instance == played.instance && played.instance in recovered.copies);
    const entry = recovered.port(20, 1, type, true);
    assert(entry.enter && entry.instance == invited);
}
