/**
 * Creatures that fight: CMaNGOS's base creature AI (`AI/BaseAI/UnitAI.cpp`, `CreatureAI.cpp`), its
 * threat list (`Combat/ThreatManager.cpp`), its combat timers and leash (`Combat/CombatManager.cpp`),
 * chasing (`ChaseMovementGenerator`) and going home (`HomeMovementGenerator`), and a creature's
 * half of melee (`Unit::Attack`, `UpdateMeleeAttackingState`).
 *
 * Every creature gets this AI: CMaNGOS's EventAI (`creature_ai_scripts`) and the guards' scripts
 * build on it, and their spells and texts come with spells. A creature with
 * `CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT` is defensive: it fights back but attacks nobody on sight.
 * Creatures do not call for help or assist each other yet, and chase in straight lines (no
 * movement maps).
 */
module dmangos.world.creatureai;

import std.math : atan2, cos, sin, sqrt;

import dmangos.world.combat;
alias attackStartPacket = dmangos.world.combat.attackStart;
import dmangos.world.creature : Creature;
import dmangos.world.defines : UnitFlags;
import dmangos.world.motion : IdleMovement, launch, MotionWorld, MovementGenerator, stopMoving;
import dmangos.world.movement : MovementFlags, Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.relations;
import dmangos.world.updatefields;
import dmangos.vmap.math : Vector3;

/// A player a creature can fight, as the creature sees it (`WorldSession` implements it).
interface Combatant
{
    /// Its guid.
    @property ulong combatGuid() const;

    /// What the melee formulas need of it now.
    Fighter fighter() const;

    /// How the relations see it.
    Relating relating();

    /// A creature's swing landed (or not): `Unit::DealDamage` and what follows, on its side.
    void meleeHitBy(ulong attacker, const ref MeleeDamage damage);

    /// A creature has it in its threat list now, or no longer (`HostileRefManager`): it is in combat while any does.
    void threatAdded(ulong creature);
    /// ditto
    void threatRemoved(ulong creature);
}

/// What a creature's AI needs of its map.
interface CombatWorld : MotionWorld
{
    /// The player with this guid on the map, if it can fight; null otherwise.
    Combatant combatant(ulong guid);

    /// `IsWithinLOSInMap`: whether nothing built stands between two points (at eye height).
    bool inLineOfSight(Position a, Position b);

    /// Sends what changed in the creature's fields to those who see it.
    void flushCreature(Creature creature);

    /// Puts a resting creature back in the tick.
    void wake(ulong guid);

    /// A dead creature's corpse has lasted its time: it goes, and comes back when its respawn time is up.
    void corpseExpired(Creature creature);
}

/// `ReactStates`
enum ReactState : ubyte
{
    passive,    /// never attacks
    defensive,  /// fights back
    aggressive, /// also attacks on sight
}

/// `CONFIG_FLOAT_LEASH_RADIUS`: past this from where its timer last started, a creature's victim is out of reach.
enum float leashRadius = 30;

/// `REGEN_TIME_FULL_UNIT`: out of combat a creature gets a third of its health back this often.
enum int regenInterval = 5000;

/// `COMBAT_MANAGER_TICK`
enum int combatManagerTick = 1200;

/// `AI_REACTION_HOSTILE`
enum uint aiReactionHostile = 2;

/// See the module documentation.
final class CreatureAI
{
    private
    {
        Creature me;
        float[ulong] threat;       // `ThreatManager`: who it fights, and how much each has done to it
        ulong victim;              // `m_attacking`: whom it attacks
        bool meleeAttacking;       // `UNIT_STAT_MELEE_ATTACKING`
        bool inCombat_;
        bool evadingHome;          // `EVADE_HOME`: running back, ignoring everything
        int attackTimer;           // until the next swing
        int combatTimer;           // `CombatManager::m_combatTimer`: the pursuit time left
        int combatTick;            // until the next leash check
        int regenTimer;
        Position lastRefresh;      // where it was when its combat timer last started
        Position combatStart;      // where the fight began: it goes back there
        Position chasedTo;         // where the target was when it last set off after it
        MovementGenerator outOfCombat; // how it moved before the fight
    }

    ReactState react;

    ///
    this(Creature me)
    {
        enum uint noAggroOnSight = 0x02; // CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT
        this.me = me;
        react = (me.template_.extraFlags & noAggroOnSight) ? ReactState.defensive : ReactState.aggressive;
    }

    /// `IsInCombat`
    @property bool inCombat() const
    {
        return inCombat_;
    }

    /// `CombatManager::IsInEvadeMode`: running home; attacks on it are evaded.
    @property bool evading() const
    {
        return evadingHome;
    }

    /// Whether it has anything to do in the tick: a fight, the way home, or health to get back.
    @property bool active() const
    {
        return inCombat_ || evadingHome || me.values.get!UNIT_FIELD_HEALTH < me.values.get!UNIT_FIELD_MAXHEALTH;
    }

    /// The one it attacks; 0 if none.
    @property ulong currentVictim() const
    {
        return victim;
    }

    /// The threat `who` has on it; 0 if it is not in its list.
    float threatOf(ulong who) const
    {
        return threat.get(who, 0);
    }

    // -----------------------------------------------------------------------
    // What happens to it
    // -----------------------------------------------------------------------

    /**
     * `UnitAI::MoveInLineOfSight`: a player came into sight, or it came into a player's. An
     * aggressive creature that may attack it on sight attacks it if it is within its aggro radius
     * and line of sight.
     */
    void moveInLineOfSight(Combatant who, CombatWorld world)
    {
        if (react != ReactState.aggressive || victim || evadingHome || !me.alive)
            return;
        if (me.factionTemplate !is null && isNeutralToAll(*me.factionTemplate))
            return;
        if (me.values.get!UNIT_FIELD_FLAGS & (UnitFlags.spawning | UnitFlags.uninteractible)) // `CanInitiateAttack`
            return;
        const target = who.fighter;
        if (!target.alive)
            return;
        // `CanAttackOnSight`: may attack it, and is its enemy.
        const self = relating, other = who.relating;
        if (!canAttack(self, other, me.client) || !isEnemy(self, other, me.client))
            return;
        // `DetectOrAttack`: within the aggro radius and in sight.
        const radius = attackDistance(target);
        const dx = me.position.x - target.position.x, dy = me.position.y - target.position.y,
            dz = me.position.z - target.position.z;
        if (dx * dx + dy * dy + dz * dz > radius * radius)
            return;
        if (!world.inLineOfSight(me.position, target.position))
            return;
        if (!inCombat_)
            attackStart(who, world);
    }

    /// `UnitAI::AttackedBy`: hit (or swung at) by `attacker`; it fights back if it is not fighting yet.
    void attackedBy(Combatant attacker, CombatWorld world)
    {
        if (!me.alive || evadingHome)
            return;
        if (!inCombat_ && !victim)
            attackStart(attacker, world);
        else
            addThreat(attacker, 0);
    }

    /// `HandleDamageDealt`'s threat: what `attacker` did to it; direct damage restarts its combat timer.
    void damageTaken(Combatant attacker, uint damage)
    {
        if (!me.alive || evadingHome)
            return;
        addThreat(attacker, damage);
        if (damage)
            triggerCombatTimer();
    }

    /// It died: it fights nobody any more.
    void died(CombatWorld world)
    {
        foreach (guid, _; threat)
            notifyRemoved(guid, world);
        threat = null;
        victim = 0;
        meleeAttacking = false;
        inCombat_ = evadingHome = false;
    }

    // -----------------------------------------------------------------------
    // The update
    // -----------------------------------------------------------------------

    /**
     * `Creature::Update`'s AI part: the combat timers and leash, `UpdateAI` (choosing its victim,
     * evading when there is none, chasing, swinging), and regeneration out of combat.
     */
    void update(CombatWorld world, int diff)
    {
        if (!me.alive)
            return;
        attackTimer = attackTimer > diff ? attackTimer - diff : 0;
        if (evadingHome)
        {
            if (me.spline.finalized)
                reachedHome(world);
        }
        else if (inCombat_)
        {
            updateCombatManager(world, diff);
            if (inCombat_)
                updateAI(world);
        }
        if (!inCombat_)
            regenerate(world, diff);
    }

private:
    /// How the relations see it.
    @property Relating relating() const
    {
        return Relating(me.values.get!UNIT_FIELD_FLAGS, me.factionTemplate, false, 0, 0, me.alive);
    }

    /// `Unit::GetAttackDistance`: its detection range, a yard more for each level its target is below it.
    float attackDistance(const Fighter target) const
    {
        const self = me.fighter;
        int levelDiff = int(levelFor(target, self)) - int(levelFor(self, target));
        if (levelDiff < -25)
            levelDiff = -25;
        float distance = me.template_.detection;
        if (distance == 0)
            return 0;
        distance -= levelDiff;
        return distance < 5 ? 5 : distance;
    }

    /// `ThreatManager::addThreat`: a new entry tells the player it is in combat.
    void addThreat(Combatant who, float amount)
    {
        const guid = who.combatGuid;
        if (auto t = guid in threat)
            *t += amount;
        else
        {
            threat[guid] = amount;
            who.threatAdded(me.guid);
        }
    }

    void notifyRemoved(ulong guid, CombatWorld world)
    {
        if (world !is null)
            if (auto who = world.combatant(guid))
                who.threatRemoved(me.guid);
    }

    /**
     * `UnitAI::AttackStart`: attacks `who` (`Unit::Attack`), enters combat with it
     * (`EngageInCombatWith`), and chases it.
     */
    void attackStart(Combatant who, CombatWorld world)
    {
        if (react == ReactState.passive || !me.alive)
            return;
        const guid = who.combatGuid;
        if (victim == guid)
            return;
        if (victim)
            meleeStop(world);
        victim = guid;
        me.values.set!UNIT_FIELD_TARGET(guid);
        if (!meleeAttacking)
        {
            meleeAttacking = true;
            world.sendToObservers(me.guid, Opcode.SMSG_ATTACKSTART, attackStartPacket(me.guid, guid));
        }
        import dmangos.bytes : ByteWriter;

        ByteWriter reaction;
        reaction.put(me.guid);
        reaction.put(aiReactionHostile);
        world.sendToObservers(me.guid, Opcode.SMSG_AI_REACTION, reaction.data);
        addThreat(who, 0);
        if (!inCombat_)
            enterCombat(world);
        world.flushCreature(me);
        world.wake(me.guid);
    }

    /// `SetInCombatWith`: combat starts where it stands; its way of moving waits until it is home.
    void enterCombat(CombatWorld world)
    {
        inCombat_ = true;
        combatStart = me.position;
        triggerCombatTimer();
        combatTick = combatManagerTick;
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS | UnitFlags.inCombat);
        if (outOfCombat is null)
            outOfCombat = me.generator;
        me.generator = new IdleMovement;
        stopMoving(me, world);
    }

    /// `CombatManager::TriggerCombatTimer`: its pursuit time again, from where it is.
    void triggerCombatTimer()
    {
        combatTimer = me.template_.pursuit;
        lastRefresh = me.position;
    }

    /// `MeleeAttackStop`
    void meleeStop(CombatWorld world)
    {
        if (meleeAttacking)
        {
            meleeAttacking = false;
            world.sendToObservers(me.guid, Opcode.SMSG_ATTACKSTOP, attackStop(me.guid, victim, !me.alive));
        }
    }

    /**
     * `CombatManager::Update`: once its pursuit time has run out, a victim more than `leashRadius` from
     * where the timer last started has got away; past its template's leash distance from where the
     * fight began, it gives up whatever the timer says.
     */
    void updateCombatManager(CombatWorld world, int diff)
    {
        combatTimer = combatTimer > diff ? combatTimer - diff : 0;
        combatTick += diff;
        if (combatTick < combatManagerTick)
            return;
        combatTick -= combatManagerTick;
        if (combatTimer == 0 && victim)
            if (auto target = world.combatant(victim))
            {
                const at = target.fighter.position;
                const dx = at.x - lastRefresh.x, dy = at.y - lastRefresh.y;
                if (dx * dx + dy * dy > leashRadius * leashRadius)
                    return enterEvadeMode(world);
            }
        if (me.template_.leash)
        {
            const dx = me.position.x - combatStart.x, dy = me.position.y - combatStart.y;
            if (dx * dx + dy * dy > float(me.template_.leash) ^^ 2)
                return enterEvadeMode(world);
        }
    }

    /**
     * `UnitAI::UpdateAI`: `SelectHostileTarget` (the threat list without those gone, dead or no longer
     * to be attacked; evading if nobody is left), then chasing and `DoMeleeAttackIfReady`.
     */
    void updateAI(CombatWorld world)
    {
        ulong[] gone;
        foreach (guid, _; threat)
        {
            auto who = world.combatant(guid);
            if (who is null || !who.fighter.alive || !canAttack(relating, who.relating, me.client))
                gone ~= guid;
        }
        foreach (guid; gone)
        {
            threat.remove(guid);
            notifyRemoved(guid, world);
        }
        if (threat.length == 0)
            return enterEvadeMode(world);
        auto target = world.combatant(selectNextVictim(world));
        if (target.combatGuid != victim)
            attackStart(target, world);
        chase(target, world);
        meleeAttackIfReady(target, world);
    }

    /**
     * `ThreatContainer::selectNextVictim`: the most hated, but the current victim keeps its place
     * unless another has more than 110% of its threat in melee reach, or 130% anywhere.
     */
    ulong selectNextVictim(CombatWorld world)
    {
        import std.algorithm.sorting : sort;

        auto order = threat.keys;
        order.sort!((a, b) => threat[a] > threat[b] || (threat[a] == threat[b] && a < b));
        const current = victim in threat;
        if (current is null)
            return order[0];
        const self = me.fighter;
        foreach (guid; order)
        {
            if (guid == victim)
                return victim;
            const t = threat[guid];
            if (t <= 1.1f * *current)
                return victim;
            auto who = world.combatant(guid);
            const inMelee = who !is null && canReachWithMelee(self, who.fighter);
            if (t > 1.3f * *current || (t > 1.1f * *current && inMelee))
                return guid;
        }
        return victim;
    }

    /**
     * `ChaseMovementGenerator`: runs to its target until it can reach it, setting off again when the
     * target has moved on, and faces it (`SetInFront`).
     */
    void chase(Combatant target, CombatWorld world)
    {
        const self = me.fighter, other = target.fighter;
        me.movement.position.orientation = angleTo(me.position, other.position);
        if (canReachWithMelee(self, other))
        {
            if (!me.spline.finalized && moved(chasedTo, other.position) > 0.5f)
                stopMoving(me, world);
            return;
        }
        if (!me.spline.finalized && moved(chasedTo, other.position) < 1)
            return;
        // To a point just within reach, on the line between the two.
        const reach = meleeReach(self, other) - 1;
        const angle = angleTo(other.position, me.position);
        const x = other.position.x + reach * cos(angle), y = other.position.y + reach * sin(angle);
        auto z = world.groundHeight(x, y, other.position.z + 2, false);
        if (!(z > -100_000))
            z = other.position.z;
        chasedTo = other.position;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(x, y, z)];
        launch(me, world, points, false);
    }

    /// `UpdateMeleeAttackingState` for a creature: a swing whenever it is ready and can.
    void meleeAttackIfReady(Combatant target, CombatWorld world)
    {
        import std.math : PI;

        if (!meleeAttacking || attackTimer)
            return;
        const self = me.fighter, other = target.fighter;
        if (!canReachWithMelee(self, other) || !hasInArc(self.position, other.position, 2 * PI / 3) || !other.alive)
        {
            attackTimer = 100; // delaying a weapon that is not ready would make it ready sooner
            return;
        }
        auto d = calculateMeleeDamage(self, other, AttackType.mainHand, world.random);
        world.sendToObservers(me.guid, Opcode.SMSG_ATTACKERSTATEUPDATE, attackerStateUpdate(d));
        attackTimer = me.values.get!UNIT_FIELD_BASEATTACKTIME;
        if (d.damage)
            triggerCombatTimer(); // direct damage either way
        target.meleeHitBy(me.guid, d);
    }

    /**
     * `UnitAI::EnterEvadeMode`: stops fighting (`CombatStop`), forgets its threat list, and runs back
     * to where the fight began, evading every attack on the way.
     */
    void enterEvadeMode(CombatWorld world)
    {
        meleeStop(world);
        foreach (guid, _; threat)
            notifyRemoved(guid, world);
        threat = null;
        victim = 0;
        inCombat_ = false;
        me.setLootRecipient(0, 0); // `TriggerEvadeEvents`: nobody's any more
        me.values.set!UNIT_FIELD_TARGET(0UL);
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.inCombat);
        world.flushCreature(me);
        evadingHome = true;
        regenTimer = 0;
        const home = combatStart;
        const dx = home.x - me.position.x, dy = home.y - me.position.y;
        if (dx * dx + dy * dy < 0.01f)
            return reachedHome(world);
        Vector3[] points = [Vector3(0, 0, 0), Vector3(home.x, home.y, home.z)];
        launch(me, world, points, false, home.orientation);
    }

    /// `HomeMovementGenerator::Finalize`: home; it moves as before the fight.
    void reachedHome(CombatWorld world)
    {
        evadingHome = false;
        if (outOfCombat !is null)
        {
            me.generator = outOfCombat;
            outOfCombat = null;
            me.generator.initialize(me, world);
        }
    }

    /// `Creature::RegenerateAll`: a third of its health every five seconds out of combat.
    void regenerate(CombatWorld world, int diff)
    {
        const health = me.values.get!UNIT_FIELD_HEALTH, maximum = me.values.get!UNIT_FIELD_MAXHEALTH;
        if (health >= maximum)
            return;
        regenTimer += diff;
        if (regenTimer < regenInterval)
            return;
        regenTimer -= regenInterval;
        const added = health + maximum / 3;
        me.values.set!UNIT_FIELD_HEALTH(added > maximum ? maximum : added);
        world.flushCreature(me);
    }

    static float angleTo(Position from, Position to)
    {
        import std.math : PI;

        const a = atan2(to.y - from.y, to.x - from.x);
        return a < 0 ? a + 2 * PI : a;
    }

    static float moved(Position a, Position b)
    {
        const dx = a.x - b.x, dy = a.y - b.y;
        return sqrt(dx * dx + dy * dy);
    }
}

/// `FactionTemplateEntry::IsNeutralToAll`
bool isNeutralToAll(const ref FactionTemplateEntry t) pure nothrow @nogc @safe
{
    foreach (f; t.enemyFactions)
        if (f != 0)
            return false;
    return t.enemyGroupMask == 0 && t.friendGroupMask == 0;
}

import dmangos.world.clientdata : FactionTemplateEntry;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/**
 * A creature attacked fights back: it attacks the player, chases and hits it, and the player is in
 * combat while it does; when the player is gone it evades home and gets its health back. A hostile
 * creature attacks on sight a player who comes within its aggro radius.
 */
unittest
{
    import core.time : MonoTime, msecs, seconds;
    import std.algorithm.searching : canFind;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.creature : CreatureTemplate;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.teleport : moveTo;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(innkeeper);
    keeper.values.set!UNIT_FIELD_LEVEL(1u);
    keeper.values.set!UNIT_FIELD_MINDAMAGE(2.0f);
    keeper.values.set!UNIT_FIELD_MAXDAMAGE(3.0f);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    const myGuid = anduin.session.character.guid;

    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
    }

    // Attacked, it attacks back at once.
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    anduin.read();
    tick(50);
    assert(keeper.ai.inCombat && keeper.ai.currentVictim == myGuid && keeper.ai.threatOf(myGuid) >= 0);
    assert(keeper.values.get!UNIT_FIELD_TARGET == myGuid);
    const healthBefore = anduin.session.character.values.get!UNIT_FIELD_HEALTH;
    ushort[] seen;
    foreach (_; 0 .. 40)
    {
        tick(500);
        seen ~= opcodesOf(anduin.read());
    }
    assert(seen.canFind(Opcode.SMSG_AI_REACTION) && seen.canFind(Opcode.SMSG_ATTACKSTART));
    assert(anduin.session.character.values.get!UNIT_FIELD_HEALTH < healthBefore, "its swings land on the player");
    assert(anduin.session.character.values.get!UNIT_FIELD_FLAGS & UnitFlags.inCombat);

    // Every swing it takes is threat.
    assert(keeper.ai.threatOf(myGuid) > 0);

    // The player stops and leaves: nobody is left in its threat list, so it evades home and heals.
    anduin.write(Opcode.CMSG_ATTACKSTOP, null);
    anduin.write(Opcode.CMSG_LOGOUT_REQUEST, null);
    anduin.read();
    tick(30_000);
    assert(!keeper.ai.inCombat && keeper.values.get!UNIT_FIELD_TARGET == 0);
    foreach (_; 0 .. 40)
        map.update(500.msecs);
    assert(!keeper.ai.evading && keeper.values.get!UNIT_FIELD_HEALTH == 500, "home, and whole again");

    // A hostile creature notices a player that moves within its aggro radius, and attacks.
    enum uint players = 1, monsters = 8;
    auto jaina = loggedIn(context, db, 8, "Jaina", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    jaina.read();
    const humans = jaina.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, 0, players, 0, 0, 0,
        0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    keeper.factionTemplate = context.client.factionTemplates.lookup(14);
    (cast(CreatureTemplate*) keeper.template_).detection = 20;
    jaina.write(Opcode.MSG_MOVE_HEARTBEAT, moveTo(Position(-8949.5f, -132, 83.53f, 1.97f)));
    assert(keeper.ai.inCombat && keeper.ai.currentVictim == jaina.session.character.guid, "attacked on sight");
}
