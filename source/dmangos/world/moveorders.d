/**
 * Orders that change how a player moves, the client's acknowledgements of them, and what those who see
 * the player are told; mixed into `dmangos.world.character.Character`.
 *
 * The server never moves a player itself: it orders its client (`SMSG_FORCE_*_SPEED_CHANGE`,
 * `SMSG_FORCE_MOVE_ROOT`, `SMSG_MOVE_KNOCK_BACK`, `SMSG_MOVE_WATER_WALK`, `SMSG_MOVE_FEATHER_FALL`,
 * `SMSG_MOVE_SET_HOVER` and their opposites), each with the next number of the order counter, and the
 * client answers with an acknowledgement that carries its movement as it obeys. That answer, as in
 * CMaNGOS (`MovementHandler.cpp`), is taken like any move and shown to the others as
 * `MSG_MOVE_SET_*_SPEED`, `MSG_MOVE_ROOT` / `MSG_MOVE_UNROOT`, `MSG_MOVE_KNOCK_BACK`, `MSG_MOVE_WATER_WALK`,
 * `MSG_MOVE_FEATHER_FALL` or `MSG_MOVE_HOVER`, so that their clients move the player at its new speed,
 * stop it where it is rooted, and throw it as it is thrown.
 *
 * Speeds follow CMaNGOS's `Unit::UpdateSpeed` (`speedRate`): run speed by the strongest
 * `MOD_INCREASE_SPEED` on foot, or the strongest `MOD_INCREASE_MOUNTED_SPEED` mounted, times the greater
 * of the stacking `MOD_SPEED_ALWAYS` (`MOD_MOUNTED_SPEED_ALWAYS`) and the strongest
 * `MOD_SPEED_NOT_STACK` (`MOD_MOUNTED_SPEED_NOT_STACK`); swim speed by `MOD_INCREASE_SWIM_SPEED` alone;
 * run, run back and swim all slowed by the strongest `MOD_DECREASE_SPEED`, and run and swim capped by
 * `USE_NORMAL_MOVEMENT_SPEED`. A ghost runs and swims a quarter faster (a night elf's wisp half), as the
 * ghost aura is applied by hand (`dmangos.world.death`).
 *
 * Water Walking (`WATER_WALK`, and every ghost), Slow Fall and Levitate (`FEATHER_FALL`) and `HOVER` are
 * ordered when the first aura of their kind begins and taken back when the last ends.
 */
module dmangos.world.moveorders;

import dmangos.bytes : ByteReader, ByteWriter;
import dmangos.world.auras : AuraSet;
import dmangos.world.movement : baseMoveSpeed, MovementInfo, MoveType;
import dmangos.world.opcodes : Opcode;
import dmangos.world.spellids : AuraType;

/// For each `MoveType`: the order, the client's acknowledgement, and what others are told (CMaNGOS `SetSpeed2Opc_table`).
immutable Opcode[3][MoveType.max + 1] speedOpcodes = [
    [Opcode.SMSG_FORCE_WALK_SPEED_CHANGE, Opcode.CMSG_FORCE_WALK_SPEED_CHANGE_ACK, Opcode.MSG_MOVE_SET_WALK_SPEED],
    [Opcode.SMSG_FORCE_RUN_SPEED_CHANGE, Opcode.CMSG_FORCE_RUN_SPEED_CHANGE_ACK, Opcode.MSG_MOVE_SET_RUN_SPEED],
    [Opcode.SMSG_FORCE_RUN_BACK_SPEED_CHANGE, Opcode.CMSG_FORCE_RUN_BACK_SPEED_CHANGE_ACK,
        Opcode.MSG_MOVE_SET_RUN_BACK_SPEED],
    [Opcode.SMSG_FORCE_SWIM_SPEED_CHANGE, Opcode.CMSG_FORCE_SWIM_SPEED_CHANGE_ACK, Opcode.MSG_MOVE_SET_SWIM_SPEED],
    [Opcode.SMSG_FORCE_SWIM_BACK_SPEED_CHANGE, Opcode.CMSG_FORCE_SWIM_BACK_SPEED_CHANGE_ACK,
        Opcode.MSG_MOVE_SET_SWIM_BACK_SPEED],
    [Opcode.SMSG_FORCE_TURN_RATE_CHANGE, Opcode.CMSG_FORCE_TURN_RATE_CHANGE_ACK, Opcode.MSG_MOVE_SET_TURN_RATE],
];

/// Every speed acknowledgement.
enum Opcode[] speedAckOpcodes = () {
    Opcode[] acks;
    foreach (opcodes; speedOpcodes)
        acks ~= opcodes[1];
    return acks;
}();

/// The kind of movement a speed acknowledgement is for.
MoveType moveTypeOfAck(Opcode ack) pure nothrow @nogc @safe
{
    foreach (type, opcodes; speedOpcodes)
        if (opcodes[1] == ack)
            return cast(MoveType) type;
    assert(0, "not a speed acknowledgement");
}

/**
 * A player's speed rate for `type` by its auras (CMaNGOS `Unit::UpdateSpeed`); `mounted`: it has a mount
 * (`UNIT_FIELD_MOUNTDISPLAYID`). The speed is the rate times `baseMoveSpeed`. Walking, swimming backwards and
 * turning are only ever 1 here: no aura changes them (CMaNGOS updates only run, run back and swim from auras).
 */
float speedRate(MoveType type, const ref AuraSet auras, bool mounted)
{
    import std.algorithm.comparison : max;

    int main;
    float stack = 1, nonStack = 1;
    switch (type)
    {
    case MoveType.run:
        if (mounted)
        {
            main = auras.strongest(AuraType.modIncreaseMountedSpeed, true);
            stack = auras.multiplier(AuraType.modMountedSpeedAlways);
            nonStack = (100.0f + auras.strongest(AuraType.modMountedSpeedNotStack, true)) / 100.0f;
        }
        else
        {
            main = auras.strongest(AuraType.modIncreaseSpeed, true);
            stack = auras.multiplier(AuraType.modSpeedAlways);
            nonStack = (100.0f + auras.strongest(AuraType.modSpeedNotStack, true)) / 100.0f;
        }
        break;
    case MoveType.swim:
        main = auras.strongest(AuraType.modIncreaseSwimSpeed, true);
        break;
    case MoveType.runBack:
        break;
    default:
        return 1;
    }
    const bonus = max(nonStack, stack);
    float rate = main ? bonus * (100.0f + main) / 100.0f : bonus;
    if (type == MoveType.run || type == MoveType.swim)
        if (const normal = auras.strongest(AuraType.useNormalMovementSpeed, true))
        {
            const cap = normal / baseMoveSpeed[type];
            if (rate > cap)
                rate = cap;
        }
    if (const slow = auras.strongest(AuraType.modDecreaseSpeed, false))
        rate *= (100.0f + slow) / 100.0f;
    return max(rate, 0.01f);
}

unittest
{
    import dmangos.world.auras : Aura, makeAura;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.spellids : SpellEffect;

    AuraSet auras;
    SpellInfo[] spells;
    void add(AuraType type, int amount)
    {
        SpellInfo s;
        s.id = cast(uint)(90_000 + spells.length);
        s.effect[0] = SpellEffect.applyAura;
        s.casting.applyAuraName[0] = type;
        spells ~= s;
        auras.list ~= makeAura(&spells[$ - 1], 1, 60, -1, amount > 0, [amount, 0, 0]);
    }

    spells.reserve(16); // the auras point into it
    bool rate(MoveType type, bool mounted, float expected)
    {
        import std.math : isClose;

        return isClose(speedRate(type, auras, mounted), expected);
    }

    assert(rate(MoveType.run, false, 1) && rate(MoveType.walk, false, 1));
    add(AuraType.modIncreaseSpeed, 70);         // Sprint
    add(AuraType.modIncreaseSpeed, 30);         // Aspect of the Cheetah: only the strongest
    add(AuraType.modIncreaseMountedSpeed, 60);  // a horse
    assert(rate(MoveType.run, false, 1.7f), "on foot: Sprint");
    assert(rate(MoveType.run, true, 1.6f), "mounted: the mount alone");
    assert(rate(MoveType.swim, false, 1), "swimming: neither");
    add(AuraType.modMountedSpeedAlways, 10);    // Riding Crop / Mithril Spurs
    assert(rate(MoveType.run, true, 1.1f * 1.6f));
    add(AuraType.modSpeedNotStack, 8);          // Minor Speed: the greater of it and the stacking kind
    assert(rate(MoveType.run, false, 1.08f * 1.7f));
    add(AuraType.modDecreaseSpeed, -50);        // a snare: running back too
    assert(rate(MoveType.runBack, false, 0.5f));
    assert(rate(MoveType.run, false, 1.08f * 1.7f * 0.5f));
    add(AuraType.modDecreaseSpeed, -100);
    assert(speedRate(MoveType.swim, auras, false) == 0.01f, "never quite nothing");
}

/// `CMSG_FORCE_MOVE_ROOT_ACK`, `CMSG_FORCE_MOVE_UNROOT_ACK`, `CMSG_MOVE_KNOCK_BACK_ACK`: whose, the order's number, the movement.
struct ClientMoveAck
{
    ulong guid;
    uint counter;
    MovementInfo movement;

    ///
    static ClientMoveAck read(ref ByteReader r)
    {
        ClientMoveAck ack;
        ack.guid = r.read!ulong;
        ack.counter = r.read!uint;
        ack.movement = MovementInfo.read(r);
        return ack;
    }
}

/// `CMSG_FORCE_*_SPEED_CHANGE_ACK`: as `ClientMoveAck`, and the speed the client now moves at.
struct ClientSpeedAck
{
    ClientMoveAck ack;
    float speed = 0;

    ///
    static ClientSpeedAck read(ref ByteReader r)
    {
        auto ack = ClientMoveAck.read(r);
        return ClientSpeedAck(ack, r.read!float);
    }
}

/// `CMSG_MOVE_WATER_WALK_ACK`, `CMSG_MOVE_FEATHER_FALL_ACK`, `CMSG_MOVE_HOVER_ACK`: as `ClientMoveAck`, and whether it was set.
struct ClientMoveFlagAck
{
    ClientMoveAck ack;
    uint applied;

    ///
    static ClientMoveFlagAck read(ref ByteReader r)
    {
        auto ack = ClientMoveAck.read(r);
        return ClientMoveFlagAck(ack, r.read!uint);
    }
}

unittest
{
    import dmangos.world.movement : Position;

    MovementInfo m;
    m.position = Position(1, 2, 3, 0);
    ByteWriter w;
    w.put(7UL);
    w.put(4u);
    m.write(w);
    w.put(10.5f);
    auto r = ByteReader(w.data);
    const ack = ClientSpeedAck.read(r);
    assert(r.empty && ack.ack.guid == 7 && ack.ack.counter == 4 && ack.ack.movement == m && ack.speed == 10.5f);
    assert(moveTypeOfAck(Opcode.CMSG_FORCE_RUN_BACK_SPEED_CHANGE_ACK) == MoveType.runBack);
    assert(speedAckOpcodes.length == 6);
}

/// See the module documentation.
mixin template MovementOrders()
{
    import std.math : abs;
    import dmangos.log;
    import dmangos.world.moveorders;
    import dmangos.world.movement : baseMoveSpeed, MovementFlags, MoveType;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : DeathState, PlayerFlags;
    import dmangos.world.spellids : AuraType;
    import dmangos.world.updatefields : PLAYER_FLAGS, UNIT_FIELD_MOUNTDISPLAYID;

    private
    {
        uint[MoveType.max + 1] pendingSpeedAcks; // speed orders not yet acknowledged, by kind
        bool waterWalking, featherFalling, hovering; // as last ordered
    }

    /// An order that names the player and counts (`SMSG_MOVE_WATER_WALK`, ...), chosen at run time.
    private void sendCountedOrder(Opcode opcode)
    {
        ByteWriter w;
        w.putPackedGuid(player.guid);
        w.put(moveOrderCounter++);
        deliver(opcode, w.data);
    }

    /// `SMSG_FORCE_*_SPEED_CHANGE`: the player's speed for one kind of movement, which its client acknowledges.
    package void forceSpeed(MoveType type, float speed)
    {
        player.speeds[type] = speed;
        ++pendingSpeedAcks[type];
        ByteWriter w;
        w.putPackedGuid(player.guid);
        w.put(moveOrderCounter++);
        w.put(speed);
        deliver(speedOpcodes[type][0], w.data);
        resetMovementCheck();
    }

    /// Run, run back and swim speeds by the player's auras and mount (`speedRate`), and its being a ghost; each changed one ordered.
    package void refreshSpeeds()
    {
        enum ubyte raceNightElf = 4;
        const mounted = player.values.get!UNIT_FIELD_MOUNTDISPLAYID != 0;
        const ghost = player.deathState == DeathState.ghost ? player.data.race == raceNightElf ? 1.5f : 1.25f : 1;
        foreach (type; [MoveType.run, MoveType.runBack, MoveType.swim])
        {
            const speed = baseMoveSpeed[type] * speedRate(type, player.auras, mounted)
                * (type == MoveType.runBack ? 1 : ghost);
            if (speed != player.speeds[type])
                forceSpeed(type, speed);
        }
    }

    /**
     * Water walking (a `WATER_WALK` aura, or a ghost), slow fall (`FEATHER_FALL`) and hover (`HOVER`): each ordered
     * when it begins and taken back when it ends (CMaNGOS `Unit::SetWaterWalk`, `SetFeatherFall`, `SetHover`).
     * The end of a slow fall starts the next fall where the player is.
     */
    package void refreshMovementAuras()
    {
        const ghost = (player.values.get!PLAYER_FLAGS & PlayerFlags.ghost) != 0;
        const walk = ghost || player.auras.has(AuraType.waterWalk);
        if (walk != waterWalking)
        {
            waterWalking = walk;
            sendCountedOrder(walk ? Opcode.SMSG_MOVE_WATER_WALK : Opcode.SMSG_MOVE_LAND_WALK);
        }
        const feather = player.auras.has(AuraType.featherFall);
        if (feather != featherFalling)
        {
            featherFalling = feather;
            sendCountedOrder(feather ? Opcode.SMSG_MOVE_FEATHER_FALL : Opcode.SMSG_MOVE_NORMAL_FALL);
            if (!feather)
                startFallAt(player.position.z);
        }
        const hover = player.auras.has(AuraType.hover);
        if (hover != hovering)
        {
            hovering = hover;
            sendCountedOrder(hover ? Opcode.SMSG_MOVE_SET_HOVER : Opcode.SMSG_MOVE_UNSET_HOVER);
        }
    }

    /**
     * The client moves at a new speed (CMaNGOS `HandleForceSpeedChangeAckOpcodes`): its move is taken, and those
     * who see it are told the speed. Of several orders of one kind only the last is checked against the speed
     * the server keeps; a client that disagrees is logged (CMaNGOS kicks one that is faster).
     */
    @Handles(speedAckOpcodes, WorldState.inWorld)
    void handleForceSpeedChangeAck(const ClientSpeedAck answer, Opcode opcode)
    {
        const type = moveTypeOfAck(opcode);
        const ack = &answer.ack;
        if (ack.guid != player.guid || !takeMovement(ack.movement, opcode))
            return;
        ByteWriter speed;
        speed.put(answer.speed);
        relayMovement(speedOpcodes[type][2], ack.movement, speed.data);
        movedOn(ack.movement, opcode);
        if (pendingSpeedAcks[type] > 0 && --pendingSpeedAcks[type] > 0)
            return;
        if (!ack.movement.has(MovementFlags.onTransport) && abs(player.speeds[type] - answer.speed) > 0.01f)
            warning!"%s: '%s' acknowledged %s speed %.2f, but it is %.2f"(remoteAddress, player.data.name, type,
                answer.speed, player.speeds[type]);
    }

    /// Rooted or free (CMaNGOS `HandleMoveRootAck`): those who see the player stop it where it is, or let it go.
    @Handles([Opcode.CMSG_FORCE_MOVE_ROOT_ACK, Opcode.CMSG_FORCE_MOVE_UNROOT_ACK], WorldState.inWorld)
    void handleMoveRootAck(const ClientMoveAck ack, Opcode opcode)
    {
        const unroot = opcode == Opcode.CMSG_FORCE_MOVE_UNROOT_ACK;
        // Only a change: freed while not rooted, or rooted while already, is nothing to show.
        if (ack.guid != player.guid || player.movement.has(MovementFlags.root) != unroot)
            return;
        if (!takeMovement(ack.movement, opcode))
            return;
        relayMovement(unroot ? Opcode.MSG_MOVE_UNROOT : Opcode.MSG_MOVE_ROOT, ack.movement);
        movedOn(ack.movement, opcode);
    }

    /// Thrown (CMaNGOS `HandleMoveKnockBackAck`): those who see the player see it fly, its launch after the move.
    @Handles(Opcode.CMSG_MOVE_KNOCK_BACK_ACK, WorldState.inWorld)
    void handleMoveKnockBackAck(const ClientMoveAck ack)
    {
        if (ack.guid != player.guid || !takeMovement(ack.movement, Opcode.CMSG_MOVE_KNOCK_BACK_ACK))
            return;
        const m = &ack.movement;
        ByteWriter launch;
        launch.put(m.jumpCos);
        launch.put(m.jumpSin);
        launch.put(m.jumpXySpeed);
        launch.put(m.jumpVelocity);
        relayMovement(Opcode.MSG_MOVE_KNOCK_BACK, ack.movement, launch.data);
        movedOn(ack.movement, Opcode.CMSG_MOVE_KNOCK_BACK_ACK);
    }

    /// Water walking, slow fall or hover on or off (CMaNGOS `HandleMoveFlagChangeOpcode`): shown with the move.
    @Handles([Opcode.CMSG_MOVE_WATER_WALK_ACK, Opcode.CMSG_MOVE_FEATHER_FALL_ACK, Opcode.CMSG_MOVE_HOVER_ACK],
        WorldState.inWorld)
    void handleMoveFlagAck(const ClientMoveFlagAck answer, Opcode opcode)
    {
        const ack = &answer.ack;
        if (ack.guid != player.guid || !takeMovement(ack.movement, opcode))
            return;
        const shown = opcode == Opcode.CMSG_MOVE_WATER_WALK_ACK ? Opcode.MSG_MOVE_WATER_WALK
            : opcode == Opcode.CMSG_MOVE_FEATHER_FALL_ACK ? Opcode.MSG_MOVE_FEATHER_FALL : Opcode.MSG_MOVE_HOVER;
        relayMovement(shown, ack.movement);
        movedOn(ack.movement, opcode);
    }
}

/**
 * Speeds by aura and mount, ordered to the player and shown to Jaina once acknowledged; root, knockback and
 * water walking likewise.
 */
unittest
{
    import dmangos.world.auras : makeAura;
    import dmangos.world.movement : MovementFlags, MovementInfo, Position;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.spellids : SpellEffect;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8940, -132, 83.5f));
    auto me = anduin.session.inWorld;
    auto player = me.player;
    anduin.read();
    jaina.read();

    enum uint sprint = 91_201, snare = 91_202, horse = 91_203, waterWalking = 91_204;
    with (context.data.spells)
    {
        spells[sprint] = testSpell(sprint, 6, 1, 50);
        spells.edit(sprint).casting.applyAuraName[0] = AuraType.modIncreaseSpeed;
        spells[snare] = testSpell(snare, 6, 1, -50);
        spells.edit(snare).casting.applyAuraName[0] = AuraType.modDecreaseSpeed;
        spells[horse] = testSpell(horse, 6, 1, 0);
        spells.edit(horse).casting.applyAuraName[0] = AuraType.mounted;
        spells.edit(horse).miscValue[0] = creatureInnkeeper; // any creature: its model is the mount's
        spells.edit(horse).effect[1] = SpellEffect.applyAura;
        spells.edit(horse).casting.applyAuraName[1] = AuraType.modIncreaseMountedSpeed;
        spells[waterWalking] = testSpell(waterWalking, 6, 1, 0);
        spells.edit(waterWalking).casting.applyAuraName[0] = AuraType.waterWalk;
    }
    auto aura(uint spell, int amount, int second = 0)
    {
        return makeAura(context.data.spells.spell(spell), 7, 1, -1, amount >= 0, [amount, second, 0]);
    }

    // [order counter, speed] of each speed order of `opcode`.
    float[][] ordered(const(ServerPacketRead)[] packets, Opcode opcode)
    {
        float[][] found;
        foreach (p; packets)
            if (p.opcode == opcode)
            {
                auto r = ByteReader(p.body_);
                assert(r.readPackedGuid() == 7);
                found ~= [float(r.read!uint), r.read!float];
            }
        return found;
    }

    ubyte[] ack(uint counter, uint flags = 0, const(ubyte)[] tail = null)
    {
        MovementInfo m;
        m.flags = flags;
        m.position = player.position;
        ByteWriter w;
        w.put(7UL);
        w.put(counter);
        m.write(w);
        w.putBytes(tail);
        return w.data.dup;
    }

    // What Jaina was told but the object updates (Anduin's aura slots).
    ushort[] told()
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        return opcodesOf(jaina.read()).filter!(o => o != Opcode.SMSG_UPDATE_OBJECT
            && o != Opcode.SMSG_COMPRESSED_UPDATE_OBJECT).array;
    }

    ubyte[] floats(float[] values...)
    {
        ByteWriter w;
        foreach (v; values)
            w.put(v);
        return w.data.dup;
    }

    // Sprint: the run speed ordered; Jaina sees nothing until the client has it.
    auto running = aura(sprint, 50);
    me.addAura(running);
    const sprinting = ordered(anduin.read(), Opcode.SMSG_FORCE_RUN_SPEED_CHANGE);
    assert(sprinting.length == 1 && sprinting[0][1] == 10.5f && told() == []);
    anduin.write(Opcode.CMSG_FORCE_RUN_SPEED_CHANGE_ACK, ack(cast(uint) sprinting[0][0], 0, floats(10.5f)));
    auto seen = jaina.read();
    assert(opcodesOf(seen) == [Opcode.MSG_MOVE_SET_RUN_SPEED], "the speed, as the client has it");
    auto r = ByteReader(seen[0].body_);
    assert(r.readPackedGuid() == 7);
    MovementInfo.read(r);
    assert(r.read!float == 10.5f && r.empty);

    // A snare: running back and swimming slowed too.
    auto slowed = aura(snare, -50);
    me.addAura(slowed);
    auto orders = anduin.read();
    assert(ordered(orders, Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)[0][1] == 5.25f);
    assert(ordered(orders, Opcode.SMSG_FORCE_RUN_BACK_SPEED_CHANGE)[0][1] == 2.25f);
    assert(ordered(orders, Opcode.SMSG_FORCE_SWIM_SPEED_CHANGE).length == 1);
    me.removeAura(slowed);
    anduin.read();

    // Mounted: the mount's speed, not Sprint's; dismounted, Sprint's again.
    auto mount = aura(horse, 0, 60);
    me.addAura(mount);
    assert(player.values.get!UNIT_FIELD_MOUNTDISPLAYID != 0);
    assert(ordered(anduin.read(), Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)[0][1] == 7.0f * 1.6f);
    me.removeAura(mount);
    assert(ordered(anduin.read(), Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)[0][1] == 10.5f);
    me.removeAura(running);
    assert(ordered(anduin.read(), Opcode.SMSG_FORCE_RUN_SPEED_CHANGE)[0][1] == 7.0f);

    // Rooted: shown once the client is; again is nothing new; freed.
    anduin.write(Opcode.CMSG_FORCE_MOVE_ROOT_ACK, ack(20, MovementFlags.root));
    assert(told() == [Opcode.MSG_MOVE_ROOT]);
    anduin.write(Opcode.CMSG_FORCE_MOVE_ROOT_ACK, ack(21, MovementFlags.root));
    assert(told() == []);
    anduin.write(Opcode.CMSG_FORCE_MOVE_UNROOT_ACK, ack(22));
    assert(told() == [Opcode.MSG_MOVE_UNROOT]);

    // Knocked back: upwards is negative, as the client counts it; Jaina sees the launch after the move.
    me.knockedBack(Position(-8960, -132.49f, 83.53f), 10, 5);
    auto knock = anduin.read();
    assert(opcodesOf(knock) == [Opcode.SMSG_MOVE_KNOCK_BACK]);
    r = ByteReader(knock[0].body_);
    r.readPackedGuid();
    r.read!uint;
    r.read!float;
    r.read!float;
    assert(r.read!float == 10 && r.read!float == -5);
    MovementInfo thrown;
    thrown.flags = MovementFlags.jumping;
    thrown.position = player.position;
    thrown.jumpVelocity = -5;
    thrown.jumpCos = 1;
    thrown.jumpXySpeed = 10;
    ByteWriter knockAck;
    knockAck.put(7UL);
    knockAck.put(23u);
    thrown.write(knockAck);
    anduin.write(Opcode.CMSG_MOVE_KNOCK_BACK_ACK, knockAck.data);
    seen = jaina.read();
    assert(opcodesOf(seen) == [Opcode.MSG_MOVE_KNOCK_BACK]);
    r = ByteReader(seen[0].body_);
    r.readPackedGuid();
    assert(MovementInfo.read(r).jumpVelocity == -5);
    assert(r.read!float == 1 && r.read!float == 0 && r.read!float == 10 && r.read!float == -5 && r.empty);

    // Water Walking: ordered, shown once acknowledged, taken back when the aura ends.
    auto walking = aura(waterWalking, 0);
    me.addAura(walking);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MOVE_WATER_WALK));
    enum uint waterWalkFlag = 0x10000000; // MOVEFLAG_WATERWALKING
    anduin.write(Opcode.CMSG_MOVE_WATER_WALK_ACK, ack(24, waterWalkFlag, floats(1)));
    assert(told() == [Opcode.MSG_MOVE_WATER_WALK]);
    me.removeAura(walking);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_MOVE_LAND_WALK));
}
