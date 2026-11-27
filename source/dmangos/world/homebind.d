/**
 * Out of a dungeon after leaving its group (CMaNGOS's `Player::m_InstanceValid` and `UpdateHomebindTime`).
 *
 * A player who leaves (or is removed from) its group inside a dungeon or raid copy is no longer welcome there: the
 * client shows "You are not in a raid group" with a minute's countdown (`SMSG_RAID_GROUP_ONLY`: the milliseconds
 * left and `ERR_RAID_GROUP_NONE`), and when it runs out the player goes to its hearthstone's place. Joining again a
 * group bound to that copy, or leaving the dungeon, cancels it (the countdown hidden: `SMSG_RAID_GROUP_ONLY` with
 * none left). Game masters are never sent out; battlegrounds never count.
 *
 * Approximation: CMaNGOS spares a player permanently bound to the copy (a raid saved by a boss's death, a group's
 * permanent bind on entering); this server does not track binds made permanent by kills, so every player who leaves
 * its group inside a copy is sent out.
 */
module dmangos.world.homebind;

/// `ERR_RAID_GROUP_NONE`: the countdown's own error code (the others are the raid frame's).
enum uint raidGroupNone = 0;

/// The minute a player who left its group has before it is sent home.
enum int homebindDelayMs = 60_000;

/// `SMSG_RAID_GROUP_ONLY`: milliseconds left (0: hide the countdown), and the error.
ubyte[] raidGroupOnly(uint msLeft, uint error = raidGroupNone) pure nothrow @safe
{
    import dmangos.bytes : ByteWriter;

    ByteWriter w;
    w.put(msLeft);
    w.put(error);
    return w.data.dup;
}

unittest
{
    assert(raidGroupOnly(60_000) == [0x60, 0xEA, 0, 0, 0, 0, 0, 0]);
}

/// See the module documentation.
final class Homebind
{
    import dmangos.world.character : Character;
    import dmangos.world.session : Handles, WorldState;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import dmangos.world.homebind : homebindDelayMs, raidGroupOnly;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.teleport : Teleport;
    import dmangos.world.player : PlayerFlags;

    private bool instanceValid = true; /// welcome in the copy it is in (`m_InstanceValid`)
    private int homebindTimer;         /// the countdown under way, in milliseconds; 0: none

    /// In a dungeon or raid copy (not a battleground).
    private bool inDungeonCopy()
    {
        const entry = me.context.client.maps.lookup(me.player.data.map);
        return me.instanceId != 0 && entry !is null && entry.isDungeon;
    }

    /**
     * The group changed: out of any group inside a copy, the player is no longer welcome (`_homebindIfInstance`);
     * in a group bound to this very copy, it is again (`Group::AddMember`).
     */
    package void instanceValidityOnGroupChange()
    {
        if (me.player is null || !inDungeonCopy() || me.player.hasFlag(PlayerFlags.gm))
            return;
        if (me.context.groups.of(me.player.guid) is null)
            instanceValid = false;
        else if (me.context.dungeons.boundInstance(me.player.guid, me.player.data.map) == me.instanceId)
            instanceValid = true;
    }

    /// Arrived on a map that is not a dungeon: welcome (`HandleMoveWorldportAckOpcode`).
    package void instanceValidityOnArrival()
    {
        if (!inDungeonCopy())
            instanceValid = true;
    }

    /// Each tick (`Player::UpdateHomebindTime`): the countdown started, run, or cancelled.
    package void updateHomebindTimer(int ms)
    {
        if (me.player is null || me.teleporting != Teleport.none)
            return;
        if (instanceValid || me.player.hasFlag(PlayerFlags.gm))
        {
            if (homebindTimer)
                me.deliver(Opcode.SMSG_RAID_GROUP_ONLY, raidGroupOnly(0)); // the countdown hidden
            homebindTimer = 0;
            return;
        }
        if (homebindTimer > 0)
        {
            homebindTimer -= ms;
            if (homebindTimer <= 0)
            {
                homebindTimer = 0;
                instanceValid = true;
                const home = me.player.data.homeBind;
                me.teleportTo(home.map, Position(home.x, home.y, home.z, me.player.position.orientation));
            }
            return;
        }
        homebindTimer = homebindDelayMs;
        me.deliver(Opcode.SMSG_RAID_GROUP_ONLY, raidGroupOnly(homebindTimer));
    }
}

/**
 * In the Deadmines with her group, Jaina is removed from it: a minute's countdown, then home. Varian, removed and
 * invited back, has his countdown hidden.
 */
unittest
{
    import core.time : msecs;
    import dmangos.world.packets : ClientGroupName;
    import dmangos.world.testclient;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    const at = Position(deadminesEntrance[0], deadminesEntrance[1], deadminesEntrance[2]);
    auto anduin = loggedIn(context, db, 7, "Anduin", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    auto jaina = loggedIn(context, db, 8, "Jaina", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    auto varian = loggedIn(context, db, 9, "Varian", at, AccountLevel.player, raceHuman, mapEasternKingdoms, 10);
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("jaina"));
    jaina.write(Opcode.CMSG_GROUP_ACCEPT, null);
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("varian"));
    varian.write(Opcode.CMSG_GROUP_ACCEPT, null);
    anduin.session.inWorld.teleportTo(mapDeadmines, Position(-16, -383, 61));
    anduin.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    jaina.session.inWorld.teleportTo(mapDeadmines, Position(-16, -383, 61));
    jaina.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    varian.session.inWorld.teleportTo(mapDeadmines, Position(-16, -383, 61));
    varian.write(Opcode.MSG_MOVE_WORLDPORT_ACK, null);
    auto me = jaina.session.inWorld;
    assert(me.instanceId != 0 && me.instanceId == anduin.session.inWorld.instanceId);
    jaina.read();
    varian.read();
    jaina.session.update(100.msecs);
    assert(!opcodesOf(jaina.read()).canFind(Opcode.SMSG_RAID_GROUP_ONLY), "welcome while in the group");

    // Removed: the countdown, then home after the minute.
    anduin.write(Opcode.CMSG_GROUP_UNINVITE, ClientGroupName("jaina"));
    jaina.session.update(100.msecs);
    assert(bodyOf(jaina.read(), Opcode.SMSG_RAID_GROUP_ONLY) == raidGroupOnly(homebindDelayMs));
    jaina.session.update(30_000.msecs);
    assert(me.player.data.map == mapDeadmines, "not yet");
    jaina.session.update(30_100.msecs);
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_NEW_WORLD) || me.player.data.map != mapDeadmines, "sent home");

    // Varian removed and invited back into the group bound to this copy: the countdown hidden.
    anduin.write(Opcode.CMSG_GROUP_UNINVITE, ClientGroupName("varian"));
    varian.session.update(100.msecs);
    assert(bodyOf(varian.read(), Opcode.SMSG_RAID_GROUP_ONLY) == raidGroupOnly(homebindDelayMs));
    anduin.write(Opcode.CMSG_GROUP_INVITE, ClientGroupName("varian"));
    varian.write(Opcode.CMSG_GROUP_ACCEPT, null);
    varian.session.update(100.msecs);
    assert(bodyOf(varian.read(), Opcode.SMSG_RAID_GROUP_ONLY) == raidGroupOnly(0));
}
