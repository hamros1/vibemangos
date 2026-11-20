/**
 * A player under fear or disorientation (`SPELL_AURA_MOD_FEAR`, `SPELL_AURA_MOD_CONFUSE`: Psychic Scream,
 * Polymorph, Blind, Scatter Shot): the client gives up control of its character (`SMSG_CLIENT_CONTROL_UPDATE`)
 * and the server walks it, as CMaNGOS's fleeing and confused movement generators do: a feared player runs away
 * from whoever feared it, a little to one side or the other, again each time it gets there; a disoriented one
 * wanders a few yards at a time. Everyone, the player too, sees the walk as `SMSG_MONSTER_MOVE`, and the server
 * follows it along its spline. When the last such aura ends the walk stops where it is and control comes back.
 *
 * Neither state lets the player cast (`SPELL_FAILED_FLEEING`, `_CONFUSED`) or swing; both are on its unit flags.
 */
module dmangos.world.crowdcontrol;

/// See the module documentation.
mixin template CrowdControlHandlers()
{
    import dmangos.bytes : ByteWriter;
    import dmangos.vmap.math : Vector3;
    import dmangos.world.auras : AuraType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : MoveType, Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spline : MoveSpline, monsterMove, monsterStop, SplineFlags;
    import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

    private MoveSpline controlledWalk;   // the walk the server leads it on, while it is not in control
    private bool controlLost;            // the client was told it has no control
    private uint controlledWalkId;
    private int controlledRelocate;      // until the map is next told where it is, in milliseconds

    /// Whether the client has control of its character (not feared, not disoriented).
    package @property bool inControl() const
    {
        return !controlLost;
    }

    /// Each tick: under fear or disorientation, the walk goes on (or begins); without, control comes back.
    void updateCrowdControl(int ms)
    {
        if (player is null || map is null)
            return;
        // Curse of Recklessness (`PREVENTS_FLEEING`) keeps a feared player in control (`HandlePreventFleeing`).
        const feared = player.auras.hasType(AuraType.modFear) && !player.auras.hasType(AuraType.preventsFleeing);
        const confused = player.auras.hasType(AuraType.modConfuse);
        if ((!feared && !confused) || player.deathState != imported!"dmangos.world.player".DeathState.alive)
        {
            if (controlLost)
                regainControl();
            return;
        }
        if (!controlLost)
            loseControl();
        if (!controlledWalk.finalized)
        {
            controlledWalk.update(ms);
            player.movement.position = controlledWalk.position();
            controlledRelocate -= ms;
            if (controlledRelocate <= 0)
            {
                controlledRelocate = 500;
                map.relocated(this);
            }
            if (!controlledWalk.finalized)
                return;
            map.relocated(this);
        }
        walkOn(feared);
    }

    /// The client loses control: told so, its attack and cast stopped.
    private void loseControl()
    {
        controlLost = true;
        stopAttack(false);
        sendClientControl(false);
    }

    /// The last fear or disorientation ended: the walk stops where it is, and the client has control again.
    private void regainControl()
    {
        controlLost = false;
        if (!controlledWalk.finalized)
        {
            controlledWalk.update(int.max / 4); // no further: it stops where the server has it now
            map.sendToWatchers(this, Opcode.SMSG_MONSTER_MOVE, monsterStop(player.guid, player.position,
                controlledWalkId), true);
        }
        controlledWalk = MoveSpline.init;
        map.relocated(this);
        sendClientControl(true);
    }

    private void sendClientControl(bool enabled)
    {
        ByteWriter w;
        w.putPackedGuid(player.guid);
        w.put(ubyte(enabled));
        deliver(Opcode.SMSG_CLIENT_CONTROL_UPDATE, w.data);
    }

    /**
     * The next stretch: feared, about 10 yards away from its fear's caster (a little to one side or the other);
     * disoriented, 3 to 6 yards any way. The ground there, or where it stands.
     */
    private void walkOn(bool feared)
    {
        import std.math : atan2, cos, sin, PI;
        import std.random : uniform;

        const at = player.position;
        float angle, distance;
        if (feared)
        {
            Position from = at;
            foreach (aura; player.auras.list)
                if (aura.has(AuraType.modFear))
                    if (auto caster = map.unit(aura.caster))
                    {
                        from = caster.position;
                        break;
                    }
            angle = (from.x == at.x && from.y == at.y) ? uniform(0.0f, 2 * PI, map.random)
                : atan2(at.y - from.y, at.x - from.x) + uniform(-0.6f, 0.6f, map.random);
            distance = 10;
        }
        else
        {
            angle = uniform(0.0f, 2 * PI, map.random);
            distance = uniform(3.0f, 6.0f, map.random);
        }
        const x = at.x + distance * cos(angle), y = at.y + distance * sin(angle);
        auto z = map.groundHeight(x, y, at.z + 2, false);
        if (!(z > -100_000) || z > at.z + 4) // nowhere to stand, or a wall: stay a moment and try again
            z = at.z;
        const speed = feared ? player.speeds[MoveType.run] : player.speeds[MoveType.walk];
        controlledWalk = MoveSpline([Vector3(at.x, at.y, at.z), Vector3(x, y, z)],
            feared ? SplineFlags.runMode : SplineFlags.none, speed > 0 ? speed : 2.5f, ++controlledWalkId);
        controlledRelocate = 500;
        map.sendToWatchers(this, Opcode.SMSG_MONSTER_MOVE, monsterMove(player.guid, controlledWalk), true);
    }
}

/// Feared: the client loses control, the server walks the player (seen by it), it cannot cast; then control is back.
unittest
{
    import core.time : msecs;
    import std.algorithm.searching : canFind;
    import dmangos.auth.accounts : AccountLevel;
    import dmangos.world.auras : makeAura, AuraType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.player : Player;
    import dmangos.world.spellcast : SpellCastResult, SpellTargets, TargetFlags;
    import dmangos.world.spellids : SpellEffect, ImplicitTarget;
    import dmangos.world.spells : SpellInfo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;
    import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto scream = SpellInfo(8122);
    scream.effect[0] = SpellEffect.applyAura;
    scream.casting.applyAuraName[0] = AuraType.modFear;
    context.data.spells.spells[8122] = scream;
    auto bolt = SpellInfo(90001);
    bolt.effect[0] = SpellEffect.dummy;
    bolt.implicitTargetA[0] = ImplicitTarget.caster;
    context.data.spells.spells[90001] = bolt;

    auto priest = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    priest.read();
    auto session = priest.session.inWorld;
    auto me = cast(Player) priest.session.character;
    auto fear = makeAura((8122 in context.data.spells.spells), 0, 10, 8000, false, [0, 0, 0]);
    session.addAura(fear);
    assert(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.fleeing, "fleeing on its flags");
    assert(session.castSpell((90001 in context.data.spells.spells), SpellTargets(TargetFlags.self, 0), false, 0)
        == SpellCastResult.fleeing, "no casting while feared");
    priest.read();
    priest.session.update(100.msecs);
    const got = opcodesOf(priest.read());
    assert(got.canFind(Opcode.SMSG_CLIENT_CONTROL_UPDATE) && got.canFind(Opcode.SMSG_MONSTER_MOVE),
        "control taken, and the walk shown to the player itself");
    assert(!session.inControl);
    const start = me.position;
    priest.session.update(1000.msecs);
    assert(me.position.x != start.x || me.position.y != start.y, "the server moves it");

    session.removeAura(fear);
    assert(!(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.fleeing));
    priest.read();
    priest.session.update(100.msecs);
    assert(opcodesOf(priest.read()).canFind(Opcode.SMSG_CLIENT_CONTROL_UPDATE) && session.inControl, "control back");
}
