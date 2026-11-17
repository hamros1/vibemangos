/**
 * The pet's AI (CMaNGOS's `PetAI`), mixed into `dmangos.world.creatureai.CreatureAI`: a creature
 * with an owner (`Creature.petOwner`) runs `petUpdate` instead of a creature's fight. It has no
 * threat list and never evades. It attacks what its owner tells it to (`petAttack`), and unless
 * passive it also attacks what attacks it or its owner, or what its owner attacks (`OwnerAttacked`,
 * `OwnerAttackedBy`). When its victim is dead or gone it goes back to its owner, following at a
 * yard and a half to its left (`m_followDist`, `m_followAngle`), or to where it was told to stay.
 * Spells set to cast by themselves (`ACT_ENABLED`) are cast at its victim as their cooldowns allow;
 * the imp casts from 25 yards and does not melee.
 */
module dmangos.world.petai;

/// `PetAI::m_followDist`, `m_followAngle`: a yard and a half, a quarter turn left of the owner.
enum float petFollowDistance = 1.5f;
/// ditto
enum float petFollowAngle = 1.5707964f;

/// `SPELL_ATTR_EX_NO_AUTOCAST_AI`
enum uint spellAttrExNoAutocast = 0x0002_0000;

/// `IsAutocastable`: neither passive nor marked not to be autocast.
bool isAutocastable(const ref imported!"dmangos.world.spells".SpellInfo spell) pure nothrow @nogc @safe
{
    return !spell.isPassive && !(spell.attributesEx & spellAttrExNoAutocast);
}

/// See the module documentation.
mixin template PetBehaviour()
{
    import std.math : cos, sin, PI;
    import dmangos.world.motion : launch, stopMoving;
    import dmangos.vmap.math : Vector3;
    import dmangos.world.movement : Position;
    import dmangos.world.pet : ActiveState, CommandState, PetState;
    import dmangos.world.petai : isAutocastable, petFollowAngle, petFollowDistance;
    import dmangos.world.relations : canAttack;
    import dmangos.world.spells : SpellInfo;

    private
    {
        Position followedTo;        // where the owner was when it last set off after it
        int[uint] petCooldowns;     // its spells' cooldowns left, in milliseconds
        int lookTimer;              // until an aggressive pet next looks around
    }

    /// The imp's way (`m_attackDistance`, `m_meleeEnabled`): it casts from `distance` and never melees.
    void petRangedAttacker(float distance)
    {
        meleeEnabled = false;
        rangedMode_ = true;
        chaseDistance_ = distance;
    }

    /// Its pet state (`Creature.petData`).
    @property PetState pet()
    {
        return cast(PetState) me.petData;
    }

    /// `CharmInfo::GetCommandState`
    @property CommandState petCommand()
    {
        return pet.command;
    }

    /// `PetAI::AttackStart`: attacks `who`, chasing it (or casting from afar, the imp).
    void petAttack(Combatant who, CombatWorld world)
    {
        world_ = world;
        if (!me.alive || who is null || who.combatGuid == me.guid)
            return;
        if (victim == who.combatGuid)
            return;
        if (victim)
            meleeStop(world);
        victim = who.combatGuid;
        me.values.set!UNIT_FIELD_TARGET(victim);
        if (!inCombat_)
        {
            inCombat_ = true;
            me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS | UnitFlags.inCombat);
        }
        if (meleeEnabled && !meleeAttacking)
        {
            meleeAttacking = true;
            world.sendToObservers(me.guid, Opcode.SMSG_ATTACKSTART, attackStartPacket(me.guid, victim));
        }
        chasedTo = Position.init;
        world.flushCreature(me);
        world.wake(me.guid);
    }

    /// `AttackStop` and `CombatStop`: it stops fighting and goes back to its owner (or its place).
    void petStopAttack(CombatWorld world)
    {
        world_ = world;
        interruptCast();
        meleeStop(world);
        victim = 0;
        inCombat_ = false;
        me.values.set!UNIT_FIELD_TARGET(0UL);
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.inCombat);
        followedTo = Position.init;
        world.flushCreature(me);
    }

    /// `OwnerAttackedBy`, `OwnerAttacked`, and its own `AttackedBy`: unless passive, staying out of
    /// it, or already fighting, it attacks.
    void petAssist(Combatant enemy, CombatWorld world)
    {
        if (react == ReactState.passive || victim || !me.alive || enemy is null)
            return;
        if (!enemy.fighter.alive || !canAttack(relating, enemy.relating, me.client))
            return;
        petAttack(enemy, world);
    }

    /// `PetAI::UpdateAI`
    void petUpdate(CombatWorld world, int diff)
    {
        world_ = world;
        attackTimer = attackTimer > diff ? attackTimer - diff : 0;
        foreach (spell; petCooldowns.keys)
            if ((petCooldowns[spell] -= diff) <= 0)
                petCooldowns.remove(spell);
        updateCasting(diff);
        if (!me.alive)
            return;
        if (victim)
        {
            auto target = world.combatant(victim);
            if (target is null || !target.fighter.alive || target.untouchable
                || !canAttack(relating, target.relating, me.client))
                petStopAttack(world);
            else
            {
                if (casting_ !is null)
                {
                    me.movement.position.orientation = angleTo(me.position, target.fighter.position);
                    return;
                }
                petAutocast(world);
                if (casting_ !is null)
                    return;
                chase(target, world);
                meleeAttackIfReady(target, world);
                return;
            }
        }
        regenerate(world, diff);
        if (react == ReactState.aggressive && pet.command != CommandState.stay && (lookTimer -= diff) <= 0)
        {
            lookTimer = 1000;
            if (petLookAround(world))
                return;
        }
        Position owner;
        if (!world.positionOf(me.petOwner, owner))
            return;
        if (pet.command == CommandState.stay)
            return petHoldStay(world);
        petFollow(owner, world);
    }

    /**
     * `PetAI::MoveInLineOfSight` of an aggressive pet: the nearest enemy (not a civilian) within its
     * attack distance and in sight. Whether it found one.
     */
    private bool petLookAround(CombatWorld world)
    {
        import dmangos.world.relations : isEnemy;

        Creature best;
        float bestDistance = float.max;
        foreach (other; world.creaturesNear(me.position, 45))
        {
            if (other is me || !other.alive || other.petOwner || other.template_.civilian || other.ai is null)
                continue;
            const otherRelating = other.ai.relatingOf;
            if (!canAttack(relating, otherRelating, me.client) || !isEnemy(relating, otherRelating, me.client))
                continue;
            const distance = moved(me.position, other.position);
            if (distance > other.ai.attackDistanceTo(me.fighter) || distance >= bestDistance)
                continue;
            if (!world.inLineOfSight(me.position, other.position))
                continue;
            best = other;
            bestDistance = distance;
        }
        if (best is null)
            return false;
        petAttack(world.combatantOf(best), world);
        return victim != 0;
    }

    /**
     * A spell its owner tells it to cast (`CMSG_PET_ACTION`, `CMSG_PET_CAST_SPELL`) at `target` (0: its
     * victim, or itself); at an enemy, it attacks it too. Whether it is cast.
     */
    bool petCastByCommand(const(SpellInfo)* info, ulong target, CombatWorld world)
    {
        world_ = world;
        if (info is null || info.id in petCooldowns || !me.alive)
            return false;
        Combatant enemy;
        if (target && target != me.guid)
        {
            enemy = world.combatant(target);
            if (enemy is null)
                if (auto creature = world.creatureAt(target))
                    if (creature.petOwner != me.petOwner)
                        enemy = world.combatantOf(creature);
            if (enemy !is null && !canAttack(relating, enemy.relating, me.client))
                enemy = null;
        }
        if (!castSpell(info, target, 0))
            return false;
        const cooldown = info.recoveryTime > info.categoryRecoveryTime ? info.recoveryTime : info.categoryRecoveryTime;
        if (cooldown)
            petCooldowns[info.id] = cooldown;
        if (enemy !is null && victim != enemy.combatGuid && react != ReactState.passive)
            petAttack(enemy, world);
        return true;
    }

    /// The spells it casts by itself, at its victim, when ready and in range.
    private void petAutocast(CombatWorld world)
    {
        if (lore is null)
            return;
        foreach (s; pet.spells)
        {
            if (s.active != ActiveState.enabled || s.spell in petCooldowns)
                continue;
            const info = lore.spellInfo(s.spell);
            if (info is null || !isAutocastable(*info))
                continue;
            if (castSpell(info, victim, 0))
            {
                const cooldown = info.recoveryTime > info.categoryRecoveryTime ? info.recoveryTime
                    : info.categoryRecoveryTime;
                if (cooldown)
                    petCooldowns[s.spell] = cooldown;
                return;
            }
        }
    }

    /// `MoveStay`: back to where it was told to stay.
    private void petHoldStay(CombatWorld world)
    {
        if (!pet.hasStay)
        {
            pet.hasStay = true;
            pet.stayAt = me.position;
            return;
        }
        if (moved(me.position, pet.stayAt) < 1 || !me.spline.finalized)
            return;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(pet.stayAt.x, pet.stayAt.y, pet.stayAt.z)];
        launch(me, world, points, false);
    }

    /// `FollowMovementGenerator`: to its place beside its owner, setting off again when it moved on.
    private void petFollow(Position owner, CombatWorld world)
    {
        const angle = owner.orientation + petFollowAngle;
        const x = owner.x + petFollowDistance * cos(angle), y = owner.y + petFollowDistance * sin(angle);
        const close = moved(me.position, Position(x, y, owner.z)) < 1;
        if (close)
        {
            if (!me.spline.finalized && moved(followedTo, owner) > 0.5f)
                stopMoving(me, world);
            else if (me.spline.finalized && abs(me.position.orientation - owner.orientation) > 0.1f)
                me.movement.position.orientation = owner.orientation;
            return;
        }
        if (!me.spline.finalized && moved(followedTo, owner) < 1)
            return;
        auto z = world.groundHeight(x, y, owner.z + 2, false);
        if (!(z > -100_000))
            z = owner.z;
        followedTo = owner;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(x, y, z)];
        // As fast as its owner runs, to keep up (`UpdateSpeed` from the owner's).
        launch(me, world, points, false, owner.orientation);
    }

    private static float abs(float v)
    {
        return v < 0 ? -v : v;
    }
}
