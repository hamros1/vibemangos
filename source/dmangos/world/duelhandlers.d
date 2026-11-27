/**
 * Duels: the request, the countdown, the flag's distance, and the end. Mixed into
 * `dmangos.world.character.Character`.
 *
 * The Duel spell at another player plants a flag between them and asks the other; accepted, both
 * count down 3 seconds and are then enemies of each other (`PLAYER_DUEL_TEAM` 1 and 2 with the same
 * `PLAYER_DUEL_ARBITER`), in melee and with spells. Whoever would fall to the other's blow is left
 * with 1 health and loses (and begs); one who stays more than 50 yards from the flag for 10 seconds
 * flees and loses; declining, logging out or teleporting ends it. Everyone around hears who won.
 */
module dmangos.world.duelhandlers;

/// How a duel ended.
enum DuelEnd : ubyte
{
    interrupted = 0,
    won = 1,
    fled = 2,
}

/// The duel flag (`gameobject_template` 21680), the Duel spell's `EffectMiscValue`.
enum uint duelFlagEntry = 21680;

/// One side of a duel.
final class DuelState
{
    ulong initiator;
    ulong opponent;
    ulong arbiter;     /// the flag's guid
    float[3] flagAt;   /// where the flag stands
    long startTimer;   /// when it was accepted (Unix time); 0 before or once it has begun
    long startTime;    /// when it began; 0 before
    long outOfBound;   /// since when this side is too far from the flag; 0 if it is not
}

/// See the module documentation.
final class Dueling
{
    import dmangos.world.character : Character, Handles;
    import dmangos.world.session : WorldState;

    private Character me;

    ///
    this(Character me)
    {
        this.me = me;
    }

    import dmangos.bytes : ByteReader, ByteWriter;
    import dmangos.log : info;
    import dmangos.world.duelhandlers;
    import dmangos.world.gameobject : GameObject, GameObjectSpawn;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.opcodes;
    import dmangos.world.updatefields;

package:
    DuelState duel; // this player's side of its duel, while one is asked or on

    /// The other duelist's session, while a duel is asked or on.
    Dueling duelOpponent()
    {
        if (duel is null)
            return null;
        auto other = me.context.onlinePlayer(duel.opponent);
        return other is null || other.dueling.duel is null || other.player is null ? null : other.dueling;
    }

    /// Whether this player is in a duel that has begun with `guid`.
    package bool duelingWith(ulong guid)
    {
        return duel !is null && duel.startTime != 0 && duel.opponent == guid;
    }

    /**
     * The Duel spell's effect: a flag midway between the two, the request to both, and each one's side
     * of the duel.
     */
    package void startDuel(ulong target)
    {
        auto other = me.context.onlinePlayer(target);
        if (other is null || other is me || other.player is null || other.map !is me.map)
            return;
        if (duel !is null || other.dueling.duel !is null)
            return;
        const a = me.player.position, b = other.player.position;
        const at = [(a.x + b.x) / 2, (a.y + b.y) / 2, a.z];
        import core.atomic : atomicOp;

        static shared uint flags; // one count for the node, whichever thread the duel is on
        const spawnGuid = (uint(me.context.nodeId) << 20) | (0x80000 + (atomicOp!"+="(flags, 1) & 0x7FFFF));
        ulong arbiter = makeGuid(HighGuid.gameObject, duelFlagEntry, spawnGuid);
        if (auto template_ = duelFlagEntry in me.context.data.gameObjectTemplates)
        {
            auto spawn = GameObjectSpawn(spawnGuid, duelFlagEntry, me.player.data.map, at[0], at[1], at[2],
                a.orientation);
            auto flag = new GameObject(spawn, template_);
            flag.values.set!GAMEOBJECT_FACTION(me.player.values.get!UNIT_FIELD_FACTIONTEMPLATE);
            flag.values.set!GAMEOBJECT_LEVEL(me.player.data.level + 1);
            flag.values.clearChanges();
            arbiter = flag.guid;
            me.map.addObject(flag);
        }
        ByteWriter w;
        w.put(arbiter);
        w.put(me.player.guid);
        me.deliver(Opcode.SMSG_DUEL_REQUESTED, w.data);
        other.deliver(Opcode.SMSG_DUEL_REQUESTED, w.data);
        foreach (pair; [[me, other], [other, me]])
        {
            auto side = pair[0], against = pair[1];
            auto state = new DuelState;
            state.initiator = me.player.guid;
            state.opponent = against.player.guid;
            state.arbiter = arbiter;
            state.flagAt = at;
            side.dueling.duel = state;
            side.player.values.set!PLAYER_DUEL_ARBITER(arbiter);
            side.flushPlayerChanges();
        }
    }

    /// The one asked accepts; both count down 3 seconds.
    @Handles(Opcode.CMSG_DUEL_ACCEPTED, WorldState.inWorld)
    void handleDuelAccepted(ref ByteReader reader)
    {
        auto other = duelOpponent();
        if (other is null || duel.initiator == me.player.guid)
            return;
        if (duel.startTimer || duel.startTime || other.duel.startTimer || other.duel.startTime)
            return;
        const now = me.context.unixTime;
        duel.startTimer = other.duel.startTimer = now;
        ByteWriter w;
        w.put(3000u);
        me.deliver(Opcode.SMSG_DUEL_COUNTDOWN, w.data);
        other.me.deliver(Opcode.SMSG_DUEL_COUNTDOWN, w.data);
    }

    /// Declined (or, once begun, given up: lost).
    @Handles(Opcode.CMSG_DUEL_CANCELLED, WorldState.inWorld)
    void handleDuelCancelled(ref ByteReader reader)
    {
        auto other = duelOpponent();
        if (other is null)
            return;
        if (duel.startTime)
        {
            me.stopAttack(false);
            other.me.stopAttack(false);
            beg();
            return duelComplete(DuelEnd.won);
        }
        duelComplete(DuelEnd.interrupted);
    }

    /// The duel each tick: it begins 3 seconds after it was accepted; the flag's distance is watched.
    void updateDuel()
    {
        if (duel is null)
            return;
        const now = me.context.unixTime;
        // The countdown over, by the initiator's side: the teams are set, and the duel is on.
        if (duel.startTimer && now >= duel.startTimer + 3 && duel.initiator == me.player.guid)
            if (auto other = duelOpponent())
            {
                me.player.values.set!PLAYER_DUEL_TEAM(1u);
                other.me.player.values.set!PLAYER_DUEL_TEAM(2u);
                duel.startTimer = other.duel.startTimer = 0;
                duel.startTime = other.duel.startTime = now;
                me.flushPlayerChanges();
                other.me.flushPlayerChanges();
            }
        if (duel is null || duel.startTime == 0)
            return;
        // The flag's distance: 50 yards out, 10 seconds to come within 40 again.
        const p = me.player.position;
        const d2 = (p.x - duel.flagAt[0]) ^^ 2 + (p.y - duel.flagAt[1]) ^^ 2 + (p.z - duel.flagAt[2]) ^^ 2;
        if (duel.outOfBound == 0)
        {
            if (d2 > 50 ^^ 2)
            {
                duel.outOfBound = now;
                me.deliver(Opcode.SMSG_DUEL_OUTOFBOUNDS, null);
            }
        }
        else if (d2 <= 40 ^^ 2)
        {
            duel.outOfBound = 0;
            me.deliver(Opcode.SMSG_DUEL_INBOUNDS, null);
        }
        else if (now >= duel.outOfBound + 10)
            duelComplete(DuelEnd.fled);
    }

    /// `EMOTE_ONESHOT_BEG` (spell 7267's): the loser begs.
    void beg()
    {
        enum uint emoteBeg = 20;
        ByteWriter w;
        w.put(emoteBeg);
        w.put(me.player.guid);
        me.map.sendToWatchers(me, Opcode.SMSG_EMOTE, w.data, true);
    }

    /**
     * The opponent's blow would have killed this player in the duel: it keeps 1 health, both stop
     * fighting, it begs and loses.
     */
    package void duelLost()
    {
        auto other = duelOpponent();
        me.player.values.set!UNIT_FIELD_HEALTH(1u);
        me.stopAttack(false);
        if (other !is null)
            other.me.stopAttack(false);
        beg();
        duelComplete(DuelEnd.won);
    }

    /**
     * The duel is over, called on the losing (or leaving) side: both are told it is over, the
     * players around who won, the flag goes, the debuffs each put on the other in it go, and the
     * duel fields are cleared.
     */
    package void duelComplete(DuelEnd how)
    {
        if (duel is null)
            return;
        auto other = duelOpponent();
        ByteWriter complete;
        complete.put(ubyte(how != DuelEnd.interrupted));
        me.deliver(Opcode.SMSG_DUEL_COMPLETE, complete.data);
        if (other !is null)
            other.me.deliver(Opcode.SMSG_DUEL_COMPLETE, complete.data);
        if (how != DuelEnd.interrupted && other !is null)
        {
            ByteWriter w;
            w.put(ubyte(how == DuelEnd.won ? 0 : 1));
            w.putCString(other.me.player.data.name);
            w.putCString(me.player.data.name);
            me.map.sendToWatchers(me, Opcode.SMSG_DUEL_WINNER, w.data, true);
            info!"%s: '%s' %s a duel with '%s'"(me.remoteAddress, me.player.data.name, how == DuelEnd.won ? "lost" : "fled",
                other.me.player.data.name);
        }
        if (me.map.findObject(duel.arbiter) !is null)
            me.map.removeObject(duel.arbiter);
        foreach (side; other is null ? [this] : [this, other])
        {
            const enemy = side is this ? (other is null ? 0 : other.me.player.guid) : me.player.guid;
            foreach (aura; side.me.player.auras.list.dup)
                if (!aura.positive && aura.caster == enemy)
                    side.me.removeAura(aura);
            side.me.player.values.set!PLAYER_DUEL_ARBITER(0UL);
            side.me.player.values.set!PLAYER_DUEL_TEAM(0u);
            side.duel = null;
            side.me.flushPlayerChanges();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * Anduin challenges Jaina; she accepts; after the countdown they are enemies, and his blow that
 * would kill her leaves her at 1 health and ends the duel, which everyone around hears.
 */
unittest
{
    testDuel(false);
    testDuel(true);
}

/// A player's duel with themselves is no duel: no request, no flag, no side.
unittest
{
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    import std.algorithm.searching : canFind;

    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f));
    anduin.read();
    auto me = anduin.session.inWorld;
    me.dueling.startDuel(me.player.guid);
    assert(me.dueling.duel is null, "no side of a duel");
    assert(!opcodesOf(anduin.read()).canFind(Opcode.SMSG_DUEL_REQUESTED), "no request");
}

version (unittest)
private void testDuel(bool crossNode)
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.bytes : ByteWriter;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : spellCastTimesFormat, spellRangeFormat;
    import dmangos.world.grid : cellKeyAt;
    import dmangos.world.movement : Position;
    import dmangos.world.playercreate : NewSpell;
    import dmangos.world.replication : encodePlayerState;
    import dmangos.world.opcodes;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.player : DeathState, Player;
    import dmangos.world.spellcast : SpellTargets, TargetFlags;
    import dmangos.world.spellhandlers : testSpell;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto home = crossNode ? newCreationContext(db) : context;
    auto now = MonoTime.currTime;
    import dmangos.bytes : bits = floatBits;
    enum uint duelSpell = 7266;
    foreach (node; crossNode ? [home, context] : [context])
    {
        node.clock = () => now;
        node.client.spellCastTimes = typeof(node.client.spellCastTimes).parse(buildDbc(spellCastTimesFormat,
            [[1u, 0, 0, 0]]), "SpellCastTimes.dbc");
        node.client.spellRanges = typeof(node.client.spellRanges).parse(buildDbc(spellRangeFormat,
            [[1u, bits(0), bits(30), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]), "SpellRange.dbc");
        node.data.spells.spells[duelSpell] = testSpell(duelSpell, 83, 25, 0);
        node.data.spells.spells.edit(duelSpell).miscValue[0] = duelFlagEntry;
    }

    auto relay = crossNode ? new TestPlayerRelay(home, context) : null;

    // Facing each other, two yards apart.
    auto anduin = loggedIn(home, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 0),
        setup: (ref c) { c.spells ~= NewSpell(duelSpell, true, false); });
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8948.0f, -132.49f, 83.53f, 3.14159f));
    anduin.read();
    jaina.read();
    auto j = cast(Player) jaina.session.character;
    if (crossNode)
    {
        context.regionOwnerAround = (uint, Position, float) => ushort(1);
        home.map(0).replicaCreated(context.nodeId, cellKeyAt(j.position.x, j.position.y), j.guid, encodePlayerState(j, 0));
    }

    ByteWriter cast_;
    cast_.put(duelSpell);
    SpellTargets(TargetFlags.unit, j.guid).write(cast_);
    anduin.write(Opcode.CMSG_CAST_SPELL, cast_.data);
    auto challenger = anduin.session;
    if (crossNode)
    {
        assert(relay.remote !is null && challenger.inWorld is null);
        challenger = relay.remote;
        challenger.update(50.msecs);
        now += 11.seconds;
        assert(challenger.inWorld.migrationTarget() == 0, "a pending challenge pins the challenger");
        assert(jaina.session.inWorld.migrationTarget() == 0, "a pending challenge pins the opponent");
    }
    auto a = cast(Player) challenger.character;
    assert(opcodesOf(jaina.read()).canFind(Opcode.SMSG_DUEL_REQUESTED), "Jaina is challenged");
    const flag = a.values.get!PLAYER_DUEL_ARBITER;
    assert(flag != 0 && j.values.get!PLAYER_DUEL_ARBITER == flag);

    // Not enemies before it begins.
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(j.guid));
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_ATTACKSTOP));

    ByteWriter accept;
    accept.put(flag);
    jaina.write(Opcode.CMSG_DUEL_ACCEPTED, accept.data);
    assert(opcodesOf(anduin.read()).canFind(Opcode.SMSG_DUEL_COUNTDOWN));
    now += 3.seconds;
    challenger.update(50.msecs);
    assert(a.values.get!PLAYER_DUEL_TEAM == 1 && j.values.get!PLAYER_DUEL_TEAM == 2, "it has begun");

    // Now he may attack her; at 3 health her fall ends the duel instead.
    j.values.set!UNIT_FIELD_HEALTH(3u);
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(j.guid));
    anduin.read();
    foreach (_; 0 .. 40)
    {
        now += 2.seconds;
        challenger.update(2000.msecs);
        jaina.session.update(50.msecs);
        if (a.values.get!PLAYER_DUEL_TEAM == 0)
            break;
    }
    assert(a.values.get!PLAYER_DUEL_TEAM == 0 && j.values.get!PLAYER_DUEL_ARBITER == 0, "over");
    assert(j.values.get!UNIT_FIELD_HEALTH == 1 && j.deathState == DeathState.alive, "she lost, and lives");
    const heard = opcodesOf(jaina.read());
    assert(heard.canFind(Opcode.SMSG_DUEL_WINNER) && heard.canFind(Opcode.SMSG_DUEL_COMPLETE));
    if (crossNode)
    {
        auto regionOwner = context.regionOwnerAround;
        context.regionOwnerAround = null; // keep the test on this node while the combat flag wears off
        now += 10.seconds;
        challenger.update(50.msecs);
        context.regionOwnerAround = regionOwner;
        assert(challenger.inWorld.migrationTarget() == 1, "normal placement resumes after the duel");
    }
}
