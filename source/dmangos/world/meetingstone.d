/**
 * Meeting stones (1.12's looking for group): at a dungeon's stone a player, or a party's leader, joins the
 * queue for its area; the server fills parties with what they lack and forms new ones from players who wait.
 *
 * The rules (as vmangos has them; Blizzard's were never published):
 * $(UL
 *   $(LI Each player can fill some of three roles, by class (`rolesOf`): a tank, a healer, damage. A party
 *        of five takes a tank, a healer and three dealing damage; a party that queues has the roles its
 *        members already fill taken (`MeetingStoneQueue.fillRoles`).)
 *   $(LI Once a second (`MeetingStoneQueue.update`): the parties waiting take the players of their area
 *        and faction whose roles they still need, the best suited first (`priorityOf`), then who has waited
 *        longest; after 30 minutes a player is ahead of the newer ones. A party filled to five is complete.
 *        Five players waiting for one area, and none of them taken, make a new party of the first two, which
 *        then waits like any other. A party still waiting is told so every five minutes.)
 *   $(LI A player alone who logs out keeps its place (`offline`, as vmangos's `LFGQueue` keeps it): it is
 *        matched with nobody while away, and back in the world (its stone window asks, `CMSG_MEETINGSTONE_INFO`)
 *        it waits again, its time waited kept. A party's place is the group's, which stays.)
 * )
 *
 * Roles are by class alone. The 1.12 client has no role to choose and the queue no talents to look at: vmangos
 * reads talents only behind its own `LFG.Matchmaking` option, off by default, which Blizzard never described.
 *
 * The queue here is plain data with no world in it: what it decides comes back as `QueueEvent`s, which the
 * group service (`dmangos.world.groupservice`, on the coordinator in a cluster) carries out on the groups
 * and tells the players.
 */
module dmangos.world.meetingstone;

import std.sumtype : SumType;

import dmangos.world.opcodes : Opcode;
import dmangos.world.packets : ServerPacket;

/// The roles a player can fill, as bits.
enum Role : ubyte
{
    none = 0,
    tank = 1,
    healer = 2,
    damage = 4,
}

/// The order the queue looks at roles in.
immutable Role[3] roleOrder = [Role.tank, Role.healer, Role.damage];

/// How well a class fills a role (`priorityOf`): of two who wait for the role, the higher goes first.
enum Priority : ubyte
{
    none,
    low,
    normal,
    high,
}

/// `SMSG_MEETINGSTONE_SETQUEUE`'s status.
enum QueueStatus : ubyte
{
    leftQueue = 0,
    joinedQueue = 1,
    memberLeftQueue = 2,          /// a party member left: the party waits on without it
    removedFromParty = 3,         /// removed from the party: back in the queue alone
    lookingForNewParty = 4,
    none = 5,                     /// not in the queue (the stone's window shows nothing)
}

/// `SMSG_MEETINGSTONE_JOINFAILED`'s reason.
enum JoinFailure : ubyte
{
    notPartyLeader = 1,
    partyFull = 2,
    raid = 3,
}

/// A party has room for this many dealing damage.
enum uint damageSlots = 3;
/// A party is complete at this many.
enum uint partySize = 5;
/// Waited this long, a player goes before those who came later, whatever their class.
enum long longWaitMs = 30 * 60 * 1000;
/// A party still waiting is told so this often.
enum long stillLookingMs = 5 * 60 * 1000;

private enum ubyte classWarrior = 1, classPaladin = 2, classHunter = 3, classRogue = 4, classPriest = 5,
    classShaman = 7, classMage = 8, classWarlock = 9, classDruid = 11;

/// The roles a class can fill.
Role rolesOf(ubyte classId) pure nothrow @nogc @safe
{
    switch (classId)
    {
    case classDruid, classPaladin: return cast(Role)(Role.tank | Role.damage | Role.healer);
    case classPriest, classShaman: return cast(Role)(Role.damage | Role.healer);
    case classWarrior: return cast(Role)(Role.tank | Role.damage);
    case classHunter, classMage, classRogue, classWarlock: return Role.damage;
    default: return Role.none;
    }
}

/// How well `classId` fills `role`.
Priority priorityOf(ubyte classId, Role role) pure nothrow @nogc @safe
{
    final switch (role)
    {
    case Role.none:
        return Priority.none;
    case Role.tank:
        return classId == classWarrior ? Priority.high
            : classId == classDruid || classId == classPaladin ? Priority.normal : Priority.none;
    case Role.healer:
        return classId == classDruid || classId == classPaladin || classId == classPriest || classId == classShaman
            ? Priority.high : Priority.none;
    case Role.damage:
        switch (classId)
        {
        case classHunter, classMage, classRogue, classWarlock: return Priority.high;
        case classDruid, classPaladin, classShaman, classWarrior: return Priority.normal;
        case classPriest: return Priority.low;
        default: return Priority.none;
        }
    }
}

/// A player waiting alone.
struct QueuedPlayer
{
    ulong guid;
    string name;
    ubyte classId;
    uint team;        /// its faction (`Team`): parties are of one
    uint area;        /// the stone's area (`GAMEOBJECT` data 2)
    long waitedMs;
}

/// A party waiting for members.
struct QueuedParty
{
    uint group;       /// `Group.id`
    ulong leader;     /// a new leader takes the party out of the queue
    uint team;
    uint area;
    Role open = cast(Role)(Role.tank | Role.healer | Role.damage); /// the roles it still takes
    uint damageTaken; /// of `damageSlots`
    uint members;
    long untilStillLooking = stillLookingMs;
}

/// A player joins a waiting party.
struct Joins
{
    uint group;
    ulong player;
    string name;
}

/// Two waiting players make a new party, the first its leader; it then waits as any party does.
struct Forms
{
    ulong leader;
    string leaderName;
    ulong member;
    string memberName;
    uint team;
    uint area;
}

/// A party is complete: it leaves the queue.
struct Completes
{
    uint group;
}

/// A party still waits (every `stillLookingMs`).
struct StillLooking
{
    uint group;
}

/// What the queue decided, for the group service to carry out.
alias QueueEvent = SumType!(Joins, Forms, Completes, StillLooking);

/// See the module documentation.
struct MeetingStoneQueue
{
    QueuedPlayer[] players; /// in the order they came
    QueuedParty[] parties;  /// ditto
    QueuedPlayer[] offline; /// players alone who logged out while waiting, their places kept

    /// The waiting player `guid`, or null.
    inout(QueuedPlayer)* player(ulong guid) inout pure nothrow @nogc @safe
    {
        foreach (i, ref p; players)
            if (p.guid == guid)
                return &players[i];
        return null;
    }

    /// The waiting party of group `id`, or null.
    inout(QueuedParty)* party(uint id) inout pure nothrow @nogc @safe
    {
        foreach (i, ref p; parties)
            if (p.group == id)
                return &parties[i];
        return null;
    }

    /// Takes a player out; whether it was waiting.
    bool removePlayer(ulong guid) pure nothrow @safe
    {
        foreach (i, ref p; players)
            if (p.guid == guid)
            {
                players = players[0 .. i] ~ players[i + 1 .. $];
                return true;
            }
        return false;
    }

    /// A waiting player logs out: its place is kept (`offline`), and nothing matches it; whether it was waiting.
    bool setOffline(ulong guid) pure nothrow @safe
    {
        foreach (i, ref p; players)
            if (p.guid == guid)
            {
                offline ~= p;
                players = players[0 .. i] ~ players[i + 1 .. $];
                return true;
            }
        return false;
    }

    /// A player back in the world (`RestoreOfflinePlayer`): it waits again where it waited; its area, or 0.
    uint restore(ulong guid) pure nothrow @safe
    {
        foreach (i, ref p; offline)
            if (p.guid == guid)
            {
                const area = p.area;
                players ~= p;
                offline = offline[0 .. i] ~ offline[i + 1 .. $];
                return area;
            }
        return 0;
    }

    /// Forgets a player who logged out (it joined a group meanwhile, or asked to leave); whether it had a place.
    bool forgetOffline(ulong guid) pure nothrow @safe
    {
        foreach (i, ref p; offline)
            if (p.guid == guid)
            {
                offline = offline[0 .. i] ~ offline[i + 1 .. $];
                return true;
            }
        return false;
    }

    /// Takes a party out; whether it was waiting.
    bool removeParty(uint id) pure nothrow @safe
    {
        foreach (i, ref p; parties)
            if (p.group == id)
            {
                parties = parties[0 .. i] ~ parties[i + 1 .. $];
                return true;
            }
        return false;
    }

    /**
     * The roles a party still takes, from its members' classes: each member fills the first role it can
     * (tank, then healer, then damage) unless another member, not yet placed, fills it better.
     */
    static void fillRoles(ref QueuedParty party, const(ubyte)[] memberClasses) pure nothrow @safe
    {
        party.open = cast(Role)(Role.tank | Role.healer | Role.damage);
        party.damageTaken = 0;
        party.members = cast(uint) memberClasses.length;
        auto placed = new bool[memberClasses.length];
        foreach (i, c; memberClasses)
            foreach (role; roleOrder)
            {
                if (!(rolesOf(c) & role) || !(party.open & role))
                    continue;
                bool better;
                foreach (j, other; memberClasses)
                    if (j != i && !placed[j] && priorityOf(c, role) < priorityOf(other, role))
                        better = true;
                if (better)
                    continue;
                take(party, role);
                placed[i] = true;
                break;
            }
    }

    /// Time passes: see the module documentation.
    QueueEvent[] update(long elapsedMs)
    {
        QueueEvent[] events;
        foreach (ref p; players)
            p.waitedMs += elapsedMs;
        foreach (partyIndex; 0 .. parties.length)
        {
            auto party = &parties[partyIndex];
            for (size_t i = 0; i < players.length && party.members < partySize;)
            {
                const candidate = players[i];
                bool joined;
                if (candidate.team == party.team && candidate.area == party.area)
                    foreach (role; roleOrder)
                        if ((rolesOf(candidate.classId) & role) && (party.open & role) && firstFor(candidate, role))
                        {
                            take(*party, role);
                            ++party.members;
                            events ~= QueueEvent(Joins(party.group, candidate.guid, candidate.name));
                            removePlayer(candidate.guid);
                            joined = true;
                            break;
                        }
                if (!joined)
                    ++i;
            }
            if (party.members >= partySize)
            {
                // Complete: out of the queue. One party completes an update (the list just changed).
                events ~= QueueEvent(Completes(party.group));
                removeParty(party.group);
                break;
            }
            party.untilStillLooking -= elapsedMs;
            if (party.untilStillLooking <= 0)
            {
                party.untilStillLooking = stillLookingMs;
                events ~= QueueEvent(StillLooking(party.group));
            }
        }
        // Enough waiting alone for one area: the first two make a party.
        if (players.length >= partySize)
        {
            const leader = players[0];
            QueuedPlayer[] sameArea;
            foreach (p; players[1 .. $])
                if (p.area == leader.area && p.team == leader.team)
                    sameArea ~= p;
            if (sameArea.length >= partySize - 1)
            {
                const member = sameArea[0];
                removePlayer(leader.guid);
                removePlayer(member.guid);
                events ~= QueueEvent(Forms(leader.guid, leader.name, member.guid, member.name, leader.team, leader.area));
            }
        }
        return events;
    }

private:
    // `who` may take `role` now: no one else waiting for the area fills it better, nor waited longer while
    // `who` has not waited long (or both have, and the other longer).
    bool firstFor(const QueuedPlayer who, Role role) const pure nothrow @nogc @safe
    {
        const mine = priorityOf(who.classId, role);
        const waitedLong = who.waitedMs >= longWaitMs;
        foreach (ref other; players)
        {
            if (other.guid == who.guid || other.area != who.area || other.team != who.team)
                continue;
            if (!(rolesOf(other.classId) & role))
                continue;
            if (priorityOf(other.classId, role) > mine)
                return false;
            const longer = other.waitedMs > who.waitedMs;
            if (longer && (other.waitedMs >= longWaitMs || !waitedLong))
                return false;
        }
        return true;
    }

    static void take(ref QueuedParty party, Role role) pure nothrow @nogc @safe
    {
        if (role == Role.damage)
        {
            if (party.damageTaken < damageSlots && ++party.damageTaken >= damageSlots)
                party.open = cast(Role)(party.open & ~Role.damage);
        }
        else
            party.open = cast(Role)(party.open & ~role);
    }
}

/// `SMSG_MEETINGSTONE_SETQUEUE`: the stone's window: the area waited for (0: none) and how it stands.
struct ServerMeetingStoneSetQueue
{
    mixin ServerPacket!(Opcode.SMSG_MEETINGSTONE_SETQUEUE);
    uint area;
    QueueStatus status;
}

/// `SMSG_MEETINGSTONE_JOINFAILED`
struct ServerMeetingStoneJoinFailed
{
    mixin ServerPacket!(Opcode.SMSG_MEETINGSTONE_JOINFAILED);
    JoinFailure reason;
}

/// `SMSG_MEETINGSTONE_MEMBER_ADDED`: a player joined the party through the stone.
struct ServerMeetingStoneMemberAdded
{
    mixin ServerPacket!(Opcode.SMSG_MEETINGSTONE_MEMBER_ADDED);
    ulong player;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

private enum uint alliance = 469, area = 1581; // the Deadmines

private QueuedPlayer waiting(ulong guid, ubyte classId, long waitedMs = 0)
{
    import std.conv : text;

    return QueuedPlayer(guid, text("P", guid), classId, alliance, area, waitedMs);
}

// Roles and how well each class fills them.
@safe unittest
{
    assert(rolesOf(classWarrior) == (Role.tank | Role.damage) && rolesOf(classMage) == Role.damage);
    assert(priorityOf(classWarrior, Role.tank) == Priority.high && priorityOf(classPaladin, Role.tank) == Priority.normal);
    assert(priorityOf(classPriest, Role.damage) == Priority.low && priorityOf(classPriest, Role.healer) == Priority.high);
    assert(priorityOf(classMage, Role.tank) == Priority.none);
}

// A party's members take their roles; what it lacks stays open.
@safe unittest
{
    QueuedParty party;
    MeetingStoneQueue.fillRoles(party, [classWarrior, classMage]);
    assert(party.open == (Role.healer | Role.damage) && party.damageTaken == 1 && party.members == 2);
    MeetingStoneQueue.fillRoles(party, [classPaladin, classWarrior]);
    assert(!(party.open & Role.tank) && !(party.open & Role.healer), "the warrior tanks, so the paladin heals");
}

// A party takes the healer it lacks before another damage dealer; full, it completes.
unittest
{
    import std.algorithm.searching : canFind;
    import std.sumtype : match;

    MeetingStoneQueue q;
    QueuedParty party = QueuedParty(7, 100, alliance, area);
    MeetingStoneQueue.fillRoles(party, [classWarrior, classMage, classRogue]);
    q.parties = [party];
    q.players = [waiting(1, classHunter), waiting(2, classPriest), waiting(3, classWarlock)];
    const events = q.update(1000);
    ulong[] joined;
    bool complete;
    foreach (e; events)
        e.match!((Joins j) { joined ~= j.player; }, (Completes c) { complete = c.group == 7; }, (_) {});
    assert(joined.canFind(2), "the priest heals");
    assert(joined.length == 2 && complete, "and one damage slot was left: five, complete");
    assert(q.parties.length == 0 && q.players.length == 1);
}

// The best suited takes a role: of a paladin (who waited longer) and a warrior, the warrior tanks and the paladin
// deals damage.
unittest
{
    MeetingStoneQueue q;
    auto party = QueuedParty(7, 100, alliance, area);
    MeetingStoneQueue.fillRoles(party, [classPriest]);
    q.parties = [party];
    q.players = [waiting(1, classPaladin, 5000), waiting(2, classWarrior)];
    q.update(1000);
    assert(q.players.length == 0);
    const p = q.party(7);
    assert(p.members == 3 && !(p.open & Role.tank) && p.damageTaken == 1);
}

// Five alone for one area: the first two make a party; another faction or area does not count.
unittest
{
    import std.sumtype : match;

    MeetingStoneQueue q;
    q.players = [waiting(1, classMage), waiting(2, classRogue), waiting(3, classHunter), waiting(4, classWarlock)];
    auto horde = waiting(5, classMage);
    horde.team = 67;
    q.players ~= horde;
    assert(q.update(1000).length == 0, "one of the five is of the other faction");
    q.players ~= waiting(6, classPriest);
    Forms formed;
    foreach (e; q.update(1000))
        e.match!((Forms f) { formed = f; }, (_) {});
    assert(formed.leader == 1 && formed.member == 2 && formed.area == area);
    assert(q.player(1) is null && q.player(2) is null && q.players.length == 4);
}

// A party waiting is told so every five minutes.
unittest
{
    import std.sumtype : match;

    MeetingStoneQueue q;
    q.parties = [QueuedParty(7, 100, alliance, area)];
    size_t told;
    foreach (minute; 0 .. 11)
        foreach (e; q.update(60_000))
            e.match!((StillLooking s) { ++told; }, (_) {});
    assert(told == 2);
}
