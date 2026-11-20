/**
 * Creatures that fight: the base creature AI (`CreatureAI`), its threat list, its combat timers
 * and leash, chasing its victim and going home, and a creature's half of melee.
 *
 * Every creature gets this AI; one with a script (`creature_ai_scripts`, `dmangos.world.eventai`)
 * runs it from here, and casts its spells with `dmangos.world.creaturecasting`. A creature with
 * `CREATURE_EXTRA_FLAG_NO_AGGRO_ON_SIGHT` is defensive: it fights back but attacks nobody on sight.
 * Creatures call allies near them for help, and chase in straight lines (no movement maps).
 */
module dmangos.world.creatureai;

/// What a creature's linked creatures react to (`CombatWorld.linked`).
enum LinkEvent : ubyte { aggro, evade, despawn }

import std.math : atan2, cos, sin, sqrt;

import dmangos.world.combat;
alias attackStartPacket = dmangos.world.combat.attackStart;
import dmangos.world.creature : Creature, VirtualItem;
import dmangos.world.gameobject : GameObject;
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
import dmangos.world.worlddata : SpellListEntry;
import dmangos.world.eventai : Scripted;
import dmangos.script.registry : ScriptHandle, ScriptRuntime;
import dmangos.script.api : ActionResult, MenuOption, QuestProgress, Waypoint, CreatureHost, Damaged, Died, EnteredCombat, EntityRef, Evaded, KilledUnit, Reset, UnitInSight;
import dmangos.world.updatefields;
import dmangos.vmap.math : Vector3;
import dmangos.world.unit : UnitKind, UnitRef;


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

    /// Summons a creature of `entry` at `at` (all zeros: near `summoner`), going as `type`
    /// (`TempSpawnType`) says after `durationMs`; null if it could not be made.
    Creature summon(CombatWorld world, uint entry, Position at, uint type, uint durationMs, ulong summoner);

    /// A `creature_ai_summons` row: where, and for how long; false if there is none.
    bool summonSpot(uint id, out Position at, out uint seconds);

    /// Starts relay script `id` (`DbScriptType.relay`) on `world` (negative `id`: one of the relay group -`id`).
    void startRelay(int id, CombatWorld world, ulong source, ulong target);

    /// A `script_texts` row; null if there is none. Its sound (0: none).
    const(BroadcastText)* scriptText(int entry);
    /// ditto
    uint scriptTextSound(int entry);

    /// What a creature holding item `entry` shows (nothing for 0 or an unknown item).
    VirtualItem virtualItem(uint entry);

    /// A `Signal` for the script of dungeon copy `instance` (nothing if it has none).
    void signalDungeon(uint instance, EntityRef from, uint id, int value);

    /// A model of creature `entry` (its template's first); 0 if none.
    uint displayOf(uint entry);

    /// Spell list `id`'s spells (`creature_spell_list`); empty if none.
    const(SpellListEntry)[] spellList(uint id);

    /// `creature` becomes a creature of `entry` (`Creature.changeEntry`); false if there is no such entry.
    bool changeEntry(Creature creature, uint entry);

    /// The escort path (`script_waypoint`) of creature `entry`; empty if it has none.
    const(Waypoint)[] escortPath(uint entry);

    /// A `Signal` for creature `to`: its script here, or (another node simulates it) sent there.
    ActionResult signalCreature(CombatWorld world, EntityRef from, EntityRef to, uint id, int value);

    /// The server's scripts, and the script of spell `id` (no handle if none serves it).
    @property ScriptRuntime scriptRuntime();
    /// ditto
    ScriptHandle spellScript(uint id);

    // Kalimdor scripts:

    /// Whether two players are in one group.
    bool sameGroup(ulong a, ulong b);
    // Eastern Kingdoms scripts:

    /// The guid of the nearest game object of `entry` within `range` yards of `center` on `world`; 0 if none.
    ulong gameObjectNear(CombatWorld world, Position center, uint entry, float range);

    /// Uses game object `guid` on `world` as a door or button is used: open for its time.
    ActionResult useGameObject(CombatWorld world, ulong guid);

    /// Spell `spell` teleports player `guid` to its `spell_target_position` (a creature's cast: a boss's room).
    void teleportBySpell(ulong guid, uint spell);

    /// A creature of dungeon copy `instance` began fighting `enemy`, or (no enemy) gave its fight up:
    /// the copy's script hears of it (`CreatureEngaged`, `CreatureEvaded`).
    void dungeonFight(uint instance, EntityRef creature, EntityRef enemy);

    // Raid scripts:

    /// The answer of dungeon copy `instance`'s script to question `id` from `from` (0: none).
    int askDungeon(uint instance, EntityRef from, uint id);

    // Instance round 2:

    /// Scripted event `event` (a creature's `SEND_EVENT`) happens on `world`, `source` starting it at
    /// `target`: its script, the dungeon's, then its database script (`WorldContext.scriptedEvent`).
    void scriptedEvent(uint event, CombatWorld world, ulong source, ulong target);

    // Open-world round 2:

    /// `defender`'s zone is under attack by `attacker` (a player, or a pet): the players of the other side
    /// on this node are told (`SMSG_ZONE_UNDER_ATTACK`; the client writes it in its defense channel).
    void zoneUnderAttack(CombatWorld world, Creature defender, ulong attacker);

    /// `creature`, not fighting, goes back to its spawn point and then moves as it does by itself.
    void sendCreatureHome(CombatWorld world, Creature creature);

    /// A `Signal` from `from` for the script of the continent `world` is (nothing in a dungeon, or without one).
    void signalWorldMap(CombatWorld world, EntityRef from, uint id, int value);

    /// The waypoint path a creature of `entry` (spawn `guid`) walks by default; none if it has none.
    const(imported!"dmangos.world.motion".WaypointNode)[] creaturePath(uint entry, uint guid);

    /// A creature's base damage at `level` for its class (`creature_template_classlevelstats`); 0 if none.
    float creatureBaseDamage(uint level, uint unitClass);

    /// The zone and area at `at` on map `map`; zeros where the terrain is not known.
    uint[2] zoneAndAreaAt(uint map, Position at);

    /// Whether the player `player` (a pet's owner for a pet) meets condition `id` (`conditions`); false if the
    /// player is not online here.
    bool conditionMet(uint id, ulong player);
}

/// What a creature's AI needs of its map.
interface CombatWorld : MotionWorld
{
    /// The unit with this guid on the map: a player simulated here, or a creature; none if neither.
    UnitRef unit(ulong guid);

    /// `creature` as a unit on this map.
    UnitRef unitOf(Creature creature);

    /// Whether nothing built stands between two points (at eye height).
    bool inLineOfSight(Position a, Position b);

    /// Sends what changed in the creature's fields to those who see it.
    void flushCreature(Creature creature);

    /// Puts a resting creature back in the tick.
    void wake(ulong guid);

    /// A dead creature's corpse has lasted its time: it goes, and comes back when its respawn time is up.
    void corpseExpired(Creature creature);

    /// The creatures within `range` yards of `center` here.
    Creature[] creaturesNear(Position center, float range);

    /// The players within `range` yards of `center` here, as units.
    UnitRef[] playersNear(Position center, float range);

    /// The creature with this guid here; null if none.
    Creature creatureAt(ulong guid);

    /// Where the object (a replica too) with this guid is on the map; false if it is not here.
    bool positionOf(ulong guid, out Position at);

    /// Something happened to `source` that linked creatures follow (`dmangos.world.creaturelinking`): it was
    /// attacked by `enemy` (`LinkEvent.aggro`) or evades.
    void linked(Creature source, LinkEvent event, ulong enemy);

    /// A packet for the players within `range` yards of `center`.
    void sendInRange(Position center, float range, Opcode opcode, const(ubyte)[] body_);

    // Kalimdor scripts:

    /// The game object with this guid here; null if none.
    GameObject gameObjectAt(ulong guid);

    /// Sends what changed in the game object's fields to those who see it.
    void flushGameObject(GameObject go);
}

/// How far a creature's call for help reaches (yards), how long its allies take to come (ms), and
/// how near an ally a fighting creature must pass to pull it in (yards).
enum float assistanceRadius = 5;
enum int assistanceDelay = 1500; /// ditto
enum float checkForHelpRadius = 5; /// ditto

/// `CREATURE_EXTRA_FLAG_NO_CALL_ASSIST`: it does not call for help when it starts fighting.
enum uint extraFlagNoCallAssist = 0x800;

/// `CREATURE_EXTRA_FLAG_AGGRO_ZONE`: in a dungeon, a player's attack puts it in combat with everyone there.
enum uint extraFlagAggroZone = 0x200;

/// How a creature reacts to others.
enum ReactState : ubyte
{
    passive,    /// never attacks
    defensive,  /// fights back
    aggressive, /// also attacks on sight
}

/// Past this from where its timer last started, a creature's victim is out of reach.
enum float leashRadius = 30;

/// Out of combat a creature gets a third of its health back this often.
enum int regenInterval = 5000;

/// Milliseconds between leash checks.
enum int combatManagerTick = 1200;

/// The `SMSG_AI_REACTION` of a creature that turns hostile.
enum uint aiReactionHostile = 2;

/// See the module documentation.
final class CreatureAI : Scripted, CreatureHost
{
    import dmangos.world.creaturecasting : CreatureCasting;
    import dmangos.world.creaturescripting : CreatureScripting;

    import dmangos.world.creatureevents : CreatureEvents;

    mixin CreatureCasting;
    mixin CreatureScripting;
    mixin CreatureEvents;
    import dmangos.world.petai : PetBehaviour;

    mixin PetBehaviour;

    private
    {
        Creature me;
        float[ulong] threat;       // its threat list: who it fights, and how much each has done to it
        bool chaseWalking;         // its script has it walk after its victim
        bool rootedForFight;       // its script holds it in place until the fight ends
        bool calledAssistance;     // `m_AlreadyCallAssistance`: once a fight
        Creature[] assistanceReceivers; // the allies called, until the call arrives
        ulong assistanceEnemy;     // whom they are called against
        int assistanceTimer;       // until then, in milliseconds
        int helpCheckTimer;        // until it next pulls in allies it passes
        ulong victim;              // `m_attacking`: whom it attacks
        bool meleeAttacking;       // swinging at its victim
        bool inCombat_;
        bool evadingHome;          // running back, ignoring everything
        int unreachableTimer;      // ms left before it gives up on its victim
        bool victimReachable = true; // its last way to the victim ended within reach
        bool[ulong] suppressed;    // given up on, while it has others to fight
        int attackTimer;           // until the next swing
        int combatTimer;           // the pursuit time left
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

    /// Whether it is in combat.
    @property bool inCombat() const
    {
        return inCombat_;
    }

    /**
     * Running home, or unable to reach its victim (for up to 10 s):
     * attacks on it are evaded, so nobody fights it from where it cannot answer.
     */
    @property bool evading() const
    {
        return evadingHome || unreachableTimer > 0;
    }

    /// Running home; it cannot be attacked.
    @property bool runningHome() const
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
        // Eastern Kingdoms scripts: a script that wants to hear of the players in its sight (`UnitInSight`) does.
        if (behaviour && me.alive && scripts_.handles!UnitInSight(behaviour))
            return true;
        if (script !is null && script.watchesLineOfSight && me.alive && !me.petOwner) // `EVENT_T_OOC_LOS`
            return true;
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
     * A player (or a pet) came into sight, or it came into a player's. An
     * aggressive creature that may attack it on sight attacks it if it is within its aggro radius
     * and line of sight.
     */
    void moveInLineOfSight(UnitRef who, CombatWorld world)
    {
        world_ = world;
        if (behaviour && me.alive)
            unitInSight(who); // Eastern Kingdoms scripts
        scriptSaw(who, world);
        // In a dungeon a fighting creature still notices those coming near: they join its fight (CMaNGOS's
        // `DetectOrAttack`, `EngageInCombatWith`). Elsewhere it has eyes only for its victim.
        if (react != ReactState.aggressive || (victim && !inDungeon) || evadingHome || !me.alive || me.petOwner)
            return;
        if (me.factionTemplate !is null && isNeutralToAll(*me.factionTemplate))
            return;
        if (me.values.get!UNIT_FIELD_FLAGS & (UnitFlags.spawning | UnitFlags.uninteractible)) // cannot start a fight
            return;
        const target = who.fighter;
        if (!target.alive || who.untouchable)
            return;
        // May attack it, and is its enemy.
        const self = relating, other = who.relating;
        if (!canAttack(self, other, me.client) || !isEnemy(self, other, me.client))
            return;
        // Within the aggro radius and in sight.
        const radius = attackDistance(target);
        const dx = me.position.x - target.position.x, dy = me.position.y - target.position.y,
            dz = me.position.z - target.position.z;
        if (dx * dx + dy * dy + dz * dz > radius * radius)
            return;
        if (!world.inLineOfSight(me.position, target.position))
            return;
        // A stealthed one only if it detects it: in front, near enough for its level and the stealth's strength.
        // Short of that but within the alert range, its script hears of it (a lookout on its guard).
        if (target.stealthed)
        {
            import dmangos.world.combat : detects;

            const watcher = me.fighter;
            if (!detects(watcher, target, radius))
            {
                if (behaviour && detects(watcher, target, radius, true))
                    stealthAlert(who);
                return;
            }
        }
        if (!inCombat_)
            attackStart(who, world);
        else if ((who.combatGuid in threat) is null)
            addThreat(who, 0);
    }

    /**
     * Whether it is in a dungeon (an instance or a raid, not a battleground), where creatures do not
     * give up a fight by their pursuit time, and see those who come near while they fight.
     */
    @property bool inDungeon()
    {
        if (lore is null || !me.instanceId)
            return false;
        const entry = lore.clientData.maps.lookup(me.spawn.map);
        return entry !is null && entry.isDungeon;
    }

    /// Hit (or swung at) by `attacker`; it fights back if it is not fighting yet.
    void attackedBy(UnitRef attacker, CombatWorld world)
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

    /**
     * The threat of damage taken: what `attacker` did to it, times `threatFactor` (the attacker's threat auras);
     * direct damage restarts its combat timer.
     */
    void damageTaken(UnitRef attacker, uint damage, float threatFactor = 1)
    {
        if (!me.alive || evadingHome || me.petOwner)
            return;
        addThreat(attacker, damage * threatFactor);
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
        // Eastern Kingdoms scripts: its summoner's script hears of it.
        if (world !is null && me.summon.summoner)
            if (auto summoner = world.creatureAt(me.summon.summoner))
                if (summoner.ai !is null)
                    summoner.ai.summonedDied(world, EntityRef(me.guid), EntityRef(victim));
        foreach (guid, _; threat)
            notifyRemoved(guid, world);
        threat = null;
        // Its swing stops, as everyone watching is told (CMaNGOS's `CombatStop` for the dead).
        if (meleeAttacking && world !is null)
            world.sendToObservers(me.guid, Opcode.SMSG_ATTACKSTOP, attackStop(me.guid, victim, true));
        victim = 0;
        meleeAttacking = false;
        inCombat_ = evadingHome = false;
    }

    // -----------------------------------------------------------------------
    // The update
    // -----------------------------------------------------------------------

    /**
     * The creature's AI tick: the combat timers and leash, `updateAI` (choosing its victim,
     * evading when there is none, chasing, swinging), and regeneration out of combat.
     */
    void update(CombatWorld world, int diff)
    {
        if (!me.alive)
            return;
        world_ = world;
        // A forced despawn: gone, to come back after its respawn time.
        if (despawnTimer > 0 && (despawnTimer -= diff) <= 0)
        {
            despawnTimer = 0;
            world.linked(me, LinkEvent.despawn, 0); // its pack's that go with it go too
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
            // Curse of Recklessness (`PREVENTS_FLEEING`) holds it in the fight through a fear (`HandlePreventFleeing`).
            const feared = me.auras.has(AuraType.modFear) && !me.auras.has(AuraType.preventsFleeing);
            const confused = me.auras.has(AuraType.modConfuse);
            if (!me.auras.has(AuraType.modStun) && fleeTimer <= 0 && !feared && !confused)
                spellListTick(world, diff);
            if (inCombat_ && (feared || confused))
                updateControlledWalk(feared);
            else
            {
                controlledWalkEnded();
                if (inCombat_ && fleeTimer > 0)
                    updateFleeing(diff);
                else if (inCombat_ && !me.auras.has(AuraType.modStun)) // stunned, it does nothing
                    updateAI(world);
            }
            if (inCombat_)
                updateReachability(world, diff);
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

    /// Its aggro radius against `target`, in yards.
    float attackDistanceTo(const Fighter target) const
    {
        return attackDistance(target);
    }

    /// Its aggro radius against `who` (`.debug aggrorange`), in yards.
    float aggroRangeFor(UnitRef who)
    {
        return attackDistance((cast() who).fighter);
    }

    /// The world it acts in, for a script that drives it before it ticks.
    void bind(CombatWorld world)
    {
        world_ = world;
    }

    /// A linked creature brings it into a fight with `who`: it attacks, or (fighting already) counts it as a threat.
    void joinLinkedFight(UnitRef who, CombatWorld world)
    {
        if (inCombat_)
            addThreat(who, 0);
        else
            attackStart(who, world);
    }

    /// A linked creature evades: it does too, if it fights.
    void evadeWithLinked(CombatWorld world)
    {
        if (inCombat_)
            enterEvadeMode(world);
    }

private:
    /// How the relations see it.
    @property Relating relating() const
    {
        Relating r = Relating(me.values.get!UNIT_FIELD_FLAGS, me.factionTemplate, false, 0, 0, me.alive);
        r.playerOwned = me.petOwner != 0 || me.guardianOwner != 0;
        r.controller = me.petOwner ? me.petOwner : me.guardianOwner;
        r.playerFlags = me.controllerPlayerFlags;
        return r;
    }

    /// Its aggro radius: its detection range, a yard more for each level its target is below it.
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

    /// `who`'s threat changes by `percent` (-100: none left; it stays in the list).
    public void modifyThreatPercent(ulong who, int percent)
    {
        if (auto t = who in threat)
            *t = *t * (percent <= -100 ? 0 : (100 + percent) / 100.0f);
    }

    /// The most threat anyone has on it; 0 with nobody in its list.
    public float highestThreat() const
    {
        float top = 0;
        foreach (_, t; threat)
            if (t > top)
                top = t;
        return top;
    }

    /**
     * Taunted by `who` (`SPELL_EFFECT_ATTACK_ME`, CMaNGOS's `EffectTaunt`): its threat raised to the
     * highest in the list and attacked at once. Its taunt aura, if any, then holds it there (`tauntedBy`).
     */
    public void taunt(UnitRef who, CombatWorld world)
    {
        if (!me.alive || evadingHome || me.petOwner)
            return;
        world_ = world;
        const top = highestThreat();
        const own = threatOf(who.combatGuid);
        addThreat(who, top > own ? top - own : 0);
        attackStart(who, world);
    }

    /**
     * The one whose taunt aura (`SPELL_AURA_MOD_TAUNT`) it is under, the latest first, while it is in its
     * threat list: it attacks that one whatever the threat (CMaNGOS's taunt states); 0 if none.
     */
    public ulong tauntedBy() const
    {
        foreach_reverse (aura; me.auras.list)
            if (aura.has(AuraType.modTaunt) && (aura.caster in threat) !is null)
                return aura.caster;
        return 0;
    }

    /**
     * `guid` is out of its fight (Feign Death, Vanish, Divine Intervention: CMaNGOS's `CombatStop` of the
     * player, which deletes its hostile references): out of the threat list, told so; with nobody left
     * it evades at its next update.
     */
    public void forget(ulong guid, CombatWorld world)
    {
        if ((guid in threat) is null)
            return;
        threat.remove(guid);
        suppressed.remove(guid);
        notifyRemoved(guid, world);
        if (victim == guid && threat.length)
        {
            world_ = world;
            if (auto next = world.unit(selectNextVictim(world)))
                attackStart(next, world);
        }
        world.wake(me.guid);
    }

    /**
     * Distracted (`SPELL_EFFECT_DISTRACT`: Distract): out of combat and able to react, it stops where it
     * is, faces `at`, and stands so for `ms` before it moves as it did (CMaNGOS's `MoveDistract`).
     */
    public void distract(Position at, int ms, CombatWorld world)
    {
        import dmangos.vmap.math : Vector3;
        import dmangos.world.motion : DistractMovement;

        if (!me.alive || inCombat_ || evadingHome || me.petOwner || me.immobilized || ms <= 0)
            return;
        world_ = world;
        stopMoving(me, world);
        const facing = angleTo(me.position, at);
        const p = me.position;
        launch(me, world, [Vector3(p.x, p.y, p.z), Vector3(p.x, p.y, p.z)], true, facing);
        me.movement.position.orientation = facing;
        auto after = cast(DistractMovement) me.generator;
        me.generator = new DistractMovement(ms, after !is null ? after.after : me.generator);
        world.wake(me.guid);
    }

    /// Adds threat; a new entry tells the player it is in combat.
    package void addThreat(UnitRef who, float amount)
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

    /// Forgets everyone it fought, each told it no longer threatens them (a beast tamed, gone from the world).
    package void dropThreat(CombatWorld world)
    {
        foreach (guid, _; threat)
            notifyRemoved(guid, world);
        threat = null;
    }

    void notifyRemoved(ulong guid, CombatWorld world)
    {
        if (world !is null)
            if (auto who = world.unit(guid))
                who.threatRemoved(me.guid);
    }

    /**
     * Attacks `who`, enters combat with it, and chases it.
     */
    void attackStart(UnitRef who, CombatWorld world)
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
            helpCheckTimer = 2000; // ms before it first looks for allies to pull in
            callAssistance(who, world);
            world_ = world;
            if (script !is null)
                script.combatStarted(this, guid);
            raiseScript(EnteredCombat(EntityRef(guid)));
            if (lore !is null && me.instanceId) // its dungeon's script: an encounter may begin
                lore.dungeonFight(me.instanceId, EntityRef(me.guid), EntityRef(guid));
            // `CREATURE_EXTRA_FLAG_AGGRO_ZONE`: a boss pulled by a player in a dungeon fights everyone in it.
            if ((me.template_.extraFlags & extraFlagAggroZone) && inDungeon && inCombat_
                    && (who.kind == UnitKind.player || who.relating.playerOwned))
                scriptZoneCombatPulse();
            world.linked(me, LinkEvent.aggro, guid); // its pack joins in
        }
        world.flushCreature(me);
        world.wake(me.guid);
    }

    // -----------------------------------------------------------------------
    // Help: calling allies, and pulling in those it passes
    // -----------------------------------------------------------------------

    /**
     * Calling for help: once a fight,
     * the allies near it (`CallForHelp` yards, or 5) that may join are told, and join in after a
     * moment and a half.
     */
    void callAssistance(UnitRef enemy, CombatWorld world)
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

    /// Whether it calls for help at all.
    @property bool canCallForAssistance() const
    {
        return !(me.template_.extraFlags & extraFlagNoCallAssist);
    }

    /**
     * Whether it may help `who` against `enemy` (CMaNGOS's `CanAssistInCombatAgainst`): one that would attack
     * `enemy`, and outside dungeons not fighting already and an ally of `who` (friendly to it). In a dungeon (or
     * a battleground) any creature that may attack `enemy` joins, fighting or not, whatever its faction.
     */
    bool canAssistAgainst(const Creature who, UnitRef enemy)
    {
        if (!me.alive || evadingHome || react != ReactState.aggressive)
            return false;
        if (me.values.get!UNIT_FIELD_FLAGS & (UnitFlags.spawning | UnitFlags.uninteractible | UnitFlags.immuneToNpc))
            return false;
        const self = relating, target = enemy.relating;
        if (!enemy.fighter.alive || enemy.untouchable || !canAttack(self, target, me.client))
            return false;
        if (instanceable)
            return victim != enemy.combatGuid;
        if (inCombat_ || who.values.get!UNIT_FIELD_FLAGS & UnitFlags.uninteractible)
            return false;
        const ally = who.ai.relating;
        if (reactionTo(self, ally, me.client) < ReputationRank.friendly)
            return false;
        return isEnemy(self, target, me.client);
    }

    /// Whether it is in a dungeon or a battleground (CMaNGOS's `Map::Instanceable`).
    @property bool instanceable()
    {
        if (lore is null || !me.instanceId)
            return false;
        const entry = lore.clientData.maps.lookup(me.spawn.map);
        return entry !is null && (entry.isDungeon || entry.isBattleground);
    }

    /**
     * Whether it answers a call for help (CMaNGOS's `OnCallForHelp`): only a creature whose faction template
     * says so (`FACTION_TEMPLATE_RESPOND_TO_CALL_FOR_HELP`). Allies it pulls in by passing them do not ask.
     */
    @property bool answersCallsForHelp() const
    {
        enum uint respondToCallForHelp = 0x01;
        return me.factionTemplate is null || (me.factionTemplate.flags & respondToCallForHelp) != 0;
    }

    /// The help called for arrives: each ally still free to come, and whose faction answers, attacks.
    void deliverAssistance(CombatWorld world)
    {
        auto enemy = world.unit(assistanceEnemy);
        auto receivers = assistanceReceivers;
        assistanceReceivers = null;
        if (!enemy)
            return;
        foreach (other; receivers)
            if (other.ai !is null && other.ai.canAssistAgainst(me, enemy))
            {
                other.ai.calledAssistance = true; // it does not call others in turn
                if (other.ai.answersCallsForHelp)
                    other.ai.joinFightAgainst(enemy, world);
            }
    }

    /// Attacks `enemy`, or (fighting already, in a dungeon) adds it to those it fights.
    void joinFightAgainst(UnitRef enemy, CombatWorld world)
    {
        if (inCombat_)
            addThreat(enemy, 0);
        else
            attackStart(enemy, world);
    }

    /**
     * Pulling in help: a fighting creature that comes within 5 yards of an
     * ally free to help (and seen by it) pulls it into the fight against its victim.
     */
    void checkForHelp(CombatWorld world)
    {
        if (!victim || !canCallForAssistance)
            return;
        auto enemy = world.unit(victim);
        if (!enemy)
            return;
        foreach (other; world.creaturesNear(me.position, checkForHelpRadius))
            if (other !is me && other.ai !is null && other.ai.canCallForAssistance && !other.ai.inCombat
                && other.ai.canAssistAgainst(me, enemy) && world.inLineOfSight(other.position, me.position))
                other.ai.attackStart(enemy, world);
    }

    /// Combat starts where it stands; its way of moving waits until it is home.
    void enterCombat(CombatWorld world)
    {
        inCombat_ = true;
        combatStart = me.position;
        triggerCombatTimer();
        combatTick = combatManagerTick;
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS | UnitFlags.inCombat);
        if (outOfCombat is null)
        {
            import dmangos.world.motion : DistractMovement;

            auto distracted = cast(DistractMovement) me.generator; // a fight ends a distraction
            outOfCombat = distracted !is null ? distracted.after : me.generator;
        }
        me.generator = new IdleMovement;
        stopMoving(me, world);
    }

    /// Its pursuit time again, from where it is.
    void triggerCombatTimer()
    {
        combatTimer = me.template_.pursuit;
        lastRefresh = me.position;
    }

    /// Stops swinging.
    void meleeStop(CombatWorld world)
    {
        if (meleeAttacking)
        {
            meleeAttacking = false;
            world.sendToObservers(me.guid, Opcode.SMSG_ATTACKSTOP, attackStop(me.guid, victim, !me.alive));
        }
    }

    /**
     * The leash: once its pursuit time has run out, a victim more than `leashRadius` from
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
        // The pursuit time is not looked at in dungeons (CMaNGOS: "disabled in instances").
        if (combatTimer == 0 && victim && !inDungeon)
            if (auto target = world.unit(victim))
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

    /// How long it tries to reach a victim it cannot.
    enum int unreachableEvadeMs = 10_000;

    /**
     * Reachability: while its victim cannot
     * be reached (its way ends out of reach: on a rock, a ledge, across water it cannot path over), it
     * evades every attack; after 10 s it goes home if the victim was its only enemy, and otherwise
     * leaves that one be and turns to another. Reachable again, it fights on.
     */
    void updateReachability(CombatWorld world, int diff)
    {
        if (!combatMovement_ || !victim || victimReachable)
        {
            unreachableTimer = 0;
            return;
        }
        if (unreachableTimer == 0)
        {
            unreachableTimer = unreachableEvadeMs;
            return;
        }
        unreachableTimer -= diff;
        if (unreachableTimer > 0)
            return;
        unreachableTimer = 0;
        if (threat.length <= 1)
            return enterEvadeMode(world);
        suppressed[victim] = true;
        victimReachable = true; // the next victim's way is looked at afresh
    }

    /**
     * Its fight each tick: choosing its victim (the threat list without those gone, dead or no longer
     * to be attacked; evading if nobody is left), then chasing and swinging when ready.
     */
    void updateAI(CombatWorld world)
    {
        ulong[] gone;
        foreach (guid, _; threat)
        {
            auto who = world.unit(guid);
            if (!who || !who.fighter.alive || who.untouchable || !canAttack(relating, who.relating, me.client))
                gone ~= guid;
        }
        foreach (guid; gone)
        {
            threat.remove(guid);
            notifyRemoved(guid, world);
        }
        if (threat.length == 0)
            return enterEvadeMode(world);
        auto target = world.unit(selectNextVictim(world));
        if (target.combatGuid != victim)
            attackStart(target, world);
        if (casting_ !is null)
        {
            // Casting: it stands, facing its target.
            me.movement.position.orientation = angleTo(me.position, target.fighter.position);
            return;
        }
        chase(target, world);
        meleeAttackIfReady(target, world);
    }

    /**
     * The next victim: the most hated, but the current victim keeps its place
     * unless another has more than 110% of its threat in melee reach, or 130% anywhere.
     */
    ulong selectNextVictim(CombatWorld world)
    {
        import std.algorithm.sorting : sort;

        // Taunted: the taunter, whatever the threat.
        if (const taunter = tauntedBy())
            return taunter;
        auto order = threat.keys;
        order.sort!((a, b) => threat[a] > threat[b] || (threat[a] == threat[b] && a < b));
        // Those given up on come last, while there are others.
        if (suppressed.length)
        {
            import std.algorithm.mutation : SwapStrategy;

            order.sort!((a, b) => (a in suppressed) is null && (b in suppressed) !is null, SwapStrategy.stable);
            if ((order[0] in suppressed) is null && (victim in suppressed) !is null)
                return order[0];
        }
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
            auto who = world.unit(guid);
            const inMelee = cast(bool) who && canReachWithMelee(self, who.fighter);
            if (t > 1.3f * *current || (t > 1.1f * *current && inMelee))
                return guid;
        }
        return victim;
    }

    /**
     * Chasing: runs to its target until it can reach it, setting off again when the
     * target has moved on, and faces it.
     */
    void chase(UnitRef target, CombatWorld world)
    {
        const self = me.fighter, other = target.fighter;
        me.movement.position.orientation = angleTo(me.position, other.position);
        if (!combatMovement_)
            return;
        // Ranged mode, or its script's distance (`ACTION_T_RANGED_MOVEMENT`): near enough, it stays (`m_attackDistance`).
        const keep = rangedMode_ ? chaseDistance_ : attackDistance_;
        if (keep > 0 && moved(me.position, other.position) <= keep
            && world.inLineOfSight(me.position, other.position))
        {
            if (!me.spline.finalized)
                stopMoving(me, world);
            return;
        }
        if (canReachWithMelee(self, other))
        {
            victimReachable = true;
            if (!me.spline.finalized && moved(chasedTo, other.position) > 0.5f)
                stopMoving(me, world);
            return;
        }
        if (!me.spline.finalized && moved(chasedTo, other.position) < 1)
            return;
        // To a point just within reach (or its casting distance), on the line between the two.
        const reach = keep > 0 ? keep - 1 : meleeReach(self, other) - 1;
        // At its script's angle from the way its victim faces, or on the line between the two.
        const angle = !rangedMode_ && attackDistance_ > 0 && attackAngle_ != 0
            ? other.position.orientation + attackAngle_ : angleTo(other.position, me.position);
        const x = other.position.x + reach * cos(angle), y = other.position.y + reach * sin(angle);
        auto z = world.groundHeight(x, y, other.position.z + 2, false);
        if (!(z > -100_000))
            z = other.position.z;
        chasedTo = other.position;
        Vector3[] points = [Vector3(0, 0, 0), Vector3(x, y, z)];
        launch(me, world, points, chaseWalking, float.nan, true);
        // Does the way end within reach of it?
        const end = me.spline.finalDestination;
        const ex = end.x - other.position.x, ey = end.y - other.position.y;
        const within = meleeReach(self, other);
        victimReachable = ex * ex + ey * ey <= within * within;
    }

    // -----------------------------------------------------------------------
    // Its spell list (`creature_spell_list`)
    // -----------------------------------------------------------------------

    private int[] spellListTimers; /// each spell's time until it is ready; empty out of a fight
    private uint spellListChosen;  /// its script's list instead of its template's (raid scripts); 0: its template's

    /// Its script's spell list from now (0: its template's again); the list's timers start afresh.
    package void chooseSpellList(uint id)
    {
        if (id == spellListChosen)
            return;
        spellListChosen = id;
        spellListTimers = null;
    }

    /**
     * In a fight, the spells of its list come round on their timers: the ready ones with no probability
     * first, in order, else one by their probabilities; each at its target (`creature_spell_targeting`),
     * then again after its repeat time. A spell is used at all in a fight by its availability.
     */
    private void spellListTick(CombatWorld world, int diff)
    {
        import std.random : uniform;

        const listId = spellListChosen ? spellListChosen : me.template_.spellList;
        if (lore is null || listId == 0 || casting_ !is null || !victim || me.petOwner)
            return;
        const list = lore.spellList(listId);
        if (list.length == 0)
            return;
        int span(uint low, uint high)
        {
            return cast(int)(high > low ? uniform!"[]"(low, high, world.random) : low);
        }
        if (spellListTimers.length != list.length)
        {
            spellListTimers = new int[list.length];
            foreach (i, ref e; list)
                spellListTimers[i] = e.availability >= 100 || uniform(0, 100, world.random) < e.availability
                    ? span(e.initialMin, e.initialMax) : int.max;
            // A ranged main attack: it keeps its distance to cast it.
            foreach (ref e; list)
                if (e.flags & 2)
                    if (const info = lore.spellInfo(e.spell))
                    {
                        import dmangos.world.spellcast : range;

                        const r = range(*info, lore.clientData)[1];
                        if (r > 5)
                            scriptRangedMode(true, r - 2);
                    }
        }
        foreach (ref t; spellListTimers)
            if (t != int.max)
                t -= diff;
        size_t pick = size_t.max;
        uint total;
        foreach (i, ref e; list)
            if (spellListTimers[i] <= 0)
            {
                if (e.probability == 0)
                {
                    pick = i;
                    break;
                }
                total += e.probability;
            }
        if (pick == size_t.max && total)
        {
            uint roll = uniform(0, total, world.random);
            foreach (i, ref e; list)
                if (spellListTimers[i] <= 0 && e.probability)
                {
                    if (roll < e.probability)
                    {
                        pick = i;
                        break;
                    }
                    roll -= e.probability;
                }
        }
        if (pick == size_t.max)
            return;
        const e = list[pick];
        const spell = lore.spellInfo(e.spell);
        const target = spellListTarget(e.targetId, world);
        if (spell is null || target == 0)
        {
            spellListTimers[pick] = 1000; // no one to cast it at now: try again in a second
            return;
        }
        spellListTimers[pick] = castSpell(spell, target, 0) ? span(e.repeatMin, e.repeatMax) : 500;
    }

    /// The target `creature_spell_targeting` row `id` names for it now; 0 if none.
    private ulong spellListTarget(int id, CombatWorld world)
    {
        import std.random : uniform;

        switch (id)
        {
        case 0, 2, 3, 5: // none (the spell picks), self, and its own dispels and buffs
            return me.guid;
        case 1, 103, 104: // its victim (an area spell's, with someone there)
            return victim;
        case 7: // its victim, if not alone
            return threat.length > 1 ? victim : 0;
        case 4, 6: // a friend other than itself
            foreach (c; world.creaturesNear(me.position, 30))
                if (c !is me && c.alive && !c.petOwner && c.factionTemplate is me.factionTemplate)
                    return c.guid;
            return 0;
        case 200: .. case 207: // a friend missing a share of its health (itself too, for some)
        {
            static immutable uint[8] missing = [10, 50, 90, 10, 50, 90, 25, 25];
            static immutable bool[8] withSelf = [true, true, true, false, false, false, true, false];
            const share = missing[id - 200];
            ulong best;
            float lowest = 101;
            void consider(Creature c)
            {
                const most = c.values.get!UNIT_FIELD_MAXHEALTH;
                if (!c.alive || most == 0)
                    return;
                const pct = 100.0f * c.values.get!UNIT_FIELD_HEALTH / most;
                if (pct <= 100 - share && pct < lowest)
                {
                    lowest = pct;
                    best = c.guid;
                }
            }
            if (withSelf[id - 200])
                consider(me);
            foreach (c; world.creaturesNear(me.position, 40))
                if (c !is me && !c.petOwner && c.factionTemplate is me.factionTemplate)
                    consider(c);
            return best;
        }
        default: // attacks: a player it fights, at random (not its victim, for the "non-tank" ones, if it can)
        {
            const nonTank = id == 101 || id == 108 || id == 110 || id == 120;
            ulong[] players;
            foreach (guid, _; threat)
                if (auto who = world.unit(guid))
                    if (who.kind == imported!"dmangos.world.unit".UnitKind.player && who.fighter.alive && (!nonTank || guid != victim))
                        players ~= guid;
            if (players.length == 0)
                return nonTank ? victim : 0;
            return players[uniform(0, players.length, world.random)];
        }
        }
    }

    /// It parried a swing: its own comes sooner (`combat.parryHasted`), unless its template says it never does
    /// (`CREATURE_EXTRA_FLAG_NO_PARRY_HASTEN`).
    package void parried()
    {
        import dmangos.world.combat : parryHasted;

        enum uint noParryHasten = 0x08;
        if (me.template_.extraFlags & noParryHasten || attackTimer <= 0)
            return;
        attackTimer = parryHasted(attackTimer, me.values.get!UNIT_FIELD_BASEATTACKTIME);
    }

    /// A creature's melee: a swing whenever it is ready and can.
    void meleeAttackIfReady(UnitRef target, CombatWorld world)
    {
        import std.math : PI;

        if (!meleeAttacking || attackTimer || !meleeEnabled || (me.values.get!UNIT_FIELD_FLAGS & UnitFlags.pacified))
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
        if ((d.absorbed = target.absorb(d.school, d.damage)) != 0)
            d.hitInfo |= HitInfo.absorb;
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
     * Evading: stops fighting, forgets its threat list, and runs back
     * to where the fight began, evading every attack on the way.
     */
    void enterEvadeMode(CombatWorld world)
    {
        const wasFighting = inCombat_;
        world_ = world;
        spellListTimers = null; // its list's timers start again in its next fight
        if (rootedForFight)
        {
            me.scriptRooted = false;
            rootedForFight = false;
        }
        scope (exit)
            if (wasFighting)
                world.linked(me, LinkEvent.evade, 0);
        interruptCast();
        nextSwing = null;
        if (fleeTimer > 0)
        {
            fleeTimer = 0;
            me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.fleeing);
        }
        combatMovement_ = true;
        rangedMode_ = rangedModeSet;
        attackDistance_ = attackAngle_ = 0; // its script's chase distance is for one fight
        meleeStop(world);
        foreach (guid, _; threat)
            notifyRemoved(guid, world);
        threat = null;
        victim = 0;
        inCombat_ = false;
        unreachableTimer = 0;
        victimReachable = true;
        suppressed = null;
        me.setLootRecipient(0, 0); // its loot is nobody's any more
        calledAssistance = false;  // the next fight calls again
        assistanceReceivers = null;
        me.values.set!UNIT_FIELD_TARGET(0UL);
        me.values.set!UNIT_FIELD_FLAGS(me.values.get!UNIT_FIELD_FLAGS & ~UnitFlags.inCombat);
        removeAurasOnEvade(world);
        if (script !is null)
            script.evaded(this);
        raiseScript(Evaded());
        if (wasFighting && lore !is null && me.instanceId)
            lore.dungeonFight(me.instanceId, EntityRef(me.guid), EntityRef.init);
        world.flushCreature(me);
        evadingHome = true;
        regenTimer = 0;
        const home = combatStart;
        const dx = home.x - me.position.x, dy = home.y - me.position.y;
        if (dx * dx + dy * dy < 0.01f)
            return reachedHome(world);
        Vector3[] points = [Vector3(0, 0, 0), Vector3(home.x, home.y, home.z)];
        launch(me, world, points, false, home.orientation, true);
    }

    /**
     * Evading, it loses its auras (CMaNGOS's `RemoveAllAurasOnEvade`): its enemies' debuffs and damage over time
     * and its own buffs, but not its passives (`creatureevents.removedOnEvade`). Its health comes back as it does
     * out of combat, a third every five seconds, from the moment it turns for home.
     */
    void removeAurasOnEvade(CombatWorld world)
    {
        import dmangos.world.creatureevents : removedOnEvade;

        foreach (aura; me.auras.list.dup)
            if (aura.spell !is null && removedOnEvade(*aura.spell))
                me.loseAura(aura, world);
    }

    /// Back home; it moves as before the fight.
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

    /// Regeneration: a third of its health every five seconds out of combat.
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
        const addedMana = mana + maxMana / 3; // mana out of combat: a third too
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

/// `SPELL_ATTR_EX_NO_THREAT`, `SPELL_ATTR_EX2_NO_INITIAL_THREAT`: spells that anger nobody.
enum uint spellAttrExNoThreat = 0x00000400, spellAttrEx2NoInitialThreat = 0x00400000;

/**
 * Threat from helping (CMaNGOS's `HostileRefManager::threatAssist`): `helper` healed `amount` of `helped`'s
 * health (or buffed it: no amount). Each of the creatures fighting `helped` (`fightingHelped`) that may attack
 * the helper and is not held (stunned, fleeing, confused) takes the helper into its fight, with half the heal
 * shared out among them as threat (`assistThreatEach`). A spell with `SPELL_ATTR_EX_NO_THREAT` or
 * `SPELL_ATTR_EX2_NO_INITIAL_THREAT` angers no one.
 */
void assistThreat(CombatWorld world, const(ulong)[] fightingHelped, UnitRef helper, uint amount,
    const ref SpellInfo spell)
{
    import dmangos.world.relations : canAttack;

    if (!helper || fightingHelped.length == 0 || spell.attributesEx & spellAttrExNoThreat
            || spell.attributesEx2 & spellAttrEx2NoInitialThreat)
        return;
    Creature[] angered;
    foreach (guid; fightingHelped)
    {
        auto c = world.creatureAt(guid);
        if (c is null || !c.alive || c.ai is null || !c.ai.inCombat || c.ai.runningHome || c.guid == helper.combatGuid)
            continue;
        if (c.values.get!UNIT_FIELD_FLAGS & (UnitFlags.stunned | UnitFlags.fleeing | UnitFlags.confused))
            continue;
        if (canAttack(c.ai.relatingOf, helper.relating, c.client))
            angered ~= c;
    }
    const each = assistThreatEach(amount, angered.length);
    foreach (c; angered)
    {
        c.ai.addThreat(helper, each);
        world.wake(c.guid);
    }
}

/// Each creature's threat from a heal of `amount` shared among `creatures`: half the heal, divided.
float assistThreatEach(uint amount, size_t creatures) pure nothrow @nogc @safe
{
    return creatures ? amount * 0.5f / creatures : 0;
}

unittest
{
    assert(assistThreatEach(1000, 2) == 250, "half of it, shared by two");
    assert(assistThreatEach(1000, 1) == 500);
    assert(assistThreatEach(0, 3) == 0, "a buff: in the fight, without threat");
    assert(assistThreatEach(100, 0) == 0);
}

/// Whether a faction template has no enemies and no friends: neutral to everyone.
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
        [[humans, 1, 0, players | 2, 2, monsters, 0, 0, 0, 0, 0, 0, 0, 0], [14u, 14, 1, monsters, monsters, players, 0, 0,
        0, 0, 0, 0, 0, 0]]), "FactionTemplate.dbc"); // monsters that answer a call for help (as faction 16 does)
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

/**
 * A victim it cannot reach (its way ends out of reach): it evades every attack meanwhile, and after
 * 10 s goes home, its only enemy left be. Reachable, it fights as before.
 */
unittest
{
    import core.time : MonoTime, msecs;
    import dmangos.vmap.math : Vector3;
    import dmangos.world.movement : Position;
    import dmangos.world.objects : HighGuid, makeGuid;
    import dmangos.world.packets : ClientGuid;
    import dmangos.world.testclient;
    import dmangos.world.testdata;

    auto db = newDatabase();
    auto context = newCreationContext(db);
    auto now = MonoTime.currTime;
    context.clock = () => now;
    // A few yards from the innkeeper: out of its melee reach, so it sets off towards the player.
    auto anduin = loggedIn(context, db, 7, "Anduin", Position(-8949.95f, -132.49f, 83.53f, 1.97f));
    anduin.read();
    const innkeeper = makeGuid(HighGuid.unit, creatureInnkeeper, innkeeperSpawn);
    auto map = context.map(0);
    auto keeper = cast(Creature) map.findObject(innkeeper);
    keeper.values.set!UNIT_FIELD_LEVEL(1u);
    keeper.values.set!UNIT_FIELD_MAXHEALTH(500u);
    keeper.values.set!UNIT_FIELD_HEALTH(500u);
    auto me = anduin.session.inWorld;

    void tick(int ms)
    {
        now += ms.msecs;
        anduin.session.update(ms.msecs);
        map.update(ms.msecs);
    }

    // The fight starts in reach; then the player stands 8 yards off, where no way leads.
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    anduin.read();
    tick(50);
    assert(keeper.ai.inCombat);
    const at = keeper.position;
    me.player.movement.position = Position(at.x + 8, at.y, at.z, 0);
    map.relocated(me);
    // (A cliff in between: the way leads along it, never nearer.)
    map.testPaths = (Vector3 from, Vector3 to) => [from, Vector3(from.x, from.y + 2, from.z)];
    tick(100);
    tick(100);
    assert(keeper.ai.inCombat && keeper.ai.evading, "out of reach: it evades");
    assert(!keeper.ai.runningHome, "but fights on for now");
    foreach (_; 0 .. 95)
        tick(100);
    assert(keeper.ai.inCombat, "still trying after 9.5 s");
    foreach (_; 0 .. 10)
        tick(100);
    assert(!keeper.ai.inCombat && keeper.ai.threatList.length == 0, "after 10 s: it gave up, for home");

    // A way that reaches: it fights, and does not evade.
    foreach (_; 0 .. 300)
        tick(100);
    assert(!keeper.ai.evading, "home again");
    map.testPaths = null;
    const there = keeper.position;
    me.player.movement.position = Position(there.x + 1, there.y, there.z, 3.14159f); // facing it
    map.relocated(me);
    anduin.write(Opcode.CMSG_ATTACKSWING, ClientGuid(innkeeper));
    anduin.read();
    tick(100);
    tick(100);
    assert(keeper.ai.inCombat && !keeper.ai.evading, "in reach: a fight as ever");
}
