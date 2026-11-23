/**
 * Parties and raids: the group registry, each group's members and settings,
 * and the group list and member stats the members are sent.
 *
 * `Groups` is the registry: every group by id, and which group each player
 * belongs to or is invited to. It loads the `groups` and `group_member` rows
 * at start-up, so an offline member keeps its place. A `Group` is one party
 * or raid. Its methods keep the database up to date and tell the members
 * online, through `GroupDirectory`, what changed.
 *
 * In a cluster (docs/CLUSTER.md) the coordinator's `Groups` is the
 * only one that changes; it tells its members on any node, and every other
 * node keeps a mirror of its groups (`mirror`) for what it decides itself:
 * who sees whose health, party chat, member stats.
 *
 * A group is created in two steps: the first invitation makes
 * a group that only has a leader and invitees (`isCreated` is false, `id` is
 * 0); it gets an id and rows when the first invitee accepts.
 */
module dmangos.world.group;

import std.algorithm.searching : count, countUntil;
import std.range : only;

import dmangos.bytes : ByteWriter;
import dmangos.log;
import dmangos.world.database : GroupMemberRecord, GroupRecord, WorldDatabase;
import dmangos.world.defines : Power;
import dmangos.world.objects : HighGuid, lowGuid, makeGuid;
import dmangos.world.online : OnlinePlayer;
import dmangos.cluster.protocol : GroupMemberState, GroupState;
import dmangos.world.opcodes : Opcode;
import dmangos.world.player : Player;
import dmangos.world.updatefields;

enum uint maxGroupSize = 5;  /// members of a party, or of a raid's sub-group
enum uint maxRaidSize = 40;  /// members of a raid
enum uint maxRaidSubGroups = maxRaidSize / maxGroupSize; /// sub-groups of a raid
enum uint targetIconCount = 8; /// target icons a group can place

/// A party or a raid.
enum GroupType : ubyte
{
    normal = 0,
    raid = 1,
}

/// How a group's loot is shared.
enum LootMethod : ubyte
{
    freeForAll = 0,
    roundRobin = 1,
    masterLoot = 2,
    groupLoot = 3,
    needBeforeGreed = 4,
}

/// How a member leaves a group.
enum RemoveMethod
{
    leave,
    kick,
}

/// Flags of a member in the group list and in member stats.
enum MemberStatus : ubyte
{
    offline = 0x00,
    online = 0x01,
    pvp = 0x02,
    dead = 0x04,
    ghost = 0x08,
    pvpFreeForAll = 0x10,
    zoneOut = 0x20,
    afk = 0x40,
    dnd = 0x80,
}

/// What an `SMSG_PARTY_MEMBER_STATS` carries.
enum GroupUpdate : uint
{
    none = 0,
    status = 0x00000001,
    currentHealth = 0x00000002,
    maxHealth = 0x00000004,
    powerType = 0x00000008,
    currentPower = 0x00000010,
    maxPower = 0x00000020,
    level = 0x00000040,
    zone = 0x00000080,
    position = 0x00000100,
    auras = 0x00000200,
    negativeAuras = 0x00000400,
    petGuid = 0x00000800,
    petName = 0x00001000,
    petModel = 0x00002000,
    petCurrentHealth = 0x00004000,
    petMaxHealth = 0x00008000,
    petPowerType = 0x00010000,
    petCurrentPower = 0x00020000,
    petMaxPower = 0x00040000,
    petAuras = 0x00080000,
    petNegativeAuras = 0x00100000,
    pet = 0x001FF800,  /// every pet flag
    full = 0x001FFFFF, /// every flag
}

private enum : uint
{
    playerFlagsAfk = 0x02,
    playerFlagsDnd = 0x04,
}

/// A member's status flags: online, away, busy, between maps. There is no PvP or death yet.
ubyte memberStatus(const OnlinePlayer member)
{
    if (member is null)
        return MemberStatus.offline;
    ubyte flags = MemberStatus.online;
    const playerFlags = member.character.values.get!PLAYER_FLAGS;
    if (member.transferring)
        flags |= MemberStatus.zoneOut;
    if (playerFlags & playerFlagsAfk)
        flags |= MemberStatus.afk;
    if (playerFlags & playerFlagsDnd)
        flags |= MemberStatus.dnd;
    return flags;
}

/**
 * The `SMSG_PARTY_MEMBER_STATS` body for the
 * fields in `mask`. Players have no pets or auras yet, so those parts are empty.
 */
ubyte[] partyMemberStats(const Player player, uint mask, ubyte status)
{
    if (mask & GroupUpdate.powerType)
        mask |= GroupUpdate.currentPower | GroupUpdate.maxPower;
    if (mask & GroupUpdate.petPowerType)
        mask |= GroupUpdate.petCurrentPower | GroupUpdate.petMaxPower;

    ByteWriter w;
    w.putPackedGuid(player.guid);
    w.put(mask);
    const power = player.powerType;
    if (mask & GroupUpdate.status)
        w.put(status);
    if (mask & GroupUpdate.currentHealth)
        w.put(cast(ushort) player.values.get!UNIT_FIELD_HEALTH);
    if (mask & GroupUpdate.maxHealth)
        w.put(cast(ushort) player.values.get!UNIT_FIELD_MAXHEALTH);
    if (mask & GroupUpdate.powerType)
        w.put(cast(ubyte) power);
    if (mask & GroupUpdate.currentPower)
        w.put(cast(ushort) player.values.get!UNIT_FIELD_POWER1(power));
    if (mask & GroupUpdate.maxPower)
        w.put(cast(ushort) player.values.get!UNIT_FIELD_MAXPOWER1(power));
    if (mask & GroupUpdate.level)
        w.put(cast(ushort) player.values.get!UNIT_FIELD_LEVEL);
    if (mask & GroupUpdate.zone)
        w.put(cast(ushort) player.data.zone);
    if (mask & GroupUpdate.position)
    {
        w.put(cast(short) player.position.x);
        w.put(cast(short) player.position.y);
    }
    if (mask & GroupUpdate.auras)
        w.put(uint(0));
    if (mask & GroupUpdate.negativeAuras)
        w.put(ushort(0));
    if (mask & GroupUpdate.petGuid)
        w.put(ulong(0));
    if (mask & GroupUpdate.petName)
        w.put(ubyte(0));
    if (mask & GroupUpdate.petModel)
        w.put(ushort(0));
    if (mask & GroupUpdate.petCurrentHealth)
        w.put(ushort(0));
    if (mask & GroupUpdate.petMaxHealth)
        w.put(ushort(0));
    if (mask & GroupUpdate.petPowerType)
        w.put(ubyte(0));
    if (mask & GroupUpdate.petCurrentPower)
        w.put(ushort(0));
    if (mask & GroupUpdate.petMaxPower)
        w.put(ushort(0));
    if (mask & GroupUpdate.petAuras)
        w.put(uint(0));
    if (mask & GroupUpdate.petNegativeAuras)
        w.put(ushort(0));
    return w.data.dup;
}

/**
 * The `SMSG_PARTY_MEMBER_STATS_FULL` body, the answer to a request for a member's stats.
 * `player` is null for a member who is offline.
 */
ubyte[] partyMemberStatsFull(ulong guid, const Player player, ubyte status)
{
    ByteWriter w;
    w.putPackedGuid(guid);
    if (player is null)
    {
        w.put(uint(GroupUpdate.status));
        w.put(ubyte(MemberStatus.offline));
        return w.data.dup;
    }
    const power = player.powerType;
    w.put(uint(GroupUpdate.full & ~GroupUpdate.pet));
    w.put(status);
    w.put(cast(ushort) player.values.get!UNIT_FIELD_HEALTH);
    w.put(cast(ushort) player.values.get!UNIT_FIELD_MAXHEALTH);
    w.put(cast(ubyte) power);
    w.put(cast(ushort) player.values.get!UNIT_FIELD_POWER1(power));
    w.put(cast(ushort) player.values.get!UNIT_FIELD_MAXPOWER1(power));
    w.put(cast(ushort) player.values.get!UNIT_FIELD_LEVEL);
    w.put(cast(ushort) player.data.zone);
    w.put(cast(short) player.position.x);
    w.put(cast(short) player.position.y);
    w.put(uint(0));   // positive auras
    w.put(ushort(0)); // negative auras
    w.put(ubyte(0));  // a member without a pet ends with an empty pet name and aura mask
    w.put(uint(0));
    return w.data.dup;
}

/// Finds group members online, on this node or (in a cluster) another.
interface GroupDirectory
{
    /// The player, if this node simulates it; null otherwise.
    OnlinePlayer local(ulong guid);

    /// Sends a packet to a player online on any node; false if it is not online.
    bool deliverTo(ulong guid, Opcode opcode, const(ubyte)[] body_);

    /// The status flags of a player on any node; `MemberStatus.offline` if not online.
    ubyte statusOf(ulong guid);

    /// Whether two players see each other.
    bool seeEachOther(ulong a, ulong b);
}

/// One member of a group.
struct MemberSlot
{
    ulong guid;
    string name;
    ubyte subGroup;
    bool assistant;
}

/// See the module documentation.
final class Group
{
    uint id;                      /// 0 until created
    GroupType type;
    ulong leader;
    string leaderName;
    ulong mainTank;
    ulong mainAssistant;
    LootMethod lootMethod = LootMethod.groupLoot;
    ulong looter;                 /// the master looter
    ulong nextLooter;             /// `m_currentLooterGuid`: round robin's next turn
    ubyte lootThreshold = 2;      /// uncommon (green) quality
    ulong[targetIconCount] targetIcons;

    /// Chooses an eligible member in party order and advances to the next eligible member.
    ulong takeLootTurn(const(ulong)[] eligible, const(ulong)[] order = null)
    {
        import std.algorithm.searching : canFind;

        if (order is null)
            order = lootTurnOrder(null);
        if (!order.length)
            return 0;
        size_t start;
        foreach (i, guid; order)
            if (guid == nextLooter)
                start = i;
        ulong first;
        foreach (offset; 0 .. order.length)
        {
            const guid = order[(start + offset) % order.length];
            if (!eligible.canFind(guid))
                continue;
            if (first)
            {
                nextLooter = guid;
                return first;
            }
            first = guid;
        }
        return first;
    }

    /// Keep the recorded rotation across a reload, removing former members and appending new ones.
    package ulong[] lootTurnOrder(const(ulong)[] previous) const
    {
        import std.algorithm.searching : canFind;

        ulong[] order;
        foreach (guid; previous)
            if (isMember(guid))
                order ~= guid;
        foreach (ref slot; slots)
            if (!order.canFind(slot.guid))
                order ~= slot.guid;
        return order;
    }

    package @property bool persistentLootTurns() const
    {
        return owner.database !is null;
    }

    private
    {
        Groups owner;
        MemberSlot[] slots;
        string[ulong] invitees;  // guid -> name
    }

    invariant (slots.length <= maxRaidSize);

    private this(Groups owner)
    {
        this.owner = owner;
    }

    /// The members, in the order they joined.
    @property const(MemberSlot)[] members() const
    {
        return slots;
    }

    /// Whether the group exists yet: it has members, not only a leader and invitees.
    @property bool isCreated() const
    {
        return slots.length > 0;
    }

    /// Whether it is a raid.
    @property bool isRaid() const
    {
        return type == GroupType.raid;
    }

    /// Whether it has no room for another member.
    @property bool isFull() const
    {
        return slots.length >= (isRaid ? maxRaidSize : maxGroupSize);
    }

    /// Fewer members than this, and the group is disbanded.
    enum uint membersMinCount = 2;

    /// Whether `guid` is a member.
    bool isMember(ulong guid) const
    {
        return slotIndex(guid) >= 0;
    }

    /// Whether `guid` leads the group.
    bool isLeader(ulong guid) const
    {
        return leader == guid;
    }

    /// Whether `guid` is a member with the assistant flag.
    bool isAssistant(ulong guid) const
    {
        const i = slotIndex(guid);
        return i >= 0 && slots[i].assistant;
    }

    /// The member called `name` (exactly), or 0.
    ulong memberGuid(string name) const
    {
        foreach (ref slot; slots)
            if (slot.name == name)
                return slot.guid;
        return 0;
    }

    /// The sub-group of a member, or `maxRaidSubGroups + 1` for a stranger.
    ubyte subGroupOf(ulong guid) const
    {
        const i = slotIndex(guid);
        return i >= 0 ? slots[i].subGroup : maxRaidSubGroups + 1;
    }

    /// Whether a raid's sub-group has room for another member.
    bool hasFreeSlot(ubyte subGroup) const
    {
        return isRaid && subGroup < maxRaidSubGroups && countIn(subGroup) < maxGroupSize;
    }

    /// Whether the online player `guid` was invited and has not answered.
    bool isInvited(ulong guid) const
    {
        return (guid in invitees) !is null;
    }

    /// The invitee called `name`: its guid, or 0.
    ulong invitedGuid(string name) const
    {
        foreach (guid, invitee; invitees)
            if (invitee == name)
                return guid;
        return 0;
    }

    // -----------------------------------------------------------------------
    // Invitations
    // -----------------------------------------------------------------------

    /// Invites a player: false if the player is already invited somewhere or in a group.
    bool addInvite(ulong guid, string name)
    {
        if (owner.invitationOf(guid) !is null || owner.of(guid) !is null)
            return false;
        invitees[guid] = name;
        owner.invitedTo[guid] = this;
        return true;
    }

    /// Invites the leader of a group that is not created yet.
    bool addLeaderInvite(ulong guid, string name)
    {
        if (!addInvite(guid, name))
            return false;
        leader = guid;
        leaderName = name;
        return true;
    }

    /// Drops a player's invitation.
    void removeInvite(ulong guid)
    {
        invitees.remove(guid);
        if (auto group = guid in owner.invitedTo)
            if (*group is this)
                owner.invitedTo.remove(guid);
    }

    /// Drops every invitation.
    void removeAllInvites()
    {
        foreach (guid; invitees.keys)
            removeInvite(guid);
    }

    /// Number of invitations not yet answered.
    @property size_t inviteeCount() const
    {
        return invitees.length;
    }

    // -----------------------------------------------------------------------
    // Members
    // -----------------------------------------------------------------------

    /// Gives the group an id and its row, with the leader as its first member.
    void create()
    in (!isCreated && leader != 0)
    {
        id = owner.takeId();
        type = GroupType.normal;
        lootMethod = LootMethod.groupLoot;
        lootThreshold = 2;
        looter = leader;
        const row = record();
        if (owner.database !is null)
            owner.database.createGroup(row);
        owner.byId[id] = this;
        removeInvite(leader);
        addMember(leader, leaderName);
    }

    /// Adds a member: false if the group is full.
    bool addMember(ulong guid, string name)
    {
        if (isFull || guid == 0)
            return false;
        ubyte subGroup;
        if (isRaid)
        {
            while (subGroup < maxRaidSubGroups && countIn(subGroup) >= maxGroupSize)
                ++subGroup;
            if (subGroup == maxRaidSubGroups)
                return false;
        }
        const slot = MemberSlot(guid, name, subGroup, false);
        slots ~= slot;
        removeInvite(guid);
        owner.memberOf[guid] = this;
        if (!isRaid)
            targetIcons[] = 0;
        if (owner.database !is null)
            owner.database.addGroupMember(id, GroupMemberRecord(lowGuid(guid), name, false, subGroup));

        sendUpdate();
        if (auto player = owner.directory.local(guid))
        {
            player.groupChanged(); // both ways: what it sees of the members in sight, and they of it
            updatePlayerOutOfRange(player, GroupUpdate.full);
        }
        return true;
    }

    /**
     * Takes a member out, kicked or leaving. A group left with fewer than two
     * members is disbanded. Returns the number of members left.
     */
    size_t removeMember(ulong guid, RemoveMethod method)
    {
        if (slots.length <= membersMinCount)
        {
            disband(true);
            return 0;
        }
        const leaderChanged = removeSlot(guid);
        if (method == RemoveMethod.kick)
            owner.directory.deliverTo(guid, Opcode.SMSG_GROUP_UNINVITE, null);
        sendEmptyList(guid);
        if (auto player = owner.directory.local(guid))
            player.groupChanged();
        if (leaderChanged)
            broadcast(Opcode.SMSG_GROUP_SET_LEADER, cstring(leaderName));
        sendUpdate();
        return slots.length;
    }

    /// Makes member `guid` the leader, and tells the group.
    void changeLeader(ulong guid)
    {
        const i = slotIndex(guid);
        if (i < 0)
            return;
        setLeader(guid);
        broadcast(Opcode.SMSG_GROUP_SET_LEADER, cstring(slots[i].name));
        sendUpdate();
    }

    /// Disbands the group: every member is told, and the rows are deleted.
    void disband(bool hideDestroy = false)
    {
        auto former = slots;
        slots = null;
        foreach (ref slot; former)
        {
            owner.memberOf.remove(slot.guid);
            if (!hideDestroy)
                owner.directory.deliverTo(slot.guid, Opcode.SMSG_GROUP_DESTROYED, null);
            sendEmptyList(slot.guid);
            if (auto player = owner.directory.local(slot.guid))
                player.groupChanged();
        }
        removeAllInvites();
        if (id)
        {
            if (owner.database !is null)
                owner.database.deleteGroup(id);
            owner.byId.remove(id);
            if (owner.removed !is null)
                owner.removed(id);
        }
        leader = 0;
        leaderName = null;
    }

    /// Makes the party a raid.
    void convertToRaid()
    {
        type = GroupType.raid;
        save();
        sendUpdate();
    }

    /// Gives or takes a member's assistant flag: raids only.
    void setAssistant(ulong guid, bool state)
    {
        if (!isRaid)
            return;
        const i = slotIndex(guid);
        if (i < 0)
            return;
        slots[i].assistant = state;
        saveSlot(slots[i]);
        sendUpdate();
    }

    /// Moves a member to another sub-group: raids only.
    void changeSubGroup(ulong guid, ubyte subGroup)
    {
        if (!isRaid || subGroup >= maxRaidSubGroups)
            return;
        const i = slotIndex(guid);
        if (i < 0 || slots[i].subGroup == subGroup)
            return;
        slots[i].subGroup = subGroup;
        saveSlot(slots[i]);
        sendUpdate();
    }

    /// The loot settings: method, master looter and threshold together.
    void setLoot(LootMethod method, ulong master, ubyte threshold)
    {
        // The threshold "can be set to Uncommon, Rare, or Epic"; the master looter is a member (WoWWiki "Party",
        // 2006: "set by the party leader by right-clicking on any member's portrait"). Otherwise nothing changes.
        enum ubyte uncommon = 2, epic = 4;
        if (threshold < uncommon || threshold > epic || (method == LootMethod.masterLoot && !isMember(master)))
            return;
        lootMethod = method;
        looter = master;
        lootThreshold = threshold;
        save();
        sendUpdate();
    }

    /// An icon on a target; a target has one icon at most.
    void setTargetIcon(ubyte icon, ulong target)
    {
        if (icon >= targetIconCount)
            return;
        if (target)
            foreach (ubyte i, ref other; targetIcons)
                if (other == target)
                    setTargetIcon(i, 0);
        targetIcons[icon] = target;
        ByteWriter w;
        w.put(ubyte(0)); // one change
        w.put(icon);
        w.put(target);
        broadcast(Opcode.MSG_RAID_TARGET_UPDATE, w.data);
        changed();
    }

    /// Sends the target icons to member `to`.
    void sendTargetIconList(ulong to)
    {
        ByteWriter w;
        w.put(ubyte(1)); // the whole list
        foreach (ubyte i, target; targetIcons)
            if (target)
            {
                w.put(i);
                w.put(target);
            }
        owner.directory.deliverTo(to, Opcode.MSG_RAID_TARGET_UPDATE, w.data);
    }

    // -----------------------------------------------------------------------
    // Telling the members
    // -----------------------------------------------------------------------

    /// The group list, to every member online.
    void sendUpdate()
    {
        foreach (ref slot; slots)
            if (owner.directory.statusOf(slot.guid) != MemberStatus.offline)
                sendUpdateTo(slot.guid);
        changed();
    }

    /// The `SMSG_GROUP_LIST` a member sees, everyone but itself.
    void sendUpdateTo(ulong guid)
    {
        const self = slotIndex(guid);
        if (self < 0)
            return;
        ByteWriter w;
        w.put(cast(ubyte) type);
        w.put(flagsOf(slots[self]));
        w.put(cast(uint)(slots.length - 1));
        foreach (i, ref slot; slots)
        {
            if (i == self)
                continue;
            w.putCString(slot.name);
            w.put(slot.guid);
            w.put(owner.directory.statusOf(slot.guid));
            w.put(flagsOf(slot));
        }
        w.put(leader);
        if (slots.length > 1)
        {
            w.put(cast(ubyte) lootMethod);
            w.put(lootMethod == LootMethod.masterLoot ? looter : 0UL);
            w.put(lootThreshold);
        }
        owner.directory.deliverTo(guid, Opcode.SMSG_GROUP_LIST, w.data);
    }

    /**
     * A packet to every member online, or those of one sub-group, except
     * `except`.
     */
    void broadcast(Opcode opcode, const(ubyte)[] body_, int subGroup = -1, ulong except = 0)
    {
        foreach (ref slot; slots)
            if (slot.guid != except && (subGroup < 0 || slot.subGroup == subGroup))
                owner.directory.deliverTo(slot.guid, opcode, body_);
    }

    /**
     * Member stats to the members that do not see `player`; those
     * who see it get its fields instead.
     */
    void updatePlayerOutOfRange(OnlinePlayer player, uint mask)
    {
        if (mask == GroupUpdate.none)
            return;
        const guid = player.character.guid;
        const body_ = partyMemberStats(player.character, mask, memberStatus(player));
        foreach (ref slot; slots)
            if (slot.guid != guid && !owner.directory.seeEachOther(slot.guid, guid))
                owner.directory.deliverTo(slot.guid, Opcode.SMSG_PARTY_MEMBER_STATS, body_);
    }

    /// A member logged in or out.
    void updatePlayerOnlineStatus(OnlinePlayer player, bool online)
    {
        if (!isMember(player.character.guid))
            return;
        sendUpdate();
        if (online)
            updatePlayerOutOfRange(player, GroupUpdate.full);
    }

    /// The row this group is saved as.
    GroupRecord record() const
    {
        GroupRecord r;
        r.id = id;
        r.leader = lowGuid(leader);
        r.mainTank = lowGuid(mainTank);
        r.mainAssistant = lowGuid(mainAssistant);
        r.lootMethod = lootMethod;
        r.looter = lowGuid(looter);
        r.lootThreshold = lootThreshold;
        r.icons = targetIcons;
        r.isRaid = isRaid;
        return r;
    }

private:
    ptrdiff_t slotIndex(ulong guid) const
    {
        return slots.countUntil!(s => s.guid == guid);
    }

    size_t countIn(ubyte subGroup) const
    {
        return slots.count!(s => s.subGroup == subGroup);
    }

    static ubyte flagsOf(const ref MemberSlot slot)
    {
        return cast(ubyte)(slot.subGroup | (slot.assistant ? 0x80 : 0));
    }

    /// Removes a member's slot: true if the leader left, and a new one was chosen.
    bool removeSlot(ulong guid)
    {
        import std.algorithm.mutation : remove;

        owner.memberOf.remove(guid);
        slots = slots.remove!(s => s.guid == guid);
        if (owner.database !is null)
            owner.database.removeGroupMember(lowGuid(guid));
        if (leader != guid)
            return false;
        chooseLeader();
        return true;
    }

    /// A new leader: an online assistant in a raid, any online member in a party, else the first.
    void chooseLeader()
    {
        ulong first, chosen;
        foreach (ref slot; slots)
        {
            if (owner.directory.statusOf(slot.guid) == MemberStatus.offline)
                continue;
            if (isRaid && !slot.assistant)
            {
                if (first == 0)
                    first = slot.guid;
                continue;
            }
            chosen = slot.guid;
            break;
        }
        if (chosen == 0)
            chosen = first;
        if (chosen == 0 && slots.length)
            chosen = slots[0].guid;
        if (chosen)
            setLeader(chosen);
    }

    /// Sets the leader and saves it; the old and new leaders are told.
    void setLeader(ulong guid)
    {
        const i = slotIndex(guid);
        if (i < 0)
            return;
        const previous = leader;
        leader = guid;
        leaderName = slots[i].name;
        save();
        foreach (who; only(previous, guid))
            if (auto player = owner.directory.local(who))
                player.groupChanged(); // the leader flag moves
    }

    void save()
    {
        if (id && owner.database !is null)
        {
            const row = record();
            owner.database.updateGroup(row);
        }
    }

    void saveSlot(const ref MemberSlot slot)
    {
        if (owner.database !is null)
            owner.database.updateGroupMember(GroupMemberRecord(lowGuid(slot.guid), slot.name, slot.assistant,
            slot.subGroup));
    }

    void sendEmptyList(ulong guid)
    {
        const ubyte[24] empty = 0;
        owner.directory.deliverTo(guid, Opcode.SMSG_GROUP_LIST, empty[]);
    }

    /// A created group changed: other nodes' mirrors follow.
    void changed()
    {
        if (id && owner.changes !is null)
            owner.changes(this);
    }

    static const(ubyte)[] cstring(string text)
    {
        ByteWriter w;
        w.putCString(text);
        return w.data;
    }
}

/// One pending invitation, including the leader when the first accept will create the party.
package struct OpenGroupInvite
{
    uint group;
    ulong leader, recipient;
    string leaderName, recipientName;
}

/// See the module documentation.
final class Groups
{
    package
    {
        WorldDatabase database;
        GroupDirectory directory;
        uint nextId;
        uint delegate() idSource;  // a cluster member's group ids; null: `nextId`
        Group[uint] byId;
        Group[ulong] memberOf;   // player guid -> created group
        Group[ulong] invitedTo;  // player guid -> group it is invited to (or leads, before creation)
    }

    /// Optional match-only groups shared by the battlegroup hosts.
    Groups battlegroundRaids;
    private uint realmNamespace;

    /// In a cluster, on the coordinator: a group changed, or was disbanded (`stateOf`, for the mirrors).
    void delegate(const Group group) changes;
    void delegate(uint id) removed; /// ditto

    ///
    /// The next group id.
    uint takeId()
    {
        return idSource !is null ? idSource() : nextId++;
    }

    this(WorldDatabase database, GroupDirectory directory, uint nextId, uint realmNamespace = 0)
    in (directory !is null && nextId > 0)
    {
        this.database = database;
        this.directory = directory;
        this.nextId = nextId;
        this.realmNamespace = realmNamespace;
    }

    /// The groups loaded at start-up: one whose leader is gone is disbanded, members who are gone are removed.
    void load(GroupRecord[] records)
    {
        import dmangos.world.battlegroup : realmPlayerGuid;

        foreach (ref r; records)
        {
            auto group = new Group(this);
            group.id = r.id;
            if (r.leaderName is null)
            {
                warning!"group %s: its leader %s does not exist; disbanded"(r.id, r.leader);
                database.deleteGroup(r.id);
                continue;
            }
            group.type = r.isRaid ? GroupType.raid : GroupType.normal;
            group.leader = realmPlayerGuid(realmNamespace, r.leader);
            group.leaderName = r.leaderName;
            group.mainTank = r.mainTank ? realmPlayerGuid(realmNamespace, r.mainTank) : 0;
            group.mainAssistant = r.mainAssistant ? realmPlayerGuid(realmNamespace, r.mainAssistant) : 0;
            group.lootMethod = r.lootMethod <= LootMethod.max ? cast(LootMethod) r.lootMethod : LootMethod.groupLoot;
            group.looter = r.looter ? realmPlayerGuid(realmNamespace, r.looter) : 0;
            group.lootThreshold = r.lootThreshold;
            group.targetIcons = r.icons;
            foreach (m; r.members)
            {
                if (m.name is null)
                {
                    warning!"group %s: member %s does not exist; removed"(r.id, m.guid);
                    database.removeGroupMember(m.guid);
                    continue;
                }
                group.slots ~= MemberSlot(realmPlayerGuid(realmNamespace, m.guid), m.name,
                    m.subGroup < maxRaidSubGroups ? m.subGroup : 0, m.assistant);
            }
            if (group.slots.length < Group.membersMinCount)
            {
                database.deleteGroup(r.id);
                continue;
            }
            byId[group.id] = group;
            foreach (ref slot; group.slots)
                memberOf[slot.guid] = group;
            if (group.id >= nextId)
                nextId = group.id + 1;
        }
        info!"loaded %s groups"(byId.length);
    }

    /// The group the player belongs to, online or not, or null.
    Group of(ulong guid)
    {
        if (auto group = guid in memberOf)
            return *group;
        return battlegroundRaids is null ? null : battlegroundRaids.of(guid);
    }

    /// The group the player is invited to, or null.
    Group invitationOf(ulong guid)
    {
        return invitedTo.get(guid, null);
    }

    package OpenGroupInvite[] openInvitations()
    {
        import std.algorithm.sorting : sort;

        OpenGroupInvite[] result;
        foreach (recipient, group; invitedTo)
            if (group.isCreated || group.leader != recipient)
                result ~= OpenGroupInvite(group.id, group.leader, recipient, group.leaderName, group.invitees[recipient]);
        result.sort!((a, b) => a.recipient < b.recipient);
        return result;
    }

    package void restoreInvitation(const ref OpenGroupInvite invite)
    {
        if (!invite.leader || !invite.recipient || invite.leader == invite.recipient || of(invite.recipient) !is null)
            return;
        auto group = invite.group ? byId.get(invite.group, null) : of(invite.leader);
        if (!invite.group)
        {
            if (group !is null)
            {
                if (!group.isLeader(invite.leader) || group.id !in byId)
                    return;
            }
            else
            {
                group = invitationOf(invite.leader);
                if (group is null)
                {
                    group = newGroup();
                    if (!group.addLeaderInvite(invite.leader, invite.leaderName))
                        return;
                }
                else if (group.isCreated || !group.isLeader(invite.leader))
                    return;
            }
        }
        if (group !is null)
            group.addInvite(invite.recipient, invite.recipientName);
    }

    /// A group that is not created yet, for a first invitation.
    Group newGroup()
    {
        return new Group(this);
    }

    /// Number of groups that exist.
    @property size_t count() const
    {
        return byId.length;
    }

    /// Whether two players are in the same group.
    bool sameGroup(ulong a, ulong b) const
    {
        const first = a in memberOf, second = b in memberOf;
        if (first !is null || second !is null)
            return first !is null && second !is null && *first is *second;
        return battlegroundRaids !is null && battlegroundRaids.sameGroup(a, b);
    }

    // -----------------------------------------------------------------------
    // Mirrors
    // -----------------------------------------------------------------------

    /// A group as other nodes' mirrors get it.
    static GroupState stateOf(const Group g)
    {
        GroupState s;
        s.id = g.id;
        s.groupType = g.type;
        s.leader = g.leader;
        s.leaderName = g.leaderName;
        s.mainTank = g.mainTank;
        s.mainAssistant = g.mainAssistant;
        s.lootMethod = g.lootMethod;
        s.looter = g.looter;
        s.lootThreshold = g.lootThreshold;
        s.icons = g.targetIcons.dup;
        foreach (ref slot; g.slots)
            s.members ~= GroupMemberState(slot.guid, slot.name, slot.subGroup, slot.assistant);
        return s;
    }

    /// Every group, for a node that links.
    GroupState[] states()
    {
        GroupState[] all;
        foreach (g; byId)
            all ~= stateOf(g);
        return all;
    }

    /// Forgets every group: this node mirrors the coordinator's from now on.
    void clear()
    {
        byId = null;
        memberOf = null;
        invitedTo = null;
    }

    /// A complete baseline can supersede a disband a disconnected worker missed.
    void reconcileMirrors(const(uint)[] ids)
    {
        bool[uint] present;
        foreach (id; ids)
            present[id] = true;
        foreach (id; byId.keys)
        {
            auto group = byId[id];
            if (id in present)
            {
                foreach (ref slot; group.slots)
                    if (directory.local(slot.guid) !is null)
                        group.sendUpdateTo(slot.guid);
                continue;
            }
            GroupState gone;
            gone.id = id;
            gone.removed = true;
            mirror(gone);
        }
    }

    /**
     * The mirror of a group of the coordinator's (never saved here): its members here see each other
     * anew, and one that has just joined tells the members who do not see it how it is.
     */
    void mirror(const ref GroupState s)
    {
        import std.algorithm.searching : canFind;

        ulong[] before, after;
        auto group = byId.get(s.id, null);
        if (group !is null)
            foreach (ref slot; group.slots)
            {
                before ~= slot.guid;
                if (memberOf.get(slot.guid, null) is group)
                    memberOf.remove(slot.guid);
            }
        if (s.removed)
            byId.remove(s.id);
        else
        {
            if (group is null)
            {
                group = new Group(this);
                group.id = s.id;
                byId[s.id] = group;
            }
            group.type = s.groupType == GroupType.raid ? GroupType.raid : GroupType.normal;
            group.leader = s.leader;
            group.leaderName = s.leaderName;
            group.mainTank = s.mainTank;
            group.mainAssistant = s.mainAssistant;
            group.lootMethod = s.lootMethod <= LootMethod.max ? cast(LootMethod) s.lootMethod : LootMethod.groupLoot;
            group.looter = s.looter;
            group.lootThreshold = s.lootThreshold;
            group.targetIcons[] = 0;
            foreach (i, icon; s.icons[0 .. s.icons.length < targetIconCount ? s.icons.length : targetIconCount])
                group.targetIcons[i] = icon;
            group.slots = null;
            foreach (ref m; s.members[0 .. s.members.length < maxRaidSize ? s.members.length : maxRaidSize])
            {
                group.slots ~= MemberSlot(m.guid, m.name, m.subGroup, m.assistant);
                memberOf[m.guid] = group;
                after ~= m.guid;
            }
        }
        bool[ulong] seen;
        foreach (guid; before ~ after)
        {
            if (guid in seen)
                continue;
            seen[guid] = true;
            if (auto player = directory.local(guid))
            {
                player.groupChanged(); // its leader flag, and who sees its health
                if (guid !in memberOf && group !is null)
                    group.sendEmptyList(guid);
                if (!before.canFind(guid) && after.canFind(guid))
                    group.updatePlayerOutOfRange(player, GroupUpdate.full);
            }
        }
    }

    /// Drops a pending invitation, and the group if nobody is left in it.
    void uninvite(ulong guid)
    {
        auto group = invitationOf(guid);
        if (group is null)
            return;
        group.removeInvite(guid);
        if (group.isCreated)
        {
            if (group.slots.length < Group.membersMinCount)
                group.disband(true);
        }
        else if (group.isLeader(guid) || group.inviteeCount <= 1)
            group.removeAllInvites();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import core.time : Duration;
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.database : MemoryWorldDatabase;
    import dmangos.world.map : Inhabitant;
    import dmangos.world.objects : UpdateData;
    import dmangos.world.player : CharacterData;
    import dmangos.world.playercreate : CharacterBuilder, CreationSettings, KnownAbilities;
    import dmangos.world.testdata;

    /// An online player that records what it is sent.
    final class FakePlayer : OnlinePlayer
    {
        bool ignores(ulong) const { return false; }
        @property uint instanceId() const { return 0; }
        Player player;
        Opcode[] received;
        const(ubyte)[][] bodies;
        uint groupChanges;

        this(uint guid, string name)
        {
            auto client = testClientData();
            auto world = testWorldData(client);
            CharacterData c;
            c.guid = guid;
            c.name = name;
            c.race = raceHuman;
            c.classId = classWarrior;
            c.level = 1;
            KnownAbilities abilities;
            new CharacterBuilder(world, client, CreationSettings.init, () => 1u).loadAbilities(c.race, c.classId,
                c.level, AccountLevel.player, null, null, abilities);
            player = new Player(c, abilities, world, client, testItemGuids());
        }

        @property const(Player) character() const { return player; }
        void deliver(Opcode opcode, const(ubyte)[] body_) { received ~= opcode; bodies ~= body_.dup; }
        UpdateData appearanceFor(const Inhabitant viewer, uint serverTime) const
        {
            return player.createForOthers(serverTime, false);
        }

        uint appearanceKind(const Inhabitant viewer) const
        {
            return 0;
        }
        @property AccountLevel security() const { return AccountLevel.player; }
        bool canUseCommand(char) const { return false; }
        @property bool hasPermissions() const { return false; }
        @property bool transferring() const { return false; }
        void groupChanged() { ++groupChanges; }
        void update(Duration) {}

        Opcode[] take()
        {
            auto got = received;
            received = null;
            bodies = null;
            return got;
        }
    }

    /// Players by guid; nobody sees anybody.
    final class FakeDirectory : GroupDirectory
    {
        FakePlayer[ulong] players;
        OnlinePlayer local(ulong guid) { return players.get(guid, null); }
        bool deliverTo(ulong guid, Opcode opcode, const(ubyte)[] body_)
        {
            if (auto p = guid in players)
            {
                p.deliver(opcode, body_);
                return true;
            }
            return false;
        }
        ubyte statusOf(ulong guid) { return memberStatus(players.get(guid, null)); }
        bool seeEachOther(ulong a, ulong b) { return false; }
    }
}

/// Inviting, creating, joining, leading, raids, and disbanding, with the rows they write.
unittest
{
    auto db = new MemoryWorldDatabase;
    auto directory = new FakeDirectory;
    auto groups = new Groups(db, directory, 10);
    auto anduin = new FakePlayer(1, "Anduin"), jaina = new FakePlayer(2, "Jaina"), varian = new FakePlayer(3, "Varian");
    foreach (p; [anduin, jaina, varian])
        directory.players[p.player.guid] = p;

    // The first invitation makes a group that is not created yet.
    auto group = groups.newGroup();
    assert(group.addLeaderInvite(1, "Anduin") && group.addInvite(2, "Jaina"));
    assert(!group.isCreated && groups.invitationOf(2) is group && groups.invitationOf(1) is group);
    assert(!group.addInvite(2, "Jaina"), "invited once");

    // Accepting creates it, with the leader first.
    group.removeInvite(2);
    group.create();
    assert(group.addMember(2, "Jaina"));
    assert(group.id == 10 && groups.of(1) is group && groups.of(2) is group && groups.invitationOf(1) is null);
    assert(db.groups[10].members.length == 2 && db.groups[10].leader == 1);
    // Both get the list; Anduin, who does not see Jaina, gets her stats (the client asks for the others').
    assert(anduin.received.canFind(Opcode.SMSG_GROUP_LIST) && jaina.received.canFind(Opcode.SMSG_GROUP_LIST));
    assert(anduin.received.canFind(Opcode.SMSG_PARTY_MEMBER_STATS)
        && !jaina.received.canFind(Opcode.SMSG_PARTY_MEMBER_STATS));
    assert(groups.sameGroup(1, 2) && !groups.sameGroup(1, 3));

    // Anduin's list shows Jaina, online, and Anduin as leader, with the loot settings.
    anduin.take();
    group.sendUpdateTo(1);
    const list = anduin.bodies[0];
    assert(list[0] == GroupType.normal && list[2 .. 6] == [1, 0, 0, 0]);
    assert(list[6 .. 12] == "Jaina\0" && list[20] == MemberStatus.online);
    assert(list[22] == 1 && list[30] == LootMethod.groupLoot);

    // The loot settings: a threshold of uncommon to epic, a master looter among the members; else unchanged.
    group.setLoot(LootMethod.masterLoot, 2, 3);
    assert(group.lootMethod == LootMethod.masterLoot && group.looter == 2 && group.lootThreshold == 3);
    group.setLoot(LootMethod.groupLoot, 0, 1);
    group.setLoot(LootMethod.groupLoot, 0, 5);
    group.setLoot(LootMethod.masterLoot, 99, 2);
    assert(group.lootMethod == LootMethod.masterLoot && group.looter == 2 && group.lootThreshold == 3,
        "common, legendary, a stranger: refused");
    group.setLoot(LootMethod.groupLoot, 0, 2);

    // A new leader; then a raid with an assistant in sub-group 3.
    group.changeLeader(2);
    assert(group.isLeader(2) && db.groups[10].leader == 2);
    group.addMember(3, "Varian");
    group.convertToRaid();
    assert(group.isRaid && db.groups[10].isRaid);
    group.setAssistant(3, true);
    group.changeSubGroup(3, 3);
    assert(group.isAssistant(3) && group.subGroupOf(3) == 3 && db.groups[10].members[2].subGroup == 3);

    // Kicking Varian; then Anduin leaves and two are too few: the group is disbanded.
    varian.take();
    assert(group.removeMember(3, RemoveMethod.kick) == 2);
    assert(varian.take() == [Opcode.SMSG_GROUP_UNINVITE, Opcode.SMSG_GROUP_LIST] && groups.of(3) is null);
    assert(group.removeMember(1, RemoveMethod.leave) == 0);
    assert(groups.of(1) is null && groups.of(2) is null && 10 !in db.groups && groups.count == 0);
}

/// Loading: offline members keep their places; broken groups are removed.
unittest
{
    auto db = new MemoryWorldDatabase;
    db.groups[5] = GroupRecord(5, 1, 0, 0, LootMethod.freeForAll, 1, 2, (ulong[8]).init, false, "Anduin",
        [GroupMemberRecord(1, "Anduin", false, 0), GroupMemberRecord(2, "Jaina", false, 0)]);
    db.groups[6] = GroupRecord(6, 3, 0, 0, 0, 0, 0, (ulong[8]).init, false, "Varian",
        [GroupMemberRecord(3, "Varian", false, 0), GroupMemberRecord(4, null, false, 0)]);
    auto groups = new Groups(db, new FakeDirectory, 1);
    groups.load(db.loadGroups());
    assert(groups.count == 1 && groups.of(makeGuid(HighGuid.player, 2)).id == 5 && 6 !in db.groups);
    assert(groups.nextId == 6);
}

/// Member stats: the packed guid, the mask, and the fields it names.
unittest
{
    auto p = new FakePlayer(7, "Anduin");
    const stats = partyMemberStats(p.player, GroupUpdate.status | GroupUpdate.currentHealth | GroupUpdate.powerType,
        MemberStatus.online);
    // guid 7 packed (2 bytes), the mask with the power fields added, status, health, power type, current, max
    assert(stats[0 .. 2] == [1, 7] && stats[2 .. 6] == [0x3B, 0, 0, 0]);
    assert(stats.length == 2 + 4 + 1 + 2 + 1 + 2 + 2 && stats[6] == MemberStatus.online && stats[9] == Power.rage);
    assert(partyMemberStatsFull(7, null, 0) == [1, 7, 1, 0, 0, 0, 0]);
    assert(partyMemberStatsFull(7, p.player, MemberStatus.online).length == 2 + 4 + 1 + 2 + 2 + 1 + 2 + 2 + 2 + 2
        + 4 + 4 + 2 + 1 + 4);
}
