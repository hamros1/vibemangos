/**
 * Creatures that fight: CMaNGOS's base creature AI (`AI/BaseAI/UnitAI.cpp`, `CreatureAI.cpp`), its
 * threat list (`Combat/ThreatManager.cpp`), its combat timers and leash (`Combat/CombatManager.cpp`),
 * chasing (`ChaseMovementGenerator`) and going home (`HomeMovementGenerator`), and a creature's
 * half of melee (`Unit::Attack`, `UpdateMeleeAttackingState`).
 *
 * Every creature gets this AI; one with a script (`creature_ai_scripts`, `dmangos.world.eventai`)
 * runs it from here, and casts its spells with `dmangos.world.creaturecasting`. A creature with
 * `CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT` is defensive: it fights back but attacks nobody on sight.
 * Creatures call allies near them for help, and chase in straight lines (no movement maps).
 */
module dmangos.world.creatureai;

import std.math : atan2, cos, sin, sqrt;

import dmangos.world.combat;
alias attackStartPacket = dmangos.world.combat.attackStart;
import dmangos.world.creature : Creature, VirtualItem;
import dmangos.world.defines : UnitFlags;
import dmangos.world.motion : IdleMovement, launch, MotionWorld, MovementGenerator, stopMoving;
import dmangos.world.movement : MovementFlags, Position;
import dmangos.world.opcodes : Opcode;
import dmangos.world.relations;
import dmangos.world.auras : Aura, AuraType;
import dmangos.world.clientdata : ClientData;
import dmangos.world.npcdata : BroadcastText;
import dmangos.world.opcodes : ChatType;
import dmangos.world.spells : SpellInfo;
import dmangos.world.eventai : Scripted;
import dmangos.script.registry : ScriptHandle, ScriptRuntime;
import dmangos.script.api : ActionResult, MenuOption, QuestProgress, Waypoint, CreatureHost, Damaged, Died, EnteredCombat, EntityRef, Evaded, KilledUnit, Reset;
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

    /// A periodic effect of its aura on `target` ticked (damage over time).
    void auraTick(Creature target, Aura aura, size_t effect);

    /// Its health in percent.
    uint healthPercent();

    /// A creature's spell hurt it (`DealDamage` from a spell): the log is already sent.
    void spellHitBy(ulong caster, uint damage);

    /// A creature's spell put an aura on it (a debuff).
    void auraFrom(ulong caster, const(SpellInfo)* spell, uint casterLevel, int durationMs, const int[3] values);

    /// Whether it has an aura of `spell`.
    bool hasAuraOf(uint spell);

    /// A packet for it alone (a creature's whisper).
    void tell(Opcode opcode, const(ubyte)[] body_);

    /// Whether it is casting a spell.
    @property bool castingSpell();

    /// A creature's script: the event of quest `quest` happened for it (`AreaExploredOrEventHappens`).
    void questEventHappened(uint quest);

    /// A creature's script: kill credit of `entry` (`KilledMonsterCredit`), from `creature`.
    void killCreditFrom(uint entry, ulong creature);

    /// A creature's script took an aura of `spell` off it.
    void auraRemovedBy(uint spell);

    /// `.invincible`: creatures do not attack it (`isAttackable` is false).
    @property bool untouchable();

    /// A creature's spell interrupted its cast (`SPELL_EFFECT_INTERRUPT_CAST`).
    void castInterruptedBy(ulong creature);

    /// A creature's script: its quest `quest` under way failed (`FailQuest`).
    void questFailedBy(uint quest);

    /// A creature's script: `gossip_menu` `menu` of creature `npc` shown to it.
    void showGossip(ulong npc, uint menu);

    /// A creature's script: its gossip window closes.
    void closeGossip();

    /// A creature's script: where it stands with `quest`.
    QuestProgress questStatusOf(uint quest);

    /// A creature's script: a menu the script built, from creature `npc`.
    void showScriptGossip(ulong npc, uint textId, const(MenuOption)[] options, bool withQuests);
}

/**
 * What a creature's script and spells need of the world's data (`WorldContext` implements it): the
 * spells, the client's tables, the texts, and how far a creature is heard.
 */
interface CreatureLore
{
    /// The spell; null if there is none.
    const(SpellInfo)* spellInfo(uint id);

    /// The client's tables.
    @property const(ClientData) clientData();

    /// A `broadcast_text`; null if there is none.
    const(BroadcastText)* broadcastText(uint id);

    /// `ListenRange.Say`, `.Yell`, `.TextEmote` in yards.
    float listenRange(ChatType type);

    /// `SummonCreature`: a creature of `entry` at `at` (all zeros: near `summoner`), going as `type`
    /// (`TempSpawnType`) says after `durationMs`; null if it could not be made.
    Creature summon(CombatWorld world, uint entry, Position at, uint type, uint durationMs, ulong summoner);

    /// A `creature_ai_summons` row: where, and for how long; false if there is none.
    bool summonSpot(uint id, out Position at, out uint seconds);

    /// `ScriptsStart(SCRIPT_TYPE_RELAY)` on `world` (negative `id`: one of the relay group -`id`).
    void startRelay(int id, CombatWorld world, ulong source, ulong target);

    /// A `script_texts` row; null if there is none. Its sound (0: none).
    const(BroadcastText)* scriptText(int entry);
    /// ditto
    uint scriptTextSound(int entry);

    /// What a creature holding item `entry` shows (nothing for 0 or an unknown item).
    VirtualItem virtualItem(uint entry);

    /// A `Signal` for the script of dungeon copy `instance` (nothing if it has none).
    void signalDungeon(uint instance, EntityRef from, uint id, int value);

    /// The escort path (`script_waypoint`) of creature `entry`; empty if it has none.
    const(Waypoint)[] escortPath(uint entry);

    /// A `Signal` for creature `to`: its script here, or (another node simulates it) sent there.
    ActionResult signalCreature(CombatWorld world, EntityRef from, EntityRef to, uint id, int value);

    /// The server's scripts, and the script of spell `id` (no handle if none serves it).
    @property ScriptRuntime scriptRuntime();
    /// ditto
    ScriptHandle spellScript(uint id);
}

/// What a creature's AI needs of its map.
interface CombatWorld : MotionWorld
{
    /// The player with this guid on the map, if it can fight; null otherwise.
    Combatant combatant(ulong guid);

    /// A creature as a combatant, for a creature (a pet) to fight it; null if creatures fight only players.
    Combatant combatantOf(Creature creature);

    /// `IsWithinLOSInMap`: whether nothing built stands between two points (at eye height).
    bool inLineOfSight(Position a, Position b);

    /// Sends what changed in the creature's fields to those who see it.
    void flushCreature(Creature creature);

    /// Puts a resting creature back in the tick.
    void wake(ulong guid);

    /// A dead creature's corpse has lasted its time: it goes, and comes back when its respawn time is up.
    void corpseExpired(Creature creature);

    /// The creatures within `range` yards of `center` here.
    Creature[] creaturesNear(Position center, float range);

    /// The players within `range` yards of `center` here who can fight.
    Combatant[] combatantsNear(Position center, float range);

    /// The creature with this guid here; null if none.
    Creature creatureAt(ulong guid);

    /// Where the object (a replica too) with this guid is on the map; false if it is not here.
    bool positionOf(ulong guid, out Position at);

    /// A packet for the players within `range` yards of `center`.
    void sendInRange(Position center, float range, Opcode opcode, const(ubyte)[] body_);
}

/// `CreatureFamilyAssistanceRadius`, `CreatureFamilyAssistanceDelay`, `CreatureCheckForHelpRadius` (mangosd.conf).
enum float assistanceRadius = 5;
enum int assistanceDelay = 1500; /// ditto
enum float checkForHelpRadius = 5; /// ditto

/// `CREATURE_EXTRA_FLAG_NO_CALL_ASSIST`: it does not call for help when it starts fighting.
enum uint extraFlagNoCallAssist = 0x800;

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
final class CreatureAI : Scripted, CreatureHost
{
    import dmangos.world.creaturecasting : CreatureCasting;
    import dmangos.world.creaturescripting : CreatureScripting;

    mixin CreatureCasting;
    mixin CreatureScripting;
    import dmangos.world.petai : PetBehaviour;

    mixin PetBehaviour;

    private
    {
        Creature me;
        float[ulong] threat;       // `ThreatManager`: who it fights, and how much each has done to it
        bool calledAssistance;     // `m_AlreadyCallAssistance`: once a fight
        Creature[] assistanceReceivers; // the allies called, until the call arrives
        ulong assistanceEnemy;     // whom they are called against
        int assistanceTimer;       // until then, in milliseconds
        int helpCheckTimer;        // until it next pulls in allies it passes
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
        return inCombat_ || evadingHome || despawnTimer > 0 || me.values.get!UNIT_FIELD_HEALTH < me.values.get!UNIT_FIELD_MAXHEALTH
            || me.values.get!UNIT_FIELD_POWER1 < me.values.get!UNIT_FIELD_MAXPOWER1 || casting_ !is null || fleeTimer > 0 || (script !is null && script.wantsTicks) || behaviourBusy || me.petOwner != 0;
    }

    /// Whether it may attack anyone on sight at all: aggressive, alive, not neutral to all
    /// (`moveInLineOfSight`'s first checks, for the map to skip it early).
    @property bool mayNotice() const
    {
        return react == ReactState.aggressive && me.alive && !me.petOwner
            && (me.factionTemplate is null || !isNeutralToAll(*me.factionTemplate));
    }

    /// The one it attacks; 0 if none.
    @property ulong currentVictim() const
    {
        return victim;
    }

    /// How the relations see it (`Relating`).
    Relating relatingOf() const
    {
        return relating;
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
        world_ = world;
        if (react != ReactState.aggressive || victim || evadingHome || !me.alive || me.petOwner)
            return;
        if (me.factionTemplate !is null && isNeutralToAll(*me.factionTemplate))
            return;
        if (me.values.get!UNIT_FIELD_FLAGS & (UnitFlags.spawning | UnitFlags.uninteractible)) // `CanInitiateAttack`
            return;
        const target = who.fighter;
        if (!target.alive || who.untouchable)
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
        world_ = world;
        if (me.petOwner)
            return petAssist(attacker, world);
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
        if (!me.alive || evadingHome || me.petOwner)
            return;
        addThreat(attacker, damage);
        if (damage)
            triggerCombatTimer();
        if (behaviour)
        {
            // Told before the damage is taken: its health from now to after it.
            const maximum = me.values.get!UNIT_FIELD_MAXHEALTH, health = me.values.get!UNIT_FIELD_HEALTH;
            const after = health > damage ? health - damage : 0;
            const percent = (uint h) => cast(ubyte)(maximum ? (ulong(h) * 100 + maximum - 1) / maximum : 0);
            raiseScript(Damaged(EntityRef(attacker.combatGuid), damage, percent(health), percent(after)));
        }
    }

    /// It died: it fights nobody any more.
    void died(CombatWorld world)
    {
        world_ = world;
        if (world !is null)
            interruptCast();
        casting_ = nextSwing = null;
        fleeTimer = 0;
        if (script !is null && world !is null)
            script.died(this, victim);
        if (world !is null)
            raiseScript(Died(EntityRef(victim)));
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
        world_ = world;
        // `ForcedDespawn`: gone, to come back after its respawn time.
        if (despawnTimer > 0 && (despawnTimer -= diff) <= 0)
        {
            despawnTimer = 0;
            return world.corpseExpired(me);
        }
        if (me.petOwner)
            return petUpdate(world, diff);
        attackTimer = attackTimer > diff ? attackTimer - diff : 0;
        updateCasting(diff);
        if (!me.alive)
            return;
        if (script !is null && !evadingHome)
        {
            script.update(this, diff);
            if (!me.alive)
                return;
        }
        if (behaviour && !evadingHome)
        {
            tickBehaviour(diff);
            if (!me.alive)
                return;
        }
        if (evadingHome)
        {
            if (me.spline.finalized)
                reachedHome(world);
        }
        else if (inCombat_)
        {
            updateCombatManager(world, diff);
            if (inCombat_ && fleeTimer > 0)
                updateFleeing(diff);
            else if (inCombat_ && !me.auras.has(AuraType.modStun)) // `UNIT_STAT_STUNNED`: it does nothing
                updateAI(world);
            if (inCombat_ && assistanceReceivers.length)
            {
                assistanceTimer -= diff;
                if (assistanceTimer <= 0)
                    deliverAssistance(world);
            }
            helpCheckTimer -= diff;
            if (inCombat_ && helpCheckTimer <= 0)
            {
                helpCheckTimer = 1000;
                checkForHelp(world);
            }
        }
        if (!inCombat_)
            regenerate(world, diff);
    }

    /// Its threat list (`.debug threatList`): who it fights, and how much.
    const(float[ulong]) threatList() const
    {
        return threat;
    }

    /// `GetAttackDistance` against `target`, in yards.
    float attackDistanceTo(const Fighter target) const
    {
        return attackDistance(target);
    }

    /// Its aggro radius against `who` (`.debug aggrorange`), in yards.
    float aggroRangeFor(const Combatant who)
    {
        return attackDistance((cast() who).fighter);
    }

    /// The world it acts in, for a script that drives it before it ticks.
    void bind(CombatWorld world)
    {
        world_ = world;
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
    /// `ModifyThreatPercent`: `who`'s threat changes by `percent` (-100: none left; it stays in the list).
    public void modifyThreatPercent(ulong who, int percent)
    {
        if (auto t = who in threat)
            *t = *t * (percent <= -100 ? 0 : (100 + percent) / 100.0f);
    }

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
        {
            enterCombat(world);
            helpCheckTimer = 2000; // `CreatureCheckForHelpAggroDelay`
            callAssistance(who, world);
            world_ = world;
            if (script !is null)
                script.combatStarted(this, guid);
            raiseScript(EnteredCombat(EntityRef(guid)));
        }
        world.flushCreature(me);
        world.wake(me.guid);
    }

    // -----------------------------------------------------------------------
    // Help (`Creature::CallAssistance`, `UnitAI::CheckForHelp`)
    // -----------------------------------------------------------------------

    /**
     * `Creature::CallAssistance` and `SendAIEventAround(AI_EVENT_CALL_ASSISTANCE)`: once a fight,
     * the allies near it (`CallForHelp` yards, or 5) that may join are told, and join in after a
     * moment and a half.
     */
    void callAssistance(Combatant enemy, CombatWorld world)
    {
        if (calledAssistance || !canCallForAssistance)
            return;
        calledAssistance = true;
        const radius = me.template_.callForHelp ? float(me.template_.callForHelp) : assistanceRadius;
        Creature[] receivers;
        foreach (other; world.creaturesNear(me.position, radius))
            if (other !is me && other.ai !is null && other.ai.canAssistAgainst(me, enemy)
                && world.inLineOfSight(me.position, other.position))
                receivers ~= other;
        if (receivers.length == 0)
            return;
        assistanceReceivers = receivers;
        assistanceEnemy = enemy.combatGuid;
        assistanceTimer = assistanceDelay;
    }

    /// Whether it calls for help at all (`CanCallForAssistance`).
    @property bool canCallForAssistance() const
    {
        return !(me.template_.extraFlags & extraFlagNoCallAssist);
    }

    /**
     * `CanAssistInCombatAgainst` (outside dungeons): not fighting already, an ally of `who`
     * (`CanAssist`: friendly to it), and one that would attack `enemy` on sight.
     */
    bool canAssistAgainst(const Creature who, Combatant enemy)
    {
        if (!me.alive || inCombat_ || evadingHome || react != ReactState.aggressive)
            return false;
        if (me.values.get!UNIT_FIELD_FLAGS & (UnitFlags.spawning | UnitFlags.uninteractible | UnitFlags.immuneToNpc))
            return false;
        if (who.values.get!UNIT_FIELD_FLAGS & UnitFlags.uninteractible)
            return false;
        const self = relating, ally = who.ai.relating;
        if (reactionTo(self, ally, me.client) < ReputationRank.friendly)
            return false;
        const target = enemy.relating;
        return enemy.fighter.alive && !enemy.untouchable && canAttack(self, target, me.client)
            && isEnemy(self, target, me.client);
    }

    /// The help called for arrives: `HandleAssistanceCall` for each ally still free to come.
    void deliverAssistance(CombatWorld world)
    {
        auto enemy = world.combatant(assistanceEnemy);
        auto receivers = assistanceReceivers;
        assistanceReceivers = null;
        if (enemy is null)
            return;
        foreach (other; receivers)
            if (other.ai !is null && other.ai.canAssistAgainst(me, enemy))
            {
                other.ai.calledAssistance = true; // `SetNoCallAssistance`: it does not call others in turn
                other.ai.attackStart(enemy, world);
            }
    }

    /**
     * `UnitAI::CheckForHelp` from the other side: a fighting creature that comes within 5 yards of an
     * ally free to help (and seen by it) pulls it into the fight against its victim.
     */
    void checkForHelp(CombatWorld world)
    {
        if (!victim || !canCallForAssistance)
            return;
        auto enemy = world.combatant(victim);
        if (enemy is null)
            return;
        foreach (other; world.creaturesNear(me.position, checkForHelpRadius))
            if (other !is me && other.ai !is null && other.ai.canCallForAssistance
                && other.ai.canAssistAgainst(me, enemy) && world.inLineOfSight(other.position, me.position))
                other.ai.attackStart(enemy, world);
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
            if (who is null || !who.fighter.alive || who.untouchable || !canAttack(relating, who.relating, me.client))
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
        if (casting_ !is null)
        {
            // Casting: it stands, facing its target (`SetInFront`).
            me.movement.position.orientation = angleTo(me.position, target.fighter.position);
            return;
        }
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
        if (!combatMovement_)
            return;
        if (rangedMode_ && moved(me.position, other.position) <= chaseDistance_
            && world.inLineOfSight(me.position, other.position))
        {
            // Ranged mode: near enough to cast; it stays (`m_attackDistance`).
            if (!me.spline.finalized)
                stopMoving(me, world);
            return;
        }
        if (canReachWithMelee(self, other))
        {
            if (!me.spline.finalized && moved(chasedTo, other.position) > 0.5f)
                stopMoving(me, world);
            return;
        }
        if (!me.spline.finalized && moved(chasedTo, other.position) < 1)
            return;
        // To a point just within reach (or its casting distance), on the line between the two.
        const reach = rangedMode_ ? chaseDistance_ - 1 : meleeReach(self, other) - 1;
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

        if (!meleeAttacking || attackTimer || !meleeEnabled)
            return;
        const self = me.fighter, other = target.fighter;
        if (!canReachWithMelee(self, other) || !hasInArc(self.position, other.position, 2 * PI / 3) || !other.alive)
        {
            attackTimer = 100; // delaying a weapon that is not ready would make it ready sooner
            return;
        }
        attackTimer = me.values.get!UNIT_FIELD_BASEATTACKTIME;
        if (swingSpell(target))
            return;
        auto d = calculateMeleeDamage(self, other, AttackType.mainHand, world.random);
        world.sendToObservers(me.guid, Opcode.SMSG_ATTACKERSTATEUPDATE, attackerStateUpdate(d));
        if (d.damage)
            triggerCombatTimer(); // direct damage either way
        target.meleeHitBy(me.guid, d);
        if (!target.fighter.alive && script !is null)
            script.killed(this, target.combatGuid); // `KilledUnit`
        if (!target.fighter.alive)
            raiseScript(KilledUnit(EntityRef(target.combatGuid)));
    }

    /**
     * `UnitAI::EnterEvadeMode`: stops fighting (`CombatStop`), forgets its threat list, and runs back
     * to where the fight began, evading every attack on the way.
     */
    void enterEvadeMode(CombatWorld world)
    {
        world_ = world;
        interruptCast();
        nextSwing = null;
        if (fleeTimer > 0)
        {
            fleeTimer = 0;
            me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.fleeing);
        }
        combatMovement_ = true;
        rangedMode_ = rangedModeSet;
        meleeStop(world);
        foreach (guid, _; threat)
            notifyRemoved(guid, world);
        threat = null;
        victim = 0;
        inCombat_ = false;
        me.setLootRecipient(0, 0); // `TriggerEvadeEvents`: nobody's any more
        calledAssistance = false;  // the next fight calls again
        assistanceReceivers = null;
        me.values.set!UNIT_FIELD_TARGET(0UL);
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.inCombat);
        if (script !is null)
            script.evaded(this);
        raiseScript(Evaded());
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
        world_ = world;
        if (script !is null)
            script.reachedHome(this);
        raiseScript(Reset());
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
        const mana = me.values.get!UNIT_FIELD_POWER1, maxMana = me.values.get!UNIT_FIELD_MAXPOWER1;
        if (health >= maximum && mana >= maxMana)
            return;
        regenTimer += diff;
        if (regenTimer < regenInterval)
            return;
        regenTimer -= regenInterval;
        const added = health + maximum / 3;
        me.values.set!UNIT_FIELD_HEALTH(added > maximum ? maximum : added);
        const addedMana = mana + maxMana / 3; // `RegenerateMana` out of combat: a third too
        me.values.set!UNIT_FIELD_POWER1(addedMana > maxMana ? maxMana : addedMana);
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

/// Attacked, a creature calls its allies near it for help; they come a moment and a half later.
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.dbc : buildDbc;
    import dmangos.world.clientdata : factionTemplateFormat;
    import dmangos.world.creature : CreatureTemplate;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn));
    auto trainer = cast(Creature) map.findObject(makeGuid(HighGuid.unit, creatureTrainer, trainerSpawn));
    assert(keeper !is null && trainer !is null);

    // Both monsters of one faction, three yards apart; the trainer would not notice the player itself.
    enum uint players = 1, monsters = 8;
    const humans = anduin.session.character.values.get!UNIT_FIELD_FACTIONTEMPLATE;
    context.client.factionTemplates = typeof(context.client.factionTemplates).parse(buildDbc(factionTemplateFormat,
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 0, monsters, monsters, players, 0, 0,
        0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc");
    foreach (c; [keeper, trainer])
    {
        c.factionTemplate = context.client.factionTemplates.lookup(14);
        c.values.set!UNIT_FIELD_MAXHEALTH(500u);
        c.values.set!UNIT_FIELD_HEALTH(500u);
    }
    (cast(CreatureTemplate*) trainer.template_).detection = 0;
    trainer.movement.position = Position(-8951, -127, 83.5f, 0);

    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
    }

    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(keeper.guid));
    tick(50);
    assert(keeper.ai.inCombat && !trainer.ai.inCombat, "the call takes a moment");
    foreach (_; 0 .. 4)
        tick(500);
    assert(trainer.ai.inCombat && trainer.ai.currentVictim == anduin.session.character.guid, "the ally came");
}
