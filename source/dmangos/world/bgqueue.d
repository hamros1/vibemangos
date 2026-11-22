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
    }

    private
    {
        Ticket[queueSlots][ulong] tickets;
        ushort[ulong] nodes;
        Waiting[][2][bracketCount][4] waiting; // [type][bracket][team]
        Running[uint] running;
        uint[waitSamples][bracketCount][2][4] waitTimes; // [type][team][bracket]
        uint[bracketCount][2][4] waitNext;
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
        typeof(waitTimes) waitTimes_;
        typeof(waitNext) waitNext_;
        bool testing;
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
            player.node = nodes.get(guid, 0);
            foreach (i, ref slot; slots)
                player.slots[i] = SavedTicket(slot.type, slot.stage, slot.instance,
                    slot.group is null ? 0 : groupIds[slot.group]);
            state.players ~= player;
        }
        foreach (ref copy; running)
            state.copies ~= SavedCopy(copy.instance, copy.type, copy.bracket, copy.clientId, copy.invited,
                copy.status, (copy.made - now).total!"hnsecs");
        state.waitTimes_ = waitTimes;
        state.waitNext_ = waitNext;
        state.testing = testing;
        ubyte[] bytes;
        encode(bytes, state);
        return bytes;
    }

    /// Restore a fresh queue using this node's clock, templates and callbacks.
    private void restoreState(const(ubyte)[] bytes)
    {
        import dmangos.plaindata : decode;

        if (!bytes.length)
            return;
        SavedQueue state;
        decode(bytes, state);
        const now = clock();
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
                slots[i] = Ticket(slot.type, slot.stage, slot.instance, groups[slot.group]);
            tickets[player.guid] = slots;
            nodes[player.guid] = player.node;
        }
        foreach (ref copy; state.copies)
            running[copy.instance] = Running(copy.instance, copy.type, copy.bracket, copy.clientId, copy.invited,
                copy.status, now + copy.made.hnsecs);
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
        foreach (i, ref s; *(&tickets[guid]))
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
        *ticket = Ticket(type, Stage.inside, copy.instance, null);
        send(guid, battlefieldStatus(slot, type, copy.clientId, BattlegroundStatus.inProgress, 0,
            sinceMs(copy.made)));
        return Entry(true, copy.instance, team, type);
    }

    /// The client asks for its queues: every slot's state, sent again.
    void status(ulong guid, ushort node)
    {
        nodes[guid] = node;
        auto mine = guid in tickets;
        if (mine is null)
            return;
        const now = clock();
        foreach (i, ref t; *mine)
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
                if (auto copy = t.instance in running)
                    send(guid, battlefieldStatus(cast(uint) i, t.type, copy.clientId, BattlegroundStatus.inProgress,
                        0, sinceMs(copy.made)));
                break;
            }
        }
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
    void changed(uint instance, BattlegroundStatus status)
    {
        auto copy = instance in running;
        if (copy is null)
            return;
        if (status == BattlegroundStatus.none)
        {
            running.remove(instance);
            return;
        }
        copy.status = status;
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
    }

private:
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
    void leaveQueue(ulong guid, int slot, bool tell)
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
            send(guid, battlefieldStatus(slot, type, 0, BattlegroundStatus.none));
        if (g !is null)
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

/// The queues as a cluster service: on the node the cluster places it on.
@Service(ServiceKind.battlegroundQueue)
struct BattlegroundQueueHost
{
    BattlegroundQueue queue;

    bool clockOwner = true;

    this(BattlegroundQueue queue, const(ubyte)[] state, bool clockOwner = true)
    {
        this.queue = queue;
        this.clockOwner = clockOwner;
        if (clockOwner) queue.restoreState(state);
    }

    ubyte[] saveState() const
    {
        return queue.saveState();
    }

    ///
    @Call void join(const ref BattlegroundJoin r)
    {
        queue.join(r.guid, r.node, r.team, r.level, cast(BattlegroundType) r.type, r.desired);
    }

    ///
    @Call BattlegroundJoinResult joinGroup(const ref BattlegroundGroupJoin r)
    {
        return BattlegroundJoinResult(queue.joinGroup(r.players, r.nodes, r.team, r.level, cast(BattlegroundType) r.type,
            r.desired));
    }

    ///
    @Call BattlegroundEntry port(const ref BattlegroundPort r)
    {
        const e = queue.port(r.guid, r.node, cast(BattlegroundType) r.type, r.enter);
        return BattlegroundEntry(e.enter, e.instance, e.team, e.type);
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
    }

    ///
    @Call void changed(const ref BattlegroundChanged r)
    {
        queue.changed(r.instance, cast(BattlegroundStatus) r.status);
    }

    ///
    @Call BattlegroundInvited invited(const ref BattlegroundInstance r)
    {
        return BattlegroundInvited(queue.invited(r.instance));
    }

    ///
    @Call void forceStart(const ref BattlegroundInstance)
    {
        queue.forceStart();
    }

    void tick(Duration)
    {
        if (clockOwner) queue.tick();
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
    auto invite = ByteReader(sent[$ - 1].body_);
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
