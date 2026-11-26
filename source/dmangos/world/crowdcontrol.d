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
    import dmangos.world.auras : Aura, AuraType;
    import dmangos.world.defines : UnitFlags;
    import dmangos.world.movement : MovementFlags, MoveType, Position;
    import dmangos.world.opcodes : Opcode;
    import dmangos.world.spline : MoveSpline, monsterMove, monsterStop, SplineFlags;
    import dmangos.world.updatefields : UNIT_FIELD_FLAGS;

    private MoveSpline controlledWalk;   // the walk the server leads it on, while it is not in control
    private bool controlLost;            // the client was told it has no control
    private uint controlledWalkId;
    private int controlledRelocate;      // until the map is next told where it is, in milliseconds
    private int controlledRetry;         // delay before trying a blocked route again

    private ulong npcCharmer;
    private uint factionBeforeCharm;
    private int charmDecision;

    private void npcCharmChanged(Aura aura, bool apply)
    {
        import dmangos.world.updatefields : UNIT_FIELD_CHARMEDBY, UNIT_FIELD_FACTIONTEMPLATE;
        import dmangos.world.spellcast : SpellCastResult;
        if (apply)
        {
            auto caster = map is null ? null : map.creatureAt(aura.caster);
            if (caster is null || !caster.alive)
                return;
            if (!npcCharmer)
                factionBeforeCharm = player.values.get!UNIT_FIELD_FACTIONTEMPLATE;
            npcCharmer = caster.guid;
            player.values.set!UNIT_FIELD_CHARMEDBY(npcCharmer);
            player.values.set!UNIT_FIELD_FACTIONTEMPLATE(caster.values.get!UNIT_FIELD_FACTIONTEMPLATE);
            interruptCast(SpellCastResult.interrupted);
            stopAttack(false);
            if (!controlLost)
                loseControl();
            charmDecision = 0;
        }
        else if (npcCharmer && npcCharmer == aura.caster)
        {
            npcCharmer = 0;
            if (aura.spell.id == 28410)
                if (auto scale = player.auras.find(28409))
                    removeAura(scale);
            player.values.set!UNIT_FIELD_CHARMEDBY(0UL);
            player.values.set!UNIT_FIELD_FACTIONTEMPLATE(factionBeforeCharm);
            stopAttack(false);
            interruptCast(SpellCastResult.interrupted);
            if (controlLost)
                regainControl();
            updateCrowdControl(0);
        }
    }

    private void releaseNpcCharm()
    {
        if (npcCharmer)
            foreach (aura; player.auras.list.dup)
                if (aura.caster == npcCharmer && aura.has(AuraType.aoeCharm))
                    removeAura(aura);
    }

    /// A charmed raider can use its learned direct heals on its master or attack another raider.
    private void obeyNpc(int ms)
    {
        import std.math : atan2, sqrt;
        import dmangos.world.combat : canReachWithMelee;
        import dmangos.world.relations : canAttack;
        import dmangos.world.spellcast : SpellTargets, TargetFlags, SpellCastResult;
        import dmangos.world.spells : ImplicitTarget, SpellEffect, SpellInfo;
        import dmangos.world.unit : UnitRef;
        auto master = map.creatureAt(npcCharmer);
        if (master is null || !master.alive)
            return releaseNpcCharm();
        if ((charmDecision -= ms) > 0 || castingSpell)
            return;
        charmDecision = 1000;
        if (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.stunned)
            return;
        UnitRef enemy;
        float best = float.max;
        const at = player.position;
        foreach (who; map.playersNear(at, 100))
        {
            if (who.session is null || who.session is this || !who.alive || who.untouchable || !canAttack(relatingNow(), who.relating, context.client))
                continue;
            // Another the same master holds is on its side (CMaNGOS: the charmer's faction, a friend).
            if (who.session.player !is null && who.session.player.values.get!(imported!"dmangos.world.updatefields".UNIT_FIELD_CHARMEDBY) == npcCharmer)
                continue;
            const d = (at.x - who.position.x) ^^ 2 + (at.y - who.position.y) ^^ 2 + (at.z - who.position.z) ^^ 2;
            if (d < best)
            {
                best = d;
                enemy = who;
            }
        }
        const(SpellInfo)* heal, attack;
        foreach (id; player.spells)
        {
            auto spell = context.data.spells.spell(id);
            if (spell is null || spell.isPassive || !spell.casting.spellFamilyName)
                continue;
            if (spell.hasEffect(SpellEffect.heal) && spell.implicitTargetA[0] == ImplicitTarget.friend
                && (heal is null || spell.spellLevel > heal.spellLevel))
                heal = spell;
            if (spell.hasEffect(SpellEffect.schoolDamage) && spell.implicitTargetA[0] == ImplicitTarget.enemy
                && (attack is null || spell.spellLevel > attack.spellLevel))
                attack = spell;
        }
        if (heal !is null && map.unitOf(master).healthPercent < 100
            && castSpell(heal, SpellTargets(TargetFlags.unit, master.guid), false, 0) == SpellCastResult.ok)
            return;
        if (!enemy)
            return;
        auto to = enemy.position;
        player.movement.position.orientation = atan2(to.y - at.y, to.x - at.x);
        if (attack !is null && castSpell(attack, SpellTargets(TargetFlags.unit, enemy.combatGuid), false, 0) == SpellCastResult.ok)
            return;
        if (attacking != enemy.combatGuid)
            attackPlayer(enemy.session);
        if (canReachWithMelee(player.fighter, enemy.fighter) || player.auras.hasType(AuraType.modRoot))
            return;
        const speed = player.speeds[MoveType.run];
        if (speed <= 0 || best <= 1)
            return;
        const distance = sqrt(best);
        const fraction = distance <= speed ? 1 : speed / distance;
        beginControlledWalk(Vector3(at.x + fraction * (to.x - at.x), at.y + fraction * (to.y - at.y),
            at.z + fraction * (to.z - at.z)), true);
    }

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
        if ((!feared && !confused && !npcCharmer) || player.deathState != imported!"dmangos.world.player".DeathState.alive)
        {
            if (controlLost)
                regainControl();
            return;
        }
        if (!controlLost)
        {
            // Let a jump or fall finish before taking over the player's movement.
            if (player.movement.flags & (MovementFlags.jumping | MovementFlags.fallingFar))
                return;
            loseControl();
        }
        const immobilized = (player.values.get!UNIT_FIELD_FLAGS & UnitFlags.stunned)
            || player.auras.hasType(AuraType.modRoot);
        if (immobilized && !controlledWalk.finalized)
        {
            stopControlledWalk();
            map.relocated(this);
        }
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
        if (feared || confused)
        {
            if (!immobilized && (controlledRetry -= ms) <= 0)
                walkOn(feared);
        }
        else
            obeyNpc(ms);
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
        stopControlledWalk();
        controlledRetry = 0;
        resetMovementCheck();
        map.relocated(this);
        sendClientControl(true);
    }

    private void stopControlledWalk()
    {
        if (!controlledWalk.finalized)
            map.sendToWatchers(this, Opcode.SMSG_MONSTER_MOVE, monsterStop(player.guid, player.position,
                controlledWalkId), true);
        controlledWalk = MoveSpline.init;
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
        beginControlledWalk(Vector3(at.x + distance * cos(angle), at.y + distance * sin(angle), at.z), feared);
    }

    private void beginControlledWalk(Vector3 destination, bool run)
    {
        const at = player.position;
        const from = Vector3(at.x, at.y, at.z);
        Vector3[] path;
        if (!player.movement.has(MovementFlags.onTransport))
        {
            if (player.movement.has(MovementFlags.swimming))
                map.pathInWater(from, destination, 1.0f, path);
            else
                path = map.controlledGroundPath(from, destination);
        }
        if (path.length < 2)
        {
            controlledRetry = 250;
            return;
        }
        const speed = player.speeds[run ? MoveType.run : MoveType.walk];
        controlledWalk = MoveSpline(path, run ? SplineFlags.runMode : SplineFlags.none,
            speed > 0 ? speed : 2.5f, ++controlledWalkId);
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
    auto stun = SpellInfo(90002);
    stun.effect[0] = SpellEffect.applyAura;
    stun.casting.applyAuraName[0] = AuraType.modStun;
    context.data.spells.spells[90002] = stun;

    auto priest = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f), AccountLevel.player);
    priest.read();
    auto session = priest.session.inWorld;
    auto me = cast(Player) priest.session.character;
    session.currentMap.testGroundHeight = (float x, float y, float z) => 83.53f;
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

    auto cower = makeAura((90002 in context.data.spells.spells), 0, 10, 4000, false, [0, 0, 0]);
    session.addAura(cower);
    const stoppedAt = me.position;
    priest.session.update(1000.msecs);
    assert(me.position == stoppedAt, "a stun stops a fear spline at the player's current position");
    session.removeAura(cower);
    priest.session.update(100.msecs);
    priest.session.update(1000.msecs);
    assert(me.position != stoppedAt, "fleeing continues if the stun expires before the fear");

    session.removeAura(fear);
    assert(!(me.values.get!UNIT_FIELD_FLAGS & UnitFlags.fleeing));
    priest.read();
    priest.session.update(100.msecs);
    assert(opcodesOf(priest.read()).canFind(Opcode.SMSG_CLIENT_CONTROL_UPDATE) && session.inControl, "control back");
}

/// The straight line near the Farm passes below the sloping ground even though both ends are on it.
unittest
{
    import std.math : abs;
    import dmangos.vmap.math : Vector3;
    import dmangos.world.realspelltests : haveRealData, RealWorld;

    if (!haveRealData())
        return;
    auto world = RealWorld.make(529, true);
    auto map = world.context.map(529);
    assert(map.collision !is null);
    map.testPaths = (Vector3 start, Vector3 end) => null; // loaded terrain while movement tiles load
    Vector3 from = Vector3(720.224f, 732.896f, -29.7667f);
    Vector3 to = Vector3(725.224f, 741.5563f, -33.7533f);
    from.z = map.groundHeight(from.x, from.y, from.z, false);
    to.z = map.groundHeight(to.x, to.y, to.z, false);
    bool straightPathBuried;
    foreach (sample; 1 .. 20)
    {
        const at = from + (to - from) * (sample / 20.0f);
        straightPathBuried |= map.groundHeight(at.x, at.y, at.z, false) > at.z + 0.15f;
    }
    assert(straightPathBuried);
    const path = map.controlledGroundPath(from, to);
    assert(path.length > 2 && (path[$ - 1] - to).magnitude < 0.1f);
    foreach (i; 1 .. path.length)
    {
        const at = (path[i - 1] + path[i]) * 0.5f;
        assert(abs(map.groundHeight(at.x, at.y, at.z, false) - at.z) < 0.15f,
            "every short segment stays on the Arathi Basin slope");
    }
}
